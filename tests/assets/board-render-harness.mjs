// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [click] [relang]
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges,ack}],
//     charted:[{title,sub,badges,pickable,ack}], empty, more,
//     cards:[{badges,title,ctx:[{k,v}],options:[{label,consequence,rec}],chips,ack}],
//     headings:[call,charted,underway,landed], error }
// An `ack` is {label, why} or null.
//
// A second argument replays a captain click before the page is read, so the
// immediate acknowledgement is asserted through the real handler rather than
// by reading the template's source:
//   dispatch        check every pickable Charted Next row, then send
//   answer          submit the dealt Captain's Call card
// A third argument (en|hant|hans) then clicks that language button, so what
// survives a re-render is asserted through the real control the captain has.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) {
    (this._listeners || (this._listeners = {}))[type] = fn;
  }
  dispatch(type, ev) {
    const fn = this._listeners && this._listeners[type];
    if (fn) fn.call(this, ev || { preventDefault() {} });
  }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
// The page remembers what the captain clicked so a re-render can put the
// acknowledgement back; that memory is browser storage, so the shim has one.
const storage = new Map();
globalThis.window = {
  localStorage: {
    getItem: (k) => (storage.has(k) ? storage.get(k) : null),
    setItem: (k, v) => { storage.set(k, String(v)); },
  },
};
globalThis.TextEncoder = TextEncoder;
// The card's submit handler reads its own inputs; a radio is answered only
// when something checked it, exactly as in a browser.
globalThis.FormData = class {
  constructor(form) { this.form = form; }
  get(name) {
    const inputs = [];
    const walk = (n) => { for (const c of n.children) { if (c.tagName === "input") inputs.push(c); walk(c); } };
    walk(this.form);
    const radio = inputs.find((i) => i.name === name && i.type === "radio" && i.checked);
    if (radio) return radio.value;
    const field = inputs.find((i) => i.name === name && i.type !== "radio");
    return field ? field.value : null;
  }
};
// The deck deals the next card on a timer; the acknowledgement is not on it,
// so the shim never runs one and the read below sees the click's own effect.
globalThis.setTimeout = () => 0;
// The pills age on an interval the page owns. Nothing here advances it: each
// read below is one instant, and an aged acknowledgement is produced by an
// older stamp rather than by winding a clock on.
globalThis.setInterval = () => 0;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

/* Replay one captain click through the real handler before the page is read. */
const nodesWhere = (root, pred) => {
  const out = [];
  const walk = (n) => { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } };
  walk(root);
  return out;
};
const click = process.argv[3] || "";
if (click === "dispatch") {
  const picks = nodesWhere(byId.get("bb-charted"), (n) => n.className.split(/\s+/).includes("bb-pick"));
  for (const p of picks) { p.checked = true; p.dispatch("change"); }
  const btn = byId.get("bb-dispatch-btn");
  if (typeof btn.onclick === "function") btn.onclick();
} else if (click === "answer") {
  const form = nodesWhere(byId.get("bb-call"), (n) => n.tagName === "form")[0];
  if (form) {
    const radio = nodesWhere(form, (n) => n.tagName === "input" && n.type === "radio")[0];
    if (radio) radio.checked = true;
    form.dispatch("submit", { preventDefault() {} });
  }
} else if (click) {
  throw new Error("unknown click: " + click);
}

/* Then, optionally, the language switch - a control the captain keeps, and a
   full re-render of every row. */
const relang = process.argv[4] || "";
if (relang) {
  if (!["en", "hant", "hans"].includes(relang)) throw new Error("unknown language: " + relang);
  document.getElementById("bb-lang-" + relang).dispatch("click");
}

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

/* The pill the click or the payload put on the row, and a refusal's reason. */
const ackOf = (n) => {
  if (!n) return null;
  const pill = n.children.find((c) => c.className.split(/\s+/).includes("bb-ack"));
  if (!pill) return null;
  const why = n.children.find((c) => c.className.includes("bb-ack__why"));
  return {
    label: pill.textContent,
    kind: pill.className.replace(/.*bb-ack--/, "").trim(),
    why: why ? why.textContent : null,
  };
};

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
        ack: ackOf(main),
      };
    });

/* Captain's Call cards: badges, title, context rows (key -> value), option
   labels with their consequences, evidence chips, and which language the
   renderer chose (the html lang the renderer sets, when the shim has one). */
const deck = byId.get("bb-call") || new Node("div");
const findAll = (n, cls) => n.querySelectorAll("." + cls);
const cards = deck.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => ({
    badges: findAll(card, "fm-badge").map((b) => b.textContent),
    title: findAll(card, "bb-decision__title")[0]?.textContent ?? "",
    ctx: findAll(card, "bb-ctx__row").map((r) => ({
      k: findAll(r, "bb-ctx__k")[0]?.textContent ?? "",
      v: findAll(r, "bb-ctx__v")[0]?.textContent ?? "",
    })),
    options: findAll(card, "bb-opt").map((o) => ({
      label: findAll(o, "bb-opt__label")[0]?.textContent ?? "",
      consequence: findAll(o, "bb-opt__consequence")[0]?.textContent ?? "",
      rec: findAll(o, "bb-opt__rec").length > 0,
    })),
    chips: findAll(card, "bb-chip").map((a) => a.textContent),
    ack: ackOf(card.children.find((c) => c.className.includes("bb-decision__pad"))),
  }));
const headings = ["bb-t-call", "bb-t-charted", "bb-t-underway", "bb-t-landed"]
  .map((id) => byId.get(id)?.textContent ?? "");

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, cards, headings, error: errorText }) + "\n");
