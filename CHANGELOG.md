# Changelog

All notable changes to websocket-nv are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

## 0.1.1 — 2026-11-03

This release requires novo 0.23.0 or later.

## 0.1.0 — 2026-10-29

First implementation of the interface published as 0.0.5. Every function has a body, the package is `experimental`, and the floor is toolchain 0.22.0. The dependency ranges are `websocket-codec-nv ^0.1.0`, `http-codec-nv ^0.1.0` and `flate-nv ^0.1.0`.

### Added

- The client and the server upgrade, over http-codec-nv's request and response types and over a transport, with the four checks on the server's answer, subprotocol choice in the server's order, and a refusal that is an HTTP response (426 with `Sec-WebSocket-Version` for a wrong version).
- `wsconn.pump` reads the transport, answers pings, echoes a close, fails the connection with the close code the fault owes the peer, runs the close and pong deadlines and sends the idle ping. `send_text`, `send_binary`, `send_fragment`, `send_ping` and `close` write frames, cut messages at `max_send_frame` and mask a client's frames.
- permessage-deflate: the offer and answer for every parameter RFC 7692 section 7.1 defines, compression with the trailing four bytes removed, a decoder that keeps the peer's window across messages unless the peer declared `no_context_takeover`, a window shorter than 15 bits honoured by compressing in pieces of that size, and a budget on what one message may inflate to.
- `wsdeflate.new_inflater` and `wsdeflate.inflate_step`, the decoder step `wsconn` uses, public because the connection is a separate module.
- `wsconn.started_with`, which gives a connection the seed of its mask keys and the bytes the transport delivered after the handshake.
- `wstrans.send_all`, `wstrans.read_head` and `wstrans.WsHead`, the two transport steps the handshake on both sides shares.
- `WsConnError` gains `WsTextNotUtf8` (close code 1007) and `WsHeadNotBuildable`, for a text message that is not UTF-8 and for a handshake head that cannot be written as HTTP.
- `WsClientHandshake` gains `mask_seed`. A drawn handshake takes it from the system's entropy, and a handshake made from a given nonce derives it from the nonce.
- `tests/`: the Autobahn Testsuite's conversations for framing, pings, reserved bits, opcodes, fragmentation, UTF-8, closing and limits as tables of bytes; the handshake on both sides over a transport and over a loopback socket; permessage-deflate against streams written by CPython's zlib; `tests/tls_loopback.sh` for `WsTls` against a TLS peer; `tests/interop.sh`, which runs Node's WebSocket client against a server built on this package and a client built on it against an echo server written in Python on its socket and zlib modules, with and without permessage-deflate; `tests/coverage.sh`; `tests/vectors.py`. Line coverage of `src/` is 97.3%, and the lines left are marked with the reason.

### Changed

- A fault found in a read that also held events arrives with the next `pump`, after the events. The close frame the fault owes the peer is sent in the turn that found it. A fault in a read with no events is returned at once, as before.
- `WsTransport.ws_recv` reads an empty answer from a transport that reports itself open as nothing yet, and `Err(IoClosed)` as the peer having closed. `Err(IoTimedOut)` is a receive deadline. The comment on the trait says so.
- `wsconn.WsConn` gains the fields the implementation keeps between turns (`raw`, `compressed`, `inflater`, `streaming_out`, `mask_seed`, `mask_count`, `failed`). The struct is not meant to be built by hand, and `wsconn.connection` is its constructor.
- `wsclient.accept_response` checks the `Upgrade` and `Connection` fields of the response (RFC 6455 section 4.1) as well as the status, the accept value, the subprotocol and the extension. A status other than 101 is `WsUpgradeAnswered` with an empty body, because the response type carries no body.
- `wsdeflate.check_answer` accepts a server that leaves out `server_no_context_takeover` although it was offered, and reads the answer as a server that keeps its window. A window parameter in the answer that the client did not offer, or that is wider than the offer, is refused.
- `tests/wshake_tests.nv` built `wshandshake.UnsupportedVersion` without its payload. It is `UnsupportedVersion(8)`, as the test's own name describes.
- The comments in `src/` and `novo.toml` and the README are in the plain register.

### Known

- A message sent with `send_fragment` is binary, and a streamed message is never compressed.
- A text message is checked as UTF-8 when it is whole, so a connection that receives invalid text fails at the end of the message and not at the first bad byte.
- With `max_message` set to 0 the caller is streaming, and neither the UTF-8 check nor the inflate budget applies.
- An outgoing message is compressed on an empty window, whatever was negotiated, so the ratio of a connection with context takeover is that of `no_context_takeover`.
- `wstrans.WsTls.ws_recv` cannot tell a receive deadline from a peer that closed without a close_notify, because `tls.last_error()` gives the same text for both. An abrupt close reads as a deadline, and `pong_timeout_ms` is what ends the connection. This is the `workaround(tls-recv-cannot-tell-a-receive-deadline-from-an-abrupt-close)` at the site.
- `WsTls` is exercised by `tests/tls_loopback.sh`, which needs `openssl` and `python3`, and not by `novo test`. Its lines carry `cov: skip` with that reason.
- The codec refuses a set RSV1, so on a connection that negotiated permessage-deflate `wsconn` cuts the stream into frames itself and clears the bit on the first frame of a compressed message.

## 0.0.5 — 2026-10-25

A file that names a sibling module's type, function or constant now has the `use` line for that module (E2033, E2003).  No signature and no behaviour changed.

## 0.0.4 — 2026-09-28

The dependency ranges move to the dependencies' current releases.  A
pre-1.0 caret range admits only the release it names, so the old
ranges held this package on interface releases, and a program could
not take this package beside those packages' current releases.  No
signature in this package changed.

- websocket-codec-nv: `^0.0.3` to `^0.0.6`.
- http-codec-nv: `^0.0.1` to `^0.1.0`.

## 0.0.3 — 2026-09-18

### Changed

- **`wstrans.dial_tls` and `.tls_for` name `TlsConfig`**, the standard
  library's own record, and `WsTlsConfig` is gone.  `std.tls` became
  reachable from user source on 2026-09-18: `use std.tls` resolves, the
  surface is spelled `tls.*`, and `docs/stdlib/tls.md` is its page.  The
  reason this package declared its own record — no `use` brought the
  module into scope, so no signature could name its type — no longer
  holds, and the globally-unique type rule prefers one record over a
  prefixed clone per package.
- **Nothing was dropped.**  `WsTlsConfig`'s three fields — `hostname`,
  `verify_peer`, `ca_bundle_path` — are three of `TlsConfig`'s five,
  field for field.  The other two, `cert_path` and `key_path`, are the
  server side's PEM paths, which a `wss://` dial leaves empty.
- **TLS is still a hook and not a field.**  `WsTransport[e]` names no
  transport, and naming the standard library's config in `dial_tls`
  does not put one on the trait.
- **`tls_for` stays and is now exactly `tls.config_for_client`.**  It is
  kept so a `wss://` dial needs one `use`, not two.

### Requires

- **`novo = ">= 0.9.1"`**, up from `>= 0.8.9`.  The package names
  `TlsConfig`, which the 0.9.0 toolchain has no module for: `std.tls`
  ships as a reachable module in 0.9.1.  A 0.9.0 build of this release
  fails on the undefined type, so the floor states it rather than
  letting it be discovered at `E2033`.

## 0.0.2 — 2026-09-15

README rewritten to the package README style guide (docs/writing-a-readme.md).

### Changed

- **`wstrans.dial_tls` and `.tls_for` name `WsTlsConfig`**, a struct
  this package declares, where 0.0.1 named a bare `TlsConfig`.  No such
  type exists in any build: the standard library's TLS surface is not
  published, and the name type-checked in 0.0.1 only because the
  undefined-type check (`E2033`) had not landed.  The fields are the
  ones the two functions always meant — `hostname` for SNI and the
  certificate name match, `verify_peer`, and `ca_bundle_path` for a
  caller that pins its own roots.  A 0.0.1 consumer could not have
  called either function, so nothing that compiled before stops.

## 0.0.1 — 2026-09-11

The **interface**: every signature and every effect row, and no bodies.
`stability = "draft"`, and the release is recorded `implemented = false`.

### Added

- `wsconn` — `WsConnState` with its two closing states, the connection
  value, the six events a turn can produce, and `pump`, which answers
  the pings, echoes the closes and sends the protocol-error close
  before any of it reaches the caller.
- `wstrans` — `WsTransport[e]`, the TLS hook spelled as a trait, with
  `WsTcp` (`[io, net]`), `WsTls` (`[net]`), a listener, and
  `address_of`, which gets the default port from the scheme.
- `wsclient` — the client handshake over http-codec-nv's types, with
  `nonce` and `mask_keys` as the two `[rand]` rows the codec
  deliberately would not draw, and `handshake_with_nonce` beside
  `handshake` so the exchange stays assertable.
- `wsserve` — `WsUpgradeOutcome` as a value rather than a callback, a
  server policy, and `refusal_response`, because a refused upgrade is
  still an HTTP response.
- `wsdeflate` — permessage-deflate's negotiation and parameters, the
  four bytes RFC 7692 removes and appends, and `worth_compressing`.
- `wsconnerr` — the faults that only exist once a socket does, each
  carrying the codec's own error where one caused it.

### Known

- **`WsConnState` is the load-bearing interface**, and its two closing
  states are why.  `can_send` is true only in `WsOpen`; `can_receive`
  is true in `WsOpen` and in `WsClosingLocal`, and that asymmetry is
  the whole close handshake.
- **Two deadlines, and they are different numbers**: how long to wait
  for the peer's close (RFC 6455 § 7.1.1) and how long to wait for a
  pong.  Both are milliseconds the caller supplies, so both are tables.
- **1006 is reported and never sent.**  `WsFailed` is a state and not a
  close code a caller can put on a wire.
- **`pump` discharges the three MUSTs** — answer a ping, echo a close,
  close on a protocol error — rather than returning them as work.
- **TLS is a hook and not a field.**  `WsTransport[e]` names no
  transport, so a program terminating TLS elsewhere plugs its own in.
- **`std.ws` is coexisted with, not wrapped.**  Its framing happens
  outside novo-lang, so there is nothing to wrap; the README has the
  table that says which to reach for.
- **`http-codec-nv` is pinned `^0.0.1` and not `^0.0.2`**, because
  websocket-codec-nv 0.0.3 requires exactly 0.0.1 and one version of a
  package is built into a program.  The line moves when the codec's
  does.
- **The subprotocol and the `Origin` are the application's.**  This
  package hands over the list and the header and decides neither.
- **No device claim.**  The package is `host`.
- **Three `core` dependencies**: websocket-codec-nv, http-codec-nv and
  flate-nv, all of which are interfaces themselves today.

### Design notes

The reference implementations for the port are `tungstenite` for the
client and the connection shape, `websockets` (Python) for the close
handshake's two deadlines, and the Autobahn Testsuite as the oracle the
finished implementation will be measured against. Three things change in
the crossing. `tungstenite`'s `WebSocket<S>` is generic over a
`Read + Write` stream; here the transport is `WsTransport[e]`, a trait
of this package's own with four methods, one of which — `ws_is_open` —
has no effect row, because a close handshake asks it on every turn. Its
`Message::Text(String)` stays the codec's `TextMessage([u8])`, so
invalid UTF-8 is reportable. And its internal `Instant`s become
millisecond integers taken as arguments, which is what makes both
deadlines assertable against a table.
