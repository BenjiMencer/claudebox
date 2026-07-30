# claude-local: contained, dockerized Claude Code.
#
# Source this from ~/.zshrc rather than pasting the function in, so that
# `git pull` actually updates it:
#
#     CLAUDEBOX_REPO="$HOME/claude-docker"
#     [ -f "$CLAUDEBOX_REPO/claude-local.zsh" ] && source "$CLAUDEBOX_REPO/claude-local.zsh"
#
# A copy pasted into ~/.zshrc is invisible to git: pulls update the image and
# this file, while the launcher you actually run stays frozen at the copy.
#
# What it does:
#   - loads the token from this repo's .env
#   - starts Docker Desktop if it isn't running
#   - auto-builds the image if missing  (claude-local --rebuild forces a rebuild)
#   - mounts the CURRENT directory only
#   - skips permission prompts only under a sandbox root (see sandbox-gate.sh)

# Honour CLAUDEBOX_REPO when ~/.zshrc set it, so the path is written down once.
# Otherwise fall back to this file's own location, which means sourcing it by
# any path still works. Resolved out here on purpose: inside the function, $0
# is the function name, not the file.
CLAUDEBOX_REPO="${CLAUDEBOX_REPO:-${${(%):-%x}:A:h}}"

if [ -f "$CLAUDEBOX_REPO/sandbox-gate.sh" ]; then
  source "$CLAUDEBOX_REPO/sandbox-gate.sh"
else
  echo "claude-local: missing $CLAUDEBOX_REPO/sandbox-gate.sh - bypass disabled." >&2
fi

if [ -f "$CLAUDEBOX_REPO/deps-volumes.sh" ]; then
  source "$CLAUDEBOX_REPO/deps-volumes.sh"
fi

# Install a project's dependencies into a Docker volume, via a throwaway
# container that gets the manifest and nothing else. See claudebox-install.
claudebox-install() { "$CLAUDEBOX_REPO/claudebox-install" "$@"; }

claude-local() {
  local image="cc-agent"
  local claude_docker_dir="$CLAUDEBOX_REPO"
  local scanner_ip="${SCANNER_IP:-100.123.181.11}"

  # Load token (and any other vars) straight from .env on disk.
  # Sourcing reads the file directly; it does NOT enter Docker build context.
  if [ -f "$claude_docker_dir/.env" ]; then
    set -a
    source "$claude_docker_dir/.env"
    set +a
  fi

  if [ -z "${SCANNER_TOKEN:-}" ]; then
    echo "claude-local: SCANNER_TOKEN not set (checked $claude_docker_dir/.env)." >&2
    return 1
  fi

  # Start Docker Desktop if the daemon isn't up yet.
  if ! docker info >/dev/null 2>&1; then
    echo "claude-local: Docker isn't running — starting Docker Desktop ..."
    open -a Docker
    local i=0
    while ! docker info >/dev/null 2>&1; do
      sleep 2
      i=$((i+1))
      if [ "$i" -ge 30 ]; then
        echo "claude-local: Docker didn't start within ~60s. Try again shortly." >&2
        return 1
      fi
    done
    echo "claude-local: Docker is up."
  fi

  # Forced rebuild:  claude-local --rebuild
  if [ "${1:-}" = "--rebuild" ]; then
    shift
    echo "claude-local: rebuilding image from $claude_docker_dir ..."
    docker build --no-cache -t "$image" "$claude_docker_dir" || return 1
  fi

  # Auto-build if the image doesn't exist yet.
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    if [ ! -f "$claude_docker_dir/Dockerfile" ]; then
      echo "claude-local: no Dockerfile at $claude_docker_dir." >&2
      return 1
    fi
    echo "claude-local: image '$image' not found; building from $claude_docker_dir ..."
    docker build -t "$image" "$claude_docker_dir" || {
      echo "claude-local: build failed." >&2
      return 1
    }
  fi

  # One container per project directory, so running claude-local from several
  # projects at once gives each its own container instead of colliding on the
  # name. Re-running from the SAME directory still hits the stale/running
  # check below, since two agents editing the same mounted files at once is
  # unsafe.
  local dir_slug container_name
  dir_slug="$(basename "$PWD" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
  container_name="cc-agent-${dir_slug}"

  # Permission prompts are skipped only under a sandbox root. See
  # sandbox-gate.sh for what counts as one and why it is scoped this way.
  local -a perm_args
  perm_args=()
  if typeset -f claudebox_check_sandbox > /dev/null; then
    claudebox_check_sandbox
    if [ "$CLAUDEBOX_BYPASS" = 1 ]; then
      perm_args=(--permission-mode bypassPermissions)
      echo "claude-local: $PWD is under sandbox root $CLAUDEBOX_MATCHED_ROOT"
      echo "claude-local: starting WITHOUT permission prompts (bypassPermissions)."
    fi
  fi

  # Dependency volumes, if claudebox-install has populated any for this
  # project. Only mount ones that already exist: naming a missing volume would
  # create an empty root-owned directory over node_modules, which reads as
  # "dependencies are installed" while being unwritable to the agent.
  local -a deps_args
  deps_args=()
  if typeset -f claudebox_deps_volumes > /dev/null; then
    claudebox_deps_volumes
    if [ -n "$CLAUDEBOX_VOL_NODE" ] && claudebox_volume_exists "$CLAUDEBOX_VOL_NODE"; then
      deps_args+=(-v "${CLAUDEBOX_VOL_NODE}:${CLAUDEBOX_DEPS_MOUNT_NODE}")
    fi
    if [ -n "$CLAUDEBOX_VOL_PY" ] && claudebox_volume_exists "$CLAUDEBOX_VOL_PY"; then
      deps_args+=(-v "${CLAUDEBOX_VOL_PY}:${CLAUDEBOX_DEPS_MOUNT_PY}")
    fi
  fi

  # --rm only cleans up the container on a normal exit. A crashed terminal,
  # sleeping Mac, or Docker Desktop restart can leave a stale container with
  # this name behind, which makes the `docker run --name` below fail with
  # "already in use". Reclaim a stale (stopped) one automatically; leave a
  # genuinely running one alone and tell the user how to deal with it, since
  # killing it could interrupt a session in another terminal.
  local existing_running
  existing_running="$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)"
  if [ "$existing_running" = "true" ]; then
    echo "claude-local: a '${container_name}' container is already running." >&2
    echo "  Attach to it with:  docker attach ${container_name}" >&2
    echo "  Or stop it first:   docker rm -f ${container_name}" >&2
    return 1
  elif [ -n "$existing_running" ]; then
    echo "claude-local: removing stale '${container_name}' container from a previous run..."
    docker rm "$container_name" >/dev/null
  fi

  # Run: contained network + dropped privileges, mounting the current dir.
  docker run -it --rm \
    --name "$container_name" \
    --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=SETUID --cap-add=SETGID \
    --security-opt no-new-privileges \
    -e SCANNER_TOKEN="$SCANNER_TOKEN" \
    -e SCANNER_IP="$scanner_ip" \
    -e ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://${scanner_ip}:8080}" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy}" \
    -v "$PWD":/home/ccagent/work \
    "${deps_args[@]}" \
    -w /home/ccagent/work \
    "$image" "${perm_args[@]}" "$@"
}
