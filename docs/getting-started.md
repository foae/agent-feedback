# Getting started

This guide starts a disposable local `agent-feedback` stack and sends one
friction report. The stack is for one trusted environment; read
[Security](security.md) before using real telemetry.

## Prerequisites and installation

For the Compose stack, install Git, Docker with Compose 2.24.4 or newer, Bash,
`curl`, and `openssl`. The companion client skill also requires `jq`. Container
images support Linux/amd64 and Linux/arm64.

Use the current stable source snapshot when you want a fixed checkout:

```bash
git clone https://github.com/foae/agent-feedback.git
cd agent-feedback
git checkout v1.0.1
```

## Configure and start the local stack

The checked-out local Compose stack builds the service source and publishes it
at `127.0.0.1:8090` by default. PostgreSQL is available only on the Compose
network. Do not overwrite an existing deployment's `.env`.

```bash
cd infra/agent-feedback
test ! -e .env || { echo '.env already exists; refusing to overwrite' >&2; exit 1; }
umask 077
API_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
printf 'API_KEY=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_URL=postgres://feedback:%s@postgres:5432/feedback?sslmode=disable\n' \
  "$API_KEY" "$POSTGRES_PASSWORD" "$POSTGRES_PASSWORD" > .env
docker compose up -d --build --wait
curl --fail --silent --show-error --retry 10 --retry-connrefused \
  --retry-delay 1 --max-time 5 http://127.0.0.1:8090/ready
```

`infra/agent-feedback/.env.example` lists all stack configuration. Compose
requires nonempty `API_KEY`, `POSTGRES_PASSWORD`, and `POSTGRES_URL`. The
Postgres URL must use the same URL-encoded password as `POSTGRES_PASSWORD`; the
hexadecimal value above needs no further encoding. Keep `.env` private and out
of Git.

To intentionally expose the service beyond loopback, set
`FEEDBACK_BIND_ADDRESS=0.0.0.0` in the stack `.env` only after providing the
protected ingress described in [Security](security.md). Both supplied Compose
stacks use this loopback default.

## Send and retrieve a report

In the shell that created `API_KEY`:

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

A new report returns `201` with its ID; a list returns submission summaries.
Fetch `/api/v1/submissions/<id>` for the full payload. To mark work processed,
POST `{"ids":[<id>],"processed":true}` to `/api/v1/submissions/processed`.
The [API contract](agent-usage.md) defines every schema, limit, filter, and
error response.

## Install the companion skill

Copy [`skills/agent-feedback/`](../skills/agent-feedback/) into your harness's
skill location, for example `~/.claude/skills/agent-feedback/`. Do not copy
`tests/skill/` with it. Set both `AGENT_FEEDBACK_URL` and
`AGENT_FEEDBACK_API_KEY`; the skill has no hosted default endpoint.

```bash
# Run from the repository root after setting the two environment variables.
bash skills/agent-feedback/scripts/submit-friction.sh \
  --category documentation --summary 'Example feedback report' \
  --model manual-example --dry-run
bash skills/agent-feedback/scripts/query.sh --type friction --processed false
bash skills/agent-feedback/scripts/process.sh list
# bash skills/agent-feedback/scripts/process.sh done <id>
```

`--dry-run` validates and prints the payload without making a request. Remove it
to submit; doing so includes the client-collected context. Always pass `--model`
(or set `AGENT_FEEDBACK_MODEL`) for useful attribution. `submit-review.sh`
requires the external runner's `meta.json`, `summary.tsv`, and scorecard ledger;
see the [run-directory contract](agent-usage.md#building-a-review-payload-from-a-run-directory).
Prompts and raw outputs are omitted unless `--include-outputs` is selected.

## Stop the disposable stack

From `infra/agent-feedback/`:

```bash
docker compose down -v
```

`down -v` permanently deletes the stack's database volume. Do not use it on a
real deployment merely to remove test rows. It leaves `.env` in place; protect
or remove that private local configuration separately.