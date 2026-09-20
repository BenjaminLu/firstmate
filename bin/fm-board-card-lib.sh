#!/usr/bin/env bash
# fm-board-card-lib.sh - the one owner of a captain call's CARD record.
#
# WHY THIS EXISTS
#
# The captain ruled on 2026-09-20 that the board's cards must be realtime:
# 看板的卡片我要一個realtime方案，不要你每次重建，沒意義. A card that arrives
# without a model composing it must carry its content as structured data
# written at the moment the call is raised, because after the fact is exactly
# the rebuild he refused.
#
# THE OBLIGATION THIS CREATES IS NARROW, AND STAYS NARROW
#
# Read this paragraph before adding any requirement to this file.
#
# PR #33 removed the decision packet as a blanket obligation: a `needs-decision`
# is NOT required to produce or verify a packet, and that removal STANDS. This
# library does not bring it back and must never be extended to.
#
# What the captain approved is one narrow rule: a call that wants a FULL OPTION
# CARD - N choices with per-option consequence and risk - carries those options
# as structured data when it is raised. A call that wants no such card carries
# nothing extra and is unaffected. Concretely:
#
#   --card-file given     -> a full option card. The file must be a valid
#                            fm-packet-decision.v1 block or the hold REFUSES.
#   --card-file absent    -> a thin card. Title, what to decide, and a
#                            free-form answer box. No obligation of any kind.
#
# Merge cards need neither: their options are a fixed vocabulary and the rest
# is forge data, so they are composed from what the task already records.
#
# If a future change makes a packet required for a call that did not ask for a
# full card, that change has recreated the blanket rule the captain deliberately
# removed, whatever it is called.
#
# A THIN CARD IS VISIBLY THIN, AND A BROKEN ONE REFUSES
#
# The failure this whole line of work exists to remove is the captain acting on
# a surface that looks complete and is not. A card silently missing its options
# is that same failure wearing a nicer face, so there are two rules:
#
#   - A thin card is RECORDED as thin (`"thin": true`, `"options": []`). The
#     board renders it saying it carries no options. It never renders as a full
#     card with an empty option list.
#   - A card file that was GIVEN and cannot be used is a REFUSAL, never a
#     silent downgrade to thin. A caller that meant to ship options and shipped
#     a malformed file must hear about it, because the alternative is a card
#     the captain answers believing he saw the choices.
#
# This is the one place these two differ from the gate-call log's posture. That
# log is an observer and must never fail its caller. A missing card is a call
# the captain never sees, so this refuses loudly instead.
#
# CONTRACT (this header is the one owner of the format).
#
#   One file per call: <state>/board-cards/<task-id>.json, replaced
#   atomically. A card is MUTABLE by design - it must be able to say it was
#   answered, or that a pull request appeared after it was raised - which is
#   why it is not an append-only log and why it is a separate record from
#   <state>/gate-calls.jsonl rather than a field on it.
#
#   The two records share one identity: the same task id and the same
#   captain-hold key. A reader joins them; neither duplicates the other. The
#   gate log is the immutable audit of firstmate's judgement at the instant of
#   the call; this is the call's current state.
#
#     {"schema":"fm-board-card.v1","task":"<id>","key":"<routing key>",
#      "at":"<UTC ISO-8601 seconds>","state":"open|answered|deferred",
#      "thin":true|false,"title":"<copy>","repo":"<repo or empty>",
#      "decide":"<copy>","if_nothing":"<copy>","reversible":"yes|no|partly",
#      "risk":"low|medium|high","options":[...],"recommend_value":"<value>",
#      "recommend_why":"<copy>","close":"done|release|","figures":[...]}
#
#   A copy field is a plain string or an {en,hant?,hans?} object, exactly as
#   fm-bearings-board.v1 defines it, so the board renders a card record with no
#   conversion. `options`, `recommend_value`, `recommend_why`, `close` and
#   `figures` come from the fm-packet-decision.v1 block when one was given; on
#   a thin card `options` is empty and `thin` is true.
#
# Sourced, never executed.

# Guard against double-sourcing; this file defines functions only.
[ -n "${FM_BOARD_CARD_LIB_LOADED:-}" ] && return 0
FM_BOARD_CARD_LIB_LOADED=1

FM_BOARD_CARD_SCHEMA=fm-board-card.v1

# Where this home keeps its card records.
fm_board_card_dir() {  # <state-dir>
  printf '%s/board-cards\n' "$1"
}

fm_board_card_path() {  # <state-dir> <task-id>
  printf '%s/%s.json\n' "$(fm_board_card_dir "$1")" "$2"
}

# Is this a usable fm-packet-decision.v1 block?
#
# The checks are the ones that decide whether a CARD can be rendered from it,
# not a re-implementation of bin/fm-packet.sh's own validation - that script
# owns the packet's contract and this owns the card's. What a card cannot do
# without: at least two options, each with a value and a label, and a title.
# Everything else is optional and simply absent from the card.
fm_board_card_block_ok() {  # <path>; prints the reason on stderr when not
  local path=$1
  [ -r "$path" ] || { printf 'card file cannot be read: %s\n' "$path" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'jq is required to read a card file\n' >&2; return 1; }
  jq -e '
    type == "object"
    and ((.title | type == "string" and length > 0) or (.title | type == "object"))
    and (.options | type == "array")
    and ((.options | length) >= 2)
    and ([.options[]
      | type == "object"
        and (.value | type == "string" and length > 0)
        and ((.label | type == "string" and length > 0) or (.label | type == "object"))]
      | all)
  ' "$path" >/dev/null 2>&1 && return 0
  printf 'card file is not a usable fm-packet-decision.v1 block: %s\n' "$path" >&2
  printf 'a full option card needs a title and at least two options, each with a value and a label\n' >&2
  return 1
}

# Write the card record for a call being raised.
#
# Returns nonzero on failure, and the caller is expected to REFUSE rather than
# continue - see the header. This is deliberately not the gate log's posture.
fm_board_card_write() {  # <state-dir> <task-id> <key> <title> <repo> <reason> [<block-path>]
  local state=$1 task=$2 key=$3 title=$4 repo=$5 reason=$6 block=${7:-}
  local dir at tmp
  dir=$(fm_board_card_dir "$state")
  mkdir -p "$dir" 2>/dev/null || { printf 'cannot create %s\n' "$dir" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'jq is required to write a card record\n' >&2; return 1; }
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(fm_board_card_path "$state" "$task").tmp.$$

  if [ -n "$block" ]; then
    # A full option card. Every field the block carries reaches the card; the
    # ones it does not are absent rather than invented.
    jq -n --arg schema "$FM_BOARD_CARD_SCHEMA" --arg task "$task" --arg key "$key" \
      --arg at "$at" --arg repo "$repo" --arg reason "$reason" \
      --slurpfile b "$block" '
      ($b[0] // {}) as $d
      | {schema:$schema, task:$task, key:$key, at:$at, state:"open", thin:false,
         title: ($d.title // $reason), repo:$repo,
         decide: ($d.decide // $reason),
         if_nothing: ($d.if_nothing // ""),
         reversible: ($d.reversible // "yes"),
         risk: ($d.risk // "medium"),
         options: ($d.options // []),
         recommend_value: ($d.recommend_value // ""),
         recommend_why: ($d.recommend_why // ""),
         close: ($d.close // ""),
         figures: ($d.figures // [])}' > "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; printf 'cannot build the card record for %s\n' "$task" >&2; return 1; }
  else
    # A thin card, recorded AS thin. The reason string is what the captain is
    # being asked, because on a thin call it is the only statement of the
    # question that exists.
    jq -n --arg schema "$FM_BOARD_CARD_SCHEMA" --arg task "$task" --arg key "$key" \
      --arg at "$at" --arg title "$title" --arg repo "$repo" --arg reason "$reason" '
      {schema:$schema, task:$task, key:$key, at:$at, state:"open", thin:true,
       title: (if ($title | length) > 0 then $title else $reason end),
       repo:$repo, decide:$reason, if_nothing:"", reversible:"yes", risk:"medium",
       options: [], recommend_value:"", recommend_why:"", close:"", figures: []}' > "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; printf 'cannot build the card record for %s\n' "$task" >&2; return 1; }
  fi

  mv -f "$tmp" "$(fm_board_card_path "$state" "$task")" 2>/dev/null && return 0
  rm -f "$tmp"
  printf 'cannot write the card record for %s\n' "$task" >&2
  return 1
}

# Move a card to a terminal state. A card that does not exist is not an error:
# a call raised before this library existed simply has no record, and refusing
# its answer would be worse than letting the answer through.
fm_board_card_close() {  # <state-dir> <task-id> <state: answered|deferred>
  local state=$1 task=$2 to=$3 path tmp
  path=$(fm_board_card_path "$state" "$task")
  [ -f "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 1
  tmp="$path.tmp.$$"
  jq --arg to "$to" '.state = $to' "$path" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}
