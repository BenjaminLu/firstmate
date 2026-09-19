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
//   unreadable  a snapshot arrives that this page cannot render, first thing
//   went-quiet  a readable payload lands and then the page stops receiving
//   long-quiet  the same, read again an hour and a half later
//   never-shown a payload is held mid-answer, never painted, and the link drops
//   bad-shape   a readable payload paints, then a schema-tagged one the board
//               cannot render arrives
//   held-quiet  a payload is held mid-answer, the page stops receiving, the
//               answer is sent and the held payload is released
//   hold        a live payload arrives while an answer is being written
//   hold-send   the same, and then the answer is sent
//   hold-stale  a selection is left behind on a card the deck has moved past
//   hold-picks  a payload arrives on unsent dispatch ticks
//   picks-sent  the same, and then the dispatch order is queued
//   write-fails an answer is written, the write is refused, a payload follows
//   stopped     the same, and then the page stops receiving readable payloads
//   repaint-cost    twelve live payloads in a row, to weigh what each repaint left
//   answer-button   a Captain's Call answer given by pressing an option
//   answer-written  an answer given only in writing, no option pressed
//   answer-both     an option pressed and a note written together
//   lang        the board's own language switch is used
//   no-db       the artifact store never hands over a db capability
//
// Prints one JSON document:
//   { badge, badgeAtDrop, badgeHost, langHost, answers, answersHost,
//     provenance, note,
//     stack, picks, writes }
import { readFileSync } from "node:fs";

const [pagePath, scenario] = process.argv.slice(2);
const html = readFileSync(pagePath, "utf8");

const EMBEDDED = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
// The live payload differs from the built-in one only in its stamp, which the
// board prints, so "did this repaint" is answered by what the page shows.
const LIVE = { ...JSON.parse(EMBEDDED), generated: "2099-01-01T00:00Z" };

/* ---- time: a clock the run advances itself, and timers flushed on demand,
       so what a page reports after an hour is observable in milliseconds ---- */
let shift = 0;
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...args) {
    super(...(args.length ? args : [RealDate.now() + shift]));
  }
  static now() { return RealDate.now() + shift; }
};
// Timers carry ids and can be cancelled, because the page under test tears down
// what a previous board run registered; a harness that cannot cancel would show
// a leak-free page for the wrong reason.
let timers = new Map();
let intervals = new Map();
let timerSeq = 0;
globalThis.setTimeout = (fn) => { timers.set(++timerSeq, fn); return timerSeq; };
globalThis.setInterval = (fn) => { intervals.set(++timerSeq, fn); return timerSeq; };
globalThis.clearTimeout = (id) => timers.delete(id);
globalThis.clearInterval = (id) => intervals.delete(id);
function waitMinutes(n) {
  shift += n * 60000;
  [...intervals.values()].forEach((fn) => fn());
}
function flushTimers() {
  for (let i = 0; i < 20 && timers.size; i++) {
    const due = [...timers.values()];
    timers = new Map();
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
// The skeleton is the published page's own: which ids exist before any script
// runs, and which of them sit inside <main class="bb-main"> - which matters,
// because the board empties that element when it refuses a payload and its
// sections really do leave the document. Anything not declared there - the
// transport's two badges among them - has to be created and attached by the
// code under test, which is the behavior worth proving.
const idsIn = (text) => [...text.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
const TEMPLATE_IDS = idsIn(html);
const MAIN_IDS = new Set(idsIn(html.slice(html.indexOf("<main"), html.indexOf("</main>"))));
let body = new Node("body");

function attach(parent, node) {
  node.parentNode = parent;
  parent.children.push(node);
  return node;
}

function reseed() {
  body.children = [];
  // Mirror the shipped template's real nesting: a .bb-nav header wrapping the
  // fixed-height .bb-nav__inner row that carries the brand and the language
  // switch. A flat .bb-nav__inner cannot show where the transport puts its
  // status line, which is the difference between a tappable language switch and
  // one covered by a badge on a phone.
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
  TEMPLATE_IDS.forEach((id) => {
    const node = attach(MAIN_IDS.has(id) ? main : body, new Node(id === "bearings-data" ? "script" : "div"));
    node.id = id;
    if (id === "bearings-data") node.textContent = EMBEDDED;
  });
}

globalThis.document = {
  documentElement: { lang: "" },
  activeElement: null,
  body,
  createElement: (tag) => new Node(tag),
  getElementById: (id) => body.querySelector("#" + id),
  querySelector: (sel) => body.querySelector(sel),
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
    if (type === "click" && typeof n.onclick === "function") n.onclick(event);
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
    set: (record) => {
      writes.push({ path, record });
      return scenario === "write-fails" || scenario === "stopped"
        ? Promise.reject(new Error("the store refused this write"))
        : Promise.resolve();
    },
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

// The three shapes a Captain's Call answer can take. The template is the writer
// of an answer record, so these exist to pin what it actually emits and what a
// carrier must pass on unchanged - a written-only answer included, which has an
// empty selection and is still a real answer.
// The card the deck opens on is the one that takes a written answer, so these
// three drive it rather than whichever form happens to be last.
const openCard = () => document.querySelectorAll("form[data-lavish-question]")[0];
function answerOn(card, { press, write }) {
  if (press) {
    const radio = card.querySelector("input[type=radio]");
    radio.checked = true;
    fire(radio, "change", {});
  }
  if (write) {
    const note = card.querySelector(".bb-freeform");
    note.value = write;
    document.activeElement = note;
    fire(note, "input", {});
  }
  document.activeElement = null;
  fire(card, "submit", { preventDefault() {} });
}

if (scenario === "repaint-cost") {
  // Repaint many times over and report what the last run left registered. A
  // number that grows with the repaint count is the leak; it must not move.
  for (let i = 0; i < 12; i += 1) {
    push({ ...LIVE, generated: `2026-09-19T${10 + i}:00Z` });
    await tick();
  }
} else if (scenario === "answer-button") {
  answerOn(openCard(), { press: true });
} else if (scenario === "answer-written") {
  answerOn(openCard(), { write: "do it the slow way" });
} else if (scenario === "answer-both") {
  answerOn(openCard(), { press: true, write: "do it the slow way" });
} else if (scenario === "live") {
  push(LIVE);
} else if (scenario === "unreadable") {
  push(null);
} else if (scenario === "went-quiet" || scenario === "long-quiet") {
  push(LIVE);
  await tick();
  push(null);
} else if (scenario === "bad-shape") {
  push(LIVE);
  await tick();
  // Schema-tagged and refused by the board's own structural check: the list it
  // needs is not a list. Nothing between the publisher and this page checks it.
  push({ ...LIVE, captains_call: {}, generated: "2100-01-01T00:00Z" });
} else if (scenario === "never-shown") {
  // The page was opened before board/current existed, so nothing has ever been
  // painted but the store is reachable; a payload then arrives mid-answer and
  // is held, and the link drops before it is ever shown.
  push(null);
  await tick();
  document.getElementById("bb-stack-next").onclick();
  typeNote("mid answer");
  push(LIVE);
  await tick();
  push(null);
} else if (scenario === "held-quiet") {
  document.getElementById("bb-stack-next").onclick();
  typeNote("wait for me");
  push(LIVE);
  await tick();
  push(null);
  await tick();
  submitAnswer();
} else if (scenario === "hold" || scenario === "hold-send") {
  document.getElementById("bb-stack-next").onclick();
  typeNote("wait for me");
  push(LIVE);
  if (scenario === "hold-send") submitAnswer();
} else if (scenario === "hold-stale") {
  // A radio tapped to read its consequence, then left behind by dealing the
  // next card: the captain is answering nothing, so nothing may hold the board.
  const first = document.querySelectorAll("form[data-lavish-question]")[0];
  const radio = first.querySelector("input[type=radio]");
  radio.checked = true;
  fire(radio, "change", {});
  document.getElementById("bb-stack-next").onclick();
  document.activeElement = null;
  push(LIVE);
} else if (scenario === "hold-picks" || scenario === "picks-sent") {
  // Nothing is being typed and no card is selected: only the dispatch ticks he
  // has made and not queued can hold this update.
  const pick = body.querySelector(".bb-pick");
  pick.checked = true;
  fire(pick, "change", {});
  document.activeElement = null;
  push(LIVE);
  if (scenario === "picks-sent") fire(document.getElementById("bb-dispatch-btn"), "click", {});
} else if (scenario === "write-fails" || scenario === "stopped") {
  typeNote("this write is refused");
  submitAnswer();
  await tick();
  push(scenario === "stopped" ? null : LIVE);
} else if (scenario === "lang") {
  push(LIVE);
  await tick();
  fire(document.getElementById("bb-lang-hant"), "click", {});
} else if (scenario === "no-db") {
  typeNote("goes nowhere");
  submitAnswer();
}
await tick();

const shown = (id) => body.querySelector("#" + id);
// What the line said when the link dropped, beside what it says after time has
// passed, so a frozen age and a counting one cannot look the same.
const badgeAtDrop = (shown("bb-remote-link") || {}).textContent || "";
if (scenario === "long-quiet") {
  await tick();
  waitMinutes(90);
}
// Report the host by class OR id: the status line sits in a container the
// transport creates, which carries an id rather than a board class.
const hostOf = (node) =>
  (node && node.parentNode ? (node.parentNode.className || node.parentNode.id || "") : "");
const linkNode = shown("bb-remote-link");
const answerNode = shown("bb-remote-answers");
process.stdout.write(JSON.stringify({
  badge: linkNode ? linkNode.textContent : "",
  badgeAtDrop,
  badgeHost: hostOf(linkNode),
  statusRowHost: hostOf(shown("bb-remote-status")),
  langHost: hostOf(shown("bb-lang-en")),
  answers: answerNode ? answerNode.textContent : "",
  answersHost: hostOf(answerNode),
  provenance: (shown("bb-provenance") || {}).textContent || "",
  note: noteField() ? noteField().value : null,
  stack: (shown("bb-stack-count") || {}).textContent || "",
  picks: body.querySelectorAll(".bb-pick:checked").length,
  writes,
  registrations:
    typeof globalThis.__fmBoardRegistrations === "function"
      ? globalThis.__fmBoardRegistrations()
      : null,
}) + "\n");
