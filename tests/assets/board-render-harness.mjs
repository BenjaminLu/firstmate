// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [click] [relang]
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges,ack}],
//     charted:[{title,sub,badges,pickable,ack}], empty, more,
//     cards:[{badges,title,ctx:[{k,v}],options:[{label,consequence,rec}],chips,ack,
//             hidden, tabs:[{label,selected}],
//             panels:[{hidden,figures,notes,rows,label,cost,
//                      buttons:[{text,queues}]}],
//             on_enter, on_enter_all,
//             packet:{lang,headings,items,links}|null}],
//     headings:[call,charted,underway,landed], error, intervals }
// `intervals` is how many of the page's own tickers are still live once the
// script has run. Set BOARD_REPAINTS=<n> to re-run the shipped script n more
// times on the same page, which is what a repaint does: the count must not
// grow with n, or the board gets heavier every time it is repainted.
// An `ack` is {label, kind, why} or null. It rides only the two surfaces the
// captain clicks - a Captain's Call card and a Charted Next row - so an
// Underway row reads it back as null, which is itself worth asserting.
//
// A second argument replays a captain click before the page is read, so the
// immediate acknowledgement is asserted through the real handler rather than
// by reading the template's source:
//   dispatch            check every pickable Charted Next row, then send
//   answer              submit the dealt Captain's Call card
//   answer-then-paging  submit the dealt card, page two cards on by hand, then
//                       let the deal timer the answer armed fire
// A third argument (en|hant|hans) then clicks that language button, so what
// survives a re-render is asserted through the real control the captain has.
// Set BOARD_REBUILD=<another built board.html> to load a DIFFERENT build of
// the same board into the same page and storage after the click, which is what
// a republication does to a captain who has clicked but not yet sent.
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
  dispatch(type, ev) {
    (this._on[type] || []).slice()
      .forEach((fn) => fn.call(this, ev || { preventDefault() {} }));
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
// The page remembers what the captain clicked so a re-render can put the
// acknowledgement back; that memory is browser storage, so the shim has one.
const storage = new Map();
// A board opened WITHOUT the surface that serves it has no answer channel at
// all - queuePrompt is simply absent. That is a real state the captain can be
// in, not a hypothetical, so the shim can reproduce it.
const noChannel = process.env.BOARD_NO_ANSWER_CHANNEL === "1";
// The seam the live transport exposes, which is the one that exists on the
// captain's own machine. BOARD_LIVE_SEAM=connected|disconnected selects it;
// unset leaves only the serving surface's seam, as before.
const liveSeam = process.env.BOARD_LIVE_SEAM || "";
const liveAnswers = [];
globalThis.window = {
  ...(liveSeam ? {
    fmBoardLive: {
      canAnswer: () => liveSeam === "connected",
      answer: (picks) => { liveAnswers.push(picks); return liveSeam === "connected"; },
    },
  } : {}),
  ...(noChannel ? {} : {
    lavish: { queuePrompt: (text, opts) => queued.push({ text, data: opts && opts.data }) },
  }),
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
// The deck deals the next card on a timer. Timers are queued rather than run,
// so the acknowledgement read below is the click's own effect; a click mode
// that is about the deal itself drains the queue deliberately.
const timers = [];
globalThis.setTimeout = (fn) => timers.push(fn);
globalThis.clearTimeout = (id) => { if (id) timers[id - 1] = null; };
const runTimers = () => {
  for (let i = 0; i < timers.length; i += 1) {
    const fn = timers[i];
    timers[i] = null;
    if (fn) fn();
  }
};
// The pills age on an interval the page owns. Nothing here advances it: each
// read below is one instant, and an aged acknowledgement is produced by an
// older stamp rather than by winding a clock on. What the shim does keep is a
// count of the LIVE ones, because a repaint re-runs the script and a ticker
// with no teardown would leave one more behind on every repaint - each holding
// its own detached copy of the page.
const intervals = new Map();
let intervalSeq = 0;
globalThis.setInterval = (fn, ms) => { intervalSeq += 1; intervals.set(intervalSeq, { fn, ms }); return intervalSeq; };
globalThis.clearInterval = (id) => { intervals.delete(id); };

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();
// A repaint is this same shipped script running again on the same page, so
// that is exactly what BOARD_REPAINTS does. The `intervals` figure printed
// below is then a measurement across that many runs rather than a claim about
// one, which is the only way to show that nothing accumulates.
const repaints = Number(process.env.BOARD_REPAINTS || 0);
for (let i = 0; i < repaints; i += 1) new Function(script)();

/* Replay one captain click through the real handler before the page is read. */
const nodesWhere = (root, pred) => {
  const out = [];
  const walk = (n) => { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } };
  walk(root);
  return out;
};
// The deck deals the first card that still needs an answer, and that is the
// only one on screen, so the first form is the card under the captain's hand.
const answerDealtCard = () => {
  const dealt = nodesWhere(byId.get("bb-call"), (n) => n.tagName === "form")[0];
  if (!dealt) return;
  const radio = nodesWhere(dealt, (n) => n.tagName === "input" && n.type === "radio")[0];
  if (radio) radio.checked = true;
  dealt.dispatch("submit", { preventDefault() {} });
};
const click = process.argv[3] || "";
if (click === "dispatch") {
  const picks = nodesWhere(byId.get("bb-charted"), (n) => n.className.split(/\s+/).includes("bb-pick"));
  for (const p of picks) { p.checked = true; p.dispatch("change"); }
  const btn = byId.get("bb-dispatch-btn");
  if (typeof btn.onclick === "function") btn.onclick();
} else if (click === "answer") {
  answerDealtCard();
} else if (click === "answer-then-paging") {
  answerDealtCard();
  const next = byId.get("bb-stack-next");
  next.onclick(); next.onclick();
  runTimers();
} else if (click) {
  throw new Error("unknown click: " + click);
}

/* Then, optionally, a REBUILD of the board: a different build of the same
   board, loaded into the same page with the same browser storage, exactly as
   a republication reaches a captain who has clicked but not yet sent. The
   click above is deliberately not captured first, because that is the window
   this models - a click reaches firstmate only when Lavish's send is pressed,
   so a board rebuilt before that carries no acknowledgement for it and the
   pill can only come from what this page remembered. */
const rebuild = process.env.BOARD_REBUILD || "";
if (rebuild) {
  const html2 = readFileSync(rebuild, "utf8");
  dataNode.textContent = html2
    .split('<script id="bearings-data" type="application/json">')[1]
    .split("</script>")[0];
  new Function(html2.slice(html2.indexOf("<script>") + "<script>".length, html2.lastIndexOf("</script>")))();
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
        lang: box.attributes.lang ?? "",
        /* the as-written block as the page actually built it: a heading per
           section, the items under it, and the links they named */
        headings: findAll(box, "pk-part__h").map((h) => h.textContent),
        items: findAll(box, "bb-packet__list").map((ul) =>
          ul.children.map((li) => li.textContent)),
        links: findAll(box, "bb-packet__link").map((a) => ({ text: a.textContent, url: a.href })),
      };
    })(),
    ack: ackOf(card.children.find((c) => c.className.includes("bb-decision__pad"))),
    /* What the card says when it refused to send, and whether it marked
       itself answered. A card that could not reach firstmate must show the
       first and must NOT do the second. */
    limit: findAll(card, "bb-limit")
      .filter((n) => n.className.includes("is-visible"))
      .map((n) => n.textContent)[0] ?? "",
    is_queued: card.className.split(/\s+/).includes("is-queued"),
    hidden: card.hidden === true,
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
const dispatchBar = byId.get("bb-dispatch") || new Node("div");
const dispatchLimit = byId.get("bb-dispatch-limit");
const dispatch = {
  is_queued: dispatchBar.className.split(/\s+/).includes("is-queued"),
  count: byId.get("bb-dispatch-count")?.textContent ?? "",
  /* The bar's own refusal: its text, whether it is actually shown, and
     whether anything would announce it. A refusal routed into the counter
     slot would show up here as an empty limit with a wordy count. */
  limit: dispatchLimit?.className?.includes("is-visible") ? dispatchLimit.textContent : "",
  limit_role: dispatchLimit?.attributes?.role ?? "",
};
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, cards, headings, error: errorText,
    dispatch, live_answers: liveAnswers, intervals: intervals.size }) + "\n");
