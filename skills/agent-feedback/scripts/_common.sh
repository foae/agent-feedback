#!/usr/bin/env bash
# Shared helpers for the agent-feedback skill scripts. SOURCED, not executed.
#
# Env contract (only the key is per-machine state):
#   AGENT_FEEDBACK_URL         optional — defaults to the production service
#   AGENT_FEEDBACK_API_KEY     required for every /api/v1/* call
#   AGENT_FEEDBACK_MACHINE     optional — canonical machine name; falls back to
#                              `hostname -s`. Set it where the hostname is not
#                              the canonical name.
#   AGENT_FEEDBACK_HARNESS     optional — overrides harness auto-detection
#   AGENT_FEEDBACK_MODEL       optional — overrides coordinator-model detection
#   AGENT_FEEDBACK_SESSION_ID  optional — overrides session-id detection
# The three overrides make attribution exact from ANY harness: set them in the
# harness's profile/hook and detection below never matters.
#
# Spool: ~/.cache/agent-feedback/spool/ — one JSON payload per file.
#   review-*    retry-safe forever: the API is idempotent on (skill, run_id)
#               and rejects changed content with 409, so replays never corrupt.
#   friction-*  retry-safe within the server's 24h content-dedupe window: an
#               identical friction re-POSTed inside the window is absorbed
#               (200 + existing row). Spooled frictions older than 20h are
#               dropped loudly rather than risk a duplicate past the window.
#   *.inflight  claimed by a flusher (claim-by-rename). A crashed flusher's
#               .inflight stays eligible on the next flush; a concurrent
#               double-send is harmless for BOTH types now — the server
#               dedupes — so no per-type retry ceremony remains.
#   *.rejected  got a 4xx/409 back — a payload/content bug, kept for inspection.

AF_URL="${AGENT_FEEDBACK_URL:?Set AGENT_FEEDBACK_URL to your service endpoint}"
AF_KEY="${AGENT_FEEDBACK_API_KEY:-}"
AF_CACHE="$HOME/.cache/agent-feedback"
AF_SPOOL="$AF_CACHE/spool"
AF_REVIEW_MAX_AGE_DAYS=30
AF_FRICTION_MAX_AGE_MINS=1200   # 20h — safely inside the server's 24h dedupe window
AF_CLIENT_VERSION="2.1"

af_machine() { printf '%s' "${AGENT_FEEDBACK_MACHINE:-$(hostname -s)}"; }

af_die() { echo "agent-feedback: $*" >&2; exit 1; }
af_warn() { echo "agent-feedback: $*" >&2; }

# Machine-readable outcome: ALWAYS the last stdout line of a submit/process
# call. Agents relay it verbatim. Statuses: submitted, duplicate, spooled,
# rejected, mismatch, collision, valid.
af_outcome() { printf '%s\n' "$1"; }

af_require_deps() {
  command -v curl >/dev/null || af_die "curl not found"
  command -v jq >/dev/null || af_die "jq not found"
}

af_require_key() {
  [ -n "$AF_KEY" ] && return 0
  af_die "AGENT_FEEDBACK_API_KEY is not set — export it in your shell profile (ask the operator for the key)"
}

# af_request <METHOD> <path> [payload-file]
# Short timeouts on purpose: this runs in the caller's foreground (the
# score-review.sh auto-submit hook), so a dead service must cost ~2s, not 30.
# Sets: AF_HTTP_CODE (000 on transport failure), AF_CURL_EXIT, AF_RESP (body file).
af_request() {
  local method="$1" path="$2" payload="${3:-}"
  AF_RESP=$(mktemp)
  local -a args=(-sS -m 10 --connect-timeout 2 -o "$AF_RESP" -w '%{http_code}' \
    -H "Authorization: Bearer $AF_KEY" -X "$method")
  [ -n "$payload" ] && args+=(-H "Content-Type: application/json" --data-binary "@$payload")
  AF_CURL_EXIT=0
  AF_HTTP_CODE=$(curl "${args[@]}" "$AF_URL$path" 2>/dev/null) || AF_CURL_EXIT=$?
  [ -n "$AF_HTTP_CODE" ] || AF_HTTP_CODE=000
  return 0
}

# af_request_get <path> [--data-urlencode k=v ...]
# GET with proper URL encoding of every query value (curl --get).
af_request_get() {
  local path="$1"; shift
  AF_RESP=$(mktemp)
  AF_CURL_EXIT=0
  AF_HTTP_CODE=$(curl -sS -m 10 --connect-timeout 2 -o "$AF_RESP" -w '%{http_code}' \
    -H "Authorization: Bearer $AF_KEY" --get "$@" "$AF_URL$path" 2>/dev/null) || AF_CURL_EXIT=$?
  [ -n "$AF_HTTP_CODE" ] || AF_HTTP_CODE=000
  return 0
}

# af_transport_reason — human-stable reason string for the last failure.
af_transport_reason() {
  case "$AF_CURL_EXIT" in
    6) printf 'resolve_failed' ;;
    7) printf 'connect_failed' ;;
    28) printf 'timeout' ;;
    *) printf 'transport_error_%s' "$AF_CURL_EXIT" ;;
  esac
}

# af_spool <prefix> <payload-file> — atomic landing (tmp + mv).
af_spool() {
  local prefix="$1" payload="$2" name
  mkdir -p "$AF_SPOOL"
  name="$prefix-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM.json"
  cp "$payload" "$AF_SPOOL/.tmp.$name" && mv "$AF_SPOOL/.tmp.$name" "$AF_SPOOL/$name"
  af_warn "payload spooled to $AF_SPOOL/$name (will retry on the next submit/flush call)"
}

# One-line human-visible signal that the service has been unreachable.
af_backlog_warning() {
  [ -d "$AF_SPOOL" ] || return 0
  local n
  n=$(find "$AF_SPOOL" -maxdepth 1 \( -name '*.json' -o -name '*.inflight' \) 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && af_warn "spool backlog: $n unsent submission(s) in $AF_SPOOL — the service has been unreachable"
  return 0
}

# af_prune_spool — age out entries instead of growing forever. Covers BOTH
# *.json and *.inflight (an interrupted claim must not survive pruning).
af_prune_spool() {
  [ -d "$AF_SPOOL" ] || return 0
  local old summary
  find "$AF_SPOOL" -maxdepth 1 \( -name 'review-*.json' -o -name 'review-*.inflight' \) \
      -mtime +"$AF_REVIEW_MAX_AGE_DAYS" -print 2>/dev/null | while read -r old; do
    af_warn "dropping spooled review older than ${AF_REVIEW_MAX_AGE_DAYS}d: $(basename "$old")"
    rm -f "$old"
  done
  # Frictions past the dedupe window can no longer be retried safely (a
  # maybe-delivered original would duplicate) — drop loudly with the summary
  # so a human/agent can re-file if it still matters.
  find "$AF_SPOOL" -maxdepth 1 \( -name 'friction-*.json' -o -name 'friction-*.inflight' \) \
      -mmin +"$AF_FRICTION_MAX_AGE_MINS" -print 2>/dev/null | while read -r old; do
    summary=$(jq -r '.summary // "?"' "$old" 2>/dev/null | head -c 120)
    af_warn "dropping spooled friction older than 20h (past the server dedupe window): $(basename "$old") — summary was: $summary — re-file it if still relevant"
    rm -f "$old"
  done
}

# Flush spooled payloads. Claim-by-rename before POSTing; delete on success.
# Both types are retry-safe (see header), so .json and .inflight are both
# eligible and failure paths just leave the file .inflight for the next flush.
af_flush_spool() {
  [ -d "$AF_SPOOL" ] || return 0
  af_prune_spool

  local f claimed endpoint prefix
  for f in "$AF_SPOOL"/review-*.json "$AF_SPOOL"/review-*.inflight \
           "$AF_SPOOL"/friction-*.json "$AF_SPOOL"/friction-*.inflight; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      review-*) endpoint="/api/v1/reviews"; prefix=review ;;
      friction-*) endpoint="/api/v1/frictions"; prefix=friction ;;
    esac
    claimed="${f%.json}"; claimed="${claimed%.inflight}.inflight"
    if [ "$f" != "$claimed" ]; then
      mv "$f" "$claimed" 2>/dev/null || continue   # another flusher claimed it
    fi
    af_request POST "$endpoint" "$claimed"
    if [ "$AF_HTTP_CODE" = 201 ] || [ "$AF_HTTP_CODE" = 200 ]; then
      if [ "$prefix" = review ]; then
        # Trust a 200/201 only if it is OUR record (post-409-API this should
        # always hold; the check guards against a legacy no-hash row).
        local want got
        want=$(jq -r '.run_id + "|" + .machine_name' "$claimed" 2>/dev/null)
        got=$(jq -r '(.run_id // "") + "|" + .machine_name' "$AF_RESP" 2>/dev/null)
        if [ "$want" != "$got" ]; then
          mv "$claimed" "${claimed%.inflight}.rejected" 2>/dev/null || true
          af_warn "spooled $(basename "$claimed") answered with a different record ($got) — kept as .rejected"
          rm -f "$AF_RESP"
          continue
        fi
      fi
      rm -f "$claimed"
      af_warn "flushed spooled $(basename "$claimed")"
    elif [ "$AF_HTTP_CODE" = 000 ]; then
      # Still unreachable; stays .inflight, re-eligible next flush. Stop:
      # every remaining file would eat the same timeout for the same result.
      rm -f "$AF_RESP"
      af_warn "service unreachable — deferring remaining spool to the next flush"
      break
    elif [ "${AF_HTTP_CODE#4}" != "$AF_HTTP_CODE" ]; then
      mv "$claimed" "${claimed%.inflight}.rejected" 2>/dev/null || true
      af_warn "spooled $(basename "$claimed") rejected ($AF_HTTP_CODE): $(head -c 300 "$AF_RESP") — kept as .rejected"
    else
      : # 5xx: stays .inflight for the next flush (both types are retry-safe)
    fi
    rm -f "$AF_RESP"
  done
}

# Harness auto-detection. Explicit --harness / AGENT_FEEDBACK_HARNESS always
# wins. Markers verified from each harness's installed code:
#   claude-code  CLAUDECODE=1
#   opencode     OPENCODE=1
#   pi (pi.dev)  PI_CODING_AGENT=true
#   omp (omp.sh) PI_CODING_AGENT_DIR / OMP_PROFILE (a pi fork — it does NOT
#                set pi's marker, but is checked first in case that changes)
#   codex        CODEX_SANDBOX
# Non-claude markers are checked BEFORE CLAUDECODE: nested launches (e.g. the
# review runner starting pi from a Claude Code session) carry both, and the
# inner harness is the one reporting. Deliberately NO prefix sniffing (any
# OPENCODE_*/CODEX_*): API keys exported from shell profiles (OPENCODE_API_KEY,
# CODEX_API_KEY) leak into every session and would false-positive.
# PI_MODEL/OPENCODE_MODEL are legacy wrapper vars kept as a last resort.
af_detect_harness() {
  if [ -n "${AGENT_FEEDBACK_HARNESS:-}" ]; then printf '%s' "$AGENT_FEEDBACK_HARNESS"
  elif [ -n "${PI_CODING_AGENT_DIR:-}" ] || [ -n "${OMP_PROFILE:-}" ]; then printf 'omp'
  elif [ -n "${PI_CODING_AGENT:-}" ]; then printf 'pi'
  elif [ -n "${OPENCODE:-}" ]; then printf 'opencode'
  elif [ -n "${CODEX_SANDBOX:-}" ]; then printf 'codex'
  elif [ -n "${CLAUDECODE:-}" ]; then printf 'claude-code'
  elif [ -n "${PI_MODEL:-}" ]; then printf 'pi'
  elif [ -n "${OPENCODE_MODEL:-}" ]; then printf 'opencode'
  else printf 'unknown'; fi
}

# Coordinator-model auto-detection. No harness exports its model to child
# processes (verified), so SKILL.md tells agents to ALWAYS pass --model; the
# env fallbacks cover harness profiles (AGENT_FEEDBACK_MODEL) and the review
# runner's wrapper vars.
af_detect_model() {
  printf '%s' "${AGENT_FEEDBACK_MODEL:-${REVIEW_CALLER_MODEL:-${PI_MODEL:-${OPENCODE_MODEL:-unknown}}}}"
}

# Project auto-detection: git remote basename, else cwd basename.
af_detect_project() {
  local p
  p=$(git remote get-url origin 2>/dev/null | sed 's#.*/##; s#\.git$##') || true
  [ -n "$p" ] || p=$(basename "$PWD")
  printf '%s' "$p"
}

# af_collect_context — compact JSON object of auto-collected metadata. All
# best-effort: keys are omitted when unavailable, the agent supplies nothing.
# The server stores this verbatim in payload.context and EXCLUDES it from the
# dedupe hash (it varies between attempts of the same friction).
#   occurred_at     payload build time, UTC — survives spool delays, unlike the
#                   server's created_at which is receipt time
#   cwd/repo_root   where the friction happened ("folder name")
#   git_remote      origin URL, userinfo stripped (https tokens never leave)
#   git_branch/git_commit/git_dirty
#   os/arch         uname
#   session_id      AGENT_FEEDBACK_SESSION_ID override, else Claude Code's
#                   CLAUDE_CODE_SESSION_ID (verified present in that harness)
#   agent           AI_AGENT when set (harness + version, e.g. claude-code_2-1-220_agent)
#   effort          CLAUDE_EFFORT when set
#   profile         omp/pi profile name (OMP_PROFILE / PI_PROFILE) when set
#   client_version  this skill's version
af_collect_context() {
  local occurred cwd osname arch root="" remote="" branch="" commit="" dirty=""
  occurred=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cwd="$PWD"
  osname="$(uname -s) $(uname -r)"
  arch=$(uname -m)
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    remote=$(git remote get-url origin 2>/dev/null | sed 's#//[^/@]*@#//#') || true
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
    commit=$(git rev-parse --short HEAD 2>/dev/null) || true
    if [ -n "$(git status --porcelain 2>/dev/null | head -1)" ]; then dirty=true; else dirty=false; fi
  else
    root=""
  fi
  jq -cn \
    --arg occurred "$occurred" --arg cwd "$cwd" --arg os "$osname" --arg arch "$arch" \
    --arg root "$root" --arg remote "$remote" --arg branch "$branch" \
    --arg commit "$commit" --arg dirty "$dirty" \
    --arg session "${AGENT_FEEDBACK_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}" \
    --arg agent "${AI_AGENT:-}" --arg effort "${CLAUDE_EFFORT:-}" \
    --arg profile "${OMP_PROFILE:-${PI_PROFILE:-}}" \
    --arg version "$AF_CLIENT_VERSION" \
    '{occurred_at: $occurred, cwd: $cwd, os: $os, arch: $arch, client_version: $version}
     + (if $root    != "" then {repo_root: $root} else {} end)
     + (if $remote  != "" then {git_remote: $remote} else {} end)
     + (if $branch  != "" then {git_branch: $branch} else {} end)
     + (if $commit  != "" then {git_commit: $commit} else {} end)
     + (if $dirty   != "" then {git_dirty: $dirty} else {} end)
     + (if $session != "" then {session_id: $session} else {} end)
     + (if $agent   != "" then {agent: $agent} else {} end)
     + (if $effort  != "" then {effort: $effort} else {} end)
     + (if $profile != "" then {profile: $profile} else {} end)'
}
