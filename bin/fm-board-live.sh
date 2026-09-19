#!/usr/bin/env bash
# fm-board-live.sh - publish fleet events to the bearings board, and run the
# server that pushes them.
#
# Usage:
#   fm-board-live.sh event <kind> <task-id> [--state S] [--detail D] [--name N]
#                          [--repo R] [--kind-of-task K] [--what W] [--owner O]
#                          [--pr-url U] [--key K]
#   fm-board-live.sh start [--port N]
#   fm-board-live.sh stop
#   fm-board-live.sh status
#   fm-board-live.sh endpoint
#   fm-board-live.sh doctor
#
# event     Append ONE fm-board-event.v1 line to this home's event log. That
#           append is the whole publication: no port is opened, no process is
#           contacted, nothing is waited for. bin/fm-board-live.mjs follows the
#           log and repaints every open board from it.
#
#           THIS SUBCOMMAND NEVER FAILS ITS CALLER. It is invoked from inside
#           dispatch, teardown, hold, and answer paths, and a board is worth
#           less than any of them, so every failure here - no home, no disk, a
#           malformed argument - exits 0 after writing one line to stderr. A
#           board that missed an event says it is behind (the server marks it
#           stale); a teardown that died publishing one is a real loss.
#
#           Kinds, and the fields each one uses:
#             step        --state --detail       a worker's step changed
#             dispatched  --name --repo --state --detail --kind-of-task
#             landed      --what --owner --repo --pr-url
#             pr          --pr-url              a pull request changed
#             answered    --key                 a captain's call was answered
#             call                              a captain's call was opened
#           A `call` carries no words on purpose: the question's prose is
#           firstmate's to compose, so the event only tells the board it is
#           behind. bin/fm-board-live.mjs owns what each kind may change.
#
# start     Start the server if this home has none, and print its endpoint.
#           Idempotent: a second start prints the running endpoint and exits 0.
#           Nothing about this is a step a person has to remember - the board
#           build starts it, so a clone that has never heard of this script
#           still gets a live board.
# stop      Stop this home's server. Exits 0 when none is running.
# status    Print whether a server is running here, its endpoint, and how many
#           events the log holds.
# endpoint  Print the endpoint URL a page should connect to, from the running
#           server's own record, or exit 1 when none is running.
# doctor    Report what is and is not set up here, and exit 0 when the home is
#           in a complete state - including the complete state of having no
#           board at all.
#
# WHY A FILE AND NOT A SOCKET. A publisher that had to reach a process could
# fail in a caller that must not fail, and would lose the event when the server
# is down. An append cannot: the log is the durable record and the server is
# only the latency. That is also what makes a restart a non-event.
#
# docs/configuration.md owns the port, the log, and the endpoint record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$STATE/board-live.jsonl"
PIDFILE="$STATE/board-live.pid"
ENDPOINT="$STATE/board-live.endpoint"
SERVER="$SCRIPT_DIR/fm-board-live.mjs"

# The whole header, found by where it ends rather than by a line number: a
# hardcoded range silently drops whatever is added past it, which is how this
# help lost its pointer to the file that owns the port and the paths.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

# One JSON string, escaped the way JSON requires. jq is this repo's JSON tool
# everywhere else, but `event` must not depend on a tool being installed to
# keep a caller alive, so the escaping is done here.
json_string() {  # <text>
  local s=$1 out=""
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  # A control character in a durable record is a corrupt line for every later
  # reader, so anything below space that survived the cases above is dropped.
  out=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$out"
}

server_pid() {
  local pid
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

command_event() {
  local kind=${1-} task=${2-}
  shift 2 2>/dev/null || true
  if [ -z "$kind" ] || [ -z "$task" ]; then
    printf 'fm-board-live: event needs a kind and a task id\n' >&2
    return 0
  fi
  case $kind in
    step|dispatched|landed|pr|answered|call) ;;
    *) printf 'fm-board-live: unknown event kind: %s\n' "$kind" >&2; return 0 ;;
  esac

  local fields="" at
  while [ "$#" -gt 0 ]; do
    local name=""
    case $1 in
      --state) name=state ;;
      --detail) name=detail ;;
      --name) name=name ;;
      --repo) name=repo ;;
      --kind-of-task) name=task_kind ;;
      --what) name="what" ;;
      --owner) name=owner ;;
      --pr-url) name=pr_url ;;
      --key) name=key ;;
      *) printf 'fm-board-live: unknown event option: %s\n' "$1" >&2; return 0 ;;
    esac
    if [ "$#" -lt 2 ]; then
      printf 'fm-board-live: %s needs a value\n' "$1" >&2
      return 0
    fi
    fields="$fields,$(json_string "$name"):$(json_string "$2")"
    shift 2
  done

  at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || at=""
  if [ -z "$at" ]; then
    printf 'fm-board-live: cannot stamp the event; not publishing\n' >&2
    return 0
  fi
  # PUBLISHING NEVER CREATES A HOME. A teardown that retires a secondmate
  # removes the home it was torn down in, and a publisher that ran afterwards
  # and made the directory would resurrect the retired home as a side effect of
  # telling a board that no longer exists. So an absent state directory means
  # there is nothing here to tell, not something to create.
  if [ ! -d "$STATE" ]; then
    printf 'fm-board-live: no state directory at %s; not publishing\n' "$STATE" >&2
    return 0
  fi
  # One append of one line. O_APPEND on a line this short is atomic against
  # concurrent publishers on every filesystem this fleet runs on, so no lock is
  # taken and no caller ever waits on one.
  if ! printf '{"schema":"fm-board-event.v1","at":%s,"kind":%s,"task":%s%s}\n' \
      "$(json_string "$at")" "$(json_string "$kind")" "$(json_string "$task")" "$fields" \
      >> "$LOG" 2>/dev/null; then
    printf 'fm-board-live: cannot append to the board event log\n' >&2
    return 0
  fi
  return 0
}

command_start() {
  local port_args=() pid
  while [ "$#" -gt 0 ]; do
    case $1 in
      --port) port_args=(--port "${2-}"); shift 2 ;;
      *) printf 'fm-board-live: unknown start option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if pid=$(server_pid); then
    printf 'already-running: %s\n' "$pid"
    [ -f "$ENDPOINT" ] && cat "$ENDPOINT"
    return 0
  fi
  command -v node >/dev/null 2>&1 || {
    printf 'fm-board-live: node is required to serve the live board\n' >&2
    return 1
  }
  [ -f "$SERVER" ] || { printf 'fm-board-live: server is missing: %s\n' "$SERVER" >&2; return 1; }
  ( [ -d "$STATE" ] || mkdir -p "$STATE" ) || {
    printf 'fm-board-live: cannot create %s\n' "$STATE" >&2
    return 1
  }
  # Detached, with its own output kept, so a server that refused its port says
  # why in a file rather than dying invisibly behind a build.
  ( umask 077
    FM_HOME="$FM_HOME" nohup node "$SERVER" serve \
      ${port_args[@]+"${port_args[@]}"} >"$STATE/board-live.log" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$PIDFILE" )
  # The endpoint record is written by the server once it has the port, so its
  # appearance - not the fork - is what proves the server took one.
  local waited=0
  while [ "$waited" -lt 50 ]; do
    if [ -f "$ENDPOINT" ] && server_pid >/dev/null; then
      printf 'started: %s\n' "$(server_pid)"
      cat "$ENDPOINT"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  printf 'fm-board-live: the server did not come up; see %s\n' "$STATE/board-live.log" >&2
  return 1
}

command_stop() {
  local pid
  if ! pid=$(server_pid); then
    printf 'not-running\n'
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  rm -f -- "$PIDFILE"
  printf 'stopped: %s\n' "$pid"
}

command_status() {
  local pid lines
  lines=0
  [ -f "$LOG" ] && lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if pid=$(server_pid); then
    printf 'running: %s\n' "$pid"
    [ -f "$ENDPOINT" ] && printf 'endpoint: %s' "$(cat "$ENDPOINT")" && printf '\n'
  else
    printf 'running: no\n'
  fi
  printf 'events: %s\n' "${lines:-0}"
  printf 'log: %s\n' "$LOG"
}

command_endpoint() {
  server_pid >/dev/null || { printf 'fm-board-live: no server is running in this home\n' >&2; return 1; }
  [ -f "$ENDPOINT" ] || { printf 'fm-board-live: the server has recorded no endpoint\n' >&2; return 1; }
  cat "$ENDPOINT"
}

command_doctor() {
  local ok=0
  if command -v node >/dev/null 2>&1; then
    printf 'node: %s\n' "$(node -v)"
  else
    printf 'node: MISSING - the live board cannot serve without it\n'
    ok=1
  fi
  if [ -f "$SERVER" ]; then
    printf 'server: %s\n' "$SERVER"
  else
    printf 'server: MISSING\n'
    ok=1
  fi
  if [ -f "$FM_HOME/.lavish/bearings-board.html" ]; then
    printf 'board: %s\n' "$FM_HOME/.lavish/bearings-board.html"
  else
    # A home with no board is complete, not broken: nothing has built one yet.
    printf 'board: none built in this home yet\n'
  fi
  command_status
  return $ok
}

cmd=${1-}
[ "$#" -gt 0 ] && shift
case $cmd in
  event) command_event "$@" ;;
  start) command_start "$@" ;;
  stop) command_stop "$@" ;;
  status) command_status "$@" ;;
  endpoint) command_endpoint "$@" ;;
  doctor) command_doctor "$@" ;;
  ''|--help|-h) usage; [ -n "$cmd" ] && exit 0 || exit 2 ;;
  *) printf 'fm-board-live: unknown command: %s\n' "$cmd" >&2; usage >&2; exit 2 ;;
esac
