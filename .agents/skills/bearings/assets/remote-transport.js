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
  var linkState = "connecting";

  /* The only copy this file owns: it describes the connection, which is the one
     thing the shipped board has no concept of. It follows the board's own
     language choice through the key the template already stores. */
  var SAY = {
    connecting: { en: "connecting…", hant: "連線中…", hans: "连线中…" },
    live: { en: "live", hant: "即時更新", hans: "即时更新" },
    offline: {
      en: "not updating — showing the copy built into this page",
      hant: "沒在更新 — 顯示頁面內建的舊資料",
      hans: "没在更新 — 显示页面内建的旧资料"
    },
    readonly: {
      en: "read-only — answers cannot be sent from here",
      hant: "唯讀 — 這裡無法送出回答",
      hans: "只读 — 这里无法送出回答"
    }
  };
  var TONE = { connecting: "neutral", live: "online", offline: "warn", readonly: "danger" };

  function lang() {
    try {
      var stored = window.localStorage && window.localStorage.getItem("fm-bearings-lang");
      if (stored === "en" || stored === "hant" || stored === "hans") return stored;
    } catch (e) { /* private mode */ }
    return document.documentElement.lang === "en" ? "en"
      : (document.documentElement.lang === "zh-Hans" ? "hans" : "hant");
  }

  /* A board that quietly shows stale data is the complaint this answers, so the
     connection state is on the page rather than in the console. */
  function paintStatus() {
    var host = document.querySelector(".bb-nav__inner");
    if (!host) return;
    var node = document.getElementById(STATUS_ID);
    if (!node) {
      node = document.createElement("span");
      node.id = STATUS_ID;
      node.setAttribute("role", "status");
      host.appendChild(node);
    }
    node.className = "fm-badge fm-badge--" + (TONE[linkState] || "neutral");
    node.textContent = (SAY[linkState] || SAY.connecting)[lang()] || SAY[linkState].en;
  }

  function setLink(state) {
    linkState = state;
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

  /* ---- answers out -------------------------------------------------------
   * The shipped board sends every answer - decision, merge, credential, and
   * the dispatch order - through window.lavish.queuePrompt, under keys the
   * template itself supplies. Implementing that one interface on this
   * transport keeps the keys, the card types, and the payload shape identical
   * to the local board's; nothing here knows what a card is.
   * A separate branch owns carrying these answers back to firstmate. */
  var db = null;
  var writable = true;
  var pending = [];

  function answerSlot(key) {
    return "answers/" + String(key).replace(/[^A-Za-z0-9_.-]/g, "_");
  }

  function send(key, body) {
    if (!db) { pending.push([key, body]); return; }
    if (!writable) return;
    db.doc(answerSlot(key)).set(body).catch(function () {
      writable = false;
      setLink("readonly");
    });
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
      if (!handle) { setLink("offline"); return; }
      db = handle;
      while (pending.length) { var q = pending.shift(); send(q[0], q[1]); }
      handle.doc("board/current").onSnapshot(function (snap) {
        var next = snap && snap.exists ? snap.data() : null;
        /* Only a payload the shipped board can read replaces the embedded one;
           anything else leaves the page showing what it was published with. */
        if (next && next.schema === "fm-bearings-board.v1") {
          setLink("live");
          paint(next);
        } else {
          setLink("live");
        }
      }, function () { setLink("offline"); });
    }).catch(function () { setLink("offline"); });
  } else {
    setLink("offline");
  }
})();
