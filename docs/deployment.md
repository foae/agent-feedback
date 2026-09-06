# Deployment

The image-based deployment path is `scripts/deploy.sh [image-tag]`. It pulls a
GHCR image locally with `crane`, streams it over SSH, installs the image-based
Compose file, preserves an existing remote `.env`, starts the stack, and checks
readiness.

## Prerequisites

On the machine running the script: authenticated `gh`, `crane`, Docker CLI,
SSH, and SCP. On the remote host: Docker Compose and `curl`. The local script
requires these two settings:

```bash
DEPLOY_REMOTE=deploy@example.invalid
DEPLOY_IMAGE=ghcr.io/example-owner/agent-feedback
```

`DEPLOY_IMAGE` is a GHCR repository without a tag. Store local settings in
`.private/deploy.env` if useful; it is gitignored and must remain owner-only.
Use your own remote and image values.

```bash
chmod 600 .private/deploy.env
bash scripts/deploy.sh <image-tag>
```

The tag defaults to `latest`. The script writes the deployment stack to
`~/agent-feedback/docker-compose.yml` on the remote host and runs it with
`FEEDBACK_IMAGE` set to the selected fully-qualified image reference. Manual
use of that Compose file must set `FEEDBACK_IMAGE` too.

## Remote configuration

On first deployment, the script creates `~/agent-feedback/.env` with generated
`API_KEY`, `POSTGRES_PASSWORD`, and matching `POSTGRES_URL`; later deployments
preserve that file. Protect it as a credential file. The Compose stack requires
those nonempty values and binds `127.0.0.1:8090` by default.

For intentional remote ingress, set `FEEDBACK_BIND_ADDRESS=0.0.0.0` in the
remote `.env` only after configuring authenticated TLS or another protected
network boundary. See [Security](security.md). The script does not provide
automatic rollback or database backups; make and verify a backup before an
upgrade as described in [Operations](operations.md).