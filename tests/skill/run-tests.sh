#!/usr/bin/env bash
# Hermetic test suite for the agent-feedback skill scripts. No running stack
# needed: a Python mock server plays the service, HOME is a temp dir so the
# spool never touches the real cache.
#
# Lives OUTSIDE skills/agent-feedback/ on purpose: the skill directory is
# copied as-is into a harness, and test tooling must never travel with it.
#
# Portable to macOS and Linux: no GNU-only flags (no `touch -d`), and every
# path comparison uses the canonical (symlink-resolved) form, because macOS
# temp dirs are /var/... symlinks onto /private/var/....
#
# Usage: bash tests/skill/run-tests.sh
# Requires: bash, curl, jq, python3.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TESTS_DIR/../../skills/agent-feedback/scripts"

WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd -P)   # canonical: /private/var/... on macOS
STATE="$WORK/state"
mkdir -p "$STATE"
export HOME="$WORK/home"
mkdir -p "$HOME"
SPOOL="$HOME/.cache/agent-feedback/spool"

python3 "$TESTS_DIR/mock_server.py" "$STATE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

for _ in $(seq 1 50); do [ -s "$STATE/port" ] && break; sleep 0.1; done
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
      REVIEW_LOG_DIR AGENT_FEEDBACK_REVIEW_DIRS \
      2>/dev/null || true
# Run everything from a non-git temp cwd so auto-detected context (cwd, git)
# is deterministic regardless of where the suite was invoked.
cd "$WORK" || exit 1

pass=0; fail=0
chk() { # chk <desc> <ok 0|1>
  if [ "$2" = 1 ]; then pass=$((pass+1)); echo "PASS  $1";
  else fail=$((fail+1)); echo "FAIL  $1"; fi
}
set_mode() { printf '%s' "$1" >"$STATE/mode"; }
set_list_rows() { printf '%s' "$1" >"$STATE/list_rows"; }
# Cap the rows the mock returns per list page, so paging can be exercised with
# a handful of rows instead of hundreds. 0 removes the cap.
set_list_page_cap() {
  if [ "$1" = 0 ]; then rm -f "$STATE/list_page_cap"; else printf '%s' "$1" >"$STATE/list_page_cap"; fi
}
# Portable mtime setter: `touch -d '8 days ago'` is GNU-only.
set_mtime() { # <path> <seconds ago>
  python3 -c 'import os,sys,time; p=sys.argv[1]; t=time.time()-float(sys.argv[2]); os.utime(p,(t,t))' "$1" "$2"
}
realpath_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
log_len() {
  if [ -f "$STATE/requests.jsonl" ]; then
    wc -l <"$STATE/requests.jsonl" | tr -d ' '
  else
    echo 0
  fi
}
last_req() { tail -n1 "$STATE/requests.jsonl"; }
outcome() { tail -n1 <<<"$1"; }

set_list_rows 1

# A missing endpoint must fail locally, without sending to a default service.
before=$(log_len)
env -u AGENT_FEEDBACK_URL bash "$SCRIPTS/query.sh" --type friction >/dev/null 2>&1
rc=$?
chk "missing endpoint rejects locally without requests" \
  "$([ "$rc" -ne 0 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

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
prose="The bash tool runs \`hypa\` and exits 127 — while \"hypa_shell\" works."
out=$(jq -n --arg d "$prose" \
  '{category:"tooling",summary:"stdin summary",details:$d,harness:"pi"}' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model claude-fable-5 2>/dev/null)
req=$(last_req)
chk "friction --stdin prose intact" "$(jq -r --arg d "$prose" \
  'if .body.details==$d and .body.summary=="stdin summary" and .body.harness=="pi" then 1 else 0 end' <<<"$req")"

# 2a. Prose far past the OS per-argument limit (128 KiB) must survive: nothing
# large may travel through jq's argv.
python3 -c '
import json,sys
json.dump({"category":"tooling","summary":"big prose",
           "details":"D"*300000,"suggested_fix":"F"*150000}, sys.stdout)' >"$WORK/big.json"
out=$(bash "$SCRIPTS/submit-friction.sh" --stdin --model m <"$WORK/big.json" 2>/dev/null)
rc=$?
o=$(outcome "$out")
req=$(last_req)
chk "friction 300 KB details via --stdin is built and sent intact" "$(jq -r --argjson rc "$rc" '
  if $rc==0 and (.body.details|length)==300000 and (.body.suggested_fix|length)==150000
  then 1 else 0 end' <<<"$req")"

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

# 4a. --dry-run validates what the server validates: blank-after-trim is not a
# value, and identifier limits are enforced locally.
before=$(log_len)
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "   " --model m --dry-run 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "whitespace-only summary -> rejected by --dry-run, no request" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and ($j.message|test("summary")) and $rc==1 and $b==$a then 1 else 0 end')"
before=$(log_len)
out=$(bash "$SCRIPTS/submit-friction.sh" --category "$(python3 -c 'print("c"*201)')" \
  --summary "over-long category" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "over-long category -> rejected locally, no request" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and ($j.message|test("category")) and $rc==1 and $b==$a then 1 else 0 end')"

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

# 7-perm. The spool holds unsent prose and repo paths: user-only, both the
# directory (700) and every payload file (600).
mode_of() { python3 -c 'import os,stat,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
spool_file=$(find "$SPOOL" -name 'friction-*.json' | head -n1)
chk "spool directory is 0700 and spooled payloads are 0600" \
  "$([ "$(mode_of "$SPOOL")" = "0o700" ] && [ "$(mode_of "$spool_file")" = "0o600" ] && echo 1 || echo 0)"

export AGENT_FEEDBACK_URL="$saved_url"
before=$(log_len)
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "online again" --model m 2>/dev/null)
n_spool=$(find "$SPOOL" \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
sent=$(( $(log_len) - before ))
flushed_ok=$(jq -r 'select(.body.summary=="offline friction") | 1' "$STATE/requests.jsonl" | head -n1)
chk "next call flushes spooled friction" "$(jq -n --argjson n "$n_spool" --argjson sent "$sent" \
  --argjson f "${flushed_ok:-0}" 'if $n==0 and $sent==2 and $f==1 then 1 else 0 end')"

# 7a. A spool that cannot be written must NEVER report "spooled": the payload
# is echoed to stderr instead and the outcome says so. The directory is now
# narrowed to 700 on every spool, so a mode-555 directory this user owns is no
# longer unwritable — the durable way to make the spool unusable is a regular
# FILE sitting at its path, which makes mkdir fail.
rm -rf "$SPOOL"
: >"$SPOOL"
export AGENT_FEEDBACK_URL="http://127.0.0.1:1"
err="$WORK/spool-fail.err"
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "unspoolable" --model m 2>"$err")
rc=$?
o=$(outcome "$out")
export AGENT_FEEDBACK_URL="$saved_url"
echoed=$(grep -c 'unspoolable' "$err")
n_spool=$(find "$SPOOL" -name 'friction-*' 2>/dev/null | wc -l | tr -d ' ')
rm -f "$SPOOL"; mkdir -p "$SPOOL"
chk "unwritable spool -> failed outcome, exit 1, payload echoed to stderr" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson e "$echoed" --argjson n "$n_spool" \
  '($o|fromjson) as $j |
   if $j.status=="failed" and $j.reason=="spool_unwritable" and ($j.path|length>0)
      and $rc==1 and $e>=1 and $n==0 then 1 else 0 end')"

# 7a-perm. A spool left world-readable by an older client (or a loose umask) is
# narrowed on the next spool: the directory to 700, the payload written to 600.
rm -rf "$SPOOL"
mkdir -p "$SPOOL"
chmod 755 "$SPOOL"
printf 'legacy\n' >"$SPOOL/legacy-notes.txt"
chmod 644 "$SPOOL/legacy-notes.txt"
export AGENT_FEEDBACK_URL="http://127.0.0.1:1"
bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "widen-then-narrow" --model m >/dev/null 2>&1
export AGENT_FEEDBACK_URL="$saved_url"
spool_file=$(find "$SPOOL" -name 'friction-*.json' | head -n1)
chk "a pre-existing 0755 spool is narrowed to 0700 and the new payload is 0600" \
  "$([ "$(mode_of "$SPOOL")" = "0o700" ] && [ -n "$spool_file" ] \
    && [ "$(mode_of "$spool_file")" = "0o600" ] && echo 1 || echo 0)"
rm -f "$SPOOL"/* 2>/dev/null || true

# 7b. An unreadable spool directory must not swallow the outcome line.
chmod 000 "$SPOOL"
set_mode created
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "unreadable spool" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
chmod 755 "$SPOOL"
chk "unreadable spool still prints an outcome" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="submitted" and $rc==0 then 1 else 0 end')"

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

# 8a. Credentials stay in a protected curl header file, never curl's argv.
FAKE_BIN="$WORK/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CURL_ARGS"
out=""
prev=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [ "$arg" = "-o" ]; then
    next=$((i + 1)); out="${!next}"
  elif [ "$prev" = "-H" ] && [[ "$arg" == @* ]]; then
    header="${arg#@}"
    printf '%s' "$header" >"$CURL_HEADER_PATH"
    if stat -c '%a' "$header" >"$CURL_HEADER_MODE" 2>/dev/null; then :; else
      stat -f '%Lp' "$header" >"$CURL_HEADER_MODE"
    fi
    cat "$header" >"$CURL_HEADER_CONTENTS"
  fi
  prev="$arg"
done
printf '{"id":101,"family":"friction","submission_type":"friction","machine_name":"testmach"}' >"$out"
printf 201
SH
chmod +x "$FAKE_BIN/curl"
out=$(PATH="$FAKE_BIN:$PATH" CURL_ARGS="$WORK/curl.args" \
  CURL_HEADER_PATH="$WORK/curl.header.path" CURL_HEADER_MODE="$WORK/curl.header.mode" \
  CURL_HEADER_CONTENTS="$WORK/curl.header.contents" \
  bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "header file" --model m 2>/dev/null)
header_path=$(cat "$WORK/curl.header.path")
args=$(cat "$WORK/curl.args")
contents=$(cat "$WORK/curl.header.contents")
case "$args" in *testkey*) no_secret_argv=0 ;; *) no_secret_argv=1 ;; esac
chk "friction auth key stays out of curl argv and protected header is cleaned" \
  "$([ "$no_secret_argv" = 1 ] && [ "$(cat "$WORK/curl.header.mode")" = 600 ] \
    && [ "$contents" = "Authorization: Bearer testkey" ] && [ ! -e "$header_path" ] && echo 1 || echo 0)"

# 8b. Header injection in an environment key is rejected before any request.
before=$(log_len)
AGENT_FEEDBACK_API_KEY=$'testkey\r\nX-Injected: yes' \
  bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "bad key" --model m >/dev/null 2>&1
rc=$?
chk "CRLF API key rejects locally without requests" \
  "$([ "$rc" -ne 0 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

# 8c. A malformed friction success is spooled directly and remains retained
# when a later flush sees a different malformed success shape.
set_mode friction_bad_created
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "malformed receipt" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
n_spool=$(find "$SPOOL" -name 'friction-*.json' 2>/dev/null | wc -l | tr -d ' ')
chk "malformed friction 201 is spooled rather than acknowledged" "$(jq -n \
  --arg o "$o" --argjson rc "$rc" --argjson n "$n_spool" \
  '($o|fromjson) as $j | if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0 and $n==1 then 1 else 0 end')"
set_mode friction_wrong_duplicate
bash "$SCRIPTS/query.sh" --type friction --flush >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
chk "flush retains friction when 200 has wrong submission type" "$([ "$n_spool" = 1 ] && echo 1 || echo 0)"
set_mode created
bash "$SCRIPTS/query.sh" --type friction --flush >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
chk "well-formed later friction receipt clears retained spool" "$([ "$n_spool" = 0 ] && echo 1 || echo 0)"

# 8d. Rejected reports are visible until their bounded retention expires (30d).
mkdir -p "$SPOOL"
printf '{"summary":"expired rejected"}' >"$SPOOL/friction-expired.rejected"
set_mtime "$SPOOL/friction-expired.rejected" $((31 * 86400))
out=$(bash "$SCRIPTS/query.sh" --type friction --flush 2>&1)
expired_gone=$([ ! -e "$SPOOL/friction-expired.rejected" ] && echo 1 || echo 0)
printf '{"summary":"fresh rejected"}' >"$SPOOL/friction-fresh.rejected"
set_mtime "$SPOOL/friction-fresh.rejected" $((20 * 86400))
out=$(bash "$SCRIPTS/query.sh" --type friction --flush 2>&1)
retained_20d=$([ -e "$SPOOL/friction-fresh.rejected" ] && echo 1 || echo 0)
case "$out" in *"spool backlog: 1 rejected submission"*) rejected_visible=1 ;; *) rejected_visible=0 ;; esac
chk "rejected spool retention is 30d with a visible backlog warning" \
  "$([ "$expired_gone" = 1 ] && [ "$retained_20d" = 1 ] && [ "$rejected_visible" = 1 ] && echo 1 || echo 0)"
rm -f "$SPOOL/friction-fresh.rejected"

# 8e. auto-context outside a git repo: base keys present, git keys absent
set_mode created
bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "ctx nogit" --model m >/dev/null 2>&1
req=$(last_req)
chk "context auto-collected (non-git): base keys, no git keys" "$(jq -r --arg cwd "$(realpath_of "$PWD")" '
  if (.body.context.occurred_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
  and .body.context.cwd==$cwd
  and (.body.context.os | length > 0) and (.body.context.arch | length > 0)
  and .body.context.client_version=="3.0"
  and (.body.context | has("git_commit") | not)
  and (.body.context | has("session_id") | not)
  then 1 else 0 end' <<<"$req")"

# 8f. git context: repo/branch/commit/dirty detected, remote token stripped,
#     project auto-derived from the remote
GITDIR="$WORK/myrepo"
mkdir -p "$GITDIR"
GITDIR=$(realpath_of "$GITDIR")
git -C "$GITDIR" -c init.defaultBranch=main init -q
git -C "$GITDIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$GITDIR" remote add origin "https://user:tok123@example.com/org/myrepo.git?access_token=leak#fragment"
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

# 8g. SCP-style usernames are also collection-only metadata, while caller
# context remains untouched by sanitization.
git -C "$GITDIR" remote set-url origin "gituser@example.com:org/scprepo.git"
(cd "$GITDIR" && bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "ctx scp" --model m >/dev/null 2>&1)
req=$(last_req)
chk "context strips SCP remote username" "$(jq -r '
  if .body.project=="scprepo" and .body.context.git_remote=="example.com:org/scprepo.git" then 1 else 0 end' <<<"$req")"
printf '%s' '{"category":"tooling","summary":"explicit remote","context":{"git_remote":"https://caller:keep@example.com/p.git?keep#keep"}}' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model m >/dev/null 2>&1
req=$(last_req)
chk "explicit context remote is not rewritten" "$(jq -r '
  if .body.context.git_remote=="https://caller:keep@example.com/p.git?keep#keep" then 1 else 0 end' <<<"$req")"

# 8h. session/agent/effort picked up from the environment when present
AGENT_FEEDBACK_SESSION_ID="sess-123" AI_AGENT="test-harness_9" CLAUDE_EFFORT="high" \
  bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "ctx env" --model m >/dev/null 2>&1
req=$(last_req)
chk "context session/agent/effort from env" "$(jq -r '
  if .body.context.session_id=="sess-123" and .body.context.agent=="test-harness_9"
  and .body.context.effort=="high" then 1 else 0 end' <<<"$req")"

# 8i. --stdin "context" object merges over the auto-collected one
printf '%s' '{"category":"tooling","summary":"ctx merge","context":{"custom_key":"custom_val","cwd":"/overridden"}}' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model m >/dev/null 2>&1
req=$(last_req)
chk "context stdin merge (agent keys win)" "$(jq -r '
  if .body.context.custom_key=="custom_val" and .body.context.cwd=="/overridden"
  and (.body.context | has("occurred_at")) then 1 else 0 end' <<<"$req")"

# 8j. context caps are enforced locally (the server rejects beyond them)
before=$(log_len)
python3 -c '
import json,sys
json.dump({"category":"tooling","summary":"too much context",
           "context":{("k%d"%i):"v" for i in range(40)}}, sys.stdout)' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model m >"$WORK/ctxcap.out" 2>/dev/null
rc=$?
o=$(outcome "$(cat "$WORK/ctxcap.out")")
chk "over-cap context -> rejected locally, no request" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and ($j.message|test("context")) and $rc==1 and $b==$a then 1 else 0 end')"

# 8k. harness detection matrix — markers verified from each harness's
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

# 8l. AGENT_FEEDBACK_MODEL env fallback when --model is not passed
set_mode created
env AGENT_FEEDBACK_MODEL=model-from-env bash "$SCRIPTS/submit-friction.sh" \
  --category tooling --summary "model from env" >/dev/null 2>&1
req=$(last_req)
chk "AGENT_FEEDBACK_MODEL fallback for coordinator_model" \
  "$(jq -r 'if .body.coordinator_model=="model-from-env" then 1 else 0 end' <<<"$req")"

# ── submit-event.sh ──────────────────────────────────────────────────────────

set_mode created
# 20. happy path: 201 -> submitted, payload sent verbatim, key defaulted
out=$(printf '%s' '{"service":"agent-feedback","ok":true,"n":3}' \
  | bash "$SCRIPTS/submit-event.sh" --kind deploy --stdin --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
req=$(last_req)
chk "event 201 -> submitted, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="submitted" and ($j.id|type)=="number" and $rc==0 then 1 else 0 end')"
chk "event payload verbatim + defaulted key + POST /api/v1/events" "$(jq -r '
  if .path=="/api/v1/events" and .body.kind=="deploy" and .body.payload.n==3
  and .body.payload.ok==true and .body.machine_name=="testmach"
  and (.body.key|test("^testmach-[0-9]{8}-[0-9]{6}-[0-9]+$")) then 1 else 0 end' <<<"$req")"

# 21. identical replay under the same (kind,key) -> duplicate
printf '%s' '{"a":1}' >"$WORK/event.json"
bash "$SCRIPTS/submit-event.sh" --kind deploy --key dup-key --payload-file "$WORK/event.json" --model m >/dev/null 2>&1
out=$(bash "$SCRIPTS/submit-event.sh" --kind deploy --key dup-key --payload-file "$WORK/event.json" --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "event identical replay -> duplicate, exit 0" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="duplicate" and $j.key=="dup-key" and $rc==0 then 1 else 0 end')"

# 22. different content under the same key -> 409 mismatch, exit 1
out=$(printf '%s' '{"a":2}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key dup-key --stdin --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "event changed content -> mismatch, exit 1" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="mismatch" and $j.key=="dup-key" and $rc==1 then 1 else 0 end')"

# 23. kind "friction" is reserved, and a non-object payload is refused locally
before=$(log_len)
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind friction --stdin --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
reserved_ok=$(jq -n --arg o "$o" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("reserved")) and $rc==1 then 1 else 0 end')
out=$(printf '%s' '[1,2]' | bash "$SCRIPTS/submit-event.sh" --kind deploy --stdin --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
nonobj_ok=$(jq -n --arg o "$o" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and $rc==1 then 1 else 0 end')
chk "event kind friction and non-object payload rejected locally, no request" \
  "$([ "$reserved_ok" = 1 ] && [ "$nonobj_ok" = 1 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

# 24. unreachable -> spooled as event-*, flushed to /api/v1/events next call
export AGENT_FEEDBACK_URL="http://127.0.0.1:1"
out=$(printf '%s' '{"spooled":true}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key spooled-key --stdin --model m 2>/dev/null)
rc=$?
o=$(outcome "$out")
n_spool=$(find "$SPOOL" -name 'event-*.json' 2>/dev/null | wc -l | tr -d ' ')
spool_ok=$(jq -n --arg o "$o" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="spooled" and $rc==0 and $n==1 then 1 else 0 end')
export AGENT_FEEDBACK_URL="$saved_url"
before=$(log_len)
bash "$SCRIPTS/query.sh" --family event --flush >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'event-*.json' -o -name 'event-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
flushed=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.path=="/api/v1/events" and .body.key=="spooled-key") | 1' | head -n1)
chk "event spooled offline and flushed to /api/v1/events" \
  "$([ "$spool_ok" = 1 ] && [ "$n_spool" = 0 ] && [ "${flushed:-0}" = 1 ] && echo 1 || echo 0)"

# 25. --dry-run builds and validates without sending
before=$(log_len)
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind bench --key k --stdin --model m --dry-run 2>/dev/null)
rc=$?
chk "event --dry-run -> valid, no request" "$(jq -n --arg last "$(outcome "$out")" \
  --arg payload "$(sed '$d' <<<"$out")" --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($last|fromjson) as $j | ($payload|fromjson) as $p |
   if $j.status=="valid" and $p.kind=="bench" and $p.payload.a==1 and $rc==0 and $b==$a then 1 else 0 end')"

# ── submit-review.sh ─────────────────────────────────────────────────────────

# fixture run dir
RUN_BASE="$HOME/.cache/review-panel"
RUN_DIR="$RUN_BASE/20260730-101010-4242"
mkdir -p "$RUN_DIR"
export AGENT_FEEDBACK_REVIEW_DIRS="$RUN_BASE"
cat >"$RUN_DIR/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20260730-101010",
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

# 9a. --include-outputs sends reviewer output and prompt, however large.
rm -f "$RUN_DIR/.submitted"
python3 -c 'import sys; sys.stdout.write("O"*200000)' >"$RUN_DIR/gpt56.md"
python3 -c 'import sys; sys.stdout.write("P"*200000)' >"$RUN_DIR/prompt.md"
bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" --include-outputs >/dev/null 2>&1
req=$(last_req)
chk "review --include-outputs carries 200 KB output and prompt" "$(jq -r '
  if (.body.reviewers[0].output|length)==200000 and (.body.prompt|length)==200000
  and (.body.reviewers[1] | has("output") | not) then 1 else 0 end' <<<"$req")"
rm -f "$RUN_DIR/gpt56.md" "$RUN_DIR/prompt.md" "$RUN_DIR/.submitted"

# 9b. A 201 whose receipt cannot be trusted must NOT write .submitted; the run
# is spooled instead (reviews are idempotent, so a retry is safe).
set_mode review_bad_created
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null)
rc=$?
o=$(outcome "$out")
marked=$([ -e "$RUN_DIR/.submitted" ] && echo 1 || echo 0)
n_spool=$(find "$SPOOL" -name 'review-*.json' 2>/dev/null | wc -l | tr -d ' ')
chk "malformed review 201 -> no .submitted, spooled for retry" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson marked "$marked" --argjson n "$n_spool" \
  '($o|fromjson) as $j |
   if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0
      and $marked==0 and $n==1 then 1 else 0 end')"
# The same validation guards the flush path: a malformed success keeps the file.
bash "$SCRIPTS/query.sh" --family review --flush >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'review-*.json' -o -name 'review-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
retained=$([ "$n_spool" = 1 ] && echo 1 || echo 0)
set_mode created
bash "$SCRIPTS/query.sh" --family review --flush >/dev/null 2>&1
n_spool=$(find "$SPOOL" \( -name 'review-*.json' -o -name 'review-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
chk "flush retains a malformed review receipt, clears it on a valid one" \
  "$([ "$retained" = 1 ] && [ "$n_spool" = 0 ] && echo 1 || echo 0)"
rm -f "$RUN_DIR/.submitted"

# 10. 409 mismatch -> mismatch outcome, exit 1, no .submitted
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

# 12a. Blank optional counts do not discard a completed score, and a delayed
# retry attributes the payload to the run's original caller.
RUN_OPTIONAL="$RUN_BASE/20260730-202020-optional"
mkdir -p "$RUN_OPTIONAL"
cat >"$RUN_OPTIONAL/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20260730-202020",
 "caller":"original-caller-model","slots":{"one":{"label":"Optional Counts"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\none\tmodel/one\tcompleted\t1\t2\n' >"$RUN_OPTIONAL/summary.tsv"
printf '20260730-202020\tx\tOptional Counts\t4\t\t\ttab\tpreserved\n' >>"$RUN_BASE/scorecards.tsv"
set_mode created
out=$(REVIEW_CALLER_MODEL="resubmitting-shell-model" bash "$SCRIPTS/submit-review.sh" "$RUN_OPTIONAL" 2>/dev/null)
rc=$?
req=$(last_req)
chk "review keeps score with blank optional counts, tabs, and original caller" "$(jq -r --argjson rc "$rc" '
  if $rc==0 and .body.coordinator_model=="original-caller-model"
  and .body.reviewers[0].score==4
  and (.body.reviewers[0] | has("valid") | not)
  and (.body.reviewers[0] | has("invalid") | not)
  and .body.reviewers[0].note=="tab\tpreserved"
  then 1 else 0 end' <<<"$req")"

# 12b. Direct submission refuses a PENDING scorecard before allocating run_id.
RUN_PENDING="$RUN_BASE/20200101-000000-pending"
mkdir -p "$RUN_PENDING"
cat >"$RUN_PENDING/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20200101-000000",
 "caller":"caller","slots":{"one":{"label":"Pending Grade"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\none\tmodel/one\tcompleted\t1\t2\n' >"$RUN_PENDING/summary.tsv"
printf '20200101-000000\tx\tPending Grade\tPENDING\t\t\t\n' >>"$RUN_BASE/scorecards.tsv"
before=$(log_len)
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_PENDING" 2>/dev/null)
rc=$?
chk "direct review refuses PENDING scorecard without request or marker" \
  "$([ "$rc" -ne 0 ] && [ "$(log_len)" -eq "$before" ] && [ ! -e "$RUN_PENDING/.submitted" ] && echo 1 || echo 0)"

# 12c. Sweep likewise leaves a completed run with no scorecard unsubmitted.
RUN_MISSING="$RUN_BASE/20200101-000001-missing"
mkdir -p "$RUN_MISSING"
cat >"$RUN_MISSING/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20200101-000001",
 "caller":"caller","slots":{"one":{"label":"Missing Grade"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\none\tmodel/one\tcompleted\t1\t2\n' >"$RUN_MISSING/summary.tsv"
before=$(log_len)
SWEEP_MIN_AGE_HOURS=0 bash "$SCRIPTS/submit-review.sh" --sweep >/dev/null 2>&1
chk "sweep refuses missing scorecard without request or marker" \
  "$([ "$(log_len)" -eq "$before" ] && [ ! -e "$RUN_MISSING/.submitted" ] && echo 1 || echo 0)"

# 12d. Timestamp-only scorecards cannot disambiguate sibling runs.
RUN_AMBIG_A="$RUN_BASE/20200101-000002-a"
RUN_AMBIG_B="$RUN_BASE/20200101-000002-b"
mkdir -p "$RUN_AMBIG_A" "$RUN_AMBIG_B"
for run in "$RUN_AMBIG_A" "$RUN_AMBIG_B"; do
  cat >"$run/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20200101-000002",
 "caller":"caller","slots":{"one":{"label":"Shared Timestamp"}}}
JSON
  printf 'slot\tmodel\tstatus\tduration_s\tbytes\none\tmodel/one\tcompleted\t1\t2\n' >"$run/summary.tsv"
done
printf '20200101-000002\tx\tShared Timestamp\t5\t1\t0\tok\n' >>"$RUN_BASE/scorecards.tsv"
before=$(log_len)
bash "$SCRIPTS/submit-review.sh" "$RUN_AMBIG_A" >/dev/null 2>&1
rc=$?
chk "ambiguous timestamp refuses score borrowing without request or marker" \
  "$([ "$rc" -ne 0 ] && [ "$(log_len)" -eq "$before" ] && [ ! -e "$RUN_AMBIG_A/.submitted" ] && echo 1 || echo 0)"

# 12e. Sweep picks up an unsubmitted run from AGENT_FEEDBACK_REVIEW_DIRS.
RUN_SWEEP="$RUN_BASE/20200101-000003-sweepable"
mkdir -p "$RUN_SWEEP"
cat >"$RUN_SWEEP/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20200101-000003",
 "caller":"caller","slots":{"one":{"label":"Sweepable"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\none\tmodel/one\tcompleted\t1\t2\n' >"$RUN_SWEEP/summary.tsv"
printf '20200101-000003\tx\tSweepable\t5\t1\t0\tok\n' >>"$RUN_BASE/scorecards.tsv"
set_mode created
out=$(bash "$SCRIPTS/submit-review.sh" --sweep 2>/dev/null)
swept=$(jq -r 'select(.body.run_id=="testmach-20200101-000003-sweepable") | 1' "$STATE/requests.jsonl" | head -n1)
chk "sweep submits a run found via AGENT_FEEDBACK_REVIEW_DIRS" \
  "$([ "${swept:-0}" = 1 ] && [ -f "$RUN_SWEEP/.submitted" ] && echo 1 || echo 0)"

# 12f. With no run dirs configured, sweep warns and only flushes the spool.
before=$(log_len)
out=$(env -u AGENT_FEEDBACK_REVIEW_DIRS -u REVIEW_LOG_DIR bash "$SCRIPTS/submit-review.sh" --sweep 2>&1)
case "$out" in
  *"no review run directories configured (set AGENT_FEEDBACK_REVIEW_DIRS)"*) warned=1 ;;
  *) warned=0 ;;
esac
chk "sweep without configured dirs warns and sends nothing" \
  "$([ "$warned" = 1 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

# 12g. Sweep recovers locks without metadata or with corrupt metadata by
# directory mtime, while a live owner remains protected even past the threshold.
LOCK="$HOME/.cache/agent-feedback/sweep.lock"
mkdir -p "$(dirname "$LOCK")"
rm -rf "$LOCK"
mkdir "$LOCK"
set_mtime "$LOCK" 120
SWEEP_LOCK_STALE_SECS=1 SWEEP_MIN_AGE_HOURS=100000 bash "$SCRIPTS/submit-review.sh" --sweep >/dev/null 2>&1
missing_lock_recovered=$([ ! -e "$LOCK" ] && echo 1 || echo 0)
mkdir "$LOCK"
printf 'corrupt\n' >"$LOCK/born"
set_mtime "$LOCK" 120
SWEEP_LOCK_STALE_SECS=1 SWEEP_MIN_AGE_HOURS=100000 bash "$SCRIPTS/submit-review.sh" --sweep >/dev/null 2>&1
corrupt_lock_recovered=$([ ! -e "$LOCK" ] && echo 1 || echo 0)
mkdir "$LOCK"
printf '%s\n' "$$:ancient:owner" >"$LOCK/owner"
printf '1\n' >"$LOCK/born"
SWEEP_LOCK_STALE_SECS=1 SWEEP_MIN_AGE_HOURS=100000 bash "$SCRIPTS/submit-review.sh" --sweep >/dev/null 2>&1
live_lock_preserved=$([ -d "$LOCK" ] && [ "$(cat "$LOCK/owner")" = "$$:ancient:owner" ] && echo 1 || echo 0)
chk "sweep lock recovers stale missing/corrupt metadata but preserves live owner" \
  "$([ "$missing_lock_recovered" = 1 ] && [ "$corrupt_lock_recovered" = 1 ] && [ "$live_lock_preserved" = 1 ] && echo 1 || echo 0)"
rm -rf "$LOCK"

# ── query.sh ─────────────────────────────────────────────────────────────────

# 13. URL encoding: +02:00 offset must arrive percent-encoded. Hex case is
# curl-version-dependent (8.5 emits %3a, 8.21 emits %3A) — match either.
set_mode created
bash "$SCRIPTS/query.sh" --type friction --since "2026-07-01T00:00:00+02:00" >/dev/null 2>&1
req=$(last_req)
chk "query URL-encodes since (+02:00)" "$(jq -r 'if (.path|test("since=2026-07-01T00%3A00%3A00%2B02%3A00"; "i")) then 1 else 0 end' <<<"$req")"

# 13a. new 1.1 list parameters reach the server
bash "$SCRIPTS/query.sh" --family friction --before-id 40 --include-payload --limit 5 >/dev/null 2>&1
req=$(last_req)
chk "query passes family, before_id and include=payload" "$(jq -r '
  if (.path|test("family=friction")) and (.path|test("before_id=40"))
  and (.path|test("include=payload")) and (.path|test("limit=5")) then 1 else 0 end' <<<"$req")"

# 14. read-only: a spooled payload is NOT flushed by query
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
chk "query by id -> full payload" "$(jq -r 'if .id==43 and .payload.category=="tooling" and .family=="friction" then 1 else 0 end' <<<"$out")"

# 16a. export: stream verified against its terminator (count + sha256)
set_list_rows 7
out=$(bash "$SCRIPTS/query.sh" export 2>"$WORK/export.err")
rc=$?
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
header_ok=$(printf '%s\n' "$out" | head -n1 | jq -r 'if .export_format==1 then 1 else 0 end')
term_ok=$(printf '%s\n' "$out" | tail -n1 | jq -r 'if .export_complete==true and .count==7 and (.sha256|length)==64 then 1 else 0 end')
chk "export streams header+records+terminator and verifies it, exit 0" \
  "$([ "$rc" = 0 ] && [ "$lines" = 9 ] && [ "$header_ok" = 1 ] && [ "$term_ok" = 1 ] && echo 1 || echo 0)"

# 16b. export without a terminator is reported as damaged, exit 1, output kept
set_mode export_no_terminator
out=$(bash "$SCRIPTS/query.sh" export 2>"$WORK/export2.err")
rc=$?
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
case "$(cat "$WORK/export2.err")" in *"missing its"*|*"truncated"*) warned=1 ;; *) warned=0 ;; esac
chk "export without terminator -> warning, exit 1, partial output still printed" \
  "$([ "$rc" = 1 ] && [ "$warned" = 1 ] && [ "$lines" = 8 ] && echo 1 || echo 0)"
set_mode created

# 16c. export honours its filters
out=$(bash "$SCRIPTS/query.sh" export --family friction --since "2026-01-01T00:00:00Z" 2>/dev/null)
req=$(last_req)
chk "export passes family and since" "$(jq -r '
  if (.path|startswith("/api/v1/export")) and (.path|test("family=friction"))
  and (.path|test("since=2026-01-01")) then 1 else 0 end' <<<"$req")"

# ── process.sh ───────────────────────────────────────────────────────────────

# 17. list: unprocessed filter + compact TSV with family
set_list_rows 1
out=$(bash "$SCRIPTS/process.sh" list 2>"$WORK/list.err")
req=$(last_req)
case "$(cat "$WORK/list.err")" in *"total: 1"*) total_shown=1 ;; *) total_shown=0 ;; esac
chk "process list -> processed=false, TSV row with family, total on stderr" "$(jq -n --arg o "$out" \
  --arg path "$(jq -r .path <<<"$req")" --argjson t "$total_shown" \
  'if ($path|contains("processed=false")) and ($t==1)
      and ($o|contains("1\tfriction\tfriction\ttestmach\ttooling\tfixture summary 1")) then 1 else 0 end')"

# 17a. list follows next_before_id across every page (500 rows per page)
set_list_rows 1200
before=$(log_len)
# The merged result is hundreds of KB: it goes to jq via --rawfile, never
# --arg (capped at 128 KiB per argument on Linux).
bash "$SCRIPTS/process.sh" list --json >"$WORK/list2.out" 2>"$WORK/list2.err"
gets=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.method=="GET") | 1' | wc -l | tr -d ' ')
cursors=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.path|test("before_id=")) | 1' | wc -l | tr -d ' ')
case "$(cat "$WORK/list2.err")" in *"total: 1200"*) total_shown=1 ;; *) total_shown=0 ;; esac
chk "process list pages through 1200 rows in 3 requests, merged --json, total" "$(jq -n \
  --rawfile o "$WORK/list2.out" --argjson gets "$gets" --argjson cursors "$cursors" --argjson t "$total_shown" \
  '($o|fromjson) as $j |
   if ($j.submissions|length)==1200 and $j.total==1200 and $j.submissions[0].id==1200
      and $j.submissions[1199].id==1 and $gets==3 and $cursors==2 and $t==1 then 1 else 0 end')"

# 17b. --limit caps the total rows returned across pages
before=$(log_len)
bash "$SCRIPTS/process.sh" list --limit 600 --json >"$WORK/list3.out" 2>/dev/null
gets=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.method=="GET") | 1' | wc -l | tr -d ' ')
chk "process list --limit caps the whole result, not one page" "$(jq -n --rawfile o "$WORK/list3.out" --argjson gets "$gets" \
  '($o|fromjson) as $j | if ($j.submissions|length)==600 and $gets==2 then 1 else 0 end')"

# 17c. --include-processed drops the processed filter; --all is a hard error
out=$(bash "$SCRIPTS/process.sh" list --include-processed --limit 1 2>/dev/null)
req=$(last_req)
inc_ok=$(jq -r 'if (.path|contains("processed=false")) then 0 else 1 end' <<<"$req")
before=$(log_len)
err=$(bash "$SCRIPTS/process.sh" list --all 2>&1 >/dev/null)
rc=$?
case "$err" in *"--include-processed"*) all_msg=1 ;; *) all_msg=0 ;; esac
chk "list --include-processed drops the filter; --all errors pointing at it" \
  "$([ "$inc_ok" = 1 ] && [ "$rc" -ne 0 ] && [ "$all_msg" = 1 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"
set_list_rows 1

# 17d. family/type/machine filters reach the server
bash "$SCRIPTS/process.sh" list --family review --type review-panel --machine other >/dev/null 2>&1
req=$(last_req)
chk "process list passes family/type/machine" "$(jq -r '
  if (.path|test("family=review")) and (.path|test("type=review-panel"))
  and (.path|test("machine=other")) then 1 else 0 end' <<<"$req")"

# 18. done: batch mark with a resolution, outcome echoed verbatim
out=$(bash "$SCRIPTS/process.sh" 'done' 43 44 --resolution "fixed in example@1a2b3c4" 2>/dev/null)
rc=$?
o=$(outcome "$out")
req=$(last_req)
chk "process done --resolution -> ids marked, resolution sent and echoed" "$(jq -n --arg o "$o" --argjson rc "$rc" \
  --arg body "$(jq -c .body <<<"$req")" \
  '($o|fromjson) as $j | ($body|fromjson) as $b |
   if $j.processed==true and $j.updated==[43,44] and $j.resolution=="fixed in example@1a2b3c4"
      and $b.ids==[43,44] and $b.processed==true and $b.resolution=="fixed in example@1a2b3c4"
      and $rc==0 then 1 else 0 end')"

# 18a. a blank resolution is rejected locally (the server would 400)
before=$(log_len)
out=$(bash "$SCRIPTS/process.sh" 'done' 43 --resolution "   " 2>/dev/null)
rc=$?
o=$(outcome "$out")
chk "blank --resolution -> rejected locally, no request" "$(jq -n --arg o "$o" \
  --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and $rc==1 and $b==$a then 1 else 0 end')"

# 19. undo -> processed:false, no resolution field
out=$(bash "$SCRIPTS/process.sh" undo 44 2>/dev/null)
req=$(last_req)
chk "process undo -> processed:false without resolution" "$(jq -r '
  if .body.processed==false and .body.ids==[44] and (.body|has("resolution")|not) then 1 else 0 end' <<<"$req")"

# 20. non-numeric id dies
if bash "$SCRIPTS/process.sh" 'done' abc >/dev/null 2>&1; then rc=0; else rc=$?; fi
chk "process done abc -> exit 1" "$([ "$rc" = 1 ] && echo 1 || echo 0)"

# ── agent-feedback-triage digest.sh ────────────────────────────────────────────────

TRIAGE_SCRIPTS="$TESTS_DIR/../../skills/agent-feedback-triage/scripts"

# 21. happy path: 3 unprocessed frictions served across two pages.
set_list_rows 3
set_list_page_cap 2
before=$(log_len)
out=$(bash "$TRIAGE_SCRIPTS/digest.sh" --out "$WORK/digest1" 2>"$WORK/digest1.err")
rc=$?
dir=$(outcome "$out")
gets=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.method=="GET") | 1' | wc -l | tr -d ' ')
cursors=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.path|test("before_id=")) | 1' | wc -l | tr -d ' ')
payload_q=$(tail -n +"$((before+1))" "$STATE/requests.jsonl" | jq -r 'select(.path|test("include=payload")) | 1' | wc -l | tr -d ' ')
chk "digest pages through 3 rows in 2 requests with include=payload" \
  "$([ "$rc" = 0 ] && [ "$gets" = 2 ] && [ "$cursors" = 1 ] && [ "$payload_q" = 2 ] && echo 1 || echo 0)"
chk "digest prints its directory as the last stdout line" \
  "$([ "$dir" = "$WORK/digest1" ] && [ -d "$dir" ] && echo 1 || echo 0)"
chk "digest writes one <id>.json per row" \
  "$([ -f "$WORK/digest1/1.json" ] && [ -f "$WORK/digest1/2.json" ] && [ -f "$WORK/digest1/3.json" ] && echo 1 || echo 0)"
chk "digest index.json holds every pulled row with its payload" "$(jq -r '
  if length==3 and ([.[].id]|sort)==[1,2,3]
     and (map(select(.payload.summary|startswith("fixture summary")))|length)==3
  then 1 else 0 end' "$WORK/digest1/index.json" 2>/dev/null || echo 0)"
md=$(cat "$WORK/digest1/digest.md" 2>/dev/null || true)
case "$md" in *"## project:"*) md_project=1 ;; *) md_project=0 ;; esac
case "$md" in *"### tooling"*) md_category=1 ;; *) md_category=0 ;; esac
case "$md" in *"#1"*) md_1=1 ;; *) md_1=0 ;; esac
case "$md" in *"#2"*) md_2=1 ;; *) md_2=0 ;; esac
case "$md" in *"#3"*) md_3=1 ;; *) md_3=0 ;; esac
case "$md" in *"pulled: 3"*) md_count=1 ;; *) md_count=0 ;; esac
chk "digest.md has project/category headings, every id, and pulled: 3" \
  "$([ "$md_project" = 1 ] && [ "$md_category" = 1 ] && [ "$md_count" = 1 ] \
     && [ "$md_1" = 1 ] && [ "$md_2" = 1 ] && [ "$md_3" = 1 ] && echo 1 || echo 0)"
set_list_page_cap 0

# 22. service unreachable -> exit 1, nothing on stdout
out=$(env AGENT_FEEDBACK_URL="http://127.0.0.1:1" bash "$TRIAGE_SCRIPTS/digest.sh" \
  --out "$WORK/digest2" 2>"$WORK/digest2.err")
rc=$?
chk "digest on an unreachable service -> exit 1, no directory on stdout" \
  "$([ "$rc" = 1 ] && [ -z "$out" ] && echo 1 || echo 0)"

# 23. empty queue -> exit 0 and a digest reporting pulled: 0
set_list_rows 0
out=$(bash "$TRIAGE_SCRIPTS/digest.sh" --out "$WORK/digest3" 2>"$WORK/digest3.err")
rc=$?
dir=$(outcome "$out")
md=$(cat "$WORK/digest3/digest.md" 2>/dev/null || true)
case "$md" in *"pulled: 0"*) md_count=1 ;; *) md_count=0 ;; esac
chk "digest on an empty queue -> exit 0, digest.md reports pulled: 0" \
  "$([ "$rc" = 0 ] && [ "$dir" = "$WORK/digest3" ] && [ "$md_count" = 1 ] && echo 1 || echo 0)"
set_list_rows 1

# ── outcome discipline on failure paths ──────────────────────────────────────

set_mode created
set_list_rows 1
rm -f "$SPOOL"/* 2>/dev/null || true

# 24. Every exit path ends with exactly one machine-readable outcome line:
# "error" for configuration/transport/HTTP failures, "rejected" for local
# validation failures.
before=$(log_len)
out=$(env -u AGENT_FEEDBACK_API_KEY bash "$SCRIPTS/query.sh" --type friction 2>/dev/null)
rc=$?
o=$(outcome "$out")
key_ok=$(jq -n --arg o "$o" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and ($j.message|test("API_KEY")) and $rc==1 then 1 else 0 end')
chk "missing API key -> error outcome, exit 1, no request" \
  "$([ "$key_ok" = 1 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

before=$(log_len)
out=$(bash "$SCRIPTS/query.sh" --bogus x 2>/dev/null); rc=$?
q_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("unknown flag")) and $rc==1 then 1 else 0 end')
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary s --model m --bogus 2>/dev/null); rc=$?
f_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("unknown flag")) and $rc==1 then 1 else 0 end')
out=$(bash "$SCRIPTS/process.sh" list --bogus 2>/dev/null); rc=$?
p_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and $rc==1 then 1 else 0 end')
chk "unknown flags -> rejected outcome everywhere, exit 1, no request" \
  "$([ "$q_ok" = 1 ] && [ "$f_ok" = 1 ] && [ "$p_ok" = 1 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

out=$(env AGENT_FEEDBACK_URL="http://127.0.0.1:1" bash "$SCRIPTS/process.sh" list 2>/dev/null); rc=$?
list_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and ($j.message|test("unreachable")) and $rc==1 then 1 else 0 end')
out=$(env AGENT_FEEDBACK_URL="http://127.0.0.1:1" bash "$SCRIPTS/process.sh" 'done' 43 2>/dev/null); rc=$?
done_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and ($j.message|test("unreachable")) and $rc==1 then 1 else 0 end')
chk "process.sh on an unreachable service -> error outcome, exit 1" \
  "$([ "$list_ok" = 1 ] && [ "$done_ok" = 1 ] && echo 1 || echo 0)"
rm -f "$SPOOL"/* 2>/dev/null || true

# 25. A 200 that is not the documented classification shape is not an answer.
set_mode processed_bad
out=$(bash "$SCRIPTS/process.sh" 'done' 43 2>/dev/null); rc=$?
chk "process done with a malformed 200 -> error outcome, exit 1" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and ($j.message|test("malformed")) and $rc==1 then 1 else 0 end')"
set_mode created

# ── receipt validation: family AND type, and malformed is never a collision ──

# 26. A 201 filed under a different skill proves nothing: retry, do not claim.
rm -f "$RUN_DIR/.submitted"
rm -f "$SPOOL"/* 2>/dev/null || true
set_mode review_wrong_type
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'review-*.json' 2>/dev/null | wc -l | tr -d ' ')
chk "review 201 under a foreign submission_type -> spooled, not acknowledged" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" \
  --argjson marked "$([ -e "$RUN_DIR/.submitted" ] && echo 1 || echo 0)" \
  '($o|fromjson) as $j |
   if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0
      and $n==1 and $marked==0 then 1 else 0 end')"

# 27. An unparseable 2xx body is a malformed success, NEVER a collision: it is
# retryable in both the direct and the flush path.
set_mode review_unparseable
bash "$SCRIPTS/query.sh" --family review --flush >/dev/null 2>&1
retained=$(find "$SPOOL" \( -name 'review-*.json' -o -name 'review-*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
rejected=$(find "$SPOOL" -name 'review-*.rejected' 2>/dev/null | wc -l | tr -d ' ')
rm -f "$SPOOL"/* 2>/dev/null || true
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" 2>/dev/null); rc=$?
direct=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0 then 1 else 0 end')
chk "unparseable review 2xx is retryable (direct + flush), never a collision" \
  "$([ "$retained" = 1 ] && [ "$rejected" = 0 ] && [ "$direct" = 1 ] && echo 1 || echo 0)"
set_mode created
bash "$SCRIPTS/query.sh" --family review --flush >/dev/null 2>&1
rm -f "$SPOOL"/* "$RUN_DIR/.submitted" 2>/dev/null || true

# 28. The same distinction for events: a non-integer id is malformed (spool), a
# record naming a different key/machine is a collision (exit 1, no spool).
set_mode event_bad_created
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key mal-key --stdin --model m 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'event-*.json' 2>/dev/null | wc -l | tr -d ' ')
bad_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0 and $n==1 then 1 else 0 end')
rm -f "$SPOOL"/* 2>/dev/null || true
set_mode event_unparseable
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key mal-key2 --stdin --model m 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'event-*.json' 2>/dev/null | wc -l | tr -d ' ')
unp_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0 and $n==1 then 1 else 0 end')
rm -f "$SPOOL"/* 2>/dev/null || true
set_mode event_collision
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key coll-key --stdin --model m 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'event-*' 2>/dev/null | wc -l | tr -d ' ')
coll_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="collision" and $j.key=="coll-key" and $rc==1 and $n==0 then 1 else 0 end')
chk "event receipts: malformed -> spooled, foreign record -> collision" \
  "$([ "$bad_ok" = 1 ] && [ "$unp_ok" = 1 ] && [ "$coll_ok" = 1 ] && echo 1 || echo 0)"
set_mode created
rm -f "$SPOOL"/* 2>/dev/null || true

# 29. A 401 is a fixable configuration problem, not a payload problem: the
# spooled file stays retryable instead of being parked as .rejected.
export AGENT_FEEDBACK_URL="http://127.0.0.1:1"
bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "401 retry" --model m >/dev/null 2>&1
export AGENT_FEEDBACK_URL="$saved_url"
AGENT_FEEDBACK_API_KEY="wrongkey" bash "$SCRIPTS/query.sh" --type friction --flush >/dev/null 2>&1
retryable=$(find "$SPOOL" -name 'friction-*.json' 2>/dev/null | wc -l | tr -d ' ')
rejected=$(find "$SPOOL" -name 'friction-*.rejected' 2>/dev/null | wc -l | tr -d ' ')
bash "$SCRIPTS/query.sh" --type friction --flush >/dev/null 2>&1
left=$(find "$SPOOL" -name 'friction-*' 2>/dev/null | wc -l | tr -d ' ')
chk "flush keeps a 401-refused payload retryable and delivers it once the key works" \
  "$([ "$retryable" = 1 ] && [ "$rejected" = 0 ] && [ "$left" = 0 ] && echo 1 || echo 0)"

# ── pagination guards ────────────────────────────────────────────────────────

# 30. has_more with no usable cursor must stop loudly, never return a silently
# truncated queue.
set_mode pagination_bad
set_list_rows 5
set_list_page_cap 2
out=$(bash "$SCRIPTS/process.sh" list 2>/dev/null); rc=$?
list_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and $j.message=="malformed pagination response" and $rc==1 then 1 else 0 end')
out=$(bash "$TRIAGE_SCRIPTS/digest.sh" --out "$WORK/digest-badpage" 2>/dev/null); rc=$?
digest_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and $j.message=="malformed pagination response" and $rc==1 then 1 else 0 end')
chk "malformed pagination stops process.sh list and digest.sh with an error outcome" \
  "$([ "$list_ok" = 1 ] && [ "$digest_ok" = 1 ] && echo 1 || echo 0)"
set_mode created
set_list_page_cap 0
set_list_rows 1

# ── temp-file hygiene ────────────────────────────────────────────────────────

# 31. EXIT traps must not reference function-local paths: a trap firing after
# the function returned expands them to "" and leaves the temp file behind.
# TMPDIR is set for GNU mktemp; macOS mktemp ignores it and uses the Darwin
# per-user temp dir, so the check is a before/after snapshot of whichever
# directory mktemp actually writes to.
PRIV_TMP="$WORK/private-tmp"
mkdir -p "$PRIV_TMP"
TMP_ROOT=$(dirname "$(TMPDIR="$PRIV_TMP" mktemp -u)")
tmp_entries() { find "$TMP_ROOT" "$PRIV_TMP" -maxdepth 1 -mindepth 1 2>/dev/null | sort; }
tmp_before=$(tmp_entries)
set_list_rows 3
TMPDIR="$PRIV_TMP" bash "$SCRIPTS/query.sh" export >/dev/null 2>&1
TMPDIR="$PRIV_TMP" bash "$SCRIPTS/process.sh" list >/dev/null 2>&1
TMPDIR="$PRIV_TMP" bash "$SCRIPTS/query.sh" 43 >/dev/null 2>&1
leaked=$(comm -13 <(printf '%s\n' "$tmp_before") <(tmp_entries) | wc -l | tr -d ' ')
chk "query.sh export / process.sh list leave no temp files behind" \
  "$([ "$leaked" = 0 ] && echo 1 || echo 0)"
set_list_rows 1

# ── bash 3.2: possibly-empty arrays ──────────────────────────────────────────

# 32. macOS ships bash 3.2, where "${ARR[@]}" on an empty array is an unbound
# variable under `set -u`. Both of these expand an empty array.
set_list_rows 2
bash "$SCRIPTS/query.sh" export >/dev/null 2>&1; export_rc=$?
bash "$SCRIPTS/process.sh" list --include-processed >/dev/null 2>&1; list_rc=$?
chk "unfiltered export and unfiltered list run with empty parameter arrays" \
  "$([ "$export_rc" = 0 ] && [ "$list_rc" = 0 ] && echo 1 || echo 0)"
set_list_rows 1

# ── export verification ──────────────────────────────────────────────────────

# 33. An HTTP error is not an export: nothing but the outcome on stdout.
set_mode export_http_500
out=$(bash "$SCRIPTS/query.sh" export 2>/dev/null); rc=$?
chk "export HTTP 500 -> error outcome, exit 1, no NDJSON on stdout" "$(jq -n \
  --arg o "$out" --argjson rc "$rc" \
  '($o|fromjson) as $j | if $j.status=="error" and ($j.message|test("HTTP 500")) and $rc==1 then 1 else 0 end')"

# 34. An empty export (header + terminator, count 0) verifies successfully.
set_mode export_empty
out=$(bash "$SCRIPTS/query.sh" export 2>"$WORK/export3.err"); rc=$?
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
term_ok=$(printf '%s\n' "$out" | tail -n1 | jq -r 'if .export_complete==true and .count==0 then 1 else 0 end')
case "$(cat "$WORK/export3.err")" in *"export verified: 0 record(s)"*) verified=1 ;; *) verified=0 ;; esac
chk "empty export verifies (exit 0), verification goes to stderr only" \
  "$([ "$rc" = 0 ] && [ "$lines" = 2 ] && [ "$term_ok" = 1 ] && [ "$verified" = 1 ] && echo 1 || echo 0)"

# 35. A stream that does not start with an export header is not an export.
set_mode export_bad_header
set_list_rows 2
out=$(bash "$SCRIPTS/query.sh" export 2>"$WORK/export4.err"); rc=$?
case "$(cat "$WORK/export4.err")" in *"export_format"*) warned=1 ;; *) warned=0 ;; esac
chk "export with a bad header line -> exit 1 and a stderr warning" \
  "$([ "$rc" = 1 ] && [ "$warned" = 1 ] && echo 1 || echo 0)"
set_mode created
set_list_rows 1

# ── submit-event.sh: byte-for-byte payload forwarding ────────────────────────

# 36. Number spelling and key order are part of the payload: the bytes the
# caller handed over are the bytes the server receives.
VERBATIM='{"z":1.0,"a":1e0,"big":12345678901234567890,"nested":{"b":2},"t":true}'
printf '%s' "$VERBATIM" >"$WORK/verbatim.json"
bash "$SCRIPTS/submit-event.sh" --kind bench --key verbatim-1 \
  --payload-file "$WORK/verbatim.json" --model m >/dev/null 2>&1
raw=$(last_req | jq -r '.raw')
case "$raw" in
  *"\"payload\":$VERBATIM"*) verbatim_ok=1 ;;
  *) verbatim_ok=0 ;;
esac
chk "event payload reaches the server byte-identical (1.0, 1e0, big integers, key order)" \
  "$verbatim_ok"

# 37. A concatenated stream of JSON documents is a mistake, not a payload.
before=$(log_len)
out=$(printf '%s' '{"a":1}{"b":2}' | bash "$SCRIPTS/submit-event.sh" --kind bench --stdin --model m 2>/dev/null); rc=$?
ev_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and $rc==1 then 1 else 0 end')
out=$(printf '%s\n%s\n' '{"category":"tooling","summary":"one"}' '{"category":"tooling","summary":"two"}' \
  | bash "$SCRIPTS/submit-friction.sh" --stdin --model m 2>/dev/null); rc=$?
fr_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("single JSON object")) and $rc==1 then 1 else 0 end')
chk "multi-document --stdin input rejected for events and frictions, no request" \
  "$([ "$ev_ok" = 1 ] && [ "$fr_ok" = 1 ] && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

# 38. The server's 10 MiB body limit is enforced locally, so an oversized
# report costs no round trip.
before=$(log_len)
python3 -c '
import json,sys
json.dump({"category":"tooling","summary":"oversized","details":"D"*11010048}, sys.stdout)' \
  >"$WORK/oversized.json"
out=$(bash "$SCRIPTS/submit-friction.sh" --stdin --model m <"$WORK/oversized.json" 2>/dev/null); rc=$?
chk "10.5 MiB friction -> rejected locally, no request" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and ($j.message|test("10485760")) and $rc==1 and $b==$a then 1 else 0 end')"
rm -f "$WORK/oversized.json"

# ── submit-review.sh: TSV parsing, skips, flags ──────────────────────────────

# 39. Tabs are IFS whitespace: a naive read collapses consecutive tabs (losing
# an empty duration into the bytes column) and drops a final unterminated row.
RUN_TSV="$RUN_BASE/20200101-000004-tsv"
mkdir -p "$RUN_TSV"
cat >"$RUN_TSV/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20200101-000004",
 "caller":"caller","slots":{"one":{"label":"TSV Row"},"two":{"label":"TSV Row Two"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\n' >"$RUN_TSV/summary.tsv"
printf 'one\tmodel/one\tcompleted\t\t2048\n' >>"$RUN_TSV/summary.tsv"
printf 'two\tmodel/two\ttimeout\t12\t99' >>"$RUN_TSV/summary.tsv"   # no trailing newline
printf '20200101-000004\tx\tTSV Row\t5\t1\t0\tok\n' >>"$RUN_BASE/scorecards.tsv"
set_mode created
bash "$SCRIPTS/submit-review.sh" "$RUN_TSV" >/dev/null 2>&1
req=$(last_req)
chk "review TSV keeps an empty duration in place and the final unterminated row" "$(jq -r '
  if (.body.reviewers|length)==2
  and .body.reviewers[0].slot=="one"
  and (.body.reviewers[0]|has("duration_s")|not)
  and .body.reviewers[0].bytes==2048
  and .body.reviewers[1].slot=="two"
  and .body.reviewers[1].duration_s==12 and .body.reviewers[1].bytes==99
  then 1 else 0 end' <<<"$req")"

# 40. Nothing to submit still ends with an outcome in direct mode.
RUN_NOMETA="$RUN_BASE/20200101-000005-nometa"
mkdir -p "$RUN_NOMETA"
rm -f "$SPOOL"/* 2>/dev/null || true
before=$(log_len)
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_NOMETA" 2>/dev/null); rc=$?
nometa_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="skipped" and ($j.reason|test("meta.json")) and ($j.run_id|length>0) and $rc==1 then 1 else 0 end')
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_PENDING" 2>/dev/null); rc=$?
pending_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="skipped" and ($j.reason|test("incomplete scorecard")) and $rc==1 then 1 else 0 end')
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_AMBIG_A" 2>/dev/null); rc=$?
ambig_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="skipped" and ($j.reason|test("ambiguous timestamp")) and $rc==1 then 1 else 0 end')
chk "direct review skips end with a skipped outcome and send nothing" \
  "$([ "$nometa_ok" = 1 ] && [ "$pending_ok" = 1 ] && [ "$ambig_ok" = 1 ] \
     && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

# 40a. Sweep keeps warning per run and exiting 0.
before=$(log_len)
out=$(SWEEP_MIN_AGE_HOURS=0 bash "$SCRIPTS/submit-review.sh" --sweep 2>&1); rc=$?
case "$out" in *"incomplete scorecard"*) swept_warn=1 ;; *) swept_warn=0 ;; esac
chk "sweep still warns per run and exits 0" \
  "$([ "$rc" = 0 ] && [ "$swept_warn" = 1 ] && echo 1 || echo 0)"

# 41. A flag typo must never submit with the wrong options.
before=$(log_len)
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_DIR" --include-output 2>/dev/null); rc=$?
chk "review unknown flag -> rejected outcome, exit 1, no request" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson b "$before" --argjson a "$(log_len)" \
  '($o|fromjson) as $j | if $j.status=="rejected" and ($j.message|test("unknown flag")) and $rc==1 and $b==$a then 1 else 0 end')"

# ── agent-feedback-triage digest.sh output directory ───────────────────────────────

# 42. Two digests in the same second must not land in the same directory, and
# an existing non-empty --out is refused rather than mixed into.
set_mode created
set_list_rows 1
DIGEST_TMP="$WORK/digest-tmp"
mkdir -p "$DIGEST_TMP"
d1=$(TMPDIR="$DIGEST_TMP" bash "$TRIAGE_SCRIPTS/digest.sh" 2>/dev/null | tail -n1)
d2=$(TMPDIR="$DIGEST_TMP" bash "$TRIAGE_SCRIPTS/digest.sh" 2>/dev/null | tail -n1)
out=$(bash "$TRIAGE_SCRIPTS/digest.sh" --out "$WORK/digest1" 2>&1); rc=$?
case "$out" in *"not empty"*) refused=1 ;; *) refused=0 ;; esac
chk "digest makes a fresh directory per run and refuses a non-empty --out" \
  "$([ -n "$d1" ] && [ -n "$d2" ] && [ "$d1" != "$d2" ] && [ -d "$d1" ] && [ -d "$d2" ] \
     && [ "$rc" != 0 ] && [ "$refused" = 1 ] && echo 1 || echo 0)"

# 43. digest.sh is executable as shipped (it is invoked directly, not via bash).
chk "digest.sh is executable" "$([ -x "$TRIAGE_SCRIPTS/digest.sh" ] && echo 1 || echo 0)"

# ── receipt comparability: only a well-formed receipt can claim a collision ──

# 44. A receipt whose id is a STRING is not comparable, even when it names a
# foreign key: it proves nothing, so the event is spooled, never called a
# collision. The same holds for a body holding two JSON documents.
set_mode event_bad_id_foreign_key
rm -f "$SPOOL"/* 2>/dev/null || true
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key strid-key --stdin --model m 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'event-*.json' 2>/dev/null | wc -l | tr -d ' ')
strid_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0 and $n==1 then 1 else 0 end')
rm -f "$SPOOL"/* 2>/dev/null || true
set_mode event_two_docs
out=$(printf '%s' '{"a":1}' | bash "$SCRIPTS/submit-event.sh" --kind deploy --key twodoc-key --stdin --model m 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'event-*.json' 2>/dev/null | wc -l | tr -d ' ')
twodoc_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="spooled" and $j.reason=="malformed_success_response" and $rc==0 and $n==1 then 1 else 0 end')
chk "string id with a foreign key and a two-document body are spooled, never a collision" \
  "$([ "$strid_ok" = 1 ] && [ "$twodoc_ok" = 1 ] && echo 1 || echo 0)"
set_mode created
rm -f "$SPOOL"/* 2>/dev/null || true

# ── paging contract: a 200 without it is malformed, not an empty queue ───────

# 45. A 200 carrying {} has no has_more/submissions/total: reporting it as the
# end of the walk would be indistinguishable from an empty queue.
set_mode list_bad_shape
out=$(bash "$SCRIPTS/process.sh" list 2>/dev/null); rc=$?
list_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and $j.message=="malformed pagination response" and $rc==1 then 1 else 0 end')
out=$(bash "$TRIAGE_SCRIPTS/digest.sh" --out "$WORK/digest-badshape" 2>/dev/null); rc=$?
digest_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and $j.message=="malformed pagination response" and $rc==1 then 1 else 0 end')
chk "a {} 200 is an error outcome for list and digest, not an empty queue" \
  "$([ "$list_ok" = 1 ] && [ "$digest_ok" = 1 ] && echo 1 || echo 0)"
set_mode created

# ── flags that need a value ─────────────────────────────────────────────────

# 46. A flag with no value must be rejected, never `shift 2` into a `set -e`
# death — and never an endless loop where `set -e` happens to be disabled.
# Each call is watchdogged so a regression fails the suite instead of hanging.
run_with_timeout() { # <secs> <outfile> <cmd...>
  local secs="$1" outf="$2"; shift 2
  "$@" >"$outf" 2>/dev/null &
  local pid=$! rc=0
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watch=$!
  wait "$pid" || rc=$?
  kill "$watch" 2>/dev/null
  wait "$watch" 2>/dev/null
  return "$rc"
}
before=$(log_len)
run_with_timeout 10 "$WORK/noval1.out" bash "$SCRIPTS/submit-event.sh" --kind; rc=$?
ev_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval1.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("--kind requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
run_with_timeout 10 "$WORK/noval2.out" bash "$SCRIPTS/query.sh" export --family; rc=$?
qx_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval2.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("--family requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
run_with_timeout 10 "$WORK/noval3.out" bash "$SCRIPTS/query.sh" --type; rc=$?
q_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval3.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
run_with_timeout 10 "$WORK/noval4.out" bash "$SCRIPTS/process.sh" list --family; rc=$?
pl_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval4.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
run_with_timeout 10 "$WORK/noval5.out" bash "$SCRIPTS/process.sh" 'done' 43 --resolution; rc=$?
pd_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval5.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
run_with_timeout 10 "$WORK/noval6.out" bash "$SCRIPTS/submit-friction.sh" --category; rc=$?
sf_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval6.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
run_with_timeout 10 "$WORK/noval7.out" bash "$TRIAGE_SCRIPTS/digest.sh" --out; rc=$?
dg_ok=$(jq -n --arg o "$(outcome "$(cat "$WORK/noval7.out")")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="rejected" and ($j.message|test("requires a value")) and $rc==1 then 1 else 0 end' 2>/dev/null || echo 0)
chk "a value-less flag -> rejected outcome, exit 1, no request, no loop" \
  "$([ "$ev_ok" = 1 ] && [ "$qx_ok" = 1 ] && [ "$q_ok" = 1 ] && [ "$pl_ok" = 1 ] \
     && [ "$pd_ok" = 1 ] && [ "$sf_ok" = 1 ] && [ "$dg_ok" = 1 ] \
     && [ "$(log_len)" -eq "$before" ] && echo 1 || echo 0)"

# ── redirects are a misconfigured URL, not a retryable failure ───────────────

# 47. A 3xx must be rejected with its status, never spooled for 30 days.
set_mode redirect
rm -f "$SPOOL"/* 2>/dev/null || true
out=$(bash "$SCRIPTS/submit-friction.sh" --category tooling --summary "redirected" --model m 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'friction-*' 2>/dev/null | wc -l | tr -d ' ')
chk "friction 302 -> rejected with http_status, exit 1, not spooled" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" \
  '($o|fromjson) as $j |
   if $j.status=="rejected" and $j.http_status==302 and $rc==1 and $n==0 then 1 else 0 end')"
set_mode created
rm -f "$SPOOL"/* 2>/dev/null || true

# ── submit-review.sh: the 10 MiB body cap ───────────────────────────────────

# 48. --include-outputs can push a run past the server's request-body cap: the
# check happens before the upload, and sweep only warns.
RUN_BIG="$RUN_BASE/20200101-000006-big"
mkdir -p "$RUN_BIG"
cat >"$RUN_BIG/meta.json" <<'JSON'
{"machine":"testmach","skill":"review-panel","run_ts":"20200101-000006",
 "caller":"caller","slots":{"one":{"label":"Big Output"}}}
JSON
printf 'slot\tmodel\tstatus\tduration_s\tbytes\none\tmodel/one\tcompleted\t1\t2\n' >"$RUN_BIG/summary.tsv"
printf '20200101-000006\tx\tBig Output\t5\t1\t0\tok\n' >>"$RUN_BASE/scorecards.tsv"
python3 -c 'import sys; sys.stdout.write("O"*11010048)' >"$RUN_BIG/one.md"
before=$(log_len)
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_BIG" --include-outputs 2>/dev/null); rc=$?
n_spool=$(find "$SPOOL" -name 'review-*' 2>/dev/null | wc -l | tr -d ' ')
direct_ok=$(jq -n --arg o "$(outcome "$out")" --argjson rc "$rc" --argjson n "$n_spool" '($o|fromjson) as $j |
  if $j.status=="rejected" and $j.reason=="body_too_large" and $j.limit==10485760
     and $rc==1 and $n==0 then 1 else 0 end')
chk "oversized review body -> rejected locally before the upload, no request" \
  "$([ "$direct_ok" = 1 ] && [ "$(log_len)" -eq "$before" ] && [ ! -e "$RUN_BIG/.submitted" ] && echo 1 || echo 0)"
# The same run submitted without outputs fits and goes through.
out=$(bash "$SCRIPTS/submit-review.sh" "$RUN_BIG" 2>/dev/null); rc=$?
chk "the same run without --include-outputs still submits" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="submitted" and $rc==0 then 1 else 0 end')"
rm -rf "$RUN_BIG"

# ── export: a filtered header on an unfiltered request ──────────────────────

# 49. An unfiltered export whose header reports a filter is a subset of the
# database: the error goes to stderr so stdout stays pure NDJSON.
set_mode export_filtered_header
set_list_rows 2
out=$(bash "$SCRIPTS/query.sh" export 2>"$WORK/export5.err"); rc=$?
err_outcome=$(grep -c '"status":"error"' "$WORK/export5.err")
case "$(cat "$WORK/export5.err")" in *"reports a filtered export"*) msg_ok=1 ;; *) msg_ok=0 ;; esac
stdout_pure=$(printf '%s\n' "$out" | head -n1 | jq -r 'if .export_format==1 then 1 else 0 end' 2>/dev/null || echo 0)
chk "unfiltered export with a filtered header -> error on stderr, exit 1, stdout pure NDJSON" \
  "$([ "$rc" = 1 ] && [ "$err_outcome" -ge 1 ] && [ "$msg_ok" = 1 ] && [ "$stdout_pure" = 1 ] && echo 1 || echo 0)"
# Asking for that filter makes the same header correct.
out=$(bash "$SCRIPTS/query.sh" export --family friction 2>"$WORK/export6.err"); rc=$?
case "$(cat "$WORK/export6.err")" in *"export verified"*) verified=1 ;; *) verified=0 ;; esac
chk "the same header verifies when --family was actually requested" \
  "$([ "$rc" = 0 ] && [ "$verified" = 1 ] && echo 1 || echo 0)"
set_mode created
set_list_rows 1

# ── process.sh: the classification must answer THIS request ─────────────────

# 50. A well-shaped 200 that classifies submissions nobody asked about is not
# an answer: echoing it would report a mark that never happened.
set_mode processed_foreign_ids
out=$(bash "$SCRIPTS/process.sh" 'done' 43 2>/dev/null); rc=$?
chk "processed 200 naming foreign ids -> error outcome, exit 1" "$(jq -n \
  --arg o "$(outcome "$out")" --argjson rc "$rc" '($o|fromjson) as $j |
  if $j.status=="error" and $rc==1 then 1 else 0 end')"
set_mode created

python3 "$TESTS_DIR/test_cluster.py"
rc=$?
chk "triage advisory disclosure and failure boundaries" "$([ "$rc" = 0 ] && echo 1 || echo 0)"

echo
echo "skill tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
