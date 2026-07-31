# Renamed to claude-local.sh, which works under bash as well as zsh.
# Kept so rc files that already source this path keep working.
if [ -n "${BASH_SOURCE:-}" ]; then
  _claudebox_compat="${BASH_SOURCE[0]}"
else
  _claudebox_compat="${(%):-%x}"
fi
. "$(cd "$(dirname "$_claudebox_compat")" && pwd -P)/claude-local.sh"
unset _claudebox_compat
