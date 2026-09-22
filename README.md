# agent-feedback

A self-hosted inbox for feedback from AI coding agents. Agents on any machine,
in any harness, report what slowed them down; later an agent triages the queue
with a human and fixes the causes. Go, SQLite, one container, one API key.

Two parts:

| Part | What it is | Where |
|---|---|---|
| **The service** | HTTP API that stores write-once submissions (frictions, review runs, events) and a processed mark | this repository, one binary |
| **Two skills** | `agent-feedback`: submit and read, installed for every harness on every machine. `agent-feedback-triage`: process the queue, only when the user invokes it (`/agent-feedback-triage`) | [`skills/`](skills/) |

## Start here

| You want to | Read |
|---|---|
| Install the skill and file feedback from an agent | [`skills/agent-feedback/SKILL.md`](skills/agent-feedback/SKILL.md) |
| Triage the queue | [`skills/agent-feedback-triage/SKILL.md`](skills/agent-feedback-triage/SKILL.md) |
| Call the API directly | [`docs/api.md`](docs/api.md) |
| Run, deploy, back up, migrate | [`docs/operate.md`](docs/operate.md) |
| Uninstall the skills, the service, or a 1.x PostgreSQL stack | [`docs/operate.md#uninstall`](docs/operate.md#uninstall) |
| Change the code | [`CLAUDE.md`](CLAUDE.md) then [`docs/develop.md`](docs/develop.md) |
| Trust boundary and credentials | [`docs/security.md`](docs/security.md) |
| Versions and upgrade notes | [`docs/releases.md`](docs/releases.md) |

## Five-minute local run

```bash
git clone https://github.com/foae/agent-feedback.git && cd agent-feedback
git checkout v2.0.0
cd infra/agent-feedback && umask 077 && printf 'API_KEY=%s\n' "$(openssl rand -hex 32)" > .env
docker compose up -d --build --wait
export AGENT_FEEDBACK_URL=http://127.0.0.1:8090 AGENT_FEEDBACK_API_KEY=$(sed -n 's/^API_KEY=//p' .env)
bash ../../skills/agent-feedback/scripts/submit-friction.sh --category test --summary "hello" --model manual
bash ../../skills/agent-feedback/scripts/process.sh list
```

Needs Docker with Compose, `curl`, `jq`, `openssl`. The service binds
`127.0.0.1:8090`; the database lives in a named volume.

## Uninstall

Three parts, each removable on its own: the skills on every machine (delete
the skill directories or links, `~/.cache/agent-feedback/`, and the
`AGENT_FEEDBACK_*` variables from shell profiles), the 2.x service (`docker
compose down -v` in the deploy directory after a `feedback backup`), and a
leftover 1.x PostgreSQL stack (dump first, then `down -v`; its compose file
needs `FEEDBACK_IMAGE` set before it parses). Exact commands, including the
1.x case, in [`docs/operate.md#uninstall`](docs/operate.md#uninstall).

## What it is not

Not a review runner, benchmark, dashboard or automated fixer. It stores what
agents report and lets a processor work through it. Records are never
overwritten: a correction is a new submission.

MIT licensed. Current stable release: [v2.2.0](https://github.com/foae/agent-feedback/releases/tag/v2.2.0).
