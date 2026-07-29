# agent-feedback API — usage for agents

This document is for LLM agents editing skills that submit to `agent-feedback`
(`multi-llm-review`, `second-opinion`, the friction directive in `AGENTS.core.md`,
future skills). It is self-contained: read this, then write the `curl` calls. No
human-oriented framing below.

## Base URL and auth

Two env vars, set by the operator on each machine that submits:

```
AGENT_FEEDBACK_URL=http://localhost:8090
AGENT_FEEDBACK_API_KEY=<shared key>
```

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

`GET /health`, `GET /ready`, `GET /metrics` require no auth.

## Request body limits and strictness

Both POST endpoints:

- Reject unknown JSON fields with `400 {"error": "bad_request", "message": "..."}` —
  the message names the offending field. A typo'd field name is a bug, not something
  to silently drop (this is a write-once API: a dropped field plus an idempotent
  replay is unrecoverable telemetry loss).
- Reject request bodies over 10 MiB with `413 {"error": "request_too_large", "message": "request body exceeds 10 MiB"}`.

## Idempotency

`POST /api/v1/reviews` is idempotent on `(skill, run_id)`. Resubmitting the same
`skill` + `run_id` returns the **existing** record with **HTTP 200** (first submission
returns **201**). Same body, same values back either way — safe to retry blindly
(network failure, timeout, at-least-once cron, etc.), never creates a duplicate.

`POST /api/v1/frictions` has no dedupe key (`run_id` is always null server-side) —
every call creates a new row. Do not retry a friction POST that may have already
succeeded without accepting a duplicate.

## POST /api/v1/reviews

Submitted once, at the end of a review run, after grading (prompt + all reviewers'
raw output + timings + scores in one request — no partial/incremental submission).

Request body:

| Field | Type | Required | Notes |
|---|---|---|---|
| `skill` | string | yes | submitting skill name, e.g. `multi-llm-review`, `second-opinion`; `"friction"` is reserved (rejected — use `POST /api/v1/frictions`) |
| `machine_name` | string | yes | self-reported, e.g. `workstation-a`, `laptop-a` |
| `coordinator_model` | string | yes | e.g. `claude-fable-5`, `openai-codex/gpt-5.6-sol` |
| `run_id` | string | yes | existing run_ts format, e.g. `20260728-194119-849873`; dedupe key with `skill` |
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

Success: `201` (new) or `200` (idempotent replay of an existing `skill`+`run_id`).
Response body (same shape both cases):

```json
{
  "id": 42,
  "submission_type": "multi-llm-review",
  "machine_name": "workstation-a",
  "coordinator_model": "claude-fable-5",
  "run_id": "20260728-194119-849873",
  "payload": {
    "prompt": "…",
    "reviewers": [ { "slot": "gpt56", "model": "openai-codex/gpt-5.6-sol", "status": "completed", "duration_s": 354, "bytes": 2392, "output": "…", "score": 5, "valid": 2, "invalid": 0, "note": "…" } ]
  },
  "created_at": "2026-07-28T19:41:19Z"
}
```

Error: `400` with `{"error": "create_review_failed", "message": "..."}` —
`message` names the missing/invalid field, e.g. `invalid input: reviewers[0].score must be between 1 and 5`.
(`"bad_request"` is only used for malformed JSON or unknown fields, not validation failures.)

curl example (2 reviewers, one with scores and raw output, one timed out):

```bash
curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/reviews" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "skill": "multi-llm-review",
    "machine_name": "workstation-a",
    "coordinator_model": "claude-fable-5",
    "run_id": "20260728-194119-849873",
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
| `coordinator_model` | string | yes | |
| `category` | string | yes | free-form, no server enum, e.g. `documentation`, `tooling` |
| `summary` | string | yes | what the friction was |
| `details` | string | no | |
| `suggested_fix` | string | no | the concrete fix |
| `project` | string | no | repo/project it occurred in |
| `harness` | string | no | e.g. `claude-code` |

Success: `201`.
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
Note: `run_id` is absent from the response (`omitempty`) — frictions have no dedupe key.

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

Query params (all optional):

| Param | Type | Notes |
|---|---|---|
| `type` | string | filters `submission_type`, e.g. `multi-llm-review`, `friction` |
| `machine` | string | filters `machine_name` |
| `model` | string | filters `coordinator_model` |
| `since` | RFC 3339 timestamp | `created_at >=` |
| `until` | RFC 3339 timestamp | `created_at <=` |
| `limit` | int | default `50`, max `500` |
| `offset` | int | default `0`, clamped to `>= 0` |

The response echoes back the normalized `limit`/`offset` actually used for the
query — not the raw query params. `limit <= 0` becomes `50`, `limit > 500` becomes
`500`, `offset < 0` becomes `0`.

Success: `200`, payload omitted (list is summary-only — use GET by id for the full record):
```json
{
  "submissions": [
    {
      "id": 43,
      "submission_type": "friction",
      "machine_name": "workstation-a",
      "coordinator_model": "claude-fable-5",
      "created_at": "2026-07-29T10:00:00Z"
    }
  ],
  "limit": 50,
  "offset": 0
}
```

Error: `400` with `{"error": "bad_request", "message": "since must be RFC 3339"}` (or `until`/`limit`/`offset` equivalents).

curl example:

```bash
curl -sS "$AGENT_FEEDBACK_URL/api/v1/submissions?type=multi-llm-review&machine=workstation-a&since=2026-07-01T00:00:00Z&limit=20" \
  -H "X-Api-Key: $AGENT_FEEDBACK_API_KEY"
```

## GET /api/v1/submissions/{id}

`{id}` is the numeric submission id (from a prior create/list response).

Success: `200`, full record including `payload` (same shape as the POST response body).

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

## Recipe skeleton: building a review payload from a run directory

Matches `~/.cache/multi-llm-review/<run_ts>/` run dirs: `summary.tsv` (slot, model,
status, duration_s, bytes), per-slot raw output `<slot>.md`, `prompt.md`,
`scorecard.md` (grading — score/valid/invalid/note per reviewer, keyed by model name
not slot).

```bash
run_dir=~/.cache/multi-llm-review/20260728-194119-849873
run_id=$(basename "$run_dir")

reviewers_json=$(
  tail -n +2 "$run_dir/summary.tsv" | while IFS=$'\t' read -r slot model status duration_s bytes; do
    output_file="$run_dir/$slot.md"
    output="null"
    [ -s "$output_file" ] && output=$(jq -Rs . < "$output_file")

    jq -n \
      --arg slot "$slot" --arg model "$model" --arg status "$status" \
      --argjson duration_s "$duration_s" --argjson bytes "$bytes" --argjson output "$output" \
      '{slot: $slot, model: $model, status: $status, duration_s: $duration_s, bytes: $bytes} +
       (if $output != null then {output: $output} else {} end)'
  done | jq -s .
)

payload=$(jq -n \
  --arg skill "multi-llm-review" \
  --arg machine_name "$(hostname -s)" \
  --arg coordinator_model "claude-fable-5" \
  --arg run_id "$run_id" \
  --rawfile prompt "$run_dir/prompt.md" \
  --argjson reviewers "$reviewers_json" \
  '{skill: $skill, machine_name: $machine_name, coordinator_model: $coordinator_model,
    run_id: $run_id, prompt: $prompt, reviewers: $reviewers}')

curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/reviews" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$payload"
```

If scores are graded separately (`scorecard.md`/`scorecards.tsv`, keyed by model
name), merge `score`/`valid`/`invalid`/`note` into the matching reviewer object
before building `reviewers_json` — match on `model`, not `slot` (scorecards key by
model name, summary.tsv keys by slot).
