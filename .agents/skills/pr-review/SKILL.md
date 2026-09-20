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

## Ground truth

`AGENTS.md` says a status line is a wake event rather than current-state truth, and names what owns the truth instead.
Every report in this path is the same shape.
A reviewer verifies against the commits and the CI run, never against the pull request body and never against a firstmate ruling: a ruling is a claim like any other, and a review that finds one wrong against the artifact is reporting a defect rather than defying you - rule on it as a finding.
Where a task carries a design record, that record owns intent, so the pull request body, the brief, a steer, and a ruling are all subordinate to it - and a disagreement between one of them and the record is a defect in the other thing, not in the record.

## The path, end to end

1. **The worker implements and pushes.**
   It works on its own branch in its own worktree and opens the pull request itself, exactly as the `direct-PR` definition of done in `bin/fm-dod-lib.sh` states.
   No pipeline, no validation run, no gate response flow.
2. **The pull request opens as soon as there is something to review**, not after everything is green.
   The worker's `done: PR <url>` line is the signal; record it with `bin/fm-pr-check.sh <id> <PR url>` as section 7 requires.
3. **A reviewer reviews it on the pull request.**
   Dispatch the first review on the worker's `done:` line, not on the pull request merely existing: a pull request opened before the work is finished is there to be watched and to arm the merge poll, and a reviewer dispatched against it reviews the first commit of a change still being written.
   Do not wait for the checks: a reviewer reading the diff and a CI run watching the same commit are independent, and serializing them buys nothing.
4. **Firstmate reads the findings, rules, and posts the ruling on the pull request.**
5. **Fixes land as commits on the same pull request**, by the same worker, one finding per commit.
6. **A reviewer reviews again**, and the path from step 4 repeats until a review approves.
7. **The merge gate is: checks green, every finding ruled, and a reviewer's approval of the exact commit that would merge.**
   Merge authority itself is unchanged and stays with section 7 - `yolo` on means firstmate merges through `bin/fm-pr-merge.sh`, `yolo` off means the captain's word.

Red checks are the worker's to fix, not the reviewer's and not a finding class of their own.
The reviewer reports a red check as a finding so it is visible with everything else; firstmate steers the worker to fix it.
Nothing merges red - section 7 owns that rule and the single named waiver.

## Rounds, and why they are not a pipeline

A round is not a stage and not a phase: it is what happens when a review does not approve and a fix lands.
A round is also what happens when the review at the head stops standing - withdrawn, or never submitted - because the pull request is then unapproved with no fix landed and no commit moved.
Either way the next reviewer reads a range and posts a verdict, and that is the whole mechanism.
There is no round record, no per-round gate, and no transition table, because a path that needs those to describe it is the pipeline this one exists to replace.
Firstmate knows which round it is because it dispatched them and the pull request shows them, not because anything keeps a count.

The only two numbers in this path are the commit an approval binds to, and five.
Five is not a gate.
A pull request still unapproved in its fifth round is no longer a review converging: it is evidence that something about the change or the brief is wrong, so it stops there and goes to the captain rather than to a sixth reviewer.

If a future change to this path needs a third number to describe it, that change is the one to take to the captain rather than to build.

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

## Dispatch a re-review

A re-review is the same call with a new task id, because the previous reviewer was torn down when it reported.
What changes is the `--spec`, and four things belong in it:

- **The range.** Name the last reviewed commit; a re-review reads only what is new since that head, never the pull request from the beginning.
  A round that began because a review stopped standing has nothing new since that head, so it reads the same range the last one did rather than an empty one - the rulings on that ground still stand.
- **What is closed.** Ground already ruled on is not reopened, and a finding firstmate declined stays declined - re-raising it is not a new finding.
- **The numbering.** New findings continue the earlier sequence rather than restarting at `R1`, so no two findings on one pull request share an id and no ruling is ambiguous about which one it answered.
- **What the fixes were.** The finding ids that were fixed and the commits that fixed them, so the reviewer checks each fix against the finding it answers.

The `--ask` does not change: the captain's intent behind the pull request did not move because a fix landed.
None of this is inferable from the pull request, so a re-review dispatched without it reads the whole diff again and re-raises what you already declined.

## Read the findings

Read them off the pull request, not out of the reviewer's pane:

```
gh-axi pr view <number> -R <owner>/<repo> --reviews
```

Name the repository with `-R` on every `gh-axi` call against a task's pull request, here and when you post the ruling below.
A project clone commonly has an `upstream` fork parent beside `origin`, and gh-axi may resolve that one: a bare read then returns a different repository's pull request of the same number, with no error and plausible output ([`docs/verification/pr-review.md`](../../../docs/verification/pr-review.md) records the observed case).
Take the owner and repository from the recorded `pr=` URL, which is the only authority on where that pull request is.

That is the point of the path - the findings are on the pull request where the captain can read them too.
The reviewer's local record at `data/<review-task-id>/report.md` is a pointer to the posted review, useful for teardown and for finding the review again; it is never the authoritative copy.

A reviewer that reported `done:` without a review actually posted has failed its contract.
Verify the review is on the pull request before relaying anything to the captain, and steer the reviewer to post it rather than relaying findings that exist only in a session.

## The verdict that ends the rounds

A review ends with an explicit verdict that either approves the pull request at the exact commit it reviewed, in those words, or does not approve it.
Nothing else is that statement: blocking, non-blocking, clean, a severity table, or a summary of what is left all describe the findings rather than approve a commit.
Require the verdict in the `--spec` and read it back off the posted review, because a review that names no commit has approved nothing whatever else it says.

An approval binds to that commit and to no later one.
A fix pushed after it leaves the pull request unapproved again, which is what makes the next pass a round rather than a formality.

The worker who wrote the change never approves it, on any round.
Nothing on the forge will show you that it did not: one fleet account opens and reviews these pull requests, so the author field names that account whoever did the work - which is also why the verdict is text in the review body rather than GitHub's own approve button, since GitHub refuses a self-approval outright.
The rule holds because you dispatched a reviewer that is not the worker, which makes it your obligation rather than a fact a reader can check off the pull request.

## Rule on each finding

Every finding gets a ruling.
A finding left silent is the black box coming back.

Load `ask-user-authority` and apply its criteria unchanged.
Finding authority does not depend on who produced the finding, so a reviewer finding and a pipeline ask-user finding are the same question: firstmate decides what is unambiguous toward the accepted intent and escalates what is genuinely ambiguous, expanding, or destructive.
A finding the reviewer marked `widens scope: yes` is the reviewer telling you it believes this one is yours or the captain's; that marking is evidence for the judgment, not the judgment.

The rulings available to you are:

- **Fix** - the finding is a defect within the accepted intent. Steer the worker.
- **Won't fix** - the finding is correct but out of scope, or a preference you are declining. Say why; a declined finding with no reason is not a ruling.
- **Not a defect** - the reviewer is wrong. Say what it missed, with the evidence.
- **Captain's call** - escalate under `ask-user-authority`, then post the captain's answer as the ruling once it lands.

## From the third round, challenge the reviewer

Through the first two rounds firstmate relays: it reads the findings, rules on them, and steers the fixes.
From the third round it also challenges - it puts back to the reviewer the findings it believes are wrong, the ones the reviewer keeps missing, and the question of why a change that has been round the loop twice is still not approved.

Post the challenge on the pull request in full, never only in a steer or a pane.
Firstmate ruled on the earlier findings, so a firstmate challenge is firstmate marking its own homework, and publication rather than a different author is what keeps it honest: the captain reads the challenge and the reviewer's answer side by side instead of a summary written by the interested party.

## Post the ruling on the pull request

Post it to the same pull request, naming the finding by its `R<n>` id so a reader can line the two up:

```
gh-axi pr comment <number> -R <owner>/<repo> --body-file <file>
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
