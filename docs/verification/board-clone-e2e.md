# Captain's board clone-and-browser verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence that a clone of this repository, with nothing of the host machine on its path, gets a working captain's board - and that the guarantee is enforced by a check rather than by anyone remembering to look.

`docs/configuration.md` owns the board's operating contract, `bin/fm-board-live.sh` and `bin/fm-bearings-board.sh` own their own mechanics, and `tests/fm-board-clone-e2e.test.sh` is the check this record is about.

## What the check does

It copies the tracked tree into a directory with no git history and nothing installed, runs the shipped build command under a path holding only the system directories and a link to `node`, opens the URL that command prints in a real headless browser over the Chrome DevTools Protocol, publishes real fleet events, and presses a real option with a real mouse event.

Nothing in it models a browser.
The board's freshness, its live socket, and what sits under the captain's pointer are all the browser's decisions, and the DOM shim in `tests/assets/board-render-harness.mjs` was measured wrong by up to 21 percent against Chrome on 2026-09-20, which is why a second model was not built here.

This is the board's only end-to-end suite: the file that previously carried that name guarded another tool and reported a capability skip, and was deleted.
Its header is the single owner of what it covers and, more usefully, what it does not - one browser, no appearance, one card shape, one viewer, no reconnection under a live page, and the read boundary untested.
Read that list before concluding the board is covered for something.

## Refreshing this record

```sh
bin/fm-test-run.sh tests/fm-board-clone-e2e.test.sh
```

The suite reports `skip: chrome not found` only on a machine with no browser at all.
The portable serial CI lane requires a browser in its own step and passes `--fail-on-gate-skip 'chrome not found'`, so that skip is a lane failure where the code lands.
`FM_TEST_BROWSER` points the driver at a specific binary when a machine has several.

The case asserting that a behind board never reports an empty desk names a live defect rather than a gap in the suite, and it stays red until the branch that owns that rule closes it.
The suite's own header says which case that is and why the fix deliberately does not live on the same branch as the assertion.

## Proving the cases can fail

A branch that both asserts a behaviour and provides it can bend the test to fit the code, so the assertion about a stale server was checked against three separate mutations of the fix - `status` no longer reporting staleness, `start` no longer replacing a stale server, and `doctor` no longer refusing the state - each of which must make the case fail, and fail naming what it lost.
Re-run that with the mutation transcript in this branch's pull request when the fix changes.

## Verified

FILL_VERIFIED
