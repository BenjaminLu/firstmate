/* Live transport for the bearings board.
 *
 * THE BOARD IS NOT RE-AUTHORED HERE. Everything the captain sees - markup,
 * stylesheet, copy, card types, badges, packet and its figures, pickers, the
 * language switch - comes from the shipped template
 * (.agents/skills/bearings/assets/board-template.html) and is rendered by that
 * template's OWN script. This file carries only what a live surface must do
 * that a built page does not: subscribe, and say what it knows about its own
 * freshness. Adding anything that renders board content here would recreate
 * the hand-written second copy that silently lost features last time.
 *
 * ANSWERS ARE NOT TOUCHED. The board sends every answer through
 * window.lavish.queuePrompt, which the surface serving this page provides, and
 * this file neither implements nor intercepts it. Carrying answers back to
 * firstmate is a separate owner's job and works exactly as it did before.
 *
 * THE CAPTAIN'S UNSENT WORK OUTRANKS A FRESH PAYLOAD. Repainting runs the
 * shipped renderer, which throws away everything on the page, so an update is
 * HELD while he has touched something and not yet sent it - a card he is
 * answering, a dispatch tick he has not queued - and the page says so until
 * that work is sent or left behind.
 *
 * A BOARD THAT RENDERS IS NEVER REPLACED BY ONE THAT DOES NOT. An arriving
 * payload is judged by the only authority on what this board can render: the
 * shipped board itself. The payload is drawn and the board's own verdict is
 * read off the page afterwards - it builds its sections when it accepted the
 * payload and replaces them with a single error card when it did not. A
 * payload that does not render is undone, the last one that did is drawn
 * again, and the page says the update was rejected. No rule of the board's is
 * restated here, so this cannot drift from it.
 *
 * WHAT "LIVE" IS ALLOWED TO MEAN, AND WHAT IT IS NOT. Every message carries
 * the WHOLE board rather than a delta, so a message this page never received
 * cannot leave it subtly wrong - the next one it receives is complete, and a
 * reconnecting page is sent the current state before anything else. That is
 * the guarantee, and it is the reason a delta protocol was not built.
 * What it does NOT cover is a change the fleet cannot express without new
 * prose, above all a new captain's call: the server marks the board behind and
 * names what changed, and this page says a rebuild is owed rather than letting
 * a complete-looking board stand in for one that is missing a question.
 *
 * bin/fm-bearings-board.sh composes this file into the built board; it is not
 * loaded on its own.
 */
(function () {
  "use strict";

  /* The endpoint bin/fm-bearings-board.sh injected at build time. A page built
     in a home with no server still renders: it paints from the payload built
     into it and says it is not updating. */
  var ENDPOINT = "__FM_BOARD_LIVE_ENDPOINT__";
  var SLOT_ID = "bearings-data";
  var SELF_ID = "fm-board-live";

  /* The board's markup as parsed, BEFORE the shipped script has rendered into
     it. Capturing it here - above the data slot, below every element - is why
     this file is injected where it is: a repaint restores this and re-runs the
     shipped script, so re-rendering can never drift from first paint, and the
     board's own error card can be undone. Everything after this script's own
     opening tag is this file, so it is cut off rather than carried along. */
  var PRISTINE = (function () {
    var html = document.body.innerHTML;
    var cut = html.lastIndexOf('<script id="' + SELF_ID + '"');
    return cut >= 0 ? html.slice(0, cut) : html;
  })();

  /* The shipped board script, read from the page rather than embedded, so this
     file carries no second copy of it to fall behind the template. */
  var BOARD_SRC = null;

  var STRIP_ID = "bb-live-status";
  var LINK_ID = "bb-live-link";
  var BEHIND_ID = "bb-live-behind";
  var linkState = "connecting";
  var arrivedAt = null;
  var lastSeq = -1;

  /* The only copy this file owns: the connection, and the one thing a live
     board can be behind on. It follows the board's own language choice through
     the key the template already stores. */
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
      hant: "沒在更新 — 顯示頁面內建的資料",
      hans: "没在更新 — 显示页面内建的资料"
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
    }
  };
  var TONE = {
    connecting: "neutral", live: "online", holding: "warn",
    offline: "warn", rejected: "danger"
  };

  /* A quiet board is two different things - one that has never heard anything
     and one that heard and then stopped - and only the age tells them apart. */
  var AGE = {
    min: { en: "{n} min", hant: "{n} 分鐘", hans: "{n} 分钟" },
    hour: { en: "{n} h", hant: "{n} 小時", hans: "{n} 小时" }
  };

  /* What a live board cannot do for itself, said plainly rather than implied
     by a board that looks complete. */
  var BEHIND = {
    one: {
      en: "{n} change needs firstmate to rebuild this board",
      hant: "有 {n} 項變更要等 firstmate 重建這塊板",
      hans: "有 {n} 项变更要等 firstmate 重建这块板"
    },
    many: {
      en: "{n} changes need firstmate to rebuild this board",
      hant: "有 {n} 項變更要等 firstmate 重建這塊板",
      hans: "有 {n} 项变更要等 firstmate 重建这块板"
    }
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

  /* The status sits on its own row UNDER the nav, never inside it:
     .bb-nav__inner is a fixed-height flex row and .fm-badge is nowrap, so a
     long status string placed in that row pushes the page wider than a phone
     screen and the language buttons stop being tappable. The board's own
     stylesheet is not touched - these inline properties style this file's OWN
     element so it can wrap. */
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

  var behindCount = 0;

  /* Two facts, and neither may stand in for the other: whether the page is
     still being updated, and whether what it is showing is everything there
     is. A connection that is perfectly healthy while a captain's call is
     missing must not read as a board with nothing on it. */
  function paintStatus() {
    var node = pin(LINK_ID, TONE[linkState] || "neutral");
    if (!node) return;
    node.textContent = linkCopy();
    if (behindCount > 0) {
      var behind = pin(BEHIND_ID, "danger");
      behind.textContent = say(behindCount === 1 ? BEHIND.one : BEHIND.many)
        .replace("{n}", String(behindCount));
      behind.hidden = false;
    } else {
      var existing = document.getElementById(BEHIND_ID);
      if (existing) existing.hidden = true;
    }
  }

  function setLink(next) {
    linkState = next;
    paintStatus();
  }

  function runBoard() {
    if (BOARD_SRC === null) return;
    var s = document.createElement("script");
    s.textContent = BOARD_SRC;
    document.body.appendChild(s);
  }

  var showing = null;

  function draw(payload) {
    document.body.innerHTML = PRISTINE;
    var slot = document.createElement("script");
    slot.id = SLOT_ID;
    slot.type = "application/json";
    slot.textContent = JSON.stringify(payload);
    document.body.appendChild(slot);
    runBoard();
    paintStatus();
    return !!document.getElementById("bb-stats") && !!document.getElementById("bb-call");
  }

  function paint(payload) {
    if (!draw(payload)) {
      if (showing !== null) draw(showing);
      return false;
    }
    showing = payload;
    arrivedAt = new Date().getTime();
    return true;
  }

  /* ---- unsent work, as the page itself shows it -------------------------
   * Both signals are the template's OWN - a form it tagged with
   * data-lavish-question, and its dispatch bar - never a shape this file
   * invents, and both are read the same way: visible, and carrying something
   * not yet sent. That is also what bounds a hold, since the deck hides a card
   * once it deals the next one and the bar marks itself queued once its order
   * goes.
   */
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

  function accept(message) {
    behindCount = (message.stale && message.stale.length) || 0;
    if (answerInProgress()) {
      held = message;
      setLink("holding");
      return;
    }
    held = null;
    if (message.payload === null) {
      /* The server has no board to serve - nothing has been built in this home
         yet. The page keeps what it was built with rather than blanking. */
      setLink("offline");
      return;
    }
    if (!paint(message.payload)) {
      setLink("rejected");
      return;
    }
    setLink("live");
  }

  /* Any touch of the page can be the moment an answer stops being in progress,
     and a submit marks its card answered only after its own handler runs, so
     the recheck is deferred to the next turn. */
  function recheckHeld() {
    if (held === null) return;
    var message = held;
    setTimeout(function () {
      if (held === message && !answerInProgress()) accept(message);
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
     dropped link is read long after that. This repaints what is already known;
     it never asks the server for anything. */
  setInterval(paintStatus, 60000);

  /* ---- the subscription -------------------------------------------------
   * One socket, reopened with a backoff when it drops. The page is correct
   * while it is down - it shows what it last drew and says it is not updating
   * - and correct again the moment it is back, because the server's first
   * message on any connection is the whole current state.
   */
  var backoff = 500;
  var socket = null;

  function connect() {
    if (!ENDPOINT || ENDPOINT.indexOf("ws") !== 0) { setLink("offline"); return; }
    if (typeof window.WebSocket !== "function") { setLink("offline"); return; }
    try {
      socket = new window.WebSocket(ENDPOINT);
    } catch (e) {
      setLink("offline");
      retry();
      return;
    }
    socket.onopen = function () { backoff = 500; };
    socket.onmessage = function (ev) {
      var message;
      try {
        message = JSON.parse(ev.data);
      } catch (e) {
        return;
      }
      if (!message || message.type !== "state") return;
      /* Every message is the whole board, so an older one arriving late can
         only take the page backwards. */
      if (typeof message.seq === "number" && message.seq <= lastSeq) return;
      if (typeof message.seq === "number") lastSeq = message.seq;
      accept(message);
    };
    socket.onclose = function () { setLink("offline"); retry(); };
    socket.onerror = function () { /* onclose follows and owns the retry */ };
  }

  function retry() {
    setTimeout(connect, backoff);
    backoff = Math.min(backoff * 2, 30000);
  }

  /* The shipped script runs between this file and DOMContentLoaded, so its
     source is read once the document is parsed - from the page, never from a
     copy kept here. Until then a repaint is impossible and none is attempted. */
  function ready() {
    var scripts = document.getElementsByTagName("script");
    for (var i = scripts.length - 1; i >= 0; i--) {
      var s = scripts[i];
      if (s.id || (s.type && s.type !== "text/javascript")) continue;
      BOARD_SRC = s.textContent;
      break;
    }
    paintStatus();
    connect();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", ready);
  } else {
    ready();
  }
})();
