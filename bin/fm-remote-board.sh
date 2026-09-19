#!/usr/bin/env bash
# fm-remote-board.sh - derive the REMOTE bearings board from the shipped board.
#
# The bearings board has ONE definition: the shipped template
# (.agents/skills/bearings/assets/board-template.html). The remote board is
# that same board on a different transport - a private Claude artifact the
# captain can reach from a phone - and it is DERIVED from that template
# mechanically, never re-authored. Deriving is what makes parity structural:
# the remote page runs the template's own markup, stylesheet, copy and render
# script, so every card type with its badges and context rows, the packet and
# its figures including inline drawings, the queued and warning kinds with
# their counts, the pickers and the language switch all reach the remote board
# without anyone maintaining a list of them.
#
# Exactly two things differ, and both live in
# .agents/skills/bearings/assets/remote-transport.js:
#   data in    the payload embedded in the page is first paint and the offline
#              fallback; a live payload arrives from the artifact's store and
#              repaints through the SAME shipped renderer, with the connection
#              state shown on the page rather than failing silently.
#   answers out the shipped board sends every answer through
#              window.lavish.queuePrompt; the transport implements that one
#              interface against the artifact's store, under the keys the
#              template itself supplies (the captain-held task ids,
#              merge.<task>, dispatch.charted). Carrying those answers back to
#              firstmate belongs to another owner and is not done here.
#
# Usage:
#   fm-remote-board.sh path
#   fm-remote-board.sh render <data.json> [--out <file>]
#   fm-remote-board.sh check <published.html> [--out <file>]
#   fm-remote-board.sh publish <data.json>
#   fm-remote-board.sh url
#   fm-remote-board.sh doctor
#
# path       Print the shipped template this board is derived from.
# render     Validate <data.json> through `bin/fm-bearings-board.sh validate`,
#            then write the derived remote page: the template verbatim, that
#            payload in the template's own data slot, and the transport in
#            place of the template's script tag, carrying that script embedded
#            verbatim. Output goes to --out, else stdout. Injection escapes
#            every `<` in the compact JSON as the \u003c string escape, so a
#            payload string containing "</script>" can never terminate the data
#            block early.
# check      Prove the page published as the remote board is what TODAY'S
#            template derives. Re-derives from the current template using the
#            published page's own embedded payload and requires the result to
#            appear verbatim inside the published page, then reports the
#            publish-time wrapper it found and refuses when that wrapper
#            carries anything untracked. This is the parity check: a feature
#            added to the shipped board and not re-published here fails it,
#            instead of going missing on the captain's phone unmeasured.
#            Also runs the published page's own payload through the contract
#            owner and reports the verdict.
#            Get <published.html> with the Artifact tool's read_file action on
#            the board's artifact URL, asking for its `index.html`. There is no
#            credentialed CLI for that read, so this script takes the fetched
#            file rather than pretending it can fetch it. `--out` writes the
#            page it expected, for a direct diff when they disagree.
# publish    Prepare a publish and name the one step a shell cannot take.
#            Validates the payload, derives the page to this home's stable
#            remote-board path, reads the configured address, then prints the
#            exact operation to perform and EXITS 69. It never reports a
#            publish it did not make. 69 is this repository's "cannot run
#            here" status, the same one a missing linter uses.
# url        Print this home's configured remote board address; exit 1 with a
#            reason when the home has none.
# doctor     Report what is and is not set up here - the address, the shipped
#            assets, whether a derived page is waiting, and what performs the
#            publish - so a fresh clone learns its state instead of finding out
#            at the surface the captain reads. Exits 0 when the home has no
#            remote board, because that is a complete, supported state.
#
# WHAT A SHELL CANNOT DO HERE, STATED PLAINLY. Creating the board artifact and
# writing its payload both go through a Claude-harness agent tool; no
# credentialed CLI exposes that store, so this script cannot perform either and
# does not pretend to. Everything up to that boundary - composing, validating,
# deriving, and proving afterwards that the published page is what this
# template derives - runs from a clone with nothing configured. A home without
# such a harness keeps the desk board and loses only the remote one.
# `config/remote-board` holds the address so a clone points at its own board.
# docs/configuration.md owns that file; the bearings skill owns the procedure
# for creating, publishing, and verifying this board.
#
# WHAT THIS SCRIPT REFUSES. The derivation is anchored on the template's two
# transport seams - its `bearings-data` slot and its window.lavish.queuePrompt
# answer interface. If either moves, render stops and names it rather than
# emitting a board that would look right and answer nowhere. A template change
# that breaks derivation is meant to fail here and in tests/fm-remote-board.test.sh,
# never quietly on the surface the captain reads.
#
# THE PAYLOAD CONTRACT IS NOT OWNED HERE. `bin/fm-bearings-board.sh` states
# fm-bearings-board.v1 once and validates it; this script calls that validator
# rather than keeping a second copy of the rules.
#
# FM_REMOTE_BOARD_TEMPLATE and FM_REMOTE_BOARD_TRANSPORT override the shipped
# asset paths (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ASSETS="$FM_ROOT/.agents/skills/bearings/assets"

FM_HOME="${FM_HOME:-$FM_ROOT}"
ADDRESS_FILE="$FM_HOME/config/remote-board"
DERIVED_PATH="$FM_HOME/.lavish/remote-board.html"

TEMPLATE="${FM_REMOTE_BOARD_TEMPLATE:-$ASSETS/board-template.html}"
TRANSPORT="${FM_REMOTE_BOARD_TRANSPORT:-$ASSETS/remote-transport.js}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-remote-board: %s\n' "$*" >&2
  exit 1
}

# The derivation itself, shared by render and check so the two can never
# disagree about what the remote board is. Reads the template, the transport
# and a payload file; writes the derived page.
derive() {  # <payload.json> <out-file>
  [ -f "$TEMPLATE" ] || fail "the shipped board template is missing: $TEMPLATE"
  [ -f "$TRANSPORT" ] || fail "the remote transport is missing: $TRANSPORT"
  python3 - "$TEMPLATE" "$TRANSPORT" "$1" "$2" <<'PY'
import json, re, sys

template_path, transport_path, payload_path, out_path = sys.argv[1:5]
html = open(template_path, encoding="utf-8").read()
transport = open(transport_path, encoding="utf-8").read()

# Seam 1: the template's data slot. The remote board seeds from the very slot
# `fm-bearings-board.sh build` injects into, so both surfaces read one payload.
slot = re.compile(r'(<script id="bearings-data" type="application/json">)(.*?)(</script>)', re.S)
m = slot.search(html)
if not m:
    sys.exit("the template no longer carries its `bearings-data` payload slot; "
             "the remote board is derived through that slot and cannot be built without it")

# Seam 2: the template's own board script, the next script after that slot. It
# is embedded verbatim and run as-is, which is what makes parity structural.
tail = html[m.end():]
board = re.compile(r'<script>(.*?)</script>', re.S).search(tail)
if not board:
    sys.exit("the template no longer carries a board script after its payload slot; "
             "the remote board runs that script verbatim and cannot be built without it")
board_src = board.group(1)

# Seam 3: the answer interface the transport implements. A template that stopped
# routing answers through it would answer nowhere on this transport.
if "window.lavish.queuePrompt" not in board_src:
    sys.exit("the template no longer sends answers through window.lavish.queuePrompt; "
             "the remote transport implements that exact interface, so deriving now "
             "would publish a board whose answers go nowhere")

PLACEHOLDER = '"__FM_BEARINGS_BOARD_SCRIPT__"'
if PLACEHOLDER not in transport:
    sys.exit("the remote transport has no slot for the shipped board script")
# The board source is embedded as a JS string inside a <script> element, so it
# is escaped by the same rule as the payload below: every `<` becomes the
# \u003c string escape. Without it, a `</script>` reaching the template's own
# script - today only as an escaped sequence, tomorrow however someone writes
# it - would close this element early and leave the captain a blank board.
embedded = json.dumps(board_src).replace("<", "\\u003c")
transport = transport.replace(PLACEHOLDER, embedded, 1)

payload = json.dumps(json.load(open(payload_path, encoding="utf-8")),
                     ensure_ascii=False, separators=(",", ":"))
# A payload string containing "</script>" would otherwise close the data block.
payload = payload.replace("<", "\\u003c")

out = html[:m.start()] + m.group(1) + payload + m.group(3)
# The template's script tag is replaced by the transport, which runs that same
# script itself: one copy of the board's code on the page, not two.
rest = tail[:board.start()] + "<script>\n" + transport + "</script>" + tail[board.end():]
open(out_path, "w", encoding="utf-8").write(out + rest)
PY
}

command_render() {  # <data.json> [--out <file>]
  local data=${1-} out=""
  [ -n "$data" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) out=${2-}; [ -n "$out" ] || { usage >&2; exit 2; }; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -f "$data" ] || fail "board data does not exist: $data"
  # The contract's owner decides whether this payload may reach the captain.
  "$SCRIPT_DIR/fm-bearings-board.sh" validate "$data" >/dev/null \
    || fail "board data does not satisfy the fm-bearings-board.v1 contract: $data"

  if [ -n "$out" ]; then
    derive "$data" "$out"
    printf 'rendered: %s\n' "$out"
  else
    local tmp
    tmp=$(mktemp) || fail "cannot create a temporary file"
    # shellcheck disable=SC2064  # expand tmp now, while it is still set
    trap "rm -f '$tmp'" EXIT
    derive "$data" "$tmp"
    cat "$tmp"
  fi
}

command_check() {  # <published.html> [--out <file>]
  local published=${1-} keep=""
  [ -n "$published" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) keep=${2-}; [ -n "$keep" ] || { usage >&2; exit 2; }; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -f "$published" ] || fail "the published page does not exist: $published"

  local work payload expected
  work=$(mktemp -d) || fail "cannot create a temporary directory"
  # shellcheck disable=SC2064  # expand work now, while it is still set
  trap "rm -rf '$work'" EXIT
  payload="$work/payload.json"
  expected="$work/expected.html"

  # The published page's own embedded payload, so the comparison is about the
  # board and not about which refresh it was published on.
  python3 - "$published" "$payload" <<'PY' || fail "cannot read the published page's payload"
import json, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<script id="bearings-data" type="application/json">(.*?)</script>', html, re.S)
if not m:
    sys.exit("the published page carries no `bearings-data` payload slot")
json.dump(json.loads(m.group(1)), open(sys.argv[2], "w", encoding="utf-8"))
PY

  derive "$payload" "$expected"
  [ -z "$keep" ] || cp "$expected" "$keep"

  python3 - "$expected" "$published" <<'PY' || exit 1
import re, sys
expected = open(sys.argv[1], encoding="utf-8").read()
published = open(sys.argv[2], encoding="utf-8").read()

at = published.find(expected)
if at < 0:
    sys.exit("the published board is NOT what this template derives today: it has "
             "drifted from the shipped board, so something the local board renders "
             "may be missing from it (re-render and re-publish, or diff --out against it)")

prefix, suffix = published[:at], published[at + len(expected):]
# The artifact host wraps a published page in its own document skeleton. That
# wrapper is the only thing allowed around the derived board; anything else is
# content this repository does not track.
WRAP_OPEN = re.compile(r'\A\s*<!doctype html><html><head>.*?</head><body>\s*\Z', re.S | re.I)
WRAP_CLOSE = re.compile(r'\A\s*</body></html>\s*\Z', re.S | re.I)
for part, pattern, where in ((prefix, WRAP_OPEN, "before"), (suffix, WRAP_CLOSE, "after")):
    if part and not pattern.match(part):
        sys.exit("the published page carries untracked content %s the derived board "
                 "(%d bytes): %r" % (where, len(part), part[:200]))

print("board: the published page is what this template derives")
print("parity: every feature the shipped board renders is present, because the "
      "published page runs the shipped board's own script")
print("wrapper: %d bytes before, %d bytes after (the artifact host's document skeleton)"
      % (len(prefix), len(suffix)))
PY

  # The page's own payload, judged by the contract's owner rather than by a
  # second copy of its rules here.
  if "$SCRIPT_DIR/fm-bearings-board.sh" validate "$payload" >/dev/null 2>&1; then
    printf 'payload: satisfies fm-bearings-board.v1\n'
  else
    printf 'payload: does NOT satisfy fm-bearings-board.v1 (bin/fm-bearings-board.sh owns that contract)\n' >&2
    return 1
  fi
}

board_address() {
  [ -f "$ADDRESS_FILE" ] || return 1
  sed -n '1{s/[[:space:]]*$//;s/^[[:space:]]*//;p;}' "$ADDRESS_FILE"
}

command_url() {
  local url
  url=$(board_address) && [ -n "$url" ] \
    || fail "this home has no remote board configured; write its address to $ADDRESS_FILE (docs/configuration.md \"Remote bearings board\")"
  printf '%s\n' "$url"
}

command_publish() {  # <data.json>
  local data=${1-} url
  [ -n "$data" ] || { usage >&2; exit 2; }
  [ -f "$data" ] || fail "board data does not exist: $data"
  url=$(board_address) || url=""

  mkdir -p "$(dirname "$DERIVED_PATH")" || fail "cannot create $(dirname "$DERIVED_PATH")"
  command_render "$data" --out "$DERIVED_PATH" >/dev/null

  printf 'derived: %s\n' "$DERIVED_PATH"
  if [ -n "$url" ]; then
    printf 'address: %s\n' "$url"
  else
    printf 'address: (none configured - write it to %s)\n' "$ADDRESS_FILE"
  fi
  # Named, not implied: the operation a Claude-harness agent must perform, and
  # the reason this script stops here instead of reporting success.
  printf 'publish: write this payload to the board\x27s board/current document, then republish %s as the page\n' "$DERIVED_PATH"
  printf 'verify: fetch the published page and run: %s check <file>\n' "$(basename "$0")"
  printf 'blocked: a shell cannot reach that store; no credentialed CLI exposes it, so this prepared the publish rather than making it\n' >&2
  exit 69
}

command_doctor() {
  local url rc=0 tmp
  if url=$(board_address) && [ -n "$url" ]; then
    printf 'address: %s\n' "$url"
  else
    printf 'address: not configured (%s) - this home has no remote board, which is a supported state\n' "$ADDRESS_FILE"
  fi

  if [ -f "$TEMPLATE" ]; then printf 'template: %s\n' "$TEMPLATE"
  else printf 'template: MISSING %s\n' "$TEMPLATE" >&2; rc=1; fi
  if [ -f "$TRANSPORT" ]; then printf 'transport: %s\n' "$TRANSPORT"
  else printf 'transport: MISSING %s\n' "$TRANSPORT" >&2; rc=1; fi

  # Prove the shipped assets still derive, so a clone learns it here rather
  # than when someone tries to publish.
  tmp=$(mktemp -d) || fail "cannot create a temporary directory"
  printf '%s\n' '{"schema":"fm-bearings-board.v1","home":"doctor","generated":"1970-01-01T00:00Z","prs_live":false,"captains_call":[],"underway":[],"landed":[],"charted":[]}' > "$tmp/p.json"
  # A subshell: derive refuses by exiting, and doctor must finish its report
  # rather than stop at the first missing asset.
  if ( derive "$tmp/p.json" "$tmp/page.html" ) >/dev/null 2>&1; then
    printf 'derives: yes\n'
  else
    printf 'derives: NO - the shipped assets above do not derive a remote board; the lines above name which one is missing, and a present template that still fails no longer carries the seams this derivation needs\n' >&2
    rc=1
  fi
  rm -rf "$tmp"

  if [ -f "$DERIVED_PATH" ]; then printf 'derived-page: %s\n' "$DERIVED_PATH"
  else printf 'derived-page: none yet (run: %s publish <data.json>)\n' "$(basename "$0")"; fi
  printf 'publish-by: a Claude-harness agent tool; a shell cannot reach the board store\n'
  return "$rc"
}

case "${1-}" in
  path) printf '%s\n' "$TEMPLATE" ;;
  render) shift; command_render "$@" ;;
  check) shift; command_check "$@" ;;
  publish) shift; command_publish "$@" ;;
  url) command_url ;;
  doctor) command_doctor ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
