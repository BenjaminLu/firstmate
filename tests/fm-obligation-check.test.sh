#!/usr/bin/env bash
# Tests for bin/fm-obligation-check.sh, the fleet obligation report.
#
# Every obligation is proven in BOTH directions: it prints when the obligation
# is genuinely owed, and it stays silent when the obligation is genuinely met.
# Only proving the printing half would let the silent case rot into a check that
# reports nothing because it can no longer see anything, which is exactly the
# failure this script was written to end - an obligation that stopped being met
# and made no sound.
#
# The forge is a fixture, and it is deliberately not a fixture that invents its
# own output shape. Each repository is a JSON file in gh's own --json shape, and
# the fake gh applies the CALLER's --jq program to it with the local jq, so what
# the hermetic suite exercises is the script's own extraction program rather
# than a hand-written answer that agrees with whatever the script expects.
# gh evaluates --jq with gojq rather than the jq binary, so that those programs
# also compile where they actually run is proven separately and against the real
# forge by tests/fm-obligation-forge-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-obligation-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-obligation-check)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq is required to shape the forge fixtures\n'; exit 0; }

SLUG=fmtest/repo
PR_BASE="https://github.com/$SLUG/pull"

# --- fixtures ---------------------------------------------------------------

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/.lavish" "$home/forge" "$home/bin"
  make_gh "$home"
  printf '%s\n' "$home"
}

# A gh that answers from the fixture repository files and applies the caller's
# own --jq program. It logs every invocation so a case can assert how many forge
# calls a sweep actually made.
make_gh() {
  local home=$1
  cat > "$home/bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$GH_LOG"
mode= repo= number= program= head=
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[i]}" in
    list) mode=list ;;
    view) i=$((i + 1)); mode=view; number=${args[i]} ;;
    --repo) i=$((i + 1)); repo=${args[i]} ;;
    --head) i=$((i + 1)); head=${args[i]} ;;
    --jq) i=$((i + 1)); program=${args[i]} ;;
    --json|--limit|--state) i=$((i + 1)) ;;
  esac
  i=$((i + 1))
done
[ -z "${GH_FIXTURE_HANG:-}" ] || sleep "$GH_FIXTURE_HANG"
[ -z "${GH_FIXTURE_FAIL:-}" ] || { printf 'the forge said no\n' >&2; exit 1; }
# GitHub owner and repository names are case-insensitive, so the fixture
# resolves them that way too; a fixture that did not would make a
# case-varied record look like a missing repository rather than the same one.
lc=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
file="$GH_FORGE/${lc//\//__}.json"
[ -f "$file" ] || { printf 'no such repository\n' >&2; exit 1; }
if [ "$mode" = list ]; then
  if [ -n "$head" ]; then
    jq -c --arg h "$head" '[.[] | select(.state == "OPEN" and .headRefName == $h)]' "$file" | jq -r "$program"
  else
    jq -c '[.[] | select(.state == "OPEN")]' "$file" | jq -r "$program"
  fi
else
  jq -c --arg n "$number" '.[] | select((.number | tostring) == $n)' "$file" | jq -r "$program"
fi
SH
  chmod 0755 "$home/bin/gh"
}

# forge_pr <home> <slug> <number> <state> <head> <reviews> <comments> [branch]
forge_pr() {
  local home=$1 slug=$2 number=$3 state=$4 head=$5 reviews=$6 comments=$7 branch=${8:-} file tmp
  local lc
  lc=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  file="$home/forge/${lc//\//__}.json"
  [ -f "$file" ] || printf '[]\n' > "$file"
  tmp="$file.tmp"
  jq --argjson n "$number" --arg s "$state" --arg h "$head" --arg b "$branch" \
    --argjson r "$reviews" --argjson c "$comments" --arg u "https://github.com/$slug/pull/$number" \
    '. + [{number: $n, url: $u, state: $s, headRefOid: $h, headRefName: $b,
           reviews: [range($r) | {state: "COMMENTED"}],
           comments: [range($c) | {body: "a note"}]}]' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

sha() { printf '%040d\n' "$1" | tr '0' "${2:-a}" | cut -c1-40; }

# A 40-hex commit that is distinct per seed.
commit() { printf '%s%036d\n' "$1" "$1" | cut -c1-40 | tr ' ' '0'; }

# task <home> <id> [extra meta lines...]
#
# The worktree is a real repository, because obligation 1 reads the task's own
# branch out of it when the records name no pull request. It starts on a
# detached HEAD, which is where bin/fm-brief.sh starts every task and which
# means the task has not branched and so can have no pull request yet.
task() {
  local home=$1 id=$2 wt
  shift 2
  wt="$home/wt/$id"
  mkdir -p "$wt"
  git -C "$wt" init -q 2>/dev/null
  git -C "$wt" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m base 2>/dev/null
  git -C "$wt" checkout -q --detach 2>/dev/null
  {
    printf 'window=default:w1:p1\n'
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$home/state/$id.meta"
}

# task_branch <home> <id> <branch> [remote-url]: put the task's worktree on a
# branch with an origin, which is what obligation 1's discovery path reads.
task_branch() {
  local home=$1 id=$2 branch=$3 remote=${4:-git@github.com:fmtest/repo.git} wt
  wt="$home/wt/$id"
  git -C "$wt" checkout -q -B "$branch" 2>/dev/null
  git -C "$wt" remote remove origin 2>/dev/null
  git -C "$wt" remote add origin "$remote" 2>/dev/null
}

# poll <home> <id> <url>: the armed merge poll's own sidecar.
poll() {
  local home=$1 id=$2 url=$3 host=github.com path number
  path=$(printf '%s' "$url" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/.*#\1#')
  number=${url##*/}
  printf '%s\n%s\n%s\n%s\n%s\n' github "$url" "$host" "$path" "$number" > "$home/state/$id.pr-poll"
}

# steer <home> <id> <count>: <count> handled steering records.
steer() {
  local home=$1 id=$2 count=$3 i
  mkdir -p "$home/state/$id.inbox/handled"
  for ((i = 1; i <= count; i++)); do
    printf 'a steer\n' > "$home/state/$id.inbox/handled/$(printf '%03d' "$i").msg"
  done
}

design_record() {
  local home=$1 id=$2 name=${3:-design.md}
  mkdir -p "$home/data/$id"
  printf '# the plan\n' > "$home/data/$id/$name"
}

# board <home> <key>=<pr-url>...: a built board page carrying Captain's Call cards.
board() {
  local home=$1 cards='[]' entry key url
  shift
  for entry in "$@"; do
    key=${entry%%=*}
    url=${entry#*=}
    cards=$(printf '%s' "$cards" | jq --arg k "$key" --arg u "$url" '. + [{key: $k, pr_url: $u}]')
  done
  {
    printf '<html><body>\n'
    printf '<script id="bearings-data" type="application/json">\n'
    printf '%s\n' "$(printf '%s' "$cards" | jq -c '{schema: "fm-bearings-board.v1", captains_call: ., landed: [], underway: [], charted: []}')"
    printf '</script>\n'
    printf '</body></html>\n'
  } > "$home/.lavish/bearings-board.html"
}

# make_stalled_git <home>: a git that never answers, for driving the bound on a
# worktree read. It shadows git only for the check under test, because the
# fixture PATH puts this directory first.
make_stalled_git() {
  local home=$1
  cat > "$home/bin/git" <<'SH'
#!/usr/bin/env bash
sleep "${GIT_STALL_SECS:-30}"
exit 0
SH
  chmod 0755 "$home/bin/git"
}

# make_selective_git <home> <exact git arguments>: a git that answers every
# invocation normally and stalls on exactly one. It matches the WHOLE argument
# list after `-C <path>`, not its first word, because `remote get-url origin`
# and a bare `remote` are two different reads that both begin with "remote" and
# happen at different points in the discovery path.
#
# It is how a failure is driven at a read that only happens once the earlier
# reads have already succeeded.
make_selective_git() {
  local home=$1 real
  shift
  real=$(command -v git)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'want=%s\n' "$(printf '%q' "$*")"
    printf 'args=("$@")\n'
    # shellcheck disable=SC2016  # single quotes are deliberate: these expansions belong to the generated stub, not to this shell.
    printf 'if [ "${args[0]:-}" = -C ]; then args=("${args[@]:2}"); fi\n'
    # shellcheck disable=SC2016  # as above.
    printf 'if [ "${args[*]}" = "$want" ]; then sleep "${GIT_STALL_SECS:-20}"; exit 0; fi\n'
    printf 'exec %s "$@"\n' "$(printf '%q' "$real")"
  } > "$home/bin/git"
  chmod 0755 "$home/bin/git"
}

# run <home> <out> [env assignments...]: one sweep with the cadence gate open, so
# a case exercises the obligations rather than the no-nag interval.
run() {
  local home=$1 out=$2
  shift 2
  local status=0
  # The case's own assignments come LAST so a case that means to drive the
  # cadence gate or the watcher bound actually overrides the defaults here.
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=0 FM_CHECK_TIMEOUT=30 \
    PATH="$home/bin:$PATH" "$@" "$CHECK" > "$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

assert_silent() {
  [ ! -s "$1" ] || fail "$2: $(cat "$1")"
}

# --- obligation 1: an open pull request with nothing posted on it -----------

test_open_pull_request_with_nothing_posted_is_reported() {
  local home out
  home=$(make_home o1-owed)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "nothing posted on $PR_BASE/7 (task alpha)" \
    "an open pull request with no review and no comment was not reported"
  assert_contains "$(cat "$out")" "obligations owed:" "the finding was not reported as owed"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must be exactly one line for the wake record"
  pass "an open pull request with nothing posted on it is reported"
}

test_a_reviewed_pull_request_is_silent() {
  local home out
  home=$(make_home o1-review)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 1 0
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a pull request carrying a formal review was still reported as unreviewed"
  pass "a pull request with a formal review is silent"
}

test_a_commented_pull_request_is_silent() {
  local home out
  home=$(make_home o1-comment)
  # The reviewed-PR path posts its findings with `gh pr comment`, so a comment
  # and not only a formal review has to satisfy this obligation.
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 1
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a pull request carrying a posted comment was still reported as unreviewed"
  pass "a pull request whose findings were posted as a comment is silent"
}

test_a_closed_pull_request_is_not_owed_a_review() {
  local home out
  home=$(make_home o1-closed)
  forge_pr "$home" "$SLUG" 7 MERGED "$(commit 7)" 0 0
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a pull request that is no longer open was reported as owing a review"
  pass "only an OPEN pull request is owed a review"
}

test_a_pull_request_nobody_recorded_is_still_found() {
  local home out
  # The finding this closes: a pull request reached obligation 1 only through
  # pr= in the task's records, and writing that key is firstmate's own
  # remembered action. So the detector built because firstmate forgets was
  # blind to exactly the pull request nobody registered.
  home=$(make_home discover-owed)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 0 0 fm/discover-owed
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/discover-owed
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "nothing posted on $PR_BASE/55" \
    "an unreviewed pull request that no task record names was not found"
  assert_contains "$(cat "$out")" "(task omega, which its own records do not name)" \
    "the report did not say the pull request is missing from the task's own records"
  pass "an unreviewed pull request nobody recorded is found from the task's own branch"
}

test_a_discovered_pull_request_that_is_reviewed_is_silent() {
  local home out
  home=$(make_home discover-met)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 1 0 fm/discover-met
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/discover-met
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a discovered pull request that already has a review was reported as unreviewed"
  pass "a discovered pull request with a review posted is silent"
}

test_a_branch_with_no_pull_request_is_silent() {
  local home out
  # The forge answering "none" is a determinate answer, not an unknown.
  home=$(make_home discover-none)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 0 0 fm/someone-else
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/discover-none
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a branch the forge says has no open pull request was reported"
  pass "a branch with no open pull request is a determinate none, not an unknown"
}

test_a_task_that_has_not_branched_yet_is_silent_and_costs_nothing() {
  local home out calls
  # Every task starts at a detached HEAD, so this is the common state. It can
  # have no pull request, which is determinate, and it must not spend a read.
  home=$(make_home discover-detached)
  task "$home" omega "kind=ship"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a task that has not branched yet was reported"
  calls=0
  [ ! -e "$home/gh.log" ] || calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 0 ] || fail "a task that cannot have a pull request still cost $calls forge reads"
  pass "a task still on a detached HEAD is silent and asks the forge nothing"
}

test_a_pull_request_named_only_by_the_armed_poll_costs_no_discovery() {
  local home out calls report
  # The poll sidecar is the task's second record of its own pull request.
  # Consulted after the branch on pr= alone, it let the task spend a discovery
  # call anyway - and the finding then said the task's records do not name the
  # pull request when its armed poll does, pointing at the wrong repair.
  home=$(make_home poll-names-it)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0 fm/poll-names-it
  task "$home" alpha "kind=ship"
  task_branch "$home" alpha fm/poll-names-it
  poll "$home" alpha "$PR_BASE/7"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "a task whose armed poll names its pull request cost $calls forge calls, so the sidecar is still read too late"
  assert_contains "$report" "nothing posted on $PR_BASE/7 (task alpha)" \
    "the pull request its armed poll names was not reported against the task"
  assert_not_contains "$report" "which its own records do not name" \
    "the report claimed the task's records do not name a pull request its armed poll names"
  pass "a pull request named only by the armed poll costs no discovery call and no wrong repair"
}

test_discovery_is_skipped_for_a_task_that_already_records_its_pull_request() {
  local home out calls
  # Asking again would buy no coverage, so it must not be paid for.
  home=$(make_home discover-skip)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 1 1 fm/discover-skip
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  task_branch "$home" alpha fm/discover-skip
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a task with a reviewed recorded pull request was reported"
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "a task that already records its pull request cost $calls reads, so discovery ran when it buys nothing"
  pass "a task that already records its pull request is not discovered again"
}

test_a_worktree_that_is_gone_is_unknown_not_clean() {
  local home out report
  home=$(make_home discover-noworktree)
  task "$home" omega "kind=ship"
  rm -rf "$home/wt/omega"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a task whose worktree is gone produced silence about whether it has a pull request"
  assert_contains "$report" "is not there, so whether it has a pull request of its own could not be established" \
    "a missing worktree was not named as the reason obligation 1 could not be established"
  assert_contains "$report" "unknown:" "a missing worktree did not produce an unknown answer"
  pass "a task whose worktree is gone is unknown, not clean"
}

# The three states where the worktree PATH is there and the repository cannot
# be read. Each used to refuse the branch read exactly as a detached HEAD does,
# and so was reported as "this task has not branched, it can have no pull
# request" - an input the check could not read, announced as an obligation met.
# The control below proves the same fixture is genuinely owed.
assert_discovery_control_is_owed() {
  local home=$1 out
  out="$home/control.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "nothing posted on $PR_BASE/7" \
    "the control did not report, so this case cannot prove anything about silence"
  rm -f "$home/state/.fleet-obligations"
}

test_a_worktree_that_is_not_a_repository_is_unknown_not_clean() {
  local home out report
  home=$(make_home discover-nogit)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0 fm/nogit
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/nogit
  assert_discovery_control_is_owed "$home"
  rm -rf "$home/wt/omega/.git"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a worktree that is no longer a repository produced silence while a pull request sat unreviewed"
  assert_contains "$report" "is not a readable git repository" \
    "a worktree that is not a repository was reported as a task that has not branched"
  assert_contains "$report" "unknown:" "a worktree that is not a repository did not produce an unknown answer"
  pass "a worktree that is not a readable repository is unknown, not a task that has not branched"
}

test_a_worktree_whose_git_cannot_be_read_is_unknown_not_clean() {
  local home out report
  home=$(make_home discover-gitperm)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0 fm/gitperm
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/gitperm
  assert_discovery_control_is_owed "$home"
  chmod 000 "$home/wt/omega/.git"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  chmod 755 "$home/wt/omega/.git"
  [ -s "$out" ] || fail "a worktree whose .git cannot be read produced silence while a pull request sat unreviewed"
  assert_contains "$report" "unknown:" "an unreadable .git did not produce an unknown answer"
  assert_not_contains "$report" "owed:" "an unreadable .git was turned into an owed obligation"
  pass "a worktree whose .git cannot be read is unknown, not a task that has not branched"
}

test_a_worktree_read_that_hits_its_bound_is_unknown_not_clean() {
  local home out report
  # The case LOCAL_READ_SECS was introduced for. It does not hang the sweep,
  # and it must not report the stall as "no pull request exists" either.
  home=$(make_home discover-stall)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0 fm/stall
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/stall
  assert_discovery_control_is_owed "$home"
  make_stalled_git "$home"
  out="$home/out.txt"
  run "$home" "$out" GIT_STALL_SECS=20
  report=$(cat "$out")
  [ -s "$out" ] || fail "a worktree read that hit its bound produced silence while a pull request sat unreviewed"
  assert_contains "$report" "did not answer in time" \
    "a read that hit its bound was not distinguished from a task that has not branched"
  assert_contains "$report" "unknown:" "a read that hit its bound did not produce an unknown answer"
  pass "a worktree read that hits its bound is unknown, not a task that has not branched"
}

test_a_branch_read_that_cannot_be_established_is_unknown_not_clean() {
  local home out report
  # The repository answers rev-parse and then the branch read itself cannot be
  # established. Distinct from the case where the repository never answered at
  # all, and reachable only once that first probe has succeeded.
  home=$(make_home branch-read-stall)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0 fm/branch-stall
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/branch-stall
  assert_discovery_control_is_owed "$home"
  make_selective_git "$home" symbolic-ref --quiet --short HEAD
  out="$home/out.txt"
  run "$home" "$out" GIT_STALL_SECS=20
  report=$(cat "$out")
  [ -s "$out" ] || fail "a branch read that could not be established produced silence"
  assert_contains "$report" "the branch of omega's worktree" \
    "the branch read that could not be established was not named"
  assert_contains "$report" "unknown:" "a branch read that could not be established did not produce an unknown answer"
  pass "a branch read that cannot be established is unknown, not a task that has not branched"
}

test_a_remote_list_that_cannot_be_read_is_unknown_not_clean() {
  local home out report
  # Everything answers except the bare remote list, which is only reached once
  # origin has already been read and the forge has said this branch has no
  # open pull request there.
  home=$(make_home remote-list-stall)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 0 0 fm/somewhere-else
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/no-pr-here
  make_selective_git "$home" remote
  out="$home/out.txt"
  run "$home" "$out" GIT_STALL_SECS=20
  report=$(cat "$out")
  [ -s "$out" ] || fail "a remote list that could not be read produced silence about where else the branch could have gone"
  assert_contains "$report" "its other remotes could not be listed" \
    "the unreadable remote list was not named"
  assert_contains "$report" "unknown:" "an unreadable remote list did not produce an unknown answer"
  pass "a remote list that cannot be read is unknown, not a determinate none"
}

test_a_branch_with_another_remote_says_only_origin_was_asked() {
  local home out report
  # The fork-plus-upstream clone is ordinary in this repository, and in that
  # flow the branch is on origin while the pull request is on the parent.
  # Absence proved against origin alone used to be reported as absence
  # everywhere, which is silence - and silence is what this check sells.
  home=$(make_home discover-upstream)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 0 0 fm/elsewhere
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/not-on-origin
  git -C "$home/wt/omega" remote add upstream git@github.com:fmtest/parent.git 2>/dev/null
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a branch with somewhere else to have gone was reported as having no pull request anywhere"
  assert_contains "$report" "only origin was asked" \
    "the report did not say the answer covers origin alone"
  assert_contains "$report" "upstream" "the report did not name the other remote"
  assert_contains "$report" "unknown:" "the one-remote gap did not produce an unknown answer"
  pass "a branch whose worktree has another remote says only origin was asked"
}

test_a_branch_with_only_origin_stays_a_determinate_none() {
  local home out
  # The control for the case above: with nowhere else the branch could have
  # gone, origin answering "none" IS the whole answer and must stay silent.
  home=$(make_home discover-onlyorigin)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 0 0 fm/elsewhere
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/not-on-origin
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a branch whose only remote is origin was reported when origin already answered for all of it"
  pass "a branch whose only remote is origin keeps its determinate none"
}

test_a_found_pull_request_needs_no_remote_caveat() {
  local home out report
  # When origin does have the pull request there is no absence to qualify, so
  # the extra remote must not add a caveat to a finding that is already exact.
  home=$(make_home discover-found-upstream)
  forge_pr "$home" "$SLUG" 55 OPEN "$(commit 8)" 0 0 fm/found-here
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/found-here
  git -C "$home/wt/omega" remote add upstream git@github.com:fmtest/parent.git 2>/dev/null
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "nothing posted on $PR_BASE/55" "the discovered pull request was not reported"
  assert_not_contains "$report" "only origin was asked" \
    "a pull request that was found still carried the absence caveat"
  pass "a pull request found in origin needs no caveat about the other remotes"
}

test_a_non_github_origin_is_a_named_gap_not_a_pass() {
  local home out report
  home=$(make_home discover-gitlab)
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/elsewhere "git@gitlab.example.com:grp/proj.git"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "is not a GitHub remote, and this check reads GitHub only" \
    "a task on a non-GitHub remote was passed over instead of being named"
  assert_contains "$report" "unknown:" "a non-GitHub remote did not produce an unknown answer"
  pass "a task whose origin is not GitHub is a named unknown rather than a silent pass"
}

# --- obligation 2: an armed merge poll bound to the wrong commit ------------

test_a_poll_bound_to_a_superseded_commit_is_reported() {
  local home out
  home=$(make_home o2-owed)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0
  task "$home" beta "kind=ship" "pr=$PR_BASE/8" "pr_head=$(commit 1)"
  poll "$home" beta "$PR_BASE/8"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "the recorded head for beta is $(commit 1 | cut -c1-9)" \
    "the report does not name the superseded commit the records still hold"
  assert_contains "$(cat "$out")" "$PR_BASE/8 is at $(commit 2 | cut -c1-9)" \
    "the report does not name the live head the pull request actually has"
  pass "a merge poll bound to a superseded commit is reported"
}

test_a_poll_bound_to_the_live_commit_is_silent() {
  local home out
  home=$(make_home o2-current)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0
  task "$home" beta "kind=ship" "pr=$PR_BASE/8" "pr_head=$(commit 2)"
  poll "$home" beta "$PR_BASE/8"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a merge poll bound to the pull request's live head was reported as stale"
  pass "a merge poll bound to the live head is silent"
}

test_a_poll_on_a_closed_pull_request_is_reported() {
  local home out
  home=$(make_home o2-dead)
  # The recorded incident: a poll left watching a pull request closed hours
  # earlier. It can never fire, so nothing will ever report on that task again.
  forge_pr "$home" "$SLUG" 9 CLOSED "$(commit 3)" 1 0
  task "$home" gamma "kind=ship" "pr=$PR_BASE/9" "pr_head=$(commit 3)"
  poll "$home" gamma "$PR_BASE/9"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "the merge poll for gamma watches $PR_BASE/9, which is closed unmerged" \
    "a poll left watching a closed pull request was not reported"
  pass "a merge poll watching a closed unmerged pull request is reported"
}

test_a_poll_on_a_merged_pull_request_is_silent() {
  local home out
  home=$(make_home o2-merged)
  # That poll is doing its job: its next sweep prints `merged` and retires it.
  forge_pr "$home" "$SLUG" 9 MERGED "$(commit 4)" 1 0
  task "$home" gamma "kind=ship" "pr=$PR_BASE/9" "pr_head=$(commit 3)"
  poll "$home" gamma "$PR_BASE/9"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a poll whose pull request merged was reported instead of being left to fire"
  pass "a merge poll whose pull request has merged is silent"
}

# The poll sidecar is the other record obligation 2 rests on. An unreadable one
# used to be dropped with nothing said, so a poll left bound to a superseded
# commit - the exact miss obligation 2 exists for - went unreported.
assert_poll_control_is_owed() {
  local home=$1 out
  out="$home/control.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "the recorded head for beta is" \
    "the control did not report the stale head, so this case cannot prove anything about silence"
  rm -f "$home/state/.fleet-obligations"
}

test_a_poll_record_that_cannot_be_read_is_unknown_not_clean() {
  local home out report
  home=$(make_home poll-unreadable)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0 fm/poll-unreadable
  task "$home" beta "kind=ship" "pr=$PR_BASE/8" "pr_head=$(commit 1)"
  poll "$home" beta "$PR_BASE/8"
  assert_poll_control_is_owed "$home"
  chmod 000 "$home/state/beta.pr-poll"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  chmod 644 "$home/state/beta.pr-poll"
  [ -s "$out" ] || fail "an unreadable poll record produced silence while the poll watched a superseded commit"
  assert_contains "$report" "the merge poll record for beta cannot be read" \
    "an unreadable poll record was dropped instead of reported"
  assert_contains "$report" "unknown:" "an unreadable poll record did not produce an unknown answer"
  pass "a merge poll record that cannot be read is unknown, not clean"
}

test_a_poll_record_that_is_a_symlink_is_unknown_not_clean() {
  local home out report
  home=$(make_home poll-symlink)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0 fm/poll-symlink
  task "$home" beta "kind=ship" "pr=$PR_BASE/8" "pr_head=$(commit 1)"
  poll "$home" beta "$PR_BASE/8"
  assert_poll_control_is_owed "$home"
  rm -f "$home/state/beta.pr-poll"
  ln -s /etc/hosts "$home/state/beta.pr-poll"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a symlinked poll record produced silence while the poll watched a superseded commit"
  assert_contains "$report" "the merge poll record for beta cannot be read" \
    "a symlinked poll record was followed or dropped instead of reported"
  pass "a merge poll record that is a symlink is unknown, not clean"
}

test_a_poll_record_naming_no_pull_request_is_unknown_not_clean() {
  local home out report
  home=$(make_home poll-truncated)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0 fm/poll-truncated
  task "$home" beta "kind=ship" "pr=$PR_BASE/8" "pr_head=$(commit 1)"
  poll "$home" beta "$PR_BASE/8"
  assert_poll_control_is_owed "$home"
  printf 'github\n' > "$home/state/beta.pr-poll"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a truncated poll record produced silence while the poll watched a superseded commit"
  assert_contains "$report" "the merge poll record for beta names no pull request" \
    "a poll record with no URL where its format puts one was dropped instead of reported"
  pass "a merge poll record naming no pull request is unknown, not clean"
}

test_a_home_with_no_poll_record_stays_silent() {
  local home out
  # The control for all three: no sidecar at all is not an unreadable one.
  home=$(make_home poll-absent)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0 fm/poll-absent
  task "$home" beta "kind=ship" "pr=$PR_BASE/8" "pr_head=$(commit 2)"
  task_branch "$home" beta fm/poll-absent
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a task with no armed poll at all was reported as having an unreadable one"
  pass "a task with no armed poll record is silent, not undeterminable"
}

test_a_poll_with_no_recorded_head_is_silent() {
  local home out
  home=$(make_home o2-nohead)
  forge_pr "$home" "$SLUG" 8 OPEN "$(commit 2)" 1 0
  task "$home" beta "kind=ship" "pr=$PR_BASE/8"
  poll "$home" beta "$PR_BASE/8"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a task that never recorded a head was reported as holding a stale one"
  pass "a poll with no recorded head has nothing stale to report"
}

# --- obligation 3: a landed pull request still an open call on the board ----

test_a_merged_pull_request_left_on_the_board_is_reported() {
  local home out
  home=$(make_home o3-owed)
  forge_pr "$home" "$SLUG" 11 MERGED "$(commit 5)" 1 1
  board "$home" "delta=$PR_BASE/11"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "the board still shows delta as an open call, but $PR_BASE/11 is merged" \
    "a merged pull request still on the board was not reported"
  pass "a merged pull request still shown as an open call is reported"
}

test_an_open_pull_request_on_the_board_is_silent() {
  local home out
  home=$(make_home o3-open)
  forge_pr "$home" "$SLUG" 11 OPEN "$(commit 5)" 1 1
  board "$home" "delta=$PR_BASE/11"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a board card whose pull request is still open was reported as stale"
  pass "a board card whose pull request is still open is silent"
}

test_a_home_with_no_board_is_silent() {
  local home out
  home=$(make_home o3-noboard)
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a home that has never built a board reported a stale card"
  pass "a home with no board has no card to be stale"
}

# --- obligation 4: a steered task with no design record ---------------------

test_a_steered_task_with_no_design_record_is_reported() {
  local home out
  home=$(make_home o4-owed)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 4
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "epsilon has been steered 4 times with no design record at data/epsilon/design.md" \
    "a task whose plan lives only in its steering inbox was not reported"

  # FM_OBLIGATION_STEERS defaults to 1, so a single steer is the most common
  # wake line this check will ever print, and it is captain-visible.
  local single
  single=$(make_home o4-owed-one)
  task "$single" epsilon "kind=ship"
  steer "$single" epsilon 1
  out="$single/out.txt"
  run "$single" "$out"
  assert_contains "$(cat "$out")" "epsilon has been steered once with no design record" \
    "the single-steer line does not read like something written on purpose"
  assert_not_contains "$(cat "$out")" "steered 1 times" "the single-steer line still reads \"1 times\""
  pass "a steered task with no design record is reported, and one steer reads as once"
}

test_a_steered_task_with_a_design_record_is_silent() {
  local home out
  home=$(make_home o4-design)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 4
  design_record "$home" epsilon design.md
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a task that already has a design record was reported as missing one"
  pass "a steered task with a design record is silent"
}

test_a_steered_scout_with_a_report_is_silent() {
  local home out
  home=$(make_home o4-report)
  task "$home" zeta "kind=scout"
  steer "$home" zeta 4
  design_record "$home" zeta report.md
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a scout whose report already holds its reasoning was reported as missing a design record"
  pass "a task whose report holds the reasoning is silent"
}

test_a_task_that_was_never_steered_is_silent() {
  local home out
  home=$(make_home o4-unsteered)
  # Its whole plan is in its brief, which is already durable, so nothing is owed.
  task "$home" eta "kind=ship"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a task that was never steered was reported as missing a design record"
  pass "a task that was never steered is silent"
}

test_a_secondmate_is_not_a_work_item() {
  local home out
  home=$(make_home o4-secondmate)
  task "$home" mate "kind=secondmate"
  steer "$home" mate 9
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a persistent secondmate was treated as a task owing a design record"
  pass "a secondmate is not a work item and owes none of the four"
}

# --- the undeterminable paths obligation 1's discovery added ----------------
#
# Each of these was silent, and each is proven non-vacuous by removing its own
# unknown and watching the case go red. They are separated from the cases above
# because they all live in discover_task_pull_request, which is the
# neighbourhood the suite could not see.

test_a_task_record_with_an_unusable_id_is_unknown_not_clean() {
  local home out report
  home=$(make_home bad-id)
  # A space is outside the characters a task id may use, and a record the
  # check cannot name is a record whose obligations it cannot check.
  printf 'kind=ship\n' > "$home/state/bad id.meta"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a task record with an unusable id was dropped in silence"
  assert_contains "$report" "does not carry a usable task id" "the unusable id was not named"
  assert_contains "$report" "unknown:" "an unusable task id did not produce an unknown answer"
  pass "a task record whose id cannot be used is unknown, not clean"
}

test_a_task_that_records_no_worktree_is_unknown_not_clean() {
  local home out report
  home=$(make_home no-worktree-key)
  printf 'kind=ship\nendpoint_task_id=omega\n' > "$home/state/omega.meta"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a task recording no worktree was passed over as having no pull request"
  assert_contains "$report" "omega records no worktree" "the missing worktree record was not named"
  assert_contains "$report" "unknown:" "a task recording no worktree did not produce an unknown answer"
  pass "a task that records no worktree is unknown, not clean"
}

test_a_worktree_with_no_origin_is_unknown_not_clean() {
  local home out report
  home=$(make_home no-origin)
  task "$home" omega "kind=ship"
  git -C "$home/wt/omega" checkout -q -B fm/no-origin 2>/dev/null
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a branch with no origin to ask was reported as having no pull request"
  assert_contains "$report" "no readable origin" "the missing origin was not named"
  assert_contains "$report" "unknown:" "a worktree with no origin did not produce an unknown answer"
  pass "a worktree with no origin to ask is unknown, not clean"
}

test_discovery_with_no_gh_is_unknown_not_clean() {
  local home out report status=0
  home=$(make_home discover-no-gh)
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/no-gh
  rm -f "$home/bin/gh"
  out="$home/out.txt"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=0 FM_CHECK_TIMEOUT=30 \
    PATH="$(fm_test_base_path_sans "$PATH" gh)" "$CHECK" > "$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
  report=$(cat "$out")
  [ -s "$out" ] || fail "discovery with no gh to ask produced silence"
  assert_contains "$report" "gh is not installed, so whether omega has a pull request" \
    "the absent tool was not named as the reason discovery could not answer"
  assert_contains "$report" "unknown:" "discovery without gh did not produce an unknown answer"
  pass "discovery with no gh installed is unknown naming the tool, not clean"
}

test_a_discovery_read_the_forge_refuses_is_unknown_not_clean() {
  local home out report
  home=$(make_home discover-refused)
  task "$home" omega "kind=ship"
  task_branch "$home" omega fm/refused
  out="$home/out.txt"
  run "$home" "$out" GH_FIXTURE_FAIL=1
  report=$(cat "$out")
  [ -s "$out" ] || fail "a discovery read the forge refused produced silence"
  assert_contains "$report" "the open pull requests for omega's branch fm/refused could not be read" \
    "a refused discovery read was not named"
  assert_contains "$report" "unknown:" "a refused discovery read did not produce an unknown answer"
  assert_not_contains "$report" "owed:" "a refused discovery read was turned into an owed obligation"
  pass "a discovery read the forge refuses is unknown, not clean"
}

# --- undeterminable is its own answer ---------------------------------------

test_an_unreachable_forge_is_unknown_not_clean() {
  local home out report
  home=$(make_home unreachable)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  run "$home" "$out" GH_FIXTURE_FAIL=1
  report=$(cat "$out")
  [ -s "$out" ] || fail "an unreachable forge produced silence, which means all four obligations are met"
  assert_contains "$report" "unknown: $PR_BASE/7 could not be read: the forge refused the read" \
    "an unreachable forge was not reported as an undeterminable answer with its reason"
  assert_contains "$report" "the forge said no" \
    "the forge's own explanation did not reach the report, so a rate limit reads the same as a broken token"
  assert_not_contains "$report" "owed:" \
    "an undeterminable obligation was reported as owed, which sends firstmate to do work that may not be needed"
  pass "an unreachable forge is reported as unknown, never as clean and never as owed"
}

test_a_missing_gh_is_unknown_not_clean() {
  local home out report status=0
  home=$(make_home no-gh)
  rm -f "$home/bin/gh"
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=0 FM_CHECK_TIMEOUT=30 \
    PATH="$(fm_test_base_path_sans "$PATH" gh)" "$CHECK" > "$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
  report=$(cat "$out")
  assert_contains "$report" "gh is not installed" "an absent gh was not named as the reason nothing could be read"
  assert_contains "$report" "unknown:" "an absent gh did not produce an unknown answer"
  assert_not_contains "$report" "owed:" "an absent gh was turned into an owed obligation"
  pass "an absent gh is reported as unknown naming the tool"
}

test_a_gitlab_merge_request_is_a_named_gap_not_a_pass() {
  local home out report
  home=$(make_home gitlab)
  task "$home" theta "kind=ship" "pr=https://gitlab.example.com/grp/proj/-/merge_requests/4"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "this check reads GitHub only" \
    "a GitLab merge request was passed over instead of being reported as a named gap"
  assert_contains "$report" "unknown:" "the GitLab gap was not reported as an undeterminable answer"
  pass "a GitLab merge request is a named unknown rather than a silent pass"
}

test_the_budget_running_out_is_unknown_not_dropped() {
  local home out report
  home=$(make_home budget)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  # One forge call that never answers inside a two-second sweep budget.
  run "$home" "$out" FM_OBLIGATION_BUDGET_SECS=2 GH_FIXTURE_HANG=8
  report=$(cat "$out")
  [ -s "$out" ] || fail "a sweep the budget cut short produced silence"
  assert_contains "$report" "unknown:" "a sweep the budget cut short did not report an unknown answer"
  assert_not_contains "$report" "owed:" "a pull request the budget never reached was reported as owed"
  pass "a sweep the budget cuts short reports what it could not determine"
}

test_a_read_that_times_out_says_so_rather_than_saying_nothing() {
  local home out report
  # The two failures are different actions for firstmate - wait, or fix the
  # credential - so the report has to tell them apart.
  home=$(make_home slow-forge)
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  out="$home/out.txt"
  run "$home" "$out" FM_OBLIGATION_CALL_SECS=1 GH_FIXTURE_HANG=6
  report=$(cat "$out")
  assert_contains "$report" "the forge did not answer within" \
    "a read killed at its bound was not distinguished from a read the forge refused"
  assert_not_contains "$report" "could not be read: the forge refused" \
    "a timed-out read was reported as a refusal"
  pass "a read killed at its bound says so, and says it differently from a refusal"
}

test_an_oversized_budget_is_cut_to_fit_and_named() {
  local home out
  home=$(make_home budget-cut)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 1
  out="$home/out.txt"
  run "$home" "$out" FM_CHECK_TIMEOUT=10 FM_OBLIGATION_BUDGET_SECS=90
  assert_contains "$(cat "$out")" "the sweep budget 90s was cut to 7s to stay inside the watcher check timeout of 10s" \
    "a budget larger than the watcher's own bound was cut without saying so"
  pass "a budget that cannot fit the watcher's bound is cut and the cut is named"
}

test_a_board_with_no_payload_is_unknown_not_clean() {
  local home out report
  home=$(make_home board-broken)
  printf '<html><body>no payload here</body></html>\n' > "$home/.lavish/bearings-board.html"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "carries no readable payload" "a board with no payload was passed over as having no stale card"
  assert_contains "$report" "unknown:" "an unreadable board did not produce an unknown answer"
  pass "a board whose payload slot is missing is unknown, not clean"
}

test_a_board_file_that_cannot_be_read_is_unknown_not_clean() {
  local home out report
  # Distinct from the case above: the page exists and holds a payload, but this
  # home cannot open the file at all. Silence here is the merged card sitting on
  # the board, which is the eight hours this check was built for.
  home=$(make_home board-unreadable)
  board "$home" "delta=$PR_BASE/11"
  forge_pr "$home" "$SLUG" 11 MERGED "$(commit 5)" 1 1
  chmod 000 "$home/.lavish/bearings-board.html"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  chmod 644 "$home/.lavish/bearings-board.html"
  [ -s "$out" ] || fail "a board file that cannot be read produced silence, which means all four obligations are met"
  assert_contains "$report" "cannot be read" "an unopenable board file was not named as the reason"
  assert_contains "$report" "unknown:" "an unopenable board file did not produce an unknown answer"
  pass "a board file that cannot be opened is unknown, not clean"
}

test_a_board_payload_that_is_not_json_is_unknown_not_clean() {
  local home out report
  home=$(make_home board-not-json)
  {
    printf '<html><body>\n'
    printf '<script id="bearings-data" type="application/json">\n'
    printf '{"schema":"fm-bearings-board.v1","captains_call":[ THIS IS NOT JSON\n'
    printf '</script>\n'
    printf '</body></html>\n'
  } > "$home/.lavish/bearings-board.html"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a board payload that is not JSON produced silence"
  assert_contains "$report" "is not readable JSON" "a corrupt board payload was not named as the reason"
  assert_contains "$report" "unknown:" "a corrupt board payload did not produce an unknown answer"
  pass "a board payload that will not parse is unknown, not clean"
}

test_a_board_with_no_jq_to_read_it_is_unknown_not_clean() {
  local home out report status=0
  # One of the two gaps this change states outright. A stated gap that reports
  # nothing is an unstated gap, so the statement has to be executable.
  home=$(make_home board-no-jq)
  board "$home" "delta=$PR_BASE/11"
  out="$home/out.txt"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=0 FM_CHECK_TIMEOUT=30 \
    PATH="$(fm_test_base_path_sans "$PATH" jq)" "$CHECK" > "$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a board this home has no jq to read produced silence"
  assert_contains "$report" "jq is not installed" "the absent tool was not named"
  assert_contains "$report" "unknown:" "an absent jq with a board present did not produce an unknown answer"
  pass "a board with no jq to read it is unknown naming the tool, not clean"
}

test_local_worktree_reads_stop_when_the_budget_is_spent() {
  local home out report elapsed started finished i
  # The local reads used to shrink their own bound and run anyway, so a home
  # with many such tasks grew the sweep without limit until the watcher killed
  # it - and a killed run prints nothing and writes no record, so the probe
  # clock never moves and the next sweep repeats it. That is permanent silence
  # through the one path the budget did not cover.
  home=$(make_home budget-local)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    task "$home" "stalled$i" "kind=ship"
    task_branch "$home" "stalled$i" "fm/stalled$i"
  done
  make_stalled_git "$home"
  out="$home/out.txt"
  started=$(date +%s)
  run "$home" "$out" FM_OBLIGATION_BUDGET_SECS=3 GIT_STALL_SECS=30
  finished=$(date +%s)
  elapsed=$((finished - started))
  report=$(cat "$out")
  # Twelve tasks that each used to cost up to their own clamped bound. The
  # sweep must now stop at the budget plus at most one read in flight.
  [ "$elapsed" -le 20 ] \
    || fail "a sweep over twelve stalled worktrees took ${elapsed}s, so the local reads are still not charged to the budget"
  assert_contains "$report" "the time budget ran out before the rest of the forge reads" \
    "a sweep that stopped for the budget did not say so"
  assert_not_contains "$report" "owed:" "a task the budget never reached was reported as owed"
  pass "local worktree reads are charged to the sweep budget and decline once it is spent"
}

test_targets_the_budget_never_reached_are_named_not_dropped() {
  local home out report
  # The single-target case exercises one call's own bound. This is the other
  # one: the budget is gone before the sweep reaches the remaining pull
  # requests at all, and budget_note is the only thing between them and
  # silence.
  home=$(make_home budget-unreached)
  forge_pr "$home" "$SLUG" 41 OPEN "$(commit 1)" 0 0
  forge_pr "$home" "$SLUG" 42 OPEN "$(commit 2)" 0 0
  forge_pr "$home" "$SLUG" 43 OPEN "$(commit 3)" 0 0
  task "$home" t41 "kind=ship" "pr=$PR_BASE/41" "pr_head=$(commit 1)"
  task "$home" t42 "kind=ship" "pr=$PR_BASE/42" "pr_head=$(commit 2)"
  task "$home" t43 "kind=ship" "pr=$PR_BASE/43" "pr_head=$(commit 3)"
  out="$home/out.txt"
  run "$home" "$out" FM_OBLIGATION_BUDGET_SECS=2 GH_FIXTURE_HANG=5
  report=$(cat "$out")
  [ -s "$out" ] || fail "a sweep that never reached two of its three pull requests produced silence"
  assert_contains "$report" "the time budget ran out before the rest of the forge reads" \
    "the sweep did not say the budget stopped it"
  # The aggregate alone would let the individual pull requests vanish. Each one
  # the sweep never reached has to be named, which is what the header promises.
  assert_contains "$report" "$PR_BASE/42 was not read" \
    "a pull request the budget never reached was dropped instead of named"
  assert_contains "$report" "$PR_BASE/43 was not read" \
    "a pull request the budget never reached was dropped instead of named"
  assert_not_contains "$report" "owed:" "a pull request the budget never reached was reported as owed"
  pass "every pull request the budget never reached is named, not dropped"
}

# --- silence means all four were checked and met ----------------------------

test_a_home_where_all_four_are_met_is_silent() {
  local home out
  home=$(make_home all-met)
  # One of each: a reviewed open pull request whose poll is bound to its live
  # head, a board card on that same open pull request, and a steered task with
  # a design record.
  forge_pr "$home" "$SLUG" 20 OPEN "$(commit 6)" 1 2
  task "$home" iota "kind=ship" "pr=$PR_BASE/20" "pr_head=$(commit 6)"
  poll "$home" iota "$PR_BASE/20"
  steer "$home" iota 3
  design_record "$home" iota design.md
  board "$home" "iota=$PR_BASE/20"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a home where all four obligations are met still reported something"
  # Silence has to be the result of asking, not of never getting that far.
  assert_present "$home/gh.log" "the sweep was silent because it never reached the forge at all"
  pass "silence means all four obligations were checked and found met"
}

test_an_empty_home_is_silent() {
  local home out
  home=$(make_home empty)
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "a home with no tasks and no board reported an obligation"
  pass "a home with nothing under way owes nothing"
}

# --- it observes and changes nothing ----------------------------------------

test_the_check_changes_nothing_but_its_own_record() {
  local home out before after
  home=$(make_home observer)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  forge_pr "$home" "$SLUG" 11 MERGED "$(commit 5)" 1 1
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 1)"
  poll "$home" alpha "$PR_BASE/7"
  steer "$home" alpha 2
  board "$home" "delta=$PR_BASE/11"
  before="$TMP_ROOT/observer-before.txt"
  after="$TMP_ROOT/observer-after.txt"
  ( cd "$home" && find . -type f ! -name 'gh.log' ! -name 'out.txt' -exec shasum {} \; | sort ) > "$before"
  out="$home/out.txt"
  run "$home" "$out"
  [ -s "$out" ] || fail "the observer case did not actually report anything, so it proves nothing"
  ( cd "$home" && find . -type f ! -name 'gh.log' ! -name 'out.txt' -exec shasum {} \; | sort ) > "$after"
  diff <(grep -v 'fleet-obligations' "$before") <(grep -v 'fleet-obligations' "$after") >/dev/null \
    || fail "the check changed something other than its own report record:"$'\n'"$(diff "$before" "$after" || true)"
  assert_present "$home/state/.fleet-obligations" "the check wrote no report record"
  pass "the check reads everything and writes only its own report record"
}

# --- reporting once, and reporting again ------------------------------------

test_the_same_finding_is_reported_once() {
  local home out
  home=$(make_home once)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 2
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "epsilon has been steered" "the first sweep did not report the finding"
  run "$home" "$out"
  assert_silent "$out" "an unchanged finding was reported again on the very next sweep"
  pass "an unchanged finding set is reported once rather than on every sweep"
}

test_a_new_finding_is_news() {
  local home out
  home=$(make_home news)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 2
  out="$home/out.txt"
  run "$home" "$out"
  run "$home" "$out"
  assert_silent "$out" "the unchanged set was not suppressed, so this case cannot prove the next step"
  task "$home" kappa "kind=ship"
  steer "$home" kappa 1
  run "$home" "$out"
  assert_contains "$(cat "$out")" "kappa has been steered" "a finding that appeared after a suppressed sweep was never reported"
  pass "a finding that lands after a suppressed sweep is still news"
}

test_an_undischarged_obligation_is_reported_again() {
  local home out now
  home=$(make_home repeat)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 2
  out="$home/out.txt"
  run "$home" "$out"
  run "$home" "$out"
  assert_silent "$out" "the unchanged set was not suppressed, so this case cannot prove the repeat"
  # Age the last report past the repeat horizon. Acknowledging a wake is not
  # discharging the obligation, so it has to come back.
  now=$(date +%s)
  sed "s/^reported_at=.*/reported_at=$((now - 7200))/" "$home/state/.fleet-obligations" > "$home/state/.fleet-obligations.new"
  mv -f "$home/state/.fleet-obligations.new" "$home/state/.fleet-obligations"
  run "$home" "$out" FM_OBLIGATION_REPEAT=3600
  assert_contains "$(cat "$out")" "epsilon has been steered" \
    "an obligation still owed an hour later went quiet instead of coming back"
  pass "an obligation that is still owed is reported again once the repeat horizon passes"
}

test_a_silent_sweep_does_not_push_the_repeat_horizon_out() {
  local home out now recorded probed
  home=$(make_home horizon)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 2
  out="$home/out.txt"
  run "$home" "$out"
  now=$(date +%s)
  sed "s/^reported_at=.*/reported_at=$((now - 100))/" "$home/state/.fleet-obligations" > "$home/state/.fleet-obligations.new"
  mv -f "$home/state/.fleet-obligations.new" "$home/state/.fleet-obligations"
  run "$home" "$out"
  assert_silent "$out" "the unchanged set was reported again too early"
  recorded=$(grep '^reported_at=' "$home/state/.fleet-obligations" | cut -d= -f2)
  [ "$recorded" = "$((now - 100))" ] \
    || fail "a silent sweep rewrote the report clock, so each suppressed sweep would push the repeat another interval away"
  # The probe clock is the other half: it MUST move, or the no-probe interval
  # never engages on a home whose finding set stops changing.
  probed=$(grep '^epoch=' "$home/state/.fleet-obligations" | cut -d= -f2)
  [ "$probed" -ge "$now" ] \
    || fail "a silent sweep left the probe clock behind, so the no-probe interval would never engage"
  pass "a suppressed sweep moves the probe clock and leaves the report clock alone"
}

test_a_home_where_all_four_are_met_stops_reading_the_forge() {
  local home out calls sweep
  # The steady state. An all-met home's finding set is empty every sweep and so
  # never changes; when the record was written only on a change, its clock
  # stayed at zero and the forge was read on every single watcher sweep - the
  # full cost paid permanently by exactly the homes where nothing is wrong.
  home=$(make_home met-rate)
  forge_pr "$home" "$SLUG" 20 OPEN "$(commit 6)" 1 2
  task "$home" iota "kind=ship" "pr=$PR_BASE/20" "pr_head=$(commit 6)"
  out="$home/out.txt"
  for sweep in 1 2 3 4 5; do
    local status=0
    env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
      FM_OBLIGATION_INTERVAL=900 FM_CHECK_TIMEOUT=30 \
      PATH="$home/bin:$PATH" "$CHECK" > "$out" 2>&1 || status=$?
    expect_code 0 "$status" "sweep $sweep exit"
    assert_silent "$out" "an all-met home reported on sweep $sweep"
  done
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "five sweeps of an all-met home made $calls forge reads, so the no-probe interval never engaged"
  assert_present "$home/state/.fleet-obligations" "an all-met sweep wrote no record, so it has no probe clock to gate on"
  pass "an all-met home probes once per interval rather than on every sweep"
}

test_the_forge_is_not_read_between_intervals() {
  local home out now calls
  home=$(make_home interval)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 1 1
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  run "$home" "$out"
  # Age the probe clock forward on the record the sweep above actually wrote,
  # rather than hand-writing one: a hand-written record has to name the schema,
  # and a stale literal there would silently disable this whole case.
  now=$(date +%s)
  sed "s/^epoch=.*/epoch=$now/" "$home/state/.fleet-obligations" > "$home/state/.fleet-obligations.new"
  mv -f "$home/state/.fleet-obligations.new" "$home/state/.fleet-obligations"
  : > "$home/gh.log"
  local status=0
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=900 FM_CHECK_TIMEOUT=30 \
    PATH="$home/bin:$PATH" "$CHECK" > "$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 0 ] || fail "the forge was read $calls times inside the no-probe interval"
  assert_silent "$out" "a sweep inside the no-probe interval still reported"
  pass "the forge is not read again until the probe interval has passed"
}

# --- an input that cannot be read or resolved is never "met" ----------------

test_a_record_spelled_in_another_case_still_reports() {
  local home out
  # GitHub owner and repository names are case-insensitive and gh answers in
  # its own canonical spelling, so a locally recorded URL that differs only in
  # case names the same pull request. Matching on the raw string made that
  # record read successfully at the forge and then match nothing, and fall
  # through to "met" - silence while the obligation was owed.
  home=$(make_home case-card)
  forge_pr "$home" "$SLUG" 11 MERGED "$(commit 5)" 1 1
  board "$home" "delta=https://github.com/FmTest/Repo/pull/11"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "the board still shows delta as an open call" \
    "a board card recorded in another case was read as met"

  local task_home
  task_home=$(make_home case-task)
  forge_pr "$task_home" "$SLUG" 7 OPEN "$(commit 7)" 0 0
  task "$task_home" alpha "kind=ship" "pr=https://github.com/FmTest/Repo/pull/7"
  out="$task_home/out.txt"
  run "$task_home" "$out"
  assert_contains "$(cat "$out")" "nothing posted on" \
    "a task pull request recorded in another case was read as met"
  pass "a record spelled in another case names the same pull request, not a met obligation"
}

test_one_pull_request_spelled_two_ways_is_one_read() {
  local home out calls
  home=$(make_home case-dedupe)
  forge_pr "$home" "$SLUG" 11 MERGED "$(commit 5)" 1 1
  task "$home" alpha "kind=ship" "pr=https://github.com/FmTest/Repo/pull/11"
  board "$home" "delta=$PR_BASE/11"
  out="$home/out.txt"
  run "$home" "$out"
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "one pull request spelled two ways cost $calls forge calls, so the dedupe is still keyed on the raw string"
  pass "one pull request spelled two ways is one canonical identity and one read"
}

test_an_unreadable_task_record_is_unknown_not_clean() {
  local home out report
  # A task record this home cannot read starts obligations 1, 2 and 4. Dropping
  # it removes that whole task from the report in silence.
  home=$(make_home meta-unreadable)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 3
  chmod 000 "$home/state/epsilon.meta"
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  chmod 644 "$home/state/epsilon.meta"
  [ -s "$out" ] || fail "an unreadable task record produced silence, which means all four obligations are met"
  assert_contains "$report" "the task record for epsilon cannot be read" \
    "an unreadable task record was dropped instead of reported as undeterminable"
  assert_contains "$report" "unknown:" "an unreadable task record did not produce an unknown answer"
  pass "a task record that cannot be read is unknown, never met"
}

test_a_forge_answer_with_no_content_is_unknown_not_clean() {
  local home out report
  # gh exiting 0 with nothing on stdout resolves nothing. Treating that as a
  # completed read leaves the pull request silently unaccounted for.
  home=$(make_home empty-answer)
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  # The repository fixture exists but holds no such pull request, so the
  # fixture's own select produces an empty answer at exit status 0.
  forge_pr "$home" "$SLUG" 99 OPEN "$(commit 1)" 0 0
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ -s "$out" ] || fail "a forge answer with no content produced silence"
  assert_contains "$report" "the forge answered with nothing" \
    "an empty forge answer was not named as the reason the pull request is undeterminable"
  assert_not_contains "$report" "owed:" "an empty forge answer was turned into an owed obligation"
  pass "a forge answer with no content is unknown, never met"
}

# --- the forge is asked once per distinct pull request ----------------------

test_obligation_four_is_not_gated_by_the_forge_interval() {
  local home out calls
  # The interval is a rate limit on the forge. Obligation 4 costs no forge call
  # at all, so gating it delayed an owed obligation by up to a whole interval
  # and saved nothing.
  home=$(make_home local-not-gated)
  forge_pr "$home" "$SLUG" 20 OPEN "$(commit 6)" 1 2 fm/met
  task "$home" iota "kind=ship" "pr=$PR_BASE/20" "pr_head=$(commit 6)"
  out="$home/out.txt"
  # First sweep at the real interval: all met, silent, and it sets the clock.
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=900 FM_CHECK_TIMEOUT=30 PATH="$home/bin:$PATH" \
    "$CHECK" > "$out" 2>&1 || fail "the first sweep exited non-zero"
  assert_silent "$out" "the all-met home reported on its first sweep"

  # A new task appears, steered, with no design record. It must be reported
  # now, not after the interval.
  task "$home" beta "kind=ship"
  steer "$home" beta 2
  : > "$home/gh.log"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=900 FM_CHECK_TIMEOUT=30 PATH="$home/bin:$PATH" \
    "$CHECK" > "$out" 2>&1 || fail "the gated sweep exited non-zero"
  assert_contains "$(cat "$out")" "beta has been steered 2 times with no design record" \
    "an obligation costing no forge call was suppressed by the forge's own rate limit"
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 0 ] \
    || fail "the gated sweep made $calls forge reads, so the interval stopped gating what it is for"
  pass "obligation 4 is evaluated inside the no-probe interval, and the forge still is not read"
}

test_a_gated_sweep_keeps_the_forge_findings_it_is_not_rechecking() {
  local home out
  # A gated sweep must neither re-report the forge half as news nor drop it
  # from the record, or the next full sweep would read as changed.
  home=$(make_home gated-carry)
  forge_pr "$home" "$SLUG" 7 OPEN "$(commit 7)" 0 0 fm/carry
  task "$home" alpha "kind=ship" "pr=$PR_BASE/7" "pr_head=$(commit 7)"
  out="$home/out.txt"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=900 FM_CHECK_TIMEOUT=30 PATH="$home/bin:$PATH" \
    "$CHECK" > "$out" 2>&1 || fail "the first sweep exited non-zero"
  assert_contains "$(cat "$out")" "nothing posted on $PR_BASE/7" "the first sweep did not report the forge finding"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    FM_OBLIGATION_INTERVAL=900 FM_CHECK_TIMEOUT=30 PATH="$home/bin:$PATH" \
    "$CHECK" > "$out" 2>&1 || fail "the gated sweep exited non-zero"
  assert_silent "$out" "a gated sweep re-reported the forge finding it did not recheck"
  grep -q "^owed_forge=.*pull/7" "$home/state/.fleet-obligations" \
    || fail "a gated sweep dropped the forge finding from the record, so the next full sweep would read it as news"
  pass "a gated sweep carries the forge findings forward instead of re-reporting or dropping them"
}

test_one_read_covers_a_pull_request_every_obligation_names() {
  local home out calls
  home=$(make_home one-call)
  # The same pull request is a task's own, an armed poll's, and a board card's.
  # That is one question about one pull request, so it must cost one read.
  forge_pr "$home" "$SLUG" 41 MERGED "$(commit 1)" 1 1
  task "$home" t41 "kind=ship" "pr=$PR_BASE/41" "pr_head=$(commit 1)"
  poll "$home" t41 "$PR_BASE/41"
  board "$home" "t41=$PR_BASE/41"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "the board still shows t41 as an open call" "the single read did not answer the board's question"
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "one pull request named by three obligations cost $calls forge calls instead of one"
  pass "one read answers every obligation that names the same pull request"
}

test_the_forge_is_asked_only_about_this_home_s_own_work() {
  local home out calls
  home=$(make_home scoped)
  # Three of the repository's pull requests are open, and this home watches one.
  # The cost must follow this home's work, not the size of the repository.
  forge_pr "$home" "$SLUG" 41 OPEN "$(commit 1)" 0 0
  forge_pr "$home" "$SLUG" 42 OPEN "$(commit 2)" 0 0
  forge_pr "$home" "$SLUG" 43 OPEN "$(commit 3)" 0 0
  task "$home" t42 "kind=ship" "pr=$PR_BASE/42" "pr_head=$(commit 2)"
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "$PR_BASE/42" "the watched pull request was not reported"
  assert_not_contains "$(cat "$out")" "$PR_BASE/41" "a pull request this home does not watch was reported"
  calls=$(wc -l < "$home/gh.log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "watching one of three open pull requests cost $calls forge calls, so the cost is set by the repository rather than by this home"
  pass "the forge is asked only about the pull requests this home is watching"
}

# --- the printed line stays one line and hides nothing silently -------------

test_an_overlong_report_says_how_much_is_not_shown() {
  local home out report i
  home=$(make_home cut)
  for i in $(seq 1 30); do
    task "$home" "task-with-a-deliberately-long-identifier-$i" "kind=ship"
    steer "$home" "task-with-a-deliberately-long-identifier-$i" 3
  done
  out="$home/out.txt"
  run "$home" "$out"
  report=$(cat "$out")
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must stay one line for the wake record"
  assert_contains "$report" "more; run: bin/fm-obligation-check.sh report" \
    "an over-long report was cut without saying how much it did not show"
  # Nothing may be lost: the full set has to be readable from the record.
  [ "$(FM_HOME="$home" "$CHECK" report | grep -c 'has been steered')" = 30 ] \
    || fail "the findings past the printed cut are not recoverable from the report action"
  pass "an over-long report names what it cut and keeps all of it readable"
}

test_report_states_plainly_when_nothing_is_owed() {
  local home out
  # "All four met" has to come from a record that says so, so the record is
  # made by a real sweep of a home where they are met.
  home=$(make_home report-clean)
  forge_pr "$home" "$SLUG" 20 OPEN "$(commit 6)" 1 2 fm/report-clean
  task "$home" iota "kind=ship" "pr=$PR_BASE/20" "pr_head=$(commit 6)"
  out="$home/out.txt"
  run "$home" "$out"
  assert_silent "$out" "the all-met fixture reported something, so this case cannot prove the report line"
  FM_HOME="$home" "$CHECK" report | grep -q 'all four obligations met' \
    || fail "report did not say plainly that the last check found everything met"
  pass "report says plainly when the last check found all four met"
}

# report takes no reading of its own, so a record it cannot use is not an
# answer. Saying "all four obligations met" there inverts the one sentence this
# check sells, in the action whose whole job is to show what the cut hid.
assert_report_declines() {
  local home=$1 why=$2 label=$3 out
  out=$(FM_HOME="$home" "$CHECK" report 2>&1)
  case "$out" in
    *"all four obligations met"*)
      fail "$label: report claimed all four obligations met from a record it could not use"
      ;;
  esac
  assert_contains "$out" "no findings could be read" "$label: report did not say it read no findings"
  assert_contains "$out" "$why" "$label: report did not say why the record could not be used"
}

test_report_declines_a_record_it_cannot_use() {
  local home out
  home=$(make_home report-unusable)
  task "$home" alpha "kind=ship"
  steer "$home" alpha 1
  out="$home/out.txt"
  run "$home" "$out"
  assert_contains "$(cat "$out")" "alpha has been steered once" "the fixture did not record an owed obligation"
  FM_HOME="$home" "$CHECK" report | grep -q 'alpha has been steered once' \
    || fail "report did not print the owed obligation from a record it could read"

  # Every home already running an earlier version holds a previous-schema
  # record the moment a new one lands, so this is the first case a live home
  # meets rather than a hypothetical.
  cp "$home/state/.fleet-obligations" "$home/state/.fleet-obligations.keep"
  sed 's/^fm-fleet-obligations-v2$/fm-fleet-obligations-v1/' "$home/state/.fleet-obligations.keep" \
    > "$home/state/.fleet-obligations"
  assert_report_declines "$home" "is not a fm-fleet-obligations-v2 record" "previous schema"

  cp "$home/state/.fleet-obligations.keep" "$home/state/.fleet-obligations"
  chmod 000 "$home/state/.fleet-obligations"
  assert_report_declines "$home" "cannot be read" "unreadable record"
  chmod 644 "$home/state/.fleet-obligations"

  : > "$home/state/.fleet-obligations"
  assert_report_declines "$home" "is empty" "empty record"

  rm -f "$home/state/.fleet-obligations"
  assert_report_declines "$home" "no check has recorded a reading" "absent record"
  pass "report declines a record it cannot use instead of answering all four met"
}

test_report_leaks_no_raw_shell_error() {
  local home out
  # The unreadable case used to put a bash redirect error on the operator's
  # terminal beside the wrong answer.
  home=$(make_home report-noleak)
  task "$home" alpha "kind=ship"
  steer "$home" alpha 1
  out="$home/out.txt"
  run "$home" "$out"
  chmod 000 "$home/state/.fleet-obligations"
  out=$(FM_HOME="$home" "$CHECK" report 2>&1)
  chmod 644 "$home/state/.fleet-obligations"
  assert_not_contains "$out" "Permission denied" "report leaked a raw shell error to the operator"
  pass "report names the unreadable record rather than leaking a shell error"
}

# --- refusals and arming ----------------------------------------------------

test_invalid_settings_and_actions_refuse() {
  local home status
  home=$(make_home refuse)
  status=0
  env FM_HOME="$home" FM_OBLIGATION_CALL_SECS=0 "$CHECK" check >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a call bound of zero must refuse"
  status=0
  env FM_HOME="$home" FM_OBLIGATION_INTERVAL=5 "$CHECK" check >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an out-of-range interval must refuse"
  status=0
  env FM_HOME="$home" "$CHECK" wobble >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown action must refuse"
  pass "an unusable setting or action refuses rather than checking something else"
}

test_arm_registers_the_check_and_disarm_retires_it() {
  local home mode
  home=$(make_home arm)
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/fleet-obligations.check.sh" "arm did not write the check shim"
  assert_present "$home/state/fleet-obligations.check-trust" "arm did not bind the shim's bytes"
  mode=$(stat -c %a "$home/state/fleet-obligations.check.sh" 2>/dev/null \
    || stat -f %Lp "$home/state/fleet-obligations.check.sh")
  [ "$mode" = 700 ] || fail "the check shim is mode $mode, not 700"
  assert_grep 'fm-custom-check-v1' "$home/state/fleet-obligations.check-trust" "the trust binding has the wrong schema"

  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arming twice failed"
  assert_grep 'fm-custom-check-v1' "$home/state/fleet-obligations.check-trust" "re-arming lost the trust binding"

  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/fleet-obligations.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/fleet-obligations.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.fleet-obligations" "disarm left the report record behind"
  # disarm is not permanent, and it has to say so: the next locked bootstrap
  # arms the check again for any home with a task or a board.
  FM_HOME="$home" "$CHECK" disarm 2>&1 | grep -q 'the next locked bootstrap arms it again' \
    || fail "disarm did not say that bootstrap re-arms the check"
  pass "arm registers a trusted check, and disarm retires it and says it is not permanent"
}

test_if_needed_arms_only_a_home_with_something_to_report_on() {
  local home
  # A registered custom check makes supervision REQUIRED for a home
  # (bin/fm-supervision-lib.sh), so a home with no task and no board must not be
  # armed into keeping a watcher alive to report on nothing.
  home=$(make_home arm-empty)
  FM_HOME="$home" "$CHECK" arm --if-needed >/dev/null || fail "arm --if-needed failed on an empty home"
  assert_absent "$home/state/fleet-obligations.check.sh" "an empty home was armed into needing a watcher"

  # A live task: supervision is required for the task anyway, so arming is free.
  task "$home" epsilon "kind=ship"
  FM_HOME="$home" "$CHECK" arm --if-needed >/dev/null || fail "arm --if-needed failed on a home with a task"
  assert_present "$home/state/fleet-obligations.check.sh" "a home with a live task was left unarmed"

  # A board with no task at all: the eight-hour stale card is exactly this case.
  local board_home
  board_home=$(make_home arm-board)
  board "$board_home" "delta=$PR_BASE/11"
  FM_HOME="$board_home" "$CHECK" arm --if-needed >/dev/null || fail "arm --if-needed failed on a home with a board"
  assert_present "$board_home/state/fleet-obligations.check.sh" "a home whose board can hold a stale card was left unarmed"
  pass "--if-needed arms a home that has something to report on and leaves an empty one alone"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target mode status=0
  # Following a symlink here would write the shim body into a file someone else
  # owns and then make that file executable. Refusing means the target is left
  # exactly as it was, content and mode; the dangling link itself is cleared,
  # because a home holding a shim with no trust binding wakes firstmate about an
  # unauthenticated state check on every watcher cycle.
  home=$(make_home arm-symlink)
  target="$home/not-the-shim.txt"
  printf 'a file the shim must not touch\n' > "$target"
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
  ln -s "$target" "$home/state/fleet-obligations.check.sh"
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "arm followed a symlink at the shim path"
  [ "$(cat "$target")" = 'a file the shim must not touch' ] || fail "arm followed the symlink and overwrote its target"
  [ "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" = "$mode" ] \
    || fail "arm changed the mode of the symlink's target"
  assert_absent "$home/state/fleet-obligations.check-trust" "a refused arm still wrote a trust binding"
  pass "a symlink at the shim path is refused instead of followed"
}

test_the_armed_check_reaches_the_watcher_as_a_wake() {
  local home out err status=0
  home=$(make_home wake)
  task "$home" epsilon "kind=ship"
  steer "$home" epsilon 3
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not arm the obligation check"
  out="$home/wake-out.txt"
  err="$home/wake-err.txt"
  env FM_HOME="$home" GH_FORGE="$home/forge" GH_LOG="$home/gh.log" \
    PATH="$home/bin:$PATH" FM_CHECK_TIMEOUT=30 FM_OBLIGATION_INTERVAL=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 > "$out" 2> "$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "epsilon has been steered" "the wake did not carry the obligation report"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

test_open_pull_request_with_nothing_posted_is_reported
test_a_reviewed_pull_request_is_silent
test_a_commented_pull_request_is_silent
test_a_closed_pull_request_is_not_owed_a_review
test_a_pull_request_nobody_recorded_is_still_found
test_a_discovered_pull_request_that_is_reviewed_is_silent
test_a_branch_with_no_pull_request_is_silent
test_a_task_that_has_not_branched_yet_is_silent_and_costs_nothing
test_a_pull_request_named_only_by_the_armed_poll_costs_no_discovery
test_discovery_is_skipped_for_a_task_that_already_records_its_pull_request
test_a_worktree_that_is_gone_is_unknown_not_clean
test_a_worktree_that_is_not_a_repository_is_unknown_not_clean
test_a_worktree_whose_git_cannot_be_read_is_unknown_not_clean
test_a_worktree_read_that_hits_its_bound_is_unknown_not_clean
test_a_branch_read_that_cannot_be_established_is_unknown_not_clean
test_a_remote_list_that_cannot_be_read_is_unknown_not_clean
test_a_branch_with_another_remote_says_only_origin_was_asked
test_a_branch_with_only_origin_stays_a_determinate_none
test_a_found_pull_request_needs_no_remote_caveat
test_a_non_github_origin_is_a_named_gap_not_a_pass
test_a_poll_bound_to_a_superseded_commit_is_reported
test_a_poll_bound_to_the_live_commit_is_silent
test_a_poll_on_a_closed_pull_request_is_reported
test_a_poll_on_a_merged_pull_request_is_silent
test_a_poll_record_that_cannot_be_read_is_unknown_not_clean
test_a_poll_record_that_is_a_symlink_is_unknown_not_clean
test_a_poll_record_naming_no_pull_request_is_unknown_not_clean
test_a_home_with_no_poll_record_stays_silent
test_a_poll_with_no_recorded_head_is_silent
test_a_merged_pull_request_left_on_the_board_is_reported
test_an_open_pull_request_on_the_board_is_silent
test_a_home_with_no_board_is_silent
test_a_steered_task_with_no_design_record_is_reported
test_a_steered_task_with_a_design_record_is_silent
test_a_steered_scout_with_a_report_is_silent
test_a_task_that_was_never_steered_is_silent
test_a_secondmate_is_not_a_work_item
test_a_task_record_with_an_unusable_id_is_unknown_not_clean
test_a_task_that_records_no_worktree_is_unknown_not_clean
test_a_worktree_with_no_origin_is_unknown_not_clean
test_discovery_with_no_gh_is_unknown_not_clean
test_a_discovery_read_the_forge_refuses_is_unknown_not_clean
test_an_unreachable_forge_is_unknown_not_clean
test_a_missing_gh_is_unknown_not_clean
test_a_gitlab_merge_request_is_a_named_gap_not_a_pass
test_a_read_that_times_out_says_so_rather_than_saying_nothing
test_the_budget_running_out_is_unknown_not_dropped
test_an_oversized_budget_is_cut_to_fit_and_named
test_a_board_with_no_payload_is_unknown_not_clean
test_a_board_file_that_cannot_be_read_is_unknown_not_clean
test_a_board_payload_that_is_not_json_is_unknown_not_clean
test_a_board_with_no_jq_to_read_it_is_unknown_not_clean
test_local_worktree_reads_stop_when_the_budget_is_spent
test_targets_the_budget_never_reached_are_named_not_dropped
test_a_home_where_all_four_are_met_is_silent
test_an_empty_home_is_silent
test_the_check_changes_nothing_but_its_own_record
test_the_same_finding_is_reported_once
test_a_new_finding_is_news
test_an_undischarged_obligation_is_reported_again
test_a_silent_sweep_does_not_push_the_repeat_horizon_out
test_a_home_where_all_four_are_met_stops_reading_the_forge
test_the_forge_is_not_read_between_intervals
test_a_record_spelled_in_another_case_still_reports
test_one_pull_request_spelled_two_ways_is_one_read
test_an_unreadable_task_record_is_unknown_not_clean
test_a_forge_answer_with_no_content_is_unknown_not_clean
test_obligation_four_is_not_gated_by_the_forge_interval
test_a_gated_sweep_keeps_the_forge_findings_it_is_not_rechecking
test_one_read_covers_a_pull_request_every_obligation_names
test_the_forge_is_asked_only_about_this_home_s_own_work
test_an_overlong_report_says_how_much_is_not_shown
test_report_states_plainly_when_nothing_is_owed
test_report_declines_a_record_it_cannot_use
test_report_leaks_no_raw_shell_error
test_invalid_settings_and_actions_refuse
test_arm_registers_the_check_and_disarm_retires_it
test_if_needed_arms_only_a_home_with_something_to_report_on
test_arm_refuses_a_symlink_at_the_shim_path
test_the_armed_check_reaches_the_watcher_as_a_wake
