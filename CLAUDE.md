# agent-feedback — working in this repo

Go JSON REST service that centralizes LLM-agent telemetry (review-run results,
friction reports) in Postgres. One service, one table, write-once semantics.

This file is the entry point for agents **changing this repo**. It stays short on
purpose — each section tells you where the depth lives; follow a link only when
your task needs it. If you are instead **submitting data to the running service**
(wiring a skill/producer), you need exactly one document: [docs/agent-usage.md](docs/agent-usage.md).

## Route by task

| Task | Go to |
|---|---|
| Wire a skill/producer to submit feedback | [docs/agent-usage.md](docs/agent-usage.md) — self-contained API contract, curl recipes |
| Change service code | This file (rules below), then [docs/architecture.md](docs/architecture.md) for the layer model |
| Change the API surface | Rules below — three artifacts must move together |
| Understand naming/error/test conventions | [docs/conventions.md](docs/conventions.md) |
| See how the service was scaffolded | [docs/adding-a-service.md](docs/adding-a-service.md), [docs/patterns.md](docs/patterns.md) |
| Run / verify / deploy | Commands + Verification below; deploy runbook in [README.md](README.md) ("Deploy to production") |

## Layout

```
backend/                      Go module root (single go.mod)
  pkg/                        shared infra (postgres pool, envutil, httputil, observability)
  services/feedback/
    cmd/feedback/main.go      wiring: config, DI, chi router, graceful shutdown
    core/                     business logic: validation, idempotent create, list/get
    handler/                  HTTP: auth middleware, DTOs, sentinel-error → status mapping
    storage/postgres/         q.sql + migrations/ (inputs) → sqlc/ (generated, never edit)
infra/agent-feedback/         docker-compose stack (postgres + service)
scripts/e2e.sh                live-contract test suite (all endpoints)
docs/agent-usage.md           THE API contract (producers integrate against this)
```

## Commands

Run from `backend/services/feedback/` unless noted:

```bash
just check           # fmt, vet, sqlc-vet, tidy, build — the pre-commit gate
just test            # unit tests (integration tests skip without TEST_POSTGRES_URL)
just run-local       # needs .env (cp .env.example .env)
just sqlc-generate   # regenerate storage/postgres/sqlc/ after editing q.sql or migrations
bash scripts/e2e.sh <API_KEY> [BASE_URL]   # from repo root, against a running stack
```

Integration tests need a real Postgres:

```bash
docker run -d --name pg-test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=feedback_test -p 127.0.0.1:55432:5432 postgres:18-alpine
cd backend && TEST_POSTGRES_URL='postgres://postgres:test@127.0.0.1:55432/feedback_test?sslmode=disable' go test -race -count=1 ./...
docker rm -f pg-test
```

## Rules that are not obvious from the code

- **JSONB params must be `json.RawMessage`, never `[]byte`.** `pkg/postgres` pins
  `pgx.QueryExecModeExec`; a `[]byte` param is encoded as bytea and Postgres
  rejects it for jsonb columns with `invalid input syntax for type json`. The
  `sqlc.yaml` override handles the existing column — keep it for any new jsonb column.
- **`storage/postgres/sqlc/` is generated.** Edit `q.sql` / `migrations/`, run
  `just sqlc-generate`. Never hand-edit generated files.
- **Migrations are append-only** now that the service is deployed. New numbered
  file per change; never rewrite an existing one.
- **An API change is a three-artifact change**: handler/core code,
  [docs/agent-usage.md](docs/agent-usage.md), and `scripts/e2e.sh` move in the
  same commit. The doc is a load-bearing contract — producer agents build their
  recipes from it without reading the code.
- **Write-once semantics are deliberate.** No update endpoints. Reviews dedupe on
  `(submission_type, run_id)` — replay returns the existing row with 200. The
  skill name `friction` is reserved. Don't add PATCH; a correction is a new
  submission.
- **Identity PK is a deliberate exception** to the template's UUID convention
  (see note in [docs/conventions.md](docs/conventions.md)).
- Create endpoints are strict: unknown JSON fields → 400, bodies over 10 MiB → 413.
  Keep it that way — silent field-dropping plus idempotent replay would lose data
  irrecoverably.

## Deployment facts

- Production: compose stack on **deploy-host** (Intel Mac / Docker Desktop / Tailscale),
  service at `http://deploy-host:8090`, deployed manually via `scripts/deploy.sh`
  (full runbook in [README.md](README.md)). CI publishes the image to
  `ghcr.io/foae/agent-feedback` on every `main` push; the script ships it to deploy-host
  over SSH — deploy-host has no registry credentials and the API key exists only in
  `~/agent-feedback/.env` there.
- Changing `infra/agent-feedback/docker-compose.deploy.yml` changes what the next
  deploy installs; the sibling `docker-compose.yml` (build-based) is for local
  stacks only.

## Verification before you're done

1. `just check` passes.
2. `go test -race -count=1 ./...` with `TEST_POSTGRES_URL` set — integration tests
   must run, not skip.
3. If you touched the API surface: `docker compose up -d` in `infra/agent-feedback/`
   (needs `.env`, see `.env.example`), then `bash scripts/e2e.sh <key>` — all
   checks green — then `docker compose down -v` to remove test data.
