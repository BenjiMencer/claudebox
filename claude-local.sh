# claude-local: contained, dockerized Claude Code. Works under bash and zsh,
# on Linux and macOS.
#
# Source this from ~/.bashrc or ~/.zshrc rather than pasting the function in,
# so that `git pull` actually updates it:
#
#     CLAUDEBOX_REPO="$HOME/claudebox"
#     [ -f "$CLAUDEBOX_REPO/claude-local.sh" ] && . "$CLAUDEBOX_REPO/claude-local.sh"
#
# A copy pasted into ~/.zshrc is invisible to git: pulls update the image and
# this file, while the launcher you actually run stays frozen at the copy.
#
# What it does:
#   - loads the token from this repo's .env
#   - starts Docker Desktop if it isn't running (macOS)
#   - auto-builds the image if missing  (claude-local --rebuild forces a rebuild)
#   - mounts the CURRENT directory only
#   - skips permission prompts only under a sandbox root (see sandbox-gate.sh)

# Honour CLAUDEBOX_REPO when the rc file set it, so the path is written down
# once. Otherwise fall back to this file's own location, which means sourcing it
# by any path still works. Resolved out here on purpose: inside the function,
# $0 is the function name, not the file.
#
# The two shells name the current file differently, and neither can parse the
# other's form - hence the branch rather than a default expansion. bash never
# evaluates the zsh arm, so it never has to understand it.
if [ -z "${CLAUDEBOX_REPO:-}" ]; then
  if [ -n "${BASH_SOURCE:-}" ]; then
    _claudebox_src="${BASH_SOURCE[0]}"
  else
    _claudebox_src="${(%):-%x}"
  fi
  CLAUDEBOX_REPO="$(cd "$(dirname "$_claudebox_src")" && pwd -P)"
  unset _claudebox_src
fi

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
  local claudebox_dir="$CLAUDEBOX_REPO"
  local scanner_ip="${SCANNER_IP:-100.123.181.11}"

  # Load token (and any other vars) straight from .env on disk.
  # Sourcing reads the file directly; it does NOT enter Docker build context.
  if [ -f "$claudebox_dir/.env" ]; then
    set -a
    source "$claudebox_dir/.env"
    set +a
  fi

  if [ -z "${SCANNER_TOKEN:-}" ]; then
    echo "claude-local: SCANNER_TOKEN not set (checked $claudebox_dir/.env)." >&2
    return 1
  fi

  # Start the daemon if it isn't up. Only worth automating on macOS, where
  # Docker Desktop is a user application; on Linux it's a system service, so
  # starting it needs privileges this shell shouldn't assume it has.
  if ! docker info >/dev/null 2>&1; then
    if [ "$(uname -s)" != "Darwin" ]; then
      echo "claude-local: the Docker daemon isn't running. Start it with:" >&2
      echo "  sudo systemctl start docker" >&2
      echo "If that says permission denied, add yourself to the docker group:" >&2
      echo "  sudo usermod -aG docker \"$USER\"   # then log out and back in" >&2
      return 1
    fi
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
    echo "claude-local: rebuilding image from $claudebox_dir ..."
    docker build --no-cache --build-arg WITH_BUILD_TOOLS="${CLAUDEBOX_BUILD_TOOLS:-0}" -t "$image" "$claudebox_dir" || return 1
  fi

  # Auto-build if the image doesn't exist yet.
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    if [ ! -f "$claudebox_dir/Dockerfile" ]; then
      echo "claude-local: no Dockerfile at $claudebox_dir." >&2
      return 1
    fi
    echo "claude-local: image '$image' not found; building from $claudebox_dir ..."
    docker build --build-arg WITH_BUILD_TOOLS="${CLAUDEBOX_BUILD_TOOLS:-0}" -t "$image" "$claudebox_dir" || {
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

  # Attach whatever dependency volumes this project already has. Nothing is
  # created here: an install started later copies itself into the running
  # container, so a session doesn't need to have guessed in advance.
  local -a deps_args
  deps_args=()
  if typeset -f claudebox_deps_volumes > /dev/null; then
    claudebox_deps_volumes
    if claudebox_volume_exists "$CLAUDEBOX_VOL_NODE"; then
      deps_args+=(-v "${CLAUDEBOX_VOL_NODE}:${CLAUDEBOX_DEPS_MOUNT_NODE}")
    fi
    if claudebox_volume_exists "$CLAUDEBOX_VOL_PY"; then
      deps_args+=(-v "${CLAUDEBOX_VOL_PY}:${CLAUDEBOX_DEPS_MOUNT_PY}")
    fi
  fi

  # --rm only cleans up the container on a normal exit. A crashed terminal,
  # sleeping machine, or Docker restart can leave a stale container with
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

  # Under a sandbox root, watch for install requests from the agent. It has no
  # network and no Docker socket, so it signals by writing a file; the watcher
  # runs a fixed command in response. Only here, where the blast radius is
  # already disposable. Set CLAUDEBOX_NO_WATCH=1 to opt out.
  local watch_pid=""
  if [ "${CLAUDEBOX_BYPASS:-0}" = 1 ] && [ -z "${CLAUDEBOX_NO_WATCH:-}" ] \
     && [ -x "$CLAUDEBOX_REPO/claudebox-watch" ]; then
    "$CLAUDEBOX_REPO/claudebox-watch" "$PWD" > /dev/null 2>&1 &
    watch_pid=$!
    echo "claude-local: watching for install requests (touch .claudebox-install-request)"
  fi

  # Run: contained network + dropped privileges, mounting the current dir.
  docker run -it --rm \
    --name "$container_name" \
    -e CLAUDEBOX_HOST_UID="$(id -u)" -e CLAUDEBOX_HOST_GID="$(id -g)" \
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
  local run_status=$?

  if [ -n "$watch_pid" ]; then
    kill "$watch_pid" 2> /dev/null
    wait "$watch_pid" 2> /dev/null
    rm -f "$PWD/.claudebox-install-request"
    # Surface installs that happened mid-session: they ran without you watching,
    # and the terminal was busy with the agent's own output at the time.
    [ -f "$PWD/.claudebox-install.log" ] \
      && echo "claude-local: the agent ran an install — see .claudebox-install.log"
  fi

  return $run_status
}
