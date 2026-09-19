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
  var ANSWER_ID = "bb-remote-answers";
  var linkState = "connecting";
  var sendState = null;

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
      en: "not updating — showing the copy built into this page",
      hant: "沒在更新 — 顯示頁面內建的舊資料",
      hans: "没在更新 — 显示页面内建的旧资料"
    },
    unsendable: {
      en: "answers cannot be sent from here",
      hant: "這裡無法送出回答",
      hans: "这里无法送出回答"
    }
  };
  var TONE = {
    connecting: "neutral", live: "online", holding: "warn",
    offline: "warn", unsendable: "danger"
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

  function pin(id, tone) {
    var host = document.querySelector(".bb-nav__inner");
    if (!host) return null;
    var node = document.getElementById(id);
    if (!node) {
      node = document.createElement("span");
      node.id = id;
      node.setAttribute("role", "status");
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
    node.textContent = say(SAY[linkState] || SAY.connecting);
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

  function runBoard() {
    /* Appending a script element executes it; the shipped source stays one
       copy, used for first paint and for every repaint after it. */
    var s = document.createElement("script");
    s.textContent = BOARD_SRC;
    document.body.appendChild(s);
  }

  function paint(payload) {
    document.body.innerHTML = PRISTINE;
    if (payload !== undefined) {
      var slot = document.getElementById(SLOT_ID);
      if (!slot) return;
      slot.textContent = JSON.stringify(payload);
    }
    runBoard();
    paintStatus();
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
    setLink("live");
    paint(payload);
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
    var record = {};
    for (var k in body) { if (Object.prototype.hasOwnProperty.call(body, k)) record[k] = body[k]; }
    record.key = key;
    record.prompt = String(text || "");
    record.at = new Date().toISOString();
    record.lang = lang();
    send(key, record);
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
        /* Only a payload the shipped board can read replaces the embedded one;
           anything else leaves the page showing what it was published with,
           and saying so - a snapshot this page cannot render is not an update. */
        if (next && next.schema === "fm-bearings-board.v1") {
          accept(next);
        } else {
          setLink("offline");
        }
      }, function () { setLink("offline"); });
    }).catch(function () { cannotSend(); });
  } else {
    cannotSend();
  }
})();
