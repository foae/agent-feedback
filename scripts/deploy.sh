#!/usr/bin/env bash
# Manual deploy of agent-feedback to the deploy-host machine (Intel Mac, Docker Desktop).
#
# Flow: fetch the CI-built image from GHCR into a tarball with crane (bypasses the
# local docker image store; deploy-host needs no registry credentials) → stream it over
# SSH into deploy-host's docker → sync the image-based compose file → generate
# credentials on first deploy (preserved afterwards) → compose up → health check.
#
# Why crane and not `docker pull + docker save`: with docker's containerd image
# store (workstation-a, docker 29.x), `docker save` can silently emit a tar that
# references layer blobs it doesn't contain (content GC'd after extraction) —
# the remote `docker load` then fails with "blobs/sha256/…: no such file or
# directory". crane pulls the blobs straight from the registry, so the tar is
# always complete.
#
# Usage:   scripts/deploy.sh [image-tag]
#   image-tag defaults to "latest"; pass a commit SHA to deploy a specific build.
# Requires: gh (authed), crane (brew install crane), docker login config,
#           ssh access as deploy-host@deploy-host (Tailscale).
# The API key lives ONLY on deploy-host in ~/agent-feedback/.env — read it there.
set -euo pipefail

TAG=${1:-latest}
IMAGE="ghcr.io/foae/agent-feedback:${TAG}"
REMOTE="${DEPLOY_REMOTE:?Set DEPLOY_REMOTE to your SSH destination}"
REMOTE_DIR=agent-feedback   # relative to the remote $HOME

command -v crane >/dev/null || { echo "crane is required: brew install crane"; exit 1; }

echo "==> Logging into GHCR locally (crane reads docker's credential config)"
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin >/dev/null

IMG_TAR=$(mktemp /tmp/agent-feedback-image-XXXXXX.tar)
trap 'rm -f "${IMG_TAR}"' EXIT

echo "==> Fetching ${IMAGE} from GHCR"
crane pull "${IMAGE}" "${IMG_TAR}"

echo "==> Streaming image to ${REMOTE}"
ssh "${REMOTE}" docker load < "${IMG_TAR}"

echo "==> Syncing compose file"
ssh "${REMOTE}" "mkdir -p ${REMOTE_DIR}"
scp -q "$(dirname "$0")/../infra/agent-feedback/docker-compose.deploy.yml" \
  "${REMOTE}:${REMOTE_DIR}/docker-compose.yml"

echo "==> Ensuring .env (generated on first deploy, preserved afterwards)"
ssh "${REMOTE}" bash -s <<'REMOTE_ENV'
set -euo pipefail
cd "$HOME/agent-feedback"
if [ ! -f .env ]; then
  API_KEY=$(openssl rand -hex 32)
  PW=$(openssl rand -hex 16)
  printf 'API_KEY=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_URL=postgres://feedback:%s@postgres:5432/feedback?sslmode=disable\n' \
    "$API_KEY" "$PW" "$PW" > .env
  chmod 600 .env
  echo "    generated new .env — API key is in ~/agent-feedback/.env on deploy-host"
else
  echo "    .env exists — preserved"
fi
REMOTE_ENV

echo "==> Starting stack (tag: ${TAG})"
ssh "${REMOTE}" "cd ${REMOTE_DIR} && IMAGE_TAG=${TAG} docker compose up -d --remove-orphans"

echo "==> Readiness check (includes Postgres)"
ssh "${REMOTE}" 'for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:8090/ready >/dev/null && { echo "    ready"; exit 0; }
  sleep 1
done
echo "    readiness check FAILED — inspect: ssh deploy-host@deploy-host \"cd agent-feedback && docker compose logs\""
exit 1'

echo "==> Deployed ${IMAGE} — reachable at http://deploy-host:8090 (Tailscale)"
