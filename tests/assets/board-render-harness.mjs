// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more,
//     cards:[{badges,title,ctx:[{k,v}],options:[{label,consequence,rec}],chips,
//             tabs:[{label,selected}],
//             panels:[{hidden,figures,notes,rows,label,cost,
//                      buttons:[{text,queues}]}],
//             on_enter, on_enter_all, packet:{said,lang,body}|null}],
//     headings:[call,charted,underway,landed], error }
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
    this.name = "";
    this.value = "";
    this.checked = false;
    this._on = {};
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
  addEventListener(type, fn) { (this._on[type] = this._on[type] || []).push(fn); }
  dispatch(type) {
    (this._on[type] || []).slice().forEach((fn) => fn({ preventDefault() {} }));
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
// What the page handed to Lavish, in order: this is the answer channel, and
// the only place the value a card actually sends can be observed.
const queued = [];
globalThis.window = {
  lavish: { queuePrompt: (text, opts) => queued.push({ text, data: opts && opts.data }) },
};
globalThis.FormData = class {
  constructor(form) {
    this._v = new Map();
    const walk = (n) => n.children.forEach((c) => {
      if (c.name && !(c.type === "radio" && !c.checked) && !this._v.has(c.name)) {
        this._v.set(c.name, c.value);
      }
      walk(c);
    });
    walk(form);
  }
  get(k) { return this._v.has(k) ? this._v.get(k) : null; }
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

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
      };
    });

/* Captain's Call cards: badges, title, context rows (key -> value), option
   labels with their consequences, evidence chips, and which language the
   renderer chose (the html lang the renderer sets, when the shim has one). */
const deck = byId.get("bb-call") || new Node("div");
const findAll = (n, cls) => n.querySelectorAll("." + cls);

/* Answering a card, through the page's own listeners, so what a card sends is
   read off the answer channel rather than off an attribute nobody submits.
   A browser presses a form's FIRST submit button when the reader hits Enter in
   a text field, so that is what `on_enter` does: type a note, press Enter, and
   report what the page queued. */
const descendants = (n, out = []) => {
  out.push(n);
  n.children.forEach((c) => descendants(c, out));
  return out;
};
const answerCard = (card) => {
  const form = descendants(card).find((n) => n.tagName === "form");
  if (!form) return;
  const nodes = descendants(form);
  const record = (act) => {
    queued.length = 0;
    act();
    return queued.length ? queued[queued.length - 1].data : null;
  };
  /* Every answer the act queued, not just the last one. Pressing Enter must
     send ONE answer; a spurious extra vote queued before it is invisible to a
     reader that only keeps the last, which is exactly how a live
     implicit-submit bug once sat under a green test. */
  const recordAll = (act) => {
    queued.length = 0;
    act();
    return queued.map((q) => q.data);
  };
  const note = nodes.find((n) => n.name === "note");
  if (note) {
    note.value = "in my own words";
    const dflt = nodes.find((n) => n.tagName === "button" && n.type === "submit");
    card._onEnterAll = recordAll(() => {
      if (dflt) dflt.dispatch("click");
      form.dispatch("submit");
    });
    card._onEnter = card._onEnterAll.length
      ? card._onEnterAll[card._onEnterAll.length - 1]
      : null;
    note.value = "";
  }
  nodes
    .filter((n) => n.tagName === "button" && n.parentNode
      && n.parentNode.className.split(/\s+/).includes("bb-panel"))
    .forEach((b) => { b._queued = record(() => b.dispatch("click")); });
};
deck.children.forEach(answerCard);

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
    /* the packet opened inside the card: its tab strip, one panel per tab, and
       the as-written block behind the collapsed line */
    tabs: findAll(card, "bb-tab").map((b) => ({
      label: b.textContent,
      selected: b.attributes["aria-selected"] === "true",
    })),
    panels: findAll(card, "bb-panel").map((pnl) => ({
      hidden: pnl.hidden === true,
      figures: findAll(pnl, "bb-fig").map((f) => f.innerHTML),
      notes: findAll(pnl, "bb-panel__note").map((n) => n.textContent),
      /* what the option changes: one row per key, each carrying its list */
      rows: findAll(pnl, "bb-panel__row").map((r) => ({
        k: findAll(r, "bb-panel__k")[0]?.textContent ?? "",
        v: (() => {
          const v = findAll(r, "bb-panel__v")[0];
          if (!v) return [];
          const items = descendants(v).filter((n) => n.tagName === "li");
          return items.length ? items.map((li) => li.textContent) : [v.textContent];
        })(),
      })),
      label: findAll(pnl, "bb-panel__label")[0]?.textContent ?? "",
      cost: findAll(pnl, "bb-panel__cost")[0]?.textContent ?? "",
      buttons: findAll(pnl, "fm-btn").map((b) => ({
        text: b.textContent, queues: b._queued ?? null,
      })),
    })),
    on_enter: card._onEnter ?? null,
    on_enter_all: card._onEnterAll ?? [],
    packet: (() => {
      const box = findAll(card, "bb-packet__body")[0];
      if (!box) return null;
      return {
        said: findAll(card, "bb-packet__said")[0]?.textContent ?? "",
        lang: box.attributes.lang ?? "",
        body: box.innerHTML,
      };
    })(),
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
