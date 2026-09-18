# Changelog

All notable changes to websocket-nv are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

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
