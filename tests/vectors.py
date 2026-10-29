#!/usr/bin/env python3
"""Regenerate the permessage-deflate vectors in tests/wsdeflate_tests.nv and
tests/wscompress_tests.nv.

Every vector is written by CPython's zlib, the independent encoder the tests
check the decoder against. The script rewrites the text between the
`BEGIN VECTORS` and `END VECTORS` lines of each test file.

    python3 tests/vectors.py
"""
import os
import random
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SUITES = [os.path.join(HERE, "wsdeflate_tests.nv"), os.path.join(HERE, "wscompress_tests.nv")]

TAIL = bytes([0, 0, 255, 255])


def pm_deflate(payload, wbits=15, level=6):
    """One message as RFC 7692 section 7.2.1 sends it, on a fresh window."""
    c = zlib.compressobj(level, zlib.DEFLATED, -wbits)
    out = c.compress(payload) + c.flush(zlib.Z_SYNC_FLUSH)
    assert out.endswith(TAIL)
    return out[:-4]


def sequence(payloads, wbits=15):
    """Messages on one window, as a peer with context takeover sends them."""
    c = zlib.compressobj(6, zlib.DEFLATED, -wbits)
    msgs = []
    for p in payloads:
        out = c.compress(p) + c.flush(zlib.Z_SYNC_FLUSH)
        assert out.endswith(TAIL)
        msgs.append(out[:-4])
    return msgs


def final_block(payload):
    """A message that ends its stream with BFINAL set and no tail."""
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    return c.compress(payload) + c.flush(zlib.Z_FINISH)


def text(n, seed):
    rng = random.Random(seed)
    words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
    out = []
    size = 0
    while size < n:
        w = rng.choice(words)
        out.append(w)
        size += len(w) + 1
    return " ".join(out).encode()[:n]


def noise(n, seed):
    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(n))


def lit(name, data):
    return 'fn %s() -> Str\n    "%s"\n' % (name, data.hex())


def main():
    single = [
        ("hello", b"Hello"),
        ("empty", b""),
        ("text300", text(300, 1)),
        ("text5000", text(5000, 2)),
        ("noise1000", noise(1000, 3)),
    ]
    seq_payloads = [b"Hello Hello Hello Hello", b"Hello Hello again Hello", b"Hello"]
    seq = sequence(seq_payloads)
    out = []
    for name, data in single:
        out.append(lit("vec_%s_packed" % name, pm_deflate(data)))
        out.append(lit("vec_%s_plain" % name, data))
    for i, (p, m) in enumerate(zip(seq_payloads, seq)):
        out.append(lit("vec_seq%d_packed" % i, m))
        out.append(lit("vec_seq%d_plain" % i, p))
    out.append(lit("vec_final_packed", final_block(b"Hello")))
    out.append(lit("vec_final_plain", b"Hello"))
    # A message cut inside a block: the first bytes of a real one.
    out.append(lit("vec_cut_packed", pm_deflate(text(300, 1))[:5]))
    block = "// BEGIN VECTORS\n\n" + "\n".join(out) + "\n// END VECTORS\n"
    for suite in SUITES:
        src = open(suite).read()
        a = src.index("// BEGIN VECTORS")
        b = src.index("// END VECTORS") + len("// END VECTORS\n")
        open(suite, "w").write(src[:a] + block + src[b:])


if __name__ == "__main__":
    main()
