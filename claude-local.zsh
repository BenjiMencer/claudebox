# claude-local: contained, dockerized Claude Code.
#
# Source this from ~/.zshrc rather than pasting the function in, so that
# `git pull` actually updates it:
#
#     [ -f "$HOME/claude-docker/claude-local.zsh" ] && \
#       source "$HOME/claude-docker/claude-local.zsh"
#
# A pasted copy silently ignores every future pull - the image rebuilds from
# the repo but the launcher around it stays whatever you pasted months ago.
#
# What it does:
#   - loads the token from this repo's .env
#   - starts Docker Desktop if it isn't running
#   - auto-builds the image if missing  (claude-local --rebuild forces a rebuild)
#   - mounts the CURRENT directory only
#   - skips permission prompts only under a sandbox root (see sandbox-gate.sh)

# Directory this file lives in, resolved when sourced. It has to be captured
# out here: inside the function, $0 is the function name, not the file.
CLAUDEBOX_DIR="${${(%):-%x}:A:h}"

if [ -f "$CLAUDEBOX_DIR/sandbox-gate.sh" ]; then
  source "$CLAUDEBOX_DIR/sandbox-gate.sh"
else
  echo "claude-local: missing $CLAUDEBOX_DIR/sandbox-gate.sh - bypass disabled." >&2
fi

claude-local() {
  local image="cc-agent"
  # Derived from this file's location, so there is nothing to hand-edit if the
  # repo lives somewhere else.
  local claude_docker_dir="$CLAUDEBOX_DIR"
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
    -w /home/ccagent/work \
    "$image" "${perm_args[@]}" "$@"
}
