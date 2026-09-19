#!/usr/bin/env bash
# Behavior tests for `bin/fm-bearings-board.sh refresh`: the no-model-in-the-loop
# republication of the captain's board. What must hold is that a refresh is
# idempotent, that it never touches the Lavish session or its armed source, that
# a stored card is reused verbatim instead of recomposed, that the Underway
# progress projection comes from structured state alone, and that the fleet
# triggers actually carry it the way they carry the home summary.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
PROGRESS="$ROOT/bin/fm-task-progress.sh"
SNAPSHOT_FIXTURE="$ROOT/tests/assets/bearings-compose/snapshot.json"
BACKLOG_FIXTURE="$ROOT/tests/assets/bearings-compose/backlog.md"
TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-refresh)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A home whose board already exists. A refresh republishes a board that was
# built once; seeding the stable path with the shipped template is exactly the
# "a board exists here" precondition, without spending a Lavish session on it.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data" "$home/.lavish"
  cp "$BACKLOG_FIXTURE" "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  # A refresh must not call lavish-axi at all, so the stub here RECORDS every
  # call and fails loudly: a test that sees this file has caught a refresh
  # reaching for the session it promised not to touch.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${*:-<list>}" >> "${LAVISH_FAKE_CALLS:?}"
exit 1
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

seed_board() {  # <home>
  cp "$TEMPLATE" "$1/.lavish/bearings-board.html"
}

# The progress projection stamps each row with its own read time, so the
# projection's clock is pinned here exactly as the hold clock is pinned
# elsewhere: a test comparing two publications compares the board, not the wall
# clock. Every read still goes through the real bin/fm-task-progress.sh.
run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TASK_PROGRESS_NOW_EPOCH="${FM_TASK_PROGRESS_NOW_EPOCH:-1758240000}" \
    LAVISH_FAKE_CALLS="$home/lavish-calls" \
    "$BOARD" "$@"
}

refresh() {  # <home> [extra args]
  local home=$1
  shift
  run_board "$home" refresh --snapshot "$SNAPSHOT_FIXTURE" "$@"
}

# The board page's data block IS the published payload - the one artifact a
# publication writes - so every assertion below reads it back out of the page.
injected_payload() {  # <home>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' \
    "$1/.lavish/bearings-board.html" | sed '1d;$d'
}

# Rewrite the published page's payload through <jq-filter>, leaving the rest of
# the page byte-for-byte. This is how a test puts the board in a state a build
# would have left it in, editing the published artifact the same way it reads
# it.
set_page_payload() {  # <home> <jq-filter>
  local page="$1/.lavish/bearings-board.html" json
  json=$(injected_payload "$1" | jq -c "$2") || return 1
  json=${json//</\\u003c}
  PAGE_JSON="$json" perl -0pi -e '
    s{(<script id="bearings-data" type="application/json">\n).*?(\n</script>)}{$1$ENV{PAGE_JSON}$2}s
  ' "$page"
}

test_refresh_publishes_the_board_in_place() {
  local home out
  home=$(make_home publish)
  seed_board "$home"
  out=$(refresh "$home") || fail "refresh refused a seeded board: $out"
  assert_contains "$out" "refreshed: $home/.lavish/bearings-board.html" \
    "refresh did not name the board it republished: $out"
  injected_payload "$home" \
    | jq -e '.schema == "fm-bearings-board.v1" and (.underway | length) >= 1' >/dev/null \
    || fail "the page does not carry a board payload: $(injected_payload "$home")"
  pass "refresh injects a board payload into the page in place"
}

test_refresh_is_idempotent() {
  local home
  home=$(make_home idempotent)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "the first refresh failed"
  cp "$home/.lavish/bearings-board.html" "$home/first.html"
  refresh "$home" >/dev/null || fail "the second refresh failed"
  cmp -s "$home/first.html" "$home/.lavish/bearings-board.html" \
    || fail "a second refresh over unchanged state produced a different page"
  pass "refresh over unchanged state republishes a byte-identical page"
}

test_refresh_never_touches_the_session_or_its_armed_source() {
  local home before after
  home=$(make_home no-session)
  seed_board "$home"
  # A registered source and a bound intake, exactly as a built board leaves
  # them. Refresh must leave both records untouched and unread.
  mkdir -p "$home/state/procevent" "$home/state/decision-bindings"
  printf 'id=board\n' > "$home/state/procevent/board-source"
  printf 'origin=(any)\n' > "$home/state/decision-bindings/board-source"
  before=$(find "$home/state/procevent" "$home/state/decision-bindings" -type f \
    -exec shasum {} \; | sort)
  refresh "$home" >/dev/null || fail "refresh failed"
  after=$(find "$home/state/procevent" "$home/state/decision-bindings" -type f \
    -exec shasum {} \; | sort)
  [ "$before" = "$after" ] \
    || fail "refresh changed the source registration or the answer binding"
  [ ! -e "$home/lavish-calls" ] \
    || fail "refresh called lavish-axi: $(cat "$home/lavish-calls")"
  pass "refresh rebinds nothing, re-arms nothing, and never calls lavish-axi"
}

test_refresh_refuses_when_no_board_has_been_built() {
  local home out rc=0
  home=$(make_home unbuilt)
  set +e; out=$(refresh "$home" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "refresh invented a board for a home that never built one"
  assert_contains "$out" "no board has been built yet" \
    "the refusal did not say why: $out"
  [ ! -e "$home/.lavish/bearings-board.html" ] \
    || fail "the refused refresh created a board anyway"

  # The same refusal under the mode every fleet trigger uses: silent, exit 0,
  # and recorded where a diagnosis can find it.
  set +e; out=$(refresh "$home" --best-effort 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "best-effort refresh failed its caller: $out"
  [ -z "$out" ] || fail "best-effort refresh printed to its caller: $out"
  assert_grep "no board has been built yet" "$home/state/.bearings-board-refresh.log" \
    "the best-effort failure was not recorded"
  pass "refresh refuses an unbuilt board, and stays silent about it under --best-effort"
}

# The holder must stay ALIVE for the contention to exist at all: the refresh
# lock records its owner precisely so a lock whose owner is gone is reclaimed.
hold_refresh_lock() {  # <home> -> echoes the holder pid
  local home=$1 lock="$1/state/.bearings-board-refresh.lock" holder i=0
  mkdir -p "$home/state"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "$holder"
}

test_a_concurrent_refresh_is_a_no_op_rather_than_a_race() {
  local home out holder
  home=$(make_home concurrent)
  seed_board "$home"
  holder=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" hold_refresh_lock "$home") \
    || { echo "skip: could not hold the refresh lock in this environment"; return 0; }
  out=$(refresh "$home") || fail "a locked-out refresh failed instead of standing down"
  assert_contains "$out" "refresh: busy" "a locked-out refresh did not say it stood down: $out"
  # The seeded page still carries the template's data slot, not a payload.
  injected_payload "$home" | jq -e '.schema == "fm-bearings-board.v1"' >/dev/null 2>&1 \
    && fail "a locked-out refresh published anyway"
  # Every fleet trigger discards this stdout, so the stand-down must also be
  # readable afterwards or a board that stopped refreshing is undiagnosable.
  assert_grep "refresh: busy" "$home/state/.bearings-board-refresh.log" \
    "the stand-down left no trace a diagnosis could find"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a concurrent refresh stands down instead of racing the one under way"
}

test_a_refresh_lock_whose_owner_is_gone_is_reclaimed() {
  local home holder
  home=$(make_home stale-lock)
  seed_board "$home"
  holder=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" hold_refresh_lock "$home") \
    || { echo "skip: could not hold the refresh lock in this environment"; return 0; }
  # The refresh is spawned detached by every fleet trigger, so its process can
  # be killed by a session shutdown or a reboot with the lock still taken. The
  # board must not stop refreshing for good because of it.
  kill -9 "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ -e "$home/state/.bearings-board-refresh.lock" ] \
    || fail "the killed holder released the lock, so there is nothing to reclaim"
  refresh "$home" >/dev/null || fail "a refresh behind a dead owner's lock failed"
  injected_payload "$home" | jq -e '.schema == "fm-bearings-board.v1"' >/dev/null \
    || fail "the refresh behind a dead owner's lock published nothing"
  pass "a refresh lock left by a dead owner is reclaimed instead of wedging the board"
}

test_refresh_keeps_the_language_the_board_was_published_in() {
  local home
  home=$(make_home language)
  seed_board "$home"
  # A page with no payload yet, so the compose default is all a refresh has.
  refresh "$home" >/dev/null || fail "the first refresh failed"
  injected_payload "$home" | jq -e '.lang == "hant"' >/dev/null \
    || fail "a first refresh did not fall back to the compose default: $(injected_payload "$home")"

  # A board built for an English-reading captain. The published page is where
  # that choice lives, so a fleet event must read it back and carry it forward
  # rather than re-deciding it.
  set_page_payload "$home" '.lang = "en"' || fail "could not republish the page in English"
  refresh "$home" >/dev/null || fail "the refresh after an English build failed"
  injected_payload "$home" | jq -e '.lang == "en"' >/dev/null \
    || fail "a refresh moved the board off the captain's language: $(injected_payload "$home")"
  pass "a refresh republishes the board in the language its page was published in"
}

test_a_build_waits_for_the_publication_already_under_way() {
  local home out rc=0 holder data
  home=$(make_home build-lock)
  # A publication in flight - a fleet-triggered refresh composing right now.
  holder=$(FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" hold_refresh_lock "$home") \
    || { echo "skip: could not hold the publication lock in this environment"; return 0; }
  data="$home/payload.json"
  jq -n '{schema:"fm-bearings-board.v1", home:"build-lock", generated:"2026-09-19T00:00Z",
    prs_live:false, lang:"en", captains_call:[], underway:[], landed:[], charted:[]}' > "$data"
  set +e
  out=$(FM_BEARINGS_REFRESH_TIMEOUT=2 run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "a build published straight through a publication already under way: $out"
  assert_contains "$out" "another board publication is still under way" \
    "the build did not say what it was waiting for: $out"
  # The decisive part: it wrote nothing. A build that injected first and only
  # then discovered the contention is exactly the race this serializes.
  [ ! -e "$home/.lavish/bearings-board.html" ] \
    || fail "the build wrote the board while another publication held the lock"
  pass "a build takes the same publication lock a refresh does instead of racing it"
}

test_refresh_carries_no_placeholder_to_the_captain() {
  local home
  home=$(make_home deterministic)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "refresh failed"
  # The fixture holds two captain calls with no stored card and no packet, and
  # a merge-ready PR: every one of those is a slot a composer would have filled.
  injected_payload "$home" \
    | jq -e '[paths(type == "string" and test("\\{(FILL|TRANSLATE)"))] | length == 0' >/dev/null \
    || fail "the refreshed payload still carries composer placeholders: $(injected_payload "$home")"
  # A degraded card must ASK something. The fixture's pick-route hold carries
  # its own reason, and that reason - not the task title, which is already the
  # card's title - is the only text saying what the captain must decide.
  injected_payload "$home" | jq -e '
    (.captains_call | length) >= 2
    and ([.captains_call[] | select(.type == "merge")][0].risk == "unassessed")
    and ([.captains_call[] | select(.key == "pick-route")][0]
      | .title == "Pick the route"
        and .decide == "we must choose before the region freeze"
        and ([.options[].value] == ["reconcile"]) and .allow_freeform == true)
  ' >/dev/null \
    || fail "a card with no written copy did not degrade to an answerable one: $(injected_payload "$home")"
  # A hold whose row records no reason still gets an answerable question
  # rather than an empty one.
  injected_payload "$home" | jq -e '
    [.captains_call[] | select(.key == "gated-work")][0]
      | .decide == "Gated work item: choose the rollout order"
  ' >/dev/null \
    || fail "a hold with no recorded reason lost its fallback question: $(injected_payload "$home")"
  pass "refresh degrades unwritten copy to the hold's own question, never a placeholder"
}

test_refresh_reuses_the_stored_card_verbatim() {
  local home card
  home=$(make_home stored-card)
  seed_board "$home"
  # The copy written once, exactly as a hold or a build stores it.
  mkdir -p "$home/data/gated-work"
  jq -n '{key:"gated-work", type:"decision", repo:"firstmate",
    title:{en:"Rollout order", hant:"上線順序"},
    decide:{en:"Which rollout order ships first?", hant:"先上哪一種順序？"},
    if_nothing:{en:"the release waits", hant:"發佈會等著"},
    risk:"medium", reversible:"partly", recommend_value:"canary",
    options:[{value:"canary", label:{en:"Canary first", hant:"先金絲雀"},
              consequence:{en:"slower, safer", hant:"慢一點，安全一點"}},
             {value:"all", label:{en:"All at once", hant:"一次全上"},
              consequence:{en:"faster, riskier", hant:"快一點，風險高"}}],
    allow_freeform:true}' > "$home/data/gated-work/board-card.json"
  refresh "$home" >/dev/null || fail "refresh failed"
  card=$(injected_payload "$home" | jq -c '.captains_call[] | select(.key == "gated-work")')
  printf '%s' "$card" | jq -e '
    .title.hant == "上線順序"
    and .decide.hant == "先上哪一種順序？"
    and .risk == "medium" and .reversible == "partly"
    and .recommend_value == "canary"
    and ([.options[].value] == ["canary", "all", "reconcile"])
    and (.options[0].consequence.hant == "慢一點，安全一點")
  ' >/dev/null || fail "the stored card was not carried onto the board verbatim: $card"
  pass "a stored card round-trips onto a refreshed board without recomposition"
}

# --- the Underway progress projection ---------------------------------------
# The progress a captain reads comes from structured state alone: the current
# state bin/fm-crew-state.sh reports, and the attributed validation run's own
# step tables. A worker's terminal is never read for it.

# One of the recorded `no-mistakes axi status --run` captures, bound to this
# test's disposable repository. Only the run id, branch and head are
# substituted - the same three fields tests/fm-crew-state.test.sh substitutes;
# the steps, statuses and active-step columns stay exactly as the real CLI
# emitted them, so the projection is tested against the pipeline's own output
# rather than a hand-typed row.
captured_axi_status() {  # <capture> <branch> <run-id> <head>
  awk -v branch="$2" -v id="$3" -v head="$4" '
    /^  id:/ { print "  id: \"" id "\""; next }
    /^  branch:/ { print "  branch: " branch; next }
    /^  head:/ { print "  head: " head; next }
    /^  head_sha:/ { print "  head_sha: " head; next }
    { print }
  ' "$ROOT/tests/captures/no-mistakes-v1.70.1/$1.toon"
}

CAPTURED_RUN_ID=01M2GAWMSDQK4B5EA9GZW35RXE
# The exact bytes replacement.toon's active_steps row carries in its
# last_activity column, minus the `quiet ` prefix the projection lifts into
# its own flag.
CAPTURED_LAST_ACTIVITY="2h58m ago: log: all CI checks passed - still monitoring until merged or closed"

# A worktree on a branch, plus a no-mistakes that replays <capture> for it.
# <overview-status> is the status the run inventory reports for the row, which
# the projection checks against the run's own status class before it will use
# the ladder; it defaults to the live word the replacement capture records.
make_run_home() {  # <name> <capture> [overview-status]
  local home head short
  home=$(make_home "$1")
  mkdir -p "$home/wt"
  git -C "$home/wt" init -q
  git -C "$home/wt" checkout -q -b fm/ship-task
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  head=$(git -C "$home/wt" rev-parse HEAD)
  short=$(git -C "$home/wt" rev-parse --short=8 HEAD)
  fm_write_meta "$home/state/ship-task.meta" "worktree=$home/wt" "kind=ship" "project=firstmate"
  captured_axi_status "$2" fm/ship-task "$CAPTURED_RUN_ID" "$head" > "$home/axi-status.toon"
  cat > "$home/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1-}" = axi ] && [ "\${2-}" = status ]; then
  cat "$home/axi-status.toon"
  exit 0
fi
if [ "\${1-}" = axi ]; then
  cat <<'EOF'
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  "$CAPTURED_RUN_ID",fm/ship-task,${3:-running},$short,""
EOF
  exit 0
fi
exit 0
SH
  chmod +x "$home/fakebin/no-mistakes"
  printf '%s\n' "$home"
}

run_progress() {  # <home> <id>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROGRESS" "$@"
}

test_progress_reads_the_ladder_from_the_attributed_run() {
  local home doc
  home=$(make_run_home progress-run replacement)
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e --arg id "$CAPTURED_RUN_ID" --arg act "$CAPTURED_LAST_ACTIVITY" '
    .schema == "fm-task-progress.v1" and .id == "ship-task"
    and .state == "working" and .source == "run-step"
    and (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and (.run.id == $id) and (.run.status == "running")
    and (.run.step == "ci")
    and ([.run.steps[] | .step]
      == ["intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"])
    and ([.run.steps[] | select(.status == "skipped") | .step] == ["rebase"])
    and (.run.active_for == "4h28m")
    and (.run.last_activity == $act) and (.run.quiet == true)
    and (.run.activity == "starting")
  ' >/dev/null || fail "the projection did not read the recorded run ladder: $doc"
  pass "the progress projection reads phase, ladder, timing, and activity from structured state"
}

# An older no-mistakes CLI whose `axi` surface has no run-inventory table, so
# run selection is `unavailable` and bin/fm-crew-state.sh falls back to the
# bare `axi status` answer plus the coarse `no-mistakes runs` ledger. <status>
# is what the bare answer reports; <ledger-status> is what the newest
# same-branch ledger row reports. When those two disagree, crew-state cannot
# name the run that is actually current and says so.
make_legacy_run_home() {  # <name> <status> <ledger-status>
  local home head short outcome=''
  home=$(make_home "$1")
  mkdir -p "$home/wt"
  git -C "$home/wt" init -q
  git -C "$home/wt" checkout -q -b fm/ship-task
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  head=$(git -C "$home/wt" rev-parse HEAD)
  short=$(git -C "$home/wt" rev-parse --short=8 HEAD)
  [ "$2" = running ] || outcome="outcome: passed"
  fm_write_meta "$home/state/ship-task.meta" "worktree=$home/wt" "kind=ship" "project=firstmate"
  cat > "$home/axi-status.toon" <<EOF
run:
  id: "01LEGACY"
  branch: fm/ship-task
  status: $2
  head: $head
  head_sha: $head
  pr: ""
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,20
    review,completed,0,120
    test,completed,0,300
$outcome
EOF
  cat > "$home/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1-}" = axi ] && [ "\${2-}" = status ]; then
  cat "$home/axi-status.toon"
  exit 0
fi
if [ "\${1-}" = axi ]; then
  printf 'active run: 01LEGACY on fm/ship-task\n'
  exit 0
fi
if [ "\${1-}" = runs ]; then
  printf '$3 fm/ship-task $short 2026-09-19 09:00\n'
  exit 0
fi
exit 0
SH
  chmod +x "$home/fakebin/no-mistakes"
  printf '%s\n' "$home"
}

test_a_superseded_run_crew_state_cannot_identify_carries_no_ladder() {
  local home doc
  # The bare answer reports a finished run; the ledger reports a newer live
  # one whose id this CLI surface cannot hand over. crew-state refuses to name
  # either as current, so the board must not render the finished one's fully
  # green ladder beside that refusal.
  home=$(make_legacy_run_home progress-superseded completed running)
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '.run == null' >/dev/null \
    || fail "a run crew-state could not identify was published as the ladder: $doc"
  pass "a run superseded by one crew-state cannot name carries no ladder"
}

test_a_run_whose_records_disagree_carries_no_ladder() {
  local home doc
  # The mirror: the bare answer reports a live run while the ledger reports
  # the branch's newest run as finished. Neither record can answer for the
  # other, and an unidentified run must not become a ladder.
  home=$(make_legacy_run_home progress-disagree running completed)
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '.run == null' >/dev/null \
    || fail "a run whose records disagree was published as the ladder: $doc"
  pass "a run whose records disagree carries no ladder"
}

test_a_run_that_is_not_this_worktrees_code_carries_no_ladder() {
  local home doc
  # The recorded completed run, and then the worker moves past the commit it
  # validated - an amend or a follow-up commit. bin/fm-nm-run-lib.sh requires
  # a caller to prove branch and head, or active pipeline custody, before
  # using a run's steps; nothing here proves either any more.
  home=$(make_run_home progress-stale-head completed completed)
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m rework
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '.run == null' >/dev/null \
    || fail "a run whose head this worktree has moved past was published as its ladder: $doc"
  # The row still reports what IS established - the task's own state - so the
  # captain loses the ladder, not the row.
  printf '%s' "$doc" | jq -e '.schema == "fm-task-progress.v1" and (.state | type == "string")' \
    >/dev/null || fail "dropping the ladder cost the row its projection: $doc"
  pass "a run whose code identity is unproven carries no ladder rather than an unproven one"
}

test_progress_carries_the_pipelines_whole_last_activity_message() {
  local home doc
  # The pipeline puts the age AND the line it is reporting in one column
  # (tests/captures/no-mistakes-v1.70.1/replacement.toon). The projection lifts
  # out only the `quiet` prefix, which is already a flag of its own, and hands
  # the rest on whole rather than cutting it to a duration it never was.
  home=$(make_run_home progress-activity replacement)
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e --arg act "$CAPTURED_LAST_ACTIVITY" '
    .run.last_activity == $act
    and (.run.last_activity | startswith("quiet ") | not)
    and .run.quiet == true
  ' >/dev/null || fail "the last-activity message was cut down or kept its prefix: $doc"
  pass "the projection hands on the pipeline's whole last-activity message, quiet lifted out"
}

test_a_last_activity_carrying_quotes_and_commas_stays_one_field() {
  local home doc message encoded
  # The pipeline's last_activity column is a json.dumps-encoded log line, so
  # it can carry its own quotes and commas. Both are taken from the recorded
  # replacement capture's own row; only that one column's text changes.
  message='quiet 5m ago: log: applied "add a test, then fix"'
  home=$(make_run_home progress-quoted replacement)
  encoded=$(printf '%s' "$message" \
    | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))')
  python3 - "$home/axi-status.toon" "\"quiet $CAPTURED_LAST_ACTIVITY\"" "$encoded" <<'PY2'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); text = p.read_text()
assert sys.argv[2] in text, "the capture no longer carries the recorded last_activity field"
p.write_text(text.replace(sys.argv[2], sys.argv[3]))
PY2
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '
    .run.last_activity == "5m ago: log: applied \"add a test, then fix\""
    and .run.quiet == true
    and .run.activity == "starting"
    and .run.active_for == "4h28m"
  ' >/dev/null || fail "a quoted last-activity line was split or left escaped: $doc"
  pass "a last-activity line carrying quotes and commas stays one decoded field"
}

test_progress_reads_a_gate_that_is_waiting_on_the_captain() {
  local home doc
  home=$(make_run_home progress-parked parked)
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '
    ([.run.steps[] | select(.status == "awaiting_approval") | .step] == ["test"])
    and (.run.step == null)
    and (.run.last_activity == null) and (.run.quiet == false)
  ' >/dev/null || fail "a run parked at a gate did not read as awaiting approval: $doc"
  pass "a run parked at a captain gate reports that status rather than inventing a step"
}

test_progress_reports_no_ladder_without_an_attributable_run() {
  local home doc
  home=$(make_home progress-norun)
  fm_write_meta "$home/state/lonely.meta" "worktree=$home/missing" "kind=ship"
  doc=$(run_progress "$home" lonely) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '.run == null and .state == "unknown"' >/dev/null \
    || fail "a task with no attributable run invented one: $doc"
  pass "a task with no attributable run reports no ladder rather than a guess"
}

test_progress_never_reads_a_workers_terminal() {
  local home doc
  home=$(make_run_home progress-noterm replacement)
  # Every terminal-reading backend command fails loudly. A projection that
  # depended on scrollback would surface that failure instead of the ladder.
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'terminal read attempted: %s\n' "$*" >> "$FM_TERMINAL_READS"
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  doc=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TERMINAL_READS="$home/terminal-reads" "$PROGRESS" ship-task) \
    || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '.run.step == "ci" and .state == "working"' >/dev/null \
    || fail "the projection did not read the ladder: $doc"
  # A scrollback capture would have been recorded above; the ladder came from
  # the run tables either way.
  if [ -e "$home/terminal-reads" ]; then
    grep -q 'capture-pane' "$home/terminal-reads" \
      && fail "the projection read a worker's terminal: $(cat "$home/terminal-reads")"
  fi
  pass "the progress projection never depends on a worker's terminal"
}

test_the_board_carries_each_underway_rows_progress() {
  local home row
  home=$(make_run_home progress-board replacement)
  seed_board "$home"
  run_board "$home" refresh --snapshot "$SNAPSHOT_FIXTURE" >/dev/null \
    || fail "refresh failed"
  row=$(injected_payload "$home" | jq -c '.underway[] | select(.id == "ship-task")')
  printf '%s' "$row" | jq -e --arg act "$CAPTURED_LAST_ACTIVITY" '
    .progress.state == "working"
    and .progress.step == "ci"
    and ([.progress.steps[] | .step]
      == ["intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"])
    and .progress.active_for == "4h28m"
    and .progress.last_activity == $act
    and .progress.quiet == true
    and (.progress.refreshed | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
  ' >/dev/null || fail "the Underway row does not carry its progress: $row"
  pass "an Underway row carries the step it is on, the steps it passed, and when it was read"
}

test_a_stored_card_carrying_the_injected_reconcile_choice_still_builds() {
  local home card
  home=$(make_home stored-reconcile)
  seed_board "$home"
  # The hazard: the reconcile choice is injected per publication, and the
  # validator refuses a card that already carries it, so a card stored FROM a
  # published payload would refuse every later board. A stored card is used
  # without it, whatever it happens to carry.
  mkdir -p "$home/data/gated-work"
  jq -n '{key:"gated-work", type:"decision", repo:"firstmate",
    title:{en:"Rollout order", hant:"上線順序"},
    options:[{value:"canary", label:{en:"Canary first", hant:"先金絲雀"}},
             {value:"reconcile", label:{en:"Reconcile", hant:"重新核對"}}],
    allow_freeform:true}' > "$home/data/gated-work/board-card.json"
  refresh "$home" >/dev/null || fail "a stored card carrying reconcile refused the board"
  card=$(injected_payload "$home" | jq -c '.captains_call[] | select(.key == "gated-work")')
  printf '%s' "$card" | jq -e '[.options[].value] == ["canary", "reconcile"]' >/dev/null \
    || fail "the reconcile choice was duplicated or lost: $card"
  pass "a stored card carrying the injected reconcile choice still publishes exactly one"
}

test_refresh_states_only_the_omission_total_the_snapshot_establishes() {
  local home row
  home=$(make_home omitted-count)
  seed_board "$home"
  # The snapshot reports ONE omitted-gates total and never says how many of
  # those rows were queued work and how many were repair notices. A refresh has
  # no composer to divide it, and splitting it itself would assert a count the
  # evidence does not support - in the harmful direction, since under-reporting
  # a repair notice hides a repair.
  jq '.omitted = [{surface: "gates showing 4 of 9", reveal: "--all-gates"}]' \
    "$SNAPSHOT_FIXTURE" > "$home/snapshot.json"
  run_board "$home" refresh --snapshot "$home/snapshot.json" >/dev/null \
    || fail "refresh failed on a snapshot that omitted gate rows"
  injected_payload "$home" \
    | jq -e '(has("charted_more") | not) and (has("charted_warning_more") | not)' >/dev/null \
    || fail "refresh split an omitted total the snapshot never split: $(injected_payload "$home")"
  row=$(injected_payload "$home" | jq -c '.charted[] | select(.id == "charted-omitted")')
  [ -n "$row" ] || fail "refresh hid the omission instead of stating it: $(injected_payload "$home")"
  printf '%s' "$row" | jq -e '
    .kind == "warning" and .dispatchable == false
    and (.title | tostring | test("5 more"))
  ' >/dev/null || fail "the omission row did not state the one total the snapshot gives: $row"
  pass "refresh states the omitted total the snapshot establishes and splits nothing it does not"
}

test_a_malformed_stored_card_degrades_one_row_instead_of_the_board() {
  local home card
  home=$(make_home stored-malformed)
  seed_board "$home"
  # Durable state written by an earlier session. Anything the payload validator
  # would refuse must cost this ONE row, never the whole board.
  mkdir -p "$home/data/gated-work"
  jq -n '{key:"gated-work", type:"decision", repo:"firstmate", title:"",
    options:[{value:"bad value with spaces", label:"x"}], allow_freeform:true}' \
    > "$home/data/gated-work/board-card.json"
  refresh "$home" >/dev/null || fail "a malformed stored card refused the whole board"
  card=$(injected_payload "$home" | jq -c '.captains_call[] | select(.key == "gated-work")')
  [ -n "$card" ] || fail "the malformed stored card dropped its captain call entirely: $(injected_payload "$home")"
  printf '%s' "$card" | jq -e '(.title | tostring | length) > 0' >/dev/null \
    || fail "the degraded card carried the malformed title through: $card"
  pass "a malformed stored card degrades its own row instead of refusing the board"
}

# --- the fleet triggers ------------------------------------------------------
# The board rides the same events as the home summary. The watcher is the one
# trigger whose delivery is not obvious from the call site, so it is exercised
# for real: a real watcher, a real status append, and the board republished
# within its cadence.

test_a_watcher_observed_status_change_republishes_the_board() {
  local home watch_pid i=0 before
  home=$(make_home watcher-trigger)
  seed_board "$home"
  # The watcher reads the recorded endpoint every poll; a fixture pane keeps
  # that read off the host's real terminal multiplexer.
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/tmux"
  fm_write_meta "$home/state/ledger-task.meta" "worktree=$home" "kind=ship" "project=firstmate"
  : > "$home/state/ledger-task.status"
  refresh "$home" >/dev/null || fail "the initial refresh failed"
  before=$(injected_payload "$home" | jq -r .generated)
  # Force the next publication to differ, so republication is observable
  # without depending on clock resolution.
  set_page_payload "$home" '.generated = "1970-01-01T00:00:00Z"' \
    || fail "could not stamp the published page"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    LAVISH_FAKE_CALLS="$home/lavish-calls" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  watch_pid=$!
  while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -e "$home/state/.last-watcher-beat" ]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    echo "skip: the watcher did not start in this environment: $(cat "$home/watch.err" 2>/dev/null)"
    return 0
  fi
  printf 'blocked [key=fixture]: waiting on the fixture\n' >> "$home/state/ledger-task.status"
  i=0
  while [ "$i" -lt 300 ]; do
    [ "$(injected_payload "$home" | jq -r .generated 2>/dev/null)" = "1970-01-01T00:00:00Z" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  [ "$(injected_payload "$home" | jq -r .generated 2>/dev/null)" != "1970-01-01T00:00:00Z" ] \
    || fail "a status change did not republish the board within the watcher cadence"
  [ -n "$before" ] || fail "the initial publication recorded no generation"
  [ ! -e "$home/lavish-calls" ] \
    || fail "the watcher-carried refresh called lavish-axi: $(cat "$home/lavish-calls")"
  pass "a watcher-observed status change republishes the board without touching its session"
}

test_refresh_publishes_the_board_in_place
test_refresh_is_idempotent
test_a_stored_card_carrying_the_injected_reconcile_choice_still_builds
test_refresh_never_touches_the_session_or_its_armed_source
test_refresh_refuses_when_no_board_has_been_built
test_a_concurrent_refresh_is_a_no_op_rather_than_a_race
test_a_refresh_lock_whose_owner_is_gone_is_reclaimed
test_refresh_keeps_the_language_the_board_was_published_in
test_a_build_waits_for_the_publication_already_under_way
test_refresh_carries_no_placeholder_to_the_captain
test_refresh_reuses_the_stored_card_verbatim
test_refresh_states_only_the_omission_total_the_snapshot_establishes
test_a_malformed_stored_card_degrades_one_row_instead_of_the_board
test_progress_reads_the_ladder_from_the_attributed_run
test_progress_carries_the_pipelines_whole_last_activity_message
test_a_last_activity_carrying_quotes_and_commas_stays_one_field
test_a_run_that_is_not_this_worktrees_code_carries_no_ladder
test_a_superseded_run_crew_state_cannot_identify_carries_no_ladder
test_a_run_whose_records_disagree_carries_no_ladder
test_progress_reads_a_gate_that_is_waiting_on_the_captain
test_progress_reports_no_ladder_without_an_attributable_run
test_progress_never_reads_a_workers_terminal
test_the_board_carries_each_underway_rows_progress
test_a_watcher_observed_status_change_republishes_the_board
