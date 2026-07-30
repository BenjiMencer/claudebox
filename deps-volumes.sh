# Shared dependency-volume policy, sourced by run.sh (bash), claude-local.zsh
# (zsh), and claudebox-install (bash).
#
# Dependencies live in Docker named volumes rather than in the mounted project
# directory. Named volumes live inside Docker Desktop's VM, so installed package
# code never lands on the host filesystem, and the installer that fetches it can
# be handed the volume without being handed your source.
#
# Sourcing this defines claudebox_deps_volumes, which sets:
#   CLAUDEBOX_VOL_NODE  volume name for node_modules
#   CLAUDEBOX_VOL_PY    volume name for .venv
#   CLAUDEBOX_HAS_NODE  1 if this directory has a node manifest
#   CLAUDEBOX_HAS_PY    1 if it has a python manifest
#
# The names are always set; the HAS_ flags say whether a manifest is present
# right now. Callers need both, because a session can gain a manifest partway
# through and the volumes have to already be mounted for that to be usable.
#
# POSIX only - no arrays, no unquoted word splitting - because bash and zsh
# disagree on both and all three callers must agree on the names.

# Mounted OUTSIDE the bind-mounted work directory, deliberately. Two reasons:
# nothing appears in the project on the host, not even an empty mount point;
# and `docker cp` into a bind-mounted path writes through to the host, so a
# path under work/ could not be topped up mid-session without spilling package
# code onto the Mac. Node resolves node_modules by walking up parent
# directories, so /home/ccagent/node_modules is found from /home/ccagent/work.
CLAUDEBOX_DEPS_MOUNT_NODE="/home/ccagent/node_modules"
CLAUDEBOX_DEPS_MOUNT_PY="/home/ccagent/venv"

# Stable per-project id: readable basename plus a hash of the full path, so two
# checkouts sharing a basename ("api", "web") don't collide onto one volume and
# silently swap dependency trees.
claudebox_project_id() {
    claudebox_base=$(basename "$PWD" | sed 's/[^a-zA-Z0-9_.-]/_/g')
    if command -v shasum > /dev/null 2>&1; then
        claudebox_hash=$(printf '%s' "$PWD" | shasum | cut -c1-8)
    else
        claudebox_hash=$(printf '%s' "$PWD" | cksum | tr -d ' ' | cut -c1-8)
    fi
    printf '%s-%s' "$claudebox_base" "$claudebox_hash"
}

claudebox_deps_volumes() {
    claudebox_id=$(claudebox_project_id)
    CLAUDEBOX_VOL_NODE="claudebox-${claudebox_id}-node_modules"
    CLAUDEBOX_VOL_PY="claudebox-${claudebox_id}-venv"

    [ -f "$PWD/package.json" ] && CLAUDEBOX_HAS_NODE=1 || CLAUDEBOX_HAS_NODE=0
    if [ -f "$PWD/requirements.txt" ] || [ -f "$PWD/pyproject.toml" ]; then
        CLAUDEBOX_HAS_PY=1
    else
        CLAUDEBOX_HAS_PY=0
    fi
    return 0
}

claudebox_volume_exists() { docker volume inspect "$1" > /dev/null 2>&1; }

# One container per project directory. Shared so the installer targets the same
# container the launchers created.
claudebox_container_name() {
    printf 'cc-agent-%s' "$(basename "$PWD" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
}

# Create a volume if it doesn't exist, and hand it to the agent user: a fresh
# named volume is root-owned, and the agent runs unprivileged. Costs one short
# container run, once per project, and nothing on later launches.
claudebox_ensure_volume() {
    claudebox_volume_exists "$1" && return 0
    docker volume create "$1" > /dev/null || return 1
    docker run --rm --entrypoint sh -v "$1:/v" "$2" \
        -c 'chown "$(id -u ccagent):$(id -g ccagent)" /v' > /dev/null 2>&1
}
