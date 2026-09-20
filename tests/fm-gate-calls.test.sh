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
  assert_equals '' "$(log_field "$log" 1 rejected)" \
    "decided: a clean record claimed a field was rejected"
  assert_absent "$home/state/gate-calls.drops" "decided: a clean record wrote a drop"
  pass "a decided call is recorded with when, what, why, the link and the key"
}

test_a_malformed_link_loses_the_link_and_not_the_call() {
  local home log rc=0
  home=$(make_home bad-link)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record --site captain-hold --task clone-worker-launch \
    --verdict escalated --what 'which board implementation ships' \
    --grounds 'an unmeasured blast radius on his own permission rules is his call' \
    --link 'https://github.com/example/repo/pull/1 ' --key R1 \
    >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "bad-link: a trailing space on a link must not cost the call"
  expect_code 1 "$(log_lines "$log")" "bad-link: the call did not reach the log"
  assert_absent "$home/state/gate-calls.drops" \
    "bad-link: a well-formed ruling was filed as a system failure"
  assert_equals escalated "$(log_field "$log" 1 verdict)" "bad-link: the verdict was lost"
  assert_contains "$(log_field "$log" 1 grounds)" 'unmeasured blast radius' \
    "bad-link: the grounds were lost"
  assert_equals R1 "$(log_field "$log" 1 key)" "bad-link: a valid key was thrown out too"
  assert_equals '' "$(log_field "$log" 1 link)" "bad-link: the malformed link was recorded anyway"
  assert_equals link "$(log_field "$log" 1 rejected)" \
    "bad-link: the dropped link is invisible in the record"
  pass "a malformed link is dropped and named, and the ruling still reaches the log"
}

test_a_malformed_key_is_named_beside_a_malformed_link() {
  local home log rc=0
  home=$(make_home bad-both)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record --task task-b --verdict decided \
    --what 'a ruling typed by hand' --grounds 'both optional fields fat-fingered' \
    --link 'github.com/example/repo/pull/2' --key 'R2 (the second one)' \
    >/dev/null 2>&1 || rc=$?

  expect_code 0 "$rc" "bad-both: two malformed optional fields must not cost the call"
  assert_equals 'link,key' "$(log_field "$log" 1 rejected)" \
    "bad-both: the record does not name both dropped fields"
  assert_equals decided "$(log_field "$log" 1 verdict)" "bad-both: the verdict was lost"
  pass "both dropped presentation fields are named in the record"
}

test_a_bad_task_id_still_costs_the_whole_record() {
  local home rc=0
  home=$(make_home bad-task)

  run_gate_call "$home" record --task 'not a task id' --verdict decided \
    --what 'a call naming no identifiable task' --grounds 'testing the severity split' \
    >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 1 "$rc" "bad-task: an unidentifiable task must still refuse the record"
  assert_absent "$home/state/gate-calls.jsonl" \
    "bad-task: a record naming no real task reached the log"
  assert_present "$home/state/gate-calls.drops" "bad-task: the refusal left no durable trace"
  pass "a bad identity field still costs the record, unlike a bad presentation field"
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
  case "$(log_field "$log" 1 grounds)" in
    *...) : ;;
    *) fail "oversized: the cut value does not say it was cut, so a surface that renders grounds without consulting truncated shows a sentence stopping mid-word as the whole reason" ;;
  esac
  case "$(log_field "$log" 1 what)" in
    *...) fail "oversized: a field that was never shortened claims it was" ;;
  esac
  [ "$(wc -c < "$log" | tr -d ' ')" -le 1024 ] \
    || fail "oversized: the record line crossed the 1024-byte flush boundary, where concurrent appends tear"
  pass "an overlong call is shortened visibly rather than silently"
}

test_concurrent_writers_never_tear_a_record() {
  local home log rounds=20 writers=3 r i grounds torn=0 total line
  home=$(make_home concurrent)
  log="$home/state/gate-calls.jsonl"
  # Longer than any bound, so every record is shortened to the maximum line
  # the library will emit. That is the only size worth racing: a bound that
  # holds for short lines and tears at its own maximum is not a bound.
  grounds=$(head -c 4000 < /dev/zero | tr '\0' 'g')

  for r in $(seq 1 "$rounds"); do
    for i in $(seq 1 "$writers"); do
      run_gate_call "$home" record --site pr-merge --task "task-r${r}w${i}" \
        --verdict refused --what 'merge pull request 38' --grounds "$grounds" \
        >/dev/null 2>&1 &
    done
    wait
  done

  total=$(log_lines "$log")
  expect_code $(( rounds * writers )) "$total" \
    "concurrent: the log lost or gained whole lines under concurrent writers"
  while IFS= read -r line; do
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || torn=$((torn + 1))
  done < "$log"
  expect_code 0 "$torn" \
    "concurrent: $torn of $total records were torn - a torn line is unparseable, writes no drops entry and says nothing on stderr, which is the silent loss this log exists to prevent"
  assert_absent "$home/state/gate-calls.drops" \
    "concurrent: a clean concurrent run reported dropped calls"
  pass "concurrent writers at the maximum line size never tear a record"
}

test_a_shortened_record_stays_valid_utf8_in_any_locale() {
  local home log locale pad rc=0 cjk grounds
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  # CJK, so every character is three bytes and every cut point that is not a
  # multiple of three lands inside one. The captain's own asks in this work
  # are CJK. The three ASCII pads below shift the cut through all three byte
  # offsets, so one of them must land mid-character whatever the halving does
  # - which is what stops this case passing by luck on a clean boundary.
  cjk=''
  while [ "${#cjk}" -lt 800 ]; do
    cjk="${cjk}中文字元的理由說明"
  done

  for locale in en_US.UTF-8 C; do
    for pad in '' 'x' 'xx'; do
      home=$(make_home "utf8-$locale-${#pad}")
      log="$home/state/gate-calls.jsonl"
      grounds="${pad}${cjk}"
      rc=0
      LC_ALL="$locale" LANG="$locale" run_gate_call "$home" record \
        --site review-finding --task task-u8 --verdict refused \
        --what 'a ruling with a long reason' --grounds "$grounds" \
        >/dev/null 2>&1 || rc=$?
      expect_code 0 "$rc" "utf8-$locale-${#pad}: the call must record"
      assert_equals true "$(log_field "$log" 1 truncated)" \
        "utf8-$locale-${#pad}: this case only tests anything if the record was shortened"
      python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' < "$log" \
        || fail "utf8-$locale-${#pad}: the shortened record is not valid UTF-8, so it is not valid JSON and a strict reader loses the line"
      python3 -c 'import json,sys; json.loads(sys.stdin.buffer.read().decode("utf-8"))' < "$log" \
        || fail "utf8-$locale-${#pad}: the shortened record is not a JSON object to a strict parser"
    done
  done
  pass "a shortened record stays valid UTF-8, and valid JSON, at every cut offset under a C locale as well as a UTF-8 one"
}

test_a_bulky_link_costs_the_link_and_never_the_ruling() {
  local home log rc=0 cjk link grounds
  home=$(make_home bulky-link)
  log="$home/state/gate-calls.jsonl"
  # 498 characters, 1458 bytes. Inside a character cap, far outside a byte
  # one - which is how a valid call used to cross the tear boundary.
  cjk=''
  while [ "${#cjk}" -lt 480 ]; do cjk="${cjk}中"; done
  link="https://x.example/${cjk}"
  grounds=$(head -c 3000 < /dev/zero | tr '\0' 'g')

  run_gate_call "$home" record --site pr-merge --task task-n1 --verdict refused \
    --what 'merge pull request 38' --grounds "$grounds" --link "$link" --key R1 \
    >/dev/null 2>&1 || rc=$?

  expect_code 0 "$rc" "bulky-link: the call must still record"
  [ "$(wc -c < "$log" | tr -d ' ')" -le 1024 ] \
    || fail "bulky-link: the emitted line crossed the 1024-byte flush boundary, where concurrent appends tear"
  assert_equals 'merge pull request 38' "$(log_field "$log" 1 what)" \
    "bulky-link: the subject of the call was destroyed to chase the bound"
  case "$(log_field "$log" 1 grounds)" in
    ...|'') fail "bulky-link: the ruling was reduced to its marker - a ruling with no reason is not a ruling" ;;
  esac
  assert_contains "$(log_field "$log" 1 rejected)" link \
    "bulky-link: the dropped link is invisible in the record"
  pass "an oversized link is dropped and named, and the ruling it was attached to survives intact"
}

test_an_oversized_link_is_rejected_before_it_can_shorten_the_grounds() {
  local home log rc=0 cjk link
  home=$(make_home byte-cap-link)
  log="$home/state/gate-calls.jsonl"
  # 498 characters, 1458 bytes: inside the cap if the cap counts characters,
  # outside it if the cap counts bytes - which is the unit the line bound
  # uses. The grounds here are short, so the shortening ladder has no reason
  # to run: anything that happens to them is the cap failing to catch this.
  cjk=''
  while [ "${#cjk}" -lt 480 ]; do cjk="${cjk}中"; done
  link="https://x.example/${cjk}"

  run_gate_call "$home" record --site pr-merge --task task-n1c --verdict refused \
    --what 'merge pull request 38' --grounds 'the checks are not green' \
    --link "$link" >/dev/null 2>&1 || rc=$?

  expect_code 0 "$rc" "byte-cap-link: the call must still record"
  assert_equals link "$(log_field "$log" 1 rejected)" \
    "byte-cap-link: a 1458-byte link passed a cap that is supposed to be counted in the same unit as the line bound"
  assert_equals 'the checks are not green' "$(log_field "$log" 1 grounds)" \
    "byte-cap-link: the grounds were shortened, so the link reached the line and the ladder had to rescue it"
  assert_equals false "$(log_field "$log" 1 truncated)" \
    "byte-cap-link: nothing should have needed shortening once the link was rejected"
  pass "an over-cap link is rejected on its byte length, before it can cost the grounds anything"
}

test_an_escape_heavy_link_cannot_cross_the_boundary() {
  local home log rc=0 quotes
  home=$(make_home escape-link)
  log="$home/state/gate-calls.jsonl"
  # Inside every cap as raw bytes; JSON escaping doubles each one.
  quotes=$(head -c 480 < /dev/zero | tr '\0' '"')

  run_gate_call "$home" record --site pr-merge --task task-n1b --verdict refused \
    --what 'merge pull request 38' --grounds 'the checks are not green' \
    --link "https://x.example/$quotes" >/dev/null 2>&1 || rc=$?

  expect_code 0 "$rc" "escape-link: the call must still record"
  [ "$(wc -c < "$log" | tr -d ' ')" -le 1024 ] \
    || fail "escape-link: JSON escaping pushed the emitted line past the flush boundary"
  assert_contains "$(log_field "$log" 1 grounds)" 'not green' \
    "escape-link: the grounds were lost to an over-long link"
  pass "a link that only becomes oversized once escaped is dropped rather than written over the bound"
}

test_a_bulky_task_id_keeps_the_drops_record_bounded() {
  local home drops rc=0 cjk
  home=$(make_home bulky-task)
  drops="$home/state/gate-calls.drops"
  cjk=''
  while [ "${#cjk}" -lt 160 ]; do cjk="${cjk}中"; done

  run_gate_call "$home" record --site review-finding --task "$cjk" \
    --verdict refused --what w --grounds g >/dev/null 2>&1 || rc=$?

  expect_code 1 "$rc" "bulky-task: an over-cap task id must be refused"
  assert_present "$drops" "bulky-task: the refusal left no durable trace"
  [ "$(wc -c < "$drops" | tr -d ' ')" -le 1024 ] \
    || fail "bulky-task: the drops line crossed the flush boundary, so the record of the gap can tear too"
  pass "an over-cap identity field keeps the drops record inside the same boundary as the log"
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

test_a_declined_review_finding_is_recorded_as_refused() {
  local home log rc=0
  home=$(make_home declined)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record \
    --site review-finding \
    --task acknowledgement-branch \
    --verdict refused \
    --what 'R9 wire every refusal path in fm-pr-merge.sh' \
    --grounds 'correct but out of scope: wiring them all commits this project to keeping them wired as that script grows' \
    --link https://github.com/example/repo/pull/30 \
    --key R9 >/dev/null 2> "$home/stderr" || rc=$?

  expect_code 0 "$rc" "declined: declining a finding must record"
  assert_equals refused "$(log_field "$log" 1 verdict)" \
    "declined: a permanent decline must be refused, not deferred - deferred says firstmate means to come back to it"
  assert_equals review-finding "$(log_field "$log" 1 site)" "declined: wrong site"
  assert_equals R9 "$(log_field "$log" 1 key)" \
    "declined: the finding id must be the routing key so the ruling lines up with the review"
  assert_contains "$(log_field "$log" 1 grounds)" 'out of scope' \
    "declined: the reason for declining it was lost"
  pass "a review finding declined as out of scope is recorded as refused, with its reason"
}

test_a_postponed_call_is_the_only_thing_recorded_as_deferred() {
  local home log rc=0
  home=$(make_home postponed)
  log="$home/state/gate-calls.jsonl"

  run_gate_call "$home" record --site review-finding --task stale-badge \
    --verdict deferred --what 'R4 the stale badge' \
    --grounds 'correct and worth doing, but after seventeen fix rounds it goes to follow-up work rather than a eighteenth' \
    --key R4 >/dev/null 2>&1 || rc=$?

  expect_code 0 "$rc" "postponed: a genuine postponement must record"
  assert_equals deferred "$(log_field "$log" 1 verdict)" \
    "postponed: something firstmate means to come back to is deferred"
  pass "deferred is reserved for a call firstmate means to come back to"
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
  [ "$(wc -c < "$drops" | tr -d ' ')" -le 1024 ] \
    || fail "long-task: the drops record crossed the 1024-byte flush boundary"
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
  [ "$(wc -c < "$drops" | tr -d ' ')" -le 1024 ] \
    || fail "oversized-drop: the drops record crossed the 1024-byte flush boundary"
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
test_a_malformed_link_loses_the_link_and_not_the_call
test_a_malformed_key_is_named_beside_a_malformed_link
test_a_bad_task_id_still_costs_the_whole_record
test_every_verdict_in_the_vocabulary_is_accepted
test_a_call_with_no_grounds_is_refused_and_reported
test_a_multi_line_refusal_keeps_its_structure_on_one_line
test_a_declined_review_finding_is_recorded_as_refused
test_a_postponed_call_is_the_only_thing_recorded_as_deferred
test_an_oversized_call_is_shortened_visibly
test_a_bulky_link_costs_the_link_and_never_the_ruling
test_an_oversized_link_is_rejected_before_it_can_shorten_the_grounds
test_an_escape_heavy_link_cannot_cross_the_boundary
test_a_bulky_task_id_keeps_the_drops_record_bounded
test_concurrent_writers_never_tear_a_record
test_a_shortened_record_stays_valid_utf8_in_any_locale
test_an_unwritable_log_is_reported_not_swallowed
test_an_unwritable_state_directory_still_reports
test_a_drops_record_reads_with_the_same_parser_as_the_log
test_an_over_long_identity_field_is_refused_rather_than_cut
test_an_oversized_drop_stays_within_the_byte_bound
test_holding_a_task_for_the_captain_records_an_escalated_call
test_a_hold_still_lands_when_its_gate_call_cannot_be_recorded
