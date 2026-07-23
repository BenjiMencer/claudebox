#!/usr/bin/env bash
# Runs as root. Sets a default-drop egress policy that allows only the scanner
# IP, verifies the wall with a fail-closed self-test, then drops privileges and
# launches Claude Code as an unprivileged user that cannot alter the rules.
set -euo pipefail

SCANNER_IP="${SCANNER_IP:-100.123.181.11}"
ALLOWED_PORTS="${ALLOWED_PORTS:-8080,8099}"   # 8080 = ANTHROPIC_BASE_URL, 8099 = scanner

if [ -z "${SCANNER_TOKEN:-}" ]; then
  echo "FATAL: SCANNER_TOKEN is not set. Pass it with -e SCANNER_TOKEN=... at run time." >&2
  exit 1
fi

echo "[entrypoint] applying egress policy: allow only ${SCANNER_IP}:${ALLOWED_PORTS}"

# Default-drop outbound; allow loopback, return traffic, and the scanner only.
iptables -P OUTPUT DROP
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p tcp -d "${SCANNER_IP}" -m multiport --dports "${ALLOWED_PORTS}" -j ACCEPT
# No DNS rule on purpose: the scanner is reached by literal IP, so name
# resolution stays blocked. Do not add a DNS allow "to make things work"
# without understanding it reopens a lookup/exfil channel.

# Fail-closed self-test: if the wall is NOT holding, do not start the agent.
/usr/local/bin/selftest.sh "${SCANNER_IP}" "8099" || {
  echo "FATAL: egress self-test failed. Refusing to start the agent." >&2
  exit 1
}

echo "[entrypoint] self-test passed; dropping privileges to ccagent and starting Claude Code"

# Drop to the unprivileged user. gosu does a clean exec without needing
# sudo's PAM/audit/pty machinery, but it still calls setuid/setgid under the
# hood, which the kernel gates on CAP_SETUID/CAP_SETGID even for UID 0 once
# --cap-drop=ALL has stripped the default capability set — so the run
# command MUST --cap-add=SETUID --cap-add=SETGID or this exec fails. The
# container also runs with --security-opt=no-new-privileges, so once we're
# ccagent here, there is no way back to root to re-add capabilities or
# flush the iptables rules above.
exec gosu ccagent env \
  HOME=/home/ccagent \
  SCANNER_TOKEN="$SCANNER_TOKEN" \
  ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://100.123.181.11:8080}" \
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy}" \
  claude "$@"
