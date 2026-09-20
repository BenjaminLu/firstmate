#!/usr/bin/env bash
# Behavioral tests for firstmate's gate-call record: the durable half of
# firstmate's own judgement.
#
# Every assertion drives a real entry point - the command line, or the fleet
# action whose own code writes the entry - and reads the resulting log. None of
# them reads implementation source.
#
# Three properties decide whether this record is worth having, and each site is
# checked against all three: the entry appears with the right verdict when that
# path runs, a site whose write fails still completes its own work, and a call
# that could not be recorded is visible as missing rather than silently gone.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE_CALL="$ROOT/bin/fm-gate-call.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-calls)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# jq is used only to READ the log back the way a board would, never to write it:
# the library must produce valid JSON with no jq installed.
log_field() {  # <log> <line-number> <field>
  jq -r --argjson n "$2" --arg f "$3" -s '.[$n - 1][$f]' < "$1"
}

log_lines() {  # <log>
  [ -f "$1" ] || { printf '0\n'; return 0; }
  wc -l < "$1" | tr -d ' '
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_gate_call() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$GATE_CALL" "$@"
}

# ---------------------------------------------------------------- the record

test_a_decided_call_is_recorded_with_every_field() {
  local home log rc=0
  home=$(make_home decided)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record \
    --site ask-user \
    --task board-redesign \
    --verdict decided \
    --what 'R3 doctor timeout' \
    --grounds 'an environment override nothing sets; restoring accepted behavior, not widening it' \
    --link https://github.com/example/repo/pull/30 \
    --key R3 > "$home/stdout" 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "decided: recording a decided call must succeed"
  expect_code 1 "$(log_lines "$log")" "decided: exactly one line must be appended"
  assert_equals decided "$(log_field "$log" 1 verdict)" "decided: wrong verdict"
  assert_equals board-redesign "$(log_field "$log" 1 task)" "decided: wrong task"
  assert_equals ask-user "$(log_field "$log" 1 site)" "decided: wrong site"
  assert_equals 'R3 doctor timeout' "$(log_field "$log" 1 what)" "decided: wrong subject"
  assert_equals https://github.com/example/repo/pull/30 "$(log_field "$log" 1 link)" \
    "decided: wrong link"
  assert_equals R3 "$(log_field "$log" 1 key)" "decided: wrong key"
  assert_contains "$(log_field "$log" 1 grounds)" 'environment override' \
    "decided: the grounds did not survive"
  printf '%s' "$(log_field "$log" 1 at)" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || fail "decided: the timestamp is not a UTC ISO-8601 instant"
  assert_absent "$home/state/gate-calls.drops" "decided: a clean record wrote a drop"
  pass "a decided call is recorded with when, what, why, the link and the key"
}

test_every_verdict_in_the_vocabulary_is_accepted() {
  local home log verdict rc n=0
  home=$(make_home verdicts)
  log="$home/state/gate-calls.jsonl"
  for verdict in decided escalated refused deferred; do
    rc=0
    n=$((n + 1))
    run_gate_call "$home" record --task task-v --verdict "$verdict" \
      --what "call $n" --grounds "because $n" >/dev/null 2>&1 || rc=$?
    expect_code 0 "$rc" "verdicts: $verdict must be accepted"
    assert_equals "$verdict" "$(log_field "$log" "$n" verdict)" \
      "verdicts: $verdict was not recorded as itself"
  done
  expect_code 4 "$(log_lines "$log")" "verdicts: the log must be append-only"
  pass "the log carries all four verdicts and appends rather than replaces"
}

test_a_call_with_no_grounds_is_refused_and_reported() {
  local home log rc=0
  home=$(make_home no-grounds)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record --task task-g --verdict decided \
    --what 'R1 naming' --grounds '' > "$home/stdout" 2> "$home/stderr" || rc=$?

  expect_code 2 "$rc" "no-grounds: a ruling with no reason must be refused"
  assert_absent "$log" "no-grounds: a groundless entry reached the log"
  pass "a ruling with no stated grounds never reaches the log"
}

test_a_multi_line_refusal_keeps_its_structure_on_one_line() {
  local home log rc=0 grounds
  home=$(make_home multiline)
  log="$home/state/gate-calls.jsonl"
  grounds='  - check "Lint 2" is not green
  - check "CI" is not green'

  run_gate_call "$home" record --task task-m --verdict refused \
    --what 'merge pull request 27' --grounds "$grounds" >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "multiline: a multi-line refusal list must record"
  expect_code 1 "$(log_lines "$log")" "multiline: the record must stay one line"
  assert_contains "$(log_field "$log" 1 grounds)" 'Lint 2' \
    "multiline: the first failing condition was lost"
  assert_contains "$(log_field "$log" 1 grounds)" 'CI' \
    "multiline: the second failing condition was lost"
  pass "a multi-line refusal list survives intact inside a one-line record"
}

test_an_oversized_call_is_shortened_visibly() {
  local home log rc=0 grounds
  home=$(make_home oversized)
  log="$home/state/gate-calls.jsonl"
  grounds=$(head -c 20000 < /dev/zero | tr '\0' 'g')

  run_gate_call "$home" record --task task-o --verdict deferred \
    --what 'a very long finding' --grounds "$grounds" >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "oversized: an overlong call must still record"
  expect_code 1 "$(log_lines "$log")" "oversized: the record must stay one line"
  assert_equals true "$(log_field "$log" 1 truncated)" \
    "oversized: shortening was not declared in the record"
  [ "$(wc -c < "$log" | tr -d ' ')" -lt 4096 ] \
    || fail "oversized: the record line exceeded its byte bound"
  pass "an overlong call is shortened visibly rather than silently"
}

# ------------------------------------------------- a missing record is visible

test_an_unwritable_log_is_reported_not_swallowed() {
  local home log drops rc=0
  home=$(make_home unwritable)
  log="$home/state/gate-calls.jsonl"
  drops="$home/state/gate-calls.drops"
  : > "$log"
  chmod 000 "$log"

  run_gate_call "$home" record --task task-u --verdict decided \
    --what 'R7 stale badge' --grounds 'seventeen fix rounds spent' \
    > "$home/stdout" 2> "$home/stderr" || rc=$?
  chmod 644 "$log"

  expect_code 1 "$rc" "unwritable: an unrecorded call must report a failure"
  assert_grep 'actionable:' "$home/stderr" "unwritable: the drop was silent on stderr"
  assert_grep 'task-u' "$home/stderr" "unwritable: the stderr report did not name the task"
  assert_present "$drops" "unwritable: the drop left no durable trace"
  assert_grep 'R7 stale badge' "$drops" "unwritable: the drops record lost the call"
  assert_equals 'the gate-call log could not be appended to' \
    "$(log_field "$drops" 1 dropped)" "unwritable: the drop did not say why"
  pass "a call that cannot be logged is reported on stderr and kept in the drops record"
}

test_an_unwritable_state_directory_still_reports() {
  local home rc=0
  home=$(make_home no-state)
  chmod 000 "$home/state"

  run_gate_call "$home" record --task task-s --verdict refused \
    --what 'merge pull request 9' --grounds 'checks are not green' \
    > "$home/stdout" 2> "$home/stderr" || rc=$?
  chmod 755 "$home/state"

  expect_code 1 "$rc" "no-state: an unrecordable call must report a failure"
  assert_grep 'actionable:' "$home/stderr" "no-state: the drop was silent"
  assert_grep 'task-s' "$home/stderr" "no-state: the stderr report did not name the task"
  pass "a home whose state cannot be written still says the call went unrecorded"
}

test_a_drops_record_reads_with_the_same_parser_as_the_log() {
  local home drops rc=0
  home=$(make_home same-parser)
  drops="$home/state/gate-calls.drops"

  run_gate_call "$home" record --task task-p --verdict conjured \
    --what 'an invented verdict' --grounds 'nothing' >/dev/null 2>&1 || rc=$?

  expect_code 1 "$rc" "same-parser: an invalid verdict must not be recorded as a call"
  assert_absent "$home/state/gate-calls.jsonl" "same-parser: an invalid verdict reached the log"
  assert_equals conjured "$(log_field "$drops" 1 verdict)" \
    "same-parser: the drops record is not the same object shape as the log"
  pass "the drops record is the same JSON object plus its reason, so one parser reads both"
}

test_a_declined_review_finding_is_recorded_as_deferred() {
  local home log rc=0
  home=$(make_home deferred)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record \
    --site review-finding \
    --task acknowledgement-branch \
    --verdict deferred \
    --what 'R5 widen the acknowledgement to every board key' \
    --grounds 'the marginal one of the five: closest to a criterion the captain settled, and cut only because the round was held to three' \
    --link https://github.com/example/repo/pull/30 \
    --key R5 >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "deferred: declining a finding must record"
  assert_equals deferred "$(log_field "$log" 1 verdict)" \
    "deferred: a declined finding must be recorded as deferred"
  assert_equals review-finding "$(log_field "$log" 1 site)" "deferred: wrong site"
  assert_equals R5 "$(log_field "$log" 1 key)" \
    "deferred: the finding id must be the routing key so the ruling lines up with the review"
  assert_contains "$(log_field "$log" 1 grounds)" 'held to three' \
    "deferred: the reasoning behind declining it was lost"
  pass "a review finding declined rather than fixed is recorded as deferred, with its reason"
}

test_an_over_long_identity_field_is_refused_rather_than_cut() {
  local home log drops rc=0 long_task
  home=$(make_home long-task)
  log="$home/state/gate-calls.jsonl"
  drops="$home/state/gate-calls.drops"
  long_task=$(head -c 300 < /dev/zero | tr '\0' 't')

  run_gate_call "$home" record --task "$long_task" --verdict decided \
    --what 'a call against an implausible task id' --grounds 'testing the cap' \
    >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 1 "$rc" "long-task: an over-long task id must be refused"
  assert_absent "$log" "long-task: a half-written task id reached the log"
  assert_present "$drops" "long-task: the refused call left no durable trace"
  [ "$(wc -c < "$drops" | tr -d ' ')" -lt 4096 ] \
    || fail "long-task: the drops record ignored the byte bound"
  assert_grep 'actionable:' "$home/stderr" "long-task: the refusal was silent"
  pass "an over-long task id is refused, not silently cut to point at the wrong task"
}

test_an_oversized_drop_stays_within_the_byte_bound() {
  local home drops rc=0 grounds
  home=$(make_home oversized-drop)
  drops="$home/state/gate-calls.drops"
  grounds=$(head -c 20000 < /dev/zero | tr '\0' 'g')

  run_gate_call "$home" record --task task-d --verdict conjured \
    --what 'an invented verdict with a very long reason' --grounds "$grounds" \
    >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 1 "$rc" "oversized-drop: an invalid verdict must be refused"
  assert_present "$drops" "oversized-drop: the refused call left no durable trace"
  expect_code 1 "$(log_lines "$drops")" "oversized-drop: the drops record must stay one line"
  [ "$(wc -c < "$drops" | tr -d ' ')" -lt 4096 ] \
    || fail "oversized-drop: the drops record exceeded the byte bound"
  assert_equals true "$(log_field "$drops" 1 truncated)" \
    "oversized-drop: shortening was not declared in the drops record"
  pass "a dropped call is shortened to the same bound as a recorded one"
}

# ------------------------------------------------------- the captain-hold site

test_holding_a_task_for_the_captain_records_an_escalated_call() {
  local home log rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home hold-site)
  log="$home/state/gate-calls.jsonl"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"

  PATH="$(fm_fakebin "$home"):$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" \
    hold clone-worker-launch --title 'Which board implementation ships' \
    --reason 'an unmeasured blast radius on his own permission rules is his call' \
    > "$home/stdout" 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "hold-site: the hold itself must succeed"
  expect_code 1 "$(log_lines "$log")" "hold-site: the hold recorded no gate call"
  assert_equals escalated "$(log_field "$log" 1 verdict)" \
    "hold-site: a hold is an escalation and must be recorded as one"
  assert_equals clone-worker-launch "$(log_field "$log" 1 task)" "hold-site: wrong task"
  assert_equals captain-hold "$(log_field "$log" 1 site)" "hold-site: wrong site"
  assert_contains "$(log_field "$log" 1 what)" 'Which board implementation ships' \
    "hold-site: the call's subject was lost"
  assert_contains "$(log_field "$log" 1 grounds)" 'unmeasured blast radius' \
    "hold-site: the captain's own grounds were lost"
  assert_contains "$(log_field "$log" 1 key)" 'captain-hold-clone-worker-launch-' \
    "hold-site: the routing key was lost"
  pass "holding a task for the captain records it as an escalated gate call"
}

test_a_hold_still_lands_when_its_gate_call_cannot_be_recorded() {
  local home log rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home hold-unwritable)
  log="$home/state/gate-calls.jsonl"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  : > "$log"
  chmod 000 "$log"

  PATH="$(fm_fakebin "$home"):$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" \
    hold fund-moving-off-bash --title 'Whether to fund moving off bash' \
    --reason 'a product call not settled by accepted intent' \
    > "$home/stdout" 2> "$home/stderr" || rc=$?
  chmod 644 "$log"

  expect_code 0 "$rc" \
    "hold-unwritable: an unrecordable gate call must not stop the hold"
  assert_grep fund-moving-off-bash "$home/stdout" \
    "hold-unwritable: the hold did not report the task it held"
  assert_grep 'actionable:' "$home/stderr" \
    "hold-unwritable: the unrecorded call was silent"
  assert_present "$home/state/gate-calls.drops" \
    "hold-unwritable: the unrecorded call left no durable trace"
  PATH="$(fm_fakebin "$home"):$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" \
    open fund-moving-off-bash > "$home/open" 2>&1 \
    || fail "hold-unwritable: the task is not actually held for the captain"
  pass "a hold lands, and says its record did not, when the log cannot be written"
}

test_a_decided_call_is_recorded_with_every_field
test_every_verdict_in_the_vocabulary_is_accepted
test_a_call_with_no_grounds_is_refused_and_reported
test_a_multi_line_refusal_keeps_its_structure_on_one_line
test_a_declined_review_finding_is_recorded_as_deferred
test_an_oversized_call_is_shortened_visibly
test_an_unwritable_log_is_reported_not_swallowed
test_an_unwritable_state_directory_still_reports
test_a_drops_record_reads_with_the_same_parser_as_the_log
test_an_over_long_identity_field_is_refused_rather_than_cut
test_an_oversized_drop_stays_within_the_byte_bound
test_holding_a_task_for_the_captain_records_an_escalated_call
test_a_hold_still_lands_when_its_gate_call_cannot_be_recorded
