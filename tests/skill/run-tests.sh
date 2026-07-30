#!/usr/bin/env bash
# Hermetic test suite for the agent-feedback skill scripts. No running stack
# needed: a Python mock server plays the service, HOME is a temp dir so the
# spool never touches the real cache.
#
# Lives OUTSIDE skills/agent-feedback/ on purpose: the skill directory is
# distributed as-is, and test tooling must never travel with it.
#
# Usage: bash tests/skill/run-tests.sh
# Requires: bash, curl, jq, python3.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TESTS_DIR/../../skills/agent-feedback/scripts"

WORK=$(mktemp -d)
STATE="$WORK/state"
mkdir -p "$STATE"
export HOME="$WORK/home"
mkdir -p "$HOME"
SPOOL="$HOME/.cache/agent-feedback/spool"

python3 "$TESTS_DIR/mock_server.py" "$STATE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

for i in $(seq 1 50); do [ -s "$STATE/port" ] && break; sleep 0.1; done
[ -s "$STATE/port" ] || { echo "FATAL mock server did not start" >&2; exit 1; }
PORT=$(cat "$STATE/port")

export AGENT_FEEDBACK_URL="http://127.0.0.1:$PORT"
export AGENT_FEEDBACK_API_KEY="testkey"
export AGENT_FEEDBACK_MACHINE="testmach"
# Scrub harness identity the suite may have inherited (running under Claude
# Code or any other harness leaks these); individual tests set them explicitly.
unset REVIEW_CALLER_MODEL AI_AGENT CLAUDE_EFFORT CLAUDE_CODE_SESSION_ID \
      AGENT_FEEDBACK_SESSION_ID AGENT_FEEDBACK_HARNESS AGENT_FEEDBACK_MODEL \
      CLAUDECODE OPENCODE OPENCODE_MODEL OPENCODE_API_KEY PI_CODING_AGENT \
      PI_CODING_AGENT_DIR OMP_PROFILE PI_MODEL CODEX_SANDBOX CODEX_API_KEY \
      2>/dev/null || true
# Run everything from a non-git temp cwd so auto-detected context (cwd, git)
# is deterministic regardless of where the suite was invoked.
cd "$WORK"

pass=0; fail=0
chk() { # chk <desc> <ok 0|1>
  if [ "$2" = 1 ]; then pass=$((pass+1)); echo "PASS  $1";
  else fail=$((fail+1)); echo "FAIL  $1"; fi
}
set_mode() { printf '%s' "$1" >"$STATE/mode"; }
log_len() { wc -l <"$STATE/requests.jsonl" 2>/dev/null | tr -d ' ' || echo 0; }
last_req() { tail -n1 "$STATE/requests.jsonl"; }
outcome() { tail -n1 <<<"$1"; }

# ── submit-friction.sh ───────────────────────────────────────────────────────

# 1. happy path: 201 -> submitted, correct payload + auth
set_mode created
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "t1 summary" \
  --details "t1 details" --model claude-fable-5 --project proj1 --harness claude-code 2>/dev/null)
rc=$?
o=$(outcome "$out")
req=$(last_req)
chk "friction 201 -> submitted id, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="submitted" and $j.id==101 and $rc==0 then 1 else 0 end')"
chk "friction payload fields + auth" "$(jq -r 'if .auth and .body.machine_name=="testmach"
  and .body.coordinator_model=="claude-fable-5" and .body.category=="tooling"
  and .body.summary=="t1 summary" and .body.details=="t1 details"
  and .body.project=="proj1" and .body.harness=="claude-code" then 1 else 0 end' <<<"$req")"

# 2. --stdin: prose with quotes/backticks/hyphens survives untouched
prose='The bash tool runs `hypa` and exits 127 — while "hypa_shell" works.'
out=$(jq -n --arg d "$prose" \
  '{category:"tooling",summary:"stdin summary",details:$d,harness:"pi"}' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model claude-fable-5 2>/dev/null)
req=$(last_req)
chk "friction --stdin prose intact" "$(jq -r --arg d "$prose" \
  'if .body.details==$d and .body.summary=="stdin summary" and .body.harness=="pi" then 1 else 0 end' <<<"$req")"

# 3. --stdin unknown key -> rejected locally, nothing sent
before=$(log_len)
out=$(bash "$SCRIPTS/submit-friction.sh" --stdin 2>/dev/null <<'JSON'
{"category":"tooling","summary":"x","bogus":"y"}
JSON
)
rc=$?
o=$(outcome "$out")
chk "friction --stdin unknown key -> local reject, no request" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and $rc==1 and $b==$a then 1 else 0 end')"

# 4. --dry-run: prints payload + valid, nothing sent
before=$(log_len)
out=$(bash "$SCRIPTS/submit-friction.sh" --category config --summary "dry" --model m --dry-run 2>/dev/null)
rc=$?
chk "friction --dry-run -> valid, no request" "$(jq -n --arg last "$(outcome "$out")" \
  --arg payload "$(sed '$d' <<<"$out")" --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($last|fromjson) as $j | ($payload|fromjson) as $p |
   if $j.status=="valid" and $p.category=="config" and $rc==0 and $b==$a then 1 else 0 end')"

# 5. duplicate absorption: 200 -> duplicate, exit 0
set_mode duplicate
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "dup" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "friction 200 -> duplicate id, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="duplicate" and $j.id==55 and $rc==0 then 1 else 0 end')"

# 6. 400 -> rejected, exit 1, not spooled
set_mode reject400
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "bad" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
n_spool=$(find "$SPOOL" -name 'friction-*' 2>/dev/null | wc -l | tr -d ' ')
chk "friction 400 -> rejected, exit 1, no spool" "$(jq -n --arg o "$o" --argjson rc "$rc" --argjson n "$n_spool" \
  '($o|fromjson) as $j | if $j.status=="rejected" and $j.http_status==400 and $rc==1 and $n==0 then 1 else 0 end')"

# 7. connect failure -> spooled, exit 0; next call flushes it
set_mode created
saved_url="$AGENT_FEEDBACK_URL"
export AGENT_FEEDBACK_URL="http://127.0.0.1:1"
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "offline friction" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
n_spool=$(find "$SPOOL" -name 'friction-*.json' 2>/dev/null | wc -l | tr -d ' ')
chk "friction connect fail -> spooled, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" --argjson n "$n_spool" \
  '($o|fromjson) as $j | if $j.status=="spooled" and $rc==0 and $n==1 then 1 else 0 end')"

export AGENT_FEEDBACK_URL="$saved_url"
before=$(log_len)
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "online again" --model m 2>/dev/null)
n_spool=$(find "$SPOOL" \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
sent=$(( $(log_len) - before ))
flushed_ok=$(jq -r 'select(.body.summary=="offline friction") | 1' "$STATE/requests.jsonl" | head -n1)
chk "next call flushes spooled friction" "$(jq -n --argjson n "$n_spool" --argjson sent "$sent" \
  --argjson f "${flushed_ok:-0}" 'if $n==0 and $sent==2 and $f==1 then 1 else 0 end')"

# 8. 500 -> spooled (dedupe-safe retry), then flushed on next call
set_mode error500
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "s500" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "friction 500 -> spooled, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="spooled" and ($j.reason|startswith("server_error")) and $rc==0 then 1 else 0 end')"
set_mode created
bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "post-500 flush" --model m >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
chk "500-spooled friction flushed after recovery" "$([ "$n_spool" = 0 ] && echo 1 || echo 0)"

# 8a. auto-context outside a git repo: base keys present, git keys absent
set_mode created
bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "ctx nogit" --model m >/dev/null 2>&1
req=$(last_req)
chk "context auto-collected (non-git): base keys, no git keys" "$(jq -r --arg cwd "$PWD" '
  if (.body.context.occurred_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
  and .body.context.cwd==$cwd
  and (.body.context.os | length > 0) and (.body.context.arch | length > 0)
  and .body.context.client_version=="2.1"
  and (.body.context | has("git_commit") | not)
  and (.body.context | has("session_id") | not)
  then 1 else 0 end' <<<"$req")"

# 8b. git context: repo/branch/commit/dirty detected, remote token stripped,
#     project auto-derived from the remote
GITDIR="$WORK/myrepo"
mkdir -p "$GITDIR"
git -C "$GITDIR" -c init.defaultBranch=main init -q
git -C "$GITDIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$GITDIR" remote add origin "https://user:tok123@example.com/org/myrepo.git"
echo dirty >"$GITDIR/f"
(cd "$GITDIR" && bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "ctx git" --model m >/dev/null 2>&1)
req=$(last_req)
chk "context git fields + sanitized remote + auto project" "$(jq -r --arg root "$GITDIR" '
  if .body.project=="myrepo"
  and .body.context.git_remote=="https://example.com/org/myrepo.git"
  and .body.context.git_branch=="main"
  and (.body.context.git_commit | length >= 7)
  and .body.context.git_dirty=="true"
  and .body.context.repo_root==$root
  then 1 else 0 end' <<<"$req")"

# 8c. session/agent/effort picked up from the environment when present
AGENT_FEEDBACK_SESSION_ID="sess-123" AI_AGENT="test-harness_9" CLAUDE_EFFORT="high" \
  bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "ctx env" --model m >/dev/null 2>&1
req=$(last_req)
chk "context session/agent/effort from env" "$(jq -r '
  if .body.context.session_id=="sess-123" and .body.context.agent=="test-harness_9"
  and .body.context.effort=="high" then 1 else 0 end' <<<"$req")"

# 8d. --stdin "context" object merges over the auto-collected one
printf '%s' '{"category":"tooling","summary":"ctx merge","context":{"custom_key":"custom_val","cwd":"/overridden"}}' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model m >/dev/null 2>&1
req=$(last_req)
chk "context stdin merge (agent keys win)" "$(jq -r '
  if .body.context.custom_key=="custom_val" and .body.context.cwd=="/overridden"
  and (.body.context | has("occurred_at")) then 1 else 0 end' <<<"$req")"

# 8e. harness detection matrix — markers verified from each harness's
#     installed code; nested launches attribute to the INNER harness; profile
#     API-key leaks must not false-positive.
detect_case() { # <desc> <expected_harness> [ENV=val ...]
  local desc="$1" want="$2"; shift 2
  set_mode created
  env "$@" bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "detect $want $RANDOM" --model m >/dev/null 2>&1
  local got
  got=$(last_req | jq -r '.body.harness // "none"')
  chk "$desc" "$([ "$got" = "$want" ] && echo 1 || echo 0)"
}
detect_case "detect claude-code (CLAUDECODE)" claude-code CLAUDECODE=1
detect_case "detect opencode (OPENCODE)" opencode OPENCODE=1
detect_case "detect pi (PI_CODING_AGENT)" pi PI_CODING_AGENT=true
detect_case "detect omp (PI_CODING_AGENT_DIR)" omp PI_CODING_AGENT_DIR=/x
detect_case "detect omp via OMP_PROFILE" omp OMP_PROFILE=default
detect_case "omp beats pi (fork precedence)" omp PI_CODING_AGENT=true PI_CODING_AGENT_DIR=/x
detect_case "detect codex (CODEX_SANDBOX)" codex CODEX_SANDBOX=seatbelt
detect_case "nested pi inside claude-code -> pi" pi CLAUDECODE=1 PI_CODING_AGENT=true
detect_case "nested opencode inside claude-code -> opencode" opencode CLAUDECODE=1 OPENCODE=1
detect_case "profile API-key leaks -> unknown" unknown OPENCODE_API_KEY=k CODEX_API_KEY=k
detect_case "AGENT_FEEDBACK_HARNESS override wins" my-harness AGENT_FEEDBACK_HARNESS=my-harness CLAUDECODE=1
detect_case "legacy PI_MODEL fallback -> pi" pi PI_MODEL=some/model

# 8f. AGENT_FEEDBACK_MODEL env fallback when --model is not passed
set_mode created
env AGENT_FEEDBACK_MODEL=model-from-env bash "$SCRIPTS/submit-friction.sh" \
  --category tooling --summary "model from env" >/dev/null 2>&1
req=$(last_req)
chk "AGENT_FEEDBACK_MODEL fallback for coordinator_model" \
  "$(jq -r 'if .body.coordinator_model=="model-from-env" then 1 else 0 end' <<<"$req")"

# ── submit-review.sh ─────────────────────────────────────────────────────────

# fixture run dir
RUN_BASE="$HOME/.cache/multi-llm-review"
RUN_DIR="$RUN_BASE/20260730-101010-4242"
mkdir -p "$RUN_DIR"
cat >"$RUN_DIR/meta.json" <<'JSON'
{"machine":"testmach","skill":"multi-llm-review","run_ts":"20260730-101010",
 "caller":"claude-fable-5",
 "slots":{"gpt56":{"label":"GPT-5.6-Sol"},"kimi":{"label":"Kimi-K3"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\n' >"$RUN_DIR/summary.tsv"
printf 'gpt56\topenai-codex/gpt-5.6-sol\tcompleted\t354\t2392\n' >>"$RUN_DIR/summary.tsv"
printf 'kimi\ttelnyx/moonshotai/Kimi-K3\ttimeout\t\t\n' >>"$RUN_DIR/summary.tsv"
printf '20260730-101010\tx\tGPT-5.6-Sol\t5\t2\t0\tsolid\n' >"$RUN_BASE/scorecards.tsv"

# 9. direct submit: run_id join, scores joined by label, empty duration omitted
set_mode created
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null)
rc=$?
o=$(outcome "$out")
req=$(last_req)
chk "review submit -> submitted, exit 0, .submitted written" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  --arg marker "$(cat "$RUN_DIR/.submitted" 2>/dev/null)" \
  '($o|fromjson) as $j | if $j.status=="submitted" and $j.id==102 and $rc==0 and $marker=="102" then 1 else 0 end')"
chk "review payload: run_id, label-joined score, empty duration omitted" "$(jq -r '
  if .body.run_id=="testmach-20260730-101010-4242"
  and .body.coordinator_model=="claude-fable-5"
  and (.body.reviewers[0].score==5 and .body.reviewers[0].valid==2 and .body.reviewers[0].note=="solid")
  and (.body.reviewers[1] | has("duration_s") | not)
  and (.body.reviewers[0] | has("output") | not)
  then 1 else 0 end' <<<"$req")"

# 10. 409 mismatch -> mismatch outcome, exit 1, no .submitted
rm -f "$RUN_DIR/.submitted"
set_mode mismatch409
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "review 409 -> mismatch, exit 1, not marked" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  --argjson marked "$([ -f "$RUN_DIR/.submitted" ] && echo 1 || echo 0)" \
  '($o|fromjson) as $j | if $j.status=="mismatch" and ($j.message|test("submission 7")) and $rc==1 and $marked==0 then 1 else 0 end')"

# 11. collision (200 with foreign record) -> collision, exit 1
set_mode collision200
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "review foreign 200 -> collision, exit 1" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="collision" and $rc==1 then 1 else 0 end')"

# 12. identical replay (200, own record) -> duplicate, exit 0
set_mode replay200
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "review replay 200 -> duplicate, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="duplicate" and $j.id==102 and $rc==0 then 1 else 0 end')"

# ── query.sh ─────────────────────────────────────────────────────────────────

# 13. URL encoding: +02:00 offset must arrive percent-encoded. Hex case is
# curl-version-dependent (8.5 emits %3a, 8.21 emits %3A) — match either.
set_mode created
bash "$SCRIPTS/query.sh" --type friction --since "2026-07-01T00:00:00+02:00" >/dev/null 2>&1
req=$(last_req)
chk "query URL-encodes since (+02:00)" "$(jq -r 'if (.path|test("since=2026-07-01T00%3A00%3A00%2B02%3A00"; "i")) then 1 else 0 end' <<<"$req")"

# 14. read-only: a spooled payload is NOT flushed by query
saved_url="$AGENT_FEEDBACK_URL"
export AGENT_FEEDBACK_URL="http://127.0.0.1:1"
bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "stay spooled" --model m >/dev/null 2>&1
export AGENT_FEEDBACK_URL="$saved_url"
before=$(log_len)
bash "$SCRIPTS/query.sh" --type friction >/dev/null 2>&1
posts=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.method=="POST") | 1' | wc -l | tr -d ' ')
n_spool=$(find "$SPOOL" -name 'friction-*.json' 2>/dev/null | wc -l | tr -d ' ')
chk "query is read-only (spool untouched)" "$([ "$posts" = 0 ] && [ "$n_spool" = 1 ] && echo 1 || echo 0)"

# 15. query --flush does flush
bash "$SCRIPTS/query.sh" --type friction --flush >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
chk "query --flush flushes the spool" "$([ "$n_spool" = 0 ] && echo 1 || echo 0)"

# 16. get by id returns full record
out=$(bash "$SCRIPTS/query.sh" 43 2>/dev/null)
chk "query by id -> full payload" "$(jq -r 'if .id==43 and .payload.category=="tooling" then 1 else 0 end' <<<"$out")"

# ── process.sh ───────────────────────────────────────────────────────────────

# 17. list: unprocessed filter + compact TSV
out=$(bash "$SCRIPTS/process.sh" list 2>/dev/null)
req=$(last_req)
chk "process list -> processed=false, TSV row" "$(jq -n --arg o "$out" --arg path "$(jq -r .path <<<"$req")" \
  'if ($path|contains("processed=false")) and ($o|contains("43\tfriction\ttestmach\ttooling\tfixture summary")) then 1 else 0 end')"

# 18. done: batch mark, outcome echoed
out=$(bash "$SCRIPTS/process.sh" done 43 44 2>/dev/null)
rc=$?
o=$(outcome "$out")
req=$(last_req)
chk "process done -> ids marked" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  --arg body "$(jq -c .body <<<"$req")" \
  '($o|fromjson) as $j | ($body|fromjson) as $b |
   if $j.processed==true and $j.updated==[43,44] and $b.ids==[43,44] and $b.processed==true and $rc==0 then 1 else 0 end')"

# 19. undo -> processed:false
out=$(bash "$SCRIPTS/process.sh" undo 44 2>/dev/null)
req=$(last_req)
chk "process undo -> processed:false" "$(jq -r 'if .body.processed==false and .body.ids==[44] then 1 else 0 end' <<<"$req")"

# 20. non-numeric id dies
bash "$SCRIPTS/process.sh" done abc >/dev/null 2>&1
chk "process done abc -> exit 1" "$([ $? != 0 ] && echo 1 || echo 0)"

echo
echo "skill tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
