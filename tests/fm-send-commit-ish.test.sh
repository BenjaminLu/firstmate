#!/usr/bin/env bash
# tests/fm-send-commit-ish.test.sh - fm-send refuses a steer naming a commit
# that does not exist.
#
# A verification instruction pointing at a commit nobody read is worthless, and
# a commit-ish either resolves in the task's local copy or it does not. These
# tests drive the real fm-send executable over a stubbed tmux and a real git
# worktree, and pin:
#   1. A message naming an unresolvable commit-ish refuses with exit 2, names
#      the value, and records nothing - the steer is not sent.
#   2. A message naming a commit that does resolve is sent unchanged.
#   3. Ordinary prose carrying hex-like words is not treated as a commit-ish:
#      the 8-character floor keeps 'facade' and 'decade' below the match.
#   4. A sha ending a sentence is still read, while a UUID - whose dashes sit
#      on the inside, where nothing strips them - is still left alone.
#   5. A value that resolves in another object database this home can see - the
#      project clone, firstmate itself - is not refused, and a remote target is
#      not judged against this host at all.
#   6. No readable source at all steps aside rather than blocking a steer
#      it cannot judge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-commit-ish)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: enough of the doorbell path to reach a clean verdict, logging any
# literal typed text so a refused steer can be proved silent.
make_stubs() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-task-a\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# setup_case <name> -> echoes case dir with home/state, a source clone standing
# in for the project the task was spawned from, a slot worktree cloned from it,
# and meta recording both the way fm-spawn does.
setup_case() { # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_git_init_commit "$dir/project"
  git clone -q "$dir/project" "$dir/worktree"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=sess:fm-task-a" "kind=ship" "harness=claude" \
    "worktree=$(cd "$dir/worktree" && pwd)" \
    "project=$(cd "$dir/project" && pwd)"
  printf '%s\n' "$dir"
}

# commit_only_in_project <case-dir> -> echoes a sha that exists in the project
# clone and NOT in the slot's worktree, the shape of a commit merged after the
# slot was created.
commit_only_in_project() { # <case-dir>
  local dir=$1
  printf 'landed after the slot was created\n' >>"$dir/project/README.md"
  git -C "$dir/project" add README.md
  git -C "$dir/project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "landed later"
  git -C "$dir/project" rev-parse HEAD
}

run_send() { # <case-dir> <err-file> -- <fm-send args...>
  local dir=$1 err=$2
  shift 3
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 \
    "$SEND" "$@" >/dev/null 2>"$err"
}

test_refuses_a_message_naming_a_commit_that_does_not_resolve() {
  local dir err rc
  dir=$(setup_case unresolvable)
  err="$dir/send.err"
  run_send "$dir" "$err" -- task-a 'verify against deadbeefdeadbeef'
  rc=$?
  expect_code 2 "$rc" "a steer naming an unresolvable commit should refuse"
  assert_contains "$(cat "$err")" 'deadbeefdeadbeef' \
    "the refusal must name the value that does not resolve"
  assert_contains "$(cat "$err")" 'does not resolve' \
    "the refusal must say what is wrong with it"
  [ ! -d "$dir/home/state/task-a.inbox" ] ||
    fail "a refused steer still wrote an inbox record"
  [ ! -s "$dir/send.log" ] ||
    fail "a refused steer still rang the doorbell:"$'\n'"$(cat "$dir/send.log")"
  pass "fm-send: a steer naming a commit that does not resolve refuses and names it"
}

test_accepts_a_message_naming_a_commit_that_resolves() {
  local dir err rc head
  dir=$(setup_case resolvable)
  err="$dir/send.err"
  head=$(git -C "$dir/worktree" rev-parse HEAD)
  run_send "$dir" "$err" -- task-a "verify against ${head:0:8}"
  rc=$?
  expect_code 0 "$rc" "a steer naming a commit that resolves should be sent:"$'\n'"$(cat "$err")"
  assert_grep "verify against ${head:0:8}" "$dir/home/state/task-a.inbox/001.msg" \
    "the steer should be recorded unchanged"
  pass "fm-send: a steer naming a commit that resolves is sent unchanged"
}

test_ordinary_prose_with_hex_like_words_is_not_treated_as_a_commit() {
  local dir err rc
  dir=$(setup_case prose)
  err="$dir/send.err"
  # 'facade' and 'decade' are hex-only words; a naive matcher would refuse them.
  run_send "$dir" "$err" -- task-a 'the facade added a decade of debt'
  rc=$?
  expect_code 0 "$rc" "ordinary prose must not be read as a commit-ish:"$'\n'"$(cat "$err")"
  assert_grep 'the facade added a decade of debt' "$dir/home/state/task-a.inbox/001.msg" \
    "the prose steer should be recorded unchanged"
  pass "fm-send: hex-like words in ordinary prose are not treated as commits"
}

test_a_commit_ending_a_sentence_is_still_read() {
  local dir err rc
  dir=$(setup_case punctuation)
  err="$dir/send.err"
  run_send "$dir" "$err" -- task-a 'verify against deadbeefdeadbeef.'
  rc=$?
  expect_code 2 "$rc" "trailing punctuation must not hide an unresolvable commit"
  assert_contains "$(cat "$err")" 'deadbeefdeadbeef' \
    "the refusal must name the value without its trailing punctuation"
  # A UUID carries its dashes on the inside, so stripping the edges cannot
  # turn its first field into a commit-ish and refuse a steer that named none.
  dir=$(setup_case uuid)
  err="$dir/send.err"
  run_send "$dir" "$err" -- task-a 'the record is 550e8400-e29b-41d4-a716-446655440000'
  rc=$?
  expect_code 0 "$rc" "a UUID must not be read as a commit-ish:"$'\n'"$(cat "$err")"
  pass "fm-send: a sha ending a sentence is read, and a UUID is still left alone"
}

test_a_commit_that_resolves_in_another_object_database_is_not_refused() {
  local dir err rc sha
  dir=$(setup_case merged-after-spawn)
  err="$dir/send.err"
  sha=$(commit_only_in_project "$dir")
  # The slot's own clone was frozen at spawn, so a sha merged since resolves
  # only in the project clone. It was read off the forge; it is not the error
  # this guard exists to catch.
  run_send "$dir" "$err" -- task-a "main is now at ${sha:0:8}, rebase onto it"
  rc=$?
  expect_code 0 "$rc" "a commit that resolves in the project clone must not be refused:"$'\n'"$(cat "$err")"
  pass "fm-send: a commit the slot has not fetched yet is not refused"
}

test_a_remote_targets_recorded_paths_are_not_judged_locally() {
  local dir err
  dir=$(setup_case remote-target)
  err="$dir/send.err"
  # A remote secondmate's worktree= names a path on the OTHER host. Judging a
  # remote steer against whatever sits at that path locally is judging an
  # unrelated repository, so the guard steps aside entirely.
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=remote:task-a" "kind=secondmate" "harness=claude" \
    "worktree=$(cd "$dir/worktree" && pwd)" \
    "project=$(cd "$dir/project" && pwd)" \
    "remote_host=remote-mac"
  run_send "$dir" "$err" -- task-a 'verify against deadbeefdeadbeef'
  assert_not_contains "$(cat "$err")" 'does not resolve' \
    "a remote target's steer must not be judged against a local repository"
  pass "fm-send: a remote target's recorded paths are not judged against this host"
}

test_refusal_is_skipped_when_no_local_copy_can_answer() {
  local dir err rc
  dir=$(setup_case noworktree)
  err="$dir/send.err"
  # Every source gone: the slot's worktree deleted and the recorded project a
  # plain directory. Nothing can answer, so the guard steps aside rather than
  # blocking a steer it cannot judge.
  rm -rf "$dir/worktree"
  mkdir -p "$dir/notarepo"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=sess:fm-task-a" "kind=ship" "harness=claude" \
    "worktree=$dir/worktree" "project=$dir/notarepo"
  run_send "$dir" "$err" -- task-a 'verify against deadbeefdeadbeef'
  rc=$?
  expect_code 0 "$rc" "an unreadable local copy must not block a steer:"$'\n'"$(cat "$err")"
  assert_grep 'verify against deadbeefdeadbeef' "$dir/home/state/task-a.inbox/001.msg" \
    "the steer should still be recorded when the check cannot judge it"
  pass "fm-send: the check steps aside when no local copy can answer"
}

test_refuses_a_message_naming_a_commit_that_does_not_resolve
test_accepts_a_message_naming_a_commit_that_resolves
test_ordinary_prose_with_hex_like_words_is_not_treated_as_a_commit
test_a_commit_ending_a_sentence_is_still_read
test_a_commit_that_resolves_in_another_object_database_is_not_refused
test_a_remote_targets_recorded_paths_are_not_judged_locally
test_refusal_is_skipped_when_no_local_copy_can_answer
