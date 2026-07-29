# agent-feedback

A Go JSON REST service that centralizes LLM-agent telemetry — multi-model
review-run results (timings, raw outputs, grading scores) and free-form
"friction" reports — into Postgres. Producers (skills, harness directives)
previously wrote this data to per-machine local files; this service is the
control center they submit to instead, so the data can be mined to improve
skills, tooling, docs, and system prompts across the fleet.

## Using this repo as an agent

Route by what you came here to do — each destination is self-contained:

| You are... | Read |
|---|---|
| **Wiring a skill/script to submit feedback** (build a recipe: env vars, payloads, curl) | [docs/agent-usage.md](docs/agent-usage.md) — the full API contract, written for agents; you need nothing else |
| **Changing this service's code** | [CLAUDE.md](CLAUDE.md) (also symlinked as `AGENTS.md`) — commands, layout, non-obvious rules |
| **Setting up or operating a deployment** | The sections below on this page |

Client integration in three lines: the operator sets `AGENT_FEEDBACK_URL` and
`AGENT_FEEDBACK_API_KEY` on the submitting machine; every `/api/v1/*` call sends
the key (`Authorization: Bearer` or `X-Api-Key`); payload shapes, idempotent
retry semantics, and copy-pasteable recipes are all in
[docs/agent-usage.md](docs/agent-usage.md).

## API

Endpoints: `POST /api/v1/reviews`, `POST /api/v1/frictions`,
`GET /api/v1/submissions` (filtered list), `GET /api/v1/submissions/{id}`.
Unauthenticated: `/health`, `/ready`, `/metrics` (Prometheus).

The contract — request/response schemas per field, error bodies, status codes,
idempotency, curl examples — lives in **[docs/agent-usage.md](docs/agent-usage.md)**
and nowhere else; code, that document, and the e2e suite are kept in lockstep
(see [CLAUDE.md](CLAUDE.md)).

## Layout

```
agent-feedback/
├── CLAUDE.md / AGENTS.md              # Agent guide for working in this repo
├── backend/                           # Go module root
│   ├── pkg/                           # Shared packages (postgres pool, envutil, httputil, observability)
│   └── services/feedback/             # The service
│       ├── cmd/feedback/main.go       # Entry point: config, DI, router, graceful shutdown
│       ├── core/                      # Business logic: validation, idempotent create, list/get
│       ├── handler/                   # HTTP transport: auth middleware, DTOs, error mapping
│       ├── storage/postgres/          # sqlc queries, embedded migrations, DB client
│       ├── Dockerfile
│       ├── justfile
│       └── .env.example
├── infra/agent-feedback/              # docker-compose stack (postgres + feedback)
├── scripts/e2e.sh                     # End-to-end contract suite (all endpoints)
└── docs/
    ├── agent-usage.md                 # API contract for producer agents (start here for integration)
    ├── architecture.md                # Layer model, module strategy (template docs)
    ├── patterns.md                    # Pattern reference (template docs)
    ├── adding-a-service.md            # How this service was bootstrapped (template docs)
    └── conventions.md                 # Naming, imports, errors, logging, testing rules
```

The repo was bootstrapped from a Go monorepo template (chi + pgx/v5 + sqlc,
4-layer architecture, config-from-env, graceful shutdown); the template docs
under `docs/` apply as-is to `backend/services/feedback`.

## Set up and run

### Locally (development)

Requires Go 1.26, `just`, `sqlc`, and a Postgres instance.

```bash
cd backend/services/feedback
cp .env.example .env   # set POSTGRES_URL and API_KEY
just run-local
curl http://localhost:8080/health
```

Migrations run automatically on startup. Useful recipes (from
`backend/services/feedback/`): `just check` (pre-commit gate: fmt, vet,
sqlc-vet, tidy, build), `just test`, `just sqlc-generate`, `just docker-build`.

### As a compose stack

```bash
cd infra/agent-feedback
cp .env.example .env   # set API_KEY and POSTGRES_PASSWORD (mirror it into POSTGRES_URL)
docker compose up -d
```

The service listens on host port `8090` (`8090:8080`); Postgres stays inside the
compose network. Migrations run on container startup — `docker compose up` is the
whole deploy.

## CI

`.github/workflows/ci.yml` runs on every push and PR: `go vet`, build, and the
full test suite with a real Postgres service container (integration tests run,
they don't skip). On pushes to `main` it additionally builds the service image
and pushes it to GitHub Container Registry as
`ghcr.io/foae/agent-feedback:latest` and `:<commit-sha>`. The image is private
(same visibility as the repo).

## Verification

```bash
bash scripts/e2e.sh <API_KEY> [BASE_URL]   # BASE_URL defaults to http://127.0.0.1:8090
```

Exercises every endpoint against a live deployment: auth failures, create,
idempotent replay, validation errors (bad values, unknown fields, oversized
bodies), list filters, get-by-id. It creates test submissions — clean up with
`docker compose down -v` (or delete the rows) afterwards.
