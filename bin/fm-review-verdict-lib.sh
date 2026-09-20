#!/usr/bin/env bash
# The single owner of the review verdict line: the exact string a reviewer ends
# its posted review with, and the exact string the merge gate matches.
#
# It lives here because it is one contract read by three programs that must
# agree byte for byte - bin/fm-brief.sh tells the reviewer what to write,
# bin/fm-pr-merge.sh decides whether a merge may proceed, and bin/fm-pr-state.sh
# reports the missing approval as a blocker. A copy in each was the one-owner
# rule broken with extra steps: nothing failed when they drifted, and the
# failure mode is silent and total, because every review would then state a
# verdict the gate cannot see and every merge would refuse "states no verdict"
# with a correct-looking brief in hand.
#
# Sourcing this file is what makes drift impossible rather than merely
# forbidden. tests/fm-pr-merge.test.sh additionally drives a brief scaffolded by
# bin/fm-brief.sh through bin/fm-pr-merge.sh's own entrypoint, so the agreement
# is asserted through both executable interfaces and not only by construction.
#
# Usage: . "$SCRIPT_DIR/fm-review-verdict-lib.sh"

# The prefix and the two verdicts, kept apart so a caller can render either the
# literal lines or the "<prefix> <one of these>" placeholder a brief shows.
FM_REVIEW_VERDICT_PREFIX='Review verdict:'
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_REVIEW_VERDICT_APPROVED="$FM_REVIEW_VERDICT_PREFIX APPROVED"
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_REVIEW_VERDICT_DECLINED="$FM_REVIEW_VERDICT_PREFIX NOT APPROVED"
