#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the upstream-write PreToolUse seatbelt
# (docs/upstream-guard.md).
#
# bin/fm-upstream-pretool-check.sh is the single owner of the decision and of
# the transport. This suite drives it through real invocations against real
# fixture repositories with real remotes: every verdict below comes from
# running the script, never from reading its source.
#
# It proves the decision matrix in both directions (a write naming upstream is
# refused; the same write naming the fork is allowed; reads and fetches against
# upstream are allowed), the slug derivation from the clone's OWN upstream
# remote rather than any hardcoded default, the complete inertness of a clone
# with no upstream remote, the harness-output shaping, and every documented
# step-aside path. No harness is spawned; live per-harness evidence lives in
# docs/upstream-guard.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-upstream-pretool-check)

GUARD="$ROOT/bin/fm-upstream-pretool-check.sh"

# A fork-shaped clone: origin is our fork, upstream is the parent repository.
# The slugs deliberately belong to NOBODY in this repository's own history, so
# a guard that still carried a hardcoded default would fail every case here.
FORK_OWNER=someoperator
FORK_SLUG="$FORK_OWNER/widget"
UP_OWNER=originalauthor
UP_SLUG="$UP_OWNER/widget"

make_fork_clone() {  # <dir> [upstream-url]
  local dir=$1 up=${2:-"https://github.com/$UP_SLUG.git"}
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" remote add origin "git@github.com:$FORK_SLUG.git"
  git -C "$dir" remote add upstream "$up"
  printf '%s\n' "$dir"
}

make_plain_clone() {  # <dir> - a clone with NO upstream remote at all
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" remote add origin "git@github.com:$FORK_SLUG.git"
  printf '%s\n' "$dir"
}

FORK=$(make_fork_clone "$TMP_ROOT/fork")
PLAIN=$(make_plain_clone "$TMP_ROOT/plain")

# Run the guard the way an adapter does, against a chosen repository.
# FM_UPSTREAM_GUARD_REPO is the documented repository override; every case
# below states which clone it is judging rather than depending on $PWD.
run_guard() {  # <repo-dir> <command> [extra-arg...]
  local repo=$1 cmd=$2
  shift 2
  FM_UPSTREAM_GUARD_REPO="$repo" FM_ALLOW_UPSTREAM_WRITE="" \
    "$GUARD" --command "$cmd" "$@" 2>"$TMP_ROOT/stderr" >"$TMP_ROOT/stdout"
  printf '%s' "$?"
}

verdict() {  # <repo-dir> <command> -> allow|deny
  local code
  code=$(run_guard "$1" "$2" --claude)
  case "$code" in
    0) printf 'allow' ;;
    2) printf 'deny' ;;
    *) printf 'exit%s' "$code" ;;
  esac
}

# --- decision matrix, both directions ---------------------------------------

MATRIX_IDS=()
MATRIX_EXPECT=()
MATRIX_CMDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECT+=("$2")
  MATRIX_CMDS+=("$3")
}

# DENY: a write that names the upstream repository.
matrix_case D01 deny "gh pr create --repo $UP_SLUG --title x --body y"
matrix_case D02 deny "gh pr create -R $UP_SLUG --title x"
matrix_case D03 deny "gh pr edit 7 --repo $UP_SLUG --title x"
matrix_case D04 deny "gh pr close 7 --repo $UP_SLUG"
matrix_case D05 deny "gh pr comment 7 --repo $UP_SLUG --body hi"
matrix_case D06 deny "gh pr review 7 --repo $UP_SLUG --approve"
matrix_case D07 deny "gh pr merge 7 --repo $UP_SLUG --squash"
matrix_case D08 deny "gh issue create --repo $UP_SLUG --title x"
matrix_case D09 deny "gh-axi pr create --repo $UP_SLUG --title x"
matrix_case D10 deny "gh api -X POST repos/$UP_SLUG/pulls -f title=x"
matrix_case D11 deny "gh api --method DELETE repos/$UP_SLUG/issues/1"
matrix_case D12 deny "gh pr create --repo=$UP_SLUG --title x"
matrix_case D13 deny "gh pr create --repo \"$UP_SLUG\" --title x"
matrix_case D14 deny "gh release create v1 --repo $UP_SLUG"

# DENY: a push that reaches the upstream repository, by remote name or by URL.
matrix_case D20 deny 'git push upstream HEAD:main'
matrix_case D21 deny 'git push --force upstream main'
matrix_case D22 deny 'git push -u upstream fm/branch'
matrix_case D23 deny "git push https://github.com/$UP_SLUG.git HEAD:main"
matrix_case D24 deny "git push ssh://git@github.com/$UP_SLUG main"
matrix_case D25 deny "git push git@github.com:$UP_SLUG.git main"
matrix_case D26 deny 'sudo git push upstream main'
matrix_case D27 deny 'GIT_SSH_COMMAND=ssh git push upstream main'
matrix_case D28 deny 'git -C . push upstream main'

# DENY: a bare forge write, which the forge CLI resolves against the parent.
matrix_case D30 deny 'gh pr create --title x --body y'
matrix_case D31 deny 'gh issue create --title x'

# DENY: the same owner's other repositories on a write.
matrix_case D40 deny "gh pr create --repo $UP_OWNER/other --title x"

# ALLOW: the same writes aimed at our own fork.
matrix_case A01 allow "gh pr create --repo $FORK_SLUG --title x --body y"
matrix_case A02 allow "gh pr merge 7 --repo $FORK_SLUG --squash"
matrix_case A03 allow "gh issue create --repo $FORK_SLUG --title x"
matrix_case A04 allow "gh api -X POST repos/$FORK_SLUG/pulls -f title=x"
matrix_case A05 allow 'git push origin fm/branch'
matrix_case A06 allow "git push git@github.com:$FORK_SLUG.git main"
matrix_case A07 allow 'git push --force-with-lease origin HEAD'

# ALLOW: every read of upstream, and fetching from it.
matrix_case A10 allow 'git fetch upstream'
matrix_case A11 allow 'git fetch --all --prune'
matrix_case A12 allow "git ls-remote upstream"
matrix_case A13 allow "gh pr view 4937 --repo $UP_SLUG"
matrix_case A14 allow "gh pr list --repo $UP_SLUG"
matrix_case A15 allow "gh pr diff 4937 --repo $UP_SLUG"
matrix_case A16 allow "gh pr checks 4937 --repo $UP_SLUG"
matrix_case A17 allow "gh issue view 12 --repo $UP_SLUG"
matrix_case A18 allow "gh issue list --repo $UP_SLUG"
matrix_case A19 allow "gh repo view $UP_SLUG"
matrix_case A20 allow "gh api repos/$UP_SLUG/pulls"
matrix_case A20b allow "gh api -X GET repos/$UP_SLUG/pulls"
matrix_case A20c allow "gh api --method GET repos/$UP_SLUG/issues"
matrix_case A21 allow "git log upstream/main --oneline"
matrix_case A22 allow "git remote -v"

# ALLOW: the upstream slug in prose rather than in a repository selector.
matrix_case A30 allow "gh pr create --repo $FORK_SLUG --body \"ports $UP_SLUG#4937\""
matrix_case A31 allow "echo git push upstream main"
matrix_case A32 allow "grep -rn 'gh pr create' docs/"

# ALLOW: an unrelated command that merely contains a trigger word.
matrix_case A40 allow 'ls -la'
matrix_case A41 allow 'cargo release create'
matrix_case A42 allow 'npm run push'

# ALLOW: a read chained ahead of a write to our own fork.
matrix_case A50 allow "git fetch upstream && gh pr create --repo $FORK_SLUG --title x"

for idx in "${!MATRIX_IDS[@]}"; do
  got=$(verdict "$FORK" "${MATRIX_CMDS[idx]}")
  assert_equals "${MATRIX_EXPECT[idx]}" "$got" \
    "${MATRIX_IDS[idx]}: ${MATRIX_CMDS[idx]}"
done
pass "decision matrix: ${#MATRIX_IDS[@]} cases, writes to upstream refused and every read, fetch and fork write allowed"

# --- the deny reason is actionable ------------------------------------------

run_guard "$FORK" "gh pr create --repo $UP_SLUG --title x" --claude >/dev/null
REASON=$(cat "$TMP_ROOT/stderr")
assert_contains "$REASON" "upstream-guard" "deny reason is labelled"
assert_contains "$REASON" "$UP_SLUG" "deny reason names the protected repository"
run_guard "$FORK" 'gh pr create --title x' --claude >/dev/null
BARE_REASON=$(cat "$TMP_ROOT/stderr")
assert_contains "$BARE_REASON" "--repo $FORK_SLUG" \
  "the bare-write refusal names the fork to pass instead"
pass "deny reasons name the protected repository and the fork to use instead"

# --- the protected slug comes from THIS clone's own upstream remote ---------
#
# The defect that kept the prototype out of version control was a hardcoded
# default slug: a clone by anyone else inherited a guard pointing at a
# repository that had nothing to do with them. These two clones have different
# upstreams, and each must protect its own.

OTHER=$(make_fork_clone "$TMP_ROOT/other" "https://github.com/thirdparty/gadget.git")
assert_equals deny "$(verdict "$OTHER" 'gh pr create --repo thirdparty/gadget --title x')" \
  "a second clone protects ITS upstream"
assert_equals allow "$(verdict "$OTHER" "gh pr create --repo $UP_SLUG --title x")" \
  "a second clone does NOT protect another clone's upstream"
assert_equals allow "$(verdict "$FORK" 'gh pr create --repo thirdparty/gadget --title x')" \
  "the fork clone does NOT protect an unrelated repository"
pass "the protected repository is derived per clone from its own upstream remote"

# An upstream remote whose push URL has been disabled with a non-URL
# placeholder - the shape this fleet actually configures - must still yield the
# slug from the readable fetch URL.
DISABLED=$(make_fork_clone "$TMP_ROOT/disabled" "ssh://git@github.com/$UP_SLUG")
git -C "$DISABLED" remote set-url --push upstream no_push_disabled_by_firstmate
assert_equals deny "$(verdict "$DISABLED" "gh pr create --repo $UP_SLUG --title x")" \
  "an unreadable push URL does not disarm the readable fetch URL"
assert_equals deny "$(verdict "$DISABLED" 'git push upstream main')" \
  "an unreadable push URL does not disarm the remote-name rule"
pass "an upstream remote with a disabled push URL is still protected"

# --- a clone with no upstream remote is completely unaffected ---------------

NO_UPSTREAM_IDS=()
for cmd in \
  'gh pr create --title x --body y' \
  "gh pr create --repo $UP_SLUG --title x" \
  "gh issue create --repo $UP_SLUG --title x" \
  'git push upstream main' \
  "git push https://github.com/$UP_SLUG.git HEAD" \
  'git push origin fm/branch' \
  'git fetch upstream'; do
  NO_UPSTREAM_IDS+=("$cmd")
  assert_equals allow "$(verdict "$PLAIN" "$cmd")" \
    "no upstream remote: '$cmd' must be untouched"
done
pass "a clone with no upstream remote is inert for all ${#NO_UPSTREAM_IDS[@]} probes, including ones denied in a fork"

# --- step-aside: the guard never blocks when it cannot do its job ------------

assert_equals allow "$(verdict "$TMP_ROOT/not-a-git-dir" "gh pr create --repo $UP_SLUG")" \
  "a repository path that does not exist steps aside"

NOTREPO="$TMP_ROOT/plaindir"
mkdir -p "$NOTREPO"
assert_equals allow "$(verdict "$NOTREPO" "git push upstream main")" \
  "a directory that is not a git repository steps aside"

# The same step-aside with NO override at all: the script copied outside any
# repository, run from a directory that is not one either, so every candidate
# in its resolution chain fails. This is the path a broken environment takes.
LOOSE="$TMP_ROOT/loose/bin"
mkdir -p "$LOOSE"
cp "$GUARD" "$ROOT/bin/fm-hook-host-lib.sh" "$LOOSE/"
code=$(cd "$NOTREPO" && "$LOOSE/fm-upstream-pretool-check.sh" \
  --command "git push upstream main" --claude >/dev/null 2>&1; printf '%s' "$?")
assert_equals 0 "$code" "with no resolvable repository anywhere, the guard steps aside"

# An upstream URL this parser cannot read as owner/repo yields no slug. The
# remote-name rule still stands, but nothing is guessed from the unreadable URL.
OPAQUE=$(make_fork_clone "$TMP_ROOT/opaque" "weird-transport-with-no-path")
assert_equals allow "$(verdict "$OPAQUE" "gh pr create --repo $UP_SLUG --title x")" \
  "an unreadable upstream URL never guesses a protected slug"

# Without git on PATH the guard cannot read any remote, so it must allow.
NOGIT_PATH=$(fm_test_base_path_sans "$PATH" git) || fail "could not build a git-free PATH"
code=$(PATH="$NOGIT_PATH" FM_UPSTREAM_GUARD_REPO="$FORK" \
  "$GUARD" --command "gh pr create --repo $UP_SLUG" --claude >/dev/null 2>&1; printf '%s' "$?")
assert_equals 0 "$code" "a missing git steps aside"

# Empty and malformed transport.
code=$(printf '' | "$GUARD" --claude >/dev/null 2>&1; printf '%s' "$?")
assert_equals 0 "$code" "empty stdin steps aside"
code=$(printf 'not json at all' | "$GUARD" --claude >/dev/null 2>&1; printf '%s' "$?")
assert_equals 0 "$code" "malformed stdin steps aside"
code=$(printf '{"tool_input":{}}' | "$GUARD" --claude >/dev/null 2>&1; printf '%s' "$?")
assert_equals 0 "$code" "a payload with no command steps aside"

# The deliberate escape hatch.
code=$(FM_ALLOW_UPSTREAM_WRITE=1 FM_UPSTREAM_GUARD_REPO="$FORK" \
  "$GUARD" --command "gh pr create --repo $UP_SLUG --title x" --claude >/dev/null 2>&1; printf '%s' "$?")
assert_equals 0 "$code" "FM_ALLOW_UPSTREAM_WRITE=1 allows deliberately"
pass "every documented step-aside path allows instead of blocking"

# --- harness transport and output shaping -----------------------------------

# Claude: deny object on stderr, stdout empty, exit 2.
code=$(run_guard "$FORK" "gh pr create --repo $UP_SLUG --title x" --claude)
assert_equals 2 "$code" "claude deny exits 2"
assert_equals "" "$(cat "$TMP_ROOT/stdout")" "claude deny leaves stdout empty"
assert_contains "$(cat "$TMP_ROOT/stderr")" '"permissionDecision":"deny"' \
  "claude deny object on stderr"

# Grok and the exit-2 consumers: the same stderr object, plus a Grok decision
# object on stdout because --claude was not supplied.
code=$(run_guard "$FORK" "gh pr create --repo $UP_SLUG --title x")
assert_equals 2 "$code" "default deny exits 2"
assert_contains "$(cat "$TMP_ROOT/stdout")" '"decision":"deny"' \
  "grok decision object on stdout"

# Cursor reads the returned object rather than the exit status.
code=$(run_guard "$FORK" "gh pr create --repo $UP_SLUG --title x" --cursor)
assert_equals 0 "$code" "cursor deny exits 0"
assert_contains "$(cat "$TMP_ROOT/stdout")" '"permission":"deny"' \
  "cursor decision object on stdout"

# Stdin transport, in both payload shapes, with the repository taken from the
# payload's own cwd.
payload_verdict() {  # <json> -> exit code
  printf '%s' "$1" | (cd "$TMP_ROOT" && "$GUARD" --claude >/dev/null 2>&1; printf '%s' "$?")
}
code=$(payload_verdict "$(jq -nc --arg c "gh pr create --repo $UP_SLUG --title x" --arg d "$FORK" \
  '{tool_input:{command:$c},cwd:$d}')")
assert_equals 2 "$code" "claude/codex stdin payload denies"
code=$(payload_verdict "$(jq -nc --arg c "gh pr create --repo $UP_SLUG --title x" --arg d "$FORK" \
  '{toolInput:{command:$c},cwd:$d}')")
assert_equals 2 "$code" "grok stdin payload denies"
code=$(payload_verdict "$(jq -nc --arg c "gh pr create --repo $FORK_SLUG --title x" --arg d "$FORK" \
  '{tool_input:{command:$c},cwd:$d}')")
assert_equals 0 "$code" "stdin payload allows a write to our own fork"

# A Cursor-delivered payload reaching the tracked Claude registration is the
# duplicate Cursor also loads; that copy stands down rather than deciding twice.
code=$(payload_verdict "$(jq -nc --arg c "gh pr create --repo $UP_SLUG --title x" --arg d "$FORK" \
  '{tool_input:{command:$c},cwd:$d,cursor_version:"2026.08.11"}')")
assert_equals 0 "$code" "the foreign-host duplicate stands down"
pass "transport and per-harness output shaping match the documented contract"

# --- the guard is registered where the fleet actually runs ------------------

assert_grep 'fm-upstream-pretool-check.sh' "$ROOT/.claude/settings.json" \
  "the guard is wired into the tracked Claude PreToolUse array"
for reg in .codex/hooks.json .cursor/hooks.json; do
  assert_grep 'fm-upstream-pretool-check.sh' "$ROOT/$reg" \
    "the guard is wired into $reg"
done
assert_present "$ROOT/.grok/hooks/fm-primary-upstream-check.json" \
  "the guard has a Grok registration"
assert_present "$ROOT/.opencode/plugins/fm-primary-upstream-check.js" \
  "the guard has an OpenCode registration"
for ext in .pi/extensions/fm-primary-turnend-guard.ts .omp/extensions/fm-primary-turnend-guard.ts; do
  assert_grep 'fm-upstream-pretool-check.sh' "$ROOT/$ext" \
    "the guard is wired into $ext"
done
for reg in .claude/settings.json .codex/hooks.json .cursor/hooks.json; do
  jq -e . "$ROOT/$reg" >/dev/null || fail "$reg is not valid JSON"
done
jq -e . "$ROOT/.grok/hooks/fm-primary-upstream-check.json" >/dev/null \
  || fail "the Grok registration is not valid JSON"
pass "the guard is registered on every harness that carries the sibling seatbelts"

# --- end to end through the real hook entry point ---------------------------
#
# The regression this whole guard exists for: a worker in a fork's worktree
# opening a pull request against the parent repository. Drive it exactly as the
# harness does - a PreToolUse payload on stdin, cwd inside the worktree - and
# require the refusal.

# A genuine linked worktree of the fork - the shape bin/fm-spawn.sh hands every
# crewmate. Built directly rather than through fm_git_worktree, which would
# rewrite this fixture's origin URL and invalidate the fork-slug cases above.
WORKTREE="$TMP_ROOT/fork-task-worktree"
git -C "$FORK" worktree add --quiet -b fm/upstream-guard-regression "$WORKTREE"
INCIDENT="gh pr create --repo $UP_SLUG --title 'work in progress' --body please-no"
code=$(printf '%s' "$(jq -nc --arg c "$INCIDENT" --arg d "$WORKTREE" \
  '{tool_input:{command:$c},cwd:$d}')" \
  | (cd "$WORKTREE" && "$GUARD" --claude >/dev/null 2>"$TMP_ROOT/stderr"; printf '%s' "$?"))
assert_equals 2 "$code" "the incident command is refused from inside a task worktree"
assert_contains "$(cat "$TMP_ROOT/stderr")" "$UP_SLUG" \
  "the refusal names the parent repository"
code=$(printf '%s' "$(jq -nc --arg c "gh pr create --repo $FORK_SLUG --title x" --arg d "$WORKTREE" \
  '{tool_input:{command:$c},cwd:$d}')" \
  | (cd "$WORKTREE" && "$GUARD" --claude >/dev/null 2>&1; printf '%s' "$?"))
assert_equals 0 "$code" "the same pull request against our fork is allowed from the same worktree"
pass "end to end: the incident is refused from a task worktree and the fork route stays open"
