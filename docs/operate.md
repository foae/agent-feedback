# Operate agent-feedback

Install, run, back up, upgrade and migrate the service. One container, one
SQLite file, one API key. Every step is a command an agent can run.

Contents: [Run locally](#run-locally) · [Deploy to a host](#deploy-to-a-host) ·
[Configuration](#configuration) · [Backups](#backups) ·
[Restore and migration](#restore-and-migration) · [Upgrade](#upgrade) ·
[Key rotation](#key-rotation) · [Retention](#retention) · [Monitoring](#monitoring) ·
[Uninstall](#uninstall)

## Run locally

Needs Docker with Compose. From the repository root:

```bash
cd infra/agent-feedback
test ! -e .env || { echo '.env exists; refusing to overwrite' >&2; exit 1; }
umask 077
printf 'API_KEY=%s\n' "$(openssl rand -hex 32)" > .env
docker compose up -d --build --wait
curl --fail --silent --show-error http://127.0.0.1:8090/ready
```

The service listens on `127.0.0.1:8090` and stores its database in the named
volume `feedback-data` (`/data/feedback.db` in the container). First request:

```bash
export AGENT_FEEDBACK_URL=http://127.0.0.1:8090
export AGENT_FEEDBACK_API_KEY=$(sed -n 's/^API_KEY=//p' .env)
bash ../../skills/agent-feedback/scripts/submit-friction.sh --category test --summary "local smoke test" --model manual
bash ../../skills/agent-feedback/scripts/process.sh list
```

Tear down with `docker compose down -v` (deletes the database volume; `.env`
stays).

Without Docker: `go build ./cmd/feedback && API_KEY=dev DATABASE_PATH=/tmp/feedback.db HTTP_LISTEN_ADDR=127.0.0.1:8090 ./feedback`.

## Deploy to a host

Prerequisites on the host: Docker with Compose, `curl`, SSH access. The
image is published by CI to `ghcr.io/foae/agent-feedback` tagged `latest` and
with the commit SHA. The package must be publicly pullable (GitHub package
settings) or the host must be logged in to GHCR.

```bash
DEPLOY_REMOTE=user@host bash scripts/deploy.sh <commit-sha>
```

`scripts/deploy.sh`:

1. copies `infra/agent-feedback/docker-compose.deploy.yml` to
   `~/agent-feedback/docker-compose.yml` on the host;
2. creates `~/agent-feedback/.env` with a generated `API_KEY` on first deploy
   and preserves it afterwards;
3. writes `FEEDBACK_IMAGE=ghcr.io/foae/agent-feedback:<commit-sha>` into that
   `.env` so the pinned image survives later `docker compose up` calls;
4. runs `docker compose pull && docker compose up -d --wait` and checks `/ready`.

Always deploy a commit SHA, never `latest`: an old CI run finishing late can
move `latest` backwards. `DEPLOY_REMOTE` and `DEPLOY_IMAGE` can live in the
gitignored `.private/deploy.env`.

The stack binds `127.0.0.1:8090` on the host. To serve other machines, set
`FEEDBACK_BIND_ADDRESS=0.0.0.0` in the host `.env` only inside a trusted
network or behind TLS; see [security.md](security.md).

## Configuration

Environment variables read by the binary:

| Variable | Default | Meaning |
|---|---|---|
| `API_KEY` | required | the shared key every client sends |
| `DATABASE_PATH` | `/data/feedback.db` | SQLite file; its directory must be writable |
| `HTTP_LISTEN_ADDR` | `0.0.0.0:8080` | inside the container; Compose maps it to `127.0.0.1:8090` |
| `GRACEFUL_SHUTDOWN_TIMEOUT` | `30s` | drain time for in-flight requests |
| `SERVICE_VERSION` | build default | reported in logs |
| `LOG_LEVEL` | `info` | `debug` or `info` |

Compose-level variables (`infra/agent-feedback/.env`): `API_KEY`,
`FEEDBACK_IMAGE` (deploy stack only), `FEEDBACK_BIND_ADDRESS`.

## Backups

Two complementary forms.

**Physical backup** (fastest restore, byte-identical database):

```bash
cd ~/agent-feedback
docker compose exec feedback /opt/feedback backup /data/backup-$(date -u +%Y%m%dT%H%M%SZ).db
docker compose cp feedback:/data/backup-<stamp>.db ./backups/
docker compose exec feedback rm /data/backup-<stamp>.db
```

`feedback backup` uses SQLite's `VACUUM INTO`, which is safe on a live
database in WAL mode. Never copy `feedback.db` from the volume while the
service runs; the `-wal` file holds committed data the main file lacks.

**Logical backup** (portable, inspectable, the migration format):

```bash
bash skills/agent-feedback/scripts/query.sh export > feedback-$(date -u +%Y%m%d).jsonl
```

The client verifies the export header, record count and digest. Store
backups off-host and restrict them: they contain everything agents reported.

## Restore and migration

**Restore a physical backup**: stop the stack, replace `/data/feedback.db` in
the volume (remove any `-wal`/`-shm` files beside it), start the stack, check
`/ready`.

**Restore or import a logical export** into an empty database:

```bash
docker compose stop feedback
docker compose run --rm -v "$PWD/feedback.jsonl:/import.jsonl:ro" feedback import /import.jsonl
docker compose start feedback
```

`feedback import` runs in one transaction and verifies the header, record
count and digest before committing anything. It preserves `id`, `created_at`,
`processed_at`, `resolution` and `payload_hash` (recomputing and checking each
hash; `--trust-hashes` skips the check), advances the id sequence past the
highest id in the stream (skipped rows included, so archived ids are never
reused), and refuses a non-empty database (`--allow-nonempty` to merge) or a
filtered export (`--allow-partial`). `--family friction` imports only that
family from a full export; `--reserve-ids-through N` raises the sequence
further when needed. Flags go before the file name.

**Migrate from the 1.x PostgreSQL deployment**:

1. Stop producers or accept that they spool: the client retries frictions for
   20 hours, reviews and events for 30 days.
2. On the old host, export straight from PostgreSQL with
   `bash scripts/export-v1-postgres.sh > v1.jsonl` (run beside the old
   compose file; it emits the API 1.1 export format, including
   `payload_hash`, and prints the row count).
3. Keep `v1.jsonl` whole: its header and terminator are what the importer
   verifies. Note the highest id in it (`tail -2 v1.jsonl | head -1 | jq .id`).
4. Stop the old stack (`docker compose down`, keep the volume), install the
   new stack in the same directory with `scripts/deploy.sh`, then import
   only the frictions, reserving every old id (flags come before the file):

   ```bash
   docker compose stop feedback
   docker compose run --rm -v "$PWD/v1.jsonl:/import.jsonl:ro" feedback \
     import --family friction --reserve-ids-through <highest id> /import.jsonl
   docker compose start feedback
   ```

   The summary reports `imported`, `skipped` (the archived review rows) and
   the id sequence. Keep `v1.jsonl` as the archive of the review rows.
5. Check `/ready`, list the queue, and compare the friction count and the
   unprocessed count with the export.
6. Keep the old PostgreSQL volume until you are sure; `docker volume rm` it
   afterwards.

Rollback before the new service has accepted writes is starting the old stack
again. After it has, export from the new service first; the old schema cannot
hold events or resolutions.

## Upgrade

`bash scripts/deploy.sh <new-commit-sha>`. Schema changes apply automatically
at startup, forward only; a binary older than the database's schema refuses
to start rather than corrupting it. Take a physical backup first. Rolling back
the image does not roll back the schema.

## Key rotation

No overlap window. Edit `API_KEY` in the host `.env`, `docker compose up -d`,
then update `AGENT_FEEDBACK_API_KEY` on every producer. Spooled payloads on
producers retry with the new key on their next call.

## Retention

Nothing is deleted automatically. `processed` means acted on, not removed.
To purge, export first, then delete inside the container with an explicit
predicate, for example rows processed more than a year ago:

```bash
docker compose exec feedback sh -c 'apk add --no-cache sqlite >/dev/null && sqlite3 /data/feedback.db "DELETE FROM submissions WHERE processed_at < (strftime(\"%s\",\"now\")-31536000)*1000000"'
```

Client spools live in `~/.cache/agent-feedback/spool/` on each producer and
age out on their own.

## Monitoring

- `GET /health`: process is up. `GET /ready`: database answers and schema is
  current; `503` while shutting down.
- `GET /metrics` (Prometheus): `http_requests_total` and
  `http_request_duration_seconds` by route, method and code;
  `submissions_created_total` by family and outcome;
  `feedback_submissions_unprocessed` (the backlog);
  `feedback_db_bytes` (database plus WAL size); `feedback_sqlite_busy_total`
  (writes that waited out the busy timeout, should stay at zero).
- Logs are JSON on stdout: `docker compose logs -f feedback`.

## Uninstall

Three independent parts: the skills on each machine, the 2.x service, and,
where one still exists, the 1.x PostgreSQL stack. Take a backup before
removing any service; the data is gone with the volume.

### Skills, on every machine that has them

1. Find the installed copies: `ls -la ~/.claude/skills/agent-feedback ~/.claude/skills/feedback-triage ~/.agents/skills/agent-feedback ~/.agents/skills/feedback-triage 2>/dev/null`
   and any other harness skill directory you use. Entries may be symlinks into
   a shared checkout; remove the links, then the checkout if nothing else uses it.
2. Flush or discard unsent payloads first: `bash <skill-dir>/scripts/query.sh --flush --limit 1`
   sends whatever is spooled; or delete `~/.cache/agent-feedback/` to drop it.
3. Remove the directories or links, then `rm -rf ~/.cache/agent-feedback`.
4. Remove `AGENT_FEEDBACK_URL`, `AGENT_FEEDBACK_API_KEY`, `AGENT_FEEDBACK_MACHINE`,
   `AGENT_FEEDBACK_MODEL`, `AGENT_FEEDBACK_HARNESS`, `AGENT_FEEDBACK_SESSION_ID`
   and `AGENT_FEEDBACK_REVIEW_DIRS` from shell profiles (`grep -n AGENT_FEEDBACK ~/.zshenv ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null`).
5. Remove any directive in your agent system prompt that tells agents to
   submit friction, and any hook in a review runner that calls `submit-review.sh`.

### The 2.x service (SQLite)

On the host, in the directory holding `docker-compose.yml` (default `~/agent-feedback`):

```bash
cd ~/agent-feedback
docker compose exec feedback /opt/feedback backup /data/final.db && docker compose cp feedback:/data/final.db ./final-backup.db   # keep a copy elsewhere
docker compose down -v          # stops the container and deletes the feedback-data volume
docker image rm $(sed -n 's/^FEEDBACK_IMAGE=//p' .env)
cd ~ && rm -rf ~/agent-feedback  # compose file, .env with the API key, local backups
```

Skip `-v` and the last line to keep the data for a later reinstall. Also
remove any reverse-proxy or firewall rule that exposed port 8090, and any
monitoring scrape of `/metrics`.

### The 1.x service (PostgreSQL)

The 1.x stack is two containers (`feedback`, `postgres`) and a volume named
`<project>_postgres-data`, where `<project>` is the compose project (the
directory name, usually `agent-feedback`). Its `.env` holds `API_KEY`,
`POSTGRES_PASSWORD` and `POSTGRES_URL`, and its compose file may require
`FEEDBACK_IMAGE` to be set before compose will even parse it.

```bash
cd ~/agent-feedback
export FEEDBACK_IMAGE=$(docker inspect --format '{{.Config.Image}}' agent-feedback-feedback-1 2>/dev/null || echo unused:latest)
# Keep the data: a database dump, and the API 1.1 export if you may migrate later
docker compose exec -T postgres pg_dump -U feedback -d feedback -Fc </dev/null > feedback-final.dump
bash /path/to/agent-feedback/scripts/export-v1-postgres.sh </dev/null > v1.jsonl
# Remove
docker compose down -v          # both containers, the network, the postgres-data volume
docker image rm "$FEEDBACK_IMAGE" postgres:18-alpine 2>/dev/null || true
cd ~ && rm -rf ~/agent-feedback
```

If a 2.x service was installed in the same directory during a migration, the
1.x volume is still there under the old name: list it with
`docker volume ls | grep postgres-data` and remove it with
`docker volume rm <name>` once the migration is confirmed. Stale 1.x images
tagged `ghcr.io/foae/agent-feedback:<sha>` can be listed with `docker images ghcr.io/foae/agent-feedback`.

If 1.x was deployed with the old `scripts/deploy.sh`, nothing else was
installed on the host; the local machine may still hold `.private/deploy.env`
in the repository checkout.

### Verify

`curl -s -o /dev/null -w '%{http_code}\n' http://<host>:8090/health` must fail
to connect; `docker ps -a | grep agent-feedback` and `docker volume ls | grep
feedback` must be empty; a fresh shell must have no `AGENT_FEEDBACK_*`
variables.
