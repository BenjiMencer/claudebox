# Shared dependency-volume policy, sourced by run.sh (bash), claude-local.zsh
# (zsh), and claudebox-install (bash).
#
# Dependencies live in Docker named volumes rather than in the mounted project
# directory. Named volumes live inside Docker Desktop's VM, so installed package
# code never lands on the host filesystem, and the installer that fetches it can
# be given the volume without being given your source.
#
# Sourcing this defines claudebox_deps_volumes, which sets:
#   CLAUDEBOX_VOL_NODE  volume name for node_modules, or "" if not a node project
#   CLAUDEBOX_VOL_PY    volume name for .venv, or "" if not a python project
#
# POSIX only - no arrays, no unquoted word splitting - because bash and zsh
# disagree on both and all three callers must agree on the names.

CLAUDEBOX_DEPS_MOUNT_NODE="/home/ccagent/work/node_modules"
CLAUDEBOX_DEPS_MOUNT_PY="/home/ccagent/work/.venv"

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
    CLAUDEBOX_VOL_NODE=""
    CLAUDEBOX_VOL_PY=""
    claudebox_id=$(claudebox_project_id)

    [ -f "$PWD/package.json" ] && CLAUDEBOX_VOL_NODE="claudebox-${claudebox_id}-node_modules"
    if [ -f "$PWD/requirements.txt" ] || [ -f "$PWD/pyproject.toml" ]; then
        CLAUDEBOX_VOL_PY="claudebox-${claudebox_id}-venv"
    fi
    return 0
}

claudebox_volume_exists() { docker volume inspect "$1" > /dev/null 2>&1; }
