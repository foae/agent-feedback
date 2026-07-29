# agent-feedback

A Go JSON REST service that centralizes LLM-agent skill telemetry — multi-llm-review
and second-opinion run results, plus free-form "friction" reports — into Postgres.
Producers (skills, harness directives) currently write this data to per-machine
local files (`~/.cache/multi-llm-review/`, `~/.cache/second-opinion/`); this service
is the control center they submit to instead, so the data can be mined later to
improve skills, tooling, docs, and system prompts across the fleet.

Scope: the service only. Updating the producing skills to POST here is a separate
follow-up.

## API

Full request/response contract, curl examples, and idempotency semantics:
[docs/agent-usage.md](docs/agent-usage.md). Written for agents editing skills to
submit to this service.

Endpoints: `POST /api/v1/reviews`, `POST /api/v1/frictions`,
`GET /api/v1/submissions` (filtered list), `GET /api/v1/submissions/{id}`. All
`/api/v1/*` routes require an API key (`Authorization: Bearer <key>` or
`X-Api-Key: <key>`). `/health`, `/ready`, `/metrics` are open.

## Layout

```
agent-feedback/
├── backend/                           # Go module root
│   ├── go.mod
│   ├── pkg/                           # Shared packages (postgres pool, envutil, httputil, observability)
│   └── services/feedback/             # The service
│       ├── cmd/feedback/main.go       # Entry point: config, DI, router, graceful shutdown
│       ├── core/                      # Business logic: validation, idempotent create, list/get
│       ├── handler/                   # HTTP transport: auth middleware, DTOs, error mapping
│       ├── storage/postgres/          # sqlc queries, embedded migrations, DB client
│       ├── Dockerfile
│       ├── justfile
│       └── .env.example
├── infra/agent-feedback/              # docker-compose deployment (postgres + feedback)
└── docs/
    ├── agent-usage.md                 # API contract for agents (start here for integration)
    ├── architecture.md                # Layer model, module strategy (template docs, unchanged)
    ├── patterns.md                    # Pattern reference (template docs, unchanged)
    ├── adding-a-service.md            # How this service was bootstrapped (template docs, unchanged)
    └── conventions.md                 # Naming, imports, errors, logging, testing rules (unchanged)
```

This repo was bootstrapped from a Go monorepo template; `docs/architecture.md`,
`docs/patterns.md`, `docs/conventions.md`, and `docs/adding-a-service.md` describe
the underlying template conventions (4-layer architecture, sqlc, chi, config-from-env,
graceful shutdown, etc.) and apply as-is to `backend/services/feedback`.

## Run locally

Requires Go 1.24, `just`, `sqlc`, and a Postgres instance.

```bash
cd backend/services/feedback
cp .env.example .env   # edit POSTGRES_URL and API_KEY
just run-local
```

Migrations run automatically on startup. Verify:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/ready
```

Other useful recipes (run from `backend/services/feedback/`):

```bash
just check          # fmt, vet, sqlc-vet, tidy, build — pre-commit gate
just test           # go test -race -v
just sqlc-generate  # regenerate storage/postgres/sqlc/ after editing q.sql or migrations
just docker-build   # build the image
```

## Deploy

Deployed via docker compose (postgres + the service, one host port exposed):

```bash
cd infra/agent-feedback
cp .env.example .env   # edit API_KEY and POSTGRES_PASSWORD
docker compose up -d
```

The service listens on host port `8090` (`8090:8080`), postgres is not exposed
outside the compose network. Migrations run automatically on container startup —
`docker compose up` is the whole deploy.

## Verification

`scripts/e2e.sh <API_KEY> [BASE_URL]` runs an end-to-end smoke test against a
running compose deployment (`BASE_URL` defaults to `http://127.0.0.1:8090`) —
auth, create/idempotent-replay, validation errors, list/get, and creates test
submissions in Postgres. Clean up afterward via `docker compose down -v` or by
deleting the rows.
