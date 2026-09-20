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
 * ANSWERS GO BACK DOWN THE SAME SOCKET, AND THAT IS ALL THIS FILE DOES WITH
 * THEM. The board used to hand every answer to window.lavish.queuePrompt,
 * which the surface serving the page provided; when that surface is not there,
 * the captain presses a button and nothing happens. So this file carries the
 * answer itself, and exposes exactly one seam for the board to call:
 *
 *   window.fmBoardLive.canAnswer()
 *       true when this board can reach firstmate right now.
 *   window.fmBoardLive.answer(picks, whenSettled)
 *       picks is one {key, selection, note, label, close} or a list of them.
 *       key       the board's own routing key for the row
 *       selection the option value the captain chose, or "" when he only typed
 *       note      his typed words, or ""
 *       label     what that option said on the board, so the durable record
 *                 reads the way he read it
 *       close     "done", "release", or omitted - the card's own declared mode
 *       Returns false when it could not even be sent, so the board can say so
 *       rather than looking like it worked. whenSettled, if given, is called
 *       with {status, reason} as the server accepts it and again when it has
 *       landed or failed; status is "accepted", "recorded", "refused" or
 *       "failed".
 *
 * WHAT IT DOES NOT DECIDE. It does not know what a key means, what an answer
 * does, or whether an answer may be given: it puts the captain's pick on the
 * wire and shows him what came back. Everything an answer MEANS is settled
 * where it always was, behind the connection.
 *
 * WHAT COMES BACK IS ALWAYS SHOWN. An answer that was refused, or that the
 * fleet could not record, paints on this file's own status row. A press whose
 * outcome the captain cannot see is the failure this seam exists to remove,
 * and a silent refusal would be that same failure one layer further in.
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
  /* What proves an answer sent from this page is the captain's. It is a
     credential: it is injected into a board written at mode 0600, it is never
     rendered, logged, or put in a link, and it leaves this page only inside a
     message to the loopback endpoint above. */
  var TOKEN = "__FM_BOARD_LIVE_TOKEN__";
  var INBOUND_SCHEMA = "fm-board-inbound.v1";
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
  var SENT_ID = "bb-live-sent";
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
    /* What the two sentences under Captain's Call must say INSTEAD of "nothing
       needs you" while the board knows it is behind. A change the fleet could
       not word IS a captain's call missing from the payload, so at exactly the
       moment the board is behind, the count those sentences are derived from is
       the one number it must not treat as complete. */
    call_sub_behind: {
      en: "this list is not complete — a rebuild is owed",
      hant: "這份清單並不完整 — 還欠一次重建",
      hans: "这份清单并不完整 — 还欠一次重建"
    },
    call_empty_behind: {
      en: "Nothing is listed here, and this board cannot say that is all there is — it is waiting on a rebuild.",
      hant: "這裡沒有列出任何事項，但這塊板無法說那就是全部 — 它還在等一次重建。",
      hans: "这里没有列出任何事项，但这块板无法说那就是全部 — 它还在等一次重建。"
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

  /* What became of a press. Only the three outcomes the captain can act on:
     it is on its way, it is recorded, or it is not - and the last one says so
     rather than leaving the row looking answered. */
  var SENT = {
    sending: {
      en: "sending your answer…",
      hant: "正在送出你的回答…",
      hans: "正在送出你的回答…"
    },
    accepted: {
      en: "answer sent — recording it",
      hant: "回答已送出 — 正在記錄",
      hans: "回答已送出 — 正在记录"
    },
    recorded: {
      en: "answer recorded",
      hant: "回答已記錄",
      hans: "回答已记录"
    },
    refused: {
      en: "your answer was NOT recorded — firstmate refused it",
      hant: "你的回答沒有被記錄 — firstmate 拒絕了它",
      hans: "你的回答没有被记录 — firstmate 拒绝了它"
    },
    failed: {
      en: "your answer was NOT recorded — tell firstmate",
      hant: "你的回答沒有被記錄 — 請告訴 firstmate",
      hans: "你的回答没有被记录 — 请告诉 firstmate"
    },
    unreachable: {
      en: "your answer was NOT sent — this board is not connected",
      hant: "你的回答沒有送出 — 這塊板沒有連上",
      hans: "你的回答没有送出 — 这块板没有连上"
    }
  };
  var SENT_TONE = {
    sending: "neutral", accepted: "online", recorded: "online",
    refused: "danger", failed: "danger", unreachable: "danger"
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
  var sentState = null;
  var sentDetail = "";

  /* Two facts, and neither may stand in for the other: whether the page is
     still being updated, and whether what it is showing is everything there
     is. A connection that is perfectly healthy while a captain's call is
     missing must not read as a board with nothing on it. */
  /* THE PAGE HALF OF "A BOARD THAT IS BEHIND MAY NOT REPORT AN EMPTY DESK".
     The server half keeps rows from being dropped out of the payload; this is
     the half about what the board SAYS when the payload legitimately carries
     none. Both sentences under Captain's Call - the section caption and the
     empty deck's body - are derived by the board from captains_call.length,
     and a change the fleet could not word is precisely a captain's call missing
     from that payload. So while the badge is up, that count is the one number
     the page must not present as complete.
     Correcting only the caption is not enough: the body goes on saying it, and
     a reader sees the reassuring sentence rather than the corrected one. Both
     are replaced or neither is.
     It reads the payload back out of the page's own data slot rather than
     trusting a remembered copy, and it leaves the board's own words alone when
     that payload carries calls or will not parse - overwriting on a guess is
     the same fault in the other direction. */
  function correctEmptyDesk() {
    var payload;
    try {
      var slot = document.getElementById(SLOT_ID);
      if (!slot) return;
      payload = JSON.parse(slot.textContent);
    } catch (e) {
      return;
    }
    if (!payload || !Array.isArray(payload.captains_call)) return;
    var n = payload.captains_call.length;
    /* THE RULE IS ABOUT THE COUNT, AT EVERY COUNT. A list of one presented as
       the whole of what needs him is the same assertion as a list of none - the
       board cannot vouch for either while it is behind. So the caption says the
       list is partial whatever the count is, rather than only when it would
       otherwise have read "nothing needs you". */
    var sub = document.getElementById("bb-call-sub");
    if (sub) sub.textContent = say(SAY.call_sub_behind);
    /* The empty deck's body only exists when there is nothing to list. */
    if (n === 0) {
      var deck = document.getElementById("bb-call");
      var empty = deck ? deck.querySelector(".bb-empty") : null;
      if (empty) empty.textContent = say(SAY.call_empty_behind);
    }
    /* THE THIRD RENDERING, AND THE ONE IN THE LARGEST TYPE ON THE PAGE. The
       stat strip derives its NEED YOU tile from the same captains_call.length,
       so a board that is behind headlines a bare 0 directly above the two
       sentences just corrected - the same number, the same page, the same
       moment, presented as complete. The rule is about the COUNT wherever it is
       rendered, not about the sentences that were quoted, so the tile stops
       asserting a number the board cannot vouch for. */
    /* `n+` rather than a bare `n` or a dash: it keeps the number the captain
       does have and says the list is partial, and it reads the same in all
       three languages, which is why it is not written into the copy table. */
    var strip = document.getElementById("bb-stats");
    var tile = strip ? strip.querySelector(".bb-stat--call .bb-stat__num") : null;
    if (tile) tile.textContent = String(n) + "+";
  }

  function paintStatus() {
    var node = pin(LINK_ID, TONE[linkState] || "neutral");
    if (!node) return;
    node.textContent = linkCopy();
    if (behindCount > 0) {
      var behind = pin(BEHIND_ID, "danger");
      behind.textContent = say(behindCount === 1 ? BEHIND.one : BEHIND.many)
        .replace("{n}", String(behindCount));
      behind.hidden = false;
      correctEmptyDesk();
    } else {
      var existing = document.getElementById(BEHIND_ID);
      if (existing) existing.hidden = true;
    }
    /* Survives a repaint on purpose: the answer that caused the repaint is
       exactly the one whose outcome he is waiting to read. */
    if (sentState !== null) {
      var sent = pin(SENT_ID, SENT_TONE[sentState] || "neutral");
      if (sent) {
        sent.textContent = say(SENT[sentState] || SENT.failed) +
          (sentDetail ? " — " + sentDetail : "");
        sent.hidden = false;
      }
    } else {
      var wasSent = document.getElementById(SENT_ID);
      if (wasSent) wasSent.hidden = true;
    }
  }

  function setSent(next, detail) {
    sentState = next;
    sentDetail = detail || "";
    paintStatus();
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

  /* WHAT THE PAGE WAS BUILT WITH, AND THE RULE THAT PROTECTS IT. The server
     merges from the board at this home's stable path, not from the page that
     connected, so a page built from newer state can be sent a merge whose base
     is OLDER than itself. That is not a stale update to be drawn: it is this
     page being taken backwards by a board it has already superseded, and the
     section built by REMOVING rows - the Captain's Call - is the one it
     empties, because the additive sections survive the merge and go on looking
     plausible. So a payload stamped older than the one this page was built with
     is never applied. The page keeps what it has and says it is not updating,
     which is the same thing it does when the server has no board at all. */
  /* WHEN THIS PAGE'S CONTENT WAS COMPOSED, which is the only clock this
     comparison can use. `generated` is not it: the server overwrites it with
     the newest event a merge saw, so the first event published after this page
     was built makes an older board look newer than us - and on a branch whose
     whole subject is refreshing on fleet events, there are no quiet periods for
     that to be safe in. `composed` is stamped once, where the content is made.
     Read on first use rather than now: this file is injected ABOVE the data
     slot so that it can capture the page's markup before the board renders, so
     at this point the slot does not exist yet. The first use is the first state
     message, which is after the page has parsed and before anything has
     repainted the slot, so what it reads is what the page was built with. */
  var builtAt;
  function builtWith() {
    if (builtAt !== undefined) return builtAt;
    builtAt = NaN;
    try {
      var slot = document.getElementById(SLOT_ID);
      if (slot) builtAt = Date.parse((JSON.parse(slot.textContent) || {}).composed);
    } catch (e) {
      builtAt = NaN;
    }
    return builtAt;
  }

  function olderThanThisPage(payload) {
    var mine = builtWith();
    if (isNaN(mine) || !payload) return false;
    var t = Date.parse(payload.composed);
    return !isNaN(t) && t < mine;
  }

  function accept(message) {
    if (olderThanThisPage(message.payload)) {
      /* Keep every row this page was built with; say the link is not carrying
         us forward rather than drawing a board we are already ahead of. */
      setLink("offline");
      return;
    }
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
      if (!message) return;
      if (message.type === "inbound") { settled(message); return; }
      if (message.type !== "state") return;
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

  /* ---- the answer, going the other way ---------------------------------
   * The seam the board calls. It puts the captain's pick on the wire, shows
   * him it is on its way, and shows him what came back - including, above
   * all, that it did not land. It decides nothing about what his pick means.
   */
  var pending = {};
  var nextId = 0;

  function settled(message) {
    var id = typeof message.id === "string" ? message.id : "";
    var status = typeof message.status === "string" ? message.status : "failed";
    var waiting = pending[id];
    if (status === "accepted") {
      setSent("accepted", "");
    } else if (status === "recorded") {
      setSent("recorded", "");
      delete pending[id];
    } else {
      /* The reason is the server's stable machine word, not copy for the
         captain: it is shown after this file's own sentence so he has
         something exact to pass on, and the sentence carries the meaning. */
      setSent(status === "refused" ? "refused" : "failed",
        typeof message.reason === "string" ? message.reason : "");
      delete pending[id];
    }
    if (typeof waiting === "function") waiting({ status: status, reason: message.reason });
  }

  /* An unfilled slot is not a token: a board derived by something that did not
     inject one must say it cannot answer rather than send a message that will
     be refused. */
  function canAnswer() {
    return !!(socket && socket.readyState === 1 && /^[0-9a-f]{64}$/.test(TOKEN));
  }

  function answer(picks, whenSettled) {
    var list = Object.prototype.toString.call(picks) === "[object Array]" ? picks : [picks];
    if (!list.length) return false;
    if (!canAnswer()) {
      setSent("unreachable", "");
      if (typeof whenSettled === "function") {
        whenSettled({ status: "failed", reason: "not-connected" });
      }
      return false;
    }
    nextId += 1;
    var id = "a" + nextId;
    var body = [];
    for (var i = 0; i < list.length; i++) {
      var pick = list[i] || {};
      var one = { key: String(pick.key === undefined ? "" : pick.key) };
      if (pick.selection !== undefined && pick.selection !== null) {
        one.selection = String(pick.selection);
      }
      if (pick.note !== undefined && pick.note !== null) one.note = String(pick.note);
      if (pick.label !== undefined && pick.label !== null) one.label = String(pick.label);
      if (pick.close !== undefined && pick.close !== null) one.close = String(pick.close);
      body.push(one);
    }
    try {
      socket.send(JSON.stringify({
        schema: INBOUND_SCHEMA, token: TOKEN, type: "answer", id: id, answers: body
      }));
    } catch (e) {
      setSent("unreachable", "");
      if (typeof whenSettled === "function") {
        whenSettled({ status: "failed", reason: "not-connected" });
      }
      return false;
    }
    pending[id] = whenSettled;
    setSent("sending", "");
    return true;
  }

  window.fmBoardLive = { canAnswer: canAnswer, answer: answer };

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
