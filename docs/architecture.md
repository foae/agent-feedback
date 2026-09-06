# Architecture

This repository contains one Go service, `backend/services/feedback`, in the
`backend/go.mod` module, plus a Bash client skill. It does not contain a generic
service generator, model runner, background processor, or dashboard.

## Dependencies and request flow

`cmd/feedback/main.go` loads configuration and constructs the PostgreSQL client,
core service, handlers, and Chi router. Requests flow through `handler` → `core`
→ `storage/postgres`; storage does not depend on HTTP or core code.

- `handler/`: authentication, strict JSON decoding, DTO conversion, status mapping.
- `core/`: validation, content hashing, replay/deduplication, queries, processing.
- `storage/postgres/`: pool lifecycle, embedded migrations, SQL inputs and generated bindings.
- `backend/pkg/`: database pool, environment host override, metrics and tracing helpers.

The entrypoint owns wiring and shutdown. `core.Service.Close` releases database
resources. Migration drivers are closed after migrations complete. The service
marks readiness unavailable before its five-second drain delay and configurable
shutdown deadline. Compose allows two minutes for the default 90-second deadline.

## Persistence invariants

Submission payloads are write-once. Only `processed_at` is mutable. Review keys
are `(submission_type, run_id)`; matching payload hashes replay the existing row,
and differing hashes return 409. Legacy rows without hashes retain compatibility
behavior described in the [API contract](agent-usage.md).

Friction dedupe excludes context and uses a 24-hour window. A transaction-scoped
advisory lock serializes identical hashes before a fresh lookup and insertion.
Processing locks requested existing rows in ID order and classifies and updates
them in one transaction. These are database-backed invariants, not client locks.

`q.sql` and append-only migrations are inputs to sqlc. Never edit generated
`sqlc/` files. JSONB parameters use `json.RawMessage`: the shared pool uses pgx
exec mode, where plain `[]byte` is encoded as bytea rather than JSON.

## HTTP and operational boundary

One API key protects all `/api/v1` routes. Health, database-backed readiness and
Prometheus metrics are unauthenticated. Middleware provides panic recovery,
request IDs, structured logging and request metrics. `RealIP` is deliberately
absent: do not trust arbitrary forwarded headers. Tracing is optional; the OTLP
gRPC exporter currently uses insecure transport and needs a trusted local or
encrypted network boundary.

The client collects context, builds payloads and retries queued writes on later
invocations. It is not a delivery daemon. See the [skill](../skills/agent-feedback/SKILL.md)
and [public setup/security guide](../README.md) for runtime contracts.
