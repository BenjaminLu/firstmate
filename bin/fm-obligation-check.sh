#!/usr/bin/env bash
# fm-obligation-check.sh - report the fleet obligations that recur on every
# pull request and every merge and are currently NOT met.
#
# Usage:
#   fm-obligation-check.sh [check]
#   fm-obligation-check.sh report
#   fm-obligation-check.sh arm [--if-needed]
#   fm-obligation-check.sh disarm
#   fm-obligation-check.sh --help
#
# WHY THIS EXISTS
#
# Across 2026-09-19 and 2026-09-20 this fleet missed the same shape of thing
# repeatedly: an obligation that recurs every time a pull request appears or a
# merge lands was performed correctly once and then never again, and nothing
# made a sound when it stopped. The obligations that never slipped in the same
# window were the ones a script refused to proceed without, or that blocked the
# turn until they were done. The dividing line was not importance or attention:
# an obligation held when the system refused to proceed without it, and slipped
# when it depended on an agent noticing that now was the moment.
#
# So this is the second of those two mechanisms - the turn-end check that fails
# loudly while an obligation is owed - built on the one the fleet already has.
# The watcher runs state/*.check.sh on every sweep, a check prints one line only
# when firstmate should wake, and the durable wake queue then refuses to let the
# turn end until that line is handled. Nothing here is a new control plane.
#
# WHAT IT REPORTS
#
# Four obligations, each computed from durable records plus the forge, each a
# fact rather than a judgement:
#
#   1. A task's own OPEN pull request with nothing posted on it - no review and
#      no comment. The recorded cost: three of three open pull requests had zero
#      reviews, against a delivery path whose merge gate requires every finding
#      ruled. A task whose records name no pull request is not assumed to have
#      none: the forge is asked by the task's own branch, so this does not rest
#      on firstmate having remembered to record one. See
#      discover_task_pull_request.
#   2. An armed merge poll whose recorded head is not the pull request's live
#      head, or that watches a pull request which is closed and unmerged. The
#      recorded cost: six of eight armed polls were watching superseded commits
#      and one watched a pull request closed hours earlier.
#   3. A Captain's Call card on the board whose pull request is no longer open.
#      The recorded cost: a merged pull request sat on the board for eight hours.
#   4. A live task firstmate has STEERED that has no durable design record. The
#      recorded cost: every design decision of a session was recoverable only
#      from one worker's steering inbox and the conversation.
#
# It is an OBSERVER. It reads, it prints one line, and it changes nothing but
# its own report record. It never merges, dispatches, rebuilds a board, rebinds
# a poll, writes a design record, or touches any task, worktree, or forge state,
# and it holds up no fleet action while it runs. Firstmate acts; this only says
# what is owed.
#
# THE JUDGEMENTS THIS SCRIPT MAKES, STATED RATHER THAN ASSUMED
#
# ONE FLEET CHECK, NOT ONE PER TASK. All four obligations are facts about the
# home rather than about one task: the board is a single artifact for the whole
# home, and obligations 1 and 2 are answered for every task at once by a single
# pull request listing per repository. A per-task check would repeat that
# listing once per task, and obligations 3 and 4 have no task whose lifecycle
# would arm and retire them - a card left behind by a torn-down task is exactly
# the case that went unnoticed for eight hours. So this follows the fleet-level
# precedent already in state/: contributions.check.sh, tool-updates.check.sh and
# mail.check.sh.
#
# UNDETERMINABLE IS ITS OWN ANSWER, NOT "OWED" AND NEVER SILENCE. When the forge
# cannot be reached, a record cannot be read, or the sweep budget runs out, the
# affected obligation is reported in a separate `unknown:` segment, visibly
# distinct from `owed:`. Reporting it as owed would send firstmate to dispatch a
# reviewer against a pull request that may already have one, and a check whose
# reports are routinely wrong is an advisory line that gets skimmed - which is
# the failure mode this whole mechanism exists to end. Reporting it as met is
# forbidden outright: silence from this check means all four obligations were
# checked and found met, and nothing else.
#
# COST. One `gh pr view` per DISTINCT pull request this home is actually
# watching - a task's own pull request, an armed poll's, a board card's - and
# one read covers all three when they name the same pull request. Measured 0.59
# and 0.60 seconds per call against cli/cli on 2026-09-20. Plus one
# `gh pr list --head` for each task whose records name no pull request, which is
# obligation 1's discovery path, measured 0.67 and 0.74 seconds. Obligation 4
# costs no forge call at all, and a home with no task and no board makes none.
# view_pull_request's own comment records why this is not one listing per
# repository, with the measurements that decided it.
#
# Each call is bounded by FM_OBLIGATION_CALL_SECS (default 12) and the whole
# sweep by FM_OBLIGATION_BUDGET_SECS (default 20). Twelve is not a guess and not
# a fresh measurement: it is the figure bin/fm-contributions.sh already derived
# for this exact CLI against this exact forge, from measured GitHub latency of
# 0.9 to 4.4 seconds per call with samples 4.35, 2.83 and 3.39 and one read per
# URL regularly past five seconds. That script's previous FIVE-second bound
# killed reads from a merely slow forge, and this must not repeat it.
#
# The sweep has to finish inside the watcher's own per check bound, because a
# run the watcher kills prints nothing and writes no record, so it would repeat
# that silence on every poll. A budget larger than FM_CHECK_TIMEOUT allows is
# cut down to what fits and the cut is named in the report, so it is visible
# rather than assumed. When the budget runs out mid-sweep, every pull request it
# did not reach is reported as unknown rather than dropped.
#
# The forge is not read on every sweep. Probes run at most once per
# FM_OBLIGATION_INTERVAL (default 900, 0 disables the gate, otherwise 60..86400),
# so the watcher's 300-second sweep does not turn into a forge poll every five
# minutes. That gate covers the FORGE and nothing else: obligation 4 and the
# task records it reads cost no forge call, so a sweep inside the interval
# still evaluates and reports them, and carries the forge half of the last
# reading forward unchanged. Rate-limiting work that does not use the rationed
# resource would delay an owed obligation by up to a whole interval and save
# nothing.
#
# WHAT COUNTS AS A REVIEW. A pull request satisfies obligation 1 when it carries
# any formal review OR any comment. The reviewed-PR path posts its findings with
# `gh pr comment`, and firstmate posts its rulings the same way, so a formal
# review alone would miss both. This is deliberately not filtered by author: in
# a fleet where the worker, the reviewer and firstmate all authenticate as one
# GitHub account, an author filter would discard the rulings it is meant to
# find. The stated consequence is that a bot comment, or a note the author left
# on their own pull request, satisfies this obligation. The check reports that
# nobody has said anything on the pull request, which is the fact it can
# establish; whether what was said is a review is firstmate's read.
#
# WHAT COUNTS AS A DESIGN RECORD. data/<task>/design.md or data/<task>/report.md.
# The obligation applies only to a task firstmate has actually STEERED - one
# whose state/<task>.inbox holds at least FM_OBLIGATION_STEERS records, pending
# or handled. A task that was dispatched and never steered has its whole plan in
# its brief, which is already durable; a task that has been steered has had its
# plan moved somewhere the brief does not cover, and the steering inbox is
# removed at teardown. That threshold is the one place here where a policy, not
# a fact, decides whether a line is printed, which is why it is a named setting
# with its strict value as the default rather than a number buried in the code.
#
# WHY A MERGED PULL REQUEST UNDER AN ARMED POLL IS NOT REPORTED. That poll is
# doing its job: it prints `merged` on its next sweep and retires itself. Only a
# poll watching a CLOSED and unmerged pull request is owed, because that one
# will never fire. A stale recorded head IS reported even on an open pull
# request, because bin/fm-teardown.sh's landed-work test and
# bin/fm-review-diff.sh's review base both read pr_head=, and both read the
# wrong commit while it is stale.
#
# A pull request under an armed poll with no recorded pr_head= at all is not
# reported. Nothing was recorded, so nothing is stale; bin/fm-pr-check.sh
# records the head only when the forge's CLI supplies it.
#
# STATED GAP: GITLAB. Every forge read here is `gh` against GitHub. A GitLab
# merge request reaches this check through the same records, and is reported as
# unknown naming GitLab, rather than being passed over as met. Adding `glab` is
# the follow-up; until it lands a GitLab home gets a named gap instead of a
# quiet one.
#
# STATED GAP: jq. Obligation 3 has to read the board's injected JSON payload,
# and jq is not a tool a fresh clone is required to have. The forge reads need
# no jq at all - gh carries its own - so only obligation 3 is affected. Without
# jq: a home with no board file has no card to be stale and obligation 3 is
# genuinely met, while a home that HAS a board is reported as unknown naming jq.
# The board itself is built by bin/fm-bearings-board.sh, which needs jq, so the
# first case is the only one a jq-less clone actually reaches.
#
# SELF-CONTAINED. A fresh clone gets this with no setup: no config file, no
# environment variable, no installed tool the repository does not already
# require, and no coding agent of any vendor. Every input is either a durable
# record this home already writes or a shipped default. The two tools it does
# reach for, gh and jq, are each detected and named at the moment they are
# needed rather than assumed, and their absence produces an unknown line rather
# than a clean result.
#
# WHEN IT IS ARMED, AND WHY NOT ALWAYS. Bootstrap arms this on a locked session
# with `arm --if-needed`, rather than leaving it to an operator action, because
# a detector somebody has to remember to switch on is the same failure it exists
# to catch. `--if-needed` arms only a home that has something this check could
# report on - a live task, or a board page - and is otherwise silent, because a
# registered custom check makes supervision REQUIRED for that home
# (bin/fm-supervision-lib.sh's FM_SUP_CHECKS), and a home with no task and no
# board would then keep a watcher alive to report on nothing. A home that has a
# task already needs that watcher, so arming there costs nothing new, and a home
# whose last task is gone keeps the check for its board - which is the eight
# hours a merged pull request sat on one. It never disarms itself.
#
# `disarm` is not permanent, and saying otherwise would be a contract this code
# does not keep: it retires the check now, and the next locked bootstrap of a
# home that still has a task or a board arms it again. That is deliberate - a
# detector a home can quietly end up without is the failure this exists to
# catch - but it means `disarm` is for retiring the check in a home that should
# not have it at this moment, not for turning it off for good.
#
# REPORTING ONCE, AND REPORTING AGAIN. The record state/.fleet-obligations holds
# the whole finding set the last report was made from, uncut, so the same owed
# obligation is reported once rather than on every sweep, while a new finding
# that lands past the printed line's cut is still news. An unchanged finding set
# is reported again once the last report is older than FM_OBLIGATION_REPEAT
# (default 3600, 0 disables), because acknowledging a wake is not discharging
# the obligation, and an obligation that goes quiet while still owed is the
# exact failure this script was built to end. A sweep killed part way through
# leaves no record and is retried instead of suppressing its finding.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BOARD="${FM_BOARD_OVERRIDE:-$FM_HOME/.lavish/bearings-board.html}"
CHECK_ID=fleet-obligations
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.$CHECK_ID"
RECORD_SCHEMA=fm-fleet-obligations-v2
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
BOARD_ANCHOR='<script id="bearings-data" type="application/json">'

# One finding names a full pull request URL, a task id and two abbreviated
# commits, and several can report in one sweep, so this is wider than
# bin/fm-line-cap-lib.sh's 220-character digest default. That library is
# deliberately not used here: its cut is a blind character cut, and a wake line
# that simply stops mid-finding hides both that finding and every one after it
# behind one marker. compose_line below cuts by whole findings and says how many
# it did not show, and the `report` action is where those stay readable.
MAX_LINE=1000

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-clock-lib.sh
. "$SCRIPT_DIR/fm-clock-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-obligation-check.sh [check]   report unmet fleet obligations (silent when all four are met)
  fm-obligation-check.sh report    print the full finding set the last check recorded
  fm-obligation-check.sh arm       write and register state/fleet-obligations.check.sh
  fm-obligation-check.sh arm --if-needed
                                   arm only a home that has a live task or a board
  fm-obligation-check.sh disarm    retire the check, its trust binding, and the record
                                   (the next locked bootstrap arms it again)

Reads durable records in this home plus the forge. Writes nothing but its own
report record. See this script's header for the four obligations, the cost
model, and the stated gaps.
EOF
}

die_usage() {
  printf 'fm-obligation-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# read_setting <name> <value> <min> <max> <zero-allowed>: validate and put the
# result in FM_SETTING. It assigns rather than prints because an `exit` inside a
# command substitution ends only that subshell, so a refusal written that way
# would leave the setting empty and let the sweep run on anyway.
FM_SETTING=
read_setting() {
  local name=$1 value=$2 min=$3 max=$4 zero=$5
  FM_SETTING=
  case "$value" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$value" -eq 0 ]; then
        if [ "$zero" = 1 ]; then FM_SETTING=$value; return 0; fi
      elif [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
        FM_SETTING=$value
        return 0
      fi
      ;;
  esac
  if [ "$zero" = 1 ]; then
    printf 'fm-obligation-check: %s must be 0 or a whole number from %s to %s\n' "$name" "$min" "$max" >&2
  else
    printf 'fm-obligation-check: %s must be a whole number from %s to %s\n' "$name" "$min" "$max" >&2
  fi
  exit 2
}

read_setting FM_OBLIGATION_INTERVAL "${FM_OBLIGATION_INTERVAL:-900}" 60 86400 1
INTERVAL=$FM_SETTING
read_setting FM_OBLIGATION_REPEAT "${FM_OBLIGATION_REPEAT:-3600}" 60 604800 1
REPEAT=$FM_SETTING
read_setting FM_OBLIGATION_CALL_SECS "${FM_OBLIGATION_CALL_SECS:-12}" 1 30 0
CALL_SECS=$FM_SETTING
read_setting FM_OBLIGATION_BUDGET_SECS "${FM_OBLIGATION_BUDGET_SECS:-20}" 1 120 0
BUDGET_SECS=$FM_SETTING
read_setting FM_OBLIGATION_STEERS "${FM_OBLIGATION_STEERS:-1}" 1 1000 0
STEER_FLOOR=$FM_SETTING

# The smallest bound a call can be given, because fm_run_timed treats a
# non-positive bound as no bound.
CALL_MIN_SECS=1
# A local git read of a task's own worktree. Bounded far tighter than a forge
# call because it touches no network, and bounded at all because a worktree on
# a stalled mount must not hang the sweep.
LOCAL_READ_SECS=5
# Both clocks count whole seconds, so a call can start when the arithmetic says
# a second is left while almost none of it really is.
CLOCK_ROUNDING_SECS=1
# fm_run_timed asks its runner for -k 1, so a call that does not stop on TERM is
# only killed a second after its bound.
KILL_GRACE_SECS=1

# The watcher's per check bound, read from this check's own environment. The
# watcher runs the check as a direct child, so an operator who raised it is seen
# here too, and when it is unset both sides resolve the same default.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_MAX=$((CHECK_TIMEOUT - CALL_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
# Cut rather than refuse. A refusal is reported once and then suppressed by the
# no-nag gate, which leaves this detector dead and quiet, and a check that goes
# silent is worse than a check that reports something awkward.
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

# --- findings ---------------------------------------------------------------

# Newline-delimited lists, one finding per line, never a string the printer has
# to split back apart. flatten() guarantees no finding can contain a newline, so
# a list is unambiguous whatever a home path or a board key holds; joining them
# with "; " for the wake line is a one-way rendering step.
#
# They are kept in two scopes because the no-probe interval gates the forge and
# nothing else. A sweep inside that interval still evaluates every LOCAL
# obligation and reports it, and carries the FORGE findings forward from the
# record unchanged, so gating a rate limit for one resource never suppresses
# work that does not use it.
OWED_LOCAL=
UNKNOWN_LOCAL=
OWED_FORGE=
UNKNOWN_FORGE=
# Which pair owed() and unknown() append to. Set once per phase by action_check.
FINDING_SCOPE=local
DEADLINE=0
BUDGET_REPORTED=0

flatten() { printf '%s' "$1" | tr '\t\r\n' '   '; }

owed() {
  if [ "$FINDING_SCOPE" = local ]; then
    OWED_LOCAL="$OWED_LOCAL$(flatten "$1")
"
  else
    OWED_FORGE="$OWED_FORGE$(flatten "$1")
"
  fi
}

unknown() {
  if [ "$FINDING_SCOPE" = local ]; then
    UNKNOWN_LOCAL="$UNKNOWN_LOCAL$(flatten "$1")
"
  else
    UNKNOWN_FORGE="$UNKNOWN_FORGE$(flatten "$1")
"
  fi
}

all_owed() { printf '%s%s' "$OWED_LOCAL" "$OWED_FORGE"; }
all_unknown() { printf '%s%s' "$UNKNOWN_LOCAL" "$UNKNOWN_FORGE"; }

count_findings() {
  printf '%s' "$1" | awk 'NF { n++ } END { printf "%d", n + 0 }'
}

budget_left() {
  local now
  fm_now now
  printf '%s\n' $((DEADLINE - now))
}

# True while the sweep budget still has room for another forge call.
budget_allows() { [ "$(budget_left)" -gt 0 ]; }

# The bound for one call: the call bound, cut down to whatever the sweep budget
# has left, never below CALL_MIN_SECS because fm_run_timed treats a non-positive
# bound as no bound.
call_bound() {
  local left
  left=$(budget_left)
  if [ "$left" -lt "$CALL_MIN_SECS" ]; then
    printf '%s\n' "$CALL_MIN_SECS"
  elif [ "$left" -lt "$CALL_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$CALL_SECS"
  fi
}

# --- durable records --------------------------------------------------------

# One readable, non-symlink regular file. Every read here is of a record this
# home wrote, so the bar is "can this be trusted to say what it says", not the
# ownership proof arming needs.
readable_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }

meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Every live task in this home, one id per line. A task's metadata is what makes
# it live: bin/fm-teardown.sh removes it. Secondmates are excluded because a
# secondmate is a persistent direct report rather than a work item, so none of
# the four obligations is about one.
# A task record this home cannot read is an input whose obligations cannot be
# established - obligations 1, 2 and 4 all start from it - so it is reported as
# undeterminable rather than dropped. Dropping it would delete that whole task
# from the report in silence, which is the one thing this check may never do.
#
# The list is built ONCE into a global rather than produced by a function each
# caller reads through `< <(...)`. A process substitution runs in a subshell, so
# a finding recorded from inside one is assigned to a copy of the finding list
# that dies with it - the report would come out clean while the record was
# unreadable. Callers iterate the global with a here-string, which runs in the
# caller's own shell.
LIVE_TASKS=

collect_live_tasks() {
  local meta id
  LIVE_TASKS=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    if ! fm_pr_task_id_valid "$id"; then
      unknown "a task record at $meta does not carry a usable task id, so its obligations were not checked"
      continue
    fi
    if ! readable_file "$meta"; then
      unknown "the task record for $id cannot be read, so its obligations were not checked"
      continue
    fi
    [ "$(meta_value "$meta" kind)" = secondmate ] && continue
    LIVE_TASKS="$LIVE_TASKS$id
"
  done
}

# How many steering records a task has, pending plus handled.
steer_count() {
  local inbox=$1 count=0 entry
  for entry in "$inbox"/*.msg "$inbox"/handled/*.msg; do
    [ -f "$entry" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# --- obligation 4: a steered task with no design record ---------------------

# Local only, no forge call, so it is evaluated before anything can spend the
# budget, can never be cut short by it, and is not held behind the no-probe
# interval that rations the forge.
check_design_records() {
  local id inbox steers
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    inbox="$STATE/$id.inbox"
    [ -d "$inbox" ] || continue
    steers=$(steer_count "$inbox")
    [ "$steers" -ge "$STEER_FLOOR" ] || continue
    [ -e "$DATA/$id/design.md" ] && continue
    [ -e "$DATA/$id/report.md" ] && continue
    if [ "$steers" = 1 ]; then
      owed "$id has been steered once with no design record at data/$id/design.md"
    else
      owed "$id has been steered $steers times with no design record at data/$id/design.md"
    fi
  done <<< "$LIVE_TASKS"
}

# --- what has to be asked of the forge --------------------------------------

# One line per thing that needs a pull request's live state:
#   <key|-> <TAB> <url> <TAB> <slug|-> <TAB> <number|-> <TAB> <role> <TAB> <owner> <TAB> <extra>
# role is taskpr (obligation 1, from the task's own records), discovered
# (obligation 1, found at the forge by the task's branch), poll (obligation 2,
# extra is the recorded head), or card (obligation 3, owner is the board card
# key).
#
# The key is the pull request's CANONICAL identity - the lowercased owner and
# repository plus the number - and never the raw URL a local record happens to
# hold. GitHub owner and repository names are case-insensitive and gh answers in
# its own canonical spelling, so a record written in another case names the same
# pull request while matching no raw string the forge returns. Keying on the raw
# string made such a record read successfully at the forge and then match
# nothing, which fell through to "met" - silence while the obligation was owed.
# It is also what makes the dedupe real: one pull request spelled two ways is
# one key, and so one forge read.
TARGETS=

pr_key() {
  printf '%s#%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$2"
}

add_target() {
  local url=$1 role=$2 owner=$3 extra=${4:-}
  local slug=- number=- key=-
  if fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ]; then
    slug="$FM_PR_OWNER/$FM_PR_REPO"
    number=$FM_PR_NUMBER
    key=$(pr_key "$slug" "$number")
  fi
  TARGETS="$TARGETS$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$key" "$url" "$slug" "$number" "$role" "$owner" "$extra")
"
}

# A bounded read of a task's own worktree, charged to the same sweep budget as
# a forge call.
#
# WHY IT DECLINES RATHER THAN CLAMPING. It used to shrink its own bound to what
# the budget had left and run anyway, with CALL_MIN_SECS flooring that at a
# second, so every task past the deadline still cost up to two seconds and the
# sweep grew without limit: measured 23, 30 and 46 seconds for six, twelve and
# twenty-four tasks with a stalled git. Past FM_CHECK_TIMEOUT the watcher kills
# the run, and a killed run prints nothing AND writes no record - so the probe
# clock never moves and the next sweep repeats it. That is the permanent
# silence the budget exists to prevent, reached through the one path the budget
# did not cover. It now declines once the budget is spent, exactly as the forge
# reads do, and the caller turns that into the ordinary budget note.
#
# The four statuses the caller has to tell apart. They are named rather than
# written as bare numbers at the six places that produce or match them, because
# a "3" in a case arm says nothing about why that arm calls budget_note, and
# because these names are then the one owner of the table instead of a comment
# that can drift from the code.
GIT_READ_OK=0            # the command answered
GIT_READ_REFUSED=1       # a clean refusal - a determinate no, such as a detached HEAD
GIT_READ_UNESTABLISHED=2 # it hit its bound, or answered nothing where an answer was required
GIT_READ_BUDGET_SPENT=3  # the sweep budget is spent, and nothing was run
GIT_OUT=
git_read() {
  local wt=$1 bound left status
  GIT_OUT=
  shift
  budget_allows || return "$GIT_READ_BUDGET_SPENT"
  left=$(budget_left)
  bound=$LOCAL_READ_SECS
  [ "$left" -ge "$bound" ] || bound=$left
  [ "$bound" -ge "$CALL_MIN_SECS" ] || bound=$CALL_MIN_SECS
  GIT_OUT=$(fm_run_timed "$bound" git -C "$wt" "$@" 2>/dev/null)
  status=$?
  [ "$status" -ne 124 ] || return "$GIT_READ_UNESTABLISHED"
  [ "$status" -eq 0 ] || return "$GIT_READ_REFUSED"
  [ -n "$GIT_OUT" ] || return "$GIT_READ_UNESTABLISHED"
  return "$GIT_READ_OK"
}

# owner/repo of a GitHub remote URL, in either the ssh or the https spelling.
github_slug_from_remote() {
  local raw=$1 path
  case "$raw" in
    git@github.com:*) path=${raw#git@github.com:} ;;
    ssh://git@github.com/*) path=${raw#ssh://git@github.com/} ;;
    https://github.com/*) path=${raw#https://github.com/} ;;
    http://github.com/*) path=${raw#http://github.com/} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  path=${path%/}
  case "$path" in
    */*/*|*/) return 1 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

# Obligation 1's discovery path, used for a task whose records name no pull
# request of its own.
#
# WHY THIS EXISTS. A pull request used to reach this check only through `pr=` in
# state/<id>.meta, and AGENTS.md section 7 makes writing that key firstmate's
# own remembered action at the moment a pull request appears. So the detector
# built because firstmate forgets was fed by a step firstmate has to remember,
# and it was blind to exactly the pull request nobody registered - while "no
# reviewer dispatched on any open pull request" is one of the recorded misses
# it exists to answer. A check that holds only when someone notices is not held.
#
# The forge is asked instead, by the one thing the task cannot be without: its
# own branch. bin/fm-spawn.sh writes `worktree=` when it creates the task, and
# the branch and the origin remote are read out of that worktree, so the chain
# is task creation rather than a remembered follow-up action.
#
# It runs ONLY for a task whose records name no pull request at all - neither
# `pr=` nor its armed poll's sidecar - because a task that has one is already
# visible and asking again would buy no coverage. Cost is one
# `gh pr list --head` for such a task, measured 0.67 and 0.74 seconds against
# BenjaminLu/firstmate on 2026-09-20.
#
# A worktree still on a detached HEAD has no branch, so no pull request of this
# task's work can exist yet: that is a determinate "none", not an unknown, and
# it stays silent - but only once the repository itself has answered, because a
# directory that is not a repository, a repository whose .git cannot be read,
# and a read that hits its bound all refuse the branch read the same way a
# detached HEAD does. Each of those, a recorded worktree that is gone, a remote
# that is not a GitHub one, and a forge read that fails are undeterminable and
# say so, because each of them hides whether a pull request is sitting there
# unreviewed.
# Every remote of the worktree except origin, as a readable list. Local only.
# Returns git_read's own statuses so the caller can tell "there are none" from
# "the list could not be read".
discovery_other_remotes() {
  local wt=$1 status
  git_read "$wt" remote
  status=$?
  case "$status" in
    "$GIT_READ_OK") ;;
    # No remote at all is not possible here - origin was just read - so a clean
    # refusal means git answered with an empty list, which is the same "none".
    "$GIT_READ_REFUSED") printf ''; return "$GIT_READ_OK" ;;
    *) return "$status" ;;
  esac
  printf '%s' "$GIT_OUT" | grep -v '^origin$' | grep -v '^[[:space:]]*$' \
    | awk '{ if (out != "") out = out ", "; out = out $0 } END { printf "%s", out }'
  return "$GIT_READ_OK"
}

discover_task_pull_request() {
  local id=$1 meta=$2 wt branch slug remote other_remotes
  wt=$(meta_value "$meta" worktree)
  if [ -z "$wt" ]; then
    unknown "$id records no worktree, so whether it has a pull request of its own could not be established"
    return 0
  fi
  if [ ! -d "$wt" ]; then
    unknown "$id's worktree $wt is not there, so whether it has a pull request of its own could not be established"
    return 0
  fi
  # Establish that the worktree is a readable repository BEFORE reading its
  # branch, because otherwise the two answers arrive down one channel.
  # symbolic-ref refuses identically for a detached HEAD, for a directory that
  # is not a repository, and for a repository whose .git cannot be read, and
  # only the first of those means "this task has not branched, so it can have
  # no pull request". Reading the other two that way reported an input this
  # check could not read as an obligation met - including a worktree on a
  # stalled mount, which is the case LOCAL_READ_SECS exists for: it did not
  # hang the sweep, it reported the stall as "no pull request exists", which is
  # worse.
  git_read "$wt" rev-parse --git-dir
  case "$?" in
    "$GIT_READ_OK") ;;
    "$GIT_READ_BUDGET_SPENT") budget_note; return 0 ;;
    "$GIT_READ_UNESTABLISHED")
      unknown "$id's worktree $wt did not answer in time, so whether it has a pull request of its own could not be established"
      return 0
      ;;
    *)
      unknown "$id's worktree $wt is not a readable git repository, so whether it has a pull request of its own could not be established"
      return 0
      ;;
  esac
  git_read "$wt" symbolic-ref --quiet --short HEAD
  case "$?" in
    "$GIT_READ_OK") branch=$GIT_OUT ;;
    "$GIT_READ_REFUSED")
      # The repository answered and said it has no branch. bin/fm-brief.sh
      # starts every task at a detached HEAD and the worker creates its branch,
      # so this is a task that has not branched yet and therefore cannot have a
      # pull request - a determinate none, established rather than assumed
      # because the repository read above succeeded.
      return 0
      ;;
    "$GIT_READ_BUDGET_SPENT") budget_note; return 0 ;;
    *)
      unknown "the branch of $id's worktree $wt could not be read, so whether it has a pull request of its own could not be established"
      return 0
      ;;
  esac
  git_read "$wt" remote get-url origin
  case "$?" in
    "$GIT_READ_OK") remote=$GIT_OUT ;;
    "$GIT_READ_BUDGET_SPENT") budget_note; return 0 ;;
    *)
      unknown "$id's worktree has no readable origin, so whether it has a pull request of its own could not be established"
      return 0
      ;;
  esac
  if ! slug=$(github_slug_from_remote "$remote"); then
    unknown "$id's origin $remote is not a GitHub remote, and this check reads GitHub only"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    unknown "gh is not installed, so whether $id has a pull request of its own could not be established"
    return 0
  fi
  if ! budget_allows; then
    budget_note
    return 0
  fi
  if ! run_gh pr list --repo "$slug" --head "$branch" --state open --limit 1 \
    --json url --jq '.[0].url // ""'; then
    unknown "the open pull requests for $id's branch $branch could not be read: $FORGE_ERROR"
    return 0
  fi
  if [ -n "$GH_OUT" ]; then
    add_target "$GH_OUT" discovered "$id"
    return 0
  fi
  # An empty answer is the forge saying this branch has no open pull request in
  # ORIGIN. That is absence proved against one repository, and reporting it as
  # absence everywhere is silence rather than a determinate none whenever the
  # branch could have been proposed somewhere else.
  #
  # The fork-plus-upstream clone is ordinary here - bin/fm-brief.sh and
  # bin/fm-teardown.sh both say so - and in that flow the branch is on origin
  # while the pull request is on the parent. Asking the parent too would add a
  # second forge read per such task, and the cost model is the thing this check
  # argued hardest for, so it is not asked. What is not acceptable is the gap
  # being invisible: unlike the GitLab and jq gaps, which each produce an
  # unknown line, this one produced SILENCE, and silence is the whole product.
  # So the remotes are listed - a local read, no forge call - and the gap is
  # reported whenever there is somewhere else this branch could have gone.
  other_remotes=$(discovery_other_remotes "$wt")
  case "$?" in
    "$GIT_READ_BUDGET_SPENT") budget_note; return 0 ;;
    "$GIT_READ_UNESTABLISHED")
      unknown "$id's branch $branch has no open pull request in $slug, and its other remotes could not be listed, so whether it has one elsewhere could not be established"
      return 0
      ;;
  esac
  [ -n "$other_remotes" ] || return 0
  unknown "$id's branch $branch has no open pull request in $slug, but the worktree also has $other_remotes, and only origin was asked"
}

collect_task_targets() {
  local id meta poll url poll_url head
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    meta="$STATE/$id.meta"
    readable_file "$meta" || continue

    # The armed poll is bound by its sidecar, so the sidecar's own URL is what
    # that poll actually watches - not necessarily what the metadata now says.
    # It is read FIRST because it is the task's second record of its own pull
    # request: consulted afterwards, a task whose poll named its pull request
    # still spent a discovery call, and the finding then said its records do
    # not name it, which points firstmate at the wrong repair.
    #
    # A sidecar that is present but cannot be read, or that does not carry the
    # URL where its own format puts it, is an input this check cannot read -
    # never an obligation met. The poll is still armed and still watching; what
    # cannot be established is whether it is bound to the right commit, and
    # polls left on superseded commits are the exact miss obligation 2 exists
    # for. bin/fm-pr-poll.sh owns the sidecar's format; only its presence and
    # its second line are read here.
    poll_url=
    poll="$STATE/$id.pr-poll"
    if [ -e "$poll" ] || [ -L "$poll" ]; then
      if ! readable_file "$poll"; then
        unknown "the merge poll record for $id cannot be read, so whether it still watches the right commit could not be established"
      else
        poll_url=$(sed -n '2p' "$poll" 2>/dev/null)
        if [ -z "$poll_url" ]; then
          unknown "the merge poll record for $id names no pull request, so whether it still watches the right commit could not be established"
        fi
      fi
    fi

    url=$(meta_value "$meta" pr)
    if [ -n "$url" ]; then
      add_target "$url" taskpr "$id"
    elif [ -n "$poll_url" ]; then
      add_target "$poll_url" taskpr "$id"
    else
      discover_task_pull_request "$id" "$meta"
    fi

    [ -n "$poll_url" ] || continue
    head=$(meta_value "$meta" pr_head)
    add_target "$poll_url" poll "$id" "$head"
  done <<< "$LIVE_TASKS"
}

# The board's Captain's Call cards, read out of the injected payload in the
# built page. bin/fm-bearings-board.sh owns writing that payload; this only
# reads the pull request each open call is about.
collect_board_targets() {
  local payload key url line
  [ -e "$BOARD" ] || return 0
  readable_file "$BOARD" || { unknown "the board at $BOARD cannot be read"; return 0; }
  payload=$(sed -n "/$(printf '%s' "$BOARD_ANCHOR" | sed 's/[\/&]/\\&/g')/,/<\/script>/p" "$BOARD" 2>/dev/null \
    | sed '1d;$d')
  if [ -z "$payload" ]; then
    unknown "the board at $BOARD carries no readable payload"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    unknown "jq is not installed, so the board's open calls cannot be read"
    return 0
  fi
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    unknown "the board's payload at $BOARD is not readable JSON"
    return 0
  fi
  while IFS=$'\t' read -r key url; do
    [ -n "$url" ] || continue
    add_target "$url" card "${key:-unnamed}"
  done < <(printf '%s' "$payload" \
    | jq -r '.captains_call[]? | select(.pr_url != null and .pr_url != "") | [(.key // "unnamed"), .pr_url] | @tsv' 2>/dev/null)
}

# --- forge resolution -------------------------------------------------------

# One line per resolved pull request, keyed by the canonical identity rather
# than by any URL string:
#   <key> <TAB> <state> <TAB> <head> <TAB> <reviews> <TAB> <comments>
RESOLVED=
# Every key resolve_targets already reported a reason for, so evaluate_targets
# does not report a second, vaguer line for the same pull request.
UNRESOLVED_REPORTED=

resolved_line() {
  printf '%s' "$RESOLVED" | awk -F'\t' -v k="$1" '$1 == k { print; exit }'
}

reason_already_reported() {
  printf '%s' "$UNRESOLVED_REPORTED" | grep -qxF "$1"
}

note_unresolved() {
  UNRESOLVED_REPORTED="$UNRESOLVED_REPORTED$1
"
}

# The distinct pull requests to ask about: <key> <TAB> <url> <TAB> <slug> <TAB>
# <number>, one line per canonical identity.
target_reads() {
  printf '%s' "$TARGETS" \
    | awk -F'\t' 'NF >= 5 && $1 != "-" { print $1 "\t" $2 "\t" $3 "\t" $4 }' \
    | sort -u -t"$(printf '\t')" -k1,1
}

GH_MISSING=0

# One bounded gh call. The answer lands in GH_OUT and the reason for a failure
# in FORGE_ERROR, both assigned in the caller's own shell.
#
# It does NOT print its answer for a caller to capture. A caller writing
# `out=$(run_gh ...)` runs the whole function in a command substitution, so its
# FORGE_ERROR assignment lands in a subshell that dies with it and the parent
# reads an empty reason - which is how every failure came out as "could not be
# read:" with nothing after the colon, leaving firstmate unable to tell a rate
# limit from a broken token from a network outage. Assigning GH_OUT keeps the
# command substitution around gh itself, where only gh's output crosses.
#
# gh's own first line of stderr is carried into the reason, because "the forge
# refused the read" alone does not say which of those three it was.
FORGE_ERROR=
GH_OUT=
run_gh() {
  local bound status errfile detail
  FORGE_ERROR=
  GH_OUT=
  bound=$(call_bound)
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-obligation-gh.XXXXXX" 2>/dev/null) || {
    FORGE_ERROR="no temporary file could be created for the forge read"
    return 1
  }
  GH_OUT=$(fm_run_timed "$bound" gh "$@" 2>"$errfile")
  status=$?
  detail=$(head -n 1 "$errfile" 2>/dev/null | tr '\t\r\n' '   ')
  rm -f -- "$errfile"
  case "${#detail}" in
    0) ;;
    *) [ "${#detail}" -le 200 ] || detail="${detail:0:200}..." ;;
  esac
  if [ "$status" -eq 124 ]; then
    FORGE_ERROR="the forge did not answer within ${bound}s"
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    if [ -n "$detail" ]; then
      FORGE_ERROR="the forge refused the read: $detail"
    else
      FORGE_ERROR="the forge refused the read"
    fi
    return 1
  fi
  return 0
}

# One pull request, named explicitly by repository and number.
#
# WHY NOT ONE LISTING PER REPOSITORY. A single `gh pr list` carrying these same
# fields answers every open pull request in a repository at once, and against a
# small one it is cheaper: measured 0.62, 0.62 and 0.68 seconds for the three
# open pull requests of BenjaminLu/firstmate on 2026-09-20, against 0.59 and
# 0.60 seconds for one `gh pr view`. It stops being cheaper as the repository
# grows, and the growth is not this home's to control: the same listing against
# cli/cli, 63 open pull requests, measured 3.38 and 3.16 seconds for a 200 KB
# payload, because asking for reviews and comments asks for them on every open
# pull request there rather than on the handful this home is watching. A
# firstmate home clones upstream projects, so a listing would let somebody
# else's busy repository set this check's cost and eventually spend its whole
# budget. Reading exactly the pull requests of interest keeps the cost
# proportional to this home's own work, and it is also exact: a listing needs a
# --limit, and past that limit absence stops being proof of anything.
view_pull_request() {
  local key=$1 slug=$2 number=$3
  run_gh pr view "$number" --repo "$slug" \
    --json state,headRefOid,reviews,comments \
    --jq '[.state, (.headRefOid // "-"), ((.reviews // []) | length | tostring), ((.comments // []) | length | tostring)] | @tsv' \
    || return 1
  # An exit status of 0 with nothing on stdout resolves nothing, and treating it
  # as a completed read would leave the pull request silently unaccounted for.
  if [ -z "$GH_OUT" ]; then
    FORGE_ERROR="the forge answered with nothing"
    return 1
  fi
  RESOLVED="$RESOLVED$key	$GH_OUT
"
  return 0
}

budget_note() {
  [ "$BUDGET_REPORTED" -eq 0 ] || return 0
  BUDGET_REPORTED=1
  unknown "the time budget ran out before the rest of the forge reads"
}

resolve_targets() {
  local key url slug number

  [ -n "$(target_reads)" ] || return 0

  if ! command -v gh >/dev/null 2>&1; then
    GH_MISSING=1
    return 0
  fi

  # The list is unique by canonical identity, so a pull request that is a task's
  # own, an armed poll's, and a board card's - however each record spells it -
  # costs one read, not three.
  while IFS=$'\t' read -r key url slug number; do
    [ -n "$key" ] || continue
    if ! budget_allows; then
      budget_note
      break
    fi
    if ! view_pull_request "$key" "$slug" "$number"; then
      unknown "$url could not be read: $FORGE_ERROR"
      note_unresolved "$key"
    fi
  done < <(target_reads)
}

# --- obligations 1, 2 and 3 -------------------------------------------------

short_sha() {
  case "$1" in
    ?????????*) printf '%s\n' "${1:0:9}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

evaluate_targets() {
  local key url slug number role owner extra line pr_state head reviews comments

  while IFS=$'\t' read -r key url slug number role owner extra; do
    [ -n "$url" ] || continue
    if [ "$key" = - ]; then
      unknown "$url is not a GitHub pull request, and this check reads GitHub only"
      continue
    fi
    if [ "$GH_MISSING" -eq 1 ]; then
      unknown "gh is not installed, so $url could not be read"
      continue
    fi
    line=$(resolved_line "$key")
    if [ -z "$line" ]; then
      # A target with no live state is undeterminable, never met. When
      # resolve_targets already said why, that stands; when it did not - the
      # budget broke out of the loop before reaching this one - the pull
      # request is named here so it is not swallowed by the aggregate.
      reason_already_reported "$key" \
        || unknown "$url was not read, so its obligations could not be established"
      continue
    fi
    IFS=$'\t' read -r _ pr_state head reviews comments <<< "$line"

    case "$role" in
      taskpr|discovered)
        [ "$pr_state" = OPEN ] || continue
        [ "${reviews:-0}" = 0 ] && [ "${comments:-0}" = 0 ] || continue
        if [ "$role" = discovered ]; then
          # Say where it came from: the task's own records not naming it is
          # itself something for firstmate to fix.
          owed "nothing posted on $url (task $owner, which its own records do not name): no review and no comment"
        else
          owed "nothing posted on $url (task $owner): no review and no comment"
        fi
        ;;
      poll)
        if [ "$pr_state" = CLOSED ]; then
          owed "the merge poll for $owner watches $url, which is closed unmerged, so it can never fire"
          continue
        fi
        [ "$pr_state" = OPEN ] || continue
        [ -n "$extra" ] || continue
        [ "$head" != - ] && [ -n "$head" ] || continue
        [ "$extra" != "$head" ] || continue
        owed "the recorded head for $owner is $(short_sha "$extra") but $url is at $(short_sha "$head")"
        ;;
      card)
        [ "$pr_state" != OPEN ] || continue
        owed "the board still shows $owner as an open call, but $url is $(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
        ;;
    esac
  done < <(printf '%s' "$TARGETS")
}

# --- report record ----------------------------------------------------------

# Two clocks, because they answer two different questions and sharing one made
# the first of them never engage. `epoch` is when the forge was last PROBED and
# is written after every completed sweep, including a silent one - it is what
# the no-probe interval reads. `reported_at` is when a report was last PRINTED
# and moves only when one is; it is what the repeat horizon reads, so a silent
# sweep can no longer push a suppressed repeat another interval into the future.
#
# Sharing one field meant the record was written only when the finding set
# changed, and on a home where everything is met the set is empty every sweep,
# never changes, and so the record was never written at all: the gate read a
# zero epoch forever and the forge was read on every single watcher sweep. That
# is the steady state - the healthy home - paying the full cost permanently.
RECORD_EPOCH=0
RECORD_REPORTED_AT=0
RECORD_OWED_LOCAL=
RECORD_UNKNOWN_LOCAL=
RECORD_OWED_FORGE=
RECORD_UNKNOWN_FORGE=

# The record keeps each finding list separately rather than one rendered
# string, one finding per line under a repeated key. flatten() guarantees no
# finding holds a newline, so this round-trips exactly with no escaping and no
# separator a finding could itself contain. The forge lists are kept apart from
# the local ones so a sweep inside the no-probe interval can carry the forge
# half forward untouched instead of recomputing or discarding it.
# Why the record could not be used, empty when it was. `check` treats every one
# of these the same way - as a home it has no previous reading for, which is
# correct there because it is about to take a fresh one - but `report` takes no
# reading of its own, so it has to say which of them happened instead of
# answering for a record it never read.
RECORD_UNUSABLE=

record_read() {
  local line first=1 saw_epoch=0
  RECORD_EPOCH=0
  RECORD_REPORTED_AT=0
  RECORD_OWED_LOCAL=
  RECORD_UNKNOWN_LOCAL=
  RECORD_OWED_FORGE=
  RECORD_UNKNOWN_FORGE=
  RECORD_UNUSABLE=
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    RECORD_UNUSABLE="no check has recorded a reading for this home yet"
    return 0
  fi
  if ! readable_file "$RECORD"; then
    RECORD_UNUSABLE="the record at $RECORD cannot be read"
    return 0
  fi
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      if [ "$line" != "$RECORD_SCHEMA" ]; then
        RECORD_UNUSABLE="the record at $RECORD is not a $RECORD_SCHEMA record"
        return 0
      fi
      continue
    fi
    case "$line" in
      epoch=*)
        saw_epoch=1
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      reported_at=*)
        line=${line#reported_at=}
        case "$line" in
          ''|*[!0-9]*) RECORD_REPORTED_AT=0 ;;
          *) RECORD_REPORTED_AT=$line ;;
        esac
        ;;
      owed_local=*) RECORD_OWED_LOCAL="$RECORD_OWED_LOCAL${line#owed_local=}
" ;;
      unknown_local=*) RECORD_UNKNOWN_LOCAL="$RECORD_UNKNOWN_LOCAL${line#unknown_local=}
" ;;
      owed_forge=*) RECORD_OWED_FORGE="$RECORD_OWED_FORGE${line#owed_forge=}
" ;;
      unknown_forge=*) RECORD_UNKNOWN_FORGE="$RECORD_UNKNOWN_FORGE${line#unknown_forge=}
" ;;
    esac
  done < "$RECORD"
  # A record is a READING, not a header. Accepting any file whose first line is
  # the schema meant a file carrying only that line read as "all four met" - so
  # the epoch line record_write always writes is what makes it a reading. This
  # covers the empty file too, which has no lines at all.
  [ "$saw_epoch" = 1 ] || RECORD_UNUSABLE="the record at $RECORD carries no reading"
  return 0
}

# record_write <epoch> <reported_at>: both clocks are passed, because a sweep
# that did not reach the forge must leave the probe clock where it was or the
# no-probe interval would never reopen, while still recording the local half it
# did evaluate.
record_write() {
  local epoch=$1 reported_at=$2 tmp finding
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$epoch"
    printf 'reported_at=%s\n' "$reported_at"
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      printf 'owed_local=%s\n' "$finding"
    done <<< "$OWED_LOCAL"
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      printf 'unknown_local=%s\n' "$finding"
    done <<< "$UNKNOWN_LOCAL"
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      printf 'owed_forge=%s\n' "$finding"
    done <<< "$OWED_FORGE"
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      printf 'unknown_forge=%s\n' "$finding"
    done <<< "$UNKNOWN_FORGE"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- the printed line -------------------------------------------------------

# Cut by whole findings with a count, never mid-finding. A blind character cut
# can leave the line ending inside a finding, which hides both that finding and
# every one after it behind one marker; a count plus the `report` action says
# exactly how much is not shown and where to read it. The disclosure itself is
# reserved out of the budget before any finding is added, so the count can
# never be the thing that does not fit.
DISCLOSURE_RESERVE=64

compose_line() {
  local body='obligations' total shown=0 remaining segment list finding candidate
  total=$(( $(count_findings "$(all_owed)") + $(count_findings "$(all_unknown)") ))
  [ "$total" -gt 0 ] || { printf '%s' ''; return 0; }

  for segment in owed unknown; do
    if [ "$segment" = owed ]; then list=$(all_owed); else list=$(all_unknown); fi
    [ -n "$list" ] || continue
    local first=1
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      if [ "$first" = 1 ]; then
        # " | " between the two segments, so owed and unknown never run
        # together into one sentence the reader has to separate by eye.
        [ "$shown" -eq 0 ] && candidate="$body $segment: $finding" \
          || candidate="$body | $segment: $finding"
      else
        candidate="$body; $finding"
      fi
      if [ "${#candidate}" -gt $((MAX_LINE - DISCLOSURE_RESERVE)) ]; then
        remaining=$((total - shown))
        body="$body (+$remaining more; run: bin/fm-obligation-check.sh report)"
        printf '%s' "$body"
        return 0
      fi
      body=$candidate
      first=0
      shown=$((shown + 1))
    done <<< "$list"
  done
  printf '%s' "$body"
}

# --- actions ----------------------------------------------------------------

action_check() {
  local now line age changed=0 gated=0 epoch

  record_read
  fm_now now
  # The interval gates the FORGE and nothing else. Obligation 4 and the task
  # records it reads cost no forge call, so they are evaluated on every sweep;
  # rate-limiting them behind a limit for a resource they do not use delayed an
  # owed obligation by up to a whole interval for no saving at all.
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    gated=1
  fi

  if [ ! -d "$STATE" ]; then
    printf 'obligations unknown: this home has no state directory at %s, so nothing could be checked\n' "$STATE"
    return 0
  fi

  DEADLINE=$((now + BUDGET_SECS))

  FINDING_SCOPE=local
  collect_live_tasks
  check_design_records

  FINDING_SCOPE=forge
  if [ "$gated" -eq 0 ]; then
    [ -z "$BUDGET_CUT_FROM" ] \
      || unknown "the sweep budget ${BUDGET_CUT_FROM}s was cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
    collect_task_targets
    collect_board_targets
    resolve_targets
    evaluate_targets
    epoch=$now
  else
    # The forge half is carried forward exactly as the last sweep that reached
    # the forge left it, so a gated sweep neither re-reports it as news nor
    # drops it from the record.
    OWED_FORGE=$RECORD_OWED_FORGE
    UNKNOWN_FORGE=$RECORD_UNKNOWN_FORGE
    epoch=$RECORD_EPOCH
  fi

  [ "$OWED_LOCAL" = "$RECORD_OWED_LOCAL" ] && [ "$UNKNOWN_LOCAL" = "$RECORD_UNKNOWN_LOCAL" ] \
    && [ "$OWED_FORGE" = "$RECORD_OWED_FORGE" ] && [ "$UNKNOWN_FORGE" = "$RECORD_UNKNOWN_FORGE" ] \
    || changed=1

  line=
  if [ -n "$(all_owed)" ] || [ -n "$(all_unknown)" ]; then
    line=$(compose_line)
  fi

  # The whole finding set decides whether this is news, not the cut line: a
  # finding that lands past the cut leaves the printed line unchanged and would
  # otherwise be suppressed for good. An unchanged set still reports again once
  # the last report has aged past the repeat horizon, because an acknowledged
  # wake is not a discharged obligation.
  age=$((now - RECORD_REPORTED_AT))
  if [ -n "$line" ] \
    && { [ "$changed" -eq 1 ] || [ "$RECORD_REPORTED_AT" -eq 0 ] \
      || { [ "$REPEAT" -ne 0 ] && [ "$age" -ge "$REPEAT" ]; }; }; then
    # Report before recording, so a record that cannot be written costs a
    # repeated report rather than a lost one.
    printf '%s\n' "$line"
    record_write "$epoch" "$now" || true
    return 0
  fi
  # Nothing printed. A sweep that reached the forge moves the probe clock so
  # the no-probe interval engages - including on a home where everything is
  # met, which is the case that runs most - while a gated sweep passes the old
  # one straight back. The report clock is carried forward untouched either
  # way, so a suppressed repeat still arrives on time.
  record_write "$epoch" "$RECORD_REPORTED_AT" || true
  return 0
}

action_report() {
  local finding printed=0
  record_read
  # This action exists to show what the one-line cut hid, so answering "all
  # four met" for a record it could not use inverts the one sentence this
  # check sells - and every home already running an earlier version holds a
  # record of the previous schema the moment a new one lands.
  if [ -n "$RECORD_UNUSABLE" ]; then
    printf 'no findings could be read: %s\n' "$RECORD_UNUSABLE"
    printf 'run: bin/fm-obligation-check.sh check\n'
    return 0
  fi
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    [ "$printed" -eq 1 ] || printf 'owed:\n'
    printed=1
    printf '  - %s\n' "$finding"
  done <<< "$RECORD_OWED_LOCAL$RECORD_OWED_FORGE"
  printed=0
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    [ "$printed" -eq 1 ] || printf 'unknown:\n'
    printed=1
    printf '  - %s\n' "$finding"
  done <<< "$RECORD_UNKNOWN_LOCAL$RECORD_UNKNOWN_FORGE"
  if [ -z "$RECORD_OWED_LOCAL$RECORD_OWED_FORGE" ] \
    && [ -z "$RECORD_UNKNOWN_LOCAL$RECORD_UNKNOWN_FORGE" ]; then
    printf 'the last check found all four obligations met\n'
  fi
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-obligation-check.sh - fleet obligation poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-obligation-check.sh") check"
}

SHIM_WRITE_TMP=

# The guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-fleet-obligations-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim already in place, so a failed arm puts back what a
# working home was using rather than an equivalent rewrite.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-fleet-obligations-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-obligation-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

# Something this check could report on: a live task, or a board page. Used only
# by `arm --if-needed`; the check itself always looks at everything.
home_has_something_to_report_on() {
  local meta
  [ ! -e "$BOARD" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] && return 0
  done
  return 1
}

action_arm() {
  local want home
  if [ "${1:-}" = --if-needed ]; then
    home_has_something_to_report_on || return 0
  elif [ "$#" -gt 0 ]; then
    die_usage "unknown arm option: $1"
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-obligation-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-obligation-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-obligation-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-obligation-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

# Retirement goes through the named owner rather than a hand-composed rm, which
# AGENTS.md section 7 forbids; only this script's own report record is removed
# here.
action_disarm() {
  local status=0
  if [ -e "$CHECK_SHIM" ] || [ -e "$STATE/$CHECK_ID.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || status=$?
    if [ "$status" -ne 0 ]; then
      printf 'fm-obligation-check: could not retire state/%s.check.sh\n' "$CHECK_ID" >&2
      return 1
    fi
  fi
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  printf 'note: the next locked bootstrap arms it again while this home has a task or a board\n'
  return 0
}

# Sourced late: fm-check-lib.sh needs fm-pr-lib.sh, which is already in scope.
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

case "${1:-check}" in
  check) action_check ;;
  report) action_report ;;
  arm) shift; action_arm "$@" ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
