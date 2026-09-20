#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OLD_HEAD_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
OLD_HEAD_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test. The pull-request object speaks GitHub's own vocabulary: an
# uppercase state with MERGED as its own value, and a null mergeable while
# GitHub is still computing one.
# It evaluates with the local jq, while gh itself embeds gojq; the live guard in
# tests/fm-pr-state-live-e2e.test.sh runs the real engine.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
serve() {
  case "$*" in
    "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq "*)
      jq -n --arg head "$head" --arg state "${FM_TEST_STATE-OPEN}" \
        --arg merged "${FM_TEST_MERGED_AT-}" --arg draft "${FM_TEST_DRAFT-false}" \
        --arg mergeable "${FM_TEST_VIEW_MERGEABLE-MERGEABLE}" \
        --arg decision "${FM_TEST_VIEW_REVIEW_DECISION-APPROVED}" \
        '{state: $state, mergedAt: (if $merged == "" then null else $merged end),
          isDraft: ($draft == "true"), headRefOid: $head,
          author: {login: "prauthor", is_bot: false},
          mergeable: (if $mergeable == "null" then null else $mergeable end),
          reviewDecision: $decision}'
      ;;
    "api /repos/o/r/pulls/7/reviews?per_page=100 --paginate --jq "*)
      printf '%s\n' "${FM_TEST_REVIEWS:-[]}"
      ;;
    "pr view "*" --json reviews --jq "*)
      # The approval read. The verdict line and the head reach the shell as
      # data, so this answers the payload and the --jq program does the rest.
      # Defaults to one standing approval at the head, so every fixture that is
      # not about the approval stays silent the way it always did.
      if [ -n "${FM_TEST_APPROVAL_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_APPROVAL_ERROR" >&2
        exit 1
      fi
      default='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"reviewer"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: APPROVED"}]}'
      printf '%s\n' "${FM_TEST_APPROVAL_REVIEWS:-$default}"
      ;;
    "pr checks "*" --required --json name,state,bucket --jq "*)
      if [ -n "${FM_TEST_CHECKS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_CHECKS_ERROR" >&2
        exit 1
      fi
      checks='[{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"},{"name":"optional","state":"SKIPPED","bucket":"skipping","workflow":"ci"}]'
      printf '%s\n' "${FM_TEST_REQUIRED_CHECKS:-$checks}"
      ;;
    *)
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 91
      ;;
  esac
}
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
serve "$@" | jq -r "$prog"
SH
chmod +x "$FAKEBIN/gh"

run_state() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" https://github.com/o/r/pull/7
}

# reviews "<login> <state> <commit> <submitted_at>"... prints the JSON array
# GitHub's reviews endpoint returns for those submissions.
reviews() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" +"; "")
    | {user: {login: .[0], type: .[1]}, state: .[2], commit_id: .[3], submitted_at: .[4]})'
}

test_clean_pr_is_silent_and_ignores_skipped_checks() {
  local out
  out=$(run_state) || fail "clean fixture was refused"
  [ -z "$out" ] || fail "clean fixture should be silent, got: $out"
  pass "a passing required check and a skipped one leave nothing to report"
}

test_terminal_state_is_the_whole_report() {
  local out
  out=$(FM_TEST_STATE=CLOSED FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "closed fixture was refused"
  [ "$out" = 'STATE: closed' ] \
    || fail "a closed pull request leaves the author nothing else to read, got: $out"

  out=$(FM_TEST_STATE=MERGED FM_TEST_MERGED_AT=2019-10-04T16:01:04Z \
    FM_TEST_VIEW_MERGEABLE=null FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "merged fixture was refused"
  [ "$out" = 'STATE: merged at 2019-10-04T16:01:04Z' ] \
    || fail "a merged pull request says so and reports no blocker after it, got: $out"
  pass "a terminal pull request reports that state and nothing else"
}

test_draft_is_a_blocker() {
  local out
  out=$(FM_TEST_DRAFT=true run_state) || fail "draft fixture was refused"
  assert_contains "$out" 'DRAFT: pull request is not ready for review' \
    "a draft pull request leaves the author something to do"
  pass "draft state blocks readiness"
}

test_stale_blocking_reviews_explain_a_blocking_decision() {
  local out history expected
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "commenter User COMMENTED $OLD_HEAD_2 2026-09-01T23:10:00Z" \
    "alice User APPROVED $OLD_HEAD_2 2026-09-01T23:11:00Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "voided-review fixture was refused"
  expected=$(printf 'REVIEW DECISION: CHANGES_REQUESTED\nSTALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at %s' "$OLD_HEAD_2")
  [ "$out" = "$expected" ] \
    || fail "a stale verdict names the commit it was left at and no head this reading was not verified against, got: $out"
  assert_not_contains "$out" "$OLD_HEAD_1" \
    "a verdict the same reviewer later superseded is history, not a blocker"
  assert_not_contains "$out" 'commenter' \
    "a stale COMMENTED review is informational noise"
  assert_not_contains "$out" 'alice' \
    "a stale approval is not a concrete blocker"
  pass "stale changes-requested verdicts explain a blocking review decision"
}

test_approved_pr_with_only_stale_changes_requested_is_silent() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=APPROVED FM_TEST_REVIEWS=$history run_state) \
    || fail "approved stale-review fixture was refused"
  [ -z "$out" ] || fail "an approved PR with only stale review history should be silent, got: $out"
  pass "approved PR ignores stale changes-requested history"
}

test_current_changes_requested_review_is_a_blocker() {
  local out history
  history=$(reviews "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "current-review fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: coderabbitai[bot] CHANGES_REQUESTED' ] \
    || fail "a verdict left at the head under review blocks readiness and names no head, got: $out"
  pass "current changes-requested review blocks readiness"
}

test_changes_requested_decision_is_never_silent() {
  local out history
  history=$(reviews \
    "bob User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "bob User COMMENTED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "comment-after-changes fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: bob CHANGES_REQUESTED' ] \
    || fail "a later COMMENTED review does not clear the reviewer's change request, got: $out"

  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "decision-only fixture was refused"
  [ "$out" = 'REVIEW DECISION: CHANGES_REQUESTED' ] \
    || fail "GitHub's blocking decision must be printed even without an explaining review, got: $out"
  pass "a CHANGES_REQUESTED decision is always reported"
}

test_authors_own_changes_requested_review_is_not_a_blocker() {
  local out history
  history=$(reviews "prauthor User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "self-review fixture was refused"
  assert_not_contains "$out" 'REVIEW: prauthor' \
    "the author's own verdict is not a reviewer blocking them"
  pass "the author's own review is never listed as a blocker"
}

# GitHub's REVIEW_REQUIRED never becomes APPROVED here, because the verdict
# lives in a COMMENTED body that reviewDecision does not count. So it is not the
# signal this command blocks on; the approval read below is.
test_review_required_decision_is_not_itself_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_REVIEW_DECISION=REVIEW_REQUIRED run_state) \
    || fail "review-required fixture was refused"
  [ -z "$out" ] || fail "reviewDecision alone is not a blocker this command reports, got: $out"
  pass "a REVIEW_REQUIRED decision is not itself reported, because the approval is read directly"
}

# The blocker the merge path enforces: bin/fm-pr-merge.sh refuses without an
# approval at the head, so this command has to say so rather than fall silent
# and read as ready.
test_a_missing_approval_is_a_blocker() {
  local out head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e

  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[]}' run_state) \
    || fail "no-review fixture was refused"
  case "$out" in
    *"NO APPROVAL AT HEAD: $head (no review has been posted)"*) ;;
    *) fail "an unreviewed pull request must say no review was posted, got: $out" ;;
  esac

  # Approved, but of a commit that is no longer what would merge.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"reviewer"},"commit":{"oid":"2710bc5efc936efb70e95b86ca3582e9da7e60f4"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: APPROVED"}]}' run_state) \
    || fail "stale-approval fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(the newest review is of commit 2710bc5efc936efb70e95b86ca3582e9da7e60f4)'*) ;;
    *) fail "an approval of a superseded commit must name that commit, got: $out" ;;
  esac

  # Approved at the head by an account with no standing on this repository.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"NONE","author":{"login":"stranger"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: APPROVED"}]}' run_state) \
    || fail "outside-approval fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(an approval at this head is from an account with no standing)'*) ;;
    *) fail "a stranger's approval must be named as such, got: $out" ;;
  esac

  # "The newest review" must mean the newest by submission time, not the order
  # the forge happened to return, and must name the same commit the merge path
  # names. The newer review is listed first here.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"r2"},"commit":{"oid":"4dc2291e6969de1bf204fbdb53c9e57a8353d4e2"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: APPROVED"},{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"r1"},"commit":{"oid":"2710bc5efc936efb70e95b86ca3582e9da7e60f4"},"submittedAt":"2026-09-19T09:00:00Z","body":"Review verdict: APPROVED"}]}' run_state) \
    || fail "out-of-order fixture was refused"
  case "$out" in
    *'(the newest review is of commit 4dc2291e6969de1bf204fbdb53c9e57a8353d4e2)'*) ;;
    *) fail "the newest review must be the newest by submission time, got: $out" ;;
  esac

  # A withdrawn review at the head, which is not the same as a stale approval
  # and must not be reported as one.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"DISMISSED","authorAssociation":"COLLABORATOR","author":{"login":"reviewer"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: APPROVED"}]}' run_state) \
    || fail "withdrawn-approval fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(every review at this head is withdrawn or unsubmitted)'*) ;;
    *) fail "a withdrawn review at the head must be named as such, got: $out" ;;
  esac

  # A review that declined is not a review that stated no verdict: it wants
  # findings fixed and a new review, not a verdict line added. Both the verbal
  # decline (the only form this fleet can post) and GitHub's own
  # CHANGES_REQUESTED state must say so.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"reviewer"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"R1 defect high.\n\nReview verdict: NOT APPROVED"}]}' run_state) \
    || fail "declined fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(a review at this head does not approve)'*) ;;
    *) fail "a declined review must not be reported as stating no verdict, got: $out" ;;
  esac

  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"CHANGES_REQUESTED","authorAssociation":"COLLABORATOR","author":{"login":"reviewer"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Please fix R1."}]}' run_state) \
    || fail "changes-requested fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(a review at this head does not approve)'*) ;;
    *) fail "a CHANGES_REQUESTED review must not be reported as stating no verdict, got: $out" ;;
  esac

  # A standing review at the head that reached no verdict.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"reviewer"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Some notes, no verdict."}]}' run_state) \
    || fail "no-verdict fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(the review at this head states no verdict)'*) ;;
    *) fail "a verdictless review at the head must be named as such, got: $out" ;;
  esac

  # A read it cannot complete says so rather than staying silent.
  out=$(FM_TEST_APPROVAL_ERROR='could not resolve host' run_state) \
    || fail "approval-error fixture was refused"
  case "$out" in
    *'APPROVAL UNREADABLE'*) ;;
    *) fail "an unreadable approval must be reported, not omitted, got: $out" ;;
  esac
  pass "each way of being unapproved is reported apart, the way the merge path reports them"
}

# Every other fixture in this suite is a SINGLE review at the head, which is why
# a decline hidden behind an approval survived three rounds. These are the
# combinations, and each asserts the same condition bin/fm-pr-merge.sh names for
# the same payload.
test_combinations_at_one_head_agree_with_the_gate() {
  local out
  local head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e

  # (A) A standing approval beside a standing decline. The gate refuses on the
  # decline; silence here would report a declined pull request as review-ready.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"r1"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T08:00:00Z","body":"Review verdict: APPROVED"},{"state":"CHANGES_REQUESTED","authorAssociation":"COLLABORATOR","author":{"login":"r2"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Fix R1."}]}' run_state) \
    || fail "approval-beside-decline fixture was refused"
  [ -n "$out" ] \
    || fail "(A) a declined pull request read as ready: the preview printed nothing while the gate refuses it"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(a review at this head does not approve)'*) ;;
    *) fail "(A) an approval hid a decline, got: $out" ;;
  esac

  # (B) A decline from an account with no standing. The gate's refusal test does
  # not ask about standing, so this is a decline on both surfaces.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"CHANGES_REQUESTED","authorAssociation":"NONE","author":{"login":"stranger"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"No."}]}' run_state) \
    || fail "nonstanding-decline fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(a review at this head does not approve)'*) ;;
    *) fail "(B) a decline from an account with no standing was not reported as a decline, got: $out" ;;
  esac

  # The same decline written as a body verdict rather than a forge state.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"NONE","author":{"login":"stranger"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: NOT APPROVED"}]}' run_state) \
    || fail "nonstanding-verbal-decline fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(a review at this head does not approve)'*) ;;
    *) fail "(B) a verbal decline from an account with no standing was not reported as a decline, got: $out" ;;
  esac

  # (D) A standing review with no verdict beside an approval from an account
  # with no standing. The gate reports the outside approval, not the verdict.
  out=$(FM_TEST_APPROVAL_REVIEWS='{"reviews":[{"state":"COMMENTED","authorAssociation":"COLLABORATOR","author":{"login":"r1"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T08:00:00Z","body":"Notes, no verdict."},{"state":"COMMENTED","authorAssociation":"NONE","author":{"login":"stranger"},"commit":{"oid":"c2eac54c17a1ddc2633ad51b83e21e5fe888142e"},"submittedAt":"2026-09-20T09:00:00Z","body":"Review verdict: APPROVED"}]}' run_state) \
    || fail "verdictless-beside-outside fixture was refused"
  case "$out" in
    *'NO APPROVAL AT HEAD'*'(an approval at this head is from an account with no standing)'*) ;;
    *) fail "(D) the preview named a different condition than the gate, got: $out" ;;
  esac
  [ -n "$head" ]
  pass "combinations at one head are reported the way the gate reports them, and an approval never hides a decline"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_REQUIRED_CHECKS='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' run_state) \
    || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  assert_not_contains "$out" 'lint' \
    "a passing required check is not a blocker"
  pass "required failure blocks readiness"
}

# The next two cases supply gh's own "nothing reported" sentences through
# FM_TEST_CHECKS_ERROR, so they prove the behaviour GIVEN those strings and
# nothing about the strings themselves. A gh reword is invisible to this
# hermetic suite; only a run against a real gh would catch one.
test_unreported_required_checks_are_unconfirmed() {
  local out status
  out=$(FM_TEST_CHECKS_ERROR="no required checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported required checks was refused"
  [ "$out" = 'CHECKS: no required check has reported; readiness unconfirmed' ] \
    || fail "a head where nothing required has reported must not pass silently as ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.

  status=0
  FM_TEST_CHECKS_ERROR='HTTP 502: Bad Gateway' run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a real check lookup failure must still refuse"
  pass "given gh's sentence, an unreported required check is unconfirmed, other check lookup failures refuse"
}

test_no_reported_checks_is_unverified() {
  local out
  out=$(FM_TEST_CHECKS_ERROR="no checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported checks was refused"
  [ "$out" = 'CHECKS: none reported yet' ] \
    || fail "a head with no reported checks must read as unverified, not ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.
  pass "given gh's sentence, a head with no reported checks is unverified rather than ready"
}

test_help_states_what_silence_means_and_what_is_out_of_scope() {
  local out
  out=$("$SCRIPT" --help) || fail "help was refused"
  assert_contains "$out" 'it does not mean the pull request is ready to merge' \
    "help must not let empty output read as a verdict that the pull request can merge"
  assert_contains "$out" 'is absent from what this command reads' \
    "help must name the limit: a required context that never reported is absent from what is read"
  assert_contains "$out" "Unresolved review-thread state is out of this command's scope" \
    "help must state the thread-resolution boundary without inventing a reason for it"
  pass "help states what empty output means and what is out of scope"
}

test_unknown_mergeability_is_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"

  out=$(FM_TEST_VIEW_MERGEABLE=CONFLICTING run_state) \
    || fail "conflicting fixture was refused"
  assert_contains "$out" 'MERGEABILITY: conflicting' \
    "a conflicting merge state must be reported"
  pass "unknown and conflicting mergeability block readiness"
}

test_refusals_exit_nonzero() {
  local status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lookup refusal exited zero"

  local out
  status=0
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" 7 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "a bare number resolves against the ambient repository and is not an address"
  assert_contains "$out" 'expected a GitHub pull-request URL' \
    "a bare number must be refused as an address, not attempted as a lookup"
  pass "argument and lookup refusals exit nonzero"
}

test_clean_pr_is_silent_and_ignores_skipped_checks
test_terminal_state_is_the_whole_report
test_draft_is_a_blocker
test_stale_blocking_reviews_explain_a_blocking_decision
test_approved_pr_with_only_stale_changes_requested_is_silent
test_current_changes_requested_review_is_a_blocker
test_changes_requested_decision_is_never_silent
test_authors_own_changes_requested_review_is_not_a_blocker
test_review_required_decision_is_not_itself_a_blocker
test_a_missing_approval_is_a_blocker
test_combinations_at_one_head_agree_with_the_gate
test_required_failure_is_a_blocker
test_unreported_required_checks_are_unconfirmed
test_no_reported_checks_is_unverified
test_help_states_what_silence_means_and_what_is_out_of_scope
test_unknown_mergeability_is_a_blocker
test_refusals_exit_nonzero
