#!/usr/bin/env bash
# Behavior tests for bin/fm-packet.sh: the scaffold is generated from the
# task's worktree, verify refuses a skeleton and accepts a filled packet, the
# decision block is validated field by field, card emits a board-ready
# Captain's Call item, render writes one self-contained HTML page whose
# decision card answers the five questions, and serve opens that page with
# lavish-axi under a stable name and hands the card its URL.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACKET="$ROOT/bin/fm-packet.sh"
TMP_ROOT=$(fm_test_tmproot fm-packet)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A home with one task whose worktree carries two commits past main.
make_home() {  # <name> -> prints home; sets nothing else
  local home="$TMP_ROOT/$1" repo wt
  mkdir -p "$home/state" "$home/data"
  repo="$home/repo"; wt="$home/wt"
  fm_git_worktree "$repo" "$wt" "fm/pk-1"
  printf 'a\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qm "add a"
  printf 'b\n' > "$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qm "add b"
  fm_write_meta "$home/state/pk-1.meta" "worktree=$wt" "project=$repo" "kind=ship"
  make_lavish_stub "$home" nonames
  printf '%s\n' "$home"
}
run_packet_lavish() {  # <home> <args...>: run_packet with the stub's state bound
  local home=$1; shift
  LAVISH_FAKE_STATE="$home/lavish-state" run_packet "$home" "$@"
}

run_packet() {  # <home> <args...>
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$home/fakebin:$TMP_ROOT/nogh:$PATH" "$PACKET" "$@"
}
mkdir -p "$TMP_ROOT/nogh"  # no gh on PATH so the PR facts stay offline and deterministic
# card and serve read lavish-axi's listing; without a stub a developer machine's
# real server would answer, so every home gets one that lists nothing until a
# serve opens the page. The listing shapes follow lavish-axi 0.1.71 (with
# --name, a `name` column and the /s/<slug> URL) and an older release without.
make_lavish_stub() {  # <home> <names|nonames>: a lavish-axi that records its args
  local fakebin
  fakebin=$(fm_fakebin "$1")
  mkdir -p "$1/lavish-state"
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
# Every invocation in order, so a test can assert what serve asked the vendor
# for and when. A bare listing logs as `<list>`.
printf '%s\n' "${*:-<list>}" >> "$state/calls"
case "${1-}" in
  --version) printf '0.1.71\n'; exit 0 ;;
  --help)
    # Inert: help never opens, lists, or ends a session. A release that names
    # sessions advertises the flag here; the `names` marker selects it.
    printf 'help[1]: "Run `lavish-axi <html-file>` to open a session"\n'
    if [ -e "$state/names" ]; then
      printf 'help[2]: "Pass `--name <slug>` (lowercase letters, digits, hyphens) to give a session a stable URL"\n'
    fi
    exit 0 ;;
  '')
    if [ -e "$state/names" ]; then
      printf 'sessions[1]{file,status,url,name,pending_prompts}:\n'
      [ -s "$state/open" ] && printf '  %s,open,"http://127.0.0.1:4387/s/%s",%s,0\n' "$(cat "$state/open")" "$(cat "$state/name")" "$(cat "$state/name")"
      printf 'help[2]: "Run `lavish-axi <html-file>` to open a session","Pass `--name <slug>` (lowercase letters, digits, hyphens) to give a session a stable URL"\n'
    else
      printf 'sessions[1]{file,status,url,pending_prompts}:\n'
      [ -s "$state/open" ] && printf '  %s,open,"http://127.0.0.1:4387/session/deadbeef",0\n' "$(cat "$state/open")"
      printf 'help[1]: "Run `lavish-axi <html-file>` to open a session"\n'
    fi
    exit 0 ;;
esac
file=$1; shift
printf '%s\n' "$*" >> "$state/args"
name=''
while [ "$#" -gt 0 ]; do
  case "$1" in --name) name=$2; shift 2 ;; *) shift ;; esac
done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
printf '%s\n' "$real" > "$state/open"
printf '%s\n' "$name" > "$state/name"
printf 'session:\n  file: %s\n  status: opened\n' "$real"
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  rm -f "$1/lavish-state/names" "$1/lavish-state/calls"
  [ "$2" = names ] && : > "$1/lavish-state/names"
  return 0
}

fill_prose() {  # <packet>: replace the two prose placeholders with real content
  python3 - "$1" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"\{FILL: every path you tried.*?\}", "- tried a retry loop first; dropped it because the bound, not the forge, was failing\n- the 15 s bound is unverified against the slowest repo\n- the merged-record rule assumes settle_final runs before publish", s, flags=re.S)
s = re.sub(r"\{FILL: file:line.*?\}", "- bin/fm-contributions.sh:190 forge() bound\n- tests/fm-contributions.test.sh: test_bound_hit_is_not_unavailable", s, flags=re.S)
s = re.sub(r"\{FILL: optional.*?\}\n", "", s)
p.write_text(s)
PY
}

fill_decision() {  # <packet> <json>: replace the decision block
  python3 - "$1" "$2" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"```json fm-packet-decision.v1\n.*?\n```", "```json fm-packet-decision.v1\n" + sys.argv[2] + "\n```", s, flags=re.S)
p.write_text(s)
PY
}

GOOD_DECISION='{"key":"pk-1","title":{"en":"Raise the bound","hant":"拉高上限"},"decide":"Ship which fix first?","if_nothing":"the wake keeps coming","reversible":"yes","risk":"low","options":[{"value":"bound","label":"Raise to 15 s","consequence":"failures stop"},{"value":"quiet","label":{"en":"Stop waking on merged"},"consequence":"noise stops, open PRs still fail"}],"recommend_value":"bound","recommend_why":"measured latency is 0.9 to 4.4 s"}'

test_scaffold_is_generated_from_the_worktree_and_refuses_to_overwrite() {
  local home out packet rc
  home=$(make_home scaffold)
  out=$(run_packet "$home" scaffold pk-1) || fail "scaffold failed: $out"
  packet="$home/data/pk-1/packet.md"
  assert_present "$packet" "scaffold wrote no packet"
  assert_contains "$out" "packet: $packet" "scaffold did not report the packet path: $out"
  assert_grep "schema: fm-packet.v1" "$packet" "packet lacks its schema line"
  assert_grep "kind: done" "$packet" "packet did not default to kind=done"
  assert_grep "branch: fm/pk-1" "$packet" "packet did not record the worktree branch"
  assert_grep " add a" "$packet" "packet did not list the first commit past main"
  assert_grep " add b" "$packet" "packet did not list the second commit past main"
  assert_grep "b.txt" "$packet" "packet did not list the changed files"
  assert_grep "- pr: none recorded" "$packet" "packet did not say no PR is recorded"
  assert_grep "{FILL" "$packet" "the skeleton carries no placeholders"
  assert_no_grep "fm-packet-decision.v1" "$packet" "a done packet should not carry a decision block"
  set +e; out=$(run_packet "$home" scaffold pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a second scaffold overwrote the packet"
  assert_contains "$out" "already exists" "the overwrite refusal did not say why: $out"
  run_packet "$home" scaffold pk-1 --force >/dev/null || fail "--force did not re-scaffold"
  pass "scaffold is generated from the worktree and refuses to overwrite a packet"
}

test_verify_refuses_a_skeleton_and_accepts_a_filled_packet() {
  local home out rc packet
  home=$(make_home verify)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted an unfilled skeleton"
  assert_contains "$out" "placeholders remain" "verify did not name the placeholders: $out"
  fill_prose "$packet"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a filled done packet: $out"
  assert_contains "$out" "packet: ok $packet" "verify did not report ok: $out"
  # Thin session knowledge is the failure the packet exists to catch.
  python3 - "$packet" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"(## What only this session knows\n\n)(.*?)(\n\n## )", r"\1- only one line\3", s, flags=re.S)
p.write_text(s)
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a one-line session section"
  assert_contains "$out" "at least three are required" "verify did not explain the thin section: $out"
  pass "verify refuses a skeleton or a thin packet and accepts a filled one"
}

test_verify_checks_the_decision_block_field_by_field() {
  local home out rc packet bad
  home=$(make_home decision)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  assert_grep "kind: needs-decision" "$packet" "packet did not record kind=needs-decision"
  assert_grep "fm-packet-decision.v1" "$packet" "a needs-decision packet has no decision block"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a good decision packet: $out"

  bad=$(printf '%s' "$GOOD_DECISION" | jq -c '.recommend_value = "other"')
  fill_decision "$packet" "$bad"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a recommendation that names no option"
  assert_contains "$out" "recommend_value must name one of the options" "wrong reason: $out"

  bad=$(printf '%s' "$GOOD_DECISION" | jq -c '.reversible = "maybe"')
  fill_decision "$packet" "$bad"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted an unknown reversible value"

  bad=$(printf '%s' "$GOOD_DECISION" | jq -c '.options[1] |= del(.consequence)')
  fill_decision "$packet" "$bad"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted an option without a consequence"
  assert_contains "$out" "every option needs value, label, and consequence" "wrong reason: $out"

  bad=$(printf '%s' "$GOOD_DECISION" | jq -c '.key = "someone-else"')
  fill_decision "$packet" "$bad"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a decision keyed to another task"

  bad=$(printf '%s' "$GOOD_DECISION" | jq -c '.options[0].value = "reconcile"')
  fill_decision "$packet" "$bad"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted the reserved reconcile value"
  pass "verify checks the decision block field by field"
}

test_card_emits_a_board_ready_decision_item() {
  local home out packet
  home=$(make_home card)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    .key == "pk-1" and .type == "decision" and .repo == "repo"
    and (.title.hant == "拉高上限")
    and (.options | length == 2)
    and (.options[1].label == "Stop waking on merged")
    and (.options[0].consequence == "failures stop")
    and .recommend_value == "bound" and .risk == "low" and .reversible == "yes"
    and .allow_freeform == true
  ' >/dev/null || fail "card did not emit the expected board item: $out"
  out=$(run_packet "$home" card pk-1 --repo other) || fail "card --repo failed"
  printf '%s' "$out" | jq -e '.repo == "other"' >/dev/null || fail "--repo did not override the card repo"
  # A done packet has no decision to card.
  home=$(make_home card-done)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  fill_prose "$home/data/pk-1/packet.md"
  set +e; out=$(run_packet "$home" card pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "card produced an item from a done packet"
  pass "card emits a board-ready decision item, flattening single-language copy"
}

test_path_and_bad_ids_are_refused() {
  local home rc
  home=$(make_home path)
  [ "$(run_packet "$home" path pk-1)" = "$home/data/pk-1/packet.md" ] || fail "path printed the wrong location"
  set +e; run_packet "$home" scaffold "../escape" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a path-traversal task id was accepted"
  set +e; run_packet "$home" verify pk-missing >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify passed a task with no packet"
  pass "path prints the packet location and malformed ids are refused"
}

# The page must open with no network at all: nothing may be fetched at load.
# Author links (<a href>) are fine; stylesheets, scripts, fonts, images, and
# CSS imports from a remote host are not.
assert_no_external_fetch() {  # <page>
  assert_no_grep '<link ' "$1" "the page links an external resource"
  assert_no_grep '<script src=' "$1" "the page loads a remote script"
  assert_no_grep '@import' "$1" "the page imports a remote stylesheet"
  assert_no_grep '<img src="http' "$1" "the page loads a remote image"
  assert_no_grep 'url(http' "$1" "the page references a remote url() asset"
  assert_no_grep 'url("http' "$1" "the page references a remote url() asset"
  assert_no_grep "url('http" "$1" "the page references a remote url() asset"
}

section_order() {  # <page> -> the section ids in document order, space-joined
  grep -o 'id="s_[a-z]*"' "$1" | tr '\n' ' '
}

test_render_writes_a_self_contained_page_for_a_done_packet() {
  local home out rc packet page
  home=$(make_home render-done)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  # A skeleton is refused: render never publishes a packet verify rejects.
  set +e; out=$(run_packet "$home" render pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "render accepted an unverified skeleton"
  assert_absent "$page" "render wrote a page for a skeleton"
  fill_prose "$packet"
  python3 - "$packet" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("- the 15 s bound is unverified against the slowest repo",
  "- the **15 s** bound is `unverified` against [the slowest repo](https://example.test/slow); see <b>escaped</b>")
s = s.replace("- the merged-record rule assumes settle_final runs before publish",
  "- the RAW_JS and TASK_ID slots are named here on purpose\n- [a data link](data:text/html,x) and [a vb link](VBScript:x) stay text")
p.write_text(s)
PY
  out=$(run_packet "$home" render pk-1) || fail "render failed: $out"
  assert_contains "$out" "page: $page" "render did not report the page path: $out"
  assert_present "$page" "render wrote no page"
  assert_no_grep '{FILL' "$page" "a placeholder survived into the page"
  assert_no_external_fetch "$page"
  assert_grep '<strong>15 s</strong>' "$page" "bold did not convert"
  assert_grep '<code>unverified</code>' "$page" "inline code did not convert"
  assert_grep '<a href="https://example.test/slow"' "$page" "the link did not convert"
  assert_no_grep 'href="data:' "$page" "a data: link was made clickable"
  assert_no_grep 'href="VBScript:' "$page" "a vbscript: link was made clickable"
  assert_grep '[a vb link](VBScript:x) stay text' "$page" "the refused link was not kept as text"
  assert_grep '<li>the RAW_JS and TASK_ID slots are named here on purpose</li>' "$page" "prose naming a template slot was rewritten"
  assert_grep '&lt;b&gt;escaped&lt;/b&gt;' "$page" "raw HTML in the packet was not escaped"
  assert_grep '<code>git -C' "$page" "the fenced pull-more block did not convert"
  assert_grep '<li>tried a retry loop first' "$page" "the session list did not convert"
  assert_no_grep 'id="pk-decision"' "$page" "a done packet rendered a decision card"
  [ "$(section_order "$page")" = 'id="s_changed" id="s_session" id="s_evidence" id="s_more" ' ] \
    || fail "sections are missing or out of packet order: $(section_order "$page")"
  # Chrome carries all three languages; the raw markdown rides the page for the copy button.
  assert_grep 'data-hant="只有這個 session 知道的事"' "$page" "the section chrome lacks 繁體"
  assert_grep 'data-hans="只有这个 session 知道的事"' "$page" "the section chrome lacks 简体"
  assert_grep 'id="pk-lang-hans"' "$page" "the language switch is missing"
  assert_grep 'var RAW = "# Packet: pk-1' "$page" "the raw markdown is not embedded for the copy button"
  assert_grep 'id="pk-copy"' "$page" "the copy button is missing"
  assert_grep 'id="pk-raw-text"' "$page" "the selected-text fallback is missing"
  assert_no_grep 'id="pk-show-raw"' "$page" "the page grew a second entry point to the fallback"
  pass "render writes one self-contained page for a done packet"
}

test_render_decision_card_answers_the_five_questions() {
  local home packet page
  home=$(make_home render-decision)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  run_packet "$home" render pk-1 >/dev/null || fail "render failed"
  assert_no_grep '{FILL' "$page" "a placeholder survived into the page"
  assert_no_external_fetch "$page"
  assert_grep 'id="pk-decision"' "$page" "no decision card was rendered"
  # 1. what to decide
  assert_grep 'Ship which fix first?' "$page" "the card lacks the question"
  # 2. per-option consequence
  assert_grep 'Raise to 15 s' "$page" "the card lacks option A"
  assert_grep 'failures stop' "$page" "the card lacks option A's consequence"
  assert_grep 'Stop waking on merged' "$page" "the card lacks option B"
  assert_grep 'noise stops, open PRs still fail' "$page" "the card lacks option B's consequence"
  # 3. if nothing
  assert_grep 'the wake keeps coming' "$page" "the card lacks the if-nothing answer"
  # 4. reversible, 5. risk
  assert_grep 'data-hant="可回頭"' "$page" "the card lacks the reversible answer"
  assert_grep 'data-hant="風險 低"' "$page" "the card lacks the risk answer"
  # recommendation and why
  assert_grep '<span class="pk-rec">Raise to 15 s' "$page" "the card does not name the recommended option"
  assert_grep 'measured latency is 0.9 to 4.4 s' "$page" "the card lacks the why behind the recommendation"
  assert_grep 'class="bb-opt pk-opt pk-opt--rec"' "$page" "the recommended option is not marked"
  # Copy objects render per language; plain strings render as written.
  assert_grep 'data-en="Raise the bound" data-hant="拉高上限" data-hans="拉高上限"' "$page" "the trilingual title lost a language or hans did not fall back to hant"
  assert_no_grep 'data-en="Ship which fix first?"' "$page" "a plain string grew language attributes"
  assert_no_grep 'pk-raw-json' "$page" "the card dumped the decision JSON a second time"
  [ "$(section_order "$page")" = 'id="s_changed" id="s_session" id="s_decision" id="s_evidence" id="s_more" ' ] \
    || fail "sections are missing or out of packet order: $(section_order "$page")"
  pass "the rendered decision card answers all five questions and the recommendation"
}

test_serve_opens_the_page_under_a_stable_name_and_the_card_links_it() {
  local home out packet page real
  home=$(make_home serve)
  make_lavish_stub "$home" names
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  # Before any session is open, the card carries no packet link.
  out=$(run_packet_lavish "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e 'has("packet_url") | not' >/dev/null || fail "card linked a page nobody served: $out"
  out=$(run_packet_lavish "$home" serve pk-1) || fail "serve failed: $out"
  assert_present "$page" "serve did not render the page"
  assert_contains "$out" "page: $page" "serve did not report the page: $out"
  assert_contains "$out" "url: http://127.0.0.1:4387/s/packet-pk-1" "serve did not print the named URL: $out"
  assert_grep '--name packet-pk-1' "$home/lavish-state/args" "serve did not open the page under its stable name"
  real=$(cd "$(dirname "$page")" && pwd -P)/packet.html
  assert_equals "$(cat "$home/lavish-state/open")" "$real" "serve opened a different file"
  out=$(run_packet_lavish "$home" card pk-1) || fail "card failed after serve: $out"
  printf '%s' "$out" | jq -e '.packet_url == "http://127.0.0.1:4387/s/packet-pk-1"' >/dev/null \
    || fail "card did not carry the served URL: $out"
  # The worker edits the packet after serve: card re-renders the stale page before linking it.
  fill_decision "$packet" "$(printf '%s' "$GOOD_DECISION" | jq -c '.recommend_why = "the slowest repo measured 4.4 s"')"
  touch -t 202001010000 "$page"
  out=$(run_packet_lavish "$home" card pk-1) || fail "card failed on a stale page: $out"
  printf '%s' "$out" | jq -e '.packet_url == "http://127.0.0.1:4387/s/packet-pk-1"' >/dev/null \
    || fail "card dropped the served URL after re-rendering: $out"
  assert_grep 'the slowest repo measured 4.4 s' "$page" "card linked a page rendered from the old packet"
  # An older lavish-axi without --name gets the plain open and the keyed URL.
  home=$(make_home serve-keyed)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  fill_prose "$home/data/pk-1/packet.md"
  out=$(run_packet_lavish "$home" serve pk-1) || fail "serve failed without name support: $out"
  assert_contains "$out" "url: http://127.0.0.1:4387/session/deadbeef" "serve did not print the keyed URL: $out"
  assert_no_grep '--name' "$home/lavish-state/args" "serve passed --name to a lavish-axi that lacks it"
  pass "serve opens the page under a stable name and the card links the served URL"
}

test_name_support_probe_never_lists_before_the_session_is_opened() {
  local home packet first
  home=$(make_home name-probe-inert)
  make_lavish_stub "$home" names
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  run_packet_lavish "$home" serve pk-1 >/dev/null || fail "serve failed"
  # A listing is the read serve's open/reopen decision consumes, so nothing
  # serve asks before opening the session may be one. Pinning the FIRST call
  # keeps a future probe from answering a question serve has not asked yet.
  first=$(sed -n '1p' "$home/lavish-state/calls")
  case "$first" in
    '<list>') fail "serve listed sessions before opening one" ;;
  esac
  pass "the session-name probe never lists sessions before the page session is opened"
}

test_scaffold_is_generated_from_the_worktree_and_refuses_to_overwrite
test_verify_refuses_a_skeleton_and_accepts_a_filled_packet
test_verify_checks_the_decision_block_field_by_field
test_card_emits_a_board_ready_decision_item
test_path_and_bad_ids_are_refused
test_render_writes_a_self_contained_page_for_a_done_packet
test_render_decision_card_answers_the_five_questions
test_serve_opens_the_page_under_a_stable_name_and_the_card_links_it
test_name_support_probe_never_lists_before_the_session_is_opened
