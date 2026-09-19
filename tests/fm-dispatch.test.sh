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
  printf '%s\n' "$case_dir"
}

# The resolver's opt-in key for one call; empty keeps it off.
RESOLVER_KEY=''
# The pooled worktree the fake pane reports; empty means the case's default.
PANE_PATH=''

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
