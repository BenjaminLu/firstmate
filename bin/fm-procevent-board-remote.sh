#!/usr/bin/env bash
# Remote-board answer adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-board-remote.sh arm --key <key>[=done|release] [--key ...]
#   fm-procevent-board-remote.sh ingest --documents <dir>
#   fm-procevent-board-remote.sh tick [--interval <secs>]
#   fm-procevent-board-remote.sh classify <result-file>
#   fm-procevent-board-remote.sh terminal <result-file>
#   fm-procevent-board-remote.sh silent <result-file>
#   fm-procevent-board-remote.sh source-id
#   fm-procevent-board-remote.sh retire
#
# THE ONE THING THAT IS DIFFERENT FROM EVERY OTHER ADAPTER HERE. The remote
# board's answers live in a claude.ai artifact database that only a first-party
# Claude session's own Artifact tool can read, so - unlike Lavish or quota - the
# registered child CANNOT perform the read. It is a timer: it waits, and wakes
# firstmate, whose session does the one read and hands the documents to
# `ingest`. Registration, durable capture, acknowledgement and retirement are
# the unchanged family contract in bin/fm-procevent.sh; only the read is
# firstmate's own. Nobody needs to spend an hour re-deriving that: `claude -p`
# has no Artifact tool even when it is named explicitly, the CLI has no artifact
# subcommand, no MCP server exposes the database, and the artifact URL refuses
# an unauthenticated request.
#
# WHAT ARMS IT AND WHAT RETIRES IT, so a reader can tell whether it should be
# running right now.
#   arms:    `arm`, naming every card on the board the captain has not answered.
#            Composing a board that carries open cards is the moment to call it.
#   retires: `ingest`, the moment the last awaited key has an answer. That is
#            the deterministic path, not something an agent has to remember.
#            A `tick` that finds nothing awaited is the backstop: it classifies
#            `settled`, which the runner treats as both silent and terminal, so
#            the source retires without announcing anything.
#            `retire` is the explicit path for a board rebuilt with no cards.
# Whether a runner is actually listening is bin/fm-procevent.sh list's fact, not
# this script's.
#
# So the cost is genuinely gated. While a card is open, one short firstmate turn
# per interval; while none is, the source does not exist and nothing is woken at
# all. The cadence is fixed rather than a caller's knob: the board already
# promises the captain a real consequence within about a minute, so a finer
# interval cannot be noticed and still spends a turn every time.
#
# Stated plainly rather than accepted quietly: this is SLOWER than the local
# Lavish board it replaces, which woke firstmate within seconds of a click
# because its poll blocked on the click itself. An interval is the best a
# surface with no event can do, and `bearings` owns that standard. If seconds
# are wanted here, the way back is a transport that can be woken - a signed-in
# browser holding the page, or a session that can perform the read - not a
# finer interval.
#
# A FAILED READ LOSES NOTHING, and that is a property of this store rather than
# of this script. The artifact read returns documents without consuming or
# clearing them, so an answer that is not captured stays exactly where it was
# and the next read returns it again. `ingest` therefore never writes to the
# documents it is given, and advances its durable cursor only after the answers
# it found are recorded here. Anything that fails before that - an unreadable
# directory, a record that cannot be written - leaves the cursor untouched and
# the answer is delivered on the next pass. This is the pre-capture window the
# published Lavish poll has and cannot close, and it is absent here.
#
# NEVER THE SAME ANSWER TWICE. The cursor is a set of answer identities, never a
# position and never a count, so a document that is re-read, re-ordered,
# re-listed beside new ones, or read again after a crash is recognized as the
# same answer. An identity is the document's own id together with the digest of
# its canonical stored content, so a changed answer under one key is a different
# answer and is delivered, while an unchanged one is not. Nothing is ever pruned
# from the cursor: the store keeps a document until the captain changes it, so
# forgetting an identity would re-deliver an answer that is still sitting there.
# The cursor grows by one line per distinct answer ever given.
#
# AN ARM OPENS A GENERATION, which is how a never-pruned cursor and a reusable
# card key live together. `dispatch.charted` is asked again on every board round,
# so "has this key ever been answered" is the wrong question; "has it been
# answered since it was armed" is the right one. `arm` bumps a counter and stamps
# every awaited card with it, `ingest` stamps every record it writes with the
# counter's value at delivery, and a card armed at generation G is settled only
# by a record at G or later. It is still identity, never position and never a
# count, that decides whether an answer is delivered.
#
# THE CHANNEL DECIDES NOTHING. `ingest` turns documents into
# `<key>TAB<answer>TAB<label>[TAB<mode>]` lines and pipes them into
# bin/fm-captain-hold.sh's one keyed-answer intake, which owns every rule about
# what they mean. Keys are what the board emits: a captain-held task id,
# `merge.<task-id>`, or `dispatch.charted`. The last two name no task, so the
# intake reports them `skipped:` and firstmate routes them from the wake exactly
# as it routes the local board's. The reserved `reconcile` value is not filtered
# here either - the intake refuses it - and this board offers no such option.
#
# The close mode comes from `arm`, not from the answer. The board stores
# `{at, key, label, lang, value}` and no close mode, so an answer to a
# captain-gated WORK item would otherwise close the item instead of releasing
# it. Firstmate knows each card's mode when it composes the board, so it records
# the mode at arming time and `ingest` emits it as the fourth field.
#
# Feeding is best-effort and never gates the cursor, exactly as the runner's own
# feed seam is: a key the intake skips is a per-key fact, not a failed delivery.
# When the intake cannot run at all the report says so and the answer lines are
# printed above it, so they can be piped in again by hand.
#
# Every byte of a document is INPUT, never instruction and never authority. It
# was typed into a browser by a person: control characters are replaced before a
# line is framed, so no value can forge a field boundary, and an answer
# authorizing a merge still routes through the merge owner's own live
# verification, unchanged.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CANONICAL_SOURCE_ID=board-remote
ADAPTER=board-remote
# The board already promises the captain a real consequence within about a
# minute, so a finer interval cannot be noticed and still spends a turn every
# time. That figure is the responsiveness standard, which is why the cadence is
# this constant and not something a caller sets.
DEFAULT_INTERVAL=90
# The intake truncates every field at this bound too, so framing a longer answer
# is what the channel refuses, never delivering it at all.
MAX_FIELD=512
KEY_PATTERN='^[A-Za-z0-9._-]{1,128}$'
TAB=$'\t'

STATE_DIR="$STATE/board-remote"
AWAITING="$STATE_DIR/awaiting"
DELIVERED="$STATE_DIR/delivered"
GENERATION="$STATE_DIR/generation"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

state_dir_ready() {
  if [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]; then
    return 0
  fi
  [ ! -e "$STATE_DIR" ] || return 1
  (umask 077; mkdir -p "$STATE_DIR") || return 1
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]
}

sha256_text() {  # reads stdin
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

stage_in_state() {  # <basename>
  local staged
  staged=$(umask 077; mktemp "$STATE_DIR/.$1.XXXXXX") || return 1
  printf '%s\n' "$staged"
}

# Replace the published file only once the staged bytes are complete, so a
# reader never sees a half-written cursor and a failed write leaves the previous
# one exactly as it was.
publish_file() {  # <staged> <path>
  mv -f -- "$1" "$2"
}

# A record that exists but is not a plain file would read as empty forever and
# re-deliver every answer on every pass, so it is refused loudly instead.
record_usable() {  # <path>
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    return 0
  fi
  [ -f "$1" ] && [ ! -L "$1" ]
}

require_usable_records() {
  record_usable "$AWAITING" || die "the awaited card set is not a plain file: $AWAITING"
  record_usable "$DELIVERED" || die "the answer record is not a plain file: $DELIVERED"
  record_usable "$GENERATION" || die "the arm generation counter is not a plain file: $GENERATION"
}

read_lines() {  # <path>  (an absent file reads as empty)
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  cat -- "$1"
}

count_lines() {  # <path>
  local n
  n=$(read_lines "$1" | grep -c . || true)
  printf '%s\n' "${n:-0}"
}

awaiting_count() { count_lines "$AWAITING"; }

# A counter that has never been written, or that no longer reads as a whole
# number, is generation 0: every card armed from here carries a higher one, so
# no record can settle a card it did not answer.
current_generation() {
  local n
  n=$(read_lines "$GENERATION" | head -1)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# The counter is published before the awaited set that cites it, so a crash in
# between skips a generation rather than handing two boards the same one.
open_generation() {
  local n staged
  n=$(( $(current_generation) + 1 ))
  staged=$(stage_in_state generation) || return 1
  printf '%s\n' "$n" > "$staged" || { rm -f -- "$staged"; return 1; }
  publish_file "$staged" "$GENERATION" || { rm -f -- "$staged"; return 1; }
  printf '%s\n' "$n"
}

# --- arming -----------------------------------------------------------------

valid_key() {
  local LC_ALL=C
  [[ "${1-}" =~ $KEY_PATTERN ]]
}

positive_number() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ ! "${1-}" =~ ^0+(\.0+)?$ ]]
}

cmd_arm() {
  local key mode staged generation entry
  local -a keys=() awaited=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)
        [ -n "${2-}" ] || die "--key needs a board card key"
        key=${2%%=*}
        mode=''
        case "$2" in *=*) mode=${2#*=} ;; esac
        valid_key "$key" \
          || die "a card key is letters, digits, dot, dash or underscore, at most 128 of them: $key"
        case "$mode" in
          ''|done) mode='' ;;
          release) : ;;
          *) die "a card close mode is done or release: $mode" ;;
        esac
        keys+=("$key$TAB$mode")
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ "${#keys[@]}" -gt 0 ] \
    || die "arm needs at least one --key: a source with nothing awaited would wake firstmate for a board nobody owes an answer on"
  state_dir_ready || die "cannot prepare the adapter's state directory: $STATE_DIR"
  require_usable_records
  generation=$(open_generation) || die "cannot open a new arm generation"
  for entry in "${keys[@]}"; do
    awaited+=("$entry$TAB$generation")
  done
  # The awaited set is written BEFORE the registration, so a tick can never run
  # against a missing record and read a freshly armed board as settled.
  staged=$(stage_in_state awaiting) || die "cannot stage the awaited card set"
  printf '%s\n' "${awaited[@]}" > "$staged" \
    || { rm -f -- "$staged"; die "cannot write the awaited card set"; }
  publish_file "$staged" "$AWAITING" \
    || { rm -f -- "$staged"; die "cannot publish the awaited card set"; }
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-board-remote.sh" tick --interval "$DEFAULT_INTERVAL" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'interval: %ss\n' "$DEFAULT_INTERVAL"
  printf 'awaiting: %s\n' "${#keys[@]}"
}

cmd_source_id() { printf '%s\n' "$CANONICAL_SOURCE_ID"; }

cmd_retire() { "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID"; }

# --- the registered child ---------------------------------------------------

# The blocking child the generic runner executes; never run it in a
# conversational turn. It carries no board bytes at all: it says only that the
# interval elapsed and whether anything is still awaited.
cmd_tick() {
  local interval=$DEFAULT_INTERVAL state count
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)
        positive_number "${2-}" || die "--interval needs a positive number"
        interval=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  count=$(awaiting_count)
  # An already-settled source retires on its first tick rather than sleeping out
  # an interval nobody is waiting on.
  if [ "$count" -gt 0 ]; then
    sleep "$interval"
    count=$(awaiting_count)
  fi
  if [ "$count" -gt 0 ]; then
    state=due
  else
    state=settled
  fi
  printf 'board-remote: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'state: %s\n' "$state"
  printf 'awaiting: %s\n' "$count"
  printf 'interval: %s\n' "$interval"
}

# Read the state from the result's own leading block, so a later line can never
# supply it. This adapter's result carries no external bytes at all, and the
# anchored read keeps that true if one is ever added.
result_state() {  # <result-file>
  awk '
    /^state: (due|settled)$/ { sub(/^state: /, ""); print; exit }
    !/^[a-z][a-z-]*: / { exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} state
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  state=$(result_state "$file")
  case "$state" in
    due|settled) printf '%s\n' "$state" ;;
    *) printf 'unknown\n' ;;
  esac
}

# A settled tick ends this source: nothing is awaited, so no later tick can
# carry news. Anything else - an unreadable result included - stays armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ "$(cmd_classify "$file")" = settled ]
}

# A settled tick is also the routine no-op: announcing it would wake firstmate
# to be told that a board nobody owes an answer on has nothing new. A `due` tick
# is the wake, and an unknown result always announces.
cmd_silent() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ "$(cmd_classify "$file")" = settled ]
}

# --- the read firstmate performs --------------------------------------------

# Print one document's identity, or nothing when it is not a JSON object at all.
# The identity is the document's own id plus the digest of its canonical stored
# content, so it does not move when the listing does.
document_identity() {  # <doc-id> <file>
  local canon
  canon=$(jq -S -c 'if type == "object" then . else empty end' < "$2" 2>/dev/null) || return 1
  [ -n "$canon" ] || return 1
  printf '%s\n%s\n' "$1" "$canon" | sha256_text
}

# Print `<key>TAB<answer>TAB<label>` for one document, or nothing when its
# stored content is not an answer this channel can frame. Control characters are
# replaced before the line is built, so a typed value cannot forge a field, and
# the fields are joined with a literal tab rather than framed as TSV: no escape
# is needed once the separators are gone, and `@tsv` would double a backslash
# the captain typed into an answer that names a path.
document_row() {  # <file>
  jq -r --argjson max "$MAX_FIELD" '
    def clean: gsub("[\\x00-\\x1f\\x7f]"; " ");
    if type != "object" then empty
    else
      .key as $k | .value as $v | (.label // "") as $l |
      if ($k | type) != "string" or ($v | type) != "string" or ($l | type) != "string" then empty
      elif ($k | test("^[A-Za-z0-9._-]{1,128}$") | not) then empty
      elif ($v | length) == 0 then empty
      else [ $k, ($v[0:$max] | clean), ($l[0:$max] | clean) ] | join("\t")
      end
    end
  ' < "$1" 2>/dev/null
}

# The fields are read with awk rather than bash's own splitting, because `read`
# folds the empty close mode of an ordinary card into one separator and would
# hand back the card's generation as its mode.
awaited_mode() {  # <key>
  [ -f "$AWAITING" ] && [ ! -L "$AWAITING" ] || return 0
  awk -F'\t' -v key="$1" '$1 == key { print $2; exit }' "$AWAITING"
}

# Pipe the staged rows into the one keyed-answer intake. Best-effort by design:
# a key it skips is a per-key fact, and a total failure is reported with the
# rows still printed above, so they can be piped in again by hand.
feed_intake() {  # <rows-file>
  local out rc=0 summary
  out=$("$SCRIPT_DIR/fm-captain-hold.sh" answers --any-origin \
          --source "the captain's answer on the remote board" < "$1" 2>&1) || rc=$?
  summary=$(printf '%s\n' "$out" | sed -n 's/^answers: //p' | head -1)
  if [ -n "$summary" ]; then
    printf 'intake: %s\n' "$summary"
    printf '%s\n' "$out" | grep -E '^(closed|skipped|refused): ' | sed 's/^/intake-key: /' || true
    return 0
  fi
  printf 'intake: did not run (exit %s); the answer lines above still need feeding\n' "$rc" >&2
  printf '%s\n' "$out" | head -3 >&2
  return 1
}

# An awaited key is settled once an answer for it has been recorded SINCE IT WAS
# ARMED - not only one delivered on this pass, so a repeated ingest converges
# instead of drifting, and not one from an earlier generation, so asking the same
# key again on a later board round is a genuinely open card.
# The record is matched on its KEY COLUMN, never as a substring of the line: an
# answer's own value can be a task id - `dispatch.charted` carries exactly that -
# and a substring match would read one card's dispatch pick as an answer to the
# card that task happens to own.
answer_recorded() {  # <key> <armed-generation>
  [ -f "$DELIVERED" ] && [ ! -L "$DELIVERED" ] || return 1
  awk -F'\t' -v key="$1" -v gen="${2:-0}" \
    '$2 == key && ($6 + 0) >= (gen + 0) { found = 1; exit } END { exit !found }' "$DELIVERED"
}

prune_awaiting() {
  local lines line key generation staged
  local -a remaining=()
  lines=$(read_lines "$AWAITING")
  [ -n "$lines" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%"$TAB"*}
    generation=${line##*"$TAB"}
    case "$generation" in ''|*[!0-9]*) generation=0 ;; esac
    if answer_recorded "$key" "$generation"; then
      continue
    fi
    remaining+=("$line")
  done <<< "$lines"
  staged=$(stage_in_state awaiting) || die "cannot stage the awaited card set"
  if [ "${#remaining[@]}" -gt 0 ]; then
    printf '%s\n' "${remaining[@]}" > "$staged" \
      || { rm -f -- "$staged"; die "cannot write the awaited card set"; }
  else
    : > "$staged" || { rm -f -- "$staged"; die "cannot write the awaited card set"; }
  fi
  publish_file "$staged" "$AWAITING" \
    || { rm -f -- "$staged"; die "cannot publish the awaited card set"; }
}

# Retire only when this pass actually settled the last awaited card. An ingest
# run against a board that was never armed here has no source to retire and
# must not report one.
retire_when_settled() {  # <awaited-before>
  [ "$1" -gt 0 ] || return 0
  [ "$(awaiting_count)" -eq 0 ] || return 0
  if "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID" >/dev/null 2>&1; then
    printf 'retired: yes (every awaited card has an answer)\n'
  else
    printf 'retired: no (nothing is awaited, but the source could not be retired)\n' >&2
  fi
}

cmd_ingest() {
  local dir='' f docid identity row key answer label mode generation
  local documents=0 new=0 unusable=0 staged rows_file delivered_lines awaited_before
  local -a notes=() rows=() records=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --documents)
        [ -n "${2-}" ] || die "--documents needs the directory holding the answer documents"
        dir=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ -n "$dir" ] \
    || die "ingest needs --documents <dir>: the directory the artifact read wrote the answer documents into, which is <out_dir>/answers for the answers collection"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "not a directory: $dir"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  state_dir_ready || die "cannot prepare the adapter's state directory: $STATE_DIR"
  require_usable_records

  awaited_before=$(awaiting_count)
  generation=$(current_generation)
  delivered_lines=$(read_lines "$DELIVERED")
  for f in "$dir"/*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    documents=$((documents + 1))
    docid=${f##*/}
    docid=${docid%.json}
    identity=$(document_identity "$docid" "$f") || identity=''
    if [ -z "$identity" ]; then
      unusable=$((unusable + 1))
      notes+=("unparsable-document: $docid")
      continue
    fi
    case "$delivered_lines" in
      "$identity$TAB"*|*$'\n'"$identity$TAB"*) continue ;;
    esac
    row=$(document_row "$f")
    if [ -z "$row" ]; then
      unusable=$((unusable + 1))
      notes+=("unusable-document: $docid")
      continue
    fi
    IFS=$'\t' read -r key answer label <<< "$row"
    mode=$(awaited_mode "$key")
    new=$((new + 1))
    if [ -n "$mode" ]; then
      rows+=("$key$TAB$answer$TAB$label$TAB$mode")
    else
      rows+=("$key$TAB$answer$TAB$label")
    fi
    records+=("$identity$TAB$key$TAB$answer$TAB$label$TAB$mode$TAB$generation")
  done

  printf 'board-remote: ingest\n'
  printf 'documents: %s\n' "$documents"
  printf 'new: %s\n' "$new"
  printf 'unusable: %s\n' "$unusable"
  [ "${#notes[@]}" -eq 0 ] || printf '%s\n' "${notes[@]}"

  if [ "$new" -gt 0 ]; then
    # The cursor advances only once these answers are recorded here. Until that
    # write lands the store still holds them and the next pass finds them again.
    staged=$(stage_in_state delivered) || die "cannot stage the answer record"
    {
      [ -z "$delivered_lines" ] || printf '%s\n' "$delivered_lines"
      printf '%s\n' "${records[@]}"
    } > "$staged" || { rm -f -- "$staged"; die "cannot write the answer record"; }
    publish_file "$staged" "$DELIVERED" \
      || { rm -f -- "$staged"; die "cannot publish the answer record"; }
    printf 'cursor: advanced by %s\n' "$new"
    printf 'answer: %s\n' "${rows[@]}"
    rows_file=$(stage_in_state rows) || die "cannot stage the answer rows"
    printf '%s\n' "${rows[@]}" > "$rows_file" \
      || { rm -f -- "$rows_file"; die "cannot write the answer rows"; }
    feed_intake "$rows_file" || true
    rm -f -- "$rows_file"
  else
    printf 'cursor: unchanged (nothing new)\n'
    printf 'intake: not run (nothing new)\n'
  fi

  prune_awaiting
  printf 'awaiting: %s\n' "$(awaiting_count)"
  retire_when_settled "$awaited_before"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  ingest)    shift; cmd_ingest "$@" ;;
  tick)      shift; cmd_tick "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
