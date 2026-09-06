# Agent-feedback infrastructure

`infra/agent-feedback/` contains the two Compose stacks for the feedback
service:

- `docker-compose.yml` builds the checked-out service for local use.
- `docker-compose.deploy.yml` runs a supplied image; `scripts/deploy.sh` installs
  this file on the configured remote host.
- `.env.example` lists the required runtime configuration.

## Configure a stack

Copy `.env.example` to `.env` in `infra/agent-feedback/` and set every required
value. `.env` is ignored by Git. `API_KEY` must be a generated producer
credential. `POSTGRES_PASSWORD` must be a generated database password, and
`POSTGRES_URL` must use that same URL-encoded password:

```text
postgres://feedback:<POSTGRES_PASSWORD>@postgres:5432/feedback?sslmode=disable
```

Compose refuses missing or empty required values. The Postgres container receives
only its user, database, and password; it never receives `API_KEY` or
`POSTGRES_URL`. The feedback container receives only `API_KEY` and
`POSTGRES_URL`.

## Run locally

With `.env` configured, run `docker compose up --build` from
`infra/agent-feedback/`. The image-based deployment stack is installed by
`scripts/deploy.sh`; it requires explicitly configured `DEPLOY_REMOTE` and
`DEPLOY_IMAGE`.

## Network exposure and lifecycle

Both stacks publish `127.0.0.1:8090` by default. To opt in to host-network
access, set `FEEDBACK_BIND_ADDRESS=0.0.0.0` in the stack's `.env`; do this only
when a deliberately configured reverse proxy or firewall protects the service.

The feedback healthcheck calls its database-aware `/ready` endpoint. The
container has a two-minute stop grace period, covering the service's five-second
readiness withdrawal delay and its 90-second graceful request drain.
