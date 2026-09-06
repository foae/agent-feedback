# agent-feedback

**A self-hosted inbox for feedback from AI coding agents.** The Go API stores
multi-model review results and tooling or documentation friction reports in
PostgreSQL. The included Bash skill submits, queries, and marks that feedback
processed.

Use it to make feedback from separate agent sessions and machines actionable in
one place. It is a telemetry store—not a review runner, benchmark, dashboard,
or automated processor.

## Features

- Write-once review and friction submissions, with replay protection and
  friction duplicate absorption.
- Filtered retrieval and batch processed/unprocessed marking.
- API-key authentication, automatic PostgreSQL migrations, health/readiness,
  Prometheus metrics, and optional OpenTelemetry tracing.
- A harness-agnostic client skill with local spooling and retry on a later
  invocation.

## Start here

The current stable source release is [v1.0.1](https://github.com/foae/agent-feedback/releases/tag/v1.0.1).
Clone it and check out the tag for a fixed snapshot:

```bash
git clone https://github.com/foae/agent-feedback.git
cd agent-feedback
git checkout v1.0.1
```

For a local stack, you need Git, Docker with Compose 2.24.4 or newer, Bash,
`curl`, and `openssl`. Follow the [getting-started guide](docs/getting-started.md)
for the configuration and first request. The bundled client additionally needs
`jq`.

## Documentation

- [Getting started](docs/getting-started.md) — local installation, configuration,
  first API request, and client skill.
- [Security](docs/security.md) — trust boundary, credentials, network exposure,
  submitted data, and retention.
- [Development](docs/development.md) — source setup, checks, tests, and code
  conventions.
- [Deployment](docs/deployment.md) — image-based SSH deployment and remote stack
  configuration.
- [Operations](docs/operations.md) — probes, backups, restoration, retention,
  and key rotation.
- [API contract](docs/agent-usage.md) — endpoint schemas, limits, errors, and
  idempotency.
- [Architecture](docs/architecture.md), [conventions](docs/conventions.md),
  [patterns](docs/patterns.md), and [extension guide](docs/adding-a-service.md).
- [Releases](docs/releases.md) — versioning, publication, and upgrade notes.

The project is licensed under the [MIT License](LICENSE).