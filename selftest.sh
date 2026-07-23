#!/usr/bin/env bash
# Verifies the egress wall is actually holding BEFORE the agent starts.
# Exits non-zero (fail closed) if the internet is reachable, or if the
# scanner is NOT reachable. Called by entrypoint.sh.
#
#   selftest.sh <scanner_ip> <scanner_port>
set -uo pipefail

SCANNER_IP="${1:-100.123.181.11}"
SCANNER_PORT="${2:-8099}"

fail=0

# 1. The open internet must NOT be reachable. We try a couple of well-known
#    hosts by IP (DNS is blocked by design, so hostnames would fail anyway
#    and wouldn't prove anything about egress). 1.1.1.1 and 8.8.8.8 are used
#    only as reachability probes, not for name resolution.
for probe in 1.1.1.1 8.8.8.8; do
  if curl -s --max-time 4 "http://${probe}" >/dev/null 2>&1; then
    echo "[selftest] LEAK: reached ${probe} — egress wall is NOT holding" >&2
    fail=1
  else
    echo "[selftest] ok: ${probe} unreachable (expected)"
  fi
done

# 2. The scanner MUST be reachable, or the whole setup is pointless.
if curl -s --max-time 5 "http://${SCANNER_IP}:${SCANNER_PORT}/health" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
  echo "[selftest] ok: scanner health check passed"
else
  echo "[selftest] scanner health check FAILED — check meshnet routing into the container" >&2
  fail=1
fi

exit "$fail"
