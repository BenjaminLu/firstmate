# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from runs of the real lanes on `ubuntu-latest`, each script measured in the lane configuration CI actually gives it.
That is a change of meaning worth naming, because shard 1 now runs with `--jobs 2`: a hint for one of its members is usually a sample taken under that contention, which is both the right weight for the lane being modelled and a conservative one if that script were ever moved to a serial lane.
Read a hint as "what this script costs where it runs", not as a context-free serial duration.

The parallel hints were refreshed on 2026-09-20 from the `fm-test-timing-portable-parallel-*` artifacts of nine green runs on this repository - [35500675106](https://github.com/BenjaminLu/firstmate/actions/runs/35500675106), [35501233728](https://github.com/BenjaminLu/firstmate/actions/runs/35501233728), [35502182107](https://github.com/BenjaminLu/firstmate/actions/runs/35502182107), [35502455291](https://github.com/BenjaminLu/firstmate/actions/runs/35502455291), [35503091467](https://github.com/BenjaminLu/firstmate/actions/runs/35503091467), [35503181619](https://github.com/BenjaminLu/firstmate/actions/runs/35503181619), [35503920748](https://github.com/BenjaminLu/firstmate/actions/runs/35503920748), [35505054553](https://github.com/BenjaminLu/firstmate/actions/runs/35505054553) and [35511447348](https://github.com/BenjaminLu/firstmate/actions/runs/35511447348) - plus one named supplement, the `cancelled` main run [35513827276](https://github.com/BenjaminLu/firstmate/actions/runs/35513827276).
That supplement is taken under the rule below and is where the shard 2 values come from: its lane 2 job was cancelled at its cap with three scripts left to run, so it uploaded no timing artifact, but every script that did finish printed a completed `FM_TEST_END ... exit=0 duration_ms=` line in the job log, including the one that sets the lane.
Its shard 1 job completed green and is an ordinary sample.

A hint is only retained from a run whose own copy of that file was byte-identical to this tree's, compared through the GitHub trees API rather than assumed from a date.
Every one of the 24 members is measured under that rule, but the sample counts are uneven and that is the point of stating it: 11 or 12 samples for most, 11 for `tests/fm-pr-merge.test.sh`, 5 for `tests/fm-lint.test.sh`, 4 for `tests/fm-test-run.test.sh` after PR 46 rewrote both, and 2 for `tests/fm-captain-hold-lifecycle.test.sh` after PR 37 changed it.
Two samples is thin, and for the script that is a whole lane it is the thinnest place in this table; it is also all the evidence that exists for the content on main, and a sample from a version of the file that no longer exists would be worse than thin.

One sample is excluded: `tests/fm-pr-merge.test.sh` recorded 419753 ms on run [35512648071](https://github.com/BenjaminLu/firstmate/actions/runs/35512648071) against 179049-266554 ms across the other ten.
Its co-resident scripts on that same run ran about 1.3x their usual, a slow runner, while that one script ran 2.05x - so the excess is the script's own and not the machine's, and a hint 1.6x above the script's real cost unbalances the packing it exists to balance.
That is the same evidence shape the serial table requires for an exclusion: the same script measured against itself and against its own run.

Observed maxima provide conservative packing weights, not an upper bound on future durations.
How far from an upper bound is worth knowing concretely: `tests/fm-captain-hold-lifecycle.test.sh` measured 373081 ms and 447694 ms on two runs of the same content hours apart on 2026-09-20, a 1.20x spread on a script that is six and a half minutes long.
A single sample is therefore not a measurement, and a laptop's seconds are not a runner's: local timings and CI timings are not interchangeable, because platform and machine load affect each script differently and change their relative weights.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.

## Parallel lanes

The two lanes are balanced on each lane's projected **wall**, never on equal hint sums.

That distinction is the whole of the 2026-09-20 failure.
CI runs shard 1 with `--jobs 2` and shard 2 serially, so the same hint sum buys two different walls: shard 1's wall is the longest-processing-time makespan of its members over two workers, and shard 2's wall is its plain sum.
At the stale hints the two lanes' sums were 414269 ms and 417163 ms - 0.7% apart, comfortably inside the 5% band the retired assertion enforced - while shard 2's real wall on main was 10m03s against a 10-minute cap.
Every guard was green.
The lane was cancelled 1.4 seconds of work short of finishing, on main and then on every branch that rebased onto it, including [PR 45](https://github.com/BenjaminLu/firstmate/pull/45), which adds no test at all.

A cancelled job also reads as a failed check, which is the second half of the trap: nothing in that lane failed, and the summary says it did.

`bin/fm-test-run.sh` owns the model.
`PORTABLE_PARALLEL_LANE_1_JOBS` and `PORTABLE_PARALLEL_LANE_2_JOBS` record the worker count CI gives each lane, `portable_parallel_lane_wall` projects a lane's wall as the longest-processing-time makespan over that count, and `PORTABLE_PARALLEL_LANE_BUDGET_MS` is the largest wall a pack may project.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) to those same worker counts and to the same job cap, so the model can never describe a lane the workflow does not run.
Read the current projection with `bin/fm-test-run.sh --check-coverage`, which reports `parallel_lane1_wall_ms`, `parallel_lane2_wall_ms`, `parallel_max_wall_ms`, `parallel_wall_budget_ms`, `parallel_wall_cap_ms` and the per-lane worker counts.
A projection past the budget **fails** that guard, which is a five-minute job, so a bad pack goes red there instead of surviving to a ten-minute cancellation in a lane.

The budget is 510000 ms against the workflow's 600000 ms cap, 85% of it.
The 15% held back is not slack to spend: it covers the job setup the model cannot see - checkout and the pinned tool installs, measured at 10-20 s on 2026-09-20 - and the runner spread that survives retaining each script's slowest observed sample.

### Where this packing came from

At the refreshed hints the set totals 1372158 ms across 24 scripts, and `tests/fm-captain-hold-lifecycle.test.sh` alone is 447694 ms of it.
Three execution slots exist - shard 2's one worker and shard 1's two - so no split can finish sooner than 1372158/3 = 457386 ms, and no split can put shard 2 below that one script if it holds it.
Those two numbers are within 2% of each other, which decides the layout: shard 2 holds that script and nothing else, shard 1 holds the other 23, and the lanes project 447694 ms and 462617 ms.
Moving anything into shard 2 costs its full duration there while saving only half of it on shard 1, so every other split makes the worse lane worse.

That leaves **137383 ms - 2m17s, 22.9% of the cap - below the 600000 ms cap on the slower lane**, and 152306 ms (2m32s, 25.4%) on shard 2, the lane that was cancelled.
Stated the way the next change will meet it: this set runs at a measured 44.6 ms per line of test file on average, and the two heaviest scripts run at 83-90 ms per line.
PR 37's largest single test-file addition was 1491 lines.
One more addition of that size costs 66 s at the set average and 125 s at the rate the heavy scripts actually run, so it takes between 44% and 82% of the remaining room, and a second one is over the cap.

The room on shard 2 in particular cannot be recovered by repacking again, because that lane is already one script.
When it runs out, the lever is splitting that script the way `tests/fm-watch-triage.test.sh` was split below - not raising the cap, which removes the only thing that noticed, and not adding a shard, which a run already demanding 18 of this account's measured 20 concurrent slots cannot afford.

`bin/fm-test-run.sh` holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
`tests/fm-pi-primary-types.test.sh` stays on shard 1 because that is the job installing the Pi package; moving it needs that workflow step moved with it.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh) requires every member to carry a hint, requires both projected walls to sit inside the budget, and drives the guard end to end over fixture hint tables placed either side of the budget - on each lane in turn, and on a pair of lanes with identical sums and one wall over - so the assertion is demonstrably able to both fail and pass rather than asserted to be.
It also withholds one member's hint and requires the projection to rise, because a model that drops the work it cannot measure would report headroom exactly where the packing is least trustworthy.
The largest individual hint sets a lower bound on any split's projection, regardless of how evenly the rest is assigned.

Refresh `portable_parallel_weight_hints` whenever the parallel set gains scripts or a member grows materially, using the same evidence rules as the serial table below: green runs for the baseline, a cancelled run only as a named supplement, the slowest completed `duration_ms` per script, and only from a run whose copy of that file matches the tree being packed.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The serial hints were refreshed on 2026-09-19 from the `fm-test-timing-portable-serial-*` artifacts of five complete green runs on this repository: [35447243698](https://github.com/BenjaminLu/firstmate/actions/runs/35447243698), [35446928942](https://github.com/BenjaminLu/firstmate/actions/runs/35446928942), [35446548848](https://github.com/BenjaminLu/firstmate/actions/runs/35446548848), [35446251051](https://github.com/BenjaminLu/firstmate/actions/runs/35446251051), and [35444308011](https://github.com/BenjaminLu/firstmate/actions/runs/35444308011).
All nine shards completed in all five, so every one of the 178 serial scripts at refresh time carries five successful samples; retain the slowest.
Shard 1 of run 35444308011 is the one excluded sample: its single script took 1732786 ms against 765144-819256 ms in the other four, a degraded runner rather than a script that grew, and a hint 2.1x above the script's real cost unbalances the packing it exists to balance.
Exclude a sample only on that evidence - the same shard measured against itself across runs - and record the exclusion here.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
An unfinished or failed invocation is not a healthy duration sample.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Nine serial runners pack the refreshed measurements into 748.7 s (12m29s) on every shard, which is also the ideal: no script is now long enough to set the makespan on its own.
That figure is derived over a 188-script serial lane, and packing is longest-processing-time over the whole lane, so it moves whenever the lane gains or loses a script rather than only when a hint changes: re-derive it from `--list --lane portable-serial` and the hint table rather than quoting it after the lane has grown.
Scored against the same measurements at the 178-script lane that refresh was measured on, the previous hints left shard 3 carrying 983s of real work against that day's 722s ideal, and the refresh alone cut the modeled makespan to 819s.
The remaining 97s of that cut came from splitting the longest script.
`tests/fm-watch-triage.test.sh` used to run 819s as one file, occupied a whole shard, and stayed the makespan at every shard count, so it was recorded here as this layout's indivisible floor.
It was not indivisible: its 122 cases are hermetic - each mints its own state directory and its own stubs through `make_case` - and they now run as 95 in that file and 27 in `tests/fm-watch-triage-waits.test.sh`, which owns the wake someone has already explained (a declared pause or dated wait, a captain-held item, the away-posture record, and the wedge threshold that must consult them).
Their shared fixtures live in `tests/watch-triage-helpers.sh`.
A split cannot quietly drop coverage, because the coverage guard below proves the lanes still partition every `tests/*.test.sh` whatever a file is called.
The two hints are the whole file's 819256 ms CI measurement divided by the two halves' measured share of it: 428880 ms and 481020 ms back to back on one unloaded machine on 2026-09-19, 47.1% / 52.9%.
That is a local ratio applied to a CI total, not a CI measurement of either file; replace both with their own `fm-test-timing-portable-serial-*` values at the next refresh.
This is a packing estimate, not measured new-workflow execution or an end-to-end latency guarantee.
Existing job timeouts remain hang tripwires; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  for k in 1 2 3 4 5 6 7 8 9; do
    gh run download "$run" -R <owner>/firstmate --name "fm-test-timing-portable-serial-$k" --dir "/tmp/fm-serial/$run/$k"
  done
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Name the repository the hints are for on every call: an unqualified `gh`/`gh-axi` resolves to whichever remote the checkout defaults to, and run numbers collide between forks, so an unnamed repository silently measures a different fork's CI and the drift this table exists to correct stays invisible.
**One rule for which runs to measure: take `success` runs for the baseline, and use a cancelled or timed-out run's completed shards only as a named supplement.**
Read `conclusion` before using a run (`gh run view <id> -R <owner>/firstmate --json conclusion`); if it is not `success`, either leave the run out or say in this document which of its shards you took and why.
The baseline has to be complete runs because a timed-out shard may upload no artifact at all, and the scripts that go unmeasured are the ones on the shard that needed them most.
Never treat a missing tail script or a timeout duration as a successful sample.

The reason the supplement must be named is that a partial run does not look partial.
Per-PR supersession cancels runs routinely here, and a cancelled run still publishes artifacts: genuine for the jobs that finished, simply absent for the jobs that never started, with nothing in its summary distinguishing the two - so a refresh that quietly includes one measures a subset while looking like a full sample, and the scripts it drops belong to the shards that had not finished, which are the slowest shards.
Its job records mislead in the same direction: a queued-then-cancelled job still carries a `started_at`, so it reports a long wall that is entirely queue wait and never execution.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Real-Herdr CI shards

`real-herdr-gated-<k>of<n>` splits the required Herdr family across `n` separate CI runners on the same contract as the serial shards: each shard is strictly serial in itself, `bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it, and `.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal.
Each shard installs its own pinned Herdr and Treehouse, starts its own default session for the fleet-state tripwire, and snapshots and tears down its own labs, so no two Herdr scripts ever share a machine.
That per-shard setup measured about four seconds against a ten-minute lane on green run [35479482522](https://github.com/BenjaminLu/firstmate/actions/runs/35479482522), so a shard costs a runner slot rather than meaningful duplicated work.

Assignment is longest-processing-time bin packing over `real_herdr_weight_hints` in `bin/fm-test-run.sh`, refreshed the same way and on the same evidence rule as the serial hints: the slowest completed `duration_ms` per script.
The retained values are the slowest each script reached across six green runs on this repository on 2026-09-20: [35479482522](https://github.com/BenjaminLu/firstmate/actions/runs/35479482522), [35482088244](https://github.com/BenjaminLu/firstmate/actions/runs/35482088244), [35481800435](https://github.com/BenjaminLu/firstmate/actions/runs/35481800435), [35470206371](https://github.com/BenjaminLu/firstmate/actions/runs/35470206371), [35469685248](https://github.com/BenjaminLu/firstmate/actions/runs/35469685248), and [35465280840](https://github.com/BenjaminLu/firstmate/actions/runs/35465280840).
All sixteen scripts completed in all six runs, so every hint carries six samples.

Two shards is the whole win available here, and the reason is worth recording so the count is not raised in the hope of more.
`tests/fm-backend-herdr-presentation-e2e.test.sh` is 433530 ms of a 638676 ms lane - 68% of it in one script - and it is one flat script that builds a single real lab session across its whole length, so it sets the makespan at every count above one:

| shards | modelled makespan |
|---:|---|
| 1 | 638.7 s |
| 2 | **433.5 s** |
| 3 | 433.5 s |
| 4 | 433.5 s |

A third runner is a slot spent for nothing until that script is divisible, and splitting it means paying real lab setup again per piece.
`bin/fm-test-run.sh --check-coverage` reports `herdr_shards=` and `herdr_unhinted=`, and refuses past the same unmeasured-share bound the serial lane uses.

Refresh the Herdr hints exactly as the serial ones are refreshed, from the per-shard artifacts, but note two ways this glob differs from the serial one at the same `--dir` shape.
It is one level deeper, because `actions/upload-artifact@v4` roots a multi-path artifact at the least common ancestor of its paths: the Herdr artifact uploads from both `fm-test/` and `fm-herdr/`, so it extracts with a directory level the single-path serial artifact does not have.
It also names the timing file rather than matching every JSON, because that extra level carries `fm-herdr/sessions-before-<k>.json` too; `jq` prints a diagnostic for each such file and carries on to the next, so matching them costs noise rather than hints, but the noise is what invites someone to "fix" a recipe that works.

```sh
for run in <run-id> <run-id> <run-id>; do
  for k in 1 2; do
    gh run download "$run" -R <owner>/firstmate --name "fm-test-timing-herdr-$k" --dir "/tmp/fm-herdr/$run/$k"
  done
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-herdr/*/*/*/fm-test-timing-herdr-*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane, and that the real-Herdr CI shards are non-empty, disjoint, and together equal the `real-herdr-gated` family.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns `<k>of<n>` canonical CI partitions, each running the same full source-aware ShellCheck analysis with two bounded workers, pinned versions, workflow validation, and backend-purity checks.
The count belongs to the caller and `.github/workflows/ci.yml` derives it from `strategy.job-total`, so the matrix and the split cannot disagree.
Four things are refused, and the fourth is the one that matters: an index outside `1..n`, a count below one, and a malformed spec are all rejected by the argument parser, but a valid index of a valid count can still select nothing once there are more partitions than the canonical inventory has roots, which passes all three parser checks - so the produced root set is checked too and an empty partition is refused by name.
Read that count as `bin/fm-lint.sh --partition 1of1 --list-files`, not as a bare `--list-files`: with no explicit paths the reported set depends on the invocation, so on a branch it is the changed files and under `--partition <k>of<n>` it is that partition's share, and only the canonical count is the one the refusal is measured against.
That last check is the only defence against the outcome the other three are usually credited with preventing: a partition that lints nothing and reports a clean result, on the runner whose job it was to check its share.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots at several counts and unchanged analysis flags.
The workflow uploads each partition's quiet telemetry to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, reduced checks, or paid runner provisioning is part of this layout.

**Byte weight balances the partitions; it does not balance their duration, and the gap is large.**
Partitions are packed by byte weight, and on green run [35479482522](https://github.com/BenjaminLu/firstmate/actions/runs/35479482522) that packing was as close to exact as it can get - both partitions held 7065522 bytes, to the byte - yet partition 1 ran 313 s against partition 2's 586 s, with 498.84 s of CPU against 871.98 s.
Neither root bytes nor the transitive `# shellcheck source=` closure explains it: taking each partition's `--list-files` roots at that same commit and following `# shellcheck source=` transitively into one deduplicated set gives 241 files and 7576740 bytes against 248 files and 7764849 bytes, so the closures differ by **2.5%** while the wall differs by 87%.
Both halves are measured at `14fd3bef`, the `git_head` the telemetry records, because a closure read at one revision against a wall from another is two reference points in one comparison; re-derive both together if you refresh either.
Measured per root on one machine, ShellCheck cost ranges from 102 ms/KB to 10122 ms/KB, a hundredfold spread, so file size carries almost no information about analysis cost.
Raising `n` therefore splits the same mispredicted weight into more bins rather than correcting it; expect the partitions to stay uneven at any count until the weight itself is measured rather than estimated.
Treat `shard_*_weight_bytes` in the telemetry as the scheduling proxy it is, and read the measured `wall_seconds` beside it before concluding a partition is balanced.

The performance objective is a complete green run under fifteen minutes including start delay: roughly twelve minutes of longest-path execution, at most two minutes of runner delay, and less than one minute of other overhead.
The candidate uses fifteen long-lived Linux jobs (nine serial, two parallel, two Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.

**That last clause is now the binding constraint, not a caveat.**
This repository is public and on a plan whose whole-account ceiling is twenty concurrent jobs: across 180 jobs sampled from ten runs on 2026-09-20, concurrency reached exactly 20 and never 21, and sat pinned at 20 for 12.5% of the window.
One CI run is nineteen jobs at this layout - the fifteen long-lived Linux jobs named above plus the coverage guard, the timing aggregate, the repository invariants, and macOS - but the count the ceiling reasons against is **concurrent demand, which is eighteen**.
`tests-timing-aggregate` cannot be in any peak set, and that is a deduction from the workflow rather than an observation of a run: it `needs:` all four long-lived lane groups, and those thirteen jobs are what any peak near eighteen is made of, so it cannot be running while they are.
So a run demands eighteen slots of twenty and a second run in flight queues behind the first; measured queue waits in that sample reached 3478 s for a single job, several times the execution time the packing saves.
That leaves two spare slots, which is what decides whether the next shard is free - and a job that never overlaps its siblings, like the aggregate, is free of that budget however many there are.
The consequence for this layout is concrete: splitting work across more runners only shortens the wall clock while the run fits inside that ceiling, and past it a run serialises its own overflow behind its own long jobs.
Raising `PORTABLE_SERIAL_SHARDS` from 9 to 12 would add three concurrent jobs, taking demand from eighteen to twenty-one - over the ceiling by one slot, not by two.
Prefer changes that cut runner-seconds without adding a job over changes that buy another runner, and measure the account's concurrent-job ceiling before assuming a shard count is free.
Standard public `ubuntu-latest` runners have four cores, so a lane pinned to one worker leaves most of that machine idle - but idle cores are not automatically a saving, and the rule for when they are is below.
**Concurrency inside a lane wins when the lane is packing-bound and does nothing when the lane is bounded by a single long script, and it costs runner-seconds either way.**
Both portable parallel lanes carry the same isolation proof and were given `--jobs 2` together; one kept it and one did not, and the difference is entirely which of those two shapes the lane has.
Measured on run [35484461648](https://github.com/BenjaminLu/firstmate/actions/runs/35484461648) against three green baseline runs: [35479482522](https://github.com/BenjaminLu/firstmate/actions/runs/35479482522), [35482088244](https://github.com/BenjaminLu/firstmate/actions/runs/35482088244) and [35481800435](https://github.com/BenjaminLu/firstmate/actions/runs/35481800435).
That run was **cancelled** by per-PR supersession: eight of its nineteen jobs were still queued and never executed, so it establishes nothing about this layout's concurrency.
What survives cancellation is the two parallel lane jobs this table quotes, which both completed green on their own runners before the cancellation, so their walls and their uploaded timing artifacts are sound.
Read anything else from that run with the caution the closing paragraph of this section asks for.

Every cell is that lane's own measurement: the serial columns are the three baseline runs named above, the `jobs=2` columns are run 35484461648, and the script-sum and longest-script columns carry the serial median against that one run.

| lane | bound | serial wall, 3 runs (median) | `jobs=2` wall | script sum, median -> jobs=2 | longest script, median -> jobs=2 |
|---|---|---|---:|---:|---:|
| portable parallel 1 | packing: 11 scripts, longest 191 s against a 546 s sum | 472-551 s (546 s) | **356 s** | 546 -> 592 s (+8%) | 191 -> 218 s (+14%) |
| portable parallel 2 | one script: `fm-captain-hold-lifecycle` is two thirds of the lane | 347-415 s (396 s) | **393 s** | 396 -> 538 s (+36%) | 268 -> 360 s (+34%) |

Read the `jobs=2` wall against its own row's serial range, which is the whole test.
Lane 1's 356 s is 116 s below the fastest of its three serial runs, so the gain is outside the run-to-run spread rather than inside it.
Lane 2's 393 s sits between its own minimum and maximum, so nothing measurable was saved - packing cannot shorten a lane whose makespan is one script, while the contention the extra worker adds makes that script longer.
The two effects cancel, and what is left is 36% more runner-seconds.
Under the twenty-job ceiling above, spending runner-seconds for no wall-clock is strictly worse rather than neutral, so lane 2 runs serial and lane 1 does not.
The 2026-09-20 repack made that conclusion unconditional rather than measured: lane 2 now holds only `tests/fm-captain-hold-lifecycle.test.sh`, so a second worker there has nothing at all to run.
Before adding `--jobs` to any lane, compare its longest script against its script sum divided by the worker count: if the longest script is the larger of the two, the lane is already at its floor and concurrency can only cost.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | See [CI workflow](../.github/workflows/ci.yml) | The workflow owns the parallel cap rationale and its evidence limits. |
| portable serial shards | See [CI workflow](../.github/workflows/ci.yml) | Packing estimates are not healthy execution bounds; the existing cap remains a hang tripwire. |
| Herdr shards | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.
