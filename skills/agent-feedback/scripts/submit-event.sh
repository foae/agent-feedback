#!/usr/bin/env bash
# Submit a generic write-once event to the agent-feedback service: a free-form
# JSON payload under a producer-chosen (kind, key). Nothing in the service
# interprets the payload.
#
# Usage:
#   submit-event.sh --kind K [--key KEY] [--model M] [--machine NAME] \
#                   (--payload-file F | --stdin) [--dry-run]
#
# The payload is the JSON object read from --payload-file or stdin; it is sent
# BYTE-FOR-BYTE verbatim: it is validated with jq but never re-serialised by
# it, so number spelling (1.0, 1e0, 12345678901234567890) and key order reach
# the server untouched. Duplicate keys are the server's business (400).
# Size: the assembled request body must stay under 10 MiB, as the server's
# limit does.
#   --kind    producer namespace, e.g. deploy, benchmark. "friction" is
#             reserved: file those with submit-friction.sh.
#   --key     idempotency key within the kind. Defaults to
#             <machine>-<UTC yyyymmdd-HHMMSS>-<pid>. Uniqueness is
#             (kind, key) service-wide, so keep the machine name in it.
#   --model   coordinator model; falls back to AGENT_FEEDBACK_MODEL et al.
#   --machine canonical machine name; falls back to AGENT_FEEDBACK_MACHINE.
#   --dry-run build and validate the payload, print it, send nothing.
#
# Retry semantics match reviews: (kind, key) is idempotent, an identical replay
# returns the stored record (200) and changed content under the same key is
# refused (409), so transport failures and 5xx responses are SPOOLED and
# retried for 30 days.
# The last stdout line is always a machine-readable outcome:
#   {"status":"submitted","id":N,"key":"..."} | {"status":"duplicate","id":N,"key":"..."}
#   {"status":"spooled","key":"...","reason":"..."} | {"status":"mismatch","key":"...","message":"..."}
#   {"status":"rejected",...} | {"status":"failed","reason":"spool_unwritable",...}
#   {"status":"valid"} (dry-run)
# Exit 0 for submitted/duplicate/spooled/valid; 1 for rejected/mismatch/failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

KIND="" KEY="" MODEL="" MACHINE="" PAYLOAD_SRC="" STDIN_MODE=0 DRY_RUN=0

af_require_deps

WORKDIR=$(mktemp -d) || af_die "could not create a temporary directory"
trap 'rm -rf "$WORKDIR"; rm -f "${AF_RESP:-}"' EXIT

# A flag whose value is missing is a usage error, not an empty value: `shift 2`
# with one argument left fails, and under `set -e` the script would die without
# its outcome line.
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)         [ $# -ge 2 ] || af_reject "$1 requires a value"; KIND="$2"; shift 2 ;;
    --key)          [ $# -ge 2 ] || af_reject "$1 requires a value"; KEY="$2"; shift 2 ;;
    --model)        [ $# -ge 2 ] || af_reject "$1 requires a value"; MODEL="$2"; shift 2 ;;
    --machine)      [ $# -ge 2 ] || af_reject "$1 requires a value"; MACHINE="$2"; shift 2 ;;
    --payload-file) [ $# -ge 2 ] || af_reject "$1 requires a value"; PAYLOAD_SRC="$2"; shift 2 ;;
    --stdin)        STDIN_MODE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) af_reject "unknown flag: $1 (see header for usage)" ;;
  esac
done

BODY="$WORKDIR/body.json"
if [ "$STDIN_MODE" = 1 ] && [ -n "$PAYLOAD_SRC" ]; then
  af_reject "--payload-file and --stdin are mutually exclusive"
elif [ "$STDIN_MODE" = 1 ]; then
  cat >"$BODY"
elif [ -n "$PAYLOAD_SRC" ]; then
  [ -f "$PAYLOAD_SRC" ] || af_reject "not a file: $PAYLOAD_SRC"
  cp "$PAYLOAD_SRC" "$BODY"
else
  af_reject "one of --payload-file or --stdin is required (see header for usage)"
fi

jq -e 'type == "object"' "$BODY" >/dev/null 2>&1 \
  || af_reject "event payload must be a single JSON object"
# jq accepts a concatenated stream of documents; exactly one is required, or the
# envelope below would splice several values after "payload":.
BODY_DOCS=$(jq -c . "$BODY" 2>/dev/null | wc -l | tr -d ' ')
[ "$BODY_DOCS" = 1 ] \
  || af_reject "event payload must be a single JSON object (got $BODY_DOCS JSON documents)"

[ -n "$MODEL" ]   || MODEL=$(af_detect_model)
[ -n "$MACHINE" ] || MACHINE=$(af_machine)

KIND=$(af_trim "$KIND")
KEY=$(af_trim "$KEY")
MACHINE=$(af_trim "$MACHINE")
MODEL=$(af_trim "$MODEL")

af_check_required "--kind" "$KIND"
[ "$KIND" != "friction" ] || af_reject "kind \"friction\" is reserved — use submit-friction.sh"
[ -n "$KEY" ] || KEY="$MACHINE-$(date -u +%Y%m%d-%H%M%S)-$$"
af_check_required "machine_name" "$MACHINE"
af_check_required "--model" "$MODEL"
af_check_identifier "kind" "$KIND"
af_check_identifier "key" "$KEY"
af_check_identifier "machine_name" "$MACHINE"
af_check_identifier "coordinator_model" "$MODEL"

# The envelope is built without the payload, then the payload's bytes are
# spliced in by string assembly. Round-tripping it through jq would re-spell
# numbers and reorder keys, and the server stores what it receives.
PAYLOAD="$WORKDIR/payload.json"
ENVELOPE=$(jq -cn --arg kind "$KIND" --arg key "$KEY" \
  --arg machine "$MACHINE" --arg model "$MODEL" \
  '{kind: $kind, key: $key, machine_name: $machine, coordinator_model: $model}')
{ printf '%s,"payload":' "${ENVELOPE%\}}"; cat "$BODY"; printf '}\n'; } >"$PAYLOAD"

PAYLOAD_BYTES=$(wc -c <"$PAYLOAD" | tr -d ' ')
[ "$PAYLOAD_BYTES" -le "$AF_MAX_BODY_BYTES" ] \
  || af_reject "event request body is $PAYLOAD_BYTES bytes, over the ${AF_MAX_BODY_BYTES}-byte limit"

if [ "$DRY_RUN" = 1 ]; then
  cat "$PAYLOAD"
  echo
  af_outcome '{"status":"valid"}'
  exit 0
fi

af_require_key
af_flush_spool

af_request POST "/api/v1/events" "$PAYLOAD"
case "$AF_HTTP_CODE" in
  201|200)
    # Trust a 2xx only when the returned record is OUR event: positive integer
    # id, our family/kind, our key and machine.
    if af_event_response_valid "$AF_RESP" "$PAYLOAD"; then
      if [ "$AF_HTTP_CODE" = 201 ]; then
        af_outcome "$(jq -c --arg key "$KEY" '{status:"submitted",id:.id,key:$key}' "$AF_RESP")"
      else
        af_outcome "$(jq -c --arg key "$KEY" '{status:"duplicate",id:.id,key:$key}' "$AF_RESP")"
      fi
    elif af_identity_comparable "$AF_RESP" && ! af_event_identity_ok "$AF_RESP" "$PAYLOAD"; then
      # Only a receipt that parses, carries an id and names a DIFFERENT record
      # is a collision. Anything else proves nothing and must be retried.
      af_warn "key collision: server returned a different record for $KEY"
      af_outcome "$(jq -cn --arg key "$KEY" '{status:"collision",key:$key}')"
      exit 1
    else
      af_warn "malformed event success response — spooling for retry"
      af_spool "event" "$PAYLOAD"
      af_outcome "$(jq -cn --arg key "$KEY" '{status:"spooled",key:$key,reason:"malformed_success_response"}')"
    fi
    ;;
  000)
    af_warn "service unreachable (curl exit $AF_CURL_EXIT) — spooling"
    af_spool "event" "$PAYLOAD"
    af_outcome "$(jq -cn --arg key "$KEY" --arg r "$(af_transport_reason)" '{status:"spooled",key:$key,reason:$r}')"
    ;;
  409)
    af_outcome "$(jq -cn --arg key "$KEY" --arg msg "$(jq -r '.message // ""' "$AF_RESP" 2>/dev/null | head -c 400)" \
      '{status:"mismatch",key:$key,message:$msg}')"
    exit 1
    ;;
  1*|3*|4*)
    # 1xx/3xx: the endpoint is not the service (a redirect means the URL is
    # misconfigured). Retrying that for 30 days is wrong — reject it now, with
    # the status, so the configuration gets fixed.
    af_outcome "$(jq -cn --arg key "$KEY" --argjson code "$AF_HTTP_CODE" --arg msg "$(jq -r '.message // ""' "$AF_RESP" 2>/dev/null | head -c 400)" \
      '{status:"rejected",key:$key,http_status:$code,message:$msg}')"
    exit 1
    ;;
  *)
    af_warn "server error $AF_HTTP_CODE — spooling for retry (idempotent)"
    af_spool "event" "$PAYLOAD"
    af_outcome "$(jq -cn --arg key "$KEY" --argjson code "$AF_HTTP_CODE" '{status:"spooled",key:$key,reason:("server_error_"+($code|tostring))}')"
    ;;
esac
af_backlog_warning
