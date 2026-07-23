#!/usr/bin/env bash
# Build (if needed) and run the locked-down Claude Code container against the
# CURRENT directory.
#
#   SCANNER_TOKEN=... ./run.sh
#
# The container drops all Linux capabilities except NET_ADMIN (needed once, at
# startup, to install the egress rules) and SETUID/SETGID (needed once, at
# startup, for gosu to drop from root to the unprivileged agent user — see the
# comment above the exec in entrypoint.sh for why). --security-opt
# no-new-privileges means that once the agent is running as that unprivileged
# user, it cannot escalate back to root to flush the egress rules or re-add
# capabilities.
set -euo pipefail

if [ -z "${SCANNER_TOKEN:-}" ]; then
  echo "Set SCANNER_TOKEN first:  export SCANNER_TOKEN=..." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Install it with:" >&2
  echo "  brew install --cask docker" >&2
  echo "or download it from https://www.docker.com/products/docker-desktop/" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker engine is not running. Start Docker Desktop (or the docker daemon) and try again." >&2
  exit 1
fi

IMAGE="cc-agent"
SCANNER_IP="${SCANNER_IP:-100.123.181.11}"

# The API base URL is on the mesh in your config; keep it consistent here.
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://${SCANNER_IP}:8080}"

docker build -t "$IMAGE" .

exec docker run -it --rm \
  --name cc-agent \
  --cap-drop=ALL \
  --cap-add=NET_ADMIN \
  --cap-add=SETUID \
  --cap-add=SETGID \
  --security-opt no-new-privileges \
  -e SCANNER_TOKEN="$SCANNER_TOKEN" \
  -e SCANNER_IP="$SCANNER_IP" \
  -e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy}" \
  -v "$PWD":/home/ccagent/work \
  -w /home/ccagent/work \
  "$IMAGE" "$@"
