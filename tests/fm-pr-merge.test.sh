#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# The test_* functions below name the covered merge, refusal, live-head,
# away-authority, outcome-publication, and recovery behavior directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Build a fresh sandbox for one test case: a state dir with task metadata and a
# directory for its forge-command mocks. Echoes the case directory.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  : > "$case_dir/gh.log"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# One review the way GitHub reports it in the pull request's reviews array, so
# a case drives the approval gate with the forge's own shape rather than a
# field invented here. The body is JSON-escaped by jq, so a case may pass a
# multi-line review body verbatim.
# Args: state commit_oid author_login [body] [submittedAt]
review_entry() {
  local state=$1 oid=$2 login=$3 body=${4:-} submitted=${5:-2026-09-20T09:00:00Z}
  local assoc=${6:-COLLABORATOR}
  # shellcheck disable=SC2016  # jq, not the shell, expands these --arg names.
  "$JQ_BIN" -nc \
    --arg state "$state" --arg oid "$oid" --arg login "$login" \
    --arg body "$body" --arg at "$submitted" --arg assoc "$assoc" \
    '{state: $state, commit: {oid: $oid}, author: {login: $login}, authorAssociation: $assoc, submittedAt: $at, body: $body}'
}

# The review the fleet actually posts today: GitHub refuses --approve from the
# one account that opened the pull request, so the verdict is the last line of
# a COMMENTED review body. Args: oid [login] [authorAssociation]
approving_review() {
  review_entry COMMENTED "$1" "${2:-reviewer}" \
    'R1 naming, preference, low.

Review verdict: APPROVED' \
    2026-09-20T09:00:00Z "${3:-COLLABORATOR}"
}

# Live GitHub JSON for the pre-merge verify, plus gh-axi for the
# post-merge fallback view. Merge itself is `gh pr merge --match-head-commit`.
# Args: case_dir head_sha [rollup_json] [reviews_json] [pr_author_login]
write_github_view_json() {
  local case_dir=$1 head=$2
  local rollup=${3:-'{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}'}
  local author=${5:-worker} reviews
  # An explicitly empty fourth argument means a pull request with no reviews,
  # while omitting it means the ordinary approved shape every other case wants.
  if [ "$#" -ge 4 ]; then reviews=$4; else reviews=$(approving_review "$head"); fi
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","author":{"login":"$author"},"reviews":[$reviews],"statusCheckRollup":[$rollup]}
JSON
}

write_github_live_json() {
  write_github_view_json "$1" "$2"
}

write_github_red_json() {
  local case_dir=$1 head=$2 name=$3
  write_github_view_json "$case_dir" "$head" \
    "{\"__typename\":\"CheckRun\",\"name\":\"$name\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}"
}

# One CheckRun rollup entry the way GitHub reports it. A conclusion or timestamp
# of "-" is emitted as JSON null. Args: name status conclusion [startedAt]
# [completedAt]
check_run() {
  local name=$1 status=$2 conclusion=$3 started=${4:--} completed=${5:-${4:--}}
  local conclusion_json='null' started_json='null' completed_json='null'
  [ "$conclusion" = - ] || conclusion_json="\"$conclusion\""
  [ "$started" = - ] || started_json="\"$started\""
  [ "$completed" = - ] || completed_json="\"$completed\""
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":%s,"completedAt":%s}' \
    "$name" "$status" "$conclusion_json" "$started_json" "$completed_json"
}

status_context() {
  local name=$1 state=$2
  printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$name" "$state"
}

# Live GitHub JSON whose rollup holds the given entries verbatim, so a test can
# put several runs of one check name at the same head the way GitHub does after
# it cancels a pull request's in-flight run and re-triggers it. mergeStateStatus
# stays CLEAN because that is what GitHub reports for exactly this case.
# Args: case_dir head_sha <rollup-entry-json>...
write_github_rollup_json() {
  local case_dir=$1 head=$2 entry rollup=''
  shift 2
  for entry in "$@"; do
    rollup="${rollup:+$rollup,}$entry"
  done
  write_github_view_json "$case_dir" "$head" "$rollup"
}

assert_logged_gh_merge() {
  local case_dir=$1 number=$2 repo=$3 head line extra=
  shift 3
  head=$(cat "$case_dir/github-head")
  [ "$#" -eq 0 ] || extra=" $*"
  line="pr merge $number --repo $repo --match-head-commit $head$extra"
  grep -qxF "$line" "$case_dir/gh.log" \
    || fail "expected gh merge line: $line"$'\n'"got: $(grep '^pr merge ' "$case_dir/gh.log" || true)"
}

add_gh_mocks() {
  local case_dir=$1 head=$2
  write_github_live_json "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        # A forge read that does not answer: rate limit, network, auth, or any
        # other error gh exits nonzero for.
        if [ -f "${FM_TEST_GH_VIEW_FAILS:-}" ]; then
          echo 'error: API rate limit exceeded' >&2
          exit 1
        fi
        cat "$FM_TEST_GH_VIEW_JSON"
        if [ -f "${FM_TEST_AWAY_RECORD_AFTER_VIEW:-}" ]; then
          cp "$FM_TEST_AWAY_RECORD_AFTER_VIEW" "$FM_STATE_OVERRIDE/.afk-contract"
        fi
        exit 0
        ;;
      *headRefOid*)
        cat "$FM_TEST_GH_HEAD"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    if [ -n "${FM_TEST_META_AT_MERGE:-}" ] && [ -f "${FM_STATE_OVERRIDE:-}/task-x1.meta" ]; then
      cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    fi
    # The forge call runs inside the merge's critical section, so a real
    # away-record change attempted from here is the TOCTOU itself: whatever
    # happens to it happens between the authority read and the merge.
    if [ -x "${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" ]; then
      away_rc=0
      "$FM_TEST_AWAY_MUTATE_AT_MERGE" > "$FM_TEST_AWAY_MUTATE_OUT" 2>&1 || away_rc=$?
      printf '%s\n' "$away_rc" > "$FM_TEST_AWAY_MUTATE_RC"
      "$FM_TEST_ROOT/bin/fm-afk-contract.sh" grants \
        > "$FM_TEST_AWAY_GRANTS_AT_MERGE" 2>/dev/null \
        || printf 'no-live-record\n' > "$FM_TEST_AWAY_GRANTS_AT_MERGE"
    fi
    if [ -n "${FM_TEST_GH_MERGE_OUTPUT:-}" ]; then
      printf '%s\n' "$FM_TEST_GH_MERGE_OUTPUT"
    else
      printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    fi
    merge_rc=0
    if [ -f "${FM_TEST_GH_MERGE_RC_FILE:-}" ]; then
      merge_rc=$(cat "$FM_TEST_GH_MERGE_RC_FILE")
    fi
    exit "$merge_rc"
    ;;
  "api graphql")
    if [ -f "${FM_TEST_GH_GRAPHQL_FAIL:-}" ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    if [ -f "${FM_TEST_GH_RULES_FAIL_BODY:-}" ]; then
      cat "$FM_TEST_GH_RULES_FAIL_BODY" >&2
      exit 1
    fi
    if [ -f "${FM_TEST_GH_RULES_FAIL:-}" ]; then
      exit 1
    fi
    cat "$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that fails the merge call but succeeds live verify, so a real merge
# failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  local head=${2:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
  add_gh_mocks "$case_dir" "$head"
  printf '1\n' > "$case_dir/github-merge-rc"
  printf 'error: pr merge failed\n' > "$case_dir/github-merge-output"
}

# Flag the shared gh mock so GraphQL outcome reads fail while live verify and
# merge still succeed. Args: case_dir [head_sha ignored]
add_gh_mock_outcome_read_fails() {
  local case_dir=$1
  : > "$case_dir/github-graphql-fail"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    if [ -e "$case_dir/glab-view-fails" ]; then
      echo 'error: GET https://gitlab.example/api/v4: 429 Too Many Requests' >&2
      exit 1
    fi
    if [ -e "$case_dir/glab-merge-called" ] && [ -e "$case_dir/glab-post-merge-view-fails" ]; then
      # The read AFTER the forge accepted the merge. What the client says here
      # is the only evidence of whether the merge landed.
      echo 'error: GET https://gitlab.example/api/v4: 502 Bad Gateway' >&2
      exit 1
    fi
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
  api\ *)
    if [ -e "$case_dir/glab-approvals-fail" ]; then
      # The real client writes its reason to stderr; a mock that exits silently
      # leaves the branch that keeps that text undriven.
      echo 'error: GET https://gitlab.example/api/v4: 401 Unauthorized' >&2
      exit 1
    fi
    if [ -e "$case_dir/glab-approvals.json" ]; then
      cat "$case_dir/glab-approvals.json"
    else
      printf '{"approved_by":[{"user":{"username":"reviewer"}}]}\n'
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  local merge_when_pipeline_succeeds=false merge_after=null author=mrauthor
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      merge_when_pipeline_succeeds) merge_when_pipeline_succeeds=$value ;;
      merge_after) merge_after=$value ;;
      author) author=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  {
    printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
      "$state" "$detail" "$conflicts"
    printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s,' \
      "$discussions" "$head" "$pipeline"
    printf '"author":{"username":"%s"},' "$author"
    printf '"merge_when_pipeline_succeeds":%s,"merge_after":%s}\n' \
      "$merge_when_pipeline_succeeds" "$merge_after"
  } > "$file"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  write_mr_json "$case_dir/mr-post.json" state=merged
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
  FM_TEST_GH_VIEW_FAILS="$case_dir/github-view-fails" \
  FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_MERGE_RC_FILE="$case_dir/github-merge-rc" \
  FM_TEST_GH_MERGE_OUTPUT="$(cat "$case_dir/github-merge-output" 2>/dev/null || true)" \
  FM_TEST_GH_GRAPHQL_FAIL="$case_dir/github-graphql-fail" \
  FM_TEST_GH_RULES_FAIL="$case_dir/github-rules-fail" \
  FM_TEST_GH_RULES_FAIL_BODY="$case_dir/github-rules-fail-body" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_AWAY_RECORD_AFTER_VIEW="$case_dir/away-record-after-view" \
  FM_TEST_ROOT="$ROOT" \
  FM_TEST_AWAY_MUTATE_AT_MERGE="${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" \
  FM_TEST_AWAY_MUTATE_OUT="$case_dir/away-mutate-output" \
  FM_TEST_AWAY_MUTATE_RC="$case_dir/away-mutate-rc" \
  FM_TEST_AWAY_GRANTS_AT_MERGE="$case_dir/away-grants-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  HOME="${FM_TEST_USER_HOME:-$case_dir/user-home}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

write_away_record() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" propose "$@" >/dev/null
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_logged_gh_merge "$case_dir" 62 example/repo --squash
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      --attended-override -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    assert_logged_gh_merge "$case_dir" 66 example/repo "$spelling" --merge
    [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted with the exact flags' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_grep 'task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance named no queue flags"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command carrying queue flags"
}

test_github_accepted_queue_flags_do_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-accepted-queue-flags: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-flags: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted with the exact flags base branch main requires (--auto --merge)' \
    "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal did not explain that the right flags were already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal named no concrete next step"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-flags: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back queue flags the caller already used"
}

test_github_mismatched_queue_flags_still_name_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-mismatched-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mismatched-queue-flags: an unproved merge must still fail"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-mismatched-queue-flags: a caller method the queue does not use lost its retry guidance"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-mismatched-queue-flags: the exact compatible flags were not named"
  pass "fm-pr-merge still names retry flags when the caller used a different method"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules-fail"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

# A repository whose plan does not expose branch rules answers the rules
# endpoint with a 403 whose body is GitHub's own plan-upgrade message, not a
# generic auth or rate-limit failure. That repository cannot have a
# merge_queue rule either, so it must read as no queue rather than unreadable
# - an attended read still fails the merge here only because the queue-aware
# outcome read (api graphql) was never set up for this case, exactly like the
# no-queue-rule case below; the queue read itself is proven by the absence of
# 'merge-queue' wording in the refusal.
test_github_plan_gated_403_reads_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-plan-gated-403)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8989898989898989898989898989898989898989
  write_github_outcome "$case_dir" OPEN false false main
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-plan-gated-403: an unproved merge must fail"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was read as an unreadable or present queue rule"
  assert_no_grep 'could not be read' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was reported as an unreadable rules response"
  pass "fm-pr-merge reads a plan-gated 403 on branch rules as no merge queue, not unreadable"
}

# The practical effect of the fix: while away under a standing yolo=on
# posture (no per-task merge grant), a private repository's plan-gated 403
# must no longer refuse the merge the way any other unreadable queue response
# does.
test_away_plan_gated_403_does_not_block_the_merge() {
  local case_dir rc url head
  head=cececececececececececececececececececece
  url=https://github.com/example/repo/pull/91
  case_dir=$(make_case away-plan-gated-403)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-plan-gated-403: a private repo's plan-gated 403 must not block an away merge"
  assert_logged_gh_merge "$case_dir" 91 example/repo --squash
  pass "away merge proceeds on a plan-gated 403 because that repository cannot have a merge queue"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_unmerged_fallback_cannot_replace_queue_aware_read() {
  local case_dir rc
  case_dir=$(make_case github-unmerged-fallback)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  add_gh_mock_outcome_read_fails "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unmerged-fallback: an unproved merge must fail"
  assert_grep 'pr view 73 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-unmerged-fallback: the fallback view was not consulted"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback was treated as a readable outcome"
  assert_no_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback reached detailed outcome handling"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unmerged-fallback: an unproved merge was reported as verified"
  pass "fm-pr-merge accepts only a proved merge from the gh-axi fallback"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  add_gh_axi_mock_view_fails "$case_dir"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing, before recording"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh-read-fails: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing rather than merging blind"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  assert_logged_gh_merge "$case_dir" 56 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '--attended-override -- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  assert_logged_gh_merge "$case_dir" 54 example/repo --squash
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '--attended-override -- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "extra-args: branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "extra-args: refusal did not name --attended-override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "extra-args: gh pr merge ran despite the denylist"

  case_dir=$(make_case extra-args-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 \
    --attended-override -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 15 example/repo --squash --delete-branch
  pass "fm-pr-merge refuses branch deletion unless --attended-override is passed"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh.log" ] || fail "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

# A bundled short-option cluster carries -R without ever being exactly -R, and
# both CLIs expand it one character at a time, so the guard has to read the
# whole cluster. On GitLab that redirect names an instance, not only a
# repository, so it must refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "bundled-non-repo-cluster: -d is branch deletion and must be refused"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "bundled-non-repo-cluster: refusal did not name --attended-override"

  case_dir=$(make_case bundled-delete-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 --attended-override -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-delete-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 8 example/repo --squash -d
  pass "fm-pr-merge refuses a bundled short-option repo override and refuses -d unless attended"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 22 example/repo --merge
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 23 example/repo --method=merge
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 126 my-org/my-repo --squash
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_gitlab_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-extra-args: source-branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "gitlab-extra-args: refusal did not name --attended-override"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-extra-args: glab ran despite the denylist"

  case_dir=$(make_gitlab_case gitlab-extra-args-attended)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "gitlab-extra-args-attended: attended override should merge"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args-attended: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge refuses GitLab source-branch deletion unless --attended-override is passed"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when live verification or the gh merge fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name expected
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    # Each of the three is a different payload problem and says which, the way
    # the GitHub read does; one sentence for all three was R21.
    case "$name" in
      view-fails) expected='the forge did not answer the read' ;;
      not-an-object) expected='could not parse' ;;
      split-value) expected='did not read back cleanly' ;;
    esac
    assert_grep "$expected" \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name this condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

# --------------------------------------------------- the gate-call record
# A live merge-readiness refusal is firstmate keeping work off the captain's
# desk. bin/fm-gate-calls-lib.sh owns the record these read back; here the only
# questions are whether the refusal writes one, whether it carries the check
# state that caused it, and whether an unwritable record can change the merge.

gate_call_field() {  # <log> <line-number> <field>
  jq -r --argjson n "$2" --arg f "$3" -s '.[$n - 1][$f]' < "$1"
}

test_a_red_github_check_records_a_refused_gate_call() {
  local case_dir head log rc
  head=dededededededededededededededededededede
  case_dir=$(make_case gate-call-github-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" 'Lint 2'
  log="$case_dir/state/gate-calls.jsonl"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-call-github-red: a red check must still refuse"
  assert_present "$log" "gate-call-github-red: the refusal recorded no gate call"
  assert_equals refused "$(gate_call_field "$log" 1 verdict)" \
    "gate-call-github-red: a merge refusal must be recorded as refused"
  assert_equals task-x1 "$(gate_call_field "$log" 1 task)" \
    "gate-call-github-red: the record names the wrong task"
  assert_equals https://github.com/example/repo/pull/91 \
    "$(gate_call_field "$log" 1 link)" \
    "gate-call-github-red: the captain cannot open the pull request from the record"
  assert_contains "$(gate_call_field "$log" 1 grounds)" "Lint 2" \
    "gate-call-github-red: the check state that caused the refusal was not the grounds"
  pass "a GitHub merge refused for a red check is recorded with that check as its grounds"
}

test_a_green_merge_records_no_gate_call() {
  local case_dir head
  head=efefefefefefefefefefefefefefefefefefefef
  case_dir=$(make_case gate-call-green)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gate-call-green: a green pull request should merge"

  assert_absent "$case_dir/state/gate-calls.jsonl" \
    "gate-call-green: a merge that was never refused invented a gate call"
  pass "a merge that meets every condition records no refusal"
}

test_a_refusal_still_refuses_when_its_gate_call_cannot_be_recorded() {
  local case_dir head log rc
  head=fafafafafafafafafafafafafafafafafafafafa
  case_dir=$(make_case gate-call-unwritable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" 'Lint 2'
  log="$case_dir/state/gate-calls.jsonl"
  : > "$log"
  chmod 000 "$log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/93 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$log"

  expect_code 1 "$rc" \
    "gate-call-unwritable: an unrecordable gate call must not change the refusal"
  assert_grep "check 'Lint 2' is not green" "$case_dir/stderr" \
    "gate-call-unwritable: the refusal stopped naming the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "gate-call-unwritable: the merge ran because its record could not be written"
  assert_grep 'actionable:' "$case_dir/stderr" \
    "gate-call-unwritable: the unrecorded gate call was silent"
  assert_present "$case_dir/state/gate-calls.drops" \
    "gate-call-unwritable: the unrecorded gate call left no durable trace"
  pass "a merge refusal is unchanged, and says so, when its gate call cannot be recorded"
}

test_a_refused_gitlab_merge_records_a_refused_gate_call() {
  local case_dir log rc
  case_dir=$(make_gitlab_case gate-call-gitlab pipeline_status=failed)
  log="$case_dir/state/gate-calls.jsonl"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-call-gitlab: a failed head pipeline must refuse"
  assert_present "$log" "gate-call-gitlab: the refusal recorded no gate call"
  assert_equals refused "$(gate_call_field "$log" 1 verdict)" \
    "gate-call-gitlab: a merge refusal must be recorded as refused"
  assert_equals "$MR_URL" "$(gate_call_field "$log" 1 link)" \
    "gate-call-gitlab: the record does not point at the merge request"
  assert_contains "$(gate_call_field "$log" 1 grounds)" 'pipeline' \
    "gate-call-gitlab: the pipeline state that caused the refusal was not the grounds"
  pass "a GitLab merge refused for its head pipeline is recorded with that state as its grounds"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir rc
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-sha-arg: a caller --sha must be refused on GitHub too"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "github-sha-arg: refusal did not name the head override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-sha-arg: gh pr merge ran despite the head override"
  pass "fm-pr-merge refuses a caller --sha on GitHub because the head comes from the live read"
}

# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward merge line"
  # The merge path registers the PR first, and that registration publishes the
  # child's ready line on the same channel from fm-pr-check itself.
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url" "$replies" \
    "secondmate-merge-reports: the registration's ready line was not reported upward"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 2 ] \
    || fail "secondmate-merge-reports: a repeat merge changed the upward lines: $(cat "$replies")"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  # The registration's ready line is a fact of its own; only a merge line
  # would misreport the unlanded merge.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  # Registration succeeds before the later GitLab pre-merge refusal, so the
  # PR-ready fact is expected; only a merged outcome would be false.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$case_dir/state/parent-replies.status" \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  # Reused tasks re-bind through fm-pr-check before the next merge. Merge
  # refuses a URL that is not the recorded pr=, so drop the first PR identity.
  grep -vE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    > "$case_dir/state/task-x1.meta.rebind"
  mv "$case_dir/state/task-x1.meta.rebind" "$case_dir/state/task-x1.meta"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_accepted_queue_flags_do_not_echo_back_the_same_command
test_github_mismatched_queue_flags_still_name_the_retry
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_plan_gated_403_reads_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_unmerged_fallback_cannot_replace_queue_aware_read
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_github_still_forwards_sha_arg
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording

# The merge gate asks whether the task is still held for the captain. A home
# that carries no backlog records no captain calls at all, so nothing can be
# held and the merge must proceed; a backlog that EXISTS but cannot be read may
# hide a live hold, so that one must refuse. The two states are distinct and
# only the second is a refusal.
test_absent_backlog_still_merges() {
  local case_dir rc
  case_dir=$(make_case absent-backlog-merges)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-backlog-merges: a home with no backlog must still merge"
  assert_no_grep 'held for the captain' "$case_dir/stderr" \
    "absent-backlog-merges: an absent backlog was read as a captain hold"
  assert_logged_gh_merge "$case_dir" 61 example/repo --squash
  pass "fm-pr-merge proceeds when the home carries no backlog at all"
}

test_unreadable_backlog_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backlog-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6262626262626262626262626262626262626262
  : > "$case_dir/gh-axi.log"
  chmod 000 "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/data/backlog.md"

  expect_code 1 "$rc" "unreadable-backlog-refuses: an unreadable authority record must refuse"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "unreadable-backlog-refuses: the refusal did not say it refused to merge"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backlog-refuses: the forge merge ran despite an unreadable record"
  pass "fm-pr-merge refuses when the backlog exists but cannot be read"
}

test_unreadable_backend_config_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backend-config-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6363636363636363636363636363636363636363
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"
  chmod 000 "$case_dir/home/.tasks.toml"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/.tasks.toml"

  expect_code 1 "$rc" "unreadable-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep 'tasks-axi backend configuration cannot be read' "$case_dir/stderr" \
    "unreadable-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its configured backend cannot be read"
}

test_unreadable_user_backend_config_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case unreadable-user-backend-config-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6464646464646464646464646464646464646464
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 1 "$rc" "unreadable-user-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "unreadable-user-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-user-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration cannot be read"
}

test_untraversable_user_backend_config_directory_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case untraversable-user-backend-config-directory-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "${user_config%/*}"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 755 "${user_config%/*}"

  expect_code 1 "$rc" "untraversable-user-backend-config-directory-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "untraversable-user-backend-config-directory-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "untraversable-user-backend-config-directory-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration directory cannot be traversed"
}

test_absent_user_backend_config_directory_and_backlog_still_merge() {
  local case_dir rc
  case_dir=$(make_case absent-user-backend-config-directory-and-backlog-merges)
  mkdir -p "$case_dir/wt" "$case_dir/user-home"
  add_gh_mocks "$case_dir" 6767676767676767676767676767676767676767
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-user-backend-config-directory-and-backlog-merges: sound defaults and no backlog must permit merging"
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "absent-user-backend-config-directory-and-backlog-merges: the forge must merge exactly once"
  assert_logged_gh_merge "$case_dir" 67 example/repo --squash
  pass "fm-pr-merge proceeds once when its user configuration directory and backlog are genuinely absent"
}

test_backend_override_bypasses_unreadable_user_config() {
  local case_dir rc user_config
  case_dir=$(make_case backend-override-bypasses-unreadable-user-config)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6565656565656565656565656565656565656565
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  TASKS_AXI_BACKEND=markdown FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 0 "$rc" "backend-override-bypasses-unreadable-user-config: an explicit backend must bypass config"
  assert_logged_gh_merge "$case_dir" 65 example/repo --squash
  pass "fm-pr-merge honors a backend override over an unreadable user configuration"
}

test_github_red_checks_refuse_and_allow_red_waives_named() {
  local case_dir rc head
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case_dir=$(make_case github-red-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-red: a red check must refuse"
  assert_grep "check 'lint' failed" "$case_dir/stderr" \
    "github-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-red: gh pr merge ran on a red PR"

  case_dir=$(make_case github-allow-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-allow-red: named waiver should merge"
  assert_logged_gh_merge "$case_dir" 81 example/repo --squash
  pass "fm-pr-merge refuses red GitHub checks and waives only a named --allow-red check"
}

# When the base branch advances, GitHub cancels a pull request's in-flight run
# and re-triggers it, leaving the cancelled run in the rollup beside the passing
# re-run while reporting the pull request itself CLEAN. The merge must follow the
# current run rather than the one that re-run replaced.
test_superseded_failed_check_run_no_longer_refuses() {
  local case_dir head
  head=cccccccccccccccccccccccccccccccccccccccc
  case_dir=$(make_case github-superseded-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/90 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-superseded-red: a failed run replaced by a passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 90 example/repo --squash
  pass "fm-pr-merge merges when a failed check run was replaced by a passing re-run"
}

# Legacy status contexts remain independent from check runs, even when their
# reported names match.
test_check_runs_never_supersede_status_contexts() {
  local case_dir rc head
  head=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  case_dir=$(make_case github-cross-check-kind)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(status_context ci FAILURE)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-check-kind: a failing status context must refuse"
  assert_grep "check 'ci' failed" "$case_dir/stderr" \
    "github-cross-check-kind: the status context was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-check-kind: a passing check run hid a failing status context"
  pass "fm-pr-merge never lets a check run supersede a legacy status context"
}

# The inverse, and the one that matters most: a check whose current run failed is
# still red however many earlier runs of it passed.
test_current_failed_check_run_still_refuses() {
  local case_dir rc head
  head=dddddddddddddddddddddddddddddddddddddddd
  case_dir=$(make_case github-current-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-current-red: a currently failing check must refuse"
  assert_grep "check 'ci' failed" "$case_dir/stderr" \
    "github-current-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-current-red: gh pr merge ran on a currently failing check"
  pass "fm-pr-merge still refuses when a check's current run failed after an earlier pass"
}

# Run generation follows startedAt rather than the order overlapping runs finish.
test_late_finishing_old_success_does_not_hide_current_failure() {
  local case_dir rc head
  head=dededededededededededededededededededede
  case_dir=$(make_case github-old-success-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-old-success-finishes-last: the later-started failure must refuse"
  assert_grep "check 'ci' failed" "$case_dir/stderr" \
    "github-old-success-finishes-last: the current failure was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-old-success-finishes-last: completion order hid the current failure"
  pass "fm-pr-merge uses start order when the old success finishes last"
}

# A cancelled old run may settle after the passing re-run that superseded it.
test_late_finishing_old_cancellation_is_superseded() {
  local case_dir head
  head=dfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf
  case_dir=$(make_case github-old-cancellation-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/99 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-old-cancellation-finishes-last: the passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 99 example/repo --squash
  pass "fm-pr-merge supersedes an old cancellation that finishes last"
}

# A re-run that has not finished proves nothing, so it can neither be superseded
# nor supersede: the check stays red whether the run it replaces passed or failed.
test_unfinished_rerun_keeps_a_check_red() {
  local case_dir rc head prior
  head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  for prior in FAILURE SUCCESS; do
    case_dir=$(make_case "github-pending-rerun-$prior")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED "$prior" 2026-01-01T00:00:01Z)" \
      "$(check_run ci IN_PROGRESS - -)"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-pending-rerun-$prior: an unfinished re-run must refuse"
    assert_grep "check 'ci' is still running" "$case_dir/stderr" \
      "github-pending-rerun-$prior: the pending check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-pending-rerun-$prior: gh pr merge ran with a re-run still in flight"
  done
  pass "fm-pr-merge keeps a check red while its re-run is still in flight"
}

# Supersession is scoped to one check name, which is also the name --allow-red
# matches, so a newer passing check never clears a different check's failure.
test_supersession_never_crosses_check_names() {
  local case_dir rc head
  head=ffffffffffffffffffffffffffffffffffffffff
  case_dir=$(make_case github-cross-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/93 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-name: another check passing must not clear this failure"
  assert_grep "check 'lint' failed" "$case_dir/stderr" \
    "github-cross-name: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-name: gh pr merge ran on a red check of a different name"
  pass "fm-pr-merge never lets one check's pass clear another check's failure"
}

# Supersession has to be proven from the forge's own start timestamps, so a run
# GitHub dated in any other way is treated as undated and clears nothing.
test_undated_runs_never_supersede() {
  local case_dir rc spec label older newer
  local head=0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a
  set -- \
    'undated-failure|-|2026-01-01T00:00:09Z' \
    'undated-pass|2026-01-01T00:00:01Z|-' \
    'fractional-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09.500Z' \
    'offset-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09+00:00'
  for spec in "$@"; do
    label=${spec%%|*}
    older=${spec#*|}
    older=${older%%|*}
    newer=${spec##*|}
    case_dir=$(make_case "github-undated-$label")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED FAILURE "$older")" \
      "$(check_run ci COMPLETED SUCCESS "$newer")"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/94 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-undated-$label: an unproven supersession must refuse"
    assert_grep "check 'ci' failed" "$case_dir/stderr" \
      "github-undated-$label: the red check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-undated-$label: gh pr merge ran on an unproven supersession"
  done
  pass "fm-pr-merge clears a failure only on a proven later pass of the same check"
}

# A superseded failure changes nothing about the waiver: --allow-red still covers
# exactly the named check, still needs every other check green, and the merge is
# still bound to the verified head.
test_allow_red_still_waives_only_the_current_failure() {
  local case_dir rc head
  head=0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b
  case_dir=$(make_case github-superseded-allow-red-wrong-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    --allow-red ci > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "superseded-allow-red-wrong-name: waiving the green check must not merge"
  assert_grep "check 'lint' failed" "$case_dir/stderr" \
    "superseded-allow-red-wrong-name: the unwaived red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "superseded-allow-red-wrong-name: gh pr merge ran with an unwaived red check"

  case_dir=$(make_case github-superseded-allow-red-named)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    --allow-red lint > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "superseded-allow-red-named: the named waiver should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash
  pass "fm-pr-merge keeps --allow-red scoped to its named check beside a superseded failure"
}

test_allow_red_is_refused_while_away() {
  local case_dir rc head
  head=abababababababababababababababababababab
  case_dir=$(make_case github-allow-red-away)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away: --allow-red must be refused while away"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away: refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away: gh pr merge ran despite away --allow-red"

  case_dir=$(make_case github-allow-red-away-after-view)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --grant task-x1
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away-after-view: late away publication must refuse --allow-red"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away-after-view: late refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away-after-view: gh pr merge ran after late away publication"
  pass "fm-pr-merge rechecks away presence before an attended red merge"
}

test_allow_red_requires_one_separate_name() {
  local case_dir rc head
  head=afafafafafafafafafafafafafafafafafafafaf

  case_dir=$(make_case github-allow-red-equals)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/87 \
    --allow-red=lint > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-equals: equals form must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-equals: gh pr merge ran for the equals alias"

  case_dir=$(make_case github-allow-red-duplicate)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 \
    --allow-red lint --allow-red unit > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-duplicate: duplicate waiver must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-duplicate: gh pr merge ran for duplicate waivers"
  pass "fm-pr-merge accepts exactly one separately named red-check waiver"
}

test_away_grant_and_yolo_and_hold_for_return() {
  local case_dir rc url head
  head=acacacacacacacacacacacacacacacacacacacac
  url=https://github.com/example/repo/pull/83

  case_dir=$(make_case away-held)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir"
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-held: ungranted merge must refuse"
  assert_grep 'task task-x1 is held for the captain return' "$case_dir/stderr" \
    "away-held: refusal did not name hold-for-return"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-held: gh pr merge ran without a grant"

  case_dir=$(make_case away-held-attended-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir"
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --attended-override \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-held-override: --attended-override must not skip the grant"
  assert_grep 'task task-x1 is held for the captain return' "$case_dir/stderr" \
    "away-held-override: override skipped the grant"

  case_dir=$(make_case away-grant)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --grant task-x1
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-grant: granted green merge should succeed"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  assert_grep "merge landed: task-x1 $url away-grant" "$case_dir/state/.wake-queue" \
    "away-grant: the durable outcome did not tag away-grant"

  case_dir=$(make_case away-yolo)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-yolo: yolo green merge should succeed"
  assert_grep "merge landed: task-x1 $url yolo" "$case_dir/state/.wake-queue" \
    "away-yolo: the durable outcome did not tag yolo"
  pass "away merges require yolo or a grant, and --attended-override does not skip that"
}

test_away_posture_refuses_asynchronous_merge_paths() {
  local case_dir rc url head merge_line
  head=abababababababababababababababababababab
  url=https://github.com/example/repo/pull/89

  case_dir=$(make_case away-auto-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-auto-refused: auto-merge must be attended-only"
  assert_grep '--auto is attended-only' "$case_dir/stderr" \
    "away-auto-refused: refusal did not name the asynchronous flag"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-auto-refused: gh pr merge ran for an away auto-merge request"

  case_dir=$(make_case away-queue-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-queue-refused: a required merge queue must refuse before submission"
  assert_grep 'merge-queue state does not prove an immediate merge' "$case_dir/stderr" \
    "away-queue-refused: refusal did not explain the away restriction"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-queue-refused: gh received a merge that could enter its queue"

  case_dir=$(make_gitlab_case away-gitlab-auto)
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --auto-merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-auto: GitLab auto-merge must refuse"
  assert_grep 'GitLab auto-merge is attended-only' "$case_dir/stderr" \
    "away-gitlab-auto: refusal did not name auto-merge"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-auto: glab received an asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-configured merge_when_pipeline_succeeds=true)
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-configured: configured auto-merge must refuse"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-configured: glab received a configured asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-sync)
  write_away_record "$case_dir" --grant task-x1
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-gitlab-sync: an immediate granted merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *" --auto-merge=false") ;;
    *) fail "away-gitlab-sync: the final glab flag did not force an immediate merge: '$merge_line'" ;;
  esac
  pass "away posture permits immediate merges but refuses every asynchronous path"
}

test_away_grant_does_not_bypass_red_or_identity() {
  local case_dir rc head
  head=adadadadadadadadadadadadadadadadadadadad
  case_dir=$(make_case away-grant-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-grant-red: a grant must not waive red checks"
  assert_grep "check 'lint' failed" "$case_dir/stderr" \
    "away-grant-red: C1 did not refuse the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-grant-red: gh pr merge ran on a granted red PR"

  case_dir=$(make_case pr-identity-mismatch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '\npr=https://github.com/example/repo/pull/99\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "pr-identity: a different recorded URL must refuse"
  assert_grep 'is bound to https://github.com/example/repo/pull/99' "$case_dir/stderr" \
    "pr-identity: refusal did not name the recorded URL"
  pass "a grant does not bypass red checks, and a recorded pr= must match the URL"
}

test_unreadable_away_record_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case away-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
  printf 'not-a-contract\n' > "$case_dir/state/.afk-contract"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-unreadable: an unreadable away record must refuse"
  assert_grep 'away-posture record could not be read' "$case_dir/stderr" \
    "away-unreadable: refusal did not fail closed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-unreadable: gh pr merge ran despite an unreadable record"
  pass "an unreadable away-posture record refuses the merge instead of skipping the grant"
}

# The race this closes: the away record is read for merge authority and the
# forge is called afterwards, so an archive (the captain's return) or a grant
# revocation landing in between would merge on authority that no longer holds.
# away_change_script writes the change the gh mock attempts from inside the
# forge call, which IS that window. Its body drives the real away-record
# commands /afk and the return use, never a file edit, and takes a one-second
# lock bound so a contended case refuses quickly instead of waiting.
away_change_script() {  # <case-dir> <name>; script body on stdin
  local case_dir=$1 name=$2 path
  path="$case_dir/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -eu\n'
    printf 'export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1\n'
    printf 'CONTRACT="%s/bin/fm-afk-contract.sh"\n' "$ROOT"
    cat
  } > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# Two away-record changes, each attempted from inside the merge's critical
# section: the archive a captain return performs, and the replacement that
# revokes a grant. Neither may land there, and the merge must still complete on
# the authority it read.
test_away_record_cannot_change_between_the_authority_read_and_the_merge() {
  local case_dir rc mutate
  case_dir=$(make_case away-archive-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b
  write_away_record "$case_dir" --grant task-x1
  mutate=$(away_change_script "$case_dir" archive-at-merge <<'SH'
"$CONTRACT" archive
SH
  )

  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-archive-at-merge: the granted green merge should still land"
  [ -s "$case_dir/away-mutate-rc" ] \
    || fail "away-archive-at-merge: the archive was never attempted inside the merge"
  [ "$(cat "$case_dir/away-mutate-rc")" != 0 ] \
    || fail "away-archive-at-merge: the archive landed inside the merge's critical section"
  assert_grep 'locked by live process' "$case_dir/away-mutate-output" \
    "away-archive-at-merge: the refused archive did not name the live holder"
  assert_equals task-x1 "$(cat "$case_dir/away-grants-at-merge" 2>/dev/null || true)" \
    "away-archive-at-merge: the grant this merge read was not still standing at the forge call"
  assert_grep "merge landed: task-x1 https://github.com/example/repo/pull/71 away-grant" \
    "$case_dir/state/.wake-queue" \
    "away-archive-at-merge: the landed merge was not recorded under the grant it read"
  # The lock goes with the merge rather than leaking: the captain's return
  # archives the record on its first try once the merge is done.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null \
    || fail "away-archive-at-merge: the record stayed locked after the merge"

  case_dir=$(make_case away-revoke-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c
  write_away_record "$case_dir" --grant task-x1
  mutate=$(away_change_script "$case_dir" revoke-at-merge <<'SH'
"$CONTRACT" propose --grant task-other
"$CONTRACT" confirm
SH
  )
  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-revoke-at-merge: the granted green merge should still land"
  [ "$(cat "$case_dir/away-mutate-rc" 2>/dev/null || true)" != 0 ] \
    || fail "away-revoke-at-merge: the replacement landed inside the critical section"
  assert_equals task-x1 "$(cat "$case_dir/away-grants-at-merge" 2>/dev/null || true)" \
    "away-revoke-at-merge: the grant was revoked inside the merge's critical section"
  pass "no away-record archive or grant revocation lands between the authority read and the merge"
}

# The same serialization from the other side. A revocation that wins the race
# lands BEFORE the in-lock authority read, and the merge then refuses: the lock
# decides an order, it never lets a stale grant through.
test_a_grant_revoked_before_the_merge_refuses_it() {
  local case_dir rc
  case_dir=$(make_case away-revoked-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
  write_away_record "$case_dir"
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  write_away_record "$case_dir" --grant task-x1

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "away-revoked-before-merge: a revoked grant must refuse"
  assert_grep 'held for the captain return' "$case_dir/stderr" \
    "away-revoked-before-merge: refusal did not name hold-for-return"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-revoked-before-merge: gh pr merge ran on a revoked grant"
  pass "a grant revoked before the merge's own authority read refuses the merge"
}

# Fail closed. The lock is what makes the authority read and the merge one
# action, so a merge that cannot take it has no locked window to merge in and
# refuses - including on this attended case, where the record is absent and
# there is no grant to check at all.
test_merge_refuses_when_the_away_record_cannot_be_locked() {
  local case_dir rc holder_pid i lock
  case_dir=$(make_case away-lock-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e
  lock="$case_dir/state/.afk-contract.lock"

  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$case_dir/holder.ready" "$case_dir/release-holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$case_dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$case_dir/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "away-lock-unavailable: the fixture never took the record lock"; }

  export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT
  : > "$case_dir/release-holder"
  wait "$holder_pid" || fail "away-lock-unavailable: the fixture holder did not release cleanly"

  expect_code 1 "$rc" "away-lock-unavailable: an unlockable away record must refuse the merge"
  assert_grep 'could not be locked for the merge' "$case_dir/stderr" \
    "away-lock-unavailable: refusal did not name the lock it could not take"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-lock-unavailable: gh pr merge ran without the away-record lock"
  pass "a merge that cannot lock the away record refuses instead of merging unlocked"
}

test_allow_red_refused_on_gitlab() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-allow-red)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-allow-red: --allow-red must not apply on GitLab"
  assert_grep '--allow-red does not apply to GitLab' "$case_dir/stderr" \
    "gitlab-allow-red: refusal did not name GitLab"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-allow-red: glab ran despite --allow-red"
  pass "fm-pr-merge refuses --allow-red on GitLab"
}

test_gitlab_head_override_args_refuse_before_recording
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
test_absent_backlog_still_merges
test_unreadable_backlog_refuses_the_merge
test_unreadable_backend_config_refuses_the_merge
test_unreadable_user_backend_config_refuses_the_merge
test_untraversable_user_backend_config_directory_refuses_the_merge
test_absent_user_backend_config_directory_and_backlog_still_merge
test_backend_override_bypasses_unreadable_user_config
test_github_red_checks_refuse_and_allow_red_waives_named
test_superseded_failed_check_run_no_longer_refuses
test_check_runs_never_supersede_status_contexts
test_current_failed_check_run_still_refuses
test_late_finishing_old_success_does_not_hide_current_failure
test_late_finishing_old_cancellation_is_superseded
test_unfinished_rerun_keeps_a_check_red
test_supersession_never_crosses_check_names
test_undated_runs_never_supersede
test_allow_red_still_waives_only_the_current_failure
test_allow_red_is_refused_while_away
test_allow_red_requires_one_separate_name
test_away_grant_and_yolo_and_hold_for_return
test_away_posture_refuses_asynchronous_merge_paths
test_away_plan_gated_403_does_not_block_the_merge
test_away_grant_does_not_bypass_red_or_identity
test_unreadable_away_record_refuses_merge
test_away_record_cannot_change_between_the_authority_read_and_the_merge
test_a_grant_revoked_before_the_merge_refuses_it
test_merge_refuses_when_the_away_record_cannot_be_locked
test_allow_red_refused_on_gitlab
test_a_red_github_check_records_a_refused_gate_call
test_a_green_merge_records_no_gate_call
test_a_refusal_still_refuses_when_its_gate_call_cannot_be_recorded
test_a_refused_gitlab_merge_records_a_refused_gate_call

# --- The approval gate -------------------------------------------------------
# The captain's rule of 2026-09-20: only a reviewer approves, and only an
# approved pull request merges. These cases drive the gate through the script's
# own entrypoint with the forge's real reviews shape, never through its source.

# A view payload with the reviews array replaced wholesale, so one case drives
# exactly one review shape. Args: case_dir head reviews_json [pr_author]
write_github_reviews() {
  local case_dir=$1 head=$2 reviews=$3 author=${4:-worker}
  write_github_view_json "$case_dir" "$head" \
    '{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}' \
    "$reviews" "$author"
}

test_merge_refuses_a_pull_request_with_no_review() {
  local case_dir rc head=1111111111111111111111111111111111111111
  case_dir=$(make_case github-no-review)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" ''

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-no-review: an unreviewed pull request must not merge"
  assert_grep 'no review has been posted' "$case_dir/stderr" \
    "github-no-review: the refusal did not name the missing review"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-no-review: gh pr merge ran without a review"
  pass "fm-pr-merge refuses a pull request no one has reviewed"
}

test_merge_refuses_a_review_that_states_no_verdict() {
  local case_dir rc head=2222222222222222222222222222222222222222
  case_dir=$(make_case github-no-verdict)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # The shape every review in this repository had before this gate existed:
  # posted, at the head, and carrying no statement that approves or does not.
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" reviewer 'R1 - preference - low - naming.

Verdict: non-blocking')"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-no-verdict: a review without a verdict must not merge"
  assert_grep 'states no verdict' "$case_dir/stderr" \
    "github-no-verdict: the refusal did not name the missing verdict"
  assert_grep 'Review verdict: APPROVED' "$case_dir/stderr" \
    "github-no-verdict: the refusal did not name the line that would fix it"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-no-verdict: gh pr merge ran on a review that stated no verdict"
  pass "fm-pr-merge refuses a posted review that states no verdict, and names the line that fixes it"
}

test_merge_refuses_an_approval_of_a_superseded_commit() {
  local case_dir rc head=3333333333333333333333333333333333333333
  local reviewed=4444444444444444444444444444444444444444
  case_dir=$(make_case github-approval-superseded)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" "$(approving_review "$reviewed")"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-approval-superseded: an approval of an older commit must not merge"
  assert_grep "$reviewed" "$case_dir/stderr" \
    "github-approval-superseded: the refusal did not name the commit that was reviewed"
  assert_grep "$head" "$case_dir/stderr" \
    "github-approval-superseded: the refusal did not name the head that would merge"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-approval-superseded: gh pr merge ran on an approval of a superseded commit"
  pass "fm-pr-merge refuses an approval of a commit that is no longer what would merge"
}

test_merge_refuses_a_review_that_declines() {
  local case_dir rc head=5555555555555555555555555555555555555555
  case_dir=$(make_case github-not-approved)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" reviewer 'R1 - defect - high - drops the error.

Review verdict: NOT APPROVED')"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-not-approved: a declined review must not merge"
  assert_grep 'does not approve' "$case_dir/stderr" \
    "github-not-approved: the refusal did not say the review declined"
  assert_grep 'reviewer' "$case_dir/stderr" \
    "github-not-approved: the refusal did not name the reviewer who declined"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-not-approved: gh pr merge ran on a declined review"
  pass "fm-pr-merge refuses a review whose verdict declines"
}

test_a_declining_review_beats_an_approval_at_the_same_head() {
  local case_dir rc head=6666666666666666666666666666666666666666
  case_dir=$(make_case github-split-verdict)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(approving_review "$head" first),$(review_entry COMMENTED "$head" second 'Review verdict: NOT APPROVED' 2026-09-20T10:00:00Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-split-verdict: an outstanding refusal must not be merged over"
  assert_grep 'does not approve' "$case_dir/stderr" \
    "github-split-verdict: the refusal did not name the declining review"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-split-verdict: gh pr merge ran with a declining review at the head"
  pass "fm-pr-merge refuses while any review at the head declines, even beside an approval"
}

test_a_quoted_verdict_is_not_the_reviews_own_verdict() {
  local case_dir rc head=7777777777777777777777777777777777777777
  case_dir=$(make_case github-quoted-verdict)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # The earlier round's approval quoted verbatim inside a fenced block, with
  # this review reaching no verdict of its own.
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" reviewer 'The previous round said:

```
Review verdict: APPROVED
```

That was before the force-push. I have not finished reading this one.')"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-quoted-verdict: a quoted verdict must not approve"
  assert_grep 'states no verdict' "$case_dir/stderr" \
    "github-quoted-verdict: the refusal did not treat the quote as no verdict"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-quoted-verdict: gh pr merge ran on a quoted verdict"
  pass "fm-pr-merge reads only the last line as the review's own verdict"
}

test_github_native_approved_state_is_accepted() {
  local case_dir head=8888888888888888888888888888888888888888
  case_dir=$(make_case github-native-approval)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # The durable form, for the day a second account makes GitHub's own verdict
  # reachable: no verdict line at all, approved through the forge's state.
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry APPROVED "$head" reviewer 'Looks right.')"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-native-approval: a natively approved pull request should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 95 example/repo --squash
  assert_grep 'approved by reviewer' "$case_dir/stderr" \
    "github-native-approval: the merge did not name the approver"
  pass "fm-pr-merge accepts GitHub's own APPROVED state with no verdict line, so the verbal form needs no migration"
}

test_merge_discloses_an_approval_it_cannot_separate_from_the_author() {
  local case_dir head=9999999999999999999999999999999999999999
  case_dir=$(make_case github-same-account)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" "$(approving_review "$head" solo)" solo

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-same-account: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'cannot separate the two here' "$case_dir/stderr" \
    "github-same-account: the merge did not disclose that the approver is the author"

  # The same gate says nothing of the kind once the accounts differ, so the
  # disclosure is the unverifiable case speaking rather than boilerplate.
  case_dir=$(make_case github-two-accounts)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" "$(approving_review "$head" reviewer)" worker
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-two-accounts: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_no_grep 'cannot separate the two here' "$case_dir/stderr" \
    "github-two-accounts: a separable approval must not carry the disclosure"
  pass "fm-pr-merge names the approver and says when the forge cannot tell it apart from the author"
}

test_no_flag_waives_the_approval() {
  local case_dir rc head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case_dir=$(make_case github-allow-red-no-approval)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_view_json "$case_dir" "$head" \
    '{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}' ''

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    --attended-override --allow-red ci > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-allow-red-no-approval: waiving the check must not waive the approval"
  assert_grep 'no review has been posted' "$case_dir/stderr" \
    "github-allow-red-no-approval: the refusal did not name the missing approval"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-no-approval: gh pr merge ran unapproved under --allow-red --attended-override"
  pass "fm-pr-merge lets neither --allow-red nor --attended-override waive the approval"
}

test_unreadable_reviews_refuse_the_merge() {
  local case_dir rc head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc
  case_dir=$(make_case github-reviews-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' "$head" > "$case_dir/github-head"
  # Everything else readable and green, with the reviews array absent: an
  # approval that cannot be read is not an approval.
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","author":{"login":"worker"},"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-reviews-unreadable: unreadable reviews must not merge"
  assert_grep 'could not read the GitHub pull request reviews' "$case_dir/stderr" \
    "github-reviews-unreadable: the refusal did not name the failed reviews read"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-reviews-unreadable: gh pr merge ran without reading the reviews"
  pass "fm-pr-merge refuses when the reviews cannot be read rather than merging unapproved"
}

test_gitlab_merge_refuses_without_an_approval() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-no-approval)
  printf '{"approved_by":[]}\n' > "$case_dir/glab-approvals.json"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-no-approval: an unapproved merge request must not merge"
  assert_grep 'no approval' "$case_dir/stderr" \
    "gitlab-no-approval: the refusal did not name the missing approval"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-no-approval: glab mr merge ran without an approval"
  pass "fm-pr-merge refuses a GitLab merge request nobody approved"
}

test_gitlab_merge_refuses_when_approvals_cannot_be_read() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-approvals-unreadable)
  : > "$case_dir/glab-approvals-fail"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-approvals-unreadable: an unreadable approval must not merge"
  assert_grep 'approvals could not be read' "$case_dir/stderr" \
    "gitlab-approvals-unreadable: the refusal did not name the failed approvals read"
  assert_grep '401 Unauthorized' "$case_dir/stderr" \
    "gitlab-approvals-unreadable: the forge's own account of the failure was discarded"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-approvals-unreadable: glab mr merge ran on an unreadable approval"
  pass "fm-pr-merge refuses a GitLab merge whose approvals it could not read"
}

test_gitlab_merge_discloses_that_an_approval_is_not_head_bound() {
  local case_dir
  case_dir=$(make_gitlab_case gitlab-approval-not-head-bound)
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-approval-not-head-bound: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'not proven to cover head' "$case_dir/stderr" \
    "gitlab-approval-not-head-bound: the merge claimed a head binding GitLab does not report"
  pass "a GitLab merge says its approval is not proven against the head, unlike the GitHub path"
}

test_merge_refuses_a_pull_request_with_no_review
test_merge_refuses_a_review_that_states_no_verdict
test_merge_refuses_an_approval_of_a_superseded_commit
test_merge_refuses_a_review_that_declines
test_a_declining_review_beats_an_approval_at_the_same_head
test_a_quoted_verdict_is_not_the_reviews_own_verdict
test_github_native_approved_state_is_accepted
test_merge_discloses_an_approval_it_cannot_separate_from_the_author
test_no_flag_waives_the_approval
test_unreadable_reviews_refuse_the_merge
test_gitlab_merge_refuses_without_an_approval
test_gitlab_merge_refuses_when_approvals_cannot_be_read
test_gitlab_merge_discloses_that_an_approval_is_not_head_bound

# The gate must authenticate the speaker, not only the statement: on a public
# repository any account with read access can post a COMMENTED review.
test_a_stranger_cannot_supply_the_approval() {
  local case_dir rc head=cccccccccccccccccccccccccccccccccccccccc
  case_dir=$(make_case github-stranger-approval)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(approving_review "$head" random-stranger NONE)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-stranger-approval: an outside account must not approve"
  assert_grep 'random-stranger' "$case_dir/stderr" \
    "github-stranger-approval: the refusal did not name the account"
  assert_grep 'OWNER, MEMBER, or COLLABORATOR' "$case_dir/stderr" \
    "github-stranger-approval: the refusal did not say which associations count"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-stranger-approval: gh pr merge ran on a stranger's approval"
  pass "fm-pr-merge refuses an approval from an account this repository granted no standing"
}

test_each_granted_association_may_approve() {
  local case_dir assoc n=200 head=dddddddddddddddddddddddddddddddddddddddd
  for assoc in OWNER MEMBER COLLABORATOR; do
    n=$((n + 1))
    case_dir=$(make_case "github-assoc-$assoc")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_reviews "$case_dir" "$head" \
      "$(approving_review "$head" reviewer "$assoc")"
    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$n" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "github-assoc-$assoc: $assoc should be able to approve"$'\n'"$(cat "$case_dir/stderr")"
    assert_grep "approved by reviewer ($assoc)" "$case_dir/stderr" \
      "github-assoc-$assoc: the merge did not record the approver's association"
  done

  # CONTRIBUTOR has commits here but no standing the repository granted, which
  # is the boundary of the trusted set rather than an arbitrary omission.
  case_dir=$(make_case github-assoc-contributor)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(approving_review "$head" past-contributor CONTRIBUTOR)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/205 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-assoc-contributor: CONTRIBUTOR must not approve"
  assert_grep 'CONTRIBUTOR' "$case_dir/stderr" \
    "github-assoc-contributor: the refusal did not name the association it read"
  pass "fm-pr-merge accepts an approval from OWNER, MEMBER, or COLLABORATOR and no one else"
}

# The disclosure has to speak in the case it used to be silent about: an
# approver that is not the account which opened the pull request.
test_the_disclosure_speaks_in_both_cases() {
  local case_dir head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  case_dir=$(make_case github-disclosure-other-account)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(approving_review "$head" reviewer MEMBER)" worker
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-disclosure-other-account: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'not the account that opened the pull request' "$case_dir/stderr" \
    "github-disclosure-other-account: a different-account approval passed with no disclosure"
  assert_grep 'cannot establish' "$case_dir/stderr" \
    "github-disclosure-other-account: the notice implied a dispatch it cannot check"

  case_dir=$(make_case github-disclosure-same-account)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" "$(approving_review "$head" solo OWNER)" solo
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-disclosure-same-account: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'cannot separate the two here' "$case_dir/stderr" \
    "github-disclosure-same-account: the same-account case lost its disclosure"
  pass "fm-pr-merge discloses who approved in both cases, never silently in one"
}

test_a_stranger_cannot_supply_the_approval
test_each_granted_association_may_approve
test_the_disclosure_speaks_in_both_cases

# A review that was withdrawn, and one nobody submitted, are not approvals.
test_only_a_submitted_standing_review_counts() {
  local case_dir rc state head=1212121212121212121212121212121212121212
  local n=300
  for state in DISMISSED PENDING SOMETHING_NEW; do
    n=$((n + 1))
    case_dir=$(make_case "github-state-$state")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_reviews "$case_dir" "$head" \
      "$(review_entry "$state" "$head" reviewer 'Review verdict: APPROVED')"
    set +e
    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$n" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-state-$state: a $state review must not approve"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-state-$state: gh pr merge ran on a $state review"
  done

  # And they do not refuse either: a withdrawn decline beside a standing
  # approval must not hold the merge, or dismissal would mean nothing.
  case_dir=$(make_case github-state-dismissed-decline)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry DISMISSED "$head" former 'Review verdict: NOT APPROVED'),$(approving_review "$head" reviewer)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/310 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-state-dismissed-decline: a dismissed decline should not hold the merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 310 example/repo --squash
  pass "fm-pr-merge reads only submitted standing reviews, so a dismissed or draft one neither approves nor refuses"
}

test_only_a_submitted_standing_review_counts

# The verdict line crosses two programs: bin/fm-brief.sh tells the reviewer what
# to write and bin/fm-pr-merge.sh decides whether it merges. Sourcing one owner
# makes them agree by construction; this asserts it through both executable
# interfaces, so a future copy pasted back into either one fails here instead of
# silently making every review unreadable to the gate.
test_the_brief_verdict_line_is_what_the_gate_accepts() {
  local case_dir home brief line head=2323232323232323232323232323232323232323
  case_dir=$(make_case github-brief-verdict-agreement)
  mkdir -p "$case_dir/wt" "$case_dir/brief-home"
  home="$case_dir/brief-home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" verdict-probe some-proj \
    --review https://github.com/example/repo/pull/95 >/dev/null 2>&1 \
    || fail "brief-verdict-agreement: scaffolding a review brief failed"

  brief="$home/data/verdict-probe/brief.md"
  assert_present "$brief" "brief-verdict-agreement: no review brief was written"

  # The approving verdict exactly as the reviewer is instructed to write it,
  # taken out of the generated brief rather than retyped here, so this test
  # cannot agree with a copy that has drifted from what the brief says.
  line=$(grep -E '^Review verdict: APPROVED$' "$brief" | head -1)
  [ -n "$line" ] \
    || fail "brief-verdict-agreement: the generated brief instructs no approving verdict line"$'\n'"$(grep -n -i verdict "$brief" || true)"

  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" reviewer "R1 - preference - low - naming.

$line")"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "brief-verdict-agreement: the gate rejected the verdict its own brief instructs"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 95 example/repo --squash

  # And the declining one holds the merge, so the agreement covers both verdicts
  # rather than only the one that happens to pass.
  line=$(grep -E '^Review verdict: NOT APPROVED$' "$brief" | head -1)
  [ -n "$line" ] \
    || fail "brief-verdict-agreement: the generated brief instructs no declining verdict line"
  case_dir=$(make_case github-brief-verdict-declines)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" reviewer "$line")"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "brief-verdict-declines: the brief's declining verdict must hold the merge"
  pass "the verdict line bin/fm-brief.sh writes is the one bin/fm-pr-merge.sh accepts, asserted through both"
}

test_the_brief_verdict_line_is_what_the_gate_accepts

# The GitLab path has the author and the approvers in hand, so it makes the same
# two-case disclosure the GitHub path does. A notice printed on one of two
# parallel paths reads as a guarantee on the other.
test_gitlab_discloses_a_self_approval() {
  local case_dir
  case_dir=$(make_gitlab_case gitlab-self-approval author=solo)
  printf '{"approved_by":[{"user":{"username":"solo"}}]}\n' > "$case_dir/glab-approvals.json"
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-self-approval: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'cannot separate the two here' "$case_dir/stderr" \
    "gitlab-self-approval: an approval by the merge request's own author passed with no disclosure"

  case_dir=$(make_gitlab_case gitlab-other-approval author=worker)
  printf '{"approved_by":[{"user":{"username":"reviewer"}}]}\n' > "$case_dir/glab-approvals.json"
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-other-approval: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'does not include the account that opened the merge request' "$case_dir/stderr" \
    "gitlab-other-approval: a different-account approval passed with no disclosure"
  assert_grep 'reports no association' "$case_dir/stderr" \
    "gitlab-other-approval: the notice implied a standing check GitLab does not support"
  pass "a GitLab merge discloses whether its approver is the account that opened the merge request"
}

test_gitlab_discloses_a_self_approval

# A refusal must not name the same commit as both terms of a contrast. When the
# only review at the head is withdrawn or unsubmitted, the head was reviewed and
# the review stopped counting - which sends the operator somewhere different
# from "your approval is of an older commit".
# The disclosure must not assert a comparison it could not make.
test_an_unreadable_author_is_not_reported_as_a_different_account() {
  local case_dir head=1616161616161616161616161616161616161616
  case_dir=$(make_case github-author-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # Everything readable except the account that opened the pull request.
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","author":null,"reviews":[$(approving_review "$head" reviewer)],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-author-unreadable: the merge should proceed"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep 'could not be read' "$case_dir/stderr" \
    "github-author-unreadable: an unread author was not reported as unread"
  assert_no_grep 'is not the account that opened the pull request' "$case_dir/stderr" \
    "github-author-unreadable: the notice asserted a comparison it never made"
  pass "an approval whose pull request author could not be read says so instead of claiming a different account"
}

test_a_withdrawn_review_at_the_head_is_not_reported_as_a_stale_one() {
  local case_dir rc head=1414141414141414141414141414141414141414
  local older=1515151515151515151515151515151515151515
  case_dir=$(make_case github-withdrawn-at-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$older" past 'Review verdict: APPROVED' 2026-09-19T09:00:00Z),$(review_entry DISMISSED "$head" reviewer 'Review verdict: APPROVED' 2026-09-20T09:00:00Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-withdrawn-at-head: a withdrawn approval must not merge"
  assert_grep 'withdrawn or was never submitted' "$case_dir/stderr" \
    "github-withdrawn-at-head: the refusal did not name the withdrawn review"
  assert_no_grep "not the current head $head" "$case_dir/stderr" \
    "github-withdrawn-at-head: the refusal claimed the head was never reviewed"

  # The genuinely stale case keeps its own message, and its two commits differ.
  case_dir=$(make_case github-stale-not-withdrawn)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" "$(approving_review "$older")"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-stale-not-withdrawn: a stale approval must not merge"
  assert_grep "of commit $older, not the current head $head" "$case_dir/stderr" \
    "github-stale-not-withdrawn: the stale refusal lost its two distinct commits"
  pass "a withdrawn review at the head and an approval of an older commit get different refusals"
}

test_a_withdrawn_review_at_the_head_is_not_reported_as_a_stale_one
test_an_unreadable_author_is_not_reported_as_a_different_account

# A forge that will not answer and a pull request nobody approved are different
# states, and they send an operator somewhere different: one says the forge is
# not answering, the other says go get a review. If they produced the same
# sentence, a supervisor hitting a rate limit would spend its time dispatching a
# reviewer for a pull request that already has one.
test_a_failed_forge_read_is_never_reported_as_a_missing_approval() {
  local case_dir rc head=1717171717171717171717171717171717171717

  # 1. The forge does not answer at all.
  case_dir=$(make_case github-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/github-view-fails"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-read-fails: an unanswered forge read must not merge"
  assert_grep 'the forge did not answer the read' "$case_dir/stderr" \
    "github-read-fails: the refusal did not say the forge failed to answer"
  # Which of rate limit, expired token, DNS failure or a wrong URL it was
  # decides what firstmate does next, and this refusal is the only place that
  # text can reach it.
  assert_grep 'API rate limit exceeded' "$case_dir/stderr" \
    "github-read-fails: the forge's own account of the failure was discarded"
  assert_grep 'the forge said:' "$case_dir/stderr" \
    "github-read-fails: the forge's text was not marked as the forge's"
  assert_no_grep 'no review has been posted' "$case_dir/stderr" \
    "github-read-fails: an unanswered read was reported as a missing approval"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-read-fails: gh pr merge ran on a read that never answered"

  # 2. The forge answers, but not with the reviews this reads.
  case_dir=$(make_case github-reviews-absent)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","author":{"login":"worker"},"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-reviews-absent: an unreadable reviews list must not merge"
  assert_grep 'could not read the GitHub pull request reviews' "$case_dir/stderr" \
    "github-reviews-absent: the refusal did not name the reviews it could not read"
  assert_grep 'retrying will not clear it' "$case_dir/stderr" \
    "github-reviews-absent: the refusal did not say whether retrying clears it"
  assert_no_grep 'no review has been posted' "$case_dir/stderr" \
    "github-reviews-absent: an unreadable reviews list was reported as a missing approval"

  # 3. The forge answers and the pull request genuinely has no review.
  case_dir=$(make_case github-genuinely-unreviewed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" ''
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-genuinely-unreviewed: an unreviewed pull request must not merge"
  assert_grep 'no review has been posted' "$case_dir/stderr" \
    "github-genuinely-unreviewed: the refusal did not say a review is missing"
  assert_no_grep 'could not read' "$case_dir/stderr" \
    "github-genuinely-unreviewed: a missing approval was reported as a failed read"
  assert_no_grep 'did not answer' "$case_dir/stderr" \
    "github-genuinely-unreviewed: a missing approval was reported as an unanswered forge"
  pass "a forge that will not answer, an unreadable reviews list, and a pull request with no review each refuse with their own message"
}

test_a_failed_forge_read_is_never_reported_as_a_missing_approval

# The gate and its own preview must not give different reasons for one payload.
# A review from an account with no standing that also states no verdict used to
# be told to add a verdict line - a remedy that produces a different refusal on
# the next attempt - while bin/fm-pr-state.sh named the standing problem.
test_a_nonstanding_verdictless_review_names_the_standing_problem() {
  local case_dir rc head=1818181818181818181818181818181818181818
  case_dir=$(make_case github-nonstanding-no-verdict)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" drive-by 'Some notes, no verdict.' 2026-09-20T09:00:00Z NONE)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-nonstanding-no-verdict: it must not merge"
  assert_grep 'with no standing on this repository' "$case_dir/stderr" \
    "github-nonstanding-no-verdict: the refusal did not name the standing problem"
  assert_grep 'drive-by' "$case_dir/stderr" \
    "github-nonstanding-no-verdict: the refusal did not name the account"
  assert_no_grep 'states no verdict' "$case_dir/stderr" \
    "github-nonstanding-no-verdict: the refusal offered a remedy that would not fix it"

  # A standing review with no verdict keeps the verdict remedy, which is the
  # right one for it.
  case_dir=$(make_case github-standing-no-verdict)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" reviewer 'Some notes, no verdict.')"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-standing-no-verdict: it must not merge"
  assert_grep 'states no verdict' "$case_dir/stderr" \
    "github-standing-no-verdict: a standing review lost the verdict remedy"
  assert_no_grep 'with no standing' "$case_dir/stderr" \
    "github-standing-no-verdict: a standing review was reported as having none"
  pass "the merge path separates a standing review with no verdict from a non-standing one, as its preview does"
}

test_a_nonstanding_verdictless_review_names_the_standing_problem

# Four different read failures used to print one sentence, and one of them was
# the checks read. They send an operator to different places: a forge that did
# not answer clears on its own, a payload this cannot parse never will.
test_each_failed_read_says_which_read_failed() {
  local case_dir rc head=1919191919191919191919191919191919191919

  # The payload is not JSON this can parse.
  case_dir=$(make_case github-unparseable-payload)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' "$head" > "$case_dir/github-head"
  printf '%s\n' '{"state":"OPEN", this is not json' > "$case_dir/github-view.json"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-unparseable-payload: it must not merge"
  assert_grep 'could not parse' "$case_dir/stderr" \
    "github-unparseable-payload: the refusal did not say the payload would not parse"
  assert_no_grep 'did not answer' "$case_dir/stderr" \
    "github-unparseable-payload: an answered forge was reported as unanswered"

  # The checks rollup is a shape this cannot read.
  case_dir=$(make_case github-unreadable-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","author":{"login":"worker"},"reviews":[$(approving_review "$head")],"statusCheckRollup":"not-an-array"}
JSON
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-unreadable-checks: it must not merge"
  assert_grep 'could not read the GitHub pull request checks' "$case_dir/stderr" \
    "github-unreadable-checks: a failed checks read was not named as one"
  assert_no_grep 'reviews before merging' "$case_dir/stderr" \
    "github-unreadable-checks: a failed checks read was reported as a reviews read"

  # The pull request's own fields not reading back. A value carrying a newline
  # splits a field, so the six-field read comes back short and the state is
  # unknown - which is not the same as the forge failing to answer.
  case_dir=$(make_case github-fields-short)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main\nsplit","author":{"login":"worker"},"reviews":[$(approving_review "$head")],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-fields-short: a short field read must not merge"
  assert_grep 'did not read back cleanly' "$case_dir/stderr" \
    "github-fields-short: a short field read was not named as one"
  assert_no_grep 'did not answer' "$case_dir/stderr" \
    "github-fields-short: a short field read was reported as an unanswered forge"

  # The reviews not reading back cleanly, which is a different payload problem
  # from the reviews being a shape this cannot read.
  case_dir=$(make_case github-reviews-short)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" 'two
lines' 'Review verdict: APPROVED')"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-reviews-short: a split reviews field must not merge"
  assert_grep "reviews did not read back cleanly" "$case_dir/stderr" \
    "github-reviews-short: a split reviews field was not named as one"
  assert_no_grep 'came back in a shape' "$case_dir/stderr" \
    "github-reviews-short: a split field was reported as an unreadable shape"
  pass "each of the six read failures names its own read, including the two field-count guards"
}

test_each_failed_read_says_which_read_failed

# Failed, still running, never started and cancelled want four different actions
# from an operator. One sentence for all of them hands the next supervisor the
# trap this fleet spent a day establishing: that a cancelled job means several
# things and only its own timestamps separate them.
test_each_non_green_check_says_what_is_wrong_with_it() {
  local case_dir rc head=2020202020202020202020202020202020202020
  local n=400 probe

  for probe in \
    "COMPLETED FAILURE failed" \
    "COMPLETED CANCELLED was cancelled" \
    "COMPLETED TIMED_OUT timed out" \
    "IN_PROGRESS - is still running" \
    "QUEUED - has not started yet"; do
    # shellcheck disable=SC2086 # The probe's fields are split deliberately.
    set -- $probe
    n=$((n + 1))
    case_dir=$(make_case "github-check-$2-$n")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" "$(check_run ci "$1" "$2")"
    set +e
    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$n" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-check-$2: a non-green check must not merge"
    shift 2
    assert_grep "check 'ci' $*" "$case_dir/stderr" \
      "github-check: the refusal did not say what was wrong with the check"
  done

  # The waiver still matches the name, not the wording.
  case_dir=$(make_case github-check-waiver-still-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" "$(check_run ci COMPLETED CANCELLED)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/450 \
    --allow-red ci > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-check-waiver-still-name: --allow-red should still waive by name"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 450 example/repo --squash
  pass "each non-green check names its own state, and --allow-red still matches on the name"
}

test_each_non_green_check_says_what_is_wrong_with_it

# Every other fixture here is a SINGLE review at the head. These are the
# combinations, and they assert the same condition bin/fm-pr-state.sh names for
# the same payload, so the gate and its preview cannot drift apart again.
test_combinations_at_one_head_refuse_for_the_named_reason() {
  local case_dir rc head=2121212121212121212121212121212121212121

  # (A) A standing approval beside a standing decline: the decline wins, and it
  # is tested before the approval is looked at.
  case_dir=$(make_case github-approval-beside-decline)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(approving_review "$head" r1),$(review_entry CHANGES_REQUESTED "$head" r2 'Fix R1.' 2026-09-20T10:00:00Z)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-approval-beside-decline: a decline must not be merged over"
  assert_grep 'does not approve' "$case_dir/stderr" \
    "github-approval-beside-decline: an approval hid a decline"

  # (B) A decline from an account with no standing still declines: the gate's
  # refusal test does not ask about standing.
  case_dir=$(make_case github-nonstanding-decline)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry CHANGES_REQUESTED "$head" stranger 'No.' 2026-09-20T09:00:00Z NONE)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-nonstanding-decline: it must not merge"
  assert_grep 'does not approve' "$case_dir/stderr" \
    "github-nonstanding-decline: a decline from an account with no standing was not named as a decline"

  # (D) A standing review with no verdict beside an approval from an account
  # with no standing: the outside approval is the condition reported.
  case_dir=$(make_case github-verdictless-beside-outside)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" r1 'Notes, no verdict.' 2026-09-20T08:00:00Z),$(approving_review "$head" stranger NONE)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-verdictless-beside-outside: it must not merge"
  assert_grep 'an approval counts only from OWNER, MEMBER, or COLLABORATOR' "$case_dir/stderr" \
    "github-verdictless-beside-outside: the refusal did not name the outside approval"
  assert_grep 'stranger' "$case_dir/stderr" \
    "github-verdictless-beside-outside: the refusal did not name the account that approved"
  assert_no_grep 'states no verdict' "$case_dir/stderr" \
    "github-verdictless-beside-outside: the refusal named a condition its preview does not"
  pass "combinations at one head refuse for the condition the preview names, and a decline is never hidden by an approval"
}

test_combinations_at_one_head_refuse_for_the_named_reason

# Drive one two-run rollup through the entrypoint and assert which state the
# refusal reported. Args: head label first_entry second_entry expected_phrase
assert_reported_state() {
  local head=$1 label=$2 first=$3 second=$4 want=$5 case_dir rc
  case_dir=$(make_case "github-multi-run-$label")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" "$first" "$second"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-multi-run-$label: a non-green check must not merge"
  assert_grep "check 'ci' $want" "$case_dir/stderr" \
    "github-multi-run-$label: array order decided the reported state"
}

# Two runs of one check name are one state of the world. Which state the refusal
# reports must come from the same .at that decides red or green, not from the
# order the forge happened to list them - an older cancelled run under a newer
# one still in flight means wait, not re-run it.
test_a_multi_run_check_reports_its_newest_run() {
  local case_dir rc head=2222222222222222222222222222222222222222
  local newer older

  newer=$(check_run ci IN_PROGRESS - 2026-09-20T10:00:00Z)
  older=$(check_run ci COMPLETED CANCELLED 2026-09-20T09:00:00Z)

  case_dir=$(make_case github-multi-run-order-a)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" "$newer" "$older"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-multi-run-order-a: a check still running must not merge"
  assert_grep "check 'ci' is still running" "$case_dir/stderr" \
    "github-multi-run-order-a: the newest run's state was not the one reported"

  # The same two runs, reversed. One state of the world, so one answer.
  case_dir=$(make_case github-multi-run-order-b)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" "$older" "$newer"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-multi-run-order-b: a check still running must not merge"
  assert_grep "check 'ci' is still running" "$case_dir/stderr" \
    "github-multi-run-order-b: array order decided which state was reported"
  assert_no_grep 'was cancelled' "$case_dir/stderr" \
    "github-multi-run-order-b: an older cancelled run was reported over a newer one in flight"

  # Two runs the timestamp cannot separate: same whole second, and both undated.
  # sort_by is stable, so without a second key the forge's array order decides
  # which state is reported - the defect one layer under the one above.
  local tied_done tied_live undated_done undated_live
  tied_done=$(check_run ci COMPLETED CANCELLED 2026-09-20T09:00:00Z)
  tied_live=$(check_run ci IN_PROGRESS - 2026-09-20T09:00:00Z)
  undated_done=$(check_run ci COMPLETED FAILURE)
  undated_live=$(check_run ci QUEUED -)

  # Both orders of each pair, because a stable sort with an inseparable key is
  # exactly what leaves array position deciding.
  assert_reported_state "$head" tied "$tied_done" "$tied_live" 'is still running'
  assert_reported_state "$head" tied-rev "$tied_live" "$tied_done" 'is still running'
  assert_reported_state "$head" undated "$undated_done" "$undated_live" 'has not started yet'
  assert_reported_state "$head" undated-rev "$undated_live" "$undated_done" 'has not started yet'
  pass "a check with several non-green runs reports the newest one's state, and a run still in flight wins the ties the timestamp cannot separate"
}

test_a_multi_run_check_reports_its_newest_run

# A check genuinely named with a trailing space renders exactly like an unnamed
# one. Deciding the sentinel on the rendered row renamed it, so the refusal named
# a check that does not exist and --allow-red could never match the real name.
test_a_real_name_is_never_renamed_to_the_unnamed_sentinel() {
  local case_dir rc head=2323232323232323232323232323232323232323

  case_dir=$(make_case github-trailing-space-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run 'Lint ' COMPLETED FAILURE 2026-09-20T09:00:00Z)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-trailing-space-name: a red check must not merge"
  assert_grep "check 'Lint ' failed" "$case_dir/stderr" \
    "github-trailing-space-name: a real name was renamed to the sentinel"
  assert_no_grep 'unnamed check' "$case_dir/stderr" \
    "github-trailing-space-name: the refusal named a check that does not exist"

  # And the waiver matches that real name, which it could not do if the row had
  # been renamed.
  case_dir=$(make_case github-trailing-space-waiver)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run 'Lint ' COMPLETED FAILURE 2026-09-20T09:00:00Z)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    --allow-red 'Lint ' > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-trailing-space-waiver: --allow-red should match the real name"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash

  # A genuinely unnamed check still reaches the sentinel.
  case_dir=$(make_case github-genuinely-unnamed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run '' COMPLETED FAILURE 2026-09-20T09:00:00Z)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-genuinely-unnamed: a red unnamed check must not merge"
  assert_grep "check '(unnamed check)' failed" "$case_dir/stderr" \
    "github-genuinely-unnamed: an unnamed check lost its sentinel"
  pass "the unnamed sentinel is decided on the name, so a real name is never renamed to it"
}

test_a_real_name_is_never_renamed_to_the_unnamed_sentinel

# Both branches are guarded on a count greater than one being possible, and name
# the last of several, so neither may call it "the only" one.
test_a_refusal_never_calls_several_reviews_the_only_one() {
  local case_dir rc head=2424242424242424242424242424242424242424

  # Two approvals from accounts with no standing.
  case_dir=$(make_case github-two-outside-approvals)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(approving_review "$head" s1 NONE),$(approving_review "$head" s2 NONE)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-two-outside-approvals: it must not merge"
  assert_grep 'all 2 approvals' "$case_dir/stderr" \
    "github-two-outside-approvals: the refusal did not say how many there were"
  assert_no_grep 'the only approval' "$case_dir/stderr" \
    "github-two-outside-approvals: two approvals were called the only one"

  # Two non-standing reviews at the head, neither approving.
  case_dir=$(make_case github-two-nonstanding-reviews)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" \
    "$(review_entry COMMENTED "$head" s1 'Notes.' 2026-09-20T08:00:00Z NONE),$(review_entry COMMENTED "$head" s2 'More notes.' 2026-09-20T09:00:00Z NONE)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-two-nonstanding-reviews: it must not merge"
  assert_grep 'all 2 reviews' "$case_dir/stderr" \
    "github-two-nonstanding-reviews: the refusal did not say how many there were"
  assert_no_grep 'the only review' "$case_dir/stderr" \
    "github-two-nonstanding-reviews: two reviews were called the only one"

  # One of each keeps the singular wording, which is true for it.
  case_dir=$(make_case github-one-outside-approval)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_reviews "$case_dir" "$head" "$(approving_review "$head" s1 NONE)"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-one-outside-approval: it must not merge"
  assert_grep 'the only approval' "$case_dir/stderr" \
    "github-one-outside-approval: a single approval lost its singular wording"
  pass "a refusal says how many reviews it counted instead of calling several the only one"
}

test_a_refusal_never_calls_several_reviews_the_only_one

# The GitLab path gets what the GitHub path got: three distinct read failures
# named apart, and the forge's own account of why kept rather than discarded.
test_the_gitlab_read_names_its_failure_and_quotes_the_forge() {
  local case_dir rc

  case_dir=$(make_gitlab_case gitlab-read-unanswered)
  : > "$case_dir/glab-view-fails"
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-read-unanswered: an unanswered read must not merge"
  assert_grep 'the forge did not answer the read' "$case_dir/stderr" \
    "gitlab-read-unanswered: the refusal did not say the forge failed to answer"
  assert_grep '429 Too Many Requests' "$case_dir/stderr" \
    "gitlab-read-unanswered: the forge's own account of the failure was discarded"
  assert_grep 'the forge said:' "$case_dir/stderr" \
    "gitlab-read-unanswered: the forge's text was not marked as the forge's"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-read-unanswered: glab mr merge ran on a read that never answered"

  # A payload the read cannot parse is a different condition and says so.
  case_dir=$(make_gitlab_case gitlab-unparseable)
  printf '%s\n' '{"iid":7, this is not json' > "$case_dir/mr.json"
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-unparseable: an unparseable payload must not merge"
  assert_grep 'could not parse' "$case_dir/stderr" \
    "gitlab-unparseable: the refusal did not say the payload would not parse"
  assert_no_grep 'did not answer' "$case_dir/stderr" \
    "gitlab-unparseable: an answered forge was reported as unanswered"

  # A field that does not read back cleanly is a third condition.
  case_dir=$(make_gitlab_case gitlab-fields-short)
  write_mr_json "$case_dir/mr.json" 'author=two\nlines'
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-fields-short: a short field read must not merge"
  assert_grep 'did not read back cleanly' "$case_dir/stderr" \
    "gitlab-fields-short: a short field read was not named as one"
  pass "the GitLab read names which of its three failures happened and keeps the forge's own account of it"
}

test_the_gitlab_read_names_its_failure_and_quotes_the_forge

# The read after the forge accepted the merge is the one place the forge's own
# text is the only evidence of whether the merge landed, and R21 added that
# quoting with no fixture driving it.
test_a_failed_post_merge_confirmation_quotes_the_forge() {
  local case_dir
  case_dir=$(make_gitlab_case gitlab-post-merge-view-fails)
  : > "$case_dir/glab-post-merge-view-fails"

  # This path exits 0 deliberately: the merge was accepted, so the poll stays
  # armed and the unconfirmed landing is reported as actionable rather than as a
  # failed merge. What must not happen is the landing being reported as proven.
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-post-merge-view-fails: an unconfirmed landing should not exit non-zero"
  assert_grep 'landed state could not be confirmed' "$case_dir/stderr" \
    "gitlab-post-merge-view-fails: the outcome did not say the landing was unconfirmed"
  assert_grep '502 Bad Gateway' "$case_dir/stderr" \
    "gitlab-post-merge-view-fails: the forge's own account of the failed confirmation was discarded"
  pass "a post-merge confirmation that fails keeps the forge's account of why, which is the only evidence the merge landed"
}

test_a_failed_post_merge_confirmation_quotes_the_forge
