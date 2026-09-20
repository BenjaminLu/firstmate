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
// serve   Run the server in the foreground. It serves the board page at `/`,
//         holds one authoritative board state, pushes it to every subscriber,
//         and exits nonzero rather than running on a port it could not take.
//         --once serves until the first client has been sent its state and
//         then exits, which is what the tests drive.
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
// AND THE PAGE ITSELF IS SERVED FROM THIS PORT. The board used to be hosted by
// an external tool, so a clone without that tool installed had a live server,
// a built page, and no way to open it. This port already belonged to the home,
// so it answers GET / with that page and nothing else: exactly the one file
// bin/fm-bearings-board.sh built, never a directory, never state/, never data/,
// where the reports and briefs live. There is no path to traverse because
// nothing here joins a request to a path - each route names its own file, and
// every unmatched request is a plain 404. The listener stays on 127.0.0.1.
//
// TWO THINGS HERE ARE KNOWN TO BE SHORT-LIVED, and are written as routes
// rather than as facts for that reason. This home is to serve the decision
// packet from this same port, separated by path, so `/` is the first route
// and not the only one there will ever be; and the board file moves from
// .lavish/bearings-board.html - named after a tool this no longer uses - to
// state/board.html. Both are decided and both land on the system-wide branch
// that rebases onto this one. Nothing below should be read as "one port, one
// file, forever".
//
// WHAT SERVING IT COSTS, AND FOR HOW LONG. The built page carries the inbound
// token, and the board file is mode 0600, so until now only the captain's own
// user could read that credential. Serving the page puts it behind the port
// instead of behind the file mode: every local process that can reach this
// port can now fetch the page and answer as the captain. That is the read
// side of this port, which serves the whole board to any allowed origin
// without proof.
//
// The captain has since decided that reading requires the token too, knowing
// it stops every board already built until it is rebuilt. That lands on the
// system-wide branch, not here, so this paragraph describes a posture with a
// known end date rather than a standing design. The token check on every
// inbound message is unchanged and was never the part in question.
//
// NOBODY MAY FRAME THIS, AND THAT IS A SEPARATE FACT FROM WHO MAY READ IT.
// An earlier draft of this block concluded "no browser gains anything" from
// two true statements about READING: another origin cannot read this
// response, and the origin allowlist refuses its socket. Both still hold.
// Neither is about the attack that works. A page on any origin could FRAME
// this board, draw its own control over the frame, and let the captain click
// through it. Nothing is read. The framed document's origin is this board's
// own, so the allowlist admits its socket and the token baked into the page
// authenticates it, and a captain's call is settled with a real answer and
// real provenance while every check in this file correctly sees a legitimate
// board - because it is one. So framing is refused outright, on every
// response, by x-frame-options and frame-ancestors together.
//
// The lesson is worth more than the header: reading and acting are different
// boundaries, and a conclusion about one of them drawn from two true premises
// about the other is how this got shipped in the first place.
//
// AND THE CLICK COMES BACK THE SAME WAY. The socket carries the fleet out and
// the captain's answer in. The inbound half is the dangerous one - an answer
// settles a captain's call - so it is authenticated before it can resolve
// anything, refused out loud when it cannot be, and carried to the records
// that already own an answer rather than to a second set of its own.
// bin/fm-board-live.sh's header owns what proves a message is the captain's
// and what that proof does not claim; bin/fm-board-answer.sh owns what an
// accepted answer then reaches. Neither is restated here.
//
// A REFUSAL IS ALWAYS SAID. Every inbound message is answered on the same
// socket - accepted, refused with a reason, or recorded/failed once the answer
// has been carried. A press that quietly does nothing is the failure this
// whole path exists to remove, and a server that silently dropped a message
// would be that same failure one layer further in.
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

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import {
  constants, existsSync, mkdirSync, openSync, readSync, closeSync, fstatSync,
  readFileSync, statSync, watch, writeFileSync, unlinkSync, appendFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const FM_ROOT = process.env.FM_ROOT_OVERRIDE || resolve(SCRIPT_DIR, "..");
const FM_HOME = process.env.FM_HOME || FM_ROOT;
const STATE_DIR = join(FM_HOME, "state");
const LOG_PATH = join(STATE_DIR, "board-live.jsonl");
const ENDPOINT_PATH = join(STATE_DIR, "board-live.endpoint");
const TOKEN_PATH = join(STATE_DIR, "board-live.token");
const INBOUND_PATH = join(STATE_DIR, "board-inbound.jsonl");
const ANSWER_SCRIPT = join(SCRIPT_DIR, "fm-board-answer.sh");
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
const INBOUND_SCHEMA = "fm-board-inbound.v1";
const INBOUND_RESULT_SCHEMA = "fm-board-inbound-result.v1";
const SLOT_OPEN = '<script id="bearings-data" type="application/json">';
// What a CLIENT may send. An answer is a handful of short fields, so this is
// generous by three orders of magnitude already; it exists so a corrupt or
// hostile length cannot make this process allocate. The board's own payload
// travels the other way and is not bounded by it.
const MAX_INBOUND = 64 * 1024;
// How long the answer path gets before the captain is told it did not land.
// It reads the backlog through tasks-axi, which is the slow part.
const ANSWER_TIMEOUT_MS = 120000;
// What a timed-out answer path gets to run its EXIT trap in before it is
// killed outright, so firstmate is still told the captain answered.
const ANSWER_GRACE_MS = 5000;
// One message may settle several cards - the dispatch bar ticks a list - but
// not an unbounded number of them.
const MAX_ANSWERS = 64;
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
 * Frames in: unmasked and reassembled across continuation frames, then handed
 * up as one text message. A masked frame is required of a client, so an
 * unmasked one is a protocol error and closes, as is a binary message - the
 * board speaks JSON text and nothing else.
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
  constructor(socket, origin) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.open = true;
    this.alive = true;
    /* The handshake's Origin, kept for the life of the connection. A browser
       sets it and page script cannot change it, so it is read once here and
       never re-read from anything the client sends later. */
    this.origin = origin;
    this.fragments = null;
    this.fragmentOpcode = 0;
    /* Set by the server. Left null, this connection reads nothing a client
       sends, which is what it did before there was an inbound half. */
    this.onText = null;
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
      const fin = (b0 & 0x80) !== 0;
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
        if (big > BigInt(MAX_INBOUND)) return false;
        len = Number(big);
        off = 10;
      }
      if (len > MAX_INBOUND) return false;
      if (!masked) return false;
      if (this.buf.length < off + 4 + len) return true;
      // Unmasking is the whole difference between a socket that can be
      // written to and one that can only be read from: the body was always
      // there, and was always thrown away without being looked at.
      const mask = this.buf.subarray(off, off + 4);
      const body = Buffer.allocUnsafe(len);
      this.buf.copy(body, 0, off + 4, off + 4 + len);
      for (let i = 0; i < len; i += 1) body[i] ^= mask[i & 3];
      this.buf = this.buf.subarray(off + 4 + len);

      if (opcode === 0x8) return false;
      if (opcode === 0xa) { this.alive = true; continue; }
      if (opcode === 0x9) {
        // A pong must carry the ping's own body back.
        try { this.socket.write(frame(0xa, body)); } catch { return false; }
        continue;
      }
      if (opcode === 0x1 || opcode === 0x2) {
        if (this.fragments !== null) return false;
        if (!fin) { this.fragments = body; this.fragmentOpcode = opcode; continue; }
        if (!this.deliver(opcode, body)) return false;
        continue;
      }
      if (opcode === 0x0) {
        if (this.fragments === null) return false;
        this.fragments = Buffer.concat([this.fragments, body]);
        if (this.fragments.length > MAX_INBOUND) return false;
        if (!fin) continue;
        const whole = this.fragments;
        const code = this.fragmentOpcode;
        this.fragments = null;
        if (!this.deliver(code, whole)) return false;
        continue;
      }
      return false;
    }
  }

  deliver(opcode, body) {
    if (opcode !== 0x1) return false;
    if (typeof this.onText !== "function") return true;
    try {
      this.onText(body.toString("utf8"), this);
    } catch {
      // A message that threw must not take the subscription down with it: the
      // board keeps receiving the fleet even when one answer went wrong.
    }
    return true;
  }
}

/* ---- the inbound half ---------------------------------------------------
 * What proves a message is the captain's, and what that proof does not claim,
 * is owned by bin/fm-board-live.sh's header. This is the implementation of it
 * and the shape of the one message this port accepts:
 *
 *   {"schema": "fm-board-inbound.v1", "token": "<64 hex>", "type": "answer",
 *    "id": "<the page's own correlation id, optional>",
 *    "answers": [{"key": "<board key>", "selection": "<option value>",
 *                 "note": "<the captain's typed words>",
 *                 "label": "<what that option said on the board>",
 *                 "close": "done" | "release"}]}
 *
 * and the one it replies with, on the same socket, always:
 *
 *   {"type": "inbound", "schema": "fm-board-inbound-result.v1", "id": ...,
 *    "status": "accepted" | "refused" | "recorded" | "failed",
 *    "reason": "<a stable machine reason>", "detail": "<what the answer path said>"}
 *
 * `accepted` is sent the moment a message passes; `recorded` or `failed`
 * follows when the answer path has finished with it. The reason is a fixed
 * token, never a sentence for the captain: the words he reads are the page's,
 * because no server here composes captain-facing prose.
 *
 * Every field is checked against the same shapes the board's other answer
 * channel already accepts, so a click settles a call identically however it
 * arrived and neither channel can accept something the other would refuse.
 */

const TOKEN_RE = /^[0-9a-f]{64}$/;
const KEY_RE = /^[A-Za-z0-9._-]{1,128}$/;
const CORRELATION_RE = /^[A-Za-z0-9._-]{1,64}$/;
const LOOPBACK_ORIGIN_RE = /^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::\d{1,5})?$/;
const RECONCILE_VALUE = "reconcile";
// The dispatch bar's pseudo-key; bin/fm-board-answer.sh owns what it means.
const DISPATCH_KEY = "dispatch.charted";
const MAX_NOTE = 512;
const MAX_LABEL = 512;

/* A browser puts its page's origin here and page script cannot change it, so
 * a real web origin arriving on this port is a website trying to reach the
 * captain's fleet and is refused before it is upgraded. An absent header is a
 * client that is not a browser; `null` is a board opened as a file, and also
 * a sandboxed frame, which is why the token and not this is the proof. */
function originAllowed(origin) {
  if (origin === undefined || origin === null || origin === "") return true;
  if (origin === "null") return true;
  return LOOPBACK_ORIGIN_RE.test(origin);
}

/* Read fresh every time, so rotating the token takes effect on the next click
 * rather than at the next restart. */
function readToken() {
  try {
    const t = readFileSync(TOKEN_PATH, "utf8").trim();
    return TOKEN_RE.test(t) ? t : null;
  } catch {
    return null;
  }
}

function tokenMatches(given) {
  const want = readToken();
  if (want === null) return false;
  if (typeof given !== "string" || !TOKEN_RE.test(given)) return false;
  const a = Buffer.from(given, "utf8");
  const b = Buffer.from(want, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/* The boundary that sanitizes, because this is where the untrusted bytes are.
 * A tab or a newline surviving into a row would move a field, and a control
 * character surviving into a durable record would corrupt it for every later
 * reader. */
function oneLine(value, max) {
  return String(value).replace(/[\x00-\x1f\x7f]/g, " ").slice(0, max);
}

function refusal(reason, detail) {
  return { reason, detail: detail || null };
}

/* Turn one authenticated message into the rows bin/fm-board-answer.sh reads,
 * or into the reason it cannot be one. */
function answerRows(message) {
  if (message.type !== "answer") {
    return refusal("unsupported-type", "this port accepts an answer and nothing else");
  }
  const list = message.answers;
  if (!Array.isArray(list) || list.length === 0) {
    return refusal("malformed", "answers must be a non-empty list");
  }
  if (list.length > MAX_ANSWERS) {
    return refusal("malformed", `at most ${MAX_ANSWERS} answers in one message`);
  }
  const rows = [];
  const keys = [];
  for (const item of list) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return refusal("malformed", "each answer must be an object");
    }
    const key = item.key;
    if (typeof key !== "string" || !KEY_RE.test(key)) {
      return refusal("malformed", "each answer needs a routable key");
    }
    if (keys.includes(key)) {
      return refusal("duplicate-key", `two answers for ${key} in one message`);
    }
    const selection = item.selection === undefined || item.selection === null ? "" : item.selection;
    const note = item.note === undefined || item.note === null ? "" : item.note;
    if (typeof selection !== "string" || typeof note !== "string") {
      return refusal("malformed", "selection and note must be text");
    }
    if (selection !== "" && !KEY_RE.test(selection)) {
      return refusal("malformed", "an option value is not a value this board can carry");
    }
    if (note.length > MAX_NOTE) {
      return refusal("malformed", `a note may be at most ${MAX_NOTE} characters`);
    }
    if (selection === "" && note.trim() === "") {
      return refusal("malformed", `${key} carries neither a choice nor words`);
    }
    const label = item.label === undefined || item.label === null ? "" : item.label;
    if (typeof label !== "string") {
      return refusal("malformed", "a label must be text");
    }
    const close = item.close === undefined || item.close === null ? "" : item.close;
    if (close !== "" && close !== "done" && close !== "release") {
      return refusal("malformed", `${key} declares a close this board does not have`);
    }
    const value = selection !== "" ? selection : note;
    // THE DISPATCH BAR'S VALUE IS A LIST OF IDS, so it is the one field
    // carrying identifiers that does not arrive as `selection` - a comma list
    // cannot, since an option value may not contain one. Riding in `note` is
    // not a reason to skip the check every sibling field gets at the boundary
    // that calls itself the sanitising one. The ack owner downstream refuses a
    // bad id anyway, but it refuses it as "this did not land" on a message
    // that looked well-formed here; checking it here makes the refusal say
    // what is actually wrong.
    if (key === DISPATCH_KEY) {
      const ids = value.split(",");
      if (ids.length > MAX_ANSWERS) {
        return refusal("malformed", `at most ${MAX_ANSWERS} rows in one dispatch order`);
      }
      for (const one of ids) {
        if (!KEY_RE.test(one)) {
          return refusal("malformed", "a dispatch order names a row this board cannot address");
        }
      }
    }
    keys.push(key);
    // `reconcile` is the board's standard "go re-check reality" choice and is
    // never an answer. It is separated here only so it reaches its own intake;
    // what it MEANS is owned by bin/fm-captain-hold.sh, which refuses it at
    // the answer intake whatever any channel calls it.
    if (selection === RECONCILE_VALUE) {
      rows.push(["reconcile", key, oneLine(note, MAX_NOTE)].join("\t"));
    } else {
      rows.push([
        "answer",
        key,
        oneLine(value, MAX_NOTE),
        oneLine(label, MAX_LABEL),
        close,
      ].join("\t"));
    }
  }
  return { rows, keys };
}

/* The captain's answer is on disk before anything is attempted with it, minus
 * the token, which is a credential and belongs in no record. An answer the
 * answer path then loses is still recoverable from here; an answer that was
 * never written down is not. */
function journalInbound(record) {
  try {
    if (!existsSync(STATE_DIR)) return false;
    appendFileSync(INBOUND_PATH, JSON.stringify(record) + "\n", { mode: 0o600 });
    return true;
  } catch {
    return false;
  }
}

/* One answer path at a time. Two clicks a second apart on two cards would
 * otherwise read and rewrite the same backlog concurrently, and serialising
 * here costs nothing a captain can perceive. */
let answerChain = Promise.resolve();

function runAnswerPath(rows, provenance) {
  return new Promise((done) => {
    let child;
    try {
      child = spawn(ANSWER_SCRIPT, ["apply", "--source", provenance], {
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, FM_HOME },
        // Its own process group, so a timeout can reach what it started. The
        // answer path runs the backlog backend underneath it, and signalling
        // only the direct child leaves that running: it would then land the
        // captain's answer seconds after he was told it had not been
        // recorded, and nothing would ever have woken firstmate.
        detached: true,
      });
    } catch (e) {
      done({ ok: false, reason: "answer-path-unavailable", detail: e.message });
      return;
    }
    let out = "";
    let settled = false;
    const finish = (result) => { if (!settled) { settled = true; done(result); } };
    // SIGTERM FIRST, AND THAT IS THE WHOLE POINT. The answer path guarantees
    // it tells firstmate on every path out of it through an EXIT trap, and
    // names SIGKILL as the one signal that defeats that guarantee. Killing it
    // outright on a timeout would therefore use the one mechanism its own
    // contract says destroys the thing the timeout exists to report. Bash
    // runs an EXIT trap on SIGTERM even while blocked in a child, so the
    // captain's answer still reaches firstmate; SIGKILL follows only for a
    // group that ignored it.
    const signalGroup = (signal) => {
      try { process.kill(-child.pid, signal); } catch {
        try { child.kill(signal); } catch { /* already gone */ }
      }
    };
    const timer = setTimeout(() => {
      signalGroup("SIGTERM");
      const hard = setTimeout(() => signalGroup("SIGKILL"), ANSWER_GRACE_MS);
      hard.unref?.();
      finish({ ok: false, reason: "answer-path-timeout", detail: out.trim() });
    }, ANSWER_TIMEOUT_MS);
    timer.unref?.();
    child.stdout.on("data", (d) => { out += d.toString("utf8"); });
    child.stderr.on("data", (d) => { out += d.toString("utf8"); });
    child.on("error", (e) => {
      clearTimeout(timer);
      finish({ ok: false, reason: "answer-path-unavailable", detail: e.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      finish({
        ok: code === 0,
        reason: code === 0 ? "recorded" : "answer-path-refused",
        detail: out.trim(),
      });
    });
    try {
      child.stdin.end(rows.map((r) => r + "\n").join(""));
    } catch (e) {
      clearTimeout(timer);
      finish({ ok: false, reason: "answer-path-unavailable", detail: e.message });
    }
  });
}

/* ---- the server ---------------------------------------------------------- */

function homePort() {
  const digest = createHash("sha1").update(resolve(FM_HOME)).digest();
  return PORT_BASE + (digest.readUInt32BE(0) % PORT_SPAN);
}

function endpointUrl(port) {
  return `ws://127.0.0.1:${port}/board-live`;
}

/* The same port, read as a page rather than as a subscription. This is the
   URL a clone gets with nothing installed. */
function pageUrl(port) {
  return `http://127.0.0.1:${port}/`;
}

/* The two spellings of this machine, at the port this server actually took -
   never the configured one, because a server that fell back would then refuse
   its own address. A name that merely RESOLVES to 127.0.0.1 is not one of
   these, which is the whole point: see THE HOST IS CHECKED FIRST. */
function hostAllowed(host, port) {
  if (typeof host !== "string") return false;
  return host === `127.0.0.1:${port}` || host === `localhost:${port}`;
}

/* O_NOFOLLOW, the same refusal bin/fm-remote-file.sh and bin/fm-wake-lib.sh
   already make on a file that carries something private. The board page
   carries the answer token, and this commit is what put it behind a port, so
   a symlink dropped in its place must not become something this server reads
   out to whoever asked. Refusing at open() rather than checking first is what
   makes it a guard instead of a race: there is no gap between the test and
   the read. A symlink surfaces as ELOOP and is reported by that code. It
   takes the path so the packet's route can use the same guard rather than
   growing a second one. */
function readServedFile(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    return readFileSync(fd);
  } finally {
    closeSync(fd);
  }
}

function serve(opts) {
  // The port this server actually took, which is what the Host check compares
  // against. Null until listen succeeds, and the handler refuses while it is:
  // no request can arrive before then, and answering one if it did would mean
  // answering without knowing our own address.
  let boundPort = null;
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

  function reply(conn, id, status, reason, detail) {
    conn.send(JSON.stringify({
      type: "inbound",
      schema: INBOUND_RESULT_SCHEMA,
      id: id || null,
      status,
      reason,
      detail: detail || null,
    }));
  }

  /* One inbound message, from the wire to the record. Every path out of here
   * writes back to the socket, including every refusal: the captain pressing
   * a button and learning nothing is the case this exists to remove. */
  function receive(conn, text) {
    let message = null;
    try {
      message = JSON.parse(text);
    } catch {
      reply(conn, null, "refused", "malformed", "not JSON");
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      reply(conn, null, "refused", "malformed", "not an object");
      return;
    }
    const id = typeof message.id === "string" && CORRELATION_RE.test(message.id)
      ? message.id
      : null;
    if (message.schema !== INBOUND_SCHEMA) {
      reply(conn, id, "refused", "malformed", `not ${INBOUND_SCHEMA}`);
      return;
    }
    // Authentication before anything the message asks for is read, and one
    // reason for every way it can fail: which way it failed is the sender's
    // business only when the sender is the captain.
    if (!originAllowed(conn.origin) || !tokenMatches(message.token)) {
      reply(conn, id, "refused", "unauthenticated",
        "this message did not come from a board built in this home");
      return;
    }
    const read = answerRows(message);
    if (read.reason) {
      reply(conn, id, "refused", read.reason, read.detail);
      return;
    }
    const at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    // REFUSED WHEN IT CANNOT BE WRITTEN DOWN, because three places tell the
    // captain and firstmate to go read this file when something did not land:
    // the answer path's fallback wake, its "part of this did NOT land"
    // rewrite, and the bearings skill. An append that failed silently would
    // point all three at a file that does not contain his answer, and nothing
    // anywhere would have said so. Refusing hands him back a press he can
    // repeat; proceeding hands him a recovery story that is false.
    if (!journalInbound({
      schema: INBOUND_SCHEMA,
      at,
      id,
      origin: conn.origin,
      type: message.type,
      rows: read.rows,
    })) {
      reply(conn, id, "refused", "not-recorded",
        `the captain's answer could not be written to ${INBOUND_PATH}, so nothing was attempted with it`);
      return;
    }
    const provenance =
      `the captain's own board over its live connection${id ? ` (message ${id})` : ""}`;
    reply(conn, id, "accepted", "accepted", null);
    answerChain = answerChain.then(() => runAnswerPath(read.rows, provenance))
      .then((result) => {
        reply(conn, id, result.ok ? "recorded" : "failed", result.reason, result.detail);
      })
      .catch((e) => {
        reply(conn, id, "failed", "answer-path-unavailable", String(e && e.message));
      });
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
    const method = req.method || "GET";
    const path = (req.url || "/").split("?")[0];
    const head = method === "HEAD";
    const send = (code, type, body) => {
      res.writeHead(code, {
        "content-type": type,
        "content-length": Buffer.byteLength(body),
        "cache-control": "no-store",
        // The page carries a credential, so nothing may guess at its type and
        // nothing may keep a copy it was not handed directly.
        "x-content-type-options": "nosniff",
        // AND NOTHING MAY PUT IT IN A FRAME. Both spellings, because the old
        // header is what actually stops an old browser and the CSP directive
        // is what the current ones read. See NOBODY MAY FRAME THIS in the
        // header block: this is the whole defence against a page that never
        // reads the board and settles a captain's call anyway.
        "x-frame-options": "DENY",
        "content-security-policy": "frame-ancestors 'none'",
      });
      res.end(head ? undefined : body);
    };
    // THE HOST IS CHECKED FIRST, AND IT AUTHENTICATES NOBODY. It is what makes
    // the same-origin policy mean anything on this port. A name an attacker
    // controls can be pointed at 127.0.0.1, and then their page and this board
    // share an origin as far as the browser is concerned - so the browser
    // hands them the page, the token in it, and the socket. Answering only to
    // this home's own loopback address closes that, and it stays correct
    // whichever way the separate read-authentication decision goes.
    const host = req.headers.host;
    if (!boundPort || !hostAllowed(host, boundPort)) {
      send(403, "text/plain; charset=utf-8",
        "fm-board-live: this port answers 127.0.0.1 and localhost only\n");
      return;
    }
    if (path === "/board-live") {
      // Reached without an Upgrade, so it is not the subscription it names.
      send(426, "text/plain; charset=utf-8",
        "fm-board-live: this path is the websocket; the board is at /\n");
      return;
    }
    if (method !== "GET" && !head) {
      send(405, "text/plain; charset=utf-8", "fm-board-live: GET only\n");
      return;
    }
    // Each route names its own file. A request never contributes a path
    // segment to anything opened, so the home's state and data directories
    // are not "protected" from this server - they are unreachable by it, and
    // they stay unreachable when the packet's route is added beside this one.
    const file = path === "/" ? BOARD_PATH : null;
    if (file === null) {
      send(404, "text/plain; charset=utf-8", "fm-board-live: the board is at /\n");
      return;
    }
    let page;
    try {
      page = readServedFile(file);
    } catch (e) {
      // ONLY "it is not there" reads as "nothing has built one". Anything else
      // - a mode that cannot be read, a directory in its place, the symlink
      // refusal below - is a condition someone has to fix, and telling them to
      // re-run the command they just ran would hide it behind advice that
      // cannot work.
      if (e && e.code === "ENOENT") {
        send(404, "text/plain; charset=utf-8",
          "fm-board-live: no board has been built in this home yet (run /bearings)\n");
        return;
      }
      send(500, "text/plain; charset=utf-8",
        `fm-board-live: cannot read the board page (${(e && e.code) || "unknown error"}): ${file}\n`);
      return;
    }
    send(200, "text/html; charset=utf-8", page);
  });

  server.on("upgrade", (req, socket) => {
    const key = req.headers["sec-websocket-key"];
    if (req.headers.upgrade?.toLowerCase() !== "websocket" || typeof key !== "string") {
      socket.destroy();
      return;
    }
    const origin = req.headers.origin;
    if (!originAllowed(origin)) {
      // Said out loud, in the handshake, rather than dropped: a refusal
      // nobody is told about is indistinguishable from a broken port.
      socket.end(
        "HTTP/1.1 403 Forbidden\r\n" +
        "content-type: text/plain; charset=utf-8\r\n" +
        "connection: close\r\n\r\n" +
        "fm-board-live: this port answers the captain's own board, not another origin\n",
      );
      return;
    }
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n\r\n`,
    );
    socket.setNoDelay(true);
    const conn = new Conn(socket, typeof origin === "string" ? origin : null);
    conn.onText = (text) => receive(conn, text);
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
    boundPort = port;
    writeFileSync(
      ENDPOINT_PATH,
      `${endpointUrl(port)}\n`,
      { mode: 0o600 },
    );
    process.stdout.write(`endpoint: ${endpointUrl(port)}\n`);
    process.stdout.write(`page: ${pageUrl(port)}\n`);
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
