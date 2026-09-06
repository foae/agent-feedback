# Extending the service

This checkout contains only `backend/services/feedback`; there is no
`services/example` scaffold to copy. Prefer extending feedback when the feature
belongs to submission storage or processing. A separate service is an explicit
architecture decision, not a required template step.

## Changing feedback

1. Read [architecture](architecture.md), [conventions](conventions.md), and the
   [API contract](agent-usage.md). Identify the observable behavior and callers.
2. Put validation and persistence orchestration in `core/`; keep HTTP parsing,
   DTO conversion and error mapping in `handler/`.
3. Edit `storage/postgres/q.sql` for SQL changes. Schema changes require a new
   numbered migration; deployed migrations are append-only.
4. Run `just sqlc-generate` from `backend/services/feedback`. JSONB parameters
   must retain the `json.RawMessage` sqlc override.
5. For API changes update `docs/agent-usage.md`, `scripts/e2e.sh`, and the client
   skill together with service code. Preserve immutable payload/replay semantics.
6. Run `just check`, race-enabled tests with a disposable PostgreSQL database,
   and live e2e for API changes. Run `bash tests/skill/run-tests.sh` for client
   changes. Commands and safe setup are in the [README](../README.md).

Keep new helpers local unless multiple callers genuinely need them. Add tests
for behavior and uncertain boundaries rather than copying a template suite.

## If a separate service is necessary

Use the existing `backend/go.mod` unless there is a concrete reason to separate
modules. Choose its own command, HTTP routes, configuration, database ownership,
build target and deployment lifecycle deliberately. Update CI and documentation
for those actual paths; do not mechanically duplicate feedback's schema or
single-key authorization policy into a different trust domain.
