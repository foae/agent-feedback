# Patterns

Each pattern is a standalone section. Reference the example service for working implementations.

---

## Config Loading

**WHAT:** Struct-based configuration using `caarlos0/env` with struct tags for env var binding.

**WHY:** Centralizes all config in one place, makes required vs optional explicit, provides typed defaults, fails fast on missing required vars.

**HOW:**

```go
type config struct {
    ServiceName     string        `env:"SERVICE_NAME" envDefault:"example"`
    PostgresURL     string        `env:"POSTGRES_URL,required"`
    WorkerInterval  time.Duration `env:"WORKER_INTERVAL" envDefault:"1h"`
    ShutdownTimeout time.Duration `env:"GRACEFUL_SHUTDOWN_TIMEOUT" envDefault:"90s"`
}
```

- `required` tag = process exits if missing.
- `envDefault` = used when env var is unset. If a var has no default and no `required`, it zero-values silently.
- `time.Duration` fields parse Go duration strings (`1h`, `90s`, `5m`).
- `godotenv.Load()` runs before `env.Parse()` for local `.env` file support. It is a no-op if the file is missing (prod).
- After parsing, apply `envutil.ReplaceHost("POSTGRES_URL", cfg.PostgresURL)` for DNS pinning.

**DNS pinning with ReplaceHost:** For any URL env var `FOO_URL`, set a companion `FOO_URL_HOST=<hostname>` to override just the hostname portion. This supports per-DC DNS overrides in K8s without touching Vault secrets. The function is fail-closed: if the override is set but the URL cannot be parsed, the process exits.

**WHERE:** `cmd/example/main.go` — `config` struct, `env.Parse(&cfg)`, `envutil.ReplaceHost` call.

---

## Structured Logging

**WHAT:** JSON-formatted structured logging via `slog` with environment-aware log levels and OTel trace correlation.

**WHY:** Machine-parseable logs for production log aggregation. Trace IDs in logs let you correlate a log line with its distributed trace.

**HOW:**

- Logger: `slog.NewJSONHandler` to stdout with `LevelDebug` in dev, `LevelInfo` in prod.
- Request logging: `slog-chi` middleware auto-logs every request with method, path, status, latency.
- Noise filtering: Health, ready, and metrics endpoints are excluded from request logs via `slogchi.IgnorePath`.
- OTel correlation: In prod mode (`ENV_MODE=prod`), `slog-chi` injects `trace_id` and `span_id` into every request log line.
- Application logging: Use `slog.InfoContext(ctx, ...)` to propagate request context (and trace IDs) into business logic logs.

**Anti-patterns:**
- Never use `log.Printf` or `fmt.Printf` in core or handler. Use `slog`.
- Never log sensitive data (credentials, tokens, PII).
- Always use structured fields, not string interpolation: `slog.Info("created", "item_id", id)` not `slog.Info(fmt.Sprintf("created %s", id))`.

**WHERE:** `cmd/example/main.go` — `buildLoggerMiddleware()` function, `slog.NewJSONHandler` setup in `main()`.

---

## Graceful Shutdown

**WHAT:** 3-phase shutdown sequence that drains in-flight requests without dropping traffic during K8s rolling deployments.

**WHY:** K8s sends SIGTERM, then waits `terminationGracePeriodSeconds` before SIGKILL. But endpoint de-registration is asynchronous -- kube-proxy and ingress controllers may still route traffic for several seconds after SIGTERM. Without a drain delay, the pod stops accepting requests while traffic is still arriving.

**HOW:**

```
SIGTERM received
    |
    v
Phase 1: shuttingDown.Store(true) --> /ready returns 503
    |
    v
Phase 2: sleep 5s --> K8s endpoint de-registration propagates
    |
    v
Phase 3: httpSrv.Shutdown(ctx) with GRACEFUL_SHUTDOWN_TIMEOUT
    |        also: workerCancel() stops background workers
    v
Process exits
```

- Phase 1 uses `atomic.Bool` so the `/ready` handler is lock-free.
- Phase 2 is a hard 5-second sleep. This is not configurable because it maps to K8s de-registration timing, not application behavior.
- Phase 3 calls `http.Server.Shutdown()` which stops accepting new connections and waits for in-flight requests to complete, up to the timeout.
- Background workers are cancelled via their `context.Context` before HTTP shutdown begins.

**WHERE:** `cmd/example/main.go` — from `signal.Notify(stop, ...)` through end of `main()`.

---

## Health, Ready, and Metrics Endpoints

**WHAT:** Three operational endpoints outside the API route group.

**WHY:** K8s liveness/readiness probes and Prometheus scraping need dedicated endpoints that bypass auth and business logic.

**HOW:**

| Endpoint | Behavior | Used by |
|----------|----------|---------|
| `GET /health` | Always returns `200 OK`. Proves the process is alive. | K8s liveness probe |
| `GET /ready` | Returns `200 READY` normally, `503 SHUTTING_DOWN` during graceful shutdown. | K8s readiness probe |
| `GET /metrics` | Prometheus metrics via `promhttp.Handler()`. Exposes `http_requests_total`, `http_requests_in_flight`, `http_requests_bytes_in_flight`, `http_response_time_seconds`. | Prometheus scraper |

- These are registered directly on the root router, not under `/api/v1`.
- `slog-chi` is configured to suppress request logs for these paths (noise reduction).

**WHERE:** `cmd/example/main.go` — `/health`, `/ready`, `/metrics` route registrations.

---

## Error Handling

**WHAT:** Sentinel errors defined in core, mapped to HTTP status codes in handler.

**WHY:** Core layer has no knowledge of HTTP. Handler translates domain errors to transport-level responses. `errors.Is()` with wrapping preserves the ability to add context at each call site while still matching the root cause.

**HOW:**

1. Define sentinels in `core/service.go`:
   ```go
   var ErrItemNotFound = errors.New("item not found")
   ```

2. Wrap with context in core methods:
   ```go
   return fmt.Errorf("%w: current status is %s", ErrItemNotActive, item.Status)
   ```

3. Map in `handler/errors.go`:
   ```go
   func mapItemError(err error) int {
       switch {
       case errors.Is(err, core.ErrItemNotFound):
           return http.StatusNotFound
       // ...
       default:
           return http.StatusInternalServerError
       }
   }
   ```

4. Use in handler:
   ```go
   status := mapItemError(err)
   writeError(w, status, "create_item_failed", err.Error())
   ```

**Key rule:** The `default` case returns 500. Any unrecognized error is an internal server error. This means new sentinel errors that aren't added to the mapping will surface as 500s -- a safe default, but add the mapping when you add the error.

**WHERE:** `core/service.go` (sentinels), `handler/errors.go` (mapping), `handler/item.go` (usage).

---

## DB Access with sqlc

**WHAT:** Type-safe SQL queries generated by sqlc from annotated `.sql` files.

**WHY:** No ORM abstraction leaks. You write SQL, sqlc generates Go functions with correct types. The generated code uses `pgx/v5` directly. Compile-time safety: if your query doesn't match your schema, `sqlc generate` fails.

**HOW:**

1. Write migrations in `storage/postgres/migrations/` (numbered, `.up.sql` / `.down.sql`).
2. Write queries in `storage/postgres/q.sql` with sqlc annotations:
   ```sql
   -- name: GetItemByID :one
   SELECT * FROM items WHERE id = $1 LIMIT 1;

   -- name: ListItemsByOwner :many
   SELECT * FROM items WHERE owner_id = $1 ORDER BY created_at DESC;

   -- name: UpdateItemStatus :exec
   UPDATE items SET status = $1, updated_at = NOW() WHERE id = $2;
   ```
3. Run `sqlc generate` from `storage/postgres/` (or `just generate` from the service dir).
4. Use generated methods: `s.db.Queries().GetItemByID(ctx, id)`.

**Annotations:** `:one` returns a single row (error if not found), `:many` returns a slice, `:exec` returns no rows.

**Migrations:** Embedded via `//go:embed migrations/*.sql` in `storage/postgres/client.go`. Run automatically at startup when `shouldRunMigrations` is true. Uses `golang-migrate` with the `iofs` source driver.

**Dual connection pools:** `pkg/postgres` provides both a `pgxpool.Pool` (for sqlc/pgx-native queries) and a `database/sql.DB` (for golang-migrate, which requires the stdlib interface). This is a deliberate design choice, not redundancy.

**WHERE:** `storage/postgres/q.sql` (queries), `storage/postgres/sqlc.yaml` (config), `storage/postgres/client.go` (client + migrations).

---

## DB-Level Idempotency

**WHAT:** Use PostgreSQL constraints and `ON CONFLICT` to make writes safe for retries without application-level state tracking.

**WHY:** Clients retry. Networks are unreliable. If a create request is sent twice, the result should be the same. DB constraints enforce this at the lowest level — no race conditions, no application bugs.

**HOW:**

**Idempotent create** (see `core/item_create.go`, `q.sql`):
```sql
INSERT INTO items (name, owner_id)
VALUES ($1, $2)
ON CONFLICT (name, owner_id) DO UPDATE SET updated_at = NOW()
RETURNING *;
```
The unique constraint `(name, owner_id)` prevents duplicates. `ON CONFLICT DO UPDATE` returns the existing row on retry. The caller gets back an item either way — no error handling needed for "already exists."

Use `ON CONFLICT DO NOTHING` instead when you want to silently skip duplicates without returning the row.

**Idempotent delete** (see `core/item_delete.go`):
```
Validate ownership (DB lookup) -> DELETE WHERE id = $1
```
Deleting a non-existent row is a no-op in PostgreSQL. The service returns 404 if the item wasn't found during the ownership check, which is correct for both first-attempt and retry scenarios.

**Schema conventions:**
- `CREATE TABLE IF NOT EXISTS` in migrations
- Name constraints explicitly: `CONSTRAINT items_name_owner_unique UNIQUE (name, owner_id)`
- Always define the unique constraint that your `ON CONFLICT` clause targets

**WHERE:** `core/item_create.go`, `core/item_delete.go`, `storage/postgres/q.sql`, `storage/postgres/migrations/`.

---

## Background Workers

**WHAT:** Periodic goroutines that run on a fixed interval, started from `cmd/`, implemented in `core/`.

**WHY:** Cleanup of stale state, reconciliation, metrics emission -- tasks that run independently of HTTP requests.

**HOW:**

```go
workerCtx, workerCancel := context.WithCancel(context.Background())
defer workerCancel()
worker := core.NewWorker(pg, logger)
go core.StartWorker(workerCtx, worker, cfg.WorkerInterval)
```

- **1-minute startup delay:** The worker waits 60 seconds before its first run. This avoids hammering the DB during service startup (especially during rolling deploys where many pods start simultaneously).
- **Fixed interval:** After the first run, the worker ticks on `cfg.WorkerInterval` (default 1h).
- **Clean shutdown:** The worker's context is cancelled during graceful shutdown (before HTTP drain). The `select` on `ctx.Done()` exits the loop immediately.
- **No panic propagation:** Worker errors are logged, not propagated. A worker failure does not crash the service.

**WHERE:** `core/worker.go` (implementation), `cmd/example/main.go` — `core.NewWorker` / `core.StartWorker` calls in `main()`.

---

## Middleware Stack Order

**WHAT:** Chi middleware registered in a specific order in `cmd/example/main.go`.

**WHY:** Middleware executes in registration order for requests and reverse order for responses. Getting the order wrong causes subtle bugs (e.g., panic recovery not covering other middleware, request IDs missing from logs).

**HOW:**

```go
r.Use(
    middleware.Recoverer,          // 1. Catch panics (must be first)
    middleware.RequestID,          // 2. Generate X-Request-Id
    middleware.RealIP,             // 3. Extract real client IP from X-Forwarded-For
    buildLoggerMiddleware(...),    // 4. Log requests (uses RequestID and RealIP)
    httputil.ReqMonitor(name),    // 5. Prometheus metrics
)
```

**Why this order:**
1. **Recoverer first** -- catches panics from any subsequent middleware or handler. If it were later, a panic in RequestID or RealIP would crash the process.
2. **RequestID before logger** -- the logger needs the request ID to include it in log lines.
3. **RealIP before logger** -- the logger should log the real client IP, not the proxy IP.
4. **Logger before Prometheus** -- request logs include the status code from the response (deferred), metrics also need the status code. Order between these two is less critical, but logger-before-metrics is conventional.

**OTel wrapping:** The entire router is wrapped with `otelhttp.NewHandler` at the `http.Server` level, not as Chi middleware. This ensures every request gets a trace span.

**WHERE:** `cmd/example/main.go` — `r.Use(...)` block in `main()`.

---

## Dockerfile Pattern

**WHAT:** Single-stage Dockerfile that builds a statically-linked binary and runs as a non-root user.

**WHY:** Single-stage is simpler to debug and maintain. `CGO_ENABLED=0` produces a static binary with no libc dependency. Non-root user follows the principle of least privilege.

**HOW:**

```dockerfile
FROM golang:1.24-bookworm

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64

WORKDIR /build
ADD ./ ./

RUN go build -o /opt/example ./services/example/cmd/example

RUN groupadd example && useradd -g example example -d /home/example && \
    chown -R example:example /opt/example && chmod +x /opt/example

USER example
EXPOSE 8080
CMD ["/opt/example"]
```

**Build context:** The Dockerfile lives in `services/example/` but the build context is `backend/` (the module root). This is necessary because the build needs access to `pkg/` and `go.mod`.

**Docker build command** (from repo root):
```bash
docker build -f backend/services/example/Dockerfile backend/
```

**WHERE:** `services/example/Dockerfile`.

---

## Ownership Validation

**WHAT:** Every mutating and read endpoint validates that the requesting owner matches the resource owner.

**WHY:** Multi-tenant system. Without ownership checks, one tenant could read/modify/delete another tenant's resources.

**HOW:**

1. **Extract:** `extractOwnerID(r)` reads `X-Owner-Id` from the request header (set by an upstream auth proxy/gateway).
2. **Reject early:** If the header is missing, return `401 Unauthorized` immediately in the handler. This check happens before any core method call.
3. **Validate in core:** Core methods like `GetItem` and `DeleteItem` fetch the resource, then compare `item.OwnerID != ownerID`. Mismatch returns `ErrItemAccessDenied`.
4. **Map in handler:** `ErrItemAccessDenied` maps to `403 Forbidden`.

**Scope by owner:** List endpoints filter by owner at the query level (`WHERE owner_id = $1`). There is no "list all items across all owners" endpoint.

**WHERE:** `handler/helpers.go` (extractOwnerID), `handler/item.go` (early rejection), `core/item_create.go` and `core/item_delete.go` (ownership validation).
