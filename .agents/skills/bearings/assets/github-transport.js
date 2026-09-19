/* GitHub transport for the bearings board.
 *
 * THE BOARD IS NOT RE-AUTHORED HERE. Everything the captain sees - markup,
 * stylesheet, copy, card types, badges, packet and its figures, pickers, the
 * language switch - comes from the shipped template
 * (.agents/skills/bearings/assets/board-template.html) and runs here as that
 * template's OWN script, verbatim. This file carries only what a surface fed
 * by GitHub must do differently, which is two things: how a payload arrives,
 * and where an answer goes. Anything that rendered board content here would
 * recreate the hand-written second board this design exists to avoid.
 *
 * WHY GITHUB, AND WHAT IT COSTS. The store is a plain file on a public
 * branch, so this page reads it with no account, no token, and no vendor's
 * session - from GitHub Pages, from a file:// page opened out of a clone, or
 * from anywhere else it is served. What that costs is freshness, and the cost
 * is not negotiable: raw.githubusercontent.com sends cache-control max-age=300
 * from a CDN that ignores the query string, so a never-before-used cache
 * buster still returns the cached object. A reader cannot be made to see a
 * write sooner than five minutes. This page therefore NEVER says live. It
 * says how old what it is showing is, and it says the bound.
 *
 * CHECK NOW IS THE ONE WAY PAST THE FLOOR, AND IT IS RATIONED. GitHub's
 * contents API caches for 60 seconds instead of 300, and it is also
 * credential-free - but unauthenticated it allows 60 requests an hour per IP,
 * and conditional requests that come back 304 still count against that
 * (measured). It is therefore not a poll. It is wired to an explicit tap, one
 * request per tap, and when the budget is gone the page says so instead of
 * quietly showing old data.
 *
 * AN ANSWER CANNOT LEAVE THIS PAGE THE WAY THE DATA ARRIVED. There is no
 * credential-free write to GitHub - not the API, not a push, not a workflow
 * dispatch. So the read guarantee and the answer guarantee are different
 * strengths, and this page does not blur them. An answer is composed here and
 * handed to GitHub as a prefilled issue, which the captain submits as himself
 * in a browser he is already signed into. No vendor is in that path; his own
 * GitHub account is, irreducibly. A card is marked answered only after the
 * page has actually handed the answer over, never on the click.
 *
 * A BOARD THAT RENDERS IS NEVER REPLACED BY ONE THAT DOES NOT. Nothing this
 * page can reach validates what a publisher wrote, so an arriving payload is
 * judged by the only authority on what this board can render - the shipped
 * board itself. The payload is drawn and the board's own verdict is read off
 * the page afterwards. A payload that does not render is undone, the last one
 * that did is drawn again, and the page says the update was rejected.
 *
 * THE CAPTAIN'S UNSENT WORK OUTRANKS A FRESH PAYLOAD. A repaint runs the
 * shipped renderer, which throws away everything on the page, so an update
 * that arrives while he is part-way through a card is held, and the page says
 * it is holding, until that work is sent or left behind.
 *
 * A REPAINT COSTS THE SAME EVERY TIME. A page that gets heavier the longer it
 * is left open is broken even when nothing looks wrong, so each repaint undoes
 * what the last one registered before registering anything again.
 *
 * bin/fm-board-github.sh composes this file with the template; it is not
 * loaded on its own.
 */
(function () {
  "use strict";

  /* The shipped board script, embedded verbatim by bin/fm-board-github.sh.
     Running it is what makes this board render exactly what the desk board
     renders, including anything added to the template after this file was
     last touched. */
  var BOARD_SRC = "__FM_BEARINGS_BOARD_SCRIPT__";
  var SLOT_ID = "bearings-data";
  var STRIP_ID = "bb-gh-status";
  var PRISTINE = document.body.innerHTML;

  var envelope = null;      /* the whole fm-board-store.v1 record on the page */
  var current = null;       /* the board payload actually drawn */
  var state = "embedded";   /* embedded | fresh | stale | offline | rejected | holding */
  var pending = null;       /* a payload held because he is mid-answer */
  var checking = false;
  var apiSpent = 0;
  var timer = null;
  var cleanup = [];

  /* The only copy this file owns: the freshness of the data and the route an
     answer takes, the two things the shipped board has no concept of. It
     follows the board's own language choice through the key the template
     already stores. */
  var SAY = {
    asof: {
      en: "showing the board as it was {age} ago",
      hant: "顯示的是 {age} 前的看板",
      hans: "显示的是 {age} 前的看板"
    },
    bound: {
      en: "GitHub serves this file from a cache, so it can be up to 5 minutes behind. This page is never live.",
      hant: "GitHub 是從快取送出這份檔案的，所以最多可能落後 5 分鐘。這個頁面不是即時的。",
      hans: "GitHub 是从缓存送出这份文件的，所以最多可能落后 5 分钟。这个页面不是即时的。"
    },
    offline: {
      en: "could not reach GitHub — this is the copy built into the page, not current data",
      hant: "連不上 GitHub — 這是頁面內建的舊資料，不是現在的狀況",
      hans: "连不上 GitHub — 这是页面内建的旧数据，不是现在的状况"
    },
    rejected: {
      en: "the update was rejected — this board cannot read it; showing the last one it could",
      hant: "更新被拒 — 這塊板讀不了它，顯示上一份讀得到的",
      hans: "更新被拒 — 这块板读不了它，显示上一份读得到的"
    },
    holding: {
      en: "an update is waiting until this answer is sent",
      hant: "有更新在等這個回答送出後才套用",
      hans: "有更新在等这个回答送出后才套用"
    },
    checking: { en: "checking…", hant: "檢查中…", hans: "检查中…" },
    check: { en: "check now", hant: "立即檢查", hans: "立即检查" },
    spent: {
      en: "check now is used up for this hour (GitHub allows 60 an hour from one address without an account)",
      hant: "這個小時的立即檢查用完了（沒有帳號時 GitHub 每個位址每小時只給 60 次）",
      hans: "这个小时的立即检查用完了（没有账号时 GitHub 每个地址每小时只给 60 次）"
    },
    answers_off: {
      en: "answers cannot be sent from this board — it was published without an answer address",
      hant: "這塊板無法送出回答 — 發佈時沒有設定回答位址",
      hans: "这块板无法送出回答 — 发布时没有设定回答地址"
    },
    answer_route: {
      en: "answering opens a prefilled GitHub issue — you submit it as yourself, then it reaches the fleet",
      hant: "回答會開一張預先填好的 GitHub issue — 由你自己送出，然後才會傳回船隊",
      hans: "回答会开一张预先填好的 GitHub issue — 由你自己送出，然后才会传回船队"
    }
  };
  var AGE = {
    now: { en: "less than a minute", hant: "不到一分鐘", hans: "不到一分钟" },
    min: { en: "{n} min", hant: "{n} 分鐘", hans: "{n} 分钟" },
    hour: { en: "{n} h", hant: "{n} 小時", hans: "{n} 小时" },
    day: { en: "{n} days", hant: "{n} 天", hans: "{n} 天" }
  };
  var TONE = {
    embedded: "warn", fresh: "online", stale: "warn",
    offline: "danger", rejected: "danger", holding: "warn"
  };

  function lang() {
    try {
      var s = window.localStorage && window.localStorage.getItem("fm-bearings-lang");
      if (s === "en" || s === "hant" || s === "hans") return s;
    } catch (e) { /* private mode */ }
    return (envelope && envelope.board && envelope.board.lang) || "hant";
  }

  function say(entry, vars) {
    var l = lang();
    var text = entry[l] || entry.en;
    if (vars) {
      Object.keys(vars).forEach(function (k) {
        text = text.replace("{" + k + "}", vars[k]);
      });
    }
    return text;
  }

  function ageWords(seconds) {
    if (seconds < 60) return say(AGE.now);
    if (seconds < 3600) return say(AGE.min, { n: Math.floor(seconds / 60) });
    if (seconds < 86400) return say(AGE.hour, { n: Math.floor(seconds / 3600) });
    return say(AGE.day, { n: Math.floor(seconds / 86400) });
  }

  function publishedAge() {
    if (!envelope || !envelope.published_at) return null;
    var t = Date.parse(envelope.published_at);
    if (isNaN(t)) return null;
    return Math.max(0, Math.floor((Date.now() - t) / 1000));
  }

  /* ---- the status strip ------------------------------------------------
     One line, always present, always saying which of the several different
     quiet states this is. A board that is five minutes behind and says so is
     worth more than one that claims to be current. */
  function paintStrip() {
    var strip = document.getElementById(STRIP_ID);
    if (!strip) {
      strip = document.createElement("div");
      strip.id = STRIP_ID;
      strip.setAttribute("role", "status");
      strip.style.cssText = "position:sticky;top:0;z-index:40;display:flex;gap:.75rem;" +
        "align-items:center;flex-wrap:wrap;padding:.45rem .9rem;font:500 12px/1.5 " +
        "ui-sans-serif,system-ui,sans-serif;border-bottom:1px solid rgba(0,0,0,.12)";
      document.body.insertBefore(strip, document.body.firstChild);
    }
    var tone = TONE[state] || "warn";
    strip.style.background = tone === "online" ? "#0f2e1c" : tone === "danger" ? "#3a1113" : "#2a2410";
    strip.style.color = tone === "online" ? "#7fe0a6" : tone === "danger" ? "#ff9d9d" : "#e8cf86";
    strip.textContent = "";

    var line = document.createElement("span");
    var age = publishedAge();
    if (state === "offline") line.textContent = say(SAY.offline);
    else if (state === "rejected") line.textContent = say(SAY.rejected);
    else if (state === "holding") line.textContent = say(SAY.holding);
    else line.textContent = age === null ? say(SAY.offline) : say(SAY.asof, { age: ageWords(age) });
    strip.appendChild(line);

    var bound = document.createElement("span");
    bound.style.opacity = ".72";
    bound.textContent = say(SAY.bound);
    strip.appendChild(bound);

    if (envelope && envelope.read && envelope.read.api_url) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.style.cssText = "margin-left:auto;font:inherit;cursor:pointer;border-radius:999px;" +
        "border:1px solid currentColor;background:transparent;color:inherit;padding:.15rem .7rem";
      btn.textContent = checking ? say(SAY.checking) : say(SAY.check);
      btn.disabled = checking;
      btn.addEventListener("click", function () { checkNow(btn); });
      strip.appendChild(btn);
    }
    if (!answerTarget()) {
      var gap = document.createElement("span");
      gap.style.cssText = "flex-basis:100%;opacity:.85";
      gap.textContent = say(SAY.answers_off);
      strip.appendChild(gap);
    }
  }

  /* ---- painting --------------------------------------------------------
     The shipped renderer is re-run against a restored copy of the page as it
     was parsed, so a repaint can never drift from first paint. */
  function runBoard(payload) {
    document.body.innerHTML = PRISTINE;
    var slot = document.getElementById(SLOT_ID);
    slot.textContent = JSON.stringify(payload);
    try {
      (new Function(BOARD_SRC))();
    } catch (e) {
      return false;
    }
    var stats = document.getElementById("bb-stats");
    return !!(stats && stats.children.length > 0);
  }

  function undoRegistrations() {
    cleanup.forEach(function (fn) { try { fn(); } catch (e) { /* gone already */ } });
    cleanup = [];
  }

  function paint(payload) {
    undoRegistrations();
    if (!runBoard(payload)) return false;
    current = payload;
    installAnswerBridge();
    paintStrip();
    return true;
  }

  function repaint(nextEnvelope) {
    if (touched()) { pending = nextEnvelope; state = "holding"; paintStrip(); return; }
    var previous = { envelope: envelope, board: current };
    envelope = nextEnvelope;
    if (paint(nextEnvelope.board)) { state = "fresh"; paintStrip(); return; }
    envelope = previous.envelope;
    paint(previous.board);
    state = "rejected";
    paintStrip();
  }

  /* Anything he has typed or ticked and not yet handed over. The shipped
     board keeps that in its own form controls, so this asks the page rather
     than tracking a copy of his work. */
  function touched() {
    var inputs = document.querySelectorAll("#bb-call textarea, #bb-call input, #bb-charted input:checked");
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i];
      if (el.type === "checkbox" || el.type === "radio") { if (el.checked) return true; }
      else if (el.value && String(el.value).trim()) return true;
    }
    return false;
  }

  /* ---- reading ---------------------------------------------------------- */
  function accept(text) {
    var next;
    try { next = JSON.parse(text); } catch (e) { return false; }
    if (!next || next.schema !== "fm-board-store.v1" || !next.board) return false;
    if (envelope && next.published_at === envelope.published_at) {
      state = "fresh"; paintStrip(); return true;
    }
    repaint(next);
    return true;
  }

  function readStore() {
    if (!envelope || !envelope.read || !envelope.read.url) return;
    fetch(envelope.read.url, { cache: "no-store", credentials: "omit" })
      .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
      .then(function (text) { if (!accept(text)) { state = "rejected"; paintStrip(); } })
      .catch(function () { state = "offline"; paintStrip(); });
  }

  /* One request per tap, never a poll: the unauthenticated budget is 60 an
     hour for the whole address and a 304 spends one too. */
  function checkNow(btn) {
    if (checking) return;
    checking = true;
    if (btn) { btn.disabled = true; btn.textContent = say(SAY.checking); }
    fetch(envelope.read.api_url, {
      cache: "no-store", credentials: "omit",
      headers: { Accept: "application/vnd.github.raw" }
    }).then(function (r) {
      if (r.status === 403 || r.status === 429) {
        apiSpent = 1;
        return Promise.reject("budget");
      }
      return r.ok ? r.text() : Promise.reject(r.status);
    }).then(function (text) {
      checking = false;
      if (!accept(text)) { state = "rejected"; paintStrip(); }
    }).catch(function (why) {
      checking = false;
      state = why === "budget" ? "stale" : "offline";
      paintStrip();
      if (why === "budget") {
        var strip = document.getElementById(STRIP_ID);
        if (strip) {
          var s = document.createElement("span");
          s.style.cssText = "flex-basis:100%;opacity:.9";
          s.textContent = say(SAY.spent);
          strip.appendChild(s);
        }
      }
    });
  }

  /* ---- answers ----------------------------------------------------------
     The shipped board hands every answer to window.lavish.queuePrompt. Here
     that interface composes a prefilled GitHub issue and hands it to the
     browser. GitHub authenticates the captain; nothing else is in the path. */
  function answerTarget() {
    if (!envelope || !envelope.answer) return null;
    var a = envelope.answer;
    if (a.kind !== "github-issue" || !a.repo || !/^[\w.-]+\/[\w.-]+$/.test(a.repo)) return null;
    return a;
  }

  function issueUrl(data, text) {
    var a = answerTarget();
    var body = [
      "The board sent this answer. The line under `answer` is what the fleet reads;",
      "everything else is for you.",
      "",
      "```json",
      JSON.stringify({
        schema: "fm-board-answer.v1",
        question: data.question,
        selection: data.selection || "",
        note: data.note || "",
        close: data.close || ""
      }),
      "```",
      "",
      "> " + text
    ].join("\n");
    return "https://github.com/" + a.repo + "/issues/new" +
      "?labels=" + encodeURIComponent(a.label || "fm-board-answer") +
      "&title=" + encodeURIComponent("board answer: " + data.question) +
      "&body=" + encodeURIComponent(body);
  }

  function installAnswerBridge() {
    var target = answerTarget();
    window.lavish = window.lavish || {};
    window.lavish.queuePrompt = function (text, opts) {
      var data = opts && opts.data;
      if (!target || !data || data.schema !== "fm-bearings-answer.v1" || !data.question) return false;
      var win = window.open(issueUrl(data, text), "_blank", "noopener");
      /* A card is answered when the answer was actually handed over. A popup
         blocker that swallowed the window must not leave a card ticked as
         though the fleet heard it. */
      if (!win) { window.location.href = issueUrl(data, text); }
      return true;
    };
    var note = document.getElementById("bb-provenance");
    if (note && target) {
      var hint = document.createElement("span");
      hint.style.cssText = "display:block;opacity:.7";
      hint.textContent = say(SAY.answer_route);
      note.parentNode.appendChild(hint);
      cleanup.push(function () { if (hint.parentNode) hint.parentNode.removeChild(hint); });
    }
  }

  /* ---- start ------------------------------------------------------------ */
  try {
    envelope = JSON.parse(document.getElementById(SLOT_ID).textContent);
  } catch (e) { envelope = null; }

  if (!envelope || envelope.schema !== "fm-board-store.v1" || !envelope.board) {
    document.body.innerHTML = PRISTINE;
    var slot = document.getElementById(SLOT_ID);
    if (slot) slot.textContent = "{}";
    try { (new Function(BOARD_SRC))(); } catch (e) { /* the board says so itself */ }
    return;
  }

  state = "embedded";
  paint(envelope.board);
  readStore();
  timer = setInterval(function () {
    paintStrip();
    readStore();
  }, (envelope.read_lag_bound_secs || 300) * 1000);
  window.addEventListener("focus", readStore);
  window.addEventListener("beforeunload", function () { clearInterval(timer); });
}());
