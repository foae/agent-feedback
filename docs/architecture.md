# Architecture

## Module Strategy

There is a single `go.mod` at `backend/`. All services under `backend/services/` and all shared packages under `backend/pkg/` share one dependency tree. This means:

- One `go.sum`, one dependency resolution pass, one `go mod tidy`.
- Shared packages (`pkg/`) are imported directly without versioning gymnastics.
- CI builds per-service by path (e.g., `go build ./services/example/cmd/example`), not per-module.

The `backend/` directory exists to create a clean module boundary. Go tooling (build, test, vet) stays scoped to Go code. Everything outside `backend/` -- docs, infra configs, CI workflows -- is not part of the Go module.

## The 4-Layer Model

Every service follows a strict 4-layer architecture:

```
cmd/         Entry point, config, DI, router, middleware, graceful shutdown
  |
  v
core/        Business logic, sentinel errors, state machines, workers
  |
  v
handler/     HTTP transport: request parsing, response writing, error mapping
  |
  v
storage/     Data access: DB client, migrations, sqlc queries
```

### cmd (Entry Point)

**What goes here:** Config struct with `env` tags, logger setup, OTel init, DB client creation, core `Service` construction, handler creation, Chi router with middleware stack, HTTP server lifecycle, graceful shutdown.

**File:** `cmd/<service>/main.go` -- single file, procedural, top-to-bottom boot sequence.

**Key property:** cmd is the only layer that knows about all other layers. It wires everything together. See `cmd/example/main.go`.

### core (Business Logic)

**What goes here:** The `Service` struct holding dependencies (DB client), sentinel errors (`ErrItemNotFound`, etc.), business methods (create, delete, list), state machine transitions (PROVISIONING -> ACTIVE -> DELETING), background workers.

**What does NOT go here:** Anything from `net/http`. No request/response types, no status codes, no headers. Core does not know it's behind an HTTP server.

**Key files:**
- `core/service.go` -- Service struct, constructor, Close(), sentinel errors
- `core/item_create.go` -- Idempotent creation with state machine
- `core/item_delete.go` -- Deletion with rollback
- `core/worker.go` -- Background periodic task

### handler (HTTP Transport)

**What goes here:** The `Handler` struct (holds `*core.Service`), HTTP handler functions returning `http.HandlerFunc`, request/response DTOs (`types.go`), error-to-status-code mapping (`errors.go`), helpers for JSON writing and owner extraction (`helpers.go`).

**What does NOT go here:** Business logic. The handler is a translator: HTTP request -> core method call -> HTTP response. If you're writing an `if` that makes a business decision, it belongs in core.

**Import rule:** Handler imports `core` (to call methods and map errors). Handler imports `storage/postgres/sqlc` (to read generated model types for response conversion). Handler does NOT import `storage/postgres` (the DB client).

### storage (Data Access)

**What goes here:** DB client wrapper, embedded SQL migrations, sqlc config, sqlc-generated code, raw SQL queries (`q.sql`).

**What does NOT go here:** Business logic, HTTP concerns, or anything that depends on the core layer.

**Key files:**
- `storage/postgres/client.go` -- Wraps `pkg/postgres`, runs migrations, exposes `Queries()` for sqlc
- `storage/postgres/q.sql` -- All SQL queries in sqlc annotation format
- `storage/postgres/sqlc.yaml` -- sqlc code generation config
- `storage/postgres/sqlc/` -- Generated code (never edit)
- `storage/postgres/migrations/` -- Embedded `.up.sql` / `.down.sql` files

## Dependency Flow

```
                    cmd/example/main.go
                   /        |          \
                  v         v           v
              core/     handler/    storage/postgres/
                |           |           |
                v           |           v
        storage/postgres/   |     pkg/postgres
        sqlc (models)       |
                            v
                    core/ + storage/postgres/sqlc (models)
```

Rules:
- `cmd` depends on everything (it's the wiring point).
- `core` depends on `storage/postgres` (the client) and `storage/postgres/sqlc` (generated models).
- `handler` depends on `core` (calls business methods, maps errors) and `storage/postgres/sqlc` (reads model types for response conversion).
- `handler` does NOT depend on `storage/postgres` (the client). It never touches the DB directly.
- `storage/postgres` depends on `pkg/postgres` (shared pool wrapper) and `storage/postgres/sqlc` (generated code).
- `pkg/` packages have zero dependencies on any service code.

## pkg/ Philosophy

`pkg/` contains only genuinely shared, stable utilities. Criteria for inclusion:

1. **Used by 2+ services** (or clearly will be). One-off helpers stay in the service.
2. **Stable interface.** If the API is still evolving, keep it in the service until it settles.
3. **No domain knowledge.** `pkg/` never imports service code. It provides infrastructure primitives (DB pools, metrics middleware, env var helpers, tracing setup), not business logic.

Current packages:

| Package | Purpose |
|---------|---------|
| `pkg/postgres` | PGX pool wrapper with both `pgxpool.Pool` and `database/sql.DB` (for golang-migrate compatibility) |
| `pkg/envutil` | `ReplaceHost()` for DNS pinning via `_HOST` companion env vars |
| `pkg/httputil` | Prometheus `ReqMonitor` middleware for Chi (request count, in-flight, latency histogram) |
| `pkg/observability` | OTel tracing setup (gRPC exporter, optional/skip if no endpoint configured) |

## Service Directory Layout

```
services/example/
  cmd/example/main.go           # Entry point (single file)
  core/
    service.go                  # Service struct, constructor, sentinel errors
    item_create.go              # Per-method files
    item_delete.go
    item_list.go
    worker.go                   # Background worker
  handler/
    handler.go                  # Handler struct, constructor
    item.go                     # HTTP handlers (one file per entity)
    errors.go                   # Sentinel error -> HTTP status mapping
    helpers.go                  # writeJSON, writeError, extractOwnerID
    types.go                    # Request/response DTOs
  storage/postgres/
    client.go                   # DB client, migrations, sqlc wrapper
    q.sql                       # sqlc query definitions
    sqlc.yaml                   # sqlc config
    sqlc/                       # Generated (do not edit)
    migrations/                 # Embedded SQL migrations
  Dockerfile
  justfile
  .env.example
```
