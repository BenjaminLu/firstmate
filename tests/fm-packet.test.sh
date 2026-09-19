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
SAID = [
    ("tried a retry loop first; dropped it because the bound, not the forge, was failing",
     "先試過重試迴圈，後來放棄，因為壞的是上限不是 forge",
     "先试过重试循环，后来放弃，因为坏的是上限不是 forge"),
    ("the 15 s bound is unverified against the slowest repo",
     "15 秒的上限沒有對最慢的 repo 驗證過",
     "15 秒的上限没有对最慢的 repo 验证过"),
    ("the merged-record rule assumes settle_final runs before publish",
     "合併記錄規則假設 settle_final 在 publish 之前跑",
     "合并记录规则假设 settle_final 在 publish 之前跑"),
]
said = "\n".join("- en: %s\n- hant: %s\n- hans: %s" % t for t in SAID)
s = re.sub(r"- en: \{FILL: every path you tried.*?- hans: \{FILL[^}]*\}", lambda m: said, s, flags=re.S)
EVIDENCE = [
    ("the bound is measured in forge(), not in the poller",
     "上限是在 forge() 裡量的，不是在 poller",
     "上限是在 forge() 里量的，不是在 poller"),
]
evidence = "\n".join("- en: %s\n- hant: %s\n- hans: %s" % t for t in EVIDENCE)
# A line that is only a path or a command needs no translation, and says so by
# being backticked - the same exemption the approved prototype's block uses.
evidence += "\n- `bin/fm-contributions.sh:190`\n- `tests/fm-contributions.test.sh`"
s = re.sub(r"- en: \{FILL: file:line.*?- hans: \{FILL[^}]*\}", lambda m: evidence, s, flags=re.S)
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
# colours only as the page's variables, a latin data-node on each shape that
# stands for an option, ids prefixed
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
    'heading.hant: 兩個選項差在哪' \
    'heading.hans: 两个选项差在哪' \
    'figure: opt' \
    'caption: Both options end at the same place; only the left column differs.' \
    'caption.hant: 兩個選項最後都到同一處，只有左邊那欄不同。' \
    'caption.hans: 两个选项最后都到同一处，只有左边那栏不同。' \
    '' \
    "${1-$GOOD_SVG}" \
    '' \
    '- edge bound-to-quiet: measured in tests/fm-contributions.test.sh:120' \
    '- edge quiet-to-end: the merged-record rule at bin/fm-contributions.sh:190'
}

fill_figures() {  # <packet> [figures-body] [gap]: replace the scaffolded Figures section
  local body=${2-}
  [ -n "$body" ] || body=$(good_figures)
  FIG_BODY="$body" FIG_GAP="${3-}" python3 - "$1" <<'PY'
import os, re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
body = os.environ["FIG_BODY"]
gap = "\n" if os.environ.get("FIG_GAP") == "tight" else "\n\n"
if "## Figures" in s:
    s = re.sub(r"## Figures\n.*?\n## Evidence", lambda m: "## Figures" + gap + body + "\n\n## Evidence", s, flags=re.S)
else:
    s = s.replace("\n## Evidence", "\n## Figures" + gap + body + "\n\n## Evidence", 1)
p.write_text(s)
PY
}

set_figures_from_stdin() {  # <packet> <<'MD' ... MD : replace the section from stdin
  fill_figures "$1" "$(cat)"
}

# The same, with the body pressed straight against the section heading: a packet
# with no blank line there is one verify accepts, so the card must read it the
# same way rather than losing the first drawing.
set_figures_tight_from_stdin() {  # <packet> <<'MD' ... MD
  fill_figures "$1" "$(cat)" tight
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
  local home packet out svg body styled foreign wrapped plain masked cursored n
  home=$(make_home figures)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  assert_grep "## Figures" "$packet" "a needs-decision scaffold has no Figures section"
  assert_grep "diagram-design skill" "$packet" "the scaffold does not point at the drawing skill"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"

  # An unfilled Figures section is refused even once the prose is written -
  # by the placeholder check that owns it, and by nothing else: the drawing's
  # own {FILL} slot must not be reported as a stray line to move elsewhere.
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  assert_contains "$out" "placeholders remain" "the figure skeleton was not caught: $out"
  case "$out" in
    *"is not part of the figure"*)
      fail "verify told the worker to move the drawing's own placeholder: $out" ;;
  esac

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
  # back to black on --card, so only the bound palette passes - and the
  # refusal names the palette, since "use var(--...)" is what was written.
  svg=${GOOD_SVG/fill=\"var(--accent-tint)\"/fill=\"var(--ink)\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'the page binds no --ink' "a variable outside the page's palette"
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'the palette is --fg, --muted' "a palette refusal that does not say what to use"

  # A url() in a style declaration fetches like an href does, so it points at
  # a same-document fragment or the page stops rendering offline.
  cursored='style="cursor:url(//evil.example/c.cur),auto"'
  svg=${GOOD_SVG/style=\"font-family:var(--sans)\"/"$cursored"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a url() in a drawing points at a same-document #fragment" "a style that fetches off-origin"
  # The presentation-attribute form of the same property fetches the same way.
  clipped='clip-path="url(//evil.example/f.svg#blur)" id="opt-box-end"'
  svg=${GOOD_SVG/id=\"opt-box-end\"/"$clipped"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a url() in a drawing points at a same-document #fragment" "a clip-path that fetches off-origin"
  # And an attribute the drawing vocabulary does not name is refused as itself,
  # whatever it holds - there is no clause to spell around because there is no
  # clause, only the list of what a drawing carries.
  filtered='filter="url(#opt-blur)" id="opt-box-end"'
  svg=${GOOD_SVG/id=\"opt-box-end\"/"$filtered"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a drawing carries only the attributes it draws with" "an attribute outside the drawing vocabulary"
  # SMIL sets the attribute at runtime, so an animation aimed at href reaches
  # the scheme the clause above refuses; motion itself stays welcome.
  animated='<a href="#opt-box-a"><set attributeName="href" to="javascript:alert(1)" begin="0s"/><rect id="opt-box-a" data-node="bound" x="24" y="24" width="220" height="80" fill="var(--card)"/></a><rect id="opt-box-a2"'
  svg=${GOOD_SVG/<rect id=\"opt-box-a\"/"$animated"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'animates href: <set> has href="javascript:alert(1)"' "an animation that repoints a link at a script"
  # An animation that moves a shape, or repoints a reference inside the
  # document, is what the drawing tool emits and is not refused.
  moved='<animate attributeName="opacity" from="0" to="1" begin="0s" dur="1s"/><rect id="opt-box-a"'
  svg=${GOOD_SVG/<rect id=\"opt-box-a\"/"$moved"}
  fill_figures "$packet" "$(good_figures "$svg")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused an animation that moves a shape: $out"
  local_ref='<set attributeName="href" to="#opt-box-end" begin="0s"/><rect id="opt-box-a"'
  svg=${GOOD_SVG/<rect id=\"opt-box-a\"/"$local_ref"}
  fill_figures "$packet" "$(good_figures "$svg")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused an animation onto a same-document fragment: $out"
  # The same-document form every drawing already uses is untouched.
  fill_figures "$packet"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused url(#opt-arrow): $out"

  # A bound variable written with a fallback is refused for what is wrong with
  # it, not for a palette it is already in.
  svg=${GOOD_SVG/fill=\"var(--card-2)\"/fill=\"var(--card-2, #fff)\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'has to be exactly var(--card-2)' "a bound variable carrying a fallback"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  case "$out" in
    *"binds no --card-2"*) fail "the refusal called a bound variable unbound: $out" ;;
  esac
  # Every attribute clause must see an unquoted value too, or it is one
  # missing pair of quotes away from being unenforced.
  svg=${GOOD_SVG/fill=\"var(--accent-tint)\"/fill=#f4d8c9}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'colours come from the page' "an unquoted hex fill"
  svg=${GOOD_SVG/<rect id=\"opt-box-end\"/<rect onload=alert(1) id=\"opt-box-end\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a drawing carries only the attributes it draws with" "an unquoted event handler"
  # Every clause reads a value through one attribute map, and the browser takes
  # the FIRST of a duplicated attribute. A map that took the last would let a
  # drawing show the checker a harmless value and the reader the live one.
  dup='<a href="javascript:alert(1)" href="#opt-box-end"><rect id="opt-box-end"'
  svg=${GOOD_SVG/<rect id=\"opt-box-end\"/$dup}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'href="javascript:alert(1)"' "a javascript: href hidden behind a duplicate attribute"
  dup='<rect fill="red" fill="var(--card)" id="opt-box-end"'
  svg=${GOOD_SVG/<rect id=\"opt-box-end\"/$dup}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'has fill="red"' "a baked colour hidden behind a duplicate attribute"
  # The checker names what a drawing MAY carry, so every one of these refuses
  # for the same reason rather than each needing its own clause. Five of them
  # are the five spellings that got past a pattern on this branch; the rest are
  # HTML breakout markup, which ends the svg and reparses on the board.
  local shape
  for shape in \
    '<meta http-equiv="refresh" content="0;url=https://evil.example/board"><rect id="opt-box-end"' \
    '<button formaction="https://evil.example/collect">Choose</button><rect id="opt-box-end"' \
    '<img src="https://evil.example/pixel"><rect id="opt-box-end"' \
    '<p></p><div></div><br><table></table><rect id="opt-box-end"' \
    '<iframe src="https://evil.example/"></iframe><rect id="opt-box-end"' \
    '<rect formaction="https://evil.example/x" id="opt-box-end"' \
    '<rect onpointerdown="alert(1)" id="opt-box-end"' \
    '<rect/onclick="alert(1)" id="opt-box-end"' \
    '<rect onclick=a("b")<z id="opt-box-end"' \
    '<rect id="opt-box-end" onclick="alert(1)" onclick="0"' \
    '<rect class="bb-decision__foot" id="opt-box-end"' \
    '<rect style="position:fixed;top:0;left:0;width:100vw;height:100vh;opacity:0.01" id="opt-box-end"' \
    '<set attributeName="style" to="position:fixed;top:0;width:100vw;height:100vh"/><rect id="opt-box-end"' \
    '<set attributeName="onclick" to="alert(1)"/><rect id="opt-box-end"' \
    '<animate attributeName="style" values="opacity:1;position:fixed"/><rect id="opt-box-end"' \
  ; do
    svg=${GOOD_SVG/<rect id=\"opt-box-end\"/$shape}
    fill_figures "$packet" "$(good_figures "$svg")"
    set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "verify accepted a drawing outside the contract: $shape"
  done
  # And markup this reader cannot tokenize is refused rather than passed on the
  # word that it was checked: the page would tokenize it some other way.
  svg=${GOOD_SVG/<title id=\"opt-title\">/<!-- never closed <title id="opt-title">}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "cannot be read the way a browser reads it" "a drawing with an unterminated comment"

  # 3. an identity that is claimed is the source's latin name. A shape that
  # claims none stands for nothing a reader selects - a label mask, a panel -
  # and the comparison rule, not a per-tag demand, is what makes the options
  # appear.
  svg=${GOOD_SVG/data-node=\"wake\"/data-node=\"喚醒停止\"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    'has data-node="喚醒停止"' "an identity written in the reader's wording"
  masked='<rect id="opt-label-mask" x="250" y="100" width="120" height="20" fill="var(--card)"/>'
  svg=${GOOD_SVG/<path data-edge=\"bound-to-quiet\"/$masked<path data-edge="bound-to-quiet"}
  fill_figures "$packet" "$(good_figures "$svg")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify demanded an identity from a label mask: $out"

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
    "<style> is not a drawing" "an imported web font"
  # An inline <style> is not scoped to its svg: it restyles the whole served
  # page, so a drawing carries none at all.
  styled='<style>.pk-section{display:none}rect{fill:red}</style><title id="opt-title">'
  svg=${GOOD_SVG/<title id=\"opt-title\">/"$styled"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "<style> is not a drawing" "a style element that restyles the page"
  svg=${GOOD_SVG/<title id=\"opt-title\">/<script>void 0;<\/script><title id=\"opt-title\">}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "<script> is not a drawing" "a script inside the drawing"
  # The language switch replaces a label's whole text content, so a <tspan>
  # inside a <text> is destroyed the first time the captain switches.
  plain='<text x="34" y="54" style="font-family:var(--sans)" data-en="Raise the bound" data-hant="拉高上限" data-hans="拉高上限">Raise the bound</text>'
  wrapped='<text x="34" y="54" data-en="Raise the bound" data-hant="拉高上限" data-hans="拉高上限"><tspan x="34" dy="0">Raise</tspan><tspan x="34" dy="16">the bound</tspan></text>'
  svg=${GOOD_SVG/"$plain"/"$wrapped"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a <text> has element children" "a label split into tspans"

  # A <foreignObject> holds HTML the language clause cannot read, so its labels
  # would stay English when the captain switches the page.
  foreign='<foreignObject x="0" y="0" width="90" height="20"><div style="font-size:12px">SparkSQL</div></foreignObject><title id="opt-title">'
  svg=${GOOD_SVG/<title id=\"opt-title\">/"$foreign"}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "<foreignobject> is not a drawing" "HTML labels the language switch cannot reach"
  # The svg rides the page unescaped, so a link scheme the page's own prose
  # refuses must not reach it through a drawing, and nothing may fetch on open.
  svg=${GOOD_SVG/<rect id=\"opt-box-end\"/<a href=\"javascript:alert(1)\"><rect id=\"opt-box-end\"}
  svg=${svg/<\/svg>/<\/a><\/svg>}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "only an <a> may leave the page" "a javascript: link inside the drawing"
  svg=${GOOD_SVG/<title id=\"opt-title\">/<image href=\"https:\/\/evil.example\/beacon.png\" x=\"0\" y=\"0\"\/><title id=\"opt-title\">}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "<image> is not a drawing" "an image fetched from the network"

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

  # No figure clause reads above the first '### ', so a drawing parked there
  # would reach the page with nothing having checked it - and render escapes
  # it into source text rather than drawing it.
  body=$(printf '%s\n\n%s\n' "$GOOD_SVG" "$(good_figures)")
  assert_figure_refused "$home" "$packet" "$body" \
    "a drawing sits above the first '### ' figure" "a drawing parked above the first figure"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  n=$(printf '%s\n' "$out" | grep -c "sits above the first" || true)
  [ "$n" -eq 1 ] || fail "the parked drawing was reported $n times, once per line of its markup: $out"
  body=$(printf '%s\n\n%s\n' 'Drawn through the diagram-design skill; look before you report.' "$(good_figures)")
  assert_figure_refused "$home" "$packet" "$body" \
    "sits above the first '### ' figure" "prose parked above the first figure"

  # A drawing whose closing tag was lost has one true reason, and a worker is
  # told to fix what verify reports: reporting its every line as prose to move
  # elsewhere would have it delete the drawing line by line.
  body=$(good_figures "${GOOD_SVG/<\/svg>/}")
  assert_figure_refused "$home" "$packet" "$body" \
    "carries 0 inline <svg> block(s)" "a drawing whose closing tag was lost"
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); set -e
  case "$out" in
    *"is not part of the figure"*)
      fail "verify reported the drawing's own lines as prose to move elsewhere: $out" ;;
  esac

  # Nothing renders a line the figure body does not recognise, so verify
  # refuses it by name rather than letting it verify and then vanish.
  body=$(good_figures)$'\n''The left path re-uses the existing queue; the right one adds a second.'
  assert_figure_refused "$home" "$packet" "$body" \
    'The left path re-uses the existing queue' "a stray sentence inside a figure body"
  assert_figure_refused "$home" "$packet" "$body" \
    "goes in the caption" "a stray sentence without saying where it belongs"
  body=$(printf '%s\n%s\n' "$(good_figures)" 'caption: and a second caption nothing reads')
  assert_figure_refused "$home" "$packet" "$body" \
    "'caption:' is given twice" "a figure declaring one key twice"

  # A figure must still declare its slug, role and caption.
  body=$(good_figures | grep -v '^caption:')
  assert_figure_refused "$home" "$packet" "$body" \
    "'caption:' is missing" "a figure with no caption"
  pass "verify holds a figure to the SVG contract clause by clause"
}

test_a_needs_decision_packet_owes_one_figure_comparing_every_option() {
  local home packet out body rc rect_b circle_b under
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

  # An option value the decision block accepts is always drawable as the
  # matching identity: the two are one name, not two spellings of one.
  under=$(printf '%s' "$GOOD_DECISION" | jq -c '.options[0].value = "_baseline" | .recommend_value = "_baseline"')
  fill_decision "$packet" "$under"
  fill_figures "$packet" "$(good_figures "${GOOD_SVG/data-node=\"bound\"/data-node=\"_baseline\"}")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused an option value it accepts in the decision block: $out"
  fill_decision "$packet" "$GOOD_DECISION"

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
  # A section is the drawings in it, whatever the packet kind: an empty one
  # says a worker meant to draw and did not, and it is refused rather than
  # counted as nothing.
  python3 - "$packet" <<'PY2'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(re.sub(r"## Figures\n.*?\n## Evidence", "## Figures\n\n## Evidence", s, flags=re.S))
PY2
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an empty Figures section on a done packet verified: $out"
  assert_contains "$out" "carries no '### ' figure" "the empty section was not named: $out"
  fill_figures "$packet"

  assert_figure_refused "$home" "$packet" "$(good_figures "${GOOD_SVG/fill=\"var(--card)\"/fill=\"#ffffff\"}")" \
    "colours come from the page" "a broken figure on a done packet"

  # render routes a '## Figures ' heading through figures_html and inlines its
  # svg unescaped, so verify must hold that same heading to the contract; a
  # gate stricter than the renderer it guards is a way past every clause.
  python3 - "$packet" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("\n## Figures\n", "\n##  Figures \n"))
PY
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a whitespace-padded Figures heading skipped the contract: $out"
  assert_contains "$out" "colours come from the page" "the padded heading was not checked: $out"

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
  assert_contains "$out" "colours come from the page" "the form-feed heading was not checked: $out"
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
heading.hant: 沒人檢查過的第二張圖
heading.hans: 没人检查过的第二张图
figure: two
caption: The section a worker adds when the first one filled up.
caption.hant: 工作者在第一段填滿後補的一節。
caption.hans: 工作者在第一段填满后补的一节。

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

# diagram-design nests icon <svg> elements inside the drawing - its own
# examples ship a dozen - so the figure below is what unmodified skill output
# looks like once its colours are edited to the page's palette.
read -r -d '' NESTED_ICON <<'SVG' || true
  <svg x="34" y="200" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--muted)" stroke-width="1.5" aria-hidden="true">
    <circle cx="12" cy="12" r="9"/>
    <path d="M3.6 9h16.8M3.6 15h16.8"/>
  </svg>
SVG

test_a_drawing_that_nests_icon_svgs_is_one_figure_checked_end_to_end() {
  local home packet page out svg inlined
  home=$(make_home nested-svg)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"

  # One drawing, whatever it nests: the icon is part of the element, not a
  # second figure, and not a place the checker stops reading.
  svg=${GOOD_SVG/<\/svg>/$NESTED_ICON$'\n'</svg>}
  fill_figures "$packet" "$(good_figures "$svg")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a drawing with a nested icon: $out"
  assert_contains "$out" "figures: 1 checked against the contract" "the nested icon was counted as a second figure: $out"
  run_packet "$home" render pk-1 >/dev/null || fail "render failed on a nested icon"
  # The whole element reaches the page, not the bytes before the icon's </svg>.
  inlined=$(python3 - "$page" <<'PY'
import pathlib, re, sys
m = re.search(r'<div class="pk-fig__svg">(.*?)</div>', pathlib.Path(sys.argv[1]).read_text(), re.S)
svg = m.group(1) if m else ""
print(svg.count("<svg"), svg.count("</svg>"), "yes" if "opt-box-end" in svg else "no")
PY
)
  [ "$inlined" = "2 2 yes" ] || fail "the page carries a truncated drawing instead of the whole element: $inlined"

  # A drawing nests as many icons as it needs; none of them is a second figure.
  svg=${GOOD_SVG/<\/svg>/$NESTED_ICON$'\n'$NESTED_ICON$'\n'</svg>}
  fill_figures "$packet" "$(good_figures "$svg")"
  out=$(run_packet "$home" verify pk-1 2>&1) || fail "verify refused a drawing with two nested icons: $out"
  assert_contains "$out" "figures: 1 checked against the contract" "two nested icons were counted as figures: $out"

  # Nothing past the icon goes unread: the clause that would have been in the
  # unchecked tail still refuses.
  svg=${GOOD_SVG/<\/svg>/$NESTED_ICON$'\n'<text x=\"500\" y=\"240\" data-en=\"After the icon\">After the icon</text>$'\n'</svg>}
  assert_figure_refused "$home" "$packet" "$(good_figures "$svg")" \
    "a <text> is missing data-hant, data-hans" "a broken node after the nested icon"
  pass "a drawing that nests icon svgs is one figure, checked and rendered end to end"
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

test_the_card_carries_the_packet_itself() {
  local home out packet
  home=$(make_home card-packet)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  # A Figures section, in the shape the packet's own figure contract defines.
  set_figures_from_stdin "$packet" <<'MD'
### Where the options part
heading.hant: 選項在哪裡分岔
heading.hans: 选项在哪里分岔

figure: cmp
caption: Both reach the gate; only one writes onto the data stream.
caption.hant: 兩邊都會到 gate，只有一邊寫到資料輸出。
caption.hans: 两边都会到 gate，只有一边写到数据输出。

<svg viewBox="0 0 20 20"><rect data-node="bound" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><rect data-node="quiet" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><path data-edge="a-b" d="M1 1 L9 9" stroke="var(--muted)" marker-end="url(#cmp-arw)"/><text data-en="one path" data-hant="一條路" data-hans="一条路">one path</text></svg>

- edge a-b: the gate reads the error stream
MD
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    # the drawing rides the card with the identities it draws, so the board can
    # tell the comparison from an option drawing without a second declaration
    (.packet.figures | length) == 1
    and (.packet.figures[0]
      | .slug == "cmp" and (.nodes == ["bound", "quiet"])
        and (.svg | startswith("<svg"))
        # what a figure says is carried once, in the body, not twice
        and (has("caption") | not) and (has("edges") | not))
    # the rest of the packet comes as DATA: a heading the renderer owns in all
    # three languages, and the lines the worker wrote under it as text
    and ([.packet.sections[].heading | if type == "object" then .en else . end]
         == ["What changed", "What only this session knows", "Figures",
             "Evidence", "How to pull more"])
    and (.packet.sections[1].heading
         | .en == "What only this session knows" and .hant == "只有這個 session 知道的事")
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("tried a retry loop first")))
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("only one writes")))
    # no markup anywhere in it: the board builds the tags, the packet supplies
    # only words, so nothing a worker writes can restyle the captain surface
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("<svg")) | not)
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("fm-packet-decision")) | not)
    # a figure still says in words what it is, while its per-connector check
    # on the drawing renders nowhere - it was never page content
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("Where the options part")))
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("the gate reads the error stream")) | not)
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("edge a-b")) | not)
  ' >/dev/null || fail "the card did not carry the packet: $out"
  pass "the card carries the packet itself: its drawings, and the rest as words"
}

# The board still renders a card whose packet carries no drawings - that path is
# covered where it lives, in the render suite - but the packet can no longer
# REACH it by simply having none: since the figure contract landed, a
# needs-decision packet owes a drawing, and card verifies before it builds. So
# what is worth proving here is the refusal, and that it names what is missing
# rather than handing the board an empty card.
test_a_needs_decision_packet_with_no_figures_is_refused() {
  local home out rc packet
  home=$(make_home card-packet-plain)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  python3 - "$packet" <<'STRIP'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(re.sub(r"## Figures\n.*?\n## Evidence", "## Evidence", s, flags=re.S))
STRIP
  set +e; out=$(run_packet "$home" card pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "card built a decision card with no drawing: $out"
  printf '%s' "$out" | grep -q "Figures" \
    || fail "the refusal does not name the missing Figures section: $out"
  pass "a needs-decision packet with no drawing is refused, naming what is missing"
}

# A tag is not a language: a continuation line typed with nothing after it is
# that language missing, and verify has to say so here - the board validator
# refuses an empty copy field, so an empty line accepted here takes down the
# composition of the whole board with a message that names nothing.
test_an_empty_language_line_is_that_language_missing() {
  local home packet out rc
  home=$(make_home prose-empty-tag)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  python3 - "$packet" <<'EMPTYTAG'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- hant: 15 秒的上限沒有對最慢的 repo 驗證過", "- hant:", 1))
EMPTYTAG
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a language tag with nothing after it: $out"
  assert_contains "$out" "written in en but not hant" \
    "an empty continuation line was not reported as the language missing: $out"
  pass "a language tag with nothing after it is that language missing"
}


# Every heading in that block is this renderer's own words, and it has all
# three - so the captain reads it in his language, as the prototype he approved
# does. Only what the worker typed stays as typed.
# verify and the renderer have to agree on what ONE item is, or verify passes a
# packet the renderer then reads as a copy object with no English - which is a
# blank line on the page and a board payload the validator refuses by name of
# nothing at all.
test_verify_refuses_a_group_the_renderer_would_read_differently() {
  local home packet out rc
  home=$(make_home prose-grouping)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  python3 - "$packet" <<'SPLIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- hant: 15 秒的上限沒有對最慢的 repo 驗證過",
                       "\n- hant: 15 秒的上限沒有對最慢的 repo 驗證過", 1))
SPLIT
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a continuation cut off from its en line: $out"
  assert_contains "$out" 'has no "en:" line above it' \
    "the refusal does not name the orphaned continuation: $out"

  # and a continuation written as a different kind of line is the same mistake
  fill_prose "$packet"
  python3 - "$packet" <<'MARKER'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- hans: 15 秒的上限没有对最慢的 repo 验证过",
                       "hans: 15 秒的上限没有对最慢的 repo 验证过", 1))
MARKER
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a continuation written unlike its en line: $out"
  pass "verify refuses a tagged group the renderer would read as a different item"
}

# The collapse that lets a line which IS a link read once has to be true in
# every language, or the words a worker wrote around the link in 繁體 and 简体
# vanish while the English reads correctly.
# The rule that says a line needs no translation and the rule that says how it
# renders have to read that line the same way: a backticked path is exempt
# BECAUSE it is command material, so it has to reach the captain looking like
# command material, on the card and on the page alike.
# A heading is copy this renderer owns in all three languages, and it owns the
# six the scaffold writes. A seventh would stand still in the language the
# worker typed while every line under it is required to switch - the
# half-switched block the whole rule exists to prevent.
# verify and the renderer have to agree on what a "## " line IS. The scaffold
# writes a fenced block itself, so a "## " comment inside one is reachable from
# the packet the tool generates - and a packet verify called clean has to be a
# packet the captain can be shown.
# Every string that reaches the card is either written in three languages or
# is purely command, path or identifier material. There is no third case - a
# heading under a section was one, and it stood still while its own lines moved.
test_no_line_the_captain_reads_is_exempt_from_the_three_languages() {
  local home packet out rc
  home=$(make_home prose-sub-heading)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  python3 - "$packet" <<'SUBHEAD'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- en: the bound is measured in forge(), not in the poller",
                       "### What the trial measured\n- en: the bound is measured in forge(), not in the poller", 1))
SUBHEAD
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a heading that would stand still on the card: $out"
  assert_contains "$out" "is a heading inside a packet section" \
    "the refusal does not name the sub-heading: $out"
  pass "no line the captain reads is exempt from the three languages"
}

# A link is one destination said in three languages. The card pairs the
# languages of a line by position and carries one url, so three lines naming
# different links would send the captain reading 繁體 to the English page.
# The same rule on the sibling path: a figure's heading and caption are read
# by the same pairing, so they owe the same parity. One rule, both call sites
# that build a copy object from parsed lines.
test_a_figure_says_the_same_links_in_every_language() {
  local home packet
  home=$(make_home fig-link-langs)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  assert_figure_refused "$home" "$packet" \
    "$(good_figures | sed \
      -e 's|^caption: .*|caption: read the [design doc](https://ex.test/en/design)|' \
      -e 's|^caption.hant: .*|caption.hant: 讀[設計文件](https://ex.test/zh/design)|' \
      -e 's|^caption.hans: .*|caption.hans: 读[设计文件](https://ex.test/zh/design)|')" \
    "names different links from the caption" \
    "a caption whose languages point at different pages"
  # and the same words with the same destination is accepted
  fill_figures "$packet" "$(good_figures | sed \
      -e 's|^caption: .*|caption: read the [design doc](https://ex.test/design)|' \
      -e 's|^caption.hant: .*|caption.hant: 讀[設計文件](https://ex.test/design)|' \
      -e 's|^caption.hans: .*|caption.hans: 读[设计文件](https://ex.test/design)|')"
  run_packet "$home" verify pk-1 >/dev/null \
    || fail "verify refused a caption whose languages name the same link"
  pass "a figure says the same links in every language"
}

test_the_three_languages_of_a_line_name_the_same_links() {
  local home packet out rc
  home=$(make_home prose-link-langs)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  python3 - "$packet" <<'SAMELINK'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("- en: the bound is measured in forge(), not in the poller",
              "- en: read the [design doc](https://ex.test/design)")
s = s.replace("- hant: 上限是在 forge() 裡量的，不是在 poller",
              "- hant: 讀[設計文件](https://ex.test/design)")
s = s.replace("- hans: 上限是在 forge() 里量的，不是在 poller",
              "- hans: 读[设计文件](https://ex.test/design)")
p.write_text(s)
SAMELINK
  run_packet "$home" verify pk-1 >/dev/null \
    || fail "verify refused three languages that name the same link"

  python3 - "$packet" <<'OTHERLINK'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- hant: 讀[設計文件](https://ex.test/design)",
                       "- hant: 讀[設計文件](https://ex.test/zh/design)", 1))
OTHERLINK
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted three languages pointing at different places: $out"
  assert_contains "$out" "names different links from its" \
    "the refusal does not name the disagreement: $out"
  pass "the three languages of a line name the same links"
}

test_a_heading_inside_a_fence_is_a_line_of_code_to_both_readers() {
  local home packet out
  home=$(make_home prose-fenced-heading)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  python3 - "$packet" <<'FENCE'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("```sh\n", "```sh\n## the two commands worth running first\n", 1))
FENCE
  run_packet "$home" verify pk-1 >/dev/null || fail "verify refused a comment inside its own fenced block"
  out=$(run_packet "$home" card pk-1) || fail "a packet verify called clean could not be carded: $out"
  printf '%s' "$out" | jq -e '
    ([.packet.sections[].heading.en] | index("How to pull more")) != null
    # the comment is a line of that section, not a section of its own
    and ([.packet.sections[].heading.en] | index("the two commands worth running first")) == null
    and ([.packet.sections[] | select(.heading.en == "How to pull more") | .items[].text]
         | index("## the two commands worth running first")) != null
  ' >/dev/null || fail "a fenced heading was read as a section: $out"
  run_packet "$home" render pk-1 >/dev/null || fail "render refused what verify accepted"

  # Every reader of this packet decomposes it the same way, the figures scan
  # included: a "## Figures" line inside a fence is code, not a second section.
  python3 - "$packet" <<'FENCEDSECTION'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("```sh\n", "```sh\n## Figures\n## Evidence\n", 1))
FENCEDSECTION
  run_packet "$home" verify pk-1 >/dev/null \
    || fail "a section name inside a fenced block was read as a section"
  out=$(run_packet "$home" card pk-1) || fail "card could not read the same packet: $out"
  printf '%s' "$out" | jq -e '(.packet.figures | length) == 1' >/dev/null \
    || fail "the figures scan read a fenced line as a second Figures section: $out"

  # and the two read the heading itself the same way, trailing space included
  python3 - "$packet" <<'PAD'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("## Evidence\n", "## Evidence \n", 1))
PAD
  run_packet "$home" verify pk-1 >/dev/null \
    || fail "verify refused a heading over a difference the reader cannot see"
  run_packet "$home" card pk-1 >/dev/null || fail "card could not read a padded heading"
  pass "a heading inside a fence is a line of code to verify and to both renderers"
}

test_a_section_the_scaffold_never_wrote_is_refused() {
  local home packet out rc
  home=$(make_home prose-unknown-section)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  run_packet "$home" verify pk-1 >/dev/null || fail "verify refused a scaffolded packet"
  python3 - "$packet" <<'INVENT'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("## Evidence", "## Open questions\n\n- en: does the bound hold on Linux\n- hant: 上限在 Linux 上成立嗎\n- hans: 上限在 Linux 上成立吗\n\n## Evidence", 1))
INVENT
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a section this renderer has no heading for: $out"
  assert_contains "$out" '"## Open questions" section' \
    "the refusal does not name the section it refused: $out"
  pass "a section the scaffold never wrote is refused, rather than half-switched"
}

test_a_backticked_line_is_code_on_both_surfaces() {
  local home packet out page
  home=$(make_home card-code-line)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    (.packet.sections[] | select(.heading.en == "Evidence") | .items) as $ev
    # the path the scaffold asks a worker to write in backticks rides the card
    # as code, like a line out of a fenced block
    | ([$ev[] | select(.code == true) | .text] | index("bin/fm-contributions.sh:190")) != null
    # and the prose beside it is not code
    and ([$ev[] | select(.text | type == "object") | .code] | unique) == [null]
  ' >/dev/null || fail "a backticked path did not ride the card as code: $out"
  run_packet "$home" render pk-1 >/dev/null || fail "render failed"
  assert_grep '<code>bin/fm-contributions.sh:190</code>' "$page" \
    "the page did not render a backticked path as code"
  pass "a line that is one backticked span reaches the captain as code on both surfaces"
}

test_a_line_that_is_a_link_only_collapses_when_every_language_is() {
  local home packet out
  home=$(make_home card-link-collapse)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  python3 - "$packet" <<'COLLAPSE'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("- en: the 15 s bound is unverified against the slowest repo",
              "- en: [the CI run](https://ci.example.test/run/7)")
s = s.replace("- hant: 15 秒的上限沒有對最慢的 repo 驗證過",
              "- hant: 詳見 [CI 執行](https://ci.example.test/run/7)")
s = s.replace("- hans: 15 秒的上限没有对最慢的 repo 验证过",
              "- hans: 详见 [CI 执行](https://ci.example.test/run/7)")
s = s.replace("- en: the merged-record rule assumes settle_final runs before publish",
              "- en: [the PR](https://example.test/pr/10)")
s = s.replace("- hant: 合併記錄規則假設 settle_final 在 publish 之前跑",
              "- hant: [那個 PR](https://example.test/pr/10)")
s = s.replace("- hans: 合并记录规则假设 settle_final 在 publish 之前跑",
              "- hans: [那个 PR](https://example.test/pr/10)")
p.write_text(s)
COLLAPSE
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    (.packet.sections[] | select(.heading.en == "What only this session knows") | .items) as $said
    # the line that says more than its link in 繁體 keeps every language of it
    | ($said[1].text.hant | test("詳見"))
    and ($said[1].text.hans | test("详见"))
    and ([$said[1].links[].url] == ["https://ci.example.test/run/7"])
    # the line that IS the link in all three still reads once
    and ($said[2] | has("text") | not)
    and ($said[2].links[0].label.hant == "那個 PR")
  ' >/dev/null || fail "a trilingual link line lost the words around it: $out"
  pass "a line collapses to its link only when it is the link in every language"
}

test_the_packet_block_switches_every_heading_it_owns() {
  local home out packet
  home=$(make_home card-packet-headings)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    ([.packet.sections[].heading | type] | unique == ["object"])
    and ([.packet.sections[].heading | keys_unsorted | sort] | unique == [["en", "hans", "hant"]])
    and ([.packet.sections[].heading | select(.hant == .en)] | length) == 0
  ' >/dev/null || fail "a heading in the as-written block did not carry all three: $out"
  pass "every heading the card owns rides it in all three languages"
}

# The clause-by-clause refusals live in the verify test above; what matters here
# is that card is on the far side of them. A drawing that could run code on the
# captain's board must not merely be dropped from the card - the packet carrying
# it must not produce a card at all, because a dropped drawing is a silent
# result and a refusal is not.
# The figure contract names the option a drawing illustrates, rather than the
# board inferring it from the identities the drawing happens to carry. The
# inference was this branch's own invention and it was wrong for exactly the
# drawings the approved prototype uses, whose shapes are named a0-fn and a1-fn,
# not after the options at all.
# The captain reads one page in his own language, end to end. Everything the
# card carries - the decision copy, the drawings, the headings of the collapsed
# block AND the worker's own lines inside it - is written in all three, so no
# part of that page stands still while the rest of it moves.
test_the_packet_block_reaches_the_card_in_all_three_languages() {
  local home out packet
  home=$(make_home card-packet-trilingual)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    (.packet.sections[] | select(.heading.en == "What only this session knows") | .items) as $said
    | ([$said[].text | type] | unique == ["object"])
    and ([$said[].text | keys_unsorted | sort] | unique == [["en", "hans", "hant"]])
    and ($said[0].text.hant | test("先試過重試迴圈"))
    and ($said[0].text.hans | test("先试过重试循环"))
  ' >/dev/null || fail "the worker prose did not reach the card in three languages: $out"
  # and so do the words a figure says, which sit in that same block
  printf '%s' "$out" | jq -e '
    (.packet.sections[] | select(.heading.en == "Figures") | .items) as $fig
    | ([$fig[].text | type] | unique == ["object"])
    and ($fig[0].text.hant == "兩個選項差在哪")
    and ($fig[1].text.hans | test("两个选项最后都到同一处"))
  ' >/dev/null || fail "a figure heading or caption did not reach the card in three languages: $out"
  pass "the packet block reaches the card in all three languages, prose and figure words alike"
}

# The worker writes the three languages, so verify is what makes them write
# them: the section that is nothing but the worker explaining something owes
# all three, and a line written by halves is refused wherever it is.
test_verify_refuses_prose_the_captain_could_not_read() {
  local home packet out rc
  home=$(make_home prose-langs)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  run_packet "$home" verify pk-1 >/dev/null || fail "verify refused a trilingual packet"

  python3 - "$packet" <<'ONELANG'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- en: the 15 s bound is unverified against the slowest repo",
                       "- the 15 s bound is unverified against the slowest repo", 1)
              .replace("- hant: 15 秒的上限沒有對最慢的 repo 驗證過\n", "", 1)
              .replace("- hans: 15 秒的上限没有对最慢的 repo 验证过\n", "", 1))
ONELANG
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a session line the captain could only read in one language"
  assert_contains "$out" "is written in one language" "the refusal does not name the one-language line: $out"

  fill_prose "$packet"
  python3 - "$packet" <<'HALF'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("- hans: 先试过重试循环，后来放弃，因为坏的是上限不是 forge\n", "", 1))
HALF
  set +e; out=$(run_packet "$home" verify pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "verify accepted a line written in en and hant but not hans"
  assert_contains "$out" "written in en but not hans" "the refusal does not name the missing language: $out"
  pass "verify refuses prose the captain could not read in his own language"
}

test_a_figure_says_its_words_in_all_three_languages() {
  local home packet
  home=$(make_home fig-langs)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  assert_figure_refused "$home" "$packet" \
    "$(good_figures | grep -v '^caption.hans:')" \
    "the caption is written in en but not hans" \
    "a figure whose caption stops short of the captain's third language"
  assert_figure_refused "$home" "$packet" \
    "$(good_figures | grep -v '^heading.hant:')" \
    "the heading is written in en but not hant" \
    "a figure whose heading stops short of the captain's second language"
  pass "a figure says its heading and its caption in all three languages"
}

test_a_figure_names_the_option_it_illustrates() {
  local home out packet
  home=$(make_home fig-option)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  set_figures_from_stdin "$packet" <<'MD'
### Where the two options differ
heading.hant: 兩個選項差在哪
heading.hans: 两个选项差在哪

figure: cmp
caption: Both options end at the same place; only the left column differs.
caption.hant: 兩個選項最後都到同一處，只有左邊那欄不同。
caption.hans: 两个选项最后都到同一处，只有左边那栏不同。

<svg viewBox="0 0 20 20"><rect data-node="bound" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><rect data-node="quiet" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="both" data-hant="兩個" data-hans="两个">both</text></svg>

### What raising the bound changes
heading.hant: 拉高上限會改什麼
heading.hans: 拉高上限会改什么

figure: raise
option: bound
caption: the wait grows and the failures stop.
caption.hant: 等待變長，失敗停止。
caption.hans: 等待变长，失败停止。

<svg viewBox="0 0 20 20"><rect data-node="a0-fn" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="before" data-hant="之前" data-hans="之前">before</text></svg>
MD
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    ((.packet.figures | length) == 2)
    # the comparison names no option of its own
    and (.packet.figures[0] | .slug == "cmp" and (.option == "" or (has("option") | not)))
    # the option drawing says which option it is for, and is believed even
    # though not one of the identities it draws is an option value
    and (.packet.figures[1] | .slug == "raise" and .option == "bound"
         and (.nodes == ["a0-fn"]))
  ' >/dev/null || fail "a figure did not carry the option it illustrates: $out"
  pass "a figure names the option it illustrates, whatever its shapes are called"
}

# Which figure is which is its POSITION in the section, never its heading text:
# nothing makes a heading unique, so two figures that share one must still be
# told apart - or the comparison rule filters out the drawing that does compare
# and refuses a packet that carries one, naming a cause that is not the cause.
test_two_figures_may_share_a_heading() {
  local home out packet
  home=$(make_home fig-same-heading)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  set_figures_from_stdin "$packet" <<'MD'
### What changes
heading.hant: 改了什麼
heading.hans: 改了什么

figure: cmp
caption: Both options end at the same place; only the left column differs.
caption.hant: 兩個選項最後都到同一處，只有左邊那欄不同。
caption.hans: 两个选项最后都到同一处，只有左边那栏不同。

<svg viewBox="0 0 20 20"><rect data-node="bound" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><rect data-node="quiet" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="both" data-hant="兩個" data-hans="两个">both</text></svg>

### What changes
heading.hant: 改了什麼
heading.hans: 改了什么

figure: raise
option: bound
caption: the wait grows and the failures stop.
caption.hant: 等待變長，失敗停止。
caption.hans: 等待变长，失败停止。

<svg viewBox="0 0 20 20"><rect data-node="a0-fn" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="before" data-hant="之前" data-hans="之前">before</text></svg>
MD
  out=$(run_packet "$home" verify pk-1 2>&1) \
    || fail "a packet whose comparison shares a heading with an option drawing was refused: $out"
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    ([.packet.figures[] | .slug] == ["cmp", "raise"])
    and (.packet.figures[0].option == "")
    and (.packet.figures[1].option == "bound")
  ' >/dev/null || fail "two figures sharing a heading did not both reach the card: $out"
  pass "two figures may share a heading; the comparison is still found"
}

test_a_figure_cannot_name_an_option_the_decision_never_offers() {
  local home packet
  home=$(make_home fig-option-bad)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  assert_figure_refused "$home" "$packet" \
    "$(good_figures | sed 's/^figure: opt$/figure: opt\noption: nonesuch/')" \
    "not one of the decision's options" \
    "a drawing that illustrates a choice the reader is never offered"

  # and a packet whose every drawing claims an option still owes a comparison
  assert_figure_refused "$home" "$packet" \
    "$(good_figures | sed 's/^figure: opt$/figure: opt\noption: bound/')" \
    "none of them compares" \
    "a packet whose only drawing illustrates one side of the choice"
  pass "a figure's option must name a real option, and one drawing per option is still not a comparison"
}

test_a_drawing_that_could_run_code_never_produces_a_card() {
  local home out rc packet
  home=$(make_home card-packet-unsafe)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  set_figures_from_stdin "$packet" <<'MD'
### A drawing that runs code when the reader clicks it
heading.hant: 讀者一點就會執行程式的圖
heading.hans: 读者一点就会执行程序的图

figure: hostile
caption: an inline link runs its href on the board that inlined it.
caption.hant: 內嵌連結會在把它畫進來的看板上執行 href。
caption.hans: 内嵌链接会在把它画进来的看板上执行 href。

<svg viewBox="0 0 20 20"><a xlink:href="javascript:alert(1)"><rect data-node="bound" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/></a><rect data-node="quiet" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="run" data-hant="跑" data-hans="跑">run</text></svg>
MD
  set +e; out=$(run_packet "$home" card pk-1 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "card was built from a drawing that can run code: $out"
  printf '%s' "$out" | grep -q "javascript:alert(1)" \
    || fail "the refusal does not name the href it refused: $out"
  # and nothing was printed for the board to consume
  printf '%s' "$out" | grep -q '"figures"' \
    && fail "the refusal still emitted a card payload: $out"
  pass "a drawing that could run code on the board is refused rather than quietly dropped"
}

test_a_figures_section_parses_the_same_without_a_blank_line_after_it() {
  local home out packet
  home=$(make_home card-packet-tight)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  # verify reads this section per line, so a figure that opens on the line
  # straight after the section heading is a packet verify accepts - and the
  # card has to read it the same way rather than losing the first drawing.
  set_figures_tight_from_stdin "$packet" <<'MD'
### Where the options part
heading.hant: 選項在哪裡分岔
heading.hans: 选项在哪里分岔
figure: cmp
caption: Both reach the gate; only one writes onto the data stream.
caption.hant: 兩邊都會到 gate，只有一邊寫到資料輸出。
caption.hans: 两边都会到 gate，只有一边写到数据输出。
<svg viewBox="0 0 20 20"><rect data-node="bound" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><rect data-node="quiet" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="one path" data-hant="一條路" data-hans="一条路">one path</text></svg>
MD
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    ([.packet.figures[] | .slug] == ["cmp"])
    and (.packet.figures[0].nodes == ["bound", "quiet"])
    # and the drawing left the block rather than being dumped into it as text
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("<svg")) | not)
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("figure: cmp")) | not)
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("Where the options part")))
    and ([.packet.sections[].items[].text | if type == "object" then .en else . end] | any(test("only one writes")))
  ' >/dev/null || fail "a Figures section with no blank line after it did not parse: $out"
  pass "a figure opening on the line after the section heading parses like any other"
}

# The identities the card ships are what decides which drawing leads the
# Difference tab, so verify and the card have to agree about what the markup
# says. An unquoted value is an identity to a browser; it was invisible to the
# second reader the card used to have.
test_the_card_reads_identities_the_way_verify_does() {
  local home out packet
  home=$(make_home card-identities)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  set_figures_from_stdin "$packet" <<'MD'
### Where the options part
heading.hant: 選項在哪裡分岔
heading.hans: 选项在哪里分岔
figure: cmp
caption: Both reach the gate; only one writes onto the data stream.
caption.hant: 兩邊都會到 gate，只有一邊寫到資料輸出。
caption.hans: 两边都会到 gate，只有一边写到数据输出。

<svg viewBox="0 0 20 20"><rect data-node=bound x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><rect data-node="quiet" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="both here: data-node=&quot;loud&quot;" data-hant="兩個" data-hans="两个">both</text></svg>
MD
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    # the unquoted identity is one a browser reads, so the card ships it
    (.packet.figures[0].nodes == ["bound", "quiet"])
  ' >/dev/null || fail "the card read the drawing differently from verify: $out"
  pass "the card reads a drawing's identities the way verify does"
}

test_a_drawing_that_nests_an_icon_is_read_whole() {
  local home out packet
  home=$(make_home card-packet-nested)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  # diagram-design nests icon <svg> elements inside a drawing, and verify counts
  # depth to decide which bytes are the drawing. Stopping at the first </svg>
  # would hand the board half a figure and a node set short of one option, so
  # the comparison drawing would no longer name every option.
  set_figures_from_stdin "$packet" <<'MD'
### Where the options part
heading.hant: 選項在哪裡分岔
heading.hans: 选项在哪里分岔

figure: cmp
caption: Both reach the gate; only one writes onto the data stream.
caption.hant: 兩邊都會到 gate，只有一邊寫到資料輸出。
caption.hans: 两边都会到 gate，只有一边写到数据输出。

<svg viewBox="0 0 40 20"><rect data-node="bound" x="1" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><svg x="12" y="1" width="6" height="6"><path d="M0 0 L6 6" stroke="var(--muted)"/></svg><rect data-node="quiet" x="20" y="1" width="9" height="9" fill="var(--card)" stroke="var(--rule)"/><text data-en="one path" data-hant="一條路" data-hans="一条路">one path</text></svg>
MD
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    (.packet.figures | length) == 1
    # every identity the drawing names, including the ones drawn after the icon
    and (.packet.figures[0].nodes == ["bound", "quiet"])
    # and the drawing arrives closed, not cut off at the icon
    and (.packet.figures[0].svg | endswith("</svg>"))
    and (.packet.figures[0].svg | test("one path"))
  ' >/dev/null || fail "a drawing with a nested icon was cut short: $out"
  pass "a drawing that nests an icon svg is read whole, with every identity it names"
}

# The page and the card read ONE decision block, so they may not show different
# halves of it: what an option changes, touches and buys is on both or neither.
test_the_page_shows_what_an_option_changes_touches_and_buys() {
  local home packet page rich
  home=$(make_home page-option-detail)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"
  rich=$(printf '%s' "$GOOD_DECISION" | jq -c '
    .options[0] += {
      buys: {en: "One behaviour to reason about.", hant: "只剩一種行為要想。"},
      files: ["bin/fm-contributions.sh"],
      changes: {added: [{en: "a merged-record rule", hant: "一條合併記錄規則"}],
                removed: [{en: "the stdout probe", hant: "stdout 判斷"}],
                unchanged: [{en: "the answer channel", hant: "answer 通道"}]}}')
  fill_decision "$packet" "$rich"
  fill_figures "$packet"
  run_packet "$home" render pk-1 >/dev/null || fail "render failed"
  assert_grep 'a merged-record rule' "$page" "the page dropped what the option adds"
  assert_grep 'the stdout probe' "$page" "the page dropped what the option removes"
  assert_grep 'the answer channel' "$page" "the page dropped what the option leaves alone"
  assert_grep 'bin/fm-contributions.sh' "$page" "the page dropped the files the option touches"
  assert_grep 'One behaviour to reason about.' "$page" "the page dropped what the option buys"
  # and each of them switches with the rest of the page
  assert_grep 'data-hant="一條合併記錄規則"' "$page" "what the option adds does not switch"
  assert_grep 'data-hant="只剩一種行為要想。"' "$page" "what the option buys does not switch"
  pass "the page shows what an option changes, touches and buys, in every language"
}

# The board accepts one shape of link, and a packet that names any other must
# not take the whole board build down with it: the words stay, the link does
# not, which is what an unsafe scheme already gets.
test_a_link_the_board_would_refuse_rides_the_card_as_text() {
  local home packet out
  home=$(make_home card-links)
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  python3 - "$packet" <<'LINKS'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("- en: the bound is measured in forge(), not in the poller",
  "- en: see [the brief](data/pk-1/brief.md) and [the run](https://ci.example.test/run/7)")
s = s.replace("- hant: 上限是在 forge() 裡量的，不是在 poller",
  "- hant: 看 [簡報](data/pk-1/brief.md) 和 [那一輪](https://ci.example.test/run/7)")
s = s.replace("- hans: 上限是在 forge() 里量的，不是在 poller",
  "- hans: 看 [简报](data/pk-1/brief.md) 和 [那一轮](https://ci.example.test/run/7)")
p.write_text(s)
LINKS
  out=$(run_packet "$home" card pk-1) || fail "card failed: $out"
  printf '%s' "$out" | jq -e '
    (.packet.sections[] | select(.heading.en == "Evidence") | .items[0]) as $it
    | ($it.text.en | test("the brief")) and ($it.text.hant | test("簡報"))
    and ([$it.links[].url] == ["https://ci.example.test/run/7"])
    and ($it.links[0].label | .en == "the run" and .hant == "那一輪" and .hans == "那一轮")
  ' >/dev/null || fail "the card did not keep the words and drop the unreachable link: $out"
  pass "a link the board would refuse rides the card as text, and the reachable one as a link"
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
s = s.replace("- en: the 15 s bound is unverified against the slowest repo",
  "- en: the bound is unverified; see [the CI run](https://ci.example.test/run/7)")
s = s.replace("- hant: 15 秒的上限沒有對最慢的 repo 驗證過",
  "- hant: 上限沒有驗證過，看 [CI 那一輪](https://ci.example.test/run/7)")
s = s.replace("- hans: 15 秒的上限没有对最慢的 repo 验证过",
  "- hans: 上限没有验证过，看 [CI 那一轮](https://ci.example.test/run/7)")
# The generated section renders as written - it is git output, not the
# worker's words - so it is where the markdown converter is exercised.
s = s.replace("- uncommitted paths in the worktree at scaffold time:",
  "- the **15 s** bound is `unverified` against [the slowest repo](https://example.test/slow); see <b>escaped</b>\n"
  "- the RAW_JS and TASK_ID slots are named here on purpose\n"
  "- [a data link](data:text/html,x) and [a vb link](VBScript:x) stay text\n"
  "- uncommitted paths in the worktree at scaffold time:", 1)
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
  # A line the worker wrote in three languages rides the page as one switchable
  # string, so the captain reads the session's own words in his language too.
  assert_grep 'tried a retry loop first' "$page" "the session list did not convert"
  assert_grep 'data-hant="先試過重試迴圈' "$page" "a trilingual prose line lost its 繁體"
  assert_grep 'data-hans="先试过重试循环' "$page" "a trilingual prose line lost its 简体"
  # and the links inside such a line stay links, the way the board card has
  # them, so the page and the card do not disagree about what the packet says
  assert_grep 'class="pk-said__link" href="https://ci.example.test/run/7"' "$page" \
    "a trilingual prose line lost the link it named"
  assert_grep 'data-hant="CI 那一輪"' "$page" "the link label does not switch with the page"
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

test_serve_opens_the_page_under_a_stable_name_and_the_card_stays_one_address() {
  local home out packet page real
  home=$(make_home serve)
  make_lavish_stub "$home" names
  run_packet "$home" scaffold pk-1 --kind needs-decision >/dev/null || fail "scaffold failed"
  packet="$home/data/pk-1/packet.md"
  page="$home/data/pk-1/packet.html"
  fill_prose "$packet"
  fill_decision "$packet" "$GOOD_DECISION"
  fill_figures "$packet"
  out=$(run_packet_lavish "$home" serve pk-1) || fail "serve failed: $out"
  assert_present "$page" "serve did not render the page"
  assert_contains "$out" "page: $page" "serve did not report the page: $out"
  assert_contains "$out" "url: http://127.0.0.1:4387/s/packet-pk-1" "serve did not print the named URL: $out"
  assert_grep '--name packet-pk-1' "$home/lavish-state/args" "serve did not open the page under its stable name"
  real=$(cd "$(dirname "$page")" && pwd -P)/packet.html
  assert_equals "$(cat "$home/lavish-state/open")" "$real" "serve opened a different file"
  # The card carries the whole packet, so there is no second address to send the
  # captain to and the card never offers one - served page or not.
  out=$(run_packet_lavish "$home" card pk-1) || fail "card failed after serve: $out"
  printf '%s' "$out" | jq -e '(has("packet_url") | not) and ((.packet.sections | length) > 0)' >/dev/null \
    || fail "card sent the captain to a second address: $out"
  # and composing a card never rewrites the served page behind the reader
  assert_equals "$(cat "$home/lavish-state/open")" "$real" "card opened or re-served a page of its own"
  # An older lavish-axi without --name gets the plain open and the keyed URL.
  home=$(make_home serve-keyed)
  run_packet "$home" scaffold pk-1 >/dev/null || fail "scaffold failed"
  fill_prose "$home/data/pk-1/packet.md"
  out=$(run_packet_lavish "$home" serve pk-1) || fail "serve failed without name support: $out"
  assert_contains "$out" "url: http://127.0.0.1:4387/session/deadbeef" "serve did not print the keyed URL: $out"
  assert_no_grep '--name' "$home/lavish-state/args" "serve passed --name to a lavish-axi that lacks it"
  pass "serve opens the page under a stable name, and a card still sends nobody to it"
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
test_a_drawing_that_nests_icon_svgs_is_one_figure_checked_end_to_end
test_card_emits_a_board_ready_decision_item
test_the_page_shows_what_an_option_changes_touches_and_buys
test_a_link_the_board_would_refuse_rides_the_card_as_text
test_path_and_bad_ids_are_refused
test_render_writes_a_self_contained_page_for_a_done_packet
test_render_decision_card_answers_the_five_questions
test_serve_opens_the_page_under_a_stable_name_and_the_card_stays_one_address
test_name_support_probe_never_lists_before_the_session_is_opened
test_the_card_carries_the_packet_itself
test_a_needs_decision_packet_with_no_figures_is_refused
test_an_empty_language_line_is_that_language_missing
test_verify_refuses_a_group_the_renderer_would_read_differently
test_a_line_that_is_a_link_only_collapses_when_every_language_is
test_a_backticked_line_is_code_on_both_surfaces
test_a_section_the_scaffold_never_wrote_is_refused
test_no_line_the_captain_reads_is_exempt_from_the_three_languages
test_the_three_languages_of_a_line_name_the_same_links
test_a_figure_says_the_same_links_in_every_language
test_a_heading_inside_a_fence_is_a_line_of_code_to_both_readers
test_the_packet_block_switches_every_heading_it_owns
test_the_packet_block_reaches_the_card_in_all_three_languages
test_verify_refuses_prose_the_captain_could_not_read
test_a_figure_says_its_words_in_all_three_languages
test_a_figure_names_the_option_it_illustrates
test_two_figures_may_share_a_heading
test_a_figure_cannot_name_an_option_the_decision_never_offers
test_a_drawing_that_could_run_code_never_produces_a_card
test_a_figures_section_parses_the_same_without_a_blank_line_after_it
test_the_card_reads_identities_the_way_verify_does
test_a_drawing_that_nests_an_icon_is_read_whole
