// board-browser.mjs - drive a REAL browser against a REAL server, and print
// what the captain would have seen.
//
// Usage: node board-browser.mjs <url> <steps.json|-> [--timeout-ms N]
//
// Prints one JSON object on stdout: { steps: [...], console: [...],
// errors: [...] }. Exits 0 when every step ran (a step's own result says
// whether it found what it wanted), 3 when no browser could be found on this
// machine, and 1 on any other failure with a reason on stderr.
//
// WHY THIS EXISTS AND WHY IT IS NOT A DOM SHIM. The board's freshness, its
// live socket, and the hit-testing under the captain's click are all decided
// by a browser. The shim in tests/assets/board-render-harness.mjs models some
// of that, and on 2026-09-20 its text measurements were found to be wrong by
// up to 21 percent against Chrome. A model that is wrong is exactly how a
// defect reaches a captain past a green suite, so nothing here models
// anything: it launches the browser the machine has, over the Chrome DevTools
// Protocol, and reads back what that browser did.
//
// NO DEPENDENCY, FOR THE SAME REASON bin/fm-board-live.mjs HAS NONE. There is
// no package.json in this repository, so `npm install puppeteer` is not a step
// a fresh clone can take offline. CDP is a websocket carrying JSON, and the
// client half of RFC 6455 is a mask and a length prefix; it is written out
// below because writing it is cheaper than the dependency, and it is the same
// trade bin/fm-board-live.mjs already made for the server half.
//
// A STEP MAY RUN A COMMAND, which is what makes an end-to-end case possible at
// all: "the page is open, the fleet publishes, and the page changes without
// anyone touching it" cannot be driven from outside one browser session. So
// the publish happens as a step, between the observations, with the page open
// throughout.
//
// The steps, each an object in the array:
//   {"op":"wait","expr":"<js>","timeout_ms":N}   poll until the expression is
//        truthy. Result carries ok and waited_ms. A wait that runs out is a
//        result, not a crash, so the assertion is the test's to make.
//   {"op":"eval","expr":"<js>"}                  evaluate and return the value
//   {"op":"text","selector":"<css>"}             innerText of the first match,
//        or null when nothing matches
//   {"op":"click","selector":"<css>"}            a real mouse press and release
//        at the element's measured centre, so what is under the pointer is
//        decided by the browser's own hit-testing and not by this file
//   {"op":"run","argv":["cmd","arg"],"env":{...},"cwd":"..."}  run a command to
//        completion with the page still open
//   {"op":"sleep","ms":N}
//   {"op":"reload"}                              reload the page
//
// This is a test tool. Nothing here ships to a board.

import { createHash, randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { connect } from "node:net";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const argv = process.argv.slice(2);
const positional = [];
let overallTimeout = 60000;
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === "--timeout-ms") { overallTimeout = Number(argv[i + 1]); i += 1; continue; }
  positional.push(argv[i]);
}
const [url, stepsArg] = positional;
if (!url || !stepsArg) {
  process.stderr.write("board-browser: usage: board-browser.mjs <url> <steps.json|->\n");
  process.exit(1);
}
const steps = JSON.parse(stepsArg === "-"
  ? readFileSync(0, "utf8")
  : readFileSync(stepsArg, "utf8"));

const die = (why, code = 1) => {
  process.stderr.write(`board-browser: ${why}\n`);
  process.exit(code);
};

/* ---- finding a browser ---------------------------------------------------
 * Every machine this suite runs on has one: a GitHub Linux runner ships Google
 * Chrome on PATH, and a developer machine has Chrome or Chromium somewhere.
 * Exit 3 is reserved for "this machine has none" so the calling test can say
 * that in those words - and so CI can refuse to accept those words, which is
 * the whole difference between this file and the capability skip it replaces.
 */
function findBrowser() {
  const named = process.env.FM_TEST_BROWSER;
  if (named) {
    if (!existsSync(named)) die(`FM_TEST_BROWSER is set to a path that does not exist: ${named}`);
    return named;
  }
  const onPath = [
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
    "microsoft-edge", "microsoft-edge-stable",
  ];
  for (const name of onPath) {
    const found = spawnSync("command", ["-v", name], { shell: true, encoding: "utf8" });
    if (found.status === 0 && found.stdout.trim()) return found.stdout.trim().split("\n")[0];
  }
  const bundles = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  ];
  for (const path of bundles) if (existsSync(path)) return path;
  return null;
}

/* ---- RFC 6455, the client half ------------------------------------------ */

function clientFrame(opcode, payload) {
  const mask = randomBytes(4);
  const len = payload.length;
  let head;
  if (len < 126) {
    head = Buffer.allocUnsafe(2);
    head.writeUInt8(0x80 | opcode, 0);
    head.writeUInt8(0x80 | len, 1);
  } else if (len < 65536) {
    head = Buffer.allocUnsafe(4);
    head.writeUInt8(0x80 | opcode, 0);
    head.writeUInt8(0x80 | 126, 1);
    head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.allocUnsafe(10);
    head.writeUInt8(0x80 | opcode, 0);
    head.writeUInt8(0x80 | 127, 1);
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  const body = Buffer.from(payload);
  for (let i = 0; i < body.length; i += 1) body[i] ^= mask[i & 3];
  return Buffer.concat([head, mask, body]);
}

class Ws {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.fragments = null;
    this.onMessage = null;
    socket.on("data", (chunk) => this.feed(chunk));
  }

  send(text) { this.socket.write(clientFrame(0x1, Buffer.from(text, "utf8"))); }

  feed(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      if (this.buf.length < 2) return;
      const b0 = this.buf[0];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      let len = this.buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        len = Number(this.buf.readBigUInt64BE(2));
        off = 10;
      }
      if (this.buf.length < off + len) return;
      const body = this.buf.subarray(off, off + len);
      this.buf = this.buf.subarray(off + len);
      if (opcode === 0x9) { this.socket.write(clientFrame(0xa, body)); continue; }
      if (opcode === 0x8) { this.socket.destroy(); return; }
      if (opcode === 0xa) continue;
      const whole = this.fragments ? Buffer.concat([this.fragments, body]) : Buffer.from(body);
      if (!fin) { this.fragments = whole; continue; }
      this.fragments = null;
      if (this.onMessage) this.onMessage(whole.toString("utf8"));
    }
  }
}

function openWs(wsUrl) {
  const m = /^ws:\/\/([^:/]+):(\d+)(\/.*)?$/.exec(wsUrl);
  if (!m) return Promise.reject(new Error(`not a ws:// url: ${wsUrl}`));
  const [, host, port, path] = m;
  const key = randomBytes(16).toString("base64");
  const expect = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  return new Promise((resolve, reject) => {
    const socket = connect(Number(port), host, () => {
      socket.write(
        `GET ${path || "/"} HTTP/1.1\r\nHost: ${host}:${port}\r\n` +
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
    });
    socket.setNoDelay(true);
    let head = Buffer.alloc(0);
    const onData = (chunk) => {
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf("\r\n\r\n");
      if (end < 0) return;
      const text = head.subarray(0, end).toString("utf8");
      if (!/^HTTP\/1\.1 101 /.test(text) || !text.includes(expect)) {
        socket.destroy();
        reject(new Error(`handshake refused: ${text.split("\r\n")[0]}`));
        return;
      }
      socket.removeListener("data", onData);
      const ws = new Ws(socket);
      const rest = head.subarray(end + 4);
      if (rest.length) ws.feed(rest);
      resolve(ws);
    };
    socket.on("data", onData);
    socket.on("error", reject);
  });
}

/* ---- the Chrome DevTools Protocol, the little of it this needs ---------- */

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.next = 1;
    this.pending = new Map();
    this.events = [];
    ws.onMessage = (text) => {
      let msg;
      try { msg = JSON.parse(text); } catch { return; }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(`${msg.error.message} (${msg.error.code})`));
        else resolve(msg.result);
        return;
      }
      if (msg.method) this.events.push(msg);
    };
  }

  send(method, params, sessionId) {
    const id = this.next;
    this.next += 1;
    const frame = { id, method, params: params || {} };
    if (sessionId) frame.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify(frame));
    });
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const browser = findBrowser();
  if (!browser) die("no chrome, chromium or edge found on this machine", 3);

  const profile = mkdtempSync(join(tmpdir(), "fm-board-browser-"));
  const child = spawn(browser, [
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--no-sandbox",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--disable-features=Translate,MediaRouter,OptimizationHints",
    "--window-size=1280,900",
    "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  let browserStderr = "";
  child.stderr.on("data", (d) => { browserStderr += d.toString("utf8"); });

  const stop = () => {
    try { child.kill("SIGKILL"); } catch { /* already gone */ }
    try { rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
  };
  process.on("exit", stop);

  // The port the browser actually took, from the file it writes once it has
  // one. Deriving it any other way is guessing.
  const portFile = join(profile, "DevToolsActivePort");
  let endpoint = null;
  for (let waited = 0; waited < 20000; waited += 100) {
    if (existsSync(portFile)) {
      const lines = readFileSync(portFile, "utf8").split("\n");
      if (lines.length >= 2 && lines[0].trim()) {
        endpoint = `ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}`;
        break;
      }
    }
    if (child.exitCode !== null) break;
    await sleep(100);
  }
  if (!endpoint) {
    stop();
    die(`the browser never reported a debugging port. Its own words: ${browserStderr.trim() || "(none)"}`);
  }

  const cdp = new Cdp(await openWs(endpoint));
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Runtime.enable", {}, sessionId);
  await cdp.send("Log.enable", {}, sessionId);

  const consoleLines = [];
  const errors = [];
  cdp.ws.onMessage = ((inner) => (text) => {
    inner(text);
    let msg;
    try { msg = JSON.parse(text); } catch { return; }
    if (msg.method === "Runtime.consoleAPICalled") {
      consoleLines.push({
        level: msg.params.type,
        text: (msg.params.args || []).map((a) => String(a.value ?? a.description ?? "")).join(" "),
      });
    }
    if (msg.method === "Runtime.exceptionThrown") {
      errors.push(msg.params.exceptionDetails?.exception?.description
        || msg.params.exceptionDetails?.text || "exception");
    }
    if (msg.method === "Log.entryAdded" && msg.params.entry?.level === "error") {
      errors.push(msg.params.entry.text);
    }
  })(cdp.ws.onMessage);

  async function evaluate(expression) {
    const res = await cdp.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    }, sessionId);
    if (res.exceptionDetails) {
      return { threw: res.exceptionDetails.exception?.description || res.exceptionDetails.text };
    }
    return { value: res.result?.value ?? null };
  }

  await cdp.send("Page.navigate", { url }, sessionId);
  // The load event, bounded: a page that never loads is a result, not a hang.
  for (let waited = 0; waited < 20000; waited += 50) {
    const ready = await evaluate("document.readyState");
    if (ready.value === "complete" || ready.value === "interactive") break;
    await sleep(50);
  }

  const results = [];
  const deadline = Date.now() + overallTimeout;
  for (const step of steps) {
    if (Date.now() > deadline) {
      results.push({ op: step.op, ok: false, why: "the run's overall timeout was reached" });
      continue;
    }
    if (step.op === "eval") {
      results.push({ op: "eval", ...(await evaluate(step.expr)) });
      continue;
    }
    if (step.op === "text") {
      const got = await evaluate(
        `(function(){var e=document.querySelector(${JSON.stringify(step.selector)});` +
        "return e ? (e.innerText || e.textContent || '') : null;})()",
      );
      results.push({ op: "text", selector: step.selector, ...got });
      continue;
    }
    if (step.op === "wait") {
      const limit = Number(step.timeout_ms || 10000);
      const started = Date.now();
      let last = null;
      let ok = false;
      while (Date.now() - started < limit) {
        last = await evaluate(step.expr);
        if (last.value) { ok = true; break; }
        await sleep(50);
      }
      results.push({ op: "wait", ok, waited_ms: Date.now() - started, last: last?.value ?? null, threw: last?.threw });
      continue;
    }
    if (step.op === "sleep") {
      await sleep(Number(step.ms || 0));
      results.push({ op: "sleep", ok: true });
      continue;
    }
    if (step.op === "reload") {
      await cdp.send("Page.reload", {}, sessionId);
      for (let waited = 0; waited < 20000; waited += 50) {
        const ready = await evaluate("document.readyState");
        if (ready.value === "complete") break;
        await sleep(50);
      }
      results.push({ op: "reload", ok: true });
      continue;
    }
    if (step.op === "click") {
      // The element's own measured box, then a press and a release at its
      // centre. What is actually under that point is the browser's to decide,
      // which is the difference between this and calling .click() on a node
      // nothing can reach.
      const box = await evaluate(
        `(function(){var e=document.querySelector(${JSON.stringify(step.selector)});` +
        "if(!e) return null; e.scrollIntoView({block:'center'});" +
        "var r=e.getBoundingClientRect();" +
        "if(r.width<=0||r.height<=0) return null;" +
        "return {x:r.left+r.width/2,y:r.top+r.height/2};})()",
      );
      if (!box.value) {
        results.push({ op: "click", selector: step.selector, ok: false, why: "no visible element matches" });
        continue;
      }
      const at = { x: Math.round(box.value.x), y: Math.round(box.value.y) };
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mousePressed", ...at, button: "left", clickCount: 1, buttons: 1,
      }, sessionId);
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mouseReleased", ...at, button: "left", clickCount: 1, buttons: 0,
      }, sessionId);
      results.push({ op: "click", selector: step.selector, ok: true, at });
      continue;
    }
    if (step.op === "run") {
      const done = spawnSync(step.argv[0], step.argv.slice(1), {
        encoding: "utf8",
        cwd: step.cwd || process.cwd(),
        env: { ...process.env, ...(step.env || {}) },
      });
      results.push({
        op: "run",
        argv: step.argv,
        exit: done.status === null ? -1 : done.status,
        stdout: (done.stdout || "").trim(),
        stderr: (done.stderr || "").trim(),
      });
      continue;
    }
    results.push({ op: step.op, ok: false, why: "unknown step" });
  }

  process.stdout.write(JSON.stringify({ steps: results, console: consoleLines, errors }) + "\n");
  stop();
  process.exit(0);
}

main().catch((e) => die(e && e.stack ? e.stack : String(e)));
