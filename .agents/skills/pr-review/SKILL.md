---
name: pr-review
description: >-
  Agent-only procedure for the reviewed-PR delivery path: the end-to-end shape of a direct-PR ship without the no-mistakes pipeline, dispatching a reviewer against an open pull request, and what firstmate does with the findings.
  Use before dispatching a reviewer, on a wake reporting a review posted, and before ruling on, relaying, or fixing a reviewer finding.
  This skill is the single owner of the reviewed-PR path's detail; AGENTS.md section 7 states it in one paragraph and points here.
user-invocable: false
metadata:
  internal: true
---

# pr-review

The reviewed-PR path is what a `direct-PR` ship task looks like end to end.
`AGENTS.md` section 7 owns delivery-mode selection and merge authority and does not restate this procedure.
`bin/fm-brief.sh`'s `--review` contract is the single owner of what the reviewer itself owes; read the generated brief rather than restating its disciplines here or in a steer.

## The path, end to end

1. **The worker implements and pushes.**
   It works on its own branch in its own worktree and opens the pull request itself, exactly as the `direct-PR` definition of done in `bin/fm-dod-lib.sh` states.
   No pipeline, no validation run, no gate response flow.
2. **The pull request opens as soon as there is something to review**, not after everything is green.
   The worker's `done: PR <url>` line is the signal; record it with `bin/fm-pr-check.sh <id> <PR url>` as section 7 requires.
3. **A reviewer reviews it on the pull request.**
   Dispatch it as soon as the pull request exists.
   Do not wait for the checks: a reviewer reading the diff and a CI run watching the same commit are independent, and serializing them buys nothing.
4. **Firstmate reads the findings, rules, and posts the ruling on the pull request.**
5. **Fixes land as commits on the same pull request**, by the same worker, one finding per commit.
6. **The merge gate is: checks green, and every finding has a posted ruling.**
   Merge authority itself is unchanged and stays with section 7 - `yolo` on means firstmate merges through `bin/fm-pr-merge.sh`, `yolo` off means the captain's word.

Red checks are the worker's to fix, not the reviewer's and not a finding class of their own.
The reviewer reports a red check as a finding so it is visible with everything else; firstmate steers the worker to fix it.
Nothing merges red - section 7 owns that rule and the single named waiver.

## This is one pass, not a pipeline

One dispatch produces one review.
There is no round counter, no re-review requirement, no escalating sequence of passes, and nothing in this path counts or compares attempts.
If a change is large enough that firstmate genuinely wants a second pair of eyes after the fixes land, that is a new reviewer dispatch firstmate decides on and states a reason for - never an automatic next round.
If a path you are about to take starts needing gates, rounds, or a state machine to describe, stop and take it to the captain instead: that is the machinery this path exists to replace.

## Dispatch a reviewer

One call, the same shape as any other intake (`bin/fm-dispatch.sh` owns the mechanics):

```
bin/fm-dispatch.sh <review-task-id> --project projects/<name> \
  --review <full https:// PR url> --ask <file> --spec <file>
```

`--ask` is the captain's own words behind the pull request, copied from the shipping task's brief `## Captain's intent`.
The reviewer needs it to judge scope: a finding "widens scope" only against what the captain actually asked for, so a reviewer given no intent cannot apply that rule and will guess.
`--spec` is what to focus this review on - the risky surface, a subsystem, a class of defect the captain has been bitten by - and naming nothing in particular is a legitimate spec, written as such.

Give the review its own task id, distinct from the shipping task's.
It is filed and spawned as a scout, so it is supervised, torn down, and reported like any scout.

## Read the findings

Read them off the pull request, not out of the reviewer's pane:

```
gh-axi pr view <number> --reviews
```

That is the point of the path - the findings are on the pull request where the captain can read them too.
The reviewer's local record at `data/<review-task-id>/report.md` is a pointer to the posted review, useful for teardown and for finding the review again; it is never the authoritative copy.

A reviewer that reported `done:` without a review actually posted has failed its contract.
Verify the review is on the pull request before relaying anything to the captain, and steer the reviewer to post it rather than relaying findings that exist only in a session.

## Rule on each finding

Every finding gets a ruling. A finding left silent is the black box coming back.

Load `ask-user-authority` and apply its criteria unchanged.
Finding authority does not depend on who produced the finding, so a reviewer finding and a pipeline ask-user finding are the same question: firstmate decides what is unambiguous toward the accepted intent and escalates what is genuinely ambiguous, expanding, or destructive.
A finding the reviewer marked `widens scope: yes` is the reviewer telling you it believes this one is yours or the captain's; that marking is evidence for the judgment, not the judgment.

The rulings available to you are:

- **Fix** - the finding is a defect within the accepted intent. Steer the worker.
- **Won't fix** - the finding is correct but out of scope, or a preference you are declining. Say why; a declined finding with no reason is not a ruling.
- **Not a defect** - the reviewer is wrong. Say what it missed, with the evidence.
- **Captain's call** - escalate under `ask-user-authority`, then post the captain's answer as the ruling once it lands.

## Post the ruling on the pull request

Post it to the same pull request, naming the finding by its `R<n>` id so a reader can line the two up:

```
gh-axi pr comment <number> --body-file <file>
```

The captain's words go up **verbatim** when the ruling is the captain's.
Do not summarize, soften, re-order, or translate them into your own phrasing: the captain's exact wording is the ruling, and a paraphrase is a different ruling that the captain never gave.
Your own rulings are your own words, and you say which is which.

The same rule the captain's chat follows applies to the pull request: never put "captain" or any other direct address into it.

## Land the fixes

Steer the same worker that opened the pull request (`bin/fm-send.sh`), naming the finding ids it is to act on and the ruling for each.

One finding per commit.
A commit that fixes three findings cannot be reverted for one of them, cannot be reviewed against the finding it answers, and hides which finding a later regression came from.
Tell the worker this explicitly in the steer; it is the reviewed-PR path's commit rule, not the worker's default.

The worker pushes those commits to the same pull request and reports back.
Do not open a second pull request for fixes to the first.
