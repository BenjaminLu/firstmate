#!/usr/bin/env bash
# fm-dispatch.sh - brief, resolve, file, and spawn one crewmate or scout in a
# single call, so intake costs firstmate one tool turn instead of several.
#
# Usage:
#   fm-dispatch.sh <task-id> --project <dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> --ask <file> --spec <file> <--design <file>|--no-design <reason>> [options]
#   fm-dispatch.sh <task-id> --project <dir> --scout --ask <file> --spec <file> <--design <file>|--no-design <reason>> [options]
#   fm-dispatch.sh <task-id> --project <dir> --review <github-pr-url> --ask <file> --spec <file> <--design <file>|--no-design <reason>> [options]
#   options: [--title <text>] [--reason <text>] [--herdr-lab] [--harness <name>] [--model <name>] [--effort <level>] [--backend <name>]
#
# --design and --no-design are the task's design record: firstmate's plan for this
# task, written to data/<id>/design.md beside the brief so a decision made in a
# steer does not live only in a steer. Exactly one is REQUIRED, the way --secondmate
# requires a project list or --no-projects: --design <file> writes the plan, and
# --no-design <reason> records, dated, that firstmate judged this task to carry no
# design decisions worth writing down. Omitting both fails here, before anything is
# written, because a design record that firstmate has to remember at the end of an
# intake is exactly the one that does not get written. The gate cannot tell a real
# plan from a thin one; what it converts is silence into a dated statement the
# captain can read.
#
# --project accepts the same forms as fm-spawn: a directory path, or
# `projects/<name>` resolved against FM_PROJECTS_OVERRIDE, else $FM_HOME/projects.
#
# Which flags live here: a flag stays when it is an inert passthrough the script
# it reaches validates itself (--title, and --backend, which carries the
# per-task runtime authority AGENTS.md section 4 grants explicitly and which
# fm-spawn refuses an invalid value for), and goes when it would let the filed
# item and the spawned worker disagree, which is why --kind was removed and the
# kind follows --scout alone.
#
# --review dispatches a reviewer against one open pull request: bin/fm-brief.sh
# writes the reviewer contract and validates the URL, and the task is then filed
# and spawned as a scout, because a review is scout-shaped in every mechanical
# respect (scratch worktree, no branch, no commit, no push, no PR of its own).
# It is exclusive with --mode and --yolo, and its backlog note records
# `kind=review pr=<url>`. An existing brief is refused when its review shape and
# this call's --review disagree, the same way the --mode and --herdr-lab
# mismatches are refused. AGENTS.md section 7 owns when a review is dispatched
# and the `pr-review` skill owns what firstmate does with the findings.
#
# Mechanics, in order; each step is owned by the script it calls and every
# refusal of that script is a refusal of this one, exit status and message
# unchanged:
#   1. Validate the inputs before touching anything: --ask and --spec must be
#      readable non-empty files, the ask must not open with a Captain label or
#      address (the same spelling set bin/fm-spawn.sh refuses on a filled
#      brief; bin/fm-dod-lib.sh owns it), and neither file may contain an
#      unfenced level-1 or level-2 heading or leave a code fence open at its
#      end, because the brief parser ends `## Captain's intent` and
#      `## Firstmate spec` at the next such heading and treats everything
#      inside an open fence as fenced, so the spliced text would truncate or
#      swallow sections for the worker and the reviewer. The backlog title -
#      --title, else the first non-blank ask line with any list marker dropped -
#      must carry text and must not start with a dash, which tasks-axi would
#      read as a flag. An existing brief is refused here, before any record is
#      made, when it disagrees with this call: its recorded "Delivery
#      contract: mode=<mode>" line (bin/fm-dod-lib.sh owns that read too, so
#      this refusal and fm-spawn's cannot drift) differs from --mode, it
#      carries one under --scout, it carries none (a scout brief) under --mode,
#      its Herdr section (bin/fm-brief.sh writes `# Herdr isolation - HARD
#      SAFETY CONTRACT` with --herdr-lab and `# Herdr lifecycle declaration -
#      NOT ENABLED` without) disagrees with this call's --herdr-lab, or exactly
#      one of its two Task placeholders is still intact, because filling such a
#      half-filled brief would splice one file and silently drop the other.
#      --design must name a readable file carrying text, and --no-design a reason
#      carrying text; the design record itself is not parsed by section, so no
#      heading check applies to it.
#   2. Brief: scaffold data/<id>/brief.md through bin/fm-brief.sh with the same
#      --mode or --scout, and --herdr-lab when given (mandatory for a task that
#      drives Herdr lifecycle commands; fm-brief.sh owns that contract), when
#      it does not exist, naming the project by the basename of --project.
#      Then replace the exact `{TASK}` placeholder line
#      with the bytes of --ask and the exact `{FIRSTMATE_SPEC}` line with the
#      bytes of --spec; a file whose last byte is not a newline gets one so the
#      next heading stays on its own line. A brief that is already filled is
#      reused untouched; one still carrying a placeholder is filled in place.
#   3. Design record: fill data/<id>/design.md's `{DESIGN}` placeholder with the
#      bytes of --design, or with the dated --no-design declaration. A record that
#      an older brief left absent is scaffolded here from the same owner
#      bin/fm-brief.sh uses (bin/fm-dod-lib.sh), so a re-dispatch of a legacy task
#      still gets one. A record already filled is reused untouched and reported as
#      reused, exactly as an already-filled brief is, which is what makes a retry
#      after a resolver stop or a spawn refusal safe.
#   4. Profile. An explicit --harness/--model/--effort is the caller's stated
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
#   5. Backlog item: when this home's automatic backlog transition gate applies
#      (bin/fm-backlog-transition-lib.sh's fm_backlog_transition_applies, the
#      same gate fm-spawn consults) and no item exists for the id, add one
#      through bin/fm-tasks-axi.sh with the title validated in step 1,
#      kind ship (scout under --scout or --review), --repo set to
#      the project's basename, and a note recording `mode=<mode> yolo=<yolo>`
#      (`kind=scout` for a scout, `kind=review pr=<url>` for a review) plus a
#      `reason: <text>` line when --reason is
#      given, which is the deviation note AGENTS.md section 7 asks for. An
#      existing item is reused as is and no --reason is written into it;
#      fm-spawn still decides whether it is dispatchable. When the gate does not apply
#      (manual backend or no backlog in this home) the step is skipped and
#      says so.
#   6. Spawn through bin/fm-spawn.sh with the explicit --mode/--yolo or --scout,
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

START_MS=$(fm_timing_now_ms)

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RULES_PATH="$CONFIG/crew-dispatch.json"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

ID='' PROJECT='' MODE='' YOLO='' SCOUT=0 REVIEW='' HERDR_LAB=0 ASK='' SPEC='' TITLE='' REASON=''
HARNESS='' MODEL='' EFFORT='' BACKEND='' DESIGN='' NO_DESIGN=''
MODE_SET=0 YOLO_SET=0 DESIGN_SET=0 NO_DESIGN_SET=0
need() { [ $# -ge 2 ] || die "$1 requires a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need "$@"; PROJECT=$2; shift 2 ;;
    --mode) need "$@"; MODE=$2; MODE_SET=1; shift 2 ;;
    --yolo) need "$@"; YOLO=$2; YOLO_SET=1; shift 2 ;;
    --scout) SCOUT=1; shift ;;
    --review) need "$@"; REVIEW=$2; shift 2 ;;
    --herdr-lab) HERDR_LAB=1; shift ;;
    --ask) need "$@"; ASK=$2; shift 2 ;;
    --spec) need "$@"; SPEC=$2; shift 2 ;;
    --design) need "$@"; DESIGN=$2; DESIGN_SET=1; shift 2 ;;
    --no-design) need "$@"; NO_DESIGN=$2; NO_DESIGN_SET=1; shift 2 ;;
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
if [ -n "$REVIEW" ]; then
  # A review is scout-shaped machinery with a different deliverable, so it is
  # briefed with --review, filed and spawned as a scout, and torn down by the
  # scout gate. bin/fm-brief.sh validates the URL and owns that contract.
  [ "$MODE_SET" -eq 0 ] && [ "$YOLO_SET" -eq 0 ] || die "--review cannot be combined with --mode or --yolo; a review posts findings on an existing PR and delivers no change of its own"
  # Validate here as well as in fm-brief.sh, because an already-scaffolded
  # brief is reused without calling it, and the URL would then reach the
  # backlog note having been checked by nothing.
  fm_pr_url_parse "$REVIEW" && [ "$FM_PR_PROVIDER" = github ] \
    || die "--review requires a GitHub pull request URL of the form https://github.com/<owner>/<repo>/pull/<number> (got '$REVIEW')"
  SCOUT=1
  KIND=scout
  NOTE="kind=review pr=$REVIEW"
elif [ "$SCOUT" -eq 1 ]; then
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
# The design record is firstmate's plan for this task. Requiring the choice here,
# before anything is written, is what makes recording the plan the default; a
# deliberate "this task has none" is a decision that lands in the record dated,
# rather than a step that was skipped and left no trace.
if [ "$DESIGN_SET" -eq 1 ] && [ "$NO_DESIGN_SET" -eq 1 ]; then
  die "--design and --no-design are exclusive; pass the plan, or the reason there is none, not both"
fi
if [ "$DESIGN_SET" -eq 0 ] && [ "$NO_DESIGN_SET" -eq 0 ]; then
  die "--design <file> or --no-design <reason> required: firstmate's plan for this task lands in its design record at $DATA/$ID/design.md, and judging that it has none is a decision that gets recorded rather than a step that gets skipped"
fi
if [ "$DESIGN_SET" -eq 1 ]; then
  [ -f "$DESIGN" ] && [ -r "$DESIGN" ] || die "not a readable file: $DESIGN"
  [ -n "$(tr -d '[:space:]' < "$DESIGN")" ] || die "$DESIGN is empty; --design must carry firstmate's decisions and why, or pass --no-design <reason>"
else
  [ -n "$(printf '%s' "$NO_DESIGN" | tr -d '[:space:]')" ] || die "--no-design requires a reason carrying text; it is written into the design record as firstmate's dated statement that this task has no design decisions worth recording"
fi

if ADDRESS_LINE=$(fm_brief_intent_address_line_of_text < "$ASK"); then
  die "--ask $ASK has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address, since the brief heading already records provenance"
fi
if HEADING_LINE=$(fm_brief_body_terminator_line_of_text "## Captain's intent" < "$ASK"); then
  die "--ask $ASK has a line that would break ## Captain's intent: $HEADING_LINE; the brief parser stops the section at any unfenced level-1 or level-2 heading and an unclosed code fence swallows every section after it, so demote the heading to ### or deeper, or close the fence"
fi
if HEADING_LINE=$(fm_brief_body_terminator_line_of_text "## Firstmate spec" < "$SPEC"); then
  die "--spec $SPEC has a line that would break ## Firstmate spec: $HEADING_LINE; the brief parser stops the section at any unfenced level-1 or level-2 heading and an unclosed code fence swallows every section after it, so demote the heading to ### or deeper, or close the fence"
fi

# The item's title is a positional argument to tasks-axi, which reads a leading
# dash as a flag, so it is settled before anything is written rather than after
# the brief exists. A bullet-led ask is ordinary captain input: the list marker
# is markup, not title text.
if [ -z "$TITLE" ]; then
  TITLE=$(grep -m 1 -v '^[[:space:]]*$' "$ASK" |
    sed -e 's/^[[:space:]]*//' \
      -e 's/^[-*+][[:space:]][[:space:]]*//' \
      -e 's/^[0-9][0-9]*[.)][[:space:]][[:space:]]*//' \
      -e 's/[[:space:]]*$//')
fi
case "$TITLE" in
  '') die "no backlog title: the first non-blank line of --ask $ASK carries no text beyond its list marker; pass --title <text>" ;;
  -*) die "backlog title '$TITLE' starts with a dash, which tasks-axi reads as a flag rather than the item's title; pass --title <text>" ;;
esac

BRIEF="$DATA/$ID/brief.md"
BRIEF_EXISTS=0
if [ -e "$BRIEF" ]; then
  [ -f "$BRIEF" ] && [ -r "$BRIEF" ] || die "$BRIEF exists but is not a readable regular file"
  BRIEF_EXISTS=1
  BRIEF_MODE=$(fm_brief_delivery_mode "$BRIEF")
  if [ "$SCOUT" -eq 1 ]; then
    [ -z "$BRIEF_MODE" ] || die "$BRIEF is a ship brief (Delivery contract: mode=$BRIEF_MODE) but this dispatch is --scout; move that brief aside or drop --scout"
  elif [ -z "$BRIEF_MODE" ]; then
    die "$BRIEF is a scout brief (no Delivery contract line) but this dispatch passes --mode $MODE; move that brief aside or pass --scout"
  elif [ "$BRIEF_MODE" != "$MODE" ]; then
    die "$BRIEF records Delivery contract: mode=$BRIEF_MODE but this dispatch passes --mode $MODE; re-scaffold the brief or pass the recorded mode"
  fi
  if fm_brief_heading_present "$BRIEF" "# The review you post"; then
    [ -n "$REVIEW" ] || die "$BRIEF is a review brief but this dispatch omits --review; pass --review <pr-url> or move that brief aside"
  else
    [ -z "$REVIEW" ] || die "$BRIEF is not a review brief but this dispatch passes --review; move that brief aside to rebuild it as a review, or drop --review"
  fi
  if fm_brief_heading_present "$BRIEF" "# Herdr isolation - HARD SAFETY CONTRACT"; then
    [ "$HERDR_LAB" -eq 1 ] || die "$BRIEF carries the Herdr isolation contract (scaffolded with --herdr-lab) but this dispatch omits --herdr-lab; pass the flag or re-scaffold the brief"
  else
    [ "$HERDR_LAB" -eq 0 ] || die "$BRIEF was scaffolded without --herdr-lab (Herdr lifecycle declaration - NOT ENABLED) but this dispatch passes --herdr-lab; re-scaffold the brief or drop the flag"
  fi
  INTENT_INTACT=0 SPEC_INTACT=0
  fm_brief_task_placeholder_intact "$BRIEF" "## Captain's intent" '{TASK}' && INTENT_INTACT=1
  fm_brief_task_placeholder_intact "$BRIEF" "## Firstmate spec" '{FIRSTMATE_SPEC}' && SPEC_INTACT=1
  if [ "$INTENT_INTACT" -ne "$SPEC_INTACT" ]; then
    if [ "$INTENT_INTACT" -eq 1 ]; then
      HALF_FILLED="## Captain's intent still carries {TASK} while ## Firstmate spec is already written"
    else
      HALF_FILLED="## Firstmate spec still carries {FIRSTMATE_SPEC} while ## Captain's intent is already written"
    fi
    die "$BRIEF is half-filled: $HALF_FILLED; this call would splice only the placeholder that is left and silently drop the other file, so the worker and the reviewer would read text this dispatch never supplied. Move that brief aside to rebuild it from --ask and --spec, or fill the remaining subsection by hand so the brief is reused whole"
  fi
fi

# ---- 2. brief ------------------------------------------------------------------------
if [ "$BRIEF_EXISTS" -eq 0 ]; then
  BRIEF_ARGS=("$ID" "$REPO")
  if [ -n "$REVIEW" ]; then
    BRIEF_ARGS+=(--review "$REVIEW")
  elif [ "$SCOUT" -eq 1 ]; then
    BRIEF_ARGS+=(--scout)
  else
    BRIEF_ARGS+=(--mode "$MODE")
  fi
  [ "$HERDR_LAB" -eq 0 ] || BRIEF_ARGS+=(--herdr-lab)
  "$SCRIPT_DIR/fm-brief.sh" "${BRIEF_ARGS[@]}" >/dev/null || exit $?
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
  # Each placeholder is replaced inside its own subsection, one pass each, so an
  # ask that quotes `{TASK}` on a line of its own is not spliced into twice, and
  # so no second section-tracking loop is written here to disagree with the shared
  # parser about a fenced block.
  #
  # It is NOT the same scope its detector uses, and the difference is worth
  # stating rather than implying. fm_brief_task_placeholder_intact reads two
  # levels - `# Task`'s body, then the subsection inside it - while this searches
  # the whole file for `## Captain's intent` and `## Firstmate spec`. A brief with
  # one of those subsections OUTSIDE `# Task` would be filled here and not seen
  # there. No scaffold produces that: fm-brief.sh puts `# Task` at line 3 of every
  # ship, scout and review brief, so the subsections only ever appear inside it,
  # and only a hand-edited brief could differ. Closing the gap needs a two-level
  # mark, because fm_brief_task_heading_body returns an extracted body rather than
  # a position in the file, and that is machinery for a case nothing can reach.
  # The design record's fill above has no such gap: fm_design_placeholder_intact
  # reads `## Decisions` from the whole file, which is exactly what its fill marks.
  fill_brief_subsection() {  # <heading> <placeholder> <file>
    fm_brief_replace_placeholder_in_heading "$BRIEF_TMP.in" "$1" "$2" emit_file_bytes "$3"
  }
  cp -- "$BRIEF" "$BRIEF_TMP.in" || die "could not stage $BRIEF for filling"
  for pass in "## Captain's intent|{TASK}|$ASK" "## Firstmate spec|{FIRSTMATE_SPEC}|$SPEC"; do
    PASS_HEADING=${pass%%|*}
    PASS_REST=${pass#*|}
    PASS_PLACEHOLDER=${PASS_REST%%|*}
    PASS_FILE=${PASS_REST#*|}
    if fm_brief_task_placeholder_intact "$BRIEF_TMP.in" "$PASS_HEADING" "$PASS_PLACEHOLDER"; then
      if fill_brief_subsection "$PASS_HEADING" "$PASS_PLACEHOLDER" "$PASS_FILE" > "$BRIEF_TMP"; then
        mv -f -- "$BRIEF_TMP" "$BRIEF_TMP.in" || {
          rm -f -- "$BRIEF_TMP" "$BRIEF_TMP.in"
          die "could not stage the filled $PASS_HEADING for $BRIEF"
        }
      else
        rm -f -- "$BRIEF_TMP" "$BRIEF_TMP.in"
        die "could not fill $BRIEF: its $PASS_HEADING body holds no $PASS_PLACEHOLDER line to replace"
      fi
    fi
  done
  mv -f -- "$BRIEF_TMP.in" "$BRIEF" || { rm -f -- "$BRIEF_TMP.in"; die "could not replace $BRIEF"; }
  if fm_brief_task_placeholders_present "$BRIEF"; then
    die "$BRIEF still contains {TASK} or {FIRSTMATE_SPEC} after filling; the scaffold's placeholder lines were not where fm-brief.sh puts them"
  fi
  echo "brief: filled $BRIEF"
else
  echo "brief: reused $BRIEF"
fi

# ---- 3. design record ----------------------------------------------------------------
# A brief scaffolded before design records existed has none, so scaffold it from
# the same owner fm-brief.sh uses rather than leaving a re-dispatch with nothing
# to fill.
DESIGN_RECORD=$(fm_design_record_path "$DATA" "$ID")
if [ -e "$DESIGN_RECORD" ]; then
  [ -f "$DESIGN_RECORD" ] && [ -r "$DESIGN_RECORD" ] || die "$DESIGN_RECORD exists but is not a readable regular file"
else
  fm_design_record_scaffold "$ID" > "$DESIGN_RECORD" || die "could not scaffold the design record at $DESIGN_RECORD"
fi
if fm_design_placeholder_intact "$DESIGN_RECORD"; then
  DESIGN_TMP="$DATA/$ID/.design.md.dispatch.$$"
  emit_design_fill() {
    if [ "$DESIGN_SET" -eq 1 ]; then
      emit_file_bytes "$DESIGN"
    else
      printf '%s\n' \
        "None recorded at dispatch ($(date -u +%Y-%m-%d)): $NO_DESIGN" \
        "Firstmate judged this task to carry no design decisions worth recording. A decision made later is appended below as its own dated entry."
    fi
  }
  # Bounded to `## Decisions` by the same parser fm_design_placeholder_intact uses,
  # so the two cannot disagree about a heading, a fenced block, or a placeholder
  # carrying stray whitespace. The refusal is reachable: the helper RETURNS, where
  # an `exit` inside a `{ ... } > file` group would unwind past the handler
  # attached to it and leave firstmate a bare status with nothing said.
  if fm_brief_replace_placeholder_in_heading \
    "$DESIGN_RECORD" "## Decisions" "$FM_DESIGN_PLACEHOLDER" emit_design_fill > "$DESIGN_TMP"; then
    mv -f -- "$DESIGN_TMP" "$DESIGN_RECORD" || { rm -f -- "$DESIGN_TMP"; die "could not replace $DESIGN_RECORD"; }
  else
    rm -f -- "$DESIGN_TMP"
    die "could not fill $DESIGN_RECORD: its ## Decisions section holds no $FM_DESIGN_PLACEHOLDER line to replace"
  fi
  if fm_design_placeholder_intact "$DESIGN_RECORD"; then
    die "$DESIGN_RECORD's ## Decisions section still holds nothing but $FM_DESIGN_PLACEHOLDER after filling; the scaffold's placeholder line was not where bin/fm-dod-lib.sh puts it"
  fi
  echo "design: filled $DESIGN_RECORD"
else
  echo "design: reused $DESIGN_RECORD"
fi

# ---- 4. profile ----------------------------------------------------------------------
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

# ---- 5. backlog item ----------------------------------------------------------------
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  if fm_backlog_row_probe "$DATA" "$ID"; then
    echo "backlog: reused $ID (${FM_BACKLOG_ROW_STATE%% *})"
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
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

# ---- 6. spawn ------------------------------------------------------------------------
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
