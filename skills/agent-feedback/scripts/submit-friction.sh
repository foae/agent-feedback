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
# --stdin takes a single JSON object — no shell-quoting of prose. Allowed keys:
#   category, summary (required), details, suggested_fix, project, harness,
#   model, machine, context (object of extra string pairs). Anything else is
#   rejected locally (the server is strict).
#
# Every submission is auto-enriched with a "context" object (occurred_at, cwd,
# git repo/branch/commit, os, session id, ...) — see af_collect_context in
# _common.sh. The agent supplies nothing; a "context" object in --stdin input
# merges on top of the auto-collected one.
# --dry-run builds and validates the payload, prints it, and exits without
#   sending ({"status":"valid"} outcome).
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
#   {"status":"valid"} (dry-run)
# Exit 0 for submitted/duplicate/spooled/valid; 1 for rejected/invalid input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

CATEGORY="" SUMMARY="" DETAILS="" FIX="" PROJECT="" HARNESS="" MODEL="" MACHINE=""
EXTRA_CONTEXT="{}"
STDIN_MODE=0 DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --category)      CATEGORY="${2:-}"; shift 2 ;;
    --summary)       SUMMARY="${2:-}"; shift 2 ;;
    --details)       DETAILS="${2:-}"; shift 2 ;;
    --suggested-fix) FIX="${2:-}"; shift 2 ;;
    --project)       PROJECT="${2:-}"; shift 2 ;;
    --harness)       HARNESS="${2:-}"; shift 2 ;;
    --model)         MODEL="${2:-}"; shift 2 ;;
    --stdin)         STDIN_MODE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) af_die "unknown flag: $1 (see header for usage)" ;;
  esac
done

af_require_deps

if [ "$STDIN_MODE" = 1 ]; then
  STDIN_JSON=$(cat)
  jq -e 'type == "object"' <<<"$STDIN_JSON" >/dev/null 2>&1 \
    || { af_outcome '{"status":"rejected","message":"--stdin input is not a JSON object"}'; exit 1; }
  UNKNOWN=$(jq -r '[keys[] | select(. as $k | ["category","summary","details","suggested_fix","project","harness","model","machine","context"] | index($k) | not)] | join(",")' <<<"$STDIN_JSON")
  if [ -n "$UNKNOWN" ]; then
    af_outcome "$(jq -cn --arg k "$UNKNOWN" '{status:"rejected",message:("unknown keys in --stdin input: "+$k)}')"
    exit 1
  fi
  # Flags (if any) override stdin values; stdin overrides auto-detection.
  [ -n "$CATEGORY" ] || CATEGORY=$(jq -r '.category // ""' <<<"$STDIN_JSON")
  [ -n "$SUMMARY" ]  || SUMMARY=$(jq -r '.summary // ""' <<<"$STDIN_JSON")
  [ -n "$DETAILS" ]  || DETAILS=$(jq -r '.details // ""' <<<"$STDIN_JSON")
  [ -n "$FIX" ]      || FIX=$(jq -r '.suggested_fix // ""' <<<"$STDIN_JSON")
  [ -n "$PROJECT" ]  || PROJECT=$(jq -r '.project // ""' <<<"$STDIN_JSON")
  [ -n "$HARNESS" ]  || HARNESS=$(jq -r '.harness // ""' <<<"$STDIN_JSON")
  [ -n "$MODEL" ]    || MODEL=$(jq -r '.model // ""' <<<"$STDIN_JSON")
  [ -n "$MACHINE" ]  || MACHINE=$(jq -r '.machine // ""' <<<"$STDIN_JSON")
  EXTRA_CONTEXT=$(jq -c '.context // {}' <<<"$STDIN_JSON")
  jq -e 'type == "object" and (to_entries | all(.value | type == "string"))' <<<"$EXTRA_CONTEXT" >/dev/null 2>&1 \
    || { af_outcome '{"status":"rejected","message":"context must be an object of string values"}'; exit 1; }
fi

if [ -z "$CATEGORY" ] || [ -z "$SUMMARY" ]; then
  af_outcome '{"status":"rejected","message":"--category and --summary are required"}'
  exit 1
fi
[ -n "$HARNESS" ] || HARNESS=$(af_detect_harness)
[ -n "$PROJECT" ] || PROJECT=$(af_detect_project)
[ -n "$MODEL" ]   || MODEL=$(af_detect_model)
[ -n "$MACHINE" ] || MACHINE=$(af_machine)

# Soft nudge, never a gate: a suggested_fix claiming the fix was already
# applied should name the commit. Two of ~20 "Applied" claims in the
# 2026-08-17 triage were false — one had no commit anywhere, one existed only
# as an uncommitted working-tree change — and both would have been caught at
# submission time by asking for the SHA. Warning only: sometimes the claim is
# honest but uncommitted (say so in the text), or the commit comes later.
if printf '%s' "$FIX" | grep -qiE '\b(applied|fixed|corrected)\b' \
   && ! printf '%s' "$FIX" | grep -qE '\b[0-9a-f]{7,40}\b' \
   && ! printf '%s' "$FIX" | grep -qiE '\b(will be|being|to be|not yet|pending|uncommitted|planned)\b'; then
  af_warn "suggested-fix claims a fix was applied but names no commit SHA — include it (git log -1 --format=%h), or state explicitly that the change is uncommitted/pending"
fi

# Auto-collected context; agent-provided context keys (stdin) win per-key.
CONTEXT_JSON=$(jq -cn --argjson auto "$(af_collect_context)" --argjson extra "$EXTRA_CONTEXT" '$auto + $extra')

PAYLOAD=$(mktemp)
trap 'rm -f "$PAYLOAD" "${AF_RESP:-}"' EXIT
jq -n \
  --arg machine "$MACHINE" --arg model "$MODEL" \
  --arg category "$CATEGORY" --arg summary "$SUMMARY" \
  --arg details "$DETAILS" --arg fix "$FIX" \
  --arg project "$PROJECT" --arg harness "$HARNESS" \
  --argjson context "$CONTEXT_JSON" \
  '{machine_name: $machine, coordinator_model: $model,
    category: $category, summary: $summary}
   + (if $details != "" then {details: $details} else {} end)
   + (if $fix     != "" then {suggested_fix: $fix} else {} end)
   + (if $project != "" then {project: $project} else {} end)
   + (if $harness != "" then {harness: $harness} else {} end)
   + {context: $context}' >"$PAYLOAD"

if [ "$DRY_RUN" = 1 ]; then
  cat "$PAYLOAD"
  af_outcome '{"status":"valid"}'
  exit 0
fi

af_require_key
af_flush_spool

af_request POST "/api/v1/frictions" "$PAYLOAD"
case "$AF_HTTP_CODE" in
  201|200)
    if af_friction_response_valid "$AF_RESP"; then
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
