#!/usr/bin/env bash
# tests/fm-clock-lib.test.sh - the clock seam and, above all, the proof that its
# test-only substitution cannot reach a real run.
#
# bin/fm-clock-lib.sh is the single owner of "what time is it" for bin/. Every
# staleness, wedge, and expiry decision in supervision reads it, so a production
# process that could be persuaded to believe an attacker-chosen or merely wrong
# time is a worse outcome than a slow suite. The library therefore ships no
# injection point at all, and the cases below drive production-shaped
# invocations - a real bin/ script writing a real durable record - under every
# channel that could plausibly carry a forged time into it.
#
# The one channel deliberately NOT covered is PATH: a shim named `date` ahead of
# the watcher is believed on the bash 3.2 fallback path, exactly as a shim named
# `git`, `gh`, or `tmux` is. That is not a property of this library, it is what
# controlling a process's PATH already means, and the suite's own fakebin
# convention depends on it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOCK="$ROOT/bin/fm-clock-lib.sh"
INBOX="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-clock-tests)

# Every name a forged clock would plausibly arrive under, including the
# library's own internals and the two dynamic variables a modern bash exposes.
hostile_clock_env() {
  printf '%s\n' \
    FM_NOW=4102444800 \
    FM_TEST_NOW=4102444800 \
    FM_FAKE_CLOCK=4102444800 \
    FM_CLOCK=4102444800 \
    FM_CLOCK_NOW=4102444800 \
    FM_CLOCK_OFFSET=999999999 \
    FM_CLOCK_SOURCE=fake \
    _FM_CLOCK_SOURCE=fake \
    FM_CLOCK_LIB=/dev/null \
    SOURCE_DATE_EPOCH=4102444800 \
    EPOCHSECONDS=4102444800 \
    EPOCHREALTIME=4102444800.000000
}

# A home shaped like a real one: state/ and config/ present, nothing else.
make_home() {  # <name>
  local dir
  dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' "$dir"
}

# Run a production-shaped invocation that commits the clock to a durable record,
# and print the epoch it recorded. bin/fm-inbox.sh note is the smallest real
# caller that does this: it appends one `check` row to the durable wake queue,
# whose first field is fm_now's value.
recorded_epoch() {  # <home> [env-assignments...]
  local home=$1
  shift
  rm -f "$home/state/.wake-queue"
  env "$@" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$INBOX" note "clock seam probe" >/dev/null 2>&1 \
    || fail "production-shaped invocation failed"
  awk -F '\t' 'NR == 1 { print $1 }' "$home/state/.wake-queue"
}

# Fail unless <epoch> is the real clock. The window is deliberately wide enough
# to absorb a loaded machine and narrow enough that no forged value survives it.
assert_real_epoch() {  # <epoch> <what>
  local epoch=$1 what=$2 reference delta
  reference=$(date +%s)
  case "$epoch" in
    ''|*[!0-9]*) fail "$what: recorded no usable epoch, got '$epoch'" ;;
  esac
  delta=$(( epoch - reference ))
  [ "$delta" -ge 0 ] || delta=$(( -delta ))
  [ "$delta" -le 60 ] \
    || fail "$what: recorded $epoch, which is ${delta}s from the real clock $reference"
}


test_the_clock_reports_the_operating_system_time() {
  local printed captured source reference delta
  reference=$(date +%s)
  printed=$(bash -c '. "$1"; fm_now' _ "$CLOCK") || fail "fm_now failed"
  captured=$(bash -c '. "$1"; fm_now v; printf "%s" "$v"' _ "$CLOCK") \
    || fail "fm_now with an output variable failed"
  source=$(bash -c '. "$1"; fm_clock_source' _ "$CLOCK") || fail "fm_clock_source failed"
  case "$source" in
    epochseconds|printf|date) ;;
    *) fail "fm_clock_source reported an unknown implementation: $source" ;;
  esac
  assert_real_epoch "$printed" "fm_now printing to stdout"
  assert_real_epoch "$captured" "fm_now assigning an output variable"
  delta=$(( printed - captured ))
  [ "$delta" -ge 0 ] || delta=$(( -delta ))
  [ "$delta" -le 5 ] || fail "fm_now's two call forms disagreed by ${delta}s"
  pass "fm_now reports the operating system clock in both call forms"
}

test_path_age_reads_backdated_mtimes_and_fails_maximally_stale() {
  local dir file age
  dir="$TMP_ROOT/path-age"
  mkdir -p "$dir"
  file="$dir/record"
  : > "$file"
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$file"
  age=$(bash -c '. "$1"; fm_path_age "$2"' _ "$CLOCK" "$file")
  [ "$age" -ge 3590 ] && [ "$age" -le 3610 ] \
    || fail "fm_path_age read a backdated record as ${age}s old, expected about 3600"
  age=$(bash -c '. "$1"; fm_path_age "$2"' _ "$CLOCK" "$dir/absent")
  assert_equals 999999 "$age" "a missing record must read as maximally stale"
  pass "fm_path_age reads a backdated record without waiting and treats a missing one as maximally stale"
}

test_a_hostile_environment_cannot_move_a_production_clock() {
  local home epoch
  home=$(make_home hostile-env)
  # shellcheck disable=SC2046
  epoch=$(recorded_epoch "$home" $(hostile_clock_env))
  assert_real_epoch "$epoch" "a production record written under a hostile environment"
  pass "no environment variable can move the clock a production invocation records"
}

test_an_exported_clock_function_is_overwritten_when_the_library_loads() {
  local home epoch overwritten
  home=$(make_home exported-function)
  # The structural claim: bash exports functions to child shells, so `export -f
  # fm_now` is the way a forged clock would actually travel into the watcher.
  # bin/fm-clock-lib.sh defines fm_now unconditionally, so sourcing it
  # overwrites whatever arrived, and it is sourced before the first read.
  # Negative control first, so this case can never pass vacuously: prove the
  # channel is live on this bash before asserting the library closes it. If a
  # future bash stops exporting functions, this assertion fails and says so
  # rather than letting the real claim below go quietly untested.
  local inherited
  inherited=$(
    # shellcheck disable=SC2329  # invoked in a child shell through export -f
    fm_now() { printf '4102444800\n'; }
    export -f fm_now
    bash -c 'fm_now' 2>/dev/null
  )
  assert_equals 4102444800 "$inherited" \
    "an exported fm_now must actually reach a child shell, or this case proves nothing"

  overwritten=$(
    # shellcheck disable=SC2329  # invoked in a child shell through export -f
    fm_now() { printf '4102444800\n'; }
    export -f fm_now
    bash -c '. "$1"; fm_now' _ "$CLOCK"
  )
  assert_real_epoch "$overwritten" "a shell that inherited an exported fm_now and then sourced the library"

  epoch=$(
    # shellcheck disable=SC2329  # invoked in a child shell through export -f
    fm_now() { printf '4102444800\n'; }
    export -f fm_now
    recorded_epoch "$home"
  )
  assert_real_epoch "$epoch" "a production record written with an exported fm_now in the environment"
  pass "an exported fm_now is overwritten by the library and never reaches a production record"
}

test_a_planted_state_or_config_file_cannot_move_a_production_clock() {
  local home epoch
  home=$(make_home planted-files)
  # $STATE is a directory this repository already treats as attacker-reachable
  # (bin/fm-check-register.sh exists for that reason), and config/x-mode.env is
  # sourced into the arming shell, so both are the realistic carriers.
  printf '4102444800\n' > "$home/state/.fm-fake-clock"
  printf '4102444800\n' > "$home/state/.clock"
  printf '4102444800\n' > "$home/config/clock"
  printf '4102444800\n' > "$home/config/fake-clock"
  hostile_clock_env | sed 's/^/export /' > "$home/config/x-mode.env"
  cat >> "$home/config/x-mode.env" <<'POISON'
fm_now() { echo 4102444800; }
export -f fm_now
POISON
  # Negative control: the poisoned file really does forge a clock in the shell
  # that sources it, so the assertion below is about the library, not about a
  # file that happened to do nothing.
  local poisoned
  # shellcheck disable=SC1090,SC1091
  poisoned=$(. "$home/config/x-mode.env" >/dev/null 2>&1; fm_now)
  assert_equals 4102444800 "$poisoned" \
    "the poisoned config/x-mode.env must actually forge a clock, or this case proves nothing"
  # shellcheck disable=SC1090,SC1091
  epoch=$(. "$home/config/x-mode.env" >/dev/null 2>&1; recorded_epoch "$home")
  assert_real_epoch "$epoch" "a production record written from a poisoned config/x-mode.env"
  pass "neither a planted state file nor a poisoned config/x-mode.env can move a production clock"
}

test_a_fast_clock_that_disagrees_with_the_system_is_refused() {
  local native source epoch
  # shellcheck disable=SC2016  # the probe must be evaluated by the child bash, not here
  native=$(env -u EPOCHSECONDS bash -c 'printf "%s" "${EPOCHSECONDS+native}"')
  source=$(EPOCHSECONDS=4102444800 bash -c '. "$1"; fm_clock_source' _ "$CLOCK")
  epoch=$(EPOCHSECONDS=4102444800 bash -c '. "$1"; fm_now' _ "$CLOCK")
  assert_real_epoch "$epoch" "a shell whose EPOCHSECONDS was forged in the environment"
  if [ "$native" = native ]; then
    # This bash owns EPOCHSECONDS as a dynamic variable, so the forged export
    # never becomes the value the library reads.
    assert_equals epochseconds "$source" "a bash with a native EPOCHSECONDS should adopt it"
  else
    # This bash has no EPOCHSECONDS of its own, so the forged export is a plain
    # variable and IS what the candidate check reads. It must be rejected for
    # disagreeing with date(1), leaving the fallback clock in place.
    assert_equals date "$source" "a forged EPOCHSECONDS must be refused, not adopted"
  fi
  pass "a fast clock candidate is adopted only after it agrees with the system clock"
}

test_the_clock_reports_the_operating_system_time
test_path_age_reads_backdated_mtimes_and_fails_maximally_stale
test_a_hostile_environment_cannot_move_a_production_clock
test_an_exported_clock_function_is_overwritten_when_the_library_loads
test_a_planted_state_or_config_file_cannot_move_a_production_clock
test_a_fast_clock_that_disagrees_with_the_system_is_refused
