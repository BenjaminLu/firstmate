// fm-board-live.mjs - the bearings board's live event server.
//
// WHAT THIS IS FOR. The board is exactly as fresh as the last time firstmate
// rebuilt it, which is minutes at best and much worse while firstmate is busy.
// Nothing about the transport was slow; nothing wrote. This server is the
// write path: the fleet appends one line the instant something happens, and
// every open board is repainted from it before the next breath. No timer
// anywhere decides when the captain learns something.
//
// Usage:
//   fm-board-live.mjs serve [--port N] [--once]
//   fm-board-live.mjs state
//   fm-board-live.mjs --help
//
// serve   Run the server in the foreground. It holds one authoritative board
//         state, pushes it to every subscriber, and exits nonzero rather than
//         running on a port it could not take. --once serves until the first
//         client has been sent its state and then exits, which is what the
//         tests drive.
// state   Print the merged board state this server would serve right now, as
//         one JSON document, and exit. Reads nothing from the network and
//         starts no server, so a home can be inspected without one running.
//
// SELF-CONTAINED, WHICH DECIDED THE ONE DEPENDENCY QUESTION HERE. A clone on a
// machine configured with nothing must get the working board, so the websocket
// is implemented against node:crypto and node:http rather than pulled from a
// registry. There is no package.json in this repository and no node_modules,
// so `npm install ws` is not a step a fresh clone can take offline, and a
// board that needs one is a board most clones do not get. RFC 6455's server
// half is a SHA-1 handshake and a length-prefixed frame; it is written out
// below because writing it is cheaper than the dependency.
//
// THE WIRE CARRIES STATE, THE EVENT ONLY DECIDES WHEN. Every message a client
// receives is the whole board, not a delta. A subscriber that misses a message
// cannot therefore be left behind by it: the next one it receives is complete,
// and a client that reconnects is sent the current state before anything else.
// This is what lets the page promise correctness rather than best effort. The
// cost is bandwidth on a loopback socket, which is not a cost.
//
// WHAT AN EVENT MAY CHANGE, AND WHAT IT MAY NOT. An event carries facts a
// script already knows - a task's id, its state word, a pull request URL - and
// those map onto fields fm-bearings-board.v1 already defines. It can never
// carry the words a captain-facing card is made of, because no script knows
// them: a decision card's "what you are deciding", its options and what each
// one costs are composed by firstmate and only by firstmate. So an event that
// would need new prose is NOT guessed and NOT dropped. It marks the board
// stale, naming what changed, and the page says a rebuild is owed. A board
// that is quietly missing a captain's call is the failure this whole branch
// exists to stop; a board that says it is behind is not that failure.
//
// THE EVENT LOG IS THE DURABILITY, THE SOCKET IS ONLY THE LATENCY. Publishers
// append to state/board-live.jsonl and do nothing else - no port, no client,
// nothing that can fail in a caller's critical path. This server follows that
// file. Events published while it is down are therefore not lost; they are
// read at the next start. bin/fm-board-live.sh owns the publishing side.
//
// A REBUILD SUPERSEDES EVERY EVENT OLDER THAN IT. The base state is the
// payload inside the board page firstmate builds, and building it recomposes
// everything. Events are applied only when they are newer than the page they
// would be applied to, so a rebuild cannot be undone by a stale overlay.
//
// docs/configuration.md owns the port and the file locations.

import { createHash } from "node:crypto";
import { createServer } from "node:http";
import {
  existsSync, mkdirSync, openSync, readSync, closeSync, fstatSync,
  readFileSync, statSync, watch, writeFileSync, unlinkSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const FM_ROOT = process.env.FM_ROOT_OVERRIDE || resolve(SCRIPT_DIR, "..");
const FM_HOME = process.env.FM_HOME || FM_ROOT;
const STATE_DIR = join(FM_HOME, "state");
const LOG_PATH = join(STATE_DIR, "board-live.jsonl");
const ENDPOINT_PATH = join(STATE_DIR, "board-live.endpoint");
const BOARD_PATH = join(FM_HOME, ".lavish", "bearings-board.html");
// A PORT NOBODY HAS TO CHOOSE, AND NOBODY ELSE'S. One fixed port would mean a
// second home on the same machine - a secondmate, a test home, a clone next to
// this one - could not serve at all, and a port in a config file is a step
// someone has to remember. So the default is derived from the home's own path:
// stable across restarts, so a page built yesterday still reconnects today,
// and distinct per home, so two homes never contend. The ephemeral range is
// avoided; a port already taken falls back to one the system assigns, which
// the endpoint record then names.
const PORT_BASE = 41000;
const PORT_SPAN = 4000;
const BOARD_SCHEMA = "fm-bearings-board.v1";
const EVENT_SCHEMA = "fm-board-event.v1";
const SLOT_OPEN = '<script id="bearings-data" type="application/json">';
// The board page can carry a whole decision packet with inlined drawings, so
// the ceiling is generous; it exists to bound a corrupt length, not the board.
const MAX_FRAME = 16 * 1024 * 1024;
// Events older than the base page are already represented in it. The ring is
// what a merge is recomputed from, so it only has to outlast one build.
const EVENT_RING = 2000;

/* ---- the board state ----------------------------------------------------
 * base      the payload firstmate last built, read out of the board page
 * baseAt    when that page was written; an event at or after it is live, an
 *           event before it was already composed into the page
 * events    the recent event ring, in arrival order
 */

function readBase() {
  let html;
  let mtime;
  try {
    html = readFileSync(BOARD_PATH, "utf8");
    mtime = statSync(BOARD_PATH).mtimeMs;
  } catch {
    return { payload: null, at: 0, reason: "no board has been built in this home yet" };
  }
  const start = html.indexOf(SLOT_OPEN);
  if (start < 0) return { payload: null, at: mtime, reason: "the board page carries no data slot" };
  const from = start + SLOT_OPEN.length;
  const end = html.indexOf("</script>", from);
  if (end < 0) return { payload: null, at: mtime, reason: "the board page's data slot is not closed" };
  let payload;
  try {
    payload = JSON.parse(html.slice(from, end));
  } catch {
    return { payload: null, at: mtime, reason: "the board page's payload is not readable JSON" };
  }
  if (!payload || payload.schema !== BOARD_SCHEMA) {
    return { payload: null, at: mtime, reason: `the board page's payload is not ${BOARD_SCHEMA}` };
  }
  return { payload, at: mtime, reason: null };
}

function parseEvent(line) {
  let ev;
  try {
    ev = JSON.parse(line);
  } catch {
    return null;
  }
  if (!ev || ev.schema !== EVENT_SCHEMA || typeof ev.kind !== "string") return null;
  const at = Date.parse(ev.at);
  ev.at_ms = Number.isFinite(at) ? at : 0;
  return ev;
}

/* ---- the merge ----------------------------------------------------------
 * Every case below writes fields fm-bearings-board.v1 already defines, with
 * values the publishing script already held. Nothing here invents a sentence.
 * A case that WOULD have to invent one records a staleness reason instead, and
 * the page shows it; see the header.
 */

function copyOf(payload) {
  return JSON.parse(JSON.stringify(payload));
}

function rowText(value, fallback) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function applyEvent(state, ev, stale) {
  const id = typeof ev.task === "string" ? ev.task : "";
  switch (ev.kind) {
    case "step": {
      const row = state.underway.find((r) => r.id === id);
      if (!row) {
        stale.push({ kind: ev.kind, task: id, why: "a worker this board does not list changed step" });
        return false;
      }
      // An event updates only the fields it carries. A publisher that knows
      // the state word but not what the worker is doing must not overwrite the
      // composed detail with the state word: that trades a live badge for a
      // less informative row, which is a worse board, not a fresher one.
      let changed = false;
      if (typeof ev.state === "string" && ev.state.length > 0 && ev.state !== row.state) {
        row.state = ev.state;
        changed = true;
      }
      if (typeof ev.detail === "string" && ev.detail.length > 0 && ev.detail !== row.doing) {
        row.doing = ev.detail;
        changed = true;
      }
      return changed;
    }
    case "dispatched": {
      if (!id) return false;
      if (state.underway.some((r) => r.id === id)) return false;
      state.underway.push({
        id,
        name: rowText(ev.name, id),
        repo: Object.prototype.hasOwnProperty.call(ev, "repo") ? ev.repo : null,
        state: rowText(ev.state, "working"),
        doing: rowText(ev.detail, rowText(ev.state, "working")),
        kind: rowText(ev.task_kind, "ship"),
      });
      return true;
    }
    case "landed": {
      if (!id) return false;
      const was = state.underway.findIndex((r) => r.id === id);
      const name = was >= 0 ? state.underway[was].name : rowText(ev.name, id);
      const repo = was >= 0
        ? state.underway[was].repo
        : (Object.prototype.hasOwnProperty.call(ev, "repo") ? ev.repo : null);
      if (was >= 0) state.underway.splice(was, 1);
      if (!state.landed.some((r) => r.id === id)) {
        const row = {
          id,
          what: rowText(ev.what, name),
          repo,
          owner: rowText(ev.owner, state.home),
        };
        if (typeof ev.pr_url === "string" && /^https:\/\//.test(ev.pr_url)) row.pr_url = ev.pr_url;
        state.landed.unshift(row);
      }
      // A landed task can no longer be a live question about itself.
      state.captains_call = state.captains_call.filter((c) => c.key !== id);
      return true;
    }
    case "pr": {
      const row = state.landed.find((r) => r.id === id);
      if (row && typeof ev.pr_url === "string" && /^https:\/\//.test(ev.pr_url)) {
        row.pr_url = ev.pr_url;
        return true;
      }
      // A pull request going green on work this board still lists as underway
      // is a merge the captain may now be owed, and a merge card is composed,
      // never mapped. Say so rather than quietly holding yesterday's board.
      stale.push({ kind: ev.kind, task: id, why: "a pull request changed on work this board has no landed row for" });
      return false;
    }
    case "answered": {
      const key = typeof ev.key === "string" && ev.key.length > 0 ? ev.key : id;
      const before = state.captains_call.length;
      state.captains_call = state.captains_call.filter((c) => c.key !== key);
      return state.captains_call.length !== before;
    }
    case "call": {
      // The one thing an event cannot carry: the words of a question.
      stale.push({ kind: ev.kind, task: id, why: "a new captain's call needs firstmate to word it" });
      return false;
    }
    default:
      return false;
  }
}

function merge(base, events) {
  if (!base.payload) {
    return { payload: null, stale: [], applied: 0, generated: null };
  }
  const state = copyOf(base.payload);
  const stale = [];
  let applied = 0;
  let newest = null;
  // An event is stamped to the second and a page's mtime is not, so an event
  // published in the same second as the build it follows would compare as
  // older than it. The boundary is therefore taken at that second, which errs
  // toward re-applying an event the build already composed rather than
  // dropping one it did not - and re-applying is harmless, because every case
  // below writes a value rather than making a change relative to one.
  const boundary = Math.floor(base.at / 1000) * 1000;
  for (const ev of events) {
    if (ev.at_ms < boundary) continue;
    const before = stale.length;
    if (applyEvent(state, ev, stale)) applied += 1;
    if (applied > 0 || stale.length !== before) newest = ev.at || newest;
  }
  if (newest) state.generated = newest;
  return { payload: state, stale, applied, generated: newest };
}

/* ---- the event log ------------------------------------------------------
 * Read forward only. The cursor never rewinds, so a publisher appending while
 * this runs is read exactly once and a truncation is noticed rather than
 * replayed.
 */

class EventLog {
  constructor(path) {
    this.path = path;
    this.cursor = 0;
    this.partial = "";
    this.events = [];
  }

  read() {
    let fd;
    try {
      fd = openSync(this.path, "r");
    } catch {
      return 0;
    }
    let added = 0;
    try {
      const size = fstatSync(fd).size;
      if (size < this.cursor) {
        // The file shrank: something replaced it, so re-read it whole rather
        // than reading the middle of a new file as the tail of the old one.
        this.cursor = 0;
        this.partial = "";
        this.events = [];
      }
      while (this.cursor < fstatSync(fd).size) {
        const want = Math.min(65536, fstatSync(fd).size - this.cursor);
        const buf = Buffer.allocUnsafe(want);
        const got = readSync(fd, buf, 0, want, this.cursor);
        if (got <= 0) break;
        this.cursor += got;
        this.partial += buf.subarray(0, got).toString("utf8");
        let nl;
        while ((nl = this.partial.indexOf("\n")) >= 0) {
          const line = this.partial.slice(0, nl);
          this.partial = this.partial.slice(nl + 1);
          if (!line.trim()) continue;
          const ev = parseEvent(line);
          if (!ev) continue;
          this.events.push(ev);
          added += 1;
        }
      }
    } finally {
      closeSync(fd);
    }
    if (this.events.length > EVENT_RING) {
      this.events.splice(0, this.events.length - EVENT_RING);
    }
    return added;
  }
}

/* ---- RFC 6455, the server half -----------------------------------------
 * Handshake: echo the client's key hashed with the protocol's fixed GUID.
 * Frames out: unmasked, one text frame per message, with the 16- and 64-bit
 * length forms so a board carrying a packet is not truncated at 125 bytes.
 * Frames in: only close and ping matter to this server, and a masked frame is
 * required of a client, so an unmasked one is a protocol error and closes.
 */

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function acceptKey(key) {
  return createHash("sha1").update(key + WS_GUID).digest("base64");
}

function frame(opcode, payload) {
  const len = payload.length;
  let head;
  if (len < 126) {
    head = Buffer.allocUnsafe(2);
    head.writeUInt8(0x80 | opcode, 0);
    head.writeUInt8(len, 1);
  } else if (len < 65536) {
    head = Buffer.allocUnsafe(4);
    head.writeUInt8(0x80 | opcode, 0);
    head.writeUInt8(126, 1);
    head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.allocUnsafe(10);
    head.writeUInt8(0x80 | opcode, 0);
    head.writeUInt8(127, 1);
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([head, payload]);
}

class Conn {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.open = true;
    this.alive = true;
  }

  send(text) {
    if (!this.open) return;
    try {
      this.socket.write(frame(0x1, Buffer.from(text, "utf8")));
    } catch {
      this.close();
    }
  }

  ping() {
    if (!this.open) return;
    try {
      this.socket.write(frame(0x9, Buffer.alloc(0)));
    } catch {
      this.close();
    }
  }

  close() {
    if (!this.open) return;
    this.open = false;
    try {
      this.socket.end(frame(0x8, Buffer.alloc(0)));
    } catch {
      try { this.socket.destroy(); } catch { /* already gone */ }
    }
  }

  // Returns false when the peer must be closed.
  feed(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      if (this.buf.length < 2) return true;
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let off = 2;
      if (len === 126) {
        if (this.buf.length < 4) return true;
        len = this.buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return true;
        const big = this.buf.readBigUInt64BE(2);
        if (big > BigInt(MAX_FRAME)) return false;
        len = Number(big);
        off = 10;
      }
      if (len > MAX_FRAME) return false;
      if (!masked) return false;
      if (this.buf.length < off + 4 + len) return true;
      off += 4;
      this.buf = this.buf.subarray(off + len);
      if (opcode === 0x8) return false;
      if (opcode === 0xa) this.alive = true;
      // A client ping is answered with a pong carrying no body; this server
      // reads no application message, so every other opcode is ignored.
      if (opcode === 0x9) {
        try { this.socket.write(frame(0xa, Buffer.alloc(0))); } catch { return false; }
      }
    }
  }
}

/* ---- the server ---------------------------------------------------------- */

function homePort() {
  const digest = createHash("sha1").update(resolve(FM_HOME)).digest();
  return PORT_BASE + (digest.readUInt32BE(0) % PORT_SPAN);
}

function endpointUrl(port) {
  return `ws://127.0.0.1:${port}/board-live`;
}

function serve(opts) {
  const base = { ...readBase() };
  const log = new EventLog(LOG_PATH);
  log.read();

  let seq = 0;
  let current = merge(base, log.events);
  const conns = new Set();

  function messageFor() {
    return JSON.stringify({
      type: "state",
      schema: "fm-board-live.v1",
      seq,
      payload: current.payload,
      stale: current.stale,
      base_missing: current.payload === null ? base.reason : null,
      generated: current.generated,
    });
  }

  function recompute(why) {
    const next = merge(base, log.events);
    const changed = JSON.stringify(next) !== JSON.stringify(current);
    current = next;
    if (!changed && why !== "base") return false;
    seq += 1;
    const msg = messageFor();
    for (const c of conns) c.send(msg);
    return true;
  }

  function reloadBase() {
    const fresh = readBase();
    if (fresh.at === base.at && fresh.reason === base.reason) return;
    base.payload = fresh.payload;
    base.at = fresh.at;
    base.reason = fresh.reason;
    recompute("base");
  }

  const server = createServer((req, res) => {
    // The board page is served by its own surface; this port answers one
    // question, so anything else gets a plain refusal rather than a 404 page.
    res.writeHead(426, { "content-type": "text/plain; charset=utf-8" });
    res.end("fm-board-live: websocket only, connect to /board-live\n");
  });

  server.on("upgrade", (req, socket) => {
    const key = req.headers["sec-websocket-key"];
    if (req.headers.upgrade?.toLowerCase() !== "websocket" || typeof key !== "string") {
      socket.destroy();
      return;
    }
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n\r\n`,
    );
    socket.setNoDelay(true);
    const conn = new Conn(socket);
    conns.add(conn);
    const drop = () => { conns.delete(conn); conn.open = false; };
    socket.on("data", (chunk) => { if (!conn.feed(chunk)) { conn.close(); drop(); } });
    socket.on("close", drop);
    socket.on("error", drop);
    // Correctness on reconnect is this line: a fresh subscriber is told the
    // whole state before it is told anything else, so it never has to be
    // rebuilt to be right.
    conn.send(messageFor());
    if (opts.once) setTimeout(() => shutdown(0), 50);
  });

  // A dropped connection that never sends a close frame is invisible until
  // something is written to it, so the server writes to it on purpose.
  const heartbeat = setInterval(() => {
    for (const c of conns) {
      if (!c.alive) { c.close(); conns.delete(c); continue; }
      c.alive = false;
      c.ping();
    }
  }, 30000);
  heartbeat.unref?.();

  let watchers = [];
  function armWatch(path, fn) {
    try {
      const w = watch(path, { persistent: false }, fn);
      w.on?.("error", () => { /* the backstop below covers a lost watch */ });
      watchers.push(w);
      return true;
    } catch {
      return false;
    }
  }

  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  if (!existsSync(LOG_PATH)) writeFileSync(LOG_PATH, "", { mode: 0o600 });

  // THE MECHANISM IS THE WATCH. An append wakes this process; nothing is on a
  // timer. The interval below is a backstop for a watch the platform drops
  // (a network filesystem, an editor replacing the file), not the way events
  // are normally noticed - if it were, this would be the poller the captain
  // asked us not to build. It is deliberately slow enough to be useless as one.
  armWatch(LOG_PATH, () => { if (log.read() > 0) recompute("events"); });
  armWatch(dirname(BOARD_PATH), () => reloadBase());
  const backstop = setInterval(() => {
    // A home that is gone cannot have a board, and a server outliving its home
    // is a process nobody will ever stop. This is also what keeps a test run
    // from leaving one server per temporary home behind it.
    if (!existsSync(STATE_DIR)) { shutdown(0); return; }
    if (log.read() > 0) recompute("events");
    reloadBase();
  }, 30000);
  backstop.unref?.();

  function shutdown(code) {
    clearInterval(heartbeat);
    clearInterval(backstop);
    for (const w of watchers) { try { w.close(); } catch { /* already closed */ } }
    watchers = [];
    for (const c of conns) c.close();
    try { unlinkSync(ENDPOINT_PATH); } catch { /* never written, or already gone */ }
    server.close(() => process.exit(code));
    setTimeout(() => process.exit(code), 500).unref?.();
  }
  process.on("SIGINT", () => shutdown(0));
  process.on("SIGTERM", () => shutdown(0));

  let fellBack = false;
  server.on("error", (err) => {
    // Another process already holds the home's derived port. Rather than
    // refusing to serve at all, take one the system assigns and record it: the
    // endpoint record, not the derivation, is what a page is built against.
    if (err.code === "EADDRINUSE" && !fellBack && !opts.pinned) {
      fellBack = true;
      server.listen(0, "127.0.0.1");
      return;
    }
    process.stderr.write(`fm-board-live: cannot serve on port ${opts.port}: ${err.message}\n`);
    process.exit(1);
  });
  server.listen(opts.port, "127.0.0.1", () => {
    const port = server.address().port;
    writeFileSync(
      ENDPOINT_PATH,
      `${endpointUrl(port)}\n`,
      { mode: 0o600 },
    );
    process.stdout.write(`endpoint: ${endpointUrl(port)}\n`);
    process.stdout.write(`log: ${LOG_PATH}\n`);
    process.stdout.write(`board: ${BOARD_PATH}\n`);
  });
}

function main(argv) {
  const cmd = argv[0];
  if (!cmd || cmd === "--help" || cmd === "-h") {
    process.stdout.write(
      "usage: fm-board-live.mjs serve [--port N] [--once]\n" +
      "       fm-board-live.mjs state\n",
    );
    process.exit(cmd ? 0 : 2);
  }
  if (cmd === "state") {
    const base = readBase();
    const log = new EventLog(LOG_PATH);
    log.read();
    const merged = merge(base, log.events);
    process.stdout.write(JSON.stringify({
      schema: "fm-board-live.v1",
      payload: merged.payload,
      stale: merged.stale,
      base_missing: merged.payload === null ? base.reason : null,
      generated: merged.generated,
    }) + "\n");
    return;
  }
  if (cmd !== "serve") {
    process.stderr.write(`fm-board-live: unknown command: ${cmd}\n`);
    process.exit(2);
  }
  let port = Number(process.env.FM_BOARD_LIVE_PORT || 0) || null;
  let pinned = port !== null;
  let once = false;
  for (let i = 1; i < argv.length; i += 1) {
    if (argv[i] === "--port") { port = Number(argv[i + 1]); pinned = true; i += 1; continue; }
    if (argv[i] === "--once") { once = true; continue; }
    process.stderr.write(`fm-board-live: unknown option: ${argv[i]}\n`);
    process.exit(2);
  }
  if (port === null) {
    const configured = join(FM_HOME, "config", "board-live-port");
    if (existsSync(configured)) { port = Number(readFileSync(configured, "utf8").trim()); pinned = true; }
  }
  if (port === null || Number.isNaN(port)) port = homePort();
  serve({ port, once, pinned });
}

main(process.argv.slice(2));
