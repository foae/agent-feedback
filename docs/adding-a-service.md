# Adding a Service

Step-by-step guide for bootstrapping a new service from the example template.

Throughout this guide, replace `myservice` with your actual service name and `myentity` with your primary domain entity (e.g., `bucket`, `credential`, `job`).

---

## 1. Copy the Example Service

```bash
cp -r backend/services/example backend/services/myservice
```

## 2. Rename: Search and Replace

These replacements must be applied across all files in `backend/services/myservice/`:

| Find | Replace | Files affected |
|------|---------|----------------|
| `services/example` | `services/myservice` | All `.go` files (import paths) |
| `example` (binary name) | `myservice` | `cmd/example/` dir name, `justfile`, `Dockerfile` |
| `item` / `Item` (entity) | `myentity` / `MyEntity` | `core/`, `handler/`, `storage/`, `q.sql`, migrations |

Concretely:

```bash
cd backend/services/myservice

# Rename cmd directory
mv cmd/example cmd/myservice

# Fix import paths in all Go files
find . -name '*.go' -exec sed -i 's|services/example|services/myservice|g' {} +

# Fix justfile
sed -i 's/SERVICE_NAME := "example"/SERVICE_NAME := "myservice"/' justfile

# Fix Dockerfile
sed -i 's/example/myservice/g' Dockerfile
```

Then manually rename entity-specific files and types (item -> myentity). This is intentionally not scripted because entity naming requires thought about your domain.

## 3. Define Your Schema

**Write the migration:**

Delete the example migration and create your own:

```bash
rm storage/postgres/migrations/001_items.up.sql
rm storage/postgres/migrations/001_items.down.sql
```

Create `storage/postgres/migrations/001_myentities.up.sql`:

```sql
CREATE TABLE IF NOT EXISTS myentities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    owner_id VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PROVISIONING',
    -- your domain-specific columns here
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT myentities_name_owner_unique UNIQUE (name, owner_id)
);

CREATE INDEX IF NOT EXISTS idx_myentities_owner_id ON myentities(owner_id);
CREATE INDEX IF NOT EXISTS idx_myentities_status ON myentities(status);
```

Create the corresponding `001_myentities.down.sql`:

```sql
DROP TABLE IF EXISTS myentities;
```

**Write queries in `q.sql`:**

Replace the example queries with your entity-specific queries. Keep the sqlc annotation format:

```sql
-- name: CreateMyEntity :one
INSERT INTO myentities (name, owner_id, status)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetMyEntityByID :one
SELECT * FROM myentities WHERE id = $1 LIMIT 1;
```

**Update `sqlc.yaml`:**

The `schema` field points at the migrations directory. No change needed unless you renamed it. The `queries` field points at `q.sql`. No change needed.

**Regenerate:**

```bash
cd storage/postgres && sqlc generate
```

This overwrites everything in `sqlc/`. Verify the generated model matches your schema.

## 4. Define Core Types

Edit `core/service.go`:

- Replace sentinel errors with your domain-specific ones. Keep the pattern: one `var` block, all errors as `errors.New(...)`.
- Update the `Service` struct if you need additional dependencies (e.g., an external API client, a cache).
- Update the constructor to accept and validate those dependencies.

```go
var (
    ErrMyEntityNotFound  = errors.New("myentity not found")
    ErrMyEntityDenied    = errors.New("myentity does not belong to this owner")
    ErrInvalidInput      = errors.New("invalid input")
)

type Service struct {
    db       *postgres.Client
    extAPI   *somepackage.Client  // additional dependency
}
```

## 5. Implement Core Methods

Follow the patterns from the example service:

- **Create:** INSERT with ON CONFLICT for idempotency. See `core/item_create.go`.
- **Delete:** Validate ownership -> delete. See `core/item_delete.go`.
- **List:** Filter by owner at the query level. Return empty slice (not nil) when no results. See `core/item_list.go`.
- **Get:** Fetch by ID, validate ownership in Go (not in the query). See `core/item_create.go` `GetItem` method.

Rename files: `item_create.go` -> `myentity_create.go`, etc.

If your service does not need the state machine pattern (PROVISIONING/ACTIVE/DELETING), simplify. The pattern exists for services that coordinate with external systems. A purely CRUD service can skip intermediate states.

## 6. Wire Up Handlers

**`types.go`:** Define request/response DTOs for your entity. Follow the existing pattern: separate `Create*Request` and `*Response` structs, all with JSON tags.

**`item.go` -> `myentity.go`:** Rename and update each handler function. The structure stays the same:

1. Extract owner ID from header.
2. Parse request body or URL params.
3. Call core method.
4. On error, map via `mapMyEntityError()` and `writeError()`.
5. On success, convert to response DTO and `writeJSON()`.

**`errors.go`:** Update the error mapping function to use your new sentinel errors:

```go
func mapMyEntityError(err error) int {
    switch {
    case errors.Is(err, core.ErrMyEntityNotFound):
        return http.StatusNotFound
    case errors.Is(err, core.ErrMyEntityDenied):
        return http.StatusForbidden
    // ...
    }
}
```

**`helpers.go`:** Update `itemToResponse` -> `myEntityToResponse`. Update the import of the sqlc model type.

## 7. Update main.go

In `cmd/myservice/main.go`:

- Update the `config` struct with any new env vars your service needs.
- Update the DI section: create any new clients, pass them to `core.New(...)`.
- Update the route registration:

```go
r.Route("/api/v1", func(api chi.Router) {
    api.Post("/myentities", h.HandleCreateMyEntity())
    api.Get("/myentities", h.HandleListMyEntities())
    api.Get("/myentities/{id}", h.HandleGetMyEntity())
    api.Delete("/myentities/{id}", h.HandleDeleteMyEntity())
})
```

- If you don't need the background worker, remove the worker context, `NewWorker`, and `StartWorker` lines.

## 8. Update Dockerfile and justfile

**Dockerfile:** Should already be correct from step 2. Verify the build path and binary name:

```dockerfile
RUN go build -o /opt/myservice ./services/myservice/cmd/myservice
```

**justfile:** Verify `SERVICE_NAME` is correct. The shared recipes in `service.just` derive all paths from it.

## 9. Update .env.example

Document all env vars your service uses. Include required vars without defaults, optional vars with their defaults, and DNS pinning companions:

```bash
# Required
POSTGRES_URL=postgres://postgres:postgres@localhost:5432/myservice?sslmode=disable

# Optional
SERVICE_NAME=myservice
# ...

# DNS pinning (optional)
# POSTGRES_URL_HOST=custom-hostname.internal
```

## 10. Verification Checklist

Run from `backend/`:

```bash
# Syntax and static analysis
go vet ./services/myservice/...

# Build
go build ./services/myservice/cmd/myservice

# Tests (write them first or now)
go test -race -v ./services/myservice/...

# Regenerate sqlc and verify no diff
cd services/myservice/storage/postgres && sqlc generate
git diff --exit-code services/myservice/storage/postgres/sqlc/
```

Manual checks:

- [ ] Start the service locally: `ENV_MODE=dev go run ./services/myservice/cmd/myservice`
- [ ] `GET /health` returns 200
- [ ] `GET /ready` returns 200
- [ ] `GET /metrics` returns Prometheus text format
- [ ] CRUD endpoints work with `X-Owner-Id` header
- [ ] `.env.example` documents all env vars

## 11. Add CI Workflow

Create `.github/workflows/myservice.yml` with path-gated triggers:

```yaml
name: myservice CI

on:
  push:
    branches: [main]
    paths:
      - 'backend/services/myservice/**'
      - 'backend/pkg/**'
  pull_request:
    paths:
      - 'backend/services/myservice/**'
      - 'backend/pkg/**'
```

Include `backend/pkg/**` in the trigger paths so that shared package changes also trigger your service's CI. The workflow should build the Docker image and run tests.

---

## Quick Reference: Files to Touch

| Step | Files |
|------|-------|
| Copy | `services/example/` -> `services/myservice/` |
| Rename binary | `cmd/example/` -> `cmd/myservice/`, `justfile`, `Dockerfile` |
| Import paths | Every `.go` file |
| Schema | `migrations/001_*.sql` |
| Queries | `q.sql` |
| Codegen | `sqlc generate` |
| Core types | `core/service.go` |
| Core methods | `core/myentity_*.go` |
| Handler | `handler/myentity.go`, `handler/types.go`, `handler/errors.go`, `handler/helpers.go` |
| Wiring | `cmd/myservice/main.go` |
| Config | `.env.example` |
| CI | `.github/workflows/myservice.yml` |
