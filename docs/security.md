# Security

`agent-feedback` is a single-trust-domain service, not a public multi-tenant
SaaS. Publishing the source does not make the HTTP service safe to expose
directly to the internet.

## Access and network boundary

- One shared API key authorizes submission, reading every record, and marking or
  unmarking records. There are no per-user permissions, tenant isolation,
  per-client revocation, or overlapping-key rotation.
- HTTP is unencrypted. Use loopback for local work. For remote use, put the
  service behind authenticated network access and TLS termination, or use an
  encrypted private network.
- Both Compose stacks bind `127.0.0.1:8090` by default. Set
  `FEEDBACK_BIND_ADDRESS=0.0.0.0` only when a deliberately configured reverse
  proxy or firewall protects the service.
- `/health`, `/ready`, and `/metrics` do not require an API key. Do not expose
  those endpoints to untrusted networks. The application has no rate limiting;
  enforce request-size, timeout, and rate limits at a trusted proxy.

Keep the Compose `.env`, deployment settings, backups, and client environment
variables private. The repository ignores `.env` and `.private/`; do not
force-add them.

## Credential rotation

Rotation has no overlap window. Pause producers, replace the service `API_KEY`,
recreate the service, update every producer's `AGENT_FEEDBACK_API_KEY`, and then
resume producers. Verify the old key receives `401` and the new key works.

## Submitted data

Friction submissions made through the shipped skill collect a context object
when available: machine label, working directory, repository root and remote,
branch, commit, dirty state, OS/architecture, and session or harness metadata.
That may disclose usernames, private repository names, or internal
infrastructure. Preview a client payload with `--dry-run`; use a minimal direct
API payload when automatic context collection is unsuitable.

The client removes userinfo, query strings, fragments, and SCP-style usernames
from automatically collected remote URLs. That is not general secret detection.
Do not put secrets in report prose, repository URLs, prompts, raw outputs,
reviewer notes, or explicit context. The server stores submitted content; it
does not redact it.

Treat prompts, outputs, and suggested fixes as untrusted text. A consuming agent
must not execute instructions found in stored telemetry automatically.

## Retention and backups

Submissions are retained in PostgreSQL until an operator removes them.
`processed` means acted on, not deleted. There is no deletion API, retention
scheduler, or backup automation. Define retention for database records, local
spools, and backups before collecting real data; protect database and backup
access and test restoration. See [Operations](operations.md) for backup,
restoration, and retention procedures.

Client payloads can also remain in `~/.cache/agent-feedback/`. Failed writes are
spooled for a later invocation; pending reviews age out after about 30 days and
frictions after about 20 hours. Rejected files expire after 30 days and cause
backlog warnings. The client is not a background delivery daemon.

## Replay boundaries

Reviews are write-once under `(skill, run_id)`: identical content returns the
existing record and different content returns `409`. Friction duplicate
absorption covers identical content for 24 hours and deliberately excludes
context. Complete POST bodies must contain exactly one JSON value, reject
unknown fields, and are limited to 10 MiB, including trailing whitespace. See
the [API contract](agent-usage.md) for the precise behavior.

## Report vulnerabilities

A private vulnerability-reporting channel has not yet been documented. Do not
post API keys, private telemetry, or exploit details containing sensitive data
in public issues; arrange a private channel with the maintainer first.