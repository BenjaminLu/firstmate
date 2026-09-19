#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-board-remote.sh, the remote board's
# answer wake path.
#
# The two properties the captain paid for get the most attention here, and both
# are driven through the real adapter against real answer documents rather than
# through a stub that answers whatever the assertion wants:
#
#   - a captured answer is never delivered twice, and the deduplication keys on
#     the answer's own identity rather than on its position or on a count, so
#     the same answer re-listed beside new ones is still recognized;
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
write_answer() {  # <home> <doc-id> <key> <value> <label> <at>
  local home=$1 doc=$2
  jq -n --arg key "$3" --arg value "$4" --arg label "$5" --arg at "$6" \
    '{at: $at, key: $key, label: $label, lang: "hant", value: $value}' \
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
  local home out
  home=$(make_home arm-refusals)

  out=$(run_adapter "$home" arm --key sample-call --interval 30 2>&1) && fail "an interval under the floor was accepted"
  assert_contains "$out" "60" "the sub-floor refusal did not name the floor"
  assert_contains "$out" "within about a minute" "the sub-floor refusal did not say why the floor is there"

  out=$(run_adapter "$home" arm --interval 60 2>&1) && fail "arming with nothing awaited was accepted"
  assert_contains "$out" "at least one --key" "arming with no key did not name what was missing"

  out=$(run_adapter "$home" arm --key "not a key" 2>&1) && fail "an invalid card key was accepted"
  out=$(run_adapter "$home" arm --key sample-call=maybe 2>&1) && fail "an invalid close mode was accepted"
  assert_contains "$out" "done or release" "the close-mode refusal did not name the accepted modes"

  assert_absent "$home/state/board-remote/awaiting" \
    "a refused arm still wrote an awaited card set"
  pass "arm refuses a sub-floor interval, an empty card set, a bad key and a bad close mode"
}

test_arm_records_the_cards_and_status_reports_them() {
  local home out
  home=$(make_home arm-records)
  out=$(run_adapter "$home" arm --key sample-call=release --key merge.other --interval 60) \
    || fail "could not arm the source"
  assert_contains "$out" "awaiting: 2" "arm did not report the awaited card count"
  out=$(run_adapter "$home" status)
  assert_contains "$out" "key: sample-call (close: release)" "status lost the card's close mode"
  assert_contains "$out" "key: merge.other (close: done)" "status lost the default close mode"
  assert_contains "$out" "should-be-armed: yes" "status did not say the source should be armed"
  run_adapter "$home" retire >/dev/null || fail "could not retire the armed source"
  pass "arm records every card with its close mode and status reports them"
}

test_tick_is_due_while_a_card_is_open_and_settled_when_none_is() {
  local home out
  home=$(make_home tick-states)

  run_adapter "$home" arm --key sample-call --interval 60 >/dev/null || fail "could not arm the source"
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
  jq -n '{at: "2026-09-19T07:00:00.000Z", key: "sample-call", lang: "hant",
          label: "L\tforged\nrow", value: "yes\tmerge.other\tmerge\nsecond-call\tyes"}' \
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
  local home dir out long
  home=$(make_home unusable-documents)
  dir=$(answers_dir "$home")
  printf 'not json at all\n' > "$dir/broken.json"
  printf '["an","array"]\n' > "$dir/array.json"
  jq -n '{at: "x", key: "has spaces", lang: "hant", label: "", value: "yes"}' > "$dir/badkey.json"
  long=$(printf 'x%.0s' $(seq 1 600))
  jq -n --arg v "$long" '{at: "x", key: "long-value", lang: "hant", label: "", value: $v}' \
    > "$dir/longvalue.json"
  jq -n '{at: "x", key: "empty-value", lang: "hant", label: "", value: ""}' > "$dir/emptyvalue.json"

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "documents: 5" "not every document was read"
  assert_contains "$out" "new: 0" "an unusable document was delivered as an answer"
  assert_contains "$out" "unusable: 5" "the unusable documents were not counted"
  assert_contains "$out" "unparsable-document: broken" "a document that is not JSON was dropped silently"
  assert_contains "$out" "unparsable-document: array" "a document that is not an object was dropped silently"
  assert_contains "$out" "unusable-document: badkey" "a document with a malformed key was dropped silently"
  assert_contains "$out" "unusable-document: longvalue" "an over-long answer was dropped silently"
  assert_contains "$out" "unusable-document: emptyvalue" "an empty answer was dropped silently"
  pass "a document this channel cannot frame is reported rather than silently dropped"
}

test_the_close_mode_comes_from_arming() {
  local home dir out
  home=$(make_home close-mode)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --key gated-work=release --key plain-call --interval 60 >/dev/null \
    || fail "could not arm the source"
  write_answer "$home" gated_work gated-work proceed "Proceed" 2026-09-19T07:00:00.000Z
  write_answer "$home" plain_call plain-call gold-only "Gold only" 2026-09-19T07:01:00.000Z
  write_answer "$home" dispatch_charted dispatch.charted pick "Pick" 2026-09-19T07:02:00.000Z

  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "answer: gated-work	proceed	Proceed	release" \
    "an answer to a release-mode card lost its close mode"
  assert_equals "3" "$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | grep '^plain-call' | awk -F'\t' '{print NF}')" \
    "an answer to an ordinary card invented a close mode"
  assert_equals "3" "$(printf '%s\n' "$out" | sed -n 's/^answer: //p' | grep '^dispatch.charted' | awk -F'\t' '{print NF}')" \
    "an answer to a key that was never armed invented a close mode"
  pass "the close mode comes from arming, and a key that was not armed gets none"
}

test_ingest_retires_the_source_once_every_card_is_answered() {
  local home dir out
  home=$(make_home retire-on-settled)
  dir=$(answers_dir "$home")
  run_adapter "$home" arm --key first-call --key second-call --interval 60 >/dev/null \
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
  run_adapter "$home" arm --key sample-call --interval 60 >/dev/null \
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

test_a_dry_run_changes_nothing() {
  local home dir out
  home=$(make_home dry-run)
  dir=$(answers_dir "$home")
  write_answer "$home" sample_call sample-call gold-only "Gold only" 2026-09-19T07:00:00.000Z
  out=$(run_adapter "$home" ingest --documents "$dir" --dry-run 2>/dev/null)
  assert_contains "$out" "answer: sample-call" "a dry run did not report what it would deliver"
  assert_contains "$out" "cursor: unchanged (dry run)" "a dry run did not say the cursor was untouched"
  assert_absent "$home/state/board-remote/delivered" "a dry run advanced the cursor"
  out=$(run_adapter "$home" ingest --documents "$dir" 2>/dev/null)
  assert_contains "$out" "answer: sample-call" "a dry run consumed the answer"
  pass "a dry run reports what it would deliver and changes nothing"
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
  run_adapter "$home" arm --key membership-call --key gated-work=release --interval 60 >/dev/null \
    || fail "could not arm the source"

  write_answer "$home" membership_call membership-call gold-only "Gold only" 2026-09-19T07:00:00.000Z
  write_answer "$home" gated_work gated-work proceed "Proceed" 2026-09-19T07:01:00.000Z
  write_answer "$home" dispatch_charted dispatch.charted some-task "Some task" 2026-09-19T07:02:00.000Z

  run_adapter "$home" ingest --documents "$dir" > "$home/ingest.out" 2>&1 \
    || fail "the ingest failed: $(cat "$home/ingest.out")"
  assert_grep "intake: closed=2 skipped=1" "$home/ingest.out" \
    "the intake did not close both answered calls and skip the dispatch key"

  show=$(tasks_in "$home" show membership-call --full)
  assert_contains "$show" "state: done" "an answered captain call was not closed"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's answer"
  show=$(tasks_in "$home" show gated-work --full)
  assert_contains "$show" "held: no" "a release-mode answer did not lift the hold"
  assert_contains "$show" "state: queued" "a release-mode answer closed the work item instead of releasing it"
  pass "the answers reach the one keyed-answer intake and close or release their tasks"
}

test_help_advertises_the_commands
test_arm_refuses_what_it_cannot_serve
test_arm_records_the_cards_and_status_reports_them
test_tick_is_due_while_a_card_is_open_and_settled_when_none_is
test_an_unreadable_result_stays_armed_and_announced
test_a_captured_answer_is_never_delivered_twice
test_a_changed_answer_under_one_key_is_a_new_answer
test_an_uncaptured_answer_survives_a_failed_read
test_an_unwritable_record_refuses_rather_than_re_delivering_forever
test_the_read_never_consumes_the_store
test_a_typed_value_cannot_forge_a_field
test_unusable_documents_are_reported_not_dropped
test_the_close_mode_comes_from_arming
test_ingest_retires_the_source_once_every_card_is_answered
test_another_cards_answer_does_not_settle_a_card
test_an_unarmed_ingest_claims_no_retirement
test_a_dry_run_changes_nothing
test_answers_close_their_captain_held_tasks

printf '# all fm-procevent-board-remote tests passed\n'
