#!/usr/bin/env bash
# Deploy a GHCR image over explicitly configured SSH without registry
# credentials on the target.
# Usage: scripts/deploy.sh [image-tag]
# Required: DEPLOY_REMOTE (SSH destination), DEPLOY_IMAGE (GHCR repo, no tag).
# Optional local settings: .private/deploy.env.
# crane avoids incomplete docker-save archives with containerd image stores.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.private/deploy.env" ]; then
  # shellcheck source=/dev/null
  source "$ROOT/.private/deploy.env"
fi
: "${DEPLOY_REMOTE:?Set DEPLOY_REMOTE to your SSH destination}"
: "${DEPLOY_IMAGE:?Set DEPLOY_IMAGE to your GHCR image repository without a tag}"
TAG=${1:-latest}
[[ "$DEPLOY_IMAGE" =~ ^ghcr\.io/[a-z0-9._/-]+$ ]] || { echo "Invalid DEPLOY_IMAGE" >&2; exit 1; }
[[ "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || { echo "Invalid image tag" >&2; exit 1; }
IMAGE="${DEPLOY_IMAGE}:${TAG}"

command -v crane >/dev/null || { echo "crane is required: brew install crane"; exit 1; }
umask 077
AUTH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-feedback-crane-auth-XXXXXX")
IMG_TAR=$(mktemp /tmp/agent-feedback-image-XXXXXX.tar)
cleanup() {
  rm -rf -- "$AUTH_DIR"
  rm -f -- "$IMG_TAR"
}
trap cleanup EXIT
export DOCKER_CONFIG="$AUTH_DIR"

echo "==> Logging into GHCR locally with temporary crane credentials"
gh auth token | crane auth login ghcr.io -u "$(gh api user -q .login)" --password-stdin
echo "==> Fetching ${IMAGE} from GHCR"
crane pull "${IMAGE}" "${IMG_TAR}"
echo "==> Streaming image to ${DEPLOY_REMOTE}"
ssh -- "${DEPLOY_REMOTE}" docker load < "${IMG_TAR}"

echo "==> Syncing compose file"
ssh -- "${DEPLOY_REMOTE}" 'mkdir -p agent-feedback'
scp -q -- "$ROOT/infra/agent-feedback/docker-compose.deploy.yml" \
  "${DEPLOY_REMOTE}:agent-feedback/docker-compose.yml"

echo "==> Ensuring .env (generated on first deploy, preserved afterwards)"
ssh -- "${DEPLOY_REMOTE}" bash -s <<'REMOTE_ENV'
set -euo pipefail
cd "$HOME/agent-feedback"
if [ ! -f .env ]; then
  umask 077
  API_KEY=$(openssl rand -hex 32)
  PW=$(openssl rand -hex 16)
  printf 'API_KEY=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_URL=postgres://feedback:%s@postgres:5432/feedback?sslmode=disable\n' \
    "$API_KEY" "$PW" "$PW" > .env
  echo "    generated .env — credentials remain on the remote host"
else
  echo "    .env exists — preserved"
fi
REMOTE_ENV

echo "==> Starting stack (tag: ${TAG})"
ssh -- "${DEPLOY_REMOTE}" "cd agent-feedback && FEEDBACK_IMAGE=${IMAGE} docker compose up -d --remove-orphans"
echo "==> Readiness check (includes Postgres)"
ssh -- "${DEPLOY_REMOTE}" 'for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:8090/ready >/dev/null && { echo "    ready"; exit 0; }
  sleep 1
done
echo "    readiness check FAILED — inspect docker compose logs in ~/agent-feedback on the target"
exit 1'
echo "==> Deployed ${IMAGE} to ${DEPLOY_REMOTE} (HTTP port 8090)"
