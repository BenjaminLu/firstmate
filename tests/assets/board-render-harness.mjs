// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [click] [relang]
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges,ack}],
//     charted:[{title,sub,badges,pickable,ack}], empty, more,
//     cards:[{badges,title,ctx:[{k,v}],options:[{label,consequence,rec}],chips,ack,
//             hidden, thin_note, tabs:[{label,selected}],
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
  removeChild(n) {
    const i = this.children.indexOf(n);
    if (i >= 0) this.children.splice(i, 1);
    if (n.parentNode === this) n.parentNode = null;
    return n;
  }
  /* The SVG text measurement the board asks for. A real browser returns the
     rendered advance width; this shim cannot lay out glyphs, so it returns the
     same per-character approximation the board falls back to, which keeps the
     suite exercising the MEASURING path rather than a second code path of its
     own. It is deliberately not exact - what the tests hold is that a name is
     judged by its own width rather than by a fixed box. */
  /* Latin at this font and size measures about 6.3px per character and 繁體
     and 简体 about 9.6px, both taken in a browser against the board's own
     label class. Modelling every script at the English width is how the suite
     could not see that the fallback was 1.5x short in the locale the captain
     reads, so the shim charges CJK its own rate. */
  getComputedTextLength() {
    var wide = (this.textContent.match(/[\u3400-\u9fff\uf900-\ufaff\uff00-\uffef]/g) || []).length;
    return wide * 9.6 + (this.textContent.length - wide) * 6.3;
  }
  /* The em box, which is what a browser reports: a constant of the font size
     rather than of the string, measured at 9.69 above the baseline and 2.02
     below it. */
  getBBox() {
    const y = this.attributes && this.attributes.y !== undefined
      ? parseFloat(this.attributes.y) : 0;
    return { width: this.getComputedTextLength(), height: 11.71, x: 0, y: y - 9.69 };
  }
  setAttribute(k, v) {
    this.attributes[k] = v;
    /* A real SVGElement has no writable className, so the page sets its class
       through setAttribute - and a real querySelectorAll still matches it.
       Mirroring it here keeps both true of the shim. */
    if (k === "class") this.className = String(v);
  }
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
/* A reason code the copy table has no words for cannot be put in a BUILT
   board - the payload contract restricts the field to the eight it knows - so
   the only way to drive the page's guard is to change the code after the build
   and before the page reads it. That is also exactly the situation the guard
   exists for: the contract and the copy table are in different files, and a
   code added to one is not forced through the other. */
if (process.env.BOARD_MERGE_REASON) {
  const patched = JSON.parse(dataNode.textContent);
  for (const row of patched.merge_queue || []) {
    if (!row.ready) row.reason = process.env.BOARD_MERGE_REASON;
  }
  dataNode.textContent = JSON.stringify(patched);
}
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  /* The decision map is SVG, which the page must build in the SVG namespace.
     The shim keeps no namespaces, so the node is the same - what matters is
     that the call exists, because a page that cannot make one draws no map. */
  createElementNS: (_ns, tag) => new Node(tag),
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
// A board with no answer channel at all is a real state the captain can be in,
// not a hypothetical, so the shim can reproduce it.
const noChannel = process.env.BOARD_NO_ANSWER_CHANNEL === "1";
// THERE IS ONE SEAM NOW, and this is it: window.fmBoardLive, what the live
// transport exposes on the captain's own machine. The serving surface's
// queuePrompt seam is gone from the board, so the shim no longer offers it -
// a harness that kept it would be testing a channel the product does not have,
// and every case reached through it would prove nothing about the board the
// captain opens.
// BOARD_LIVE_SEAM=connected|disconnected|flaky selects its state explicitly;
// BOARD_NO_ANSWER_CHANNEL=1 removes it; unset means connected, because that is
// the ordinary case.
const liveSeam = process.env.BOARD_LIVE_SEAM || (noChannel ? "" : "connected");
const liveAnswers = [];
globalThis.window = {
  ...(liveSeam ? {
    fmBoardLive: {
      canAnswer: () => liveSeam === "connected" || liveSeam === "flaky",
      answer: (picks) => {
        liveAnswers.push(picks);
        // Reported in the shape this harness already reads answers in, built
        // only from what the page actually sent: the seam's own payload,
        // renamed to the fields the reporters below expect.
        queued.push({
          text: picks.label,
          data: {
            question: picks.key,
            selection: picks.selection,
            note: picks.note,
            ...(picks.close === undefined ? {} : { close: picks.close }),
          },
        });
        return liveSeam === "connected";
      },
    },
  } : {}),
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
  /* A browser does not submit a form through a DISABLED submit button, so
     neither may this. The same rule the Enter path and the dispatch button
     already follow: a harness that can press what a person cannot will hide
     the next silent control the way it hid the last one. */
  const submit = nodesWhere(dealt, (n) => n.tagName === "button" && n.type === "submit")[0];
  if (submit && submit.disabled === true) return;
  const radio = nodesWhere(dealt, (n) => n.tagName === "input" && n.type === "radio")[0];
  if (radio) radio.checked = true;
  dealt.dispatch("submit", { preventDefault() {} });
};
/* Pressing the card's own button with NOTHING chosen and nothing typed, which
   is what a captain does who presses before he has decided. The button is live
   and the board is healthy, so this is a press that must be answered. */
const answerDealtCardEmpty = () => {
  const dealt = nodesWhere(byId.get("bb-call"), (n) => n.tagName === "form")[0];
  if (!dealt) return;
  const submit = nodesWhere(dealt, (n) => n.tagName === "button" && n.type === "submit")[0];
  if (submit && submit.disabled === true) return;
  dealt.dispatch("submit", { preventDefault() {} });
};
/* Ticking rows past the 512-byte limit. The tick the captain just made
   disappears, so the bar owes him a reason - and that reason must land in the
   alert, not in the counter slot where his own count normally sits. */
const pickPastLimit = () => {
  const picks = nodesWhere(byId.get("bb-charted"), (n) => n.className.split(/\s+/).includes("bb-pick"));
  for (const p of picks) { p.checked = true; p.dispatch("change"); }
};
/* Tick past the limit, then take every tick back - what a captain does when he
   is told he picked too much. The refusal he earned describes an action he has
   since undone, so it must not survive the undo. */
const pickPastLimitThenClear = () => {
  pickPastLimit();
  const picks = nodesWhere(byId.get("bb-charted"), (n) => n.className.split(/\s+/).includes("bb-pick"));
  for (const p of picks) { if (p.checked) { p.checked = false; p.dispatch("change"); } }
};
const click = process.argv[3] || "";
if (click === "pick-past-limit-then-clear") {
  pickPastLimitThenClear();
} else if (click === "pick-past-limit") {
  pickPastLimit();
} else if (click === "answer-empty") {
  answerDealtCardEmpty();
} else if (click === "dispatch") {
  const picks = nodesWhere(byId.get("bb-charted"), (n) => n.className.split(/\s+/).includes("bb-pick"));
  for (const p of picks) { p.checked = true; p.dispatch("change"); }
  const btn = byId.get("bb-dispatch-btn");
  /* A browser does not fire a click on a DISABLED button, and neither may
     this. Pressing what a person cannot press is how a control that greys
     itself out and explains nothing passed its own test: the assertion for
     the refusal and the assertion for the disable described two states that
     cannot both exist on screen, and the captain got the silent one. */
  if (btn.disabled !== true && typeof btn.onclick === "function") btn.onclick();
} else if (click === "answer") {
  answerDealtCard();
} else if (click === "answer-then-paging") {
  answerDealtCard();
  const next = byId.get("bb-stack-next");
  next.onclick(); next.onclick();
  runTimers();
} else if (click.startsWith("map:")) {
  /* Pressing a bubble on the decision map. It is the picture's whole claim to
     be a control rather than a decoration, so it is driven through the page's
     own listener like every other click here. */
  const key = click.slice(4);
  const bub = byId.get("bb-map").querySelectorAll(".bb-bub")
    .find((g) => g.attributes["data-key"] === key);
  if (!bub) throw new Error("no bubble for key: " + key);
  bub.dispatch("click");
} else if (click) {
  throw new Error("unknown click: " + click);
}

/* What the cards looked like AT THE PRESS, before anything else touched them.
   The `on_enter` probe below submits each card's form to report what Enter
   would send, and a probe that succeeds clears the alert the scripted click
   had just written - so a test reading `.limit` afterwards sees the probe's
   result rather than the captain's press. This snapshot is the press itself. */
const atClick = (byId.get("bb-call") || new Node("div")).children.map((c) => ({
  limit: c.querySelectorAll(".bb-limit")
    .filter((n) => n.className.includes("is-visible"))
    .map((n) => n.textContent)[0] ?? "",
  is_queued: c.className.split(/\s+/).includes("is-queued"),
}));

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
  // A browser does not submit a form through a DISABLED submit button, and
  // implicit submission from a text field is blocked with it too. The shim
  // pressed anyway, which would hide a card that correctly refuses up front
  // by letting the send-time path overwrite what it said.
  const defaultBtn = nodes.find((n) => n.tagName === "button" && n.type === "submit");
  if (note && !(defaultBtn && defaultBtn.disabled === true)) {
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
  /* The per-option buttons inside a packet card. Third press site in this
     file, and the same rule as the other two: a browser does not click a
     DISABLED button, so probing one produces a message no viewer can reach -
     here, the send-time refusal written over the render-time one the card had
     correctly shown. A disabled button reports no queued answer, which is what
     a person pressing it would get. */
  nodes
    .filter((n) => n.tagName === "button" && n.parentNode
      && n.parentNode.className.split(/\s+/).includes("bb-panel"))
    .forEach((b) => {
      b._queued = b.disabled === true ? null : record(() => b.dispatch("click"));
    });
};
deck.children.forEach(answerCard);

const cards = deck.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => ({
    badges: findAll(card, "fm-badge").map((b) => b.textContent),
    title: findAll(card, "bb-decision__title")[0]?.textContent ?? "",
    detail: findAll(card, "bb-decision__detail").map((n) => n.textContent),
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
    /* The per-option buttons inside a packet card. They are controls like any
       other and must become unavailable with the rest of the card, so both
       their labels and whether a person could press them are reported. */
    choose_buttons: findAll(card, "fm-btn")
      .filter((b) => b.type === "button" && b.textContent.length)
      .map((b) => ({ text: b.textContent, disabled: b.disabled === true })),
    /* What a call that carried no options says in place of them. Empty on
       every ordinary card, which is what makes its presence meaningful. */
    thin_note: findAll(card, "bb-thin").map((n) => n.textContent)[0] ?? "",
    /* Whether the captain could press at all. A card that cannot send must
       say so before he composes an answer, not after he presses. */
    send_disabled: findAll(card, "fm-btn").some((b) => b.type === "submit" && b.disabled === true),
    hidden: card.hidden === true,
  }));
/* The decision map: one entry per bubble, in document order, plus the ranked
   list beneath it. Read off the built SVG rather than recomputed here, so a
   test cannot agree with a formula this file got wrong too. */
const mapHost = byId.get("bb-map") || new Node("div");
const listHost = byId.get("bb-calllist") || new Node("div");
const bubbles = findAll(mapHost, "bb-bub").map((g) => {
  const circle = g.children.find((c) => c.tagName === "circle") ?? {};
  /* Two kinds of text can sit in a bubble and either may be absent, so they are
     told apart by what they are rather than by their order: the stalled count
     is drawn inside the mark and carries its own fill, the name is drawn beside
     it and does not. A bubble sitting on another has no name at all. */
  const texts = g.children.filter((c) => c.tagName === "text");
  const countNode = texts.find((n) => n.attributes?.fill);
  const labelNode = texts.find((n) => !n.attributes?.fill);
  return {
    key: g.attributes?.["data-key"] ?? "",
    label: labelNode?.textContent ?? "",
    count: countNode?.textContent ?? "",
    cx: Number(circle.attributes?.cx ?? 0),
    cy: Number(circle.attributes?.cy ?? 0),
    r: Number(circle.attributes?.r ?? 0),
    fill: circle.attributes?.fill ?? "",
    selected: (g.attributes?.class ?? "").includes("is-sel"),
    /* Where the bubble's own label was drawn. A label may be moved to keep a
       crowded plot readable; the bubble may not, because its position is the
       information. Both are reported so a test can hold that line. */
    label_y: Number(labelNode?.attributes?.y ?? 0),
    /* Where the name is anchored. A name that does not fit centred may be
       anchored at its own mark and run inward, so a test checking where a name
       actually lies has to know which end of it sits on the mark. */
    label_anchor: labelNode?.attributes?.["text-anchor"] ?? "",
    /* A broken outline is how the plot says nobody assessed this call. */
    dashed: (circle.attributes?.["stroke-dasharray"] ?? "") !== "",
    aria: g.attributes?.["aria-label"] ?? "",
  };
});
const callList = findAll(listHost, "bb-clrow").map((b) => ({
  key: b.attributes?.["data-key"] ?? "",
  text: b.textContent,
  selected: (b.attributes?.class ?? "").includes("is-sel"),
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
  btn_disabled: byId.get("bb-dispatch-btn")?.disabled === true,
  limit_role: dispatchLimit?.attributes?.role ?? "",
};
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, cards, headings, error: errorText,
    dispatch, live_answers: liveAnswers, intervals: intervals.size,
    at_click: atClick,
    map: bubbles, call_list: callList, map_note: byId.get("bb-map-note")?.textContent ?? "",
    /* The fleet as lanes: the label, the count it shows, and which workers it
       holds. The "could not be placed" column is read the same way as any
       other, because the whole point of it is that it is visible. */
    /* Every worker row in full. The lane view reports only names, so until now
       nothing in the suite could see the row's state badge or its kind - which
       is where the internal vocabulary was showing. An unobservable surface is
       an unasserted one in both directions. */
    raw_rows: (byId.get("bb-underway") || new Node("div")).querySelectorAll(".bb-row")
      .map((r) => r.textContent),
    lanes: (byId.get("bb-underway") || new Node("div")).querySelectorAll(".bb-lane")
      .map((l) => ({
        label: l.querySelectorAll(".bb-lane__label")[0]?.textContent ?? "",
        count: l.querySelectorAll(".bb-lane__n")[0]?.textContent ?? "",
        workers: l.querySelectorAll(".bb-row__title").map((n) => n.textContent),
        unplaced: l.className.includes("bb-lane--unplaced"),
      })),
    merge: {
      hidden: byId.get("bb-merge-section")?.hidden === true,
      head: byId.get("bb-merge-head")?.textContent ?? "",
      rows: (byId.get("bb-merge-queue") || new Node("div")).querySelectorAll(".bb-mqrow")
        .map((r) => ({
          text: r.textContent,
          ready: r.className.includes("bb-mqrow--ready"),
          url: r.children.find((c) => c.tagName === "a")?.href ?? "",
        })),
    } }) + "\n");
