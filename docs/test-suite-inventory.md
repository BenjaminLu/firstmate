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

Measured across all 228 test scripts:

| | count | share |
| --- | ---: | ---: |
| `assert_contains` / `assert_grep` expectations in the suite | 6,164 | |
| of those, expectations that are natural-language sentences | 1,451 | 23.5% |
| lines inside test functions where every assertion is a sentence | 7,002 | 3.6% of 195,315 |
| lines in files whose entire subject is agent-facing prose | 1,590 | 0.8% of 195,315 |

Counting the sentence assertions embedded in otherwise-behavioural tests, the deletable total is roughly **10,000 to 12,000 lines of 195,315 - about 5 to 6 percent of the suite, not most of it.**

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

Weighting every file's recorded CI seconds by its prose share gives an upper bound of **1,242 of 8,208 suite-seconds, 15.1 percent** - and that is an overestimate, because a prose assertion is a `grep` over output that has already been produced.
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
Making CI fast means shortening those waits - injectable clocks, event-driven waits in place of polling, shorter configured intervals under test - which is a different task from this one and needs its own ruling.

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
| `fm-backend-herdr-presentation-e2e.test.sh` | 1447 | herdr-1 | 433.5 | 0/0 (0%) | KEEP | 0 |
| `fm-watch-triage-waits.test.sh` | 1550 | serial-1 | 433.1 | 0/0 (0%) | KEEP | 0 |
| `fm-watch-triage.test.sh` | 3901 | serial-2 | 386.2 | 0/0 (0%) | KEEP | 0 |
| `fm-captain-hold-lifecycle.test.sh` | 5357 | par-2 | 296.5 | 61/329 (19%) | TRIM | 0 |
| `fm-remote-secondmate-lifecycle-e2e.test.sh` | 1312 | serial-3 | 238.5 | 16/60 (27%) | TRIM | 0 |
| `fm-pr-check-security.test.sh` | 3498 | serial-4 | 230.6 | 0/24 (0%) | KEEP | 0 |
| `fm-procevent.test.sh` | 3569 | serial-5 | 227.0 | 19/216 (9%) | KEEP | 0 |
| `fm-backlog-atomicity.test.sh` | 3094 | serial-6 | 205.5 | 46/79 (58%) | TRIM-HEAVY | 937 |
| `fm-session-start.test.sh` | 2796 | serial-7 | 196.5 | 82/240 (34%) | TRIM | 0 |
| `fm-bearings-snapshot.test.sh` | 3408 | serial-8 | 172.5 | 1/9 (11%) | KEEP | 0 |
| `fm-secondmate-harness.test.sh` | 2710 | serial-9 | 168.0 | 18/146 (12%) | KEEP | 0 |
| `fm-lint.test.sh` | 1712 | par-1 | 164.3 | 5/71 (7%) | KEEP | 0 |
| `fm-public-followup.test.sh` | 3220 | serial-9 | 157.9 | 62/154 (40%) | TRIM | 536 |
| `fm-teardown.test.sh` | 3759 | serial-8 | 154.0 | 18/50 (36%) | TRIM | 447 |
| `fm-spawn-dispatch-profile.test.sh` | 1586 | serial-7 | 139.6 | 20/137 (15%) | KEEP | 114 |
| `fm-bootstrap.test.sh` | 1899 | serial-6 | 127.2 | 5/30 (17%) | TRIM | 0 |
| `fm-remote-reply.test.sh` | 801 | serial-5 | 124.9 | 7/66 (11%) | KEEP | 0 |
| `fm-wake-drain-open-decisions-cursor.test.sh` | 419 | serial-4 | 114.5 | 0/8 (0%) | KEEP | 0 |
| `fm-watcher-lock.test.sh` | 1194 | serial-3 | 114.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pr-merge.test.sh` | 3221 | par-1 | 111.1 | 77/202 (38%) | TRIM | 222 |
| `fm-bearings-board.test.sh` | 2521 | serial-9 | 102.0 | 2/35 (6%) | KEEP | 0 |
| `fm-secondmate-reconcile.test.sh` | 1008 | serial-8 | 98.5 | 1/22 (5%) | KEEP | 0 |
| `fm-test-run.test.sh` | 1879 | par-1 | 92.9 | 1/48 (2%) | KEEP | 0 |
| `fm-remote-secondmate-parent-binding.test.sh` | 326 | serial-6 | 92.7 | 4/4 (100%) | KEEP | 0 |
| `fm-cursor-primary.test.sh` | 708 | serial-7 | 88.8 | 0/0 (0%) | KEEP | 0 |
| `fm-wake-queue.test.sh` | 2029 | serial-4 | 85.9 | 0/0 (0%) | KEEP | 0 |
| `fm-spawn-pool-base-freshen.test.sh` | 1014 | serial-5 | 79.5 | 31/59 (53%) | TRIM | 0 |
| `fm-remote-backlog-handoff.test.sh` | 694 | serial-3 | 77.4 | 1/23 (4%) | KEEP | 0 |
| `fm-watch-arm.test.sh` | 858 | serial-2 | 71.1 | 0/0 (0%) | KEEP | 0 |
| `fm-sessionstart-nudge.test.sh` | 1074 | serial-7 | 70.4 | 3/23 (13%) | KEEP | 0 |
| `fm-contributions.test.sh` | 1162 | serial-8 | 68.7 | 0/0 (0%) | KEEP | 0 |
| `fm-secondmate-safety.test.sh` | 3033 | serial-6 | 67.1 | 4/10 (40%) | TRIM | 0 |
| `fm-pi-branch-extension.test.sh` | 4975 | serial-9 | 66.8 | 0/0 (0%) | KEEP | 0 |
| `fm-control-relaunch.test.sh` | 1739 | serial-3 | 64.9 | 35/70 (50%) | TRIM | 319 |
| `fm-remote-transport-lanes.test.sh` | 433 | serial-4 | 63.7 | 0/5 (0%) | KEEP | 0 |
| `fm-remote-secondmate-trace-context.test.sh` | 310 | serial-5 | 62.0 | 0/1 (0%) | KEEP | 0 |
| `fm-startup-network.test.sh` | 782 | serial-1 | 61.8 | 8/49 (16%) | TRIM | 0 |
| `fm-claude-stop-autoarm.test.sh` | 1277 | serial-2 | 60.8 | 3/17 (18%) | TRIM | 0 |
| `fm-afk-inject-herdr-e2e.test.sh` | 536 | herdr-2 | 60.5 | 0/0 (0%) | KEEP | 0 |
| `fm-remote-job.test.sh` | 768 | serial-6 | 59.3 | 1/10 (10%) | KEEP | 0 |
| `fm-watch-recovery-loop.test.sh` | 226 | serial-5 | 58.9 | 0/0 (0%) | KEEP | 0 |
| `fm-secondmate-sync.test.sh` | 1378 | serial-8 | 57.4 | 13/44 (30%) | TRIM | 122 |
| `fm-procevent-when.test.sh` | 649 | serial-4 | 55.7 | 3/43 (7%) | KEEP | 0 |
| `fm-calm-pi-extension.test.sh` | 4336 | serial-9 | 54.1 | 3/96 (3%) | KEEP | 0 |
| `fm-inactive-reconcile.test.sh` | 930 | serial-3 | 54.0 | 0/1 (0%) | KEEP | 0 |
| `fm-dispatch.test.sh` | 681 | serial-1 | 53.9 | 27/86 (31%) | TRIM | 0 |
| `fm-pi-watch-extension.test.sh` | 4024 | serial-7 | 52.9 | 0/0 (0%) | KEEP | 0 |
| `fm-backlog-handoff.test.sh` | 1372 | serial-2 | 52.2 | 10/73 (14%) | KEEP | 0 |
| `fm-kimi-harness.test.sh` | 1021 | serial-7 | 52.2 | 20/42 (48%) | TRIM | 145 |
| `fm-trace-context-spawn.test.sh` | 610 | serial-9 | 50.4 | 1/11 (9%) | KEEP | 0 |
| `fm-secondmate-restart.test.sh` | 855 | serial-1 | 49.7 | 15/60 (25%) | TRIM | 0 |
| `fm-omp-harness.test.sh` | 587 | serial-3 | 48.6 | 3/16 (19%) | TRIM | 0 |
| `fm-agy-harness.test.sh` | 916 | serial-4 | 48.1 | 9/32 (28%) | TRIM | 0 |
| `fm-bearings-board-render.test.sh` | 2819 | serial-8 | 48.0 | 1/52 (2%) | KEEP | 0 |
| `fm-wake-drain-outcome-backstop.test.sh` | 525 | serial-6 | 45.0 | 0/0 (0%) | KEEP | 0 |
| `fm-vendor-auth-probe.test.sh` | 395 | serial-5 | 43.3 | 1/5 (20%) | TRIM | 0 |
| `fm-backend-herdr-launcher-workspace-e2e.test.sh` | 448 | herdr-2 | 42.3 | 0/0 (0%) | KEEP | 0 |
| `fm-muse-harness.test.sh` | 968 | serial-2 | 41.9 | 2/30 (7%) | KEEP | 0 |
| `fm-afk-launch.test.sh` | 1232 | herdr-2 | 40.6 | 0/0 (0%) | KEEP | 0 |
| `fm-control.test.sh` | 999 | serial-5 | 40.2 | 12/34 (35%) | TRIM | 116 |
| `fm-send-inbox.test.sh` | 426 | serial-6 | 39.4 | 1/15 (7%) | KEEP | 0 |
| `fm-fleet-sync.test.sh` | 721 | serial-3 | 38.8 | 23/59 (39%) | TRIM | 0 |
| `fm-turnend-guard.test.sh` | 2278 | serial-4 | 37.2 | 32/69 (46%) | TRIM | 278 |
| `fm-home-summary-refresh.test.sh` | 1078 | serial-1 | 37.1 | 0/0 (0%) | KEEP | 0 |
| `fm-afk-inject-e2e.test.sh` | 428 | serial-8 | 35.7 | 0/0 (0%) | KEEP | 0 |
| `fm-teardown-endpoint-safety.test.sh` | 1394 | serial-9 | 33.9 | 11/34 (32%) | TRIM | 0 |
| `fm-pending-reply.test.sh` | 1615 | serial-7 | 32.0 | 0/5 (0%) | KEEP | 0 |
| `fm-x-mode.test.sh` | 3111 | par-2 | 31.9 | 22/147 (15%) | KEEP | 188 |
| `fm-task-inbox.test.sh` | 714 | serial-2 | 30.9 | 0/5 (0%) | KEEP | 0 |
| `fm-arm-pretool-check.test.sh` | 474 | par-2 | 30.9 | 0/0 (0%) | KEEP | 0 |
| `fm-send-resolve-key.test.sh` | 744 | serial-7 | 30.6 | 1/17 (6%) | KEEP | 0 |
| `fm-cursor-harness.test.sh` | 430 | serial-9 | 30.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-remote-delivery.test.sh` | 805 | serial-8 | 29.4 | 9/24 (38%) | TRIM | 0 |
| `fm-busy-adapter-wiring.test.sh` | 438 | serial-1 | 29.4 | 0/2 (0%) | KEEP | 0 |
| `fm-backlog-read-bound.test.sh` | 430 | serial-4 | 28.9 | 0/0 (0%) | KEEP | 0 |
| `fm-voice-relay.test.sh` | 4741 | serial-5 | 28.7 | 6/120 (5%) | KEEP | 0 |
| `fm-daemon.test.sh` | 2909 | serial-6 | 28.1 | 3/8 (38%) | TRIM | 0 |
| `fm-board-live.test.sh` | 914 | serial-3 | 27.0 (est) | 0/32 (0%) | KEEP | 0 |
| `fm-capture-settle.test.sh` | 349 | serial-2 | 27.0 (est) | 4/19 (21%) | TRIM | 0 |
| `fm-clock-lib.test.sh` | 219 | serial-7 | 27.0 (est) | 0/0 (0%) | KEEP | 0 |
| `fm-gate-calls.test.sh` | 795 | serial-9 | 27.0 (est) | 0/18 (0%) | KEEP | 0 |
| `fm-obligation-check.test.sh` | 1913 | serial-3 | 27.0 (est) | 34/106 (32%) | TRIM | 0 |
| `fm-obligation-forge-live-e2e.test.sh` | 54 | serial-8 | 27.0 (est) | 2/2 (100%) | KEEP | 0 |
| `fm-send-commit-ish.test.sh` | 415 | serial-6 | 27.0 (est) | 1/12 (8%) | KEEP | 0 |
| `fm-upstream-pretool-check.test.sh` | 366 | serial-5 | 27.0 (est) | 0/10 (0%) | KEEP | 0 |
| `fm-wake-annotation-contradiction.test.sh` | 329 | serial-4 | 27.0 (est) | 15/22 (68%) | TRIM-HEAVY | 0 |
| `fm-secondmate-lifecycle-e2e.test.sh` | 330 | serial-1 | 24.7 | 7/35 (20%) | TRIM | 0 |
| `fm-packet.test.sh` | 1923 | serial-2 | 23.8 | 23/114 (20%) | TRIM | 165 |
| `fm-backend-orca.test.sh` | 1400 | serial-1 | 23.7 | 12/100 (12%) | KEEP | 0 |
| `fm-classify-corr-token.test.sh` | 554 | serial-7 | 22.9 | 0/0 (0%) | KEEP | 0 |
| `fm-backend.test.sh` | 1197 | serial-9 | 22.5 | 2/36 (6%) | KEEP | 0 |
| `fm-backend-herdr.test.sh` | 5413 | par-2 | 22.1 | 16/172 (9%) | KEEP | 169 |
| `fm-task-delivery.test.sh` | 897 | serial-3 | 21.5 | 52/107 (49%) | TRIM | 0 |
| `fm-afk-return.test.sh` | 806 | serial-8 | 20.6 | 36/71 (51%) | TRIM | 0 |
| `fm-secondmate-liveness.test.sh` | 559 | serial-6 | 19.7 | 4/20 (20%) | TRIM | 0 |
| `fm-backend-herdr-workspace-per-home-e2e.test.sh` | 265 | herdr-2 | 19.1 | 0/0 (0%) | KEEP | 0 |
| `fm-wake-daemon-lifecycle-e2e.test.sh` | 171 | serial-5 | 18.0 | 0/0 (0%) | KEEP | 0 |
| `fm-fleet-snapshot-view.test.sh` | 1171 | serial-4 | 17.7 | 11/13 (85%) | TRIM-HEAVY | 179 |
| `fm-wake-drain-unread-status.test.sh` | 389 | serial-2 | 17.5 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-branch-responsiveness-live-e2e.test.sh` | 238 | serial-4 | 17.2 | 0/0 (0%) | KEEP | 0 |
| `fm-cd-pretool-check.test.sh` | 400 | par-1 | 17.0 | 0/2 (0%) | KEEP | 0 |
| `fm-afk-contract.test.sh` | 704 | serial-5 | 16.6 | 33/50 (66%) | TRIM-HEAVY | 209 |
| `fm-guard-stale-banner.test.sh` | 925 | serial-6 | 15.6 | 19/26 (73%) | TRIM-HEAVY | 286 |
| `fm-rovo-harness.test.sh` | 473 | serial-2 | 15.1 | 5/28 (18%) | TRIM | 0 |
| `fm-remote-doctor.test.sh` | 889 | serial-3 | 14.8 | 16/91 (18%) | TRIM | 0 |
| `fm-tool-update-check.test.sh` | 1044 | serial-8 | 13.9 | 16/54 (30%) | TRIM | 110 |
| `fm-gate-refuse.test.sh` | 357 | serial-9 | 13.2 | 0/20 (0%) | KEEP | 0 |
| `fm-update.test.sh` | 576 | serial-7 | 12.3 | 8/54 (15%) | KEEP | 0 |
| `fm-crew-state.test.sh` | 3659 | par-2 | 11.6 | 33/406 (8%) | KEEP | 0 |
| `fm-on.test.sh` | 520 | serial-1 | 11.3 | 7/36 (19%) | TRIM | 0 |
| `fm-claude-trust.test.sh` | 1442 | serial-1 | 11.0 | 16/70 (23%) | TRIM | 111 |
| `fm-control-herdr-smoke.test.sh` | 327 | herdr-2 | 10.9 | 0/0 (0%) | KEEP | 0 |
| `fm-mail.test.sh` | 2659 | serial-7 | 10.4 | 6/158 (4%) | KEEP | 0 |
| `fm-herdr-lab.test.sh` | 517 | par-2 | 9.8 | 2/5 (40%) | TRIM | 0 |
| `fm-bootstrap-network-parallel.test.sh` | 329 | serial-8 | 9.8 | 0/7 (0%) | KEEP | 0 |
| `fm-branch-supervision.test.sh` | 859 | serial-9 | 9.6 | 26/49 (53%) | TRIM | 163 |
| `fm-backend-zellij.test.sh` | 1360 | serial-5 | 9.6 | 2/48 (4%) | KEEP | 0 |
| `fm-extension-binding.test.sh` | 2215 | serial-4 | 9.2 | 3/45 (7%) | KEEP | 0 |
| `fm-backend-autodetect-smoke.test.sh` | 193 | herdr-2 | 8.9 | 0/0 (0%) | KEEP | 0 |
| `fm-spawn-worktree-settle.test.sh` | 229 | serial-2 | 8.9 | 1/9 (11%) | KEEP | 0 |
| `fm-pi-primary-types.test.sh` | 72 | par-1 | 8.6 | 0/0 (0%) | KEEP | 0 |
| `fm-tangle-guard.test.sh` | 294 | serial-3 | 7.8 | 11/30 (37%) | TRIM | 0 |
| `fm-startup-memory-budget.test.sh` | 334 | serial-6 | 7.7 | 4/17 (24%) | TRIM | 0 |
| `fm-mail-check.test.sh` | 473 | serial-3 | 7.5 | 1/38 (3%) | KEEP | 0 |
| `fm-wake-drain-open-decisions.test.sh` | 226 | serial-6 | 7.3 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-session-cleanup.test.sh` | 329 | serial-2 | 7.2 | 0/0 (0%) | KEEP | 0 |
| `fm-grok-harness.test.sh` | 117 | par-1 | 6.6 | 1/4 (25%) | KEEP | 0 |
| `fm-backend-herdr-prune-safety-e2e.test.sh` | 180 | herdr-2 | 6.4 | 0/0 (0%) | KEEP | 0 |
| `fm-watch-checkpoint.test.sh` | 87 | serial-8 | 6.1 | 0/7 (0%) | KEEP | 0 |
| `fm-shared-captain-inheritance.test.sh` | 404 | serial-9 | 5.9 | 5/19 (26%) | TRIM | 0 |
| `fm-send-secondmate-marker.test.sh` | 278 | serial-7 | 5.6 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-windows-shell-invocation.test.sh` | 119 | serial-1 | 5.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-popup-settle.test.sh` | 167 | par-2 | 4.9 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-lib.test.sh` | 838 | par-1 | 4.8 | 0/0 (0%) | KEEP | 0 |
| `fm-dispatch-resolve.test.sh` | 638 | serial-5 | 4.7 | 40/116 (34%) | TRIM | 0 |
| `fm-backend-herdr-smoke.test.sh` | 367 | herdr-2 | 4.6 | 0/0 (0%) | KEEP | 0 |
| `fm-busy-state.test.sh` | 486 | serial-4 | 4.5 | 0/0 (0%) | KEEP | 0 |
| `fm-send-strict.test.sh` | 241 | par-2 | 3.9 | 1/20 (5%) | KEEP | 0 |
| `fm-harness-precedence.test.sh` | 761 | serial-4 | 3.8 | 2/4 (50%) | KEEP | 0 |
| `fm-tasks-axi.test.sh` | 230 | serial-5 | 3.8 | 4/15 (27%) | TRIM | 0 |
| `fm-send-agy-confirm.test.sh` | 165 | serial-1 | 3.7 | 0/0 (0%) | KEEP | 0 |
| `fm-ci-workflow.test.sh` | 233 | serial-7 | 3.6 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-cmux.test.sh` | 1166 | serial-9 | 3.6 | 0/41 (0%) | KEEP | 0 |
| `fm-classify-decision-key.test.sh` | 486 | serial-6 | 3.5 | 0/0 (0%) | KEEP | 0 |
| `fm-remote-herdr-guard.test.sh` | 343 | serial-8 | 3.1 | 10/15 (67%) | TRIM-HEAVY | 0 |
| `fm-stow-cascade.test.sh` | 370 | serial-3 | 3.1 | 2/8 (25%) | TRIM | 0 |
| `fm-remote-job-orphan-reap.test.sh` | 229 | serial-2 | 3.0 | 0/5 (0%) | KEEP | 0 |
| `fm-turnend-foreign-owner-arm-fix.test.sh` | 6 | serial-4 | 2.9 | 0/0 (0%) | KEEP | 0 |
| `fm-test-isolation-proof.test.sh` | 297 | serial-5 | 2.8 | 0/0 (0%) | KEEP | 0 |
| `fm-session-lock-ancestry.test.sh` | 414 | serial-1 | 2.8 | 0/0 (0%) | KEEP | 0 |
| `fm-tmux-agent-liveness.test.sh` | 384 | serial-8 | 2.8 | 0/0 (0%) | KEEP | 0 |
| `fm-review-diff.test.sh` | 176 | par-1 | 2.7 | 1/15 (7%) | KEEP | 0 |
| `fm-tmux-submit-busy.test.sh` | 355 | par-1 | 2.5 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-focus-flash-e2e.test.sh` | 409 | herdr-2 | 2.4 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-attached-viewer-live-e2e.test.sh` | 259 | herdr-2 | 2.3 | 3/3 (100%) | KEEP | 0 |
| `fm-spawn-batch.test.sh` | 150 | par-2 | 2.3 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-session-cleanup-e2e.test.sh` | 146 | herdr-2 | 2.2 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-ghost.test.sh` | 716 | par-1 | 2.1 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-respawn-idem-e2e.test.sh` | 182 | herdr-2 | 2.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-settle.test.sh` | 147 | par-2 | 2.1 | 0/0 (0%) | KEEP | 0 |
| `fm-procevent-quota.test.sh` | 225 | serial-3 | 2.0 | 0/0 (0%) | KEEP | 0 |
| `fm-test-fixtures.test.sh` | 320 | serial-7 | 2.0 | 3/9 (33%) | TRIM | 0 |
| `fm-live-gate.test.sh` | 220 | serial-9 | 1.9 | 6/16 (38%) | TRIM | 0 |
| `fm-backend-herdr-eventwait-smoke.test.sh` | 136 | herdr-2 | 1.7 | 0/0 (0%) | KEEP | 0 |
| `fm-brief.test.sh` | 1318 | par-1 | 1.6 | 124/198 (63%) | DELETE-FILE | 126 |
| `fm-quota-choose.test.sh` | 665 | serial-6 | 1.6 | 0/0 (0%) | KEEP | 0 |
| `fm-calm-claude-mod.test.sh` | 425 | serial-2 | 1.5 | 0/5 (0%) | KEEP | 0 |
| `fm-gotmp.test.sh` | 251 | serial-6 | 1.4 | 0/0 (0%) | KEEP | 0 |
| `fm-gemini-harness.test.sh` | 274 | serial-4 | 1.4 | 0/0 (0%) | KEEP | 0 |
| `fm-peek-remote.test.sh` | 110 | serial-7 | 1.0 | 2/4 (50%) | KEEP | 0 |
| `fm-subagent-pretool-check.test.sh` | 291 | serial-9 | 1.0 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-stale-active-tab-e2e.test.sh` | 92 | herdr-2 | 1.0 | 0/0 (0%) | KEEP | 0 |
| `fm-harness-liveness-drift-live-e2e.test.sh` | 238 | serial-3 | 0.9 | 0/0 (0%) | KEEP | 0 |
| `fm-documentation-audiences.test.sh` | 141 | serial-5 | 0.9 | 0/3 (0%) | KEEP | 0 |
| `fm-ensure-agents-md.test.sh` | 435 | par-2 | 0.9 | 7/31 (23%) | TRIM | 0 |
| `fm-nm-test-contract.test.sh` | 26 | serial-2 | 0.9 | 0/0 (0%) | KEEP | 0 |
| `fm-lint-workflows.test.sh` | 562 | serial-1 | 0.9 | 7/29 (24%) | TRIM | 0 |
| `fm-test-fixture-cleanup.test.sh` | 172 | serial-8 | 0.8 | 0/1 (0%) | KEEP | 0 |
| `fm-pr-state.test.sh` | 286 | serial-3 | 0.7 | 6/13 (46%) | TRIM | 0 |
| `fm-supervision-events.test.sh` | 156 | serial-7 | 0.7 | 0/0 (0%) | KEEP | 0 |
| `fm-check-unregister.test.sh` | 198 | serial-9 | 0.5 | 0/8 (0%) | KEEP | 0 |
| `fm-backend-tmux-smoke.test.sh` | 173 | serial-2 | 0.4 | 0/0 (0%) | KEEP | 0 |
| `fm-supervision-instructions.test.sh` | 230 | par-2 | 0.3 | 27/88 (31%) | DELETE-FILE | 0 |
| `fm-no-mistakes-required.test.sh` | 72 | serial-5 | 0.3 | 2/4 (50%) | KEEP | 0 |
| `fm-trace-context-lib.test.sh` | 253 | serial-6 | 0.3 | 0/3 (0%) | KEEP | 0 |
| `fm-operational-input.test.sh` | 160 | serial-1 | 0.2 | 0/0 (0%) | KEEP | 0 |
| `fm-pr-reviewers.test.sh` | 116 | serial-4 | 0.2 | 1/5 (20%) | TRIM | 0 |
| `fm-ask-user-authority.test.sh` | 42 | serial-5 | 0.1 | 6/7 (86%) | DELETE-FILE | 0 |
| `fm-remote-entrypoint.test.sh` | 59 | serial-2 | 0.1 | 3/3 (100%) | KEEP | 0 |
| `fm-project-origin.test.sh` | 110 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-harness-adapter-references.test.sh` | 30 | serial-9 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-stat-shadowing.test.sh` | 139 | serial-5 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-transition-lib.test.sh` | 54 | par-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-submit-confirm-live-e2e.test.sh` | 122 | serial-6 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pr-state-live-e2e.test.sh` | 39 | serial-2 | 0.1 | 0/1 (0%) | KEEP | 0 |
| `fm-calm-claude-mod-live-e2e.test.sh` | 455 | serial-4 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-codex-continuity-live-e2e.test.sh` | 53 | serial-1 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-grok-continuity-live-e2e.test.sh` | 109 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-grok-stop-live-e2e.test.sh` | 215 | serial-5 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-opencode-primary-live-e2e.test.sh` | 353 | serial-9 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-rovo-signals-live-e2e.test.sh` | 358 | serial-4 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-claude-stop-autoarm-live-e2e.test.sh` | 163 | serial-6 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-codex-idle-live-e2e.test.sh` | 145 | serial-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-branch-live-e2e.test.sh` | 993 | serial-1 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-gitignore-config.test.sh` | 91 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-secondmate-marker-herdr-e2e.test.sh` | 180 | serial-5 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-codex-hook-layer-live-e2e.test.sh` | 97 | serial-9 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-codex-native.test.sh` | 362 | serial-6 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-herdr-agent-exit-shell-e2e.test.sh` | 213 | herdr-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-agy-signals-live-e2e.test.sh` | 193 | serial-4 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-muse-signals-live-e2e.test.sh` | 201 | serial-3 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-bearings-board-lavish-live-e2e.test.sh` | 120 | serial-2 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-cmux-claude-composer-live-e2e.test.sh` | 105 | serial-1 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-version-floor-live-e2e.test.sh` | 142 | serial-7 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-send-inbox-doorbell-live-e2e.test.sh` | 205 | serial-8 | 0.1 | 0/0 (0%) | KEEP | 0 |
| `fm-composer-matrix-live-e2e.test.sh` | 218 | serial-5 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-cursor-primary-live-e2e.test.sh` | 213 | serial-9 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-herdr-pi-stale-registration-live-e2e.test.sh` | 159 | serial-4 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-afk-pi-herdr-return-e2e.test.sh` | 287 | serial-6 | 0.0 | 1/5 (20%) | TRIM | 0 |
| `fm-calm-claude-mod-plugin.test.sh` | 83 | serial-3 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-harness-adapter-instructions-live-e2e.test.sh` | 129 | serial-2 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-omp-primary-live-e2e.test.sh` | 313 | serial-1 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-pi-primary-live-e2e.test.sh` | 345 | serial-7 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-quota-array-dispatch-live-e2e.test.sh` | 524 | serial-8 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-sessionstart-hook-live-e2e.test.sh` | 628 | serial-5 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-sessionstart-instruction-refresh-live-e2e.test.sh` | 226 | serial-9 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-cmux-smoke.test.sh` | 188 | serial-4 | 0.0 | 0/0 (0%) | KEEP | 0 |
| `fm-backend-zellij-smoke.test.sh` | 205 | serial-6 | 0.0 | 0/0 (0%) | KEEP | 0 |

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
