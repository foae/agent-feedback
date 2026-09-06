---
name: agent-feedback
description: Submit and query centralized agent telemetry — multi-model review timings/scorecards and friction reports — against the agent-feedback service (Go/Postgres). Use when submitting a friction report per the system prompt's Surface Friction directive, when querying review/friction data, or when processing submissions (list unprocessed, mark done). Review runs normally submit themselves — score-review.sh auto-submits when the last reviewer is scored.
license: MIT
compatibility: Any harness that can run bash. Requires curl + jq and AGENT_FEEDBACK_URL + AGENT_FEEDBACK_API_KEY in the environment.
metadata:
  author: foae
  version: "2.1"
---

# agent-feedback

Client for the centralized telemetry service (`agent-feedback`: Go + Postgres).
The canonical source of this skill AND the API contract is the `agent-feedback`
repo — this skill lives there under `skills/agent-feedback/`, next to
`docs/agent-usage.md`.

Two kinds of data live in the service:

- **Review runs** — one record per `/multi-llm-review` or `/second-opinion`
  run: per-reviewer timings, status, and the scorecard (score/valid/invalid/
  note). Raw prompts/outputs are omitted by default.
- **Frictions** — what slowed an agent down (see the Surface Friction
  directive in the global system prompt), for triage into better tooling/docs.

An async feedback processor consumes submissions and marks them `processed`.
As a working agent you only **report**; you never need to read before writing —
the server absorbs duplicates itself.

## Installation

Copy this directory (`SKILL.md` + `scripts/`) into your harness's skills
location (e.g. `~/.claude/skills/agent-feedback/` for Claude Code, or your
shared skills directory), then set the environment (below). Nothing to build;
the scripts need only `bash`, `curl`, and `jq`.

Fleet-wide sync/distribution of this skill is handled outside this repo.

## Environment

```
AGENT_FEEDBACK_API_KEY      required for every call (ask the operator)
AGENT_FEEDBACK_URL          required for API calls — your service endpoint; no default
AGENT_FEEDBACK_MACHINE      optional — canonical machine name; defaults to `hostname -s`.
                            Set it where the hostname is not the canonical name.
AGENT_FEEDBACK_HARNESS      optional — overrides harness auto-detection
AGENT_FEEDBACK_MODEL        optional — overrides coordinator-model detection
AGENT_FEEDBACK_SESSION_ID   optional — overrides session-id detection
```

## Harness support

The scripts are harness-agnostic: any harness that can run bash can use them.
Attribution works in two tiers:

1. **Overrides (exact)** — set `AGENT_FEEDBACK_HARNESS` / `AGENT_FEEDBACK_MODEL`
   / `AGENT_FEEDBACK_SESSION_ID` in a harness's profile or session hook and
   attribution is guaranteed, including for harnesses that don't exist yet.
2. **Auto-detection (best effort)** — markers verified from each harness's own
   code: Claude Code (`CLAUDECODE`), opencode (`OPENCODE`), pi
   (`PI_CODING_AGENT`), omp (`PI_CODING_AGENT_DIR`/`OMP_PROFILE`), codex
   (`CODEX_SANDBOX`). Nested launches (e.g. a review runner starting pi from a
   Claude Code session) attribute to the **inner** harness — the one actually
   reporting. Profile-exported API keys (`OPENCODE_API_KEY`, `CODEX_API_KEY`)
   are ignored on purpose: they leak into every session and prove nothing.

No harness exports its **model** to child processes — that's why `--model`
should always be passed explicitly (or `AGENT_FEEDBACK_MODEL` set per profile).

## Machine-readable outcomes

Every submit/process command prints, as its **last stdout line**, a one-line
JSON outcome — relay it to the user verbatim:

```
{"status":"submitted","id":36}      stored as a new record
{"status":"duplicate","id":36}      server absorbed an identical duplicate — fine
{"status":"spooled","reason":"..."} service unreachable; will auto-retry later
{"status":"mismatch",...}           review replay differs from the stored record (409)
{"status":"rejected",...}           payload bug — do NOT retry as-is
{"status":"valid"}                  --dry-run passed
```

Exit codes are honest: 0 for submitted/duplicate/spooled/valid, 1 for
rejected/mismatch/collision.

## Scripts

All paths below are relative to this skill's directory.

### submit-friction.sh — file a friction report

Flags mode:

```bash
bash scripts/submit-friction.sh \
  --category documentation \
  --summary "README's VLAN note contradicts live routing" \
  --details "README says outbound WAN-only, but the service is reachable (verified)" \
  --suggested-fix "correct the VLAN paragraph in the README" \
  --model claude-fable-5
```

Stdin mode — **prefer this for prose** (no shell-quoting; a heredoc carries
newlines, quotes, and hyphens untouched):

```bash
bash scripts/submit-friction.sh --stdin <<'JSON'
{
  "category": "tooling",
  "summary": "functions.bash depends on missing hypa",
  "details": "The bash tool runs hypa and exits 127, while hypa_shell works.",
  "suggested_fix": "install hypa in the base image or fix the tool wrapper",
  "model": "claude-fable-5"
}
JSON
```

- `--category` and `--summary` are required.
- **Always pass `--model` (or `"model"` in stdin JSON) with your own model id**
  — you know it from your system prompt; `unknown` rows are useless for
  analytics. `--harness`/`--project`/`--machine` are auto-detected.
- **Context is collected for you.** Every submission carries a `context`
  object built automatically: `occurred_at`, `cwd`, `repo_root`, `git_remote`
  (credentials stripped), `git_branch`, `git_commit`, `git_dirty`, `os`,
  `arch`, `session_id`, `agent`, `effort`, `client_version` — whatever is
  available. You add nothing; an optional `"context"` object in stdin JSON
  merges extra string pairs on top. Context never affects duplicate detection.
- `--dry-run` builds + validates the payload and prints it without sending.
- **Retries are safe.** The server absorbs identical-content duplicates for
  24 h, so transport failures and 5xx are spooled and auto-retried; a manual
  re-run after an ambiguous failure is also fine. `{"status":"duplicate"}`
  means it was already there — success, not an error.
- **If your suggested-fix says "applied"/"fixed", name the commit SHA** in it
  (`git log -1 --format=%h`), or state explicitly that the change is
  uncommitted/pending. The script warns when an applied-claim carries no SHA:
  2 of ~20 such claims in the 2026-08-17 triage were false — one had no
  commit anywhere, one existed only as an uncommitted working-tree change
  that a `git pull` would have destroyed.

### Fixed something? Close its queue row at fix time, not triage time

When a session fixes a defect that a friction report may already cover, check
the queue and mark the row as part of the fix — don't leave it for the next
triage run to rediscover:

```bash
bash scripts/process.sh list --type friction --limit 500 | grep -i '<keyword>'
bash scripts/process.sh done <id>    # then name the id in the fix commit body
```

The 2026-08-17 triage spent a full validation batch re-verifying five fixes
(lxcfs guard, pi MCP-hang defenses, zellij keybinds, statusline OAuth token
renewal, OrbStack watchdog) that ordinary sessions had landed days earlier
without touching the queue. Naming the friction id in the commit body is the
fallback the friction-triage skill's commit cross-check reads; marking the
row at fix time makes the whole re-discovery class disappear. (If the user's
standing rules require approval before state changes, ask alongside the fix
itself — one question, not a leftover row.)

### submit-review.sh — (re)submit a review run

External review runners can invoke this after grading or use `--sweep` to recover
failed submissions. The runner and scoring tools are not bundled with this skill.
Manual uses:

```bash
# Resubmit a specific run (idempotent — identical replay returns the record):
bash scripts/submit-review.sh ~/.cache/multi-llm-review/<run_ts>-<pid>

# Include the full prompt + raw reviewer outputs (off by default):
bash scripts/submit-review.sh <run_dir> --include-outputs

# Recovery pass (spool flush + fully-scored-but-unsubmitted runs):
bash scripts/submit-review.sh --sweep
```

A `{"status":"mismatch"}` (HTTP 409) outcome means this run dir's content
differs from what the service already stored under that run_id — the server
never overwrites. Surface it; a correction must be a new submission.
`--include-outputs` after a default auto-submit will 409 for exactly this
reason: the enriched payload differs from the stored one.

Run dirs without `meta.json` predate the integration and are skipped. Both direct
submission and sweep require a grade for every completed reviewer; blank optional
finding counts remain absent. Runs sharing a timestamp are refused because the
external timestamp-keyed ledger cannot disambiguate their grades. Resolve the
ledger at its source rather than borrowing sibling scores. Attribution always
comes from the run's `meta.json.caller`, including delayed direct submissions.

Legacy server rows without payload hashes return the stored record on replay
without comparing content. Use a new run ID for corrections. Scores are external
coordinator judgments, not independently verified benchmarks.

### process.sh — the feedback processor's tooling

```bash
# What's waiting? (unprocessed submissions, compact TSV: id/type/machine/category/summary)
bash scripts/process.sh list
bash scripts/process.sh list --type friction --json

# Acted on them → mark processed (batch, idempotent):
bash scripts/process.sh done 43 44 45
# → {"processed":true,"updated":[43,44,45],"unchanged":[],"not_found":[]}

# Marked the wrong one:
bash scripts/process.sh undo 44
```

### query.sh — read data back

```bash
bash scripts/query.sh --type multi-llm-review --limit 20
bash scripts/query.sh --type friction --processed false
bash scripts/query.sh 43 | jq .payload
```

Raw JSON out. List rows include friction `category`/`summary`/`project`/
`harness` and `processed_at`; fetch by id for the full payload. All values are
URL-encoded properly (`+02:00` offsets are safe). Read-only — pass `--flush`
to also flush the write spool.

## Failure behavior (all scripts)

- Service unreachable → payloads spool to `~/.cache/agent-feedback/spool/` and
  auto-retry on the next submit/flush call. Reviews retry for up to 30 d;
  frictions for up to 20 h (inside the server's 24 h dedupe window — past it,
  the spooled friction is dropped with a loud warning naming its summary:
  re-file it if still relevant).
- Every script prints a spool-backlog warning (stderr) when unsent payloads
  exist — surface that line to the user, it is the only signal the service is
  down.
- `{"status":"rejected"}` (4xx) → the server names the offending field; a
  payload/contract bug to report, not a retry case.
- The scripts never print the API key.
- Authentication headers use an owner-only temporary file, not curl arguments.
- Invalid successful friction receipts are retained for retry, not acknowledged.
- Rejected spool files emit backlog warnings and expire after 30 days.
- Automatically collected remote URLs remove userinfo, query strings, fragments
  and SCP usernames. Explicit context and report prose remain your responsibility;
  preview them and never include secrets.
