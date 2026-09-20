#!/usr/bin/env bash
# Contract checks for fm_wait_capture_settled, the shared wait a terminal
# end-to-end test uses to decide that a viewport transition has finished.
#
# This is the seam the Calm /reload flake lived in. That test waited to SEE the
# "Reloading..." box Pi shows while it works, and captures are discrete: the
# box could come and go between two of them, and the wait then failed a reload
# that had completed perfectly - reddening pull requests that touched nothing
# near it. The cases below drive the helper against scripted viewports, so the
# behavior is provable on any clone, with no terminal multiplexer and no agent
# installed, instead of only being observable when CI happens to lose the race.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capture-settle)
trap fm_test_cleanup EXIT

# A scripted capture source. FRAMES holds one viewport per line, in the order
# the program under test would paint them; each call writes the next one and
# then repeats the last forever, exactly like a terminal that has stopped
# changing. CAPTURE_DELAY simulates a loaded runner, where the capture itself
# is what costs the time.
#
# The call counter lives in a file rather than a variable. Every case runs the
# wait inside $(...) to capture its diagnostics, and that subshell's variables
# never reach this shell - a counter kept in one would read 0 here no matter
# what happened, which makes an assertion on it always true and therefore
# worthless.
FRAMES=()
CAPTURE_DELAY=0
CAPTURE_COUNTER="$TMP_ROOT/capture-calls"

scripted_capture() {
  local file=$1 index
  index=$(cat "$CAPTURE_COUNTER")
  printf '%s\n' "$((index + 1))" >"$CAPTURE_COUNTER"
  [ "$index" -lt "${#FRAMES[@]}" ] || index=$(( ${#FRAMES[@]} - 1 ))
  [ "$CAPTURE_DELAY" = "0" ] || sleep "$CAPTURE_DELAY"
  printf '%s\n' "${FRAMES[$index]}" >"$file"
}

capture_calls() {
  cat "$CAPTURE_COUNTER"
}

reset_capture() {
  FRAMES=("$@")
  CAPTURE_DELAY=0
  printf '0\n' >"$CAPTURE_COUNTER"
}

test_an_unseen_intermediate_frame_still_settles() {
  local out status
  # The exact shape of the flake: the program painted "working", but no capture
  # ever sampled that frame. The transition still finished, so the wait must
  # still succeed.
  reset_capture 'composer ready' 'RELOAD DONE and the composer is back'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/unseen" 40 \
    'RELOAD DONE' 'RELOAD WORKING' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "a transition whose intermediate frame was never captured must still settle: $out"
  pass "an intermediate frame no capture ever sampled does not fail a completed transition"
}

test_the_end_state_is_not_accepted_while_the_transient_is_still_up() {
  local out status
  # Both halves on screen at once is mid-transition, not the end state: the
  # wait must keep going until the transient half clears.
  reset_capture \
    'composer ready' \
    'RELOAD WORKING ... RELOAD DONE' \
    'RELOAD WORKING ... RELOAD DONE' \
    'RELOAD DONE and the composer is back'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/overlap" 40 \
    'RELOAD DONE' 'RELOAD WORKING' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "the wait must settle once the transient half clears: $out"
  assert_grep 'RELOAD DONE and the composer is back' "$TMP_ROOT/overlap" \
    "the settled capture must be the frame with the transient gone"
  pass "an end state still overlapping the transient frame is not accepted as settled"
}

test_a_transition_that_never_happens_fails_with_the_viewport_it_saw() {
  local out status
  reset_capture 'composer ready, nothing happened at all'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/never" 4 \
    'RELOAD DONE' 'RELOAD WORKING' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a transition that never happened must fail: $out"
  assert_contains "$out" "never showed 'RELOAD DONE'" "the failure must name what it waited for"
  assert_contains "$out" 'composer ready, nothing happened at all' \
    "the failure must carry the viewport it actually saw, not just an exhausted bound"
  pass "a transition that never happens fails loudly and reports the viewport it saw"
}

test_a_stuck_transient_is_reported_as_stuck_not_as_missing() {
  local out status
  reset_capture 'RELOAD WORKING ... RELOAD DONE'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/stuck" 4 \
    'RELOAD DONE' 'RELOAD WORKING' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a viewport stuck mid-transition must fail: $out"
  assert_contains "$out" "never cleared 'RELOAD WORKING'" \
    "a stuck transient must be distinguished from an end state that never arrived"
  pass "a viewport stuck mid-transition says so instead of blaming the end state"
}

test_a_self_reported_failure_aborts_at_once() {
  local out status
  reset_capture 'composer ready' 'Reload failed: extension threw'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/abort" 400 \
    'RELOAD DONE' 'RELOAD WORKING' 'Reload failed:' 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a self-reported failure must abort, not spend the whole bound: $out"
  assert_contains "$out" "reported 'Reload failed:'" "the abort must name the failure it read"
  [ "$(capture_calls)" -lt 20 ] \
    || fail "a self-reported failure was polled $(capture_calls) times instead of aborting at once"
  pass "a failure the program reports about itself aborts the wait at once, well inside the bound"
}

test_the_bound_is_an_attempt_count_that_stretches_under_load() {
  local out status started elapsed
  # CONTRIBUTING.md: bound a test's own waiting with an iteration count, which
  # buys more real time on a loaded machine, not with a clock, which expires on
  # work that is still legitimately in progress. Each capture here costs far
  # more than the poll interval - what a loaded runner does - so a clock-bounded
  # wait would give up after its budget while this one still spends every
  # attempt it was given.
  reset_capture 'composer ready, nothing happened at all'
  CAPTURE_DELAY=0.3
  started=$SECONDS
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/slow" 6 'RELOAD DONE' 2>&1) \
    && status=0 || status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "the slow-capture wait must fail only once its attempts are spent: $out"
  assert_contains "$out" 'across 6 captures' "the failure must report the bound it spent"
  # The discriminator: a clock-bounded wait gives up after its budget, which
  # these deliberately slow captures burn in three or four samples. Counting
  # the captures actually taken is what catches that substitution; elapsed
  # time alone cannot, because both bounds take about as long.
  [ "$(capture_calls)" -eq 6 ] \
    || fail "the wait took $(capture_calls) captures of the 6 it was given, so the bound is elapsed time, not attempts"
  [ "$elapsed" -ge 1 ] \
    || fail "the wait returned in ${elapsed}s, so it stopped short of the attempts it was given"
  pass "the bound is an attempt count, so a loaded runner gets more real time instead of an early failure"
}

test_an_absent_text_is_optional() {
  local out status
  reset_capture 'RELOAD DONE'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/present-only" 40 'RELOAD DONE' 2>&1) \
    && status=0 || status=$?
  expect_code 0 "$status" "a wait with no must-be-gone text and no abort texts must settle: $out"
  pass "the must-be-gone text and the abort texts are both optional"
}

test_an_unseen_intermediate_frame_still_settles
test_the_end_state_is_not_accepted_while_the_transient_is_still_up
test_a_transition_that_never_happens_fails_with_the_viewport_it_saw
test_a_stuck_transient_is_reported_as_stuck_not_as_missing
test_a_self_reported_failure_aborts_at_once
test_the_bound_is_an_attempt_count_that_stretches_under_load
test_an_absent_text_is_optional
echo "# all fm-capture-settle tests passed"
