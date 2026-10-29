// A WebSocket client that is not this package: Node's own, which speaks
// RFC 6455 and permessage-deflate on its own account.
const port = process.argv[2];

function once(open) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/echo`);
    ws.binaryType = "arraybuffer";
    ws.onerror = (e) => reject(new Error("socket error"));
    ws.onopen = () => open(ws, resolve, reject);
  });
}

let failed = 0;
function check(name, got, want) {
  const ok = got === want;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ` (want ${want}, got ${got})`}`);
  if (!ok) failed++;
}

const text = await once((ws, done) => {
  ws.onmessage = (m) => { ws.close(1000, "bye"); done(m.data); };
  ws.send("hello from node");
});
check("a text message comes back", text, "hello from node");

const big = "x".repeat(200000) + "end";
const long = await once((ws, done) => {
  ws.onmessage = (m) => { ws.close(); done(m.data); };
  ws.send(big);
});
check("200 kB of text comes back", long.length, big.length);

const bin = new Uint8Array(70000).map((_, i) => i % 251);
const back = await once((ws, done) => {
  ws.onmessage = (m) => { ws.close(); done(new Uint8Array(m.data)); };
  ws.send(bin);
});
check("70 kB of binary comes back", Buffer.compare(Buffer.from(back), Buffer.from(bin)), 0);

const many = await once((ws, done) => {
  let n = 0;
  const seen = [];
  ws.onmessage = (m) => { seen.push(m.data); if (++n === 50) { ws.close(); done(seen); } };
  for (let i = 0; i < 50; i++) ws.send(`message ${i} ` + "abc".repeat(i * 10));
});
check("fifty messages come back in order",
  many.every((s, i) => s === `message ${i} ` + "abc".repeat(i * 10)), true);

const ext = await once((ws, done) => { ws.onmessage = () => { ws.close(); done(ws.extensions); }; ws.send("probe"); });
console.log(`extensions negotiated: "${ext}"`);

const closeCode = await once((ws, done) => {
  ws.onclose = (e) => done(`${e.code}:${e.wasClean}`);
  ws.close(3001, "going");
});
check("the close handshake is clean and the code is echoed", closeCode, "3001:true");

process.exit(failed === 0 ? 0 : 1);
