#!/usr/bin/env bash
# End-to-end test of agent-feedback. Run against a compose deployment; creates
# test submissions in Postgres — clean up via `docker compose down -v` or by
# deleting the rows afterward.
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
pass=0; fail=0
chk() { # chk <desc> <expected_status> <actual_status> [extra_ok]
  local desc=$1 want=$2 got=$3 extra=${4:-1}
  if [ "$want" = "$got" ] && [ "$extra" = 1 ]; then pass=$((pass+1)); echo "PASS  $desc";
  else fail=$((fail+1)); echo "FAIL  $desc (want $want got $got extra_ok=$extra)"; fi
}
req() { curl -sS -o /tmp/e2e-body.json -w '%{http_code}' "$@"; }

# 1-3 unauthenticated infra endpoints
chk "GET /health"  200 "$(req $BASE/health)"
chk "GET /ready"   200 "$(req $BASE/ready)"
chk "GET /metrics" 200 "$(req $BASE/metrics)"

# 4-5 auth failures
chk "list without key -> 401" 401 "$(req $BASE/api/v1/submissions)"
chk "list wrong key -> 401"   401 "$(req -H "X-Api-Key: nope" $BASE/api/v1/submissions)"

REVIEW='{
  "skill":"multi-llm-review","machine_name":"e2e-test","coordinator_model":"claude-fable-5",
  "run_id":"e2e-20260729-000000","prompt":"e2e test prompt",
  "reviewers":[
    {"slot":"gpt56","model":"openai-codex/gpt-5.6-sol","status":"completed","duration_s":354,"bytes":2392,
     "output":"# review\nfindings...","score":5,"valid":2,"invalid":0,"note":"e2e note"},
    {"slot":"kimi","model":"telnyx/moonshotai/Kimi-K3","status":"timeout","duration_s":900,"bytes":0}
  ]}'

# 6 create review
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$REVIEW" $BASE/api/v1/reviews)
rid=$(jq -r .id /tmp/e2e-body.json)
chk "POST review -> 201" 201 "$s" "$(jq -r 'if .submission_type=="multi-llm-review" and (.payload.reviewers|length)==2 then 1 else 0 end' /tmp/e2e-body.json)"

# 7 idempotent replay -> 200, same id
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$REVIEW" $BASE/api/v1/reviews)
chk "replay review -> 200 same id" 200 "$s" "$(jq -r --argjson rid "$rid" 'if .id==$rid then 1 else 0 end' /tmp/e2e-body.json)"

# 8 validation: bad score
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.run_id="e2e-badscore" | .reviewers[0].score=7' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review score=7 -> 400" 400 "$s" "$(jq -r 'if (.message|test("score")) then 1 else 0 end' /tmp/e2e-body.json)"

# 9 validation: missing machine_name
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq 'del(.machine_name) | .run_id="e2e-nomach"' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review no machine_name -> 400" 400 "$s"

# 10 create friction (X-Api-Key variant)
s=$(req -X POST -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d '{
  "machine_name":"e2e-test","coordinator_model":"claude-fable-5","category":"documentation",
  "summary":"e2e friction summary","suggested_fix":"e2e fix","project":"agent-feedback","harness":"claude-code"}' \
  $BASE/api/v1/frictions)
fid=$(jq -r .id /tmp/e2e-body.json)
chk "POST friction -> 201" 201 "$s" "$(jq -r 'if .submission_type=="friction" and .payload.category=="documentation" and .run_id==null then 1 else 0 end' /tmp/e2e-body.json)"

# 11 list filter type=friction, summary rows carry no payload
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?type=friction&machine=e2e-test")
chk "list type=friction contains it, payload omitted" 200 "$s" \
  "$(jq -r --argjson fid "$fid" 'if ([.submissions[].id]|index($fid)) != null and ([.submissions[]|has("payload")]|any|not) then 1 else 0 end' /tmp/e2e-body.json)"

# 12 list filter type+machine for review
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?type=multi-llm-review&machine=e2e-test&limit=5")
chk "list type+machine contains review" 200 "$s" "$(jq -r --argjson rid "$rid" 'if ([.submissions[].id]|index($rid)) != null then 1 else 0 end' /tmp/e2e-body.json)"

# 13 list bad since -> 400
chk "list bad since -> 400" 400 "$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions?since=notatime")"

# 14 get by id -> full payload
s=$(req -H "X-Api-Key: $KEY" "$BASE/api/v1/submissions/$rid")
chk "get review by id, full payload" 200 "$s" "$(jq -r 'if (.payload.reviewers|length)==2 and .payload.prompt=="e2e test prompt" then 1 else 0 end' /tmp/e2e-body.json)"

# 15 get missing -> 404 ; 16 get non-numeric -> 400
chk "get 999999 -> 404" 404 "$(req -H "X-Api-Key: $KEY" $BASE/api/v1/submissions/999999)"
chk "get abc -> 400"    400 "$(req -H "X-Api-Key: $KEY" $BASE/api/v1/submissions/abc)"

# 17 review with unknown field -> 400
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.run_id="e2e-unknownfield" | .bogus_field=1' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review unknown field -> 400" 400 "$s"

# 18 review with reserved skill "friction" -> 400
s=$(req -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq '.run_id="e2e-reservedskill" | .skill="friction"' <<<"$REVIEW")" $BASE/api/v1/reviews)
chk "review skill=friction -> 400" 400 "$s"

echo; echo "e2e: $pass passed, $fail failed"
[ "$fail" = 0 ]
