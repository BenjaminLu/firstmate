/* Remote transport for the bearings board.
 *
 * THE BOARD IS NOT RE-AUTHORED HERE. Everything the captain sees - markup,
 * stylesheet, copy, card types, badges, packet and its figures, pickers, the
 * language switch - comes from the shipped template
 * (.agents/skills/bearings/assets/board-template.html) and runs here as that
 * template's OWN script, verbatim. This file carries only what a remote
 * surface must do differently, which is two things: how a payload arrives, and
 * where an answer goes. Adding anything that renders board content here would
 * recreate the hand-written copy this replaced, which silently lost six
 * features before anyone measured it.
 *
 * THE CAPTAIN'S UNSENT WORK OUTRANKS A FRESH PAYLOAD. A live payload repaints
 * the page through the shipped renderer, which throws away everything on it,
 * so this transport never overwrites anything he has touched and not yet sent,
 * wherever on the page he touched it - a card he is answering, a dispatch tick
 * he has not queued. The update is held and the page says so until that work
 * is sent or left behind.
 *
 * A BOARD THAT RENDERS IS NEVER REPLACED BY ONE THAT DOES NOT. Nothing this
 * page can reach validates what a publisher writes to the board's store, so an
 * arriving payload is judged by the only authority on what this board can
 * render - the shipped board itself. The payload is drawn, and the board's own
 * verdict is read off the page afterwards: it builds its sections when it
 * accepted the payload and replaces them with a single error card when it did
 * not. A payload that does not render is undone - the last one that did is
 * drawn again - and the page says the update was rejected. No rule of the
 * board's is restated here, so this cannot drift from it.
 * What that verdict covers is exactly what the shipped board checks: the
 * schema tag, the required lists, and anything its render throws on. What it
 * cannot cover fails closed the same way - a page whose sections are missing
 * for any other reason is treated as not rendered, so the board already on
 * screen stays and the link is never reported live.
 *
 * THE BOARD MAY BE REPAINTED ANY NUMBER OF TIMES AND MUST COST THE SAME
 * EVERY TIME. A page that gets heavier the longer the captain leaves it open
 * is broken even when nothing looks wrong, so a repaint undoes what the
 * previous one registered before it registers anything again.
 *
 * bin/fm-remote-board.sh composes this file with the template; it is not
 * loaded on its own.
 */
(function () {
  "use strict";

  /* The shipped board script, embedded verbatim by bin/fm-remote-board.sh.
     Running it is what makes the remote board render exactly what the local
     board renders, including anything added to the template after this file
     was last touched. */
  var BOARD_SRC = "__FM_BEARINGS_BOARD_SCRIPT__";
  var SLOT_ID = "bearings-data";

  /* The board's markup as parsed, before its own script has rendered into it.
     A fresh payload is painted by restoring this and re-running the shipped
     script, so re-rendering can never drift from first paint. */
  var PRISTINE = document.body.innerHTML;

  var STATUS_ID = "bb-remote-link";
  var STRIP_ID = "bb-remote-status";
  var ANSWER_ID = "bb-remote-answers";
  var linkState = "connecting";
  var sendState = null;
  var receiving = false;
  var arrivedAt = null;

  /* The only copy this file owns: it describes the connection and the answer
     route, the two things the shipped board has no concept of. It follows the
     board's own language choice through the key the template already stores. */
  var SAY = {
    connecting: { en: "connecting…", hant: "連線中…", hans: "连线中…" },
    live: { en: "live", hant: "即時更新", hans: "即时更新" },
    holding: {
      en: "an update is waiting until this answer is sent",
      hant: "有更新在等這個回答送出後才套用",
      hans: "有更新在等这个回答送出后才套用"
    },
    offline: {
      en: "not updating — nothing has arrived, showing the copy built into this page",
      hant: "沒在更新 — 還沒收到任何更新，顯示頁面內建的舊資料",
      hans: "没在更新 — 还没收到任何更新，显示页面内建的旧资料"
    },
    stopped: {
      en: "not updating — last update {age} ago",
      hant: "沒在更新 — 上次更新是 {age} 前",
      hans: "没在更新 — 上次更新是 {age} 前"
    },
    rejected: {
      en: "update rejected — this board cannot read it; showing the last one it could",
      hant: "更新被拒 — 這塊板讀不了它，顯示上一份讀得到的",
      hans: "更新被拒 — 这块板读不了它，显示上一份读得到的"
    },
    unsendable: {
      en: "answers cannot be sent from here",
      hant: "這裡無法送出回答",
      hans: "这里无法送出回答"
    }
  };
  var TONE = {
    connecting: "neutral", live: "online", holding: "warn",
    offline: "warn", rejected: "danger", unsendable: "danger"
  };

  /* A quiet board is two different things - one that has never heard anything
     and one that heard and then stopped - and only the age tells them apart,
     so the line says which it is rather than always naming the built-in copy. */
  var AGE = {
    min: { en: "{n} min", hant: "{n} 分鐘", hans: "{n} 分钟" },
    hour: { en: "{n} h", hant: "{n} 小時", hans: "{n} 小时" }
  };

  /* The answer route back to firstmate is not landed yet, so the page says so.
     Without it a card ticking "queued" reads as an answer that arrived. */
  var ANSWER_GAP = {
    en: "answers stay on this board — carrying them back to firstmate is not landed yet",
    hant: "回答只留在這塊板上 — 送回 firstmate 的路還沒完成",
    hans: "回答只留在这块板上 — 送回 firstmate 的路还没完成"
  };

  function lang() {
    try {
      var stored = window.localStorage && window.localStorage.getItem("fm-bearings-lang");
      if (stored === "en" || stored === "hant" || stored === "hans") return stored;
    } catch (e) { /* private mode */ }
    return document.documentElement.lang === "en" ? "en"
      : (document.documentElement.lang === "zh-Hans" ? "hans" : "hant");
  }

  function say(copy) { return copy[lang()] || copy.en; }

  function age() {
    var mins = Math.max(1, Math.round((new Date().getTime() - arrivedAt) / 60000));
    return mins < 60
      ? say(AGE.min).replace("{n}", String(mins))
      : say(AGE.hour).replace("{n}", String(Math.round(mins / 60)));
  }

  function linkCopy() {
    if (linkState !== "offline" || arrivedAt === null) return say(SAY[linkState] || SAY.connecting);
    return say(SAY.stopped).replace("{age}", age());
  }

  /* The connection line sits on its own row UNDER the nav, never inside it.
     .bb-nav__inner is a fixed-height flex row carrying the brand and the
     language switch, and .fm-badge is nowrap, so a long status string placed in
     that row pushes the row wider than a phone screen: measured at 500px, the
     page overflowed by 483px and a tap on EN / 繁 / 简 landed on the badge
     instead of the button. The board's own stylesheet is not touched - the two
     inline properties below style the transport's OWN element so it can wrap. */
  function strip() {
    var found = document.getElementById(STRIP_ID);
    if (found) return found;
    var nav = document.querySelector(".bb-nav");
    if (!nav) return null;
    var el = document.createElement("div");
    el.id = STRIP_ID;
    el.style.cssText = "display:flex;flex-wrap:wrap;gap:8px;" +
      "max-width:var(--container-app);margin:0 auto;padding:0 28px 8px;";
    nav.appendChild(el);
    return el;
  }

  function pin(id, tone) {
    var host = strip();
    if (!host) return null;
    var node = document.getElementById(id);
    if (!node) {
      node = document.createElement("span");
      node.id = id;
      node.setAttribute("role", "status");
      node.style.whiteSpace = "normal";
      node.style.maxWidth = "100%";
      host.appendChild(node);
    }
    node.className = "fm-badge fm-badge--" + tone;
    return node;
  }

  /* Two facts, two badges, and neither may stand in for the other: whether the
     page is still being updated, and what becomes of an answer given on it. A
     board that quietly shows stale data is the complaint the first answers, so
     a lost connection cannot be hidden by a lost send; and losing the ability
     to send does not heal when a readable payload next arrives, so the second
     is sticky once set. */
  function paintStatus() {
    var node = pin(STATUS_ID, TONE[linkState] || "neutral");
    if (!node) return;
    node.textContent = linkCopy();
    var answers = pin(ANSWER_ID, sendState ? TONE[sendState] : "warn");
    answers.textContent = sendState ? say(SAY[sendState]) : say(ANSWER_GAP);
  }

  function setLink(newState) {
    linkState = newState;
    paintStatus();
  }

  function setSend(newState) {
    sendState = newState;
    paintStatus();
  }

  /* A repaint re-runs the shipped board script, and re-running a script that
     registers things is only safe if the run before it is undone first. The
     other option - updating the page without re-running - is not available
     here: the board's render logic is private to its own IIFE, which is exactly
     what embedding it verbatim buys, so there is nothing to call. So the re-run
     tears down what the previous run registered.

     Only what OUTLIVES the repaint is tracked: timers, and listeners on
     document or window. Listeners the board puts on its own forms, buttons and
     rows go when those nodes are replaced, so tracking them would be noise. */
  var registered = { timers: [], listeners: [] };

  function undoPreviousRun() {
    registered.timers.forEach(function (t) {
      if (t.repeating) { if (typeof clearInterval === "function") clearInterval(t.id); }
      else if (typeof clearTimeout === "function") clearTimeout(t.id);
    });
    registered.listeners.forEach(function (l) {
      if (l.target.removeEventListener) l.target.removeEventListener(l.type, l.fn, l.opts);
    });
    registered = { timers: [], listeners: [] };
  }

  function runBoard() {
    undoPreviousRun();

    /* Shim the global the board's own bare setTimeout/setInterval calls resolve
       to. In a browser that global IS window; under a test harness it need not
       be, and shimming only window would quietly install nothing. */
    var g = typeof globalThis !== "undefined" ? globalThis : window;
    var real = {
      g: g,
      setInterval: g.setInterval,
      setTimeout: g.setTimeout,
      docAdd: document.addEventListener,
      winAdd: window.addEventListener
    };
    function timerShim(fn, repeating) {
      return function () {
        var id = fn.apply(real.g, arguments);
        registered.timers.push({ id: id, repeating: repeating });
        return id;
      };
    }
    function listenerShim(target, fn) {
      return function (type, handler, opts) {
        registered.listeners.push({ target: target, type: type, fn: handler, opts: opts });
        return fn.call(target, type, handler, opts);
      };
    }
    if (real.setInterval) g.setInterval = timerShim(real.setInterval, true);
    if (real.setTimeout) g.setTimeout = timerShim(real.setTimeout, false);
    if (real.docAdd) document.addEventListener = listenerShim(document, real.docAdd);
    if (real.winAdd) window.addEventListener = listenerShim(window, real.winAdd);

    try {
      /* Appending a script element executes it; the shipped source stays one
         copy, used for first paint and for every repaint after it. */
      var s = document.createElement("script");
      s.textContent = BOARD_SRC;
      document.body.appendChild(s);
    } finally {
      if (real.setInterval) real.g.setInterval = real.setInterval;
      if (real.setTimeout) real.g.setTimeout = real.setTimeout;
      if (real.docAdd) document.addEventListener = real.docAdd;
      if (real.winAdd) window.addEventListener = real.winAdd;
    }
  }

  /* Only for the regression that proves the rule above: how much the last run
     left behind. A number that grows across repaints is the leak. */
  (typeof globalThis !== "undefined" ? globalThis : window).__fmBoardRegistrations =
    function () {
      return registered.timers.length + registered.listeners.length;
    };

  var showing = null;

  function draw(payload) {
    document.body.innerHTML = PRISTINE;
    if (payload !== null) {
      document.getElementById(SLOT_ID).textContent = JSON.stringify(payload);
    }
    runBoard();
    paintStatus();
    return !!document.getElementById("bb-stats") && !!document.getElementById("bb-call");
  }

  function paint(payload) {
    if (!draw(payload)) {
      draw(showing);
      return false;
    }
    showing = payload;
    arrivedAt = new Date().getTime();
    return true;
  }

  /* ---- unsent work, as the page itself shows it -------------------------
   * The rule is stated at the top of this file; this is how the page is read
   * for it. Both signals are the template's own - a form it tagged with
   * data-lavish-question, and its dispatch bar - never a shape this file
   * invents, and both are read the same way: visible, and carrying something
   * not yet sent. That is also what bounds a hold, since the deck hides a card
   * once it deals the next one and the bar marks itself queued once its order
   * goes. */
  var held = null;

  function answerInProgress() {
    var forms = document.querySelectorAll("form[data-lavish-question]");
    for (var i = 0; i < forms.length; i++) {
      var form = forms[i];
      var card = form.closest ? form.closest(".bb-decision") : null;
      if (!card || card.hidden) continue;
      /* An answered card keeps its selection, so it must stop counting as in
         progress or the first answer would hold every later update forever. */
      if (card.className.indexOf("is-queued") >= 0) continue;
      if (form.querySelector("input[type=radio]:checked")) return true;
      var note = form.querySelector(".bb-freeform");
      if (note && note.value && note.value.trim()) return true;
      if (document.activeElement && form.contains(document.activeElement)) return true;
    }
    var bar = document.getElementById("bb-dispatch");
    return !!(bar && !bar.hidden && bar.className.indexOf("is-queued") < 0 &&
      document.querySelector(".bb-pick:checked"));
  }

  function accept(payload) {
    if (answerInProgress()) {
      held = payload;
      setLink("holding");
      return;
    }
    held = null;
    if (!paint(payload)) {
      receiving = false;
      setLink("rejected");
      return;
    }
    setLink(receiving ? "live" : "offline");
  }

  /* Any touch of the page can be the moment an answer stops being in progress,
     and a submit marks its card answered only after its own handler runs, so
     the recheck is deferred to the next turn. */
  function recheckHeld() {
    if (held === null) return;
    var payload = held;
    setTimeout(function () {
      if (held === payload && !answerInProgress()) accept(payload);
    }, 0);
  }
  ["input", "change", "submit", "click", "focusout"].forEach(function (type) {
    document.addEventListener(type, recheckHeld, true);
  });
  /* The board's own language buttons are clicks that re-render the page under
     these badges, so the language is re-read once the page has reacted. */
  document.addEventListener("click", function () {
    setTimeout(paintStatus, 0);
  }, true);
  /* An age is only true at the moment it is written, and a page left open on a
     dropped link is read long after that, so the line is rewritten as time
     passes. It repaints what is already known; it never retries the store. */
  setInterval(paintStatus, 60000);

  /* ---- answers out -------------------------------------------------------
   * The shipped board sends every answer - decision, merge, credential, and
   * the dispatch order - through window.lavish.queuePrompt, under keys the
   * template itself supplies. Implementing that one interface on this
   * transport keeps the keys, the card types, and the payload shape identical
   * to the local board's; nothing here knows what a card is.
   * A separate branch owns carrying these answers back to firstmate, which is
   * why the page names that gap rather than letting a ticked card imply it. */
  var db = null;
  var writable = true;
  var pending = [];

  function answerSlot(key) {
    return "answers/" + String(key).replace(/[^A-Za-z0-9_.-]/g, "_");
  }

  function send(key, body) {
    /* Dropped answers must be dropped loudly: once the page knows nothing can
       be written, the badge says so rather than a queue filling silently. */
    if (!writable) return;
    if (!db) { pending.push([key, body]); return; }
    db.doc(answerSlot(key)).set(body).catch(function () {
      writable = false;
      setSend("unsendable");
    });
  }

  function cannotSend() {
    writable = false;
    pending.length = 0;
    linkState = "offline";
    setSend("unsendable");
  }

  window.lavish = window.lavish || {};
  window.lavish.queuePrompt = function (text, opts) {
    var o = opts || {};
    var body = o.data || {};
    var key = o.queueKey || body.question;
    if (!key) return;
    /* The record is what the shipped board emitted, unchanged. This transport
       is a carrier, not an author: the template is the writer of an answer and
       the bearings skill's "The answer record" states that shape once. The key
       addresses the document; it is not added to the answer. An empty
       selection is a written-only answer and is carried, not dropped. */
    send(key, body);
  };

  /* ---- data in ----------------------------------------------------------
   * First paint uses the payload embedded in the page, so the board is correct
   * with no connection at all. A live payload replaces it and repaints through
   * the same shipped renderer. */
  runBoard();
  paintStatus();

  if (window.claude && typeof window.claude.use === "function") {
    window.claude.use("db").then(function (handle) {
      if (!handle) { cannotSend(); return; }
      db = handle;
      while (pending.length) { var q = pending.shift(); send(q[0], q[1]); }
      handle.doc("board/current").onSnapshot(function (snap) {
        var next = snap && snap.exists ? snap.data() : null;
        /* Whether this one can replace what is on screen is the shipped
           board's call, not a rule restated here; an empty slot is the only
           thing answered without asking it. */
        if (next) {
          receiving = true;
          accept(next);
        } else {
          receiving = false;
          setLink("offline");
        }
      }, function () { receiving = false; setLink("offline"); });
    }).catch(function () { cannotSend(); });
  } else {
    cannotSend();
  }
})();
