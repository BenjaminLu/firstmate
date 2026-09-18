#!/usr/bin/env bash
# fm-dispatch.sh - file, brief, resolve, and spawn one crewmate or scout in a
# single call, so intake costs firstmate one tool turn instead of several.
#
# Usage:
#   fm-dispatch.sh <task-id> --project <dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> --ask <file> --spec <file> [options]
#   fm-dispatch.sh <task-id> --project <dir> --scout --ask <file> --spec <file> [options]
#   options: [--title <text>] [--kind <kind>] [--harness <name>] [--model <name>] [--effort <level>] [--backend <name>]
#
# Mechanics, in order; each step is owned by the script it calls and every
# refusal of that script is a refusal of this one, exit status and message
# unchanged:
#   1. Validate the inputs before touching anything: --ask and --spec must be
#      readable non-empty files, and the ask must not open with a Captain label
#      or address (the same spelling set bin/fm-spawn.sh refuses on a filled
#      brief; bin/fm-dod-lib.sh owns it). An existing brief whose recorded
#      "Delivery contract: mode=<mode>" line disagrees with --mode, or that
#      carries one under --scout, is refused here as a mode mismatch before any
#      record is filed.
#   2. Backlog item: when this home's automatic backlog transition gate applies
#      (bin/fm-backlog-transition-lib.sh's fm_backlog_transition_applies, the
#      same gate fm-spawn consults) and no item exists for the id, add one
#      through bin/fm-tasks-axi.sh with the title from --title or the first
#      non-blank line of --ask, and the kind from --kind (default: ship, or
#      scout under --scout). An existing item is reused as is; fm-spawn still
#      decides whether it is dispatchable. When the gate does not apply
#      (manual backend or no backlog in this home) the step is skipped and
#      says so.
#   3. Brief: scaffold data/<id>/brief.md through bin/fm-brief.sh with the same
#      --mode or --scout when it does not exist, naming the project by the
#      basename of --project. Then replace the exact `{TASK}` placeholder line
#      with the bytes of --ask and the exact `{FIRSTMATE_SPEC}` line with the
#      bytes of --spec; a file whose last byte is not a newline gets one so the
#      next heading stays on its own line. A brief that is already filled is
#      reused untouched; one still carrying a placeholder is filled in place.
#   4. Profile: when none of --harness/--model/--effort is given, run
#      bin/fm-dispatch-resolve.sh on the filled brief and, on `status: clear`,
#      pass its `profile:` flags to the spawn; any other status leaves the
#      spawn to its static resolution, and the resolver's own usage or
#      configuration error (exit 2) refuses this call. An explicit profile flag
#      is the caller's stated override and skips the resolver.
#   5. Spawn through bin/fm-spawn.sh with the explicit --mode/--yolo or --scout,
#      the profile flags, and --backend when given; its output passes through.
#      A successful call ends with `elapsed: <seconds>` for the whole run.
#
# Idempotent on re-run: a task whose item is already queued and whose brief is
# already filled reuses both and goes straight to the spawn, which is what makes
# a retry after a spawn refusal safe. Nothing here bypasses the placeholder,
# delivery-contract, backlog, or worktree-isolation checks the underlying
# scripts enforce; this script owns the sequencing, not the judgment
# (AGENTS.md section 7 owns intake).
#
# Home resolution mirrors fm-brief and fm-spawn: FM_HOME selects the home, and
# FM_DATA_OVERRIDE / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE relocate its parts;
# the underlying scripts read the same variables, so one environment addresses
# every step.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

START_MS=$(fm_timing_now_ms)

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

ID='' PROJECT='' MODE='' YOLO='' SCOUT=0 ASK='' SPEC='' TITLE='' KIND=''
HARNESS='' MODEL='' EFFORT='' BACKEND=''
MODE_SET=0 YOLO_SET=0
need() { [ $# -ge 2 ] || die "$1 requires a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need "$@"; PROJECT=$2; shift 2 ;;
    --mode) need "$@"; MODE=$2; MODE_SET=1; shift 2 ;;
    --yolo) need "$@"; YOLO=$2; YOLO_SET=1; shift 2 ;;
    --scout) SCOUT=1; shift ;;
    --ask) need "$@"; ASK=$2; shift 2 ;;
    --spec) need "$@"; SPEC=$2; shift 2 ;;
    --title) need "$@"; TITLE=$2; shift 2 ;;
    --kind) need "$@"; KIND=$2; shift 2 ;;
    --harness) need "$@"; HARNESS=$2; shift 2 ;;
    --model) need "$@"; MODEL=$2; shift 2 ;;
    --effort) need "$@"; EFFORT=$2; shift 2 ;;
    --backend) need "$@"; BACKEND=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1 (see --help)" ;;
    *) [ -z "$ID" ] || die "one task id only (got '$ID' and '$1')"; ID=$1; shift ;;
  esac
done

# ---- 1. validate before any mutation -------------------------------------------
[ -n "$ID" ] || die "task id required (see --help)"
[ -n "$PROJECT" ] || die "--project <dir> required"
[ -d "$PROJECT" ] || die "--project directory not found: $PROJECT"
if [ "$SCOUT" -eq 1 ]; then
  [ "$MODE_SET" -eq 0 ] && [ "$YOLO_SET" -eq 0 ] || die "--scout cannot be combined with --mode or --yolo; a scout delivers a report, not a merge"
else
  [ "$MODE_SET" -eq 1 ] || die "ship dispatch requires --mode <no-mistakes|direct-PR|local-only>, or pass --scout; resolve the mode at intake (AGENTS.md section 7)"
  [ "$YOLO_SET" -eq 1 ] || die "ship dispatch requires --yolo <on|off>; it is this task's merge authority (AGENTS.md section 7)"
fi
[ -n "$ASK" ] || die "--ask <file> required: the captain's own words for ## Captain's intent"
[ -n "$SPEC" ] || die "--spec <file> required: the build instructions for ## Firstmate spec"
for f in "$ASK" "$SPEC"; do
  [ -f "$f" ] && [ -r "$f" ] || die "not a readable file: $f"
  [ -n "$(tr -d '[:space:]' < "$f")" ] || die "$f is empty; both --ask and --spec must carry text, since the reviewer treats the ask as acceptance criteria"
done
if ADDRESS_LINE=$(fm_brief_intent_address_line_of_text < "$ASK"); then
  die "--ask $ASK has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address, since the brief heading already records provenance"
fi
if [ "$SCOUT" -eq 1 ]; then
  KIND=${KIND:-scout}
else
  KIND=${KIND:-ship}
fi

BRIEF="$DATA/$ID/brief.md"
BRIEF_EXISTS=0
if [ -e "$BRIEF" ]; then
  [ -f "$BRIEF" ] && [ -r "$BRIEF" ] || die "$BRIEF exists but is not a readable regular file"
  BRIEF_EXISTS=1
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  if [ "$SCOUT" -eq 1 ]; then
    [ -z "$BRIEF_MODE" ] || die "$BRIEF is a ship brief (Delivery contract: mode=$BRIEF_MODE) but this dispatch is --scout; move that brief aside or drop --scout"
  elif [ -n "$BRIEF_MODE" ] && [ "$BRIEF_MODE" != "$MODE" ]; then
    die "$BRIEF records Delivery contract: mode=$BRIEF_MODE but this dispatch passes --mode $MODE; re-scaffold the brief or pass the recorded mode"
  fi
fi

# ---- 2. backlog item ----------------------------------------------------------------
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  if fm_backlog_row_probe "$DATA" "$ID"; then
    echo "backlog: reused $ID (${FM_BACKLOG_ROW_STATE%% *})"
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    if [ -z "$TITLE" ]; then
      TITLE=$(grep -m 1 -v '^[[:space:]]*$' "$ASK" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    "$SCRIPT_DIR/fm-tasks-axi.sh" add "$ID" "$TITLE" --kind "$KIND" >/dev/null || exit $?
    echo "backlog: added $ID (queued, kind=$KIND)"
  else
    die "task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)"
  fi
else
  case $? in
    2) die "task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" ;;
    *) echo "backlog: skipped ($FM_BACKLOG_TRANSITION_SKIP)" ;;
  esac
fi

# ---- 3. brief ------------------------------------------------------------------------
PROJECT_ABS=$(CDPATH='' cd -- "$PROJECT" && pwd -P) || die "--project directory cannot be resolved: $PROJECT"
REPO=$(basename "$PROJECT_ABS")
if [ "$BRIEF_EXISTS" -eq 0 ]; then
  if [ "$SCOUT" -eq 1 ]; then
    "$SCRIPT_DIR/fm-brief.sh" "$ID" "$REPO" --scout >/dev/null || exit $?
  else
    "$SCRIPT_DIR/fm-brief.sh" "$ID" "$REPO" --mode "$MODE" >/dev/null || exit $?
  fi
  [ -f "$BRIEF" ] || die "fm-brief.sh reported success but $BRIEF is missing"
fi

# Copy one file's bytes exactly, appending a newline only when the last byte
# is not one, so the heading that follows the inserted text starts a line.
emit_file_bytes() {  # <file>
  cat -- "$1"
  [ -z "$(tail -c 1 -- "$1")" ] || printf '\n'
}

if fm_brief_task_placeholders_present "$BRIEF"; then
  BRIEF_TMP="$DATA/$ID/.brief.md.dispatch.$$"
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '{TASK}') emit_file_bytes "$ASK" ;;
        '{FIRSTMATE_SPEC}') emit_file_bytes "$SPEC" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$BRIEF"
  } > "$BRIEF_TMP" || { rm -f -- "$BRIEF_TMP"; die "could not fill $BRIEF"; }
  mv -f -- "$BRIEF_TMP" "$BRIEF" || { rm -f -- "$BRIEF_TMP"; die "could not replace $BRIEF"; }
  if fm_brief_task_placeholders_present "$BRIEF"; then
    die "$BRIEF still contains {TASK} or {FIRSTMATE_SPEC} after filling; the scaffold's placeholder lines were not where fm-brief.sh puts them"
  fi
  echo "brief: filled $BRIEF"
else
  echo "brief: reused $BRIEF"
fi

# ---- 4. profile ----------------------------------------------------------------------
PROFILE_ARGS=()
if [ -n "$HARNESS" ] || [ -n "$MODEL" ] || [ -n "$EFFORT" ]; then
  [ -z "$HARNESS" ] || PROFILE_ARGS+=(--harness "$HARNESS")
  [ -z "$MODEL" ] || PROFILE_ARGS+=(--model "$MODEL")
  [ -z "$EFFORT" ] || PROFILE_ARGS+=(--effort "$EFFORT")
  echo "profile: explicit ${PROFILE_ARGS[*]}"
else
  RESOLVE_OUT=$("$SCRIPT_DIR/fm-dispatch-resolve.sh" "$BRIEF" --project "$REPO")
  RESOLVE_STATUS=$?
  [ "$RESOLVE_STATUS" -eq 0 ] || exit "$RESOLVE_STATUS"
  RESOLVE_KIND=$(printf '%s\n' "$RESOLVE_OUT" | sed -n 's/^  status: *//p' | head -n 1)
  PROFILE_LINE=$(printf '%s\n' "$RESOLVE_OUT" | sed -n 's/^  profile: *//p' | head -n 1)
  if [ "$RESOLVE_KIND" = clear ] && [ -n "$PROFILE_LINE" ]; then
    # The profile line is `--harness <h> [--model <m>] [--effort <e>]`, flag
    # and value tokens with no embedded whitespace, so word-splitting is the
    # intended parse.
    read -r -a PROFILE_ARGS <<< "$PROFILE_LINE"
    echo "profile: resolved $PROFILE_LINE"
  else
    echo "profile: ${RESOLVE_KIND:-off}; spawn resolves the harness statically"
  fi
fi

# ---- 5. spawn ------------------------------------------------------------------------
SPAWN_ARGS=("$ID" "$PROJECT")
if [ "$SCOUT" -eq 1 ]; then
  SPAWN_ARGS+=(--scout)
else
  SPAWN_ARGS+=(--mode "$MODE" --yolo "$YOLO")
fi
[ "${#PROFILE_ARGS[@]}" -eq 0 ] || SPAWN_ARGS+=("${PROFILE_ARGS[@]}")
[ -z "$BACKEND" ] || SPAWN_ARGS+=(--backend "$BACKEND")
"$SCRIPT_DIR/fm-spawn.sh" "${SPAWN_ARGS[@]}" || exit $?

END_MS=$(fm_timing_now_ms)
ELAPSED_MS=$((END_MS - START_MS))
printf 'elapsed: %d.%03d\n' "$((ELAPSED_MS / 1000))" "$((ELAPSED_MS % 1000))"
