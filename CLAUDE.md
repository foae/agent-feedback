# agent-feedback: working in this repo

Go + SQLite HTTP service that stores write-once feedback from AI coding agents
(frictions, review runs, events) plus two Bash skills: `agent-feedback`
(submit/read, installed everywhere) and `feedback-triage` (process the queue).

This file is for agents **changing this repo**. If you only want to **use the
running service**, you need one document: the skill's
[`SKILL.md`](skills/agent-feedback/SKILL.md), or [`docs/api.md`](docs/api.md)
for raw HTTP.

## Route by task

| Task | Go to |
|---|---|
| Change service code | [`docs/develop.md`](docs/develop.md): layout, commands, invisible rules, verification |
| Change the API | [`docs/api.md`](docs/api.md) is the contract; five artifacts move in one commit (see develop.md) |
| Change a skill's scripts | `skills/<name>/scripts/`, then `bash tests/skill/run-tests.sh` and `shellcheck -x` |
| Change docs | Keep the [README](README.md) route table true; one doc per task, no duplicated facts |
| Run, deploy, back up, migrate | [`docs/operate.md`](docs/operate.md) |
| Release | [`docs/releases.md`](docs/releases.md) |

## Commands

```bash
just check                                  # fmt, vet, tidy, build
go test -race -count=1 ./...                # unit + SQLite integration on temp files
just run-local                              # serve on 127.0.0.1:8090 with a temp database
bash scripts/e2e.sh <API_KEY> [BASE_URL]    # live contract suite against a running service
bash tests/skill/run-tests.sh               # hermetic skill-script tests (python3 mock server)
```

## Rules

- Payloads are write-once; only `processed_at` and `resolution` change.
- Hash forms are frozen per family (see develop.md); a change breaks every replay.
- Payloads pass through as raw JSON, never via `map[string]any`.
- Migrations are forward-only, append-only, one transaction each.
- `skills/*/` ship verbatim: no tests, no tooling, no history in comments.
- Docs are written for agents first: lead with the command, state the rule,
  skip the anecdote. Nothing machine-, user- or organization-specific.
- Every delivered change lands in a `vMAJOR.MINOR.PATCH` release.

## Verification before you are done

`just check`, `go test -race -count=1 ./...`, `scripts/e2e.sh` if the API
changed, `tests/skill/run-tests.sh` plus shellcheck if scripts changed, and
every relative link in touched docs resolves.
