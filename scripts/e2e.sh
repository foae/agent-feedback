#!/usr/bin/env bash
# End-to-end test of agent-feedback. Run against a compose deployment; creates
# test submissions in Postgres — clean up via `docker compose down -v` or by
# deleting the rows afterward. Safe to rerun against a persistent database:
# every run uses unique run_ids and unique friction content.
#
# Usage: scripts/e2e.sh <API_KEY> [BASE_URL]
#   BASE_URL defaults to http://127.0.0.1:8090
set -u
if [ -z "${1:-}" ]; then
  echo "usage: $0 <API_KEY> [BASE_URL]" >&2
  exit 2
fi
KEY="$1"
BASE="${2:-http://127.0.0.1:8090}"
RUN="e2e-$(date +%Y%m%d%H%M%S)-$$"
BODY=$(mktemp)
BIG=$(mktemp)
trap 'rm -f "$BODY" "$BIG"' EXIT
pass=0; fail=0
chk() { # chk <desc> <expected_status> <actual_status> [extra_ok]
  local desc=$1 want=$2 got=$3 extra=${4:-1}
  if [ "$want" = "$got" ] && [ "$extra" = 1 ]; then pass=$((pass+1)); echo "PASS  $desc";
  else fail=$((fail+1)); echo "FAIL  $desc (want $want got $got extra_ok=$extra)"; fi
}
req() { curl -sS -o "$BODY" -w '%{http_code}' "$@"; }

# 1-3 unauthenticated infra endpoints
chk "GET /health"  200 "$(req $BASE/health)"
chk "GET /ready"   200 "$(req $BASE/ready)"
chk "GET /metrics" 200 "$(req $BASE/metrics)"

# 4-5 auth failures
chk "list without key -> 401" 401 "$(req $BASE/api/v1/submissions)"
chk "list wrong key -> 401"   401 "$(req -H "X-Api-Key: nope" $BASE/api/v1/submissions)"

REVIEW=$(cat <<EOF
{
  "skill":"multi-llm-review","machine_name":"e2e-test","coordinator_model":"claude-fable-5",
  "run_id":"$RUN-review","prompt":"e2e test prompt",
  "reviewers":[
    {"slot":"gpt56","model":"openai-codex/gpt-5.6-sol","status":"completed","duration_s":354,"bytes":2392,
     "output":"# review\nfindings...","score":5,"valid":2,"invalid":0,"note":"e2e note"},
    {"slot":"kimi","model":"telnyx/moonshotai/Kimi-K3","status":"timeout","duration_s":900,"bytes":0}
  ]}
EOF
)

# 6 create review
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$REVIEW" $BASE/api/v1/reviews)
rid=$(jq -r .id "$BODY")
chk "POST review -> 201" 201 "$s" "$(jq -r 'if .submission_type=="multi-llm-review" and (.payload.reviewers|length)==2 then 1 else 0 end' "$BODY")"

# 7 idempotent replay (identical content) -> 200, same id
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$REVIEW" $BASE/api/v1/reviews)
chk "replay review -> 200 same id" 200 "$s" "$(jq -r --argjson rid "$rid" 'if .id==$rid then 1 else 0 end' "$BODY")"

# 8 replay with different content -> 409 replay_mismatch, names the existing id
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.reviewers[0].score=3' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "replay changed content -> 409" 409 "$s" \
  "$(jq -r --argjson rid "$rid" 'if .error=="replay_mismatch" and (.message|test("\($rid)")) then 1 else 0 end' "$BODY")"

# 9 validation: bad score
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg r "$RUN-badscore" '.run_id=$r | .reviewers[0].score=7' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review score=7 -> 400" 400 "$s" "$(jq -r 'if (.message|test("score")) then 1 else 0 end' "$BODY")"

# 10 validation: missing machine_name
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg r "$RUN-nomach" 'del(.machine_name) | .run_id=$r' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review no machine_name -> 400" 400 "$s"

# 11 validation: field length cap -> 400 naming the field
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg r "$(printf 'x%.0s' $(seq 1 201))" '.run_id=$r' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "run_id over 200 bytes -> 400" 400 "$s" "$(jq -r 'if (.message|test("run_id")) then 1 else 0 end' "$BODY")"

FRICTION=$(cat <<EOF
{
  "machine_name":"e2e-test","coordinator_model":"claude-fable-5","category":"documentation",
  "summary":"e2e friction $RUN","suggested_fix":"e2e fix","project":"agent-feedback","harness":"claude-code"}
EOF
)

# 12 create friction (X-Api-Key variant)
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d "$FRICTION" $BASE/api/v1/frictions)
fid=$(jq -r .id "$BODY")
chk "POST friction -> 201" 201 "$s" "$(jq -r 'if .submission_type=="friction" and .payload.category=="documentation" and .run_id==null then 1 else 0 end' "$BODY")"

# 13 identical friction inside the dedupe window -> absorbed, 200, same id
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d "$FRICTION" $BASE/api/v1/frictions)
chk "duplicate friction -> 200 same id" 200 "$s" "$(jq -r --argjson fid "$fid" 'if .id==$fid then 1 else 0 end' "$BODY")"

# 14 different friction content -> new row, 201
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.summary+=" (variant)"' <<<"$FRICTION")" $BASE/api/v1/frictions)
fid2=$(jq -r .id "$BODY")
chk "different friction -> 201 new id" 201 "$s" "$(jq -r --argjson fid "$fid" 'if .id!=$fid then 1 else 0 end' "$BODY")"

# 14b friction with context -> stored verbatim in payload
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.summary+=" (ctx)" | .context={"cwd":"/tmp/e2e","git_branch":"main","occurred_at":"2026-07-30T10:00:00Z"}' <<<"$FRICTION")" \
  $BASE/api/v1/frictions)
fid3=$(jq -r .id "$BODY")
chk "friction context stored" 201 "$s" \
  "$(jq -r 'if .payload.context.cwd=="/tmp/e2e" and .payload.context.git_branch=="main" then 1 else 0 end' "$BODY")"

# 14c same semantic content, different context -> still absorbed (hash excludes context)
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.summary+=" (ctx)" | .context={"cwd":"/elsewhere","occurred_at":"2026-07-30T11:11:11Z"}' <<<"$FRICTION")" \
  $BASE/api/v1/frictions)
chk "dedupe ignores context differences" 200 "$s" "$(jq -r --argjson fid3 "$fid3" 'if .id==$fid3 then 1 else 0 end' "$BODY")"

# 14d oversized context value -> 400 naming context
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg v "$(printf 'x%.0s' $(seq 1 2001))" '.summary+=" (bigctx)" | .context={"cwd":$v}' <<<"$FRICTION")" \
  $BASE/api/v1/frictions)
chk "context value over 2000 bytes -> 400" 400 "$s" "$(jq -r 'if (.message|test("context")) then 1 else 0 end' "$BODY")"

# 15 list filter type=friction: contains it, no payload, friction fields surfaced
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?type=friction&machine=e2e-test")
chk "list friction: fields surfaced, payload omitted" 200 "$s" \
  "$(jq -r --argjson fid "$fid" 'if ([.submissions[].id]|index($fid)) != null
      and ([.submissions[]|has("payload")]|any|not)
      and ((.submissions[]|select(.id==$fid)|.category)=="documentation")
      and ((.submissions[]|select(.id==$fid)|.summary)|test("e2e friction")) then 1 else 0 end' "$BODY")"

# 16 list filter type+machine for review
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?type=multi-llm-review&machine=e2e-test&limit=5")
chk "list type+machine contains review" 200 "$s" "$(jq -r --argjson rid "$rid" 'if ([.submissions[].id]|index($rid)) != null then 1 else 0 end' "$BODY")"

# 17 list bad since -> 400 ; 18 list bad processed -> 400
chk "list bad since -> 400" 400 "$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?since=notatime")"
chk "list bad processed -> 400" 400 "$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?processed=maybe")"

# 19 get by id -> full payload
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$rid")
chk "get review by id, full payload" 200 "$s" "$(jq -r 'if (.payload.reviewers|length)==2 and .payload.prompt=="e2e test prompt" then 1 else 0 end' "$BODY")"

# 20 get missing -> 404 ; 21 get non-numeric -> 400
chk "get 999999999 -> 404" 404 "$(req -H "X-Api-Key: $KEY" $BASE/api/v1/submissions/999999999)"
chk "get abc -> 400"       400 "$(req -H "X-Api-Key: $KEY" $BASE/api/v1/submissions/abc)"

# 22 review with unknown field -> 400
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg r "$RUN-unknownfield" '.run_id=$r | .bogus_field=1' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review unknown field -> 400" 400 "$s"

# 23 review with reserved skill "friction" -> 400
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg r "$RUN-reservedskill" '.run_id=$r | .skill="friction"' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review skill=friction -> 400" 400 "$s"

# 24 mark processed (one existing, one bogus) -> classified outcomes
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$rid,$fid,999999999]}" $BASE/api/v1/submissions/processed)
chk "mark processed -> updated + not_found" 200 "$s" \
  "$(jq -r --argjson rid "$rid" --argjson fid "$fid" \
    'if .processed==true and (.updated|index($rid))!=null and (.updated|index($fid))!=null and (.not_found|index(999999999))!=null then 1 else 0 end' "$BODY")"

# 25 re-mark -> unchanged (idempotent)
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$rid,$fid]}" $BASE/api/v1/submissions/processed)
chk "re-mark processed -> unchanged" 200 "$s" \
  "$(jq -r --argjson rid "$rid" 'if (.updated|length)==0 and (.unchanged|index($rid))!=null then 1 else 0 end' "$BODY")"

# 26 processed filter: marked rows excluded from processed=false, present in processed=true
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?machine=e2e-test&processed=false&limit=500")
ok1=$(jq -r --argjson rid "$rid" 'if ([.submissions[].id]|index($rid))==null then 1 else 0 end' "$BODY")
s2=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?machine=e2e-test&processed=true&limit=500")
ok2=$(jq -r --argjson rid "$rid" 'if ([.submissions[].id]|index($rid))!=null and ((.submissions[]|select(.id==$rid)|.processed_at)!=null) then 1 else 0 end' "$BODY")
chk "processed filter excludes/includes" 200 "$s2" "$((ok1 * ok2))"

# 27 unmark -> updated again; get by id shows no processed_at
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$rid],\"processed\":false}" $BASE/api/v1/submissions/processed)
chk "unmark processed -> updated" 200 "$s" "$(jq -r --argjson rid "$rid" 'if .processed==false and (.updated|index($rid))!=null then 1 else 0 end' "$BODY")"
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$rid")
chk "unmarked row has no processed_at" 200 "$s" "$(jq -r 'if has("processed_at")|not then 1 else 0 end' "$BODY")"

# 28 processed with empty ids -> 400
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"ids":[]}' $BASE/api/v1/submissions/processed)
chk "processed empty ids -> 400" 400 "$s"

# 29 oversized body -> 413
{
  printf '{"skill":"multi-llm-review","machine_name":"e2e-test","coordinator_model":"c","run_id":"%s","prompt":"' "$RUN-413"
  head -c 11534336 /dev/zero | tr '\0' 'a'
  printf '","reviewers":[{"slot":"s","model":"m","status":"completed"}]}'
} >"$BIG"
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' --data-binary @"$BIG" $BASE/api/v1/reviews)
chk "body over 10 MiB -> 413" 413 "$s"

echo; echo "e2e: $pass passed, $fail failed"
[ "$fail" = 0 ]
