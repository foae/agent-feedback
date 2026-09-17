# agent-feedback HTTP API

The contract producers and processors integrate against. Self-contained: read
this, then write the calls. Prefer the shipped client scripts in
[`skills/agent-feedback/`](../skills/agent-feedback/SKILL.md); they implement
spooling, retries, receipt validation and outcome reporting. Hand-roll HTTP
only for a producer the client does not cover.

Contents:

1. [Base URL, auth, common rules](#base-url-auth-common-rules)
2. [The record](#the-record)
3. [Write endpoints](#write-endpoints): frictions, reviews, events
4. [Read endpoints](#read-endpoints): list, get, export
5. [Processing](#processing): mark processed with a resolution
6. [Idempotency and duplicates](#idempotency-and-duplicates)
7. [Operational endpoints](#operational-endpoints)
8. [Changes since API 1.0](#changes-since-api-10)

## Base URL, auth, common rules

Two environment variables, set by the operator on every machine that talks to
the service. There is no hosted default.

```
AGENT_FEEDBACK_URL=http://127.0.0.1:8090
AGENT_FEEDBACK_API_KEY=<shared key>
```

Every `/api/v1/*` request carries the key in either header:

```
Authorization: Bearer $AGENT_FEEDBACK_API_KEY
X-Api-Key: $AGENT_FEEDBACK_API_KEY
```

Missing or wrong key: `401 {"error":"unauthorized","message":"missing or invalid API key"}`.

Rules that apply to every endpoint:

- Responses are JSON. Errors have the shape `{"error":"<code>","message":"<text>"}`.
  `message` names the offending field when there is one.
- POST bodies must be exactly one JSON object. Unknown fields are rejected with
  `400 bad_request` naming the field. A typo is a bug, not something to drop:
  a dropped field plus an idempotent replay would lose data for good.
- Bodies over 10 MiB (including trailing whitespace) get
  `413 {"error":"request_too_large","message":"request body exceeds 10 MiB"}`.
- Timestamps are RFC 3339 in UTC, microsecond precision, e.g.
  `2026-09-17T20:06:48.123456Z`. Query parameters accept any RFC 3339 offset.
- Stored content is never modified after creation. The only mutable state is
  the processing mark (`processed_at`, `resolution`).

Field length limits (`400` naming the field when exceeded). They protect the
database, not police content; free-text fields are bounded only by the body cap.

| Fields | Limit |
|---|---|
| `machine_name`, `coordinator_model`, `skill`, `run_id`, `kind`, `key`, `category`, `project`, `harness`, `reviewers[].slot`, `reviewers[].model`, `reviewers[].status` | 200 bytes |
| friction `summary`, `resolution` | 2000 bytes |
| `reviewers[].note` | 4000 bytes |
| `reviewers[]` count | 100 |
| `context` object | 32 entries, keys 64 bytes, values 2000 bytes |
| `details`, `suggested_fix`, `prompt`, `reviewers[].output`, event `payload` | body cap only |

## The record

Every submission, whatever its family, is returned in one shape:

```json
{
  "id": 43,
  "family": "friction",
  "submission_type": "friction",
  "machine_name": "workstation-a",
  "coordinator_model": "claude-fable-5-1",
  "run_id": null,
  "payload": { "category": "documentation", "summary": "…", "context": { "…": "…" } },
  "payload_hash": "9f3a…",
  "created_at": "2026-09-17T20:06:48.123456Z",
  "processed_at": null,
  "resolution": null
}
```

| Field | Meaning |
|---|---|
| `id` | Positive integer, unique across all families, never reused. |
| `family` | `friction`, `review` or `event`. Decides how the payload is shaped and how duplicates are handled. |
| `submission_type` | `friction` for frictions; the submitting `skill` for reviews; the `kind` for events. |
| `run_id` | Idempotency key within `(family, submission_type)`: the review `run_id` or the event `key`. `null` for frictions. |
| `payload` | The submitted content, verbatim. Numbers are returned exactly as stored. |
| `payload_hash` | SHA-256 hex over the canonical content (see [Idempotency](#idempotency-and-duplicates)). Equal hashes mean byte-identical content. |
| `created_at` | Receipt time at the server. For frictions the client's own `context.occurred_at` records when it happened. |
| `processed_at`, `resolution` | Set by a processor. `null` until then. |

Fields with `null` values are always present; do not rely on omission.

## Write endpoints

### POST /api/v1/frictions

What slowed an agent down. The primary write path.

| Field | Type | Required | Notes |
|---|---|---|---|
| `machine_name` | string | yes | the reporting machine's canonical name |
| `coordinator_model` | string | yes | the reporting agent's model id; never `unknown` if you know it |
| `category` | string | yes | free-form, e.g. `documentation`, `tooling`, `config`, `environment` |
| `summary` | string | yes | one line, what the friction was |
| `details` | string | no | expected vs actual, what it cost |
| `suggested_fix` | string | no | the concrete fix; if already applied, name the commit |
| `project` | string | no | repository or project name |
| `harness` | string | no | e.g. `claude-code`, `opencode`, `codex` |
| `context` | object | no | flat string map of auto-collected metadata; excluded from duplicate detection |

`201` with the record when stored. `200` with the existing record when an
identical friction (same content, same reporter, `context` ignored) was stored
within the last 24 hours; blind retries are safe. `400 create_friction_failed`
on validation failure.

```bash
curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/frictions" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY" -H 'Content-Type: application/json' \
  -d '{"machine_name":"workstation-a","coordinator_model":"claude-fable-5-1",
       "category":"documentation","summary":"README install step references a flag that no longer exists",
       "suggested_fix":"replace --legacy with --compat in README step 3","project":"example","harness":"claude-code"}'
```

### POST /api/v1/reviews

One record per completed multi-reviewer run: per-reviewer status, timing and
grading. The client builds this from a run directory; see the
[run-directory contract](../skills/agent-feedback/SKILL.md#run-directory-contract).

| Field | Type | Required | Notes |
|---|---|---|---|
| `skill` | string | yes | the submitting skill; `friction` is reserved and rejected |
| `machine_name`, `coordinator_model` | string | yes | as for frictions |
| `run_id` | string | yes | idempotency key with `skill`; must be unique per machine and run |
| `prompt` | string | no | the review prompt |
| `reviewers` | array | yes, non-empty | one entry per reviewer |
| `reviewers[].slot`, `.model`, `.status` | string | yes | `status` is free-form: `completed`, `timeout`, `error`, … |
| `reviewers[].duration_s`, `.bytes` | int ≥ 0 | no | |
| `reviewers[].output` | string | no | raw output; omit for timeouts |
| `reviewers[].score` | int 1–5 | no | grading score |
| `reviewers[].valid`, `.invalid` | int ≥ 0 | no | finding counts; omit when unknown, never send 0 for unknown |
| `reviewers[].note` | string | no | grading note |

`201` new, `200` identical replay, `409 replay_mismatch` when the same
`(skill, run_id)` arrives with different content (the stored record is never
changed; submit a correction under a new `run_id`), `400 create_review_failed`
on validation failure.

### POST /api/v1/events

Anything else worth recording once: a generic write-once envelope with a
free-form JSON object payload. Nothing in the service interprets the payload.

| Field | Type | Required | Notes |
|---|---|---|---|
| `kind` | string | yes | producer-chosen namespace, e.g. `deploy`, `benchmark`; `friction` is reserved |
| `key` | string | yes | idempotency key within `kind`; make it unique per machine and occurrence |
| `machine_name`, `coordinator_model` | string | yes | as for frictions |
| `payload` | object | yes | any JSON object |

`201` new, `200` identical replay, `409 replay_mismatch` on different content
under the same `(kind, key)`, `400 create_event_failed` on validation failure.

```bash
curl -sS -X POST "$AGENT_FEEDBACK_URL/api/v1/events" \
  -H "X-Api-Key: $AGENT_FEEDBACK_API_KEY" -H 'Content-Type: application/json' \
  -d '{"kind":"deploy","key":"workstation-a-20260917-200648","machine_name":"workstation-a",
       "coordinator_model":"claude-fable-5-1","payload":{"service":"agent-feedback","image":"sha-0e840b2","ok":true}}'
```

## Read endpoints

### GET /api/v1/submissions

Filtered list, newest first (descending `id`). All parameters optional.

| Param | Type | Notes |
|---|---|---|
| `family` | `friction` \| `review` \| `event` | |
| `type` | string | filters `submission_type` (skill name, event kind, or `friction`) |
| `machine` | string | filters `machine_name` |
| `model` | string | filters `coordinator_model` |
| `since`, `until` | RFC 3339 | `created_at >=` / `<=` |
| `processed` | `true` \| `false` | `false` is the processor's work queue |
| `before_id` | int | keyset cursor: only rows with `id < before_id` |
| `limit` | int | default 50, max 500 (max 100 with `include=payload`) |
| `include` | `payload` | return full records instead of summaries |

Response:

```json
{
  "submissions": [ { "id": 43, "family": "friction", "…": "…" } ],
  "limit": 50,
  "total": 45,
  "has_more": false,
  "next_before_id": null
}
```

- Rows are summaries: the record without `payload`, plus for frictions the
  `category`, `summary`, `project` and `harness` fields lifted to the top level
  so a list is scannable. With `include=payload` rows are full records.
- `total` counts every row matching the filters (ignoring `before_id` and
  `limit`), computed in the same read transaction as the page.
- `has_more` is true when rows older than this page match; `next_before_id` is
  then the `id` of the page's last row, ready to pass back as `before_id`.
- `limit` echoes the value actually used after clamping.

To drain a queue reliably: fetch pages with `processed=false` following
`next_before_id` until `has_more` is false, collect the ids, act, then mark.
Do not mark while paging; do not mix offset arithmetic into the loop.

`400 bad_request` names any malformed parameter (`since must be RFC 3339`,
`processed must be true or false`, `before_id must be a positive integer`, …).

```bash
curl -sS "$AGENT_FEEDBACK_URL/api/v1/submissions?family=friction&processed=false&include=payload&limit=100" \
  -H "X-Api-Key: $AGENT_FEEDBACK_API_KEY"
```

### GET /api/v1/submissions/{id}

The full record. `400 bad_request` if `{id}` is not numeric,
`404 get_submission_failed` if it does not exist.

### GET /api/v1/export

Every record as newline-delimited JSON (`Content-Type: application/x-ndjson`),
ascending `id`, one full record per line, then a final line

```json
{"export_complete":true,"count":676}
```

A stream without that terminator is truncated; do not treat it as a backup.
Optional filters: `family`, `since`. The export is one consistent read
transaction. This is the migration and off-host backup format; the `feedback
import` command reads it (see [operate.md](operate.md#restore-and-migration)).

## Processing

### POST /api/v1/submissions/processed

Mark or unmark a batch after acting on it. The only write that changes an
existing row.

| Field | Type | Required | Notes |
|---|---|---|---|
| `ids` | int array | yes, 1–500 entries, positive | duplicates are collapsed |
| `processed` | bool | no, default `true` | `false` clears the mark |
| `resolution` | string | no | ≤ 2000 bytes; what was done, e.g. `fixed in example@1a2b3c4`, `invalid: premise wrong`, `duplicate of 41`. Only with `processed=true`. |

One resolution applies to the whole batch. Issue one request per distinct
resolution.

`200` with every id classified:

```json
{"processed": true, "resolution": "fixed in example@1a2b3c4", "updated": [43, 44], "unchanged": [42], "not_found": [999]}
```

- `updated`: the row changed. Marking an unprocessed row sets `processed_at`
  (now) and `resolution`. Re-marking an already processed row with a different
  non-empty `resolution` replaces the resolution and keeps the original
  `processed_at`.
- `unchanged`: already in the requested state with the same resolution (or no
  resolution given). Marking is idempotent.
- `not_found`: no such id.
- Unmarking clears both `processed_at` and `resolution`.
- Classification and updates happen in one transaction.

`400 set_processed_failed` for empty, oversized or non-positive `ids`, or a
`resolution` sent with `processed=false`.

## Idempotency and duplicates

| Family | Key | Identical replay | Different content, same key |
|---|---|---|---|
| review | `(skill, run_id)` | `200` existing record | `409 replay_mismatch` |
| event | `(kind, key)` | `200` existing record | `409 replay_mismatch` |
| friction | content hash, 24 h window | `200` existing record | new `201` row (it is a different friction) |

Content identity is `payload_hash`: SHA-256 over a canonical JSON encoding of
`{machine_name, coordinator_model, payload}` where object keys are sorted,
numbers keep their textual form, and no insignificant whitespace is present.
For frictions the `context` object is removed before hashing, so the same
friction re-filed with a new timestamp, commit or working directory still
dedupes. A friction re-encountered after the 24 h window is a new row on
purpose: recurrence stays visible to the processor.

Concurrent identical writes are serialized by the database; exactly one row
results. Rows imported from API 1.0 keep their original hash.

## Operational endpoints

No authentication. Keep them inside the deployment boundary.

- `GET /health`: process liveness, `200 OK`.
- `GET /ready`: `200 READY` when the database answers and the schema is
  current; `503` with `SHUTTING_DOWN` or `DB_UNAVAILABLE` otherwise.
- `GET /metrics`: Prometheus text format. Request counters and latency
  histograms are labelled by route pattern, allow-listed method and status
  code, never by raw path or client input.

## Changes since API 1.0

Everything from 1.0 still works unchanged. Additions:

- `family` on every record and as a list filter; `POST /api/v1/events`.
- `payload_hash`, `resolution` and explicit `null`s on every record.
- `resolution` on the processed endpoint; re-marking with a new resolution counts as `updated`.
- `before_id`, `include=payload`, `total`, `has_more`, `next_before_id` on the list endpoint.
- `GET /api/v1/export`.
- Timestamps carry microseconds.
- Review replays against rows created before payload hashing existed no longer
  occur: every stored row has a hash.
