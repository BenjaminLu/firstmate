#!/usr/bin/env python3
"""One layout library, five figures. Every figure meets baton's embedding
contract: colours as packet CSS variables, data-node on every shape,
data-en/hant/hans on every <text>, ids prefixed per figure, no external fonts,
orthogonal connectors with r=8 elbows, masked labels with a visible gap.
Writes <slug>.svg and <slug>.edges.json beside this script."""
import json, math
from pathlib import Path
import opencc
CC = opencc.OpenCC("tw2sp")
OUT = Path(__file__).resolve().parent

SANS = "var(--sans)"; MONO = "var(--mono)"

def est(s):
    return sum(12.0 if ord(c) > 0x2E80 else 7.2 for c in s)

class Fig:
    def __init__(self, slug, w, h, title_en, title_hant, desc_en, desc_hant):
        self.slug, self.w, self.h = slug, w, h
        self.title = (title_en, title_hant); self.desc = (desc_en, desc_hant)
        self.parts = []; self.edges = []
    def text(self, x, y, en, hant, size=12, weight=400, fill="var(--fg)", anchor="middle", family=SANS, extra=""):
        hans = CC.convert(hant)
        self.parts.append(
            f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
            f'text-anchor="{anchor}" style="font-family:{family}" data-en="{esc(en)}" '
            f'data-hant="{esc(hant)}" data-hans="{esc(hans)}"{extra}>{esc(en)}</text>')
        return max(est(en), est(hant), est(hans))
    def rect(self, x, y, w, h, fill, stroke, node=None, dash=None, rx=6, sw=1):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        n = f' data-node="{node}"' if node else ""
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}{n}/>')
    def mask(self, x, y, w, h, rx=2):
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="var(--card)"/>')
    def node(self, nid, x, y, w, h, en, hant, sub=None, kind="plain"):
        fill, stroke, dash = {
            "focal": ("var(--accent-tint)", "var(--accent)", None),
            "plain": ("var(--card)", "var(--fg)", None),
            "store": ("var(--card-2)", "var(--muted)", None),
            "ext":   ("var(--card)", "var(--muted)", "4,3"),
            "seal":  ("var(--card)", "var(--seal)", None),
            "amber": ("var(--card)", "var(--amber)", None),
        }[kind]
        self.mask(x, y, w, h, rx=6)
        self.rect(x, y, w, h, fill, stroke, node=nid, dash=dash)
        cx = x + w // 2
        if sub:
            self.text(cx, y + h // 2 - 4, en, hant, weight=600)
            self.text(cx, y + h // 2 + 16, sub[0], sub[1], fill="var(--muted)", family=MONO)
        else:
            self.text(cx, y + h // 2 + 4, en, hant, weight=600)
    def path(self, d, color="var(--muted)", dash=None, marker="arrow", edge=None, sw=1.2):
        ds = f' stroke-dasharray="{dash}"' if dash else ""
        m = f' marker-end="url(#{self.slug}-{marker})"' if marker else ""
        e = f' data-edge="{edge}"' if edge else ""
        self.parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{ds}{m}{e}/>')
    def label(self, cx, cy, en, hant, fill="var(--muted)", family=MONO):
        # cy = vertical centre of the label mask
        w = max(est(en), est(hant), est(CC.convert(hant))) + 16
        w = int(math.ceil(w / 4) * 4)
        self.mask(cx - w // 2, cy - 8, w, 16)
        self.text(cx, cy + 4, en, hant, fill=fill, family=family)
    def edge(self, frm, to, evidence):
        self.edges.append({"from": frm, "to": to, "evidence": evidence})
    def legend(self, y, items):
        self.parts.append(f'<line x1="32" y1="{y-8}" x2="{self.w-32}" y2="{y-8}" stroke="var(--rule)" stroke-width="0.8"/>')
        self.text(32, y + 8, "LEGEND", "圖例", fill="var(--muted)", anchor="start", family=MONO)
        x = 112
        for (en, hant, fill, stroke, dash) in items:
            d = f' stroke-dasharray="{dash}"' if dash else ""
            self.parts.append(f'<rect x="{x}" y="{y-2}" width="20" height="12" rx="2" fill="{fill}" stroke="{stroke}" stroke-width="1"{d}/>')
            w = self.text(x + 28, y + 8, en, hant, fill="var(--muted)", anchor="start")
            x += int(math.ceil((w + 48) / 4) * 4)
    def write(self):
        s = self.slug
        hans_t = CC.convert(self.title[1]); hans_d = CC.convert(self.desc[1])
        markers = "".join(
            f'<marker id="{s}-{name}" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">'
            f'<polygon points="0 0, 8 3, 0 6" fill="{col}"/></marker>'
            for name, col in [("arrow", "var(--muted)"), ("arrow-accent", "var(--accent)"),
                              ("arrow-fg", "var(--fg)"), ("arrow-seal", "var(--seal)"), ("arrow-amber", "var(--amber)")])
        markers += (f'<marker id="{s}-arrow-open" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">'
                    f'<polyline points="0 0, 8 3, 0 6" fill="none" stroke="var(--muted)" stroke-width="1.2"/></marker>')
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="100%" role="img" '
               f'aria-labelledby="{s}-title {s}-desc" style="font-family:{SANS}">'
               f'<title id="{s}-title" data-en="{esc(self.title[0])}" data-hant="{esc(self.title[1])}" data-hans="{esc(hans_t)}">{esc(self.title[0])}</title>'
               f'<desc id="{s}-desc" data-en="{esc(self.desc[0])}" data-hant="{esc(self.desc[1])}" data-hans="{esc(hans_d)}">{esc(self.desc[0])}</desc>'
               f'<defs>{markers}</defs>' + "".join(self.parts) + '</svg>')
        (OUT / f"{s}.svg").write_text(svg)
        (OUT / f"{s}.edges.json").write_text(json.dumps(self.edges, ensure_ascii=False, indent=1))
        print(f"{s}: {len(self.parts)} parts, {len(self.edges)} edges")

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

# ---------- sequence helper ----------
class Seq(Fig):
    """Actors in a row, dashed lifelines, horizontal messages, one fragment."""
    def __init__(self, slug, actors, n_rows, title, desc, top=40, row=40, w=960):
        self.n = len(actors); self.top = top; self.row = row
        h = top + 96 + n_rows * row + 80
        super().__init__(slug, w, h, *title, *desc)
        self.cx = []
        gap = (w - 64) // self.n
        for i, (aid, en, hant, sub, kind) in enumerate(actors):
            aw = 176 if self.n >= 5 else 160
            x = 32 + i * gap + (gap - aw) // 2
            x -= x % 4
            self.cx.append(x + aw // 2)
            self.node(aid, x, top, aw, 56, en, hant, sub=sub, kind=kind)
        self.y0 = top + 56
        self.y_end = top + 96 + n_rows * row
        for c in self.cx:
            self.parts.append(f'<line x1="{c}" y1="{self.y0}" x2="{c}" y2="{self.y_end}" stroke="var(--rule-strong)" stroke-width="1" stroke-dasharray="3,3"/>')
    def y(self, r):
        return self.top + 96 + r * self.row
    def msg(self, r, a, b, en, hant, kind="call", evidence="", ids=None):
        y = self.y(r); x1, x2 = self.cx[a], self.cx[b]
        color, dash, marker = {
            "call":   ("var(--muted)", None, "arrow"),
            "ret":    ("var(--muted)", "5,4", "arrow"),
            "async":  ("var(--muted)", "5,4", "arrow-open"),
            "accent": ("var(--accent)", None, "arrow-accent"),
            "seal":   ("var(--seal)", None, "arrow-seal"),
            "amber":  ("var(--amber)", None, "arrow-amber"),
        }[kind]
        if a == b:  # self message: U loop, to the right unless this is the last lifeline
            fillc = "var(--accent)" if kind == "accent" else "var(--muted)"
            w = max(est(en), est(hant), est(CC.convert(hant))) + 16; w = int(math.ceil(w / 4) * 4)
            if a == self.n - 1:
                d = f"M {x1},{y-12} H {x1-40} Q {x1-48},{y-12} {x1-48},{y-4} V {y+4} Q {x1-48},{y+12} {x1-40},{y+12} H {x1-6}"
                self.path(d, color, dash, marker, edge=f"{ids[0]}-{ids[1]}" if ids else None)
                self.mask(x1 - 56 - w, y - 8, w, 16)
                self.text(x1 - 64, y + 4, en, hant, fill=fillc, anchor="end", family=MONO)
            else:
                d = f"M {x1},{y-12} H {x1+40} Q {x1+48},{y-12} {x1+48},{y-4} V {y+4} Q {x1+48},{y+12} {x1+40},{y+12} H {x1+6}"
                self.path(d, color, dash, marker, edge=f"{ids[0]}-{ids[1]}" if ids else None)
                self.mask(x1 + 56, y - 8, w, 16)
                self.text(x1 + 64, y + 4, en, hant, fill=fillc, anchor="start", family=MONO)
        else:
            sx = x1 + (6 if x2 > x1 else -6); ex = x2 - (2 if x2 > x1 else -2)
            self.path(f"M {sx},{y} H {ex}", color, dash, marker, edge=f"{ids[0]}-{ids[1]}" if ids else None)
            self.label((x1 + x2) // 2, y - 16, en, hant, fill=("var(--accent)" if kind == "accent" else "var(--seal)" if kind == "seal" else "var(--amber)" if kind == "amber" else "var(--muted)"))
        if ids:
            self.edge(ids[0], ids[1], evidence)
    def frame(self, r0, r1, a, b, op, guard_en, guard_hant, guard2=None, div_r=None):
        x = min(self.cx[a], self.cx[b]) - 100; w = abs(self.cx[b] - self.cx[a]) + 200
        y = self.y(r0) - 48; h = self.y(r1) - y + 20
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="none" stroke="var(--rule-strong)" stroke-width="1"/>')
        self.mask(x, y, 48, 16)
        self.parts.append(f'<rect x="{x}" y="{y}" width="48" height="16" rx="2" fill="none" stroke="var(--rule-strong)" stroke-width="1"/>')
        self.text(x + 24, y + 12, op, op, fill="var(--muted)", family=MONO)
        self.text(x + 60, y + 12, guard_en, guard_hant, fill="var(--muted)", anchor="start", family=MONO)
        if div_r is not None:
            dy = self.y(div_r) - 20
            self.parts.append(f'<line x1="{x+8}" y1="{dy}" x2="{x+w-8}" y2="{dy}" stroke="var(--rule-strong)" stroke-width="1" stroke-dasharray="4,3"/>')
            self.text(x + 12, dy + 14, guard2[0], guard2[1], fill="var(--muted)", anchor="start", family=MONO)

# ======================================================================
# 1. architecture map
# ======================================================================
def fig_map():
    f = Fig("fmmap", 960, 560,
            "firstmate: the three channels", "firstmate：三條溝通管道",
            "Architecture map showing how the captain, the first mate session, the bash watcher, the durable wake queue, a crewmate's status and inbox files, the process-event runner, and the Lavish server connect.",
            "架構圖：captain、firstmate session、bash watcher、durable wake queue、crewmate 的 status 與 inbox 檔案、process-event runner 和 Lavish server 之間如何連接。")
    A, B, C = 64, 400, 760; R1, R2, R3 = 40, 184, 328
    # ---- connectors first (z-order) ----
    # 1 captain -> firstmate
    f.path(f"M {A+160+6},{R1+28} H {B-2}", marker="arrow-fg", color="var(--fg)", edge="captain-firstmate")
    f.label((A+160+B)//2, R1+12, "chat", "聊天")
    f.edge("captain", "firstmate", "AGENTS.md section 1: the captain talks only to the first mate")
    # 2 firstmate -> crewmate
    f.path(f"M {B+200+6},{R1+28} H {C-2}", marker="arrow-fg", color="var(--fg)", edge="firstmate-crewmate")
    f.label((B+200+C)//2, R1+12, "fm-spawn · fm-send", "fm-spawn · fm-send")
    f.edge("firstmate", "crewmate", "bin/fm-spawn.sh and bin/fm-send.sh headers")
    # 3 crewmate -> files (append status), x=864
    f.path(f"M 864,{R1+64+6} V {R2-2}", edge="crewmate-files")
    f.label(864+56, R1+64+40, "append", "追加一行")
    f.edge("crewmate", "files", "bin/fm-brief.sh scaffold: echo \"{state}: {note}\" >> state/<id>.status")
    # 4 watcher -> files (poll), x=816
    f.path(f"M 816,{R3-6} V {R2+64+2}", edge="watcher-files")
    f.label(816-52, R2+64+40, "poll", "輪詢")
    f.edge("watcher", "files", "bin/fm-watch.sh header: classifies status and turn-end signals, polls the inbox ladder")
    # 5 watcher -> queue (left & up)
    f.path(f"M {C-6},{R3+24} H 688 Q 680,{R3+24} 680,{R3+16} V {R2+40} Q 680,{R2+32} 672,{R2+32} H {B+200+2}", color="var(--accent)", marker="arrow-accent", edge="watcher-queue")
    f.label(680, (R3+16+R2+40)//2, "actionable row", "可行動的一列", fill="var(--accent)")
    f.edge("watcher", "queue", "docs/architecture.md: actionable wakes are written to state/.wake-queue, then the watcher exits")
    # 12 watcher -> runner (reconcile / start)
    f.path(f"M {C-6},{R3+48} H {B+200+2}", edge="watcher-runner")
    f.label((C+B+200)//2, R3+48+16, "reconcile · start", "reconcile · start")
    f.edge("watcher", "runner", "bin/fm-procevent.sh header: reconcile is the idempotent liveness entry the watcher calls on its ordinary cycle")
    # 11 runner -> queue (vertical x=500)
    f.path(f"M 500,{R3-6} V {R2+64+2}", color="var(--accent)", marker="arrow-accent", edge="runner-queue")
    f.label(500+64, R2+64+40, "check wake", "check wake", fill="var(--accent)")
    f.edge("runner", "queue", "bin/fm-watch.sh header: check: process-event result captured")
    # 6 queue -> firstmate (vertical x=500)
    f.path(f"M 500,{R2-6} V {R1+64+2}", color="var(--accent)", marker="arrow-accent", edge="queue-firstmate")
    f.label(500+72, R1+64+40, "rewake · drain", "rewake · drain", fill="var(--accent)")
    f.edge("queue", "firstmate", "bin/fm-claude-stop-autoarm.sh: exit 2 delivers the rewake banner; bin/fm-wake-drain.sh presents the rows")
    # 7 firstmate -> board
    f.path(f"M 440,{R1+64+6} V 144 Q 440,152 432,152 H 128 Q 120,152 120,160 V {R2-2}", edge="firstmate-board")
    f.label(280, 152-16, "build · serve", "build · serve")
    f.edge("firstmate", "board", "bin/fm-bearings-board.sh build: template + payload, then lavish-axi serves it and the session is proved live")
    # 8 board -> server
    f.path(f"M 120,{R2+64+6} V {R3-2}", edge="board-server")
    f.label(120+48, (R2+64+R3)//2, "serves", "提供頁面")
    f.edge("board", "server", "lavish-axi <html-file> opens a session on http://127.0.0.1:4387")
    # 9 captain -> server via left gutter
    f.path(f"M {A-6},{R1+40} H 40 Q 32,{R1+40} 32,{R1+48} V {R3+24} Q 32,{R3+32} 40,{R3+32} H {A-2}", edge="captain-server")
    f.label(A+48, 124, "answers in browser", "在瀏覽器裡作答")
    f.edge("captain", "server", ".agents/skills/bearings/SKILL.md: the captain answers Captain's Call items directly on the board")
    # 10 runner -> server (below the watcher row)
    f.path(f"M 840,{R3+64+6} V 432 Q 840,440 832,440 H 128 Q 120,440 120,432 V {R3+64+2}", color="var(--seal)", marker="arrow-seal", edge="runner-server")
    f.label(480, 440-16, "lavish-axi poll (blocking; clears feedback)", "lavish-axi poll（阻塞；回傳即清除）", fill="var(--seal)")
    f.edge("runner", "server", "bin/fm-procevent-lavish.sh header: wraps `lavish-axi poll <html-file>`, which long-polls indefinitely and destructively clears feedback")
    # ---- nodes ----
    f.node("captain", A, R1, 160, 64, "Captain", "Captain", ("chat · browser", "chat · browser"), "ext")
    f.node("firstmate", B, R1, 200, 64, "First mate session", "firstmate session", ("bin/fm-*.sh", "bin/fm-*.sh"), "focal")
    f.node("crewmate", C, R1, 160, 64, "Crewmate pane", "crewmate pane", ("own worktree", "自己的 worktree"), "plain")
    f.node("board", A, R2, 160, 64, "Board / artifact", "看板 / artifact", (".lavish/*.html", ".lavish/*.html"), "store")
    f.node("queue", B, R2, 200, 64, "Wake queue", "wake queue", ("state/.wake-queue", "state/.wake-queue"), "store")
    f.node("files", C, R2, 160, 64, "Task records", "任務紀錄檔", (".status · .inbox/", ".status · .inbox/"), "store")
    f.node("server", A, R3, 160, 64, "Lavish server", "Lavish server", ("lavish-axi :4387", "lavish-axi :4387"), "ext")
    f.node("runner", B, R3, 200, 64, "Process-event runner", "process-event runner", ("bin/fm-procevent.sh", "bin/fm-procevent.sh"), "plain")
    f.node("watcher", C, R3, 160, 64, "Watcher", "watcher", ("bin/fm-watch.sh", "bin/fm-watch.sh"), "plain")
    f.legend(500, [
        ("first mate (subject)", "firstmate（主角）", "var(--accent-tint)", "var(--accent)", None),
        ("durable record", "durable 紀錄", "var(--card-2)", "var(--muted)", None),
        ("outside firstmate", "firstmate 之外", "var(--card)", "var(--muted)", "4,3"),
        ("lossy step", "會丟資料的一步", "var(--card)", "var(--seal)", None),
    ])
    f.write()

# ======================================================================
# 2. steer sequence
# ======================================================================
def fig_steer():
    s = Seq("fmsteer",
            [("fm", "First mate", "firstmate", None, "focal"),
             ("send", "fm-send.sh", "fm-send.sh", ("steer data plane", "steer 資料層"), "plain"),
             ("inbox", "Steering inbox", "steering inbox", ("state/<id>.inbox/", "state/<id>.inbox/"), "store"),
             ("pane", "Worker pane", "worker pane", ("tmux · herdr · …", "tmux · herdr · …"), "plain"),
             ("watch", "Watcher", "watcher", ("bin/fm-watch.sh", "bin/fm-watch.sh"), "plain")],
            10,
            ("Steering a crewmate: the record is the delivery", "steer 一個 crewmate：紀錄本身就是送達"),
            ("Sequence showing fm-send writing a durable inbox record, ringing a constant doorbell, the worker acknowledging by moving the file, and the watcher re-ringing then escalating when no acknowledgement arrives.",
             "Sequence：fm-send 寫入 durable inbox 紀錄、敲一行固定的 doorbell、worker 用搬檔案來 ack，沒 ack 時 watcher 重敲再升級。"))
    H = "bin/fm-send.sh header; bin/fm-task-inbox-lib.sh header"
    s.msg(0, 0, 1, 'fm-send <id> "text" [--resolve-key k]', 'fm-send <id> "text" [--resolve-key k]', ids=("fm", "send"), evidence=H)
    s.msg(1, 1, 2, "write NNN.msg (seq lock, atomic rename)", "寫入 NNN.msg（seq lock、atomic rename）", kind="accent", ids=("send", "inbox"), evidence=H)
    s.msg(2, 1, 3, "doorbell line + Enter (best-effort)", "doorbell 一行 + Enter（盡力而為）", kind="async", ids=("send", "pane"), evidence="fm_task_inbox_doorbell_line: ': Firstmate instruction waiting: list <dir>/*.msg …'")
    s.msg(3, 1, 0, "exit 0 = durably recorded", "exit 0 = 已 durable 記錄", kind="ret", ids=("send", "fm"), evidence=H)
    s.msg(4, 3, 2, "list *.msg, read, act in order", "列出 *.msg，依序讀取並執行", ids=("pane", "inbox"), evidence="bin/fm-brief.sh inbox section")
    s.msg(5, 3, 2, "mv NNN.msg handled/  (= ack)", "mv NNN.msg handled/（= ack）", kind="accent", ids=("pane", "inbox"), evidence="bin/fm-task-inbox-lib.sh: the worker's mv here IS the acknowledgement")
    s.frame(7, 9, 2, 4, "OPT", "[no ack after 90s grace]", "[過了 90 秒 grace 還沒 ack]")
    s.msg(7, 4, 2, "read .ring-state", "讀 .ring-state", ids=("watch", "inbox"), evidence="bin/fm-task-inbox-lib.sh: .ring-state '<msg>\\t<count>\\t<epoch>'")
    s.msg(8, 4, 3, "re-ring, up to 3 attempts", "重敲，最多 3 次", kind="amber", ids=("watch", "pane"), evidence="FM_TASK_INBOX_GRACE_SECS=90, FM_TASK_INBOX_RING_MAX=3")
    s.msg(9, 4, 0, "stale: (unread firstmate instruction)", "stale:（firstmate 指令未讀）", kind="async", ids=("watch", "fm"), evidence="bin/fm-watch.sh header: stale: <window> (unread firstmate instruction: ...)")
    s.legend(s.h - 40, [
        ("durable step", "durable 步驟", "var(--card)", "var(--accent)", None),
        ("best-effort / async", "盡力而為 / 非同步", "var(--card)", "var(--muted)", "5,4"),
        ("escalation", "升級", "var(--card)", "var(--amber)", None),
    ])
    s.write()

# ======================================================================
# 3. status -> wake sequence
# ======================================================================
def fig_status():
    s = Seq("fmwake",
            [("pane", "Worker", "worker", ("in its pane", "在自己的 pane"), "plain"),
             ("status", "Status log", "status log", ("state/<id>.status", "state/<id>.status"), "store"),
             ("watch", "Watcher", "watcher", ("bin/fm-watch.sh", "bin/fm-watch.sh"), "plain"),
             ("hook", "Stop hook", "Stop hook", ("fm-claude-stop-autoarm", "fm-claude-stop-autoarm"), "plain"),
             ("fm", "First mate", "firstmate", None, "focal")],
            12,
            ("A crewmate reaches the first mate: one appended line", "crewmate 找到 firstmate：追加一行"),
            ("Sequence showing a worker appending a status line, the watcher classifying it, absorbing a benign wake or queuing an actionable one and exiting, the Claude Stop hook rewaking the first mate, and the drain plus acknowledgement that closes the loop.",
             "Sequence：worker 追加一行 status，watcher 分類後吸收或排入 queue 並退出，Claude Stop hook 叫醒 firstmate，drain 加 ack 收尾。"))
    s.msg(0, 0, 1, 'echo "done: PR <url>" >> status', 'echo "done: PR <url>" >> status', ids=("pane", "status"), evidence="bin/fm-brief.sh scaffold, states: working, needs-decision, blocked, paused, done, failed")
    s.msg(1, 2, 1, "poll + classify (fm-classify-lib)", "輪詢 + 分類（fm-classify-lib）", ids=("watch", "status"), evidence="bin/fm-classify-lib.sh header")
    s.frame(3, 5, 1, 3, "ALT", "[no verb + crew provably working]", "[沒有動詞 + crew 確實在做事]", guard2=("[actionable]", "[需要行動]"), div_r=4)
    s.msg(3, 2, 2, "absorb, keep blocking", "吸收，繼續等", ids=("watch", "watch"), evidence="docs/architecture.md: absorbed wakes advance markers and keep the watcher blocking without a queue record or LLM turn")
    s.msg(5, 2, 2, "append state/.wake-queue row, exit", "寫一列 state/.wake-queue 後退出", kind="accent", ids=("watch", "watch"), evidence="state/.wake-queue: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload")
    s.msg(7, 2, 3, "arm returns (watcher exited)", "arm 返回（watcher 已退出）", kind="ret", ids=("watch", "hook"), evidence="bin/fm-claude-stop-autoarm.sh: the Stop hook foregrounds bin/fm-watch-arm.sh")
    s.msg(8, 3, 4, "exit 2 → \"Stop hook feedback\"", "exit 2 →「Stop hook feedback」", kind="accent", ids=("hook", "fm"), evidence="bin/fm-claude-stop-autoarm.sh: exit 2 carries the rewake banner on stderr")
    s.msg(9, 4, 4, "fm-wake-drain.sh: rows + OPEN DECISIONS", "fm-wake-drain.sh：rows + OPEN DECISIONS", ids=("fm", "fm"), evidence="AGENTS.md section 8; bin/fm-wake-drain.sh header")
    s.msg(10, 4, 4, "handle, then --ack-through <gen>", "處理完再 --ack-through <gen>", ids=("fm", "fm"), evidence="AGENTS.md section 8: WAKE_ACK_REQUIRED")
    s.msg(11, 4, 3, "turn ends → hook re-arms watcher", "回合結束 → hook 重新 arm watcher", kind="async", ids=("fm", "hook"), evidence="session-start supervision block: every turn end launches or attaches one watcher cycle")
    s.legend(s.h - 40, [
        ("the wake itself", "喚醒本身", "var(--card)", "var(--accent)", None),
        ("return / async", "回傳 / 非同步", "var(--card)", "var(--muted)", "5,4"),
    ])
    s.write()

# ======================================================================
# 4. lavish sequence
# ======================================================================
def fig_lavish():
    s = Seq("fmlavish",
            [("fm", "First mate", "firstmate", None, "focal"),
             ("runner", "Runner", "runner", ("bin/fm-procevent.sh", "bin/fm-procevent.sh"), "plain"),
             ("lavish", "Lavish server", "Lavish server", ("lavish-axi", "lavish-axi"), "ext"),
             ("captain", "Captain", "Captain", ("browser", "瀏覽器"), "ext"),
             ("hold", "Keyed-answer intake", "keyed-answer intake", ("bin/fm-captain-hold.sh", "bin/fm-captain-hold.sh"), "plain")],
            12,
            ("A Lavish answer travels back without a blocked turn", "Lavish 的回答回到 firstmate，過程不卡任何回合"),
            ("Sequence showing the board served and proved live, the answer source bound before it is armed, a detached runner blocking on lavish-axi poll, the captain answering, the result captured and announced as a wake, choice answers fed to the captain-hold intake, and the first mate reading and acknowledging.",
             "Sequence：看板先提供並證明 live、答案來源先 bind 再 arm、runner 在背景阻塞於 lavish-axi poll、captain 作答、結果被捕捉並發出喚醒、選項答案餵給 captain-hold intake、firstmate 讀取並 ack。"))
    B = "bin/fm-bearings-board.sh header"
    s.msg(0, 0, 2, "lavish-axi board.html → session proved live", "lavish-axi board.html → 證明 session live", ids=("fm", "lavish"), evidence=B)
    s.msg(1, 0, 4, "bind <source-id>  (always before arm)", "bind <source-id>（一定在 arm 之前）", ids=("fm", "hold"), evidence=B + ": bind ALWAYS precedes arm")
    s.msg(2, 0, 1, "fm-procevent-lavish.sh arm board.html", "fm-procevent-lavish.sh arm board.html", ids=("fm", "runner"), evidence=".agents/skills/process-event-sources/SKILL.md")
    s.msg(3, 1, 2, "lavish-axi poll (blocking, detached from the turn)", "lavish-axi poll（阻塞，脫離回合）", kind="seal", ids=("runner", "lavish"), evidence="bin/fm-procevent-lavish.sh header: plain blocking form, no timeout flag")
    s.msg(4, 3, 2, "answer cards, Send / Send & End", "在卡片上作答，Send / Send & End", ids=("captain", "lavish"), evidence=".agents/skills/bearings/SKILL.md Lavish board mode")
    s.msg(5, 2, 1, "poll returns feedback (server clears it first)", "poll 回傳 feedback（server 先清掉）", kind="ret", ids=("lavish", "runner"), evidence="bin/fm-procevent-lavish.sh header: LOSS LIMITATION")
    s.msg(6, 1, 1, "capture state/procevent-inbox/<id>.<seq>.result", "捕捉到 state/procevent-inbox/<id>.<seq>.result", kind="accent", ids=("runner", "runner"), evidence="bin/fm-procevent-lib.sh: fm_procevent_inbox_dir")
    s.msg(7, 1, 4, "answers: choice rows → close / release held tasks", "answers：choice 列 → 關閉 / 釋放被 hold 的任務", kind="accent", ids=("runner", "hold"), evidence="bin/fm-procevent-lavish.sh header: `answers` reports <task-id>\\t<answer>\\t<label>; bin/fm-captain-hold.sh answers")
    s.msg(8, 1, 0, "check: process-event result captured", "check: process-event result captured", kind="async", ids=("runner", "fm"), evidence="bin/fm-watch.sh header (via state/.wake-queue and the Stop hook rewake)")
    s.msg(9, 0, 1, "classify · read · handled <id> <seq>", "classify · read · handled <id> <seq>", ids=("fm", "runner"), evidence=".agents/skills/process-event-sources/SKILL.md Handling a wake")
    s.frame(11, 11, 1, 2, "OPT", "[ended with nothing said]", "[結束但什麼都沒說]")
    s.msg(11, 1, 1, "silent → recorded handled, never announced", "silent → 記為 handled，永不通知", ids=("runner", "runner"), evidence="bin/fm-procevent-lavish.sh header: AN EMPTY BOARD CLOSE IS NOT NEWS")
    s.legend(s.h - 40, [
        ("durable capture / answer", "durable 捕捉 / 回答", "var(--card)", "var(--accent)", None),
        ("lossy window", "會丟資料的窗口", "var(--card)", "var(--seal)", None),
        ("return / async", "回傳 / 非同步", "var(--card)", "var(--muted)", "5,4"),
    ])
    s.write()

# ======================================================================
# 5. subagent tool vs crewmate
# ======================================================================
def fig_guard():
    f = Fig("fmguard", 960, 400,
            "Harness subagent vs crewmate", "harness 的 subagent vs crewmate",
            "Two panels: the harness's own Agent tool is denied by a PreToolUse guard because such work leaves no fleet record and dies with the session; a crewmate goes through fm-brief and fm-spawn and gets a worktree, a pane, metadata, and a status log the watcher can see.",
            "兩個面板：harness 自帶的 Agent 工具被 PreToolUse guard 擋下，因為那種工作沒有 fleet 紀錄、session 一死就沒了；crewmate 走 fm-brief 和 fm-spawn，拿到 worktree、pane、metadata 和 watcher 看得到的 status log。")
    # panel frames (drawn first, zones)
    f.parts.append('<rect x="32" y="32" width="424" height="296" rx="6" fill="none" stroke="var(--rule)" stroke-width="1"/>')
    f.parts.append('<rect x="504" y="32" width="424" height="296" rx="6" fill="none" stroke="var(--rule)" stroke-width="1"/>')
    f.text(48, 56, "LEFT: the Agent tool (denied)", "左：Agent 工具（被擋）", fill="var(--muted)", anchor="start", family=MONO)
    f.text(520, 56, "RIGHT: the fleet path", "右：fleet 的路", fill="var(--muted)", anchor="start", family=MONO)
    # left panel: primary -> Agent tool -> guard (seal); consequence box beside it
    f.path("M 166,126 V 150", edge="lp-tool")
    f.path("M 166,206 V 230", color="var(--seal)", marker="arrow-seal", edge="lt-guard")
    f.node("primary-l", 86, 72, 160, 48, "Primary session", "primary session", None, "focal")
    f.node("agent-tool", 86, 152, 160, 48, "Agent / Task tool", "Agent / Task 工具", None, "plain")
    f.node("guard", 66, 232, 200, 48, "PreToolUse guard: deny", "PreToolUse guard：拒絕", ("fm-subagent-pretool-check.sh", "fm-subagent-pretool-check.sh"), "seal")
    f.edge("primary-l", "agent-tool", "this session: Agent(claude-code-guide) was attempted")
    f.edge("agent-tool", "guard", "observed this session: permissionDecision deny, '[subagent-dispatch] the firstmate primary dispatches through the fleet'")
    f.mask(286, 152, 160, 128, rx=6)
    f.rect(286, 152, 160, 128, "var(--card)", "var(--muted)", node="consequence", dash="4,3")
    f.text(366, 176, "if it had run:", "如果沒擋住：", fill="var(--muted)", family=MONO)
    f.text(366, 200, "no state/<id>.meta", "沒有 state/<id>.meta", fill="var(--fg)", family=MONO)
    f.text(366, 220, "no brief, no worktree", "沒 brief、沒 worktree", fill="var(--fg)", family=MONO)
    f.text(366, 240, "watcher sees nothing", "watcher 看不到", fill="var(--fg)", family=MONO)
    f.text(366, 260, "dies with the session", "session 一死就沒了", fill="var(--seal)", family=MONO)
    # right panel
    f.path("M 638,126 V 150", edge="rp-brief")
    f.path("M 638,206 V 230", edge="rb-spawn")
    f.path("M 720,256 H 748", marker="arrow", edge="rs-crew")
    f.node("primary-r", 558, 72, 160, 48, "Primary session", "primary session", None, "focal")
    f.node("brief", 558, 152, 160, 48, "bin/fm-brief.sh", "bin/fm-brief.sh", ("brief.md scaffold", "brief.md 骨架"), "plain")
    f.node("spawn", 558, 232, 160, 48, "bin/fm-spawn.sh", "bin/fm-spawn.sh", ("meta · backlog · pane", "meta · backlog · pane"), "plain")
    f.node("crew", 750, 216, 160, 80, "Crewmate", "crewmate", ("worktree · status log", "worktree · status log"), "store")
    f.edge("primary-r", "brief", "AGENTS.md section 7: write the brief before spawning")
    f.edge("brief", "spawn", "bin/fm-spawn.sh header: reads the brief's Delivery contract line and refuses a mismatch")
    f.edge("spawn", "crew", "bin/fm-spawn.sh header: isolated worktree, state/<id>.meta, backlog transition to In flight")
    f.legend(360, [
        ("primary session", "primary session", "var(--accent-tint)", "var(--accent)", None),
        ("refused", "被拒絕", "var(--card)", "var(--seal)", None),
        ("durable fleet record", "durable fleet 紀錄", "var(--card-2)", "var(--muted)", None),
    ])
    f.write()

if __name__ == "__main__":
    fig_map(); fig_steer(); fig_status(); fig_lavish(); fig_guard()
