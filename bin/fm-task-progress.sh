#!/usr/bin/env bash
# fm-task-progress.sh - structured progress projection for ONE task.
#
# Usage: fm-task-progress.sh <task-id>
#
# Prints one fm-task-progress.v1 JSON document on stdout. It answers "how far
# along is this worker" from STRUCTURED STATE ONLY: bin/fm-crew-state.sh for the
# phase (which owns every run-attribution, pane, and status-log rule, and is the
# single authority for the state word), and the attributed no-mistakes run's own
# `steps[]` / `active_steps[]` tables for the validation ladder. A worker's
# terminal is never read here, and no prose is interpreted.
#
# Exit status is 0 whenever a document could be printed, including the honest
# "nothing is attributable" document; 2 is a usage error. Read-only and side
# effect free.
#
# Document:
#   schema           fm-task-progress.v1
#   id               the task id
#   generated        UTC RFC3339 second when this projection was read - the
#                    refreshed-at a renderer shows beside the row
#   generated_epoch  the same instant as epoch seconds
#   state            bin/fm-crew-state.sh's state word (working, parked, done,
#                    blocked, paused, failed, unknown)
#   source           its source word (run-step, pane, status-log,
#                    remote-endpoint, none)
#   detail           its detail text, or "" when it reported none
#   run              null when no no-mistakes run is attributed to this task's
#                    branch, else:
#     id             the attributed run id
#     status         the run's own status word
#     step           the step currently running or fixing, or null
#     steps[]        {step, status} in ledger order - the ladder, so the passed
#                    steps are visible beside the one under way
#     active_for     how long the current step has run (the pipeline's own
#                    duration word, e.g. "12m3s"), or null
#     last_activity  the active step's whole last-activity message, exactly as
#                    the pipeline's own last_activity column words it - its age
#                    and the line together, e.g.
#                    "2h58m ago: log: all CI checks passed" - or null. The
#                    pipeline prefixes that column with `quiet` once nothing
#                    has arrived for longer than its configured warning; the
#                    prefix alone is stripped here and reported as the quiet
#                    flag, and the message itself is never cut down
#     quiet          true when the pipeline flagged that activity as quiet
#     activity       the active step's own round text (e.g. "auto-fix 1/3"),
#                    from the pipeline's `round` column, or null
#
# Only a ship task can own a validation run, so a scout or secondmate row
# reports run: null without asking the pipeline anything. A selected run is
# used only after the identity proofs bin/fm-nm-run-lib.sh requires of its
# callers - the same ones bin/fm-crew-state.sh applies - so a run whose id,
# branch, status class or code identity cannot be established yields no ladder
# rather than an unproven one.
#
# Bounds: the crew-state read and each no-mistakes read are bounded by
# FM_TASK_PROGRESS_TIMEOUT (default 20) and FM_TASK_PROGRESS_NM_TIMEOUT
# (default 10) seconds respectively, so one unresponsive pipeline cannot hold a
# board refresh open. A bound that trips degrades that part of the document to
# unknown or null rather than failing the read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-nm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

PROGRESS_SCHEMA=fm-task-progress.v1
TIMEOUT=${FM_TASK_PROGRESS_TIMEOUT:-20}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=20 ;; esac
NM_TIMEOUT=${FM_TASK_PROGRESS_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*|0) NM_TIMEOUT=10 ;; esac

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

case "${1-}" in
  -h|--help|help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
ID=$1
shift
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

META=${FM_TASK_PROGRESS_META_OVERRIDE:-"$STATE/$ID.meta"}

meta_value() {  # <key>
  [ -f "$META" ] || return 0
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

strip_quotes() {
  local s=${1:-}
  case "$s" in \"*\") s=${s#\"}; s=${s%\"} ;; esac
  printf '%s' "$s"
}

# --- phase: bin/fm-crew-state.sh owns every classification rule -------------

SEP=' · '
STATE_WORD=unknown
STATE_SOURCE=none
STATE_DETAIL=

read_phase() {
  local raw rest
  raw=$(
    fm_run_timed "$TIMEOUT" \
      env FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  case "$raw" in
    state:\ *"$SEP"source:\ *)
      rest=${raw#state: }
      STATE_WORD=${rest%%"$SEP"source: *}
      rest=${rest#*"$SEP"source: }
      case "$rest" in
        *"$SEP"*) STATE_SOURCE=${rest%%"$SEP"*}; STATE_DETAIL=${rest#*"$SEP"} ;;
        *) STATE_SOURCE=$rest ;;
      esac
      ;;
  esac
}

# --- ladder: the attributed run's own step tables ---------------------------
# One awk program reads a named TOON table out of captured `axi status` output
# and prints it as a JSON array. The header names the columns, so column ORDER
# is never assumed, exactly as bin/fm-crew-state.sh's readers require. Rows are
# comma separated with optional double-quoted fields.

toon_table_json() {  # <axi-status-output> <table-name>
  printf '%s\n' "$1" | awk -v want="$2" '
    function jesc(s,   out, i, ch) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "\"" || ch == "\\") out = out "\\" ch
        else if (ch == "\t") out = out "\\t"
        else if (ch < " ") out = out " "
        else out = out ch
      }
      return out
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # A TOON quoted field is json.dumps-encoded, so a backslash escapes the
    # character after it: a field carrying a log line with its own quotes and
    # commas is one field, not several. This is the same state machine
    # row_fields keeps in bin/fm-nm-run-lib.sh, and it yields decoded fields -
    # the delimiters and their escapes are consumed here, never handed on.
    # An unterminated quote or a trailing escape means the row cannot be read,
    # and 0 fields says so rather than inventing column boundaries.
    function split_row(s, out,   i, ch, n, quoted, escaped) {
      for (i in out) delete out[i]
      n = 1; out[n] = ""; quoted = 0; escaped = 0
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (escaped) { out[n] = out[n] ch; escaped = 0 }
        else if (quoted && ch == "\\") escaped = 1
        else if (ch == "\"") quoted = !quoted
        else if (!quoted && ch == ",") { n++; out[n] = "" }
        else out[n] = out[n] ch
      }
      if (quoted || escaped) return 0
      for (i = 1; i <= n; i++) out[i] = trim(out[i])
      return n
    }
    BEGIN { printf "[" ; first = 1 }
    {
      if (!inblock) {
        if ($0 ~ "^[ \t]*" want "\\[[0-9]+\\]\\{") {
          hdr = index($0, want)
          cols = $0
          sub(/^[^{]*\{/, "", cols)
          sub(/\}.*$/, "", cols)
          ncols = split_row(cols, colname)
          inblock = 1
        }
        next
      }
      if ($0 ~ /^[ \t]*$/) { inblock = 0; next }
      match($0, /[^ \t]/)
      if (RSTART <= hdr) { inblock = 0; next }
      nf = split_row(trim($0), field)
      if (nf == 0) next
      printf "%s{", (first ? "" : ",")
      first = 0
      for (i = 1; i <= ncols; i++) {
        printf "%s\"%s\":\"%s\"", (i > 1 ? "," : ""), jesc(colname[i]), \
          jesc(i <= nf ? field[i] : "")
      }
      printf "}"
    }
    END { printf "]\n" }
  '
}

# The run attributed to this task, or empty. Selection is
# fm-nm-run-lib.sh's - this script adds no attribution rule of its own, and an
# ambiguous or unverifiable selection deliberately yields no ladder rather than
# a guessed one.
RUN_JSON=null

# What bin/fm-nm-run-lib.sh requires of every caller before it may use a
# selected run's steps: fetch the full status BY ID, then prove branch and head
# or active pipeline custody. bin/fm-crew-state.sh applies exactly these proofs
# to exactly this selection; the primitives are the library's, so there is one
# attribution rule in the repo rather than a second one here. An unproven
# identity means NO ladder: a run that finished on code this worktree has moved
# past would otherwise render as nine passed steps beside a worker mid-rework.
run_verified() {  # <worktree> <branch> <selected-id> <selected-status> <status-toon>
  local wt=$1 branch=$2 selected_id=$3 selected_status=$4 run_out=$5 run_class
  [ "$(strip_quotes "$(fm_nm_field "$run_out" id)")" = "$selected_id" ] || return 1
  [ "$(strip_quotes "$(fm_nm_field "$run_out" branch)")" = "$branch" ] || return 1
  case "$(strip_quotes "$(fm_nm_field "$run_out" status)")" in
    pending|running|fixing|ci|awaiting_approval|fix_review|completed|failed|cancelled) ;;
    *) return 1 ;;
  esac
  if fm_nm_run_is_active "$run_out"; then run_class=live; else run_class=terminal; fi
  [ "$(fm_nm_run_status_class "$selected_status")" = "$run_class" ] || return 1
  fm_nm_head_matches_worktree "$wt" "$(strip_quotes "$(fm_nm_field "$run_out" head)")" \
    || fm_nm_run_is_pipeline_owned_active "$run_out"
}

read_run() {
  local wt kind branch overview choice selected_id selected_status run_out status
  local steps active step run_class
  local active_for='' last_activity='' quiet=false activity=''
  wt=$(meta_value worktree)
  kind=$(meta_value kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 0
  [ -z "$(meta_value remote_host)" ] || return 0
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  overview=$(fm_nm_run_checked "$wt" "$NM_TIMEOUT" axi) || return 0
  [ -n "$overview" ] || return 0
  choice=$(fm_nm_select_run "$branch" "$overview" "$wt")
  case "$choice" in
    selected\|*) ;;
    *) return 0 ;;
  esac
  IFS='|' read -r _ selected_id selected_status _ <<< "$choice"
  [ -n "$selected_id" ] || return 0
  run_out=$(fm_nm_run_checked "$wt" "$NM_TIMEOUT" axi status --run "$selected_id") || return 0
  [ -n "$run_out" ] || return 0
  run_verified "$wt" "$branch" "$selected_id" "$selected_status" "$run_out" || return 0
  status=$(strip_quotes "$(fm_nm_field "$run_out" status)")
  steps=$(toon_table_json "$run_out" steps)
  active=$(toon_table_json "$run_out" active_steps)
  step=$(printf '%s' "$active" | jq -r 'if length > 0 then (.[0].step // "") else "" end' 2>/dev/null) || step=''
  if [ -z "$step" ]; then
    step=$(printf '%s' "$steps" \
      | jq -r '[.[] | select(.status == "running" or .status == "fixing")][0].step // ""' 2>/dev/null) || step=''
  fi
  if [ "$(printf '%s' "$active" | jq -r 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    active_for=$(printf '%s' "$active" | jq -r '.[0].active_for // ""')
    last_activity=$(printf '%s' "$active" | jq -r '.[0].last_activity // ""')
    activity=$(printf '%s' "$active" | jq -r '.[0].round // ""')
    case "$last_activity" in
      quiet\ *) quiet=true; last_activity=${last_activity#quiet } ;;
      quiet) quiet=true; last_activity='' ;;
    esac
  fi
  RUN_JSON=$(jq -n \
    --arg id "$selected_id" --arg status "$status" --arg step "$step" \
    --argjson steps "$steps" \
    --arg active_for "$active_for" --arg last_activity "$last_activity" \
    --argjson quiet "$quiet" --arg activity "$activity" '
    def orn: if . == "" then null else . end;
    {id: $id, status: $status, step: ($step | orn),
     steps: [$steps[] | {step: .step, status: .status}],
     active_for: ($active_for | orn), last_activity: ($last_activity | orn),
     quiet: $quiet, activity: ($activity | orn)}') || RUN_JSON=null
}

command -v jq >/dev/null 2>&1 || { printf 'fm-task-progress: jq is required\n' >&2; exit 1; }

read_phase
read_run

NOW_EPOCH=${FM_TASK_PROGRESS_NOW_EPOCH:-$(date -u +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date -u +%s) ;; esac
NOW=$(date -u -r "$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
  || NOW=$(date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
  || NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n --arg schema "$PROGRESS_SCHEMA" --arg id "$ID" --arg generated "$NOW" \
  --argjson epoch "$NOW_EPOCH" --arg state "$STATE_WORD" --arg source "$STATE_SOURCE" \
  --arg detail "$STATE_DETAIL" --argjson run "$RUN_JSON" '
  {schema: $schema, id: $id, generated: $generated, generated_epoch: $epoch,
   state: $state, source: $source, detail: $detail, run: $run}'
