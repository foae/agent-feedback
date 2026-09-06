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
| Change the API surface | Rules below — four artifacts must move together |
| Change the companion skill (client scripts) | `skills/agent-feedback/` — this repo is the canonical source; run `tests/skill/run-tests.sh` |
| Install/adopt the companion skill | `skills/agent-feedback/SKILL.md` — Installation section |
| Understand naming/error/test conventions | [docs/conventions.md](docs/conventions.md) |
| See how the service was scaffolded | [docs/adding-a-service.md](docs/adding-a-service.md), [docs/patterns.md](docs/patterns.md) |
| Run / verify / deploy | Commands + Verification below; deploy runbook in [README.md](README.md) ("Deploy to production") |

## Layout

```
backend/                      Go module root (single go.mod)
  pkg/                        shared infra (postgres pool, envutil, httputil, observability)
  services/feedback/
    cmd/feedback/main.go      wiring: config, DI, chi router, graceful shutdown
    core/                     business logic: validation, content hashing/dedupe, create, list/get, processed
    handler/                  HTTP: auth middleware, DTOs, sentinel-error → status mapping
    storage/postgres/         q.sql + migrations/ (inputs) → sqlc/ (generated, never edit)
infra/agent-feedback/         docker-compose stack (postgres + service)
scripts/e2e.sh                live-contract test suite (all endpoints)
skills/agent-feedback/        CANONICAL companion skill (SKILL.md + client scripts ONLY —
                              distributed as-is; sync/distribution handled outside this repo)
tests/skill/                  hermetic tests for the skill scripts (repo-only; must NEVER
                              travel with the skill directory)
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
bash tests/skill/run-tests.sh   # hermetic client-script tests (mock server)
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
- **An API change is a four-artifact change**: handler/core code,
  [docs/agent-usage.md](docs/agent-usage.md), `scripts/e2e.sh`, and the client
  scripts in `skills/agent-feedback/` move in the same commit. The doc is a
  load-bearing contract — producer agents build their recipes from it without
  reading the code.
- **Write-once payloads, one mutable flag.** Submission content is never
  updated; `processed_at` (set/cleared via `POST /api/v1/submissions/processed`)
  is the only mutable state. Reviews dedupe on `(submission_type, run_id)`:
  identical replay → 200 existing row; different content under the same key →
  409 `replay_mismatch` (hash comparison via `payload_hash`) — a correction is a
  new submission under a new run_id. Frictions dedupe on content hash within a
  24 h window (`core.frictionDedupeWindow`) → duplicate returns 200 + existing
  row; the auto-collected `context` object is EXCLUDED from that hash (it varies
  between attempts of the same friction). The skill name `friction` is reserved.
- **Identity PK is a deliberate exception** to the template's UUID convention
  (see note in [docs/conventions.md](docs/conventions.md)).
- Create endpoints are strict: unknown JSON fields → 400, bodies over 10 MiB → 413.
  Keep it that way — silent field-dropping plus idempotent replay would lose data
  irrecoverably.

## Deployment facts

- Deployment is configured with `DEPLOY_REMOTE` and `DEPLOY_IMAGE`, either in the
  environment or in the gitignored `.private/deploy.env`. Use `scripts/deploy.sh`
  (runbook in [README.md](README.md)). CI publishes the repository's GHCR image
  on each `main` push; the script streams it over SSH without putting registry
  credentials on the remote host. Generated API credentials remain in the
  remote host's `~/agent-feedback/.env`.
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
4. If you touched `skills/agent-feedback/`: `bash tests/skill/run-tests.sh`
   (hermetic — needs python3, no running stack). Keep the skill directory free
   of tests/tooling — it is distributed verbatim.
