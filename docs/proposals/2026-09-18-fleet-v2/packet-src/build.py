#!/usr/bin/env python3
"""Assemble packet.json from the figures, the context, and the prose below."""
import json
from pathlib import Path
D = Path(__file__).resolve().parent

def i(en, hant):
    return {"en": en, "hant": hant}

def figure(slug, heading, caption):
    return {"kind": "figure", "heading": heading, "caption": caption,
            "svg": (D / f"{slug}.svg").read_text(),
            "edges": json.loads((D / f"{slug}.edges.json").read_text())}

spec = {
    "format_version": "0.1",
    "layer": "L1",
    "layer_note": i("read from AGENTS.md, docs/architecture.md and the script headers on 2026-09-18; nothing executed",
                    "2026-09-18 讀自 AGENTS.md、docs/architecture.md 和各 script 的 header；沒有實際執行任何指令"),
    "filename": "baton-firstmate-comms",
    "repo": "kunchenguid/firstmate",
    "branch": "main",
    "range": "795e5e4a (clean)",
    "title": i("firstmate: how it talks to crewmates and to Lavish",
               "firstmate：怎麼跟 crewmate 和 Lavish 溝通"),
    "subtitle": i("Three channels, all through files on disk, none of them holding a conversational turn. Drawn from the script headers and docs/architecture.md, not from a design-doc diagram - the repo has none.",
                  "三條管道，全部走磁碟上的檔案，沒有一條會卡住對話回合。圖是從 script header 和 docs/architecture.md 畫出來的，不是照設計文件的圖，因為 repo 裡沒有那種圖。"),
    "glossary": [
        [i("crewmate", "crewmate"), i("a worker agent firstmate spawns into its own worktree and pane; the captain's word 'subagent' maps here, not to the harness's Agent tool", "firstmate 派到獨立 worktree 和 pane 的 worker agent；captain 說的「subagent」對應這個，不是 harness 的 Agent 工具")],
        [i("Lavish", "Lavish"), i("lavish-axi, the local review server that serves an HTML artifact and long-polls for the captain's feedback", "lavish-axi：本機的 review server，提供 HTML artifact 並長輪詢 captain 的回饋")],
        [i("wake", "wake"), i("an event the watcher decided the first mate must act on; queued as one row in state/.wake-queue", "watcher 判定 firstmate 必須處理的事件；在 state/.wake-queue 裡佔一列")],
        [i("procevent", "procevent"), i("process-to-event: a registered blocking child whose completed output becomes a durable wake", "process-to-event：登記的阻塞子程序，跑完的輸出會變成 durable 的 wake")],
    ],
    "sections": [
        {"heading": i("What this is", "這是什麼"),
         "text": [
            {"p": i("firstmate is a supervisor that never waits in the model. Everything it says to a worker, everything a worker says back, and everything the captain answers on a Lavish board is written to a file first; a zero-token bash watcher reads those files and wakes the model only for something actionable.",
                    "firstmate 是一個從不在模型裡等待的 supervisor。它對 worker 說的每句話、worker 回來的每句話、captain 在 Lavish 看板上的每個回答，都先寫成檔案；一個不花 token 的 bash watcher 讀那些檔案，只在有事要做時叫醒模型。"), "lead": True},
            {"stats": [
                {"n": "3", "k": i("channels: down to a crewmate, up from a crewmate, sideways to Lavish", "管道：往下到 crewmate、往上回來、側向到 Lavish"), "tone": "accent"},
                {"n": "0", "k": i("model tokens spent while the watcher waits", "watcher 等待期間花掉的模型 token")},
                {"n": "90s × 3", "k": i("doorbell grace and attempts before a steer is escalated", "steer 升級前的 doorbell 寬限與重試次數"), "tone": "warn"},
                {"n": "1", "k": i("harness tool the guard denied in this session (Agent)", "這個 session 被 guard 擋下的 harness 工具（Agent）")},
            ]},
            {"p": i("Read the map first, then the three sequences. The last figure answers the other half of the question: why the harness's own subagent tool is refused, and what replaces it.",
                    "先看總圖，再看三張 sequence。最後一張圖回答問題的另一半：為什麼 harness 自帶的 subagent 工具會被拒絕，以及拿什麼取代。")},
            {"note": i("Register: engineer. Paths and script names are kept. Nothing here was executed; every arrow cites the header or doc it came from, and the context at the bottom carries those quotes.",
                       "讀者是工程師，路徑和 script 名稱都保留。這裡沒有實際執行任何東西；每條箭頭都註明來源的 header 或文件，頁底的 context 帶著那些引文。")},
         ]},
        figure("fmmap", i("The map", "總圖"),
               i("Nine parts, twelve connections. Everything the first mate session touches is either a script it runs or a file it writes; the only processes it talks to directly are the crewmate pane (spawn, doorbell) and the Lavish server (serve). The watcher and the process-event runner are the two things that block so the model does not.",
                 "九個部件、十二條連線。firstmate session 碰到的東西不是它跑的 script 就是它寫的檔案；它直接對話的程序只有 crewmate pane（spawn、doorbell）和 Lavish server（serve）。watcher 和 process-event runner 是兩個代替模型去阻塞的東西。")),
        {"heading": i("Three rules that shape every channel", "決定每條管道形狀的三條規則"),
         "text": [
            {"kv": [
                [i("The record is the delivery", "紀錄本身就是送達"),
                 i("fm-send exits 0 when state/<id>.inbox/NNN.msg is written, not when the doorbell lands. The terminal line is free to repeat; the file is processed at most once per worker lifetime because sequence numbers scan handled/ too.",
                   "fm-send 在 state/<id>.inbox/NNN.msg 寫好時就 exit 0，不等 doorbell 落地。終端那行可以重複敲；檔案每個 worker 一生最多處理一次，因為序號連 handled/ 一起掃。")],
                [i("A status line is an event, not state", "status 一行是事件，不是狀態"),
                 i("state/<id>.status is append-only. The watcher classifies each append; the drain re-surfaces still-open needs-decision or blocked keys as OPEN DECISIONS even when a later working: line buried them. Current state comes from bin/fm-crew-state.sh, never from the last line.",
                   "state/<id>.status 只能追加。watcher 逐行分類；drain 會把還沒關的 needs-decision 或 blocked key 當成 OPEN DECISIONS 再浮上來，就算後面的 working: 行把它蓋住了。現在的狀態要問 bin/fm-crew-state.sh，永遠不是看最後一行。")],
                [i("Nothing blocks a turn", "沒有東西會卡回合"),
                 i("The watcher blocks on the fleet; bin/fm-procevent.sh start blocks on lavish-axi poll; both run outside the model and hand back one queued row. On Claude the Stop hook re-arms the watcher at every turn end and exits 2 to wake the model when the watcher returns with a wake.",
                   "watcher 阻塞在 fleet 上；bin/fm-procevent.sh start 阻塞在 lavish-axi poll 上；兩者都在模型之外跑，交回來的只有 queue 裡的一列。在 Claude 上，Stop hook 每次回合結束都重新 arm watcher，watcher 帶著 wake 回來時就 exit 2 叫醒模型。")],
            ]},
            {"p": i("The lifecycle plane is separate on purpose: interrupt, exit and relaunch go through bin/fm-control.sh, because a lifecycle command sent as text becomes chat the worker reasons about instead of executing. fm-send's TYPED plane exists only for text that must reach the harness parser itself, such as a leading slash command.",
                    "生命週期是刻意分開的一層：interrupt、exit、relaunch 走 bin/fm-control.sh，因為用文字送生命週期指令會變成 worker 拿來推理的聊天內容，而不是被執行。fm-send 的 TYPED 層只給必須碰到 harness 自己 parser 的文字用，例如開頭是斜線的指令。")},
         ]},
        figure("fmsteer", i("Down: steering a crewmate", "往下：steer 一個 crewmate"),
               i("bin/fm-send.sh writes the record, rings once, and returns. The worker's mv into handled/ is the only acknowledgement that exists. If it never comes, the watcher re-rings on the 90-second grace up to three times and then wakes the first mate with a stale: (unread firstmate instruction) reason; a dead or missing pane skips the ladder and goes straight to recovery. Frame: the opt region is the watcher's ladder, from bin/fm-task-inbox-lib.sh.",
                 "bin/fm-send.sh 寫下紀錄、敲一次、返回。worker 把檔案 mv 進 handled/ 是唯一存在的 ack。如果一直沒來，watcher 以 90 秒寬限最多重敲三次，然後用 stale:（firstmate 指令未讀）的理由叫醒 firstmate；pane 已死或不見則跳過階梯直接進復原。框：opt 區是 watcher 的階梯，出自 bin/fm-task-inbox-lib.sh。")),
        figure("fmwake", i("Up: one appended line reaches the first mate", "往上：追加的一行怎麼到 firstmate"),
               i("The alt frame is the whole design: a no-verb line (working:, a bare turn-end) is absorbed only when bin/fm-crew-state.sh proves the crew is still working; anything else becomes a row in state/.wake-queue and the watcher exits. On a Claude primary the Stop hook that foregrounded the watcher then exits 2, which the harness delivers as Stop hook feedback. The row stays durable until the turn runs the printed --ack-through command, so an interrupted turn re-handles it.",
                 "alt 框就是整個設計：沒有動詞的一行（working:、單純的 turn-end）只有在 bin/fm-crew-state.sh 證明 crew 還在做事時才被吸收；其他一律變成 state/.wake-queue 裡的一列，watcher 退出。在 Claude primary 上，把 watcher 拉到前景的 Stop hook 接著 exit 2，harness 以 Stop hook feedback 送達。那一列一直是 durable 的，直到回合跑了印出來的 --ack-through 指令，所以被中斷的回合會重新處理它。")),
        figure("fmlavish", i("Sideways: a Lavish answer comes back", "側向：Lavish 的回答怎麼回來"),
               i("The order is the contract: serve and prove the session live, bind the answer source to bin/fm-captain-hold.sh, then arm. The runner that blocks on lavish-axi poll is started by the watcher's reconcile, never by a conversational turn. Only rows tagged choice can become keyed answers; a freeform message is prose and cannot forge a decision key. The one red arrow is the published poll clearing feedback server-side before it returns: a crash between that clear and the runner's capture loses the answer, and no wrapper can close that window.",
                 "順序就是契約：先提供並證明 session live，把答案來源 bind 到 bin/fm-captain-hold.sh，然後才 arm。阻塞在 lavish-axi poll 上的 runner 由 watcher 的 reconcile 啟動，絕不由對話回合啟動。只有 tag 是 choice 的列能變成 keyed answer；自由輸入的訊息是散文，偽造不了 decision key。唯一的紅箭頭是已發布的 poll 在回傳前先在 server 端清掉 feedback：在那次清除和 runner 捕捉之間當機就會丟掉回答，沒有任何 wrapper 能關上這個窗口。")),
        {"heading": i("What Lavish is to firstmate", "Lavish 對 firstmate 是什麼"),
         "text": [
            {"p": i("Lavish is not a peer service; it is one adapter of a generic process-to-event runner. bin/fm-procevent.sh owns ownership, durable capture, publication and restart recovery for any blocking child; bin/fm-procevent-lavish.sh adds only what is Lavish-specific.",
                    "Lavish 不是對等的服務；它是通用 process-to-event runner 的其中一個 adapter。bin/fm-procevent.sh 負責任何阻塞子程序的擁有權、durable 捕捉、發布和重啟復原；bin/fm-procevent-lavish.sh 只加上 Lavish 專屬的部分。")},
            {"kv": [
                [i("source id", "source id"), i("lavish-<first 16 hex of sha256(realpath of the html)>; two paths to one file are one source", "lavish-<html realpath 的 sha256 前 16 個 hex>；同一個檔案的兩個路徑算一個來源")],
                [i("classify", "classify"), i("feedback · ended · waiting · missing · unknown", "feedback · ended · waiting · missing · unknown")],
                [i("silent", "silent"), i("an ended session with no queued content: recorded handled, never announced. Send & End with content is feedback, always announced", "結束且沒有排隊內容的 session：記為 handled、永不通知。帶內容的 Send & End 是 feedback，一定通知")],
                [i("terminal", "terminal"), i("exit 0 retires the registration, so an ended review needs no cleanup from the model", "exit 0 就撤銷登記，結束的 review 不需要模型清理")],
                [i("read / answers", "read / answers"), i("read presents every captured item; answers emits <task-id> TAB <answer> TAB <label> for choice rows only and decides nothing", "read 呈現每個捕捉到的項目；answers 只對 choice 列輸出 <task-id> TAB <answer> TAB <label>，不做任何決定")],
                [i("verified against", "驗證版本"), i("lavish-axi 0.1.45: `lavish-axi poll <html-file>` long-polls indefinitely, so the adapter runs the plain blocking form with no timeout", "lavish-axi 0.1.45：`lavish-axi poll <html-file>` 無限期長輪詢，所以 adapter 跑不帶 timeout 的純阻塞形式")],
            ]},
            {"p": i("The /bearings board is the one first-class Lavish surface: bin/fm-bearings-board.sh injects an fm-bearings-board.v1 payload into the shipped template at the stable path (.lavish/bearings-board.html here), proves the session live because lavish-axi exits 0 even on a user-ended session, drops Captain's Call cards whose subject already landed, and gives every decision card the reserved reconcile choice. A Merge now click is the captain's explicit merge word for that one PR, with the PR re-read from state/<task-id>.meta and re-verified green before bin/fm-pr-merge.sh runs.",
                    "/bearings 看板是唯一的一等 Lavish 介面：bin/fm-bearings-board.sh 把 fm-bearings-board.v1 payload 注入內建 template，放在固定路徑（這裡是 .lavish/bearings-board.html），因為 lavish-axi 就算遇到 user 已結束的 session 也 exit 0 所以要證明 session live，丟掉主題已落地的 Captain's Call 卡片，並給每張決策卡保留的 reconcile 選項。點 Merge now 就是 captain 對那個 PR 的明確合併指令，PR 要從 state/<task-id>.meta 重讀並重新確認 green 才跑 bin/fm-pr-merge.sh。")},
            {"note": i("This home has a live board right now: the session-start hook listed .lavish/bearings-board.html open at http://127.0.0.1:4387/session/a4b444c4e85830a5 with no pending prompts. Whether its poll source is armed was not checked; bin/fm-procevent.sh list would say.",
                       "這個 home 現在就有一個活著的看板：session-start hook 列出 .lavish/bearings-board.html 在 http://127.0.0.1:4387/session/a4b444c4e85830a5 開著、沒有待處理的 prompt。它的 poll 來源有沒有 arm 沒有檢查；bin/fm-procevent.sh list 會告訴你。")},
         ]},
        figure("fmguard", i("Subagent: the tool that is refused, and what replaces it", "subagent：被拒絕的工具，和取代它的東西"),
               i("Left is what happened in this session when the model reached for the Agent tool: bin/fm-subagent-pretool-check.sh denied it by name shape. The reason is an incident on 2026-07-22 - four workers run through the harness tool, zero fleet visibility, two lost on restart, supervision down 73 minutes unnoticed - and the structural cause: only bin/fm-spawn.sh writes state/<id>.meta, so untracked work makes the in-flight guards inert. Right is the path that leaves a record the watcher can see. FM_ALLOW_SUBAGENT=1 is the documented deliberate exception.",
                 "左邊是這個 session 裡模型伸手拿 Agent 工具時發生的事：bin/fm-subagent-pretool-check.sh 依名稱形狀擋下。原因是 2026-07-22 的事故：四個 worker 走 harness 工具跑、fleet 完全看不見、重啟丟了兩個、supervision 停了 73 分鐘沒人發現；結構性原因是只有 bin/fm-spawn.sh 會寫 state/<id>.meta，沒登記的工作讓 in-flight guard 全部失效。右邊是會留下 watcher 看得到的紀錄的那條路。FM_ALLOW_SUBAGENT=1 是文件明寫的刻意例外。")),
        {"kind": "points", "heading": i("What to watch", "要注意的事"), "items": [
            {"tone": "risk", "tag": "lossy window",
             "text": i("`lavish-axi poll` clears feedback before returning it. Output that reached the runner is stored before it is announced, but a result lost between the server's clear and the runner's read is gone; the adapter header forbids calling this path at-least-once.",
                       "`lavish-axi poll` 回傳前先清掉 feedback。到達 runner 的輸出會先存再通知，但在 server 清除和 runner 讀取之間丟掉的結果就沒了；adapter header 禁止把這條路說成 at-least-once。")},
            {"tone": "warn", "tag": "no dispatch here",
             "text": i("This home reports `no-mistakes`, `gh-axi`, `chrome-devtools-axi` and `quota-axi` MISSING, and AGENTS.md section 3 says not to dispatch until the launch tools are present. The channels drawn here could not be exercised end to end from this session.",
                       "這個 home 回報 `no-mistakes`、`gh-axi`、`chrome-devtools-axi`、`quota-axi` 都 MISSING，AGENTS.md 第 3 節說工具沒到齊前不派工。這裡畫的管道沒辦法從這個 session 端到端跑一遍。")},
            {"tone": "warn", "tag": "one wake path drawn",
             "text": i("The up-channel figure is the Claude Stop-hook path. Pi hands eligible rows to an in-process supervision branch, Grok uses background-notify cycles, and Herdr can replace the watcher's sleep with a native blocked-event wait; none of those is drawn.",
                       "往上那張圖畫的是 Claude 的 Stop-hook 路。Pi 會把符合條件的列交給 in-process 的 supervision branch，Grok 用 background-notify 週期，Herdr 可以把 watcher 的 sleep 換成原生的 blocked-event 等待；這些都沒畫。")},
            {"tone": "ok", "tag": "guard worked",
             "text": i("Both guards fired as designed during this session: the Agent tool was denied once, and a top-level `cd` in a Bash call was denied three times by bin/fm-cd-pretool-check.sh. Neither left any state behind.",
                       "這個 session 兩個 guard 都照設計觸發：Agent 工具被擋一次，Bash 裡頂層的 `cd` 被 bin/fm-cd-pretool-check.sh 擋三次。都沒有留下任何狀態。")},
        ]},
        {"heading": i("Roads not taken, and next steps", "沒走的路，和下一步"),
         "text": [
            {"h": i("Not drawn", "沒畫的")},
            {"p": i("Secondmates (a crewmate that is itself a firstmate home; its status file is its parent channel), remote homes over SSH, Relay, the away-mode daemon, and the Pi supervision branch. Each has its own doc under docs/ and none changes the three channels above; they add hops.",
                    "secondmate（本身是一個 firstmate home 的 crewmate；它的 status 檔就是 parent channel）、走 SSH 的遠端 home、Relay、away-mode daemon、Pi 的 supervision branch。每個在 docs/ 下都有自己的文件，沒有一個改變上面三條管道；它們只是多加幾跳。")},
            {"h": i("Not verified", "沒驗證的")},
            {"p": i("No script was executed for this reading. The doorbell text, the ladder tunables, the reason lines and the adapter verdicts are quoted from headers, which the repo treats as the owning contracts; tests/ pins most of them but those tests were not run here.",
                    "這次閱讀沒有執行任何 script。doorbell 文字、階梯參數、reason 行和 adapter 的判定都引自 header，repo 把 header 當成契約的擁有者；tests/ 釘住了大部分，但這裡沒跑。")},
            {"h": i("If you want to go one step further", "如果要再往前一步")},
            {"kv": [
                ["1", i("Run bin/fm-procevent.sh list to see whether the live bearings board's source is armed and who owns it.", "跑 bin/fm-procevent.sh list，看看活著的 bearings 看板的來源有沒有 arm、誰擁有它。")],
                ["2", i("Install the four MISSING tools through bootstrap-diagnostics so a real crewmate can be spawned and the steer and status channels exercised.", "透過 bootstrap-diagnostics 裝那四個 MISSING 的工具，才能真的 spawn 一個 crewmate 把 steer 和 status 管道跑一遍。")],
                ["3", i("If the Pi path matters to you, docs/pi-supervision-branch.md is the next read; it is the one materially different up-channel.", "如果 Pi 那條路對你重要，下一篇讀 docs/pi-supervision-branch.md；那是唯一實質不同的往上管道。")],
            ]},
         ]},
    ],
}
spec["context"] = (D / "context.md").read_text()
(D / "packet.json").write_text(json.dumps(spec, ensure_ascii=False))
print("packet.json written:", len(spec["sections"]), "sections,", len(spec["context"]), "context chars")
