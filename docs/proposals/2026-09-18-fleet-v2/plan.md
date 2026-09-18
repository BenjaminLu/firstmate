# Fleet v2 改版計畫：更快的傳遞、更少的人類理解負擔、原理不變

日期：2026-09-18。
狀態：提案，尚未實作；作為 captain 自己下一版 harness 的起點。
語言：繁體中文，技術名詞保留英文；若要送回 upstream 需另寫英文版。
附件：同目錄的 `packet.html` 是現況架構的 baton packet（含完整 context），`packet-src/` 是它的產生原始碼。

## 1. 目的與範圍

這份計畫回答一個問題：在不放棄 firstmate 現有第一性原理的前提下，怎麼讓「captain 開口」到「captain 有信心做決定」這條路變短、變清楚。
範圍是主 firstmate home 與其直接 crewmate 之間的三條溝通管道、Lavish 決策介面、以及派工啟動流程。
不在範圍：secondmate、遠端 home、Relay、away-mode daemon；它們都是在同樣三條管道上多加幾跳，本計畫落地後再套用。

## 2. 不變的第一性原理

以下每一條在現況都已成立，新版本必須保留，任何改動只能在這些之上加速，不能繞過。

- 紀錄即送達：對 worker 的指令先成為 durable 檔案，終端只收到門鈴；worker 的 ack 是 `mv handled/`。
- status 是事件不是狀態：`state/<id>.status` 只能追加，現在的狀態永遠由 `bin/fm-crew-state.sh` 判讀。
- 模型不在迴圈裡等待：阻塞的等待由 watcher 與 process-event runner 承擔，模型只在有事時被叫醒。
- 每個任務在隔離的 worktree 與自己的 pane 裡，primary checkout 永遠不被寫。
- 只有風險真正需要人時才找 captain；其他一律自動落地或自動處理。
- vendor-agnostic：所有 harness 與 backend 原生能力都是 adapter 後面可選的加速，檔案契約永遠是 source of truth 與必備 fallback。
- 重啟是 non-event：所有狀態在磁碟與 session backend 上，不在對話記憶裡。
- Captain 面向的介面一律 EN / 繁體 / 简体 三語。

## 3. 現況診斷

以下數字來自 2026-09-18 讀取 `bin/fm-watch.sh`、`bin/fm-task-inbox-lib.sh`、`docs/architecture.md` 與 `docs/herdr-backend.md`，未實際量測端到端時間。

| 段落 | 現況延遲 | 成因 |
|---|---|---|
| firstmate intake：載 3 到 5 個 skill、寫 brief、選 profile、spawn | 數個模型回合，通常數分鐘 | intake 的每一步都是模型推理，而其中 profile、quota、mode 的選擇其實是資料計算 |
| worker 冷啟動 | 約一分鐘起跳 | harness 啟動後要吞下整份 `AGENTS.md`、launch brief、role contract 與 skill |
| 往下 steer 的門鈴 | 順利時立即；被吞才進 90 秒 grace 乘 3 次 | 門鈴是往 composer 打字，沒有送達回執，只能用時間換確定性 |
| 往上：worker 追加 status 到 watcher 看見 | 最多 15 秒（`FM_POLL=15`） | Herdr 的 push event 目前只接了 `blocked`，status 追加與 turn-end 仍靠輪詢 |
| watcher 退出到 firstmate 開始處理 | 要等 firstmate 當下回合結束 | Claude 的 Stop hook 只在回合結束觸發；captain 對話與 wake 處理共用一個模型迴圈 |
| firstmate 處理一個 wake | 一整個模型回合，數十秒到一分鐘 | drain、讀證據、判斷、ack 全部由模型做，即使多數 wake 的路由是機械的 |
| captain 做決定 | 不確定，常常要自己去翻 report、PR、CI | section 9 規定只講 outcome，證據被壓縮掉；Lavish 卡片只有短文與選項 |

三個結構性原因：

1. 用 poll 與 Stop hook 模擬事件，因為 harness 沒有「叫醒我」的 API。
2. 每個 agent 冷啟動時載入整個世界，supervisor 的契約被 worker 整包背。
3. firstmate 當有損壓縮的傳話筒，captain 拿到結論卻拿不到證據。

## 4. 改動項目

每一項列出問題、改法、保留什麼、驗收標準、影響的契約。

### A. Worker 自產 decision packet

問題：done 或 needs-decision 事件只帶一行文字，firstmate 再壓縮一次，captain 收到的是第三手摘要。

改法：把 baton 的三層 context 做進 worker 的 definition of done。
每個 `done:` 或 `needs-decision:` 事件必須附一份 packet：改了什麼（從 diff、PR、CI 由 script 產生骨架）、試過什麼又為何放棄（只有 session 知道，由 worker 填）、還有什麼不確定、怎麼再往下挖。
firstmate 的工作從「再摘要一次」變成「驗證 packet 存在且完整，然後路由」。

保留什麼：status 一行仍然是 wake 事件；packet 是事件指向的證據，不進 status log。

驗收標準：`verify.py` 式的機械檢查在 DoD 內執行；缺 packet 的 done 事件被 `bin/fm-crew-state.sh` 判為未完成。

影響的契約：`bin/fm-brief.sh` 的 DoD 段落、`bin/fm-dod-lib.sh`、`bin/fm-classify-lib.sh` 對 done 的判讀。

### B. 決策卡五問、風險分級、三語

問題：Lavish 卡片只有短文與選項，captain 沒有信心當下決定。

改法：每張決策卡固定回答五個問題：決定什麼、選 A 的後果、選 B 的後果、什麼都不做會怎樣、能不能回頭；再加建議與理由，每條連到 packet 內的證據。
卡片標示風險等級與可逆性。
綠燈且可逆的工作在 yolo 下自動落地、事後在 digest 出現；只有紅燈、模稜兩可、不可逆的才成為卡片。
看板 template 與 payload 契約加上 EN / 繁體 / 简体 三語（已排入 backlog `bearings-board-i18n`）。

保留什麼：merge 授權規則不變；`bin/fm-captain-hold.sh` 仍是唯一的 keyed-answer intake；卡片只能連到 packet，不能自己重述。

驗收標準：每張卡片五個欄位齊全且各有證據連結；captain 平均在卡片上停留的時間內能作答而不需離開看板。

影響的契約：`bin/fm-bearings-board.sh` 的 `fm-bearings-board.v1`、`.agents/skills/bearings` 的 composing 規則、`captain-hold-lifecycle`。

### C. Intake 一個指令、warm worker pool、指令面分層

問題：派工前 firstmate 燒掉數個模型回合，worker 啟動後又燒掉一分鐘讀契約。

改法一：`fm-dispatch "<ask>"` 一個指令完成 brief、profile、mode、backlog、spawn；profile 與 quota 排序由 script 計算，模型只填 intent 與 spec。
改法二：treehouse 已 pool worktree，把 worker 也 pool：數個已載好精簡角色契約的 idle session，派工等於往它的 inbox 丟 brief，spawn 退化為 assign。
改法三：worker 只拿任務形狀的契約（怎麼回報、怎麼收指令、DoD），supervisor 契約留給 firstmate；`AGENTS.md` 不再整包進 worker。

保留什麼：`bin/fm-spawn.sh` 的隔離斷言、`state/<id>.meta`、backlog 自動轉移；只是被 `fm-dispatch` 包起來。

驗收標準：captain 說完到 worker 第一個 commit 在 60 秒內；worker 啟動時載入的 token 量降到現況的三分之一以下。

影響的契約：`bin/fm-spawn.sh`、`bin/fm-brief.sh`、`bin/fm-harness.sh`、`quota-array-dispatch` 與 `harness-adapters` 兩個 skill 的可程式化部分。

### D. 事件推送與可插拔 transport

問題：往上 15 秒輪詢，往下門鈴用 90 秒乘 3 猜。

改法一：本機 event server（小 daemon，不是 bash in hook）接收 worker hook、`fm-report`、lavish-axi、forge webhook 的事件，做現在 `fm-classify-lib` 的分類，但分類靠結構化事件而非 regex 動詞。
改法二：Herdr 的 push event 從只接 `blocked` 擴到 status 追加與 turn-end；非 Herdr backend 用 fs-watch 同一個檔案。
改法三：門鈴 transport 依 backend 與 harness 可插拔：Herdr 上等 idle event 到了注入一次；Claude worker 用 SendMessage 當門鈴，有送達確認；tmux 維持打字。
改法四：worker 的 `echo >> status` 升級為 `fm-report`，同時寫 status 行（相容）與結構化事件（新）。

保留什麼：inbox 檔案與 `mv handled/`、status log、`state/.wake-queue` 全部保留，作為 source of truth 與任何 adapter 不可用時的 fallback。
明確不做：worker 直接對 firstmate 送訊息、跳過 watcher；那會讓每則 progress 變成 firstmate 的一個模型回合。

驗收標準：Herdr 與 Claude 上 status 追加到 wake 進 queue 在一秒內；門鈴階梯在有送達確認的 transport 上不再啟動；拔掉 event server 後行為退回現況輪詢且測試全綠。

影響的契約：`bin/fm-watch.sh` 的 `event_wait_or_sleep`、`bin/backends/herdr.sh` 的事件訂閱、`bin/fm-task-inbox-lib.sh` 的 ring 介面、`docs/herdr-backend.md`「Push events and polling fallback」。

### E. 兩條模型車道

問題：captain 對話與 wake 處理共用一個模型迴圈，互相 head-of-line blocking。

改法：supervision 車道用小模型處理結構化事件，captain 車道用強模型；Pi 的 supervision branch 已證明拆得開，做成所有 harness 的預設。

保留什麼：captain-facing 的輸出仍只由 captain 車道發出；supervision 車道的結論以 durable outcome 回到主線，沿用 `docs/pi-supervision-branch.md` 的 outcome store 契約。

驗收標準：captain 對話進行中，一個 done wake 從進 queue 到 packet 被驗證並掛上看板不超過 30 秒。

影響的契約：`docs/watcher-continuity.md` 的 per-actor 認領、`bin/fm-lease-lib.sh`、各 harness 的 supervision protocol。

### F. 結構化事件取代 regex 動詞分類

問題：`fm-classify-lib` 靠 status 行開頭的動詞判斷是否 captain-relevant，容易誤判也難擴充。

改法：事件帶 `kind`、`risk`、`reversible`、`evidence` 欄位；分類變成查表；status 行保留為人類可讀的投影。

保留什麼：現有動詞集合作為相容層繼續被接受。

驗收標準：新舊兩種事件在測試中分類結果一致；新增一種 wake 種類不需改分類 regex。

影響的契約：`bin/fm-classify-lib.sh`、`bin/fm-wake-lib.sh` 的 queue row 格式。

## 5. 順序與里程碑

先做 A 與 B，因為那是 captain 當下最痛的，而且不動底層。
再做 C，拿到啟動速度。
最後做 D、E、F，因為那是換底層，需要各 harness 與 backend 的相容驗證。

| 階段 | 內容 | 可量測的完成定義 |
|---|---|---|
| 1 | A packet 進 DoD；B 五問卡片與三語看板 | 100% 的 done 事件附 packet；卡片五欄齊全；看板三語 |
| 2 | C 一指令派工、warm pool、指令面分層 | 開口到第一個 commit 小於 60 秒；worker 啟動 token 降三分之二 |
| 3 | D 事件推送與可插拔 transport | Herdr 與 Claude 上 status 到 queue 小於 1 秒；門鈴階梯在確認型 transport 上不啟動 |
| 4 | E 兩條車道；F 結構化事件 | 對話中 done wake 30 秒內上看板；新 wake 種類零 regex 改動 |

每一階段結束都要通過現有 `tests/` 全綠，並在 `docs/verification/` 補上該階段的 dated 證據。

## 6. 風險與明確不做的事

- 不讓 worker 繞過 watcher 直送 firstmate；transport 再快，濾網要留。
- 不用任何 harness 專屬能力當唯一路徑；每個 adapter 都要有拔掉後的 fallback 測試。
- `lavish-axi poll` 回傳前先清除 feedback 的丟失窗口是 Lavish 端的事，本計畫不宣稱能關掉它；D 的 event server 只能縮短 runner 讀取的時間差。
- 兩條車道拆開後，captain 車道不得再直接改 fleet 狀態；所有變更走 supervision 車道的 durable outcome。
- 這份計畫假設 firstmate repo 沒有登記為 project，因此改動走 no-mistakes、yolo off；本 home 目前缺 no-mistakes 與 gh-axi，實作前先裝。

## 7. 這次 session 留下的東西

- `packet.html`：現況三條管道的 baton packet，五張圖、46 條有來源的邊、完整 context。
- `packet-src/`：`draw.py`（一個共用 layout library 畫五張圖，符合 baton 的嵌入契約）、`build.py`、`context.md`、SVG 與 edges 檔。
- 主 home 的 `data/captain.md` 記錄了 captain 的兩條設計原則：vendor-agnostic 必須保留、Lavish 介面三語。
- 主 home 的 backlog 有一個 queued 項目 `bearings-board-i18n`。
- captain 的 baton repo 已合併為單一 `/baton` 個人 skill（`BenjaminLu/baton` main `0ccff28`）。
