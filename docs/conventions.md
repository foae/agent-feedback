# Conventions

## Go layout and errors

Use exported CamelCase names, unexported camelCase names and snake_case files
organized by behavior (`submission_create.go`, `submission_process.go`). Avoid
package-name stutter. Group imports into standard library, dependencies, and
`agent-feedback/backend/...` imports; run the repository formatter.

Core owns domain sentinel errors. Wrap errors with short operation context and
`%w` so `errors.Is`/`errors.As` still work. HTTP handlers map those errors into
JSON responses rather than putting HTTP concepts in core.

Use structured `slog` fields, preferably context-aware calls when a context is
available. Expected validation/replay failures are client errors, not error-level
server faults. Never log credentials, connection strings or telemetry payloads.
Passing a context alone does not guarantee trace enrichment; it depends on the
configured logger/middleware.

## HTTP

Handlers return `http.HandlerFunc` closures and call core for business behavior.
API responses use DTOs and `application/json`; errors have `error` and `message`
fields. Operational health/readiness endpoints use plain text. Empty API lists
are arrays, not null. There is no submission deletion endpoint.

Create/processed bodies reject unknown fields and require exactly one JSON
value, with a 10 MiB limit over the entire body. Preserve those boundaries.

## Database

- SQL lives in `storage/postgres/q.sql`; generate typed bindings with
  `just sqlc-generate`. Do not hand-edit generated code.
- Migrations are append-only, paired up/down files. Review destructive downs
  before using them; an older image alone does not reverse schema changes.
- Submission IDs deliberately use `BIGINT GENERATED ALWAYS AS IDENTITY`.
- Payloads are immutable; `processed_at` is the only mutable submission state.
  Do not add an `updated_at` write path to work around replay conflicts.
- JSONB parameters must use `json.RawMessage`, never plain `[]byte` with this
  pool's pgx exec mode. Keep the sqlc override.
- Use transactions for lock/read/write invariants, roll back errors, and close
  resources on unsuccessful construction as well as normal shutdown.

## Verification

Tests defend observable behavior and plausible edge cases. Table-driven tests
are useful for distinct boundaries, not repetitive plumbing assertions. Tests
must be deterministic and isolated; parallelize only without conflicting shared
state. Database semantics require real PostgreSQL, not mock echoes. Integration
tests need `TEST_POSTGRES_URL` and must not skip during release verification.

Run the commands in the [README](../README.md). API changes move handler/core,
[API docs](agent-usage.md), live e2e, and companion scripts together. Client tests
stay in `tests/skill/`, outside the distributed skill directory.
