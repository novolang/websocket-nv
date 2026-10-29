# websocket-nv

The WebSocket Protocol gives a client and a server two-way messaging over
one TCP connection, in both directions at once. It is specified in
[RFC 6455](https://www.rfc-editor.org/rfc/rfc6455). This package is the
half of it that owns a socket: it performs the opening handshake on both
sides, holds the connection, answers pings, runs the close handshake with
its deadlines, and negotiates the compression extension
[RFC 7692](https://www.rfc-editor.org/rfc/rfc7692) defines. The frame
arithmetic underneath is
[websocket-codec-nv](https://novo-lang.org/packages/websocket-codec-nv),
the handshake is spelled in
[http-codec-nv](https://novo-lang.org/packages/http-codec-nv)'s HTTP/1.1
types, and the compression itself is
[flate-nv](https://novo-lang.org/packages/flate-nv)'s.

## What a WebSocket connection is

A connection begins as an HTTP/1.1 request that asks to change protocol.
The client sends a `GET` carrying `Upgrade: websocket`,
`Connection: Upgrade`, a `Sec-WebSocket-Key` of sixteen random bytes in
base64, and `Sec-WebSocket-Version: 13`. The server answers `101
Switching Protocols` with a `Sec-WebSocket-Accept` computed from that
key. RFC 6455 section 4 defines the exchange. From then on the same
socket carries frames, and either side may send at any time.

The URL scheme decides the transport and the default port.

| Scheme | Transport | Default port |
| --- | --- | --- |
| `ws://` | TCP | 80 |
| `wss://` | TLS over TCP | 443 |

A WebSocket does not simply close. It performs a **close handshake**
(section 7.1.1): one side sends a close frame, the other answers with a
close frame of its own, and only then does the socket go. The handshake
is not symmetric, so a connection has five states rather than a boolean.

| State | May send data | May receive data | What has happened |
| --- | --- | --- | --- |
| `WsOpen` | yes | yes | Both directions carry data |
| `WsClosingLocal` | no | yes | This endpoint sent a close and is waiting for the peer's |
| `WsClosingRemote` | no | no | The peer sent a close, and this endpoint may send its own close and nothing else |
| `WsClosed` | no | no | A close went each way |
| `WsFailed` | no | no | The TCP connection ended with no close frame |

`can_send` and `can_receive` are those two columns as functions. Their
asymmetry is the whole handshake. An endpoint that has sent its close
must keep reading, because the peer's remaining data frames are legal,
its pings still have to be answered, and its close is the thing being
waited for.

An endpoint that waited forever for that answer would hang against a
peer that has crashed, so there are two deadlines, and they are
different numbers. The **close timeout** is how long to wait for the
peer's close after sending one. The **pong timeout** is how long to wait
for the answer to a ping. RFC 6455 requires no ping at all, so the
second is the caller's policy.

| Setting | `default_options` | What it does |
| --- | --- | --- |
| `close_timeout_ms` | 5000 | How long to wait for the peer's close frame |
| `pong_timeout_ms` | 10000 | How long to wait for a pong. Zero turns the check off |
| `ping_interval_ms` | 30000 | How often to ping an idle connection. Zero sends none |
| `max_send_frame` | 65536 | The largest payload this endpoint puts in one frame |
| `limits` | the codec's defaults | A 16 MiB frame and a 64 MiB message |
| `compress_outgoing` | true | Compress outgoing messages where the extension was negotiated |

`quiet_options` is the same with no ping interval and no pong deadline,
for a caller whose transport already has a keep-alive of its own.

A connection is a value and the loop is the caller's. The host reads its
clock once per turn, calls `pump`, and acts on the events it gets back.
A turn also answers `wait_ms`, which is how long the caller may wait
before pumping again.

**permessage-deflate** is the extension that compresses a message's
payload, negotiated in the handshake with a `Sec-WebSocket-Extensions`
header. RFC 7692 section 7.2.1 has the rule everybody gets wrong: a
sender compresses the message and then removes the trailing `00 00 FF
FF` before framing it, and a receiver appends those four bytes before
inflating. They are DEFLATE's empty-stored-block marker. An
implementation that forgets either half produces frames that decompress
to nothing everywhere else.

| Parameter | Range | Meaning |
| --- | --- | --- |
| `server_max_window_bits`, `client_max_window_bits` | 8 to 15 | The compression window as a base-two logarithm, so 256 bytes to 32 KiB |
| `server_no_context_takeover`, `client_no_context_takeover` | on or off | Whether that window is dropped after every message |
| The removed tail | 4 bytes | `00 00 FF FF`, removed by the sender and appended by the receiver |

A message this package sends is compressed on its own, with an empty
window, whatever was negotiated, and only when it is 128 bytes or longer.
A message it receives is inflated through the peer's window, which is
carried from one message to the next unless the peer declared
`no_context_takeover` for its direction. RFC 7692 section 6.1 puts RSV1
on the first frame of a message only, and on no control frame.

## Install

```
novo pkg add websocket-nv
```

## Example

```novo
use wsclient
use wsconn
use wstrans

fn main() [io, net, rand, time]
    match wstrans.address_of("ws://localhost:8080/chat")
        None    => println("that is not a websocket url")
        Some(a) =>
            match talk(a)
                Ok(_)  => println("the close handshake finished")
                Err(e) => println("the connection ended: ${e.message()}")

// Dial the address the URL named. The scheme chose the port.
fn talk(a: WsAddress) -> Result<WsConn, WsConnError> [io, net, rand, time]
    match wstrans.dial_tcp(a.host, a.port)
        Err(e) => Err(WsSocketFailed(e))
        Ok(t)  => drive(t, a)

fn drive(t: WsTcp, a: WsAddress) -> Result<WsConn, WsConnError> [io, net, rand, time]
    // Perform the upgrade. The sixteen random bytes of the key are
    // drawn here, which is why this function declares `[rand]`.
    var c: WsConn = wsclient.connect(t, wsclient.request(a), wsconn.default_options())!

    var reading = true
    while reading
        // One turn: read what arrived, answer the pings, echo a close,
        // and check both deadlines against this clock reading.
        let turn: WsTurn = wsconn.pump(c, t, wsconn.now_ms())!
        c = turn.conn
        for ev in turn.events
            report(ev)
        // False once the peer's close has arrived and been answered.
        reading = wsconn.can_receive(c)
    Ok(c)

// Everything a turn can teach the caller.
fn report(ev: WsConnEvent) [io]
    match ev
        WsMessageReceived(_)  => println("a whole message arrived")
        WsFragmentReceived(_) => println("one fragment arrived")
        WsPingAnswered(_)     => println("the peer pinged and has been answered")
        WsPongReceived(ms)    => println("the peer answered in ${ms} ms")
        WsCloseReceived(_)    => println("the peer began the close handshake")
        WsCloseCompleted      => println("both closes have gone")
```

Build and test with `novo pkg build` and `novo test`.

## What the package contains

| Module | Contents |
| --- | --- |
| `wsconn` | The connection value, its five states, the options, the six events a turn can produce, and `pump`, which performs one turn. |
| `wstrans` | The transport. A trait any byte pipe can implement, a TCP implementation, a TLS implementation dialled with the standard library's `TlsConfig`, a listener, and the address a `ws://` or `wss://` URL names. |
| `wsclient` | The client side of the upgrade: the request a client offers, the random nonce and mask keys, and the check the server's answer has to pass. |
| `wsserve` | The server side of the upgrade: what a server is willing to accept, the decision as a value, and the HTTP response a refusal gets. |
| `wsdeflate` | permessage-deflate. The offer, the answer, the parameters, the four bytes RFC 7692 removes and appends, and whether a message is worth compressing. |
| `wsconnerr` | The faults that exist only once there is a socket, each carrying the codec's own error where one caused it, and the close code each owes the peer. |

## How to choose an entry point

**A client that wants a connection calls `wsclient.connect`.** It writes
the request, reads the response, checks the accept value and hands back
a `WsConn`. It draws the nonce itself.

**A client that drives the exchange itself calls
`wsclient.handshake_with_nonce`, then `request_bytes`, then
`accept_response`.** Use that path in a test, where the nonce has to be
the RFC's example rather than a fresh sixteen bytes, or in a program
that multiplexes the handshake over an HTTP/1.1 connection it already
holds.

**A server that is only a WebSocket server calls
`wsserve.accept_upgrade`.** It reads the request off a freshly accepted
transport, decides, writes the answer and hands back a `WsConn`.

**A server that also serves HTTP calls `wsserve.upgrade`.** It takes an
`H1Request` the server has already parsed and answers a
`WsUpgradeOutcome`: a response and a connection, a response and nothing,
or the fact that this was not an upgrade request at all. The server
writes the response itself. That is what lets an HTTP server keep its
own accept loop and add one route, and it is what leaves room for the
server's own policy between parsing the request and accepting it.

**A program with a transport of its own implements `WsTransport`.**
`WsTcp` and `WsTls` are the two that ship. A program that terminates TLS
at a load balancer, speaks WebSocket over a unix socket, or replays a
recorded conversation supplies its own, and every driving function costs
whatever that transport costs.

## The rules a user needs

1. **An endpoint that has sent a close must keep reading** (RFC 6455
   section 7.1.1). `can_receive` stays true in `WsClosingLocal` and
   `can_send` does not. A client that stopped reading there would report
   every clean shutdown as an abort.
2. **`close` sends a close frame and does not close the socket.** Keep
   pumping until a `WsCloseCompleted` event or a `WsCloseTimedOut`
   error, and close the transport then. Closing it earlier throws away
   the peer's answer, which is the status the program was about to
   report.
3. **1006 is reported and never sent** (section 7.4.1). A TCP connection
   that ended with no close frame is the `WsFailed` state, not a close
   code a caller can put on a wire. 1005 and 1015 are the same kind of
   value.
4. **`pump` discharges the three things an endpoint MUST do.** A ping is
   answered with a pong carrying the same payload (section 5.5.2), a
   close is answered with a close (section 5.5.1), and a frame that
   breaks the protocol is answered with the close code
   `wsclose.close_code_for` names (section 7.4.1). All three happen
   before the caller sees anything.
5. **The clock is an argument.** `wsconn.now_ms` is the only function
   in the package that reads one, and the only one that declares
   `[time]`. A caller driving many connections reads its clock once per
   turn and passes the same number to each.
6. **Both deadlines are yours, in milliseconds, and they are different
   numbers.** `close_timeout_ms` is the protocol's wait for the peer's
   close (section 7.1.1). `pong_timeout_ms` is policy, because RFC 6455
   requires no ping at all. Zero turns the pong check off.
7. **A refused upgrade is still an HTTP response** (section 4.1). A
   client whose handshake is refused wants a status it can show a
   person, and a server that closed the socket instead leaves it waiting
   for a response that never comes. `wsserve.refusal_response` builds
   it, and a wrong `Sec-WebSocket-Version` gets a 426 carrying
   `Sec-WebSocket-Version: 13`, which section 4.4 requires.
8. **`WsNotAnUpgrade` is a separate answer from a refusal.** A server
   that conflated them answers 400 to its own home page.
9. **A client must check the server's answer** (section 4.1). The status
   is 101, the accept value answers the key that was sent, the
   subprotocol is one this client offered, and the extension is one this
   client offered with parameters no wider. `wsclient.accept_response`
   checks all four. The accept check is what stops a cache from
   replaying an unrelated 101.
10. **The server's preference order picks the subprotocol, not the
    client's** (section 4.2.2). A server that speaks none of the
    offered subprotocols still accepts the handshake, with no
    subprotocol agreed. Refusing would break every client that offered
    one optimistically.
11. **A deflate answer may narrow what was offered and may never widen
    it** (RFC 7692 section 5.1). A server that echoed its own
    preference back regardless produces a connection whose two sides
    have different windows, where every message after the first is
    corrupt. `wsdeflate.send_window_bits` answers which window this side
    must use for its own sends.
12. **`no_context_takeover` is a memory decision, not a speed one.**
    Without it each side keeps a 32 KiB window per connection per
    direction for the life of the connection, which is 640 MB on a
    server holding ten thousand connections.
    `wsdeflate.default_params` asks for it. A server that wants the
    compression ratio back says so.
13. **A text message is bytes, not `Str`** (section 8.1). Invalid UTF-8
    must fail the connection with close code 1007, so the invalid case
    has to survive long enough to be reported.
    `wsread.is_valid_utf8` in the codec is the check.
14. **The `Origin` is handed over and not judged.** `wsserve.origin_of`
    returns it. A browser sends one and other clients need not, so the
    policy belongs to the application.
15. **A fault arrives after the events that came before it.** When one
    read holds a message and then a frame that breaks the protocol, the
    turn reports the message and the next `pump` returns the error. The
    close frame the fault owes the peer has already gone out.
16. **A client masks every frame and a server none** (section 5.3). The
    four-byte keys come from a seed the handshake draws from the
    system's entropy, so sending needs no `[rand]` row. A connection
    built by hand with `wsconn.connection` has a fixed seed, which is
    for tests.
17. **A received text message is checked as UTF-8 when it is whole**
    (section 8.1), after it has been inflated if it was compressed. With
    `max_message` set to 0 the caller is streaming, receives each
    fragment as it arrives, and checks the text itself.
18. **`send_fragment` streams a binary message.** The first fragment
    opens it, each later one continues it, and the one sent with `fin`
    true ends it. It sends no compressed fragment.

## What is not included

- **A loop, a thread, a channel or a callback.** A connection is a
  value. The caller owns the loop, and `pump` is one turn of it.
- **Sleeping.** `WsTurn.wait_ms` answers a number of milliseconds. What
  to do with it is the caller's, whether that is a `select`, a timer
  wheel or a poll.
- **Choosing a subprotocol or checking the `Origin`.**
  `wsserve.choose_protocol` applies a preference order the server
  supplies, and `wsserve.origin_of` hands the header over. A library
  that decided either would be deciding for every application built on
  it.
- **Frame encoding and decoding.** Every frame this package sends was
  built and encoded by
  [websocket-codec-nv](https://novo-lang.org/packages/websocket-codec-nv),
  and every frame it reads was decoded there. On a connection that
  negotiated permessage-deflate this package cuts the stream into frames
  and clears RSV1 on the first frame of a compressed message, because the
  codec refuses a set reserved bit. It touches nothing else in a frame.
- **Extensions other than permessage-deflate.** No other extension is
  offered, and an extension in a server's answer that the client did not
  offer is a failed handshake.
- **WebSocket over HTTP/2 or HTTP/3** (RFC 8441). That is a different
  handshake over a different transport, and it wants an HTTP/2
  implementation under it.
- **A microcontroller claim.** This package opens sockets, so it builds
  for a host and not for a device with no heap allocator.
  websocket-codec-nv is the half that builds for one.

## Related packages

- [websocket-codec-nv](https://novo-lang.org/packages/websocket-codec-nv)
  is the core half of the same protocol. It is the frame header, the
  mask, fragmentation, reassembly, the close codes and the handshake as
  a computation, with no socket anywhere in it. Take that package if you
  are writing your own endpoint, a proxy, a fuzzer or a capture tool, or
  if you need WebSocket framing on a device. Take this one if you want a
  connection to a peer, or a server.
- [http-codec-nv](https://novo-lang.org/packages/http-codec-nv) is
  HTTP/1.1 without a socket. The upgrade is an HTTP/1.1 exchange, and
  this package names its `H1Request` and `H1Response` in its own
  signatures, so a server that already parsed the request hands the same
  value over.
- [flate-nv](https://novo-lang.org/packages/flate-nv) is DEFLATE. It
  performs the compression inside permessage-deflate, in raw mode with
  no zlib header. The negotiation and the four bytes are this package's.
- [mqtt-nv](https://novo-lang.org/packages/mqtt-nv) is the same shape
  for a different protocol: a client value a host pumps, over
  mqtt-codec-nv. Reach for it where the link is constrained and the
  pattern is publish and subscribe.
- `std.net` in the standard library is what `WsTcp` is built on, and
  what it declares is what that transport costs. `WsTls` is written
  against a TLS connection handle, and the options beside it are
  `std.tls`'s own `TlsConfig`, named bare after `use std.tls`.
- `std.ws` in the standard library is a different thing with the same
  name on the tin. It is a `WebSocket` handle and six methods that hand
  a `Str` or a `Bytes` to the runtime, where the framing happens outside
  novo-lang. It is a client and not a server, it has no close code, no
  fragmentation and no compression, and the answer to a ping is the
  runtime's. It is the right answer for a program that talks to one
  server it trusts in three lines. This package is the answer for
  everything it cannot express.

## Tests

```bash
novo test                          # every suite below
bash tests/coverage.sh             # line coverage of src/
bash tests/tls_loopback.sh         # WsTls against a TLS peer, needs openssl and python3
bash tests/interop.sh              # Node's client and a Python server, needs node and python3
python3 tests/vectors.py           # regenerate the compressed vectors
```

| Suite | What it holds |
| --- | --- |
| `tests/wsproto_tests.nv` | The Autobahn Testsuite's conversations for framing, pings, reserved bits, opcodes, fragmentation, UTF-8, closing and limits, as tables of bytes |
| `tests/wsflow_tests.nv` | Sending and masking, the close handshake begun here, the timers, the handshake on both sides over a transport and over a loopback socket, and the fault messages |
| `tests/wscompress_tests.nv` | A connection that negotiated permessage-deflate, against streams written by CPython's zlib |
| `tests/wsdeflate_tests.nv` | The negotiation table and the compressed payloads, against RFC 7692 section 7.2.3 and zlib |
| `tests/wsconn_tests.nv`, `tests/wshake_tests.nv`, `tests/wsserve_tests.nv` | The connection value, the upgrade and the server's decision |

The handshake vector is RFC 6455 section 1.3's own: the example nonce,
the key it produces and the accept value that answers it. The first frame
examples are RFC 6455 section 5.7's. The compressed bytes for `Hello` and
for the empty message are the ones RFC 7692 section 7.2.3 prints, and
every other compressed stream is inflated by zlib or written by it. The
frames a test sends are built, and the frames a connection sends are read
back, by code that shares nothing with websocket-codec-nv.

## Licence

Apache-2.0. See `LICENSE`.

<!-- docs/writing-a-readme.md is the style guide for this page. -->
