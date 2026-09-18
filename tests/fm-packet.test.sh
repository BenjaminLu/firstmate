#!/usr/bin/env bash
# Behavior tests for bin/fm-packet.sh: the scaffold is generated from the
# task's worktree, verify refuses a skeleton and accepts a filled packet, the
# decision block is validated field by field, and card emits a board-ready
# Captain's Call item.
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
  printf '%s\n' "$home"
}

run_packet() {  # <home> <args...>
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$TMP_ROOT/nogh:$PATH" "$PACKET" "$@"
}
mkdir -p "$TMP_ROOT/nogh"  # no gh on PATH so the PR facts stay offline and deterministic

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

test_scaffold_is_generated_from_the_worktree_and_refuses_to_overwrite
test_verify_refuses_a_skeleton_and_accepts_a_filled_packet
test_verify_checks_the_decision_block_field_by_field
test_card_emits_a_board_ready_decision_item
test_path_and_bad_ids_are_refused
