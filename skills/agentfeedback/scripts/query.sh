#!/usr/bin/env bash
# Read submissions back from the AgentFeedback service. Raw JSON on stdout —
# pipe to jq. READ-ONLY by default: does not touch the write spool unless
# --flush is passed.
#
# Usage:
#   query.sh [--family F] [--type T] [--machine M] [--model M] \
#            [--since RFC3339] [--until RFC3339] [--processed true|false] \
#            [--limit N] [--before-id N] [--offset N] [--include-payload] \
#            [--flush]                                  # filtered list
#   query.sh <id>                                       # full record
#   query.sh export [--family F] [--since RFC3339]      # NDJSON stream
#
# Values are URL-encoded properly — timestamps with +02:00 offsets, spaces,
# and & are all safe.
#
# Paging: --before-id N is the keyset cursor (rows with id < N); the response's
# next_before_id feeds the next call while has_more is true. --offset is the
# older style and cannot be combined with --before-id (the server rejects it).
# --include-payload returns full records instead of scannable summaries.
#
# `export` writes every record as newline-delimited JSON to stdout: a header
# line, one record per line, then the terminator carrying the record count and
# their SHA-256. STDOUT STAYS PURE NDJSON so it can be redirected to a backup
# file — the verification result ("export verified: N record(s)") and every
# warning go to stderr, never stdout. The header line, the count and the digest
# are all verified once the stream has been received; a damaged stream is still
# printed but the exit status is 1. Never restore from a stream that exited 1.
# A transport failure or an HTTP error prints nothing on stdout except a single
# {"status":"error","message":"..."} outcome line, and exits 1.
#
# Examples:
#   query.sh --type review-panel --limit 20
#   query.sh --family friction --processed false
#   query.sh 43 | jq .payload
#   query.sh export >backup.ndjson
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

af_require_deps
af_require_key

af_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else printf ''; fi
}

# Temp paths are script-global: an EXIT trap cannot see a function's locals
# (they are already out of scope when it fires), so function-local paths leak
# their files into $TMPDIR.
AF_EXPORT_RAW=""
AF_EXPORT_BODY=""
AF_EXPORT_HEADER=""
export_cleanup() {
  rm -f "${AF_EXPORT_RAW:-}" "${AF_EXPORT_BODY:-}" "${AF_EXPORT_HEADER:-}" 2>/dev/null || true
}

# export_verify_failed <message> — a verification failure. STDOUT is the NDJSON
# stream and must stay pure, so both the human line and the machine-readable
# outcome go to stderr; the caller turns the non-zero return into exit 1.
export_verify_failed() {
  af_warn "$1"
  jq -cn --arg m "$1" '{status:"error",message:$m}' >&2
  return 1
}

export_cmd() {
  local -a PARAMS=()
  local filtered=0
  # `shift 2` with a single argument left fails; inside `export_cmd "$@" || …`
  # `set -e` is disabled, so the loop would spin forever on the same flag.
  while [ $# -gt 0 ]; do
    case "$1" in
      --family) [ $# -ge 2 ] || af_reject "$1 requires a value"
                PARAMS+=(--data-urlencode "family=$2"); filtered=1; shift 2 ;;
      --since)  [ $# -ge 2 ] || af_reject "$1 requires a value"
                PARAMS+=(--data-urlencode "since=$2"); filtered=1; shift 2 ;;
      *) af_reject "unknown flag for export: $1 (see header for usage)" ;;
    esac
  done

  local code rc=0
  AF_EXPORT_HEADER=$(af_auth_header_file) || af_error "could not create the protected curl header file"
  AF_EXPORT_RAW=$(mktemp)
  trap 'export_cleanup' EXIT
  # curl never runs in a pipeline here: under `set -o pipefail` a downstream
  # failure would be reported as curl's, and PIPESTATUS gymnastics hide the
  # HTTP status. No -m cap either — a full export is as long as the database.
  code=$(curl -sS --fail-with-body --connect-timeout 5 -o "$AF_EXPORT_RAW" \
    -w '%{http_code}' -H "@$AF_EXPORT_HEADER" --get \
    ${PARAMS[@]+"${PARAMS[@]}"} "$AF_URL/api/v1/export" 2>/dev/null) || rc=$?
  rm -f "$AF_EXPORT_HEADER"; AF_EXPORT_HEADER=""
  [ -n "$code" ] || code=000
  if [ "$code" = 000 ]; then
    af_error "export failed: service unreachable (curl exit $rc) at $AF_URL"
  fi
  if [ "$code" != 200 ]; then
    af_error "export failed: HTTP $code: $(head -c 300 "$AF_EXPORT_RAW" | tr -d '\n')"
  fi
  # A 200 with a non-zero curl exit is a transfer that died mid-stream (the
  # status line arrived, the body did not): the file on disk is a truncated
  # export, never a backup.
  if [ "$rc" != 0 ]; then
    af_error "export failed: the transfer did not complete (curl exit $rc) despite HTTP 200"
  fi

  # Pure NDJSON on stdout; everything below reports to stderr only. A failed
  # write (full disk, closed pipe) must not be followed by "export verified".
  cat "$AF_EXPORT_RAW" || { export_verify_failed "export could not be written to stdout"; return 1; }

  local lines first last count records digest want_digest
  lines=$(wc -l <"$AF_EXPORT_RAW" | tr -d ' ')
  first=$(head -n1 "$AF_EXPORT_RAW")
  last=$(tail -n1 "$AF_EXPORT_RAW")
  if ! jq -e 'select(type == "object") | .export_format == 1' <<<"$first" >/dev/null 2>&1; then
    export_verify_failed "export does not start with an {\"export_format\":1,...} header — this is not an export stream; do NOT treat it as a backup"
    return 1
  fi
  # No --family/--since was asked for, so the header must report neither. A
  # filtered header on an unfiltered request means the stream is a subset of
  # the database — restoring from it would silently lose the rest.
  if [ "$filtered" = 0 ] \
     && ! jq -e '(.family == null) and (.since == null)' <<<"$first" >/dev/null 2>&1; then
    export_verify_failed "export header reports a filtered export"
    return 1
  fi
  if ! jq -e 'select(type == "object") | .export_complete == true' <<<"$last" >/dev/null 2>&1; then
    export_verify_failed "export is missing its {\"export_complete\":true,...} terminator — the stream is truncated; do NOT treat it as a backup"
    return 1
  fi
  count=$(jq -r '.count // empty' <<<"$last")
  want_digest=$(jq -r '.sha256 // empty' <<<"$last")
  # Line 1 is the export header, the last line the terminator; everything
  # between them is a record. An empty export is exactly those two lines.
  records=$((lines - 2))
  [ "$records" -ge 0 ] || records=0
  if [ "$records" != "$count" ]; then
    export_verify_failed "export terminator claims ${count:-no} record(s) but $records were received — the stream is damaged; do NOT treat it as a backup"
    return 1
  fi
  if [ -z "$want_digest" ]; then
    export_verify_failed "export terminator carries no sha256 — the stream cannot be verified; do NOT treat it as a backup"
    return 1
  fi
  AF_EXPORT_BODY=$(mktemp)
  if [ "$records" -gt 0 ]; then
    sed -n "2,$((lines - 1))p" "$AF_EXPORT_RAW" >"$AF_EXPORT_BODY"
  else
    : >"$AF_EXPORT_BODY"
  fi
  digest=$(af_sha256 "$AF_EXPORT_BODY")
  if [ -z "$digest" ]; then
    export_verify_failed "no sha256sum/shasum available — the export digest CANNOT be verified; do NOT treat it as a backup"
    return 1
  fi
  if [ "$digest" != "$want_digest" ]; then
    export_verify_failed "export digest mismatch: terminator says $want_digest, received records hash to $digest — do NOT treat it as a backup"
    return 1
  fi
  af_warn "export verified: $count record(s)"
  return 0
}

if [ "${1:-}" = "export" ]; then
  shift
  rc=0
  export_cmd "$@" || rc=$?
  export_cleanup
  exit "$rc"
fi

FLUSH=0
declare -a PARAMS=()

if [ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
  PATH_Q="/api/v1/submissions/$1"
else
  PATH_Q="/api/v1/submissions"
  add() { PARAMS+=(--data-urlencode "$1=$2"); }
  # A flag whose value is missing is a usage error: `shift 2` with one argument
  # left fails, and a filter silently dropped would return the wrong rows.
  while [ $# -gt 0 ]; do
    case "$1" in
      --family)    [ $# -ge 2 ] || af_reject "$1 requires a value"; add family "$2"; shift 2 ;;
      --type)      [ $# -ge 2 ] || af_reject "$1 requires a value"; add type "$2"; shift 2 ;;
      --machine)   [ $# -ge 2 ] || af_reject "$1 requires a value"; add machine "$2"; shift 2 ;;
      --model)     [ $# -ge 2 ] || af_reject "$1 requires a value"; add model "$2"; shift 2 ;;
      --since)     [ $# -ge 2 ] || af_reject "$1 requires a value"; add since "$2"; shift 2 ;;
      --until)     [ $# -ge 2 ] || af_reject "$1 requires a value"; add until "$2"; shift 2 ;;
      --processed)
        [ $# -ge 2 ] || af_reject "$1 requires a value"
        case "$2" in true|false) ;; *) af_reject "--processed must be true or false" ;; esac
        add processed "$2"; shift 2 ;;
      --limit)     [ $# -ge 2 ] || af_reject "$1 requires a value"; add limit "$2"; shift 2 ;;
      --before-id) [ $# -ge 2 ] || af_reject "$1 requires a value"; add before_id "$2"; shift 2 ;;
      --offset)    [ $# -ge 2 ] || af_reject "$1 requires a value"; add offset "$2"; shift 2 ;;
      --include-payload) add include payload; shift ;;
      --flush)     FLUSH=1; shift ;;
      *) af_reject "unknown flag: $1 (see header for usage)" ;;
    esac
  done
fi

[ "$FLUSH" = 1 ] && af_flush_spool

af_request_get "$PATH_Q" ${PARAMS[@]+"${PARAMS[@]}"}
trap 'rm -f "${AF_RESP:-}"' EXIT

if [ "$AF_HTTP_CODE" = 200 ]; then
  cat "$AF_RESP"; echo
elif [ "$AF_HTTP_CODE" = 000 ]; then
  af_error "service unreachable (curl exit $AF_CURL_EXIT) at $AF_URL"
else
  af_error "HTTP $AF_HTTP_CODE: $(head -c 400 "$AF_RESP" | tr -d '\n')"
fi
af_backlog_warning
