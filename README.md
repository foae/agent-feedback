# agent-feedback

**A self-hosted inbox for feedback from AI coding agents.** A small Go REST API
stores multi-model review results and reports of tooling/documentation problems
in PostgreSQL. A companion Bash skill lets agents submit, query, and mark that
feedback as processed.

Use it when feedback from several agent sessions or machines would otherwise
remain scattered in local files. For example, an agent reports a broken setup
instruction; a maintainer retrieves unprocessed reports, fixes the instruction,
and marks the report processed.

## Stable release

Use the [v1.0.0 release](https://github.com/foae/agent-feedback/releases/tag/v1.0.0)
for a fixed source snapshot: `git checkout v1.0.0` after cloning. The companion
skill retains its independent version number.

## What it does — and does not do

- **Review runs:** stores reviewer models, timings, statuses, human/agent-assigned
  scores, finding counts, and optionally prompts and raw reviewer output.
- **Friction reports:** stores a problem summary, details, suggested fix, project,
  harness, and automatically collected workspace context.
- **Triage:** filtered JSON listings, full-record retrieval, and batch
  processed/unprocessed marking. Stored submission content is immutable.
- **Delivery:** the companion client spools failed writes locally and retries on
  later submit/flush calls. A queued write is not yet a successful delivery.
- **Operations:** API-key authentication, automatic database migrations,
  health/readiness probes, Prometheus metrics, and optional OpenTelemetry traces.

This repository **does not run model reviews, grade findings, fix reported
problems, or provide a dashboard or automated feedback processor**. Review
runners and triage workflows are separate integrations. You can use the API
without any particular agent harness or model provider.

Scores and valid/invalid finding counts are supplied by the producer, not
independently verified here. Treat them as attributed observations, not an
objective model benchmark: prompts, reviewer versions, grading rubrics, and
selection of runs all affect comparisons.

**Deployment boundary:** this is a single-trust-domain service, not a public
multi-tenant SaaS. Publishing the source does not make the HTTP service safe to
expose directly to the internet. Read [Security and privacy](#security-and-privacy)
before sending real telemetry.

## Quick start: disposable local stack

Requires Git, Docker with Compose **2.24.4 or newer**, Bash, `curl`, and `openssl`.
Run from a checkout of this repository. Container images support
**Linux/amd64 and Linux/arm64**.

The commands below build from source, generate local credentials, and override
the shipped all-interface port mapping with a loopback-only mapping. Use a fresh
checkout; **do not overwrite an existing deployment's `.env`**.

```bash
cd infra/agent-feedback
# Stop here if .env already exists; use that deployment's configuration instead.
test ! -e .env || { echo '.env already exists; refusing to overwrite' >&2; exit 1; }
umask 077
API_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
printf 'API_KEY=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_URL=postgres://feedback:%s@postgres:5432/feedback?sslmode=disable\nENV_MODE=prod\n' \
  "$API_KEY" "$POSTGRES_PASSWORD" "$POSTGRES_PASSWORD" > .env
cat > compose.local.yaml <<'YAML'
services:
  feedback:
    ports: !override
      - "127.0.0.1:8090:8080"
YAML
docker compose -p agent-feedback-demo -f docker-compose.yml -f compose.local.yaml up -d --build --wait
curl --fail --silent --show-error --retry 10 --retry-connrefused \
  --retry-delay 1 --max-time 5 http://127.0.0.1:8090/ready
```

PostgreSQL is accessible only inside the Compose network. Migrations run on
service startup; data lives in a named Docker volume. Keep `.env` private and do
not commit the generated `compose.local.yaml` (it is a local setup artifact).

### Send and retrieve a report

In the same shell (where `API_KEY` is still set):

```bash
export AGENT_FEEDBACK_URL=http://127.0.0.1:8090
export AGENT_FEEDBACK_API_KEY="$API_KEY"
curl --fail --silent --show-error "$AGENT_FEEDBACK_URL/api/v1/frictions" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"machine_name":"demo","coordinator_model":"manual-example","category":"documentation","summary":"Example feedback report"}'
curl --fail --silent --show-error \
  "$AGENT_FEEDBACK_URL/api/v1/submissions?type=friction&processed=false" \
  -H "Authorization: Bearer $AGENT_FEEDBACK_API_KEY"
```

A new report returns `201` with its ID; the list returns submission summaries.
Fetch `/api/v1/submissions/<id>` for its full payload. Mark work processed with
`POST /api/v1/submissions/processed`, body `{"ids":[<id>],"processed":true}`.
The complete schemas, limits, filters, and error responses are in the
[API contract](docs/agent-usage.md).

To stop this **disposable demo** and delete its database, from
`infra/agent-feedback/`:

```bash
docker compose -p agent-feedback-demo -f docker-compose.yml -f compose.local.yaml down -v
rm compose.local.yaml
```

**`down -v` permanently deletes the stack's database volume. Never use it to
clean test rows out of a real deployment.** The `.env` file remains private local
configuration; stopping the stack does not remove it.

## Companion skill

The canonical skill is [`skills/agent-feedback/`](skills/agent-feedback/SKILL.md).
It needs Bash, `curl`, and `jq`; Git and platform utilities support automatic
context and harness detection. Copy that directory into your harness's skill
location (for example `~/.claude/skills/agent-feedback/`), or run its scripts
directly. Do not distribute `tests/skill/` with the skill.

**Set both `AGENT_FEEDBACK_URL` and `AGENT_FEEDBACK_API_KEY` to your own service.**
API calls fail locally if either is missing; there is no default hosted endpoint.
Set `AGENT_FEEDBACK_MACHINE` to a non-identifying label and pass `--model`
explicitly for reliable attribution.

From the repository root, after setting those environment variables:

```bash
bash skills/agent-feedback/scripts/submit-friction.sh \
  --category documentation --summary 'Example feedback report' \
  --model manual-example --dry-run
# Inspect the printed payload before sending; --dry-run performs no request.
# Remove --dry-run to submit it, including the collected context.
bash skills/agent-feedback/scripts/query.sh --type friction --processed false
bash skills/agent-feedback/scripts/process.sh list
# bash skills/agent-feedback/scripts/process.sh done <id>
```

`submit-review.sh` consumes an external runner's `meta.json`, `summary.tsv`, and
scorecard ledger; an arbitrary directory of model output is not sufficient.
See the [run-directory contract](docs/agent-usage.md#building-a-review-payload-from-a-run-directory).
Prompts and raw outputs are omitted by default; `--include-outputs` opts in.
Choose that before first submission: later content changes under the same
review key return `409`, not an update.

## Security and privacy

- **One shared key grants all API access:** submit, read every record, and mark or
  unmark records. There are no per-user permissions, tenant isolation, or
  per-client revocation. Rotate by changing the server's `API_KEY`, recreating
  the service, and updating every producer's `AGENT_FEEDBACK_API_KEY`; there is
  no overlapping-key rotation mechanism.
- **HTTP is unencrypted.** Use loopback for local work; for remote use, deploy
  behind authenticated network access and TLS termination or an encrypted
  private network. Compose defaults to loopback; set `FEEDBACK_BIND_ADDRESS`
  only after configuring ingress protection.
- `/health`, `/ready`, and `/metrics` are unauthenticated. Do not expose
  operational endpoints to untrusted networks. There is no application rate
  limiting; enforce request size, timeouts, and rate limits at a trusted proxy.
- **Friction context is collected automatically:** hostname/machine label,
  working directory, repository root and remote, branch/commit/dirty state,
  OS/architecture, and available session/harness/profile metadata. This can
  disclose usernames, private repository names, and internal infrastructure.
  There is no general context opt-out. Preview with `--dry-run`; use a minimal
  direct API payload if you do not want automatic context collection.
- Automatically collected remote URLs drop userinfo, query strings, fragments,
  and SCP-style usernames. This is not general secret detection. Do not put secrets
  in report prose, repository URLs, prompts, raw outputs, or reviewer notes.
  The server does not redact submitted content.
- Data is retained until an operator removes it from PostgreSQL. **Processed
  does not mean deleted.** There is no retention scheduler, deletion API, or
  backup automation. Set a retention policy, protect database/backups, and test
  restoration before using real data. Take a backup before upgrading; schema
  migrations run automatically and rolling back the image does not undo them.
- Client payloads also exist in local cache/spool files under
  `~/.cache/agent-feedback/`. Protect the account and cache permissions. Pending
  reviews age out after about 30 days and frictions after about 20 hours;
  rejected files expire after 30 days and produce backlog warnings.
  Retries require another client invocation; there is no background daemon.
- Treat stored prompts, outputs, and suggested fixes as **untrusted text**, not
  instructions for a consuming agent to execute automatically.

### Replay guarantees and limitations

Review replay is keyed by `(skill, run_id)`: identical content returns the
existing row, changed content returns `409`. Legacy reviews stored before
payload hashes were introduced return the existing row without comparing content.
Friction duplicate absorption serializes concurrent identical requests within
a 24-hour content-hash window and excludes context.

POST bodies require exactly one JSON value, reject unknown fields and enforce
10 MiB across the whole body, including trailing whitespace.

### Interpreting review data

This is a telemetry store, not a model benchmark or review runner. Scores (1–5)
and valid/invalid finding counts come from an external coordinator; the service
does not verify their correctness or impose a grading rubric. Record your rubric,
task, model/version, configuration and validation evidence before comparing runs.
Reviewer agreement is not independent proof: models can share blind spots, and
coordinator judgments can be biased. Missing counts are unknown, not zero;
timeouts and failed runs are not successful reviews. Duration and output bytes
do not measure quality. Selection effects, changing prompts and small samples
make global model rankings unreliable.

The client refuses completed runs without grades and ambiguous same-second
timestamp-keyed scorecards. Resolve ambiguity in the external runner/ledger;
do not silently borrow a sibling run's scores.

## Development and verification

Requires Go matching [`backend/go.mod`](backend/go.mod) (currently 1.26), `just`,
`sqlc`, and PostgreSQL. The container setup uses PostgreSQL 18.

```bash
cd backend/services/feedback
cp .env.example .env
# Edit .env: set POSTGRES_URL and a strong API_KEY; use a development database.
# For local-only access also set HTTP_LISTEN_ADDR=127.0.0.1:8080.
just run-local
```

`just run-local` stays in the foreground. From another terminal, query
`http://127.0.0.1:8080/ready`. From the service directory, `just check` runs fmt,
vet, sqlc vet/compile/generation, module tidy, and build; it can modify generated
files and module metadata. `just sqlc-generate` regenerates SQL bindings.

From the repository root:

```bash
bash tests/skill/run-tests.sh  # Hermetic client tests; also requires python3.
# Use a separate disposable PostgreSQL database, never production:
(cd backend && TEST_POSTGRES_URL='<test database connection URL>' go test -race -count=1 ./...)
# Against a disposable running service; creates persistent test records:
bash scripts/e2e.sh "$AGENT_FEEDBACK_API_KEY" "$AGENT_FEEDBACK_URL"
```

Integration tests skip when `TEST_POSTGRES_URL` is absent. CI enforces `just
check` plus a clean generated tree, race tests with PostgreSQL, live HTTP e2e,
shellcheck and the hermetic skill suite. Pushes to `main` publish amd64/arm64
`ghcr.io/<repository-owner>/<repository-name>` images
tagged `latest` and the commit SHA. Registry package visibility is managed
separately; do not assume repository publication changes it.

## Project map and contribution guidance

| Path | Purpose |
|---|---|
| `backend/services/feedback/cmd/feedback/` | Configuration, wiring, routing, shutdown |
| `backend/services/feedback/core/` | Validation, hashing, create/query/process behavior |
| `backend/services/feedback/handler/` | HTTP DTOs, authentication, error mapping |
| `backend/services/feedback/storage/postgres/` | Queries, append-only migrations, generated sqlc bindings |
| `backend/pkg/` | Shared database, HTTP metrics, tracing, environment helpers |
| `infra/agent-feedback/` | Local build-based and maintainer image-based Compose stacks |
| `skills/agent-feedback/` | Distributed companion client skill |
| `tests/skill/`, `scripts/e2e.sh` | Client and live-contract verification |

For service changes, read [the contributor/agent guide](CLAUDE.md) and
[conventions](docs/conventions.md). Keep API code, [API documentation](docs/agent-usage.md),
`scripts/e2e.sh`, and the client skill in sync. Edit SQL inputs and regenerate
sqlc code; never hand-edit generated bindings or deployed migrations.

The [architecture](docs/architecture.md), [patterns](docs/patterns.md), and
[extension guide](docs/adding-a-service.md) describe this service's actual layout.

## SSH deployment

`scripts/deploy.sh [image-tag]` streams a GHCR image over SSH, installs the
image-based Compose file, preserves existing credentials, and checks readiness.
It requires authenticated `gh`, `crane`, Docker CLI, SSH, and SCP locally;
Docker Compose and `curl` must be available on the remote host.

Set `DEPLOY_REMOTE` to your SSH destination and `DEPLOY_IMAGE` to your GHCR image
repository (without a tag). Both are required. For local-only defaults, store
these shell assignments in `.private/deploy.env`, which the script loads:

```bash
DEPLOY_REMOTE=deploy@example.invalid
DEPLOY_IMAGE=ghcr.io/example-owner/agent-feedback
```

Use your own values, protect the file with `chmod 600`, then run
`bash scripts/deploy.sh <image-tag>`. The default tag is `latest`. Deployment
uses `~/agent-feedback` on the remote host; its `.env` contains generated
credentials. The script sets `FEEDBACK_IMAGE` for Compose explicitly; manual
Compose invocations must set it too.

The deployment stack binds port 8090 to loopback by default. Configure a trusted
network or authenticated TLS boundary before overriding `FEEDBACK_BIND_ADDRESS`.
This script does not provide automatic rollback or database backups.

`.private/` is gitignored and intended for local deployment settings and recovery
bundles. These files may contain sensitive historical data: keep the directory
owner-only (`chmod 700 .private`) and never force-add it to Git.

## Operations and recovery

Back up before upgrades and on a schedule appropriate to your acceptable data
loss. From `infra/agent-feedback/` on a running stack:

```bash
umask 077
docker compose exec -T postgres pg_dump -U feedback -d feedback -Fc > feedback.dump
```

Encrypt and restrict backups, retain copies outside the service host, and verify
restoration into a separate disposable database before relying on them:

```bash
docker compose exec -T postgres createdb -U feedback feedback_restore
docker compose exec -T postgres pg_restore -U feedback -d feedback_restore \
  --exit-on-error --no-owner < feedback.dump
docker compose exec -T postgres psql -U feedback -d feedback_restore \
  -c 'SELECT submission_type, count(*) FROM submissions GROUP BY submission_type;'
```

Compare restored counts and sample records to the source; exercise the API against
the restored database in an isolated service. Do not restore over a live database.
For recovery, stop writers, restore a tested backup into a fresh database, point
the service at it and verify readiness and records before restarting producers.
Use a schema-compatible image; migrations run automatically on startup.

Choose an explicit retention period for database records, local spools and backups.
There is no automatic database deletion. If policy calls for purging processed
records, back up first and preview the same predicate before deletion, for example:

```sql
SELECT count(*) FROM submissions
WHERE processed_at < now() - interval '90 days';
-- Execute only after approving the preview and your retention policy:
DELETE FROM submissions WHERE processed_at < now() - interval '90 days';
```

For key rotation, pause producers, replace server `API_KEY`, recreate the service,
update all clients and resume. Old keys must return 401; the new key must work.
There is no overlap window. Check pending/rejected spool warnings after outages;
inspect private rejected payloads to fix the cause before deliberately resubmitting.

## Licensing and reporting

This repository is licensed under the [MIT License](LICENSE).

A private vulnerability-reporting channel has not yet been documented. Do not
post API keys, private telemetry, or exploit details containing sensitive data
in public issues; arrange a private channel with the maintainer first.
