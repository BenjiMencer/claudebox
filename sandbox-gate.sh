# Shared sandbox-root gate, sourced by run.sh (bash) and claude-local.zsh (zsh).
#
# Sourcing this defines claudebox_check_sandbox, which sets:
#   CLAUDEBOX_BYPASS        1 when the current directory is inside a sandbox
#                           root, 0 otherwise
#   CLAUDEBOX_MATCHED_ROOT  the resolved root that matched, when one did
#
# Deliberately POSIX: no arrays, no unquoted word splitting, no shell-specific
# expansions, because bash and zsh disagree on all three. One implementation
# means the two launchers cannot drift apart on a security-relevant decision.
#
# ---------------------------------------------------------------------------
# Sandbox roots are the directories where the agent may run without permission
# prompts. The container mounts the launch directory as its only writable
# surface, so scoping bypass by launch location makes the blast radius exactly
# the thing you already decided was disposable.
#
# Override with CLAUDE_SANDBOX_ROOTS (colon-separated). That is a convenience,
# not a security boundary: anything that can set your environment can grant
# itself bypass. Keep the default narrow and don't export it globally.
#
# Do NOT list the claudebox repo itself. Bypass there would let the agent
# rewrite these launchers and widen its own allowlist.
# ---------------------------------------------------------------------------

CLAUDEBOX_DEFAULT_SANDBOX_ROOT="$HOME/claude-sandbox"

# Resolve symlinks and return the real path, or nothing if it isn't a readable
# directory. The subshell keeps the cd from leaking to the caller, and the
# `|| true` keeps a miss from tripping `set -e` in run.sh.
claudebox_resolve_path() { ( cd "$1" 2>/dev/null && pwd -P ) || true; }

claudebox_check_sandbox() {
    CLAUDEBOX_BYPASS=0
    CLAUDEBOX_MATCHED_ROOT=""

    # Resolve both sides before comparing, so a symlink into a sandbox root -
    # or one pointing out of it - can't change the answer.
    claudebox_current=$(claudebox_resolve_path "$PWD")
    [ -n "$claudebox_current" ] || return 0

    # Walk the colon-separated list using parameter expansion rather than IFS
    # splitting, which behaves differently between the two shells.
    claudebox_rest="${CLAUDE_SANDBOX_ROOTS:-$CLAUDEBOX_DEFAULT_SANDBOX_ROOT}"
    while [ -n "$claudebox_rest" ]; do
        case "$claudebox_rest" in
            *:*)
                claudebox_root="${claudebox_rest%%:*}"
                claudebox_rest="${claudebox_rest#*:}"
                ;;
            *)
                claudebox_root="$claudebox_rest"
                claudebox_rest=""
                ;;
        esac

        [ -n "$claudebox_root" ] || continue
        claudebox_resolved=$(claudebox_resolve_path "$claudebox_root")
        [ -n "$claudebox_resolved" ] || continue

        # Exact match, or a path beneath it. Matching "$root"/* rather than a
        # bare prefix is what stops /tmp/sandbox-evil from matching a
        # /tmp/sandbox root.
        case "$claudebox_current" in
            "$claudebox_resolved"|"$claudebox_resolved"/*)
                CLAUDEBOX_BYPASS=1
                CLAUDEBOX_MATCHED_ROOT="$claudebox_resolved"
                return 0
                ;;
        esac
    done

    return 0
}
