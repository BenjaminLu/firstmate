#!/usr/bin/env bash
# fm-board-answer.sh - turn the captain's click on the live board into the
# answer the fleet already acts on.
#
# Usage:
#   fm-board-answer.sh apply --source <provenance>   (rows on stdin)
#   fm-board-answer.sh source-id
#
# apply      Read the captain's picks on stdin and carry each one to the record
#            that already owns it. Prints one line per key and one summary
#            line, and exits nonzero when any key was not recorded, so the
#            caller can tell the captain what happened to his click rather than
#            leaving him to wonder.
# source-id  Print the bound source id this channel feeds the keyed-answer
#            intake under. One line, nothing else.
#
# THIS SCRIPT RECORDS NOTHING ITSELF, AND THAT IS THE POINT. A click and a
# typed answer must settle a captain's call identically, so every durable
# effect here is produced by the owner that already produces it for the other
# channels:
#
#   the acknowledgement on the clicked row   bin/fm-bearings-board.sh ack
#   the captain's recorded answer            bin/fm-captain-hold.sh answers
#   a re-check of a call that may be moot    bin/fm-captain-hold.sh reconcile-requests
#   the board dropping the answered card     published by the intake above
#   firstmate learning an answer landed      the durable wake queue
#
# Nothing below decides what an answer MEANS, maps a key to a task, chooses a
# close mode beyond the one the card declared, or closes anything. Those rules
# have one owner each and this file holds none of them; see the keyed-answer
# intake in bin/fm-captain-hold.sh and the acknowledgement lifecycle in
# bin/fm-bearings-board.sh.
#
# A CLICK CARRIES WHAT THE CAPTAIN COULD SAY IN CHAT, AND NOTHING MORE. Almost
# every message says "the captain picked this option on this card". The one
# exception is the dispatch bar, which names no card and says "he ticked these
# queued rows" - an order to start work, named here rather than filed under
# "answer", because an absolute with one unstated exception is what invites a
# second.
#
# Neither can merge, discard, spawn, tear down, or run anything, because the
# only commands this file invokes are the four above and none of them takes an
# action from its input. Even the dispatch order decides nothing: it
# acknowledges the rows and wakes firstmate. What follows is firstmate's to
# decide under the rules that already govern it, which is why step 5 wakes him
# instead of acting.
#
# INPUT. One row per line, fields separated by tabs, already free of control
# characters (the caller is the boundary that sanitizes, because it is the one
# holding the untrusted bytes):
#
#   answer<TAB><key><TAB><value><TAB><label><TAB><close>
#   reconcile<TAB><key><TAB><note>
#
# <close> is empty, `done`, or `release`, and is the card's own declared mode.
# <label> is what the option said on the board, recorded beside the answer so
# the durable decision reads the way the captain read it. A `reconcile` row is
# the board's standard "go re-check reality" choice, which is never an answer;
# it is routed to its own intake, which refuses it unless this channel is bound.
#
# ORDER, AND WHY IT IS THIS ONE. The acknowledgement goes first, because it is
# the one thing the captain is watching for and it must not wait on a backlog
# read. The intake goes next, because it is the durable record. The wake goes
# last and on every path out of here, including the ones that failed: an answer
# firstmate never hears about is the failure this whole path exists to remove,
# and a wake that says the answer could not be recorded is worth far more than
# silence. Dying on a signal that cannot be trapped is the one case that
# defeats that, and it is why the caller writes the captain's answer down
# before it ever runs this - and why the caller's own timeout signals this
# script's process group with SIGTERM, which the EXIT trap below survives,
# rather than reaching straight for the signal named here.
#
# BOUND BEFORE IT CAN BE USED. `reconcile-requests` refuses a source that is
# not bound to the keyed-answer intake. Nothing binds here: the binding is made
# when the inbound token is issued (bin/fm-board-live.sh token), which is what
# a board must have before it can send anything at all, so a click can never
# arrive ahead of the binding that gives it somewhere to go.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The source id this channel feeds the keyed-answer intake under. One board per
# home at one stable path means one inbound channel per home, so this is a
# constant rather than something derived from the board file.
SOURCE_ID=board-live

# The dispatch bar's pseudo-key. It is not a card and names no task: it
# answers FOR the rows the captain ticked, carrying their ids as its value. So
# its acknowledgement goes to each ticked row rather than to itself, and it
# never reaches the keyed-answer intake, which could only report that no
# captain-held task is called dispatch.charted - a skip that would then be
# reported back to the captain as his order not landing. What it produces is
# the acknowledgement on each row he ticked and a wake naming them, which is
# what starting queued work has always been.
DISPATCH_KEY=dispatch.charted

TAB=$'\t'

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

# --- the wake -----------------------------------------------------------
# One wake per key, appended once, whatever else happened. fm-wake-lib.sh is
# sourced lazily so `source-id` and `--help` need nothing from it.
WOKE=0

# One `<key><TAB><what firstmate is being told>` line per key, kept where the
# exit trap can reach it: whatever goes wrong below, firstmate hears about the
# captain's answer.
WAKES=''
ACKED=0

ACK_FALLBACK="unrecorded${TAB}the captain answered on the board and this did not finish; read state/board-inbound.jsonl"

# Every exit but an untrappable signal comes through here, so a run that died
# between the captain's click and the record still tells firstmate it happened.
on_exit() {
  [ "$WOKE" -eq 0 ] || return 0
  wake_keys "${WAKES:-$ACK_FALLBACK}" || true
}

wake_keys() {  # <wake-lines>
  local lines=$1 lib="$FM_ROOT/bin/fm-wake-lib.sh" line key note
  [ "$WOKE" -eq 0 ] || return 0
  WOKE=1
  [ -n "$lines" ] || return 0
  if [ ! -r "$lib" ]; then
    printf 'fm-board-answer: the captain answered but firstmate was NOT told (missing %s)\n' "$lib" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib" || {
    printf 'fm-board-answer: the captain answered but firstmate was NOT told (cannot read %s)\n' "$lib" >&2
    return 1
  }
  local status=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%"$TAB"*}
    note=${line#*"$TAB"}
    fm_wake_append check "board-answer:$key" "check: $note" || status=1
  done <<EOF
$lines
EOF
  [ "$status" -eq 0 ] \
    || printf 'fm-board-answer: the captain answered but firstmate was NOT told (the wake queue refused)\n' >&2
  return "$status"
}

# --- step 1: the acknowledgement on the row he clicked -------------------
# A failed acknowledgement is a real failure, not a cosmetic one: the row the
# captain clicked then shows him nothing, which is the case this whole path
# exists to remove. So it is reported and it counts.
ack_one() {  # <key>
  if "$SCRIPT_DIR/fm-bearings-board.sh" ack "$1" --acting >/dev/null 2>&1; then
    printf 'acked: %s\n' "$1"
  else
    printf 'ack-failed: %s\n' "$1"
    ACKED=1
  fi
}

ack_key() {  # <key> <value>
  local key=$1 value=$2 picked
  if [ "$key" != "$DISPATCH_KEY" ]; then
    ack_one "$key"
    return 0
  fi
  while IFS= read -r picked; do
    [ -n "$picked" ] || continue
    ack_one "$picked"
  done <<EOF
$(printf '%s\n' "$value" | tr ',' '\n')
EOF
}

# Split a row into EXACTLY <count> tab-separated fields, into SPLIT. Exact in
# both directions: too few fields and too many are both refusals. `read` with a
# tab IFS cannot be used for this - tab is IFS whitespace, so bash collapses a
# run of tabs and an empty middle field silently shifts every later one along.
SPLIT=()
split_row() {  # <row> <count>
  local row=$1 want=$2 i=1
  SPLIT=()
  while [ "$i" -lt "$want" ]; do
    case $row in *"$TAB"*) ;; *) return 1 ;; esac
    SPLIT+=("${row%%"$TAB"*}")
    row=${row#*"$TAB"}
    i=$((i + 1))
  done
  case $row in *"$TAB"*) return 1 ;; esac
  SPLIT+=("$row")
}

command_apply() {
  local source='' row kind key value label mode note
  local answers='' reconciles='' out status=0 answered=0 reconciled=0 ordered=0

  while [ "$#" -gt 0 ]; do
    case $1 in
      --source) source=${2-}; shift 2 ;;
      *) printf 'fm-board-answer: unknown apply option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$source" ] \
    || { printf 'fm-board-answer: --source provenance is required\n' >&2; return 2; }

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    kind=${row%%"$TAB"*}
    case $kind in
      answer)
        if ! split_row "$row" 5; then
          printf 'refused: (a row with the wrong number of fields)\n'
          status=1
          continue
        fi
        key=${SPLIT[1]}; value=${SPLIT[2]}; label=${SPLIT[3]}; mode=${SPLIT[4]}
        ;;
      reconcile)
        if ! split_row "$row" 3; then
          printf 'refused: (a row with the wrong number of fields)\n'
          status=1
          continue
        fi
        key=${SPLIT[1]}; note=${SPLIT[2]}
        ;;
      *)
        printf 'refused: (an unreadable row)\n'
        status=1
        continue
        ;;
    esac
    case $key in
      ''|*[!A-Za-z0-9._-]*)
        printf 'refused: %s (not a routable key)\n' "${key:-(empty)}"
        status=1
        continue
        ;;
    esac
    [ "${#key}" -le 128 ] || { printf 'refused: %s (key is too long)\n' "$key"; status=1; continue; }
    if [ "$kind" = answer ] && [ "$key" = "$DISPATCH_KEY" ]; then
      [ -n "$value" ] || { printf 'refused: %s (no rows on it)\n' "$key"; status=1; continue; }
      ack_key "$key" "$value"
      WAKES="$WAKES$key${TAB}the captain ordered these queued items started from the board: $value
"
      ordered=$((ordered + 1))
    elif [ "$kind" = answer ]; then
      [ -n "$value" ] || { printf 'refused: %s (no answer on it)\n' "$key"; status=1; continue; }
      ack_key "$key" "$value"
      answers="$answers$key$TAB$value$TAB$label${mode:+$TAB$mode}
"
      WAKES="$WAKES$key${TAB}the captain answered $key on the board
"
      answered=$((answered + 1))
    else
      ack_key "$key" ''
      reconciles="$reconciles$key${note:+$TAB$note}
"
      WAKES="$WAKES$key${TAB}the captain asked for $key to be re-checked before it is answered
"
      reconciled=$((reconciled + 1))
    fi
  done

  if [ "$answered" -eq 0 ] && [ "$reconciled" -eq 0 ] && [ "$ordered" -eq 0 ]; then
    printf 'board-answer: nothing to record\n'
    return 1
  fi

  # Step 2 and 3. Each intake prints its own per-key verdict; those lines are
  # the report, passed through rather than re-worded, because the intake is the
  # owner of what happened and a second wording of it would drift from the
  # first.
  if [ "$answered" -gt 0 ]; then
    if ! out=$(printf '%s' "$answers" \
      | "$SCRIPT_DIR/fm-captain-hold.sh" answers --any-origin --source "$source" 2>&1); then
      status=1
    fi
    printf '%s\n' "$out"
  fi
  if [ "$reconciled" -gt 0 ]; then
    if ! out=$(printf '%s' "$reconciles" \
      | "$SCRIPT_DIR/fm-captain-hold.sh" reconcile-requests \
          --source-id "$SOURCE_ID" --source "$source" 2>&1); then
      status=1
    fi
    printf '%s\n' "$out"
  fi

  [ "$ACKED" -eq 0 ] || status=1
  if [ "$status" -eq 0 ]; then
    printf 'board-answer: answers=%s reconcile=%s dispatch=%s\n' \
      "$answered" "$reconciled" "$ordered"
  else
    printf 'board-answer: recorded with refusals; answers=%s reconcile=%s dispatch=%s\n' \
      "$answered" "$reconciled" "$ordered"
    # The wake is what firstmate acts on, so when part of this did not land it
    # says so there rather than only in a return code nobody reads later.
    WAKES=$(printf '%s' "$WAKES" \
      | sed '/./s|$| - part of this did NOT land; read state/board-inbound.jsonl|')
  fi

  # Step 5, last on the ordinary path; the exit trap covers every other one.
  wake_keys "$WAKES" || status=1
  return "$status"
}

cmd=${1-}
[ "$#" -gt 0 ] && shift
case $cmd in
  apply) trap on_exit EXIT; command_apply "$@" ;;
  source-id) printf '%s\n' "$SOURCE_ID" ;;
  ''|--help|-h) usage; [ -n "$cmd" ] && exit 0 || exit 2 ;;
  *) printf 'fm-board-answer: unknown command: %s\n' "$cmd" >&2; usage >&2; exit 2 ;;
esac
