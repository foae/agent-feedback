#!/usr/bin/env bash
# Submit a completed multi-reviewer run to the agent-feedback service —
# timings + scorecard by default, raw outputs only with --include-outputs.
#
# Usage:
#   submit-review.sh <run_dir> [--include-outputs]
#   submit-review.sh --sweep
#
# <run_dir> is a runner run dir (<base>/<run_ts>-<pid>/) holding meta.json
# (written by the review runner), summary.tsv, and — beside it in the cache
# base — scorecards.tsv. Dirs without meta.json predate this integration and
# are skipped.
#
# Called automatically by the runner's scoring hook when a run's last PENDING
# row is filled, and by the runner at end-of-run as `--sweep`. Safe to call by
# hand: POST /api/v1/reviews is idempotent on (skill, run_id) — an identical
# replay returns the existing record (200); changed content under the same
# run_id is refused with 409 (the stored record is never silently replaced).
#
# Run-dir bases swept by --sweep (no defaults; nothing is swept unless set):
#   REVIEW_LOG_DIR               the runner's own base, when exported
#   AGENT_FEEDBACK_REVIEW_DIRS   colon-separated list of additional bases
#
# The last stdout line per submission is a machine-readable outcome:
#   {"status":"submitted","id":N,"run_id":"..."}
#   {"status":"duplicate","id":N,"run_id":"..."}   (identical replay)
#   {"status":"spooled","run_id":"...","reason":"..."}
#   {"status":"mismatch","run_id":"...","message":"..."}   (409 — content differs)
#   {"status":"collision","run_id":"..."}          (server returned another record)
#   {"status":"rejected","run_id":"...","http_status":N,"message":"..."}
#   {"status":"skipped","reason":"...","run_id":"..."}   (nothing safe to send)
# Direct mode exits 1 on rejected/mismatch/collision or an unsafe incomplete
# scorecard; sweep always exits 0 and only warns per run.
#
# --sweep (single instance per machine, mkdir lock):
#   1. flush the spool;
#   2. submit every old run dir whose completed reviewers have exactly one
#      numeric grade and no .submitted marker — the recovery path for
#      auto-submits that failed or died.
#   Sweep NEVER submits an incomplete scorecard: a score-less submission would
#   permanently occupy the write-once (skill, run_id) key. Abandoned runs stay
#   local-only (timings.tsv keeps their timings).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

SWEEP_LOCK="$AF_CACHE/sweep.lock"
SWEEP_LOCK_STALE_SECS="${SWEEP_LOCK_STALE_SECS:-600}"
# Sweep ignores run dirs younger than this: fresh runs are the auto-submit
# hook's job, and a sibling runner mid-run has a dir whose summary.tsv holds
# only the header — submitting that would 400 on the empty reviewers array.
SWEEP_MIN_AGE_HOURS="${SWEEP_MIN_AGE_HOURS:-2}"

usage() {
  echo "usage: submit-review.sh <run_dir> [--include-outputs]" >&2
  echo "       submit-review.sh --sweep" >&2
  af_reject "${1:-invalid arguments (see usage above)}"
}

# build_payload communicates through globals: it is called directly (never in a
# command substitution, which would be a subshell that cannot hand a skip
# reason back) so every skip ends with an outcome line in direct mode.
AF_PAYLOAD_FILE=""
AF_SKIP_REASON=""
AF_SKIP_RUN_ID=""

# af_skip <run-id> <reason> — record why nothing was sent.
af_skip() {
  AF_SKIP_RUN_ID="$1"
  AF_SKIP_REASON="$2"
  af_warn "$1: $2 — NOT submitting"
  return 1
}

# scorecard_timestamp_ambiguous <run-dir> <run-ts> — scorecards.tsv predates
# per-run identifiers, so matching timestamp siblings have indistinguishable rows.
scorecard_timestamp_ambiguous() {
  local run_dir="$1" run_ts="$2" base self peer peer_ts
  base=$(cd "$(dirname "$run_dir")" && pwd)
  self=$(basename "$run_dir")
  for peer in "$base"/*; do
    [ -d "$peer" ] || continue
    [ -L "$peer" ] && continue   # the runner's `latest` symlink is not a peer run
    [ "$(basename "$peer")" = "$self" ] && continue
    [ -f "$peer/meta.json" ] || continue
    peer_ts=$(jq -r '.run_ts // empty' "$peer/meta.json" 2>/dev/null) || continue
    [ "$peer_ts" = "$run_ts" ] && return 0
  done
  return 1
}

# ── Payload construction ─────────────────────────────────────────────────────

# build_payload <run_dir> <include_outputs 0|1> <mode direct|sweep> → payload file path
# Reviewer outputs and the prompt can be megabytes; they are never passed
# through jq's argv (--arg is capped by the OS argument limit) and never
# accumulated in a shell variable. Everything large moves via files.
build_payload() {
  local run_dir="$1" include_outputs="$2"
  local meta="$run_dir/meta.json"
  local fallback_id; fallback_id=$(basename "$run_dir")
  AF_PAYLOAD_FILE=""
  [ -f "$meta" ] || { af_skip "$fallback_id" "no meta.json (predates integration)"; return 1; }
  [ -s "$run_dir/summary.tsv" ] || { af_skip "$fallback_id" "no summary.tsv"; return 1; }

  # Every read is checked explicitly: inside a function called in a `||` list,
  # `set -e` is disabled, so an unchecked failure would keep going silently.
  local machine skill run_ts run_id coordinator
  machine=$(jq -r '.machine // empty' "$meta" 2>/dev/null) \
    || { af_skip "$fallback_id" "unreadable meta.json"; return 1; }
  skill=$(jq -r '.skill // empty' "$meta" 2>/dev/null) \
    || { af_skip "$fallback_id" "unreadable meta.json"; return 1; }
  run_ts=$(jq -r '.run_ts // empty' "$meta" 2>/dev/null) \
    || { af_skip "$fallback_id" "unreadable meta.json"; return 1; }
  coordinator=$(jq -r '.caller // "unknown"' "$meta" 2>/dev/null) \
    || { af_skip "$fallback_id" "unreadable meta.json"; return 1; }

  # Trim what the server trims, so the receipt comparison compares the values
  # the server actually stored.
  machine=$(af_trim "$machine")
  skill=$(af_trim "$skill")
  run_ts=$(af_trim "$run_ts")
  coordinator=$(af_trim "$coordinator")
  [ -n "$coordinator" ] || coordinator="unknown"

  [ -n "$machine" ] && [ -n "$skill" ] && [ -n "$run_ts" ] \
    || { af_skip "$fallback_id" "malformed meta.json (machine/skill/run_ts missing)"; return 1; }

  run_id="$machine-$(basename "$run_dir")"

  local work
  work=$(mktemp -d) || { af_skip "$run_id" "could not create a temporary directory"; return 1; }

  # Scorecards are timestamp-keyed by the external runner. Refuse to borrow
  # rows when sibling run directories share a timestamp; their score rows
  # cannot be assigned safely without changing that external protocol.
  local ledger
  ledger="$(dirname "$run_dir")/scorecards.tsv"
  if [ -f "$ledger" ] && scorecard_timestamp_ambiguous "$run_dir" "$run_ts"; then
    rm -rf "$work"
    af_skip "$run_id" "ambiguous timestamp: multiple run directories share scorecard timestamp $run_ts"
    return 1
  fi

  local rows_f="$work/score-rows.json" scores_f="$work/scores.json"
  printf '[]' >"$rows_f"
  if [ -f "$ledger" ]; then
    if ! awk -F'\t' -v ts="$run_ts" '$1 == ts { print $0 }' "$ledger" \
      | jq -Rsc '
          def optional_number:
            if . == null or . == "" then null else try tonumber catch null end;
          split("\n")
          | map(select(length > 0)
                | capture("^(?<timestamp>[^\t]*)\t(?<source>[^\t]*)\t(?<label>[^\t]*)\t(?<score_text>[^\t]*)(?:\t(?<valid_text>[^\t]*))?(?:\t(?<invalid_text>[^\t]*))?(?:\t(?<note>.*))?$")
                | .score_text as $score
                | {label: .label,
                   score: (if $score == "" or $score == "PENDING"
                           then null else try ($score | tonumber) catch null end),
                   valid: (.valid_text | optional_number),
                   invalid: (.invalid_text | optional_number),
                   note: (.note // "")})' >"$rows_f"; then
      rm -rf "$work"
      af_skip "$run_id" "could not parse the scorecard ledger"
      return 1
    fi
  fi
  jq -c 'map(select(.score != null))' "$rows_f" >"$scores_f" \
    || { rm -rf "$work"; af_skip "$run_id" "could not parse the scorecard ledger"; return 1; }

  # Reviewers from summary.tsv (slot, model, status, duration_s, bytes).
  # Tabs are IFS whitespace, so `IFS=$'\t' read` collapses consecutive tabs and
  # loses empty fields; the separator is translated to \034 (a non-whitespace
  # IFS character) so every column keeps its position, blank or not. The
  # `|| [ -n "$slot" ]` tail keeps a final row that has no trailing newline.
  local slot model status dur bytes out_file want_output i=0
  local empty="$work/empty"; : >"$empty"
  local revdir="$work/reviewers"; mkdir -p "$revdir"
  while IFS=$'\034' read -r slot model status dur bytes || [ -n "$slot" ]; do
    [ -n "$slot" ] || continue
    # Non-numeric timings are dropped, never sent: the server would 400 on the
    # whole run because one column was garbled.
    case "$dur" in
      ''|*[!0-9.]*) [ -z "$dur" ] || { af_warn "$run_id: non-numeric duration_s \"$dur\" for slot $slot — omitting it"; dur=""; } ;;
    esac
    case "$bytes" in
      ''|*[!0-9]*) [ -z "$bytes" ] || { af_warn "$run_id: non-numeric bytes \"$bytes\" for slot $slot — omitting it"; bytes=""; } ;;
    esac
    want_output=0
    out_file="$empty"
    if [ "$include_outputs" = 1 ] && [ -s "$run_dir/$slot.md" ]; then
      out_file="$run_dir/$slot.md"
      want_output=1
    fi
    i=$((i + 1))
    jq -cn \
      --arg slot "$slot" --arg model "$model" --arg status "$status" \
      --arg dur "$dur" --arg bytes "$bytes" \
      --rawfile output "$out_file" --argjson want_output "$want_output" \
      --slurpfile scores "$scores_f" \
      --slurpfile meta "$meta" \
      '($meta[0].slots[$slot].label // "") as $label
       | ($scores[0] | map(select($label != "" and .label == $label)) | first) as $sc
       | {slot: $slot, model: $model, status: $status}
         + (if $dur   != "" then {duration_s: ($dur | tonumber)} else {} end)
         + (if $bytes != "" then {bytes: ($bytes | tonumber)} else {} end)
         + (if $want_output == 1 and $output != "" then {output: $output} else {} end)
         + (if $sc != null then
              ({}
               + (if $sc.score   != null then {score: $sc.score} else {} end)
               + (if $sc.valid   != null then {valid: $sc.valid} else {} end)
               + (if $sc.invalid != null then {invalid: $sc.invalid} else {} end)
               + (if ($sc.note // "") != "" then {note: $sc.note} else {} end))
            else {} end)' >"$revdir/$(printf '%05d' "$i").json" \
      || { rm -rf "$work"; af_skip "$run_id" "could not build the reviewer row for slot $slot"; return 1; }
  done < <(tail -n +2 "$run_dir/summary.tsv" | tr '\t' '\034')

  local reviewers_f="$work/reviewers.json"
  if [ "$i" -eq 0 ]; then
    rm -rf "$work"
    af_skip "$run_id" "no reviewer rows in summary.tsv"
    return 1
  fi
  jq -sc '.' "$revdir"/*.json >"$reviewers_f" \
    || { rm -rf "$work"; af_skip "$run_id" "could not assemble the reviewer rows"; return 1; }

  # A completed reviewer must have exactly one numeric grade. Never claim the
  # write-once run_id before the scorecard is complete enough to be trustworthy.
  local incomplete
  incomplete=$(jq -nr \
    --slurpfile reviewers "$reviewers_f" --slurpfile rows "$rows_f" \
    --slurpfile meta "$meta" '
      [
        $reviewers[0][]
        | select(.status == "completed")
        | .slot as $slot
        | ($meta[0].slots[$slot].label // "") as $label
        | ($rows[0] | map(select(.label == $label))) as $grades
        | select($label == "" or ($grades | length) != 1 or ($grades[0].score == null))
        | if $label == "" then "\($slot) (no scorecard label)"
          else "\($slot) (\($label))" end
      ]
      | join(", ")') \
    || { rm -rf "$work"; af_skip "$run_id" "could not evaluate the scorecard"; return 1; }
  if [ -n "$incomplete" ]; then
    rm -rf "$work"
    af_skip "$run_id" "incomplete scorecard for completed reviewer(s): $incomplete"
    return 1
  fi

  local prompt_file="$empty" want_prompt=0
  if [ "$include_outputs" = 1 ] && [ -s "$run_dir/prompt.md" ]; then
    prompt_file="$run_dir/prompt.md"
    want_prompt=1
  fi

  local payload
  payload=$(mktemp) || { rm -rf "$work"; af_skip "$run_id" "could not create a temporary file"; return 1; }
  if ! jq -n \
    --arg skill "$skill" --arg machine "$machine" \
    --arg coordinator "$coordinator" --arg run_id "$run_id" \
    --rawfile prompt "$prompt_file" --argjson want_prompt "$want_prompt" \
    --slurpfile reviewers "$reviewers_f" \
    '{skill: $skill, machine_name: $machine, coordinator_model: $coordinator,
      run_id: $run_id, reviewers: $reviewers[0]}
     + (if $want_prompt == 1 and $prompt != "" then {prompt: $prompt} else {} end)' >"$payload"; then
    rm -rf "$work"; rm -f "$payload"
    af_skip "$run_id" "could not build the review payload"
    return 1
  fi
  rm -rf "$work"
  AF_PAYLOAD_FILE="$payload"
  return 0
}

# submit_run <run_dir> <include_outputs> <mode> — POST + outcome handling.
# Returns 0 on submitted/duplicate/spooled/skipped, 1 on rejected/mismatch,
# collision, or an unsafe direct submission.
submit_run() {
  local run_dir="$1" include_outputs="$2" mode="$3"
  local payload run_id rc=0
  if ! build_payload "$run_dir" "$include_outputs"; then
    # Sweep keeps its per-run warning and exits 0; direct mode must still end
    # with exactly one machine-readable outcome line.
    [ "$mode" = sweep ] && return 0
    af_outcome "$(jq -cn --arg r "$AF_SKIP_REASON" --arg run_id "$AF_SKIP_RUN_ID" \
      '{status:"skipped",reason:$r,run_id:$run_id}')"
    return 1
  fi
  payload="$AF_PAYLOAD_FILE"
  run_id=$(jq -r '.run_id' "$payload")

  af_request POST "/api/v1/reviews" "$payload"
  case "$AF_HTTP_CODE" in
    201|200)
      # A 2xx is only a receipt for OUR run when the returned record proves it:
      # positive integer id, our family/skill, our run_id and machine. The
      # .submitted marker suppresses every later retry, so it is written only
      # after that check passes.
      if af_review_response_valid "$AF_RESP" "$payload"; then
        # The marker suppresses every later retry: if it cannot be written the
        # run would be re-submitted forever, so say so rather than fail silently.
        jq -r '.id' "$AF_RESP" >"$run_dir/.submitted" \
          || af_warn "could not write $run_dir/.submitted — this run will be retried by the next sweep"
        if [ "$AF_HTTP_CODE" = 201 ]; then
          af_outcome "$(jq -c --arg run_id "$run_id" '{status:"submitted",id:.id,run_id:$run_id}' "$AF_RESP")"
        else
          af_outcome "$(jq -c --arg run_id "$run_id" '{status:"duplicate",id:.id,run_id:$run_id}' "$AF_RESP")"
        fi
      elif af_identity_comparable "$AF_RESP" && ! af_review_identity_ok "$AF_RESP" "$payload"; then
        af_warn "run_id collision: server returned a different record for $run_id — NOT marking submitted"
        af_outcome "$(jq -cn --arg run_id "$run_id" '{status:"collision",run_id:$run_id}')"
        rc=1
      else
        # Right run, unusable receipt (no/!integer id, wrong family). Reviews
        # are idempotent, so retrying is safe and losing the run is not.
        af_warn "malformed review success response for $run_id — spooling for retry"
        af_spool "review-$run_id" "$payload"
        af_outcome "$(jq -cn --arg run_id "$run_id" '{status:"spooled",run_id:$run_id,reason:"malformed_success_response"}')"
      fi
      ;;
    000)
      af_warn "service unreachable (curl exit $AF_CURL_EXIT) — spooling"
      af_spool "review-$run_id" "$payload"
      af_outcome "$(jq -cn --arg run_id "$run_id" --arg r "$(af_transport_reason)" '{status:"spooled",run_id:$run_id,reason:$r}')"
      ;;
    409)
      # Content differs from the stored record. The server never overwrites —
      # this run dir's data does NOT match what was already submitted.
      af_outcome "$(jq -cn --arg run_id "$run_id" --arg msg "$(jq -r '.message // ""' "$AF_RESP" 2>/dev/null | head -c 400)" \
        '{status:"mismatch",run_id:$run_id,message:$msg}')"
      rc=1
      ;;
    5*)
      af_warn "server error $AF_HTTP_CODE — spooling for retry (idempotent)"
      af_spool "review-$run_id" "$payload"
      af_outcome "$(jq -cn --arg run_id "$run_id" --argjson code "$AF_HTTP_CODE" '{status:"spooled",run_id:$run_id,reason:("server_error_"+($code|tostring))}')"
      ;;
    *)
      af_outcome "$(jq -cn --arg run_id "$run_id" --argjson code "$AF_HTTP_CODE" --arg msg "$(jq -r '.message // ""' "$AF_RESP" 2>/dev/null | head -c 400)" \
        '{status:"rejected",run_id:$run_id,http_status:$code,message:$msg}')"
      rc=1
      ;;
  esac
  rm -f "$payload" "${AF_RESP:-}"
  return "$rc"
}

# ── Sweep ────────────────────────────────────────────────────────────────────

sweep_lock_mtime() {
  stat -c %Y "$SWEEP_LOCK" 2>/dev/null || stat -f %m "$SWEEP_LOCK" 2>/dev/null
}

sweep_lock_owner_live() {
  local owner pid
  owner=$(cat "$SWEEP_LOCK/owner" 2>/dev/null || true)
  pid="${owner%%:*}"
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  [ "$owner" != "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

sweep_lock_is_stale() {
  local born now mtime
  now=$(date +%s)
  born=$(cat "$SWEEP_LOCK/born" 2>/dev/null || true)
  case "$born" in
    *[!0-9]*|"") born="" ;;
  esac
  if [ -n "$born" ]; then
    [ $((now - born)) -ge "$SWEEP_LOCK_STALE_SECS" ]
    return
  fi
  # Old locks have no owner/born metadata. Their directory timestamp is the
  # portable fallback; if it cannot be read, retain rather than risk eviction.
  mtime=$(sweep_lock_mtime) || return 1
  case "$mtime" in *[!0-9]*|"") return 1 ;; esac
  [ $((now - mtime)) -ge "$SWEEP_LOCK_STALE_SECS" ]
}

sweep_lock_release() {
  local owner
  owner=$(cat "$SWEEP_LOCK/owner" 2>/dev/null || true)
  [ "$owner" = "${SWEEP_OWNER:-}" ] || return 0
  rm -f "$SWEEP_LOCK/born" "$SWEEP_LOCK/owner"
  rmdir "$SWEEP_LOCK" 2>/dev/null || true
}

sweep_lock_acquire() {
  local now
  if ! mkdir "$SWEEP_LOCK" 2>/dev/null; then
    # A valid, live owner wins even when its born timestamp is old. This
    # prevents a slow sweep from being evicted solely on elapsed time.
    sweep_lock_owner_live && return 1
    sweep_lock_is_stale || return 1
    # Recheck immediately before removal in case metadata arrived while the
    # first check was reading an acquiring owner's directory.
    sweep_lock_owner_live && return 1
    rm -rf "$SWEEP_LOCK" 2>/dev/null || return 1
    mkdir "$SWEEP_LOCK" 2>/dev/null || return 1
  fi
  now=$(date +%s)
  SWEEP_OWNER="$$:$now:$RANDOM"
  if ! printf '%s\n' "$SWEEP_OWNER" >"$SWEEP_LOCK/owner" \
    || ! printf '%s\n' "$now" >"$SWEEP_LOCK/born"; then
    sweep_lock_release
    return 1
  fi
  return 0
}

# sweep_bases — the configured run-dir bases, one per line. No defaults: a
# machine that does not say where its run dirs live has none to sweep.
sweep_bases() {
  local dir
  local -a parts=()
  [ -z "${REVIEW_LOG_DIR:-}" ] || printf '%s\n' "$REVIEW_LOG_DIR"
  if [ -n "${AGENT_FEEDBACK_REVIEW_DIRS:-}" ]; then
    IFS=':' read -ra parts <<<"$AGENT_FEEDBACK_REVIEW_DIRS"
    for dir in "${parts[@]}"; do
      if [ -n "$dir" ]; then printf '%s\n' "$dir"; fi
    done
  fi
  return 0
}

sweep() {
  mkdir -p "$AF_CACHE"
  sweep_lock_acquire || return 0   # another live/fresh sweep is redundant
  trap 'sweep_lock_release' EXIT

  af_flush_spool

  local bases
  bases=$(sweep_bases)
  if [ -z "$bases" ]; then
    af_warn "no review run directories configured (set AGENT_FEEDBACK_REVIEW_DIRS)"
    return 0
  fi

  local cutoff
  cutoff=$(date -d "$SWEEP_MIN_AGE_HOURS hours ago" +%Y%m%d-%H%M%S 2>/dev/null \
    || date -v-"${SWEEP_MIN_AGE_HOURS}"H +%Y%m%d-%H%M%S 2>/dev/null || echo "")

  local base run_dir run_ts
  while IFS= read -r base; do
    [ -d "$base" ] || continue
    for run_dir in "$base"/*/; do
      run_dir="${run_dir%/}"
      [ -f "$run_dir/meta.json" ] || continue
      [ -f "$run_dir/.submitted" ] && continue
      run_ts=$(jq -r '.run_ts // empty' "$run_dir/meta.json" 2>/dev/null) || run_ts=""
      # run_ts is fixed-width zero-padded: string compare IS chronological.
      [ -n "$cutoff" ] && [ "$run_ts" \> "$cutoff" ] && continue
      submit_run "$run_dir" 0 sweep || true   # sweep is best-effort; outcomes are printed per run
    done
  done <<<"$bases"
}

# ── Main ─────────────────────────────────────────────────────────────────────

af_require_deps

case "${1:-}" in
  --sweep)
    af_require_key
    sweep
    ;;
  ""|--help|-h)
    usage "a run directory or --sweep is required"
    ;;
  *)
    RUN_DIR="${1%/}"
    [ -d "$RUN_DIR" ] || af_reject "not a directory: $RUN_DIR"
    shift
    INCLUDE_OUTPUTS=0
    # A flag typo must never submit with the wrong options silently.
    while [ $# -gt 0 ]; do
      case "$1" in
        --include-outputs) INCLUDE_OUTPUTS=1; shift ;;
        *) af_reject "unknown flag: $1 (see header for usage)" ;;
      esac
    done
    af_require_key
    af_flush_spool
    rc=0
    submit_run "$RUN_DIR" "$INCLUDE_OUTPUTS" direct || rc=$?
    af_backlog_warning
    exit "$rc"
    ;;
esac
