# websocket-nv

**Status: NOT IMPLEMENTED — interface only.**

Every public function below is published with its signature and its
effect row, and every body is `todo()`.  Installing this package works;
calling it panics with `not implemented`.

## What this is

The half of WebSocket that owns a socket.  websocket-codec-nv turns
frames into bytes and bytes into frames; this package performs the RFC
6455 upgrade on both sides, holds the connection, answers the pings,
runs the close handshake with its two deadlines, negotiates
permessage-deflate, and hands a server the shape it needs to add one
route.

It does not own a loop.  A host holds a `WsConn`, reads its clock once
per turn, calls `pump`, and acts on the events it gets back.

## Adding it, and checking it

```bash
novo pkg add websocket-nv      # into your novo.toml
novo pkg build                 # type- and effect-check the package
novo test --isolate tests/wsconn_tests.nv
```

`novo test` is red today and that is the point of the release: every
assertion fails with `not implemented: websocket-nv.<module>.<fn>`.
They turn green one at a time as bodies land.

## The one example that will work

```novo
use wsclient
use wsconn
use wstrans

// Open a connection, read messages until the peer closes, and close
// back properly — which means pumping until the handshake finishes
// rather than dropping the socket.
fn run(url: Str) -> Result<Unit, WsConnError> [io, net, time, rand]
    let a = wstrans.address_of(url) ?? wstrans.address_of("ws://localhost/")!
    let t = wstrans.dial_tcp(a.host, a.port)!
    var c = wsclient.connect(t, wsclient.request(a), wsconn.default_options())!

    loop
        let turn = wsconn.pump(c, t, wsconn.now_ms())!
        c = turn.conn
        for ev in turn.events
            match ev
                WsMessageReceived(m) => deliver(m)
                WsCloseCompleted     => nothing()
                _                    => nothing()
        if not wsconn.can_receive(c)
            break
    Ok(unit())
```

## The layer, and why

`host`, and the rows are not all the same.

| module | row | why |
| --- | --- | --- |
| `wstrans.dial_tcp`, `.listen`, `.accept` | `[io, net]` | `std.net`'s own row |
| `wstrans.dial_tls` | `[net]` | `std.tls`'s own row, which is narrower |
| `wsconn.now_ms` | `[time]` | the one function in the package that reads a clock |
| `wsclient.nonce`, `.mask_keys`, `.handshake` | `[rand]` | the entropy the codec deliberately would not draw |
| `wsclient.connect` | `[e, rand]` | the transport's row, plus the nonce |
| `wsconn.pump`, `.send_text`, `.send_binary`, `.send_fragment`, `.send_ping`, `.close`, `wsserve.accept_upgrade` | `[e]` | effect-POLYMORPHIC: whatever the transport costs |
| everything else — options, deflate negotiation, the server policy, the close arithmetic | `[]` | values |

## The load-bearing interface

`WsConnState`, and specifically its **two** closing states.

```novo
pub enum WsConnState
    WsOpen            // both directions carry data
    WsClosingLocal    // we sent a close; the peer may still send DATA
    WsClosingRemote   // the peer sent a close; we may send ours and no more
    WsClosed          // a close went each way
    WsFailed          // the TCP connection went with no close frame — 1006
```

A WebSocket does not close; it performs a handshake, and the handshake
is not symmetric.  A library that modelled this as one boolean makes
four specific bugs unavoidable, and all four are Autobahn cases:

- a client that stops reading after sending its close never sees the
  peer's answer, and reports every clean shutdown as an abort;
- one that keeps sending after the close sends frames a conforming peer
  must fail the connection over;
- one that cannot tell a close frame from a dropped socket reports 1006
  for both — and then sends 1006 back, which is one of the three codes
  RFC 6455 § 7.4.1 says may never travel;
- and one with no deadline waits forever for a peer that has crashed.

`can_send` and `can_receive` are the two questions that fall out of it,
and their asymmetry is the whole handshake: `can_send` is true only in
`WsOpen`, `can_receive` is true in `WsOpen` **and** `WsClosingLocal`.

The second decision is `WsTransport[e]` as the TLS hook.  "TLS via a
hook" could have been a boolean on the options or a `?TlsConfig` field,
and both would have been wrong the same way — they name the two
transports this package happens to know about and refuse every other
one.  A trait names none of them, so a program terminating TLS at a
load balancer, speaking WebSocket over a unix socket, or replaying a
recorded conversation supplies its own and pays for nothing it does not
use.  It is also what makes the Autobahn cases writable: over a socket
they are integration tests with timing in them; over a transport that
hands back bytes from memory they are tables.

## What `pump` answers without being asked

A ping gets a pong with the same payload; a close gets a close; a
decode fault gets the close code `wsclose.close_code_for` names — all
inside `pump`, all before the error reaches the caller.  Those are the
three things RFC 6455 says an endpoint MUST do, and returning them as
work for the caller is how a library ends up with callers that each
forget a different one.

## What `std.ws` does, and whether this replaces it

`std.ws` is forty lines: a `WebSocket` struct holding a session id, and
six methods — `connect`, `send`, `recv`, `send_bytes`, `recv_bytes`,
`close` — each handing a `Str` or a `Bytes` to the runtime, every one
of them `[io, net]`.  There is no frame type in it, no close code, no
fragmentation and no handshake, because **the framing happens outside
novo-lang entirely**: the handle is an opaque session id the runtime
keys its own connection state off.

So this package **coexists** with it, and could not wrap it if it
wanted to.  There is nothing to wrap — no socket to take over, no bytes
to intercept, no place to put a frame encoder.  The two are different
implementations of the same protocol at different levels, and the
choice between them is not about quality:

| | `std.ws` | websocket-nv |
| --- | --- | --- |
| client | yes | yes |
| server | no | yes |
| close code, and why | no | yes |
| fragmentation, streaming a large message | no | yes |
| permessage-deflate | no | yes |
| answering a ping within a deadline | the runtime's | yours, with the number |
| a transport of your own | no | `WsTransport[e]` |
| lines to write for "talk to one server" | 3 | about 15 |

`std.ws` stays exactly as it is, and it is the right answer for the
program that wants three lines.  This package is for everything it
cannot express: a server, a proxy, a fuzzer, an endpoint that has to
answer a ping within a deadline, and any program that needs to know
**why** a connection closed rather than only that it did.

## The accept loop for orbit/http-server

A WebSocket server is an HTTP server with one more route, and the shape
here exists so that stays true.  `orbit/http-server` already has an
accept loop, a router and a request type; what it does not have is a
way for one route to say "this exchange stops being HTTP now".

`wsserve.upgrade` takes an `H1Request` — http-codec-nv's, the same one
the server already parsed — and answers a value:

```novo
pub enum WsUpgradeOutcome
    WsUpgradeAccepted(response: H1Response, conn: WsConn)
    WsUpgradeRefusedWith(response: H1Response)
    WsNotAnUpgrade
```

A value and not a callback, because that is what lets the server apply
its own policy between parsing the request and accepting it:
authenticate the `Origin`, check a session cookie, count connections
per address.  A function that took a handler would have to be given all
of that as options it does not understand.

`WsNotAnUpgrade` is a separate arm rather than a `None` because a
server that conflated "this is not an upgrade" with "this upgrade is
refused" answers 400 to its own home page.

And a refused upgrade is still an **HTTP response**.  A client whose
handshake is refused wants a status it can show a person; a server that
closed the socket instead leaves it waiting for a response that never
comes.  `refusal_response` builds it, and a version mismatch gets 426
with the `Sec-WebSocket-Version: 13` header RFC 6455 § 4.4 requires.

## permessage-deflate, and the four bytes

RFC 7692 § 7.2.1: a sender compresses the message and then **removes**
the trailing `00 00 FF FF` before framing it; a receiver **appends**
those four bytes before inflating.  They are DEFLATE's
empty-stored-block marker, and dropping them is what lets one DEFLATE
stream span many messages without each paying for a flush.  An
implementation that forgets either half produces frames that decompress
to nothing everywhere else, and the failure looks like corruption
rather than like a missing four bytes.

`no_context_takeover` is a **memory** decision, not a speed one.
Without it each side keeps a 32 KiB sliding window per connection per
direction for the life of the connection — 640 MB on a server with ten
thousand connections.  `wsdeflate.default_params` asks for it; a server
that wants the compression ratio back says so, having read this
paragraph.

## What this does not do, on purpose

- **It does not own a loop**, a thread, a channel or a callback.
- **It does not sleep.**  `WsTurn.wait_ms` answers a number.
- **It does not pick a subprotocol for you.**  `choose_protocol` applies
  a preference order the server supplies; the package has none.
- **It does not check the `Origin`.**  `origin_of` hands it over.  A
  library that enforced a policy would be deciding for every
  application built on it, including the ones with no browser near
  them.
- **It does not decode text to `Str`.**  A text message is bytes,
  because § 8.1 makes invalid UTF-8 a close with 1007 and the invalid
  case has to survive long enough to be reported.
- **It does not do HTTP/2 or HTTP/3 WebSockets** (RFC 8441).  That is a
  different handshake over a different transport, and it wants the same
  `http2-nv` grpc-codec-nv's README names as a missing row.
- **No device claim.**  The package is `host`.  A device that needs a
  framed message stream over a constrained link should look at
  mqtt-codec-nv, which was designed for exactly that.

## The reference implementation

`tungstenite` for the client and the connection shape, `websockets`
(Python) for the close handshake's two deadlines, and the Autobahn
Testsuite as the oracle the implementation will be measured against.

Three things change in the port.  `tungstenite`'s `WebSocket<S>` is
generic over a `Read + Write` stream; here the transport is a trait of
this package's own with four methods, one of which —
`ws_is_open` — has no effect row, because a close handshake asks it on
every turn.  Its `Message::Text(String)` stays the codec's
`TextMessage([u8])`, so invalid UTF-8 is reportable.  And its internal
`Instant`s become millisecond integers taken as arguments, which is what
makes both deadlines assertable against a table.

## Status

| item | implemented |
| --- | --- |
| `wstrans` — `WsTransport[e]`, `WsTcp`, `WsTls`, `WsListener`, `WsAddress`, `WsAccepted` | types only |
| `wstrans.WS_PORT`, `.WSS_PORT` | yes — they are constants |
| `wstrans.address_of`, `.dial_tcp`, `.dial_tls`, `.tls_for` | no |
| `wstrans.listen`, `.accept`, `.stream_of` | no |
| `wstrans` — both `WsTransport` impls | no |
| `wsconn` — `WsConnState`, `WsConnOptions`, `WsConn`, `WsConnEvent`, `WsTurn` | types only |
| `wsconn.default_options`, `.quiet_options`, `.connection` | no |
| `wsconn.state_of`, `.can_send`, `.can_receive`, `.now_ms` | no |
| `wsconn.pump`, `.send_text`, `.send_binary`, `.send_fragment`, `.send_ping`, `.close` | no |
| `wsconn.peer_close`, `.local_close`, `.subprotocol_of`, `.deflate_of` | no |
| `wsconn.wait_ms`, `.close_expired`, `.pong_expired`, `.ping_due` | no |
| `wsclient` — `WsClientRequest`, `WsClientHandshake` | types only |
| `wsclient.request`, `.with_protocols`, `.with_headers`, `.with_deflate` | no |
| `wsclient.nonce`, `.mask_keys` | no |
| `wsclient.handshake`, `.handshake_with_nonce`, `.request_bytes` | no |
| `wsclient.accept_response`, `.connect` | no |
| `wsserve` — `WsUpgradeOutcome`, `WsServerPolicy` | types only |
| `wsserve.policy`, `.with_protocols`, `.with_deflate`, `.with_options` | no |
| `wsserve.is_upgrade`, `.upgrade`, `.choose_protocol`, `.origin_of` | no |
| `wsserve.refusal_response`, `.response_bytes`, `.accept_upgrade` | no |
| `wsdeflate` — `WsDeflateParams`, `WsDeflateState` | types only |
| `wsdeflate.WS_DEFLATE_MIN_WINDOW_BITS`, `.WS_DEFLATE_MAX_WINDOW_BITS`, `.WS_DEFLATE_TAIL_LEN`, `.WS_PERMESSAGE_DEFLATE` | yes — they are constants |
| `wsdeflate.default_params`, `.offer_header`, `.answer_header`, `.extensions_header` | no |
| `wsdeflate.accept_offer`, `.check_answer` | no |
| `wsdeflate.compress`, `.decompress` | no |
| `wsdeflate.send_window_bits`, `.resets_context`, `.worth_compressing` | no |
| `wsconnerr` — `WsConnError`, the `message` impl | type only |
| `wsconnerr.close_code_for`, `.is_reconnectable`, `.http_status_for` | no |
