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
# an account this repository granted standing. reviewDecision still owns
# CHANGES_REQUESTED, whose review history is printed to explain it, naming each
# reviewer whose latest verdict still requests changes and marking it STALE when
# it was left at a superseded head.
# This is a read-only preview of one condition the merge path proves for itself;
# bin/fm-pr-merge.sh remains the authority, and a disagreement between them is
# this command being out of date, never permission to merge.
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
# line. The reviews are fetched raw and evaluated with jq rather than through
# gh's own --jq, because the verdict line has to reach the program as data and
# gh accepts no --arg; interpolating it into the program text instead would put
# a string this repository edits inside an expression it also parses.
# Any read failure, jq included, prints a blocker rather than staying silent: an
# approval this cannot see is one it must not report as present.
APPROVAL=
if ! command -v jq >/dev/null 2>&1; then
  printf 'APPROVAL UNREADABLE: jq is required to read the approval on this pull request\n'
elif ! REVIEWS_JSON=$(gh pr view "$URL" --json reviews 2>/dev/null) || [ -z "$REVIEWS_JSON" ]; then
  printf 'APPROVAL UNREADABLE: could not read the reviews on this pull request\n'
else
  # shellcheck disable=SC2016  # jq, not the shell, expands $head and $yes.
  APPROVAL=$(printf '%s' "$REVIEWS_JSON" | jq -r \
    --arg head "$HEAD" --arg yes "$FM_REVIEW_VERDICT_APPROVED" '
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
      if type != "object" or (.reviews | type) != "array" then error("no reviews") else . end
      | [ .reviews[]
          | select(submitted and standing and (.commit.oid // "") == $head)
          | select(.state == "APPROVED" or tail_line == $yes)
        ] | length' 2>/dev/null) || APPROVAL=
  case "$APPROVAL" in
    0) printf 'NO APPROVAL AT HEAD: %s\n' "$HEAD" ;;
    ''|*[!0-9]*) printf 'APPROVAL UNREADABLE: could not read the reviews on this pull request\n' ;;
  esac
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
