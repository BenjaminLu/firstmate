#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-trust.sh and the claude spawn that calls it.
#
# Both halves of the contract are load-bearing and both are proven here, for
# each directory a claude launch can start in: a legitimate fresh task worktree
# and a seeded secondmate home are trusted so the agent reaches its brief or
# charter with no human, and every out-of-scope path is REFUSED rather than
# warned about or quietly skipped.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-trust)

TRUST="$ROOT/bin/fm-claude-trust.sh"

# make_case <name>: a project with one linked worktree plus an isolated Claude
# config directory. Echoes "<case>|<proj>|<wt>|<config>".
make_case() {
  local name=$1 case_dir proj wt config
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  mkdir -p "$config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$config"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT CONFIG <<EOF
$1
EOF
}

# run_trust <config> <worktree> <project> [home]: invoke with an isolated store.
run_trust() {
  local config=$1 wt=$2 proj=$3 home=${4:-$1}
  CLAUDE_CONFIG_DIR="$config" HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

trusted_paths() {  # <store>
  node -e 'const j=require("node:fs").existsSync(process.argv[1])?JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")):{};for(const [k,v] of Object.entries(j.projects||{})){if(v&&v.hasTrustDialogAccepted===true)console.log(k);}' "$1"
}

assert_trusted() {  # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_not_trusted() {  # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

# The store is the vendor's own persisted JSON, so preservation is asserted
# against the parsed value at a key path rather than the serialized bytes.
store_value() {  # <store> <key...> -> the JSON value at that key path
  local store=$1
  shift
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));let v=j;for(const k of process.argv.slice(2)){v=(v===undefined||v===null)?undefined:v[k];}console.log(JSON.stringify(v));' "$store" "$@"
}

assert_store_value() {  # <store> <expected-json> <msg> <key...>
  local store=$1 expected=$2 msg=$3 actual
  shift 3
  actual=$(store_value "$store" "$@")
  [ "$actual" = "$expected" ] || fail "$msg (expected $expected, got $actual)"
}

# assert_all_flags <store> <path> <msg>: all three registered flags - trust,
# external-includes approved, external-includes warning-shown - are true on
# the project entry at <path>. The external-imports flags are the ones the
# running app reads only from the PROJECT-root entry, never the worktree
# entry, so this is what actually proves the dialog is suppressed.
assert_all_flags() {
  local store=$1 key=$2 msg=$3
  node -e '
    const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));
    const e=(j.projects||{})[process.argv[2]]||{};
    const flags=["hasTrustDialogAccepted","hasClaudeMdExternalIncludesApproved","hasClaudeMdExternalIncludesWarningShown"];
    process.exit(flags.every((f)=>e[f]===true)?0:1);
  ' "$store" "$key" || fail "$msg"
}

# assert_trust_only_no_import_consent <store> <path> <msg>: the entry at
# <path> carries hasTrustDialogAccepted===true but NEITHER external-imports
# flag is true - the shape a registration must leave behind when the project
# entry had no prior explicit "Yes, allow" for external CLAUDE.md imports, so
# a spawn never manufactures that consent from an absent flag.
assert_trust_only_no_import_consent() {
  local store=$1 key=$2 msg=$3
  node -e '
    const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));
    const e=(j.projects||{})[process.argv[2]]||{};
    const trustOk = e.hasTrustDialogAccepted === true;
    const noImportConsent =
      e.hasClaudeMdExternalIncludesApproved !== true &&
      e.hasClaudeMdExternalIncludesWarningShown !== true;
    process.exit(trustOk && noImportConsent ? 0 : 1);
  ' "$store" "$key" || fail "$msg"
}

# A PATH carrying the tools the scope test needs but no node, so the
# missing-interpreter path is exercised without disturbing the real PATH.
node_free_path() {  # <case-dir> -> a bin dir holding the script's own tools but no node
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# --- secondmate homes -------------------------------------------------------

# seed_secondmate_home <home> <id> [shape]: the on-disk shape bin/fm-home-seed.sh
# leaves behind - the identity marker, the firstmate instance files, the four
# operational directories, and a charter for the launch to carry. "clone" (the
# default) is the standalone-clone home an explicit ~/fm-homes/<id> path
# produces, a primary checkout of the firstmate repo; "worktree" is the linked
# worktree a treehouse lease produces. Both shapes are real homes, so both must
# be trusted.
seed_secondmate_home() {
  local home=$1 id=$2 shape=${3:-clone} src
  case "$shape" in
    worktree)
      src="$home.src"
      fm_git_worktree "$src" "$home" "sm-$id"
      ;;
    *)
      mkdir -p "$home"
      fm_git_init_commit "$home"
      ;;
  esac
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# run_home_trust <config> <home> <id> [user-home]: invoke the secondmate-home
# mode against an isolated store.
run_home_trust() {
  local config=$1 home=$2 id=$3 user_home=${4:-$1}
  CLAUDE_CONFIG_DIR="$config" HOME="$user_home" "$TRUST" --secondmate-home "$home" "$id" 2>&1
}

# spawn_secondmate_claude <case-dir> <home> <id>: run a real --secondmate claude
# spawn against the isolated store at <case-dir>/claude-config, logging the
# launch to <case-dir>/launch.log. Echoes the spawn output.
spawn_secondmate_claude() {
  local case_dir=$1 home=$2 id=$3 primary fakebin
  primary="$case_dir/primary"
  mkdir -p "$case_dir/claude-config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$primary" claude
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$primary" "$home" "$fakebin" "$id" "$home" claude --secondmate
}

test_fresh_worktree_is_trusted() {
  local rec out
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  assert_trusted "$CONFIG/.claude.json" "$WT" "the worktree was not recorded as trusted"
  # The staged write is renamed into place, so no temporary store may survive it.
  [ -z "$(find "$CONFIG" -maxdepth 1 -name '.claude.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the config directory"
  pass "fm-claude-trust.sh: a fresh task worktree is trusted"
}

# The trust dialog is read only from the PROJECT-root entry, never the
# worktree entry (Claude Code's own git-root canonicalization collapses every
# linked worktree to its primary checkout for that check, with no
# ancestor-walk fallback the way the trust check has), so this proves both
# entries carry the trust flag after one registration. External-imports
# consent is a SEPARATE grant this script never manufactures: on a genuinely
# fresh project (no prior interactive answer at all) neither entry may carry
# hasClaudeMdExternalIncludesApproved or hasClaudeMdExternalIncludesWarningShown
# - see test_registration_carries_forward_existing_import_consent below for
# the case where the project already said yes.
test_fresh_worktree_also_trusts_the_project_root_without_import_consent() {
  local rec out
  rec=$(make_case fresh-project)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "$PROJ" "registration did not report the project root it also trusted"
  assert_trust_only_no_import_consent "$CONFIG/.claude.json" "$WT" \
    "the worktree entry either lost trust or gained unearned import consent"
  assert_trust_only_no_import_consent "$CONFIG/.claude.json" "$PROJ" \
    "the project-root entry either lost trust or gained unearned import consent"
  pass "fm-claude-trust.sh: a fresh registration trusts the project root without manufacturing import consent"
}

# The Greptile-flagged regression this pins: a project entry that already
# carries an explicit "Yes, allow" (hasClaudeMdExternalIncludesApproved===true)
# is exactly the standing consent this script may refresh - and refreshing it
# is what actually suppresses the external-imports dialog for the worker,
# since that check reads only the project entry (see the disassembly note at
# the top of fm-claude-trust.sh), never the worktree one.
test_registration_carries_forward_existing_import_consent() {
  local rec store
  rec=$(make_case import-consent-carried)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<JSON
{"hasCompletedOnboarding":true,"projects":{"$PROJ":{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":true,"hasClaudeMdExternalIncludesWarningShown":true}}}
JSON
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null || fail "registration failed against a project that already approved external imports"
  assert_all_flags "$store" "$WT" \
    "the worktree entry did not carry the refreshed import consent"
  assert_all_flags "$store" "$PROJ" \
    "the project-root entry lost its own already-granted import consent"
  pass "fm-claude-trust.sh: carries forward a project's already-granted import consent to the worktree entry"
}

# The project-root entry is the same store the launching user's interactive
# claude sessions read and write (it is usually already present, carrying
# unrelated keys such as allowedTools or MCP config), so preservation must
# hold there exactly as it holds for the worktree entry.
test_project_root_entry_preserves_other_keys() {
  local rec store
  rec=$(make_case project-preserve)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<JSON
{"hasCompletedOnboarding":true,"projects":{"$PROJ":{"hasTrustDialogAccepted":false,"allowedTools":["Read"]}}}
JSON
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing project entry"
  assert_trust_only_no_import_consent "$store" "$PROJ" \
    "the project-root entry did not gain trust, or gained unearned import consent it had never been asked for"
  assert_store_value "$store" '["Read"]' "the project entry's unrelated settings were lost" projects "$PROJ" allowedTools
  pass "fm-claude-trust.sh: preserves unrelated keys on the project-root entry"
}

# hasClaudeMdExternalIncludesApproved===false with WarningShown===true on the
# project-root entry is a human's explicit "No, disable" answer, recorded in the SAME store their own
# interactive sessions read. A spawn must never flip that to true on their
# behalf: doing so would grant every later interactive session in that
# checkout silent external-file inclusion the human declined. The whole
# registration refuses instead, and the store - including the worktree entry,
# which is never reached - must come back byte-for-byte unchanged.
test_project_root_entry_declined_external_imports_is_not_overridden() {
  local rec store out before after
  rec=$(make_case project-decline)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<JSON
{"hasCompletedOnboarding":true,"projects":{"$PROJ":{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":true,"allowedTools":["Read"]}}}
JSON
  before=$(cat "$store")
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "a project that already declined external imports must be refused: $out"
  assert_contains "$out" "declined external CLAUDE.md imports" \
    "the refusal did not name the declined-consent reason"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "the store was modified despite the refusal"
  assert_not_trusted "$store" "$WT" "the worktree entry was registered despite the refusal"
  pass "fm-claude-trust.sh: refuses to override a project's declined external-imports consent"
}

# Claude Code's own default project entry carries BOTH external-imports flags as
# false before the dialog was ever shown; answering the dialog either way sets
# hasClaudeMdExternalIncludesWarningShown to true. So false/false is "never
# asked", not "No, disable": it must be treated like an absent flag - trust
# registered, no import consent manufactured - rather than refused.
test_project_root_entry_default_import_flags_are_not_a_decline() {
  local rec store out
  rec=$(make_case project-default-flags)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<JSON
{"hasCompletedOnboarding":true,"projects":{"$PROJ":{"allowedTools":[],"mcpContextUris":[],"mcpServers":{},"enabledMcpjsonServers":[],"disabledMcpjsonServers":[],"hasTrustDialogAccepted":false,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":false}}}
JSON
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a never-asked default entry must not be refused as a decline: $out"
  assert_trust_only_no_import_consent "$store" "$WT" \
    "the worktree entry either lost trust or gained unearned import consent"
  assert_trust_only_no_import_consent "$store" "$PROJ" \
    "the project-root entry either lost trust or gained import consent it was never asked for"
  pass "fm-claude-trust.sh: a never-asked default external-imports pair is not treated as a decline"
}

test_registration_is_idempotent() {
  local rec out count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  count=$(trusted_paths "$CONFIG/.claude.json" | grep -Fxc "$WT")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the entry ($count)"
  pass "fm-claude-trust.sh: repeat registration is idempotent"
}

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "the primary checkout was trusted"
  pass "fm-claude-trust.sh: refuses the primary checkout"
}

# CDPATH redirects a relative `cd` operand, and `git rev-parse
# --git-common-dir` answers `.git` for a primary checkout. With a decoy on
# CDPATH that also holds a `.git`, the common dir resolved for both arguments
# once landed in the decoy instead, so the git-dir-vs-common-dir comparison
# disagreed and the primary checkout was trusted.
test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case cdpath)
  read_case "$rec"
  mkdir -p "$CASE_DIR/decoy/.git"
  export CDPATH="$CASE_DIR/decoy"
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "an exported CDPATH must not let the primary checkout through: $out"
  unset CDPATH
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "an exported CDPATH let the primary checkout be trusted"
  pass "fm-claude-trust.sh: an exported CDPATH cannot defeat the scope refusal"
}

# There is deliberately no case for an unresolvable git directory. The guard at
# that line is defence in depth and cannot be reached from outside the script:
# `real_dir`'s `cd` needs search permission on the git dir and git's own reads
# need the same permission on the same directory, so any mode that makes the
# resolution empty makes git fail first and the earlier "not inside a git
# repository" refusal fires instead. A case built with `chmod 000` passes
# identically with the guard deleted, which reports safety that is not there.

# Git exports GIT_DIR into every hook environment, so an inherited pair is
# ordinary. With GIT_DIR naming a linked worktree's git dir and GIT_WORK_TREE
# naming the primary checkout, git reports a toplevel that matches the argument
# and a git dir that differs from the common dir, so the primary checkout once
# satisfied the refusal on the caller's environment rather than on disk.
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case gitenv)
  read_case "$rec"
  GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  GIT_WORK_TREE=$PROJ
  export GIT_DIR GIT_WORK_TREE
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  set -- $?
  unset GIT_DIR GIT_WORK_TREE
  expect_code 1 "$1" "inherited git environment overrides must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "inherited git environment overrides let the primary checkout be trusted"
  pass "fm-claude-trust.sh: inherited git environment overrides cannot defeat the scope refusal"
}

test_home_directory_is_refused_even_when_it_is_a_worktree() {
  local rec out home
  rec=$(make_case home-worktree)
  read_case "$rec"
  # Make HOME itself a linked worktree of the project, so every git check
  # PASSES and only the home guard can refuse it. Without this the home case
  # would pass vacuously through the "not a git repository" branch.
  home="$CASE_DIR/home"
  git -C "$PROJ" worktree add --quiet -b wt-home "$home"
  out=$(run_trust "$CONFIG" "$home" "$PROJ" "$home")
  expect_code 1 $? "a home directory must be refused even as a valid worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$CONFIG/.claude.json" "$home" "the home directory was trusted"
  # Prove the git checks really would have accepted it, so the guard above is
  # what refused rather than an unrelated failure.
  out=$(run_trust "$CONFIG" "$home" "$PROJ" "$CASE_DIR/elsewhere-home")
  expect_code 0 $? "the same path must be acceptable once it is not HOME: $out"
  pass "fm-claude-trust.sh: refuses a home directory the git checks would accept"
}

# fm-spawn forwards CLAUDE_CONFIG_DIR onto the worker verbatim and the worker's
# pane starts in the task worktree, so a relative value names one store here and
# another there; registering into the first and reporting success would leave the
# worker meeting the dialog this control exists to remove.
test_relative_config_dir_is_refused() {
  local rec out
  rec=$(make_case relative-config)
  read_case "$rec"
  mkdir -p "$CASE_DIR/relhome"
  out=$(cd "$CASE_DIR/relhome" && CLAUDE_CONFIG_DIR=.claude-work HOME="$CASE_DIR/relhome" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative CLAUDE_CONFIG_DIR must be refused: $out"
  assert_contains "$out" ".claude-work" "the refusal did not name the relative value"
  assert_contains "$out" "relative" "the refusal did not say why the value is unusable"
  [ ! -e "$CASE_DIR/relhome/.claude-work/.claude.json" ] \
    || fail "a store was written under this process's cwd for a relative CLAUDE_CONFIG_DIR"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed for a store the worker may not read: $out" ;;
  esac
  pass "fm-claude-trust.sh: refuses a relative CLAUDE_CONFIG_DIR"
}

test_config_directory_is_refused() {
  local rec out
  rec=$(make_case config-dir)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$CONFIG" "$PROJ")
  expect_code 1 $? "the Claude config directory must be refused: $out"
  assert_contains "$out" "config directory" "the refusal did not name the config directory"
  pass "fm-claude-trust.sh: refuses the Claude config directory"
}

test_non_git_directory_is_refused() {
  local rec out plain
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$CONFIG" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$CONFIG/.claude.json" "$plain" "a plain directory was trusted"
  pass "fm-claude-trust.sh: refuses a directory that is not a git worktree"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a nonexistent path must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-claude-trust.sh: refuses a path that does not exist"
}

test_foreign_project_worktree_is_refused() {
  local rec out other other_wt
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(run_trust "$CONFIG" "$other_wt" "$PROJ")
  expect_code 1 $? "another project's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the project mismatch"
  assert_not_trusted "$CONFIG/.claude.json" "$other_wt" "a foreign project's worktree was trusted"
  pass "fm-claude-trust.sh: refuses a worktree belonging to another project"
}

test_worktree_subdirectory_is_refused() {
  local rec out sub
  rec=$(make_case subdir)
  read_case "$rec"
  sub="$WT/sub"
  mkdir -p "$sub"
  out=$(run_trust "$CONFIG" "$sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "is not a worktree root" "the refusal did not name the non-root path"
  assert_not_trusted "$CONFIG/.claude.json" "$sub" "a worktree subdirectory was trusted"
  pass "fm-claude-trust.sh: refuses a subdirectory of the worktree"
}

# The write target the external-imports flags depend on is only correct when
# it names the primary checkout. When <project> is itself a linked worktree
# (a secondmate home spawned from, rather than as, the primary checkout),
# writing the flags at that worktree's own path would land them at a key
# Claude Code's git-root canonicalization never reads, silently reproducing
# the bug this script exists to close - so this resolves the argument
# structurally to its primary checkout instead of refusing it.
test_project_argument_that_is_itself_a_worktree_resolves_to_the_primary_checkout() {
  local rec out proj_wt
  rec=$(make_case nested-project)
  read_case "$rec"
  proj_wt="$CASE_DIR/proj-wt"
  git -C "$PROJ" worktree add --quiet -b wt-proj-wt "$proj_wt"
  out=$(run_trust "$CONFIG" "$WT" "$proj_wt")
  expect_code 0 $? "a project argument that is itself a linked worktree must resolve to its primary checkout: $out"
  assert_contains "$out" "$PROJ" "the outcome did not name the resolved primary checkout"
  assert_trust_only_no_import_consent "$CONFIG/.claude.json" "$PROJ" \
    "the resolved primary checkout either lost trust or gained unearned import consent"
  assert_not_trusted "$CONFIG/.claude.json" "$proj_wt" \
    "the linked worktree argument itself was recorded as the project root"
  pass "fm-claude-trust.sh: a project argument that is itself a linked worktree resolves to the primary checkout"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<'JSON'
{"hasCompletedOnboarding":true,"numStartups":7,"projects":{"/other/path":{"hasTrustDialogAccepted":false,"allowedTools":["Bash"]}}}
JSON
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$store" "$WT" "the worktree was not recorded in an existing store"
  assert_store_value "$store" true "an unrelated top-level key was lost" hasCompletedOnboarding
  assert_store_value "$store" 7 "an unrelated top-level value was changed" numStartups
  assert_store_value "$store" '["Bash"]' "another project's settings were lost" projects /other/path allowedTools
  assert_not_trusted "$store" "/other/path" "another project's trust decision was flipped"
  pass "fm-claude-trust.sh: preserves unrelated store content"
}

test_symlinked_store_to_a_foreign_owned_target_is_refused() {
  local rec out
  rec=$(make_case symlink-foreign)
  read_case "$rec"
  # Root owns /etc/passwd as a regular file on both Linux and macOS, so it
  # stands in for a store resolving outside this user's ownership. Running as
  # root would own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-claude-trust.sh: refuses a store symlinked to another user's file (skipped as root)"
    return 0
  fi
  ln -s /etc/passwd "$CONFIG/.claude.json"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "a store resolving to another user's file must be refused: $out"
  assert_contains "$out" "not owned by this user" "the refusal did not name the ownership failure"
  assert_contains "$out" "/etc/passwd" "the refusal named the link rather than the resolved target it judged"
  pass "fm-claude-trust.sh: refuses a store symlinked to another user's file"
}

test_symlinked_store_to_an_owned_target_is_accepted() {
  local rec out target
  rec=$(make_case symlink-owned)
  read_case "$rec"
  # The dotfile-manager and synced-folder layout: the store is a symlink whose
  # target this user owns, so it must be followed rather than refused, and the
  # link must survive so the layout keeps working.
  target="$CASE_DIR/dotfiles/.claude.json"
  mkdir -p "$CASE_DIR/dotfiles"
  printf '%s\n' '{"numStartups":3,"projects":{}}' > "$target"
  ln -s "$target" "$CONFIG/.claude.json"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a store symlinked to this user's own file must be accepted: $out"
  assert_trusted "$target" "$WT" "the trust did not land in the symlink's target"
  [ -L "$CONFIG/.claude.json" ] || fail "the store symlink was replaced by a regular file instead of followed"
  assert_store_value "$target" 3 "an unrelated key in the target was lost" numStartups
  [ -z "$(find "$CASE_DIR/dotfiles" -maxdepth 1 -name '.claude.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left beside the resolved target"
  pass "fm-claude-trust.sh: follows a store symlink to this user's own file and leaves the link intact"
}

# Registering trust is what keeps a worker off the dialog, so a missing node
# refuses rather than degrades: proceeding would launch the worker straight into
# the dialog this control exists to remove.
test_missing_node_is_refused() {
  local rec out bindir
  rec=$(make_case no-node)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "a missing node must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  assert_not_trusted "$CONFIG/.claude.json" "$WT" "a worktree was trusted without an interpreter to write the store"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed although none could be written: $out" ;;
  esac
  pass "fm-claude-trust.sh: a missing node is refused rather than degraded"
}

# A missing interpreter must not soften the scope boundary, which
# git and the filesystem decide on their own.
test_scope_refusal_stays_fail_closed_without_node() {
  local rec out bindir
  rec=$(make_case no-node-refusal)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must still be refused without node: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-claude-trust.sh: a scope refusal stays fail-closed without node"
}

test_corrupt_store_fails_closed() {
  local rec out store
  rec=$(make_case corrupt)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  printf '%s\n' 'not json' > "$store"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not json' "$store" "the unparseable store was overwritten instead of left alone"
  pass "fm-claude-trust.sh: refuses an unparseable store and leaves it untouched"
}

# A refused registration must abort the spawn before any per-task state exists.
# The busy-state generation is armed after it, and nothing between that arm and
# the far-later rollback arming can clear it, so a record stranded here would
# read as a task busy forever for an id that has no meta at all. The per-task
# temp root /tmp/fm-<id> is the other resource created on the way to the arm, and
# nothing removes it either: fm-teardown finds it through tasktmp= in the task's
# meta, which a refused spawn never publishes. The id carries this process's pid
# so the temp-root assertion reads only this run's path.
test_refused_spawn_leaves_no_task_state() {
  local case_dir home proj wt config fakebin out id
  case_dir="$TMP_ROOT/refused-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  id="refusedspawn$$"
  # Root owns /etc/passwd, so a store resolving to it is refused as another
  # user's file. Running as root would own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-spawn.sh: a trust-refused claude spawn leaves no task state (skipped as root)"
    return 0
  fi
  mkdir -p "$config"
  ln -s /etc/passwd "$config/.claude.json"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-refused
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose trust registration is refused must fail: $out"
  assert_contains "$out" "workspace trust" "the spawn did not report the trust refusal"
  [ ! -e "$home/state/$id.busy-state" ] \
    || fail "a refused spawn stranded a busy record nothing can clear"
  [ ! -e "$home/state/$id.busy-gen" ] \
    || fail "a refused spawn stranded a busy generation nothing can clear"
  [ ! -e "/tmp/fm-$id" ] \
    || { rm -rf "/tmp/fm-$id"; fail "a refused spawn stranded a temp root no teardown can find"; }
  pass "fm-spawn.sh: a trust-refused claude spawn leaves no task state behind"
}

# The spawn half: a real fm-spawn of a claude worker must pre-register the
# worktree AND deliver the launch command carrying the brief, with no dialog to
# answer and no human in the loop.
test_claude_spawn_pretrusts_its_worktree_and_reaches_the_brief() {
  local case_dir home proj wt config fakebin launch_log out
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  launch_log="$case_dir/launch.log"
  mkdir -p "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" trustspawn
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" trustspawn "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the claude spawn must succeed: $out"
  assert_trusted "$config/.claude.json" "$wt" \
    "the claude spawn did not pre-register trust for its worktree"
  assert_present "$launch_log" "the claude spawn sent no launch command"
  assert_grep 'claude --dangerously-skip-permissions' "$launch_log" \
    "the launch command was not the claude worker launch"
  assert_grep "$home/data/trustspawn/launch-brief.md" "$launch_log" \
    "the launch command did not carry the brief the worker must read"
  # The worker must read the SAME store the registration wrote, or the trust
  # would land somewhere the pane never looks.
  assert_grep "CLAUDE_CONFIG_DIR='$config'" "$launch_log" \
    "the launch command did not point the worker at the store that was trusted"
  pass "fm-spawn.sh: a claude spawn pre-trusts its worktree and launches with the brief"
}

# A secondmate home is the second directory a claude launch starts in, and it is
# as unseen by Claude as a fresh worktree. The standalone-clone shape is the one
# that wedged in production: the trust step was skipped for every secondmate, so
# nothing was registered and the pane stopped on the dialog before it read its
# charter.
test_secondmate_standalone_clone_home_is_trusted() {
  local case_dir home out
  case_dir="$TMP_ROOT/sm-clone-spawn"
  home="$case_dir/fm-homes/nomistakes-n1"
  seed_secondmate_home "$home" nomistakes-n1 clone
  out=$(spawn_secondmate_claude "$case_dir" "$home" nomistakes-n1)
  expect_code 0 $? "a claude secondmate spawn into a standalone-clone home must succeed: $out"
  assert_trusted "$case_dir/claude-config/.claude.json" "$home" \
    "the claude secondmate spawn did not pre-register trust for its standalone-clone home"
  assert_present "$case_dir/launch.log" "the claude secondmate spawn sent no launch command"
  assert_grep 'claude --dangerously-skip-permissions' "$case_dir/launch.log" \
    "the launch command was not the claude secondmate launch"
  assert_grep "$home/data/charter.md" "$case_dir/launch.log" \
    "the launch command did not carry the charter the secondmate must read"
  # The pane must read the SAME store the registration wrote, or the trust would
  # land somewhere it never looks and the dialog would appear anyway.
  assert_grep "CLAUDE_CONFIG_DIR='$case_dir/claude-config'" "$case_dir/launch.log" \
    "the launch command did not point the secondmate at the store that was trusted"
  pass "fm-spawn.sh: a claude secondmate spawn pre-trusts a standalone-clone home"
}

# The other seeded shape, a treehouse-leased linked worktree. It must be trusted
# through the same seed evidence rather than incidentally, so the registration
# does not depend on which shape the home happens to have.
test_secondmate_leased_worktree_home_is_trusted() {
  local case_dir home out
  case_dir="$TMP_ROOT/sm-leased-spawn"
  home="$case_dir/leased/home"
  mkdir -p "$case_dir/leased"
  seed_secondmate_home "$home" leased-n1 worktree
  out=$(spawn_secondmate_claude "$case_dir" "$home" leased-n1)
  expect_code 0 $? "a claude secondmate spawn into a leased worktree home must succeed: $out"
  assert_trusted "$case_dir/claude-config/.claude.json" "$home" \
    "the claude secondmate spawn did not pre-register trust for its leased worktree home"
  pass "fm-spawn.sh: a claude secondmate spawn pre-trusts a leased worktree home"
}

# The seed is the whole security boundary for home-level trust, so every path
# that is not a home seeded for THIS secondmate is refused and left untrusted.
# Each row drives one structural property apart from a genuine home.
test_secondmate_home_trust_refuses_everything_unseeded() {
  local case_dir config home target out
  case_dir="$TMP_ROOT/sm-refusals"
  config="$case_dir/claude-config"
  mkdir -p "$config"

  # A plain directory: no marker at all.
  target="$case_dir/plain"
  mkdir -p "$target"
  out=$(run_home_trust "$config" "$target" plain-n1)
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "no .fm-secondmate-home marker" "the refusal did not name the missing marker"
  assert_not_trusted "$config/.claude.json" "$target" "a plain directory was trusted"

  # A firstmate checkout that was never seeded as a secondmate home: every other
  # structural signal matches and only the marker is missing.
  target="$case_dir/checkout"
  seed_secondmate_home "$target" checkout-n1 clone
  rm -f "$target/.fm-secondmate-home"
  out=$(run_home_trust "$config" "$target" checkout-n1)
  expect_code 1 $? "an unseeded firstmate checkout must be refused: $out"
  assert_contains "$out" "no .fm-secondmate-home marker" "the refusal did not name the missing marker"
  assert_not_trusted "$config/.claude.json" "$target" "an unseeded firstmate checkout was trusted"

  # A home seeded for a DIFFERENT secondmate: one home's trust must not be
  # granted while spawning another id.
  target="$case_dir/other-mate"
  seed_secondmate_home "$target" other-n1 clone
  out=$(run_home_trust "$config" "$target" wanted-n1)
  expect_code 1 $? "a home marked for another secondmate must be refused: $out"
  assert_contains "$out" "other-n1" "the refusal did not name the id the home is marked for"
  assert_not_trusted "$config/.claude.json" "$target" "a home marked for another secondmate was trusted"

  # A marker that is a symlink: another file's bytes must not stand in for the
  # seed, even when they read as the right id.
  target="$case_dir/linked-marker"
  seed_secondmate_home "$target" linked-n1 clone
  printf 'linked-n1\n' > "$case_dir/planted-id"
  ln -sf "$case_dir/planted-id" "$target/.fm-secondmate-home"
  out=$(run_home_trust "$config" "$target" linked-n1)
  expect_code 1 $? "a symlinked marker must be refused: $out"
  assert_contains "$out" "symlink" "the refusal did not name the symlinked marker"
  assert_not_trusted "$config/.claude.json" "$target" "a home whose marker is a symlink was trusted"

  # An operational directory that escapes the home: the home's own working
  # surface must stay inside it.
  target="$case_dir/escaping"
  seed_secondmate_home "$target" escaping-n1 clone
  rm -rf "$target/projects"
  mkdir -p "$case_dir/elsewhere"
  ln -s "$case_dir/elsewhere" "$target/projects"
  out=$(run_home_trust "$config" "$target" escaping-n1)
  expect_code 1 $? "a home whose operational directory escapes it must be refused: $out"
  assert_contains "$out" "outside the home" "the refusal did not name the escaping directory"
  assert_not_trusted "$config/.claude.json" "$target" "a home whose projects/ escapes it was trusted"

  # The user's own home directory, seeded to prove the marker alone cannot carry
  # it: HOME is refused in this mode exactly as it is for a worktree.
  target="$case_dir/user-home"
  seed_secondmate_home "$target" userhome-n1 clone
  out=$(run_home_trust "$config" "$target" userhome-n1 "$target")
  expect_code 1 $? "the user's home directory must be refused: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$config/.claude.json" "$target" "the user's home directory was trusted"
  # Prove the seed really would have been accepted, so the guard above is what
  # refused rather than an unrelated failure.
  out=$(run_home_trust "$config" "$target" userhome-n1 "$case_dir/elsewhere-home")
  expect_code 0 $? "the same seeded home must be accepted once it is not HOME: $out"

  pass "fm-claude-trust.sh: home-level trust is refused for everything but a home seeded for this secondmate"
}

# A secondmate home is not a linked worktree, so worktree mode must keep
# refusing it rather than quietly widening to cover the new case.
test_worktree_mode_still_refuses_a_secondmate_home() {
  local case_dir config home out
  case_dir="$TMP_ROOT/sm-wrong-mode"
  config="$case_dir/claude-config"
  home="$case_dir/home"
  mkdir -p "$config"
  seed_secondmate_home "$home" mode-n1 clone
  out=$(run_trust "$config" "$home" "$home")
  expect_code 1 $? "worktree mode must still refuse a standalone-clone home: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$config/.claude.json" "$home" "worktree mode trusted a standalone-clone home"
  pass "fm-claude-trust.sh: worktree mode still refuses a secondmate home"
}

# The fail-closed half for secondmates: when the home's trust genuinely cannot be
# recorded, the spawn must refuse rather than launch a pane that would wedge on
# the dialog. This is the guard that never fired while the step was skipped.
test_secondmate_spawn_fails_closed_when_home_trust_cannot_be_recorded() {
  local case_dir home out
  case_dir="$TMP_ROOT/sm-failclosed"
  home="$case_dir/fm-homes/failclosed-n1"
  # Root owns /etc/passwd, so a store resolving to it is refused as another
  # user's file. Running as root would own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-spawn.sh: a claude secondmate spawn refuses when home trust cannot be recorded (skipped as root)"
    return 0
  fi
  seed_secondmate_home "$home" failclosed-n1 clone
  mkdir -p "$case_dir/claude-config"
  ln -s /etc/passwd "$case_dir/claude-config/.claude.json"
  out=$(spawn_secondmate_claude "$case_dir" "$home" failclosed-n1)
  expect_code 1 $? "a secondmate spawn whose trust registration is refused must fail: $out"
  assert_contains "$out" "workspace trust" "the spawn did not report the trust refusal"
  assert_absent "$case_dir/launch.log" "a secondmate was launched into a home whose trust could not be recorded"
  pass "fm-spawn.sh: a claude secondmate spawn refuses when home trust cannot be recorded"
}

# --- the external-imports gate ----------------------------------------------
#
# Registering trust removes the FIRST dialog a claude launch meets. The second -
# "Allow external CLAUDE.md file imports?" - is deliberately not answered here,
# and before this gate existed nothing said so: the spawn went ahead and the
# worker stopped at a modal firstmate cannot answer, reaching supervision as an
# ordinary stale wake with nothing naming the cause. These cases pin both halves
# of the replacement: a launch that WOULD meet it is refused with the imports and
# the one-time human approval named, and a launch that would not is never held up
# by a scan guessing wrongly.
#
# The trigger these cases encode was reproduced against the real Claude Code
# (2.1.267) rather than assumed; the script's own header records that
# reproduction and what it deliberately does not claim.

# import_case <name>: a project, a worktree, and an isolated store, plus a file
# OUTSIDE the worktree that a memory chain can reach for. Echoes the make_case
# row so the existing readers work unchanged.
import_case() {
  local row
  row=$(make_case "$1")
  read_case "$row"
  printf 'outside\n' > "$CASE_DIR/outside.md"
  printf '%s\n' "$row"
}

# commit_project_memory <project> <content>: land a CLAUDE.md as real committed
# project content. fm-spawn.sh refuses a pooled worktree holding uncommitted
# work and then refreshes that worktree onto the fetched default branch, so a
# file written into the worktree by hand is either a refusal or discarded before
# the trust step ever runs. It has to reach the fixture's origin to survive.
commit_project_memory() {
  printf '%s' "$2" > "$1/CLAUDE.md"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm "memory" >/dev/null 2>&1
  git -C "$1" push -q origin HEAD >/dev/null 2>&1
}

# seed_import_approval <store> <project>: the record Claude Code writes when the
# human answered "Yes, allow external imports" for that project once.
seed_import_approval() {
  node -e '
    const fs=require("node:fs");
    const [store,key]=process.argv.slice(1);
    const j=fs.existsSync(store)?JSON.parse(fs.readFileSync(store,"utf8")):{};
    j.projects=j.projects||{};
    j.projects[key]={...(j.projects[key]||{}),hasClaudeMdExternalIncludesApproved:true,hasClaudeMdExternalIncludesWarningShown:true};
    fs.writeFileSync(store,JSON.stringify(j,null,2)+"\n");
  ' "$1" "$2"
}

test_external_import_with_no_consent_blocks_the_launch() {
  local row out status
  row=$(import_case imports-block)
  read_case "$row"
  printf '# p\n\n@%s/outside.md\n' "$CASE_DIR" > "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 3 "$status" "an unapproved external import must block the launch: $out"
  assert_contains "$out" "Allow external CLAUDE.md file imports?" \
    "the refusal did not name the dialog the worker would stop at"
  assert_contains "$out" "$CASE_DIR/outside.md" \
    "the refusal did not name the import that raises the dialog"
  assert_contains "$out" "$PROJ" \
    "the refusal did not name the project whose one-time approval clears it"
  # The registration itself still happened: the trust dialog is a separate gate
  # and leaving it unregistered would only add a second wedge behind this one.
  assert_trusted "$CONFIG/.claude.json" "$WT" \
    "a blocked launch must still leave the worktree's workspace trust registered"
  # And it must NOT have manufactured the consent it just refused to assume.
  assert_trust_only_no_import_consent "$CONFIG/.claude.json" "$PROJ" \
    "the gate wrote the external-import consent instead of asking for it"
  pass "fm-claude-trust.sh: an unapproved external CLAUDE.md import blocks the launch and names the one-time approval"
}

test_external_import_with_standing_consent_is_cleared() {
  local row out status
  row=$(import_case imports-approved)
  read_case "$row"
  printf '# p\n\n@%s/outside.md\n' "$CASE_DIR" > "$WT/CLAUDE.md"
  seed_import_approval "$CONFIG/.claude.json" "$PROJ"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "a project the human already approved must launch: $out"
  assert_contains "$out" "external imports: clear" \
    "the gate did not report the standing approval as clear"
  # A verdict that rests on Claude Code's own record does not rest on the scan,
  # so it must not carry the scan's unexamined-dimension caveat: no dialog can
  # render here whatever any chain holds, and a caveat with no doubt behind it
  # is what teaches an operator to ignore the one that has.
  assert_not_contains "$out" "were not examined" \
    "a clear decided by the vendor's own record carried the scan's unexamined-dimension caveat"
  assert_all_flags "$CONFIG/.claude.json" "$PROJ" \
    "the standing approval was not carried forward onto the project entry"
  pass "fm-claude-trust.sh: a project carrying the human's standing approval launches with the imports cleared"
}

test_imports_that_stay_inside_the_worktree_do_not_block() {
  local row out status
  row=$(import_case imports-inside)
  read_case "$row"
  printf '# p\n\n@AGENTS.md\n' > "$WT/CLAUDE.md"
  printf '@nested/deep.md\n' > "$WT/AGENTS.md"
  mkdir -p "$WT/nested"
  printf 'deep\n' > "$WT/nested/deep.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "a chain that stays inside the worktree must not block: $out"
  assert_contains "$out" "external imports: clear" \
    "the gate did not clear a chain that never leaves the worktree"
  pass "fm-claude-trust.sh: a memory chain that stays inside the worktree never blocks a launch"
}

# The dialog fires on what Claude Code LOADS, so a documented example of the
# import syntax must not read as an import. A scan that cannot tell the two apart
# would refuse dispatch on any project whose CLAUDE.md explains the syntax.
test_import_syntax_inside_a_code_fence_is_not_an_import() {
  local row out status tick fence
  row=$(import_case imports-fenced)
  read_case "$row"
  tick=$(printf '\140')
  fence="$tick$tick$tick"
  {
    printf '# p\n\n'
    printf 'Write an import like this:\n\n'
    printf '%s\n@%s/outside.md\n%s\n\n' "$fence" "$CASE_DIR" "$fence"
    printf 'or inline as %s@%s/outside.md%s.\n' "$tick" "$CASE_DIR" "$tick"
  } > "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "an example of the syntax must not read as an import: $out"
  pass "fm-claude-trust.sh: import syntax shown in code does not block a launch"
}

# The other markdown forms that mean "this is not an instruction". A four-space
# indented example and an HTML comment are as much non-content as a fenced block,
# so an @path in either must not refuse a dispatch - this repository's own
# CLAUDE.md opens with a comment, and commenting out a stale outside import is
# the ordinary way to retire one.
test_import_syntax_in_an_indented_block_or_an_html_comment_is_not_an_import() {
  local row out status
  row=$(import_case imports-noncontent)
  read_case "$row"
  {
    printf '<!-- retired: @%s/outside.md -->\n' "$CASE_DIR"
    printf '# p\n\nExample:\n\n'
    printf '    @%s/outside.md\n\n' "$CASE_DIR"
    printf '<!--\n@%s/outside.md\n-->\n' "$CASE_DIR"
  } > "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "an indented example or a commented-out import must not refuse a dispatch: $out"
  assert_contains "$out" "external imports: clear" \
    "markdown non-content was read as a loaded import"
  pass "fm-claude-trust.sh: an indented example and an HTML comment are not read as imports"
}

test_a_transitive_import_out_of_the_worktree_blocks() {
  local row out status
  row=$(import_case imports-transitive)
  read_case "$row"
  printf '# p\n\n@AGENTS.md\n' > "$WT/CLAUDE.md"
  printf '@%s/outside.md\n' "$CASE_DIR" > "$WT/AGENTS.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 3 "$status" "an import reached through another file must block: $out"
  assert_contains "$out" "$WT/AGENTS.md" \
    "the refusal did not name the file that reaches outside the worktree"
  pass "fm-claude-trust.sh: an external import reached through another memory file blocks the launch"
}

test_claude_local_md_is_scanned_too() {
  local row out status
  row=$(import_case imports-local)
  read_case "$row"
  printf '@%s/outside.md\n' "$CASE_DIR" > "$WT/CLAUDE.local.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 3 "$status" "CLAUDE.local.md is a memory file too and must be scanned: $out"
  assert_contains "$out" "$WT/CLAUDE.local.md" \
    "the refusal did not name CLAUDE.local.md as the source of the import"
  pass "fm-claude-trust.sh: CLAUDE.local.md is scanned for external imports like CLAUDE.md"
}

# What the scan cannot resolve it must SAY it cannot resolve. An import pointing
# outside the worktree at a file that is not there was never measured against the
# real product, so calling it clear would be exactly the silent pass this gate
# exists to remove - and calling it blocking would veto dispatch on a guess.
test_an_unresolvable_external_import_is_reported_as_undecided() {
  local row out status
  row=$(import_case imports-unknown)
  read_case "$row"
  printf '# p\n\n@%s/not-there.md\n' "$CASE_DIR" > "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 4 "$status" "an unresolvable external import must be reported as undecided: $out"
  assert_contains "$out" "external imports: unknown" \
    "the gate did not report that it could not decide"
  assert_contains "$out" "not-there.md" \
    "the undecided report did not name the import it could not resolve"
  pass "fm-claude-trust.sh: an import it cannot resolve is reported as undecided, not passed in silence"
}

# The scan follows as far as Claude Code documents it loads, and no further. What
# matters is both halves: an external import inside that depth is caught, and a
# chain that runs past it is REPORTED as unfollowed rather than called clean,
# because a chain this stopped reading is exactly where a missed import would
# put a worker back on the dialog with nobody warned.
# The depth was measured against the product hop by hop, and both sides of the
# boundary are pinned here, because a bound that is right on one side and wrong
# on the other is how the same hop ends up "never loaded" for an in-tree target
# and "loads and shows the dialog" for an outside one. This side: the outside
# file is the FIFTH file in the chain - the last one the product loads - and the
# dialog renders there, so it must refuse the dispatch.
test_an_external_import_at_the_last_loaded_file_still_blocks() {
  local row out status i
  row=$(import_case imports-depth)
  read_case "$row"
  printf '# p\n\n@link1.md\n' > "$WT/CLAUDE.md"
  for i in 1 2; do
    printf '@link%s.md\n' "$((i + 1))" > "$WT/link$i.md"
  done
  printf '@%s/outside.md\n' "$CASE_DIR" > "$WT/link3.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 3 "$status" "an outside import at the last file the product loads must be caught: $out"
  assert_contains "$out" "$WT/link3.md" \
    "the refusal did not name the file that reaches outside the loaded chain"
  pass "fm-claude-trust.sh: an external import at the last loaded memory file blocks the launch"
}

# The other side of the same measured boundary: an import written ONE file past
# the last loaded one is not followed by the product, so an outside target there
# raises no dialog and must not refuse a dispatch - and it is not `unknown`
# either, because this is measured rather than assumed. The clear line has to
# name the depth it followed, so "clear" never reads as an unbounded claim.
test_an_external_import_one_file_past_the_loaded_chain_does_not_block() {
  local row out status i
  row=$(import_case imports-deeper)
  read_case "$row"
  printf '# p\n\n@link1.md\n' > "$WT/CLAUDE.md"
  for i in 1 2 3; do
    printf '@link%s.md\n' "$((i + 1))" > "$WT/link$i.md"
  done
  printf '@%s/outside.md\n' "$CASE_DIR" > "$WT/link4.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "an import the product never loads must neither refuse nor warn: $out"
  assert_contains "$out" "external imports: clear" \
    "an edge past the measured depth was not cleared"
  assert_contains "$out" "5 memory files Claude Code was measured to load" \
    "the clear verdict did not name the depth it followed the chain to"
  pass "fm-claude-trust.sh: an external import one file past the loaded chain does not block a launch"
}

# A clear verdict is a report of what was examined, not a blanket all-clear. The
# project memory chain of the launch directory is what this scans; the
# operator's own user-global chain is deliberately not, and the line has to say
# so rather than let silence read as a check that happened.
test_the_clear_verdict_names_what_it_scanned_and_what_it_did_not() {
  local row out status
  row=$(import_case imports-clear-wording)
  read_case "$row"
  printf '# p\n\n@AGENTS.md\n' > "$WT/CLAUDE.md"
  printf 'inside\n' > "$WT/AGENTS.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "a chain that stays inside the worktree must not block: $out"
  assert_contains "$out" "project memory chain under $WT" \
    "the clear verdict did not name the chain it actually examined"
  assert_contains "$out" "user-global ~/.claude memory chain" \
    "the clear verdict did not say which chain it never looked at"
  assert_contains "$out" "directories above $WT were not examined" \
    "the clear verdict did not say that ancestor memory files were never looked at either"
  pass "fm-claude-trust.sh: a clear verdict names the chain it scanned and the ones it did not"
}

# An @import written in a sentence carries that sentence's punctuation, and the
# spec with the punctuation glued on names no file while the stripped spelling
# does. Whether Claude Code strips it was never measured, so this must report
# the case with both spellings rather than refuse a dispatch on the vendor's
# parse - a refusal from a guess is the failure this gate exists to remove.
test_an_external_import_ending_a_sentence_is_reported_not_refused() {
  local row out status
  row=$(import_case imports-punctuation)
  read_case "$row"
  printf '# p\n\nShared house rules live in @%s/outside.md.\n' "$CASE_DIR" > "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 4 "$status" "a punctuated import must be reported, never refused on an unmeasured parse: $out"
  assert_contains "$out" "external imports: unknown" \
    "the gate did not report that it could not decide the punctuated spec"
  assert_contains "$out" "$CASE_DIR/outside.md." \
    "the report did not name the spec as it was actually written"
  assert_contains "$out" "whether Claude Code strips that punctuation was not measured" \
    "the report did not say which vendor behaviour it could not verify"
  pass "fm-claude-trust.sh: an import ending a sentence is reported with both spellings, not refused"
}

# The same class in the other direction: a parenthesised in-tree import is not
# followed either, because following it would rest a later verdict on the same
# unmeasured parse - so it is reported as a piece of chain left unread.
test_a_parenthesised_in_tree_import_is_reported_unfollowed() {
  local row out status
  row=$(import_case imports-parens)
  read_case "$row"
  printf '# p\n\nThe house rules (see @AGENTS.md) apply here.\n' > "$WT/CLAUDE.md"
  printf '@%s/outside.md\n' "$CASE_DIR" > "$WT/AGENTS.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 4 "$status" "a parenthesised import must be reported, not silently followed or refused: $out"
  assert_contains "$out" "$WT/AGENTS.md" \
    "the report did not name the file the stripped spelling would reach"
  pass "fm-claude-trust.sh: a parenthesised in-tree import is reported as unfollowed"
}

# And the case that must stay quiet: a punctuated spelling of a file the chain
# ALREADY read leaves nothing unread, so there is nothing to report. This repo's
# own memory files carry exactly that shape, and reporting it would put every
# dispatch here on a permanent warning no operator could act on.
test_a_punctuated_spelling_of_an_already_scanned_file_stays_clear() {
  local row out status
  row=$(import_case imports-punctuation-seen)
  read_case "$row"
  printf '# p\n\n@AGENTS.md\n' > "$WT/CLAUDE.md"
  printf 'The rules apply to this file too (see @AGENTS.md).\n' > "$WT/AGENTS.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "a punctuated spelling of an already-scanned file must not raise a warning: $out"
  assert_contains "$out" "external imports: clear" \
    "a chain that was read in full was not cleared"
  pass "fm-claude-trust.sh: a punctuated spelling of an already-scanned file stays clear"
}

# Claude Code loads memory FILES. An @import naming a real DIRECTORY outside the
# worktree loads nothing and can raise no dialog, so refusing the dispatch over
# prose like "See @../outer for details." would block a launch that was fine.
test_an_import_naming_an_outside_directory_does_not_block() {
  local row out status
  row=$(import_case imports-directory)
  read_case "$row"
  mkdir -p "$CASE_DIR/outer"
  printf '# p\n\nSee @%s/outer for details.\n' "$CASE_DIR" > "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 0 "$status" "an import naming a directory must not block a launch: $out"
  assert_contains "$out" "external imports: clear" \
    "a directory target was treated as a loadable memory file"
  pass "fm-claude-trust.sh: an import naming a directory outside the worktree does not block a launch"
}

# A CLAUDE.md that sits in the worktree but resolves out of it is a loaded file
# outside the tree without being an import of one. That was never measured
# against the product, so it must be reported rather than decided either way.
test_a_memory_file_symlinked_out_of_the_worktree_is_reported() {
  local row out status
  row=$(import_case imports-symlink)
  read_case "$row"
  printf '# shared\n' > "$CASE_DIR/shared-CLAUDE.md"
  ln -s "$CASE_DIR/shared-CLAUDE.md" "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 4 "$status" "a memory file resolving out of the worktree must be reported: $out"
  assert_contains "$out" "$CASE_DIR/shared-CLAUDE.md" \
    "the report did not name the file the memory path resolves to"
  pass "fm-claude-trust.sh: a memory file resolving outside the worktree is reported, not assumed"
}

# The same file, read rather than skipped: a shared CLAUDE.md carrying its own
# outside import is a DEFINITE dialog, and stopping at the symlink would report
# `unknown`, let the spawn warn and launch, and put the worker on the modal.
test_a_memory_file_symlinked_out_of_the_worktree_is_still_read() {
  local row out status
  row=$(import_case imports-symlink-chain)
  read_case "$row"
  printf '# shared\n\n@%s/outside.md\n' "$CASE_DIR" > "$CASE_DIR/shared-CLAUDE.md"
  ln -s "$CASE_DIR/shared-CLAUDE.md" "$WT/CLAUDE.md"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ") && status=0 || status=$?
  expect_code 3 "$status" "an outside-resolving memory file that imports outside must block: $out"
  assert_contains "$out" "$CASE_DIR/outside.md" \
    "the refusal did not name the import the shared memory file reaches for"
  pass "fm-claude-trust.sh: a memory file resolving outside the worktree is still read for its own imports"
}

# A secondmate home is the other directory a claude launch starts in, and its own
# memory chain raises the same dialog.
test_secondmate_home_external_import_blocks_the_launch() {
  local case_dir home config out status
  case_dir="$TMP_ROOT/imports-secondmate"
  home="$case_dir/home"
  config="$case_dir/claude-config"
  mkdir -p "$case_dir" "$config"
  seed_secondmate_home "$home" smimports
  printf 'outside\n' > "$case_dir/outside.md"
  printf '@%s/outside.md\n' "$case_dir" > "$home/CLAUDE.md"
  out=$(CLAUDE_CONFIG_DIR="$config" HOME="$config" \
    "$TRUST" --secondmate-home "$home" smimports 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "a secondmate home reaching outside itself must block: $out"
  assert_trusted "$config/.claude.json" "$home" \
    "a blocked secondmate launch must still leave the home's workspace trust registered"
  pass "fm-claude-trust.sh: a secondmate home whose memory chain reaches outside it blocks the launch"
}

# The consent entry the scan reads has to be the entry Claude Code reads. A home
# that is a linked worktree in a layout this cannot resolve to a primary checkout
# - a worktree of a BARE repository, where the common dir's parent is no checkout
# at all - is exactly that case: the store lookup would answer about the wrong
# key, so a standing approval would be missed and the launch refused over an
# import the human already allowed. It must report that it could not decide.
test_secondmate_home_with_an_underivable_consent_entry_is_undecided() {
  local case_dir home config bare src out status
  case_dir="$TMP_ROOT/imports-secondmate-underivable"
  home="$case_dir/home"
  config="$case_dir/claude-config"
  src="$case_dir/src"
  bare="$case_dir/bare.git"
  mkdir -p "$case_dir" "$config"
  fm_git_init_commit "$src"
  git clone --quiet --bare "$src" "$bare" >/dev/null 2>&1
  git -C "$bare" worktree add --quiet -b sm-underivable "$home" >/dev/null 2>&1
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'smunderiv\n' > "$home/.fm-secondmate-home"
  printf 'outside\n' > "$case_dir/outside.md"
  printf '@%s/outside.md\n' "$case_dir" > "$home/CLAUDE.md"
  out=$(CLAUDE_CONFIG_DIR="$config" HOME="$config" \
    "$TRUST" --secondmate-home "$home" smunderiv 2>&1) && status=0 || status=$?
  expect_code 4 "$status" "a home whose consent entry cannot be identified must be reported as undecided: $out"
  assert_contains "$out" "external imports: unknown" \
    "the gate did not report that it could not decide"
  assert_contains "$out" "primary checkout could not be resolved" \
    "the report did not name the entry it could not identify"
  assert_trusted "$config/.claude.json" "$home" \
    "an undecided secondmate launch must still leave the home's workspace trust registered"
  pass "fm-claude-trust.sh: a secondmate home whose consent entry cannot be identified is reported as undecided"
}

# The spawn half. A launch the gate can see coming must be refused before any
# per-task state exists, the same way a refused registration is, so the captain
# gets one concrete thing to do instead of a pane that looks alive and is not.
test_spawn_refuses_a_launch_that_would_meet_the_imports_dialog() {
  local case_dir home proj wt config fakebin out id
  case_dir="$TMP_ROOT/imports-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  id="importspawn$$"
  mkdir -p "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-imports
  printf 'outside\n' > "$case_dir/outside.md"
  commit_project_memory "$proj" "$(printf '# p\n\n@%s/outside.md\n' "$case_dir")"
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn into a launch that meets the imports dialog must fail: $out"
  assert_contains "$out" "external CLAUDE.md imports dialog" \
    "the spawn did not report which dialog it refused over"
  assert_contains "$out" "Yes, allow external imports" \
    "the spawn did not carry through the one-time approval that clears it"
  [ ! -e "$home/state/$id.busy-state" ] \
    || fail "a refused spawn stranded a busy record nothing can clear"
  [ ! -e "/tmp/fm-$id" ] \
    || { rm -rf "/tmp/fm-$id"; fail "a refused spawn stranded a temp root no teardown can find"; }
  pass "fm-spawn.sh: a claude spawn that would meet the external-imports dialog is refused before any task state exists"
}

# The undecided case must not veto dispatch: a check that cannot answer says so
# and steps aside, because holding the fleet on an unresolvable scan would be a
# worse failure than the dialog it was looking for.
test_spawn_launches_and_warns_when_the_imports_verdict_is_undecided() {
  local case_dir home proj wt config fakebin launch_log out id
  case_dir="$TMP_ROOT/imports-spawn-unknown"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  launch_log="$case_dir/launch.log"
  id="importwarn$$"
  mkdir -p "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-imports-unknown
  commit_project_memory "$proj" "$(printf '# p\n\n@%s/not-there.md\n' "$case_dir")"
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "an undecided imports verdict must not veto the spawn: $out"
  assert_contains "$out" "without having decided" \
    "the spawn launched without saying what it could not decide"
  assert_present "$launch_log" "the spawn sent no launch command"
  pass "fm-spawn.sh: an undecided external-imports verdict warns and still launches"
}

test_fresh_worktree_is_trusted
test_fresh_worktree_also_trusts_the_project_root_without_import_consent
test_registration_carries_forward_existing_import_consent
test_project_root_entry_preserves_other_keys
test_project_root_entry_declined_external_imports_is_not_overridden
test_project_root_entry_default_import_flags_are_not_a_decline

test_registration_is_idempotent
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal
test_home_directory_is_refused_even_when_it_is_a_worktree
test_config_directory_is_refused
test_relative_config_dir_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_foreign_project_worktree_is_refused
test_worktree_subdirectory_is_refused
test_project_argument_that_is_itself_a_worktree_resolves_to_the_primary_checkout
test_unrelated_store_content_is_preserved
test_symlinked_store_to_a_foreign_owned_target_is_refused
test_symlinked_store_to_an_owned_target_is_accepted
test_corrupt_store_fails_closed
test_missing_node_is_refused
test_scope_refusal_stays_fail_closed_without_node
test_claude_spawn_pretrusts_its_worktree_and_reaches_the_brief
test_refused_spawn_leaves_no_task_state
test_secondmate_standalone_clone_home_is_trusted
test_secondmate_leased_worktree_home_is_trusted
test_secondmate_home_trust_refuses_everything_unseeded
test_worktree_mode_still_refuses_a_secondmate_home
test_secondmate_spawn_fails_closed_when_home_trust_cannot_be_recorded
test_external_import_with_no_consent_blocks_the_launch
test_external_import_with_standing_consent_is_cleared
test_imports_that_stay_inside_the_worktree_do_not_block
test_import_syntax_inside_a_code_fence_is_not_an_import
test_a_transitive_import_out_of_the_worktree_blocks
test_claude_local_md_is_scanned_too
test_an_unresolvable_external_import_is_reported_as_undecided
test_an_external_import_at_the_last_loaded_file_still_blocks
test_an_external_import_one_file_past_the_loaded_chain_does_not_block
test_import_syntax_in_an_indented_block_or_an_html_comment_is_not_an_import
test_the_clear_verdict_names_what_it_scanned_and_what_it_did_not
test_an_external_import_ending_a_sentence_is_reported_not_refused
test_a_parenthesised_in_tree_import_is_reported_unfollowed
test_a_punctuated_spelling_of_an_already_scanned_file_stays_clear
test_an_import_naming_an_outside_directory_does_not_block
test_a_memory_file_symlinked_out_of_the_worktree_is_reported
test_a_memory_file_symlinked_out_of_the_worktree_is_still_read
test_secondmate_home_external_import_blocks_the_launch
test_secondmate_home_with_an_underivable_consent_entry_is_undecided
test_spawn_refuses_a_launch_that_would_meet_the_imports_dialog
test_spawn_launches_and_warns_when_the_imports_verdict_is_undecided
