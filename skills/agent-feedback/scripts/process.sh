#!/usr/bin/env bash
# Process agent-feedback submissions from any machine: list what's unprocessed,
# mark submissions processed (with what was done) after acting on them, undo
# mistakes.
#
# Usage:
#   process.sh list [--family F] [--type T] [--machine M] [--include-processed]
#                   [--limit N] [--json]
#   process.sh done <id> [<id>...] [--resolution "what was done"]
#   process.sh undo <id> [<id>...]     # clear the processed mark
#
# `list` shows ONLY unprocessed submissions (processed=false) unless
# --include-processed is given, and fetches EVERY page: it follows the server's
# next_before_id cursor until has_more is false, so the output is the whole
# queue, not one page of it. --limit N caps the total number of rows returned.
# The server's total for the filter is printed to stderr as "total: N".
# Default output is one TSV line per submission:
#   id  family  type  machine  category-or-run_id  summary
# --json prints one merged object: {"submissions":[...all pages...],"total":N}
#
# `done`/`undo` print the server's classification verbatim as the outcome:
#   {"processed":true,"resolution":"...","updated":[43],"unchanged":[],"not_found":[999]}
# One --resolution applies to the whole batch; run one command per distinct
# resolution. Exit 1 when the server rejects the request or is unreachable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

AF_PAGE_SIZE=500

usage() {
  echo "usage: process.sh list [--family F] [--type T] [--machine M] [--include-processed] [--limit N] [--json]" >&2
  echo "       process.sh done <id> [<id>...] [--resolution \"what was done\"]" >&2
  echo "       process.sh undo <id> [<id>...]" >&2
  exit 1
}

af_require_deps
af_require_key

set_processed() { # <true|false> <id...> [--resolution TEXT]
  local processed="$1"; shift
  local resolution="" have_resolution=0
  local -a ids=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --resolution) resolution="${2:-}"; have_resolution=1; shift 2 ;;
      -*) usage ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ "${#ids[@]}" -gt 0 ] || usage
  if [ "$have_resolution" = 1 ]; then
    [ "$processed" = true ] || af_die "--resolution is only valid with 'done' (the server rejects it when unmarking)"
    resolution=$(af_trim "$resolution")
    [ -n "$resolution" ] || af_reject "--resolution must not be blank"
    af_check_summary "resolution" "$resolution"
  fi

  local id ids_json="[]"
  for id in "${ids[@]}"; do
    [[ "$id" =~ ^[0-9]+$ ]] || af_die "not a numeric submission id: $id"
    ids_json=$(jq -cn --argjson acc "$ids_json" --argjson id "$id" '$acc + [$id]')
  done

  local payload
  payload=$(mktemp)
  # ${payload:-}: payload is local — by the time the EXIT trap fires it is out
  # of scope, and set -u would abort the exit path on a bare "$payload".
  trap 'rm -f "${payload:-}" "${AF_RESP:-}"' EXIT
  jq -cn --argjson ids "$ids_json" --argjson p "$processed" \
    --arg resolution "$resolution" --argjson have "$have_resolution" \
    '{ids: $ids, processed: $p}
     + (if $have == 1 then {resolution: $resolution} else {} end)' >"$payload"

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
  local as_json=0 include_processed=0 limit=0
  local -a FILTERS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --family)  FILTERS+=(--data-urlencode "family=${2:-}"); shift 2 ;;
      --type)    FILTERS+=(--data-urlencode "type=${2:-}"); shift 2 ;;
      --machine) FILTERS+=(--data-urlencode "machine=${2:-}"); shift 2 ;;
      --limit)
        limit="${2:-0}"
        [[ "$limit" =~ ^[0-9]+$ ]] || af_die "--limit must be a non-negative integer"
        shift 2 ;;
      --include-processed) include_processed=1; shift ;;
      --all) af_die "--all was replaced by --include-processed (list defaults to unprocessed only)" ;;
      --json) as_json=1; shift ;;
      *) usage ;;
    esac
  done
  [ "$include_processed" = 1 ] || FILTERS+=(--data-urlencode "processed=false")

  local work rows total=0 before_id="" page_limit fetched=0
  work=$(mktemp -d) || af_die "could not create a temporary directory"
  trap 'rm -rf "${work:-}"; rm -f "${AF_RESP:-}"' EXIT
  rows="$work/rows.ndjson"
  : >"$rows"

  # Keyset pagination: follow next_before_id until the server says there is
  # nothing older. One page is never the queue.
  while :; do
    page_limit="$AF_PAGE_SIZE"
    if [ "$limit" -gt 0 ]; then
      local remaining=$((limit - fetched))
      [ "$remaining" -gt 0 ] || break
      [ "$remaining" -lt "$page_limit" ] && page_limit="$remaining"
    fi
    local -a PARAMS=("${FILTERS[@]}" --data-urlencode "limit=$page_limit")
    [ -n "$before_id" ] && PARAMS+=(--data-urlencode "before_id=$before_id")
    af_request_get "/api/v1/submissions" "${PARAMS[@]}"
    if [ "$AF_HTTP_CODE" = 000 ]; then
      af_die "service unreachable (curl exit $AF_CURL_EXIT) at $AF_URL"
    elif [ "$AF_HTTP_CODE" != 200 ]; then
      af_warn "HTTP $AF_HTTP_CODE: $(head -c 400 "$AF_RESP")"
      exit 1
    fi
    jq -c '.submissions[]?' "$AF_RESP" >>"$rows"
    total=$(jq -r '.total // 0' "$AF_RESP")
    fetched=$(wc -l <"$rows" | tr -d ' ')
    local has_more next
    has_more=$(jq -r 'if .has_more then "1" else "0" end' "$AF_RESP")
    next=$(jq -r '.next_before_id // empty' "$AF_RESP")
    rm -f "$AF_RESP"
    [ "$has_more" = 1 ] || break
    [ -n "$next" ] || break
    before_id="$next"
  done

  if [ "$as_json" = 1 ]; then
    jq -sc --argjson total "$total" '{submissions: ., total: $total}' "$rows"
  else
    jq -r '[
        .id, (.family // "-"), .submission_type, .machine_name,
        (.category // .run_id // "-"),
        ((.summary // "-") | gsub("[\\n\\t]"; " ") | .[0:160])
      ] | @tsv' "$rows"
  fi
  echo "total: $total" >&2
}

case "${1:-}" in
  list) shift; list_cmd "$@" ;;
  done) shift; set_processed true "$@" ;;
  undo) shift; set_processed false "$@" ;;
  *) usage ;;
esac
