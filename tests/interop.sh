#!/usr/bin/env bash
# tests/interop.sh — this package against WebSocket implementations that are
# not this package.
#
#   1. Node's own WebSocket client talks to an echo server built on this
#      package, with permessage-deflate on offer: text, 200 kB of text, 70 kB
#      of binary, fifty messages in a row, and the close handshake.
#   2. A client built on this package talks to an echo server written in Python
#      on its socket and zlib modules, once without compression and once with
#      permessage-deflate negotiated.
#
# It skips a leg when node or python3 is missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
NOVO="${NOVO:-novo}"
PASS=0; FAIL=0
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -f "$PKG/interop_server" "$PKG/interop_probe"; rm -rf "$WORK"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/websocket-nv-interop.XXXXXX")"
trap cleanup EXIT
check() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1)); else echo "  ✗ $1"; echo "    want: $3"; echo "    got:  $2"; FAIL=$((FAIL + 1)); fi
}
cd "$PKG"

if command -v node >/dev/null 2>&1; then
  PORT=$((20000 + RANDOM % 20000))
  INTEROP_PORT=$PORT "$NOVO" run tests/interop_server.nv > "$WORK/server.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 100); do grep -q listening "$WORK/server.log" 2>/dev/null && break; sleep 0.2; done
  OUT="$(node tests/interop_client.mjs "$PORT" 2>&1)"
  echo "$OUT" | sed "s/^/    /"
  check "Node's client against this package's server" "$(echo "$OUT" | grep -c '^ok') ok, $(echo "$OUT" | grep -c '^FAIL') failed" "5 ok, 0 failed"
else
  echo "  (skipped Node leg — node not on PATH)"
fi

if command -v python3 >/dev/null 2>&1; then
  for mode in plain deflate; do
    python3 tests/interop_server.py x "$mode" > "$WORK/py-$mode.port" &
    pids+=($!)
    for _ in $(seq 1 50); do [ -s "$WORK/py-$mode.port" ] && break; sleep 0.1; done
    PORT="$(cat "$WORK/py-$mode.port")"
    OUT="$(INTEROP_PORT=$PORT INTEROP_DEFLATE=$([ "$mode" = deflate ] && echo deflate) "$NOVO" run tests/interop_probe.nv 2>&1 | grep -E '^(deflate|echoed|MISMATCH|send|receive|connect|dial|close|no close)')"
    echo "$OUT" | sed "s/^/    /"
    WANT="echoed 15
echoed 200000
echoed 70000
echoed 0
closed 1000"
    if [ "$mode" = deflate ]; then WANT="deflate WsDeflateOn
$WANT"; else WANT="deflate WsDeflateOff
$WANT"; fi
    check "this package's client against Python's server ($mode)" "$(echo "$OUT" | sed 's/WsDeflateState\.//; s/WsDeflateOn(.*/WsDeflateOn/')" "$WANT"
  done
else
  echo "  (skipped Python leg — python3 not on PATH)"
fi
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
