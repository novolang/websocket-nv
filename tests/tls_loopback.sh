#!/usr/bin/env bash
# tests/tls_loopback.sh — the TLS transport against a TLS peer.
#
# `WsTls` is checked here and not in `novo test`, because a TLS peer needs
# a certificate and a second process. The peer is Python's ssl module on the
# loopback interface: it completes the handshake, echoes the first thing it
# reads, stays quiet for half a second, and closes with a close_notify. The script asserts that
#   1. the dial verifies the peer's certificate against the one just made;
#   2. what is sent comes back unchanged;
#   3. a quiet peer is a receive deadline and the connection stays usable;
#   4. a peer that closes cleanly is a closed connection;
#   5. a dial that verifies against the wrong certificate is refused.
#
# It skips cleanly when openssl or python3 is missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
NOVO="${NOVO:-novo}"

command -v openssl >/dev/null 2>&1 || { echo "  (skipped — openssl CLI not on PATH)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  (skipped — python3 not on PATH)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/websocket-nv-tls.XXXXXX")"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK" "$PKG/tls_probe"; }
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" -days 1 >/dev/null 2>&1 \
  || { echo "  (skipped — cannot make a certificate)"; exit 0; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/other-key.pem" -out "$WORK/other.pem" \
  -subj "/CN=other" -days 1 >/dev/null 2>&1

cat > "$WORK/server.py" <<'PYEOF'
import socket, ssl, sys, time
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1] + "/cert.pem", sys.argv[1] + "/key.pem")
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(4)
print(srv.getsockname()[1], flush=True)
while True:
    raw, _ = srv.accept()
    try:
        conn = ctx.wrap_socket(raw, server_side=True)
        data = conn.recv(100)
        conn.sendall(data)
        time.sleep(0.5)
        conn.unwrap()
        raw.close()
    except Exception:
        raw.close()
PYEOF

python3 "$WORK/server.py" "$WORK" > "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
[ -n "$PORT" ] || { echo "  ✗ the peer did not start"; exit 1; }

PASS=0; FAIL=0
check() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1)); else echo "  ✗ $1"; echo "    want: $3"; echo "    got:  $2"; FAIL=$((FAIL + 1)); fi
}

cd "$PKG"
GOOD="$(TLS_PORT="$PORT" TLS_CA="$WORK/cert.pem" "$NOVO" run tests/tls_probe.nv 2>&1 | command grep -E '^(open|sent|echo|quiet|closed|dial|close)')"
check "the dial, the echo, the deadline and the close" "$GOOD" "open true
sent 5
echo ok 5
quiet err timed out
closed err closed
closed ok"

BAD="$(TLS_PORT="$PORT" TLS_CA="$WORK/other.pem" "$NOVO" run tests/tls_probe.nv 2>&1 | command grep -E '^(open|dial)' | cut -c1-9)"
check "a certificate that is not the peer's is refused" "$BAD" "dial err "

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
