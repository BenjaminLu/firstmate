#!/usr/bin/env bash
# fm-board-answer-check.sh - carry a captain's board answer back from GitHub.
#
# The GitHub board's read path is credential-free, and its write path cannot
# be: there is no unauthenticated write to GitHub, not through the API, not a
# push, not a workflow dispatch. So the board hands an answer to the captain's
# own browser as a prefilled issue, he submits it as himself, and this check
# is the fleet end of that route. GitHub authenticates him; no vendor is
# anywhere in it.
#
# Usage:
#   fm-board-answer-check.sh [check]
#   fm-board-answer-check.sh arm
#   fm-board-answer-check.sh disarm
#   fm-board-answer-check.sh --help
#
# `check` prints one line when firstmate should wake and prints nothing at all
# otherwise, which is the watcher's state-check contract, so this needs no
# schedule of its own. `arm` writes state/board-answers.check.sh and binds its
# bytes through fm-check-register.sh; `disarm` retires it through
# fm-check-unregister.sh.
#
# WHO MAY ANSWER. A store that anyone can read is usually a repository anyone
# can open an issue on, so identity is the whole safety of this path: without
# it a stranger could answer the captain's calls, and one of the board's card
# types is a merge. An answer is therefore accepted only when GitHub itself
# says the author is the captain - the login matches `answer_from` (default:
# the answer repository's owner) AND GitHub's own author_association is OWNER,
# MEMBER, or COLLABORATOR, which a submitter cannot set. Anything else is
# never fed to anything; it is labelled, closed, and reported as an attempt.
# Putting the answer sink in a private repository closes the door earlier, and
# `bin/fm-board-github.sh doctor` says which of the two this home has.
#
# WHAT IS ACCEPTED AUTOMATICALLY, AND WHAT IS NOT. A key that names a
# captain-held task is an answer, and it goes to the one keyed-answer intake
# (`bin/fm-captain-hold.sh answers`) that every other channel feeds, so every
# guard there applies identically. A `merge.<task>` or `dispatch.<...>` key is
# NOT an answer to a held task, it is an instruction to act, and this script
# actuates nothing: it records it and wakes firstmate, who holds merge
# authority. A board answer arriving over a public channel must never be able
# to merge anything by itself.
#
# THE INBOUND LATENCY IS THE WATCHER'S CADENCE, and it is unavoidable: GitHub
# cannot push to a laptop, and the alternative - a public endpoint for a
# webhook - is a hosting service this design does not take on. A closed issue
# is the cursor, so an answer is never ingested twice; one that could not be
# closed is remembered in state/.board-answers-seen instead.
#
# FM_BOARD_ANSWER_GH overrides the forge command (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="$FM_HOME/config/board-store"
GH="${FM_BOARD_ANSWER_GH:-gh}"

CHECK_ID=board-answers
SHIM="$STATE/$CHECK_ID.check.sh"
SEEN="$STATE/.board-answers-seen"
HANDOFF="$STATE/.board-answers"
LABEL=fm-board-answer
REJECT_LABEL=fm-board-answer-rejected

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

ANSWER_REPO=; ANSWER_FROM=
read_config() {
  [ -f "$CONFIG" ] || return 1
  local line key value repo=
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; *=*) key=${line%%=*}; value=${line#*=} ;; *) continue ;; esac
    case $key in
      repo) repo=$value ;;
      answer_repo) ANSWER_REPO=$value ;;
      answer_from) ANSWER_FROM=$value ;;
    esac
  done < "$CONFIG"
  [ -n "$ANSWER_REPO" ] || ANSWER_REPO=$repo
  [ -n "$ANSWER_REPO" ] || return 1
  [ -n "$ANSWER_FROM" ] || ANSWER_FROM=${ANSWER_REPO%%/*}
  return 0
}

# GitHub sets author_association; a submitter cannot. Both halves must hold.
author_trusted() {  # <login> <association>
  [ "$1" = "$ANSWER_FROM" ] || return 1
  case $2 in OWNER|MEMBER|COLLABORATOR) return 0 ;; *) return 1 ;; esac
}

close_issue() {  # <number> <comment>
  "$GH" api -X POST "repos/$ANSWER_REPO/issues/$1/comments" \
    -f body="$2" >/dev/null 2>&1 || return 1
  "$GH" api -X PATCH "repos/$ANSWER_REPO/issues/$1" -f state=closed >/dev/null 2>&1
}

mark_seen() { printf '%s\n' "$1" >> "$SEEN"; }
already_seen() { [ -f "$SEEN" ] && grep -qxF "$1" "$SEEN"; }

action_check() {
  command -v jq >/dev/null 2>&1 || exit 0
  read_config || exit 0
  mkdir -p "$STATE" 2>/dev/null || exit 0

  local issues
  issues=$("$GH" api "repos/$ANSWER_REPO/issues?labels=$LABEL&state=open&per_page=30" 2>/dev/null) || exit 0
  printf '%s' "$issues" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || exit 0

  local answered=0 held=0 refused=0 n login assoc body record key selection note close line
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    already_seen "$n" && continue
    login=$(printf '%s' "$issues" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .user.login // ""')
    assoc=$(printf '%s' "$issues" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .author_association // ""')
    body=$(printf '%s' "$issues" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .body // ""')

    if ! author_trusted "$login" "$assoc"; then
      refused=$((refused + 1))
      "$GH" api -X POST "repos/$ANSWER_REPO/issues/$n/labels" -f "labels[]=$REJECT_LABEL" >/dev/null 2>&1 || true
      close_issue "$n" "This is not the captain, so nothing was done with it. GitHub reports the author as $login ($assoc)." \
        || mark_seen "$n"
      continue
    fi

    # The record the board wrote, and nothing else in the body.
    record=$(printf '%s' "$body" | awk '/^```json$/{f=1;next} /^```$/{f=0} f' | jq -c '.' 2>/dev/null) || record=
    if [ -z "$record" ] \
       || [ "$(printf '%s' "$record" | jq -r '.schema // ""')" != "fm-board-answer.v1" ]; then
      refused=$((refused + 1))
      close_issue "$n" "This carried no fm-board-answer.v1 record the fleet could read, so nothing was done with it." \
        || mark_seen "$n"
      continue
    fi
    key=$(printf '%s' "$record" | jq -r '.question // ""')
    selection=$(printf '%s' "$record" | jq -r '.selection // ""')
    note=$(printf '%s' "$record" | jq -r '.note // ""')
    close=$(printf '%s' "$record" | jq -r '.close // ""')
    [ -n "$key" ] || { refused=$((refused + 1)); close_issue "$n" "This named no question." || mark_seen "$n"; continue; }

    case $key in
      merge.*|dispatch.*)
        # Not an answer to a held task: an instruction to act. This script
        # actuates nothing - firstmate holds merge authority.
        printf '%s\t%s\t%s\t%s\n' "$key" "$selection" "$note" "$ANSWER_REPO#$n" >> "$HANDOFF"
        held=$((held + 1))
        mark_seen "$n"
        continue
        ;;
    esac

    line=$(printf '%s\t%s\t%s' "$key" \
      "$(if [ -n "$note" ] && [ -n "$selection" ]; then printf '%s - %s' "$selection" "$note";
         elif [ -n "$note" ]; then printf '%s' "$note"; else printf '%s' "$selection"; fi)" \
      "the captain, on the board ($ANSWER_REPO#$n)")
    case $close in release) line="$line	release" ;; done) line="$line	done" ;; esac

    if printf '%s\n' "$line" | "$SCRIPT_DIR/fm-captain-hold.sh" answers --any-origin \
         --source "github-issue:$ANSWER_REPO#$n" >/dev/null 2>&1; then
      answered=$((answered + 1))
      close_issue "$n" "Recorded against $key. Thank you, captain." || mark_seen "$n"
    else
      refused=$((refused + 1))
      close_issue "$n" "The fleet could not record this against $key; firstmate has been woken to look at it." \
        || mark_seen "$n"
    fi
  done <<< "$(printf '%s' "$issues" | jq -r '.[].number')"

  # Plain ifs, not && chains: under `set -e` a false test in a && list would
  # end the check before it reported anything it had already done.
  local parts=
  if [ "$answered" -gt 0 ]; then parts="$answered board answer(s) recorded"; fi
  if [ "$held" -gt 0 ]; then parts="${parts:+$parts, }$held board instruction(s) waiting on you (state/.board-answers)"; fi
  if [ "$refused" -gt 0 ]; then parts="${parts:+$parts, }$refused board submission(s) refused"; fi
  if [ -n "$parts" ]; then printf 'board answers: %s\n' "$parts"; fi
  exit 0
}

action_arm() {
  read_config || fail "this home has no board answer address: write $CONFIG"
  mkdir -p "$STATE" || exit 1
  local home
  case $FM_HOME in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  umask 077
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-board-answer-check.sh - board answer poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-board-answer-check.sh") check" > "$SHIM" || exit 1
  chmod 0700 "$SHIM" || exit 1
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null \
    || { rm -f -- "$SHIM"; fail "could not register state/$CHECK_ID.check.sh"; }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1 || rm -f -- "$SHIM"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
