#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# The direct-PR block is the one owner of that mode's open-the-PR-early default:
# the worker pushes and opens the pull request at its first commit and reports the
# URL in a nonterminal status line, so the work is visible from its first commit
# rather than only when it is done. Opening early is for watching and for arming
# the merge poll; the `pr-review` skill owns when the one review is dispatched.
# It is likewise the one owner of the fix-round technique a no-mistakes worker
# applies to its own commit, to how it answers a Fix gate, and to the
# third-round refusal that returns a narrow-remedy instruction to firstmate,
# the one answer that ends it, and the pass-conditions ask the worker carries.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.
# fm_design_record_path, fm_design_record_scaffold, and fm_design_placeholder_intact
# own the task's design record - firstmate's plan for one task, written beside the
# brief at data/<task-id>/design.md so a decision made in a steer does not live
# only in a steer. bin/fm-brief.sh scaffolds it and points the worker at the file
# itself rather than at any skill the worker may not have, bin/fm-dispatch.sh fills
# it from --design or --no-design, and bin/fm-spawn.sh refuses to hand a worker a
# brief pointing at a record that still carries the placeholder. Those three
# callers share this owner so the path and the placeholder cannot drift apart.

fm_brief_worker_role() {  # <state-dir> <task-id>
  local state=$1 task_id=$2
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
      ;;
    no-mistakes)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

FM_DESIGN_PLACEHOLDER='{DESIGN}'

fm_design_record_path() {  # <data-dir> <task-id>
  printf '%s/%s/design.md\n' "$1" "$2"
}

# Print the scaffolded design record for one task. The body states what the record
# is for, that entries are dated and appended rather than rewritten, and where it
# ranks against the brief's two Task subsections, so the file is self-describing to
# whoever opens it next.
fm_design_record_scaffold() {  # <task-id>
  cat <<EOF
# Design - $1

Firstmate's design record for this task: what firstmate decided and why, so a decision made in a steer does not live only in a steer.
Entries are dated and appended, never rewritten. A plan that changes mid-task is a new dated entry, which is what keeps a decision missing from this record visibly missing rather than silently wrong.
This is firstmate's plan, not the captain's ask. It ranks with the brief's \`## Firstmate spec\` and supersedes it where the two disagree; it never displaces \`## Captain's intent\`, and it is never part of a no-mistakes \`--intent\`.

## Decisions
$FM_DESIGN_PLACEHOLDER
EOF
}

# Return 0 when the record exists and its `## Decisions` body is still nothing but
# the scaffold placeholder. Bounded to that section for the same reason
# fm_brief_task_placeholder_intact is bounded to its subsection: a written plan may
# legitimately quote the token while discussing this machinery, and a bare
# whole-file match would refuse that plan as unwritten.
fm_design_placeholder_intact() {  # <file>
  local file=$1 body
  [ -f "$file" ] || return 1
  body=$(fm_brief_heading_body "$file" "## Decisions")
  [ "$(printf '%s' "$body" | tr -d '[:space:]')" = "$FM_DESIGN_PLACEHOLDER" ]
}

# Return 0 when one named Task subsection still consists only of its scaffold
# placeholder. bin/fm-dispatch.sh asks per subsection, because a brief where
# exactly one is still intact would take only one of its two files.
fm_brief_task_placeholder_intact() {  # <file> <heading> <placeholder>
  local file=$1 body
  [ -f "$file" ] || return 1
  body=$(fm_brief_task_heading_body "$file" "$2")
  [ "$(printf '%s' "$body" | tr -d '[:space:]')" = "$3" ]
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1
  fm_brief_task_placeholder_intact "$file" "## Captain's intent" '{TASK}' && return 0
  fm_brief_task_placeholder_intact "$file" "## Firstmate spec" '{FIRSTMATE_SPEC}' && return 0
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists; terminator mode prints the first unfenced heading
# at the same or a higher level as <heading> anywhere in the input, the line
# that would end <heading>'s body, or the opening line of a fence still open
# at end of input, which would swallow every heading after it; it fails when
# there is neither. Mark mode prints EVERY input line prefixed with `1` when it
# is inside <heading>'s body and `0` otherwise, which is what lets a caller
# rewrite one section of a file without deciding for itself what a heading or a
# fenced block is. That second decision is the thing this mode exists to
# prevent: a shell loop tracking `##` by hand and this awk will agree on the
# easy shapes and disagree on a fenced block, and the disagreement is silent.
# First-body-line mode prints the first non-blank line under EVERY unfenced
# occurrence of <heading>. Every occurrence, because a promoted scout brief
# carries two `# Definition of done` sections - its own, and the superseding one
# bin/fm-promote.sh appends - and the contract belongs to the second; first-line,
# because fm_dod_block always opens its block with that contract line, which is a
# shape this file states and guarantees rather than one that happens to hold.
# Open-fence mode ignores <heading> entirely and answers one question about the
# whole input: is a code fence still open at the end of it, and where did it
# start. A brief that leaves one open hides every heading below it from every
# mode above, so a reader that returns nothing there is not reporting absence.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present|terminator|mark|first-body-line|open-fence>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
          fence_open_line = line
          fence_open_nr = NR
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (mode == "open-fence") next
      if (mode == "first-body-line") {
        if (!was_fenced && !is_fence && line == heading) {
          want = 1
          next
        }
        # Stop where body and mark mode stop. Without it an
        # empty section reports the heading that ENDS it as its first body line,
        # which today only the post-filter in each caller makes harmless.
        if (want && !was_fenced && !is_fence) {
          level = 0
          while (substr(scan, level + 1, 1) == "#") level++
          if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) {
            want = 0
            next
          }
        }
        if (want && line ~ /[^[:space:]]/) {
          print line
          want = 0
        }
        next
      }
      if (mode == "mark") {
        if (!found && !was_fenced && line == heading) {
          found = 1
          grab = 1
          printf "0%s\n", line
          next
        }
        if (grab && !is_fence && !was_fenced) {
          level = 0
          while (substr(scan, level + 1, 1) == "#") level++
          if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) grab = 0
        }
        printf "%d%s\n", grab, line
        next
      }
      if (mode == "terminator") {
        if (is_fence || was_fenced) next
        level = 0
        while (substr(scan, level + 1, 1) == "#") level++
        if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) {
          print line
          found = 1
          exit
        }
        next
      }
      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "open-fence") {
        if (!fenced) exit 1
        printf "%d:%s\n", fence_open_nr, fence_open_line
        exit 0
      }
      if (mode == "terminator" && !found && fenced) {
        print fence_open_line
        found = 1
      }
      if ((mode == "present" || mode == "terminator") && !found) exit 1
    }
  ' "$input"
}

# Print the first line of the text on stdin that would break <heading>'s body
# once spliced into a brief: an unfenced ATX heading at the same or a higher
# level, which ends the body early, or the opening line of a fence left open
# at end of input, which hides every heading after it. Fail when there is
# neither. bin/fm-dispatch.sh applies it to the ask and spec files before
# splicing them under their headings, so neither can silently truncate or
# swallow the sections the parser later extracts.
fm_brief_body_terminator_line_of_text() {  # <heading> < text
  fm_brief_heading_parse - "$1" terminator
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

# Rewrite <file> on stdout with the one placeholder line inside <heading>'s body
# replaced by whatever <emit-cmd> prints. The section is decided by mark mode
# above, so this shares the detectors' parser rather than being a second opinion
# about headings and fences. A line matches when its whitespace-stripped form is
# the placeholder, which is exactly what the intactness checks compare: an exact
# match here would let a placeholder carrying stray whitespace be accepted by the
# detector and rejected by the fill, which is the same two-opinions defect in the
# small. Returns 1 without writing a usable result when that body holds no such
# line, so the caller refuses instead of saving a record it never filled.
fm_brief_replace_placeholder_in_heading() {  # <file> <heading> <placeholder> <emit-cmd> [args...]
  local file=$1 heading=$2 placeholder=$3
  shift 3
  local marked flag line found=0
  while IFS= read -r marked; do
    flag=${marked:0:1}
    line=${marked:1}
    if [ "$found" -eq 0 ] && [ "$flag" = 1 ] &&
      [ "$(printf '%s' "$line" | tr -d '[:space:]')" = "$placeholder" ]; then
      found=1
      "$@"
      continue
    fi
    printf '%s\n' "$line"
  done < <(fm_brief_heading_parse "$file" "$heading" mark)
  [ "$found" -eq 1 ]
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*(\[captain\]|Captain('\''s (words|ask|intent))?:)[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# Print a ship brief's recorded delivery mode: the value of the fixed
# "Delivery contract: mode=<mode>" line fm_dod_block opens with. Prints nothing
# for a brief that records none - a scout brief, or one scaffolded before the
# line existed. This is the one owner of that read: bin/fm-spawn.sh checks it
# against the spawn's own --mode and bin/fm-dispatch.sh checks it against the
# dispatch's, and those two refusals must not drift.
#
# Bounded to `# Definition of done` through the heading parser above, rather than
# matched anywhere in the file. A brief carries the captain's own words under
# `## Captain's intent`, and those words can contain anything - including this
# contract line, quoted inside a closed code fence, in an ask about delivery
# modes. Unbounded, that quote won every comparison against the real contract
# because it comes first, and the task was undispatchable until someone hand-
# edited the captain's text. Bounding the reader makes the quote harmless, which
# is better than teaching the ask guard to refuse a legitimate quotation.
fm_brief_delivery_mode() {  # <file>
  fm_brief_heading_parse "$1" "# Definition of done" first-body-line |
    sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' | head -n 1
}

# Print, as `<line-number>:<line>`, a contract line the brief carries that
# fm_brief_delivery_mode cannot reach; fail when there is none.
#
# Empty from that function used to mean exactly one thing: this brief records no
# contract. Bounding the read gave empty a SECOND meaning - the line is there and
# the reader cannot see it - whose consequence is the opposite, and every caller
# reports the first. That is how a ship brief dispatched with --scout gets past
# the guard that exists to stop it: the guard reads empty as "not a ship brief",
# files the item, flips kind to scout, and launches a worker whose Definition of
# done still tells it to push and open a pull request. The callers need this
# fourth CONDITION, not a fourth parser.
#
# A match inside `# Task` is not one of these. That section carries the captain's
# own words and firstmate's spec, and an ask about delivery modes quoting this
# line is the exact case bounding the read was for - a scout brief carrying such
# an ask records no contract and must stay dispatchable. Every scaffold puts both
# subsections inside `# Task`, so one membership test covers both; a brief with no
# `# Task` at all has no authored prose to protect and every match counts.
fm_brief_delivery_contract_unreachable() {  # <file>
  local file=$1 hit
  [ -f "$file" ] && [ -r "$file" ] || return 1
  [ -z "$(fm_brief_delivery_mode "$file")" ] || return 1
  # An unclosed fence hides every heading below it, so the `# Task` membership
  # test below cannot be trusted on such a brief: the section never ends and the
  # contract line reads as authored prose. A brief that leaves a fence open and
  # carries a contract line is unreachable whatever that test would say.
  if fm_brief_heading_parse "$file" '' open-fence >/dev/null; then
    hit=$(grep -n -m 1 '^Delivery contract: mode=' -- "$file") || return 1
    printf '%s\n' "$hit"
    return 0
  fi
  hit=$(fm_brief_heading_parse "$file" "# Task" mark |
    awk 'substr($0, 1, 1) == "0" && substr($0, 2) ~ /^Delivery contract: mode=/ {
      printf "%d:%s\n", NR, substr($0, 2)
      exit
    }')
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# Print the first line of the captain-intent text on stdin that opens with an
# operator address spelling; fail when there is none. This is the one owner of
# that spelling set: bin/fm-spawn.sh applies it to a filled brief through the
# wrapper below, and bin/fm-dispatch.sh applies it to the ask file before any
# brief exists, so the two refusals cannot drift.
fm_brief_intent_address_line_of_text() {  # < text
  awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | fm_brief_intent_address_line_of_text
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

fm_dod_block() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.

**Open the pull request early, not at the end.** As soon as your first commit is on \`fm/$id\`, push the branch and open the PR with \`gh-axi\`, then append \`working: PR {url} open, work continuing\` to the status file and carry straight on - that line is nonterminal under rule 4, and it is what lets firstmate and the captain follow this work from its first commit instead of seeing it only once it is finished. The review comes after you report done, so an open PR is not a request for one and you keep working.
Push each later commit to that same PR as you make it; never hold work back to make the PR look finished, and say in the PR body that the work is still in progress.
Do not open it as a draft: the reviewer and the merge path both act on an ordinary open pull request.

The task is complete only when the work is implemented, committed, and pushed to that PR.
Then append \`done: PR {url}\` to the status file and stop.
If no PR is open by then - your first commit was also your last, or an early push failed and you recovered - open it now and append the same \`done:\` line.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe the implementation is complete, append \`done: {summary}\` to the status file and stop - that is the pause before validation, not this mode's finish, which the last line of this Definition of done states.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll \`no-mistakes axi status\` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
  From the third fix round on one step the round-threshold clause below narrows this: a decision that still names a narrow remedy goes back to firstmate instead of to the gate, and that clause is where the one answer you may give the gate instead is stated, along with the one thing you append to the decision you do send.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

A fix round that lands only on the lines the reviewer named, or that introduces the next round's finding, buys another round, and the round count is what runs a task into its wall-clock limit.
Two things decide that and both are yours: the implementation you commit before starting the run, and how you answer a Fix gate.
At that gate \`--findings\` selects the set the round covers and \`--instructions\` is guidance layered onto that already-selected set, so whole-class guidance never reaches a finding you left out of the selection.
Apply these four to both, and when the \`greenlight\` skill is installed at \`~/.claude/skills/greenlight\` read \`references/generalize.md\` for the long form of what a class is and the detector forms that make two independent ways something you can actually run, and \`references/verify-your-fix.md\` for the long form of the pass over your own diff and of reading the contract rather than a paraphrase, taking the technique and not its run structure, which assumes the agent opens an umbrella pull request and a sub-pull-request per finding and does not apply here.
- One site is a class: a finding names one instance, so close the whole class in the same round - code, tests, config, comments, and documentation - detect it at least two independent ways so a sweep cannot report clean because its one pattern was wrong, re-run that sweep over the fix's own diff - yours before the run, the pipeline's after a fix round - because the fix can create a site the sweep already cleared, and name any site you deliberately leave unfixed instead of leaving the next round to find it.
- Your fix is the next candidate: before the run the diff is your own commit, so put it through the pass you would run over someone else's - every new conditional's unwritten branch, every new bound relative to where the value changes shape, every newly accepted value against its downstream consumers.
  After a fix round the diff is the pipeline's fix commit rather than one you are about to submit, so you run that same pass over it when the gate returns and fold whatever it finds into the round with \`--add-finding\`, never by editing or holding back the worktree yourself.
- A behavioral test is not evidence until it has failed: before you start the run you prove that yourself, by reverting the production fix, confirming the test goes red, and restoring it.
  Once a run is active you never touch the worktree, so the proof is something you require in the \`--instructions\` you pass at the Fix gate instead of something you perform by hand.
- Read the primary source before writing a check - the script, spec, or contract itself, not a comment beside it or a paraphrase in a design document.

From the third fix round on one step, \`ask-user-authority\` requires firstmate to stop naming a narrow remedy and ask for the coherent change, and you are the party holding the round number when that instruction arrives - the round it opens, counted the way step 4 of that skill counts it.
- Refuse an instruction that still names a narrow remedy: append \`blocked: fix round {n} on this step, instruction still names a narrow remedy\` to the status file, where {n} is that arriving round number, and ask firstmate for the coherent-change instruction instead of answering the gate with it.
  Firstmate reads status events and does not watch your pane, so a refusal you hold quietly is a deadlock however correct it is.
- One answer ends that refusal: the coherent-change instruction you asked for. Answer the gate with that. A resend that still names a narrow remedy is not one, and the refusal stands.
- Ask the reviewer for the pass conditions in the same response you do answer that gate with: everything still wanted, stated as conditions to satisfy in one pass rather than as one more repair.
  That ask rides with every response you send from this round on, whoever authored the instruction it accompanies - your own \`--instructions\` as much as a decision firstmate handed you, where adding it is the one addition that is not implementing the decision.
  Nothing carries that ask to the reviewer and returns a reply, so never wait for one - the only thing that comes back is the next gate report.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
