#!/usr/bin/env bash
# Credentialed regression for bin/fm-obligation-check.sh against gh's own jq
# engine and gh's own field names.
#
# gh evaluates --jq with gojq rather than the jq binary, and the hermetic suite
# in tests/fm-obligation-check.test.sh runs the script's program through the
# local jq, so only a real gh invocation proves it compiles and produces the
# shape the script parses where it actually runs. The field names matter just as
# much: state, headRefOid, reviews and comments are gh's contract, not this
# repository's, and a renamed or dropped field would make every obligation read
# as met - silence from a check that can no longer see anything, which is the
# one failure mode this script exists to prevent.
#
# cli/cli#1 is a merged 2019 pull request, so its verdict is stable forever. It
# reaches the check here as a board card, because a landed pull request still
# shown as an open call is exactly obligation 3.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shared gate is the live-harness family's one on/off contract. The trailing
# tool list replaces a hand-rolled gh presence check; authentication is not a
# tool check and stays below.
fm_live_gate opt-in FM_OBLIGATION_FORGE_LIVE_E2E gh

CHECK="$ROOT/bin/fm-obligation-check.sh"
PR=https://github.com/cli/cli/pull/1
TMP_ROOT=$(fm_test_tmproot fm-obligation-forge-live)

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

test_the_forge_read_runs_under_ghs_own_engine() {
  local home out status=0
  home="$TMP_ROOT/home"
  mkdir -p "$home/state" "$home/data" "$home/.lavish"
  {
    printf '<html><body>\n'
    printf '<script id="bearings-data" type="application/json">\n'
    printf '{"schema":"fm-bearings-board.v1","captains_call":[{"key":"live-card","pr_url":"%s"}],"landed":[],"underway":[],"charted":[]}\n' "$PR"
    printf '</script>\n'
    printf '</body></html>\n'
  } > "$home/.lavish/bearings-board.html"

  out=$(env FM_HOME="$home" FM_OBLIGATION_INTERVAL=0 "$CHECK" check 2>&1) || status=$?
  expect_code 0 "$status" "check exit"
  assert_not_contains "$out" "could not be read" \
    "gh refused the read, so the script's --jq program or its field list did not survive gh's own engine"
  assert_contains "$out" "the board still shows live-card as an open call, but $PR is merged" \
    "the live forge read did not produce the merged verdict the fields are supposed to carry"
  pass "the forge read's field list and jq program are accepted by gh's own engine"
}

test_the_forge_read_runs_under_ghs_own_engine
