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
# One container per project directory, so running this from several projects
# at once gives each its own container instead of colliding on the name.
# Re-running from the SAME directory still hits the stale/running check
# below, since two agents editing the same mounted files at once is unsafe.
DIR_SLUG="$(basename "$PWD" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
CONTAINER_NAME="cc-agent-${DIR_SLUG}"
SCANNER_IP="${SCANNER_IP:-100.123.181.11}"

# The API base URL is on the mesh in your config; keep it consistent here.
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://${SCANNER_IP}:8080}"

# ---------------------------------------------------------------------------
# Sandbox roots: where the agent may run without permission prompts.
#
# This container mounts the current directory as its only writable surface, so
# scoping bypass by launch directory makes the blast radius exactly the thing
# you already decided was disposable. Everywhere else gets the normal prompts.
#
# Override with CLAUDE_SANDBOX_ROOTS (colon-separated). That is a convenience,
# not a security boundary: anything that can set your environment can grant
# itself bypass, so keep the default narrow and don't export it globally.
#
# Do NOT add this repo to the list. Bypass here would let the agent rewrite
# run.sh and widen its own allowlist.
# ---------------------------------------------------------------------------
SANDBOX_ROOTS="${CLAUDE_SANDBOX_ROOTS:-$HOME/claude-sandbox}"

# Resolve symlinks on both sides before comparing, so a link into a sandbox
# root - or out of one - can't change the answer.
resolve_path() ( cd "$1" 2>/dev/null && pwd -P )

CURRENT_DIR="$(resolve_path "$PWD" || true)"
PERM_ARGS=()
OLD_IFS="$IFS"
IFS=':'
for root in $SANDBOX_ROOTS; do
  IFS="$OLD_IFS"
  [ -n "$root" ] || continue
  resolved_root="$(resolve_path "$root" || true)"
  [ -n "$resolved_root" ] || continue
  # Exact match or a path beneath it. Matching on "$root"/* rather than a bare
  # prefix stops /tmp/sandbox-evil from matching a /tmp/sandbox root.
  case "$CURRENT_DIR" in
    "$resolved_root"|"$resolved_root"/*)
      PERM_ARGS=(--permission-mode bypassPermissions)
      echo "claudebox: $CURRENT_DIR is under sandbox root $resolved_root"
      echo "claudebox: starting WITHOUT permission prompts (bypassPermissions)."
      break
      ;;
  esac
  IFS=':'
done
IFS="$OLD_IFS"

docker build -t "$IMAGE" .

# --rm only cleans up cc-agent on a normal exit. A crashed terminal, sleeping
# Mac, or Docker Desktop restart can leave a stale container with this name
# behind, which makes the `docker run --name` below fail with "already in
# use". Reclaim a stale (stopped) one automatically; leave a genuinely
# running one alone and tell the user how to deal with it, since killing it
# could interrupt a session in another terminal.
existing_running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
if [ "$existing_running" = "true" ]; then
  echo "A '${CONTAINER_NAME}' container is already running." >&2
  echo "Attach to it with:  docker attach ${CONTAINER_NAME}" >&2
  echo "Or stop it first:   docker rm -f ${CONTAINER_NAME}" >&2
  exit 1
elif [ -n "$existing_running" ]; then
  echo "Removing stale '${CONTAINER_NAME}' container from a previous run..."
  docker rm "$CONTAINER_NAME" >/dev/null
fi

exec docker run -it --rm \
  --name "$CONTAINER_NAME" \
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
  "$IMAGE" ${PERM_ARGS[@]+"${PERM_ARGS[@]}"} "$@"
