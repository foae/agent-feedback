#!/usr/bin/env bash
# Process agent-feedback submissions from any machine: list what's unprocessed,
# mark submissions processed after acting on them, unmark mistakes.
#
# Usage:
#   process.sh list [--type T] [--machine M] [--limit N] [--all] [--json]
#   process.sh done <id> [<id>...]     # mark processed
#   process.sh undo <id> [<id>...]     # clear the processed mark
#
# `list` shows unprocessed submissions (processed=false) unless --all is given.
# Default output is one TSV line per submission:
#   id  type  machine  category-or-run_id  summary
# --json prints the raw server response instead.
#
# `done`/`undo` print the server's classification verbatim as the outcome:
#   {"processed":true,"updated":[43],"unchanged":[],"not_found":[999]}
# Exit 1 when the server rejects the request or is unreachable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

usage() {
  echo "usage: process.sh list [--type T] [--machine M] [--limit N] [--all] [--json]" >&2
  echo "       process.sh done <id> [<id>...]" >&2
  echo "       process.sh undo <id> [<id>...]" >&2
  exit 1
}

af_require_deps
af_require_key

set_processed() { # <true|false> <id...>
  local processed="$1"; shift
  [ $# -gt 0 ] || usage
  local id ids_json="[]"
  for id in "$@"; do
    [[ "$id" =~ ^[0-9]+$ ]] || af_die "not a numeric submission id: $id"
    ids_json=$(jq -cn --argjson acc "$ids_json" --argjson id "$id" '$acc + [$id]')
  done

  local payload
  payload=$(mktemp)
  # ${payload:-}: payload is local — by the time the EXIT trap fires it is out
  # of scope, and set -u would abort the exit path on a bare "$payload".
  trap 'rm -f "${payload:-}" "${AF_RESP:-}"' EXIT
  jq -cn --argjson ids "$ids_json" --argjson p "$processed" '{ids: $ids, processed: $p}' >"$payload"

  af_flush_spool
  af_request POST "/api/v1/submissions/processed" "$payload"
  if [ "$AF_HTTP_CODE" = 200 ]; then
    af_outcome "$(jq -c . "$AF_RESP")"
  elif [ "$AF_HTTP_CODE" = 000 ]; then
    af_die "service unreachable (curl exit $AF_CURL_EXIT) at $AF_URL"
  else
    af_warn "HTTP $AF_HTTP_CODE: $(head -c 400 "$AF_RESP")"
    exit 1
  fi
}

list_cmd() {
  local as_json=0 all=0
  declare -a PARAMS=(--data-urlencode "limit=50")
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)    PARAMS+=(--data-urlencode "type=${2:-}"); shift 2 ;;
      --machine) PARAMS+=(--data-urlencode "machine=${2:-}"); shift 2 ;;
      --limit)   PARAMS+=(--data-urlencode "limit=${2:-}"); shift 2 ;;
      --all)     all=1; shift ;;
      --json)    as_json=1; shift ;;
      *) usage ;;
    esac
  done
  [ "$all" = 1 ] || PARAMS+=(--data-urlencode "processed=false")

  af_request_get "/api/v1/submissions" "${PARAMS[@]}"
  trap 'rm -f "${AF_RESP:-}"' EXIT
  if [ "$AF_HTTP_CODE" = 200 ]; then
    if [ "$as_json" = 1 ]; then
      cat "$AF_RESP"; echo
    else
      jq -r '.submissions[] | [
          .id, .submission_type, .machine_name,
          (.category // .run_id // "-"),
          ((.summary // "-") | gsub("[\\n\\t]"; " ") | .[0:160])
        ] | @tsv' "$AF_RESP"
    fi
  elif [ "$AF_HTTP_CODE" = 000 ]; then
    af_die "service unreachable (curl exit $AF_CURL_EXIT) at $AF_URL"
  else
    af_warn "HTTP $AF_HTTP_CODE: $(head -c 400 "$AF_RESP")"
    exit 1
  fi
}

case "${1:-}" in
  list) shift; list_cmd "$@" ;;
  done) shift; set_processed true "$@" ;;
  undo) shift; set_processed false "$@" ;;
  *) usage ;;
esac
