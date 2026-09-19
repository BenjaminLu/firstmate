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
