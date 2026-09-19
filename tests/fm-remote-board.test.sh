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

test_the_answer_keys_are_the_shipped_boards_own() {
  local d=$TMP_ROOT/keys
  mkdir -p "$d"
  valid_payload "$d/p.json"
  "$REMOTE" render "$d/p.json" --out "$d/page.html" >/dev/null
  # The transport must not name any key itself: every key reaches it from the
  # template, which is what keeps a remote answer addressable by the same
  # intake as a local one.
  assert_no_grep 'dispatch.charted' "$ROOT/.agents/skills/bearings/assets/remote-transport.js" \
    "the transport must take its keys from the board, not restate them"
  assert_grep 'queueKey' "$ROOT/.agents/skills/bearings/assets/remote-transport.js" \
    "the transport must read the key the board supplies"
  pass "the answer keys are the shipped board's own"
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

test_url_and_doctor_report_a_home_with_no_board() {
  local home out rc=0
  home=$TMP_ROOT/bare
  mkdir -p "$home"

  rc=0; out=$(FM_HOME="$home" "$REMOTE" url 2>&1) || rc=$?
  expect_code 1 "$rc" "url must refuse when the home has no board configured"
  assert_contains "$out" "no remote board configured" "url must say what is missing"
  assert_contains "$out" "config/remote-board" "url must name the file to write"

  # A clone with nothing set up is a supported state, not a failure.
  rc=0; out=$(FM_HOME="$home" "$REMOTE" doctor 2>&1) || rc=$?
  expect_code 0 "$rc" "doctor must succeed on a home with no remote board"
  assert_contains "$out" "not configured" "doctor must report the missing address"
  assert_contains "$out" "supported state" "doctor must say a home without a board is fine"
  assert_contains "$out" "derives: yes" "doctor must prove the shipped assets still derive"
  assert_contains "$out" "a shell cannot reach the board store" \
    "doctor must name what performs the publish"
  pass "url and doctor report a home with no board"
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

test_the_derived_board_runs_the_shipped_board_verbatim
test_the_derived_board_has_one_copy_of_the_board_code
test_the_contract_owner_gates_what_can_be_rendered
test_render_refuses_when_a_transport_seam_moved
test_a_script_close_in_the_payload_cannot_end_the_data_block
test_check_accepts_the_board_this_template_derives
test_check_catches_a_shipped_feature_the_remote_board_never_got
test_check_refuses_untracked_content_around_the_board
test_the_answer_keys_are_the_shipped_boards_own
test_the_derived_board_is_renderable_from_the_shipped_assets
test_the_embedded_board_source_cannot_close_its_own_script
test_url_and_doctor_report_a_home_with_no_board
test_doctor_fails_when_the_shipped_assets_stopped_deriving
test_publish_prepares_and_refuses_to_claim_it_published
