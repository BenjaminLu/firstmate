#!/usr/bin/env bash
# fm-gate-calls-lib.sh - the one owner of firstmate's gate-call record.
#
# WHAT THIS RECORDS AND WHY IT EXISTS
#
# firstmate's existing machinery records what was escalated to the captain and
# what he answered. Nothing recorded what was NOT escalated: a finding decided
# on firstmate's own authority, a finding declined as out of scope, a pull
# request kept off the captain's desk because its checks were not green. That
# half of firstmate's judgement was recoverable only by reading backlog prose
# and status lines by hand, which is what made it a black box.
#
# This is the durable half. One append-only log, one line per gate call, so a
# reader can see what firstmate did with its own authority and on what grounds.
#
# CONTRACT (this header is the one owner of the format).
#
#   Log: <state>/gate-calls.jsonl, strictly APPEND-ONLY. One JSON object per
#   line, with a stable key set - every key is always present, empty when the
#   call had no value for it, so a reader never branches on a missing field:
#
#     {"at":"<UTC ISO-8601 seconds>","site":"<where the call was made>",
#      "task":"<task id>","verdict":"decided|escalated|refused|deferred",
#      "what":"<what the call was about>","grounds":"<why>",
#      "link":"<url or empty>","key":"<routing key or empty>",
#      "truncated":true|false,"rejected":"<comma-separated field names>"}
#
#   The four verdicts are the whole vocabulary:
#     decided   - firstmate ruled on its own authority and did not escalate.
#     escalated - firstmate handed the call to the captain.
#     refused   - firstmate kept something off the captain's desk, or declined
#                 to perform it, because a standing condition was not met.
#                 A permanent decline belongs here, including an out-of-scope
#                 review finding ruled "won't fix".
#     deferred  - the call was correct and firstmate means to come back to it,
#                 just not now. A reader counting what is still owed reads
#                 these, so a decline that will never be revisited is
#                 `refused`, not `deferred`.
#
#   `grounds` is the only field allowed to span lines, because a refusal is
#   often a list of conditions and flattening it loses which one failed; the
#   newlines survive as \n inside the one-line record.
#
#   A field the shortening loop cut ends with FM_GATE_CALL_CUT_MARK, so the
#   value itself says it was shortened and which field it was, alongside the
#   record-level `"truncated":true`.
#
#   TWO SEVERITIES OF BAD INPUT, because they cost different things.
#   `site` and `task` say which call this is, and `verdict`, `what` and
#   `grounds` are the call itself: a bad one of those refuses the whole
#   record, because a record naming the wrong call or stating no reason is
#   worse than a reported gap. `link` and `key` are presentation - a board
#   opens one and lines the other up against a review - so a malformed one is
#   dropped, its name is listed in `rejected`, and the call is still recorded.
#   A pasted URL with a trailing space must not cost a well-formed ruling its
#   place in the log; that is the same silent loss arriving by a politer door.
#   `rejected` is empty when everything was accepted.
#
#   Nothing in this library reads the log. Rendering it is a separate surface;
#   the log is the durable record that surface will read.
#
#   The log lives under <state>, captain-private and gitignored with the rest
#   of the home's state. There is no retention or rotation: one bounded line
#   per gate call is small, and dropping history from a log whose whole purpose
#   is completeness would be the defect it exists to prevent. Truncating it is
#   a captain-approved manual act.
#
# OBSERVER, NEVER A GATE - AND `|| true` IS MANDATORY, NOT A CONVENIENCE
#
# Recording a call must never change its outcome. Nothing here ever calls
# `exit`, and every entry point signals a failed record by returning 1.
#
# That is not enough on its own, and the distinction matters to anyone adding
# a site. Under `set -e` a function returning 1 as a plain statement exits the
# shell, whatever this file does. So the property this library actually has is
# "safe if every caller guards the call", and the guard is required:
#
#     fm_gate_call_record ... || true      # or an `if`, or a `&&`/`||` chain
#
# The consequence of forgetting it is the exact inversion this section names.
# In bin/fm-captain-hold.sh's `command_hold` the record call sits one line
# before the `printf` that hands the caller the task id: an unguarded call
# that dropped would kill the script AFTER the hold had already landed and
# BEFORE anything told the caller it had. The observer would have become a
# gate, and a silent one. Every live site guards today - bin/fm-captain-hold.sh
# and bin/fm-pr-merge.sh with `|| true`, bin/fm-gate-call.sh inside an `if` -
# and a new site must do the same.
#
# A MISSING RECORD IS VISIBLE AS MISSING
#
# A gatekeeping log that quietly drops entries is worse than no log, because a
# reader would believe he is seeing everything. A call that cannot be recorded
# is therefore reported, never swallowed, in two places:
#
#   1. One `actionable:` line on stderr naming the task and the reason. Same
#      shape bin/fm-captain-hold.sh uses when a durable record lands but its
#      channel publication does not.
#   2. A line appended to the drops sidecar <state>/gate-calls.drops: the same
#      JSON object plus "dropped":"<reason>", so one parser reads both files
#      and a reader can count what is missing and see what it was.
#
#   TWO RESIDUAL LIMITS, STATED RATHER THAN HIDDEN. Both bound what the two
#   places above can prove, and the second is the larger one.
#
#   1. When <state> itself cannot be written neither file can be, and the
#      stderr line is the only report. That is the one case where the log's
#      incompleteness is not itself durable.
#
#   2. This covers only calls that reach fm_gate_call_record. Two of the four
#      sites - the ask-user decision and the review-finding ruling - are
#      agent prose in .agents/skills/ask-user-authority and
#      .agents/skills/pr-review, with no code path that notices a skipped
#      call. A ruling that is simply never recorded produces no log line, no
#      drops line, and nothing on stderr.
#
#   So read the guarantee precisely: a call that ENTERS here and cannot be
#   written is always visible as missing. The log cannot prove a ruling
#   happened without a record, and nothing here should be read as saying it
#   can. Closing that would mean a second mechanism watching the two prose
#   sites, which is its own piece of work and not this one.
#
# BOUNDS
#
# The assembled line is held under FM_GATE_CALL_MAX_LINE bytes by shortening
# `grounds`, then `what`, and the record carries "truncated":true whenever that
# applied - so a long refusal list is shortened visibly rather than silently.
# The identity fields it must never shorten - site, task, link, key - carry
# their own caps instead, and an input over one of those is refused rather than
# cut, because half a task id or half a link points at the wrong thing. Those
# caps are also what make the shortening loop always terminate on a line that
# still names the call.
#
# THE BOUND IS THE SHELL'S STDOUT BUFFER, NOT THE FILESYSTEM BLOCK.
#
# The bound exists so each append is a single write() and two firstmate
# processes appending at once cannot interleave. The atomic unit is the size
# at which the bash `printf` builtin flushes stdout, which is NOT the
# filesystem block size an earlier version of this comment reasoned about.
# Measured through bin/fm-gate-call.sh with four concurrent writers, 100
# records per row, macOS 24.6.0 / APFS / GNU bash 3.2.57 - the stock macOS
# shell this repository keeps a CI lane for:
#
#   write bytes (line + newline)   torn lines
#     835                            0/100
#     985                            0/100
#    1035                           18/100
#    1085                           12/100
#    2159                           25/100
#
# The boundary is 1024 bytes including the newline. A torn line is the exact
# failure this record exists to prevent: it is unparseable, it writes no drops
# entry, and it says nothing on stderr, so the log reads as complete and is
# not. FM_GATE_CALL_MAX_LINE is therefore set below that boundary with margin.
#
# The claim is about EVERY line this library emits, not about typical ones, so
# two things have to hold and both are load-bearing. The caps are counted in
# BYTES, the same unit as the bound - a cap in characters bounds nothing,
# because 498 characters of CJK are 1458 bytes. And the shortening ladder can
# always REACH the bound: when shortening the substance is not enough it drops
# `link`, then `key`, into `rejected`, so it never runs out of moves and
# writes an over-bound line anyway. What is left when every move is spent -
# the timestamp, the capped site and task, the verdict - is a few hundred
# bytes, which is what makes the guarantee total rather than typical.
# tests/fm-gate-calls.test.sh checks that directly, driving adversarial inputs
# through the real command and failing if any emitted line crosses the
# boundary, so this paragraph stays true rather than becoming folklore.
# bin/fm-board-live.sh's own append states the correct version of this
# reasoning - atomic "on a line this short" - and its lines are a couple of
# hundred bytes; the guarantee does not generalise to a long line.
#
# There is deliberately no lock: taking one would let a contended or stale lock
# delay the fleet action this library only observes.
#
# Sourced, never executed. bin/fm-gate-call.sh is the command-line entry point.
# No side effects on source. Safe to source under `set -u` and `set -e`;
# CALLING a function under `set -e` requires the guard above.

# Assembled-line byte bound. Set below the measured 1024-byte stdout flush
# (see BOUNDS above), with margin for the newline, so one append is one
# write(). Raising it past that boundary reintroduces silent torn records.
FM_GATE_CALL_MAX_LINE=900

# BYTE caps on the four short fields (see BOUNDS above). Bytes, not
# characters: the line bound they serve is counted in bytes, and a cap counted
# in characters does not bound it - 498 characters of CJK are 1458 bytes.
FM_GATE_CALL_CAP_SITE=40
FM_GATE_CALL_CAP_TASK=80
FM_GATE_CALL_CAP_LINK=500
FM_GATE_CALL_CAP_KEY=120

# Appended to whichever field the shortening loop cut, so the VALUE says it
# was shortened and says which field it was. `"truncated":true` is a sibling
# field a renderer can forget to consult; a sentence that stops mid-word with
# nothing after it reads as the whole reason. Plain ASCII so it survives every
# locale and adds no multi-byte cut point of its own.
FM_GATE_CALL_CUT_MARK='...'

# How much of `grounds`/`what` the shortening loop keeps before it starts
# dropping presentation instead. Below this the entry stops being a ruling -
# "a ruling with no reason is not a ruling" - so a long link is dropped before
# the reason is.
FM_GATE_CALL_MIN_BODY=120

FM_GATE_CALL_VERDICTS='decided escalated refused deferred'

fm_gate_calls_path() {  # <state-dir>
  printf '%s/gate-calls.jsonl\n' "$1"
}

fm_gate_calls_drops_path() {  # <state-dir>
  printf '%s/gate-calls.drops\n' "$1"
}

fm_gate_call_bytes() {  # <text> -> byte length on stdout
  printf '%s' "$1" | wc -c | tr -d ' '
}

# Cut to a BYTE length. A bare slice counts characters under a UTF-8 locale,
# so it cannot enforce a byte cap; `local LC_ALL=C` makes the slice byte-wise
# whatever the caller's locale is, and restores on return.
fm_gate_call_cut_bytes() {  # <text> <max-bytes>
  local LC_ALL=C
  printf '%s' "${1:0:$2}"
}

# JSON string content for one field. Newlines survive as \n; the remaining C0
# controls are dropped because they would break the line and carry no meaning
# in a summary.
fm_gate_call_json_escape() {  # <text>
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

fm_gate_call_one_line() {  # <text>
  case "$1" in
    *$'\n'* | *$'\r'*) return 1 ;;
  esac
  return 0
}

# Assemble the record line. The log and the drops sidecar both reach the file
# through this, so they carry byte-identical objects apart from "dropped".
fm_gate_call_line() {  # <at> <site> <task> <verdict> <what> <grounds> <link> <key> <truncated> <rejected> [dropped]
  local at=$1 site=$2 task=$3 verdict=$4 what=$5 grounds=$6 link=$7 key=$8
  local truncated=$9 rejected=${10} dropped=${11:-} tail=''
  [ -z "$dropped" ] \
    || tail=$(printf ',"dropped":"%s"' "$(fm_gate_call_json_escape "$dropped")")
  printf '{"at":"%s","site":"%s","task":"%s","verdict":"%s","what":"%s","grounds":"%s","link":"%s","key":"%s","truncated":%s,"rejected":"%s"%s}' \
    "$(fm_gate_call_json_escape "$at")" \
    "$(fm_gate_call_json_escape "$site")" \
    "$(fm_gate_call_json_escape "$task")" \
    "$(fm_gate_call_json_escape "$verdict")" \
    "$(fm_gate_call_json_escape "$what")" \
    "$(fm_gate_call_json_escape "$grounds")" \
    "$(fm_gate_call_json_escape "$link")" \
    "$(fm_gate_call_json_escape "$key")" \
    "$truncated" \
    "$(fm_gate_call_json_escape "$rejected")" \
    "$tail"
}

# One byte's numeric value, 0..255. `printf %d "'<byte>"` answers with a
# SIGNED char, so 0xE4 comes back as -28; without the correction below every
# UTF-8 lead byte reads as a negative number and the trim below silently does
# nothing.
fm_gate_call_byte_ord() {  # <single byte>
  local ord
  ord=$(printf '%d' "'$1")
  [ "$ord" -ge 0 ] || ord=$((ord + 256))
  printf '%s' "$ord"
}

# Remove a trailing INCOMPLETE UTF-8 sequence, leaving complete characters and
# plain bytes alone.
#
# The shortening loop measures in bytes but cuts with a slice, and a slice
# counts characters under a UTF-8 locale and BYTES under LC_ALL=C. So under a
# C locale - which bin/fm-inactive-reconcile.sh exports, and which any caller
# may have - the cut lands mid-character and the line stops being valid UTF-8,
# which means it stops being valid JSON. A strict reader then rejects the
# whole line, and a rejected line is a lost record with no drops entry: the
# same invisible loss as a torn line, by a third door.
#
# Repairing after the cut, rather than forcing a locale, works whichever
# semantics the slice used.
fm_gate_call_trim_partial_utf8() {  # <text>
  local LC_ALL=C text=$1 cont=0 rest ord need
  rest=$text
  while [ "$cont" -lt 3 ] && [ -n "$rest" ]; do
    ord=$(fm_gate_call_byte_ord "${rest: -1}")
    [ "$ord" -ge 128 ] && [ "$ord" -le 191 ] || break
    rest=${rest%?}
    cont=$((cont + 1))
  done
  if [ -z "$rest" ]; then
    # Nothing but continuation bytes: no lead byte survived the cut at all.
    printf '%s' ''
    return 0
  fi
  ord=$(fm_gate_call_byte_ord "${rest: -1}")
  if [ "$ord" -ge 194 ] && [ "$ord" -le 223 ]; then
    need=1
  elif [ "$ord" -ge 224 ] && [ "$ord" -le 239 ]; then
    need=2
  elif [ "$ord" -ge 240 ] && [ "$ord" -le 244 ]; then
    need=3
  else
    need=0
  fi
  if [ "$need" -eq 0 ]; then
    # No lead byte here, so any continuations collected are orphans whose
    # lead is already gone and dropping them is the repair.
    if [ "$cont" -gt 0 ]; then printf '%s' "$rest"; else printf '%s' "$text"; fi
  elif [ "$cont" -eq "$need" ]; then
    printf '%s' "$text"
  else
    printf '%s' "${rest%?}"
  fi
}

# Hold the assembled line under the byte bound by shortening the two free-text
# fields, longest first, and declaring in the record that it happened. Halving
# terminates: each pass strictly shrinks the field, an empty field cannot be
# shortened again, and the identity fields left behind are capped above, so
# what remains always fits. Publishes FM_GATE_CALL_BOUNDED_LINE.
FM_GATE_CALL_BOUNDED_LINE=
fm_gate_call_bounded_line() {  # <at> <site> <task> <verdict> <what> <grounds> <link> <key> <truncated> <rejected> [dropped]
  local at=$1 site=$2 task=$3 verdict=$4 what=$5 grounds=$6 link=$7 key=$8
  local truncated=$9 rejected=${10} dropped=${11:-} line
  local grounds_body=$grounds what_body=$what
  line=$(fm_gate_call_line "$at" "$site" "$task" "$verdict" "$what" "$grounds" \
    "$link" "$key" "$truncated" "$rejected" "$dropped")
  while [ "$(fm_gate_call_bytes "$line")" -gt "$FM_GATE_CALL_MAX_LINE" ]; do
    truncated=true
    # Order matters, and it is the whole point of this ladder. Shorten the
    # substance first, but stop at FM_GATE_CALL_MIN_BODY and drop presentation
    # rather than reduce a ruling to its marker; only if dropping both still
    # leaves the line over the bound does the substance go. Halve the BODY and
    # re-apply the marker, rather than halving a value that already carries
    # one, so the marker never accumulates.
    if [ "${#grounds_body}" -gt "$FM_GATE_CALL_MIN_BODY" ]; then
      grounds_body=$(fm_gate_call_trim_partial_utf8 \
        "${grounds_body:0:$(( ${#grounds_body} / 2 ))}")
      grounds="$grounds_body$FM_GATE_CALL_CUT_MARK"
    elif [ "${#what_body}" -gt "$FM_GATE_CALL_MIN_BODY" ]; then
      what_body=$(fm_gate_call_trim_partial_utf8 \
        "${what_body:0:$(( ${#what_body} / 2 ))}")
      what="$what_body$FM_GATE_CALL_CUT_MARK"
    elif [ -n "$link" ]; then
      link=''
      rejected="${rejected:+$rejected,}link"
    elif [ -n "$key" ]; then
      key=''
      rejected="${rejected:+$rejected,}key"
    elif [ -n "$grounds_body" ]; then
      grounds_body=$(fm_gate_call_trim_partial_utf8 \
        "${grounds_body:0:$(( ${#grounds_body} / 2 ))}")
      grounds="$grounds_body$FM_GATE_CALL_CUT_MARK"
    elif [ -n "$what_body" ]; then
      what_body=$(fm_gate_call_trim_partial_utf8 \
        "${what_body:0:$(( ${#what_body} / 2 ))}")
      what="$what_body$FM_GATE_CALL_CUT_MARK"
    else
      break
    fi
    line=$(fm_gate_call_line "$at" "$site" "$task" "$verdict" "$what" "$grounds" \
      "$link" "$key" "$truncated" "$rejected" "$dropped")
  done
  FM_GATE_CALL_BOUNDED_LINE=$line
}

# Report a call that could not be recorded: the drops sidecar first, then the
# stderr line either way. Never exits, always returns 1; the caller's mandatory
# `|| true` is what keeps that 1 from stopping the fleet action.
fm_gate_call_drop() {  # <state-dir> <reason> <at> <site> <task> <verdict> <what> <grounds> <link> <key> <truncated> <rejected>
  local state=$1 reason=$2 at=$3 site=$4 task=$5 verdict=$6 what=$7 grounds=$8
  local link=$9 key=${10} truncated=${11} rejected=${12} drops line where='stderr only'
  drops=$(fm_gate_calls_drops_path "$state")
  # A call refused for an over-long identity field still has to be written
  # down, so here - and only here, where the record already says it was
  # dropped - those fields are cut to their caps rather than refused again.
  [ "$(fm_gate_call_bytes "$site")" -le "$FM_GATE_CALL_CAP_SITE" ] \
    || { site=$(fm_gate_call_cut_bytes "$site" "$FM_GATE_CALL_CAP_SITE"); truncated=true; }
  [ "$(fm_gate_call_bytes "$task")" -le "$FM_GATE_CALL_CAP_TASK" ] \
    || { task=$(fm_gate_call_cut_bytes "$task" "$FM_GATE_CALL_CAP_TASK"); truncated=true; }
  [ "$(fm_gate_call_bytes "$link")" -le "$FM_GATE_CALL_CAP_LINK" ] \
    || { link=$(fm_gate_call_cut_bytes "$link" "$FM_GATE_CALL_CAP_LINK"); truncated=true; }
  [ "$(fm_gate_call_bytes "$key")" -le "$FM_GATE_CALL_CAP_KEY" ] \
    || { key=$(fm_gate_call_cut_bytes "$key" "$FM_GATE_CALL_CAP_KEY"); truncated=true; }
  fm_gate_call_bounded_line "$at" "$site" "$task" "$verdict" "$what" "$grounds" \
    "$link" "$key" "$truncated" "$rejected" "$reason"
  line=$FM_GATE_CALL_BOUNDED_LINE
  if [ ! -L "$drops" ] && printf '%s\n' "$line" >> "$drops" 2>/dev/null; then
    where=$drops
  fi
  printf 'actionable: a firstmate gate call was not recorded (%s); the gatekeeping record for task "%s" is incomplete (reported in %s)\n' \
    "$reason" "${task:-unnamed}" "$where" >&2
  return 1
}

# Append one gate call to the log.
#   fm_gate_call_record <state-dir> <site> <task> <verdict> <what> <grounds> [link] [key]
# Returns 0 when the line is in the log, 1 when the call was dropped and
# reported. Never exits - but see OBSERVER, NEVER A GATE above: under `set -e`
# the caller must guard the call with `|| true` or an `if`, or that 1 exits
# the caller's shell and this observer becomes a gate.
fm_gate_call_record() {  # <state-dir> <site> <task> <verdict> <what> <grounds> [link] [key]
  local state=${1:-} site=${2:-} task=${3:-} verdict=${4:-} what=${5:-} grounds=${6:-}
  local link=${7:-} key=${8:-}
  local at log line truncated=false rejected='' known found=0 link_ok=1 key_ok=1

  at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)

  if [ -z "$state" ] || [ ! -d "$state" ]; then
    printf 'actionable: a firstmate gate call was not recorded (no writable state directory "%s"); the gatekeeping record for task "%s" is incomplete (reported in stderr only)\n' \
      "$state" "${task:-unnamed}" >&2
    return 1
  fi

  # Everything below reports through fm_gate_call_drop, which needs the fields
  # it is handed to already be presentable, so validate before shortening.
  if [ -z "$at" ]; then
    fm_gate_call_drop "$state" 'the clock could not be read' \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  for known in $FM_GATE_CALL_VERDICTS; do
    [ "$known" = "$verdict" ] && found=1
  done
  if [ "$found" -ne 1 ]; then
    fm_gate_call_drop "$state" "verdict must be one of: $FM_GATE_CALL_VERDICTS" \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  case "$site" in
    '' | -* | *[!a-z0-9-]*)
      fm_gate_call_drop "$state" 'site must be a lowercase dashed name' \
        "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
      return 1 ;;
  esac
  if [ "$(fm_gate_call_bytes "$site")" -gt "$FM_GATE_CALL_CAP_SITE" ]; then
    fm_gate_call_drop "$state" "site must be at most $FM_GATE_CALL_CAP_SITE bytes" \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  case "$task" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
      fm_gate_call_drop "$state" 'task must be a task id' \
        "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
      return 1 ;;
  esac
  if [ "$(fm_gate_call_bytes "$task")" -gt "$FM_GATE_CALL_CAP_TASK" ]; then
    fm_gate_call_drop "$state" "task must be at most $FM_GATE_CALL_CAP_TASK bytes" \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  if [ -z "$what" ]; then
    fm_gate_call_drop "$state" 'the call must say what it was about' \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  if [ -z "$grounds" ]; then
    fm_gate_call_drop "$state" 'the call must state its grounds' \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  if ! fm_gate_call_one_line "$what" || ! fm_gate_call_one_line "$link" \
    || ! fm_gate_call_one_line "$key"; then
    fm_gate_call_drop "$state" 'only the grounds may span lines' \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  # link and key are presentation, not identity: a malformed one is dropped
  # and named in `rejected` so the degradation is visible in the record, and
  # the call itself - who, what, why, the verdict - is still logged. See TWO
  # SEVERITIES OF BAD INPUT above.
  if [ -n "$link" ]; then
    link_ok=1
    case "$link" in
      http://?* | https://?*)
        case "$link" in
          *[[:space:]]*) link_ok=0 ;;
        esac ;;
      *) link_ok=0 ;;
    esac
    [ "$(fm_gate_call_bytes "$link")" -le "$FM_GATE_CALL_CAP_LINK" ] || link_ok=0
    if [ "$link_ok" -ne 1 ]; then
      link=''
      rejected='link'
    fi
  fi
  if [ -n "$key" ]; then
    key_ok=1
    case "$key" in
      *[!A-Za-z0-9._:-]*) key_ok=0 ;;
    esac
    [ "$(fm_gate_call_bytes "$key")" -le "$FM_GATE_CALL_CAP_KEY" ] || key_ok=0
    if [ "$key_ok" -ne 1 ]; then
      key=''
      rejected="${rejected:+$rejected,}key"
    fi
  fi

  fm_gate_call_bounded_line "$at" "$site" "$task" "$verdict" "$what" "$grounds" \
    "$link" "$key" "$truncated" "$rejected"
  line=$FM_GATE_CALL_BOUNDED_LINE

  log=$(fm_gate_calls_path "$state")
  if [ -L "$log" ]; then
    fm_gate_call_drop "$state" 'the gate-call log is a symlink, not the append-only file' \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  if ! printf '%s\n' "$line" >> "$log" 2>/dev/null; then
    fm_gate_call_drop "$state" 'the gate-call log could not be appended to' \
      "$at" "$site" "$task" "$verdict" "$what" "$grounds" "$link" "$key" "$truncated" "$rejected"
    return 1
  fi
  return 0
}
