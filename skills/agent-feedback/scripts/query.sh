#!/usr/bin/env bash
# Read submissions back from the agent-feedback service. Raw JSON on stdout —
# pipe to jq. READ-ONLY by default: does not touch the write spool unless
# --flush is passed.
#
# Usage:
#   query.sh [--type T] [--machine M] [--model M] [--since RFC3339] \
#            [--until RFC3339] [--processed true|false] [--limit N] \
#            [--offset N] [--flush]                     # filtered list
#   query.sh <id>                                       # full record
#
# Values are URL-encoded properly — timestamps with +02:00 offsets, spaces,
# and & are all safe.
#
# Examples:
#   query.sh --type multi-llm-review --limit 20
#   query.sh --type friction --processed false
#   query.sh 43 | jq .payload
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

af_require_deps
af_require_key

FLUSH=0
declare -a PARAMS=()

if [ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
  PATH_Q="/api/v1/submissions/$1"
else
  PATH_Q="/api/v1/submissions"
  add() { PARAMS+=(--data-urlencode "$1=$2"); }
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)      add type "${2:-}"; shift 2 ;;
      --machine)   add machine "${2:-}"; shift 2 ;;
      --model)     add model "${2:-}"; shift 2 ;;
      --since)     add since "${2:-}"; shift 2 ;;
      --until)     add until "${2:-}"; shift 2 ;;
      --processed)
        case "${2:-}" in true|false) ;; *) af_die "--processed must be true or false" ;; esac
        add processed "$2"; shift 2 ;;
      --limit)     add limit "${2:-}"; shift 2 ;;
      --offset)    add offset "${2:-}"; shift 2 ;;
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
