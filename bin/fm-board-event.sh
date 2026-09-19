#!/usr/bin/env bash
# fm-board-event.sh - the one door the fleet knocks on when the board changed.
#
# Usage: fm-board-event.sh event <kind> <task-id> [--flag <value> ...]
#
# WHY THIS EXISTS RATHER THAN A CALL PER TRANSPORT. The board can have more
# than one surface - a store on GitHub anyone can read, a live channel for the
# machine the captain is sitting at - and each one needs telling when a spawn,
# a teardown, a captain hold, a pull request registration, or a board build
# changes what the board should say. Wiring each transport into those five
# scripts separately means five scripts edited again for every surface, five
# places for one to be forgotten, and two transports racing to edit the same
# lines. So the fleet's event scripts call THIS, once, and a transport adds
# itself here.
#
# Every argument is passed through verbatim, so a transport that wants the
# detail can read it and one that does not can ignore it. The GitHub store
# republishes the whole board rather than applying a delta, because a file
# served from a CDN is replaced, not patched; it therefore needs only to be
# told that something happened.
#
# NOTHING HERE MAY FAIL ITS CALLER. Publishing a board is never worth breaking
# a spawn, a teardown, or a merge over. Every sink is invoked best-effort and
# this script always exits 0. A sink that cannot publish says so in its own
# records and through the board's own freshness line, which is the honest
# place for it - a board that is behind says it is behind.
#
# THE SINKS, in the order they are told:
#   bin/fm-board-live.sh      the live local channel, when that transport is
#                             installed in this tree (it is absent otherwise,
#                             and its absence is not an error)
#   bin/fm-board-github.sh    the GitHub store
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1-}" in
  event) shift ;;
  -h|--help|help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *) printf 'usage: fm-board-event.sh event <kind> <task-id> [--flag <value> ...]\n' >&2; exit 2 ;;
esac

KIND=${1-}
ID=${2-}
[ -n "$KIND" ] || exit 0
shift 2 2>/dev/null || true

if [ -x "$SCRIPT_DIR/fm-board-live.sh" ]; then
  "$SCRIPT_DIR/fm-board-live.sh" event "$KIND" "$ID" "$@" >/dev/null 2>&1 || true
fi
if [ -x "$SCRIPT_DIR/fm-board-github.sh" ]; then
  "$SCRIPT_DIR/fm-board-github.sh" event "$KIND${ID:+ $ID}" >/dev/null 2>&1 || true
fi
exit 0
