#!/usr/bin/env bash
# Behavior tests for bin/fm-packet.sh: the scaffold is generated from the
# task's worktree, verify refuses a skeleton and accepts a filled packet, the
# decision block is validated field by field, the figures section is held to
# the SVG contract clause by clause, a needs-decision packet owes one figure
# comparing every option, card emits a board-ready Captain's Call item, render
# writes one self-contained HTML page whose decision card answers the five
# questions and whose figures ride it as inline SVG, and serve opens that page
# with lavish-axi under a stable name and hands the card its URL.
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

# One drawing that puts both options together, meeting every clause of the SVG
# contract fm-packet.sh's header states: three languages on every text node,
# colours only as the page's variables, data-node on every shape, ids prefixed
# per figure, no external font, and one evidence line per drawn connector.
read -r -d '' GOOD_SVG <<'SVG' || true
<svg role="img" viewBox="0 0 640 260" xmlns="http://www.w3.org/2000/svg" aria-labelledby="opt-title">
  <title id="opt-title">Where the two options differ</title>
  <defs><marker id="opt-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0 0 L8 4 L0 8 z" fill="var(--muted)"/></marker></defs>
  <rect id="opt-box-a" data-node="bound" x="24" y="24" width="220" height="80" rx="8" fill="var(--accent-tint)" stroke="var(--accent)"/>
  <text x="34" y="54" style="font-family:var(--sans)" data-en="Raise the bound" data-hant="拉高上限" data-hans="拉高上限">Raise the bound</text>
  <rect id="opt-box-b" data-node="quiet" x="24" y="150" width="220" height="80" rx="8" fill="var(--card-2)" stroke="var(--rule)"/>
  <text x="34" y="180" data-en="Stop waking on merged" data-hant="不再為已合併喚醒" data-hans="不再为已合并唤醒">Stop waking on merged</text>
  <rect id="opt-box-end" data-node="wake" x="400" y="88" width="200" height="80" rx="8" fill="var(--card)" stroke="var(--rule)"/>
  <text x="410" y="118" data-en="The wake stops" data-hant="喚醒停止" data-hans="唤醒停止">The wake stops</text>
  <path data-edge="bound-to-quiet" d="M244 64 L400 118" stroke="var(--accent)" fill="none" marker-end="url(#opt-arrow)"/>
  <path data-edge="quiet-to-end" d="M244 190 L400 138" stroke="var(--muted)" fill="none" marker-end="url(#opt-arrow)"/>
</svg>
SVG

good_figures() {  # -> the whole Figures body, with $1 substituted for the svg when given
  printf '%s\n' \
    '### Where the two options differ' \
    'figure: opt' \
    'caption: Both options end at the same place; only the left column differs.' \
    '' \
    "${1-$GOOD_SVG}" \
    '' \
    '- edge bound-to-quiet: measured in tests/fm-contributions.test.sh:120' \
    '- edge quiet-to-end: the merged-record rule at bin/fm-contributions.sh:190'
}

fill_figures() {  # <packet> [figures-body]: replace the scaffolded Figures section
  local body=${2-}
  [ -n "$body" ] || body=$(good_figures)
  FIG_BODY="$body" python3 - "$1" <<'PY'
import os, re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
body = os.environ["FIG_BODY"]
if "## Figures" in s:
    s = re.sub(r"## Figures\n.*?\n## Evidence", lambda m: "## Figures\n\n" + body + "\n\n## Evidence", s, flags=re.S)
else:
    s = s.replace("\n## Evidence", "\n## Figures\n\n" + body + "\n\n## Evidence", 1)
p.write_text(s)
PY
}

# Refuse the good figure with one clause broken; every case must name its reason.
assert_figure_refused() {  # <home> <packet> <figures-body> <expected> <why>
  local out rc
  fill_figures "$2" "$3"
  set +e; out=$(run_packet "$1" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted $5"
  assert_contains "$out" "$4" "verify refused $5 for the wrong reason: $out"
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
  fill_figures "$packet"
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

test_verify_holds_a_figure_to_the_svg_contract() {
  local home packet out svg body styled foreign
  home=$(make_home figures)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  assert_grep "## Figures" "$packet" "a needs-decision scaffold has no Figures section"
  assert_grep "diagram-design skill" "$packet" "the scaffold does not point at the drawing skill"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"

  # An unfilled Figures section is refused even once the prose is written.
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  assert_contains "$out" "placeholders remain" "the figure skeleton was not caught: $out"

  fill_figures "$packet"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a good trilingual figure: $out"
  assert_contains "$out" "packet: ok" "verify did not accept the figure: $out"
  # verify owns the mechanical half only; it must not imply it read the drawing.
  assert_contains "$out" "figures: 1 checked against the contract; legibility is not" \
    "verify let a passing contract stand in for a legible drawing: $out"

  # 1. every text node carries all three languages
  svg=${GOOD_SVG/ data-hans=\"唤醒停止\"/}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a <text> is missing data-hans" "a text node with no 简体"

  # 2. colours come from the page's variables, never a baked-in literal
  svg=${GOOD_SVG/fill=\"var(--accent-tint)\"/fill=\"#f4d8c9\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'colours come from the page' "a hex fill"
  svg=${GOOD_SVG/style=\"font-family:var(--sans)\"/style=\"font-family:var(--sans);fill:rgb(20,20,20)\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'styles fill: rgb(20,20,20)' "an rgb() fill in a style attribute"
  # A variable the page never binds resolves to nothing and the shape falls
  # back to black on --card, so only the bound palette passes.
  svg=${GOOD_SVG/fill=\"var(--accent-tint)\"/fill=\"var(--ink)\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'colours come from the page' "a variable outside the page's palette"
  # Every attribute clause must see an unquoted value too, or it is one
  # missing pair of quotes away from being unenforced.
  svg=${GOOD_SVG/fill=\"var(--accent-tint)\"/fill=#f4d8c9}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'colours come from the page' "an unquoted hex fill"
  svg=${GOOD_SVG/<rect id=\"opt-box-end\"/<rect onload=alert(1) id=\"opt-box-end\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "inline onload handler" "an unquoted event handler"

  # 3. every selectable shape carries its identity attribute
  svg=${GOOD_SVG/ data-node=\"wake\"/}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a <rect> carries no data-node" "a shape with no identity"

  # 4. ids are prefixed per figure, so two figures on one page cannot collide
  svg=${GOOD_SVG/id=\"opt-arrow\"/id=\"arrow\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'is not prefixed "opt-"' "an unprefixed marker id"
  # The prefix only separates two drawings while each owns its own slug.
  body=$(printf '%s\n\n%s\n' "$(good_figures)" "$(good_figures)")
  assert_figure_refused "$home" "$packet" "$body" \
    "already the slug of figure 1" "two figures declaring the same slug"

  # 5. no external font reference, no script, no <style> element
  svg=${GOOD_SVG/<title id=\"opt-title\">/<style>@import url(https://fonts.googleapis.com/css2?family=Geist);</style><title id=\"opt-title\">}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "references an external font" "an imported web font"
  # An inline <style> is not scoped to its svg: it restyles the whole served
  # page, so a drawing carries none at all.
  styled='<style>.pk-section{display:none}rect{fill:red}</style><title id="opt-title">'
  svg=${GOOD_SVG/<title id=\"opt-title\">/"$styled"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "the svg carries a <style>" "a style element that restyles the page"
  svg=${GOOD_SVG/<title id=\"opt-title\">/<script>void 0;<\/script><title id=\"opt-title\">}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "the svg carries a <script>" "a script inside the drawing"
  # A <foreignObject> holds HTML the language clause cannot read, so its labels
  # would stay English when the captain switches the page.
  foreign='<foreignObject x="0" y="0" width="90" height="20"><div style="font-size:12px">SparkSQL</div></foreignObject><title id="opt-title">'
  svg=${GOOD_SVG/<title id=\"opt-title\">/"$foreign"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "the svg carries a <foreignObject>" "HTML labels the language switch cannot reach"
  # The svg rides the page unescaped, so a link scheme the page's own prose
  # refuses must not reach it through a drawing, and nothing may fetch on open.
  svg=${GOOD_SVG/<rect id=\"opt-box-end\"/<a href=\"javascript:alert(1)\"><rect id=\"opt-box-end\"}
  svg=${svg/<\/svg>/<\/a><\/svg>}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "only an <a> may leave the page" "a javascript: link inside the drawing"
  svg=${GOOD_SVG/<title id=\"opt-title\">/<image href=\"https:\/\/evil.example\/beacon.png\" x=\"0\" y=\"0\"\/><title id=\"opt-title\">}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "same-document #fragment" "an image fetched from the network"

  # 6. a drawn connector needs an identity, and every identity needs evidence
  svg=${GOOD_SVG/ data-edge=\"quiet-to-end\"/}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "draws an arrow with no data-edge" "an unnamed connector"
  body=$(good_figures | grep -v 'edge quiet-to-end:')
  assert_figure_refused "$home" "$packet" "$body" \
    "has no '- edge quiet-to-end:" "a connector with no evidence line"
  body=$(good_figures)$'\n''- edge ghost: nothing draws this'
  assert_figure_refused "$home" "$packet" "$body" \
    'evidence names edge "ghost"' "evidence for a line the drawing does not have"

  # A figure must still declare its slug, role and caption.
  body=$(good_figures | grep -v '^caption:')
  assert_figure_refused "$home" "$packet" "$body" \
    "'caption:' is missing" "a figure with no caption"
  pass "verify holds a figure to the SVG contract clause by clause"
}

test_a_needs_decision_packet_owes_one_figure_comparing_every_option() {
  local home packet out body rc rect_b circle_b
  home=$(make_home compare)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"

  # One drawing per option buries the only question the reader has: a figure
  # naming neither option is refused before any per-option wording is tried.
  body=$(good_figures "${GOOD_SVG//data-node=\"bound\"/data-node=\"other\"}")
  body=${body//data-node=\"quiet\"/data-node=\"elsewhere\"}
  assert_figure_refused "$home" "$packet" "$body" \
    "no figure puts the options together" "a packet whose figures name no option at all"

  # An option named on any shape counts: the contract requires data-node on
  # rect and polygon, it does not confine the comparison to those two.
  rect_b='<rect id="opt-box-b" data-node="quiet" x="24" y="150" width="220" height="80" rx="8" fill="var(--card-2)" stroke="var(--rule)"/>'
  circle_b='<circle id="opt-box-b" data-node="quiet" cx="134" cy="190" r="40" fill="var(--card-2)" stroke="var(--rule)"/>'
  fill_figures "$packet" "$(good_figures "${GOOD_SVG/"$rect_b"/"$circle_b"}")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused an option drawn as a circle: $out"

  # A comparison that omits one option is not a comparison, and it is named.
  body=$(good_figures "${GOOD_SVG/data-node=\"quiet\"/data-node=\"other\"}")
  assert_figure_refused "$home" "$packet" "$body" \
    'draws no shape with data-node="quiet"' "a comparison figure missing an option"

  # There is no line that excuses the figures: a section that declares the
  # drawing skill absent still owes the drawing.
  fill_figures "$packet" 'no-figures: the diagram-design skill is not installed in this worker environment'
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  assert_contains "$out" "carries no '### ' figure" "a declared absence bought a pass: $out"

  # A figure that carries no drawing at all is refused, not swallowed: the
  # comparison rule must not crash past the problems the figure already has.
  fill_figures "$packet" "$(good_figures '')"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a needs-decision figure with no drawing in it: $out"
  assert_contains "$out" "carries 0 inline <svg> block(s)" "the missing drawing was swallowed: $out"
  case "$out" in *"packet: ok"*) fail "a crashed figures check read as a verified packet: $out" ;; esac

  # A needs-decision packet that simply drops the section is refused.
  python3 - "$packet" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(re.sub(r"## Figures\n.*?\n## Evidence", "## Evidence", s, flags=re.S))
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  assert_contains "$out" "there is no '## Figures' section" "a decision with no figures at all was accepted: $out"
  pass "a needs-decision packet owes one figure that names every option"
}

test_a_done_packet_is_not_refused_for_having_no_figures() {
  local home packet out rc
  home=$(make_home done-figures)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  assert_no_grep "## Figures" "$packet" "a done scaffold grew a Figures section it does not owe"
  fill_prose "$packet"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a done packet with no figures: $out"
  assert_contains "$out" "packet: ok" "the packet every worker already writes stopped verifying: $out"
  case "$out" in *"legibility is not"*) fail "verify talked about figures a packet does not have: $out" ;; esac

  # A done packet may carry figures, and they are held to the same contract.
  fill_figures "$packet"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a good figure on a done packet: $out"
  assert_figure_refused "$home" "$packet" "$(good_figures "${GOOD_SVG/ data-node=\"wake\"/}")" \
    "carries no data-node" "a broken figure on a done packet"

  # render routes a '## Figures ' heading through figures_html and inlines its
  # svg unescaped, so verify must hold that same heading to the contract; a
  # gate stricter than the renderer it guards is a way past every clause.
  python3 - "$packet" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("\n## Figures\n", "\n##  Figures \n"))
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a whitespace-padded Figures heading skipped the contract: $out"
  assert_contains "$out" "carries no data-node" "the padded heading was not checked: $out"

  # python splits lines on more than \n, so a heading behind a form feed is a
  # Figures section to the checker and to render. The shell gate in front of
  # the checker reads whole physical lines and must never be the reader that
  # misses it, or the drawing reaches the page with nothing having read it.
  python3 - "$packet" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("\n##  Figures \n", "\n\f## Figures\n"))
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a Figures heading behind a form feed skipped the contract: $out"
  assert_contains "$out" "carries no data-node" "the form-feed heading was not checked: $out"
  pass "a done packet needs no figures and is held to the contract for the ones it has"
}

test_a_packet_carries_one_figures_section_and_render_publishes_nothing_else() {
  local home packet out rc
  home=$(make_home second-figures)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_figures "$packet"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused one good figures section: $out"

  # A second '## Figures' heading is a second set of drawings the page has no
  # place for - it would render under the same section id - so the packet is
  # refused rather than the extra section being inlined on verify's word.
  python3 - "$packet" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
second = """
## Figures

### A second drawing nobody checked
figure: two
caption: The section a worker adds when the first one filled up.

<svg role="img" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><script>alert(document.title);</script><rect id="nope" fill="#ff0000" x="0" y="0" width="4" height="4"/><a href="javascript:alert(1)"><text x="1" y="8">English only</text></a></svg>
"""
p.write_text(s.rstrip("\n") + "\n" + second)
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a second figures section verified: $out"
  assert_contains "$out" "declares 2 '## Figures' sections" "the second section was not named: $out"
  # render publishes nothing a verify refused, so that section never reaches
  # the page it would otherwise be inlined into unescaped.
  set +e; out=$(run_packet "$home" render pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "render published a packet verify refused: $out"
  assert_absent "$home/data/pk-1/packet.html" "render wrote a page for a refused packet"

  # The Evidence check counts the lines between its heading and the next one,
  # so the reader that finds that boundary has to be the one verify reads the
  # headings with: an empty Evidence section followed by a drawing is still a
  # skeleton, however many svg lines sit under the heading after it.
  home=$(make_home empty-evidence)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  python3 - "$packet" "$(good_figures)" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"## Evidence\n.*?\n## How", "## Evidence\n\n## Figures\n\n" + sys.argv[2] + "\n\n## How", s, flags=re.S)
p.write_text(s)
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an empty Evidence section followed by figures verified: $out"
  assert_contains "$out" "'Evidence' is empty" "the emptied Evidence section was not caught: $out"
  pass "a packet carries one figures section and render publishes nothing verify refused"
}

test_the_captains_page_carries_only_what_the_worker_wrote() {
  local home packet page leftover paras
  home=$(make_home scaffold-prose)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"

  # Every line the scaffold writes into the Figures section is a placeholder
  # the worker is asked to replace; it authors no prose of its own, so nothing
  # the fleet says to itself can survive onto the captain's decision surface.
  leftover=$(python3 - "$packet" <<'PY'
import pathlib, sys
inside, out = False, []
for l in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if l.startswith("## "):
        inside = l[3:].strip() == "Figures"
    elif inside and l.strip() and "{FILL" not in l:
        out.append(l)
print("\n".join(out))
PY
)
  [ -z "$leftover" ] || fail "the scaffold wrote Figures prose nothing asks the worker to remove: $leftover"

  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  run_packet "$home" render pk-1 >/dev/null || fail "render failed"
  # The section carries the drawings, their headings and their captions. Prose
  # above the first figure would arrive as a paragraph; there is none to arrive.
  paras=$(python3 - "$page" <<'PY'
import pathlib, re, sys
m = re.search(r'<section[^>]*id="s_figures".*?</section>', pathlib.Path(sys.argv[1]).read_text(), re.S)
print(m.group(0).count("<p>") if m else "no-figures-section")
PY
)
  [ "$paras" = 0 ] || fail "the rendered figures section carries $paras paragraph(s) beside the drawings"
  pass "the captain's page carries only what the worker wrote"
}

test_card_emits_a_board_ready_decision_item() {
  local home out packet
  home=$(make_home card)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
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
  local home packet page out
  home=$(make_home render-decision)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
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
  [ "$(section_order "$page")" = 'id="s_changed" id="s_session" id="s_decision" id="s_figures" id="s_evidence" id="s_more" ' ] \
    || fail "sections are missing or out of packet order: $(section_order "$page")"
  # The drawing rides the page as inline SVG, not as escaped text, and the
  # language switch reaches its labels like everything else on the page.
  assert_grep '<figure class="pk-fig" id="fig-opt">' "$page" "the figure did not render"
  assert_grep '<rect id="opt-box-a" data-node="bound"' "$page" "the svg was not inlined"
  assert_no_grep '&lt;svg' "$page" "the svg was escaped into text instead of inlined"
  assert_grep 'data-hant="拉高上限" data-hans="拉高上限">Raise the bound</text>' "$page" "the drawing lost its languages"
  assert_grep 'Both options end at the same place' "$page" "the figure lost its caption"
  # The per-connector evidence is an integrity check verify owns, not page
  # content: it never reaches the captain's page.
  assert_no_grep 'pk-fig__edges' "$page" "the figure rendered an edge-evidence list"
  assert_no_grep '<code>bound-to-quiet</code>' "$page" "an edge id rendered as page content"
  assert_no_grep '每條線的依據' "$page" "the edge-evidence heading survived in the page's chrome"
  assert_grep '--accent-tint: var(--rust-050)' "$page" "the page does not bind the palette figures draw against"

  # A worker who drops the section's preamble leaves the '### ' heading on the
  # first line of the body. verify reads that as a figure, so render must too.
  python3 - "$packet" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("## Figures\n\n### ", "## Figures\n### "))
PY
  run_packet "$home" verify pk-1 >/dev/null || fail "verify refused a Figures section that opens on its heading"
  run_packet "$home" render pk-1 >/dev/null || fail "render failed on a Figures section that opens on its heading"
  assert_grep '<rect id="opt-box-a" data-node="bound"' "$page" "the first figure's svg was not inlined"
  assert_no_grep '&lt;svg' "$page" "the first figure's svg was escaped into prose"
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
  fill_figures "$packet"
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
  fill_figures "$packet"
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
test_verify_holds_a_figure_to_the_svg_contract
test_a_needs_decision_packet_owes_one_figure_comparing_every_option
test_a_done_packet_is_not_refused_for_having_no_figures
test_a_packet_carries_one_figures_section_and_render_publishes_nothing_else
test_the_captains_page_carries_only_what_the_worker_wrote
test_card_emits_a_board_ready_decision_item
test_path_and_bad_ids_are_refused
test_render_writes_a_self_contained_page_for_a_done_packet
test_render_decision_card_answers_the_five_questions
test_serve_opens_the_page_under_a_stable_name_and_the_card_links_it
test_name_support_probe_never_lists_before_the_session_is_opened
