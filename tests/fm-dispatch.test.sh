#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch.sh, the one-call intake: scaffold and fill
# the brief, resolve the profile, file the backlog item, spawn.
#
# These tests mirror tests/fm-spawn*.test.sh's fake-harness pattern: a fake
# tmux captures the launch command, treehouse is a no-op, and the pane path
# points at a real isolated git worktree, so the whole call runs end to end
# without starting any harness. The backlog is a real markdown file driven by
# the real tasks-axi CLI, exactly as bin/fm-spawn.sh's transition gate sees it.
# The resolver cases drive the real bin/fm-dispatch-resolve.sh through a fake
# curl and a fake quota-axi on PATH, the same seam tests/fm-dispatch-resolve.test.sh
# uses, so the profile line the dispatch consumes is the one the resolver
# actually renders.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

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
  printf 'Render the toggle from the existing view state; no new store.\n' > "$case_dir/design.md"
  printf '%s\n' "$case_dir"
}

# The resolver's opt-in key for one call; empty keeps it off.
RESOLVER_KEY=''
# The pooled worktree the fake pane reports; empty means the case's default.
PANE_PATH=''

# run_dispatch <case-dir> [fm-dispatch args...]
#
# fm-dispatch requires the task's design record on every call, so this supplies
# the case's own --design unless the caller states its own choice. A case that
# exercises the design flags themselves passes --design or --no-design and keeps it.
run_dispatch() {
  local case_dir=$1 home fakebin launchlog arg design_given=0
  shift
  for arg in "$@"; do
    case "$arg" in
      --design|--no-design) design_given=1 ;;
    esac
  done
  [ "$design_given" -eq 1 ] || set -- "$@" --design "$case_dir/design.md"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  mkdir -p "$home/user-home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="${PANE_PATH:-$case_dir/wt}" TMUX="${TMUX:-fake,1,0}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    TYPESAFE_API_KEY="$RESOLVER_KEY" \
    PATH="$fakebin:$PATH" \
    "$DISPATCH" "$@" 2>&1
}

# install_resolver <case-dir> <choice>: a two-rule crew-dispatch.json (rule_1
# plain, rule_2 approval-gated), a fake curl answering <choice> at high
# confidence, and a fake quota-axi with one fresh claude row.
install_resolver() {
  local case_dir=$1 choice=$2 fakebin
  fakebin="$case_dir/fakebin"
  cat > "$case_dir/home/config/crew-dispatch.json" <<'JSON'
{
  "rules": [
    { "when": "A small change with a stated scope.",
      "use": { "harness": "claude", "model": "sonnet", "effort": "high" } },
    { "when": "Genuinely very difficult design work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "opus" } }
  ]
}
JSON
  cat > "$case_dir/response.json" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$choice", "confidence": 0.95,
    "probabilities": { "rule_1": 0.5, "rule_2": 0.49, "default": 0.01 } } },
  "usage": { "input_tokens": 100, "output_tokens": 10 } }
JSON
  cat > "$case_dir/quota.json" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.4 } } ] } }
  ]
}
JSON
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
set -u
out=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
cp "$case_dir/response.json" "\$out"
printf '200'
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --json ] || exit 2
cat "$case_dir/quota.json"
SH
  chmod +x "$fakebin/curl" "$fakebin/quota-axi"
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

row_field() {  # <case-dir> <id> <field>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n "s/^  $3: *//p" | head -1
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
  assert_contains "$out" "backlog: added $id (queued, kind=ship, repo=project)" "item was not filed"
  assert_contains "$out" "brief: filled $case_dir/home/data/$id/brief.md" "brief was not filled"
  assert_contains "$out" "profile: no rules at $case_dir/home/config/crew-dispatch.json" "no rules file should leave the harness to the spawn"
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
  assert_equals "project" "$(row_field "$case_dir" "$id" repo)" "item lacks the project repo"
  assert_equals 'mode=no-mistakes yolo=off' "$(row_field "$case_dir" "$id" body)" "item note lacks the mode and yolo posture"
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

  # The mirror: a scout brief left behind by a stopped scout dispatch must not
  # be reused as the ship brief of a later --mode call.
  id=dispatch-mismatch-e5-scout
  FM_HOME="$case_dir/home" FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-brief.sh" "$id" project --scout >/dev/null || fail "could not scaffold the existing scout brief"
  brief="$case_dir/home/data/$id/brief.md"
  before=$(cat "$brief")
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --harness claude)
  status=$?
  expect_code 1 "$status" "a ship dispatch over a scout brief should refuse: $out"
  assert_contains "$out" "is a scout brief (no Delivery contract line) but this dispatch passes --mode no-mistakes" "ship-over-scout refusal missing"
  after=$(cat "$brief")
  assert_equals "$before" "$after" "a scout brief under a ship dispatch must not be touched"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a ship dispatch over a scout brief must not file an item"
  assert_absent "$case_dir/home/state/$id.meta" "a ship dispatch over a scout brief must not spawn"
  pass "a mode mismatch with an existing brief refuses without touching it"
}

test_herdr_lab_reaches_the_scaffold_and_must_match_on_rerun() {
  local case_dir id out status brief
  id=dispatch-herdr-m4
  case_dir=$(make_case herdr)
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --herdr-lab \
    --backend nope-backend)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn on an unknown backend should refuse: $out"
  brief="$case_dir/home/data/$id/brief.md"
  assert_contains "$out" "brief: filled $brief" "brief was not scaffolded and filled"
  fm_brief_heading_present "$brief" "# Herdr isolation - HARD SAFETY CONTRACT" || fail "--herdr-lab did not reach fm-brief.sh: the brief lacks the isolation contract"
  fm_brief_heading_present "$brief" "# Herdr lifecycle declaration - NOT ENABLED" && fail "a --herdr-lab brief still carries the NOT ENABLED declaration"

  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a re-run without --herdr-lab over a guarded brief should refuse: $out"
  assert_contains "$out" "carries the Herdr isolation contract (scaffolded with --herdr-lab) but this dispatch omits --herdr-lab" "guarded-brief refusal missing"
  assert_equals "queued" "$(row_state "$case_dir" "$id")" "a Herdr mismatch must leave the item queued"
  assert_absent "$case_dir/home/state/$id.meta" "a Herdr mismatch must not spawn"

  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --herdr-lab)
  status=$?
  expect_code 0 "$status" "the matching re-run should reuse the guarded brief and spawn: $out"
  assert_contains "$out" "brief: reused $brief" "matching re-run did not reuse the brief"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "matching re-run did not spawn"

  # The reverse mismatch: an unguarded brief cannot be promoted by the flag alone.
  id=dispatch-herdr-m4-plain
  FM_HOME="$case_dir/home" FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-brief.sh" "$id" project --scout >/dev/null || fail "could not scaffold the plain brief"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --herdr-lab)
  status=$?
  expect_code 1 "$status" "--herdr-lab over an unguarded brief should refuse: $out"
  assert_contains "$out" "was scaffolded without --herdr-lab (Herdr lifecycle declaration - NOT ENABLED) but this dispatch passes --herdr-lab" "unguarded-brief refusal missing"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "the reverse Herdr mismatch must not file an item"
  pass "--herdr-lab reaches the scaffold and a re-run must agree with the existing brief"
}

# A review dispatch is one call: it briefs with the reviewer contract, files a
# scout item whose note records the reviewed pull request, and spawns as a
# scout. The kind stays scout in meta because a review is scout-shaped in every
# mechanical respect and is supervised and torn down by that path.
test_review_call_files_a_review_item_and_spawns_a_scout() {
  local case_dir id out status brief
  id=dispatch-review-v2
  case_dir=$(make_case review)
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --review https://github.com/acme/widget/pull/64 \
    --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --title "review the toggle PR")
  status=$?
  expect_code 0 "$status" "review dispatch should succeed: $out"
  assert_contains "$out" "backlog: added $id (queued, kind=scout, repo=project)" "review item was not filed as a scout item"
  assert_contains "$out" "spawned $id harness=claude kind=scout" "review spawn line missing"
  assert_equals '"kind=review pr=https://github.com/acme/widget/pull/64"' "$(row_field "$case_dir" "$id" body)" "review note must record the reviewed pull request"
  brief="$case_dir/home/data/$id/brief.md"
  assert_grep "gh-axi pr review 64 -R acme/widget --comment --body-file" "$brief" "review brief did not reach the worker through the dispatch"
  assert_no_grep 'Delivery contract:' "$brief" "a review brief must carry no delivery contract"
  assert_grep "kind=scout" "$case_dir/home/state/$id.meta" "meta missing kind=scout"
  pass "a review call files a review item and spawns it as a scout"
}

# --review is exclusive with the ship delivery flags, and an existing brief
# whose review shape disagrees with the call is refused before anything is
# filed - the same protection the --mode and --herdr-lab mismatches already get,
# because filling the wrong contract would hand the worker a job it was not
# dispatched for.
test_review_flag_conflicts_and_brief_mismatch_refuse() {
  local case_dir id out status
  case_dir=$(make_case review-conflicts)
  id=dispatch-review-conflict-v2
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --review https://github.com/acme/widget/pull/3 --mode direct-PR --yolo off \
    --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" 2>&1)
  status=$?
  expect_code 1 "$status" "--review with --mode must refuse"
  assert_contains "$out" "--review cannot be combined with --mode or --yolo" "wrong refusal for --review --mode"
  [ -e "$case_dir/home/data/$id/brief.md" ] && fail "a refused review dispatch still scaffolded a brief"

  # A scout brief already on disk, dispatched with --review.
  id=dispatch-review-shape-v2
  mkdir -p "$case_dir/home/data/$id"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-brief.sh" "$id" project --scout >/dev/null 2>&1
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --review https://github.com/acme/widget/pull/3 \
    --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" 2>&1)
  status=$?
  expect_code 1 "$status" "a scout brief dispatched with --review must refuse"
  assert_contains "$out" "is not a review brief but this dispatch passes --review" "wrong refusal for a scout brief under --review"

  # A review brief already on disk, dispatched as a plain scout.
  id=dispatch-review-shape-b-v2
  mkdir -p "$case_dir/home/data/$id"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-brief.sh" "$id" project \
    --review https://github.com/acme/widget/pull/3 >/dev/null 2>&1
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" --scout \
    --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" 2>&1)
  status=$?
  expect_code 1 "$status" "a review brief dispatched with --scout must refuse"
  assert_contains "$out" "is a review brief but this dispatch omits --review" "wrong refusal for a review brief under --scout"

  # The URL must be validated here too. An already-scaffolded brief is reused
  # without calling fm-brief.sh, so on that path this is the only check between
  # a bad URL and the backlog note that records it.
  id=dispatch-review-badurl-v2
  mkdir -p "$case_dir/home/data/$id"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-brief.sh" "$id" project \
    --review https://github.com/acme/widget/pull/3 >/dev/null 2>&1
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --review https://gitlab.com/g/p/-/merge_requests/3 \
    --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" 2>&1)
  status=$?
  expect_code 1 "$status" "a non-GitHub --review URL must refuse even when the brief already exists"
  assert_contains "$out" "requires a GitHub pull request URL" "wrong refusal for a non-GitHub review URL"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a refused review URL still reached the backlog"
  pass "a review dispatch refuses ship flags, a disagreeing brief, and a URL it could not post to"
}

test_scout_call_files_and_spawns_a_scout() {
  local case_dir id out status brief
  id=dispatch-scout-f6
  case_dir=$(make_case scout)
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" --title "why is the toggle slow" \
    --reason "captain wants the cause before any fix")
  status=$?
  expect_code 0 "$status" "scout dispatch should succeed: $out"
  assert_contains "$out" "backlog: added $id (queued, kind=scout, repo=project)" "scout item was not filed as scout"
  assert_contains "$out" "spawned $id harness=claude kind=scout" "scout spawn line missing"
  assert_grep 'why is the toggle slow' "$case_dir/home/data/backlog.md" "--title was not used"
  assert_equals '"kind=scout\nreason: captain wants the cause before any fix"' "$(row_field "$case_dir" "$id" body)" "scout note lacks kind=scout plus the --reason line"
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

test_projects_prefix_resolves_against_the_projects_dir() {
  local case_dir id out status home
  id=dispatch-prefix-h8
  case_dir=$(make_case prefix)
  home="$case_dir/home"
  fm_git_init_commit "$home/projects/pager"
  fm_git_add_origin "$home/projects/pager" "$case_dir/pager.origin.git"
  git -C "$home/projects/pager" worktree add --quiet -b pooled-prefix "$case_dir/wt-pager"
  # From a working directory that has no projects/ of its own.
  out=$(cd "$case_dir" && PANE_PATH="$case_dir/wt-pager" run_dispatch "$case_dir" "$id" --project projects/pager \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "projects/<name> should resolve against the home's projects dir: $out"
  assert_contains "$out" "backlog: added $id (queued, kind=ship, repo=pager)" "repo not taken from the resolved project"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "spawn line missing"
  assert_equals "$(cd "$home/projects/pager" && pwd -P)" "$(sed -n 's/^project=//p' "$case_dir/home/state/$id.meta")" "meta does not point at the resolved project"
  pass "--project projects/<name> resolves the way fm-spawn does"
}

test_heading_in_ask_or_spec_refuses_before_any_record() {
  local case_dir id out status
  id=dispatch-heading-i9
  case_dir=$(make_case heading)
  printf 'add the toggle\n## Background\npasted PR description\n' > "$case_dir/heading-ask.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/heading-ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a level-2 heading in the ask should refuse: $out"
  assert_contains "$out" "would break ## Captain's intent: ## Background" "refusal did not name the heading line"
  assert_absent "$case_dir/home/data/$id" "a heading in the ask must not create the brief directory"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a heading in the ask must not file an item"

  printf 'Implement it.\n# Plan\nstep one\n' > "$case_dir/heading-spec.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/heading-spec.md")
  status=$?
  expect_code 1 "$status" "a level-1 heading in the spec should refuse: $out"
  assert_contains "$out" "would break ## Firstmate spec: # Plan" "refusal did not name the spec heading line"
  assert_absent "$case_dir/home/data/$id" "a heading in the spec must not create the brief directory"

  # A fence opened and never closed would hide ## Firstmate spec and every
  # section after it from the parser.
  printf 'add the toggle\n```sh\necho pasted snippet\n' > "$case_dir/open-fence-ask.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/open-fence-ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "an unclosed fence in the ask should refuse: $out"
  assert_contains "$out" "would break ## Captain's intent: \`\`\`sh" "refusal did not name the unclosed fence line"
  assert_absent "$case_dir/home/data/$id" "an unclosed fence must not create the brief directory"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "an unclosed fence must not file an item"

  # A fenced heading and a level-3 heading are ordinary content and reach the brief intact.
  # shellcheck disable=SC2016  # the literal backticks are the fence the parser must ignore
  printf 'add the toggle\n\n```sh\n# not a heading\n```\n### Notes\nkeep the layout\n' > "$case_dir/fenced-ask.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/fenced-ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "fenced and deeper headings should be accepted: $out"
  intent=$(fm_brief_task_heading_body "$case_dir/home/data/$id/brief.md" "## Captain's intent")
  assert_contains "$intent" '# not a heading' "fenced heading was dropped from the extracted intent"
  assert_contains "$intent" 'keep the layout' "text after the level-3 heading was dropped from the extracted intent"
  pass "an unfenced level-1 or level-2 heading or an unclosed fence in the ask or spec refuses before any record"
}

test_half_filled_brief_refuses_before_any_record() {
  local case_dir id out status brief before after intent
  id=dispatch-halffilled-n5
  case_dir=$(make_case halffilled)
  # Firstmate scaffolded and filled ## Captain's intent by hand, then reached
  # for the one-call intake: splicing only {FIRSTMATE_SPEC} would leave the
  # worker with the stale intent instead of this call's --ask.
  FM_HOME="$case_dir/home" FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-brief.sh" "$id" project --mode no-mistakes >/dev/null || fail "could not scaffold the half-filled brief"
  brief="$case_dir/home/data/$id/brief.md"
  sed 's/^{TASK}$/an older ask nobody supplied today/' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
  before=$(cat "$brief")
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a half-filled brief should refuse: $out"
  assert_contains "$out" "is half-filled" "refusal did not name the half-filled brief"
  assert_contains "$out" "## Firstmate spec still carries {FIRSTMATE_SPEC} while ## Captain's intent is already written" "refusal did not name which subsection was already written"
  after=$(cat "$brief")
  assert_equals "$before" "$after" "a half-filled brief must not be touched"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a half-filled brief must not file an item"
  assert_absent "$case_dir/home/state/$id.meta" "a half-filled brief must not spawn"

  # The mirror: the spec written by hand, the ask still a placeholder.
  id=dispatch-halffilled-n5-spec
  FM_HOME="$case_dir/home" FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-brief.sh" "$id" project --scout >/dev/null || fail "could not scaffold the mirrored half-filled brief"
  brief="$case_dir/home/data/$id/brief.md"
  sed 's/^{FIRSTMATE_SPEC}$/an older specification nobody supplied today/' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "the mirrored half-filled brief should refuse: $out"
  assert_contains "$out" "## Captain's intent still carries {TASK} while ## Firstmate spec is already written" "mirrored refusal did not name which subsection was already written"

  # A brief with both subsections written by hand is still reused whole.
  id=dispatch-halffilled-n5-whole
  FM_HOME="$case_dir/home" FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-brief.sh" "$id" project --mode no-mistakes >/dev/null || fail "could not scaffold the hand-filled brief"
  brief="$case_dir/home/data/$id/brief.md"
  sed -e 's/^{TASK}$/a hand-written ask/' -e 's/^{FIRSTMATE_SPEC}$/a hand-written specification/' \
    "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "a fully hand-filled brief should be reused: $out"
  assert_contains "$out" "brief: reused $brief" "a fully hand-filled brief was not reused"
  intent=$(fm_brief_task_heading_body "$brief" "## Captain's intent")
  assert_equals "a hand-written ask" "$intent" "a reused brief's intent was rewritten"
  pass "a brief carrying exactly one placeholder refuses before any record"
}

test_bullet_led_ask_titles_the_item_without_its_marker() {
  local case_dir id out status
  id=dispatch-bullet-o6
  case_dir=$(make_case bullet)
  printf -- '- add a summary toggle to the report view\nkeep the existing layout\n' > "$case_dir/bullet-ask.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/bullet-ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "a bullet-led ask should file and spawn: $out"
  assert_equals "add a summary toggle to the report view" "$(row_field "$case_dir" "$id" title)" "the list marker was not dropped from the derived title"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "a bullet-led ask did not reach the spawn"
  assert_grep '- add a summary toggle to the report view' "$case_dir/home/data/$id/brief.md" "the ask bytes must reach the brief with their marker intact"

  # A title that still starts with a dash is refused before anything is written,
  # because tasks-axi would read it as a flag.
  id=dispatch-bullet-o6-flag
  printf -- '--force should stop defaulting to on\nit surprised two people this week\n' > "$case_dir/flag-ask.md"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/flag-ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "a dash-leading title should refuse: $out"
  assert_contains "$out" "starts with a dash" "refusal did not explain the dash"
  assert_contains "$out" "pass --title <text>" "refusal did not name --title"
  assert_absent "$case_dir/home/data/$id" "a dash-leading title must not create the brief directory"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a dash-leading title must not file an item"

  # --title carries such an ask through in one call.
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/flag-ask.md" --spec "$case_dir/spec.md" \
    --title "stop defaulting --force to on")
  status=$?
  expect_code 0 "$status" "--title should carry the dash-leading ask: $out"
  assert_equals "stop defaulting --force to on" "$(row_field "$case_dir" "$id" title)" "--title did not reach the item"
  pass "a bullet-led ask titles the item without its marker; a dash-leading title refuses naming --title"
}

test_resolver_clear_profile_reaches_the_spawn_unquoted() {
  local case_dir id out status
  id=dispatch-clear-j1
  case_dir=$(make_case clear)
  install_resolver "$case_dir" rule_1
  out=$(RESOLVER_KEY=test-key run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 0 "$status" "a clear resolution should spawn: $out"
  assert_contains "$out" "profile: resolved --harness 'claude' --model 'sonnet' --effort 'high'" "resolved profile not reported"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "spawn line missing"
  assert_equals "claude" "$(sed -n 's/^harness=//p' "$case_dir/home/state/$id.meta")" "meta harness carries quotes or is missing"
  assert_equals "sonnet" "$(sed -n 's/^model=//p' "$case_dir/home/state/$id.meta")" "meta model carries quotes or is missing"
  assert_equals "high" "$(sed -n 's/^effort=//p' "$case_dir/home/state/$id.meta")" "meta effort carries quotes or is missing"
  assert_equals "in_flight" "$(row_state "$case_dir" "$id")" "item did not move to In flight"
  pass "a clear resolver profile reaches the spawn without its shell quotes"
}

test_resolver_escalate_stops_before_filing() {
  local case_dir id out status brief
  id=dispatch-escalate-k2
  case_dir=$(make_case escalate)
  install_resolver "$case_dir" rule_2
  out=$(RESOLVER_KEY=test-key run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "an escalate resolution should stop: $out"
  assert_contains "$out" "  status: escalate" "resolver block was not printed"
  assert_contains "$out" "reason: rule requires the captain's explicit approval before dispatch" "resolver reason was lost"
  assert_contains "$out" "candidate: claude:opus" "resolver candidate evidence was lost"
  assert_contains "$out" "profile unresolved (escalate)" "stop message missing"
  assert_contains "$out" "re-run this call with explicit --harness/--model/--effort" "stop message does not say how to continue"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "an escalate must not file an item"
  assert_absent "$case_dir/home/state/$id.meta" "an escalate must not spawn"
  [ -s "$case_dir/launch.log" ] && fail "an escalate must not send a launch command"
  brief="$case_dir/home/data/$id/brief.md"
  assert_present "$brief" "the filled brief is the record the re-run reuses"

  out=$(RESOLVER_KEY=test-key run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --harness claude --model opus)
  status=$?
  expect_code 0 "$status" "the re-run with explicit flags should spawn: $out"
  assert_contains "$out" "brief: reused $brief" "re-run did not reuse the brief"
  assert_contains "$out" "profile: explicit --harness claude --model opus" "re-run did not take the explicit profile"
  assert_equals "in_flight" "$(row_state "$case_dir" "$id")" "re-run did not file and move the item"
  pass "a non-clear resolution stops before filing; the explicit re-run completes"
}

test_resolver_off_with_rules_stops_before_filing() {
  local case_dir id out status
  id=dispatch-off-l3
  case_dir=$(make_case off)
  install_resolver "$case_dir" rule_1
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md")
  status=$?
  expect_code 1 "$status" "rules without a resolver key should stop: $out"
  assert_contains "$out" "dispatch-resolve: off" "resolver's own off line was not passed through"
  assert_contains "$out" "profile unresolved (resolver off)" "stop message missing"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "resolver off with rules must not file an item"
  assert_absent "$case_dir/home/state/$id.meta" "resolver off with rules must not spawn"
  pass "a rules file with the resolver off stops before filing instead of resolving statically"
}

# Firstmate's plan for a task is not optional machinery it can forget at the end
# of an intake: exactly one of --design or --no-design is required, and the refusal
# lands before anything is written, so a call that omitted it leaves no half-made
# task behind.
test_design_record_choice_is_required_and_exclusive() {
  local case_dir id out status home fakebin
  case_dir=$(make_case design-required)
  : > "$case_dir/empty-design.md"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"

  # The primary branch: neither flag passed. run_dispatch supplies --design for
  # every other case in this file, so this one call deliberately bypasses it and
  # invokes the script with the same environment and nothing to choose from.
  id=dispatch-design-absent
  mkdir -p "$home/user-home"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="${TMUX:-fake,1,0}" \
    TYPESAFE_API_KEY='' PATH="$fakebin:$PATH" \
    "$DISPATCH" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "omitting both design flags should refuse: $out"
  assert_contains "$out" "--design <file> or --no-design <reason> required" \
    "the refusal did not name the two flags that satisfy it"
  assert_contains "$out" "$home/data/$id/design.md" \
    "the refusal did not name the record the plan belongs in"
  assert_contains "$out" "a decision that gets recorded rather than a step that gets skipped" \
    "the refusal did not say why declaring no design is still an answer"
  assert_absent "$home/data/$id/brief.md" "a refused call still scaffolded a brief"
  assert_absent "$home/data/$id/design.md" "a refused call still wrote a design record"
  assert_no_grep "$id" "$home/data/backlog.md" "a refused call still filed an item"
  assert_absent "$home/state/$id.meta" "a refused call still spawned"

  id=dispatch-design-missing
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --no-design '')
  status=$?
  [ "$status" -ne 0 ] || fail "a blank --no-design reason should refuse: $out"
  assert_contains "$out" "--no-design requires a reason carrying text" \
    "blank reason refusal did not say what a reason is for"
  assert_absent "$case_dir/home/data/$id/brief.md" "a refused call still scaffolded a brief"
  assert_absent "$case_dir/home/data/$id/design.md" "a refused call still wrote a design record"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" "a refused call still filed an item"

  id=dispatch-design-both
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md" --no-design 'nothing to decide')
  status=$?
  [ "$status" -ne 0 ] || fail "--design with --no-design should refuse: $out"
  assert_contains "$out" "--design and --no-design are exclusive" "both-flags refusal missing"
  assert_absent "$case_dir/home/data/$id/brief.md" "a refused call still scaffolded a brief"

  id=dispatch-design-empty
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode no-mistakes --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/empty-design.md")
  status=$?
  [ "$status" -ne 0 ] || fail "an empty --design file should refuse: $out"
  assert_contains "$out" "must carry firstmate's decisions and why" "empty-plan refusal missing"
  assert_absent "$case_dir/home/data/$id/brief.md" "a refused call still scaffolded a brief"
  pass "fm-dispatch: the design record is required, exclusive, and refused before any record is made"
}

# The two accepted answers write two different records, and both leave a file the
# worker can open. A re-run reuses what is already there, exactly as it reuses an
# already-filled brief, so a retry after a refused spawn is safe.
test_design_record_is_filled_from_the_plan_or_the_declaration() {
  local case_dir id out status record before
  case_dir=$(make_case design-filled)

  id=dispatch-design-plan
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  expect_code 0 "$status" "a dispatch carrying a plan should succeed: $out"
  record="$case_dir/home/data/$id/design.md"
  assert_contains "$out" "design: filled $record" "the filled record was not reported"
  assert_grep "Render the toggle from the existing view state; no new store." "$record" \
    "the plan's bytes did not reach the design record"
  assert_no_grep "{DESIGN}" "$record" "the design placeholder survived the fill"
  grep -qF -- "$record" "$case_dir/home/data/$id/brief.md" \
    || fail "the brief does not point the worker at the filled record"

  id=dispatch-design-none
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --no-design 'a one-line typo fix with nothing to decide')
  status=$?
  expect_code 0 "$status" "a dispatch declaring no design should succeed: $out"
  record="$case_dir/home/data/$id/design.md"
  assert_grep "a one-line typo fix with nothing to decide" "$record" \
    "the declaration's reason did not reach the record"
  # Dated, so a record that later goes quiet is visibly a record that stopped
  # rather than one that was never written.
  grep -qE 'None recorded at dispatch \([0-9]{4}-[0-9]{2}-[0-9]{2}\):' "$record" \
    || fail "the no-design declaration is undated: $(cat "$record")"
  assert_no_grep "{DESIGN}" "$record" "the design placeholder survived the declaration"

  before=$(cat "$record")
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  assert_contains "$out" "design: reused $record" "a re-run did not report the record as reused"
  [ "$(cat "$record")" = "$before" ] || fail "a re-run overwrote a design record that was already written"
  pass "fm-dispatch: --design writes the plan, --no-design writes a dated declaration, and a re-run reuses both"
}

# A task briefed before design records existed has none. Re-dispatching it must
# give it one rather than leaving the call with nothing to fill.
# Detection and replacement share one assumption, so they share one boundary, and
# they share it through one parser rather than two that agree on the easy shapes.
# The quoted placeholder here sits in a FENCED block, which is how anyone would
# actually write a plan about this scaffold in Markdown, and which is the shape a
# section-tracking loop written in shell gets wrong: it is the fence the two
# parsers disagree about, so pinning the unfenced form would pin the case that
# works. A heading inside that fence is here for the same reason - it must not end
# the section the real placeholder lives in either.
test_design_fill_is_bounded_to_the_decisions_section() {
  local case_dir id record out status hits
  case_dir=$(make_case design-bounded-fill)
  id=dispatch-design-bounded
  mkdir -p "$case_dir/home/data/$id"
  record="$case_dir/home/data/$id/design.md"
  printf '%s\n' '# Design - a record with a worked example below' '' \
    '## Notes for whoever fills this' \
    'The scaffold writes its placeholder on a line of its own:' '' \
    '```markdown' \
    '## Decisions' \
    '{DESIGN}' \
    '```' '' \
    'and the dispatch replaces that one line.' '' \
    '## Decisions' '{DESIGN}' > "$record"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  expect_code 0 "$status" "a record with a placeholder outside its section should fill: $out"
  hits=$(grep -c 'Render the toggle from the existing view state; no new store.' "$record")
  assert_equals "1" "$hits" "the plan was spliced into every placeholder line, not just the section's"
  grep -qx -- '{DESIGN}' "$record" \
    || fail "the placeholder inside the fenced example was consumed; it is the record's own example text"
  grep -qx -- '## Decisions' "$record" \
    || fail "the fenced example's heading was consumed"
  pass "fm-dispatch: the fill replaces the real ## Decisions placeholder and leaves a fenced example alone"
}

# The detector strips whitespace before comparing, so a placeholder carrying
# stray whitespace reads as intact. An exact match in the fill then found no such
# line, and that combination hit an `exit` inside a `{ ... } > file` group, which
# unwinds past the handler attached to that group: firstmate got a bare status
# with nothing said and one .design.md.dispatch.<pid> per attempt. Both sides now
# compare the same way, so the case fills instead of reaching any refusal, and the
# refusal that remains returns rather than exiting.
test_design_fill_matches_what_the_detector_accepted() {
  local case_dir id record out status leftovers
  case_dir=$(make_case design-fill-refusal)
  id=dispatch-design-refusal
  mkdir -p "$case_dir/home/data/$id"
  record="$case_dir/home/data/$id/design.md"
  # A placeholder with stray whitespace: intact to the detector, and the case the
  # fill must now match too rather than refusing.
  printf '%s\n' '# Design - whitespace around the placeholder' '' \
    '## Decisions' '  {DESIGN}  ' > "$record"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  expect_code 0 "$status" "a placeholder with stray whitespace should fill, not refuse: $out"
  assert_grep 'Render the toggle from the existing view state; no new store.' "$record" \
    "the detector accepted the padded placeholder and the fill did not replace it"
  assert_no_grep '{DESIGN}' "$record" "the padded placeholder survived the fill"

  # The visible consequence of that unwind was a temp file per attempt. Nothing
  # this dispatch did may leave one, on the path that fills or any other.
  leftovers=$(find "$case_dir/home/data" -name '.design.md.dispatch.*' -o -name '.brief.md.dispatch.*' | wc -l | tr -d ' ')
  assert_equals "0" "$leftovers" "a dispatch left a .design.md.dispatch temp file behind"
  pass "fm-dispatch: the fill matches what the detector accepted and leaves no temp file"
}

# The same refusal, at the dispatch's own copy of it. Reaching that copy takes an
# EXISTING brief: with no brief the call runs bin/fm-brief.sh at step 2, whose own
# refusal - same wording, deliberately - fires first and files nothing, so a case
# built without a brief would pass with this check deleted and prove nothing.
# bin/fm-spawn.sh says the same sentence later for the same reason, and what
# separates it is WHEN: the design step is step 3 and the backlog item is step 5,
# so a dispatch refusing its own check files nothing while one running through to
# the spawn has already filed.
test_dispatch_refuses_a_design_record_that_is_not_a_file() {
  local case_dir id record brief out status
  case_dir=$(make_case design-notfile)
  id=dispatch-design-notfile
  # A brief already filled, so step 2 reuses it and never calls fm-brief.sh.
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  expect_code 0 "$?" "the setup dispatch should succeed: $out"
  brief="$case_dir/home/data/$id/brief.md"
  assert_present "$brief" "the setup dispatch left no brief to reuse"
  record="$case_dir/home/data/$id/design.md"
  rm -f "$record"
  mkdir -p "$record"

  id=dispatch-design-notfile-second
  mkdir -p "$case_dir/home/data/$id"
  cp "$brief" "$case_dir/home/data/$id/brief.md"
  record="$case_dir/home/data/$id/design.md"
  mkdir -p "$record"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a directory at the design record's path should refuse: $out"
  assert_contains "$out" "exists but is not a readable regular file" \
    "the refusal did not use the wording every script on this path shares"
  assert_contains "$out" "brief: reused" \
    "the brief was rebuilt, so fm-brief.sh refused first and this case proves nothing"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" \
    "the dispatch ran past its own design check and was refused later by the spawn instead"
  assert_absent "$case_dir/home/state/$id.meta" "a refused dispatch still spawned"
  rmdir "$record"
  pass "fm-dispatch: a design record that is not a file the worker can open is refused"
}

# Bounding the contract read gave an empty result a second meaning - the line is
# there and no reader can see it - whose consequence is the opposite of the first.
# The --scout guard reads empty as "not a ship brief", so a SHIP brief dispatched
# with --scout got past it: item filed, kind flipped to scout, and a worker
# launched on a brief whose Definition of done still says push and open a pull
# request. An unclosed fence above the heading produces the same empty, and used
# to be refused before any record was made.
test_unreachable_delivery_contract_is_refused_not_read_as_absent() {
  local case_dir id brief out status

  case_dir=$(make_case unreachable-renamed)
  id=dispatch-unreachable-renamed
  mkdir -p "$case_dir/home/data/$id"
  brief="$case_dir/home/data/$id/brief.md"
  printf '%s\n' 'You are a crewmate.' '' \
    '# Task' "## Captain's intent" 'Ship the toggle.' '' \
    '## Firstmate spec' 'Leave the settings page alone.' '' \
    '# Done' 'Delivery contract: mode=direct-PR' > "$brief"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a ship brief whose contract is unreachable should refuse --scout: $out"
  assert_contains "$out" "no reader can reach" \
    "the refusal reported the contract as absent rather than unreachable"
  assert_contains "$out" "Delivery contract: mode=direct-PR" \
    "the refusal did not name the line that caused it"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" \
    "the item was filed before the unreachable contract was noticed"
  assert_absent "$case_dir/home/state/$id.meta" "a worker was launched on an unreachable contract"

  # An unclosed fence above the heading hides it from every reader, and must be
  # refused here rather than at the spawn after the item is already filed.
  case_dir=$(make_case unreachable-fence)
  id=dispatch-unreachable-fence
  mkdir -p "$case_dir/home/data/$id"
  brief="$case_dir/home/data/$id/brief.md"
  printf '%s\n' 'You are a crewmate.' '' \
    '# Task' "## Captain's intent" 'Ship the toggle.' '' \
    '## Firstmate spec' 'The scaffold writes:' '```' 'left open' '' \
    '# Definition of done' 'Delivery contract: mode=direct-PR' > "$brief"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  [ "$status" -ne 0 ] || fail "an unclosed fence hiding the contract should refuse: $out"
  assert_contains "$out" "no reader can reach" "the fence case was not reported as unreachable"
  assert_no_grep "$id" "$case_dir/home/data/backlog.md" \
    "the item was filed before the hidden contract was noticed"

  # And the case bounding the read was FOR must still dispatch: a scout brief
  # whose captain's ask quotes the contract line records no contract of its own.
  case_dir=$(make_case unreachable-quoted-scout)
  id=dispatch-unreachable-quoted
  cat > "$case_dir/quoting-ask.md" <<'ASK'
Work out why briefs record the wrong delivery mode.

The brief carries this line and the spawn reads it:

```
Delivery contract: mode=no-mistakes
```

Report what you find.
ASK
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --scout --ask "$case_dir/quoting-ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  expect_code 0 "$status" "a scout whose ask quotes the contract line should dispatch: $out"
  assert_grep 'Delivery contract: mode=no-mistakes' "$case_dir/home/data/$id/brief.md" \
    "the captain's quoted line was scrubbed instead of left alone"
  pass "fm-dispatch: a contract no reader can reach is refused, and a quoted one still dispatches"
}

test_dispatch_scaffolds_a_design_record_an_older_brief_never_had() {
  local case_dir id out status brief record
  case_dir=$(make_case design-legacy)
  id=dispatch-design-legacy
  mkdir -p "$case_dir/home/data/$id"
  brief="$case_dir/home/data/$id/brief.md"
  cat > "$brief" <<'EOF'
You are a crewmate.

# Task
## Captain's intent
Ship the legacy toggle.

## Firstmate spec
Leave the settings page alone.

# Definition of done
Delivery contract: mode=direct-PR
EOF
  record="$case_dir/home/data/$id/design.md"
  assert_absent "$record" "the legacy fixture already had a design record"
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  expect_code 0 "$status" "re-dispatching a legacy brief should succeed: $out"
  assert_contains "$out" "brief: reused $brief" "the legacy brief was not reused"
  assert_present "$record" "re-dispatching a legacy brief left it without a design record"
  assert_grep "Render the toggle from the existing view state; no new store." "$record" \
    "the plan did not reach the newly scaffolded record"
  pass "fm-dispatch: a brief predating design records is given one on the next dispatch"
}

# The captain's own words reach the brief verbatim, and they can contain anything -
# including this contract line, quoted inside a CLOSED code fence in an ask about
# delivery modes. The heading and unclosed-fence guards do not cover it: it is a
# structural line, not a heading. Read unbounded, that quote came first and won,
# and the task was undispatchable until someone hand-edited the captain's text.
# The promoted shape is here because it is what a first-section rule would break:
# a promoted scout carries its own Definition of done AND the superseding one
# bin/fm-promote.sh appends, and the contract belongs to the second.
test_delivery_contract_is_read_from_its_own_section() {
  local case_dir id brief out status
  case_dir=$(make_case delivery-quoted)
  id=dispatch-delivery-quoted
  cat > "$case_dir/quoting-ask.md" <<'ASK'
Stop briefs from recording the wrong delivery mode.

The generated brief carries this line and the spawn reads it:

```
Delivery contract: mode=no-mistakes
```

That line is what the two refusals compare against.
ASK
  out=$(run_dispatch "$case_dir" "$id" --project "$case_dir/project" \
    --mode direct-PR --yolo off --ask "$case_dir/quoting-ask.md" --spec "$case_dir/spec.md" \
    --design "$case_dir/design.md")
  status=$?
  expect_code 0 "$status" "an ask quoting the contract line should dispatch, not refuse: $out"
  brief="$case_dir/home/data/$id/brief.md"
  assert_grep 'Delivery contract: mode=no-mistakes' "$brief" \
    "the captain's quoted line was scrubbed instead of left alone"
  assert_equals "direct-PR" "$(fm_brief_delivery_mode "$brief")" \
    "the quoted line in the ask was read as the brief's delivery contract"
  assert_equals "in_flight" "$(row_state "$case_dir" "$id")" "the quoting ask never reached the spawn"

  # A promoted scout brief: two Definition of done sections, contract in the second.
  brief="$case_dir/promoted-brief.md"
  {
    printf '%s\n' '# Task' '## Captain'"'"'s intent' 'investigate' '' \
      '# Definition of done' 'Write your findings to report.md.' '' \
      '# Current ship Firstmate spec' 'now ship it' ''
    printf '%s\n' '# Definition of done' 'Delivery contract: mode=local-only' 'and stop.'
  } > "$brief"
  assert_equals "local-only" "$(fm_brief_delivery_mode "$brief")" \
    "a promoted brief's superseding contract was missed; the scout section came first"
  pass "fm-dod-lib: the delivery contract is read from its own section, not from anywhere in the brief"
}

test_full_call_files_briefs_and_spawns
test_second_call_reuses_item_and_brief
test_empty_ask_refuses_before_any_record
test_captain_labelled_ask_refuses
test_mode_mismatch_with_existing_brief_refuses
test_herdr_lab_reaches_the_scaffold_and_must_match_on_rerun
test_scout_call_files_and_spawns_a_scout
test_explicit_profile_flags_reach_the_spawn
test_projects_prefix_resolves_against_the_projects_dir
test_heading_in_ask_or_spec_refuses_before_any_record
test_half_filled_brief_refuses_before_any_record
test_bullet_led_ask_titles_the_item_without_its_marker
test_resolver_clear_profile_reaches_the_spawn_unquoted
test_resolver_escalate_stops_before_filing
test_resolver_off_with_rules_stops_before_filing
test_review_call_files_a_review_item_and_spawns_a_scout
test_review_flag_conflicts_and_brief_mismatch_refuse
test_design_record_choice_is_required_and_exclusive
test_design_record_is_filled_from_the_plan_or_the_declaration
test_dispatch_scaffolds_a_design_record_an_older_brief_never_had
test_design_fill_is_bounded_to_the_decisions_section
test_design_fill_matches_what_the_detector_accepted
test_dispatch_refuses_a_design_record_that_is_not_a_file
test_delivery_contract_is_read_from_its_own_section
test_unreachable_delivery_contract_is_refused_not_read_as_absent
