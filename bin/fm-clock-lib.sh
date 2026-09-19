#!/usr/bin/env bash
# fm-clock-lib.sh - the single owner of "what time is it" for bin/.
#
# Sourced, never executed.
#
#   fm_now [output-variable]
#       Whole epoch seconds. With an output variable the value is assigned in
#       the caller's frame, which costs no subprocess at all on bash 4.2 and
#       newer; `now=$(fm_now)` still forks a subshell, so prefer `fm_now now`
#       inside a poll loop.
#
#   fm_path_mtime <path>
#       A file's modification time in whole epoch seconds, or nothing (status 1)
#       when the path cannot be read.
#
#   fm_path_age <path>
#       Seconds since that mtime, or 999999 when the path cannot be read, so a
#       caller comparing against a staleness threshold treats a missing record
#       as maximally stale rather than as fresh.
#
#   fm_clock_source
#       Which of the three implementations below this shell resolved. Prints
#       "epochseconds", "printf", or "date". Diagnostic and test use only; no
#       caller should branch on it.
#
# WHY THERE IS NO WAY TO INJECT A TIME HERE
#
# Supervision, the wake queue, and every guard that decides whether something is
# stale, wedged, or expired read their time through this file. A process that
# could be persuaded to believe an attacker-chosen or merely wrong time would
# declare live work dead, expire a captain's hold early, or pass a wedged
# watcher off as healthy. That is a worse outcome than a slow test suite, so
# this library has no injection point: no environment variable, no state file,
# no config key, and no argument can replace the value fm_now returns. Every
# path in it reads the operating system clock.
#
# That matters because firstmate's own runtime hands the watcher an environment
# it does not fully author - `config/x-mode.env` is sourced into the arming
# shell - and because `$STATE` is a directory the repository already treats as
# attacker-reachable (`bin/fm-check-register.sh` exists for exactly that
# reason). An env-var or state-file clock would be reachable through both.
#
# A test substitutes time by redefining fm_now in its own shell AFTER sourcing
# this file. Three properties make that confined to the test:
#
#   1. This file defines fm_now unconditionally. The definition is not guarded
#      by `command -v`, so a definition inherited through the environment -
#      bash exports functions to child shells, and `export -f fm_now` is the
#      obvious attack - is overwritten the moment the child sources this file.
#   2. Every bin/ script that reads time sources this file before its first
#      read, so the overwrite in (1) always happens first.
#   3. A bin/ script never sources a file under tests/. An override therefore
#      lives only in the memory of the shell that wrote it and dies with it.
#
# tests/fm-clock-lib.test.sh proves the negative end to end: a production-shaped
# invocation under a hostile environment, an exported fm_now, a poisoned
# `config/x-mode.env`, and a planted state file still reports the real time.

# Resolved once at source time, not per call: fm_path_mtime runs inside 0.2s
# confirm and 0.5s attach polls, and forking uname per call is a measurable cost
# on the platform (Git Bash/MSYS) that already pays the highest fork price.
# fm-wake-lib.sh reads this same variable rather than probing a second time.
_FM_UNAME=$(uname 2>/dev/null || echo unknown)

# Pick the cheapest correct clock this shell offers, once.
#
#   epochseconds  bash 5.0+ dynamic variable. No fork, no subshell.
#   printf        bash 4.2+ `%(%s)T`. No fork; needs printf -v to stay
#                 subshell-free.
#   date          the stock-macOS bash 3.2 floor, which has neither. One fork
#                 per read, which is what this repo has always paid.
#
# The probe runs in this shell, so the capability it reports is this shell's.
# A candidate is adopted only after its reading is proved to agree with date(1)
# to within a second in this same shell: a fast source that is present but
# wrong - a build whose `%(%s)T` renders something else, a shell where
# EPOCHSECONDS has been shadowed by an ordinary variable of that name - then
# cannot be adopted, and the shell falls back to the clock this repo has always
# used rather than to a plausible-looking wrong one. That costs one date(1) fork
# per process, which a script reading time once pays today anyway, and which a
# poll loop amortises over every later read.
_FM_CLOCK_SOURCE='date'
_fm_clock_select() {
  local candidate=$1 reading reference delta
  case "$candidate" in
    epochseconds)
      [ -n "${EPOCHSECONDS+x}" ] || return 1
      reading=$EPOCHSECONDS
      ;;
    printf)
      printf -v reading '%(%s)T' -1 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
  case "$reading" in ''|*[!0-9]*) return 1 ;; esac
  reference=$(date +%s 2>/dev/null) || return 1
  case "$reference" in ''|*[!0-9]*) return 1 ;; esac
  delta=$(( reading - reference ))
  [ "$delta" -ge 0 ] || delta=$(( -delta ))
  [ "$delta" -le 1 ] || return 1
  _FM_CLOCK_SOURCE=$candidate
}
_fm_clock_select epochseconds || _fm_clock_select printf || :
unset -f _fm_clock_select

fm_clock_source() {
  printf '%s\n' "$_FM_CLOCK_SOURCE"
}

fm_now() {  # [output-variable]
  local fm_clock_value
  case "$_FM_CLOCK_SOURCE" in
    epochseconds) fm_clock_value=$EPOCHSECONDS ;;
    printf) printf -v fm_clock_value '%(%s)T' -1 ;;
    *) fm_clock_value=$(date +%s) ;;
  esac
  if [ "$#" -gt 0 ]; then
    printf -v "$1" '%s' "$fm_clock_value"
  else
    printf '%s\n' "$fm_clock_value"
  fi
}

fm_path_mtime() {
  if [ "$_FM_UNAME" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m now
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  fm_now now
  echo $(( now - m ))
}
