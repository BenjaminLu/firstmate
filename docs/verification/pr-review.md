# Verification: posting a review on a pull request

Audience: maintainer verification.

Active empirical facts behind the reviewer contract in `bin/fm-brief.sh` (`--review`) and the firstmate procedure in [`.agents/skills/pr-review/SKILL.md`](../../.agents/skills/pr-review/SKILL.md).
Both state vendor behavior that a release note could change, so this record owns how it was established.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-09-19 |
| Client | `gh-axi 0.1.35` |
| Forge | github.com, repository `BenjaminLu/firstmate`, pull request 29 |
| Account | one account, the same one that opened the pull request |

## A self-opened pull request refuses approve and request-changes

The fleet posts from one GitHub account, so the account reviewing a task's pull request is the account that opened it.
GitHub refuses a review verdict in that case:

```
$ gh-axi pr review 29 -R BenjaminLu/firstmate --approve --body-file <file>
error: "failed to create review: GraphQL: Review Can not approve your own pull request (addPullRequestReview)"
code: UNKNOWN
```

`--request-changes` is refused by the same server-side rule and was not additionally exercised, because a successful one would have left the pull request blocked.
That is the single unproven half of this section.

## A comment review is accepted and reads back

```
$ gh-axi pr review 29 -R BenjaminLu/firstmate --comment --body-file <file>
review:
  number: 29
  action: commented
```

```
$ gh-axi pr view 29 -R BenjaminLu/firstmate --reviews
  reviews[1]:
    - author: BenjaminLu
      state: commented
      submitted: "2026-09-19T14:45:04Z"
      body: "..."
      inline_comments: []
```

The generated review brief therefore instructs `--comment` and carries the verdict as a line of body text, and instructs the reviewer to read the review back before reporting done.
`inline_comments` is empty because `gh-axi pr review` submits a body only; it exposes no line-anchored comment input, which is why findings are numbered `R<n>` in the body and a ruling names that id rather than threading under a line.

## gh-axi reads a different repository without -R, and does not say so

This clone carries an `upstream` remote (`kunchenguid/firstmate`) beside `origin` (`BenjaminLu/firstmate`), which is the ordinary shape of a fork clone.
gh-axi resolved `upstream`, and a read of pull request 29 returned that repository's pull request 29 rather than the one under review:

```
$ gh-axi pr view 29
pull_request:
  number: 29
  title: "fix: persist watcher wakes across supervision gaps"
  state: merged
  author: kunchenguid
```

The pull request actually under review is `BenjaminLu/firstmate#29`, open, titled `feat(bin): review a pull request with a dedicated reviewer crewmate`.
`gh-axi pr checks 29` likewise returned the other repository's checks, reporting `4 passed, 0 failed, 4 total` for a pull request that is not the one asked about.
Neither call warned, errored, or named the repository it had chosen.

A write is where the mismatch finally surfaces, and only as a confusing message:

```
$ gh-axi pr create --base main --head fm/reviewer-agent-on-pr ...
error: "pull request create failed: GraphQL: Head sha can't be blank, Base sha can't be blank,
No commits between main and fm/reviewer-agent-on-pr, Head ref must be a branch (createPullRequest)"
```

The identical call with `-R BenjaminLu/firstmate` succeeded.

This is the reason every `gh-axi` command the review brief generates, and every one the `pr-review` skill prints, carries `-R <owner>/<repo>` taken from the reviewed pull request's own URL.
Without it a reviewer can read a stranger's pull request of the same number, review it, and post findings against the wrong repository, with plausible-looking output at every step and no error anywhere.

## Checking a pull request head out

```
$ gh-axi pr checkout 29 -R BenjaminLu/firstmate
checkout:
  number: 29
  branch: branch 'fm/reviewer-agent-on-pr' set up to track 'origin/fm/reviewer-agent-on-pr'.
  status: ok
```

Run in a repository whose only remote was `origin`, it fetched the head and switched to it.
The review brief uses this rather than a hand-written `git fetch origin refs/pull/<n>/head`, which names a remote that need not be the one hosting the pull request.
