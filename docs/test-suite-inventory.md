# Test-suite inventory: what pins evolving text, and what CI actually costs

Status: inventory only.
Nothing is deleted on the strength of this document.

## The rule this inventory applies

The agent-facing surface of this system evolves through conversation with the captain.
The wording of a generated brief, the phrasing of a skill, the sentence a refusal uses, and which section a contract line sits in are all supposed to change every time the captain and firstmate work something out.
A test that pins today's phrasing fights tomorrow's improvement.

So each candidate was asked one question: does this test pin something that is meant to evolve through conversation?

- Yes - it goes, because it has no value by construction rather than a poor cost-benefit ratio.
- No - a script that refuses, mutates, or produces something with a consequence - it stays.

Two corollaries settle the hard cases.
A refusal message is the kind of thing that gets reworded the next time a diagnostic reads badly, so the sentence goes and the assertion that it refused stays.
A generated file's structure that a script later parses stays, because a parser depends on it.

`.agents/skills/firstmate-coding-guidelines/SKILL.md`, section "What a test may assert", is the standing owner of that rule.
This document is the measurement behind it.

## Headline: the class is real, and it is not where CI's time is

Measured across all 228 test scripts, counting an expectation as prose only when it is a natural-language sentence - not a markdown heading, a `key: value` field, a keyed status line, a token list or a command string:

| | count | share |
| --- | ---: | ---: |
| `assert_contains` / `assert_grep` expectations in the suite | 6,164 | |
| of those, expectations that are natural-language sentences | 997 | 16.2% |
| lines inside test functions where every assertion is a sentence | 4,727 | 2.4% of 195,315 |

Counting the sentence assertions embedded in otherwise-behavioural tests, the deletable total is roughly **6,000 to 8,000 lines of 195,315 - about 3 to 4 percent of the suite, not most of it.**

An earlier count of this document said 1,451 and 23.5 percent.
That used a looser test that called any four lowercase words a sentence, and it mislabelled 454 machine-readable lines - `ready pf-restart req-restart discord`, `done [key=child-pr-task-x1]: ...`, tab-separated rows, command strings - as prose.
The number above is the one that survived checking every needle by hand.
Telling the two apart comes down to function words: a sentence has them, a machine-readable line does not.

The suite is 1.8x the size of `bin/` because of case count, not because of this class: 4,114 cases over 228 files, the great majority asserting a refusal, a mutation, or a produced record.

### The clock is somewhere else entirely

These are the recorded CI durations `bin/fm-test-run.sh` packs its shards from, not estimates:

| file | CI seconds | prose assertions |
| --- | ---: | ---: |
| `fm-brief.test.sh` - the archetype named in the brief | **1.6** | 124 of 198 |
| `fm-supervision-instructions.test.sh` - pins nothing but rendered prose | **0.3** | 27 of 88 |
| `fm-ask-user-authority.test.sh` - pure brief wording | **0.1** | 6 of 7 |

**The three files whose whole subject is agent-facing prose cost 2.0 seconds of CI between them.**

Meanwhile the slowest lane, portable serial, is 6,738 recorded seconds across nine duration-balanced shards - about 749s modeled per shard, up to 1,271s measured on a slow runner.
Its two largest members are:

| file | CI seconds | prose assertions |
| --- | ---: | ---: |
| `fm-watch-triage-waits.test.sh` | 433 | 0 of 0 |
| `fm-watch-triage.test.sh` | 386 | 0 of 0 |

**819 seconds - 12 percent of the whole serial lane - in two files with not one prose assertion between them.**
They launch a real `bin/fm-watch.sh` per case and wait for its poll cycles, and they are wedge detection, which puts them squarely on the KEEP side of the rule.

Weighting every file's recorded CI seconds by its prose share gives an upper bound of well under a tenth of the suite's seconds - and even that is an overestimate, because a prose assertion is a `grep` over output that has already been produced.
The expensive part is producing it: spawning watchers, real git operations, real sleeps.
Deleting the assertion leaves the setup behind.

**Cutting every text-pinning test in this repository is right on the merits and will not, on its own, make CI fast.**
Saying that plainly is the point of this document; a deletion sold as a performance fix would be a hidden gap.

## Where the slowest lane's time actually is

The nine serial shards are duration-balanced, so the lane's floor is set by its heaviest members rather than by its file count.
The top 15 files are 3,077s, 46 percent of the lane.

Declared wait budgets in the heaviest files, summing `sleep` arguments and configured poll bounds, so an upper bound rather than executed time:

| file | declared wait budget (s) |
| --- | ---: |
| `fm-backend-herdr.test.sh` | 4,800 |
| `fm-session-start.test.sh` | 3,902 |
| `fm-afk-launch.test.sh` | 2,492 |
| `fm-watcher-lock.test.sh` | 2,468 |
| `fm-teardown.test.sh` | 2,102 |
| `fm-turnend-guard.test.sh` | 1,740 |

These are timing contracts against real processes.

### What the waiting turned out to be

The expected answer was that these tests sleep for real intervals to observe a watcher's timing, and that the cure was to inject the clock or shorten the interval under test.
Measured, that is not what they were doing.
The two watch-triage files already poll at 0.1s, and the cost is not the poll's sleep but the watcher's own work per cycle.

Driving `bin/fm-watch.sh` against an empty home and counting its published cycle counter:

| `FM_POLL` | seconds per completed cycle |
| --- | ---: |
| 0.5 | 0.86 |
| 0.1 | 0.50 |
| 0.01 | 0.43 |

Taking the sleep to essentially zero moves a cycle from 0.50s to 0.43s.
**The waiting was 14 percent of it; the other 86 percent was the watcher doing work** - about 30 real subprocess forks per cycle with no fleet to supervise.

One call accounted for most of that.
The watcher runs `fm-inactive-reconcile.sh scan` once per cycle, and that script's own cadence gate returns without doing anything on almost every call - but only after a re-exec, a timeout wrapper and a lock acquisition have been paid for.
Taking the same decision one process earlier, in the script that owns the gate:

| `FM_POLL` | before | cadence decided earlier | call removed entirely (ceiling) |
| --- | ---: | ---: | ---: |
| 0.1 | 0.50s | **0.29s** | 0.26s |
| 0.01 | 0.43s | **0.19s** | 0.16s |

That single change captures about 88 percent of the available headroom, and it speeds a running fleet's supervision by the same amount, not only CI.
It is committed here with a regression that pins both directions of the gate.

No assertion was removed to get it, and no wait was shortened: the tests are unchanged, and the thing they were waiting on got faster.

### The other 86 percent, counted rather than guessed at

That one call was the largest single item, not the whole of it.
Tracing a real watcher against an idle home with the fix applied, and counting only external binaries, a poll cycle still forks **43 processes with no fleet to supervise**.

Where they go:

| what the fork touches | forks per cycle |
| --- | ---: |
| `.watcher-down.lock` and its owner directory | 13.8 |
| `.wake-queue.lock` and its owner directory | 12.6 |
| path, date and environment helpers touching no state (`pwd`, `dirname`, `basename`, `date`) | 10.4 |
| interval markers (`.last-heartbeat`, `.last-check`, `.heartbeat-streak`, `home-summary.json`) | 3.9 |
| `.watch.lock` and its owner directory | 1.7 |

By command: `cat` 8.8, `readlink` 6.8, `rm` 4.5, `pwd` 3.9, `date` 3.8, `dirname` 3.6, `stat` 2.9, `mktemp` 2.3, `basename` 2.3, `rmdir` 2.3.

**About 28 of the 43 are lock machinery.**
An idle home takes and releases `.watcher-down.lock` and `.wake-queue.lock` on every cycle, writing nothing, and each acquire-release pair costs a `mktemp`, a `readlink`, several `cat`s, an `rm` and an `rmdir` through the owner-directory protocol in `bin/fm-lock-lib.sh`.
The next largest group is about 10 calls to `dirname`, `basename`, `pwd` and `date` that Bash can answer with parameter expansion and `printf '%(%s)T'`.

Neither is chased here.
They are recorded so whoever takes them starts from this table rather than from a guess about which one matters.

## The inventory

Verdicts:

- **DELETE-FILE** - the file's whole subject is agent-facing prose.
- **TRIM-HEAVY** - most assertions pin sentences; the behavioural cases stay.
- **TRIM** - some assertions pin sentences; drop the sentence and keep the assertion that it refused, mutated, or produced.
- **KEEP** - no prose pinning found.

`CI s` is the file's recorded duration from the CI timing artifacts that `bin/fm-test-run.sh` packs shards from.
Nine serial files and the unmeasured real-Herdr members carry the lane default instead and are marked `(est)`.
`wholly-prose lines` counts lines inside test functions where every assertion is a natural-language sentence - the lines deletable without touching a behavioural case.

| test file | lines | lane | CI s | prose asserts | verdict | wholly-prose lines |
| --- | ---: | --- | ---: | ---: | --- | ---: |
| `fm-backend-herdr-presentation-e2e.test.sh` | 1448 | herdr-1 | 433.5 | 0/0 (0%) | KEEP | 0 |
| `fm-watch-triage-waits.test.sh` | 1551 | serial-1 | 433.1 | 0/0 (0%) | KEEP | 0 |
| `fm-watch-triage.test.sh` | 3902 | serial-2 | 386.2 | 0/0 (0%) | KEEP | 0 |
| `fm-captain-hold-lifecycle.test.sh` | 5358 | par-2 | 296.5 | 47/329 (14%) | TRIM | 44 |
| `fm-remote-secondmate-lifecycle-e2e.test.sh` | 1313 | serial-3 | 238.5 | 9/60 (15%) | TRIM | 0 |
| `fm-pr-check-security.test.sh` | 3499 | serial-4 | 230.6 | 0/24 (0%) | KEEP | 0 |
| `fm-procevent.test.sh` | 3570 | serial-5 | 227.0 | 17/216 (8%) | TRIM | 0 |
| `fm-backlog-atomicity.test.sh` | 3095 | serial-6 | 205.5 | 39/79 (49%) | TRIM | 766 |
| `fm-session-start.test.sh` | 2797 | serial-7 | 196.5 | 41/240 (17%) | TRIM | 55 |
| `fm-bearings-snapshot.test.sh` | 3409 | serial-8 | 172.5 | 1/9 (11%) | TRIM | 14 |
| `fm-secondmate-harness.test.sh` | 2711 | serial-9 | 168.0 | 2/146 (1%) | TRIM | 0 |
| `fm-lint.test.sh` | 1713 | par-1 | 164.3 | 2/71 (3%) | TRIM | 0 |
| `fm-public-followup.test.sh` | 3221 | serial-9 | 157.9 | 52/154 (34%) | TRIM | 517 |
| `fm-teardown.test.sh` | 3760 | serial-8 | 154.0 | 8/50 (16%) | TRIM | 199 |
| `fm-spawn-dispatch-profile.test.sh` | 1587 | serial-7 | 139.6 | 16/137 (12%) | TRIM | 52 |
| `fm-bootstrap.test.sh` | 1900 | serial-6 | 127.2 | 4/30 (13%) | TRIM | 31 |
| `fm-remote-reply.test.sh` | 802 | serial-5 | 124.9 | 3/66 (5%) | TRIM | 0 |
| `fm-wake-drain-open-decisions-cursor.test.sh` | 420 | serial-4 | 114.5 | 0/8 (0%) | KEEP | 0 |
| `fm-watcher-lock.test.sh` | 1195 | serial-3 | 114.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pr-merge.test.sh` | 3222 | par-1 | 111.1 | 63/202 (31%) | TRIM | 158 |
| `fm-bearings-board.test.sh` | 2522 | serial-9 | 102.0 | 2/35 (6%) | TRIM | 0 |
| `fm-secondmate-reconcile.test.sh` | 1009 | serial-8 | 98.5 | 1/22 (5%) | TRIM | 0 |
| `fm-test-run.test.sh` | 1880 | par-1 | 92.9 | 1/48 (2%) | TRIM | 0 |
| `fm-remote-secondmate-parent-binding.test.sh` | 327 | serial-6 | 92.7 | 4/4 (100%) | TRIM | 0 |
| `fm-cursor-primary.test.sh` | 709 | serial-7 | 88.8 | 0/0 (0%) | KEEP | 0 |
| `fm-wake-queue.test.sh` | 2030 | serial-4 | 85.9 | 0/0 (0%) | KEEP | 0 |
| `fm-spawn-pool-base-freshen.test.sh` | 1015 | serial-5 | 79.5 | 31/59 (53%) | TRIM-HEAVY | 101 |
| `fm-remote-backlog-handoff.test.sh` | 695 | serial-3 | 77.4 | 0/23 (0%) | KEEP | 0 |
| `fm-watch-arm.test.sh` | 859 | serial-2 | 71.1 | 0/0 (0%) | KEEP | 0 |
| `fm-sessionstart-nudge.test.sh` | 1075 | serial-7 | 70.4 | 1/23 (4%) | TRIM | 0 |
| `fm-contributions.test.sh` | 1163 | serial-8 | 68.7 | 0/0 (0%) | KEEP | 0 |
| `fm-secondmate-safety.test.sh` | 3034 | serial-6 | 67.1 | 1/10 (10%) | TRIM | 43 |
| `fm-pi-branch-extension.test.sh` | 4976 | serial-9 | 66.8 | 0/0 (0%) | KEEP | 0 |
| `fm-control-relaunch.test.sh` | 1740 | serial-3 | 64.9 | 31/70 (44%) | TRIM | 296 |
| `fm-remote-transport-lanes.test.sh` | 434 | serial-4 | 63.7 | 0/5 (0%) | KEEP | 0 |
| `fm-remote-secondmate-trace-context.test.sh` | 311 | serial-5 | 62.0 | 0/1 (0%) | KEEP | 0 |
| `fm-startup-network.test.sh` | 783 | serial-1 | 61.8 | 1/49 (2%) | TRIM | 0 |
| `fm-claude-stop-autoarm.test.sh` | 1278 | serial-2 | 60.8 | 3/17 (18%) | TRIM | 39 |
| `fm-afk-inject-herdr-e2e.test.sh` | 537 | herdr-2 | 60.5 | 0/0 (0%) | KEEP | 0 |
| `fm-remote-job.test.sh` | 769 | serial-6 | 59.3 | 1/10 (10%) | TRIM | 0 |
| `fm-watch-recovery-loop.test.sh` | 227 | serial-5 | 58.9 | 0/0 (0%) | KEEP | 0 |
| `fm-secondmate-sync.test.sh` | 1379 | serial-8 | 57.4 | 4/44 (9%) | TRIM | 39 |
| `fm-procevent-when.test.sh` | 650 | serial-4 | 55.7 | 3/43 (7%) | TRIM | 0 |
| `fm-calm-pi-extension.test.sh` | 4337 | serial-9 | 54.1 | 1/96 (1%) | TRIM | 0 |
| `fm-inactive-reconcile.test.sh` | 931 | serial-3 | 54.0 | 0/1 (0%) | KEEP | 0 |
| `fm-dispatch.test.sh` | 682 | serial-1 | 53.9 | 19/86 (22%) | TRIM | 0 |
| `fm-pi-watch-extension.test.sh` | 4025 | serial-7 | 52.9 | 0/0 (0%) | KEEP | 0 |
| `fm-backlog-handoff.test.sh` | 1373 | serial-2 | 52.2 | 10/73 (14%) | TRIM | 52 |
| `fm-kimi-harness.test.sh` | 1022 | serial-7 | 52.2 | 16/42 (38%) | TRIM | 84 |
| `fm-trace-context-spawn.test.sh` | 611 | serial-9 | 50.4 | 1/11 (9%) | TRIM | 17 |
| `fm-secondmate-restart.test.sh` | 856 | serial-1 | 49.7 | 9/60 (15%) | TRIM | 0 |
| `fm-omp-harness.test.sh` | 588 | serial-3 | 48.6 | 2/16 (12%) | TRIM | 31 |
| `fm-agy-harness.test.sh` | 917 | serial-4 | 48.1 | 8/32 (25%) | TRIM | 83 |
| `fm-bearings-board-render.test.sh` | 2820 | serial-8 | 48.0 | 1/52 (2%) | TRIM | 0 |
| `fm-wake-drain-outcome-backstop.test.sh` | 526 | serial-6 | 45.0 | 0/0 (0%) | KEEP | 0 |
| `fm-vendor-auth-probe.test.sh` | 396 | serial-5 | 43.3 | 1/5 (20%) | TRIM | 0 |
| `fm-backend-herdr-launcher-workspace-e2e.test.sh` | 449 | herdr-2 | 42.3 | 0/0 (0%) | KEEP | 0 |
| `fm-muse-harness.test.sh` | 969 | serial-2 | 41.9 | 2/30 (7%) | TRIM | 14 |
| `fm-afk-launch.test.sh` | 1233 | herdr-2 | 40.6 | 0/0 (0%) | KEEP | 0 |
| `fm-control.test.sh` | 1000 | serial-5 | 40.2 | 12/34 (35%) | TRIM | 116 |
| `fm-send-inbox.test.sh` | 427 | serial-6 | 39.4 | 0/15 (0%) | KEEP | 0 |
| `fm-fleet-sync.test.sh` | 722 | serial-3 | 38.8 | 5/59 (8%) | TRIM | 0 |
| `fm-turnend-guard.test.sh` | 2279 | serial-4 | 37.2 | 6/69 (9%) | UNCLASSIFIED | 0 |
| `fm-home-summary-refresh.test.sh` | 1079 | serial-1 | 37.1 | 0/0 (0%) | KEEP | 0 |
| `fm-afk-inject-e2e.test.sh` | 429 | serial-8 | 35.7 | 0/0 (0%) | KEEP | 0 |
| `fm-teardown-endpoint-safety.test.sh` | 1395 | serial-9 | 33.9 | 11/34 (32%) | TRIM | 0 |
| `fm-pending-reply.test.sh` | 1616 | serial-7 | 32.0 | 0/5 (0%) | KEEP | 0 |
| `fm-x-mode.test.sh` | 3112 | par-2 | 31.9 | 9/147 (6%) | TRIM | 123 |
| `fm-task-inbox.test.sh` | 715 | serial-2 | 30.9 | 0/5 (0%) | KEEP | 0 |
| `fm-arm-pretool-check.test.sh` | 475 | par-2 | 30.9 | 0/0 (0%) | KEEP | 0 |
| `fm-send-resolve-key.test.sh` | 745 | serial-7 | 30.6 | 1/17 (6%) | TRIM | 28 |
| `fm-cursor-harness.test.sh` | 431 | serial-9 | 30.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-remote-delivery.test.sh` | 806 | serial-8 | 29.4 | 9/24 (38%) | TRIM | 97 |
| `fm-busy-adapter-wiring.test.sh` | 439 | serial-1 | 29.4 | 0/2 (0%) | KEEP | 0 |
| `fm-backlog-read-bound.test.sh` | 431 | serial-4 | 28.9 | 0/0 (0%) | KEEP | 0 |
| `fm-voice-relay.test.sh` | 4742 | serial-5 | 28.7 | 6/120 (5%) | TRIM | 0 |
| `fm-daemon.test.sh` | 2910 | serial-6 | 28.1 | 3/8 (38%) | TRIM | 0 |
| `fm-board-live.test.sh` | 915 | serial-3 | 27.0 (est) | 0/32 (0%) | KEEP | 0 |
| `fm-capture-settle.test.sh` | 350 | serial-2 | 27.0 (est) | 3/19 (16%) | TRIM | 0 |
| `fm-clock-lib.test.sh` | 220 | serial-7 | 27.0 (est) | 0/0 (0%) | KEEP | 0 |
| `fm-gate-calls.test.sh` | 796 | serial-9 | 27.0 (est) | 0/18 (0%) | KEEP | 0 |
| `fm-obligation-check.test.sh` | 1914 | serial-3 | 27.0 (est) | 31/106 (29%) | TRIM | 98 |
| `fm-obligation-forge-live-e2e.test.sh` | 55 | serial-8 | 27.0 (est) | 2/2 (100%) | TRIM | 20 |
| `fm-send-commit-ish.test.sh` | 416 | serial-6 | 27.0 (est) | 1/12 (8%) | TRIM | 12 |
| `fm-upstream-pretool-check.test.sh` | 367 | serial-5 | 27.0 (est) | 0/10 (0%) | KEEP | 0 |
| `fm-wake-annotation-contradiction.test.sh` | 330 | serial-4 | 27.0 (est) | 12/22 (55%) | TRIM-HEAVY | 64 |
| `fm-secondmate-lifecycle-e2e.test.sh` | 331 | serial-1 | 24.7 | 1/35 (3%) | TRIM | 0 |
| `fm-packet.test.sh` | 1924 | serial-2 | 23.8 | 20/114 (18%) | TRIM | 127 |
| `fm-backend-orca.test.sh` | 1401 | serial-1 | 23.7 | 8/100 (8%) | TRIM | 41 |
| `fm-classify-corr-token.test.sh` | 555 | serial-7 | 22.9 | 0/0 (0%) | KEEP | 0 |
| `fm-backend.test.sh` | 1198 | serial-9 | 22.5 | 2/36 (6%) | TRIM | 53 |
| `fm-backend-herdr.test.sh` | 5414 | par-2 | 22.1 | 15/172 (9%) | TRIM | 144 |
| `fm-task-delivery.test.sh` | 898 | serial-3 | 21.5 | 48/107 (45%) | TRIM | 31 |
| `fm-afk-return.test.sh` | 807 | serial-8 | 20.6 | 16/71 (23%) | TRIM | 29 |
| `fm-secondmate-liveness.test.sh` | 560 | serial-6 | 19.7 | 0/20 (0%) | KEEP | 0 |
| `fm-backend-herdr-workspace-per-home-e2e.test.sh` | 266 | herdr-2 | 19.1 | 0/0 (0%) | KEEP | 0 |
| `fm-wake-daemon-lifecycle-e2e.test.sh` | 172 | serial-5 | 18.0 | 0/0 (0%) | KEEP | 0 |
| `fm-fleet-snapshot-view.test.sh` | 1172 | serial-4 | 17.7 | 2/13 (15%) | UNCLASSIFIED | 18 |
| `fm-wake-drain-unread-status.test.sh` | 390 | serial-2 | 17.5 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-branch-responsiveness-live-e2e.test.sh` | 239 | serial-4 | 17.2 | 0/0 (0%) | KEEP | 0 |
| `fm-cd-pretool-check.test.sh` | 401 | par-1 | 17.0 | 0/2 (0%) | KEEP | 0 |
| `fm-afk-contract.test.sh` | 705 | serial-5 | 16.6 | 27/50 (54%) | TRIM-HEAVY | 199 |
| `fm-guard-stale-banner.test.sh` | 926 | serial-6 | 15.6 | 15/26 (58%) | TRIM-HEAVY | 261 |
| `fm-rovo-harness.test.sh` | 474 | serial-2 | 15.1 | 3/28 (11%) | TRIM | 16 |
| `fm-remote-doctor.test.sh` | 890 | serial-3 | 14.8 | 13/91 (14%) | TRIM | 0 |
| `fm-tool-update-check.test.sh` | 1045 | serial-8 | 13.9 | 6/54 (11%) | TRIM | 31 |
| `fm-gate-refuse.test.sh` | 358 | serial-9 | 13.2 | 0/20 (0%) | KEEP | 0 |
| `fm-update.test.sh` | 577 | serial-7 | 12.3 | 4/54 (7%) | TRIM | 0 |
| `fm-crew-state.test.sh` | 3660 | par-2 | 11.6 | 16/406 (4%) | TRIM | 11 |
| `fm-on.test.sh` | 521 | serial-1 | 11.3 | 5/36 (14%) | TRIM | 0 |
| `fm-claude-trust.test.sh` | 1443 | serial-1 | 11.0 | 11/70 (16%) | TRIM | 64 |
| `fm-control-herdr-smoke.test.sh` | 328 | herdr-2 | 10.9 | 0/0 (0%) | KEEP | 0 |
| `fm-mail.test.sh` | 2660 | serial-7 | 10.4 | 6/158 (4%) | TRIM | 0 |
| `fm-herdr-lab.test.sh` | 518 | par-2 | 9.8 | 2/5 (40%) | TRIM | 21 |
| `fm-bootstrap-network-parallel.test.sh` | 330 | serial-8 | 9.8 | 0/7 (0%) | KEEP | 0 |
| `fm-branch-supervision.test.sh` | 860 | serial-9 | 9.6 | 25/49 (51%) | TRIM-HEAVY | 163 |
| `fm-backend-zellij.test.sh` | 1361 | serial-5 | 9.6 | 2/48 (4%) | TRIM | 31 |
| `fm-extension-binding.test.sh` | 2216 | serial-4 | 9.2 | 1/45 (2%) | TRIM | 0 |
| `fm-backend-autodetect-smoke.test.sh` | 194 | herdr-2 | 8.9 | 0/0 (0%) | KEEP | 0 |
| `fm-spawn-worktree-settle.test.sh` | 230 | serial-2 | 8.9 | 1/9 (11%) | TRIM | 0 |
| `fm-pi-primary-types.test.sh` | 73 | par-1 | 8.6 | 0/0 (0%) | KEEP | 0 |
| `fm-tangle-guard.test.sh` | 295 | serial-3 | 7.8 | 9/30 (30%) | TRIM | 0 |
| `fm-startup-memory-budget.test.sh` | 335 | serial-6 | 7.7 | 1/17 (6%) | TRIM | 0 |
| `fm-mail-check.test.sh` | 474 | serial-3 | 7.5 | 1/38 (3%) | TRIM | 17 |
| `fm-wake-drain-open-decisions.test.sh` | 227 | serial-6 | 7.3 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-session-cleanup.test.sh` | 330 | serial-2 | 7.2 | 0/0 (0%) | KEEP | 0 |
| `fm-grok-harness.test.sh` | 118 | par-1 | 6.6 | 0/4 (0%) | KEEP | 0 |
| `fm-backend-herdr-prune-safety-e2e.test.sh` | 181 | herdr-2 | 6.4 | 0/0 (0%) | KEEP | 0 |
| `fm-watch-checkpoint.test.sh` | 88 | serial-8 | 6.1 | 0/7 (0%) | KEEP | 0 |
| `fm-shared-captain-inheritance.test.sh` | 405 | serial-9 | 5.9 | 3/19 (16%) | TRIM | 28 |
| `fm-send-secondmate-marker.test.sh` | 279 | serial-7 | 5.6 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-windows-shell-invocation.test.sh` | 120 | serial-1 | 5.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-popup-settle.test.sh` | 168 | par-2 | 4.9 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-lib.test.sh` | 839 | par-1 | 4.8 | 0/0 (0%) | KEEP | 0 |
| `fm-dispatch-resolve.test.sh` | 639 | serial-5 | 4.7 | 2/116 (2%) | TRIM | 0 |
| `fm-backend-herdr-smoke.test.sh` | 368 | herdr-2 | 4.6 | 0/0 (0%) | KEEP | 0 |
| `fm-busy-state.test.sh` | 487 | serial-4 | 4.5 | 0/0 (0%) | KEEP | 0 |
| `fm-send-strict.test.sh` | 242 | par-2 | 3.9 | 0/20 (0%) | KEEP | 0 |
| `fm-harness-precedence.test.sh` | 762 | serial-4 | 3.8 | 0/4 (0%) | KEEP | 0 |
| `fm-tasks-axi.test.sh` | 231 | serial-5 | 3.8 | 3/15 (20%) | TRIM | 14 |
| `fm-send-agy-confirm.test.sh` | 166 | serial-1 | 3.7 | 0/0 (0%) | KEEP | 0 |
| `fm-ci-workflow.test.sh` | 234 | serial-7 | 3.6 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-cmux.test.sh` | 1167 | serial-9 | 3.6 | 0/41 (0%) | KEEP | 0 |
| `fm-classify-decision-key.test.sh` | 487 | serial-6 | 3.5 | 0/0 (0%) | KEEP | 0 |
| `fm-remote-herdr-guard.test.sh` | 344 | serial-8 | 3.1 | 10/15 (67%) | TRIM-HEAVY | 0 |
| `fm-stow-cascade.test.sh` | 371 | serial-3 | 3.1 | 1/8 (12%) | TRIM | 49 |
| `fm-remote-job-orphan-reap.test.sh` | 230 | serial-2 | 3.0 | 0/5 (0%) | KEEP | 0 |
| `fm-turnend-foreign-owner-arm-fix.test.sh` | 7 | serial-4 | 2.9 | 0/0 (0%) | KEEP | 0 |
| `fm-test-isolation-proof.test.sh` | 298 | serial-5 | 2.8 | 0/0 (0%) | KEEP | 0 |
| `fm-session-lock-ancestry.test.sh` | 415 | serial-1 | 2.8 | 0/0 (0%) | KEEP | 0 |
| `fm-tmux-agent-liveness.test.sh` | 385 | serial-8 | 2.8 | 0/0 (0%) | KEEP | 0 |
| `fm-review-diff.test.sh` | 177 | par-1 | 2.7 | 0/15 (0%) | KEEP | 0 |
| `fm-tmux-submit-busy.test.sh` | 356 | par-1 | 2.5 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-focus-flash-e2e.test.sh` | 410 | herdr-2 | 2.4 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-attached-viewer-live-e2e.test.sh` | 260 | herdr-2 | 2.3 | 3/3 (100%) | TRIM | 0 |
| `fm-spawn-batch.test.sh` | 151 | par-2 | 2.3 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-session-cleanup-e2e.test.sh` | 147 | herdr-2 | 2.2 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-ghost.test.sh` | 717 | par-1 | 2.1 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-respawn-idem-e2e.test.sh` | 183 | herdr-2 | 2.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-settle.test.sh` | 148 | par-2 | 2.1 | 0/0 (0%) | KEEP | 0 |
| `fm-procevent-quota.test.sh` | 226 | serial-3 | 2.0 | 0/0 (0%) | KEEP | 0 |
| `fm-test-fixtures.test.sh` | 321 | serial-7 | 2.0 | 3/9 (33%) | TRIM | 0 |
| `fm-live-gate.test.sh` | 221 | serial-9 | 1.9 | 0/16 (0%) | KEEP | 0 |
| `fm-backend-herdr-eventwait-smoke.test.sh` | 137 | herdr-2 | 1.7 | 0/0 (0%) | KEEP | 0 |
| `fm-brief.test.sh` | 1319 | par-1 | 1.6 | 107/198 (54%) | TRIM-HEAVY | 71 |
| `fm-quota-choose.test.sh` | 666 | serial-6 | 1.6 | 0/0 (0%) | KEEP | 0 |
| `fm-calm-claude-mod.test.sh` | 426 | serial-2 | 1.5 | 0/5 (0%) | KEEP | 0 |
| `fm-gotmp.test.sh` | 252 | serial-6 | 1.4 | 0/0 (0%) | KEEP | 0 |
| `fm-gemini-harness.test.sh` | 275 | serial-4 | 1.4 | 0/0 (0%) | KEEP | 0 |
| `fm-peek-remote.test.sh` | 111 | serial-7 | 1.0 | 2/4 (50%) | TRIM | 0 |
| `fm-subagent-pretool-check.test.sh` | 292 | serial-9 | 1.0 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-stale-active-tab-e2e.test.sh` | 93 | herdr-2 | 1.0 | 0/0 (0%) | KEEP | 0 |
| `fm-harness-liveness-drift-live-e2e.test.sh` | 239 | serial-3 | 0.9 | 0/0 (0%) | KEEP | 0 |
| `fm-documentation-audiences.test.sh` | 142 | serial-5 | 0.9 | 0/3 (0%) | KEEP | 0 |
| `fm-ensure-agents-md.test.sh` | 436 | par-2 | 0.9 | 7/31 (23%) | TRIM | 0 |
| `fm-nm-test-contract.test.sh` | 27 | serial-2 | 0.9 | 0/0 (0%) | KEEP | 0 |
| `fm-lint-workflows.test.sh` | 563 | serial-1 | 0.9 | 6/29 (21%) | TRIM | 38 |
| `fm-test-fixture-cleanup.test.sh` | 173 | serial-8 | 0.8 | 0/1 (0%) | KEEP | 0 |
| `fm-pr-state.test.sh` | 287 | serial-3 | 0.7 | 4/13 (31%) | UNCLASSIFIED | 29 |
| `fm-supervision-events.test.sh` | 157 | serial-7 | 0.7 | 0/0 (0%) | KEEP | 0 |
| `fm-check-unregister.test.sh` | 199 | serial-9 | 0.5 | 0/8 (0%) | KEEP | 0 |
| `fm-backend-tmux-smoke.test.sh` | 174 | serial-2 | 0.4 | 0/0 (0%) | KEEP | 0 |
| `fm-supervision-instructions.test.sh` | 231 | par-2 | 0.3 | 7/88 (8%) | TRIM | 0 |
| `fm-no-mistakes-required.test.sh` | 73 | serial-5 | 0.3 | 0/4 (0%) | KEEP | 0 |
| `fm-trace-context-lib.test.sh` | 254 | serial-6 | 0.3 | 0/3 (0%) | KEEP | 0 |
| `fm-operational-input.test.sh` | 161 | serial-1 | 0.2 | 0/0 (0%) | KEEP | 0 |
| `fm-pr-reviewers.test.sh` | 117 | serial-4 | 0.2 | 1/5 (20%) | TRIM | 18 |
| `fm-ask-user-authority.test.sh` | 43 | serial-5 | 0.1 | 5/7 (71%) | TRIM-HEAVY | 0 |
| `fm-remote-entrypoint.test.sh` | 60 | serial-2 | 0.1 | 3/3 (100%) | TRIM | 30 |
| `fm-project-origin.test.sh` | 111 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-harness-adapter-references.test.sh` | 31 | serial-9 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-stat-shadowing.test.sh` | 140 | serial-5 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-transition-lib.test.sh` | 55 | par-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-submit-confirm-live-e2e.test.sh` | 123 | serial-6 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pr-state-live-e2e.test.sh` | 40 | serial-2 | 0.1 | 0/1 (0%) | KEEP | 0 |
| `fm-calm-claude-mod-live-e2e.test.sh` | 456 | serial-4 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-codex-continuity-live-e2e.test.sh` | 54 | serial-1 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-grok-continuity-live-e2e.test.sh` | 110 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-grok-stop-live-e2e.test.sh` | 216 | serial-5 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-opencode-primary-live-e2e.test.sh` | 354 | serial-9 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-rovo-signals-live-e2e.test.sh` | 359 | serial-4 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-claude-stop-autoarm-live-e2e.test.sh` | 164 | serial-6 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-codex-idle-live-e2e.test.sh` | 146 | serial-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-branch-live-e2e.test.sh` | 994 | serial-1 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-gitignore-config.test.sh` | 92 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-secondmate-marker-herdr-e2e.test.sh` | 181 | serial-5 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-codex-hook-layer-live-e2e.test.sh` | 98 | serial-9 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-codex-native.test.sh` | 363 | serial-6 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-agent-exit-shell-e2e.test.sh` | 214 | herdr-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-agy-signals-live-e2e.test.sh` | 194 | serial-4 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-muse-signals-live-e2e.test.sh` | 202 | serial-3 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-bearings-board-lavish-live-e2e.test.sh` | 121 | serial-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-cmux-claude-composer-live-e2e.test.sh` | 106 | serial-1 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-version-floor-live-e2e.test.sh` | 143 | serial-7 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-inbox-doorbell-live-e2e.test.sh` | 206 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-matrix-live-e2e.test.sh` | 219 | serial-5 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-cursor-primary-live-e2e.test.sh` | 214 | serial-9 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-pi-stale-registration-live-e2e.test.sh` | 160 | serial-4 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-afk-pi-herdr-return-e2e.test.sh` | 288 | serial-6 | 0.0 | 1/5 (20%) | TRIM | 0 |
| `fm-calm-claude-mod-plugin.test.sh` | 84 | serial-3 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-harness-adapter-instructions-live-e2e.test.sh` | 130 | serial-2 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-omp-primary-live-e2e.test.sh` | 314 | serial-1 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-primary-live-e2e.test.sh` | 346 | serial-7 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-quota-array-dispatch-live-e2e.test.sh` | 525 | serial-8 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-sessionstart-hook-live-e2e.test.sh` | 629 | serial-5 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-sessionstart-instruction-refresh-live-e2e.test.sh` | 227 | serial-9 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-cmux-smoke.test.sh` | 189 | serial-4 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-zellij-smoke.test.sh` | 206 | serial-6 | 0.0 | 0/0 (0%) | KEEP | 0 |

## Cases I did not classify, listed rather than guessed

Three files sit on the line and want a ruling rather than my judgement.

- `fm-fleet-snapshot-view.test.sh`, 1,171 lines, 18s, 11 of 13 assertions prose.
  It pins rendered table rows verbatim, down to the column separators.
  A rendered table is presentation, which evolves, but it is also a fixed structure that `bin/fm-bearings-board.sh` consumes from the same snapshot.
  Left at TRIM; cutting it entirely is equally defensible.
- `fm-pr-state.test.sh`, 286 lines, 1s.
  Half its assertions pin the report's explanatory prose, such as "it does not mean the pull request is ready to merge", and half pin structured lines such as `REQUIRED CHECK: CI Status (FAILURE)`.
  The explanatory half is exactly what gets reworded when the captain says a report read badly; the structured half is parsed.
  Marked TRIM, but the split is worth confirming.
- `fm-turnend-guard.test.sh`, 2,278 lines, 37s, 32 of 69 prose.
  Its `$REQUIRED_REASON` assertions pin the exact instruction text the guard emits to an agent, the most literal instance of text meant to evolve.
  But the guard is a structural backstop, and a reason that no longer names the repair action is a real defect rather than a rewording.
  Marked TRIM-HEAVY; whether that reason string may be asserted at all is a ruling, not a measurement.

## What this deletion would cost

Carrying out every DELETE-FILE and TRIM-HEAVY verdict, plus the wholly-prose test functions inside TRIM files, removes roughly 10,000 lines and these specific guarantees.

- That a generated ship, scout, review, or secondmate brief still contains the ask-user authority rule, the machine-boundary rules, the Herdr lab contract, and the worktree-isolation assertion as sentences.
  Kept: that `bin/fm-brief.sh` refuses an invalid mode, refuses delivery flags where they do not apply, and refuses to scaffold a Herdr task without `--herdr-lab`.
  What a future defect could reach production through: a brief that generates successfully, passes every refusal, and has silently lost a paragraph.
  A worker would then start work in the primary checkout, or answer its own ask-user finding, with nothing failing.
- That the emitted supervision block still carries the harness-specific wait mechanism for each harness.
  Kept: that exactly one block is emitted, and that it is the block for the detected harness.
- That refusal and report diagnostics still name the concrete thing that is missing.
  Kept: that they refuse, and what they refuse.

The first gap is the real one and it is not small.
The brief-content tests are the only thing between a reworded scaffold and a worker launched without its safety contract.
Whatever replaces them should be structural - a check that each generated brief carries its required sections, asserted by section presence rather than by the sentences inside - and that replacement is worth writing in the same pass as the deletion rather than after it.
