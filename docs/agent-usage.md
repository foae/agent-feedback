# agent-feedback API — usage for agents

This document is for LLM agents editing skills that submit to `agent-feedback`
(`multi-llm-review`, `second-opinion`, the friction directive in `AGENTS.core.md`,
future skills). It is self-contained: read this, then write the `curl` calls. No
human-oriented framing below.

**Prefer the shipped client.** The canonical client scripts live in this repo at
[`skills/agent-feedback/`](../skills/agent-feedback/) — see its `SKILL.md`
Installation section to adopt it (sync/distribution is handled outside this
repo). They implement spooling, retry rules, and outcome reporting so producers
don't have to. Hand-roll `curl` only for a new producer the skill doesn't cover
— against the contract below.

## Base URL and auth

Two env vars, set by the operator on each machine that submits:

```
AGENT_FEEDBACK_URL=http://127.0.0.1:8090        # example local stack; set your own endpoint
AGENT_FEEDBACK_API_KEY=<shared key>             # obtain privately from your operator
```

The companion client requires an explicit URL for API calls; it has no hosted
service or default destination.

Every `/api/v1/*` request requires the key, either header works:

```
Authorization: Bearer $AGENT_FEEDBACK_API_KEY
```
or
```
X-Api-Key: $AGENT_FEEDBACK_API_KEY
```

Missing or wrong key → `401`:
```json
{"error": "unauthorized", "message": "missing or invalid API key"}
```

`GET /health` (process liveness), `GET /ready` (readiness **including a
Postgres ping**), `GET /metrics` (Prometheus) require no auth.

## Request body limits and strictness

All three POST endpoints:

- Reject unknown JSON fields with `400 {"error": "bad_request", "message": "..."}` —
  the message names the offending field. A typo'd field name is a bug, not something
  to silently drop (a dropped field plus an idempotent replay is unrecoverable
  telemetry loss).
- Reject request bodies over 10 MiB with `413 {"error": "request_too_large", "message": "request body exceeds 10 MiB"}`.
- Require exactly one JSON value; trailing values or garbage return `400`.
  The size limit includes trailing whitespace after the value.

Field length limits (400 naming the field when exceeded, e.g.
`invalid input: run_id exceeds 200 bytes`). They exist to protect the database,
not to police content — the free-text dump fields are bounded only by the 10 MiB
request cap:

| Fields | Limit |
|---|---|
| `skill`, `machine_name`, `coordinator_model`, `run_id`, `category`, `project`, `harness`, `reviewers[].slot`, `reviewers[].model`, `reviewers[].status` | 200 bytes |
| friction `summary` | 2000 bytes |
| `reviewers[].note` | 4000 bytes |
| `reviewers[]` count | 100 |
| `details`, `suggested_fix`, `prompt`, `reviewers[].output` | 10 MiB body cap only |

## Idempotency and duplicate absorption

**Reviews** (`POST /api/v1/reviews`) are idempotent on `(skill, run_id)`:

- First submission → `201`.
- Replaying **identical content** → `200` with the existing record. Safe to
  retry blindly (network failure, timeout, at-least-once cron).
- Replaying the same `(skill, run_id)` with **different content** → `409`
  `{"error": "replay_mismatch", "message": "replay mismatch: run_id already stored as submission <id> with different content; submit the correction as a new submission (new run_id)"}`.
  The stored record is never modified. A correction is a new submission under a
  new `run_id` — never a silent overwrite, never a silent discard.
- Content identity covers `machine_name`, `coordinator_model`, `prompt`, and the
  full `reviewers` array (sha256 over a canonical encoding, stored server-side).
- Legacy review rows created before payload hashing have a null hash. Replays
  return `200` with the existing row without content comparison; they cannot
  establish that your payload matches. Use a new run ID for corrections.

**Frictions** (`POST /api/v1/frictions`) have no `run_id`. Instead the server
absorbs duplicates by content:

- First submission → `201`.
- An **identical-content** friction (same `machine_name`, `coordinator_model`,
  and payload fields) submitted within a **24 h window** → `200` with the
  existing record; no new row. Blind retries and double-fires are therefore safe
  — submit and don't worry.
- The same friction re-encountered **after** the window → `201`, a new row:
  recurrence stays visible to the feedback processor.
- The `context` object does **not** participate in content identity — attempts
  of the same friction differ in timestamp/commit/cwd and must still dedupe.
- Concurrent identical creates serialize the lookup and insert in a transaction.

## Processing lifecycle

Submissions carry a single mutable field, `processed_at` (`null` until set).
An external consumer marks submissions after acting on them; no processor is
bundled with the service. Everything else about a submission is write-once.

### POST /api/v1/submissions/processed

Batch mark/unmark. Request body (strict — unknown fields rejected):

| Field | Type | Required | Notes |
|---|---|---|---|
| `ids` | int array | yes, non-empty | max 500 per request, ids must be positive |
| `processed` | bool | no | default `true`; `false` clears `processed_at` |

Success: `200`, every requested id classified:

```json
{"processed": true, "updated": [43, 44], "unchanged": [42], "not_found": [999]}
```

- `updated` — state changed by this call.
- `unchanged` — already in the requested state (marking is idempotent; the
  original `processed_at` timestamp is preserved on re-marks).
- `not_found` — no such submission.
- Classification and updates run atomically in one transaction.

Error: `400` with `{"error": "set_processed_failed", "message": "..."}` for
empty/oversized/non-positive `ids`.

curl example:

```bash
curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/submissions/processed" \
  -H "X-Api-Key: $AGENT_FEEDBACK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"ids": [43, 44]}'
```

## POST /api/v1/reviews

Submitted once, at the end of a review run, after grading. The shipped client
omits `prompt` and raw `output` by default (`--include-outputs` opts in).

Request body:

| Field | Type | Required | Notes |
|---|---|---|---|
| `skill` | string | yes | submitting skill name, e.g. `multi-llm-review`, `second-opinion`; `"friction"` is reserved (rejected — use `POST /api/v1/frictions`) |
| `machine_name` | string | yes | self-reported, e.g. `workstation-a`, `laptop-a` |
| `coordinator_model` | string | yes | e.g. `claude-fable-5`, `openai-codex/gpt-5.6-sol` |
| `run_id` | string | yes | dedupe key with `skill`; the shipped client uses `<machine>-<run_ts>-<pid>`, e.g. `workstation-a-20260728-194119-849873` |
| `prompt` | string | no | full prompt.md content |
| `reviewers` | array | yes, non-empty | one entry per reviewer slot |
| `reviewers[].slot` | string | yes | e.g. `gpt56`, `glm`, `kimi`, `deepseek` |
| `reviewers[].model` | string | yes | e.g. `openai-codex/gpt-5.6-sol` |
| `reviewers[].status` | string | yes | free-form: `completed`, `timeout`, `error`, ... |
| `reviewers[].duration_s` | int | no | must be `>= 0` if present |
| `reviewers[].bytes` | int | no | raw output size |
| `reviewers[].output` | string | no | raw reviewer `.md`; omit for timeouts |
| `reviewers[].score` | int | no | grading score, `1`–`5` |
| `reviewers[].valid` | int | no | valid finding count |
| `reviewers[].invalid` | int | no | invalid finding count |
| `reviewers[].note` | string | no | short grading note |

Success: `201` (new) or `200` (identical replay). Response body (same shape both
cases; `processed_at` appears only once the processor has marked the record):

```json
{
  "id": 42,
  "submission_type": "multi-llm-review",
  "machine_name": "workstation-a",
  "coordinator_model": "claude-fable-5",
  "run_id": "workstation-a-20260728-194119-849873",
  "payload": {
    "prompt": "…",
    "reviewers": [ { "slot": "gpt56", "model": "openai-codex/gpt-5.6-sol", "status": "completed", "duration_s": 354, "bytes": 2392, "output": "…", "score": 5, "valid": 2, "invalid": 0, "note": "…" } ]
  },
  "created_at": "2026-07-28T19:41:19Z"
}
```

Errors:
- `400` `{"error": "create_review_failed", "message": "..."}` — `message` names
  the missing/invalid field, e.g. `invalid input: reviewers[0].score must be between 1 and 5`.
  (`"bad_request"` is only used for malformed JSON or unknown fields.)
- `409` `{"error": "replay_mismatch", ...}` — see *Idempotency* above.

curl example (2 reviewers, one with scores and raw output, one timed out):

```bash
curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/reviews" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "skill": "multi-llm-review",
    "machine_name": "workstation-a",
    "coordinator_model": "claude-fable-5",
    "run_id": "workstation-a-20260728-194119-849873",
    "prompt": "Review the diff for correctness and security issues.",
    "reviewers": [
      {
        "slot": "gpt56",
        "model": "openai-codex/gpt-5.6-sol",
        "status": "completed",
        "duration_s": 354,
        "bytes": 2392,
        "output": "The 14 registered routes all reach handlers guarded before parsing IDs...",
        "score": 5,
        "valid": 2,
        "invalid": 0,
        "note": "only reviewer to catch working-copy loss (MAJOR)"
      },
      {
        "slot": "kimi",
        "model": "telnyx/moonshotai/Kimi-K3",
        "status": "timeout",
        "duration_s": 900,
        "bytes": 0
      }
    ]
  }'
```

## POST /api/v1/frictions

| Field | Type | Required | Notes |
|---|---|---|---|
| `machine_name` | string | yes | |
| `coordinator_model` | string | yes | the submitting agent's model id — always pass it, never default to `unknown` |
| `category` | string | yes | free-form, no server enum, e.g. `documentation`, `tooling`, `config`, `environment` |
| `summary` | string | yes | what the friction was (≤ 2000 bytes) |
| `details` | string | no | expected vs actual, what it cost |
| `suggested_fix` | string | no | the concrete fix |
| `project` | string | no | repo/project it occurred in |
| `harness` | string | no | e.g. `claude-code`, `pi`, `opencode`, `omp`, `codex` |
| `context` | object | no | flat string→string map of auto-collected metadata (see below); ≤ 32 entries, keys ≤ 64 B, values ≤ 2000 B |

**The `context` object.** The shipped client fills it automatically — agents
supply nothing. It is stored verbatim in `payload.context` and **excluded from
the duplicate-absorption hash**: the same friction re-submitted with a new
timestamp or commit still dedupes, and the original row's context is kept. Keys
are free-form (new ones need no server change); the shipped client collects:

| Key | Source |
|---|---|
| `occurred_at` | payload build time, UTC — survives spool delays (`created_at` is receipt time) |
| `cwd`, `repo_root` | where the friction happened |
| `git_remote` | origin URL with userinfo stripped (https tokens never leave the machine) |
| `git_branch`, `git_commit`, `git_dirty` | repo state at the time |
| `os`, `arch` | `uname` |
| `session_id` | `AGENT_FEEDBACK_SESSION_ID` override, else Claude Code's `CLAUDE_CODE_SESSION_ID` |
| `agent` | `AI_AGENT` env when set (harness + version) |
| `effort` | `CLAUDE_EFFORT` env when set |
| `profile` | omp/pi profile name (`OMP_PROFILE`/`PI_PROFILE`) when set |
| `client_version` | the skill's version |

Success: `201` (new) or `200` (identical content within the 24 h dedupe window —
the existing record comes back; see *Idempotency*). Response body:

```json
{
  "id": 43,
  "submission_type": "friction",
  "machine_name": "workstation-a",
  "coordinator_model": "claude-fable-5",
  "payload": {
    "category": "documentation",
    "summary": "docs/patterns.md was stale re: idempotent create",
    "suggested_fix": "document DO NOTHING + re-fetch pattern for identity PKs",
    "project": "agent-feedback",
    "harness": "claude-code"
  },
  "created_at": "2026-07-29T10:00:00Z"
}
```
Note: `run_id` is absent from the response (`omitempty`) — frictions dedupe by
content hash, not run id.

Error: `400` with `{"error": "create_friction_failed", "message": "..."}` for validation
failures (`"bad_request"` is only used for malformed JSON or unknown fields).

curl example:

```bash
curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/frictions" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "machine_name": "workstation-a",
    "coordinator_model": "claude-fable-5",
    "category": "documentation",
    "summary": "docs/patterns.md described ON CONFLICT DO UPDATE SET id = ..., which errors on identity columns",
    "suggested_fix": "document the check-then-insert-DO-NOTHING-then-recheck pattern for identity PKs",
    "project": "agent-feedback",
    "harness": "claude-code"
  }'
```

## GET /api/v1/submissions

Query params (all optional; unknown params are currently ignored — spell them
exactly as below):

| Param | Type | Notes |
|---|---|---|
| `type` | string | filters `submission_type`, e.g. `multi-llm-review`, `friction` |
| `machine` | string | filters `machine_name` |
| `model` | string | filters `coordinator_model` (the coordinator, not reviewer models) |
| `since` | RFC 3339 timestamp | `created_at >=` |
| `until` | RFC 3339 timestamp | `created_at <=` |
| `processed` | `true` \| `false` | `false` = the processor's work queue (processed_at unset) |
| `limit` | int | default `50`, max `500` |
| `offset` | int | default `0`, clamped to `>= 0` |

The response echoes back the normalized `limit`/`offset` actually used for the
query — not the raw query params. `limit <= 0` becomes `50`, `limit > 500` becomes
`500`, `offset < 0` becomes `0`.

Success: `200`. List rows omit the payload, but **friction rows surface their
`category`/`summary`/`project`/`harness` payload fields** so a list is scannable
without per-id fetches (omitted for review rows). `processed_at` appears when set:

```json
{
  "submissions": [
    {
      "id": 43,
      "submission_type": "friction",
      "machine_name": "workstation-a",
      "coordinator_model": "claude-fable-5",
      "created_at": "2026-07-29T10:00:00Z",
      "category": "documentation",
      "summary": "docs/patterns.md was stale re: idempotent create",
      "project": "agent-feedback",
      "harness": "claude-code"
    }
  ],
  "limit": 50,
  "offset": 0
}
```

Error: `400` with `{"error": "bad_request", "message": "since must be RFC 3339"}`
(or the `until`/`processed`/`limit`/`offset` equivalents).

curl example (the processor's work-queue read):

```bash
curl -sS "$AGENT_FEEDBACK_URL/api/v1/submissions?processed=false&type=friction&limit=100" \
  -H "X-Api-Key: $AGENT_FEEDBACK_API_KEY"
```

## GET /api/v1/submissions/{id}

`{id}` is the numeric submission id (from a prior create/list response).

Success: `200`, full record including `payload` (same shape as the POST response
body, plus `processed_at` when set).

Error: `400` if `{id}` isn't numeric:
```json
{"error": "bad_request", "message": "id must be a numeric submission ID"}
```
`404` if no such submission:
```json
{"error": "get_submission_failed", "message": "submission not found"}
```

curl example:

```bash
curl -sS "$AGENT_FEEDBACK_URL/api/v1/submissions/43" \
  -H "X-Api-Key: $AGENT_FEEDBACK_API_KEY"
```

## Building a review payload from a run directory

Don't hand-roll this — `skills/agent-feedback/scripts/submit-review.sh` is the
canonical implementation and handles every subtlety below. For reference, the
run-dir layout it consumes (`~/.cache/<skill>/<run_ts>-<pid>/`):

- `meta.json` — written by the review runner: `machine`, `skill`, `run_ts`,
  `caller` (coordinator model at run time), and the slot→label map.
- `summary.tsv` — one row per reviewer: slot, model, status, duration_s, bytes.
  `duration_s`/`bytes` can be **empty strings** — guard before `tonumber`
  (a bare `--argjson duration_s ""` fails).
- `<slot>.md` — raw reviewer output (submitted only with `--include-outputs`).
- `prompt.md` — the review prompt (submitted only with `--include-outputs`).
- `../scorecards.tsv` — grading ledger beside the run dirs, keyed by run_ts +
  reviewer **label**; join label→slot through `meta.json`'s slot map, not by
  model-name matching.

The client's `run_id` is `<machine>-<basename of run dir>` (i.e.
`<machine>-<run_ts>-<pid>`), which keeps run ids unique across machines and
same-second sibling runs.

The client requires a grade for every completed reviewer before submission.
Optional blank finding counts are omitted, not converted to zero. Attribution
uses `meta.json.caller`, not the shell that later retries the run. Timestamp-only
scorecards cannot disambiguate sibling runs with the same timestamp: the client
refuses them rather than borrowing scores. Resolve this in the external ledger.
Scores are coordinator judgments, not independently verified quality measures;
see [methodology limitations](../README.md#interpreting-review-data).
