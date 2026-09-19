#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-board-remote.sh, the remote board's
# answer wake path.
#
# The properties the captain paid for get the most attention here, and each is
# driven through the real adapter against real answer documents rather than
# through a stub that answers whatever the assertion wants:
#
#   - a captured answer is never delivered twice, and the deduplication keys on
#     the answer's own identity rather than on its position or on a count, so
#     the same answer re-listed beside new ones is still recognized;
#   - an answer settles the card it was given for and no other, so an answer
#     already delivered when a card was armed never settles or retires it;
#   - an answer the captain has given is never stepped over by a board rebuild,
#     because arming ingests what it was handed before it opens new cards;
#   - an answer that has not been captured is never lost by the act of reading,
#     so a read that fails before the record lands leaves the store and the
#     cursor exactly as they were and the next pass still delivers it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin"
ADAPTER="$BIN/fm-procevent-board-remote.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-board-remote)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A home whose state root, data root and machine-wide process-event claim root
# all live inside this fixture, so arming here can never contend with a real
# source on this machine.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/docs/answers"
  if [ -f "$ROOT/.tasks.toml" ]; then
    cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
    cat > "$home/data/backlog.md" <<'BACKLOG'
## In flight

## Queued

## Done
BACKLOG
  fi
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  printf '%s\n' "$home"
}

run_adapter() {  # <home> <args...>
  local home=$1
  shift
  REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ADAPTER" "$@"
}

run_captain() {  # <home> <args...>
  local home=$1
  shift
  REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$BIN/fm-captain-hold.sh" "$@"
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# One answer document exactly as the artifact read writes it: the stored body
# and nothing else, named by the document id.
# One answer document exactly as the shipped board template queues it and the
# remote transport stores it: the versioned context the template builds, plus
# the queue key, prompt text, time and language the transport adds. Built from
# what the writer emits, never from what this reader would like to receive -
# a fixture that invents its own field is how a reader and its writer drift
# apart without a single test going red.
write_answer() {  # <home> <doc-id> <key> <selection> <note> <at> [close]
  local home=$1 doc=$2
  jq -n --arg key "$3" --arg selection "$4" --arg note "$5" --arg at "$6" --arg close "${7-}" \
    '{schema: "fm-bearings-answer.v1", question: $key, selection: $selection, note: $note}
     + (if $close == "" then {} else {close: $close} end)
     + {key: $key, prompt: ("Captain\u0027s Call answer - " + $key), at: $at, lang: "hant"}' \
    > "$home/docs/answers/$doc.json"
}

# The dispatch picker's own older shape, which carries no schema and answers in
# `answer` rather than a selection and a note.
write_dispatch_answer() {  # <home> <doc-id> <ids> <at>
  local home=$1 doc=$2
  jq -n --arg answer "$3" --arg at "$4" \
    '{question: "dispatch.charted", answer: $answer, key: "dispatch.charted",
      prompt: ("Dispatch order - start this queued work now: " + $answer),
      at: $at, lang: "hant"}' \
    > "$home/docs/answers/$doc.json"
}

answers_dir() { printf '%s\n' "$1/docs/answers"; }

test_help_advertises_the_commands() {
  local help
  if help=$("$ADAPTER" --help 2>&1); then
    fail "help unexpectedly exited zero"
  fi
  assert_contains "$help" "fm-procevent-board-remote.sh ingest --documents <dir>" \
    "help did not advertise the ingest command"
  assert_contains "$help" "arms:" "help did not say what arms the source"
  assert_contains "$help" "retires:" "help did not say what retires the source"
  pass "help advertises the commands and says what arms and retires the source"
}

test_arm_refuses_what_it_cannot_serve() {
  local home dir out
  home=$(make_home arm-refusals)
  dir=$(answers_dir "$home")

  out=$(run_adapter "$home" arm --documents "$dir" 2>&1) && fail "arming with nothing awaited was accepted"
  assert_contains "$out" "at least one --key" "arming with no key did not name what was missing"

  out=$(run_adapter "$home" arm --key sample-call 2>&1) && fail "arming without the answers was accepted"
  assert_contains "$out" "--documents" "arming without the answers did not name what was missing"

  out=$(run_adapter "$home" arm --documents "$dir" --key "not a key" 2>&1) && fail "an invalid card key was accepted"

  assert_absent "$home/state/board-remote/awaiting" \
    "a refused arm still wrote an awaited card set"
  pass "arm refuses an empty card set, an unread store and a bad key"
}

test_arm_reports_the_cards_it_will_wait_for() {
  local home dir out
  home=$(make_home arm-records)
  dir=$(answers_dir "$home")
  out=$(run_adapter "$home" arm --documents "$dir" --key sample-call --key merge.other) \
    || fail "could not arm the source"
  assert_contains "$out" "armed: board-remote" "arm did not report the source it registered"
  assert_contains "$out" "awaiting: 2" "arm did not report the awaited card count"
  run_adapter "$home" tick --interval 0.2 > "$home/armed.result" || fail "the tick failed while the cards were open"
  assert_equals "due" "$(run_adapter "$home" classify "$home/armed.result")" \
    "a freshly armed board did not make its tick due"
  run_adapter "$home" retire >/dev/null || fail "could not retire the armed source"
  pass "arm registers the source and waits for every card it was given"
}

test_tick_is_due_while_a_card_is_open_and_settled_when_none_is() {
  local home dir out
  home=$(make_home tick-states)
  dir=$(answers_dir "$home")

  run_adapter "$home" arm --documents "$dir" --key sample-call >/dev/null || fail "could not arm the source"
  run_adapter "$home" tick --interval 0.2 > "$home/due.result" || fail "the tick failed while a card was open"
  assert_equals "due" "$(run_adapter "$home" classify "$home/due.result")" \
    "a tick with a card open did not classify due"
  run_adapter "$home" terminal "$home/due.result" && fail "a due tick ended the source"
  run_adapter "$home" silent "$home/due.result" && fail "a due tick was silenced"

  run_adapter "$home" retire >/dev/null || fail "could not retire the armed source"
  : > "$home/state/board-remote/awaiting"
  run_adapter "$home" tick --interval 0.2 > "$home/settled.result" || fail "the tick failed with nothing awaited"
  assert_equals "settled" "$(run_adapter "$home" classify "$home/settled.result")" \
    "a tick with nothing awaited did not classify settled"
  run_adapter "$home" terminal "$home/settled.result" || fail "a settled tick did not end the source"
  run_adapter "$home" silent "$home/settled.result" || fail "a settled tick was announced"
  pass "a tick is due while a card is open, and settled ticks end the source without announcing"
}

test_an_unreadable_result_stays_armed_and_announced() {
  local home
  home=$(make_home unknown-result)
  printf 'board-remote: board-remote\nstate: something-else\n' > "$home/odd.result"
  assert_equals "unknown" "$(run_adapter "$home" classify "$home/odd.result")" \
    "an unrecognized result did not classify unknown"
  run_adapter "$home" terminal "$home/odd.result" && fail "an unrecognized result ended the source"
  run_adapter "$home" silent "$home/odd.result" && fail "an unrecognized result was silenced"
  pass "an unrecognized result keeps the source armed and still announces"
}

test_a_captured_answer_is_never_delivered_twice() {
  local home dir first second third
  home=$(make_home never-twice)
  dir=$(answers_dir "$home")
  write_answer "$home" dispatch_charted dispatch.charted pick-one "Pick one" 2026-09-19T06:56:29.222Z

  first=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$first" "new: 1" "the first read did not deliver the answer"
  assert_contains "$first" "answer: dispatch.charted" "the first read did not report the answer"

  second=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$second" "new: 0" "the same answer was delivered twice"
  assert_not_contains "$second" "answer: dispatch.charted" "the same answer was reported twice"
  assert_contains "$second" "cursor: unchanged" "a read with nothing new still moved the cursor"

  # Identity, not position and not a count: the same answer re-listed beside a
  # new one, and sorting ahead of it, is still recognized as already delivered.
  write_answer "$home" aaa_new_call aaa-new-call yes "Yes" 2026-09-19T08:00:00.000Z
  third=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$third" "documents: 2" "the second document was not read"
  assert_contains "$third" "new: 1" "re-listing a delivered answer beside a new one re-delivered it"
  assert_contains "$third" "answer: aaa-new-call" "the new answer was not delivered"
  assert_not_contains "$third" "answer: dispatch.charted" "the delivered answer came back when the listing grew"
  pass "a captured answer is never delivered twice, and the cursor keys on its identity"
}

test_a_changed_answer_under_one_key_is_a_new_answer() {
  local home dir out
  home=$(make_home changed-answer)
  dir=$(answers_dir "$home")
  write_answer "$home" sample_call sample-call gold-only "Gold only" 2026-09-19T07:00:00.000Z
  run_adapter "$home" ingest --documents "$dir" >/dev/null 2>&1 || fail "the first read failed"

  write_answer "$home" sample_call sample-call both "Both" 2026-09-19T07:30:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 1" "the captain's changed answer was mistaken for the old one"
  assert_contains "$out" "answer: sample-call	both" "the changed answer did not carry the new value"
  pass "a changed answer under one key is a different answer and is delivered"
}

test_an_uncaptured_answer_survives_a_failed_read() {
  local home dir out before after rc=0
  home=$(make_home failed-read)
  dir=$(answers_dir "$home")
  write_answer "$home" sample_call sample-call gold-only "Gold only" 2026-09-19T07:00:00.000Z
  before=$(cat "$dir/sample_call.json")

  # Advance nothing: the record this home must write cannot be written.
  run_adapter "$home" ingest --documents "$dir" >/dev/null 2>&1 \
    || fail "a first read that should have succeeded failed"
  write_answer "$home" second_call second-call yes "Yes" 2026-09-19T07:10:00.000Z
  chmod 500 "$home/state/board-remote"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>&1) || rc=$?
  chmod 700 "$home/state/board-remote"
  [ "$rc" -ne 0 ] || fail "a read that could not record its answer reported success"
  assert_not_contains "$out" "cursor: advanced" "a read that could not record its answer still moved the cursor"
  assert_no_grep "second-call" "$home/state/board-remote/delivered" \
    "an answer that was never recorded was marked delivered"

  after=$(cat "$dir/sample_call.json")
  assert_equals "$before" "$after" "the read changed the documents it was given"

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "answer: second-call" "the answer was lost by the failed read"
  pass "an answer that is not captured survives a failed read and is delivered next pass"
}

test_an_unwritable_record_refuses_rather_than_re_delivering_forever() {
  local home dir out rc=0
  home=$(make_home unusable-record)
  dir=$(answers_dir "$home")
  write_answer "$home" sample_call sample-call gold-only "Gold only" 2026-09-19T07:00:00.000Z
  mkdir -p "$home/state/board-remote/delivered"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an answer record that is not a plain file was accepted"
  assert_contains "$out" "not a plain file" "the refusal did not name what was wrong"
  rmdir "$home/state/board-remote/delivered"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "answer: sample-call" "the answer was lost by the refused read"
  pass "a record that cannot hold the cursor is refused rather than re-delivering forever"
}

test_the_read_never_consumes_the_store() {
  local home dir listing_before listing_after
  home=$(make_home non-consuming)
  dir=$(answers_dir "$home")
  write_answer "$home" one one yes "Yes" 2026-09-19T07:00:00.000Z
  write_answer "$home" two two no "No" 2026-09-19T07:01:00.000Z
  listing_before=$(cd "$dir" && find . -name '*.json' | sort && cat ./*.json)
  run_adapter "$home" ingest --documents "$dir" >/dev/null 2>&1 || fail "the read failed"
  run_adapter "$home" ingest --documents "$dir" >/dev/null 2>&1 || fail "the second read failed"
  listing_after=$(cd "$dir" && find . -name '*.json' | sort && cat ./*.json)
  assert_equals "$listing_before" "$listing_after" \
    "reading the answers removed or rewrote one of them"
  pass "reading the answers never consumes or clears them"
}

test_a_typed_value_cannot_forge_a_field() {
  local home dir out row fields
  home=$(make_home forged-field)
  dir=$(answers_dir "$home")
  # A value carrying the separator the intake reads, plus a newline: typed by a
  # person into a browser, and it must not become extra fields or extra rows.
  jq -n '{schema: "fm-bearings-answer.v1", question: "sample-call",
          selection: "", note: "yes\tmerge.other\tmerge\nsecond-call\tyes",
          key: "sample-call", prompt: "L\tforged\nrow",
          at: "2026-09-19T07:00:00.000Z", lang: "hant"}' \
    > "$dir/sample_call.json"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 1" "the answer carrying separators was not delivered"
  row=$(printf '%s\n' "$out" | sed -n 's/^answer: //p')
  assert_equals "1" "$(printf '%s\n' "$row" | grep -c .)" \
    "a typed newline became a second answer row"
  fields=$(printf '%s' "$row" | awk -F'\t' '{print NF}')
  assert_equals "3" "$fields" "a typed separator became extra fields: $row"
  # The framing above is one detection; this is the independent second one. The
  # typed separators must arrive as ordinary spaces, not as escape sequences a
  # later reader could turn back into separators.
  assert_not_contains "$row" '\t' "a typed separator survived as an escape sequence: $row"
  assert_not_contains "$row" '\n' "a typed newline survived as an escape sequence: $row"
  assert_contains "$row" "yes merge.other merge second-call yes" \
    "the typed separators did not arrive as spaces: $row"
  pass "a typed separator or newline cannot forge a field or a row"
}

test_unusable_documents_are_reported_not_dropped() {
  local home dir out
  home=$(make_home unusable-documents)
  dir=$(answers_dir "$home")
  printf 'not json at all\n' > "$dir/broken.json"
  printf '["an","array"]\n' > "$dir/array.json"
  jq -n '{at: "x", key: "has spaces", lang: "hant", label: "", value: "yes"}' > "$dir/badkey.json"
  jq -n '{at: "x", key: "empty-value", lang: "hant", label: "", value: ""}' > "$dir/emptyvalue.json"

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "documents: 4" "not every document was read"
  assert_contains "$out" "new: 0" "an unusable document was delivered as an answer"
  assert_contains "$out" "unusable: 4" "the unusable documents were not counted"
  assert_contains "$out" "unparsable-document: broken" "a document that is not JSON was dropped silently"
  assert_contains "$out" "unparsable-document: array" "a document that is not an object was dropped silently"
  assert_contains "$out" "unusable-document: badkey" "a document with a malformed key was dropped silently"
  assert_contains "$out" "unusable-document: emptyvalue" "an empty answer was dropped silently"
  pass "a document this channel cannot frame is reported rather than silently dropped"
}

# The intake truncates every field at 512 characters anyway, so refusing a longer
# answer here would only strand its card and wake firstmate every interval for an
# answer the captain has already given.
test_an_over_long_answer_is_truncated_rather_than_stranding_its_card() {
  local home dir out long value
  home=$(make_home long-answer)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --documents "$dir" --key long-call >/dev/null || fail "could not arm the source"
  long=$(printf 'x%.0s' $(seq 1 600))
  jq -n --arg v "$long" '{schema: "fm-bearings-answer.v1", question: "long-call",
                          selection: "", note: $v, key: "long-call", prompt: "",
                          at: "2026-09-19T07:00:00.000Z", lang: "hant"}' \
    > "$dir/long_call.json"

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  value=$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | awk -F'\t' '$1 == "long-call" { print $2 }')
  assert_equals "512" "${#value}" "the over-long answer did not arrive truncated to the intake's own bound"
  assert_contains "$out" "awaiting: 0" "an over-long answer left its card awaited forever"
  assert_contains "$out" "retired: yes" "an over-long answer kept the source armed with nothing left to wait for"
  pass "an over-long answer is truncated and settles its card instead of pinning the source"
}

# A path or an escape the captain typed must reach the intake as he typed it.
test_a_typed_backslash_reaches_the_intake_unchanged() {
  local home dir out value
  home=$(make_home typed-backslash)
  dir=$(answers_dir "$home")
  write_answer "$home" path_call path-call 'C:\logs\run and 100%' 'Use C:\logs' 2026-09-19T07:00:00.000Z

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  value=$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | awk -F'\t' '$1 == "path-call" { print $2 }')
  assert_equals 'C:\logs\run and 100%' "$value" "a typed backslash did not survive the framing intact"
  pass "a backslash the captain typed reaches the intake exactly as he typed it"
}

# The card that declared the mode is what wrote it, so the mode travels in the
# record. Nothing here may supply one the captain's board did not.
test_the_close_mode_comes_from_the_record() {
  local home dir out
  home=$(make_home close-mode)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --documents "$dir" --key gated-work --key plain-call >/dev/null \
    || fail "could not arm the source"
  write_answer "$home" gated_work gated-work proceed "" 2026-09-19T07:00:00.000Z release
  write_answer "$home" plain_call plain-call gold-only "" 2026-09-19T07:01:00.000Z
  write_dispatch_answer "$home" dispatch_charted task-a,task-b 2026-09-19T07:02:00.000Z

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_equals "release" \
    "$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | awk -F'\t' '$1 == "gated-work" { print $4 }')" \
    "an answer whose card declared release lost its close mode"
  assert_equals "3" "$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | grep '^plain-call' | awk -F'\t' '{print NF}')" \
    "an answer whose card declared no mode had one invented for it"
  assert_equals "3" "$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | grep '^dispatch.charted' | awk -F'\t' '{print NF}')" \
    "the dispatch order had a close mode invented for it"
  pass "the close mode comes from the record the board wrote, and is never invented"
}

test_ingest_retires_the_source_once_every_card_is_answered() {
  local home dir out
  home=$(make_home retire-on-settled)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --documents "$dir" --key first-call --key second-call >/dev/null \
    || fail "could not arm the source"

  write_answer "$home" first_call first-call yes "Yes" 2026-09-19T07:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "awaiting: 1" "answering one card did not leave the other awaited"
  assert_not_contains "$out" "retired: yes" "the source was retired while a card was still open"

  write_answer "$home" second_call second-call no "No" 2026-09-19T07:05:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "awaiting: 0" "answering the last card left it awaited"
  assert_contains "$out" "retired: yes" "the source was not retired once every card had an answer"
  pass "ingest retires the source the moment the last awaited card has an answer"
}

# An answer's VALUE can be a task id - the dispatch picker carries exactly that -
# so an awaited card must be settled by an answer under its own key and never by
# another card's answer that merely names it.
test_another_cards_answer_does_not_settle_a_card() {
  local home dir out
  home=$(make_home key-column)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --documents "$dir" --key sample-call >/dev/null \
    || fail "could not arm the source"
  write_answer "$home" dispatch_charted dispatch.charted sample-call "sample-call" 2026-09-19T07:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "awaiting: 1" \
    "a dispatch pick naming a card settled that card without answering it"
  assert_not_contains "$out" "retired:" \
    "the source retired while its card was still unanswered"
  run_adapter "$home" retire >/dev/null || fail "could not retire the armed source"
  pass "one card's answer never settles another card that its value happens to name"
}

test_an_unarmed_ingest_claims_no_retirement() {
  local home dir out
  home=$(make_home unarmed-ingest)
  dir=$(answers_dir "$home")
  write_answer "$home" sample_call sample-call gold-only "Gold only" 2026-09-19T07:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 1" "an unarmed read did not deliver the answer"
  assert_not_contains "$out" "retired:" "an unarmed read claimed to retire a source it never armed"
  pass "a read against a board that was never armed here claims no retirement"
}

# The sequence that used to cost the captain his answer: he answers while the
# tick is still asleep, and a board rebuild goes up over it before anyone reads.
# Losing that answer is the worst thing this adapter can do to him, because he
# has no way to see it happen - so the rebuild must deliver it, and it must
# still not settle the card the rebuild put up in its place.
test_a_board_rebuild_delivers_a_pending_answer_instead_of_stepping_over_it() {
  local home dir out
  home=$(make_home rebuild-over-answer)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --documents "$dir" --key task-a --key dispatch.charted >/dev/null \
    || fail "could not arm the first round"
  write_answer "$home" task_a task-a yes "Yes" 2026-09-19T07:00:00.000Z

  out=$(run_adapter "$home" arm --documents "$dir" --key task-a --key dispatch.charted) \
    || fail "could not rebuild the board"
  assert_contains "$out" "answer: task-a	yes" \
    "a board rebuild stepped over an answer the captain had already given"
  assert_contains "$out" "armed: board-remote" "the rebuild did not arm the new round"

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 0" "the delivered answer was delivered a second time"
  assert_contains "$out" "awaiting: 2" "the answer delivered by the rebuild settled a card the rebuild armed"
  assert_not_contains "$out" "retired: yes" "the source retired with both of this round's cards unanswered"
  run_adapter "$home" tick --interval 0.2 > "$home/open.result" || fail "the tick failed while the cards were open"
  assert_equals "due" "$(run_adapter "$home" classify "$home/open.result")" \
    "the source stopped waking firstmate while the captain still owed an answer"
  run_adapter "$home" retire >/dev/null || fail "could not retire the armed source"
  pass "a board rebuild delivers an answer already given and never settles its new cards with it"
}

# The first arm in a real home meets a store that already holds every answer of
# every earlier board round, because the board never deletes one. None of them
# was ever acted on, so all of them are delivered - and none of them answers a
# card this arm is putting up.
test_the_first_arm_delivers_a_full_store_without_settling_its_own_cards() {
  local home dir out
  home=$(make_home store-already-full)
  dir=$(answers_dir "$home")
  write_answer "$home" dispatch_charted dispatch.charted old-task "Old task" 2026-09-18T07:00:00.000Z
  write_answer "$home" old_call old-call yes "Yes" 2026-09-18T07:05:00.000Z

  out=$(run_adapter "$home" arm --documents "$dir" --key dispatch.charted --key new-call) \
    || fail "could not arm against a store that already holds answers"
  assert_contains "$out" "new: 2" "the answers already in the store were not delivered"
  assert_contains "$out" "already-answered: 2" "arm did not record what had already been delivered"

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 0" "an answer from an earlier board round was delivered twice"
  assert_contains "$out" "awaiting: 2" "an earlier round's answer settled a card armed today"
  assert_not_contains "$out" "retired:" "the source retired on answers nobody gave to its cards"
  run_adapter "$home" retire >/dev/null || fail "could not retire the armed source"
  pass "the first arm delivers a store full of earlier answers and settles none of its own cards with them"
}

# `dispatch.charted` is asked again on every board round, so the cursor - which
# is never pruned, because that is what keeps an answer from arriving twice -
# holds an answer under that key from the last round. A card armed now is open
# until the captain answers THIS round's question.
test_an_earlier_rounds_answer_does_not_settle_a_freshly_armed_card() {
  local home dir out
  home=$(make_home re-armed-key)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --documents "$dir" --key dispatch.charted >/dev/null || fail "could not arm the source"
  write_answer "$home" dispatch_charted dispatch.charted first-task "First task" 2026-09-19T07:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "retired: yes" "the first round did not retire once its card was answered"

  run_adapter "$home" arm --documents "$dir" --key dispatch.charted >/dev/null || fail "could not arm the same card again"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 0" "last round's answer was delivered a second time"
  assert_contains "$out" "awaiting: 1" "last round's answer settled a freshly armed card"
  assert_not_contains "$out" "retired: yes" "the source retired while this round's card was unanswered"
  run_adapter "$home" tick --interval 0.2 > "$home/rearmed.result" || fail "the tick failed while the card was open"
  assert_equals "due" "$(run_adapter "$home" classify "$home/rearmed.result")" \
    "the source stopped waking firstmate while the captain still owed an answer"

  # The board keeps one document per key, so this answer OVERWRITES the first
  # one: from here on the store can no longer show what he answered in round one.
  write_answer "$home" dispatch_charted dispatch.charted second-task "Second task" 2026-09-19T08:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "answer: dispatch.charted	second-task" "this round's answer was not delivered"
  assert_contains "$out" "awaiting: 0" "this round's own answer did not settle its card"
  assert_contains "$out" "retired: yes" "the source stayed armed after its card was answered"

  # Round three, with two answers to this key already behind it and the first of
  # them no longer anywhere in the store. The captain has said nothing yet.
  run_adapter "$home" arm --documents "$dir" --key dispatch.charted >/dev/null \
    || fail "could not arm the card for a third round"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "new: 0" "an answer from an earlier round was delivered again"
  assert_contains "$out" "awaiting: 1" "an overwritten answer from an earlier round settled the third round's card"
  assert_not_contains "$out" "retired: yes" "the source retired with the third round's card unanswered"
  run_adapter "$home" tick --interval 0.2 > "$home/third.result" || fail "the tick failed while the card was open"
  assert_equals "due" "$(run_adapter "$home" classify "$home/third.result")" \
    "the source stopped waking firstmate while the captain still owed a third answer"

  write_answer "$home" dispatch_charted dispatch.charted third-task "Third task" 2026-09-19T09:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "answer: dispatch.charted	third-task" "the third round's answer was not delivered"
  assert_contains "$out" "retired: yes" "the third round's own answer did not settle its card"
  pass "a card armed for a new round is settled only by an answer given since it was armed, round after round"
}

# The keyed lines reach the one intake and close the captain's own tasks. Needs
# a real backlog backend; without one the rest of this suite still runs.
test_answers_close_their_captain_held_tasks() {
  local home dir show
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home intake)
  dir=$(answers_dir "$home")
  run_captain "$home" hold membership-call --reason "which tier" --title "Which membership tier" >/dev/null \
    || fail "could not hold the sample captain call"
  run_captain "$home" hold gated-work --reason "needs the captain's word" --title "Gated work" >/dev/null \
    || fail "could not hold the sample gated work"
  run_captain "$home" hold written-call --reason "he will type it" --title "Written answer" >/dev/null \
    || fail "could not hold the sample written call"
  run_adapter "$home" arm --documents "$dir" --key membership-call --key gated-work --key written-call >/dev/null \
    || fail "could not arm the source"

  # All three forms the board actually writes, delivered together: a button
  # answer, a written-only answer whose card declared release, and a written-only
  # answer with no mode - plus the dispatch picker's own older shape.
  write_answer "$home" membership_call membership-call gold-only "" 2026-09-19T07:00:00.000Z
  write_answer "$home" gated_work gated-work "" "proceed after the release" 2026-09-19T07:01:00.000Z release
  write_answer "$home" written_call written-call "" "neither - do the third thing" 2026-09-19T07:02:00.000Z
  write_dispatch_answer "$home" dispatch_charted some-task 2026-09-19T07:03:00.000Z

  run_adapter "$home" ingest --documents "$dir" > "$home/ingest.out" 2>&1 \
    || fail "the ingest failed: $(cat "$home/ingest.out")"
  assert_grep "intake: closed=3 skipped=1" "$home/ingest.out" \
    "the intake did not settle all three answered calls and skip the dispatch key"

  show=$(tasks_in "$home" show membership-call --full)
  assert_contains "$show" "state: done" "a button answer did not close its captain call"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's answer"
  show=$(tasks_in "$home" show written-call --full)
  assert_contains "$show" "state: done" "a written-only answer did not close its captain call"
  assert_contains "$show" "Answer: neither - do the third thing" \
    "the captain's typed words were not what got recorded"
  show=$(tasks_in "$home" show gated-work --full)
  assert_contains "$show" "held: no" "a release-mode answer did not lift the hold"
  assert_contains "$show" "state: queued" "a release-mode answer closed the work item instead of releasing it"
  assert_contains "$show" "Answer: proceed after the release" \
    "the released item did not record the captain's typed words"
  pass "a button answer, a written-only answer, and both together reach the one intake"
}

test_help_advertises_the_commands
test_arm_refuses_what_it_cannot_serve
test_arm_reports_the_cards_it_will_wait_for
test_tick_is_due_while_a_card_is_open_and_settled_when_none_is
test_an_unreadable_result_stays_armed_and_announced
test_a_captured_answer_is_never_delivered_twice
test_a_changed_answer_under_one_key_is_a_new_answer
test_an_uncaptured_answer_survives_a_failed_read
test_an_unwritable_record_refuses_rather_than_re_delivering_forever
test_the_read_never_consumes_the_store
test_a_typed_value_cannot_forge_a_field
test_a_typed_backslash_reaches_the_intake_unchanged
test_unusable_documents_are_reported_not_dropped
test_an_over_long_answer_is_truncated_rather_than_stranding_its_card
test_the_close_mode_comes_from_the_record
test_ingest_retires_the_source_once_every_card_is_answered
test_another_cards_answer_does_not_settle_a_card
test_an_earlier_rounds_answer_does_not_settle_a_freshly_armed_card
test_a_board_rebuild_delivers_a_pending_answer_instead_of_stepping_over_it
test_the_first_arm_delivers_a_full_store_without_settling_its_own_cards
test_an_unarmed_ingest_claims_no_retirement
test_answers_close_their_captain_held_tasks

printf '# all fm-procevent-board-remote tests passed\n'
