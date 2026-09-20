#!/usr/bin/env bash
# End-to-end behavior tests for the captain's board, driven the way he drives
# it: a fresh copy of this repository with nothing installed, the board's own
# server, a real browser, and a real click.
#
# WHY THIS FILE EXISTS. Three defects reached the captain in one afternoon on
# 2026-09-20 and not one was caught by a test. A live server pushed a merge
# built from a four-hour-old board over a page built minutes earlier, so his
# board showed no open calls while twenty were open. The board rendered that as
# "nothing needs you, captain" directly under its own badge saying changes were
# waiting - the two statements the code says cannot both be shown. And the
# process serving his board had started hours before the code that carried his
# click to firstmate existed, so every press went nowhere, silently, while
# `status` said answers could be sent back. All three were found by a person
# opening a browser, and all three were invisible from the page.
#
# The suite had a file with `e2e` in its name. It guarded lavish-axi's own
# behavior, said in its own header that no browser was needed, and reported a
# capability skip in CI. Two other files asserted against hand-built fixtures,
# one of which a review proved constructed a state the server cannot reach, and
# a third ran the template under a DOM shim whose text measurements were found
# wrong by up to 21 percent against Chrome. Nothing drove a real browser
# against a real server, so nothing could have caught any of the three.
#
# WHAT IS ASSERTED HERE, and every one of them is a defect that shipped:
#
#   1. A clone with nothing installed gets a URL, and that URL serves the
#      board. This is the captain's own definition of done for this work -
#      "clone 下來要能直接用" - so it is the setup for every case below rather
#      than one assertion among them.
#   2. Hot reload, the page half: an event is published and the open page
#      reflects it with nobody reloading anything.
#   3. Hot reload, the server half: a server whose own code has changed on disk
#      is detectable from outside the process, and does not go on serving.
#   4. The click lands: a real mouse press on a real option reaches this home,
#      and what was clicked is recoverable afterwards.
#   5. The board is never taken backwards.
#   6. A board that is behind never tells the captain his desk is empty.
#
# HOW THE FIXTURES ARE MADE, because two of the three defects above hid behind
# fixtures that could not happen. Every state here is produced by running the
# shipped code: the boards are built by `fm-bearings-board.sh`, the events are
# published by `fm-board-live.sh event`, the merge is done by the running
# server, and the page is the one the server serves. Nothing composes a payload
# by hand and nothing reads the source of what it is testing.
#
# WHAT IT COSTS. One script on the existing portable serial lane - no new job,
# no new runner. It launches one headless browser per case and needs no
# credential and no network.
#
# A MISSING BROWSER IS NOT A PASS. This file reports `skip: chrome not found`
# only when the machine genuinely has no browser, and CI refuses that skip with
# --fail-on-gate-skip, because a capability skip reported as a pass is exactly
# how the previous e2e file became decoration.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROWSER="$ROOT/tests/assets/board-browser.mjs"
TMP_ROOT=$(fm_test_tmproot fm-board-clone-e2e)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# The clone's PATH: the system directories every machine has, plus a directory
# holding links to the individual tools this setup grants and nothing else.
# Putting node's own directory on the path instead would drag in whatever else
# shares it - on a developer machine that is homebrew, and lavish-axi lives
# there - so the grant is made one tool at a time and the first case proves
# lavish-axi really is out of reach before it concludes anything.
CLONE_BIN="$TMP_ROOT/clone-bin"
CLONE_BIN_BACKLOG="$TMP_ROOT/clone-bin-backlog"
CLONE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$CLONE_BIN"
CLONE_PATH_BACKLOG="/usr/bin:/bin:/usr/sbin:/sbin:$CLONE_BIN_BACKLOG"

grant_tool() {  # <dir> <tool>
  local dir=$1 tool=$2 path
  path=$(command -v "$2") || return 1
  mkdir -p "$dir" || return 1
  ln -sf "$path" "$dir/$tool" || return 1
}

STARTED_HOMES=()
cleanup_e2e() {
  local home
  for home in ${STARTED_HOMES[@]+"${STARTED_HOMES[@]}"}; do
    [ -n "${CLONE:-}" ] || continue
    FM_HOME="$home" "$CLONE/bin/fm-board-live.sh" stop >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_e2e EXIT INT TERM

# --- the clone ---------------------------------------------------------------
#
# The tracked tree as it stands, copied into a directory with no git history,
# no node_modules, and nothing else of this machine. It is what `git clone`
# delivers once the current work is committed, and deliberately stronger than
# cloning HEAD: an uncommitted change to the board is tested here rather than
# passing because the commit had not been made yet.
CLONE="$TMP_ROOT/firstmate"
make_clone() {
  local file dest
  mkdir -p "$CLONE" || return 1
  ( cd "$ROOT" && git ls-files -z ) > "$TMP_ROOT/tracked" 2>/dev/null || return 1
  while IFS= read -r -d '' file; do
    [ -f "$ROOT/$file" ] || continue
    dest="$CLONE/$file"
    mkdir -p "${dest%/*}" || return 1
    cp -p "$ROOT/$file" "$dest" || return 1
  done < "$TMP_ROOT/tracked"
  [ -x "$CLONE/bin/fm-bearings-board.sh" ] || return 1
  [ -f "$CLONE/.agents/skills/bearings/assets/board-template.html" ] || return 1
}

# Run one of the clone's commands the way a fresh machine would: its own PATH,
# its own empty home, and nothing inherited from this session.
in_clone() {  # <home> <argv...>
  local home=$1
  shift
  env -i \
    PATH="$CLONE_PATH" \
    HOME="$TMP_ROOT/fakehome" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FM_HOME="$home" \
    "$@"
}

# The same, with the configured backlog backend reachable. Named separately so
# no case can quietly acquire it.
in_clone_with_backlog() {  # <home> <argv...>
  local home=$1
  shift
  env -i \
    PATH="$CLONE_PATH_BACKLOG" \
    HOME="$TMP_ROOT/fakehome" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FM_HOME="$home" \
    BEADS_ACTOR=fixture \
    "$@"
}

make_home() {  # <name> <payload-json-text> ; prints the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" || return 1
  printf '%s\n' "$2" > "$home/payload.json" || return 1
  printf '%s\n' "$home"
}

# Build the board in a home through the shipped command, and print the URL it
# says the captain can open. Every failure is the case's, not a skip.
#
# The build also starts the server, and the server is what later runs the
# answer path, so whether the backlog backend is reachable from it is settled
# here and nowhere else. Starting the server without it and then reaching for
# it at the click is exactly the shape that produced `answer-path-refused`
# while every other case stayed green.
build_board() {  # <home> [--with-backlog] ; prints the url
  local home=$1 out url
  STARTED_HOMES+=("$home")
  if [ "${2-}" = --with-backlog ]; then
    out=$(in_clone_with_backlog "$home" "$CLONE/bin/fm-bearings-board.sh" build "$home/payload.json" 2>&1) || {
      printf '%s\n' "$out" >&2
      return 1
    }
  else
    out=$(in_clone "$home" "$CLONE/bin/fm-bearings-board.sh" build "$home/payload.json" 2>&1) || {
      printf '%s\n' "$out" >&2
      return 1
    }
  fi
  url=$(printf '%s\n' "$out" | awk '/^url: / { sub(/^url: /, ""); print; exit }')
  [ -n "$url" ] || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s\n' "$url"
}

# One browser session against a real URL, driving the steps in <steps-json>.
# Prints the driver's JSON, or fails the case. Whether this machine has a
# browser at all is settled once, below, and never inside a case: a case that
# could retire itself to a skip is the shape that made the previous end-to-end
# file decoration.
drive() {  # <url> <steps-json> [timeout-ms]
  local url=$1 steps=$2 timeout=${3:-90000} out
  if ! out=$(printf '%s' "$steps" | node "$BROWSER" "$url" - --timeout-ms "$timeout" 2>"$TMP_ROOT/browser.err"); then
    fail "the browser could not drive $url: $(cat "$TMP_ROOT/browser.err")"
  fi
  printf '%s\n' "$out"
}

# What the page said and what went wrong in it, for a failure message that can
# be acted on rather than guessed at.
browser_evidence() {  # <driver-json>
  printf '%s' "$1" | jq -c '{steps: .steps, console: .console, errors: .errors}' 2>/dev/null
}

PAYLOAD_ONE_CALL='{"schema":"fm-bearings-board.v1","home":"main","generated":"2026-01-01T00:00:00Z",
 "prs_live":false,
 "captains_call":[{"key":"pick-one","type":"decision","repo":"firstmate","title":"Pick one",
   "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]}],
 "underway":[{"id":"alpha","name":"Alpha","repo":"firstmate","state":"working",
   "doing":"review 2/3","kind":"ship"}],
 "landed":[],"charted":[]}'
PAYLOAD_NO_CALLS='{"schema":"fm-bearings-board.v1","home":"main","generated":"2026-01-01T00:00:00Z",
 "prs_live":false,"captains_call":[],
 "underway":[{"id":"alpha","name":"Alpha","repo":"firstmate","state":"working",
   "doing":"review 2/3","kind":"ship"}],
 "landed":[],"charted":[]}'

# Twenty open calls, which is the number that went missing from the captain's
# board, generated rather than typed out.
payload_twenty_calls() {
  jq -nc '{
    schema: "fm-bearings-board.v1", home: "main",
    generated: "2026-01-01T00:10:00Z", prs_live: false,
    captains_call: [range(1; 21) | {
      key: ("call-" + (. | tostring)), type: "decision", repo: "firstmate",
      title: ("Question " + (. | tostring)),
      options: [{value: "yes", label: "Yes"}, {value: "no", label: "No"}]
    }],
    underway: [{id: "alpha", name: "Alpha", repo: "firstmate", state: "working",
      doing: "review 2/3", kind: "ship"}],
    landed: [], charted: []
  }'
}

# The expression every case waits on first: the board is up, its transport is
# connected, and the page says so in the badge the captain reads.
WAIT_LIVE='var e = document.getElementById("bb-live-link"); !!e && e.innerText.indexOf("LIVE") >= 0'

# --- 1. a clone with nothing installed gets a URL ----------------------------

test_a_clone_with_nothing_installed_gets_a_url_that_serves_the_board() {
  local home url page absent
  home=$(make_home clone-url "$PAYLOAD_ONE_CALL") \
    || fail "could not make a home for the clone"
  # The setup is only worth anything if the tool really is out of reach.
  absent=$(in_clone "$home" sh -c 'command -v lavish-axi || true')
  [ -z "$absent" ] || fail "lavish-axi is still reachable from the clone's PATH, so this proves nothing: $absent"

  url=$(build_board "$home") \
    || fail "a clone with nothing installed could not build the board and print a URL"
  case $url in
    http://127.0.0.1:*|http://localhost:*) ;;
    *) fail "the board's URL is not a loopback address a clone can open: $url" ;;
  esac

  # Fetched with node, because node is the one thing this setup grants and a
  # fetch with anything else would be testing that other thing's presence.
  page=$(in_clone "$home" node -e '
    (async () => {
      const res = await fetch(process.argv[1]);
      process.stdout.write(res.status + " " + (res.headers.get("content-type") || "") + "\n");
      process.stdout.write(await res.text());
    })().catch((e) => { process.stderr.write(String(e) + "\n"); process.exit(1); });
  ' "$url") || fail "the URL a clone was handed did not answer at all: $url"

  assert_contains "$(printf '%s\n' "$page" | awk 'NR == 1')" "200 text/html" \
    "the URL a clone was handed did not serve a page"
  assert_contains "$page" '<script id="bearings-data" type="application/json">' \
    "what the URL served is not the board"
  assert_contains "$page" '"schema":"fm-bearings-board.v1"' \
    "the served board carries no board payload"
  pass "a clone with nothing installed builds the board and gets a URL that serves it"
}

# --- 2. hot reload, the page half --------------------------------------------

test_an_open_page_reflects_a_published_event_with_nobody_reloading_it() {
  local home url got steps
  home=$(make_home hot-page "$PAYLOAD_ONE_CALL") || fail "could not make a home"
  url=$(build_board "$home") || fail "the clone could not build a board to open"

  steps=$(jq -nc --arg live "$WAIT_LIVE" --arg live_sh "$CLONE/bin/fm-board-live.sh" --arg home "$home" '[
    {op: "wait", expr: $live, timeout_ms: 30000},
    {op: "eval", expr: "document.body.innerText.indexOf(\"review 2/3\") >= 0"},
    {op: "eval", expr: "window.__navigations = 0; window.addEventListener(\"beforeunload\", function(){window.__navigations++;}); true"},
    {op: "run", argv: [$live_sh, "event", "step", "alpha", "--state", "working", "--detail", "review 3 of 3"], env: {FM_HOME: $home}},
    {op: "wait", expr: "document.body.innerText.indexOf(\"review 3 of 3\") >= 0", timeout_ms: 20000},
    {op: "eval", expr: "document.body.innerText.indexOf(\"review 2/3\") >= 0"},
    {op: "eval", expr: "window.__navigations"}
  ]')
  got=$(drive "$url" "$steps")

  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[0].ok')" \
    "the board never reported itself live in a real browser: $(browser_evidence "$got")"
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[1].value')" \
    "the board did not show the worker's step it was built with"
  assert_equals 0 "$(printf '%s' "$got" | jq -r '.steps[3].exit')" \
    "publishing a fleet event failed: $(printf '%s' "$got" | jq -r '.steps[3].stderr')"
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[4].ok')" \
    "an event was published and the open page never showed it: $(browser_evidence "$got")"
  assert_equals false "$(printf '%s' "$got" | jq -r '.steps[5].value')" \
    "the page kept the worker's old step beside the new one"
  assert_equals 0 "$(printf '%s' "$got" | jq -r '.steps[6].value')" \
    "the page only changed because it was reloaded, which is not hot reload"
  pass "an open page reflects a published event with nobody reloading anything"
}

# --- 3. hot reload, the server half ------------------------------------------
#
# Nothing has ever covered this. A server is started once and outlives every
# update to its own code, and the captain's board was served for five hours by
# a process older than the code that carried his click. The assertion is not
# which remedy is chosen - it may refuse, report, or replace itself - but that
# a stale server is distinguishable from a healthy one from outside it.

test_a_server_running_code_that_has_changed_is_detectable_from_outside_it() {
  local home url healthy stale_status replaced after doctor_exit
  home=$(make_home stale-server "$PAYLOAD_ONE_CALL") || fail "could not make a home"
  url=$(build_board "$home") || fail "the clone could not build a board"

  healthy=$(in_clone "$home" "$CLONE/bin/fm-board-live.sh" status) \
    || fail "a healthy server could not be asked about itself"
  assert_contains "$healthy" "code: current" \
    "a server on the code it was started from does not say so, so nothing here can mean anything"
  in_clone "$home" "$CLONE/bin/fm-board-live.sh" doctor >/dev/null \
    || fail "a healthy home did not pass its own check"

  # The code moves under the running process, which is what a fleet update
  # does. Appending is enough: the process holds what it read at exec, and the
  # copy is put back at the end so the cases after this one run against the
  # clone as it shipped.
  cp -p "$CLONE/bin/fm-board-live.mjs" "$TMP_ROOT/fm-board-live.mjs.orig" \
    || fail "could not keep a copy of the clone's server code"
  printf '\n// the server code changed while a server was running on it\n' \
    >> "$CLONE/bin/fm-board-live.mjs" \
    || fail "could not change the clone's server code"

  stale_status=$(in_clone "$home" "$CLONE/bin/fm-board-live.sh" status) \
    || fail "the server could not be asked about itself after its code changed"
  case $stale_status in
    *"code: current"*)
      fail "a server running superseded code still reports itself healthy, which is the defect: $stale_status" ;;
  esac
  assert_contains "$stale_status" "code: STALE" \
    "a server running superseded code is indistinguishable from a healthy one from outside it"
  # And it says it in a way a home's own check refuses to pass.
  doctor_exit=0
  in_clone "$home" "$CLONE/bin/fm-board-live.sh" doctor >/dev/null 2>&1 || doctor_exit=$?
  [ "$doctor_exit" -ne 0 ] \
    || fail "a home serving the captain's board from superseded code reports itself complete"

  # And it does not go on serving: the next start replaces it rather than
  # reporting it as already running. Every board build calls start, so this is
  # what puts an update in front of the captain instead of leaving it to a
  # restart nobody ever performs.
  replaced=$(in_clone "$home" "$CLONE/bin/fm-board-live.sh" start) \
    || fail "starting over a stale server failed"
  assert_contains "$replaced" "replaced:" \
    "a start over a server running superseded code left it running"
  after=$(in_clone "$home" "$CLONE/bin/fm-board-live.sh" status) \
    || fail "the replacement server could not be asked about itself"
  assert_contains "$after" "code: current" \
    "the replacement server is not on the code now on disk either"
  cp -p "$TMP_ROOT/fm-board-live.mjs.orig" "$CLONE/bin/fm-board-live.mjs" \
    || fail "could not put the clone's server code back"
  pass "a server whose code has moved is detectable from outside it and does not go on serving"
}

# --- 4. the click lands ------------------------------------------------------

test_a_click_on_an_option_reaches_this_home_and_what_was_clicked_is_recoverable() {
  local home url got steps journal backlog_reachable=0 recorded
  home=$(make_home click-lands "$PAYLOAD_ONE_CALL") || fail "could not make a home"
  # The backlog backend, reached by name. Without it the answer is still
  # journalled - which is what makes a press recoverable - but nothing applies
  # it, and this case says which half it proved rather than reporting the
  # weaker half as the whole.
  if command -v tasks-axi >/dev/null 2>&1; then
    backlog_reachable=1
    cp "$ROOT/.tasks.toml" "$home/.tasks.toml" || fail "could not install the backlog config"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md" \
      || fail "could not write the backlog"
    in_clone_with_backlog "$home" "$CLONE/bin/fm-tasks-axi.sh" add pick-one "Pick one" --repo firstmate \
      >/dev/null 2>&1 || fail "could not create the task the card keys"
    in_clone_with_backlog "$home" "$CLONE/bin/fm-captain-hold.sh" hold pick-one \
      --reason "captain must decide" >/dev/null 2>&1 \
      || fail "could not hold the task for the captain"
  fi
  if [ "$backlog_reachable" -eq 1 ]; then
    url=$(build_board "$home" --with-backlog) || fail "the clone could not build a board to click"
  else
    url=$(build_board "$home") || fail "the clone could not build a board to click"
  fi

  # The card's own controls, named once and handed to jq as data so nothing
  # here has to be quoted twice.
  local option_sel='input[name="answer"][value="yes"]'
  local send_sel='form button[type="submit"]'
  steps=$(jq -nc --arg live "$WAIT_LIVE" --arg opt "$option_sel" --arg send "$send_sel" '[
    {op: "wait", expr: $live, timeout_ms: 30000},
    {op: "click", selector: $opt},
    {op: "eval", expr: ("document.querySelector(" + ($opt | tojson) + ").checked")},
    {op: "click", selector: $send},
    {op: "wait", expr: "var s = document.getElementById(\"bb-live-sent\"); !!s && !s.hidden", timeout_ms: 30000},
    {op: "wait", expr: "var s = document.getElementById(\"bb-live-sent\"); !!s && !s.hidden && /RECORDED/.test(s.innerText.toUpperCase())", timeout_ms: 120000},
    {op: "text", selector: "#bb-live-sent"}
  ]')
  got=$(drive "$url" "$steps" 240000)

  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[1].ok')" \
    "no option on the captain's card could actually be pressed: $(browser_evidence "$got")"
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[2].value')" \
    "pressing the option did not select it"
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[3].ok')" \
    "the button that sends the captain's answer could not be pressed: $(browser_evidence "$got")"
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[5].ok')" \
    "the page never said what became of the press: $(browser_evidence "$got")"

  # A board that accepts a click and records nothing is the failure the captain
  # met, so the record is read from disk rather than from the page's own word.
  journal="$home/state/board-inbound.jsonl"
  [ -f "$journal" ] || fail "the captain's press reached no durable record in this home"
  recorded=$(jq -r 'select(.type == "answer") | .rows[]' "$journal" | head -1)
  assert_contains "$recorded" "pick-one" \
    "the record of the press does not say which call was answered: $recorded"
  assert_contains "$recorded" "yes" \
    "the record of the press does not say which option was clicked: $recorded"

  if [ "$backlog_reachable" -eq 1 ]; then
    assert_not_contains "$(printf '%s' "$got" | jq -r '.steps[6].value' | tr '[:lower:]' '[:upper:]')" "NOT RECORDED" \
      "the page told the captain his answer was not recorded: $(printf '%s' "$got" | jq -r '.steps[6].value')"
    local held
    held=$(in_clone_with_backlog "$home" "$CLONE/bin/fm-tasks-axi.sh" show pick-one 2>&1) \
      || fail "the task the captain answered could not be read back"
    assert_contains "$held" "yes" \
      "the captain's answer never reached the record that owns the call: $held"
    pass "a real click reaches this home, is recoverable, and lands on the call it answered"
  else
    pass "a real click reaches this home and is recoverable (the backlog backend is not installed, so only the durable record was checked)"
  fi
}

# --- 5. the board is never taken backwards -----------------------------------
#
# The exact sequence that shipped: a page built from current state, a server
# whose own base is older than that page, and an event published after the page
# was built. The page must not lose rows.

test_an_event_never_takes_the_open_board_back_to_an_older_build() {
  local home url got steps
  home=$(make_home not-backwards "$PAYLOAD_NO_CALLS") || fail "could not make a home"
  # The old board first, and the server takes its base from it.
  url=$(build_board "$home") || fail "the clone could not build the older board"
  # Then the board the captain actually opens, built minutes later with the
  # twenty calls that went missing from his.
  payload_twenty_calls > "$home/payload.json" || fail "could not write the newer payload"
  in_clone "$home" "$CLONE/bin/fm-bearings-board.sh" build "$home/payload.json" >/dev/null 2>&1 \
    || fail "the clone could not rebuild the board"

  steps=$(jq -nc --arg live "$WAIT_LIVE" --arg live_sh "$CLONE/bin/fm-board-live.sh" --arg home "$home" '[
    {op: "wait", expr: $live, timeout_ms: 30000},
    {op: "text", selector: "#bb-call-sub"},
    # Every value that subtitle takes from here on, recorded as it happens, so
    # a board that dips to an empty desk and recovers before the next look is
    # still caught.
    {op: "eval", expr: "window.__seen = []; var sub = document.getElementById(\"bb-call-sub\"); window.__obs = new MutationObserver(function(){ var s = document.getElementById(\"bb-call-sub\"); if (s) window.__seen.push(s.innerText); }); window.__obs.observe(document.body, {childList: true, subtree: true, characterData: true}); !!sub"},
    {op: "run", argv: [$live_sh, "event", "step", "alpha", "--state", "working", "--detail", "review 3 of 3"], env: {FM_HOME: $home}},
    {op: "wait", expr: "document.body.innerText.indexOf(\"review 3 of 3\") >= 0", timeout_ms: 20000},
    {op: "text", selector: "#bb-call-sub"},
    {op: "eval", expr: "window.__seen.join(\" | \")"}
  ]')
  got=$(drive "$url" "$steps")

  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[0].ok')" \
    "the board never reported itself live: $(browser_evidence "$got")"
  assert_contains "$(printf '%s' "$got" | jq -r '.steps[1].value')" "20" \
    "the page the captain opened did not show the twenty calls it was built with"
  assert_equals 0 "$(printf '%s' "$got" | jq -r '.steps[3].exit')" \
    "publishing a fleet event failed: $(printf '%s' "$got" | jq -r '.steps[3].stderr')"
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[4].ok')" \
    "the published event never reached the page at all, so nothing below was tested"
  assert_contains "$(printf '%s' "$got" | jq -r '.steps[5].value')" "20" \
    "an event pushed an older board over the page and the captain's open calls disappeared"
  case $(printf '%s' "$got" | jq -r '.steps[6].value' | tr '[:upper:]' '[:lower:]') in
    *"nothing needs you"*)
      fail "the board passed through an empty desk on its way: $(printf '%s' "$got" | jq -r '.steps[6].value')" ;;
  esac
  pass "an event never takes the open board back to an older build"
}

# --- 6. a behind board never says the desk is empty --------------------------

test_a_board_that_is_behind_never_tells_the_captain_his_desk_is_empty() {
  local home url got steps behind text
  home=$(make_home behind-desk "$PAYLOAD_NO_CALLS") || fail "could not make a home"
  url=$(build_board "$home") || fail "the clone could not build a board"

  # A call is the one thing an event cannot carry, because its words are
  # firstmate's to compose. The server marks the board behind, and this is the
  # state the captain was shown as "nothing needs you, captain".
  steps=$(jq -nc --arg live "$WAIT_LIVE" --arg live_sh "$CLONE/bin/fm-board-live.sh" --arg home "$home" '[
    {op: "wait", expr: $live, timeout_ms: 30000},
    {op: "text", selector: "#bb-call-sub"},
    {op: "run", argv: [$live_sh, "event", "call", "newtask"], env: {FM_HOME: $home}},
    {op: "wait", expr: "var b = document.getElementById(\"bb-live-behind\"); !!b && !b.hidden", timeout_ms: 20000},
    {op: "text", selector: "#bb-live-behind"},
    {op: "eval", expr: "document.body.innerText"}
  ]')
  got=$(drive "$url" "$steps")

  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[0].ok')" \
    "the board never reported itself live: $(browser_evidence "$got")"
  # The board must say it is behind, or the contradiction below is untested.
  assert_equals true "$(printf '%s' "$got" | jq -r '.steps[3].ok')" \
    "a change the fleet could not word never made the board say it was behind: $(browser_evidence "$got")"
  behind=$(printf '%s' "$got" | jq -r '.steps[4].value')
  # The board's stylesheet upper-cases its badges, and innerText reports what
  # the browser rendered, so this reads the way the captain sees it.
  assert_contains "$(printf '%s' "$behind" | tr '[:upper:]' '[:lower:]')" "rebuild" \
    "the behind badge does not say what is owed: $behind"

  text=$(printf '%s' "$got" | jq -r '.steps[5].value' | tr '[:upper:]' '[:lower:]')
  case $text in
    *"nothing needs you"*)
      fail "the board told the captain nothing needs him while its own badge said changes were waiting: $behind" ;;
  esac
  pass "a board that is behind never tells the captain his desk is empty"
}

# Asked once, answered once. Exit 3 is the driver's reserved "this machine has
# no browser"; anything else from it is a broken driver and fails.
probe_status=0
BROWSER_PATH=$(node "$BROWSER" --probe 2>"$TMP_ROOT/probe.err") || probe_status=$?
if [ "$probe_status" -eq 3 ]; then
  echo "skip: chrome not found"
  exit 0
fi
[ "$probe_status" -eq 0 ] || fail "the browser driver could not run: $(cat "$TMP_ROOT/probe.err")"
[ -n "$BROWSER_PATH" ] || fail "the browser driver named no browser"

make_clone || fail "could not build a fresh copy of this repository to test against"
mkdir -p "$TMP_ROOT/fakehome"
grant_tool "$CLONE_BIN" node || fail "could not grant the clone the one tool it is allowed"
grant_tool "$CLONE_BIN_BACKLOG" node || fail "could not grant the clone node"
if command -v tasks-axi >/dev/null 2>&1; then
  grant_tool "$CLONE_BIN_BACKLOG" tasks-axi || fail "could not grant the clone the backlog backend"
fi

test_a_clone_with_nothing_installed_gets_a_url_that_serves_the_board
test_an_open_page_reflects_a_published_event_with_nobody_reloading_it
test_a_server_running_code_that_has_changed_is_detectable_from_outside_it
test_a_click_on_an_option_reaches_this_home_and_what_was_clicked_is_recoverable
test_an_event_never_takes_the_open_board_back_to_an_older_build
test_a_board_that_is_behind_never_tells_the_captain_his_desk_is_empty
