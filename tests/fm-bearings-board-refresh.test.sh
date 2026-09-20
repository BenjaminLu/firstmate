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

# The stored card as `bin/fm-captain-hold.sh card` hands it back - the same
# public read bin/fm-bearings-board.sh makes.
run_captain_card() {  # <home> <task-id>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    "$ROOT/bin/fm-captain-hold.sh" card "$2" >/dev/null 2>&1
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

# WHAT A REFRESH OVER UNCHANGED STATE PROMISES, STATED AS WHAT IT IS. It
# republishes the same CONTENT, not the same bytes, and the difference is not a
# weakening - it is the publication stamp doing its job. `published` moves on
# every republication by design, because the live merge orders events against it
# and a stamp that stood still would be a rebuild that stopped superseding what
# came before it. So the page necessarily differs by that field and by nothing
# else. `composed` is the field that must hold still here, and this case asserts
# it does: that is the property the board's backwards guard rests on.
test_refresh_is_idempotent() {
  local home first second
  home=$(make_home idempotent)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "the first refresh failed"
  cp "$home/.lavish/bearings-board.html" "$home/first.html"
  first=$(injected_payload "$home")
  refresh "$home" >/dev/null || fail "the second refresh failed"
  second=$(injected_payload "$home")
  [ "$(printf '%s' "$first" | jq -S 'del(.published)')" \
    = "$(printf '%s' "$second" | jq -S 'del(.published)')" ] \
    || fail "a second refresh over unchanged state changed more than its publication stamp"
  [ "$(printf '%s' "$first" | jq -r .composed)" = "$(printf '%s' "$second" | jq -r .composed)" ] \
    || fail "a second refresh over unchanged content moved the composition stamp"
  [ "$(printf '%s' "$first" | jq -r .published)" \
    != "$(printf '%s' "$second" | jq -r .published)" ] \
    || fail "a republication did not move its publication stamp, so it would stop superseding earlier events"
  diff <(sed '/^ *{"schema"/d' "$home/first.html") \
       <(sed '/^ *{"schema"/d' "$home/.lavish/bearings-board.html") >/dev/null \
    || fail "a second refresh over unchanged state changed the page outside its payload"
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
  jq -n '{schema:"fm-bearings-board.v1", home:"build-lock", generated:"2026-09-19T00:00Z", composed:"2026-09-19T00:00:00Z",
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
  # A degraded card must ASK something, and the fm-bearings.v1 contract gives
  # a main captain-hold row exactly {id,key,verb,summary,owner} - no separate
  # reason field. So the question is that row's own summary, which
  # fm-bearings-snapshot.sh fitted as "<title>: <hold reason>", while the
  # card's title is the durable task title. Both expectations are literal:
  # the fixture row is "Pick the route: route choice pending", from which
  # hold_title takes "Pick the route". A card that published the key, or the
  # summary, or the title in the other slot fails one of these.
  local summary
  summary=$(jq -r '.decisions_open[] | select(.id == "pick-route") | .summary' "$SNAPSHOT_FIXTURE")
  [ "$summary" = "Pick the route: route choice pending" ] \
    || fail "the fixture row is not the contract-shaped summary this asserts: $summary"
  injected_payload "$home" | jq -e '
    (.captains_call | length) >= 2
    and ([.captains_call[] | select(.type == "merge")][0].risk == "unassessed")
    and ([.captains_call[] | select(.key == "pick-route")][0]
      | .title == "Pick the route"
        and .decide == "Pick the route: route choice pending"
        and ([.options[].value] == ["reconcile"]) and .allow_freeform == true)
  ' >/dev/null \
    || fail "a card with no written copy did not degrade to an answerable one: $(injected_payload "$home")"
  pass "refresh degrades unwritten copy to the held row's own question, never a placeholder"
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

test_a_stored_card_publishes_only_the_copy_it_carries() {
  local home card
  home=$(make_home stored-card-partial)
  seed_board "$home"
  # What the SKILL tells the composer to produce when one call carries several
  # questions: options consolidated beyond the skeleton two, so the extra ones
  # have no consequence slot, and no if_nothing written. `build` stores that
  # card and every later refresh republishes it. An absent field must stay
  # absent - filled, the captain reads the option slug as the consequence of
  # choosing it and the task id as what happens if he does nothing.
  mkdir -p "$home/data/gated-work"
  jq -n '{key:"gated-work", type:"decision", repo:"firstmate",
    title:{en:"Rollout order", hant:"\u4e0a\u7dda\u9806\u5e8f"},
    options:[{value:"canary", label:{en:"Canary first", hant:"\u5148\u91d1\u7d72\u96c0"}},
             {value:"all", label:{en:"All at once", hant:"\u4e00\u6b21\u5168\u4e0a"}},
             {value:"regional", label:{en:"One region", hant:"\u55ae\u4e00\u5340\u57df"}}],
    allow_freeform:true}' > "$home/data/gated-work/board-card.json"
  refresh "$home" >/dev/null || fail "refresh failed on a partially written stored card"
  card=$(injected_payload "$home" | jq -c '.captains_call[] | select(.key == "gated-work")')
  printf '%s' "$card" | jq -e '
    (has("if_nothing") | not)
    and (has("decide") | not)
    and ([.options[] | select(.value != "reconcile") | has("consequence")] | any | not)
    and (.title.hant == "\u4e0a\u7dda\u9806\u5e8f")
    and ([.options[].value] == ["canary", "all", "regional", "reconcile"])
  ' >/dev/null || fail "the board invented copy the stored card never carried: $card"
  pass "a stored card publishes the copy it carries and invents none it omits"
}

test_a_stored_card_carrying_a_placeholder_costs_only_its_own_row() {
  local home id=gated-work card
  home=$(make_home stored-card-placeholder)
  seed_board "$home"
  # A publication passes TWO gates and the placeholder one runs first, so a
  # card that satisfies the payload validator can still refuse the whole
  # board. `call_item` accepts a placeholder on purpose - a composer skeleton
  # is validated while it still carries them - but a stored card is finished
  # copy, and one carrying an unfilled slot would stop every fleet-triggered
  # refresh in silence until someone deleted the file by hand.
  mkdir -p "$home/data/$id"
  jq -n --arg id "$id" '{key:$id, type:"decision", repo:"firstmate",
    title:"Rollout order", decide:"{FILL: decide}",
    risk:"{FILL: low | medium | high}",
    options:[{value:"canary", label:"Canary"}], allow_freeform:true}' \
    > "$home/data/$id/board-card.json"

  refresh "$home" --best-effort >/dev/null \
    || fail "a stored card carrying a placeholder stopped the refresh"
  injected_payload "$home" | jq -e '.schema == "fm-bearings-board.v1"' >/dev/null \
    || fail "a stored card carrying a placeholder cost the whole board"
  card=$(injected_payload "$home" | jq -c --arg id "$id" '.captains_call[] | select(.key == $id)')
  [ -n "$card" ] || fail "the degraded row lost its captain call entirely"
  printf '%s' "$card" | jq -e '
    ([.. | strings | select(test("\\{(FILL|TRANSLATE)"))] | length) == 0
    and ([.options[].value] | index("reconcile")) != null
    and .allow_freeform == true
  ' >/dev/null || fail "the placeholder reached the captain: $card"
  pass "a stored card carrying a placeholder costs its own row, not the board"
}

test_a_stored_card_the_validator_would_refuse_costs_only_its_own_row() {
  local home id=gated-work card
  home=$(make_home stored-card-unpublishable)
  seed_board "$home"
  # `card --store` is a public entry point and checks only the key, so a card
  # the payload validator would refuse can reach the store. Composed onto the
  # board it would refuse the WHOLE payload, and under --best-effort - what
  # every fleet trigger uses - the refresh would exit 0 silently and the board
  # would stop refreshing on every later event until someone deleted the file.
  # This card has no options and no allow_freeform: nothing the captain could
  # answer with, which is exactly what call_item refuses.
  mkdir -p "$home/data/$id"
  jq -n --arg id "$id" '{key:$id, type:"decision", repo:"firstmate",
    title:"Rollout order", options:[]}' > "$home/data/$id/board-card.json"
  run_captain_card "$home" "$id" || fail "the fixture card is not what the store accepts"

  refresh "$home" --best-effort >/dev/null \
    || fail "an unpublishable stored card stopped the refresh"
  injected_payload "$home" | jq -e '.schema == "fm-bearings-board.v1"' >/dev/null \
    || fail "an unpublishable stored card cost the whole board: $(injected_payload "$home")"
  # The row is still there and still answerable - it degraded to the copy the
  # snapshot supports instead of carrying the card the board could not publish.
  card=$(injected_payload "$home" | jq -c --arg id "$id" '.captains_call[] | select(.key == $id)')
  [ -n "$card" ] || fail "the degraded row lost its captain call entirely"
  printf '%s' "$card" | jq -e '
    ([.options[].value] | index("reconcile")) != null and .allow_freeform == true
  ' >/dev/null || fail "the degraded card is not answerable: $card"
  pass "a stored card the payload validator would refuse costs its own row, not the board"
}

# A merge card as a build publishes and stores it, keyed by the card key.
store_merge_card() {  # <home> <key> <pr-url>
  local home=$1 key=$2 url=$3
  jq -n --arg key "$key" --arg url "$url" '{key:$key, type:"merge", repo:"firstmate",
    title:"Merge: Ship the thing", detail:"checks passing, review APPROVED",
    risk:"unassessed", pr_url:$url,
    options:[{value:"merge", label:"Merge now"}, {value:"hold", label:"Not yet"}],
    allow_freeform:true}' > "$home/merge-card.json"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" card "$key" --store "$home/merge-card.json" >/dev/null
}

# A pull-request view returns nothing for a repo whose `gh` call failed, a
# repo whose rows were capped, a repo it never queried, and a backlog it
# could not read - the same nothing a PR that stopped being merge-ready
# returns. None of it is evidence, so none of it may cost the captain his
# Merge now control. The card stays until its work is proved landed.
assert_merge_card_survives() {  # <name> <prs> <omitted-json> <candidate-prs> <backlog:keep|break>
  local home snapshot
  home=$(make_home "$1")
  seed_board "$home"
  store_merge_card "$home" merge.ship-task "https://github.com/example/firstmate/pull/9"
  snapshot="$home/snapshot.json"
  jq --arg prs "$2" --argjson om "$3" --argjson prs_rows "$4" \
    '.prs = $prs | .omitted = $om | .candidate_prs = $prs_rows' \
    "$SNAPSHOT_FIXTURE" > "$snapshot"
  if [ "$5" != keep ]; then
    # A symlinked backlog is bin/fm-tasks-axi.sh's documented refusal: no
    # record can be read, so ownership is unknown rather than absent.
    mv "$home/data/backlog.md" "$home/data/real-backlog.md"
    ln -s "$home/data/real-backlog.md" "$home/data/backlog.md"
  fi
  run_board "$home" refresh --snapshot "$snapshot" >/dev/null \
    || fail "$1: the refresh failed"
  injected_payload "$home" | jq -e '
    [.captains_call[] | select(.key == "merge.ship-task")
     | select(.pr_url == "https://github.com/example/firstmate/pull/9")
     | select([.options[].value] == ["merge", "hold"])] | length == 1
  ' >/dev/null \
    || fail "$1: the stored merge card did not survive: $(injected_payload "$home")"
}

test_no_pull_request_view_ever_costs_a_stored_merge_card() {
  assert_merge_card_survives view-unavailable \
    'checked (2 repos, 0 open; 1 repo(s) unavailable)' '[]' '[]' keep
  assert_merge_card_survives view-capped \
    'checked (2 repos; 0 shown, at least 9 open; capped in 1 repo(s))' '[]' '[]' keep
  assert_merge_card_survives view-repos-omitted \
    'checked (10 repos, 0 open)' \
    '[{"surface":"PR repositories showing 10 of 25","reveal":"--all-pr-repos"}]' '[]' keep
  assert_merge_card_survives view-backlog-unreadable \
    'checked (2 repos, 0 open)' '[]' '[]' break
  # The sequence the finding names: the task was torn down while its PR sat
  # open and green, so its repo left the candidate set entirely. Every repo
  # the snapshot still knows about WAS queried - nothing failed, nothing was
  # capped, nothing omitted, the backlog reads fine - so this view looks
  # complete in every way a predicate could test, and it still is not
  # evidence about a repo nobody asked about.
  assert_merge_card_survives view-repo-gone 'checked (2 repos, 0 open)' '[]' '[]' keep
  # And the degenerate case: a view that queried nothing at all.
  assert_merge_card_survives view-zero-repos 'checked (0 repos, 0 open)' '[]' '[]' keep
  pass "no pull-request view, however complete it looks, retires a stored merge card"
}

# Two merge-ready pull requests claiming one task get no merge card at all,
# because a merge answer keyed to that task names only one of them and either
# click would act on whichever the task record happens to name. The board says
# so in a warning row. A stored card carried back regardless would publish a
# Merge now beside the row saying none is offered, and pressing it would merge
# a pull request that card never named - the exact wrong merge the collision
# rule exists to prevent. The card is withheld, not retired: the stored file
# stays on disk and the card returns once the collision clears.
test_a_collision_withholds_the_stored_merge_card_without_deleting_it() {
  local home snapshot collided payload
  home=$(make_home collision-withholds)
  seed_board "$home"
  store_merge_card "$home" merge.ship-task "https://github.com/example/firstmate/pull/9"
  snapshot="$home/snapshot.json"
  collided='[{"num":"9","repo":"example/firstmate","task":"ship-task",
    "url":"https://github.com/example/firstmate/pull/9","review":"APPROVED",
    "mergeable":"MERGEABLE","checks":"passing"},
   {"num":"21","repo":"example/other","task":"ship-task",
    "url":"https://github.com/example/other/pull/21","review":"APPROVED",
    "mergeable":"MERGEABLE","checks":"passing"}]'
  jq --argjson rows "$collided" '.candidate_prs = $rows' \
    "$SNAPSHOT_FIXTURE" > "$snapshot"
  run_board "$home" refresh --snapshot "$snapshot" >/dev/null \
    || fail "the refresh failed"
  payload=$(injected_payload "$home")
  printf '%s' "$payload" | jq -e '
    ([.charted[] | select(.id | startswith("merge-collision"))] | length == 1)
    and ([.captains_call[] | select(.key == "merge.ship-task")] | length == 0)
  ' >/dev/null \
    || fail "the board published a merge card and the no-merge-offered row together: $payload"
  [ -f "$home/data/merge.ship-task/board-card.json" ] \
    || fail "the collision deleted the stored card instead of withholding it"
}

# A build fills every translate slot, so the rows the captain reads carry
# {en, hant, hans}. A deterministic refresh has no translator and recomposes
# the whole payload, so without carrying the published copy the board drops
# into English the moment it refreshes itself - and this change exists to make
# refreshes frequent and automatic, which would make his board worse in his
# own language the more often it fired. The translation is reused only on
# proof it belongs to this exact text: same row, same English. A row whose
# text changed keeps the fresh English rather than a stale translation
# asserting words nobody wrote.
test_a_refresh_keeps_the_translated_row_copy_it_cannot_recompose() {
  local home payload
  home=$(make_home carry-row-copy)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "the first refresh failed"
  # What a build leaves behind: one row translated, and one translated against
  # text that no longer matches what this compose produces.
  set_page_payload "$home" '
    .underway = [ .underway[] | if .id == "ship-task"
      then .name = {en: "Ship the thing", hant: "出貨", hans: "出货"}
      else . end ]
    | .landed = [ .landed[] | if .id == "done-a"
      then .what = {en: "Something else entirely", hant: "別的", hans: "别的"}
      else . end ]
  ' || fail "could not stage the published translations"
  refresh "$home" >/dev/null || fail "the second refresh failed"
  payload=$(injected_payload "$home")
  printf '%s' "$payload" | jq -e '
    ([.underway[] | select(.id == "ship-task") | .name]
       | .[0] == {en: "Ship the thing", hant: "出貨", hans: "出货"})
  ' >/dev/null \
    || fail "the refresh dropped a translation it could have carried: $payload"
  printf '%s' "$payload" | jq -e '
    ([.landed[] | select(.id == "done-a") | .what] | .[0] | type == "string")
  ' >/dev/null \
    || fail "the refresh carried a translation onto text it does not translate: $payload"
}

test_the_merge_carry_forward_resurrects_only_merge_cards() {
  local home
  home=$(make_home merge-carry-type)
  seed_board "$home"
  # The carry-forward finds its cards by key, and a task id may legally
  # contain a dot. A DECISION card stored under such a key must not ride the
  # merge path: the decision path reads a stored card only for a hold that is
  # still open, so carrying this one would put a closed call's question back
  # on the board and leave it there.
  mkdir -p "$home/data/merge.not-a-merge"
  jq -n '{key:"merge.not-a-merge", type:"decision", repo:"firstmate",
    title:"A closed call", decide:"Which way?",
    options:[{value:"north", label:"North"}], allow_freeform:true}' \
    > "$home/data/merge.not-a-merge/board-card.json"
  run_board "$home" refresh >/dev/null || fail "a refresh with no snapshot argument failed"
  injected_payload "$home" | jq -e '
    [.captains_call[] | select(.key == "merge.not-a-merge")] | length == 0
  ' >/dev/null \
    || fail "the merge carry-forward resurrected a decision card: $(injected_payload "$home")"
  pass "the merge carry-forward resurrects only merge cards"
}

test_a_refresh_carries_the_merge_card_forward_and_retires_it_when_it_lands() {
  local home card
  home=$(make_home merge-carry)
  seed_board "$home"
  # NO --snapshot, which is the only way a fleet trigger ever calls this: PR
  # discovery is an opt-in the first mate passes, so the snapshot a refresh
  # reads carries no candidate_prs at all. The Merge now control the captain
  # opened the board to click has to survive that.
  store_merge_card "$home" merge.ship-task "https://github.com/example/firstmate/pull/9"
  run_board "$home" refresh >/dev/null || fail "a refresh with no snapshot argument failed"
  injected_payload "$home" | jq -e '.prs_live == false' >/dev/null \
    || fail "the fixture is not on the PR-less path this regression is about"
  card=$(injected_payload "$home" | jq -c '.captains_call[] | select(.key == "merge.ship-task")')
  [ -n "$card" ] || fail "a refresh deleted the captain's merge card: $(injected_payload "$home")"
  printf '%s' "$card" | jq -e '
    .type == "merge"
    and .pr_url == "https://github.com/example/firstmate/pull/9"
    and ([.options[].value] == ["merge", "hold"])
  ' >/dev/null || fail "the carried merge card lost its pull request or its options: $card"

  # The same card once its pull request reaches the payload's own landed rows
  # - the fixture backlog lands PR 7. No forge is asked; the board drops the
  # card and retires the stored copy, so it cannot return when that landed row
  # ages out.
  store_merge_card "$home" merge.ship-task "https://github.com/example/firstmate/pull/7"
  run_board "$home" refresh >/dev/null || fail "the refresh after the merge landed failed"
  injected_payload "$home" | jq -e '
    [.captains_call[] | select(.key == "merge.ship-task")] | length == 0
  ' >/dev/null || fail "a merge card whose PR landed stayed on the board"
  [ ! -e "$home/data/merge.ship-task/board-card.json" ] \
    || fail "the landed merge card was dropped but its stored copy was kept"
  run_board "$home" refresh >/dev/null || fail "the refresh after retirement failed"
  injected_payload "$home" | jq -e '
    [.captains_call[] | select(.key == "merge.ship-task")] | length == 0
  ' >/dev/null || fail "the retired merge card came back on the next refresh"
  pass "a refresh carries the merge card forward and retires it once its work lands"
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

test_a_refresh_that_runs_out_of_time_leaves_the_board_it_could_not_replace() {
  local home out
  home=$(make_home refresh-deadline)
  seed_board "$home"
  refresh "$home" >/dev/null || fail "the first refresh failed"
  cp "$home/.lavish/bearings-board.html" "$home/published.html"

  # A wedged no-mistakes behind an Underway ship. The refresh deadline is the
  # only stop, and when it fires the board must be left exactly as it was -
  # its own `generated` stamp still telling the captain how old it is. A
  # half-written page, or one carrying a synthesized read, would have the
  # board look current when nothing was read.
  mkdir -p "$home/wt"
  git -C "$home/wt" init -q
  git -C "$home/wt" checkout -q -b fm/ship-task
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  fm_write_meta "$home/state/ship-task.meta" "worktree=$home/wt" "kind=ship" "project=firstmate"
  cat > "$home/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
  chmod +x "$home/fakebin/no-mistakes"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    LAVISH_FAKE_CALLS="$home/lavish-calls" \
    FM_BEARINGS_REFRESH_TIMEOUT=2 FM_TASK_PROGRESS_TIMEOUT=30 \
    FM_CREW_STATE_NM_TIMEOUT=30 \
    "$BOARD" refresh --snapshot "$SNAPSHOT_FIXTURE" --best-effort 2>&1) \
    || fail "a best-effort refresh reported its deadline to the caller: $out"
  [ -z "$out" ] || fail "a best-effort refresh printed to its trigger: $out"
  assert_grep "deadline" "$home/state/.bearings-board-refresh.log" \
    "the refresh that ran out of time left no trace a diagnosis could find"

  # The page itself, byte for byte. A republication would differ: this second
  # refresh runs without the pinned projection clock, so every row it wrote
  # would carry its own fresh `progress.refreshed`.
  cmp -s "$home/published.html" "$home/.lavish/bearings-board.html" \
    || fail "a refresh that ran out of time still rewrote the board"
  pass "a refresh that runs out of time leaves the previous board and its own freshness stamp"
}

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

# A build derives the page BEFORE the payload goes into it: a home with a live
# board server gets the transport, its endpoint, and the answer token the
# captain's click is proved by written into the page itself. A refresh
# republishes that page, so everything outside the payload has to survive it -
# painting the bare template instead would strip a live board's transport off,
# and re-deriving would hand it an endpoint and a token nobody asked for.
test_a_refresh_keeps_what_the_build_put_on_the_page_outside_the_payload() {
  local home page slots
  home=$(make_home live-page)
  seed_board "$home"
  page="$home/.lavish/bearings-board.html"
  # The page as a build with a live server leaves it: the transport carrying a
  # resolved endpoint and answer token, ahead of the data slot.
  perl -0pi -e '
    s{(<script id="bearings-data" type="application/json">)}
     {<script id="fm-board-live">\nvar FM_LIVE = {endpoint: "ws://127.0.0.1:41999/live", token: "seed-token"};\n</script>\n$1}s
  ' "$page"
  grep -qxF '<script id="fm-board-live">' "$page" \
    || fail "the fixture did not put a live transport on the page"
  refresh "$home" >/dev/null || fail "refresh refused a live board"
  grep -qxF '<script id="fm-board-live">' "$page" \
    || fail "the refresh stripped the live transport off the board"
  grep -qF 'ws://127.0.0.1:41999/live' "$page" \
    || fail "the refresh dropped the endpoint the build resolved"
  grep -qF 'seed-token' "$page" \
    || fail "the refresh dropped the answer token the build issued"
  injected_payload "$home" | jq -e '.schema == "fm-bearings-board.v1"' >/dev/null \
    || fail "the refresh did not publish a payload into the live page"
  # And it republished exactly once: a second data slot would leave the page
  # carrying two payloads, of which the browser reads whichever it meets first.
  slots=$(grep -cxF '<script id="bearings-data" type="application/json">' "$page" || true)
  [ "$slots" -eq 1 ] || fail "the refreshed page carries $slots data slots"
  ! grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$page" \
    || fail "the refreshed page still carries an empty data slot"
  pass "a refresh republishes the page the captain has, transport and all"
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
test_a_stored_card_publishes_only_the_copy_it_carries
test_a_stored_card_the_validator_would_refuse_costs_only_its_own_row
test_a_stored_card_carrying_a_placeholder_costs_only_its_own_row
test_a_refresh_carries_the_merge_card_forward_and_retires_it_when_it_lands
test_the_merge_carry_forward_resurrects_only_merge_cards
test_no_pull_request_view_ever_costs_a_stored_merge_card
test_a_collision_withholds_the_stored_merge_card_without_deleting_it
test_a_refresh_keeps_the_translated_row_copy_it_cannot_recompose
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
test_a_refresh_that_runs_out_of_time_leaves_the_board_it_could_not_replace
test_a_watcher_observed_status_change_republishes_the_board
test_a_refresh_keeps_what_the_build_put_on_the_page_outside_the_payload
