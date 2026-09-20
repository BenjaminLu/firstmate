#!/usr/bin/env bash
# tests/fm-wake-annotation-contradiction.test.sh - a stale wake annotation must
# carry the contradiction it hides.
#
# The incident this pins (2026-09-20): firstmate told the captain a worker had
# outstanding work, reading a forty-minute-old status line while that worker had
# already finished. The line was correctly labelled `not current state`, and the
# label did not help: a label says what a line is NOT and gives nothing to
# compare it against. So the drain now prints the fresh answer beside the stale
# one, from bin/fm-crew-state.sh, the fleet's owner of current-state truth.
#
# Behaviour only, through the real drain. The current-state read is a seam
# (FM_WAKE_CREW_STATE_BIN) so these cases fix what current state SAYS without
# standing up a no-mistakes run or a live pane.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-annotation-contradiction-tests)

# fixture_crew_state <dir> <line>: install a fake current-state reader that
# prints <line> and records one call per invocation.
fixture_crew_state() {  # <case-dir> <state-line>
  local dir=$1 line=$2
  printf '%s' "$line" > "$dir/crew-state.line"
  _fixture_crew_state_bin "$dir"
}

# fixture_crew_state_fails <dir>: install a reader that cannot answer, the way a
# torn-down endpoint or a bounded read that hit its deadline cannot answer.
fixture_crew_state_fails() {  # <case-dir>
  local dir=$1
  rm -f "$dir/crew-state.line"
  _fixture_crew_state_bin "$dir"
}

# fixture_crew_state_hangs <dir>: install a reader that never answers, the way a
# wedged backend or a remote host that has stopped responding never answers. The
# bounds, not the reader, have to end the drain.
fixture_crew_state_hangs() {  # <case-dir>
  local dir=$1
  cat > "$dir/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${FM_FAKE_CREW_STATE_CALLS:-/dev/null}"
while :; do sleep 1; done
SH
  chmod +x "$dir/fm-crew-state.sh"
}

_fixture_crew_state_bin() {  # <case-dir>
  local dir=$1
  cat > "$dir/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${FM_FAKE_CREW_STATE_CALLS:-/dev/null}"
[ -f "$FM_FAKE_CREW_STATE_DIR/crew-state.line" ] || exit 1
cat "$FM_FAKE_CREW_STATE_DIR/crew-state.line"
printf '\n'
SH
  chmod +x "$dir/fm-crew-state.sh"
}

# fixture_task <case-dir> <id> <status-line>...: a task firstmate owns - meta
# plus a status log - with a signal wake queued against its status key.
fixture_task() {  # <case-dir> <id> <status-line>...
  local dir=$1 id=$2 state="$1/state" line
  shift 2
  fm_write_meta "$state/$id.meta" "kind=ship" "window=firstmate:fm-$id" \
    "worktree=$dir/wt-$id"
  : > "$state/$id.status"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$state/$id.status"
  done
  append_wake "$state" signal "$id.status" "signal: $id" \
    || fail "could not queue the signal wake for $id"
}

# drain <case-dir>: run the real drain with the current-state seam bound to this
# case's fake reader, and print everything it emitted.
drain() {  # <case-dir>
  local dir=$1
  FM_STATE_OVERRIDE="$dir/state" \
    FM_WAKE_CREW_STATE_BIN="$dir/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE_DIR="$dir" \
    FM_FAKE_CREW_STATE_CALLS="$dir/calls" \
    "$DRAIN" 2>&1
}

test_annotation_names_current_state_when_it_disagrees() {
  local dir out
  dir=$(make_case disagrees)
  # the durable status log says working; current state says done
  fixture_task "$dir" stale-worker 'working: still implementing the parser'
  fixture_crew_state "$dir" 'state: done · source: run-step · checks passed'

  out=$(drain "$dir") || fail "drain failed on the disagreeing case: $out"
  assert_contains "$out" 'still implementing the parser' \
    "the drain dropped the stale status line it was annotating"
  assert_contains "$out" 'current state disagrees: done' \
    "the stale annotation did not carry the fresh answer that contradicts it"
  pass "a stale annotation names the current state that disagrees with it"
}

test_annotation_is_unchanged_when_current_state_agrees() {
  local dir out
  dir=$(make_case agrees)
  fixture_task "$dir" fresh-worker 'working: still implementing the parser'
  fixture_crew_state "$dir" 'state: working · source: run-step · running'

  out=$(drain "$dir") || fail "drain failed on the agreeing case: $out"
  assert_contains "$out" 'still implementing the parser' \
    "the drain dropped the status line it was annotating"
  assert_not_contains "$out" 'current state disagrees' \
    "an agreeing current state was reported as a contradiction"
  assert_not_contains "$out" 'current state could not be read' \
    "an agreeing current state was reported as unreadable"
  pass "an annotation whose current state agrees gains no clause"
}

test_unreadable_current_state_says_so_rather_than_claiming_agreement() {
  local dir out
  dir=$(make_case unreadable)
  fixture_task "$dir" opaque-worker 'working: still implementing the parser'
  fixture_crew_state_fails "$dir"

  out=$(drain "$dir") || fail "drain failed on the unreadable case: $out"
  assert_contains "$out" 'current state could not be read' \
    "an unreadable current state was passed off as agreement by silence"
  assert_not_contains "$out" 'current state disagrees' \
    "an unreadable current state was reported as a contradiction"
  pass "an unreadable current state says so rather than claiming agreement"
}

test_unknown_current_state_is_reported_as_unreadable_not_as_a_contradiction() {
  local dir out
  dir=$(make_case unknown-verb)
  fixture_task "$dir" quiet-worker 'working: still implementing the parser'
  # bin/fm-crew-state.sh answers `unknown` when it could not determine a state -
  # that is the honest "could not be read", never a state that disagrees.
  fixture_crew_state "$dir" 'state: unknown · source: none · no window recorded'

  out=$(drain "$dir") || fail "drain failed on the unknown case: $out"
  assert_contains "$out" 'current state could not be read' \
    "an undetermined current state was not reported as unreadable"
  assert_not_contains "$out" 'current state disagrees: unknown' \
    "an undetermined current state was reported as a contradiction"
  pass "an undetermined current state reads as unreadable, not as a disagreement"
}

test_a_verb_the_current_state_spells_differently_is_not_a_contradiction() {
  local dir out
  dir=$(make_case vocabulary)
  # The status protocol's verb and the current-state vocabulary are not the same
  # words: a `needs-decision:` worker reads as `parked`. Comparing the raw
  # spellings would invent a contradiction on every parked crew.
  fixture_task "$dir" parked-worker 'needs-decision: pick a JSON library'
  fixture_crew_state "$dir" 'state: parked · source: run-step · parked at fix_review'

  out=$(drain "$dir") || fail "drain failed on the vocabulary case: $out"
  assert_contains "$out" 'pick a JSON library' \
    "the drain dropped the status line it was annotating"
  assert_not_contains "$out" 'current state disagrees' \
    "a needs-decision line and a parked crew were reported as contradicting"
  pass "a verb the current state spells differently is not reported as a contradiction"
}

test_a_status_key_with_no_task_gains_no_clause() {
  local dir out
  dir=$(make_case no-task)
  : > "$dir/state/orphan.status"
  printf 'working: still implementing the parser\n' >> "$dir/state/orphan.status"
  append_wake "$dir/state" signal orphan.status 'signal: orphan' \
    || fail "could not queue the orphan signal wake"
  fixture_crew_state "$dir" 'state: unknown · source: none · no meta'

  out=$(drain "$dir") || fail "drain failed on the orphan case: $out"
  assert_contains "$out" 'still implementing the parser' \
    "the drain dropped the orphan status line"
  assert_not_contains "$out" 'current state disagrees' \
    "a status key with no task firstmate owns claimed a contradiction"
  assert_not_contains "$out" 'current state could not be read' \
    "a status key with no task firstmate owns reported an unreadable crew"
  [ ! -s "$dir/calls" ] \
    || fail "a status key with no task still paid for a current-state read"
  pass "a status key with no task behind it gains no current-state clause"
}

test_current_state_is_read_once_per_status_key_not_once_per_line() {
  local dir out calls
  dir=$(make_case one-read)
  fixture_task "$dir" busy-worker \
    'working: reading the spec' \
    'working: writing the parser' \
    'working: still implementing the parser'
  fixture_crew_state "$dir" 'state: done · source: run-step · checks passed'

  out=$(drain "$dir") || fail "drain failed on the three-line case: $out"
  assert_contains "$out" 'reading the spec' "the first unread line was dropped"
  assert_contains "$out" 'writing the parser' "the second unread line was dropped"
  assert_contains "$out" 'still implementing the parser' "the newest line was dropped"
  assert_contains "$out" 'current state disagrees: done' \
    "three unread lines produced no contradiction clause"

  calls=$(wc -l < "$dir/calls" | tr -d ' ')
  [ "$calls" = 1 ] \
    || fail "a status key carrying three unread lines paid for $calls current-state reads, not 1"
  pass "current state is read once per status key, never once per unread line"
}

test_hung_current_state_reads_stay_inside_the_presentation_lock_budget() {
  local dir out started elapsed hung
  dir=$(make_case hung-reads)
  # Two keys, each with a reader that never answers. Before the whole-phase
  # deadline these cost one bound EACH, serially, and the per-key bound was
  # larger than the presentation lock's own contention budget - so one drain
  # holding the lock starved every concurrent drain of its entire status
  # presentation. The reads run while that lock is held, so their total, not
  # just each one, is what has to stay small.
  fixture_task "$dir" hung-one 'working: still implementing the parser'
  fixture_task "$dir" hung-two 'working: still implementing the parser'
  fixture_crew_state_hangs "$dir"

  started=$(date +%s)
  out=$(drain "$dir") || fail "drain failed with unanswering current-state readers: $out"
  elapsed=$(( $(date +%s) - started ))

  # bin/fm-wake-drain.sh waits FM_STATUS_PRESENTATION_LOCK_TIMEOUT (default 10s)
  # for this lock, so the whole drain must finish well inside it even when every
  # read hangs.
  [ "$elapsed" -lt 10 ] \
    || fail "two unanswering reads held the drain for ${elapsed}s, at or past the presentation lock budget"
  hung=$(grep -c 'current state could not be read' <<EOF
$out
EOF
)
  [ "$hung" = 2 ] \
    || fail "expected both unanswering keys to report an unread current state, got $hung"
  assert_not_contains "$out" 'current state disagrees' \
    "an unanswering reader produced a contradiction verdict"
  pass "hung current-state reads stay inside the presentation lock's own budget"
}

test_the_whole_phase_budget_is_shared_by_every_status_key() {
  local dir out started elapsed
  dir=$(make_case shared-budget)
  fixture_task "$dir" slow-one 'working: still implementing the parser'
  fixture_task "$dir" slow-two 'working: still implementing the parser'
  fixture_task "$dir" slow-three 'working: still implementing the parser'
  fixture_crew_state_hangs "$dir"

  # Three keys, a two-second budget for the phase. A per-key-only bound would
  # spend it three times over.
  started=$(date +%s)
  out=$(export FM_WAKE_CURRENT_STATE_BUDGET=2; drain "$dir") \
    || fail "drain failed under an explicit phase budget: $out"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 6 ] \
    || fail "three unanswering keys spent ${elapsed}s against a 2s whole-phase budget"
  assert_contains "$out" 'current state could not be read' \
    "a spent budget stayed silent instead of saying the state was not read"
  pass "the current-state budget is spent once across the drain, not once per status key"
}

test_annotation_names_current_state_when_it_disagrees
test_annotation_is_unchanged_when_current_state_agrees
test_unreadable_current_state_says_so_rather_than_claiming_agreement
test_unknown_current_state_is_reported_as_unreadable_not_as_a_contradiction
test_a_verb_the_current_state_spells_differently_is_not_a_contradiction
test_a_status_key_with_no_task_gains_no_clause
test_current_state_is_read_once_per_status_key_not_once_per_line
test_hung_current_state_reads_stay_inside_the_presentation_lock_budget
test_the_whole_phase_budget_is_shared_by_every_status_key

echo "all fm-wake annotation-contradiction tests passed"
