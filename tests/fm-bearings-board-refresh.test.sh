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

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    LAVISH_FAKE_CALLS="$home/lavish-calls" \
    "$BOARD" "$@"
}

refresh() {  # <home> [extra args]
  local home=$1
  shift
  run_board "$home" refresh --snapshot "$SNAPSHOT_FIXTURE" --no-progress "$@"
}

payload_of() {  # <home>
  cat "$1/.lavish/bearings-board.json"
}

# What the built page actually carries, read back out of the page rather than
# from the sidecar, so injection is proved rather than assumed.
injected_payload() {  # <home>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' \
    "$1/.lavish/bearings-board.html" | sed '1d;$d'
}

test_refresh_publishes_the_board_and_a_payload_beside_it() {
  local home out
  home=$(make_home publish)
  seed_board "$home"
  out=$(refresh "$home") || fail "refresh refused a seeded board: $out"
  assert_contains "$out" "refreshed: $home/.lavish/bearings-board.html" \
    "refresh did not name the board it republished: $out"
  assert_contains "$out" "payload: $home/.lavish/bearings-board.json" \
    "refresh did not name the payload it wrote: $out"
  [ "$(run_board "$home" payload-path)" = "$home/.lavish/bearings-board.json" ] \
    || fail "payload-path does not print the stable payload location"
  jq -e '.schema == "fm-bearings-board.v1" and (.underway | length) >= 1' \
    "$home/.lavish/bearings-board.json" >/dev/null \
    || fail "the payload file is not a board payload: $(payload_of "$home")"
  # The page and the file beside it are the same payload, so a remote consumer
  # reads exactly what the local page shows.
  diff <(injected_payload "$home" | jq -S .) <(payload_of "$home" | jq -S .) >/dev/null \
    || fail "the payload file and the injected page payload differ"
  pass "refresh injects the board in place and publishes the same payload beside it"
}

test_refresh_is_idempotent() {
  local home first second
  home=$(make_home idempotent)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "the first refresh failed"
  first="$home/first.json"
  cp "$home/.lavish/bearings-board.json" "$first"
  cp "$home/.lavish/bearings-board.html" "$home/first.html"
  refresh "$home" >/dev/null || fail "the second refresh failed"
  second="$home/.lavish/bearings-board.json"
  cmp -s "$first" "$second" \
    || fail "a second refresh over unchanged state produced a different payload"
  cmp -s "$home/first.html" "$home/.lavish/bearings-board.html" \
    || fail "a second refresh over unchanged state produced a different page"
  pass "refresh over unchanged state republishes byte-identical output"
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

test_a_concurrent_refresh_is_a_no_op_rather_than_a_race() {
  local home out
  home=$(make_home concurrent)
  seed_board "$home"
  mkdir -p "$home/state/.bearings-board-refresh.lock"
  out=$(refresh "$home") || fail "a locked-out refresh failed instead of standing down"
  assert_contains "$out" "refresh: busy" "a locked-out refresh did not say it stood down: $out"
  [ ! -e "$home/.lavish/bearings-board.json" ] \
    || fail "a locked-out refresh published anyway"
  rmdir "$home/state/.bearings-board-refresh.lock"
  refresh "$home" >/dev/null || fail "refresh failed once the lock cleared"
  pass "a concurrent refresh stands down instead of racing the one under way"
}

test_refresh_carries_no_placeholder_to_the_captain() {
  local home
  home=$(make_home deterministic)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "refresh failed"
  # The fixture holds two captain calls with no stored card and no packet, and
  # a merge-ready PR: every one of those is a slot a composer would have filled.
  jq -e '[paths(type == "string" and test("\\{(FILL|TRANSLATE)"))] | length == 0' \
    "$home/.lavish/bearings-board.json" >/dev/null \
    || fail "the refreshed payload still carries composer placeholders: $(payload_of "$home")"
  jq -e '
    (.captains_call | length) >= 2
    and ([.captains_call[] | select(.type == "decision")] | length) >= 1
    and ([.captains_call[] | select(.type == "merge")][0].risk == "unassessed")
    and ([.captains_call[] | select(.type == "decision")][0]
      | (.title | type == "string") and (.decide | type == "string")
        and ([.options[].value] == ["reconcile"]) and .allow_freeform == true)
  ' "$home/.lavish/bearings-board.json" >/dev/null \
    || fail "a card with no written copy did not degrade to an answerable one: $(payload_of "$home")"
  pass "refresh degrades unwritten copy instead of publishing a placeholder"
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
  card=$(jq -c '.captains_call[] | select(.key == "gated-work")' \
    "$home/.lavish/bearings-board.json")
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

# A worktree on a branch, plus a no-mistakes whose overview and run status are
# the exact TOON shapes the real CLI emits.
make_run_home() {  # <name> <status> <step-table> <active-table>
  local home head short
  home=$(make_home "$1")
  mkdir -p "$home/wt"
  git -C "$home/wt" init -q
  git -C "$home/wt" checkout -q -b fm/ship-task
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  head=$(git -C "$home/wt" rev-parse HEAD)
  short=$(git -C "$home/wt" rev-parse --short=8 HEAD)
  fm_write_meta "$home/state/ship-task.meta" "worktree=$home/wt" "kind=ship" "project=firstmate"
  cat > "$home/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1-}" = axi ] && [ "\${2-}" = status ]; then
  cat <<'EOF'
run:
  id: "01RUN"
  branch: fm/ship-task
  status: $2
  head: "$head"
  pr: ""
  findings: none
$3
$4
EOF
  exit 0
fi
if [ "\${1-}" = axi ]; then
  cat <<'EOF'
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  "01RUN",fm/ship-task,running,$short,""
EOF
  exit 0
fi
exit 0
SH
  chmod +x "$home/fakebin/no-mistakes"
  printf '%s\n' "$home"
}

STEPS_TABLE='  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,120
    review,fixing,2,50000
    test,pending,0,0'
ACTIVE_TABLE='  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,12m3s,"quiet 31m2s",44121,"auto-fix 1/3"'

run_progress() {  # <home> <id>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROGRESS" "$@"
}

test_progress_reads_the_ladder_from_the_attributed_run() {
  local home doc
  home=$(make_run_home progress-run fixing "$STEPS_TABLE" "$ACTIVE_TABLE")
  doc=$(run_progress "$home" ship-task) || fail "the progress read failed"
  printf '%s' "$doc" | jq -e '
    .schema == "fm-task-progress.v1" and .id == "ship-task"
    and .state == "working" and .source == "run-step"
    and (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and (.run.id == "01RUN") and (.run.status == "fixing")
    and (.run.step == "review")
    and ([.run.steps[] | .step] == ["intent", "review", "test"])
    and ([.run.steps[] | select(.status == "completed") | .step] == ["intent"])
    and (.run.active_for == "12m3s")
    and (.run.last_activity == "31m2s") and (.run.quiet == true)
    and (.run.activity == "auto-fix 1/3")
  ' >/dev/null || fail "the projection did not read the run ladder: $doc"
  pass "the progress projection reads phase, ladder, timing, and activity from structured state"
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
  home=$(make_run_home progress-noterm fixing "$STEPS_TABLE" "$ACTIVE_TABLE")
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
  printf '%s' "$doc" | jq -e '.run.step == "review" and .state == "working"' >/dev/null \
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
  home=$(make_run_home progress-board fixing "$STEPS_TABLE" "$ACTIVE_TABLE")
  seed_board "$home"
  run_board "$home" refresh --snapshot "$SNAPSHOT_FIXTURE" >/dev/null \
    || fail "refresh failed"
  row=$(jq -c '.underway[] | select(.id == "ship-task")' "$home/.lavish/bearings-board.json")
  printf '%s' "$row" | jq -e '
    .progress.state == "working"
    and .progress.step == "review"
    and ([.progress.steps[] | .step] == ["intent", "review", "test"])
    and .progress.active_for == "12m3s"
    and .progress.last_activity == "31m2s"
    and .progress.quiet == true
    and (.progress.refreshed | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
  ' >/dev/null || fail "the Underway row does not carry its progress: $row"
  pass "an Underway row carries the step it is on, the steps it passed, and when it was read"
}

test_a_progress_map_is_used_as_given() {
  local home row
  home=$(make_home progress-map)
  seed_board "$home"
  jq -n '{"ship-task": {state:"parked", detail:"parked at review: 2 finding(s)",
    step:"review", steps:[{step:"intent",status:"completed"},{step:"review",status:"running"}],
    active_for:"3m", last_activity:"9s", quiet:false, activity:null,
    refreshed:"2026-09-19T00:00:00Z"}}' > "$home/progress.json"
  run_board "$home" refresh --snapshot "$SNAPSHOT_FIXTURE" \
    --progress-map "$home/progress.json" >/dev/null || fail "refresh failed"
  row=$(jq -c '.underway[] | select(.id == "ship-task") | .progress' \
    "$home/.lavish/bearings-board.json")
  printf '%s' "$row" | jq -e '.state == "parked" and .refreshed == "2026-09-19T00:00:00Z"' \
    >/dev/null || fail "the supplied progress map was not used: $row"
  pass "a supplied progress map reaches the board unchanged"
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
  card=$(jq -c '.captains_call[] | select(.key == "gated-work")' \
    "$home/.lavish/bearings-board.json")
  printf '%s' "$card" | jq -e '[.options[].value] == ["canary", "reconcile"]' >/dev/null \
    || fail "the reconcile choice was duplicated or lost: $card"
  pass "a stored card carrying the injected reconcile choice still publishes exactly one"
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
  before=$(jq -r .generated "$home/.lavish/bearings-board.json")
  # Force the next publication to differ, so republication is observable
  # without depending on clock resolution.
  jq '.generated = "1970-01-01T00:00:00Z"' "$home/.lavish/bearings-board.json" \
    > "$home/.lavish/bearings-board.json.tmp" \
    && mv "$home/.lavish/bearings-board.json.tmp" "$home/.lavish/bearings-board.json"

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
    [ "$(jq -r .generated "$home/.lavish/bearings-board.json" 2>/dev/null)" = "1970-01-01T00:00:00Z" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  [ "$(jq -r .generated "$home/.lavish/bearings-board.json" 2>/dev/null)" != "1970-01-01T00:00:00Z" ] \
    || fail "a status change did not republish the board within the watcher cadence"
  [ -n "$before" ] || fail "the initial publication recorded no generation"
  [ ! -e "$home/lavish-calls" ] \
    || fail "the watcher-carried refresh called lavish-axi: $(cat "$home/lavish-calls")"
  pass "a watcher-observed status change republishes the board without touching its session"
}

test_refresh_publishes_the_board_and_a_payload_beside_it
test_refresh_is_idempotent
test_a_stored_card_carrying_the_injected_reconcile_choice_still_builds
test_refresh_never_touches_the_session_or_its_armed_source
test_refresh_refuses_when_no_board_has_been_built
test_a_concurrent_refresh_is_a_no_op_rather_than_a_race
test_refresh_carries_no_placeholder_to_the_captain
test_refresh_reuses_the_stored_card_verbatim
test_progress_reads_the_ladder_from_the_attributed_run
test_progress_reports_no_ladder_without_an_attributable_run
test_progress_never_reads_a_workers_terminal
test_the_board_carries_each_underway_rows_progress
test_a_progress_map_is_used_as_given
test_a_watcher_observed_status_change_republishes_the_board
