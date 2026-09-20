// A minimal RFC 6455 client, so the live board's server is asserted by
// actually speaking websocket to it rather than by reading its source.
//
// Usage: node board-live-client.mjs <ws-url> <messages-wanted> [timeout-ms]
//                                    [--origin <value>] [--send <text>]
// Prints one JSON array of the messages received, then exits 0. Exits 1 with a
// reason on stderr when the handshake fails or the wait runs out, so a test
// that hangs fails instead of passing quietly.
//
// --origin sends that Origin header on the handshake, which is how a message
// arriving from somewhere other than the captain's board is reproduced: a
// browser writes this header itself and page script cannot change it. The
// handshake being refused is a normal outcome, printed as
// {"handshake_refused": "<status line>"} rather than a crash, because a
// refusal is the assertion in those cases.
// --send writes that text as one masked client text frame once the handshake
// is up; repeat it to send several. A client MUST mask, so these do.
// --count-type <t> counts only messages of that type toward <messages-wanted>
// while still collecting every message, so a case waiting for two replies is
// not satisfied early by a board repaint arriving between them.
//
// This is a test tool. The server half lives in bin/fm-board-live.mjs; nothing
// here is shipped to a board.
import { createHash, randomBytes } from "node:crypto";
import { connect } from "node:net";

const argv = process.argv.slice(2);
const positional = [];
const sends = [];
let origin = null;
let countType = null;
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === "--origin") { origin = argv[i + 1]; i += 1; continue; }
  if (argv[i] === "--send") { sends.push(argv[i + 1]); i += 1; continue; }
  if (argv[i] === "--count-type") { countType = argv[i + 1]; i += 1; continue; }
  positional.push(argv[i]);
}
const [url, wantArg, timeoutArg] = positional;
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

function clientFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const mask = randomBytes(4);
  const len = payload.length;
  let head;
  if (len < 126) {
    head = Buffer.from([0x81, 0x80 | len]);
  } else if (len < 65536) {
    head = Buffer.alloc(4);
    head.writeUInt8(0x81, 0);
    head.writeUInt8(0x80 | 126, 1);
    head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.alloc(10);
    head.writeUInt8(0x81, 0);
    head.writeUInt8(0x80 | 127, 1);
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  const masked = Buffer.allocUnsafe(len);
  for (let i = 0; i < len; i += 1) masked[i] = payload[i] ^ mask[i & 3];
  return Buffer.concat([head, mask, masked]);
}

const sock = connect(Number(port), host, () => {
  sock.write(
    `GET ${path || "/"} HTTP/1.1\r\nHost: ${host}:${port}\r\n` +
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
    (origin === null ? "" : `Origin: ${origin}\r\n`) +
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
      const counted = countType === null
        ? got.length
        : got.filter((m) => m && m.type === countType).length;
      if (counted >= want) {
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
    if (!/^HTTP\/1\.1 101 /.test(head)) {
      // A refusal is an answer, and several cases here are about getting one.
      clearTimeout(timer);
      process.stdout.write(JSON.stringify({ handshake_refused: head.split("\r\n")[0] }) + "\n");
      sock.destroy();
      process.exit(0);
    }
    if (!head.includes(expect)) fail("handshake accept key did not match");
    handshook = true;
    buf = buf.subarray(end + 4);
    for (const text of sends) sock.write(clientFrame(text));
    readFrames();
    return;
  }
  buf = Buffer.concat([buf, chunk]);
  readFrames();
});
