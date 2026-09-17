#!/usr/bin/env bash
# End-to-end test of agent-feedback. Run against a compose deployment; creates
# test submissions in the service's database — clean up via `docker compose
# down -v` or by deleting the rows afterward. Safe to rerun against a
# persistent database: every run uses unique run_ids and unique friction content.
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
  "skill":"review-panel","machine_name":"e2e-test","coordinator_model":"claude-fable-5",
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
chk "POST review -> 201" 201 "$s" "$(jq -r 'if .submission_type=="review-panel" and (.payload.reviewers|length)==2 then 1 else 0 end' "$BODY")"

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
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?type=review-panel&machine=e2e-test&limit=5")
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

# Valid review followed by another JSON value -> 400.
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq --arg r "$RUN-trailing" '.run_id=$r' <<<"$REVIEW"){}" $BASE/api/v1/reviews)
chk "review trailing JSON value -> 400" 400 "$s"

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

# Processed requests follow the same one-value JSON contract.
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$rid]} []" $BASE/api/v1/submissions/processed)
chk "processed trailing JSON value -> 400" 400 "$s"

# Complete body over 10 MiB only because of trailing whitespace -> 413.
{
  printf '%s' "$(jq --arg r "$RUN-413" '.run_id=$r' <<<"$REVIEW")"
  head -c 11534336 /dev/zero | tr '\0' ' '
} >"$BIG"
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' --data-binary @"$BIG" $BASE/api/v1/reviews)
chk "body over 10 MiB -> 413" 413 "$s"

# 29 record shape: family and payload_hash on every record, run_id absent for frictions
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$fid")
chk "record carries family + payload_hash" 200 "$s" \
  "$(jq -r 'if .family=="friction" and (.payload_hash|type)=="string" and (.payload_hash|length)==64 and .run_id==null then 1 else 0 end' "$BODY")"

EVENT=$(cat <<EOF
{"kind":"deploy","key":"$RUN-deploy","machine_name":"e2e-test","coordinator_model":"claude-fable-5",
 "payload":{"service":"agent-feedback","image":"sha-e2e","ok":true,"attempts":2}}
EOF
)

# 30 create event
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d "$EVENT" $BASE/api/v1/events)
eid=$(jq -r .id "$BODY")
chk "POST event -> 201" 201 "$s" \
  "$(jq -r 'if .family=="event" and .submission_type=="deploy" and .payload.attempts==2 and .run_id!=null then 1 else 0 end' "$BODY")"

# 31 identical event replay (different key order) -> 200 same id
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq -c '.payload={"ok":true,"attempts":2,"image":"sha-e2e","service":"agent-feedback"}' <<<"$EVENT")" $BASE/api/v1/events)
chk "replay event -> 200 same id" 200 "$s" "$(jq -r --argjson eid "$eid" 'if .id==$eid then 1 else 0 end' "$BODY")"

# 32 different event content under the same key -> 409
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq -c '.payload.attempts=3' <<<"$EVENT")" $BASE/api/v1/events)
chk "event changed content -> 409" 409 "$s" "$(jq -r 'if .error=="replay_mismatch" then 1 else 0 end' "$BODY")"

# 33 reserved event kind -> 400
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq -c --arg k "$RUN-reserved" '.kind="friction" | .key=$k' <<<"$EVENT")" $BASE/api/v1/events)
chk "event kind=friction -> 400" 400 "$s"

# 34 event payload must be an object
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "$(jq -c --arg k "$RUN-badpayload" '.key=$k | .payload=[1,2]' <<<"$EVENT")" $BASE/api/v1/events)
chk "event payload array -> 400" 400 "$s"

# 35 list family filter + counters
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?family=event&machine=e2e-test&limit=1")
chk "list family=event: counters present" 200 "$s" \
  "$(jq -r 'if (.total|type)=="number" and (.has_more|type)=="boolean" and (.limit==1)
      and ([.submissions[].family]|unique)==["event"] then 1 else 0 end' "$BODY")"

# 36 before_id paging over this run's machine
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?machine=e2e-test&limit=1")
first=$(jq -r '.submissions[0].id' "$BODY")
nb=$(jq -r '.next_before_id' "$BODY")
ok1=$(jq -r 'if .has_more==true and .next_before_id!=null and .next_before_id==.submissions[-1].id then 1 else 0 end' "$BODY")
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?machine=e2e-test&limit=1&before_id=$nb")
ok2=$(jq -r --argjson first "$first" 'if (.submissions[0].id < $first) then 1 else 0 end' "$BODY")
chk "before_id paging walks older rows" 200 "$s" "$((ok1 * ok2))"

# 37 offset and before_id are mutually exclusive
chk "offset+before_id -> 400" 400 "$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?offset=1&before_id=$nb")"

# 38 include=payload returns full records
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?machine=e2e-test&include=payload&limit=5")
chk "include=payload returns payloads" 200 "$s" \
  "$(jq -r 'if ([.submissions[]|has("payload")]|all) then 1 else 0 end' "$BODY")"

# 39 processed with a resolution -> updated, resolution echoed and stored
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$fid2],\"resolution\":\"fixed in agent-feedback@e2e\"}" $BASE/api/v1/submissions/processed)
chk "mark with resolution -> updated" 200 "$s" \
  "$(jq -r --argjson fid2 "$fid2" 'if (.updated|index($fid2))!=null and .resolution=="fixed in agent-feedback@e2e" then 1 else 0 end' "$BODY")"
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$fid2")
stamp=$(jq -r .processed_at "$BODY")
chk "resolution stored on the record" 200 "$s" \
  "$(jq -r 'if .resolution=="fixed in agent-feedback@e2e" and .processed_at!=null then 1 else 0 end' "$BODY")"

# 40 same resolution again -> unchanged
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$fid2],\"resolution\":\"fixed in agent-feedback@e2e\"}" $BASE/api/v1/submissions/processed)
chk "same resolution -> unchanged" 200 "$s" \
  "$(jq -r --argjson fid2 "$fid2" 'if (.unchanged|index($fid2))!=null and (.updated|length)==0 then 1 else 0 end' "$BODY")"

# 41 different resolution -> updated, processed_at preserved
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$fid2],\"resolution\":\"duplicate of $fid\"}" $BASE/api/v1/submissions/processed)
ok1=$(jq -r --argjson fid2 "$fid2" 'if (.updated|index($fid2))!=null then 1 else 0 end' "$BODY")
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$fid2")
ok2=$(jq -r --arg stamp "$stamp" 'if .resolution!="fixed in agent-feedback@e2e" and .processed_at==$stamp then 1 else 0 end' "$BODY")
chk "new resolution replaces, keeps processed_at" 200 "$s" "$((ok1 * ok2))"

# 42 blank resolution -> 400 ; resolution with processed=false -> 400
chk "blank resolution -> 400" 400 "$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$fid2],\"resolution\":\"   \"}" $BASE/api/v1/submissions/processed)"
chk "resolution with processed=false -> 400" 400 "$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$fid2],\"processed\":false,\"resolution\":\"x\"}" $BASE/api/v1/submissions/processed)"

# 43 unmarking clears processed_at and resolution
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"ids\":[$fid2],\"processed\":false}" $BASE/api/v1/submissions/processed)
ok1=$(jq -r --argjson fid2 "$fid2" 'if (.updated|index($fid2))!=null then 1 else 0 end' "$BODY")
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$fid2")
ok2=$(jq -r 'if (has("processed_at")|not) and (has("resolution")|not) then 1 else 0 end' "$BODY")
chk "unmark clears processed_at and resolution" 200 "$s" "$((ok1 * ok2))"

# 44 export: header, records, terminator whose count matches the record lines
EXPORT=$(mktemp)
s=$(curl -sS -o "$EXPORT" -w '%{http_code}' -H "X-Api-Key: $KEY" "$BASE/api/v1/export")
records=$(grep -c . "$EXPORT")
records=$((records - 2))
ok1=$(head -n1 "$EXPORT" | jq -r 'if .export_format==1 and (has("family")) and (has("since")) then 1 else 0 end')
ok2=$(tail -n1 "$EXPORT" | jq -r --argjson n "$records" 'if .export_complete==true and .count==$n and (.sha256|length)==64 then 1 else 0 end')
chk "export header + terminator with count" 200 "$s" "$((ok1 * ok2))"

# 45 export honours the family filter and marks itself partial
s=$(curl -sS -o "$EXPORT" -w '%{http_code}' -H "X-Api-Key: $KEY" "$BASE/api/v1/export?family=event")
ok1=$(head -n1 "$EXPORT" | jq -r 'if .family=="event" then 1 else 0 end')
ok2=$(sed -n '2,$p' "$EXPORT" | sed '$d' | jq -sr 'if ([.[].family]|unique)==["event"] then 1 else 0 end')
chk "export family filter" 200 "$s" "$((ok1 * ok2))"
rm -f "$EXPORT"

# 46 export bad filter -> 400
chk "export bad family -> 400" 400 "$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/export?family=nope")"

echo; echo "e2e: $pass passed, $fail failed"
[ "$fail" = 0 ]
