# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The retained hints are the slowest completed value each script reached across six CI runs on 2026-09-10: [34459949083](https://github.com/kunchenguid/firstmate/actions/runs/34459949083), [34460760299](https://github.com/kunchenguid/firstmate/actions/runs/34460760299), [34462530836](https://github.com/kunchenguid/firstmate/actions/runs/34462530836), [34462758357](https://github.com/kunchenguid/firstmate/actions/runs/34462758357), [34466966385](https://github.com/kunchenguid/firstmate/actions/runs/34466966385), and [34470382458](https://github.com/kunchenguid/firstmate/actions/runs/34470382458).
Shard 2 completed in all six, so its scripts come from the uploaded `fm-test-timing-portable-parallel-2` artifacts.
Shard 1 was cancelled at its job cap in five of the six, so its scripts come from the `FM_TEST_END duration_ms=` markers in each cancelled job's log, which record every script that finished before the cancellation, plus the one complete `fm-test-timing-portable-parallel-1` artifact from run 34462758357.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

The measurements cover all 24 candidates, with six samples per script except:

| Samples | Scripts |
|---:|---|
| 4 | `tests/fm-lint.test.sh` |
| 3 | `tests/fm-pi-primary-types.test.sh`, `tests/fm-review-diff.test.sh` |
| 1 | `tests/fm-brief.test.sh`, `tests/fm-transition-lib.test.sh` |

The two scripts with one sample are the tail of shard 1 that only the complete run reached.
Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation.
The complete historical run supplies tail-script hints, not a completion time for any later cancelled invocation or for the rebalanced jobs.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

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
Nine serial runners pack the refreshed measurements into 721.7 s (12m02s) on every shard, which is also the ideal: no script is now long enough to set the makespan on its own.
Scored against the same measurements, the previous hints left shard 3 carrying 983s of real work against that 722s ideal, and the refresh alone cut the modeled makespan to 819s.
The remaining 97s came from splitting the longest script.
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
A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
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

Refresh the Herdr hints exactly as the serial ones are refreshed, from the per-shard artifacts:

```sh
for run in <run-id> <run-id> <run-id>; do
  for k in 1 2; do
    gh run download "$run" -R <owner>/firstmate --name "fm-test-timing-herdr-$k" --dir "/tmp/fm-herdr/$run/$k"
  done
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-herdr/*/*/*/*.json \
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
The count belongs to the caller and `.github/workflows/ci.yml` derives it from `strategy.job-total`, so the matrix and the split cannot disagree; an index outside `1..n`, a count below one, and a malformed spec are all refused rather than linting an empty root set and reporting a clean result having checked nothing.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots at several counts and unchanged analysis flags.
The workflow uploads each partition's quiet telemetry to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, reduced checks, or paid runner provisioning is part of this layout.

**Byte weight balances the partitions; it does not balance their duration, and the gap is large.**
Partitions are packed by byte weight, and on green run [35479482522](https://github.com/BenjaminLu/firstmate/actions/runs/35479482522) that packing was as close to exact as it can get - both partitions held 7065522 bytes, to the byte - yet partition 1 ran 313 s against partition 2's 586 s, with 498.84 s of CPU against 871.98 s.
Neither root bytes nor the transitive `# shellcheck source=` closure explains it: the closures differ by 6% while the wall differs by 87%.
Measured per root on one machine, ShellCheck cost ranges from 102 ms/KB to 10122 ms/KB, a hundredfold spread, so file size carries almost no information about analysis cost.
Raising `n` therefore splits the same mispredicted weight into more bins rather than correcting it; expect the partitions to stay uneven at any count until the weight itself is measured rather than estimated.
Treat `shard_*_weight_bytes` in the telemetry as the scheduling proxy it is, and read the measured `wall_seconds` beside it before concluding a partition is balanced.

The performance objective is a complete green run under fifteen minutes including start delay: roughly twelve minutes of longest-path execution, at most two minutes of runner delay, and less than one minute of other overhead.
The candidate uses fifteen long-lived Linux jobs (nine serial, two parallel, two Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.

**That last clause is now the binding constraint, not a caveat.**
This repository is public and on a plan whose whole-account ceiling is twenty concurrent jobs: across 180 jobs sampled from ten runs on 2026-09-20, concurrency reached exactly 20 and never 21, and sat pinned at 20 for 12.5% of the window.
One CI run is already eighteen jobs, so a second run in flight queues behind the first, and measured queue waits in that sample reached 3478 s for a single job - several times the execution time the packing saves.
The consequence for this layout is concrete: splitting work across more runners only shortens the wall clock while the run fits inside that ceiling, and past it a run serialises its own overflow behind its own long jobs.
Prefer changes that cut runner-seconds without adding a job - concurrency inside a lane that already has an isolation proof, as the portable parallel lanes now use - over changes that buy another runner, and measure the account's concurrent-job ceiling before assuming a shard count is free.
Standard public `ubuntu-latest` runners have four cores, so a lane pinned to one worker leaves most of that machine idle.
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
