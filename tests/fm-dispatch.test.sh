#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch.sh, the one-call intake: file the backlog
# item, scaffold and fill the brief, resolve the profile, spawn.
#
# These tests mirror tests/fm-spawn*.test.sh's fake-harness pattern: a fake
# tmux captures the launch command, treehouse is a no-op, and the pane path
# points at a real isolated git worktree, so the whole call runs end to end
# without starting any harness. The backlog is a real markdown file driven by
# the real tasks-axi CLI, exactly as bin/fm-spawn.sh's transition gate sees it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DISPATCH="$ROOT/bin/fm-dispatch.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; fm-dispatch files its item through it)\n'
  exit 0
}

# An exported TASKS_AXI_BACKEND would outrank each case's .tasks.toml fixture.
unset TASKS_AXI_BACKEND || :
# The resolver must stay off: a developer key in the environment would turn the
# profile step into a network call.
unset TYPESAFE_API_KEY || :

# make_case <name>: a home with a real backlog, a project clone with an origin,
# a pooled worktree, and the spawn fakebin. Echoes the case dir.
make_case() {
  local name=$1 case_dir home
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fm_test_make_spawn_fakebin "$case_dir" gh gh-axi no-mistakes >/dev/null
  fm_test_spawn_home "$home" claude
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b "pooled-$name" "$case_dir/wt"
  printf 'add a summary toggle to the report view\nkeep the existing layout\n' > "$case_dir/ask.md"
  printf 'Implement the toggle in the report renderer; out of scope: the settings page.\n' > "$case_dir/spec.md"
  printf '%s\n' "$case_dir"
}

# run_dispatch <case-dir> [fm-dispatch args...]
run_dispatch() {
  local case_dir=$1 home fakebin launchlog
  shift
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  mkdir -p "$home/user-home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="${TMUX:-fake,1,0}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    PATH="$fakebin:$PATH" \
    "$DISPATCH" "$@" 2>&1
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

row_count() {  # <case-dir> <id>
  grep -c -- "$2" "$1/home/data/backlog.md"
}

test_full_call_files_briefs_and_spawns() {
  local case_dir id out status brief
  id=dispatch-full-a1
  case_dir=$(make_case full)
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "full dispatch should succeed: $out"
  assert_contains "$out" "backlog: added $id (queued, kind=ship)" "item was not filed"
  assert_contains "$out" "brief: filled $case_dir/home/data/$id/brief.md" "brief was not filled"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "spawn line missing"
  assert_contains "$out" "mode=no-mistakes yolo=off" "spawn line lacks the delivery contract"
  printf '%s\n' "$out" | grep -q '^elapsed: [0-9][0-9]*\.[0-9][0-9][0-9]$' || fail "elapsed line missing: $out"

  brief="$case_dir/home/data/$id/brief.md"
  assert_grep 'add a summary toggle to the report view' "$brief" "ask bytes not in the brief"
  assert_grep 'keep the existing layout' "$brief" "second ask line not in the brief"
  assert_grep 'Implement the toggle in the report renderer; out of scope: the settings page.' "$brief" "spec bytes not in the brief"
  assert_no_grep '{TASK}' "$brief" "TASK placeholder survived"
  assert_no_grep '{FIRSTMATE_SPEC}' "$brief" "FIRSTMATE_SPEC placeholder survived"
  assert_grep 'Delivery contract: mode=no-mistakes' "$brief" "brief lacks the recorded mode"
  # The ask is the item's title when --title is absent.
  assert_grep 'add a summary toggle to the report view' "$case_dir/home/data/backlog.md" "title not taken from the ask"
  assert_equals "in_flight" "$(row_state "$case_dir" "$id")" "spawn did not move the item to In flight"
  assert_grep "kind=ship" "$case_dir/home/state/$id.meta" "meta missing kind=ship"
  [ -s "$case_dir/launch.log" ] || fail "no launch command was sent to the fake pane"
  pass "a full call files the item, fills the brief, spawns, and reports elapsed"
}

test_second_call_reuses_item_and_brief() {
  local case_dir id out status brief before after
  id=dispatch-reuse-b2
  case_dir=$(make_case reuse)
  # First call: everything up to the spawn lands, then the spawn refuses the
  # unknown backend with its own message. Nothing is unwound.
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo on --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --backend nope-backend)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn on an unknown backend should refuse: $out"
  assert_contains "$out" "backlog: added $id" "first call did not file the item"
  assert_contains "$out" "brief: filled" "first call did not fill the brief"
  assert_contains "$out" "nope-backend" "spawn refusal message was not passed through: $out"
  assert_not_contains "$out" "elapsed:" "a refused call must not report elapsed"
  assert_equals "queued" "$(row_state "$case_dir" "$id")" "refused spawn left the item off Queued"
  brief="$case_dir/home/data/$id/brief.md"
  before=$(cat "$brief")

  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo on --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "second call should reuse and spawn: $out"
  assert_contains "$out" "backlog: reused $id (queued)" "second call did not reuse the item"
  assert_contains "$out" "brief: reused $brief" "second call did not reuse the brief"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=direct-PR yolo=on" "second call did not spawn"
  after=$(cat "$brief")
  assert_equals "$before" "$after" "a reused brief must not be rewritten"
  assert_equals "1" "$(row_count "$case_dir" "$id")" "the item was filed twice"
  assert_equals "in_flight" "$(row_state "$case_dir" "$id")" "second call did not move the item to In flight"
  pass "a second call reuses the queued item and the filled brief"
}

test_empty_ask_refuses_before_any_record() {
  local case_dir id out status
  id=dispatch-empty-c3
  case_dir=$(make_case empty)
  printf '  \n\n' > "$case_dir/empty.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/empty.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "an empty ask should refuse: $out"
  assert_contains "$out" "$case_dir/empty.md is empty" "refusal did not name the empty ask"
  assert_absent "$case_dir/home/data/$id" "an empty ask must not create the brief directory"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "an empty ask must not file an item"
  pass "an empty ask refuses before filing or scaffolding anything"
}

test_captain_labelled_ask_refuses() {
  local case_dir id out status
  id=dispatch-label-d4
  case_dir=$(make_case label)
  printf "Captain's words: add a summary toggle\n" > "$case_dir/labelled.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/labelled.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a Captain-labelled ask should refuse: $out"
  assert_contains "$out" "operator-address line: Captain's words: add a summary toggle" "refusal did not quote the address line"
  assert_absent "$case_dir/home/data/$id" "a labelled ask must not create the brief directory"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a labelled ask must not file an item"
  pass "a Captain-labelled ask refuses exactly as the spawn would"
}

test_mode_mismatch_with_existing_brief_refuses() {
  local case_dir id out status brief before after
  id=dispatch-mismatch-e5
  case_dir=$(make_case mismatch)
  # Scaffold a local-only brief the way intake would, then dispatch it as
  # no-mistakes: the recorded contract wins and nothing is filed.
  FM_HOME="$case_dir/home" FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-brief.sh" "$id" project --mode local-only >/dev/null || fail "could not scaffold the existing brief"
  brief="$case_dir/home/data/$id/brief.md"
  before=$(cat "$brief")
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a mode mismatch should refuse: $out"
  assert_contains "$out" "records Delivery contract: mode=local-only but this dispatch passes --mode no-mistakes" "refusal did not name both modes"
  after=$(cat "$brief")
  assert_equals "$before" "$after" "a mismatched brief must not be touched"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a mismatch must not file an item"

  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a scout dispatch over a ship brief should refuse: $out"
  assert_contains "$out" "is a ship brief (Delivery contract: mode=local-only) but this dispatch is --scout" "scout-over-ship refusal missing"
  pass "a mode mismatch with an existing brief refuses without touching it"
}

test_scout_call_files_and_spawns_a_scout() {
  local case_dir id out status brief
  id=dispatch-scout-f6
  case_dir=$(make_case scout)
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --title "why is the toggle slow")
  status=$?
  expect_code 0 "$status" "scout dispatch should succeed: $out"
  assert_contains "$out" "backlog: added $id (queued, kind=scout)" "scout item was not filed as scout"
  assert_contains "$out" "spawned $id harness=claude kind=scout" "scout spawn line missing"
  assert_grep 'why is the toggle slow' "$case_dir/home/data/backlog.md" "--title was not used"
  brief="$case_dir/home/data/$id/brief.md"
  assert_no_grep 'Delivery contract:' "$brief" "a scout brief must carry no delivery contract"
  assert_grep "kind=scout" "$case_dir/home/state/$id.meta" "meta missing kind=scout"
  pass "a scout call files a scout item and spawns a scout"
}

test_explicit_profile_flags_reach_the_spawn() {
  local case_dir id out status
  id=dispatch-profile-g7
  case_dir=$(make_case profile)
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit profile dispatch should succeed: $out"
  assert_contains "$out" "profile: explicit --harness codex --model gpt-5 --effort high" "explicit profile not reported"
  assert_grep 'harness=codex' "$case_dir/home/state/$id.meta" "meta missing the explicit harness"
  assert_grep 'model=gpt-5' "$case_dir/home/state/$id.meta" "meta missing the explicit model"
  assert_grep 'effort=high' "$case_dir/home/state/$id.meta" "meta missing the explicit effort"
  pass "explicit --harness/--model/--effort skip the resolver and reach the spawn"
}

test_full_call_files_briefs_and_spawns
test_second_call_reuses_item_and_brief
test_empty_ask_refuses_before_any_record
test_captain_labelled_ask_refuses
test_mode_mismatch_with_existing_brief_refuses
test_scout_call_files_and_spawns_a_scout
test_explicit_profile_flags_reach_the_spawn
