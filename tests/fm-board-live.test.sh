#!/usr/bin/env bash
# Behavior tests for the bearings board's live event path in both directions:
# the publisher (bin/fm-board-live.sh), the server and its merge
# (bin/fm-board-live.mjs), the inbound half that carries the captain's click
# back (the same server plus bin/fm-board-answer.sh), the derivation that puts
# the transport on the board (bin/fm-bearings-board.sh derive), and the
# transport itself, executed under the DOM shim in
# tests/assets/board-live-page-harness.mjs.
#
# Every assertion is on observable behavior: what the server serves, what a
# real websocket client receives, and what the page shows. Nothing here reads
# the source of what it is testing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/bin/fm-board-live.sh"
ANSWER="$ROOT/bin/fm-board-answer.sh"
SERVER="$ROOT/bin/fm-board-live.mjs"
BOARD="$ROOT/bin/fm-bearings-board.sh"
CLIENT="$ROOT/tests/assets/board-live-client.mjs"
PAGE="$ROOT/tests/assets/board-live-page-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-board-live)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

PAYLOAD='{"schema":"fm-bearings-board.v1","home":"main","generated":"2026-01-01T00:00:00Z",
 "prs_live":false,
 "captains_call":[{"key":"pick-one","type":"decision","repo":"firstmate","title":"Pick one",
   "options":[{"value":"yes","label":"Yes"}]}],
 "underway":[{"id":"alpha","name":"Alpha","repo":"firstmate","state":"working","doing":"review 2/3","kind":"ship"}],
 "landed":[],"charted":[]}'

STARTED_HOMES=()
cleanup_servers() {
  local home
  for home in ${STARTED_HOMES[@]+"${STARTED_HOMES[@]}"}; do
    FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1 || true
  done
}
trap cleanup_servers EXIT

make_home() {  # <name> ; prints the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/.lavish" "$home/data"
  printf '%s\n' "$PAYLOAD" > "$home/payload.json"
  # A board page carrying that payload, written the way a build writes it. The
  # derivation itself is exercised by its own cases below; the server only ever
  # reads the payload out of the page, so this is a faithful stand-in for the
  # cases that are about the server.
  FM_HOME="$home" "$BOARD" derive "$home/payload.json" \
    --endpoint "ws://127.0.0.1:1/board-live" --out "$home/.lavish/bearings-board.html" \
    >/dev/null 2>&1 || return 1
  printf '%s\n' "$home"
}

served_state() {  # <home>
  FM_HOME="$1" node "$SERVER" state
}

free_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{process.stdout.write(String(s.address().port));s.close();});'
}

# --- the publisher -----------------------------------------------------------

# --- the click coming back ---------------------------------------------------
#
# Every case here speaks real websocket to a real server, so what is asserted
# is what a page on the wire would get, not what the code intends.

# File mode, both spellings, because the suite runs on macOS and on CI Linux.
fm_test_mode() {  # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# A home that can actually record an answer: the fixture home plus a backlog
# with one task held for the captain, which is what a decision card keys.
make_answering_home() {  # <name> ; prints the home path
  local home
  home=$(make_home "$1") || return 1
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ( cd "$home" \
    && BEADS_ACTOR=fixture tasks-axi add pick-one "Pick one" --repo firstmate \
    && BEADS_ACTOR=fixture tasks-axi hold pick-one --kind captain --reason "captain must decide" \
  ) >/dev/null 2>&1 || return 1
  printf '%s\n' "$home"
}

serve_home() {  # <home> ; prints the port
  local home=$1 port
  port=$(free_port)
  STARTED_HOMES+=("$home")
  FM_HOME="$home" "$LIVE" start --port "$port" >/dev/null 2>&1 || return 1
  printf '%s\n' "$port"
}

inbound_message() {  # <token> <id> <answers-json>
  printf '{"schema":"fm-board-inbound.v1","token":"%s","type":"answer","id":"%s","answers":%s}' \
    "$1" "$2" "$3"
}

test_a_board_is_built_able_to_answer() {
  local home token page
  home=$(make_home inbound-token) || fail "could not build a home"
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  printf '%s' "$token" | grep -Eq '^[0-9a-f]{64}$' \
    || fail "the answer token is not 32 random bytes of hex: $token"
  assert_equals "$token" "$(FM_HOME="$home" "$LIVE" token)" \
    "asking twice issued two different tokens, so a board built yesterday would stop answering"
  assert_equals "600" "$(fm_test_mode "$home/state/board-live.token")" \
    "the answer token is readable by anyone on the machine"
  page="$home/.lavish/bearings-board.html"
  assert_contains "$(cat "$page")" "$token" \
    "the built board carries no way to send an answer back"
  assert_equals "600" "$(fm_test_mode "$page")" \
    "the board carrying the token is readable by anyone on the machine"
  pass "a board is built able to answer, with one stable token kept to the captain's own account"
}

test_the_answer_token_never_reaches_a_terminal() {
  local home token printed
  home=$(make_home inbound-derive-stdout) || fail "could not build a home"
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  # Running derive without --out is the natural way to look at a board, and
  # its output is read in terminals, pasted into reports and captured in logs.
  printed=$(FM_HOME="$home" "$BOARD" derive "$home/payload.json" \
    --endpoint "ws://127.0.0.1:1/board-live" 2>/dev/null) \
    || fail "derive could not print a board"
  case $printed in
    *"$token"*) fail "derive printed the captain's answer credential to stdout" ;;
  esac
  assert_contains "$printed" "fm-board-live" \
    "the printed board is not the live board at all, so this proves nothing"
  # And the board that is KEPT still carries it, or the fix would have made
  # every board unable to answer.
  assert_contains "$(cat "$home/.lavish/bearings-board.html")" "$token" \
    "a board written to a file lost the way to send an answer back"
  pass "the answer token reaches a board written to a file and never a terminal"
}

test_a_rotated_token_stops_an_old_board_answering() {
  local home token rotated port got
  home=$(make_answering_home inbound-rotate) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  rotated=$(FM_HOME="$home" "$LIVE" token --rotate) || fail "the token could not be rotated"
  [ "$rotated" != "$token" ] || fail "rotating the token issued the same one again"
  port=$(serve_home "$home") || fail "the server did not start"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 15000 --count-type inbound \
    --send "$(inbound_message "$token" rot '[{"key":"pick-one","selection":"yes"}]')") \
    || fail "the server never answered a board carrying the retired token"
  assert_equals unauthenticated "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].reason')" \
    "a board carrying a retired token was still allowed to answer"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "rotating the token stops every board already built from answering"
}

test_a_message_from_another_origin_never_reaches_the_port() {
  local home token port got
  home=$(make_answering_home inbound-origin) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  # A website the captain happens to be visiting, holding a token it should
  # never have: the browser writes the Origin itself and page script cannot
  # change it, so this is the strongest form of the attack.
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 8000 \
    --origin "https://evil.example" \
    --send "$(inbound_message "$token" forged '[{"key":"pick-one","selection":"yes"}]')") \
    || fail "the client could not reach the server at all"
  assert_contains "$(printf '%s' "$got" | jq -r '.handshake_refused')" "403" \
    "a page on another origin was allowed to open the captain's answer channel"
  [ "$(cd "$home" && tasks-axi show pick-one 2>/dev/null | sed -n 's/^  state: //p')" != "done" ] \
    || fail "a message from another origin settled the captain's call"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "a message from another origin is refused at the handshake and settles nothing"
}

test_a_message_with_no_token_is_refused_out_loud() {
  local home port got
  home=$(make_answering_home inbound-unauth) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  FM_HOME="$home" "$LIVE" token >/dev/null || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  # A local process that is not a browser: it sends no Origin at all, so the
  # token is the whole of what stands between it and the captain's decisions.
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 15000 --count-type inbound \
    --send "$(inbound_message 0000000000000000000000000000000000000000000000000000000000000000 \
      nope '[{"key":"pick-one","selection":"yes"}]')") \
    || fail "the server never answered an unauthenticated message"
  assert_equals refused "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].status')" \
    "an unauthenticated message was not refused, or was dropped in silence"
  assert_equals unauthenticated "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].reason')" \
    "the refusal does not say the message was not the captain's"
  [ "$(cd "$home" && tasks-axi show pick-one 2>/dev/null | sed -n 's/^  state: //p')" != "done" ] \
    || fail "an unauthenticated message settled the captain's call"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "a message that cannot be proved the captain's is refused out loud and settles nothing"
}

test_an_inbound_message_can_only_ever_carry_an_answer() {
  local home token port got
  home=$(make_answering_home inbound-authority) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  # An authenticated message asking for anything other than an answer. The
  # token proves who sent it; it does not widen what may be asked for.
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 15000 --count-type inbound \
    --send "{\"schema\":\"fm-board-inbound.v1\",\"token\":\"$token\",\"type\":\"merge\",\"pr\":\"https://example.test/pr/1\"}") \
    || fail "the server never answered a message asking for something else"
  assert_equals refused "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].status')" \
    "an authenticated message was allowed to ask for something other than an answer"
  assert_equals unsupported-type "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].reason')" \
    "the refusal does not say why"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "a proven sender may answer a question and may not ask for anything else"
}

test_the_captains_click_settles_the_call_the_way_a_typed_answer_does() {
  local home token port got body
  home=$(make_answering_home inbound-answer) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 2 60000 --count-type inbound \
    --send "$(inbound_message "$token" click \
      '[{"key":"pick-one","selection":"yes","label":"Yes, ship it","close":"done"}]')") \
    || fail "the captain's click was never answered"
  assert_equals accepted "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].status')" \
    "the captain's click was not accepted"
  assert_equals recorded "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")] | last | .status')" \
    "the captain's click was accepted and then never recorded"
  # The durable record, written by the one intake every channel feeds.
  body=$(cd "$home" && tasks-axi show pick-one)
  assert_equals "done" "$(printf '%s' "$body" | sed -n 's/^  state: //p')" \
    "the captain's click did not settle the call"
  assert_contains "$body" "Answer: yes" \
    "the recorded decision does not carry what the captain chose"
  assert_contains "$body" "Yes, ship it" \
    "the recorded decision does not read the way the captain read it"
  # The acknowledgement on the row he clicked, written by the one carrier.
  [ -f "$home/state/board-acks/pick-one.json" ] \
    || fail "the row the captain clicked carries no acknowledgement"
  # Firstmate learning about it at all.
  assert_contains "$(cat "$home/state/.wake-queue")" "board-answer:pick-one" \
    "the captain answered and firstmate was never told"
  pass "the captain's click settles the call, acknowledges his row, and tells firstmate"
}

test_an_answer_is_durable_before_anything_is_attempted_with_it() {
  local home token port journal
  home=$(make_answering_home inbound-journal) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  node "$CLIENT" "ws://127.0.0.1:$port/board-live" 2 60000 --count-type inbound \
    --send "$(inbound_message "$token" kept '[{"key":"pick-one","selection":"yes","label":"Yes"}]')" \
    >/dev/null || fail "the captain's click was never answered"
  journal="$home/state/board-inbound.jsonl"
  [ -f "$journal" ] || fail "the captain's answer was never written down"
  assert_contains "$(cat "$journal")" "pick-one" \
    "the record of the captain's answer does not name what he answered"
  [ "$(grep -c "$token" "$journal")" -eq 0 ] \
    || fail "the durable record carries the token, which is a credential"
  assert_equals "600" "$(fm_test_mode "$journal")" \
    "the record of the captain's answers is readable by anyone on the machine"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "an answer is on disk, without its credential, before anything is attempted with it"
}

test_an_answer_that_cannot_be_written_down_is_refused_rather_than_attempted() {
  local home token port got
  home=$(make_answering_home inbound-journal-broken) \
    || fail "could not build a home with a captain-held task"
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  # The journal is the file three separate places tell the captain and
  # firstmate to go read when something did not land. A directory in its place
  # makes the append fail the way a full disk or a bad mode would.
  mkdir -p "$home/state/board-inbound.jsonl" \
    || fail "could not make the journal unwritable"
  port=$(serve_home "$home") || fail "the server did not start"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 20000 --count-type inbound \
    --send "$(inbound_message "$token" nojournal '[{"key":"pick-one","selection":"yes"}]')") \
    || fail "the server never answered when it could not write the answer down"
  assert_equals refused "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].status')" \
    "an answer that could not be written down was accepted anyway"
  assert_equals not-recorded "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].reason')" \
    "the refusal does not say the answer could not be written down"
  [ "$(cd "$home" && tasks-axi show pick-one 2>/dev/null | sed -n 's/^  state: //p')" != "done" ] \
    || fail "the call was settled with no durable record of the captain ever answering"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "an answer that cannot be written down is refused, not attempted behind a recovery story that is false"
}

test_the_reconcile_choice_is_not_recorded_as_an_answer() {
  local home token port got
  home=$(make_answering_home inbound-reconcile) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  node "$CLIENT" "ws://127.0.0.1:$port/board-live" 2 60000 --count-type inbound \
    --send "$(inbound_message "$token" recheck \
      '[{"key":"pick-one","selection":"reconcile","note":"this may be moot"}]')" \
    >/dev/null || fail "the reconcile choice was never answered"
  [ "$(cd "$home" && tasks-axi show pick-one | sed -n 's/^  state: //p')" != "done" ] \
    || fail "asking for a re-check closed the call as though it had been answered"
  [ -f "$home/state/reconcile-requests/pick-one.request" ] \
    || fail "asking for a re-check recorded no obligation to re-check"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "the board's re-check choice records an obligation and never closes the call"
}

# An answer path stopped mid-run, driven through the script the server drives.
# The fifo holds its stdin open so it is blocked exactly where a slow backlog
# read would block it.
interrupt_answer_path() {  # <home> <signal> ; prints nothing
  local home=$1 signal=$2 fifo="$home/answer-stdin" pid
  rm -f -- "$fifo"
  mkfifo "$fifo" || return 1
  ( sleep 30 > "$fifo" ) &
  local holder=$!
  FM_HOME="$home" "$ANSWER" apply --source "an interrupted run" < "$fifo" \
    >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill "-$signal" "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  rm -f -- "$fifo"
  return 0
}

test_an_answer_path_stopped_mid_run_still_tells_firstmate() {
  local home
  home="$TMP_ROOT/answer-interrupted"
  mkdir -p "$home/state"
  # The server's timeout signals the answer path's whole process group with
  # SIGTERM before it ever reaches for SIGKILL, because the answer path's own
  # contract names SIGKILL as the one signal that loses the captain's answer.
  # This is that difference, proved rather than asserted.
  interrupt_answer_path "$home" TERM || fail "could not interrupt the answer path"
  assert_contains "$(cat "$home/state/.wake-queue" 2>/dev/null)" "board-answer:" \
    "an answer path stopped mid-run left firstmate never knowing the captain pressed anything"

  home="$TMP_ROOT/answer-killed"
  mkdir -p "$home/state"
  interrupt_answer_path "$home" KILL || fail "could not kill the answer path"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "SIGKILL preserved the wake, so the case above proves nothing about the signal"
  pass "an answer path stopped mid-run still tells firstmate, which is why the timeout does not use SIGKILL"
}

test_the_dispatch_bar_acknowledges_each_row_the_captain_ticked() {
  local home token port got
  home=$(make_answering_home inbound-dispatch) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  # The dispatch bar answers for the rows he ticked, not for itself, and names
  # no captain-held task: it must come back as an order that landed, not as an
  # answer that could not be recorded.
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 2 60000 --count-type inbound \
    --send "$(inbound_message "$token" order \
      '[{"key":"dispatch.charted","note":"alpha,beta","label":"Dispatch: alpha, beta"}]')") \
    || fail "the dispatch order was never answered"
  assert_equals recorded \
    "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")] | last | .status')" \
    "starting queued work came back as an answer that could not be recorded"
  [ -f "$home/state/board-acks/alpha.json" ] && [ -f "$home/state/board-acks/beta.json" ] \
    || fail "the rows the captain ticked carry no acknowledgement"
  [ ! -f "$home/state/board-acks/dispatch.charted.json" ] \
    || fail "the send button acknowledged itself instead of the rows he ticked"
  assert_contains "$(cat "$home/state/.wake-queue")" "alpha,beta" \
    "firstmate was not told which queued items to start"
  # The ids are the one field carrying identifiers that cannot arrive as an
  # option value, so they get the same check here as every sibling field
  # rather than being refused downstream as "this did not land".
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 20000 --count-type inbound \
    --send "$(inbound_message "$token" badorder \
      '[{"key":"dispatch.charted","note":"alpha,../../etc/passwd"}]')") \
    || fail "the server never answered a dispatch order naming an unaddressable row"
  assert_equals refused "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].status')" \
    "a dispatch order naming a row this board cannot address was accepted"
  assert_equals malformed "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].reason')" \
    "the refusal does not say the message itself was wrong"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "the dispatch bar acknowledges each row the captain ticked, tells firstmate which they were, and its ids are checked here"
}

test_a_malformed_message_is_refused_rather_than_guessed_at() {
  local home token port got
  home=$(make_answering_home inbound-malformed) || { echo "skip: tasks-axi fixture unavailable"; return 0; }
  token=$(FM_HOME="$home" "$LIVE" token) || fail "a home could not issue an answer token"
  port=$(serve_home "$home") || fail "the server did not start"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 3 20000 --count-type inbound \
    --send "not json at all" \
    --send "$(inbound_message "$token" empty '[{"key":"pick-one"}]')" \
    --send "$(inbound_message "$token" twice \
      '[{"key":"pick-one","selection":"yes"},{"key":"pick-one","selection":"no"}]')") \
    || fail "the server never answered a malformed message"
  assert_equals malformed "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][0].reason')" \
    "text that is not a message was not refused as one"
  assert_equals malformed "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][1].reason')" \
    "a pick carrying neither a choice nor words was not refused"
  assert_equals duplicate-key "$(printf '%s' "$got" | jq -r '[.[] | select(.type == "inbound")][2].reason')" \
    "two answers for one card in one message were not refused"
  [ "$(cd "$home" && tasks-axi show pick-one 2>/dev/null | sed -n 's/^  state: //p')" != "done" ] \
    || fail "a malformed message settled the captain's call"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "a message this port cannot read is refused by name rather than guessed at"
}

test_reading_the_board_needs_no_token_which_is_exposure_not_a_guarantee() {
  local home port got
  home=$(make_home inbound-read) || fail "could not build a home"
  port=$(serve_home "$home") || fail "the server did not start"
  # Two facts this pins, and the second is the uncomfortable one. Subscribing
  # is unchanged, which is what the boards already built depend on. And an
  # allowed origin needs no token, so a sandboxed cross-origin frame - which
  # presents exactly this Origin - is sent the captain's whole board. That is
  # accepted exposure, recorded here so it cannot quietly become a belief that
  # the origin check covers reading.
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 8000) \
    || fail "a subscriber carrying no token was not sent the board"
  assert_equals state "$(printf '%s' "$got" | jq -r '.[0].type')" \
    "the outbound half started demanding a credential the pages already built do not carry"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 8000 --origin null) \
    || fail "a subscriber presenting Origin: null could not reach the server"
  assert_equals Alpha "$(printf '%s' "$got" | jq -r '.[0].payload.underway[0].name')" \
    "the exposure this records has changed; the header and the docs must change with it"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "subscribing needs no token from any allowed origin, Origin: null included - exposure, not a guarantee"
}

test_the_page_carries_the_answer_and_shows_what_came_back() {
  local home sent refused offline
  home=$(make_home page-answer) || fail "could not build a home"
  sent=$(page_says "$home" answer-sent)
  assert_contains "$(printf '%s' "$sent" | jq -r '.outbound[0]')" '"key":"pick-one"' \
    "pressing a button on a card put nothing on the wire"
  assert_contains "$(printf '%s' "$sent" | jq -r '.outbound[0]')" '"schema":"fm-board-inbound.v1"' \
    "what the page sent is not what the server accepts"
  assert_contains "$(printf '%s' "$sent" | jq -r '.sent.text')" "recorded" \
    "the page never told the captain his answer landed"
  refused=$(page_says "$home" answer-refused)
  assert_equals danger "$(printf '%s' "$refused" | jq -r '.sent.tone')" \
    "a refused answer does not read as something gone wrong"
  assert_contains "$(printf '%s' "$refused" | jq -r '.sent.text')" "NOT recorded" \
    "the page let a refused answer look like it worked"
  offline=$(page_says "$home" answer-offline)
  assert_contains "$(printf '%s' "$offline" | jq -r '.sent.text')" "NOT sent" \
    "pressing a button on a disconnected board looked like it worked"
  assert_equals 0 "$(printf '%s' "$offline" | jq -r '.outbound | length')" \
    "a disconnected board put something on the wire anyway"
  pass "the page carries the captain's answer and says what became of it, including when nothing did"
}

test_publishing_never_resurrects_a_retired_home() {
  local home rc
  # A teardown that retires a secondmate removes the home it ran in. A
  # publisher that then created the directory would bring the retired home
  # back as a side effect of telling a board that no longer exists.
  home="$TMP_ROOT/retired"
  rm -rf "$home"
  rc=0
  FM_HOME="$home" "$LIVE" event landed alpha --owner main >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "publishing into a retired home exited $rc; a teardown would have died with it"
  [ ! -e "$home" ] \
    || fail "publishing recreated the retired home at $home"
  pass "publishing into a home that has been retired creates nothing and still exits 0"
}

test_publishing_is_one_append_and_needs_no_server() {
  local home out
  home=$(make_home publish-no-server) || fail "could not build a home"
  out=$(FM_HOME="$home" "$LIVE" event step alpha --state working --detail "running tests" 2>&1) \
    || fail "publishing failed: $out"
  [ -f "$home/state/board-live.jsonl" ] \
    || fail "publishing wrote no event log"
  assert_contains "$(cat "$home/state/board-live.jsonl")" '"kind":"step"' \
    "the published line does not record the event kind"
  pass "an event is published by appending one line, with no server running"
}

test_a_publisher_never_fails_its_caller() {
  local home rc out
  home=$(make_home publish-never-fails) || fail "could not build a home"
  # Every way this can go wrong, from the callers that must not die: a kind
  # nobody defined, an option nobody defined, a missing value, and a state
  # directory that cannot be written.
  for bad in "nonsense alpha" "step alpha --nonsense x" "step alpha --state"; do
    rc=0
    # shellcheck disable=SC2086  # each case is a deliberate argument list
    out=$(FM_HOME="$home" "$LIVE" event $bad 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "publishing '$bad' exited $rc; a caller would have died with it"
    [ -n "$out" ] || fail "publishing '$bad' failed silently; it must say what it refused"
  done
  chmod 0500 "$home/state"
  rc=0
  FM_HOME="$home" "$LIVE" event step alpha --state working >/dev/null 2>&1 || rc=$?
  chmod 0700 "$home/state"
  [ "$rc" -eq 0 ] || fail "publishing to an unwritable home exited $rc"
  pass "a publisher that cannot publish still exits 0, and says why"
}

test_a_published_value_cannot_corrupt_the_log() {
  local home line
  home=$(make_home publish-escaping) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event step alpha --detail 'he said "stop" \ and
then a newline' >/dev/null 2>&1
  line=$(wc -l < "$home/state/board-live.jsonl" | tr -d ' ')
  assert_equals 1 "$line" "a quoted, backslashed, multi-line value did not stay one line"
  node -e 'const l=require("node:fs").readFileSync(process.argv[1],"utf8").trim();
    const o=JSON.parse(l); if (!o.detail.includes("\n")) { console.error("the newline was lost"); process.exit(1); }' \
    "$home/state/board-live.jsonl" \
    || fail "the published line is not readable JSON carrying the value it was given"
  pass "a value carrying quotes, backslashes and newlines stays one readable line"
}

# --- the merge ---------------------------------------------------------------

test_a_step_event_updates_only_what_it_carries() {
  local home state
  home=$(make_home merge-step) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event step alpha --state waiting >/dev/null 2>&1
  state=$(served_state "$home")
  assert_equals waiting "$(printf '%s' "$state" | jq -r '.payload.underway[0].state')" \
    "the state word did not reach the board"
  assert_equals "review 2/3" "$(printf '%s' "$state" | jq -r '.payload.underway[0].doing')" \
    "a state-only event overwrote what the worker is doing"
  pass "an event changes the fields it carries and leaves the rest of the row alone"
}

test_an_answered_call_leaves_the_board() {
  local home state
  home=$(make_home merge-answered) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event answered pick-one --key pick-one >/dev/null 2>&1
  state=$(served_state "$home")
  assert_equals 0 "$(printf '%s' "$state" | jq -r '.payload.captains_call | length')" \
    "an answered call is still on the board"
  pass "answering a captain's call takes its card off the board"
}

test_a_new_call_marks_the_board_behind_rather_than_inventing_one() {
  local home state
  home=$(make_home merge-call) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event call beta >/dev/null 2>&1
  state=$(served_state "$home")
  assert_equals 1 "$(printf '%s' "$state" | jq -r '.payload.captains_call | length')" \
    "a call event invented a card"
  assert_equals 1 "$(printf '%s' "$state" | jq -r '.stale | length')" \
    "a call the board cannot compose was not reported as owing a rebuild"
  assert_contains "$(printf '%s' "$state" | jq -r '.stale[0].why')" "firstmate" \
    "the board does not say who owes the rebuild"
  pass "a captain's call nobody has worded makes the board say it is behind"
}

test_a_pull_request_on_underway_work_is_reported_not_guessed() {
  local home state
  home=$(make_home merge-pr) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event pr alpha --pr-url "https://example.test/pr/1" >/dev/null 2>&1
  state=$(served_state "$home")
  assert_equals 1 "$(printf '%s' "$state" | jq -r '.stale | length')" \
    "a pull request the board cannot place was not reported as owing a rebuild"
  pass "a pull request the board cannot place is named, never dropped and never guessed"
}

test_landing_moves_the_row_and_retires_its_call() {
  local home state
  home=$(make_home merge-landed) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event landed alpha --repo firstmate --owner main \
    --pr-url "https://example.test/pr/2" >/dev/null 2>&1
  state=$(served_state "$home")
  assert_equals 0 "$(printf '%s' "$state" | jq -r '.payload.underway | length')" \
    "landed work is still underway"
  assert_equals 1 "$(printf '%s' "$state" | jq -r '.payload.landed | length')" \
    "landed work did not reach the landed rows"
  assert_equals "https://example.test/pr/2" \
    "$(printf '%s' "$state" | jq -r '.payload.landed[0].pr_url')" \
    "the landed row lost its pull request"
  pass "landing moves the row and carries its pull request with it"
}

test_a_rebuild_supersedes_every_earlier_event() {
  local home state
  home=$(make_home merge-rebuild) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event step alpha --state waiting >/dev/null 2>&1
  assert_equals waiting "$(served_state "$home" | jq -r '.payload.underway[0].state')" \
    "the event never applied, so this case would prove nothing"
  # A rebuild recomposes everything, so what it writes outranks anything
  # published before it. Rewriting the page is what a build does.
  sleep 1
  FM_HOME="$home" "$BOARD" derive "$home/payload.json" \
    --endpoint "ws://127.0.0.1:1/board-live" --out "$home/.lavish/bearings-board.html" >/dev/null 2>&1
  state=$(served_state "$home")
  assert_equals working "$(printf '%s' "$state" | jq -r '.payload.underway[0].state')" \
    "a stale event survived the rebuild that superseded it"
  pass "a rebuild supersedes every event published before it"
}

test_a_home_with_no_board_says_so_rather_than_serving_nothing() {
  local home state
  home="$TMP_ROOT/no-board"
  mkdir -p "$home/state"
  state=$(served_state "$home")
  assert_equals null "$(printf '%s' "$state" | jq -r '.payload')" \
    "a home with no board served a payload"
  assert_contains "$(printf '%s' "$state" | jq -r '.base_missing')" "built" \
    "a home with no board does not say why it has none"
  pass "a home that has never built a board says so instead of serving nothing"
}

# --- the socket --------------------------------------------------------------

test_a_subscriber_is_sent_the_whole_board_before_anything_else() {
  local home port got
  home=$(make_home socket-first) || fail "could not build a home"
  port=$(free_port)
  STARTED_HOMES+=("$home")
  FM_HOME="$home" "$LIVE" start --port "$port" >/dev/null 2>&1 \
    || fail "the server did not start"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 8000) \
    || fail "no message reached a subscriber"
  assert_equals state "$(printf '%s' "$got" | jq -r '.[0].type')" \
    "the first message is not the board's state"
  assert_equals Alpha "$(printf '%s' "$got" | jq -r '.[0].payload.underway[0].name')" \
    "the first message did not carry the whole board"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "a subscriber is sent the whole current board the moment it connects"
}

test_an_append_reaches_an_open_subscriber() {
  local home port got
  home=$(make_home socket-push) || fail "could not build a home"
  port=$(free_port)
  STARTED_HOMES+=("$home")
  FM_HOME="$home" "$LIVE" start --port "$port" >/dev/null 2>&1 \
    || fail "the server did not start"
  ( sleep 1; FM_HOME="$home" "$LIVE" event step alpha --detail "pushed" >/dev/null 2>&1 ) &
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 2 15000) \
    || fail "the appended event never reached the subscriber"
  wait
  assert_equals "pushed" "$(printf '%s' "$got" | jq -r '.[1].payload.underway[0].doing')" \
    "the pushed board does not carry the event"
  [ "$(printf '%s' "$got" | jq -r '.[1].seq')" -gt "$(printf '%s' "$got" | jq -r '.[0].seq')" ] \
    || fail "the pushed board did not advance the sequence"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "appending an event pushes the whole board to every open subscriber"
}

test_events_published_while_the_server_was_down_are_not_lost() {
  local home port got
  home=$(make_home socket-downtime) || fail "could not build a home"
  FM_HOME="$home" "$LIVE" event step alpha --detail "published while down" >/dev/null 2>&1
  port=$(free_port)
  STARTED_HOMES+=("$home")
  FM_HOME="$home" "$LIVE" start --port "$port" >/dev/null 2>&1 \
    || fail "the server did not start"
  got=$(node "$CLIENT" "ws://127.0.0.1:$port/board-live" 1 8000) \
    || fail "no message reached a subscriber"
  assert_equals "published while down" \
    "$(printf '%s' "$got" | jq -r '.[0].payload.underway[0].doing')" \
    "an event published while the server was down never reached the board"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "an event published while no server was running is not lost"
}

test_starting_twice_leaves_one_server() {
  local home port first second
  home=$(make_home socket-idempotent) || fail "could not build a home"
  port=$(free_port)
  STARTED_HOMES+=("$home")
  first=$(FM_HOME="$home" "$LIVE" start --port "$port" 2>&1) || fail "the first start failed: $first"
  second=$(FM_HOME="$home" "$LIVE" start --port "$port" 2>&1) || fail "the second start failed: $second"
  assert_contains "$second" "already-running" "a second start did not report the running server"
  FM_HOME="$home" "$LIVE" stop >/dev/null 2>&1
  pass "starting an already-running server reports it instead of taking the port twice"
}

# --- the derivation ----------------------------------------------------------

test_the_derived_board_is_the_shipped_board_plus_a_subscription() {
  local home page
  home=$(make_home derive-parity) || fail "could not build a home"
  page="$home/.lavish/bearings-board.html"
  grep -qxF '<script id="fm-board-live">' "$page" \
    || fail "the derived board carries no transport"
  grep -qF '__FM_BOARD_LIVE_ENDPOINT__' "$page" \
    && fail "the derived board still carries an unset endpoint"
  # Parity, proved by rendering: the shipped renderer in the derived page
  # produces what the shipped renderer always produced.
  node "$ROOT/tests/assets/board-render-harness.mjs" "$page" \
    | jq -e '.underway[0].title == "Alpha" and (.cards | length) == 1' >/dev/null \
    || fail "the derived board does not render what the shipped board renders"
  pass "the derived board renders exactly what the shipped board renders, plus a subscription"
}

test_a_derivation_whose_seam_moved_refuses_instead_of_shipping_a_dead_board() {
  local home out
  home=$(make_home derive-seam) || fail "could not build a home"
  # A template with no data slot is a template this derivation cannot anchor
  # on. It must say so, not emit a board that looks right and never updates.
  sed 's|<script id="bearings-data" type="application/json">|<script id="moved">|' \
    "$ROOT/.agents/skills/bearings/assets/board-template.html" > "$home/moved.html"
  out=$(FM_HOME="$home" FM_BEARINGS_BOARD_TEMPLATE="$home/moved.html" \
    "$BOARD" derive "$home/payload.json" --endpoint "ws://127.0.0.1:1/x" --out "$home/out.html" 2>&1) \
    && fail "a template whose seam moved still produced a board"
  assert_contains "$out" "slot" "the refusal does not name the seam that moved"
  pass "a derivation whose seam moved refuses and names it"
}

# --- the page ----------------------------------------------------------------

page_says() {  # <home> <scenario>
  node "$PAGE" "$1/.lavish/bearings-board.html" "$2"
}

test_a_board_opened_with_no_server_still_renders() {
  local home out
  home=$(make_home page-offline) || fail "could not build a home"
  out=$(page_says "$home" first-paint)
  assert_equals false "$(printf '%s' "$out" | jq -r '.error')" \
    "a board opened with no server did not render"
  assert_equals 1 "$(printf '%s' "$out" | jq -r '.calls')" \
    "a board opened with no server lost its captain's call"
  pass "a board opened with no server renders from what it was built with"
}

test_a_live_board_repaints_from_what_arrives() {
  local home out
  home=$(make_home page-live) || fail "could not build a home"
  out=$(page_says "$home" live)
  assert_contains "$(printf '%s' "$out" | jq -r '.provenance')" "2099" \
    "the page did not repaint from the board that arrived"
  assert_equals live "$(printf '%s' "$out" | jq -r '.link.text')" \
    "a repainting page does not say it is live"
  pass "a board that arrives repaints the page through the shipped renderer"
}

test_a_board_that_renders_is_never_replaced_by_one_that_does_not() {
  local home out
  home=$(make_home page-unreadable) || fail "could not build a home"
  out=$(page_says "$home" unreadable)
  assert_equals false "$(printf '%s' "$out" | jq -r '.error')" \
    "an unreadable update left the captain looking at an error card"
  assert_contains "$(printf '%s' "$out" | jq -r '.provenance')" "2099" \
    "the last board that rendered was not restored"
  assert_contains "$(printf '%s' "$out" | jq -r '.link.text')" "rejected" \
    "the page does not say the update was rejected"
  pass "an update this board cannot render is undone, and the page says so"
}

test_an_update_waits_for_the_answer_being_written() {
  local home held sent
  home=$(make_home page-hold) || fail "could not build a home"
  held=$(page_says "$home" hold)
  assert_contains "$(printf '%s' "$held" | jq -r '.link.text')" "waiting" \
    "an update did not wait for the answer being written"
  assert_contains "$(printf '%s' "$held" | jq -r '.provenance')" "2026" \
    "an update overwrote the answer the captain was writing"
  sent=$(page_says "$home" hold-send)
  assert_contains "$(printf '%s' "$sent" | jq -r '.provenance')" "2099" \
    "the held update never landed after the answer was sent"
  pass "an update waits while an answer is being written, and lands once it is sent"
}

test_the_page_says_when_a_rebuild_is_owed() {
  local home behind cleared
  home=$(make_home page-behind) || fail "could not build a home"
  behind=$(page_says "$home" behind)
  assert_contains "$(printf '%s' "$behind" | jq -r '.behind.text')" "rebuild" \
    "the page does not say a rebuild is owed"
  assert_equals danger "$(printf '%s' "$behind" | jq -r '.behind.tone')" \
    "owing a rebuild does not read as something to act on"
  cleared=$(page_says "$home" behind-clear)
  assert_equals null "$(printf '%s' "$cleared" | jq -r '.behind')" \
    "the page still says a rebuild is owed after one is not"
  pass "a change the fleet cannot paint is named on the page, and cleared when it is not"
}

test_a_late_board_cannot_take_the_page_backwards() {
  local home out
  home=$(make_home page-seq) || fail "could not build a home"
  out=$(page_says "$home" old-seq)
  assert_contains "$(printf '%s' "$out" | jq -r '.provenance')" "2099" \
    "a board older than the one already shown replaced it"
  pass "a board that arrives out of order cannot take the page backwards"
}

test_a_dropped_connection_is_reopened_and_corrected() {
  local home out
  home=$(make_home page-dropped) || fail "could not build a home"
  out=$(page_says "$home" dropped)
  [ "$(printf '%s' "$out" | jq -r '.sockets')" -ge 2 ] \
    || fail "a dropped connection was never reopened"
  assert_contains "$(printf '%s' "$out" | jq -r '.provenance')" "2100" \
    "a reopened connection did not correct the page"
  pass "a dropped connection is reopened, and its first board corrects the page"
}

test_a_page_that_stopped_receiving_says_how_long_ago() {
  local home out
  home=$(make_home page-quiet) || fail "could not build a home"
  out=$(page_says "$home" went-quiet)
  assert_contains "$(printf '%s' "$out" | jq -r '.link.text')" "not updating" \
    "a page that stopped receiving still reads as live"
  assert_contains "$(printf '%s' "$out" | jq -r '.link.text')" "7 min" \
    "a page that stopped receiving does not say how long ago it last heard anything"
  pass "a page that stopped receiving says so, and says how long ago"
}

test_the_status_never_covers_the_language_switch() {
  local home out
  home=$(make_home page-badge-host) || fail "could not build a home"
  out=$(page_says "$home" live)
  assert_equals "bb-nav" "$(printf '%s' "$out" | jq -r '.badgeHost')" \
    "the status sits inside the fixed-height nav row, where it covers the language switch on a phone"
  pass "the status sits under the nav, never inside the row carrying the language switch"
}

test_publishing_sites_reach_the_board() {
  local home log
  home=$(make_home publish-sites) || fail "could not build a home"
  # The scripts that already record these facts publish them. This proves the
  # publisher is reachable and addresses the same home a caller names, which is
  # the part a call site can get wrong; each caller's own suite owns the rest.
  FM_STATE_OVERRIDE="$home/state" "$LIVE" event step alpha --state waiting >/dev/null 2>&1
  log="$home/state/board-live.jsonl"
  [ -f "$log" ] || fail "a publisher pointed at a named home wrote nowhere"
  assert_contains "$(cat "$log")" '"task":"alpha"' \
    "the event did not reach the home it was addressed to"
  pass "a publisher addressed at a named home publishes into that home"
}

test_publishing_never_resurrects_a_retired_home
test_publishing_is_one_append_and_needs_no_server
test_a_publisher_never_fails_its_caller
test_a_published_value_cannot_corrupt_the_log
test_a_step_event_updates_only_what_it_carries
test_an_answered_call_leaves_the_board
test_a_new_call_marks_the_board_behind_rather_than_inventing_one
test_a_pull_request_on_underway_work_is_reported_not_guessed
test_landing_moves_the_row_and_retires_its_call
test_a_rebuild_supersedes_every_earlier_event
test_a_home_with_no_board_says_so_rather_than_serving_nothing
test_a_subscriber_is_sent_the_whole_board_before_anything_else
test_an_append_reaches_an_open_subscriber
test_events_published_while_the_server_was_down_are_not_lost
test_starting_twice_leaves_one_server
test_the_derived_board_is_the_shipped_board_plus_a_subscription
test_a_derivation_whose_seam_moved_refuses_instead_of_shipping_a_dead_board
test_a_board_opened_with_no_server_still_renders
test_a_live_board_repaints_from_what_arrives
test_a_board_that_renders_is_never_replaced_by_one_that_does_not
test_an_update_waits_for_the_answer_being_written
test_the_page_says_when_a_rebuild_is_owed
test_a_late_board_cannot_take_the_page_backwards
test_a_dropped_connection_is_reopened_and_corrected
test_a_page_that_stopped_receiving_says_how_long_ago
test_the_status_never_covers_the_language_switch
test_publishing_sites_reach_the_board
test_a_board_is_built_able_to_answer
test_the_answer_token_never_reaches_a_terminal
test_a_rotated_token_stops_an_old_board_answering
test_a_message_from_another_origin_never_reaches_the_port
test_a_message_with_no_token_is_refused_out_loud
test_an_inbound_message_can_only_ever_carry_an_answer
test_the_captains_click_settles_the_call_the_way_a_typed_answer_does
test_an_answer_is_durable_before_anything_is_attempted_with_it
test_an_answer_that_cannot_be_written_down_is_refused_rather_than_attempted
test_the_reconcile_choice_is_not_recorded_as_an_answer
test_an_answer_path_stopped_mid_run_still_tells_firstmate
test_the_dispatch_bar_acknowledges_each_row_the_captain_ticked
test_a_malformed_message_is_refused_rather_than_guessed_at
test_reading_the_board_needs_no_token_which_is_exposure_not_a_guarantee
test_the_page_carries_the_answer_and_shows_what_came_back
