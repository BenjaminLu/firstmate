#!/usr/bin/env bash
# Behavior tests for bin/fm-remote-board.sh: the remote bearings board is
# DERIVED from the shipped board, so it renders what the shipped board renders.
#
# The guarantee under test is parity, and it is checked structurally rather than
# against a list of features - a hand-maintained list is the same trap one level
# up. The derived page runs the shipped board's own script and carries the
# shipped board's own markup, so "renders everything it renders" is true by
# construction; these cases pin that construction, the seams it depends on, and
# the check that catches a shipped board whose remote copy was not re-published.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMOTE="$ROOT/bin/fm-remote-board.sh"
SHIPPED="$ROOT/.agents/skills/bearings/assets/board-template.html"
TMP_ROOT=$(fm_test_tmproot fm-remote-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# The smallest payload bin/fm-bearings-board.sh accepts. Written out in full
# rather than trimmed from a live board, so this fixture cannot carry a field
# the contract does not define.
valid_payload() {  # <file>
  cat > "$1" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "test/home",
  "generated": "2026-09-19T06:53Z",
  "lang": "hant",
  "prs_live": false,
  "captains_call": [],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON
}

# The artifact host wraps a published page in its own document skeleton. These
# are the exact bytes observed around the live board on 2026-09-19.
publish() {  # <derived.html> <out.html>
  {
    printf '<!doctype html><html><head><meta charset=utf8></head><body>\n'
    cat "$1"
    printf '\n</body></html>'
  } > "$2"
}

# The shipped board's own script, as the derivation reads it.
shipped_board_script() {  # <template>
  python3 - "$1" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<script id="bearings-data" type="application/json">.*?</script>', html, re.S)
print(re.search(r'<script>(.*?)</script>', html[m.end():], re.S).group(1), end="")
PY
}

test_the_derived_board_runs_the_shipped_board_verbatim() {
  local d=$TMP_ROOT/parity
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null

  # Parity is structural: the shipped script is what renders the remote board,
  # so anything the shipped board grows reaches this page without a list.
  shipped_board_script "$SHIPPED" > "$d/board.js"
  # Decoded, not raw: the embedded source is escaped so it cannot close its own
  # script element, so the assertion is that it round-trips to the shipped bytes
  # exactly - a stronger claim than finding it as literal text.
  python3 - "$d/board.js" "$d/page.html" <<'PY' || fail "the derived board does not carry the shipped board script verbatim"
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
page = open(sys.argv[2], encoding="utf-8").read()
m = re.search(r'var BOARD_SRC = ("(?:[^"\\]|\\.)*");', page)
if not m:
    sys.exit("the derived board carries no embedded board source")
sys.exit(0 if json.loads(m.group(1)) == src else 1)
PY

  # And the shipped markup, which is where every class, token and drawing lives.
  python3 - "$SHIPPED" "$d/page.html" <<'PY' || fail "the derived board does not carry the shipped markup verbatim"
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
page = open(sys.argv[2], encoding="utf-8").read()
head = html[:re.search(r'<script id="bearings-data"', html).start()]
sys.exit(0 if head in page else 1)
PY
  pass "the derived board runs the shipped board verbatim"
}

test_the_derived_board_has_one_copy_of_the_board_code() {
  local d=$TMP_ROOT/single n
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null
  # A second copy is a second renderer waiting to drift; the transport runs the
  # embedded source instead of the page carrying the script twice.
  n=$(grep -c 'function render()' "$d/page.html" || true)
  assert_equals "1" "$n" "the derived board must carry exactly one copy of the board code"
  pass "the derived board has one copy of the board code"
}

test_the_contract_owner_gates_what_can_be_rendered() {
  local d=$TMP_ROOT/gate out rc=0
  mkdir -p "$d"
  valid_payload "$d/good.json"
  # The field today's hand-written remote page actually omitted, so this case
  # pins the real defect rather than an invented one.
  jq 'del(.prs_live)' "$d/good.json" > "$d/bad.json"

  out=$("$REMOTE" render "$d/bad.json" --out "$d/bad.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "render must refuse a payload the contract refuses"
  assert_contains "$out" "does not satisfy" "render must say the contract refused it"
  assert_absent "$d/bad.html" "render must not leave a page behind for a refused payload"
  pass "the payload contract's owner decides what may be rendered"
}

# A template whose named seam has been removed, to prove each refusal fires.
template_without() {  # <marker> <replacement> <out>
  python3 - "$SHIPPED" "$1" "$2" "$3" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
marker, replacement, out = sys.argv[2], sys.argv[3], sys.argv[4]
if marker not in html:
    sys.exit("fixture marker missing from the shipped template: " + marker)
open(out, "w", encoding="utf-8").write(html.replace(marker, replacement))
PY
}

test_render_refuses_when_a_transport_seam_moved() {
  local d=$TMP_ROOT/seams out rc
  mkdir -p "$d"
  valid_payload "$d/p.json"

  template_without '<script id="bearings-data" type="application/json">' \
    '<script id="board-payload" type="application/json">' "$d/no-slot.html"
  rc=0; out=$(FM_REMOTE_BOARD_TEMPLATE="$d/no-slot.html" "$REMOTE" render "$d/p.json" --out "$d/x.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "render must refuse a template with no payload slot"
  assert_contains "$out" "payload slot" "the refusal must name the missing slot"

  template_without 'window.lavish.queuePrompt' 'window.somewhereElse.queue' "$d/no-answer.html"
  rc=0; out=$(FM_REMOTE_BOARD_TEMPLATE="$d/no-answer.html" "$REMOTE" render "$d/p.json" --out "$d/y.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "render must refuse a template that no longer answers through the interface the transport implements"
  assert_contains "$out" "answers go nowhere" "the refusal must say why answering breaks"
  pass "render refuses when a transport seam moved"
}

test_a_script_close_in_the_payload_cannot_end_the_data_block() {
  local d=$TMP_ROOT/escape blocks
  mkdir -p "$d"
  valid_payload "$d/p.json"
  jq '.home = "</script><script>alert(1)</script>"' "$d/p.json" > "$d/evil.json"
  "$REMOTE" render "$d/evil.json" --out "$d/page.html" >/dev/null

  blocks=$(grep -c '<script id="bearings-data" type="application/json">' "$d/page.html")
  assert_equals "1" "$blocks" "the payload must not be able to open a second data block"
  assert_no_grep '</script><script>alert(1)' "$d/page.html" \
    "the payload's script close must be escaped, not emitted as markup"
  pass "a script close in the payload cannot end the data block"
}

test_check_accepts_the_board_this_template_derives() {
  local d=$TMP_ROOT/accept out rc=0
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null
  publish "$d/page.html" "$d/published.html"

  out=$("$REMOTE" check "$d/published.html" 2>&1) || rc=$?
  expect_code 0 "$rc" "check must accept a published page that is today's derivation"
  assert_contains "$out" "is what this template derives" "check must say the board matched"
  assert_contains "$out" "satisfies fm-bearings-board.v1" "check must report the payload verdict"
  pass "check accepts the board this template derives"
}

test_check_catches_a_shipped_feature_the_remote_board_never_got() {
  local d=$TMP_ROOT/drift out rc=0
  mkdir -p "$d"
  valid_payload "$d/p.json"
  # The published board was derived from YESTERDAY's template: it predates a
  # feature the shipped board has now. This is the case the whole check exists
  # for - the remote board silently missing what the local board renders.
  python3 - "$SHIPPED" "$d/old.html" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
marker = '<div class="bb-stats" id="bb-stats"></div>'
assert marker in html, "fixture marker missing from the shipped template"
open(sys.argv[2], "w", encoding="utf-8").write(html.replace(marker, "", 1))
PY
  FM_REMOTE_BOARD_TEMPLATE="$d/old.html" "$REMOTE" render "$d/p.json" --out "$d/old-page.html" >/dev/null
  assert_not_equals "$(cat "$d/old-page.html")" "$( "$REMOTE" render "$d/p.json" 2>/dev/null )" \
    "the stale-template fixture must actually differ from today's derivation"
  publish "$d/old-page.html" "$d/published.html"

  out=$("$REMOTE" check "$d/published.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "check must refuse a published board that predates a shipped feature"
  assert_contains "$out" "drifted from the shipped board" "check must name the drift from the shipped board"
  pass "check catches a shipped feature the remote board never got"
}

test_check_refuses_untracked_content_around_the_board() {
  local d=$TMP_ROOT/smuggle out rc=0
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null
  {
    printf '<!doctype html><html><head><meta charset=utf8></head><body>\n'
    cat "$d/page.html"
    printf '\n<script>fetch("https://example.invalid")</script>\n</body></html>'
  } > "$d/published.html"

  out=$("$REMOTE" check "$d/published.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "check must refuse untracked content around the derived board"
  assert_contains "$out" "untracked content" "check must name the untracked content"
  pass "check refuses untracked content around the board"
}

test_the_derived_board_is_renderable_from_the_shipped_assets() {
  local d=$TMP_ROOT/shipped rc=0
  mkdir -p "$d"
  valid_payload "$d/p.json"
  # No overrides: this exercises the assets this repo actually ships, so a
  # template or transport edited into an underivable shape fails here.
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the shipped assets must derive a remote board"
  publish "$d/page.html" "$d/published.html"
  rc=0
  "$REMOTE" check "$d/published.html" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a board derived from the shipped assets must check clean"
  pass "the derived board is renderable from the shipped assets"
}

test_the_embedded_board_source_cannot_close_its_own_script() {
  local d=$TMP_ROOT/embed
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null
  # Same rule as the payload: a raw `<` in the embedded source would let a
  # `</script>` inside the shipped board end this element early and blank the
  # page the captain reads.
  python3 - "$d/page.html" <<'PY' || fail "the embedded board source carries a raw '<'"
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'var BOARD_SRC = ("(?:[^"\\]|\\.)*");', page)
if not m:
    sys.exit("the derived board carries no embedded board source")
sys.exit(1 if "<" in m.group(1) else 0)
PY
  pass "the embedded board source cannot close its own script"
}

test_doctor_reports_a_home_with_no_board() {
  local home out rc=0
  home=$TMP_ROOT/bare
  mkdir -p "$home"

  # A clone with nothing set up is a supported state, not a failure.
  rc=0; out=$(FM_HOME="$home" "$REMOTE" doctor 2>&1) || rc=$?
  expect_code 0 "$rc" "doctor must succeed on a home with no remote board"
  assert_contains "$out" "not configured" "doctor must report the missing address"
  assert_contains "$out" "supported state" "doctor must say a home without a board is fine"
  assert_contains "$out" "derives: yes" "doctor must prove the shipped assets still derive"
  assert_contains "$out" "a shell cannot reach the board store" \
    "doctor must name what performs the publish"
  assert_contains "$out" "config/remote-board" "doctor must name the file that holds the address"
  pass "doctor reports a home with no board"
}

test_doctor_fails_when_the_shipped_assets_stopped_deriving() {
  local out rc=0 d=$TMP_ROOT/doctor-broken home
  home=$d/home
  mkdir -p "$home"
  template_without '<script id="bearings-data" type="application/json">' \
    '<script id="moved" type="application/json">' "$d/broken.html"

  rc=0
  out=$(FM_HOME="$home" FM_REMOTE_BOARD_TEMPLATE="$d/broken.html" "$REMOTE" doctor 2>&1) || rc=$?
  expect_code 1 "$rc" "doctor must fail when the shipped board no longer derives"
  assert_contains "$out" "derives: NO" "doctor must name the derivation as the broken thing"
  pass "doctor fails when the shipped assets stopped deriving"
}

test_publish_prepares_and_refuses_to_claim_it_published() {
  local home out rc=0
  home=$TMP_ROOT/publish
  mkdir -p "$home/config"
  printf 'https://example.invalid/artifact/test\n' > "$home/config/remote-board"
  valid_payload "$home/p.json"

  rc=0; out=$(FM_HOME="$home" "$REMOTE" publish "$home/p.json" 2>&1) || rc=$?
  # 69 is this repository's "cannot run here", the same status a missing linter
  # uses; anything else would read as a publish that happened.
  expect_code 69 "$rc" "publish must exit 69 rather than report a publish it did not make"
  assert_contains "$out" "https://example.invalid/artifact/test" "publish must name the configured address"
  assert_contains "$out" "board/current" "publish must name the exact operation"
  assert_contains "$out" "prepared the publish rather than making it" \
    "publish must say plainly that it did not publish"
  assert_present "$home/.lavish/remote-board.html" "publish must leave the derived page ready"
  pass "publish prepares and refuses to claim it published"
}

# A published page under a wrapper of the caller's choosing.
publish_wrapped() {  # <derived.html> <open-wrapper> <out.html>
  {
    printf '%s\n' "$2"
    cat "$1"
    printf '\n</body></html>'
  } > "$3"
}

test_check_refuses_untracked_content_in_the_wrapper() {
  local d=$TMP_ROOT/head out rc=0
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null

  # The head is not a free space: a script or a stylesheet smuggled into it
  # runs on the captain's phone exactly as one placed beside the board would.
  publish_wrapped "$d/page.html" \
    '<!doctype html><html><head><meta charset=utf8><script src="https://example.invalid/x.js"></script></head><body>' \
    "$d/script-head.html"
  rc=0; out=$("$REMOTE" check "$d/script-head.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "check must refuse a wrapper head carrying a script"
  assert_contains "$out" "untracked content" "the refusal must name the untracked content"

  publish_wrapped "$d/page.html" \
    '<!doctype html><html><head><meta charset=utf8><style>.bb-decision{display:none}</style></head><body>' \
    "$d/style-head.html"
  rc=0; out=$("$REMOTE" check "$d/style-head.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "check must refuse a wrapper head carrying a stylesheet"

  # Nor is an attribute: these two carry script and a redirect without a single
  # extra tag, so a check that reads tag names alone lets them through.
  publish_wrapped "$d/page.html" \
    '<!doctype html><html><head><meta charset=utf8></head><body onload="fetch(https://example.invalid)">' \
    "$d/onload-body.html"
  rc=0; out=$("$REMOTE" check "$d/onload-body.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "check must refuse a wrapper body carrying an event handler"

  publish_wrapped "$d/page.html" \
    '<!doctype html><html><head><meta charset=utf8><meta http-equiv="refresh" content="0;url=https://example.invalid"></head><body>' \
    "$d/refresh-head.html"
  rc=0; out=$("$REMOTE" check "$d/refresh-head.html" 2>&1) || rc=$?
  expect_code 1 "$rc" "check must refuse a wrapper head carrying a meta refresh"

  # The host's own metadata skeleton still passes, or the check would refuse
  # every real publish.
  publish_wrapped "$d/page.html" \
    '<!doctype html><html lang="en"><head><meta charset=utf8><title>bearings</title><meta name="viewport" content="width=device-width"></head><body>' \
    "$d/ok-head.html"
  rc=0; out=$("$REMOTE" check "$d/ok-head.html" 2>&1) || rc=$?
  expect_code 0 "$rc" "check must still accept the host's metadata-only wrapper: $out"
  pass "check refuses untracked content in the wrapper"
}

# ---- the transport's own behavior, executed ------------------------------
# The cases below run the DERIVED page under tests/assets/remote-board-harness.mjs
# and assert what the captain would see, so the transport is judged by what it
# does rather than by what its source says.
HARNESS="$ROOT/tests/assets/remote-board-harness.mjs"

# A payload with answerable cards: an answer in progress only exists once the
# shipped board has rendered its own forms.
answerable_payload() {  # <file>
  cat > "$1" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-09-19T06:53Z",
  "lang": "en",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
JSON
}

transport_page() {  # <dir>
  mkdir -p "$1"
  answerable_payload "$1/p.json"
  "$REMOTE" render "$1/p.json" --out "$1/page.html" >/dev/null \
    || fail "the derived page did not render"
}

drive() {  # <dir> <scenario>
  node "$HARNESS" "$1/page.html" "$2" || fail "the derived board could not be driven: $2"
}

test_a_live_payload_repaints_through_the_shipped_board() {
  local d=$TMP_ROOT/drive-live out
  transport_page "$d"
  out=$(drive "$d" live)
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "a live payload must reach the page through the shipped board's own renderer"
  assert_contains "$(jq -r .badge <<<"$out")" "live" "the page must say the link is live"
  # Computed copy the captain cannot see is no signal at all, so the badge must
  # hang in the board's own nav bar.
  assert_equals "bb-nav__inner" "$(jq -r .badgeHost <<<"$out")" \
    "the link badge must be attached to the board's nav bar"
  pass "a live payload repaints through the shipped board"
}

test_an_update_waits_while_an_answer_is_in_progress() {
  local d=$TMP_ROOT/drive-hold out
  transport_page "$d"

  # The complaint this branch answers: an update arriving mid-answer must not
  # wipe the note being typed, the card being answered, or the captain's place
  # in the stack.
  out=$(drive "$d" hold)
  assert_equals "wait for me" "$(jq -r .note <<<"$out")" \
    "a live update must not discard the note the captain is writing"
  assert_contains "$(jq -r .stack <<<"$out")" "card 2 of 2" \
    "a live update must not lose the captain's place in the card stack"
  assert_not_contains "$(jq -r .provenance <<<"$out")" "2099" \
    "the held update must not have painted while the answer was in progress"
  assert_contains "$(jq -r .badge <<<"$out")" "waiting" \
    "the page must say an update is waiting rather than claim it is live"

  # ...and the hold reaches no further than that card. A selection left behind
  # on a card the deck has moved past is not an answer in progress, or the
  # board would stay stale for ever with nothing the captain can do about it.
  out=$(drive "$d" hold-stale)
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "a selection left on a card the captain has moved past must not hold the board"
  assert_contains "$(jq -r .badge <<<"$out")" "live" \
    "with nothing in progress the page must say the link is live"

  # Held, not dropped: it lands the moment the answer is sent.
  out=$(drive "$d" hold-send)
  assert_equals "1" "$(jq '.writes | length' <<<"$out")" \
    "the answer must be written to the board's own store"
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "the held update must land once the answer is sent"
  pass "an update waits while an answer is in progress"
}

test_a_snapshot_the_page_cannot_render_is_not_called_live() {
  local d=$TMP_ROOT/drive-unreadable out badge
  transport_page "$d"
  out=$(drive "$d" unreadable)
  badge=$(jq -r .badge <<<"$out")
  assert_contains "$badge" "not updating" \
    "a snapshot this page cannot render must read as not updating"
  assert_not_contains "$badge" "live" "the page must not claim a live link it does not have"
  # Nothing has ever arrived here, so the built-in copy is exactly what is on
  # screen and the page may say so.
  assert_contains "$badge" "built into this page" \
    "a page that has heard nothing must name the copy built into it"
  pass "a snapshot the page cannot render is not called live"
}

test_a_board_that_went_quiet_says_how_long_ago() {
  local d=$TMP_ROOT/drive-quiet out badge
  transport_page "$d"
  # A payload has arrived and painted, then the board stopped sending readable
  # ones. What is on screen is that payload, not the copy built into the page,
  # and the age is what separates a quiet fleet from a broken link.
  out=$(drive "$d" went-quiet)
  badge=$(jq -r .badge <<<"$out")
  assert_contains "$badge" "not updating" "a board that stopped receiving must say so"
  assert_contains "$badge" "last update" "it must say when the last update arrived"
  assert_not_contains "$badge" "built into this page" \
    "it must not claim the built-in copy after a payload has painted"
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "the payload that did arrive must still be what the page shows"
  pass "a board that went quiet says how long ago"
}

test_releasing_a_hold_does_not_claim_a_link_it_lost() {
  local d=$TMP_ROOT/drive-held-quiet out badge
  transport_page "$d"
  # Held mid-answer, then the board stops sending anything this page can read.
  # Sending the answer releases the held payload - it is still the newest thing
  # this page ever received - but it does not make the link live again.
  out=$(drive "$d" held-quiet)
  badge=$(jq -r .badge <<<"$out")
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "the held payload must still be painted once the answer is sent"
  assert_not_contains "$badge" "live" "releasing a hold must not claim a live link"
  assert_contains "$badge" "not updating" \
    "the page must keep saying it stopped receiving"
  assert_equals "1" "$(jq '.writes | length' <<<"$out")" "the answer must still have been sent"
  pass "releasing a hold does not claim a link it lost"
}

test_an_answer_that_cannot_be_sent_is_named_on_the_page() {
  local d=$TMP_ROOT/drive-nodb out
  transport_page "$d"
  # With no store to write to, an answer goes nowhere; the page must say so
  # rather than let the card tick as though it had been sent.
  out=$(drive "$d" no-db)
  assert_equals "0" "$(jq '.writes | length' <<<"$out")" "there is nothing to write the answer to"
  assert_contains "$(jq -r .answers <<<"$out")" "answers cannot be sent" \
    "the page must say answers cannot be sent from here"
  assert_contains "$(jq -r .badge <<<"$out")" "not updating" \
    "and must say separately that it is no longer being updated"
  pass "an answer that cannot be sent is named on the page"
}

test_sending_and_updating_are_reported_apart() {
  local d=$TMP_ROOT/drive-write-fails out
  transport_page "$d"
  # The store refuses the answer, then firstmate republishes. Reads working
  # again does not make the page answerable, and the two facts get a badge
  # each so neither can be read off the other.
  out=$(drive "$d" write-fails)
  assert_contains "$(jq -r .answers <<<"$out")" "answers cannot be sent" \
    "a page whose write was refused must keep saying answers cannot be sent"
  assert_contains "$(jq -r .badge <<<"$out")" "live" \
    "a readable payload is still a live link and must be reported as one"
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "that payload must still reach the page"

  # And the other way round: once it stops receiving, the page says so rather
  # than letting the send failure stand in for a link that is still fine.
  out=$(drive "$d" stopped)
  assert_contains "$(jq -r .badge <<<"$out")" "not updating" \
    "a page that stopped receiving must say so even while a send is broken"
  assert_contains "$(jq -r .answers <<<"$out")" "answers cannot be sent" \
    "and must still say answers cannot be sent"
  pass "sending and updating are reported apart"
}

test_an_unsent_dispatch_selection_survives_an_arriving_update() {
  local d=$TMP_ROOT/drive-picks out
  transport_page "$d"
  # Ticks made in Charted Next and not yet queued are unsent work like any
  # other; the picker is never hidden by the deck, so nothing else protects it.
  out=$(drive "$d" hold-picks)
  assert_equals "1" "$(jq -r .picks <<<"$out")" "an arriving update must not clear an unsent dispatch tick"
  assert_not_contains "$(jq -r .provenance <<<"$out")" "2099" \
    "the update must be held while the tick is unsent"
  assert_contains "$(jq -r .badge <<<"$out")" "waiting" "the page must say an update is waiting"

  # Queuing the order releases it, the same way sending an answer does.
  out=$(drive "$d" picks-sent)
  assert_equals "1" "$(jq '.writes | length' <<<"$out")" "the dispatch order must reach the board's store"
  assert_contains "$(jq -r .provenance <<<"$out")" "2099-01-01T00:00Z" \
    "the held update must land once the dispatch order is queued"
  pass "an unsent dispatch selection survives an arriving update"
}

test_the_badges_follow_the_boards_language_switch() {
  local d=$TMP_ROOT/drive-lang out
  transport_page "$d"
  # The board's own language buttons switch the whole page; a badge left in the
  # previous language is this file's copy contradicting the board beside it.
  out=$(drive "$d" lang)
  assert_contains "$(jq -r .badge <<<"$out")" "即時更新" \
    "the link badge must follow the language the board switched to"
  assert_contains "$(jq -r .answers <<<"$out")" "firstmate" \
    "the answer-gap notice must still name firstmate after the switch"
  assert_not_contains "$(jq -r .answers <<<"$out")" "answers stay on this board" \
    "the answer-gap notice must not stay in the previous language"
  pass "the badges follow the board's language switch"
}

test_the_page_names_the_answer_route_that_is_not_landed() {
  local d=$TMP_ROOT/drive-gap out
  transport_page "$d"
  # Carrying answers back to firstmate is not landed, and a ticked card would
  # otherwise read as an answer that arrived.
  out=$(drive "$d" live)
  assert_contains "$(jq -r .answers <<<"$out")" "firstmate" \
    "the page must name what does not yet reach firstmate"
  assert_equals "bb-nav__inner" "$(jq -r .answersHost <<<"$out")" \
    "that notice must be attached to the board's nav bar"
  pass "the page names the answer route that is not landed"
}

test_the_derived_board_runs_the_shipped_board_verbatim
test_the_derived_board_has_one_copy_of_the_board_code
test_the_contract_owner_gates_what_can_be_rendered
test_render_refuses_when_a_transport_seam_moved
test_a_script_close_in_the_payload_cannot_end_the_data_block
test_check_accepts_the_board_this_template_derives
test_check_catches_a_shipped_feature_the_remote_board_never_got
test_check_refuses_untracked_content_around_the_board
test_check_refuses_untracked_content_in_the_wrapper
test_the_derived_board_is_renderable_from_the_shipped_assets
test_the_embedded_board_source_cannot_close_its_own_script
test_doctor_reports_a_home_with_no_board
test_doctor_fails_when_the_shipped_assets_stopped_deriving
test_publish_prepares_and_refuses_to_claim_it_published

# The transport is JavaScript; without a runtime its behavior cannot be
# executed, and asserting it from its source text would prove nothing.
if command -v node >/dev/null 2>&1; then
  test_a_live_payload_repaints_through_the_shipped_board
  test_an_update_waits_while_an_answer_is_in_progress
  test_a_snapshot_the_page_cannot_render_is_not_called_live
  test_a_board_that_went_quiet_says_how_long_ago
  test_releasing_a_hold_does_not_claim_a_link_it_lost
  test_an_answer_that_cannot_be_sent_is_named_on_the_page
  test_sending_and_updating_are_reported_apart
  test_an_unsent_dispatch_selection_survives_an_arriving_update
  test_the_badges_follow_the_boards_language_switch
  test_the_page_names_the_answer_route_that_is_not_landed
else
  echo "skip: node not found - the remote transport's behavior cases need a JS runtime"
fi
