// A minimal RFC 6455 client, so the live board's server is asserted by
// actually speaking websocket to it rather than by reading its source.
//
// Usage: node board-live-client.mjs <ws-url> <messages-wanted> [timeout-ms]
// Prints one JSON array of the messages received, then exits 0. Exits 1 with a
// reason on stderr when the handshake fails or the wait runs out, so a test
// that hangs fails instead of passing quietly.
//
// This is a test tool. The server half lives in bin/fm-board-live.mjs; nothing
// here is shipped to a board.
import { createHash, randomBytes } from "node:crypto";
import { connect } from "node:net";

const [url, wantArg, timeoutArg] = process.argv.slice(2);
const want = Number(wantArg || 1);
const timeout = Number(timeoutArg || 5000);
const m = /^ws:\/\/([^:/]+):(\d+)(\/.*)?$/.exec(url || "");
if (!m) {
  process.stderr.write(`board-live-client: not a ws:// url: ${url}\n`);
  process.exit(1);
}
const [, host, port, path] = m;

const key = randomBytes(16).toString("base64");
const expect = createHash("sha1")
  .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  .digest("base64");

const got = [];
let handshook = false;
let buf = Buffer.alloc(0);

const fail = (why) => { process.stderr.write(`board-live-client: ${why}\n`); process.exit(1); };
const timer = setTimeout(() => fail(`timed out with ${got.length}/${want} messages`), timeout);

const sock = connect(Number(port), host, () => {
  sock.write(
    `GET ${path || "/"} HTTP/1.1\r\nHost: ${host}:${port}\r\n` +
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
    `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
  );
});
sock.on("error", (e) => fail(e.message));

function readFrames() {
  for (;;) {
    if (buf.length < 2) return;
    const opcode = buf[0] & 0x0f;
    let len = buf[1] & 0x7f;
    let off = 2;
    if (len === 126) {
      if (buf.length < 4) return;
      len = buf.readUInt16BE(2);
      off = 4;
    } else if (len === 127) {
      if (buf.length < 10) return;
      len = Number(buf.readBigUInt64BE(2));
      off = 10;
    }
    if ((buf[1] & 0x80) !== 0) off += 4; // a server must not mask, but read it if it does
    if (buf.length < off + len) return;
    const body = buf.subarray(off, off + len);
    buf = buf.subarray(off + len);
    if (opcode === 0x1) {
      try { got.push(JSON.parse(body.toString("utf8"))); } catch { got.push({ unparseable: body.toString("utf8") }); }
      if (got.length >= want) {
        clearTimeout(timer);
        process.stdout.write(JSON.stringify(got) + "\n");
        sock.destroy();
        process.exit(0);
      }
    }
    if (opcode === 0x8) fail(`server closed with ${got.length}/${want} messages`);
  }
}

sock.on("data", (chunk) => {
  if (!handshook) {
    buf = Buffer.concat([buf, chunk]);
    const end = buf.indexOf("\r\n\r\n");
    if (end < 0) return;
    const head = buf.subarray(0, end).toString("utf8");
    if (!/^HTTP\/1\.1 101 /.test(head)) fail(`handshake refused: ${head.split("\r\n")[0]}`);
    if (!head.includes(expect)) fail("handshake accept key did not match");
    handshook = true;
    buf = buf.subarray(end + 4);
    readFrames();
    return;
  }
  buf = Buffer.concat([buf, chunk]);
  readFrames();
});
