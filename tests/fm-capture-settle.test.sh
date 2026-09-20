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
  # A frame may carry embedded newlines, so a multi-row viewport - a transcript
  # above and the editor chrome below it - can be scripted as one entry.
  printf '%b\n' "${FRAMES[$index]}" >"$file"
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
    --present 'RELOAD DONE' --absent 'RELOAD WORKING' 2>&1) && status=0 || status=$?
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
    --present 'RELOAD DONE' --absent 'RELOAD WORKING' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "the wait must settle once the transient half clears: $out"
  assert_grep 'RELOAD DONE and the composer is back' "$TMP_ROOT/overlap" \
    "the settled capture must be the frame with the transient gone"
  pass "an end state still overlapping the transient frame is not accepted as settled"
}

test_a_transition_that_never_happens_fails_with_the_viewport_it_saw() {
  local out status
  reset_capture 'composer ready, nothing happened at all'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/never" 4 \
    --present 'RELOAD DONE' --absent 'RELOAD WORKING' 2>&1) && status=0 || status=$?
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
    --present 'RELOAD DONE' --absent 'RELOAD WORKING' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a viewport stuck mid-transition must fail: $out"
  assert_contains "$out" "never cleared 'RELOAD WORKING'" \
    "a stuck transient must be distinguished from an end state that never arrived"
  pass "a viewport stuck mid-transition says so instead of blaming the end state"
}

test_a_self_reported_failure_aborts_at_once() {
  local out status
  reset_capture 'composer ready' 'Reload failed: extension threw'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/abort" 400 \
    --present 'RELOAD DONE' --absent 'RELOAD WORKING' --abort 'Reload failed:' 2>&1) && status=0 || status=$?
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
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/slow" 6 --present 'RELOAD DONE' 2>&1) \
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

test_either_half_of_the_end_state_stands_alone() {
  local out status
  reset_capture 'RELOAD DONE'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/present-only" 40 \
    --present 'RELOAD DONE' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "a wait with only a --present text must settle: $out"

  # The wait-for-absence shape: the settle is something leaving the screen, with
  # nothing new arriving to mark it. Those are the loops that used to fall
  # through in silence when they ran out.
  reset_capture 'THINKING is expanded' 'THINKING is expanded' 'collapsed'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/absent-only" 40 \
    --absent 'THINKING' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "a wait with only an --absent text must settle: $out"

  reset_capture 'THINKING never collapses'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/absent-stuck" 4 \
    --absent 'THINKING' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a wait-for-absence that never clears must fail rather than fall through: $out"
  assert_contains "$out" "never cleared 'THINKING'" "the failure must name the text that stayed"
  pass "a --present text and an --absent text each stand alone, and an absence that never clears fails loudly"
}

test_every_text_the_next_assertion_needs_can_be_required() {
  local out status
  # R1's shape: the capture the wait leaves behind is what the assertions after
  # it read, so a wait that requires only the transition marker leaves those
  # assertions depending on the subject's internal ordering. Requiring all of
  # them is what closes that.
  reset_capture \
    'RELOAD DONE' \
    'RELOAD DONE and the skill row is back' \
    'RELOAD DONE and the skill row is back and FINAL RESPONSE'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/multi" 40 \
    --present 'RELOAD DONE' --present 'skill row' --present 'FINAL RESPONSE' 2>&1) \
    && status=0 || status=$?
  expect_code 0 "$status" "a wait naming several required texts must hold out for all of them: $out"
  assert_grep 'FINAL RESPONSE' "$TMP_ROOT/multi" \
    "the settled capture must be the frame carrying every required text"

  reset_capture 'RELOAD DONE, but the final response never came back'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/multi-missing" 4 \
    --present 'RELOAD DONE' --present 'FINAL RESPONSE' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "one required text missing must fail the wait: $out"
  assert_contains "$out" "never showed 'FINAL RESPONSE'" "the failure must name the text that was missing"
  assert_not_contains "$out" "never showed 'RELOAD DONE'" "the failure must not blame a text that was present"
  pass "every text the following assertion needs can be required of the settled capture, and a missing one is named"
}

test_a_scoped_absence_reads_its_scope_and_only_its_scope() {
  local out status
  # The condition that sent this branch back: an absence that only ever meant
  # the terminal's own chrome, checked against the transcript above it too.
  # Broadening an absence makes FEWER frames settle, and with exhaustion now
  # fatal that is a way to red a healthy run - so the scope has to survive the
  # move into the helper.
  #
  # Both halves are needed, and only one of them is about the widening. The
  # frames carry NO trailing newline, so --tail 1 lands on the chrome row
  # rather than on the empty line after it: with one, the scope would be blank
  # and the case would pass without the in-scope direction ever being
  # exercised - which is the half the real call site depends on.
  reset_capture 'a transcript row about Working hours\nchrome: Working...' \
    'a transcript row about Working hours\nchrome: Working...' \
    'a transcript row about Working hours\nchrome: idle'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/scoped" 6 \
    --tail 1 --absent 'Working' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "a --tail scoped absence must settle once its own scope clears: $out"
  [ "$(capture_calls)" -ge 3 ] \
    || fail "the wait settled after $(capture_calls) captures, so a match inside the scope did not hold it out"

  # And the in-scope match on its own must never settle, so the direction above
  # is not being reached by the scope simply reading nothing.
  reset_capture 'a quiet transcript row\nchrome: Working...'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/scoped-stuck" 3 \
    --tail 1 --absent 'Working' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a match inside the scope must hold the wait out: $out"

  # Unscoped, the settling frame never settles - which is the regression --tail
  # is here to prevent, asserted rather than assumed.
  reset_capture 'a transcript row about Working hours\nchrome: idle'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/unscoped" 3 \
    --absent 'Working' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "without --tail the match above the scope must hold the wait out: $out"
  pass "a scoped absence reads its own scope, holds out on a match inside it, and ignores one above it"
}

test_a_bounded_absence_ignores_a_longer_word_containing_the_token() {
  local out status
  reset_capture 'Workingtitle is not the indicator\n'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/bounded" 6 \
    --absent-re 'Working([[:space:]]|$)' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "a bounded absence must ignore a longer word containing the token: $out"

  reset_capture 'Working is the indicator\n'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/bounded-hit" 3 \
    --absent-re 'Working([[:space:]]|$)' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "the bounded absence must still match the token itself: $out"
  assert_contains "$out" "never cleared 'Working([[:space:]]|\$)'" \
    "the failure must name the pattern that stayed"

  # A fixed-string absence must stay fixed-string: a caller passing regex
  # metacharacters to --absent is naming a literal, not a pattern.
  # The frame says "Working now", which the pattern 'Working.*' matches as a
  # regex and does not match as a literal. Settling proves --absent stayed
  # fixed-string; a frame matching neither way would prove nothing.
  reset_capture 'Working now, and nowhere the literal token\n'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/literal" 6 \
    --absent 'Working.*' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "--absent must match literally, not as a pattern: $out"
  pass "an --absent-re absence is bounded as written, and --absent stays a literal"
}

test_an_abort_is_read_from_the_whole_capture_even_under_a_scope() {
  local out status
  # A --tail keeps a settle condition off the transcript above the chrome. An
  # abort text is the opposite kind of thing - the program saying it failed -
  # and it lands where that program puts it, which here is the transcript.
  # Scoping it out would buy nothing and cost the whole attempt bound waiting
  # on work that had already been refused.
  reset_capture 'Reload failed: extension threw\nchrome: Working...'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/abort-scoped" 400 \
    --tail 1 --absent 'Working' --abort 'Reload failed:' 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an abort above the scope must still abort the wait: $out"
  assert_contains "$out" "reported 'Reload failed:'" "the abort must name the failure it read"
  [ "$(capture_calls)" -lt 20 ] \
    || fail "an abort above the scope was polled $(capture_calls) times before it was read"
  pass "an abort text is read from the whole capture even when the settle conditions are scoped"
}

test_an_unusable_tail_count_is_refused_rather_than_matching_nothing() {
  local out status value
  # tail -n throws its own error away, so an unusable count leaves an empty
  # slice and every --absent is satisfied by a viewport nobody read. That is
  # the one way this helper can return success without looking, so each shape
  # has to be refused by name before it reaches tail.
  for value in abc -3 '' 3.5 '2 4'; do
    out=$( (fm_wait_capture_settled scripted_capture "$TMP_ROOT/badtail" 4 \
      --tail "$value" --absent 'nothing') 2>&1 ) && status=0 || status=$?
    expect_code 1 "$status" "--tail '$value' must be refused, not passed to tail: $out"
    assert_contains "$out" 'whole number of lines' "the refusal must say what --tail accepts (value '$value')"
  done

  # Zero is the one unusable value that is a legal argument, so it needs its
  # own refusal: tail -n 0 succeeds and prints nothing at all.
  out=$( (fm_wait_capture_settled scripted_capture "$TMP_ROOT/zerotail" 4 \
    --tail 0 --absent 'nothing') 2>&1 ) && status=0 || status=$?
  expect_code 1 "$status" "--tail 0 must be refused: $out"
  assert_contains "$out" 'at least 1 line' "the refusal must say why zero is not a scope"

  # A usable count still works, so the guard refuses the bad shapes only.
  reset_capture 'first row\nsecond row'
  out=$(fm_wait_capture_settled scripted_capture "$TMP_ROOT/goodtail" 4 \
    --tail 1 --absent 'first row' 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "a usable --tail count must still settle: $out"
  pass "an unusable --tail count is refused by name instead of quietly matching against nothing"
}

test_a_wait_that_requires_nothing_is_refused() {
  local out status
  reset_capture 'anything at all'
  out=$( (fm_wait_capture_settled scripted_capture "$TMP_ROOT/empty" 4) 2>&1 ) && status=0 || status=$?
  expect_code 1 "$status" "a wait with no condition must be refused, not pass on the first capture: $out"
  assert_contains "$out" 'needs at least one --present, --absent or --absent-re' \
    "the refusal must say what the call is missing"

  out=$( (fm_wait_capture_settled scripted_capture "$TMP_ROOT/typo" 4 --pressent 'x') 2>&1 ) \
    && status=0 || status=$?
  expect_code 1 "$status" "a misspelled flag must be refused rather than silently ignored: $out"
  assert_contains "$out" "unknown argument '--pressent'" "the refusal must name the argument it did not understand"

  # The third malformation: a known flag with its value left off. Reading the
  # missing value under set -u kills the shell mid-function, which prints no
  # named failure at all - the one shape that escapes while its two siblings
  # above are refused.
  out=$( (fm_wait_capture_settled scripted_capture "$TMP_ROOT/novalue" 4 --present) 2>&1 ) \
    && status=0 || status=$?
  expect_code 1 "$status" "a flag with no value must be refused: $out"
  assert_contains "$out" '--present needs a value' "the refusal must name the flag that was left bare"
  assert_not_contains "$out" 'unbound variable' \
    "a flag with no value must be refused by name, not killed by the interpreter"

  out=$( (fm_wait_capture_settled scripted_capture "$TMP_ROOT/novalue-tail" 4 \
    --absent 'x' --tail) 2>&1 ) && status=0 || status=$?
  expect_code 1 "$status" "a trailing flag with no value must be refused: $out"
  assert_contains "$out" '--tail needs a value' "the refusal must name the flag that was left bare"
  pass "a wait with no condition, an unknown flag, or a flag left without its value is refused by name"
}

test_an_unseen_intermediate_frame_still_settles
test_the_end_state_is_not_accepted_while_the_transient_is_still_up
test_a_transition_that_never_happens_fails_with_the_viewport_it_saw
test_a_stuck_transient_is_reported_as_stuck_not_as_missing
test_a_self_reported_failure_aborts_at_once
test_the_bound_is_an_attempt_count_that_stretches_under_load
test_either_half_of_the_end_state_stands_alone
test_every_text_the_next_assertion_needs_can_be_required
test_a_scoped_absence_reads_its_scope_and_only_its_scope
test_a_bounded_absence_ignores_a_longer_word_containing_the_token
test_an_abort_is_read_from_the_whole_capture_even_under_a_scope
test_an_unusable_tail_count_is_refused_rather_than_matching_nothing
test_a_wait_that_requires_nothing_is_refused
echo "# all fm-capture-settle tests passed"
