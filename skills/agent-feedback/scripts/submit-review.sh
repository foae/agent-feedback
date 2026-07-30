#!/usr/bin/env bash
# Submit a completed review run (multi-llm-review / second-opinion) to the
# agent-feedback service — timings + scorecard by default, raw outputs only
# with --include-outputs.
#
# Usage:
#   submit-review.sh <run_dir> [--include-outputs]
#   submit-review.sh --sweep
#
# <run_dir> is a runner run dir (~/.cache/<skill>/<run_ts>-<pid>/) holding
# meta.json (written by review-runner.sh), summary.tsv, and — beside it in the
# cache base — scorecards.tsv. Dirs without meta.json predate this integration
# and are skipped.
#
# Called automatically by _lib/score-review.sh when a run's last PENDING row is
# filled, and by review-runner.sh at end-of-run as `--sweep`. Safe to call by
# hand: POST /api/v1/reviews is idempotent on (skill, run_id) — an identical
# replay returns the existing record (200); changed content under the same
# run_id is refused with 409 (the stored record is never silently replaced).
#
# The last stdout line per submission is a machine-readable outcome:
#   {"status":"submitted","id":N,"run_id":"..."}
#   {"status":"duplicate","id":N,"run_id":"..."}   (identical replay)
#   {"status":"spooled","run_id":"...","reason":"..."}
#   {"status":"mismatch","run_id":"...","message":"..."}   (409 — content differs)
#   {"status":"collision","run_id":"..."}          (server returned another record)
#   {"status":"rejected","run_id":"...","http_status":N,"message":"..."}
# Direct mode exits 1 on rejected/mismatch/collision; sweep always exits 0.
#
# --sweep (single instance per machine, mkdir lock):
#   1. flush the spool;
#   2. submit every run dir that is FULLY SCORED (zero PENDING rows for its
#      run_ts) but has no .submitted marker — the recovery path for
#      auto-submits that failed or died.
#   Sweep NEVER submits a run with PENDING rows: the 12h scoring grace is a
#   heuristic, a session can legitimately score at hour 13, and a score-less
#   submission would permanently occupy the write-once (skill, run_id) key.
#   Abandoned runs stay local-only (timings.tsv keeps their timings).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

SWEEP_LOCK="$AF_CACHE/sweep.lock"
SWEEP_LOCK_STALE_SECS=600
# Sweep ignores run dirs younger than this: fresh runs are the auto-submit
# hook's job, and a sibling runner mid-run has a dir whose summary.tsv holds
# only the header — submitting that would 400 on the empty reviewers array.
SWEEP_MIN_AGE_HOURS=2

usage() {
  echo "usage: submit-review.sh <run_dir> [--include-outputs]" >&2
  echo "       submit-review.sh --sweep" >&2
  exit 1
}

# ── Payload construction ─────────────────────────────────────────────────────

# build_payload <run_dir> <include_outputs 0|1> <mode direct|sweep> → payload file path
build_payload() {
  local run_dir="$1" include_outputs="$2" mode="$3"
  local meta="$run_dir/meta.json"
  [ -f "$meta" ] || { af_warn "no meta.json in $run_dir (predates integration) — skipping"; return 1; }
  [ -s "$run_dir/summary.tsv" ] || { af_warn "no summary.tsv in $run_dir — skipping"; return 1; }

  local machine skill run_ts run_id
  machine=$(jq -r '.machine' "$meta")
  skill=$(jq -r '.skill' "$meta")
  run_ts=$(jq -r '.run_ts' "$meta")
  run_id="$machine-$(basename "$run_dir")"

  # Coordinator attribution: a direct call may carry the live session's model;
  # sweep must NOT stamp the sweeping session's env onto historical runs.
  local coordinator
  if [ "$mode" = direct ] && [ -n "${REVIEW_CALLER_MODEL:-}" ]; then
    coordinator="$REVIEW_CALLER_MODEL"
  else
    coordinator=$(jq -r '.caller // "unknown"' "$meta")
  fi

  # Scorecard rows for this run_ts: label -> score/valid/invalid/note (skip
  # PENDING). The label→slot join is exact, via meta.json's slot map.
  local ledger scores_json
  ledger="$(dirname "$run_dir")/scorecards.tsv"
  scores_json="[]"
  if [ -f "$ledger" ]; then
    scores_json=$(awk -F'\t' -v ts="$run_ts" \
      '$1 == ts && $4 != "PENDING" && $4 != "" { print }' "$ledger" \
      | jq -Rs 'split("\n") | map(select(length > 0) | split("\t") |
          {label: .[2], score: (.[3] | tonumber? ), valid: (.[4] | tonumber?),
           invalid: (.[5] | tonumber?), note: .[6]})')
  fi

  # Reviewers from summary.tsv (slot, model, status, duration_s, bytes).
  local reviewers_json="[]" slot model status dur bytes out_file output_arg
  while IFS=$'\t' read -r slot model status dur bytes; do
    [ -n "$slot" ] || continue
    output_arg=null
    if [ "$include_outputs" = 1 ]; then
      out_file="$run_dir/$slot.md"
      [ -s "$out_file" ] && output_arg=$(jq -Rs . <"$out_file")
    fi
    reviewers_json=$(jq -n \
      --argjson acc "$reviewers_json" \
      --arg slot "$slot" --arg model "$model" --arg status "$status" \
      --arg dur "$dur" --arg bytes "$bytes" --argjson output "$output_arg" \
      --argjson scores "$scores_json" \
      --slurpfile meta "$meta" \
      '($meta[0].slots[$slot].label // "") as $label
       | ($scores | map(select($label != "" and .label == $label)) | first) as $sc
       | $acc + [
           {slot: $slot, model: $model, status: $status}
           + (if $dur   != "" then {duration_s: ($dur | tonumber)} else {} end)
           + (if $bytes != "" then {bytes: ($bytes | tonumber)} else {} end)
           + (if $output != null then {output: $output} else {} end)
           + (if $sc != null then
                ({}
                 + (if $sc.score   != null then {score: $sc.score} else {} end)
                 + (if $sc.valid   != null then {valid: $sc.valid} else {} end)
                 + (if $sc.invalid != null then {invalid: $sc.invalid} else {} end)
                 + (if ($sc.note // "") != "" then {note: $sc.note} else {} end))
              else {} end)
         ]')
  done < <(tail -n +2 "$run_dir/summary.tsv")

  [ "$(jq 'length' <<<"$reviewers_json")" -gt 0 ] \
    || { af_warn "no reviewer rows in $run_dir/summary.tsv — nothing to submit"; return 1; }

  local prompt_arg=null
  if [ "$include_outputs" = 1 ] && [ -s "$run_dir/prompt.md" ]; then
    prompt_arg=$(jq -Rs . <"$run_dir/prompt.md")
  fi

  local payload
  payload=$(mktemp)
  jq -n \
    --arg skill "$skill" --arg machine "$machine" \
    --arg coordinator "$coordinator" --arg run_id "$run_id" \
    --argjson prompt "$prompt_arg" --argjson reviewers "$reviewers_json" \
    '{skill: $skill, machine_name: $machine, coordinator_model: $coordinator,
      run_id: $run_id, reviewers: $reviewers}
     + (if $prompt != null then {prompt: $prompt} else {} end)' >"$payload"
  printf '%s\n' "$payload"
}

# submit_run <run_dir> <include_outputs> <mode> — POST + outcome handling.
# Returns 0 on submitted/duplicate/spooled/skipped, 1 on rejected/mismatch/collision.
submit_run() {
  local run_dir="$1" include_outputs="$2" mode="$3"
  local payload run_id rc=0
  payload=$(build_payload "$run_dir" "$include_outputs" "$mode") || return 0
  run_id=$(jq -r '.run_id' "$payload")

  af_request POST "/api/v1/reviews" "$payload"
  case "$AF_HTTP_CODE" in
    201)
      jq -r '.id' "$AF_RESP" >"$run_dir/.submitted"
      af_outcome "$(jq -c --arg run_id "$run_id" '{status:"submitted",id:.id,run_id:$run_id}' "$AF_RESP")"
      ;;
    200)
      # Identical replay — trust it only if it is OUR record.
      if [ "$(jq -r '.run_id + "|" + .machine_name' "$AF_RESP")" = "$run_id|$(jq -r '.machine_name' "$payload")" ]; then
        jq -r '.id' "$AF_RESP" >"$run_dir/.submitted"
        af_outcome "$(jq -c --arg run_id "$run_id" '{status:"duplicate",id:.id,run_id:$run_id}' "$AF_RESP")"
      else
        af_warn "run_id collision: server returned a different record for $run_id — NOT marking submitted"
        af_outcome "$(jq -cn --arg run_id "$run_id" '{status:"collision",run_id:$run_id}')"
        rc=1
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

sweep() {
  mkdir -p "$AF_CACHE"
  if ! mkdir "$SWEEP_LOCK" 2>/dev/null; then
    local born now
    born=$(cat "$SWEEP_LOCK/born" 2>/dev/null || echo 0)
    case "$born" in ""|*[!0-9]*) born=0 ;; esac
    now=$(date +%s)
    if [ "$born" -gt 0 ] && [ $((now - born)) -ge "$SWEEP_LOCK_STALE_SECS" ]; then
      rm -rf "$SWEEP_LOCK"; mkdir "$SWEEP_LOCK" 2>/dev/null || exit 0
    else
      exit 0   # another sweep is live — this one is redundant
    fi
  fi
  date +%s >"$SWEEP_LOCK/born" 2>/dev/null || true
  trap 'rm -rf "$SWEEP_LOCK"' EXIT

  af_flush_spool

  local cutoff
  cutoff=$(date -d "$SWEEP_MIN_AGE_HOURS hours ago" +%Y%m%d-%H%M%S 2>/dev/null \
    || date -v-"${SWEEP_MIN_AGE_HOURS}"H +%Y%m%d-%H%M%S 2>/dev/null || echo "")

  local base run_dir run_ts pending
  for base in "${REVIEW_LOG_DIR:-$HOME/.cache/multi-llm-review}" "$HOME/.cache/second-opinion"; do
    [ -d "$base" ] || continue
    for run_dir in "$base"/*/; do
      run_dir="${run_dir%/}"
      [ -f "$run_dir/meta.json" ] || continue
      [ -f "$run_dir/.submitted" ] && continue
      run_ts=$(jq -r '.run_ts' "$run_dir/meta.json")
      # run_ts is fixed-width zero-padded: string compare IS chronological.
      [ -n "$cutoff" ] && [ "$run_ts" \> "$cutoff" ] && continue
      pending=0
      [ -f "$base/scorecards.tsv" ] && pending=$(awk -F'\t' -v ts="$run_ts" \
        '$1 == ts && $4 == "PENDING" { n++ } END { print n + 0 }' "$base/scorecards.tsv")
      [ "$pending" -eq 0 ] || continue   # never submit a run with PENDING rows
      submit_run "$run_dir" 0 sweep || true   # sweep is best-effort; outcomes are printed per run
    done
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────

af_require_deps

case "${1:-}" in
  --sweep)
    af_require_key
    sweep
    ;;
  ""|--help|-h)
    usage
    ;;
  *)
    RUN_DIR="${1%/}"
    [ -d "$RUN_DIR" ] || af_die "not a directory: $RUN_DIR"
    INCLUDE_OUTPUTS=0
    [ "${2:-}" = "--include-outputs" ] && INCLUDE_OUTPUTS=1
    af_require_key
    af_flush_spool
    rc=0
    submit_run "$RUN_DIR" "$INCLUDE_OUTPUTS" direct || rc=$?
    af_backlog_warning
    exit "$rc"
    ;;
esac
