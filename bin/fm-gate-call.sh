#!/usr/bin/env bash
# fm-gate-call.sh - record one firstmate gate call in this home's durable
# gatekeeping log.
#
# bin/fm-gate-calls-lib.sh is the one owner of the record format, the four
# verdicts, the bounds, and what happens when a call cannot be recorded. This
# script is only the command line onto it.
#
# WHEN TO USE IT, AND WHEN NOT TO
#
# Two gate calls record themselves and need no command here, because the code
# that makes them already holds every field:
#
#   - bin/fm-captain-hold.sh hold  records `escalated`.
#   - bin/fm-pr-merge.sh           records `refused` when its live merge-
#                                  readiness check refuses the merge.
#
# Everything else is firstmate's own judgement, made in a turn rather than by a
# script, and that is what this command is for:
#
#   - a finding decided under .agents/skills/ask-user-authority  -> decided
#   - a reviewer finding declined as out of scope under
#     .agents/skills/pr-review                                   -> refused
#   - the same finding genuinely postponed rather than declined   -> deferred
#   - a pull request kept off the captain's desk because its checks
#     are not green, which never reaches a merge attempt          -> refused
#
# Recording is an observer. It runs AFTER the call has been made and acted on,
# it changes nothing about the call, and a failure to record is reported rather
# than allowed to stop anything.
#
# Usage:
#   fm-gate-call.sh record --task <id> --verdict decided|escalated|refused|deferred \
#     --what <one line> --grounds <text> [--link <url>] [--key <routing key>] \
#     [--site <lowercase-dashed-name>]
#
#   --what      what the call was about, in one line.
#   --grounds   why it went that way, in firstmate's own words. Required: a
#               ruling with no reason is not a ruling, and an entry with no
#               grounds would leave the same black box this log exists to open.
#               It is the one field that may span lines.
#   --link      the pull request, issue, or comment a reader should open.
#   --key       the routing key the call is tracked under, where it has one.
#   --site      where the call was made; defaults to `firstmate`.
#
# Exits 0 when the call is in the log, 1 when it was dropped and reported
# (see the library's "a missing record is visible as missing"), 2 on usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-calls-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gate-calls-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

[ "${1:-}" != --help ] && [ "${1:-}" != -h ] || { usage; exit 0; }
[ "${1:-}" = record ] || { usage >&2; exit 2; }
shift

TASK=''
VERDICT=''
WHAT=''
GROUNDS=''
LINK=''
KEY=''
SITE=firstmate

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) shift; TASK=${1:-} ;;
    --verdict) shift; VERDICT=${1:-} ;;
    --what) shift; WHAT=${1:-} ;;
    --grounds) shift; GROUNDS=${1:-} ;;
    --link) shift; LINK=${1:-} ;;
    --key) shift; KEY=${1:-} ;;
    --site) shift; SITE=${1:-} ;;
    *) usage >&2; exit 2 ;;
  esac
  [ "$#" -gt 0 ] || { usage >&2; exit 2; }
  shift
done

[ -n "$TASK" ] && [ -n "$VERDICT" ] && [ -n "$WHAT" ] && [ -n "$GROUNDS" ] \
  || { usage >&2; exit 2; }

if fm_gate_call_record "$STATE" "$SITE" "$TASK" "$VERDICT" "$WHAT" "$GROUNDS" \
  "$LINK" "$KEY"; then
  exit 0
fi
exit 1
