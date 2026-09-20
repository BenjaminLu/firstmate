#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A lavish-axi stub that reproduces the shapes verified against the real
# lavish-axi 0.1.61, because the build's liveness verdict is read from what the
# vendor emits. The load-bearing shape is the refusal: opening a session the
# captain ended from the browser EXITS 0 while reporting `status: user-ended`,
# and that session is absent from the server's listing. `--reopen` restores it.
# Markers under lavish-state drive the fixture: `user-ended` makes the next
# plain open refuse, and `refuse-reopen` makes even --reopen leave it dead.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # Registered with tests/lib.sh, not with a shell array: make_home is called
  # inside a command substitution, so an array append here never reaches the
  # caller and every listener this suite started used to survive the run.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
# Every invocation in order, so a test can assert what the build asked the
# vendor for and when. A bare listing logs as `<list>`.
printf '%s\n' "${*:-<list>}" >> "$state/calls"
emit() {  # <canonical-file> <status>
  printf 'session:\n'
  printf '  file: %s\n' "$1"
  printf '  url: "http://127.0.0.1:4387/session/deadbeef"\n'
  printf '  status: %s\n' "$2"
}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  --help)
    # Inert: help never opens, lists, or ends a session. A release that names
    # sessions advertises the flag here; the `advertise-name` marker selects it.
    printf 'help[1]: "Run `lavish-axi <html-file>` to open or resume a session"\n'
    if [ -e "$state/advertise-name" ]; then
      printf 'help[2]: "Pass `--name <slug>` to give a session a stable URL"\n'
    fi
    exit 0
    ;;
  poll)
    # A real blocking listener: it returns only when the trigger appears, so a
    # live owner in these tests is a live process rather than a timing artifact.
    # Both waits are bounded, so a listener that escapes its test cannot keep
    # spawning processes for as long as the host stays up.
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "$state/poll-trigger" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    printf 'session:\n  status: ended\n'
    if [ -e "$state/hold-after-terminal" ]; then
      : > "$state/terminal-emitted"
      while [ -e "$state/hold-after-terminal" ]; do
        [ "$SECONDS" -lt "$limit" ] || exit 75
        sleep 0.05
      done
    fi
    exit 0
    ;;
  '')
    # The marker ends the session at the next listing AFTER it was opened;
    # the build also lists before any open to probe for session-name support,
    # and that probe must not spend the marker on a session that does not
    # exist yet.
    if [ -e "$state/end-before-next-list" ] && [ -s "$state/open" ]; then
      : > "$state/open"
      rm -f "$state/end-before-next-list"
    fi
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$state/open" ]; then
      while IFS= read -r listed; do
        [ -n "$listed" ] || continue
        printf '  %s,open,"http://127.0.0.1:4387/session/deadbeef",0\n' "$listed"
      done < "$state/open"
    fi
    exit 0
    ;;
  end) : > "$state/open"; printf 'session:\n  status: ended\n'; exit 0 ;;
esac
file=$1
shift
reopen=0
for arg in "$@"; do [ "$arg" != --reopen ] || reopen=1; done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
if [ -e "$state/user-ended" ] && [ "$reopen" = 0 ]; then
  emit "$real" user-ended
  exit 0
fi
if [ -e "$state/refuse-reopen" ]; then
  emit "$real" user-ended
  exit 0
fi
rm -f -- "$state/user-ended"
printf '%s\n' "$real" > "$state/open"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

end_session_as_captain() { : > "$1/lavish-state/user-ended"; : > "$1/lavish-state/open"; }

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

# ---- the acknowledgement carrier --------------------------------------------

test_ack_records_and_clears_what_the_captain_clicked() {
  local home out record
  home=$(make_home ack-roundtrip)
  record="$home/state/board-acks/plain-queued.json"
  out=$(run_board "$home" ack plain-queued --acting) || fail "recording an acknowledgement failed: $out"
  [ "$out" = "ack: $record" ] \
    || fail "the acknowledgement was not written where its carrier says: $out"
  jq -e '.schema == "fm-board-ack.v1" and .kind == "acting" and (.at | type == "number")
    and (has("why") | not)' "$record" >/dev/null \
    || fail "the acknowledgement record is not the documented shape"
  run_board "$home" ack plain-queued --clear >/dev/null || fail "clearing the acknowledgement failed"
  [ ! -e "$record" ] || fail "a cleared acknowledgement left its record behind"
  pass "an acknowledgement is recorded and cleared under its own board key"
}

test_ack_refuses_a_refusal_with_no_reason_and_a_key_that_is_not_one() {
  local home out rc
  home=$(make_home ack-refusals)
  set +e; out=$(run_board "$home" ack plain-queued --refused 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a refusal with no reason was accepted: $out"
  printf '%s' "$out" | grep -q -- '--why-file' \
    || fail "a refusal with no reason did not name what it needs: $out"
  : > "$home/empty-why"
  set +e; out=$(run_board "$home" ack plain-queued --refused --why-file "$home/empty-why" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a refusal with an empty reason was accepted: $out"
  # The key addresses a file, so only a board routing key may be one.
  for bad in '../escape' 'has space' '.' ''; do
    set +e; out=$(run_board "$home" ack "$bad" --acting 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "'$bad' was accepted as a board key: $out"
  done
  # Every call says which of the three things it is doing to the record.
  set +e; out=$(run_board "$home" ack plain-queued 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a key with no mode was accepted: $out"
  [ ! -d "$home/state/board-acks" ] || [ -z "$(ls -A "$home/state/board-acks")" ] \
    || fail "a refused write still left a record: $(ls -A "$home/state/board-acks")"
  pass "a refusal needs a reason, and only a board routing key may address one"
}

test_compose_carries_the_refusal_to_the_row_the_captain_clicked() {
  local home skeleton
  home=$(make_compose_home compose-ack-refused)
  printf 'it is waiting on the board refresh, which is still in review\n' > "$home/why"
  run_board "$home" ack plain-queued --refused --why-file "$home/why" >/dev/null \
    || fail "recording the refusal failed"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with a recorded refusal"
  jq -e '
    (.charted[] | select(.id == "plain-queued") | .ack
      | .kind == "refused"
        and .why == "it is waiting on the board refresh, which is still in review"
        and (.at | type == "number"))
    # Only the row he clicked.
    and ([.charted[] | select(.ack != null) | .id] == ["plain-queued"])
    and ([.underway[], .captains_call[] | select(.ack != null)] | length == 0)
  ' "$skeleton" >/dev/null || fail "the refusal did not reach its row: $(cat "$skeleton")"
  pass "a recorded refusal reaches the row the captain clicked, with its reason"
}

# The two surfaces the captain clicks - and only those. A record keyed to an
# Underway row reaches nothing: he has no control on that row, so a pill there
# could only ever be the shape of an unsettled record, never an answer.
test_compose_acknowledges_a_card_and_a_charted_row_by_their_own_keys() {
  local home skeleton
  home=$(make_compose_home compose-ack-keys)
  run_board "$home" ack gated-work --acting >/dev/null || fail "recording the card acknowledgement failed"
  run_board "$home" ack plain-queued --acting >/dev/null || fail "recording the row acknowledgement failed"
  run_board "$home" ack ship-task --acting >/dev/null || fail "recording the underway acknowledgement failed"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with recorded acknowledgements"
  jq -e '
    (.captains_call[] | select(.key == "gated-work") | .ack.kind == "acting")
    and (.charted[] | select(.id == "plain-queued") | .ack.kind == "acting")
    and ([.underway[] | select(.ack != null)] | length == 0)
  ' "$skeleton" >/dev/null || fail "an acknowledgement missed its card or row: $(cat "$skeleton")"
  pass "an acknowledgement reaches a decision card and a charted row, and no underway row"
}

# Compose carries the stamp and derives nothing from it: the page is what ages
# an unanswered acknowledgement into a waiting time, because the board is only
# republished when the first mate acts, and the case the waiting report exists
# for is the one where he did not.
test_compose_carries_the_click_stamp_the_page_ages_from() {
  local home skeleton at
  home=$(make_compose_home compose-ack-stamp)
  run_board "$home" ack plain-queued --acting >/dev/null || fail "recording the acknowledgement failed"
  at=$(jq -r '.at' "$home/state/board-acks/plain-queued.json")
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with a recorded acknowledgement"
  jq -e --argjson at "$at" '.charted[] | select(.id == "plain-queued") | .ack
    | .kind == "acting" and .at == $at' "$skeleton" >/dev/null \
    || fail "the click stamp did not reach the row: $(cat "$skeleton")"
  pass "compose carries the click's own stamp to the row the page ages it on"
}

test_compose_ignores_a_malformed_acknowledgement_instead_of_losing_the_board() {
  local home skeleton
  home=$(make_compose_home compose-ack-malformed)
  mkdir -p "$home/state/board-acks"
  printf 'not json at all\n' > "$home/state/board-acks/plain-queued.json"
  printf '{"schema":"something-else","kind":"acting","at":1}\n' > "$home/state/board-acks/live-gate.json"
  printf '{"schema":"fm-board-ack.v1","kind":"sudo-merge","at":1}\n' > "$home/state/board-acks/later-call.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "a malformed side-band record cost the captain the whole board"
  jq -e '[.charted[], .underway[], .captains_call[] | select(.ack != null)] | length == 0' \
    "$skeleton" >/dev/null || fail "a malformed record reached a row: $(cat "$skeleton")"
  pass "a malformed acknowledgement record is skipped, never rendered and never fatal"
}

# A record can pass the per-record filter and still break the merge that
# collects the map - two JSON values in one carrier file is the simplest way
# there. The map must absorb that the way it absorbs a malformed record: the
# acknowledgements collected before it survive, the ones after it still land,
# and the captain keeps his board. Accumulating in place loses all of them,
# because a failed command substitution empties the accumulator before the
# guard that was meant to protect it runs, and compose then fails outright.
test_compose_survives_a_record_that_breaks_the_acknowledgement_merge() {
  local home skeleton
  home=$(make_compose_home compose-ack-unmergeable)
  run_board "$home" ack gated-work --acting >/dev/null || fail "recording the card acknowledgement failed"
  run_board "$home" ack plain-queued --acting >/dev/null || fail "recording the row acknowledgement failed"
  # Sorts between the two good records, so it is read after one and before the
  # other.
  printf '%s\n%s\n' \
    '{"schema":"fm-board-ack.v1","kind":"acting","at":1758240000}' \
    '{"schema":"fm-board-ack.v1","kind":"acting","at":1758240001}' \
    > "$home/state/board-acks/later-call.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "one unmergeable record cost the captain the whole board"
  jq -e '
    (.captains_call[] | select(.key == "gated-work") | .ack.kind == "acting")
    and (.charted[] | select(.id == "plain-queued") | .ack.kind == "acting")
  ' "$skeleton" >/dev/null \
    || fail "an unmergeable record took the other acknowledgements with it: $(cat "$skeleton")"
  pass "one unmergeable record is skipped and every other acknowledgement survives"
}

# Retirement is the handler's alone. A publication enumerates what the
# snapshot's options and caps gave it - merge cards need --include-prs, gates
# and decisions are capped - so a key missing from one skeleton says nothing
# about whether its row still exists, and a refusal the captain has not seen
# yet must outlive a board that did not happen to carry its row.
test_compose_keeps_a_record_whose_key_is_absent_from_the_skeleton() {
  local home skeleton
  home=$(make_compose_home compose-ack-absent-key)
  run_board "$home" ack merge.absent-pr --acting >/dev/null || fail "recording the acknowledgement failed"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with a recorded acknowledgement"
  jq -e '[.captains_call[].key, .charted[].id] | index("merge.absent-pr") == null' "$skeleton" >/dev/null \
    || fail "the fixture key turned out to be on this board after all: $(cat "$skeleton")"
  [ -e "$home/state/board-acks/merge.absent-pr.json" ] \
    || fail "a publication that never enumerated the key deleted its record"
  pass "a record whose key is absent from the composed skeleton survives the compose"
}

# Every malformed call on this path explains itself. A flag whose value is
# missing used to abort on the failed shift before the guard that would have
# said so, which left the first mate a bare exit 1 and no refusal recorded.
# "A refusal the captain cannot read is not a refusal" - and a reason file of
# nothing but whitespace is one, because the record strips it away and leaves
# the pill with nothing beneath it.
test_a_whitespace_only_refusal_reason_is_refused() {
  local home out rc
  home=$(make_home ack-blank-why)
  printf ' \n\t\n' > "$home/blank-why"
  set +e; out=$(run_board "$home" ack plain-queued --refused --why-file "$home/blank-why" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a reason that is only whitespace was accepted: $out"
  printf '%s' "$out" | grep -q "empty" || fail "the refusal did not say the reason was empty: $out"
  [ ! -e "$home/state/board-acks/plain-queued.json" ] \
    || fail "a refusal with no readable reason was recorded anyway"
  pass "a reason file that is only whitespace is refused and records nothing"
}

assert_flag_with_no_value_explains_itself() {
  local home=$1; shift
  local out rc
  set +e; out=$(run_board "$home" "$@" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "'$*' with no value was accepted: $out"
  [ -n "$out" ] || fail "'$*' with no value failed without saying anything"
}

test_a_flag_with_no_value_explains_itself() {
  local home
  home=$(make_home ack-flag-no-value)
  assert_flag_with_no_value_explains_itself "$home" ack somekey --refused --why-file
  assert_flag_with_no_value_explains_itself "$home" compose --lang
  assert_flag_with_no_value_explains_itself "$home" compose --out
  assert_flag_with_no_value_explains_itself "$home" compose --snapshot
  [ ! -e "$home/state/board-acks/somekey.json" ] \
    || fail "a refusal with no reason file still wrote a record"
  pass "a flag whose value is missing says so instead of exiting silently"
}

test_the_payload_contract_refuses_an_unknown_acknowledgement_kind() {
  local home data out rc
  home=$(make_home ack-validator)
  data="$home/payload.json"
  for bad in '{"kind":"sudo-merge","at":1}' '{"kind":"acting"}' '{"kind":"late","at":1}' \
    '{"kind":"acting","at":"now"}' '{"kind":"acting","at":1,"why":""}' '"acting"'; do
    write_valid_payload "$data"
    jq --argjson ack "$bad" '.charted[0].ack = $ack' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "the payload contract accepted the acknowledgement $bad: $out"
  done
  write_valid_payload "$data"
  jq '.charted[0].ack = {kind:"acting", at:1758240000}
    | .captains_call[0].ack = {kind:"refused", at:1758240000, why:"no longer qualifies"}' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 \
    || fail "the payload contract refused a well-formed acknowledgement"
  pass "the payload contract refuses a malformed acknowledgement and accepts a real one"
}

# The captain's own answer is the one board refresh trigger the fleet events
# cannot supply: all of those are consequence-side, so an answer whose
# consequence has not happened yet used to leave the board looking as if
# nothing was heard. This asserts the whole chain the captain sees - the
# captured answer, and an acknowledgement on each key it named - and it
# asserts the scope, because acknowledging another Lavish review's choices
# would put pills on rows nobody clicked.
test_a_captured_board_answer_acknowledges_every_key_it_named() {
  local home board sid other stub out
  home=$(make_home ack-capture)
  board=$(run_board "$home" path)
  mkdir -p "${board%/*}"
  printf '<html></html>\n' > "$board"
  sid=$(PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$board") \
    || fail "could not resolve the board's own source id"

  # One poll response carrying both controls the captain clicks: a decision
  # card's answer, and a dispatch order naming the rows he checked.
  stub="$home/board-source.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[2]{tag,text,prompt}:
  "choice","Take the north route","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"gated-work\",\"selection\":\"north\",\"note\":\"\"}"
  "choice","Dispatch: plain-queued, later-call","Context data: {\"question\":\"dispatch.charted\",\"answer\":\"plain-queued,later-call\"}"
OUT
SH
  chmod +x "$stub"
  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  out=$(run_procevent "$home" start "$sid" 2>&1) \
    || fail "the board source runner did not complete: $out"
  assert_contains "$out" "board-acked: $sid" "the captured board answer acknowledged nothing: $out"

  jq -e '.kind == "acting"' "$home/state/board-acks/gated-work.json" >/dev/null \
    || fail "the decision card's own answer was not acknowledged"
  # The send button answers for the rows it picked, so each of those is
  # acknowledged and the pseudo-key it travelled under is not.
  jq -e '.kind == "acting"' "$home/state/board-acks/plain-queued.json" >/dev/null \
    || fail "a dispatched row was not acknowledged where the captain checked it"
  jq -e '.kind == "acting"' "$home/state/board-acks/later-call.json" >/dev/null \
    || fail "the second dispatched row was not acknowledged"
  [ ! -e "$home/state/board-acks/dispatch.charted.json" ] \
    || fail "the dispatch pseudo-key was acknowledged as if it were a row"

  # Another Lavish review is an ephemeral discussion, not this board.
  other=lavish-00000000deadbe01
  run_procevent "$home" register lavish "$other" -- "$stub" >/dev/null \
    || fail "could not register the unrelated source"
  rm -f "$home"/state/board-acks/*.json
  out=$(run_procevent "$home" start "$other" 2>&1) \
    || fail "the unrelated source runner did not complete: $out"
  if printf '%s' "$out" | grep -q "board-acked:"; then
    fail "an unrelated Lavish review acknowledged rows on the board: $out"
  fi
  [ -z "$(ls -A "$home/state/board-acks" 2>/dev/null)" ] \
    || fail "an unrelated Lavish review wrote acknowledgements: $(ls -A "$home/state/board-acks")"
  pass "a captured board answer acknowledges every key it named, and only this board's"
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

# Every remote host the built page names, with the ones that are not a fetch
# removed: loopback is the live push and is wanted, the SVG namespace is an
# identifier, an author link is the captain clicking, and the payload island is
# data the page renders as text rather than anything it loads.
#
# Deliberately NOT a list of resource-position spellings. The guard this
# replaces checked seven fixed strings and a protocol-relative webfont - the
# closest relative of the thing it was written for - walked straight past it.
# So this removes what is allowed and flags everything else, which cannot be
# walked past by inventing an eighth spelling.
board_remote_refs() {  # <page>
  awk '
    /<script id="bearings-data"/ { in_payload = 1 }
    in_payload { if (/<\/script>/) { in_payload = 0 } ; next }
    { print }
  ' "$1" \
    | sed 's/<a [^>]*>//g' \
    | grep -oE '(https?:)?//[A-Za-z0-9._:-]+' \
    | grep -vE '^(https?:)?//(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?$' \
    | grep -vE '^https?://www\.w3\.org$' \
    | sort -u
}

# The captain may open this board offline, behind a firewall that blocks a font
# host, or on a clone configured with nothing. A page that fetches at load still
# renders, so nothing reports a failure - it just silently becomes a different
# product for whoever cannot reach the host. The assertion is on the BUILT page
# rather than the template, because the built page is what reaches the captain.
#
# WHAT THIS HOLDS, precisely, because a guard that claims more than it checks is
# the defect this branch exists to attack: the built page names no REMOTE host
# outside an author link. Loopback is allowed on purpose - the live push is a
# loopback websocket, so "this page fetches nothing" would be false about the
# very build being checked, and the narrower claim is the true one.
#
# WHAT IT CANNOT SEE, stated rather than left to a green: a URL assembled at
# runtime from parts never appears as a literal, so no scan of the page finds
# it. The live transport builds its own endpoint that way.
test_the_built_board_names_no_remote_host_to_fetch_from() {
  local home data board refs probe
  home=$(make_home offline)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  # A scanner that errors prints nothing, and nothing reads as a clean page -
  # the guard would then pass by silence, which is the failure it exists to
  # catch. So prove it can FAIL on a fixture before trusting it on the board.
  probe="$home/probe.html"
  printf '<style>@import url("https://fonts.example/x.css");</style>\n' > "$probe"
  [ -n "$(board_remote_refs "$probe")" ] \
    || fail "the remote-reference scanner cannot detect a remote reference; its green would mean nothing"

  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the board did not build"

  refs=$(board_remote_refs "$board")
  [ -z "$refs" ] || fail "the built board names a remote host to fetch from: $refs"

  pass "the built board names no remote host, and the scanner proved it can fail"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "alarm"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown charted kind was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "warning"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a dispatchable warning row was accepted"

  write_valid_payload "$data"
  jq '.charted_warning_more = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative omitted-warning count was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].subject = {"artifact":"quota-axi","version":"0.1"}' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an invalid structured version subject was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","state":"working",
    "kind":"ship","doing":"implementing"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an underway row without an explicit name marker was accepted"

  for invalid_filed in "last Tuesday" "2026-13-01" "2026-08-14T99:30:00Z" "2026-02-29"; do
    write_valid_payload "$data"
    jq --arg filed "$invalid_filed" '.charted[0].filed = $filed' "$data" > "$data.tmp" \
      && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid filed date was accepted: $invalid_filed"
  done

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build --lavish "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: apart from the reconcile choice the build adds to every
  # decision card, the payload extracted from the built page is the same JSON
  # document, and the escaped </script> string can no longer terminate the
  # data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$home/extracted.json" > "$home/stripped.json"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/stripped.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data runtime origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  runtime="$home/runtime"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = arm ]; then
  artifact=${2:-}
  "$REAL_LAVISH_ADAPTER" arm "$artifact" >/dev/null
  sid=$("$REAL_LAVISH_ADAPTER" source-id "$artifact")
  "$REAL_PROCEVENT" start "$sid" >/dev/null
  exit 0
fi
exec "$REAL_LAVISH_ADAPTER" "$@"
SH
  chmod +x "$runtime/bin/fm-procevent-lavish.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ -z "${1:-}" ]; then
  printf 'sessions[1]{file,status,url,pending_prompts}:\n'
  [ ! -s "$FM_HOME/order-open" ] \
    || printf '  %s,open,"http://127.0.0.1/session/order",0\n' "$(cat "$FM_HOME/order-open")"
  exit 0
fi
if [ "${1:-}" != poll ]; then
  real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  printf '%s\n' "$real" > "$FM_HOME/order-open"
  printf 'session:\n  status: opened\n'
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"schema\\": \\"fm-bearings-answer.v1\\",\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"selection\\": \\"yes\\",\\n  \\"note\\": \\"\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$runtime" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    REAL_LAVISH_ADAPTER="$ROOT/bin/fm-procevent-lavish.sh" \
    REAL_PROCEVENT="$ROOT/bin/fm-procevent.sh" ORDER_PROOF_HOLD="$hold" \
    "$runtime/bin/fm-bearings-board.sh" build --lavish "$data" >/dev/null \
    || fail "the order-proof board build failed"

  show=$(cd "$home" && tasks-axi show "$hold" --full) \
    || fail "the order-proof captain hold disappeared"
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build --lavish "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build --lavish "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_charted_kind_is_optional_and_accepts_both_values() {
  local home data
  home=$(make_home chartedkind)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted = [
        {"id":"a","repo":"sample","title":"Queued","reason":"","dispatchable":true},
        {"id":"b","repo":"sample","title":"Queued too","reason":"gated","dispatchable":true,"kind":"queued"},
        {"id":"c","repo":"sample","title":"Integrity notice","reason":"main inventory","dispatchable":false,"kind":"warning"}
      ] | .charted_warning_more = 2' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "an omitted, queued, and warning charted kind was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.charted[] | .kind // "queued"]) == ["queued", "queued", "warning"]
      and .charted_warning_more == 2
  ' >/dev/null || fail "the built board did not carry the charted kinds and omitted-warning count it was given"
  pass "charted kind is optional and accepts queued and warning"
}


# --- part 1: never arm a poll on an ended session ---------------------------

test_build_reopens_a_session_the_captain_ended() {
  local home data board out sid claim old_pid old_token new_pid new_token
  home=$(make_home ended-session)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")
  claim="$home/procevent-claims/$sid.claim"
  old_pid=$(sed -n '2p' "$claim")
  old_token=$(sed -n '3p' "$claim")

  # The reported case: the captain ends the board from the browser, so opening
  # it again keeps the same session id, reports it ended, and EXITS 0. A build
  # that trusts the exit status arms a poll nothing can ever attach to.
  : > "$home/lavish-state/hold-after-terminal"
  : > "$home/lavish-state/poll-trigger"
  for _ in $(seq 1 100); do
    [ -e "$home/lavish-state/terminal-emitted" ] && break
    sleep 0.05
  done
  [ -e "$home/lavish-state/terminal-emitted" ] \
    || fail "the old listener did not receive its terminal result"
  rm -f "$home/lavish-state/poll-trigger"
  end_session_as_captain "$home"
  out=$(run_board "$home" build --lavish "$data") || fail "the rebuild refused a recoverable ended session"
  rm -f "$home/lavish-state/hold-after-terminal"
  assert_contains "$out" "session: reopened" \
    "the rebuild did not reopen the ended session: $out"
  [ ! -e "$home/lavish-state/user-ended" ] \
    || fail "the rebuild reported success while the session was still ended"
  new_pid=$(sed -n '2p' "$claim")
  new_token=$(sed -n '3p' "$claim")
  [ "$new_pid" != "$old_pid" ] || [ "$new_token" != "$old_token" ] \
    || fail "the rebuild accepted the pre-reopen source generation"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the reopened board has no live listener"
  pass "a board build reopens a session the captain ended instead of arming a dead one"
}

test_build_reopens_when_an_opened_session_ends_before_listing() {
  local home data out board sid
  home=$(make_home establish-list-race)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  : > "$home/lavish-state/end-before-next-list"
  out=$(run_board "$home" build --lavish "$data") || fail "the raced session build failed: $out"
  assert_contains "$out" "session: reopened" \
    "the build trusted an opened response after the server no longer listed it: $out"
  sid=$(run_lavish_source_id "$home" "$board")
  [ -s "$home/lavish-state/open" ] || fail "the raced session was not live before arming"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the replacement session did not receive a live listener"
  pass "build reopens a session that ends between establish and listing"
}

test_name_support_probe_never_lists_before_the_session_is_established() {
  local home data first
  home=$(make_home name-probe-inert)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "the build failed"
  # A listing is the read the liveness proof consumes, so nothing the build asks
  # before opening the session may be one. Pinning the FIRST call keeps a future
  # probe from answering a question the build has not asked yet.
  first=$(sed -n '1p' "$home/lavish-state/calls")
  case "$first" in
    '<list>') fail "the build listed sessions before establishing one" ;;
  esac
  pass "the session-name probe never lists sessions before the session is established"
}

test_name_support_probe_follows_what_the_release_advertises() {
  local home data opened
  home=$(make_home name-probe-absent)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "the unnamed build failed"
  opened=$(grep -c -- '--name bearings' "$home/lavish-state/calls" || true)
  [ "$opened" = 0 ] \
    || fail "the build named a session on a release that does not advertise --name"

  home=$(make_home name-probe-present)
  data="$home/payload.json"
  write_valid_payload "$data"
  : > "$home/lavish-state/advertise-name"
  run_board "$home" build --lavish "$data" >/dev/null || fail "the named build failed"
  grep -q -- '--name bearings' "$home/lavish-state/calls" \
    || fail "the build did not name the session on a release that advertises --name"
  pass "the session-name probe reads the installed release in both directions"
}

test_build_refuses_to_arm_when_the_session_stays_ended() {
  local home data rc out sid
  home=$(make_home dead-session)
  data="$home/payload.json"
  write_valid_payload "$data"
  # An ended session that will not come back: the build must stop rather than
  # register a poll against it.
  : > "$home/lavish-state/refuse-reopen"
  set +e
  out=$(run_board "$home" build --lavish "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build armed a poll on a session that stayed ended: $out"
  assert_contains "$out" "ended session" "the refusal did not say why: $out"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board to a session that stayed ended"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board against a session that stayed ended"
  pass "build refuses to arm a poll on a session that stays ended"
}

test_build_starts_a_listener_for_an_already_armed_board() {
  local home data board out sid claim
  home=$(make_home relisten)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")

  # Registered is not listening: drop the listener the way a crashed generation
  # would, then rebuild. `already-armed` must not be the end of the story.
  claim="$home/procevent-claims/$sid.claim"
  assert_present "$claim" "the first build left no listener to lose"
  kill -KILL -"$(sed -n '2p' "$claim")" 2>/dev/null || true
  kill -KILL "$(sed -n '2p' "$claim")" 2>/dev/null || true
  sleep 1

  out=$(run_board "$home" build --lavish "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: $sid" "the rebuild re-registered the source: $out"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the rebuilt board is registered but nothing is listening"
  pass "a rebuild starts a listener when an already-armed board has none"
}

# --- part 2: a landed subject is not a live call ----------------------------

test_build_drops_decision_cards_whose_subject_already_landed() {
  local home data board out
  home=$(make_home landed-cards)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call = [
        {"key":"landed-by-task","type":"decision","repo":"sample","title":"Already shipped",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"timeout-reattach","type":"decision","repo":"sample","title":"Already merged",
         "pr_url":"https://github.com/sample/sample/pull/7",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"quota-version","type":"decision","repo":"sample","title":"Old quota release",
         "subject":{"artifact":"quota-axi","version":"0.1.37"},
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"still-open","type":"decision","repo":"sample","title":"Genuinely open",
         "subject":{"artifact":"quota-axi","version":"0.2.0"},
         "options":[{"value":"yes","label":"Yes"}]}
      ]
      | .landed = [
        {"id":"landed-by-task","repo":"sample","what":"shipped it","owner":"crew"},
        {"id":"some-other-task","repo":"sample","what":"merged timeout reattach","owner":"crew",
         "pr_url":"https://github.com/sample/sample/pull/7"},
        {"id":"quota-release","repo":"sample","what":"published quota-axi","owner":"crew",
         "subject":{"artifact":"quota-axi","version":"0.1.38"}},
        {"id":"unrelated\nstill-open","repo":"sample","what":"unrelated multiline identity","owner":"crew"}
      ]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the hygiene build failed: $out"
  assert_contains "$out" "dropped-landed-card: landed-by-task" \
    "the build did not report dropping the landed work item card: $out"
  assert_contains "$out" "dropped-landed-card: timeout-reattach" \
    "the build did not report dropping the merged timeout/reattach card: $out"
  assert_contains "$out" "dropped-landed-card: quota-version" \
    "the build did not report dropping the superseded quota-axi version card: $out"
  extract_payload "$board" | jq -e '[.captains_call[].key] == ["still-open"]' >/dev/null \
    || fail "the board dropped an open card or kept one whose subject already landed"
  pass "build drops decision cards whose subject already landed and keeps open ones"
}

test_build_keeps_a_decision_absent_from_the_main_backlog() {
  local home data board out
  home=$(make_home remote-decision-card)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  write_valid_payload "$data"
  jq '.captains_call = [{
        "key":"remote-mate-call","type":"decision","repo":"sample",
        "title":"Remote secondmate decision",
        "options":[{"value":"yes","label":"Yes"}]
      }]
      | .landed = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the remote-card build failed: $out"
  assert_not_contains "$out" "dropped-landed-card: remote-mate-call" \
    "an absent remote card was reported as landed: $out"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.key == "remote-mate-call")] | length == 1
  ' >/dev/null || fail "the hygiene check dropped a decision absent from the main backlog"
  pass "build keeps remote decisions absent from the main backlog"
}

# --- part 3: every decision card offers reconcile ---------------------------

test_build_fails_when_reconcile_cannot_establish_a_listener() {
  local home data out rc sid
  home=$(make_home no-listener)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "could not establish the listener fixture"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/ps"
  set +e
  out=$(FM_PROC_ROOT_OVERRIDE="$home/no-proc" run_board "$home" build --lavish "$data" 2>&1)
  rc=$?
  set -e
  rm -f "$home/fakebin/ps"
  [ "$rc" -ne 0 ] || fail "a build with an uncertain listener reported success: $out"
  assert_contains "$out" "source $sid is not listening after reconcile" \
    "the refusal did not name the source: $out"
  assert_contains "$out" "observed owner: uncertain" \
    "the refusal did not name the observed owner: $out"
  pass "build fails when reconcile cannot prove a live listener"
}

test_every_decision_card_carries_the_reconcile_choice() {
  local home data board
  home=$(make_home reconcile-option)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the reconcile-option build failed"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type == "decision")] | length) > 0
    and ([.captains_call[]
      | select(.type == "decision")
      | ([.options[] | select(.value == "reconcile")] | length) == 1
        and ([.options[] | select(.value == "reconcile") | .label | length > 0] | all)] | all)
  ' >/dev/null || fail "a decision card was published without the reconcile choice"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type != "decision")
      | .options[] | select(.value == "reconcile")] | length) == 0
  ' >/dev/null || fail "reconcile was injected into a non-decision card"
  pass "every decision card carries exactly one reconcile choice"
}

test_build_refuses_a_payload_that_occupies_the_reconcile_value() {
  local home data rc out
  home=$(make_home reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[0].options += [{"value":"reconcile","label":"Something else"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a payload occupying the reserved reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused payload still produced a board"
  pass "build refuses a payload that occupies the reserved reconcile value"
}

test_build_refuses_a_nondecision_reconcile_value() {
  local home data rc out
  home=$(make_home merge-reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[1].options += [{"value":"reconcile","label":"Merge action"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a merge card occupying the reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused merge card still produced a board"
  pass "build reserves reconcile across non-decision cards"
}

# Captain-facing copy may be an {en, hant, hans?} object so the board renders
# the language the captain picked; a decision card may carry the five-question
# fields and evidence links. The validator accepts those shapes and refuses
# the malformed ones before touching the board.
test_build_accepts_trilingual_copy_and_five_question_fields() {
  local home data board out
  home=$(make_home i18n-accept)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '
    .lang = "hant"
    | .captains_call[0].title = {en: "Perishable-first admission", hant: "易腐品優先入場"}
    | .captains_call[0].decide = {en: "Adopt it?", hant: "要採用嗎？", hans: "要采用吗？"}
    | .captains_call[0].if_nothing = {en: "The queue keeps admitting by arrival order", hant: "佇列繼續照到達順序入場"}
    | .captains_call[0].reversible = "partly"
    | .captains_call[0].reversible_note = {en: "config flips back; admitted rows stay", hant: "設定可切回；已入場的列留下"}
    | .captains_call[0].risk = "medium"
    | .captains_call[0].recommend_value = "yes"
    | .captains_call[0].recommend_why = {en: "measured 40% fewer spoiled lots", hant: "量到報廢批次少 40%"}
    | .captains_call[0].options[0].consequence = {en: "reorders the queue at the next tick", hant: "下個 tick 重排佇列"}
    | .captains_call[0].evidence = [
        {label: {en: "scout report", hant: "偵察報告"}, url: "https://example.test/report"},
        {label: "served packet", url: "http://127.0.0.1:4387/session/abc"}]
    | .captains_call[0].packet_url = "http://127.0.0.1:4387/s/packet-abc"
    | .charted[0].title = {en: "Queued work", hant: "排隊中的工作"}
    | .charted[0].reason = {en: "waits on the cutover", hant: "等切換完成"}
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "a trilingual five-question payload was refused: $out"
  assert_present "$board" "the trilingual build produced no board"
  extract_payload "$board" | jq -e '
    .lang == "hant"
    and (.captains_call[0].title.hant == "易腐品優先入場")
    and (.captains_call[0].reversible == "partly")
    and (.captains_call[0].evidence | length == 2)
    and ([.captains_call[0].options[] | select(.value == "reconcile") | .label.hant] == ["重新核對"])
  ' >/dev/null || fail "the built board lost the trilingual copy or the injected reconcile translation"
  pass "build accepts trilingual copy, the five-question fields, and evidence links"
}

test_build_refuses_malformed_copy_and_card_fields() {
  local home data board rc out
  home=$(make_home i18n-refuse)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"

  write_valid_payload "$data"
  jq '.captains_call[0].title = {en: "Only English"}' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a copy object without hant was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].risk = "critical"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown decision risk level was accepted"

  # One key is one keyed-intake address, so a hand-written payload may not
  # carry two cards under it either.
  write_valid_payload "$data"
  jq '.captains_call += [.captains_call[0]]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two cards under one key were accepted"
  assert_absent "$board" "a payload with duplicate card keys still produced a board"

  write_valid_payload "$data"
  jq '.captains_call[0].reversible = "maybe"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown reversible value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].evidence = [{label: "raw path", url: "/Users/someone/report.html"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an evidence link that is not a URL was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].evidence = [{label: "remote http", url: "http://example.test/report"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a plain-http evidence link to a remote host was accepted"

  write_valid_payload "$data"
  jq '.lang = "fr"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unsupported default language was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed copy objects, card enums, evidence links, and languages"
}

# --- part 4: compose a trilingual skeleton from a recorded snapshot ----------
# The fixture under tests/assets/bearings-compose/ is a recorded
# `bin/fm-bearings-snapshot.sh --json --include-prs` output (its shape is owned
# by that script's header) beside the backlog it was recorded from, so the
# mapping is exercised against real projected rows rather than hand-typed ones.
COMPOSE_ASSETS="$ROOT/tests/assets/bearings-compose"

# The packet's decision block for the held work item, keyed to its task id.
COMPOSE_DECISION='{"key":"gated-work","title":{"en":"Rollout order","hant":"上線順序"},"decide":"Which rollout order ships first?","if_nothing":"the release waits","reversible":"partly","risk":"medium","options":[{"value":"canary","label":"Canary first","consequence":"slower, safer"},{"value":"all","label":{"en":"All at once"},"consequence":"faster, riskier"}],"recommend_value":"canary","recommend_why":"the canary caught the last regression"}'

make_compose_home() {  # <name> [decision-json] -> a board home whose backlog and packet match the fixture
  local home packet decision=${2-$COMPOSE_DECISION}
  home=$(make_home "$1")
  cp "$COMPOSE_ASSETS/backlog.md" "$home/data/backlog.md"
  fm_write_meta "$home/state/gated-work.meta" "worktree=$home" "project=firstmate" "kind=ship"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-packet.sh" scaffold gated-work --kind needs-decision --worktree "$home" >/dev/null \
    || fail "cannot scaffold the fixture packet"
  packet="$home/data/gated-work/packet.md"
  python3 - "$packet" "$decision" <<'PY2'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
said = "\n".join("- en: %s\n- hant: %s\n- hans: %s" % t for t in (
    ("tried a flag; dropped it", "試過一個旗標，後來放棄", "试过一个旗标，后来放弃"),
    ("the bound is unverified", "上限沒有驗證過", "上限没有验证过"),
    ("the order assumes one region", "這個順序假設只有一個區域", "这个顺序假设只有一个区域")))
s = re.sub(r"- en: \{FILL: every path you tried.*?- hans: \{FILL[^}]*\}", lambda m: said, s, flags=re.S)
evidence = ("- en: the change is at the top of the forge loop\n"
            "- hant: 改動在 forge 迴圈的最前面\n"
            "- hans: 改动在 forge 循环的最前面\n"
            "- `bin/example.sh:1`")
s = re.sub(r"- en: \{FILL: file:line.*?- hans: \{FILL[^}]*\}", lambda m: evidence, s, flags=re.S)
s = re.sub(r"\{FILL: optional.*?\}\n", "", s)
s = re.sub(r"```json fm-packet-decision.v1\n.*?\n```", "```json fm-packet-decision.v1\n" + sys.argv[2] + "\n```", s, flags=re.S)
# A needs-decision packet owes one figure putting both options in one drawing;
# the board card carries the packet itself, and only a packet that verifies.
figure = """### Where the two rollout orders differ
heading.hant: 兩種上線順序差在哪
heading.hans: 两种上线顺序差在哪
figure: roll
caption: Both orders reach the same release; only the first hour differs.
caption.hant: 兩種順序最後都上線，只有第一個小時不同。
caption.hans: 两种顺序最后都上线，只有第一个小时不同。

<svg role="img" viewBox="0 0 480 200" xmlns="http://www.w3.org/2000/svg">
  <defs><marker id="roll-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0 0 L8 4 L0 8 z" fill="var(--muted)"/></marker></defs>
  <rect id="roll-a" data-node="canary" x="20" y="20" width="160" height="60" rx="8" fill="var(--accent-tint)" stroke="var(--accent)"/>
  <text x="30" y="46" data-en="Canary first" data-hant="先金絲雀" data-hans="先金丝雀">Canary first</text>
  <rect id="roll-b" data-node="all" x="20" y="120" width="160" height="60" rx="8" fill="var(--card-2)" stroke="var(--rule)"/>
  <text x="30" y="146" data-en="All at once" data-hant="一次全開" data-hans="一次全开">All at once</text>
  <rect id="roll-end" data-node="released" x="300" y="70" width="160" height="60" rx="8" fill="var(--card)" stroke="var(--rule)"/>
  <text x="310" y="96" data-en="Released" data-hant="已上線" data-hans="已上线">Released</text>
  <path data-edge="canary-to-released" d="M180 50 L300 96" stroke="var(--accent)" fill="none" marker-end="url(#roll-arrow)"/>
  <path data-edge="all-to-released" d="M180 150 L300 114" stroke="var(--muted)" fill="none" marker-end="url(#roll-arrow)"/>
</svg>

- edge canary-to-released: the last regression the canary caught
- edge all-to-released: bin/example.sh:1 the change"""
s = re.sub(r"## Figures\n.*?\n## Evidence", lambda m: "## Figures\n\n" + figure + "\n\n## Evidence", s, flags=re.S)
p.write_text(s)
PY2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-packet.sh" verify gated-work >/dev/null || fail "the fixture packet does not verify"
  printf '%s\n' "$home"
}

# Resolve every compose slot the way the composer does: the enum and count
# slots take real values, the rest take prose and translations.
fill_skeleton() {  # <skeleton.json> <filled.json>
  jq '
    def unfilled: type == "string" and startswith("{FILL: ");
    (if (.charted_more | unfilled) then .charted_more = 0 else . end)
    | (if (.charted_warning_more | unfilled) then .charted_warning_more = 0 else . end)
    | .captains_call |= map(
        if .type == "decision" then
          (if (.reversible | unfilled) then .reversible = "yes" else . end)
          | (if (.risk | unfilled) then .risk = "low" else . end)
          | (if (.recommend_value | unfilled) then .recommend_value = .options[0].value else . end)
        else . end)
    | walk(if type == "string" then
      (if test("^\\{TRANSLATE: ") then ("譯: " + (.[12:-1]))
       elif test("^\\{FILL: low") then "low"
       elif test("^\\{FILL: ") then ("filled " + (.[7:-1]))
       else . end)
    else . end)
  ' "$1" > "$2"
}

test_compose_maps_every_section_from_the_recorded_snapshot() {
  local home skeleton
  home=$(make_compose_home compose-map)
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  jq -e '
    .schema == "fm-bearings-board.v1" and .lang == "hant" and .prs_live == true
    and (.home | type == "string") and (.generated | type == "string")
    # Underway: the durable label and run state, both trilingual-ready.
    and (.underway | length == 1)
    and (.underway[0] | .id == "ship-task" and .repo == "firstmate" and .kind == "ship"
      and .name.en == "Ship the thing" and .name.hant == "{TRANSLATE: Ship the thing}"
      and (.doing.en | length > 0) and (.doing.hant | startswith("{TRANSLATE: ")))
    # Landed: pr_url only for an https artifact, repo from the backlog record.
    and (.landed | length == 2)
    and (.landed[0] | .id == "done-a" and .repo == "firstmate" and .what.en == "Landed thing"
      and .pr_url == "https://github.com/example/firstmate/pull/7")
    and (.landed[1] | .id == "scout-b" and .repo == "sample" and (has("pr_url") | not))
    # Charted: queued rows keep their filed date; only the unblocked, unheld
    # row is dispatchable; the integrity notice is a non-dispatchable warning
    # under a slug id.
    and (.charted | length == 4)
    and (.charted[0] | .id == "plain-queued" and .kind == "queued" and .dispatchable == true
      and .reason == "" and .filed == "2026-09-16" and .repo == "sample")
    # A gate blocked by another task carries no hold reason, so the skeleton
    # words the blocker itself; a blank reason renders with no badge and no
    # explanation.
    and (.charted[1] | .id == "live-gate" and .kind == "queued" and .dispatchable == false
      and .reason.en == "waiting on ship-task" and .reason.hant == "{TRANSLATE: waiting on ship-task}")
    and (.charted[2] | .id == "later-call" and .kind == "queued" and .dispatchable == false
      and (.reason.en | startswith("until 2030-01-01")) and (.reason.hant | startswith("{TRANSLATE: until")))
    and (.charted[3] | .id == "main-inventory" and .kind == "warning" and .dispatchable == false
      and .filed == null and .repo == null)
    # This snapshot omitted no gate rows, so there is nothing to divide and
    # neither count is emitted at all.
    and (has("charted_more") | not) and (has("charted_warning_more") | not)
  ' "$skeleton" >/dev/null || fail "the skeleton did not map the fleet sections as recorded: $(cat "$skeleton")"
  pass "compose maps underway, landed, and charted rows from the recorded snapshot"
}

test_compose_cards_every_live_hold_and_merge_ready_pr() {
  local home skeleton
  home=$(make_compose_home compose-cards)
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  jq -e '
    ([.captains_call[].key] == ["gated-work", "pick-route", "merge.ship-task"])
    # The held WORK item is seeded from its verified packet: the packet copy
    # is kept, English-only packet strings gain a translation slot, about is
    # still the composer'"'"'s, and the work-item hold releases on answer.
    and (.captains_call[0] | .type == "decision" and .repo == "firstmate"
      and .title == {en: "Rollout order", hant: "上線順序"}
      and .decide == {en: "Which rollout order ships first?", hant: "{TRANSLATE: Which rollout order ships first?}"}
      and .if_nothing.en == "the release waits"
      and .reversible == "partly" and .risk == "medium"
      and ([.options[].value] == ["canary", "all"])
      and .options[1].label == {en: "All at once", hant: "{TRANSLATE: All at once}"}
      and .options[0].consequence.hant == "{TRANSLATE: slower, safer}"
      and .recommend_value == "canary" and .recommend_why.en == "the canary caught the last regression"
      and .about.en == "{FILL: about}" and .close == "release" and .allow_freeform == true)
    # The question-shaped hold without a packet gets placeholders, its title
    # and repo from the backlog record, and no close.
    and (.captains_call[1] | .type == "decision" and .repo == "sample"
      and .title == {en: "Pick the route", hant: "{TRANSLATE: Pick the route}"}
      and .decide.en == "{FILL: decide}" and .if_nothing.hant == "{FILL: if_nothing}"
      and ([.options[].value] == ["option-a", "option-b"])
      and .options[0].consequence.en == "{FILL: option A consequence}"
      and .recommend_why.en == "{FILL: recommend_why}"
      # The five questions are not the whole card: risk, reversibility, and the
      # recommended option are slots too, so no card reaches the captain
      # missing them.
      and .risk == "{FILL: low | medium | high}"
      and .reversible == "{FILL: yes | no | partly}"
      and .recommend_value == "{FILL: recommend one of option-a | option-b}"
      and (has("close") | not))
    # Only the green, mergeable PR becomes a merge card, keyed by its task,
    # with the URL set and the risk left to fill; the red PR never appears.
    and (.captains_call[2] | .type == "merge" and .repo == "firstmate"
      and .pr_url == "https://github.com/example/firstmate/pull/9"
      and .title.en == "Merge: Ship the thing" and (.risk | startswith("{FILL: "))
      and ([.options[].value] == ["merge", "hold"]) and .options[0].label.hant == "立即合併")
    and ([.captains_call[] | .options[].value] | index("reconcile") == null)
  ' "$skeleton" >/dev/null || fail "the skeleton did not card the holds and PRs as expected: $(cat "$skeleton")"
  pass "compose seeds a card from the verified packet, placeholders otherwise, and cards merge-ready PRs"
}

test_compose_lang_and_snapshot_arguments() {
  local home out rc
  home=$(make_compose_home compose-args)
  out=$(run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --lang en) \
    || fail "compose --lang en failed"
  printf '%s' "$out" | jq -e '.lang == "en" and (.underway[0].name.hant | startswith("{TRANSLATE: "))' >/dev/null \
    || fail "--lang en changed more than the default language"
  set +e; out=$(run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --lang fr 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unsupported --lang was accepted"
  printf '{"schema":"other"}\n' > "$home/not-a-snapshot.json"
  set +e; out=$(run_board "$home" compose --snapshot "$home/not-a-snapshot.json" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-bearings snapshot was accepted"
  pass "compose honors --lang and refuses a foreign snapshot"
}

# A held task with no packet still reaches the captain with ground truth: its
# card carries the pull request's own tabs as evidence links. The fixture's
# `pick-route` hold is the packetless one, so a recorded PR on it exercises the
# placeholder path; `gated-work` beside it has a packet and no recorded PR, and
# carries no evidence key at all rather than an empty list.
test_compose_gives_a_packetless_card_the_pull_requests_links() {
  local home skeleton filled pr
  home=$(make_compose_home compose-pr-links)
  pr=https://github.com/example/sample/pull/12
  fm_write_meta "$home/state/pick-route.meta" "worktree=$home" "pr=$pr"
  skeleton="$home/skeleton.json"
  filled="$home/filled.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a held task whose meta records a PR"
  jq -e --arg pr "$pr" '
    (.captains_call[1] | .key == "pick-route"
      and ([.evidence[].url] == [$pr, ($pr + "/checks"), ($pr + "/commits"), ($pr + "/files")])
      and (.evidence[0].label.en == "pull request")
      and (.evidence[1].label.en == "checks")
      and (.evidence[3].label.en == "review comments")
      # The captain reads the card in three languages, so an evidence label
      # that is only English would go blank the moment he switches.
      and ([.evidence[] | .label.hant, .label.hans]
           | length == 8 and all(type == "string" and length > 0)))
    and (.captains_call[0] | .key == "gated-work" and (has("evidence") | not))
  ' "$skeleton" >/dev/null || fail "the packetless card did not carry the PR links: $(cat "$skeleton")"
  # Those links must also survive the payload validator, or the card the
  # captain actually opens would be refused rather than degraded.
  fill_skeleton "$skeleton" "$filled"
  run_board "$home" build "$filled" >/dev/null 2>&1 || fail "build refused a card carrying the PR links"
  pass "compose gives a card with no packet the pull request's own links"
}

# Which tab is the checks tab is the forge's answer, not this script's: a
# GitLab merge request's are pipelines and diffs, and reading github's tab
# names onto one would hand the captain four links that 404.
test_compose_reads_the_pr_tab_names_from_the_forge() {
  local home skeleton mr
  home=$(make_compose_home compose-pr-links-gitlab)
  mr=https://gitlab.example.com/group/sub/proj/-/merge_requests/7
  fm_write_meta "$home/state/pick-route.meta" "worktree=$home" "pr=$mr"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a held task whose meta records a merge request"
  jq -e --arg mr "$mr" '
    .captains_call[1] | .key == "pick-route"
    and ([.evidence[].url] == [$mr, ($mr + "/pipelines"), ($mr + "/commits"), ($mr + "/diffs")])
    and (.evidence[0].label.en == "merge request") and (.evidence[1].label.en == "pipelines")
  ' "$skeleton" >/dev/null || fail "the card used GitHub tab names for a merge request: $(cat "$skeleton")"
  pass "compose reads a card's PR tab names from the forge the URL names"
}

# A PR field that is not a PR URL is not a link the captain can be handed, so
# the card degrades to no evidence rather than to a link that goes nowhere.
test_compose_drops_an_unparseable_pr_record() {
  local home skeleton
  home=$(make_compose_home compose-pr-links-bad)
  fm_write_meta "$home/state/pick-route.meta" "worktree=$home" "pr=not-a-url"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a held task whose recorded PR does not parse"
  jq -e '.captains_call[1] | .key == "pick-route" and (has("evidence") | not)' "$skeleton" >/dev/null \
    || fail "an unparseable PR record still produced evidence links: $(cat "$skeleton")"
  pass "compose drops a PR record it cannot parse instead of linking it"
}

test_compose_seeds_a_packet_card_without_a_recorded_project() {
  local home skeleton
  home=$(make_compose_home compose-no-project)
  fm_write_meta "$home/state/gated-work.meta" "worktree=$home" "kind=ship"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a verified packet whose meta records no project"
  jq -e '
    (.captains_call[0] | .key == "gated-work" and .type == "decision"
      and .title == {en: "Rollout order", hant: "上線順序"} and .repo == "firstmate")
    and ([.captains_call[].key] == ["gated-work", "pick-route", "merge.ship-task"])
  ' "$skeleton" >/dev/null || fail "the packet card did not fall back to the backlog repo: $(cat "$skeleton")"
  pass "compose seeds a packet card whose meta has no project from the backlog repo"
}

test_compose_degrades_a_blank_run_detail_to_the_state_word() {
  local home skeleton
  home=$(make_compose_home compose-blank-doing)
  jq '.in_flight[0].doing = ""' "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose in-flight row has a blank run detail"
  jq -e '.underway[0] | .state == "unknown" and .doing == {en: "unknown", hant: "{TRANSLATE: unknown}"}' \
    "$skeleton" >/dev/null || fail "a blank doing was not degraded to the state word: $(cat "$skeleton")"
  pass "compose degrades a blank run detail to the row's state word"
}

test_compose_cards_no_merge_for_a_pr_without_an_owning_task() {
  local home skeleton
  home=$(make_compose_home compose-taskless-pr)
  jq '.candidate_prs += [{num: "12", repo: "example/firstmate", task: "-",
        url: "https://github.com/example/firstmate/pull/12",
        review: "APPROVED", mergeable: "MERGEABLE", checks: "passing"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a task-less PR"
  jq -e '
    ([.captains_call[] | select(.type == "merge") | .key] == ["merge.ship-task"])
    and ([.captains_call[] | .pr_url? // empty] | index("https://github.com/example/firstmate/pull/12") == null)
  ' "$skeleton" >/dev/null || fail "a green PR with no owning task was carded: $(cat "$skeleton")"
  pass "compose cards a merge only for a PR an owning task claims"
}

test_compose_leaves_the_omitted_charted_counts_to_the_composer() {
  local home skeleton out rc
  home=$(make_compose_home compose-charted-more)
  # The snapshot reports one omitted-gates total and never says how many of the
  # dropped rows were warnings, so neither count may be asserted here.
  jq '.omitted += [{surface: "gates showing 4 of 7", reveal: "--all-gates"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot that omitted gate rows"
  # Both slots name the SAME 3, so each must say so and point at the sibling
  # that takes the rest; a hint that reads as 3 of its own kind gets written
  # into both counts and the board over-reports what it hid.
  jq -e '
    (.charted_more | type == "string") and (.charted_warning_more | type == "string")
    and (.charted_more | contains("queued") and contains("your share of the 3 gate rows")
      and contains("belonging to charted_warning_more"))
    and (.charted_warning_more | contains("warning") and contains("your share of the 3 gate rows")
      and contains("belonging to charted_more"))
  ' "$skeleton" >/dev/null || fail "the omitted counts were asserted instead of slotted: $(cat "$skeleton")"
  set +e; out=$(run_board "$home" compose --check "$skeleton" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "compose --check passed a skeleton whose omitted counts are unresolved"
  assert_contains "$out" "charted_more: {FILL: queued" "check did not list the queued count slot: $out"
  assert_contains "$out" "charted_warning_more: {FILL: warning" "check did not list the warning count slot: $out"
  pass "compose slots both omitted Charted Next counts with the snapshot total"
}

test_compose_slots_the_risk_a_packet_leaves_out() {
  local home skeleton decision
  decision=$(printf '%s' "$COMPOSE_DECISION" | jq -c 'del(.risk)')
  home=$(make_compose_home compose-packet-no-risk "$decision")
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a verified packet whose decision block records no risk"
  jq -e '.captains_call[0] | .key == "gated-work"
    and .reversible == "partly" and .recommend_value == "canary"
    and .risk == "{FILL: low | medium | high}"' "$skeleton" >/dev/null \
    || fail "the packet card did not slot the risk the packet left out: $(cat "$skeleton")"
  pass "compose slots only the card fields a verified packet left out"
}

# --- the card the call itself wrote ------------------------------------------
# The captain refused a board whose cards are recomposed every time: 看板的卡片
# 我要一個realtime方案，不要你每次重建，沒意義. So a call writes its card when it
# is raised and compose READS it. These tests hold the two halves of that: the
# record outranks everything else a card could be built from, and a thin record
# reaches the captain looking thin rather than looking complete.

# Write a card record the way bin/fm-captain-hold.sh does, for the fixture task.
write_card_record() {  # <home> <json>
  mkdir -p "$1/state/board-cards" || fail "cannot create the card directory"
  printf '%s\n' "$2" > "$1/state/board-cards/gated-work.json" \
    || fail "cannot write the fixture card record"
}

FULL_CARD_RECORD='{"schema":"fm-board-card.v1","task":"gated-work","key":"captain-hold-gated-work-1","at":"2026-09-20T04:00:00Z","state":"open","thin":false,"title":{"en":"Ship the forge loop","hant":"上線 forge 迴圈","hans":"上线 forge 循环"},"repo":"firstmate","decide":"Which way do we ship it?","if_nothing":"the branch waits","reversible":"no","risk":"high","options":[{"value":"now","label":"Ship now","consequence":"fast, unproven"},{"value":"wait","label":"Wait for the review","consequence":"slower, checked"}],"recommend_value":"wait","recommend_why":"the review caught the last one","close":"release","figures":[]}'

test_compose_builds_the_card_the_call_wrote_rather_than_rebuilding_it() {
  local home skeleton
  home=$(make_compose_home compose-card-record)
  write_card_record "$home" "$FULL_CARD_RECORD"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a home whose call wrote a card record"
  # Every field below is the RECORD's, and every one of them differs from the
  # verified packet this same fixture also carries, so a pass cannot come from
  # the packet path by accident.
  jq -e '.captains_call[0]
    | .key == "gated-work" and .type == "decision"
    and .title.en == "Ship the forge loop" and .title.hant == "上線 forge 迴圈"
    and .decide.en == "Which way do we ship it?"
    and .if_nothing.en == "the branch waits"
    and .risk == "high" and .reversible == "no"
    and .recommend_value == "wait"
    and .recommend_why.en == "the review caught the last one"
    and .close == "release"
    and ([.options[].value] == ["now", "wait"])
    and (.thin | not)' "$skeleton" >/dev/null \
    || fail "the card was not built from the record the call wrote: $(cat "$skeleton")"
  # And no slot on it is left for a composer, which is the whole claim: build
  # refuses a {FILL: ...} and this card has none, so it reaches the captain
  # exactly as the call wrote it. ({TRANSLATE: ...} is the ordinary translation
  # pass every English-only string takes and is not a composer slot.)
  jq -e '[.captains_call[0] | .. | strings | select(startswith("{FILL:"))] | length == 0' \
    "$skeleton" >/dev/null \
    || fail "a record-seeded card still carried a composer slot: $(cat "$skeleton")"
  pass "compose builds a captain card from the record the call wrote"
}

test_compose_keeps_the_packet_card_for_a_call_that_wrote_no_record() {
  local home skeleton
  home=$(make_compose_home compose-card-no-record)
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a home with no card record"
  jq -e '.captains_call[0].title.en == "Rollout order"' "$skeleton" >/dev/null \
    || fail "a call with no record lost its packet-seeded card: $(cat "$skeleton")"
  pass "a call that wrote no record keeps the packet-seeded card it had"
}

# A thin call is the ordinary needs-decision PR #33 deliberately left free of
# any packet obligation. It still reaches the board - that is the point - but
# it must arrive looking like what it is.
test_compose_carries_a_thin_call_to_the_board_as_visibly_thin() {
  local home skeleton
  home=$(make_compose_home compose-card-thin)
  write_card_record "$home" '{"schema":"fm-board-card.v1","task":"gated-work","key":"captain-hold-gated-work-1","at":"2026-09-20T04:00:00Z","state":"open","thin":true,"title":"Rename the flag?","repo":"firstmate","decide":"Rename the flag?","if_nothing":"","reversible":"yes","risk":"medium","options":[],"recommend_value":"","recommend_why":"","close":"","figures":[]}'
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a home whose call wrote a thin card"
  # thin says so on its face; it carries no option of its own, so the captain
  # is never shown a choice the call did not offer (build adds the board's own
  # reconcile afterwards); and neither risk nor reversibility is claimed here,
  # because nobody assessed either.
  jq -e '.captains_call[0]
    | .thin == true and .allow_freeform == true
    and .title.en == "Rename the flag?"
    and ([.options[].value] == [])
    and (has("risk") | not) and (has("reversible") | not)
    and (has("recommend_value") | not) and (has("recommend_why") | not)' "$skeleton" >/dev/null \
    || fail "a thin call did not reach the board as thin: $(cat "$skeleton")"
  jq -e '[.captains_call[0] | .. | strings | select(startswith("{FILL:"))] | length == 0' \
    "$skeleton" >/dev/null \
    || fail "a thin card carried a composer slot the captain would never see filled"
  pass "a call that offered no options reaches the board saying so"
}

# One unreadable file must cost its own card its freshness, never the board.
# This is the opposite posture to --card-file, which refuses the hold outright:
# there a bad file stops one call being raised, here it would blank every card
# the captain has.
test_compose_survives_a_card_record_it_cannot_read() {
  local home skeleton
  home=$(make_compose_home compose-card-unreadable)
  write_card_record "$home" 'this is not json at all {'
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "an unreadable card record took the whole board down"
  jq -e '.captains_call[0].title.en == "Rollout order"' "$skeleton" >/dev/null \
    || fail "an unreadable record did not fall back to the packet card: $(cat "$skeleton")"
  pass "an unreadable card record costs its own card, never the board"
}

test_compose_ignores_a_card_record_of_a_schema_it_does_not_know() {
  local home skeleton
  home=$(make_compose_home compose-card-foreign-schema)
  write_card_record "$home" '{"schema":"something-else.v9","title":"Not ours","options":[]}'
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a card record written by something else"
  jq -e '.captains_call[0].title.en == "Rollout order"' "$skeleton" >/dev/null \
    || fail "a foreign card record was read as though it were ours: $(cat "$skeleton")"
  pass "a card record of an unknown schema is ignored rather than guessed at"
}

# The board plots every open call by how much work is stalled behind it, so
# that number has to be counted from the fleet rather than invented. The gate
# rows already name the ids each queued item is blocked by; this is that count
# and nothing else.
test_compose_counts_the_work_stalled_behind_each_call() {
  local home skeleton snap
  home=$(make_compose_home compose-blocks)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  # Two queued items wait on gated-work, one of them also on pick-route, and
  # the space after the comma is there on purpose: a blocker list is prose in
  # a field, so the count must not depend on how it was spaced.
  jq '.gates[0].blocked_by = "gated-work"
    | .gates[2].blocked_by = "gated-work, pick-route"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the blocked-by fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose queued work names its blockers"
  jq -e '.captains_call
    | ([.[] | select(.key == "gated-work") | .blocks] == [2])
    and ([.[] | select(.key == "pick-route") | .blocks] == [1])' "$skeleton" >/dev/null \
    || fail "the stalled-work count was not read from the gate rows: $(cat "$skeleton")"
  pass "compose counts the work stalled behind each call from the gate rows"
}

# Zero is an answer, not a gap. A call nothing is waiting on must say so with a
# number, because the board plots it and an absent count would place it nowhere.
test_compose_counts_zero_for_a_call_nothing_waits_on() {
  local home skeleton
  home=$(make_compose_home compose-blocks-none)
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  jq -e '[.captains_call[] | select(has("blocks") | not)] == []
    and ([.captains_call[] | select(.key == "gated-work") | .blocks] == [0])' "$skeleton" >/dev/null \
    || fail "a call nothing waits on did not carry a zero count: $(cat "$skeleton")"
  pass "a call nothing is waiting on carries a zero count rather than none"
}

# The merge lane lists every open pull request with the reason it is not a
# merge call. The reason has to come from the SAME conditions that decide
# whether a merge card exists, or the lane and the cards can disagree - and a
# lane saying "ready" beside a call that never appeared is worse than no lane.
test_compose_gives_every_open_pull_request_its_reason() {
  local home skeleton
  home=$(make_compose_home compose-merge-lane)
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  # The fixture carries one passing pull request whose task this backlog claims
  # and one failing one whose task it does not.
  jq -e '.merge_queue
    | (length == 2)
    and ([.[] | select(.num == "9") | .ready] == [true])
    and ([.[] | select(.num == "9") | has("reason")] == [false])
    and ([.[] | select(.num == "11") | .ready] == [false])
    and ([.[] | select(.num == "11") | .reason] | length == 1)' "$skeleton" >/dev/null \
    || fail "the merge lane did not carry a verdict for every open pull request: $(jq -c .merge_queue "$skeleton")"
  pass "compose gives every open pull request a merge verdict or a reason"
}

# A failing check and a pull request nothing claims are different reasons, and
# the captain has to be able to tell them apart - one is work to fix, the other
# is a record to correct.
test_compose_tells_a_failed_check_from_an_unclaimed_pull_request() {
  local home skeleton snap
  home=$(make_compose_home compose-merge-reasons)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  jq '.candidate_prs[1].task = "gated-work"' "$COMPOSE_ASSETS/snapshot.json" > "$snap" \
    || fail "cannot stage the merge-reason fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose failing pull request has a claimed task"
  jq -e '[.merge_queue[] | select(.num == "11") | .reason] == ["checks-failed"]' "$skeleton" >/dev/null \
    || fail "a failing check was not named as the reason: $(jq -c .merge_queue "$skeleton")"
  pass "compose names a failed check rather than lumping it in with unclaimed work"
}

# A worker is placed by its pull request rather than by its own state when it
# has one, because "writing" and "waiting on checks" are the same state to the
# fleet and completely different to the captain.
test_compose_places_a_worker_by_its_pull_request_when_it_has_one() {
  local home skeleton snap
  home=$(make_compose_home compose-lane-pr)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  jq '.in_flight[0].state = "working"
    | .candidate_prs[0].task = "ship-task"
    | .candidate_prs[0].checks = "pending"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the lane fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose worker is on a pull request"
  jq -e '[.underway[] | select(.id == "ship-task") | .lane] == ["pr"]' "$skeleton" >/dev/null \
    || fail "a worker waiting on checks was not placed on its pull request: $(jq -c .underway "$skeleton")"

  jq '.in_flight[0].state = "working"
    | .candidate_prs[0].task = "ship-task"
    | .candidate_prs[0].checks = "failing"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the failing-lane fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose pull request has a failed check"
  jq -e '[.underway[] | select(.id == "ship-task") | .lane] == ["failed"]' "$skeleton" >/dev/null \
    || fail "a worker whose check failed was not placed in that lane: $(jq -c .underway "$skeleton")"
  pass "compose places a worker by its pull request rather than by its own state"
}

# Every other worker is placed by what the fleet says it is doing, and a state
# with no lane keeps its own name so the board can show it rather than lose it.
test_compose_places_every_worker_it_can_and_names_the_rest() {
  local home skeleton snap
  home=$(make_compose_home compose-lane-states)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  jq '.in_flight[0].state = "blocked" | .candidate_prs = []' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the blocked fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with a blocked worker"
  jq -e '[.underway[] | select(.id == "ship-task") | .lane] == ["stuck"]' "$skeleton" >/dev/null \
    || fail "a blocked worker was not placed as stuck: $(jq -c .underway "$skeleton")"

  jq '.in_flight[0].state = "marooned" | .candidate_prs = []' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the unknown-state fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a state it has no lane for"
  jq -e '[.underway[] | select(.id == "ship-task") | .lane] == ["marooned"]' "$skeleton" >/dev/null \
    || fail "a state with no lane did not keep its own name: $(jq -c .underway "$skeleton")"
  pass "compose places every worker it can and names the state of the rest"
}

# R12. The snapshot writes a gate's blocker ids joined and cut to 120
# characters, so a gate blocked by seven or eight of them ends in an ellipsis
# with the rest gone. Counting what is left and calling it the total is the
# board claiming to know more than it read - and this number is the vertical
# axis of the decision map and the radius of the bubble.
test_compose_says_when_a_stalled_count_is_only_a_floor() {
  local home skeleton snap long
  home=$(make_compose_home compose-blocks-cut)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  # Exactly what the snapshot emits past its limit: a joined list, cut mid-id,
  # ending in the ellipsis trunc() appends.
  long="other-one,other-two,other-three,other-four,other-five,other-six,other-sev…"
  jq --arg long "$long" '.gates[0].blocked_by = $long
    | .gates[2].blocked_by = "gated-work"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the truncated fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose blocker list was cut off"
  # One gate names it outright, so the floor is 1 - and the cut gate could name
  # it too, which is exactly what makes this a floor rather than a total.
  jq -e '[.captains_call[] | select(.key == "gated-work") | {blocks, partial: (.blocks_partial == true)}]
    == [{blocks: 1, partial: true}]' "$skeleton" >/dev/null \
    || fail "a cut-off blocker list was reported as an exact count: $(jq -c '[.captains_call[] | {key, blocks, blocks_partial}]' "$skeleton")"
  pass "compose says when a stalled count is a floor rather than a total"
}

# And an untruncated list is still reported as exact, or the warning would be
# on every card and mean nothing.
test_compose_reports_an_intact_blocker_list_as_exact() {
  local home skeleton snap
  home=$(make_compose_home compose-blocks-intact)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  jq '.gates[0].blocked_by = "gated-work" | .gates[2].blocked_by = "other"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$snap" || fail "cannot stage the intact fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with intact blocker lists"
  jq -e '[.captains_call[] | select(.key == "gated-work")
    | {blocks, partial: has("blocks_partial")}] == [{blocks: 1, partial: false}]' "$skeleton" >/dev/null \
    || fail "an intact blocker list was reported as a floor: $(jq -c '[.captains_call[] | {key, blocks, blocks_partial}]' "$skeleton")"
  pass "an intact blocker list is still reported as an exact count"
}

# The compose half of R14. The note under the decision map says nothing on it
# is weighted by hand; for a card whose risk is a {FILL: ...} slot firstmate
# types in at compose time, that is false. The board has to carry which it was,
# and only compose knows.
test_compose_records_who_weighed_each_card() {
  local home skeleton
  home=$(make_compose_home compose-weighed)
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  # gated-work has a verified packet stating its own risk and reversibility, so
  # its position is the fleet's; pick-route has no packet, so both values are
  # slots firstmate fills and its position is his.
  jq -e '[.captains_call[] | select(.key == "gated-work") | .weighed_by] == ["fleet"]
    and [.captains_call[] | select(.key == "pick-route") | .weighed_by] == ["firstmate"]' \
    "$skeleton" >/dev/null \
    || fail "compose did not record who weighed each card: $(jq -c '[.captains_call[] | {key, weighed_by, risk}]' "$skeleton")"
  pass "compose records whether a card position is the fleet's or the first mate's"
}

# A packet that states reversibility but leaves risk for firstmate is still
# his position, not the fleet's: the field is about the POSITION, and the
# position needs both values. This is the same fixture the risk-slot test uses,
# read for a different property.
test_compose_marks_a_half_stated_packet_as_the_first_mates() {
  local home skeleton decision
  decision=$(printf '%s' "$COMPOSE_DECISION" | jq -c 'del(.risk)')
  home=$(make_compose_home compose-weighed-half "$decision")
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a packet whose decision block records no risk"
  jq -e '[.captains_call[] | select(.key == "gated-work")
    | {w: .weighed_by, slotted: (.risk == "{FILL: low | medium | high}")}]
    == [{w: "firstmate", slotted: true}]' "$skeleton" >/dev/null \
    || fail "a card with one value left for firstmate was marked as the fleet's: $(jq -c '[.captains_call[] | {key, weighed_by, risk}]' "$skeleton")"
  pass "a card with any value left for the first mate is marked as his"
}

# Every merge card is this case: its risk is a slot and it carries no
# reversibility at all.
test_compose_marks_every_merge_card_as_the_first_mates() {
  local home skeleton snap
  home=$(make_compose_home compose-weighed-merge)
  skeleton="$home/skeleton.json"
  snap="$home/snapshot.json"
  jq '.candidate_prs[0].task = "gated-work"' "$COMPOSE_ASSETS/snapshot.json" > "$snap" \
    || fail "cannot stage the merge fixture"
  run_board "$home" compose --snapshot "$snap" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot with a mergeable pull request"
  jq -e '[.captains_call[] | select(.type == "merge") | .weighed_by] | (length > 0) and all(. == "firstmate")' \
    "$skeleton" >/dev/null \
    || fail "a merge card was not marked as the first mate's assessment: $(jq -c '[.captains_call[] | {key, type, weighed_by}]' "$skeleton")"
  pass "every merge card is marked as the first mate's assessment"
}

test_build_names_the_unfilled_card_slot_it_refuses() {
  local home skeleton filled board out rc
  home=$(make_compose_home compose-unfilled-slot)
  skeleton="$home/skeleton.json"
  filled="$home/filled.json"
  board="$home/.lavish/bearings-board.html"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  fill_skeleton "$skeleton" "$filled"
  # One slot left unresolved: build must name that slot, not report it as an
  # unknown enum value or a recommendation that matches no option.
  jq '.captains_call[1].risk = "{FILL: low | medium | high}"
    | .captains_call[1].recommend_value = "{FILL: recommend one of option-a | option-b}"' \
    "$filled" > "$filled.tmp" && mv "$filled.tmp" "$filled"
  set +e; out=$(run_board "$home" build "$filled" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "build accepted a card with unresolved slots"
  assert_contains "$out" "captains_call.1.risk: {FILL: low | medium | high}" \
    "build did not name the unfilled risk slot: $out"
  assert_contains "$out" "captains_call.1.recommend_value: {FILL: recommend one of" \
    "build did not name the unfilled recommendation slot: $out"
  assert_contains "$out" "placeholders" "build did not name placeholders as the reason: $out"
  case "$out" in
    *"does not satisfy"*) fail "build reported a validator error instead of the unfilled slot: $out" ;;
  esac
  assert_absent "$board" "a payload with unresolved slots still produced a board"
  pass "build names the unfilled card slot instead of a validator enum error"
}

test_compose_cards_only_the_holds_this_home_owns() {
  local home skeleton
  home=$(make_compose_home compose-mate-hold)
  # The snapshot keys a secondmate-owned hold by the mate BARE local task id,
  # so carding it would either collide with this home's live hold of the same
  # name or be unanswerable through the keyed intake.
  jq '.decisions_open += [{id: "mate-a/pick-route", key: "pick-route", verb: "captain-hold",
        summary: "Pick the route: the mate needs a call", owner: "mate-a"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a secondmate-owned hold"
  jq -e '
    ([.captains_call[].key] == ["gated-work", "pick-route", "merge.ship-task"])
    and ([.captains_call[] | select(.key == "pick-route")] | length == 1)
    and (.captains_call[1].title.en == "Pick the route")
  ' "$skeleton" >/dev/null || fail "a secondmate-owned hold was carded: $(cat "$skeleton")"
  pass "compose cards only the captain holds this home can route"
}

test_compose_never_dispatches_a_charted_row_this_home_does_not_own() {
  local home skeleton
  home=$(make_compose_home compose-mate-gate)
  jq '.gates += [{id: "tidy-docs", title: "Tidy the docs", blocked_by: "-", reason: "-",
        owner: "mate-a", filed: "2026-09-17"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a secondmate-owned gate"
  # The row stays on the board, but nothing about it can enter dispatch.charted
  # or borrow this home's repo for the mate bare local id.
  jq -e '
    (.charted | map(select(.dispatchable)) | map(.id)) == ["plain-queued"]
    and ([.charted[] | select(.title.en == "Tidy the docs")] | length == 1)
    and (.charted[] | select(.title.en == "Tidy the docs")
      | .dispatchable == false and .repo == null and (.id | contains("mate-a"))
      and .id != "tidy-docs")
  ' "$skeleton" >/dev/null || fail "a secondmate-owned gate was offered for dispatch: $(cat "$skeleton")"
  pass "compose never dispatches a Charted Next row this home does not own"
}

test_compose_carries_the_secondmate_integrity_warnings() {
  local home skeleton
  home=$(make_compose_home compose-mate-warnings)
  jq '.secondmates = [
        {id: "mate-a", state: "unknown", doing: "Current home state unavailable",
         provenance: "registered-table", freshness: "stale", age_seconds: 900,
         contradiction: false, reason: "home ledger unreadable"},
        {id: "mate-b", state: "no_active_work", doing: "No active child work",
         provenance: "structured-home", freshness: "fresh", age_seconds: 5,
         contradiction: false, reason: "-"}]
      | .secondmate_reconcile = [
        {id: "mate-c", spawn_gen: 3, host: "box", kind: "orphan_in_flight", ids: ["t-1", "t-2"]}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying secondmate integrity rows"
  jq -e '
    # The unavailable home and the mismatch notice are warning rows; a healthy
    # home is not an alarm and stays off Charted Next.
    ([.charted[] | select(.kind == "warning") | .title.en]
      == ["in-flight backlog item has no child metadata",
          "Secondmate home mate-a is unavailable",
          "Secondmate home mate-c reports an inventory mismatch"])
    and ([.charted[] | select(.title.en | test("mate-b"))] | length == 0)
    and (.charted[] | select(.title.en | test("mate-a"))
      | .dispatchable == false and .filed == null and .repo == null
      and .reason.en == "Current home state unavailable")
    and (.charted[] | select(.title.en | test("mate-c"))
      | .dispatchable == false and .reason.en == "orphan_in_flight: t-1, t-2")
  ' "$skeleton" >/dev/null || fail "the secondmate integrity notices are missing: $(cat "$skeleton")"
  pass "compose carries unavailable secondmate homes and mismatch notices as warnings"
}

test_compose_badges_a_warning_only_for_a_synthesized_gate() {
  local home skeleton
  home=$(make_compose_home compose-warning-id)
  # An ordinary queued item whose hand-written hold reason happens to read like
  # a synthesized notice is still queued work, not a repair notice.
  jq '.gates += [{id: "audit-stock", title: "Audit the stock", blocked_by: "-",
        reason: "main inventory", owner: "(main)", filed: "2026-09-14"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose gate reason reads like a notice"
  jq -e '
    (.charted[] | select(.id == "audit-stock") | .kind == "queued")
    and (.charted[] | select(.id == "main-inventory") | .kind == "warning")
  ' "$skeleton" >/dev/null || fail "a hold reason badged an ordinary row as a warning: $(cat "$skeleton")"
  pass "compose badges a warning from the synthesized gate id alone"
}

test_compose_drops_a_filed_date_the_payload_contract_refuses() {
  local home skeleton
  home=$(make_compose_home compose-filed)
  # `since` is a hand-written backlog word, so it reaches the snapshot as
  # whatever was typed; the payload contract takes YYYY-MM-DD or that date with
  # a UTC timestamp, and anything else must drop to null rather than refuse the
  # whole board.
  jq '.gates[0].filed = "last week"
      | .gates[1].filed = "2026-02-30"
      | .gates[2].filed = "2026-09-13T04:05:06Z"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying an unusable filed word"
  jq -e '
    (.charted[0] | .id == "plain-queued" and .filed == null)
    and (.charted[1] | .id == "live-gate" and .filed == null)
    and (.charted[2] | .id == "later-call" and .filed == "2026-09-13T04:05:06Z")
  ' "$skeleton" >/dev/null || fail "an unusable filed date was not dropped: $(cat "$skeleton")"
  pass "compose drops a filed date the payload contract refuses"
}

test_compose_degrades_every_blank_snapshot_string_to_its_row_identity() {
  local home skeleton
  home=$(make_compose_home compose-blank-strings)
  # A metadata-only backlog row parses to an empty title, and the payload
  # validator refuses an empty `en`; one such row must degrade its own row
  # rather than refuse the whole board.
  jq '.landed[0].what = ""
      | .gates[0].title = ""
      | .gates[2].reason = ""
      | .decisions_open += [{id: "ghost-hold", key: "ghost-hold", verb: "captain-hold",
          summary: "", owner: "(main)"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying blank strings"
  jq -e '
    (.landed[0] | .id == "done-a" and .what == {en: "done-a", hant: "{TRANSLATE: done-a}"})
    and (.charted[0] | .id == "plain-queued" and .title.en == "plain-queued")
    and (.charted[2] | .id == "later-call" and .reason == "")
    and (.captains_call[] | select(.key == "ghost-hold") | .title.en == "ghost-hold")
  ' "$skeleton" >/dev/null || fail "a blank snapshot string did not degrade to its row id: $(cat "$skeleton")"
  pass "compose degrades every blank snapshot string to its own row identity"
}

test_compose_keeps_a_secondmate_landed_row_off_this_homes_books() {
  local home skeleton filled board out
  home=$(make_compose_home compose-mate-landed)
  # The snapshot keeps a mate Done row under its BARE local id, which can equal
  # a live local captain hold; borrowing this home's repo mislabels it and the
  # bare id makes build drop that live card as already landed.
  jq '.landed += [{id: "gated-work", what: "Mate landed the same-named task",
        artifact: "-", owner: "mate-a"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  filled="$home/filled.json"
  board="$home/.lavish/bearings-board.html"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a secondmate landed row"
  jq -e '
    (.landed[] | select(.owner == "mate-a")
      | .id == "mate-a/gated-work" and .repo == null
      and .what.en == "Mate landed the same-named task")
    and ([.landed[].id] | index("gated-work") == null)
  ' "$skeleton" >/dev/null || fail "a mate landed row borrowed this home's books: $(cat "$skeleton")"
  fill_skeleton "$skeleton" "$filled"
  out=$(run_board "$home" build "$filled" 2>&1) || fail "build refused the filled skeleton: $out"
  extract_payload "$board" | jq -e '[.captains_call[].key] | index("gated-work") != null' >/dev/null \
    || fail "the mate landed row dropped this home's live decision card: $out"
  pass "a secondmate landed row keeps its own id and never drops a local card"
}

test_compose_cards_a_merge_only_for_a_pr_this_backlog_claims() {
  local home skeleton long
  home=$(make_compose_home compose-merge-owner)
  long=$(printf 'a%.0s' $(seq 1 130))
  # candidate_prs enumerates every open PR in the repo and derives `task` from
  # the head branch alone, so a mate's branch, a stale branch, and a nested or
  # over-long branch all arrive here claiming to be task ids.
  jq --arg long "$long" '.candidate_prs += [
        {num: "13", repo: "example/firstmate", task: "mate-only-task",
         url: "https://github.com/example/firstmate/pull/13",
         review: "APPROVED", mergeable: "MERGEABLE", checks: "passing"},
        {num: "14", repo: "example/firstmate", task: "release/2026-09",
         url: "https://github.com/example/firstmate/pull/14",
         review: "APPROVED", mergeable: "MERGEABLE", checks: "passing"},
        {num: "15", repo: "example/firstmate", task: "發佈 #2",
         url: "https://github.com/example/firstmate/pull/15",
         review: "APPROVED", mergeable: "MERGEABLE", checks: "passing"},
        {num: "16", repo: "example/firstmate", task: $long,
         url: "https://github.com/example/firstmate/pull/16",
         review: "APPROVED", mergeable: "MERGEABLE", checks: "passing"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  # None of those four may card, and none may refuse the whole skeleton either.
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying unkeyable candidate PRs"
  jq -e '
    ([.captains_call[] | select(.type == "merge") | .key] == ["merge.ship-task"])
    and ([.captains_call[].key] | map(select(test("^[A-Za-z0-9._-]{1,128}$") | not)) | length == 0)
  ' "$skeleton" >/dev/null || fail "a PR no local task claims was carded: $(cat "$skeleton")"
  pass "compose cards a merge only for a PR this home's backlog claims"
}

test_compose_suppresses_merge_cards_and_warns_when_the_backlog_is_unreadable() {
  local home skeleton
  home=$(make_compose_home compose-merge-no-backlog)
  # A symlinked backlog is the documented refusal of bin/fm-tasks-axi.sh: no
  # record can be read, so ownership is UNKNOWN rather than absent.
  mv "$home/data/backlog.md" "$home/data/real-backlog.md"
  ln -s "$home/data/real-backlog.md" "$home/data/backlog.md"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot when the backlog could not be read"
  jq -e '
    ([.captains_call[] | select(.type == "merge")] | length == 0)
    and (.charted[] | select(.id == "backlog-unreadable")
      | .kind == "warning" and .dispatchable == false and .repo == null
      and (.reason.en | test("merge cards are suppressed")))
  ' "$skeleton" >/dev/null \
    || fail "an unreadable backlog produced a board with no warning: $(cat "$skeleton")"
  pass "an unreadable backlog suppresses merge cards and says so on the board"
}

test_compose_degrades_a_packet_copy_object_with_a_blank_member() {
  local home skeleton decision
  # fm-packet.sh verify accepts {"en": "...", "hant": ""} and its card keeps the
  # object, so a worker who types an empty 繁體 string must degrade that one
  # field rather than refuse the whole board.
  decision=$(printf '%s' "$COMPOSE_DECISION" | jq -c '
    .title = {en: "Rollout order", hant: ""}
    | .options[0].label = {en: "Canary first", hant: "", hans: "金丝雀优先"}')
  home=$(make_compose_home compose-packet-blank-hant "$decision")
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a verified packet whose copy object has a blank member"
  jq -e '.captains_call[0]
    | .key == "gated-work"
    and .title == {en: "Rollout order", hant: "{TRANSLATE: Rollout order}"}
    and (.options[0].label | .en == "Canary first" and .hant == "{TRANSLATE: Canary first}"
      and .hans == "金丝雀优先")
  ' "$skeleton" >/dev/null || fail "a blank packet translation was not degraded: $(cat "$skeleton")"
  pass "compose degrades a packet copy object whose translation is blank"
}

# What an option CHANGES is inside the tab strip the captain was shown, so it is
# captain-facing copy like the label beside it. A panel whose label switches
# while "what it buys" stands still in English is the half-switched surface the
# standing rule forbids, so compose owes those fields a translation slot too.
test_compose_asks_for_a_translation_of_what_an_option_changes() {
  local home skeleton decision
  decision=$(printf '%s' "$COMPOSE_DECISION" | jq -c '
    .options[0] += {
      buys: "One behaviour to reason about.",
      files: ["bin/example.sh"],
      changes: {added: ["a merged-record rule"], removed: ["the stdout probe"],
                unchanged: [{en: "the answer channel", hant: "answer 通道"}]}}')
  home=$(make_compose_home compose-option-detail "$decision")
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a packet whose option says what it changes"
  jq -e '.captains_call[0].options[0]
    | .buys == {en: "One behaviour to reason about.", hant: "{TRANSLATE: One behaviour to reason about.}"}
    and .changes.added == [{en: "a merged-record rule", hant: "{TRANSLATE: a merged-record rule}"}]
    and .changes.removed == [{en: "the stdout probe", hant: "{TRANSLATE: the stdout probe}"}]
    # one the worker already translated is left alone
    and .changes.unchanged == [{en: "the answer channel", hant: "answer 通道"}]
    # the files it touches are paths, and a path is the same path in every language
    and .files == ["bin/example.sh"]
  ' "$skeleton" >/dev/null \
    || fail "what the option changes got no translation slot: $(cat "$skeleton")"
  pass "compose asks for a translation of what an option buys and changes"
}

test_compose_never_dispatches_a_charted_row_under_a_rewritten_id() {
  local home skeleton long
  home=$(make_compose_home compose-charted-id)
  long=$(printf 'b%.0s' $(seq 1 140))
  # A hand-written backlog row may carry any non-space id, and that id IS the
  # dispatch channel, so an id the intake could not resolve must not be offered
  # under a rewritten one - and must not refuse the board either.
  jq --arg long "$long" '.gates += [
        {id: "feat/login", title: "Add login", blocked_by: "-", reason: "-",
         owner: "(main)", filed: "2026-09-16"},
        {id: "修復登入", title: "Fix the login", blocked_by: "-", reason: "-",
         owner: "(main)", filed: "2026-09-16"},
        {id: "送出報告", title: "Send the report", blocked_by: "-", reason: "-",
         owner: "(main)", filed: "2026-09-16"},
        {id: $long, title: "A very long id", blocked_by: "-", reason: "-",
         owner: "(main)", filed: "2026-09-16"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying unkeyable gate ids"
  jq -e '
    # Only the row whose real id is already a key may be dispatched, and it
    # keeps that exact id.
    ([.charted[] | select(.dispatchable) | .id] == ["plain-queued"])
    # Every other row is still on the board, under a title the captain can read.
    and ([.charted[] | select(.title.en == "Add login" or .title.en == "Fix the login"
      or .title.en == "Send the report" or .title.en == "A very long id")] | length == 4)
    and ([.charted[].id] | map(select(test("^[A-Za-z0-9._-]{1,128}$") | not)) | length == 0)
  ' "$skeleton" >/dev/null || fail "a rewritten gate id was offered for dispatch: $(cat "$skeleton")"
  pass "compose never offers a Charted Next row for dispatch under a rewritten id"
}

test_compose_warns_instead_of_carding_a_hold_it_cannot_key() {
  local home skeleton
  home=$(make_compose_home compose-unkeyable-hold)
  # data/backlog.md is hand-maintained and its row id is any non-space run, so
  # a captain hold on a slashed or non-ASCII id is ordinary usage - and that id
  # is the address bin/fm-captain-hold.sh would have to answer to.
  jq '.decisions_open += [
        {id: "feat/login", key: "feat/login", verb: "captain-hold",
         summary: "Pick the login route: the captain decides", owner: "(main)"},
        {id: "修復登入", key: "修復登入", verb: "captain-hold",
         summary: "Fix the login: the captain decides", owner: "(main)"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a hold it cannot key"
  jq -e '
    # The rest of the board still composes, and every key stays addressable.
    ([.captains_call[].key] == ["gated-work", "pick-route", "merge.ship-task"])
    and ([.captains_call[].key] | map(select(test("^[A-Za-z0-9._-]{1,128}$") | not)) | length == 0)
    # Neither unanswerable hold disappears: each is a warning row naming it.
    and ([.charted[] | select(.kind == "warning") | .title.en]
      | map(select(test("feat/login") or test("修復登入"))) | length == 2)
    and (.charted[] | select(.title.en | test("feat/login"))
      | .dispatchable == false and .repo == null and (.reason.en | test("not a routable key")))
  ' "$skeleton" >/dev/null || fail "an unkeyable hold was carded or lost: $(cat "$skeleton")"
  pass "compose warns instead of carding a captain hold it cannot key"
}

test_compose_consolidates_a_task_held_more_than_once() {
  local home skeleton
  home=$(make_compose_home compose-repeat-hold)
  # data/backlog.md is hand-maintained; a copy-pasted row keeps its id, and two
  # cards under one key are two answers the keyed intake resolves to one task.
  jq '.decisions_open += [{id: "pick-route", key: "pick-route", verb: "captain-hold",
        summary: "Pick the route: and also pick the rollout window", owner: "(main)"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot holding one task twice"
  jq -e '
    ([.captains_call[].key] == ["gated-work", "pick-route", "merge.ship-task"])
    and (.captains_call[1] | .key == "pick-route" and (.decide.en | test("held 2 times")))
  ' "$skeleton" >/dev/null || fail "a repeated hold was not consolidated: $(cat "$skeleton")"
  pass "compose consolidates a task held more than once into one card"
}

test_compose_refuses_to_card_a_merge_two_prs_claim() {
  local home skeleton
  home=$(make_compose_home compose-merge-collision)
  # headRefName carries no repo or fork owner, so two open PRs can derive the
  # same task; a merge answer keyed to that task names only one of them.
  jq '.candidate_prs += [{num: "21", repo: "example/other", task: "ship-task",
        url: "https://github.com/example/other/pull/21",
        review: "APPROVED", mergeable: "MERGEABLE", checks: "passing"}]' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot whose PRs collide on one task"
  jq -e '
    ([.captains_call[] | select(.type == "merge")] | length == 0)
    and (.charted[] | select(.id == "merge-collision-ship-task")
      | .kind == "warning" and .dispatchable == false
      and (.reason.en | test("pull/9") and test("pull/21")))
  ' "$skeleton" >/dev/null || fail "a colliding merge was carded or hidden: $(cat "$skeleton")"
  pass "compose refuses to card a merge two pull requests claim, and says so"
}

test_compose_drops_a_link_the_payload_contract_refuses() {
  local home skeleton
  home=$(make_compose_home compose-bad-links)
  # A merge pr_url arrives as "-" when the snapshot has no url, and a landed
  # artifact is scanned out of a hand-written Done line, so neither is a
  # guaranteed well-formed link.
  jq '.landed[0].artifact = "https://.bad/x"
      | .candidate_prs[0].url = "-"' \
    "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a snapshot carrying a malformed link"
  jq -e '
    (.landed[0] | .id == "done-a" and (has("pr_url") | not))
    and (.captains_call[] | select(.key == "merge.ship-task") | has("pr_url") | not)
  ' "$skeleton" >/dev/null || fail "a malformed link was carried into the payload: $(cat "$skeleton")"
  pass "compose drops a link the payload contract refuses instead of aborting"
}

test_compose_validates_the_skeleton_on_stdout_too() {
  local home out rc
  home=$(make_compose_home compose-stdout-validate)
  jq '.home = ""' "$COMPOSE_ASSETS/snapshot.json" > "$home/snapshot.json"
  set +e; out=$(run_board "$home" compose --snapshot "$home/snapshot.json" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "compose emitted an unvalidated skeleton on stdout"
  assert_contains "$out" "does not satisfy fm-bearings-board.v1" "compose did not name the validator as the reason: $out"
  case "$out" in
    *'"schema"'*) fail "compose still printed the refused skeleton: $out" ;;
  esac
  pass "compose validates the skeleton before printing it to stdout"
}

test_compose_decodes_a_quoted_backlog_title() {
  local home skeleton
  home=$(make_compose_home compose-quoted-title)
  sed -i.bak 's/^- \[ \] pick-route - Pick the route /- [ ] pick-route - Pick the "fast" \\ route /' "$home/data/backlog.md"
  rm -f "$home/data/backlog.md.bak"
  grep -q 'Pick the "fast" \\ route' "$home/data/backlog.md" || fail "the fixture backlog title was not rewritten"
  skeleton="$home/skeleton.json"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused a backlog whose title needs quoting"
  jq -e '.captains_call[1] | .key == "pick-route" and .title.en == "Pick the \"fast\" \\ route"
    and .title.hant == "{TRANSLATE: Pick the \"fast\" \\ route}"' "$skeleton" >/dev/null \
    || fail "the quoted title reached the card with its escapes intact: $(cat "$skeleton")"
  pass "compose decodes a quoted backlog title instead of carrying its escapes"
}

test_skeleton_fails_build_until_its_placeholders_are_filled() {
  local home skeleton filled board out rc
  home=$(make_compose_home compose-build)
  skeleton="$home/skeleton.json"
  filled="$home/filled.json"
  board="$home/.lavish/bearings-board.html"
  run_board "$home" compose --snapshot "$COMPOSE_ASSETS/snapshot.json" --out "$skeleton" >/dev/null \
    || fail "compose refused the recorded snapshot"
  # The skeleton is structurally valid but still a skeleton: check names every
  # placeholder and build refuses it because of them.
  set +e; out=$(run_board "$home" compose --check "$skeleton" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "compose --check passed a skeleton full of placeholders"
  assert_contains "$out" "captains_call.1.decide.en: {FILL: decide}" "check did not list the decide placeholder: $out"
  assert_contains "$out" "underway.0.name.hant: {TRANSLATE: Ship the thing}" "check did not list the translation slot: $out"
  assert_contains "$out" "captains_call.2.risk: {FILL: low | medium | high}" "check did not list the merge risk: $out"
  set +e; out=$(run_board "$home" build "$skeleton" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "build accepted a skeleton with placeholders"
  assert_contains "$out" "placeholders" "build did not name the placeholders as the reason: $out"
  assert_absent "$board" "a refused skeleton still produced a board"
  # Filled in, the same payload passes check and builds.
  fill_skeleton "$skeleton" "$filled"
  out=$(run_board "$home" compose --check "$filled") || fail "check refused the filled payload: $out"
  assert_contains "$out" "placeholders: none" "check did not report the filled payload clean: $out"
  out=$(run_board "$home" build "$filled" 2>&1) || fail "build refused the filled skeleton: $out"
  assert_present "$board" "the filled skeleton produced no board"
  extract_payload "$board" | jq -e '
    .lang == "hant"
    and (.underway[0].name.hant == "譯: Ship the thing")
    and ([.captains_call[] | select(.type == "decision") | .options[] | select(.value == "reconcile")] | length == 2)
    and (.captains_call[2].risk == "low")
  ' >/dev/null || fail "the built board did not carry the filled copy"
  pass "a skeleton fails build until filled, and the filled skeleton builds"
}

# --- the board a clone with nothing installed gets ---------------------------
# The captain's board used to be hosted by lavish-axi, so a machine without it
# had a live server, a built page, and no way to open either. These cases hold
# the whole of what replaced that: the build needs no external tool, the home's
# own server hosts the page, and the address it prints serves the board the
# build just wrote.
#
# The tool is REMOVED from the path rather than stubbed, because a stub proves
# only that the stub was not called and this has to prove the tool is not
# needed. It is removed by dropping every directory that actually carries it,
# so the case is identical on a machine that has lavish-axi installed and on
# one that never did - the premise is then asserted rather than assumed.

path_without_lavish() {
  local dir out="" IFS=:
  for dir in $PATH; do
    [ -x "$dir/lavish-axi" ] && continue
    out="${out:+$out:}$dir"
  done
  printf '%s\n' "$out"
}

run_board_no_lavish() {  # <home> <args...>
  local home=$1
  shift
  PATH="$(path_without_lavish)" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

# Prints the status code; writes the body to <outfile> byte for byte, which a
# command substitution could not do - it would eat the page's last newline and
# turn a faithful serve into a failing diff.
http_get() {  # <url> <outfile>
  node -e '
    const http = require("node:http");
    const fs = require("node:fs");
    http.get(process.argv[1], (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        fs.writeFileSync(process.argv[2], Buffer.concat(chunks));
        process.stdout.write(String(res.statusCode));
      });
    }).on("error", (e) => { process.stderr.write(String(e.message)); process.exit(1); });
  ' "$1" "$2"
}

stop_board_server() {  # <home>
  FM_HOME="$1" "$ROOT/bin/fm-board-live.sh" stop >/dev/null 2>&1 || true
}

test_a_board_builds_and_is_served_with_no_lavish_installed() {
  local home data board out url status
  command -v node >/dev/null 2>&1 || { pass "skip: node not found"; return 0; }
  home=$(make_home no-lavish)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  PATH="$(path_without_lavish)" command -v lavish-axi >/dev/null 2>&1 \
    && fail "the no-lavish fixture can still reach lavish-axi, so it proves nothing"

  out=$(run_board_no_lavish "$home" build "$data" 2>&1) \
    || { stop_board_server "$home"; fail "a board could not be built without lavish-axi: $out"; }
  assert_present "$board" "build reported success without a board"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "bound: " "build did not name the channel the answer lands on: $out"
  assert_contains "$out" "url: http://127.0.0.1:" "build did not print a URL to open: $out"
  case $out in
    *lavish-axi*) stop_board_server "$home"; fail "a build that needs no lavish-axi still talked about it: $out" ;;
  esac

  url=$(printf '%s\n' "$out" | sed -n 's/^url: //p')
  status=$(http_get "$url" "$home/served.html") \
    || { stop_board_server "$home"; fail "nothing is serving the board at $url"; }
  assert_equals 200 "$status" "the board's own address did not serve the board"
  # What is served IS the board that was built, not a second rendering of it.
  diff -q "$board" "$home/served.html" >/dev/null \
    || { stop_board_server "$home"; fail "the served page is not the board file the build wrote"; }

  out=$(run_board_no_lavish "$home" url) \
    || { stop_board_server "$home"; fail "url failed without lavish-axi: $out"; }
  assert_equals "$url" "$out" "url printed a different address from the one build printed"
  stop_board_server "$home"
  pass "a clone with no lavish-axi builds the board, gets a URL, and that URL serves it"
}

test_url_reads_the_live_session_listing() {
  local home data board out rc
  home=$(make_home url)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  set +e; out=$(run_board "$home" url --lavish 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "url succeeded before any board was built"
  assert_contains "$out" "no board has been built" "url did not explain the missing board: $out"
  write_valid_payload "$data"
  run_board "$home" build --lavish "$data" >/dev/null || fail "a valid payload did not build"
  out=$(run_board "$home" url --lavish) || fail "url failed for a built, open board: $out"
  assert_contains "$out" "http://" "url did not print the session URL: $out"
  end_session_as_captain "$home"
  set +e; out=$(run_board "$home" url --lavish 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "url printed a URL for a session the captain ended"
  pass "url --lavish prints the open session's URL and refuses when none is open"
}

test_path_is_stable_and_home_scoped
test_a_board_builds_and_is_served_with_no_lavish_installed
test_build_refuses_malformed_payloads_before_touching_the_board
test_charted_kind_is_optional_and_accepts_both_values
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
test_build_reopens_a_session_the_captain_ended
test_build_reopens_when_an_opened_session_ends_before_listing
test_name_support_probe_never_lists_before_the_session_is_established
test_name_support_probe_follows_what_the_release_advertises
test_build_refuses_to_arm_when_the_session_stays_ended
test_build_starts_a_listener_for_an_already_armed_board
test_build_drops_decision_cards_whose_subject_already_landed
test_build_keeps_a_decision_absent_from_the_main_backlog
test_build_fails_when_reconcile_cannot_establish_a_listener
test_every_decision_card_carries_the_reconcile_choice
test_build_refuses_a_payload_that_occupies_the_reconcile_value
test_build_refuses_a_nondecision_reconcile_value
test_build_accepts_trilingual_copy_and_five_question_fields
test_build_refuses_malformed_copy_and_card_fields
test_compose_maps_every_section_from_the_recorded_snapshot
test_compose_cards_every_live_hold_and_merge_ready_pr
test_compose_lang_and_snapshot_arguments
test_compose_seeds_a_packet_card_without_a_recorded_project
test_compose_gives_a_packetless_card_the_pull_requests_links
test_compose_reads_the_pr_tab_names_from_the_forge
test_compose_drops_an_unparseable_pr_record
test_compose_degrades_a_blank_run_detail_to_the_state_word
test_compose_cards_no_merge_for_a_pr_without_an_owning_task
test_compose_validates_the_skeleton_on_stdout_too
test_compose_consolidates_a_task_held_more_than_once
test_compose_refuses_to_card_a_merge_two_prs_claim
test_compose_drops_a_link_the_payload_contract_refuses
test_compose_warns_instead_of_carding_a_hold_it_cannot_key
test_compose_degrades_a_packet_copy_object_with_a_blank_member
test_compose_asks_for_a_translation_of_what_an_option_changes
test_compose_never_dispatches_a_charted_row_under_a_rewritten_id
test_compose_cards_a_merge_only_for_a_pr_this_backlog_claims
test_compose_suppresses_merge_cards_and_warns_when_the_backlog_is_unreadable
test_compose_drops_a_filed_date_the_payload_contract_refuses
test_compose_degrades_every_blank_snapshot_string_to_its_row_identity
test_compose_keeps_a_secondmate_landed_row_off_this_homes_books
test_compose_cards_only_the_holds_this_home_owns
test_compose_never_dispatches_a_charted_row_this_home_does_not_own
test_compose_carries_the_secondmate_integrity_warnings
test_compose_badges_a_warning_only_for_a_synthesized_gate
test_compose_leaves_the_omitted_charted_counts_to_the_composer
test_compose_slots_the_risk_a_packet_leaves_out
test_compose_builds_the_card_the_call_wrote_rather_than_rebuilding_it
test_compose_keeps_the_packet_card_for_a_call_that_wrote_no_record
test_compose_carries_a_thin_call_to_the_board_as_visibly_thin
test_compose_survives_a_card_record_it_cannot_read
test_compose_ignores_a_card_record_of_a_schema_it_does_not_know
test_compose_counts_the_work_stalled_behind_each_call
test_compose_counts_zero_for_a_call_nothing_waits_on
test_compose_says_when_a_stalled_count_is_only_a_floor
test_compose_reports_an_intact_blocker_list_as_exact
test_compose_records_who_weighed_each_card
test_compose_marks_a_half_stated_packet_as_the_first_mates
test_compose_marks_every_merge_card_as_the_first_mates
test_compose_gives_every_open_pull_request_its_reason
test_compose_tells_a_failed_check_from_an_unclaimed_pull_request
test_compose_places_a_worker_by_its_pull_request_when_it_has_one
test_compose_places_every_worker_it_can_and_names_the_rest
test_build_names_the_unfilled_card_slot_it_refuses
test_compose_decodes_a_quoted_backlog_title
test_skeleton_fails_build_until_its_placeholders_are_filled
test_url_reads_the_live_session_listing
test_ack_records_and_clears_what_the_captain_clicked
test_ack_refuses_a_refusal_with_no_reason_and_a_key_that_is_not_one
test_compose_carries_the_refusal_to_the_row_the_captain_clicked
test_compose_acknowledges_a_card_and_a_charted_row_by_their_own_keys
test_compose_carries_the_click_stamp_the_page_ages_from
test_compose_ignores_a_malformed_acknowledgement_instead_of_losing_the_board
test_compose_survives_a_record_that_breaks_the_acknowledgement_merge
test_compose_keeps_a_record_whose_key_is_absent_from_the_skeleton
test_a_whitespace_only_refusal_reason_is_refused
test_a_flag_with_no_value_explains_itself
test_the_payload_contract_refuses_an_unknown_acknowledgement_kind
test_a_captured_board_answer_acknowledges_every_key_it_named
test_the_built_board_names_no_remote_host_to_fetch_from
