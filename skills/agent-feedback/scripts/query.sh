#!/usr/bin/env bash
# Read submissions back from the agent-feedback service. Raw JSON on stdout —
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
# `export` streams every record as newline-delimited JSON to stdout: a header
# line, one record per line, then the terminator carrying the record count and
# their SHA-256. Both are verified after the stream ends; a missing or
# disagreeing terminator means the stream is damaged — what was received is
# still printed, and the exit status is 1. Never restore from a stream that
# exited 1.
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

export_cmd() {
  local -a PARAMS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --family) PARAMS+=(--data-urlencode "family=${2:-}"); shift 2 ;;
      --since)  PARAMS+=(--data-urlencode "since=${2:-}"); shift 2 ;;
      *) af_die "unknown flag for export: $1 (see header for usage)" ;;
    esac
  done

  local header raw rc=0
  header=$(af_auth_header_file)
  raw=$(mktemp)
  trap 'rm -f "${raw:-}" "${header:-}"' EXIT
  # No -m cap: a full export is as long as the database is big. The stream is
  # printed as it arrives and copied for verification.
  curl -sS --fail --connect-timeout 5 -H "@$header" --get "${PARAMS[@]}" \
    "$AF_URL/api/v1/export" | tee "$raw"
  rc="${PIPESTATUS[0]}"
  rm -f "$header"
  if [ "$rc" != 0 ]; then
    af_warn "export stream failed (curl exit $rc) — the output above is INCOMPLETE"
    return 1
  fi

  local lines last count records digest want_digest
  lines=$(wc -l <"$raw" | tr -d ' ')
  last=$(tail -n1 "$raw")
  if ! jq -e 'select(type == "object") | .export_complete == true' <<<"$last" >/dev/null 2>&1; then
    af_warn "export is missing its {\"export_complete\":true,...} terminator — the stream is truncated; do NOT treat it as a backup"
    return 1
  fi
  count=$(jq -r '.count // empty' <<<"$last")
  want_digest=$(jq -r '.sha256 // empty' <<<"$last")
  # Line 1 is the export header, the last line the terminator; everything
  # between them is a record.
  records=$((lines - 2))
  [ "$records" -ge 0 ] || records=0
  if [ "$records" != "$count" ]; then
    af_warn "export terminator claims $count record(s) but $records were received — the stream is damaged; do NOT treat it as a backup"
    return 1
  fi
  if [ -n "$want_digest" ]; then
    local body
    body=$(mktemp)
    sed -n "2,$((lines - 1))p" "$raw" >"$body"
    digest=$(af_sha256 "$body")
    rm -f "$body"
    if [ -z "$digest" ]; then
      af_warn "no sha256sum/shasum available — export digest NOT verified (count checked: $count records)"
    elif [ "$digest" != "$want_digest" ]; then
      af_warn "export digest mismatch: terminator says $want_digest, received records hash to $digest — do NOT treat it as a backup"
      return 1
    fi
  fi
  af_warn "export verified: $count record(s)"
  return 0
}

if [ "${1:-}" = "export" ]; then
  shift
  export_cmd "$@"
  exit $?
fi

FLUSH=0
declare -a PARAMS=()

if [ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
  PATH_Q="/api/v1/submissions/$1"
else
  PATH_Q="/api/v1/submissions"
  add() { PARAMS+=(--data-urlencode "$1=$2"); }
  while [ $# -gt 0 ]; do
    case "$1" in
      --family)    add family "${2:-}"; shift 2 ;;
      --type)      add type "${2:-}"; shift 2 ;;
      --machine)   add machine "${2:-}"; shift 2 ;;
      --model)     add model "${2:-}"; shift 2 ;;
      --since)     add since "${2:-}"; shift 2 ;;
      --until)     add until "${2:-}"; shift 2 ;;
      --processed)
        case "${2:-}" in true|false) ;; *) af_die "--processed must be true or false" ;; esac
        add processed "$2"; shift 2 ;;
      --limit)     add limit "${2:-}"; shift 2 ;;
      --before-id) add before_id "${2:-}"; shift 2 ;;
      --offset)    add offset "${2:-}"; shift 2 ;;
      --include-payload) add include payload; shift ;;
      --flush)     FLUSH=1; shift ;;
      *) af_die "unknown flag: $1 (see header for usage)" ;;
    esac
  done
fi

[ "$FLUSH" = 1 ] && af_flush_spool

if [ ${#PARAMS[@]} -gt 0 ]; then
  af_request_get "$PATH_Q" "${PARAMS[@]}"
else
  af_request_get "$PATH_Q"
fi
trap 'rm -f "${AF_RESP:-}"' EXIT

if [ "$AF_HTTP_CODE" = 200 ]; then
  cat "$AF_RESP"; echo
elif [ "$AF_HTTP_CODE" = 000 ]; then
  af_die "service unreachable (curl exit $AF_CURL_EXIT) at $AF_URL"
else
  af_warn "HTTP $AF_HTTP_CODE: $(head -c 400 "$AF_RESP")"
  exit 1
fi
af_backlog_warning
