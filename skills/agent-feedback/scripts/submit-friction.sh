#!/usr/bin/env bash
# Submit a friction report to the agent-feedback service — what slowed the
# agent down, so it can be triaged into tooling/doc improvements.
#
# Usage:
#   submit-friction.sh --category <cat> --summary <one line> \
#     [--details <text>] [--suggested-fix <text>] [--project <name>] \
#     [--harness <name>] [--model <coordinator model>] [--dry-run]
#   submit-friction.sh --stdin [--dry-run]  <<'JSON'
#   {"category":"tooling","summary":"...","details":"...","suggested_fix":"..."}
#   JSON
#
# --stdin takes a single JSON object — no shell-quoting of prose, and no limit
# on prose size. Allowed keys: category, summary (required), details,
# suggested_fix, project, harness, model, machine, context (object of extra
# string pairs). Anything else is rejected locally (the server is strict).
#
# Every submission is auto-enriched with a "context" object (occurred_at, cwd,
# git repo/branch/commit, os, session id, ...) — see af_collect_context in
# _common.sh. The agent supplies nothing; a "context" object in --stdin input
# merges on top of the auto-collected one.
# --dry-run builds and validates the payload, prints it, and exits without
#   sending ({"status":"valid"} outcome). Validation is the same one applied
#   before a real send, so a dry-run "valid" means the server would accept it.
#
# Auto-detected when omitted (explicit values always win):
#   --harness   claude-code / opencode / pi / omp / codex — from env markers each
#               harness sets (see af_detect_harness); AGENT_FEEDBACK_HARNESS overrides
#   --project   git remote basename (falls back to cwd basename)
#   --model     AGENT_FEEDBACK_MODEL, else REVIEW_CALLER_MODEL, else legacy
#               wrapper vars, else unknown — pass it explicitly; "unknown" rows
#               are useless for analytics
#
# Retry semantics: the server absorbs identical-content duplicates for 24h, so
# transport failures and 5xx responses are SPOOLED and retried automatically.
# The last stdout line is always a machine-readable outcome:
#   {"status":"submitted","id":N} | {"status":"duplicate","id":N}
#   {"status":"spooled","reason":"..."} | {"status":"rejected",...}
#   {"status":"failed","reason":"spool_unwritable","path":"..."}
#   {"status":"valid"} (dry-run)
# Exit 0 for submitted/duplicate/spooled/valid; 1 for rejected/failed/invalid input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

CATEGORY="" SUMMARY="" PROJECT="" HARNESS="" MODEL="" MACHINE=""
STDIN_MODE=0 DRY_RUN=0

af_require_deps

WORKDIR=$(mktemp -d) || af_die "could not create a temporary directory"
trap 'rm -rf "$WORKDIR"; rm -f "${AF_RESP:-}"' EXIT
DETAILS_F="$WORKDIR/details"; : >"$DETAILS_F"
FIX_F="$WORKDIR/fix";         : >"$FIX_F"
CTX_F="$WORKDIR/extra-context"; printf '{}' >"$CTX_F"

# Large prose (details / suggested_fix) never travels through jq's argv:
# --arg is capped by the OS argument limit (128 KiB per argument on Linux), so
# every free-text field is staged in a file and read with --rawfile.
while [ $# -gt 0 ]; do
  case "$1" in
    --category)      CATEGORY="${2:-}"; shift 2 ;;
    --summary)       SUMMARY="${2:-}"; shift 2 ;;
    --details)       printf '%s' "${2:-}" >"$DETAILS_F"; shift 2 ;;
    --suggested-fix) printf '%s' "${2:-}" >"$FIX_F"; shift 2 ;;
    --project)       PROJECT="${2:-}"; shift 2 ;;
    --harness)       HARNESS="${2:-}"; shift 2 ;;
    --model)         MODEL="${2:-}"; shift 2 ;;
    --stdin)         STDIN_MODE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) af_reject "unknown flag: $1 (see header for usage)" ;;
  esac
done

if [ "$STDIN_MODE" = 1 ]; then
  STDIN_F="$WORKDIR/stdin.json"
  cat >"$STDIN_F"
  jq -e 'type == "object"' "$STDIN_F" >/dev/null 2>&1 \
    || { af_outcome '{"status":"rejected","message":"--stdin input is not a JSON object"}'; exit 1; }
  # jq accepts a concatenated stream of documents; only the first would ever be
  # read, so several documents are a mistake, not an input.
  STDIN_DOCS=$(jq -c . "$STDIN_F" 2>/dev/null | wc -l | tr -d ' ')
  [ "$STDIN_DOCS" = 1 ] \
    || af_reject "--stdin input must be a single JSON object (got $STDIN_DOCS JSON documents)"
  UNKNOWN=$(jq -r '[keys[] | select(. as $k | ["category","summary","details","suggested_fix","project","harness","model","machine","context"] | index($k) | not)] | join(",")' "$STDIN_F")
  if [ -n "$UNKNOWN" ]; then
    af_outcome "$(jq -cn --arg k "$UNKNOWN" '{status:"rejected",message:("unknown keys in --stdin input: "+$k)}')"
    exit 1
  fi
  # Flags (if any) override stdin values; stdin overrides auto-detection.
  [ -n "$CATEGORY" ] || CATEGORY=$(jq -r '.category // ""' "$STDIN_F")
  [ -n "$SUMMARY" ]  || SUMMARY=$(jq -r '.summary // ""' "$STDIN_F")
  [ -s "$DETAILS_F" ] || jq -j '.details // ""' "$STDIN_F" >"$DETAILS_F"
  [ -s "$FIX_F" ]     || jq -j '.suggested_fix // ""' "$STDIN_F" >"$FIX_F"
  [ -n "$PROJECT" ]  || PROJECT=$(jq -r '.project // ""' "$STDIN_F")
  [ -n "$HARNESS" ]  || HARNESS=$(jq -r '.harness // ""' "$STDIN_F")
  [ -n "$MODEL" ]    || MODEL=$(jq -r '.model // ""' "$STDIN_F")
  [ -n "$MACHINE" ]  || MACHINE=$(jq -r '.machine // ""' "$STDIN_F")
  jq -c '.context // {}' "$STDIN_F" >"$CTX_F"
  jq -e 'type == "object" and (to_entries | all(.value | type == "string"))' "$CTX_F" >/dev/null 2>&1 \
    || { af_outcome '{"status":"rejected","message":"context must be an object of string values"}'; exit 1; }
fi

[ -n "$HARNESS" ] || HARNESS=$(af_detect_harness)
[ -n "$PROJECT" ] || PROJECT=$(af_detect_project)
[ -n "$MODEL" ]   || MODEL=$(af_detect_model)
[ -n "$MACHINE" ] || MACHINE=$(af_machine)

# Local validation mirrors the server's: blank-after-trim is not a value, and
# identifier/summary limits are byte limits. Whitespace is trimmed here so the
# stored value is the same one that was validated.
CATEGORY=$(af_trim "$CATEGORY")
SUMMARY=$(af_trim "$SUMMARY")
MACHINE=$(af_trim "$MACHINE")
MODEL=$(af_trim "$MODEL")
PROJECT=$(af_trim "$PROJECT")
HARNESS=$(af_trim "$HARNESS")

af_check_required "--category" "$CATEGORY"
af_check_required "--summary" "$SUMMARY"
af_check_required "machine_name" "$MACHINE"
af_check_required "--model" "$MODEL"
af_check_identifier "category" "$CATEGORY"
af_check_identifier "machine_name" "$MACHINE"
af_check_identifier "coordinator_model" "$MODEL"
[ -z "$PROJECT" ] || af_check_identifier "project" "$PROJECT"
[ -z "$HARNESS" ] || af_check_identifier "harness" "$HARNESS"
af_check_summary "summary" "$SUMMARY"

# Soft nudge, never a gate: a suggested_fix claiming the fix was already
# applied should name the commit. Warning only — sometimes the claim is honest
# but uncommitted (say so in the text), or the commit comes later.
if grep -qiE '\b(applied|fixed|corrected)\b' "$FIX_F" \
   && ! grep -qE '\b[0-9a-f]{7,40}\b' "$FIX_F" \
   && ! grep -qiE '\b(will be|being|to be|not yet|pending|uncommitted|planned)\b' "$FIX_F"; then
  af_warn "suggested-fix claims a fix was applied but names no commit SHA — include it (git log -1 --format=%h), or state explicitly that the change is uncommitted/pending"
fi

# Auto-collected context; agent-provided context keys (stdin) win per-key.
CONTEXT_F="$WORKDIR/context.json"
af_collect_context >"$WORKDIR/auto-context.json"
jq -c -n --slurpfile auto "$WORKDIR/auto-context.json" --slurpfile extra "$CTX_F" \
  '$auto[0] + $extra[0]' >"$CONTEXT_F"
af_check_context "$(cat "$CONTEXT_F")"

PAYLOAD="$WORKDIR/payload.json"
jq -n \
  --arg machine "$MACHINE" --arg model "$MODEL" \
  --arg category "$CATEGORY" --arg summary "$SUMMARY" \
  --rawfile details "$DETAILS_F" --rawfile fix "$FIX_F" \
  --arg project "$PROJECT" --arg harness "$HARNESS" \
  --slurpfile context "$CONTEXT_F" \
  '{machine_name: $machine, coordinator_model: $model,
    category: $category, summary: $summary}
   + (if $details != "" then {details: $details} else {} end)
   + (if $fix     != "" then {suggested_fix: $fix} else {} end)
   + (if $project != "" then {project: $project} else {} end)
   + (if $harness != "" then {harness: $harness} else {} end)
   + {context: $context[0]}' >"$PAYLOAD"

PAYLOAD_BYTES=$(wc -c <"$PAYLOAD" | tr -d ' ')
[ "$PAYLOAD_BYTES" -le "$AF_MAX_BODY_BYTES" ] \
  || af_reject "friction request body is $PAYLOAD_BYTES bytes, over the ${AF_MAX_BODY_BYTES}-byte limit"

if [ "$DRY_RUN" = 1 ]; then
  cat "$PAYLOAD"
  echo
  af_outcome '{"status":"valid"}'
  exit 0
fi

af_require_key
af_flush_spool

af_request POST "/api/v1/frictions" "$PAYLOAD"
case "$AF_HTTP_CODE" in
  201|200)
    if af_friction_response_valid "$AF_RESP" "$PAYLOAD"; then
      if [ "$AF_HTTP_CODE" = 201 ]; then
        af_outcome "$(jq -c '{status:"submitted",id:.id}' "$AF_RESP")"
      else
        # Identical content within the server's 24h dedupe window — absorbed.
        af_outcome "$(jq -c '{status:"duplicate",id:.id}' "$AF_RESP")"
      fi
    else
      # A 2xx alone cannot prove the server accepted this friction payload.
      # Retain it for a later retry rather than silently losing it.
      af_warn "service returned malformed friction success response — spooling"
      af_spool "friction" "$PAYLOAD"
      af_outcome '{"status":"spooled","reason":"malformed_success_response"}'
    fi
    ;;
  000)
    af_warn "service unreachable (curl exit $AF_CURL_EXIT) — spooling"
    af_spool "friction" "$PAYLOAD"
    af_outcome "$(jq -cn --arg r "$(af_transport_reason)" '{status:"spooled",reason:$r}')"
    ;;
  4*)
    af_outcome "$(jq -cn --argjson code "$AF_HTTP_CODE" --arg msg "$(jq -r '.message // ""' "$AF_RESP" 2>/dev/null | head -c 400)" \
      '{status:"rejected",http_status:$code,message:$msg}')"
    exit 1
    ;;
  *)
    af_warn "server error $AF_HTTP_CODE — spooling (retry is dedupe-safe)"
    af_spool "friction" "$PAYLOAD"
    af_outcome "$(jq -cn --argjson code "$AF_HTTP_CODE" '{status:"spooled",reason:("server_error_"+($code|tostring))}')"
    ;;
esac
af_backlog_warning
