#!/usr/bin/env bash
# fm-dispatch.sh - brief, resolve, file, and spawn one crewmate or scout in a
# single call, so intake costs firstmate one tool turn instead of several.
#
# Usage:
#   fm-dispatch.sh <task-id> --project <dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> --ask <file> --spec <file> [options]
#   fm-dispatch.sh <task-id> --project <dir> --scout --ask <file> --spec <file> [options]
#   options: [--title <text>] [--reason <text>] [--harness <name>] [--model <name>] [--effort <level>] [--backend <name>]
#
# --project accepts the same forms as fm-spawn: a directory path, or
# `projects/<name>` resolved against FM_PROJECTS_OVERRIDE, else $FM_HOME/projects.
#
# Mechanics, in order; each step is owned by the script it calls and every
# refusal of that script is a refusal of this one, exit status and message
# unchanged:
#   1. Validate the inputs before touching anything: --ask and --spec must be
#      readable non-empty files, the ask must not open with a Captain label or
#      address (the same spelling set bin/fm-spawn.sh refuses on a filled
#      brief; bin/fm-dod-lib.sh owns it), and neither file may contain an
#      unfenced level-1 or level-2 heading, because the brief parser ends
#      `## Captain's intent` and `## Firstmate spec` at the next such heading
#      and the spliced text would be silently truncated for the worker and the
#      reviewer. An existing brief whose recorded "Delivery contract:
#      mode=<mode>" line disagrees with --mode, or that carries one under
#      --scout, is refused here as a mode mismatch before any record is made.
#   2. Brief: scaffold data/<id>/brief.md through bin/fm-brief.sh with the same
#      --mode or --scout when it does not exist, naming the project by the
#      basename of --project. Then replace the exact `{TASK}` placeholder line
#      with the bytes of --ask and the exact `{FIRSTMATE_SPEC}` line with the
#      bytes of --spec; a file whose last byte is not a newline gets one so the
#      next heading stays on its own line. A brief that is already filled is
#      reused untouched; one still carrying a placeholder is filled in place.
#   3. Profile. An explicit --harness/--model/--effort is the caller's stated
#      override and skips the resolver. Otherwise, when config/crew-dispatch.json
#      exists, run bin/fm-dispatch-resolve.sh on the filled brief: on
#      `status: clear` its `profile:` line, rendered by the resolver as
#      single-quoted shell words, is parsed as such and its flags go to the
#      spawn; any other outcome
#      (ambiguous, escalate, error, or the resolver being off) prints the
#      resolver's block verbatim and stops here, before any item is filed or
#      worker spawned, because those outcomes hand the choice back to firstmate
#      (AGENTS.md section 4) and the re-run with explicit flags is what
#      records it. The resolver's own usage or configuration error (exit 2)
#      refuses this call the same way. With no rules file there is nothing to
#      resolve and the spawn's static harness resolution applies.
#   4. Backlog item: when this home's automatic backlog transition gate applies
#      (bin/fm-backlog-transition-lib.sh's fm_backlog_transition_applies, the
#      same gate fm-spawn consults) and no item exists for the id, add one
#      through bin/fm-tasks-axi.sh with the title from --title or the first
#      non-blank line of --ask, kind ship (scout under --scout), --repo set to
#      the project's basename, and a note recording `mode=<mode> yolo=<yolo>`
#      (`kind=scout` for a scout) plus a `reason: <text>` line when --reason is
#      given, which is the deviation note AGENTS.md section 7 asks for. An
#      existing item is reused as is and no --reason is written into it;
#      fm-spawn still decides whether it is dispatchable. When the gate does not apply
#      (manual backend or no backlog in this home) the step is skipped and
#      says so.
#   5. Spawn through bin/fm-spawn.sh with the explicit --mode/--yolo or --scout,
#      the profile flags, and --backend when given; its output passes through.
#      A successful call ends with `elapsed: <seconds>` for the whole run.
#
# Idempotent on re-run: a task whose brief is already filled and whose item is
# already queued reuses both and goes straight to the profile and the spawn,
# which is what makes a retry after a resolver stop or a spawn refusal safe.
# Nothing here bypasses the placeholder, delivery-contract, backlog, or
# worktree-isolation checks the underlying scripts enforce; this script owns
# the sequencing, not the judgment (AGENTS.md section 7 owns intake).
#
# Home resolution mirrors fm-brief and fm-spawn: FM_HOME selects the home, and
# FM_DATA_OVERRIDE / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE / FM_PROJECTS_OVERRIDE
# relocate its parts; the underlying scripts read the same variables, so one
# environment addresses every step.
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
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RULES_PATH="$CONFIG/crew-dispatch.json"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

ID='' PROJECT='' MODE='' YOLO='' SCOUT=0 ASK='' SPEC='' TITLE='' REASON=''
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
    --reason) need "$@"; REASON=$2; shift 2 ;;
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
case "$PROJECT" in
  projects/*) PROJECT="$PROJECTS/${PROJECT#projects/}" ;;
esac
[ -d "$PROJECT" ] || die "--project directory not found: $PROJECT"
PROJECT_ABS=$(CDPATH='' cd -- "$PROJECT" && pwd -P) || die "--project directory cannot be resolved: $PROJECT"
REPO=$(basename "$PROJECT_ABS")
if [ "$SCOUT" -eq 1 ]; then
  [ "$MODE_SET" -eq 0 ] && [ "$YOLO_SET" -eq 0 ] || die "--scout cannot be combined with --mode or --yolo; a scout delivers a report, not a merge"
  KIND=scout
  NOTE="kind=scout"
else
  [ "$MODE_SET" -eq 1 ] || die "ship dispatch requires --mode <no-mistakes|direct-PR|local-only>, or pass --scout; resolve the mode at intake (AGENTS.md section 7)"
  [ "$YOLO_SET" -eq 1 ] || die "ship dispatch requires --yolo <on|off>; it is this task's merge authority (AGENTS.md section 7)"
  KIND=ship
  NOTE="mode=$MODE yolo=$YOLO"
fi
[ -z "$REASON" ] || NOTE="$NOTE
reason: $REASON"
[ -n "$ASK" ] || die "--ask <file> required: the captain's own words for ## Captain's intent"
[ -n "$SPEC" ] || die "--spec <file> required: the build instructions for ## Firstmate spec"
for f in "$ASK" "$SPEC"; do
  [ -f "$f" ] && [ -r "$f" ] || die "not a readable file: $f"
  [ -n "$(tr -d '[:space:]' < "$f")" ] || die "$f is empty; both --ask and --spec must carry text, since the reviewer treats the ask as acceptance criteria"
done
if ADDRESS_LINE=$(fm_brief_intent_address_line_of_text < "$ASK"); then
  die "--ask $ASK has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address, since the brief heading already records provenance"
fi
if HEADING_LINE=$(fm_brief_body_terminator_line_of_text "## Captain's intent" < "$ASK"); then
  die "--ask $ASK has a heading line that would end ## Captain's intent: $HEADING_LINE; the brief parser stops the section at any unfenced level-1 or level-2 heading, so demote it to ### or deeper or fence it"
fi
if HEADING_LINE=$(fm_brief_body_terminator_line_of_text "## Firstmate spec" < "$SPEC"); then
  die "--spec $SPEC has a heading line that would end ## Firstmate spec: $HEADING_LINE; the brief parser stops the section at any unfenced level-1 or level-2 heading, so demote it to ### or deeper or fence it"
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

# ---- 2. brief ------------------------------------------------------------------------
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

# ---- 3. profile ----------------------------------------------------------------------
PROFILE_ARGS=()
if [ -n "$HARNESS" ] || [ -n "$MODEL" ] || [ -n "$EFFORT" ]; then
  [ -z "$HARNESS" ] || PROFILE_ARGS+=(--harness "$HARNESS")
  [ -z "$MODEL" ] || PROFILE_ARGS+=(--model "$MODEL")
  [ -z "$EFFORT" ] || PROFILE_ARGS+=(--effort "$EFFORT")
  echo "profile: explicit ${PROFILE_ARGS[*]}"
elif [ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ]; then
  RESOLVE_OUT=$("$SCRIPT_DIR/fm-dispatch-resolve.sh" "$BRIEF" --project "$REPO")
  RESOLVE_STATUS=$?
  [ "$RESOLVE_STATUS" -eq 0 ] || exit "$RESOLVE_STATUS"
  RESOLVE_KIND=$(printf '%s\n' "$RESOLVE_OUT" | sed -n 's/^  status: *//p' | head -n 1)
  PROFILE_LINE=$(printf '%s\n' "$RESOLVE_OUT" | sed -n 's/^  profile: *//p' | head -n 1)
  if [ "$RESOLVE_KIND" = clear ] && [ -n "$PROFILE_LINE" ]; then
    eval "set -- $PROFILE_LINE"
    PROFILE_ARGS=("$@")
    echo "profile: resolved $PROFILE_LINE"
  else
    [ -z "$RESOLVE_OUT" ] || printf '%s\n' "$RESOLVE_OUT"
    die "profile unresolved (${RESOLVE_KIND:-resolver off}) with rules at $RULES_PATH; nothing was filed or spawned. Decide the profile from the resolver's evidence above (AGENTS.md section 4) and re-run this call with explicit --harness/--model/--effort"
  fi
else
  echo "profile: no rules at $RULES_PATH; spawn resolves the harness statically"
fi

# ---- 4. backlog item ----------------------------------------------------------------
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  if fm_backlog_row_probe "$DATA" "$ID"; then
    echo "backlog: reused $ID (${FM_BACKLOG_ROW_STATE%% *})"
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    if [ -z "$TITLE" ]; then
      TITLE=$(grep -m 1 -v '^[[:space:]]*$' "$ASK" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    "$SCRIPT_DIR/fm-tasks-axi.sh" add "$ID" "$TITLE" --kind "$KIND" --repo "$REPO" --body "$NOTE" >/dev/null || exit $?
    echo "backlog: added $ID (queued, kind=$KIND, repo=$REPO)"
  else
    die "task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)"
  fi
else
  case $? in
    2) die "task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" ;;
    *) echo "backlog: skipped ($FM_BACKLOG_TRANSITION_SKIP)" ;;
  esac
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
