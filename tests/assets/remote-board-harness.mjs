// Run a DERIVED remote bearings board page under a minimal DOM shim and print
// what the captain would actually see, so the remote transport's behavior is
// asserted by executing it rather than by reading its source.
//
// The page is the real output of `bin/fm-remote-board.sh render`, so the script
// under test is the shipped transport with the shipped board script embedded in
// it; nothing here re-implements either.
//
// Usage: node remote-board-harness.mjs <derived-page.html> <scenario>
//   live        a readable live payload arrives with no answer in progress
//   unreadable  a snapshot arrives that this page cannot render
//   hold        a live payload arrives while an answer is being written
//   hold-send   the same, and then the answer is sent
//   no-db       the artifact store never hands over a db capability
//
// Prints one JSON document:
//   { badge, gap, gapShown, provenance, note, stack, writes }
import { readFileSync } from "node:fs";

const [pagePath, scenario] = process.argv.slice(2);
const html = readFileSync(pagePath, "utf8");

const EMBEDDED = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
// The live payload differs from the built-in one only in its stamp, which the
// board prints, so "did this repaint" is answered by what the page shows.
const LIVE = { ...JSON.parse(EMBEDDED), generated: "2099-01-01T00:00Z" };

/* ---- timers: queued and flushed on demand, so a run is deterministic ---- */
let timers = [];
globalThis.setTimeout = (fn) => timers.push(fn);
function flushTimers() {
  for (let i = 0; i < 20 && timers.length; i++) {
    const due = timers;
    timers = [];
    due.forEach((fn) => fn());
  }
}
const tick = async () => {
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setImmediate(r));
    flushTimers();
  }
};

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
    if (p.startsWith("#")) return node.attributes.id === p.slice(1) || node.id === p.slice(1);
    if (p.startsWith("[")) {
      const [name, want] = p.slice(1, -1).split("=");
      const have = name in node.attributes ? node.attributes[name] : node[name];
      return want === undefined ? have !== undefined && have !== "" : String(have) === want.replace(/^["']|["']$/g, "");
    }
    return node.tagName === p;
  });
}

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.style = {};
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
  set id(v) { this.attributes.id = v; }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  get innerHTML() { return this === body ? PRISTINE_MARK : ""; }
  set innerHTML(v) {
    this.children = [];
    this._text = "";
    // Restoring the body's parsed markup throws every rendered node away, which
    // is exactly what the real repaint does.
    if (this === body && v === PRISTINE_MARK) reseed();
  }
  appendChild(n) {
    n.parentNode = this;
    this.children.push(n);
    if (n.tagName === "script" && n._text) new Function(n._text)();
    return n;
  }
  removeChild(n) { this.children = this.children.filter((c) => c !== n); return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  contains(n) {
    if (n === this) return true;
    return this.children.some((c) => c.contains(n));
  }
  closest(sel) {
    let n = this;
    while (n) {
      if (matches(n, sel)) return n;
      n = n.parentNode;
    }
    return null;
  }
  querySelectorAll(sel) {
    const out = [];
    const walk = (n) => n.children.forEach((c) => { if (matches(c, sel)) out.push(c); walk(c); });
    walk(this);
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

const PRISTINE_MARK = "[the body markup as parsed]";
let body = new Node("body");
let byId = new Map();
// The two containers the template's static markup provides; everything else on
// the page is rendered by the board script itself.
const MARKUP_SELECTORS = [".bb-nav__inner", ".bb-main"];
let bySelector = new Map();

function reseed() {
  byId = new Map();
  bySelector = new Map();
  const slot = new Node("script");
  slot.id = "bearings-data";
  slot.textContent = EMBEDDED;
  byId.set("bearings-data", slot);
  body.children.push(slot);
  slot.parentNode = body;
}

globalThis.document = {
  documentElement: { lang: "" },
  activeElement: null,
  body,
  createElement: (tag) => new Node(tag),
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      n.id = id;
      body.appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const found = body.querySelector(sel);
    if (found) return found;
    if (!MARKUP_SELECTORS.includes(sel)) return null;
    if (!bySelector.has(sel)) {
      const n = new Node("div");
      n.className = sel.slice(1);
      body.appendChild(n);
      bySelector.set(sel, n);
    }
    return bySelector.get(sel);
  },
  querySelectorAll: (sel) => body.querySelectorAll(sel),
  addEventListener: (type, fn) => body.addEventListener("doc:" + type, fn),
};

// Events: the document's capture listeners run, then the target's own, which is
// the order the transport and the board rely on.
function fire(target, type, event) {
  (body.listeners["doc:" + type] || []).forEach((fn) => fn(event));
  let n = target;
  while (n) {
    (n.listeners[type] || []).forEach((fn) => fn(event));
    n = n.parentNode;
  }
}

globalThis.FormData = class {
  constructor(form) {
    this.map = new Map();
    form.querySelectorAll("input").forEach((i) => {
      if (!i.name) return;
      if (i.type === "radio" || i.type === "checkbox") { if (i.checked) this.map.set(i.name, i.value); }
      else this.map.set(i.name, i.value);
    });
  }
  get(name) { return this.map.has(name) ? this.map.get(name) : null; }
};

const store = new Map();
const writes = [];
let snapshot = null;

const db = {
  doc: (path) => ({
    set: (record) => { writes.push({ path, record }); return Promise.resolve(); },
    onSnapshot: (cb) => { if (path === "board/current") snapshot = cb; },
  }),
};

globalThis.window = {
  localStorage: {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
  },
  claude: { use: () => Promise.resolve(scenario === "no-db" ? null : db) },
};
globalThis.TextEncoder = TextEncoder;

reseed();

/* ---- run the page's own script ---- */
const transport = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(transport)();

const lastForm = () => document.querySelectorAll("form[data-lavish-question]").slice(-1)[0];
const noteField = () => lastForm() && lastForm().querySelector(".bb-freeform");

function typeNote(text) {
  const note = noteField();
  note.value = text;
  document.activeElement = note;
  fire(note, "input", {});
}

function submitAnswer() {
  const form = lastForm();
  document.activeElement = null;
  fire(form, "submit", { preventDefault() {} });
}

function push(payload) {
  snapshot(payload ? { exists: true, data: () => payload } : { exists: false, data: () => null });
}

await tick();

if (scenario === "live") {
  push(LIVE);
} else if (scenario === "unreadable") {
  push(null);
} else if (scenario === "hold" || scenario === "hold-send") {
  document.getElementById("bb-stack-next").onclick();
  typeNote("wait for me");
  push(LIVE);
  if (scenario === "hold-send") submitAnswer();
} else if (scenario === "no-db") {
  typeNote("goes nowhere");
  submitAnswer();
}
await tick();

const gapNode = byId.get("bb-remote-answer-gap");
process.stdout.write(JSON.stringify({
  badge: (byId.get("bb-remote-link") || {}).textContent || "",
  gap: gapNode ? gapNode.textContent : "",
  gapShown: gapNode ? gapNode.style.display !== "none" : false,
  provenance: (byId.get("bb-provenance") || {}).textContent || "",
  note: noteField() ? noteField().value : null,
  stack: (byId.get("bb-stack-count") || {}).textContent || "",
  writes,
}) + "\n");
