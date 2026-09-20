#!/usr/bin/env bash
# Report the blockers this command can see on one GitHub pull request.
#
# This is a one-shot, read-only command. It reads the current pull request,
# reported checks, submitted reviews, and review decision from GitHub at
# invocation time. It never posts, requests, approves, or merges.
# It reports on checks that have reported. A required context that has never
# reported on this head is absent from what this command reads and cannot be
# enumerated here. Empty output therefore means that no reported required check
# is failing or pending; it does not mean the pull request is ready to merge.
# When nothing has reported, or nothing required has, that is printed rather
# than read as ready. Advisory checks do not block and are omitted.
# A missing approval IS reported as a blocker, because bin/fm-pr-merge.sh
# refuses a merge without one and this command exists to say what would stop
# that merge. It cannot use GitHub's reviewDecision for it: this fleet posts
# from one account, GitHub refuses --approve on a self-opened pull request, and
# the verdict therefore lives in the last line of a COMMENTED review body,
# which reviewDecision does not count and can never report as APPROVED.
# So the approval is read the same way the merge path reads it, from the same
# owner - bin/fm-review-verdict-lib.sh for the line, and the same rules for
# which review counts: submitted, standing, at the current head, and written by
# an account this repository granted standing.
# reviewDecision still owns
# CHANGES_REQUESTED, whose review history is printed to explain it, naming each
# reviewer whose latest verdict still requests changes and marking it STALE when
# it was left at a superseded head.
# Reading it needs nothing this command did not already need: gh does the JSON
# work through its own --jq and the shell does the string comparisons, so gh
# remains the single tool requirement.
# A closed or merged pull request reports that terminal state and nothing else.
# Unresolved review-thread state is out of this command's scope.
#
# Usage: fm-pr-state.sh <pr-url>
#   Prints one line per blocker it can see and nothing when it sees none.
#   Blockers do not change the successful exit status; lookup or usage refusal
#   exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-review-verdict-lib.sh
. "$SCRIPT_DIR/fm-review-verdict-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"

URL=$1
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

if [ -n "$MERGED_AT" ]; then
  printf 'STATE: merged at %s\n' "$MERGED_AT"
  exit 0
elif [ "$STATE" != open ]; then
  printf 'STATE: %s\n' "$STATE"
  exit 0
fi
[ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM
if ! REQUIRED=$(gh pr checks "$URL" --required --json name,state,bucket --jq '
  .[]
  | select(.bucket != "pass" and .bucket != "skipping")
  | "REQUIRED CHECK: \(.name) (\(.state))"' 2>"$GH_STDERR"); then
  # These two sentences are gh's own human-readable error text, verified against
  # gh 2.100.0 on 2026-09-12. gh reports "nothing reported" as an error rather
  # than as structured data, so matching its text is the only way to tell that
  # apart from a real lookup failure. An unrecognised message falls through to
  # the refusal below, so a reword degrades loudly rather than silently.
  if grep -q "^no checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: none reported yet"
  elif grep -q "^no required checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: no required check has reported; readiness unconfirmed"
  else
    cat "$GH_STDERR" >&2
    die "could not read required checks for $URL"
  fi
fi
[ -z "$REQUIRED" ] || printf '%s\n' "$REQUIRED"

# The approval the merge path requires, read by its rules rather than by
# reviewDecision. A review counts when it is submitted and standing, sits at the
# current head, comes from an account this repository granted standing, and
# either carries GitHub's own APPROVED state or ends with the approved verdict
# line. Reviews are sorted by submission time before any of that, because the
# blocker names "the newest review" and bin/fm-pr-merge.sh establishes that
# ordering the same way; taking the forge's array order would let the two name
# different commits for one pull request. The ways of being unapproved are reported apart rather than collapsed
# into one line: no review posted, a review at this head that states no verdict,
# one from an account with no standing, one withdrawn or never submitted, and an
# approval of a superseded commit each send the operator somewhere different,
# which is why bin/fm-pr-merge.sh separates them too. A read that cannot
# complete says so rather than falling silent, because an approval this cannot
# see is one it must not report as present.
#
# The split between the two halves is deliberate. gh's own --jq does the JSON
# work, so this command still needs nothing but gh, and the shell does every
# string comparison. That is why neither the verdict line nor the head commit is
# written into the jq program: gh accepts no --arg, so a value can only reach
# that program by being pasted into its text, and a string this repository edits
# does not belong inside an expression it also parses. They are emitted as data
# and compared here instead - "<commit> A" for GitHub's own approved state, and
# "<commit> T<last non-empty line>" for a review whose verdict is body text.
#
# This is a read-only preview of one condition the merge path proves for itself;
# bin/fm-pr-merge.sh remains the authority, and a disagreement between them is
# this command being out of date, never permission to merge.
# shellcheck disable=SC2016  # gh's jq engine expands $st, $a and $oid, not the shell.
if ! APPROVAL_ROWS=$(gh pr view "$URL" --json reviews --jq '
  def tail_line:
    (.body // "")
    | split("\n")
    | map(sub("\r$"; "") | sub("^[ \t]+"; "") | sub("[ \t]+$"; ""))
    | map(select(. != ""))
    | last // "";
  def submitted:
    (.state // "") as $st
    | ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"] | index($st) != null;
  def standing:
    (.authorAssociation // "") as $a
    | ["OWNER", "MEMBER", "COLLABORATOR"] | index($a) != null;
  .reviews
  | sort_by(.submittedAt // "")
  | .[]
  | (.commit.oid // "") as $oid
  | if (submitted | not) then $oid + " D"
    elif .state == "CHANGES_REQUESTED" then $oid + " N"
    elif (.state == "APPROVED" and standing) then $oid + " A"
    elif .state == "APPROVED" then $oid + " O"
    elif (standing | not) then $oid + " X" + tail_line
    else $oid + " T" + tail_line
    end
  ' 2>"$GH_STDERR"); then
  # This file already captures gh's stderr for the checks read seventy lines
  # above and prints what it does not recognise; the approval read threw the
  # same channel away, so one script gave two different answers about whether
  # the forge's own account of a failure is worth keeping.
  printf 'APPROVAL UNREADABLE: could not read the reviews on this pull request\n'
  if [ -s "$GH_STDERR" ]; then
    printf 'the forge said:\n'
    sed 's/^/  /' "$GH_STDERR"
  fi
else
  # Every review is classified rather than filtered, because the four ways a
  # pull request can be unapproved send the operator somewhere different and
  # bin/fm-pr-merge.sh reports them apart for that reason. A preview that keeps
  # the decision and drops the distinction is not previewing the decision.
  APPROVED_AT_HEAD=0
  REVIEWS_SEEN=0
  STANDING_AT_HEAD=0
  DECLINED_AT_HEAD=0
  WITHDRAWN_AT_HEAD=0
  OUTSIDE_AT_HEAD=0
  NONSTANDING_AT_HEAD=0
  NEWEST_REVIEWED=
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    REVIEWS_SEEN=$((REVIEWS_SEEN + 1))
    row_commit=${row%% *}
    row_verdict=${row#* }
    NEWEST_REVIEWED=$row_commit
    [ "$row_commit" = "$HEAD" ] || continue
    case "$row_verdict" in
      D) WITHDRAWN_AT_HEAD=1 ;;
      N) DECLINED_AT_HEAD=1 ;;
      O) NONSTANDING_AT_HEAD=1; OUTSIDE_AT_HEAD=1 ;;
      X*)
        # A review from an account with no standing, its verdict in the body.
        # The gate reports an approval from such an account apart from any
        # other review from one, because the two want different remedies, and a
        # decline counts whoever wrote it - the gate's refusal test does not ask
        # about standing either.
        NONSTANDING_AT_HEAD=1
        case "${row_verdict#X}" in
          "$FM_REVIEW_VERDICT_APPROVED") OUTSIDE_AT_HEAD=1 ;;
          "$FM_REVIEW_VERDICT_DECLINED") DECLINED_AT_HEAD=1 ;;
        esac
        ;;
      A) STANDING_AT_HEAD=$((STANDING_AT_HEAD + 1)); APPROVED_AT_HEAD=1 ;;
      T*)
        # The verdict literals are compared here rather than inside the jq
        # program, so bin/fm-review-verdict-lib.sh stays their only owner. A
        # review that declined is not one that stated no verdict: it wants
        # findings fixed and a new review, not a verdict line added.
        STANDING_AT_HEAD=$((STANDING_AT_HEAD + 1))
        case "${row_verdict#T}" in
          "$FM_REVIEW_VERDICT_APPROVED") APPROVED_AT_HEAD=1 ;;
          "$FM_REVIEW_VERDICT_DECLINED") DECLINED_AT_HEAD=1 ;;
        esac
        ;;
    esac
  done <<APPROVAL_ROWS
$APPROVAL_ROWS
APPROVAL_ROWS
  # The order below is bin/fm-pr-merge.sh's refusal chain, branch for branch.
  # A refusal is tested FIRST and UNCONDITIONALLY, exactly as the gate tests
  # `refusing` before it looks at `approving`: an approval standing beside a
  # decline does not clear the decline, and silence here is what firstmate reads
  # as ready, so a hidden decline would report a declined pull request as
  # review-ready before the gate ever got the chance to refuse it.
  if [ "$DECLINED_AT_HEAD" -eq 1 ]; then
    printf 'NO APPROVAL AT HEAD: %s (a review at this head does not approve)\n' "$HEAD"
  elif [ "$APPROVED_AT_HEAD" -ne 1 ]; then
    if [ "$REVIEWS_SEEN" -eq 0 ]; then
      printf 'NO APPROVAL AT HEAD: %s (no review has been posted)\n' "$HEAD"
    elif [ "$OUTSIDE_AT_HEAD" -eq 1 ]; then
      printf 'NO APPROVAL AT HEAD: %s (an approval at this head is from an account with no standing)\n' "$HEAD"
    elif [ "$STANDING_AT_HEAD" -ge 1 ]; then
      if [ "$STANDING_AT_HEAD" -eq 1 ]; then
        printf 'NO APPROVAL AT HEAD: %s (the review at this head states no verdict)\n' "$HEAD"
      else
        printf 'NO APPROVAL AT HEAD: %s (none of the %s reviews at this head states a verdict)\n' \
          "$HEAD" "$STANDING_AT_HEAD"
      fi
    elif [ "$NONSTANDING_AT_HEAD" -eq 1 ]; then
      printf 'NO APPROVAL AT HEAD: %s (a review at this head is from an account with no standing)\n' "$HEAD"
    elif [ "$WITHDRAWN_AT_HEAD" -eq 1 ]; then
      printf 'NO APPROVAL AT HEAD: %s (every review at this head is withdrawn or unsubmitted)\n' "$HEAD"
    else
      printf 'NO APPROVAL AT HEAD: %s (the newest review is of commit %s)\n' \
        "$HEAD" "${NEWEST_REVIEWED:-unreadable}"
    fi
  fi
fi

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
    .[]
    | select(.user.login != null and .commit_id != null and .submitted_at != null)
    | [.user.login, .state, .commit_id, .submitted_at]
    | @tsv') || die "could not read reviews for $URL"
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 4 && $1 != author && $2 != "COMMENTED" && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $4
      state[$1] = $2
      commit[$1] = $3
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head)
          printf "REVIEW: %s CHANGES_REQUESTED\n", reviewer
        else
          printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s\n", \
            reviewer, commit[reviewer]
      }
    }' | LC_ALL=C sort
fi
