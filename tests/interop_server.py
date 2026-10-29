"""A WebSocket echo server that is not this package, for tests/interop.sh.

It speaks RFC 6455 and permessage-deflate with Python's socket and zlib
modules and nothing else. It serves one connection per run of the loop and
echoes every message back, compressed when the client offered compression.
"""
import base64
import hashlib
import socket
import struct
import sys
import zlib

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_head(sock):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_frame(sock):
    b0, b1 = read_exact(sock, 2)
    fin, rsv1, op = b0 & 0x80, b0 & 0x40, b0 & 0x0F
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", read_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", read_exact(sock, 8))[0]
    key = read_exact(sock, 4) if b1 & 0x80 else b"\0\0\0\0"
    data = bytearray(read_exact(sock, n))
    for i in range(n):
        data[i] ^= key[i % 4]
    return bool(fin), bool(rsv1), op, bytes(data)


def frame(op, payload, rsv1=False):
    b0 = 0x80 | op | (0x40 if rsv1 else 0)
    n = len(payload)
    if n < 126:
        head = struct.pack(">BB", b0, n)
    elif n < 65536:
        head = struct.pack(">BBH", b0, 126, n)
    else:
        head = struct.pack(">BBQ", b0, 127, n)
    return head + payload


def serve(conn, deflate_on):
    head = read_head(conn).decode("latin-1")
    fields = {}
    for line in head.split("\r\n")[1:]:
        if ": " in line:
            k, v = line.split(": ", 1)
            fields[k.lower()] = v
    accept = base64.b64encode(hashlib.sha1(fields["sec-websocket-key"].encode() + GUID).digest()).decode()
    ext = ""
    packed = deflate_on and "permessage-deflate" in fields.get("sec-websocket-extensions", "")
    if packed:
        ext = "Sec-WebSocket-Extensions: permessage-deflate\r\n"
    conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  "Sec-WebSocket-Accept: %s\r\n%s\r\n" % (accept, ext)).encode())
    inflater = zlib.decompressobj(-15)
    message, message_op, message_packed = b"", 0, False
    while True:
        fin, rsv1, op, data = read_frame(conn)
        if op == 8:
            conn.sendall(frame(8, data[:2]))
            return
        if op == 9:
            conn.sendall(frame(10, data))
            continue
        if op in (1, 2):
            message, message_op, message_packed = data, op, rsv1
        elif op == 0:
            message += data
        if not fin:
            continue
        body = message
        if message_packed:
            body = inflater.decompress(body + b"\0\0\xff\xff")
        out, flag = body, False
        if packed and len(body) > 0:
            c = zlib.compressobj(6, zlib.DEFLATED, -15)
            out = (c.compress(body) + c.flush(zlib.Z_SYNC_FLUSH))[:-4]
            flag = True
        conn.sendall(frame(message_op, out, flag))


def main():
    deflate_on = sys.argv[2] == "deflate"
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    print(srv.getsockname()[1], flush=True)
    while True:
        conn, _ = srv.accept()
        try:
            serve(conn, deflate_on)
        except EOFError:
            pass
        finally:
            conn.close()


main()
