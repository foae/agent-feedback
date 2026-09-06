# Operations

## Health and lifecycle

`GET /health` reports process liveness. `GET /ready` includes a PostgreSQL ping
and returns unavailable while the service drains for shutdown. `GET /metrics`
serves Prometheus metrics. These endpoints are unauthenticated, so restrict
network access as described in [Security](security.md).

The supplied Compose stacks health-check `/ready`, wait for PostgreSQL before
starting the feedback service, and grant the container two minutes to stop. The
service defaults to a 90-second graceful-shutdown timeout.

## Back up and restore

Before an upgrade and on a schedule suitable for your retention policy, create
an application-consistent PostgreSQL dump. From `infra/agent-feedback/` on a
running stack:

```bash
umask 077
docker compose exec -T postgres pg_dump -U feedback -d feedback -Fc > feedback.dump
```

Encrypt and restrict the backup, retain a copy outside the service host, and
validate it in a separate disposable database before relying on it:

```bash
docker compose exec -T postgres createdb -U feedback feedback_restore
docker compose exec -T postgres pg_restore -U feedback -d feedback_restore \
  --exit-on-error --no-owner < feedback.dump
docker compose exec -T postgres psql -U feedback -d feedback_restore \
  -c 'SELECT submission_type, count(*) FROM submissions GROUP BY submission_type;'
```

Compare restored counts and sample records with the source, then exercise an
isolated service against the restored database. Never restore over a live
database. For recovery, stop writers, restore a tested backup into a fresh
database, point the service at it, verify readiness and records, and only then
restart producers. Use a schema-compatible image: migrations run automatically
on startup, and rolling back an image does not undo migrations.

## Retention

There is no automatic database deletion. Choose an explicit retention period
for records, local spools, and backups. If policy calls for purging processed
records, back up first and preview the exact predicate before deletion:

```sql
SELECT count(*) FROM submissions
WHERE processed_at < now() - interval '90 days';
-- Execute only after approving the preview and your retention policy:
DELETE FROM submissions WHERE processed_at < now() - interval '90 days';
```

## Interpret review data carefully

The service records external coordinator scores and valid/invalid finding counts;
it does not verify them or impose a grading rubric. Treat them as attributed
observations, not a model benchmark. Preserve the rubric, task, model/version,
configuration, and validation evidence before comparing runs.

Reviewer agreement is not independent proof: models can share blind spots, and
coordinator judgments can be biased. Missing counts are unknown, not zero;
timeouts and failed runs are not successful reviews. Duration and output bytes
do not measure quality. Selection effects, changing prompts, and small samples
make global model rankings unreliable.

## After incidents

After an outage, inspect client spool-backlog warnings and repair rejected
payloads before deliberately resubmitting. For an API-key change, follow the
no-overlap rotation procedure in [Security](security.md).