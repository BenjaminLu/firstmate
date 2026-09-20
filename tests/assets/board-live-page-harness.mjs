// Run a DERIVED live bearings board under a minimal DOM shim and print what
// the captain would actually see, so the live transport's behavior is asserted
// by executing it rather than by reading its source.
//
// The page is the real output of `bin/fm-bearings-board.sh derive`, so the
// script under test is the shipped transport with the shipped board script
// beside it; nothing here re-implements either.
//
// Usage: node board-live-page-harness.mjs <derived-page.html> <scenario>
//   first-paint  no message ever arrives
//   live         a readable state message arrives
//   unreadable   a state message the board cannot render arrives after a good one
//   no-board     the server reports it has no built board to serve
//   hold         a state message arrives while an answer is being written
//   hold-send    the same, and then the answer is sent
//   behind       a state message arrives carrying changes needing a rebuild
//   behind-clear the same, and then one carrying none
//   old-seq      a state message older than the one already applied arrives
//   dropped      the socket closes, and reopens with the current state
//   went-quiet   a message lands and then the page stops receiving
//   lang         the board's own language switch is used
//   answer-sent     the captain's pick is carried back and lands
//   answer-refused  the captain's pick is carried back and is refused
//   answer-offline  the captain picks while the board is not connected
//
// Prints one JSON document:
//   { link, behind, sent, outbound, badgeHost, provenance, underway, calls, sockets }
import { readFileSync } from "node:fs";

const [pagePath, scenario] = process.argv.slice(2);
const html = readFileSync(pagePath, "utf8");

const SLOT_OPEN = '<script id="bearings-data" type="application/json">';
const EMBEDDED = html.split(SLOT_OPEN)[1].split("</script>")[0];
const BOARD_SRC = html.slice(
  html.indexOf("<script>") + "<script>".length,
  html.lastIndexOf("</script>"),
);
const TRANSPORT_SRC = html
  .split('<script id="fm-board-live">')[1]
  .split("</script>")[0];

/* A payload that differs only in its stamp, which the board prints, so "did
   this repaint" is answered by what the page shows rather than by a spy. */
const base = JSON.parse(EMBEDDED);
const live = (over) => ({ ...JSON.parse(JSON.stringify(base)), generated: "2099-01-01T00:00Z", ...over });

/* ---- time: a clock the run advances itself ---- */
let shift = 0;
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...args) { super(...(args.length ? args : [RealDate.now() + shift])); }
  static now() { return RealDate.now() + shift; }
};
let timers = [];
let intervals = [];
globalThis.setTimeout = (fn) => { timers.push(fn); return timers.length; };
globalThis.setInterval = (fn) => { intervals.push(fn); return intervals.length; };
globalThis.clearTimeout = () => {};
function flushTimers() {
  for (let i = 0; i < 20 && timers.length; i++) {
    const due = timers;
    timers = [];
    due.forEach((fn) => fn());
  }
}
function waitMinutes(n) { shift += n * 60000; intervals.forEach((fn) => fn()); }

/* ---- the DOM this page needs, and no more ---- */
function matches(node, selector) {
  let sel = selector.trim();
  if (sel.endsWith(":checked")) {
    if (!node.checked) return false;
    sel = sel.slice(0, -":checked".length);
  }
  const classes = node.className.split(/\s+/).filter(Boolean);
  const parts = sel.match(/^[a-zA-Z][\w-]*|\.[\w-]+|#[\w-]+|\[[^\]]+\]/g) || [];
  return parts.every((p) => {
    if (p.startsWith(".")) return classes.includes(p.slice(1));
    if (p.startsWith("#")) return node.id === p.slice(1);
    if (p.startsWith("[")) {
      const [name, want] = p.slice(1, -1).split("=");
      const have = name in node.attributes ? node.attributes[name] : node[name];
      return want === undefined
        ? have !== undefined && have !== ""
        : String(have) === want.replace(/^["']|["']$/g, "");
    }
    return node.tagName === p;
  });
}

const PRISTINE_MARK = "[the body markup as parsed]";

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.style = { cssText: "" };
    this.listeners = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.parentNode = null;
    this.type = "";
    this.name = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { if (!this.className.split(/\s+/).includes(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get id() { return this.attributes.id || ""; }
  set id(v) { this.attributes.id = v; registry.set(v, this); }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  get innerHTML() { return this === body ? PRISTINE_MARK : ""; }
  set innerHTML(v) {
    this.children = [];
    this._text = "";
    // Restoring the body's parsed markup throws every rendered node away,
    // which is exactly what the real repaint does.
    if (this === body && v === PRISTINE_MARK) reseed();
  }
  appendChild(n) {
    n.parentNode = this;
    this.children.push(n);
    if (n.id) registry.set(n.id, n);
    // A JSON data block is data; only a script the browser would run, runs.
    if (n.tagName === "script" && n._text && (!n.type || n.type === "text/javascript")) {
      new Function(n._text)();
    }
    return n;
  }
  removeChild(n) { this.children = this.children.filter((c) => c !== n); return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  dispatch(type) { (this.listeners[type] || []).slice().forEach((fn) => fn({ preventDefault() {} })); }
  contains(n) { return n === this || this.children.some((c) => c.contains(n)); }
  closest(sel) {
    let n = this;
    while (n) { if (matches(n, sel)) return n; n = n.parentNode; }
    return null;
  }
  querySelectorAll(sel) {
    const out = [];
    const walk = (n) => n.children.forEach((c) => { if (matches(c, sel)) out.push(c); walk(c); });
    walk(this);
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  getElementsByTagName(tag) {
    const out = [];
    const walk = (n) => n.children.forEach((c) => { if (c.tagName === tag) out.push(c); walk(c); });
    walk(this);
    return out;
  }
}

// The skeleton is the derived page's own: which ids exist before any script
// runs, and which of them sit inside <main class="bb-main"> - which matters,
// because the board empties that element when it refuses a payload and its
// sections really do leave the document. Anything not declared there - the
// transport's badges among them - has to be created and attached by the code
// under test, which is the behavior worth proving.
const idsIn = (text) => [...text.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
const MAIN_SLICE = html.slice(html.indexOf("<main"), html.indexOf("</main>"));
const TEMPLATE_IDS = idsIn(html);
const MAIN_IDS = new Set(idsIn(MAIN_SLICE));

let registry = new Map();
let body = new Node("body");

function findById(root, id) {
  for (const c of root.children) {
    if (c.id === id) return c;
    const deeper = findById(c, id);
    if (deeper) return deeper;
  }
  return null;
}

function attach(parent, node) {
  node.parentNode = parent;
  parent.children.push(node);
  if (node.id) registry.set(node.id, node);
  return node;
}

function reseed() {
  registry = new Map();
  body.children = [];
  // Mirror the shipped template's real nesting: a .bb-nav header wrapping the
  // fixed-height .bb-nav__inner row that carries the brand and the language
  // switch. A flat .bb-nav__inner cannot show where the transport puts its
  // status line, which is the difference between a tappable language switch
  // and one covered by a badge on a phone.
  const navOuter = attach(body, new Node("header"));
  navOuter.className = "bb-nav";
  const nav = attach(navOuter, new Node("div"));
  nav.className = "bb-nav__inner";
  ["bb-lang-en", "bb-lang-hant", "bb-lang-hans"].forEach((id) => {
    const btn = attach(nav, new Node("button"));
    btn.id = id;
    btn.className = "bb-lang__btn";
  });
  const main = attach(body, new Node("main"));
  main.className = "bb-main";
  for (const id of TEMPLATE_IDS) {
    if (id === "bearings-data" || id === "fm-board-live") continue;
    if (registry.has(id)) continue;
    const node = new Node("div");
    node.id = id;
    attach(MAIN_IDS.has(id) ? main : body, node);
  }
  // The data slot and the board script are NOT seeded here. The transport
  // captures the markup above its own tag, which is above both of them, so a
  // repaint restores neither - and a shim that put them back would leave two
  // data slots in the tree and hand the board the stale one.
}
reseed();

globalThis.document = {
  body,
  documentElement: { lang: "zh-Hant" },
  readyState: "loading",
  activeElement: null,
  listeners: {},
  createElement: (tag) => new Node(tag),
  // The board draws its decision map as SVG, which a page must build in the
  // SVG namespace. This shim keeps no namespaces, so the node is the same one
  // createElement makes - what matters is that the call EXISTS, because a page
  // that cannot make one throws its whole render into its own catch and this
  // harness reads that as "the board could not be rendered".
  //
  // It is here rather than in the board because the page is right and the shim
  // was behind it: a real browser has createElementNS, and the map renders
  // correctly everywhere that is true. A shim modelling only the DOM the page
  // used to need will break again the moment the page needs more, so anything
  // added here is added for the board as it is, never the board trimmed to fit.
  createElementNS: (_ns, tag) => new Node(tag),
  // A LIVE lookup, walking the tree. A flat registry would keep answering with
  // a node the page has detached - and detaching is exactly what the board
  // does to its own sections when it refuses a payload, which is the signal
  // the transport reads to decide whether to undo an update.
  getElementById: (id) => findById(body, id),
  querySelector: (sel) => body.querySelector(sel),
  querySelectorAll: (sel) => body.querySelectorAll(sel),
  getElementsByTagName: (tag) => body.getElementsByTagName(tag),
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
  dispatch(type, ev) { (this.listeners[type] || []).slice().forEach((fn) => fn(ev || {})); },
};

const store = new Map();
const sockets = [];
class FakeSocket {
  constructor(url) {
    this.url = url;
    this.closed = false;
    /* CONNECTING until opened, exactly as a browser reports it, because the
       page refuses to send an answer on a socket that is not open. */
    this.readyState = 0;
    this.sent = [];
    sockets.push(this);
  }
  open() { this.readyState = 1; if (this.onopen) this.onopen(); }
  deliver(obj) { if (this.onmessage) this.onmessage({ data: JSON.stringify(obj) }); }
  drop() {
    this.closed = true;
    this.readyState = 3;
    if (this.onclose) this.onclose();
  }
  send(text) {
    if (this.readyState !== 1) throw new Error("socket is not open");
    this.sent.push(text);
  }
}
globalThis.window = {
  WebSocket: function (url) { return new FakeSocket(url); },
  localStorage: {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
  },
  // The answer channel is untouched by this transport; it is present because
  // the board uses it, and observed so a scenario can prove an answer was sent.
  lavish: { queuePrompt: (text, opts) => queued.push({ text, data: opts && opts.data }) },
};
const queued = [];
globalThis.FormData = class {
  constructor(form) {
    this._v = new Map();
    const walk = (n) => n.children.forEach((c) => {
      if (c.name && !(c.type === "radio" && !c.checked) && !this._v.has(c.name)) this._v.set(c.name, c.value);
      walk(c);
    });
    walk(form);
  }
  get(k) { return this._v.has(k) ? this._v.get(k) : null; }
};
globalThis.TextEncoder = TextEncoder;

/* ---- first paint, in the order the browser performs it ------------------
 * markup, then the transport (which captures that markup), then the data slot
 * element, then the board script - appending which runs it, exactly as a
 * parser would - and finally DOMContentLoaded, where the transport reads the
 * board's source off the page and subscribes.
 */
new Function(TRANSPORT_SRC)();
const firstSlot = new Node("script");
firstSlot.id = "bearings-data";
firstSlot.type = "application/json";
firstSlot._text = EMBEDDED;
attach(body, firstSlot);
const firstBoard = new Node("script");
firstBoard._text = BOARD_SRC;
body.appendChild(firstBoard);
globalThis.document.readyState = "complete";
globalThis.document.dispatch("DOMContentLoaded");
flushTimers();

const socket = () => sockets[sockets.length - 1];
const message = (over) => ({ type: "state", schema: "fm-board-live.v1", seq: 1, payload: live(), stale: [], ...over });

function answerInProgress() {
  const form = body.querySelector("form[data-lavish-question]");
  if (!form) return false;
  const radio = form.querySelectorAll("input[type=radio]")[0];
  if (radio) { radio.checked = true; radio.dispatch("change"); }
  document.dispatch("change", {});
  return !!radio;
}

function sendAnswer() {
  const form = body.querySelector("form[data-lavish-question]");
  if (form) form.dispatch("submit");
  document.dispatch("submit", {});
  flushTimers();
}

let seq = 1;
const next = (over) => message({ seq: seq++, ...over });

switch (scenario) {
  case "first-paint":
    break;
  case "live":
    socket().open();
    socket().deliver(next());
    break;
  case "unreadable":
    socket().open();
    socket().deliver(next());
    socket().deliver(next({ payload: { schema: "something-else.v1" } }));
    break;
  case "no-board":
    socket().open();
    socket().deliver(next({ payload: null, base_missing: "no board has been built in this home yet" }));
    break;
  case "hold":
    socket().open();
    answerInProgress();
    socket().deliver(next());
    break;
  case "hold-send":
    socket().open();
    answerInProgress();
    socket().deliver(next());
    sendAnswer();
    break;
  case "behind":
    socket().open();
    socket().deliver(next({ stale: [{ kind: "call", task: "beta", why: "a new captain's call needs firstmate to word it" }] }));
    break;
  case "behind-clear":
    socket().open();
    socket().deliver(next({ stale: [{ kind: "call", task: "beta", why: "x" }] }));
    socket().deliver(next());
    break;
  case "old-seq":
    socket().open();
    socket().deliver(message({ seq: 7, payload: live({ generated: "2099-01-01T00:00Z" }) }));
    socket().deliver(message({ seq: 3, payload: live({ generated: "1999-01-01T00:00Z" }) }));
    break;
  case "dropped":
    socket().open();
    socket().deliver(next());
    socket().drop();
    flushTimers();
    if (sockets.length > 1) {
      socket().open();
      socket().deliver(message({ seq: 99, payload: live({ generated: "2100-06-06T00:00Z" }) }));
    }
    break;
  case "went-quiet":
    socket().open();
    socket().deliver(next());
    socket().drop();
    waitMinutes(7);
    break;
  /* The captain presses a button on a card and the page carries his pick
     back. The board's own handler is not involved: this drives the seam the
     board is given, which is what the server half publishes. */
  case "answer-sent":
    socket().open();
    socket().deliver(next());
    window.fmBoardLive.answer({ key: "pick-one", selection: "yes", label: "Yes", close: "done" });
    socket().deliver({ type: "inbound", schema: "fm-board-inbound-result.v1", id: "a1", status: "accepted" });
    socket().deliver({ type: "inbound", schema: "fm-board-inbound-result.v1", id: "a1", status: "recorded" });
    break;
  case "answer-refused":
    socket().open();
    socket().deliver(next());
    window.fmBoardLive.answer({ key: "pick-one", selection: "yes", label: "Yes" });
    socket().deliver({
      type: "inbound", schema: "fm-board-inbound-result.v1", id: "a1",
      status: "refused", reason: "unauthenticated",
    });
    break;
  case "answer-offline":
    /* Never opened: the page must say the answer did not go, not swallow it. */
    window.fmBoardLive.answer({ key: "pick-one", selection: "yes", label: "Yes" });
    break;
  case "lang": {
    socket().open();
    socket().deliver(next());
    const btn = findById(body, "bb-lang-en");
    if (btn) btn.dispatch("click");
    document.dispatch("click", {});
    flushTimers();
    break;
  }
  default:
    process.stderr.write(`board-live-page-harness: unknown scenario: ${scenario}\n`);
    process.exit(2);
}
flushTimers();

const badge = (id) => {
  const n = findById(body, id);
  if (!n || n.hidden) return null;
  return { text: n.textContent, tone: n.className.replace(/.*fm-badge--/, "").trim() };
};
const strip = findById(body, "bb-live-status");
const provenance = findById(body, "bb-provenance");
const underway = findById(body, "bb-underway");
const call = findById(body, "bb-call");

process.stdout.write(JSON.stringify({
  link: badge("bb-live-link"),
  behind: badge("bb-live-behind"),
  sent: badge("bb-live-sent"),
  // Every frame the page put on the wire, so what it sends is asserted from
  // the wire rather than from a spy inside the code under test.
  outbound: sockets.map((s) => s.sent).reduce((a, b) => a.concat(b), []),
  // Where the badges live matters: inside the fixed-height nav row they push a
  // phone screen sideways and cover the language switch.
  badgeHost: strip ? strip.parentNode.className : null,
  provenance: provenance ? provenance.textContent : null,
  underway: underway ? underway.children.length : null,
  calls: call ? call.children.length : null,
  sockets: sockets.length,
  answered: queued.length,
  // The board's own verdict, read the same way the transport reads it: it
  // builds its sections when it accepted a payload and replaces them with one
  // error card when it did not.
  error: !(findById(body, "bb-stats") && findById(body, "bb-call")),
}) + "\n");
