# Development

The service is `backend/services/feedback` in the `backend/go.mod` module. It
uses Go 1.27 (toolchain 1.27.1), PostgreSQL, `just`, and `sqlc` 1.31.1.
The Compose stack uses PostgreSQL 18. Install `just` with your package manager
and sqlc with `go install github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1`; ensure
`$(go env GOPATH)/bin` is on your `PATH`.

## Run from source

```bash
cd backend/services/feedback
cp .env.example .env
# Edit .env: set POSTGRES_URL and a strong API_KEY for a development database.
# For local-only access, set HTTP_LISTEN_ADDR=127.0.0.1:8080.
just run-local
```

`just run-local` stays in the foreground. From another terminal, check
`http://127.0.0.1:8080/ready`. The source `.env.example` documents required
`POSTGRES_URL` and `API_KEY`, plus service name/version, listen address, region,
graceful-shutdown timeout, optional OpenTelemetry endpoint, and an optional
Postgres-host override.

## Checks and tests

From `backend/services/feedback`, `just check` runs formatting, vet, SQL
validation and generation, module tidy, and a build. It can update generated
files and module metadata. `just sqlc-generate` regenerates the SQL bindings.

From the repository root:

```bash
bash tests/skill/run-tests.sh
# Use a separate disposable PostgreSQL database, never production:
(cd backend && TEST_POSTGRES_URL='<test database connection URL>' go test -race -count=1 ./...)
# Against a disposable running service; creates persistent test records:
bash scripts/e2e.sh "$AGENT_FEEDBACK_API_KEY" "$AGENT_FEEDBACK_URL"
```

The client test suite requires Python 3. Integration tests skip when
`TEST_POSTGRES_URL` is absent. The end-to-end script creates submissions; delete
them deliberately or use a disposable database. CI runs the service checks,
PostgreSQL-backed race tests, the live HTTP contract, shellcheck, and the
hermetic client suite. Pushes to `main` publish multi-architecture images tagged
`latest` and the commit SHA.

## Change boundaries

Read [conventions](conventions.md) and [architecture](architecture.md) before
changing service behavior. Keep API code, the [API contract](agent-usage.md),
`scripts/e2e.sh`, and the companion skill synchronized. SQL queries and
append-only migrations are input to sqlc: regenerate bindings instead of
editing generated `sqlc/` files or deployed migrations by hand.

The project map:

| Path | Purpose |
|---|---|
| `backend/services/feedback/cmd/feedback/` | Configuration, wiring, routing, shutdown |
| `backend/services/feedback/core/` | Validation, hashing, create/query/process behavior |
| `backend/services/feedback/handler/` | HTTP DTOs, authentication, error mapping |
| `backend/services/feedback/storage/postgres/` | Queries, append-only migrations, generated sqlc bindings |
| `backend/pkg/` | Shared database, HTTP metrics, tracing, environment helpers |
| `infra/agent-feedback/` | Local build-based and image-based Compose stacks |
| `skills/agent-feedback/` | Distributed companion client skill |
| `tests/skill/`, `scripts/e2e.sh` | Client and live-contract verification |