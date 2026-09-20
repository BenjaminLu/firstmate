#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics AND
# the deterministic payload skeleton, so the invoking agent's per-run work stays
# "fill the skeleton's prose and translations, run build" - the agent never
# hand-writes the whole payload and never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh compose [--lang en|hant|hans] [--out <file>] [--snapshot <file>]
#   fm-bearings-board.sh compose --check <data.json>
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh derive <data.json> [--out <file>] [--endpoint <ws-url>]
#   fm-bearings-board.sh ack <key> (--acting | --refused --why-file <path> | --clear)
#   fm-bearings-board.sh path
#   fm-bearings-board.sh url
#   fm-bearings-board.sh open
#
# build      Refuse any leftover compose placeholder (naming every one), then
#            validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              live: <ws endpoint>           (the board subscribes to fleet
#                                            events and repaints as they land)
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# compose    Print an fm-bearings-board.v1 payload SKELETON mapped
#            deterministically from `bin/fm-bearings-snapshot.sh --json`
#            (or the recorded snapshot named by --snapshot), so the composer
#            fills prose and translations instead of hand-writing the whole
#            payload. Structured state maps as follows: every in_flight row
#            becomes an Underway row (name from the snapshot's durable label,
#            doing from its run detail, or its state word when the detail is
#            blank); every landed row becomes a Landed row
#            (pr_url when its artifact is an https link); every gate becomes
#            a Charted Next row, `warning` and non-dispatchable for the
#            action-free integrity notices (the parenthesised synthesized
#            gates) and `queued` otherwise, with dispatchable true only when
#            the gate is this home's own, its real id is already a routable
#            key, and it names no blocker and no hold reason, and with a
#            reason naming the blocker when the gate has one but no hold
#            reason; a row whose real id is not a routable key keeps its place
#            on the board under a display slug but is never offered for
#            dispatch, because the `dispatch.charted` intake resolves the id
#            against the backlog and could not resolve a rewritten one; every
#            unavailable or externally held secondmate home and every
#            secondmate inventory-mismatch notice becomes a non-dispatchable
#            `warning` Charted Next row, so a repair notice can never go
#            missing from the board; every live
#            captain hold THIS HOME OWNS whose task id is already a routable
#            key becomes exactly one decision card keyed by that id, while one
#            whose id is not becomes a non-dispatchable `warning` Charted Next
#            row naming it, because a card the keyed intake could not address
#            is unanswerable; every merge-ready candidate PR (checks
#            passing, mergeable, review not CHANGES_REQUESTED, present only
#            under the snapshot's --include-prs) that a task in THIS home's
#            backlog claims becomes a merge card keyed merge.<task-id> with
#            pr_url set and risk left for the composer. A card key is ONE
#            intake address, so the skeleton never carries two cards under it:
#            a task held more than once consolidates into one card whose
#            decide slot says how many questions it must answer, and two
#            merge-ready PRs claiming one task get no card at all plus a
#            non-dispatchable `warning` Charted Next row naming both, because
#            either click would act on whichever PR the task record names. Nothing this home
#            cannot route back to one of its own tasks is dispatched or keyed:
#            a PR gets a card only when this home's backlog record for its
#            task can be read and the resulting key satisfies the payload
#            contract, so a mate's `fm/<their-task>` branch, a stale branch,
#            and a nested or otherwise unkeyable branch name all get no card
#            instead of a card the keyed intake cannot resolve or a key that
#            refuses the whole skeleton. An unreadable backlog is unknown
#            ownership, not absent ownership: it suppresses every merge card
#            AND adds one non-dispatchable `warning` Charted Next row saying
#            so, so it can never look like a clean board. A secondmate-owned
#            hold gets no card
#            (its snapshot key is the mate's bare local task id, which
#            `bin/fm-captain-hold.sh` would resolve against this home's
#            backlog), a secondmate-owned gate is emitted owner-qualified,
#            repo-less, and never dispatchable, and a secondmate-owned landed
#            row is owner-qualified and repo-less too, so a mate's bare local
#            id can never label itself with this home's repo or drop this
#            home's live decision card as already landed. Every captain-facing
#            string passes through one guard that substitutes the row's own
#            durable identity when the snapshot value is empty or absent -
#            including a packet copy object whose own en or hant is blank - so
#            a blank title degrades that row instead of refusing the whole
#            skeleton, and a gate's `filed` is normalized to null unless it
#            matches the accepted date shapes, and a pr_url is emitted only
#            when it satisfies the same link rule the validator applies, so one
#            hand-written `since` word or one malformed link cannot refuse the
#            board either. A held task's title,
#            repo, and kind come from this home's backlog record when
#            `bin/fm-tasks-axi.sh show` can read it; a work item (kind other
#            than captain) gets `close: release`, a question omits close. A held
#            task whose call wrote a card record - `<state>/board-cards/<id>.json`,
#            owned by `bin/fm-board-card-lib.sh` - is seeded from THAT record and
#            from nothing else, because the record is the call itself rather than
#            an artifact written before it. A record-seeded card carries no
#            {FILL: ...} placeholder of any kind: a full one arrived with its
#            options, and a thin one carries `thin: true`, no options of its own,
#            no risk and no reversibility, so the page can say plainly that the
#            call offered the captain nothing to choose between. An unreadable
#            record is skipped rather than fatal, so one bad file cannot take the
#            whole board down with it. Failing that, when
#            `bin/fm-packet.sh verify` accepts the held task's packet, the card
#            is seeded from `bin/fm-packet.sh card <id>` instead of
#            placeholders. A card that gets placeholders carries the task's
#            recorded pull request as `evidence` links - the pull request, its
#            checks, its commits, and its review comments - so a card with no
#            packet behind it hands the captain the repository rather than an
#            empty panel; a task with no recorded PR emits no evidence at all.
#            Every captain-facing copy field is emitted as
#            {"en": <english>, "hant": "{TRANSLATE: <english>}"} so hant (and
#            optionally hans) is filled without re-typing the English; the
#            fixed merge choices carry their known translations. A card's
#            decide, about, if_nothing, options[].consequence, recommend_why,
#            risk, reversible, and recommend_value are {FILL: ...}
#            placeholders; a packet-seeded card keeps the worker's risk,
#            reversible, and recommend_value and gets a placeholder only for
#            the ones the packet left out. charted_more and
#            charted_warning_more appear only when the snapshot actually
#            omitted gate rows, and then as {FILL: ...} placeholders that each
#            name the SAME omitted total as a figure to divide with the other
#            count, because the snapshot reports one total and never splits it
#            into queued and warning rows. The top-level lang comes
#            from --lang (default hant). The skeleton satisfies the payload
#            validator as-is, but build refuses it until every placeholder is
#            gone.
#            --check <data.json> lists every remaining {FILL} or {TRANSLATE}
#            placeholder as `<path>: <value>` and exits 1 while any remain.
# derive     Write the LIVE board - the same derivation build performs, with
#            the payload injected - without establishing a Lavish session,
#            arming anything, or touching the board at its stable path.
#            --endpoint pins the endpoint instead of starting this home's
#            server. This is how the derivation is inspected and tested; build
#            is how the captain gets a board.
# ack        Write the acknowledgement the board shows on the row the captain
#            clicked. <key> is the board's own routing key - a Captain's Call
#            card key, or a Charted Next row id - because that is what the
#            captain clicked and what the payload keys the row by.
#            Exactly one mode is required. --acting records that the answer
#            was received and is being acted on. --refused records that the
#            picked item was verified and NOT set in motion, with the
#            captain-facing reason read from --why-file (a file, never argv,
#            so a reason may be prose of any length and any shape). --clear
#            removes the record. Output is `ack: <path>` or
#            `cleared: <path>`.
# path       Print the stable board path for this home.
# url        Print the board's Lavish session URL, read from the server's live
#            session listing for the stable path; exit 1 with a reason when no
#            open session exists. The URL never changes while the board keeps
#            its path, because Lavish keys the session on the file's realpath.
#            When the installed lavish-axi supports session names, build opens
#            the board as `--name <name>` (FM_BEARINGS_BOARD_NAME, default
#            `bearings`) and the URL is the memorable `/s/<name>` form; an
#            older lavish-axi keeps the keyed `/session/<id>` form.
# open       Print that URL and open it in the default browser (macOS `open`,
#            else `xdg-open`), so the captain reaches the board without
#            remembering the session id.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Captain-facing copy (card titles, about/decide rows, option labels, hints,
# consequences, underway names and doing, landed what, charted titles and
# reasons) is a plain string or an {en, hant, hans?} object; the template
# renders the language the captain picked (EN / 繁體 / 简体), defaulting to the
# optional top-level `lang`. A decision card MAY answer the captain's five
# questions with optional fields: `decide`, per-option `consequence`,
# `if_nothing`, `reversible` (yes|no|partly) plus `reversible_note`, and
# `recommend_why` beside `recommend_value`; `risk` (low|medium|high) badges a
# decision card, and `evidence` ([{label, url}]) plus `packet_url` link the card
# to its proof. Links must be https, or http on 127.0.0.1/localhost for a page
# served by lavish-axi.
#
# THE PACKET RIDES THE CARD. A decision card MAY also carry `packet`, the whole
# decision packet as `bin/fm-packet.sh card` reads it:
#   {figures: [{slug, svg, nodes, option}],
#    sections: [{heading, items: [{text, code?, links?}]}]}
# The template opens it in place - a tab strip whose first tab is the drawing
# that names every option, one tab per option after it, and the rest of the
# packet behind one collapsed line - so the captain decides on the board's own
# address instead of on a second page a closed tab loses. `fm-packet.sh serve`
# stays the one explicit way to put a packet on its own address; nothing here
# calls it, and no second session is ever established for a card.
# The packet's prose rides as DATA, so it reaches the page through the same
# el()/textContent path as every other payload string and can no more style or
# script the captain's surface than a title can. The drawings cannot: an svg is
# inlined as markup because that is what a drawing is, so every one of them is
# run through `bin/fm-packet.sh svg-check` - the figure contract's own
# implementation, never a second copy - before the board is built. `card` wrote
# those drawings, but the composing agent edits this file afterwards, so the
# payload is checked rather than trusted.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below, and no string may
# still carry a compose placeholder. The enum and count slots (risk,
# reversible, recommend_value, charted_more, charted_warning_more) also accept
# a compose placeholder, so a skeleton validates as a skeleton; build refuses
# every placeholder BEFORE it validates, so those slots are always real values
# by the time a board is built. Every Captain's Call key is ONE keyed-intake
# address, so the validator also refuses a payload carrying two cards under the
# same key, hand-written or composed: `bin/fm-captain-hold.sh` would resolve
# both answers to the one task. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
#
# THE ACKNOWLEDGEMENT LIFECYCLE, AND THIS SCRIPT OWNS IT. A control that sets
# fleet work in motion must say so on the row the captain clicked immediately,
# without waiting for what the click set in motion. Two things draw that pill -
# the page, the instant he clicks it, and a publication, from the durable
# record - so the rule between them is stated HERE, once and whole. The
# template, the capture seam in bin/fm-procevent.sh, the handler contract in
# .agents/skills/bearings/SKILL.md and the ledger line in AGENTS.md each carry
# out one part of it and point back at this block; none of them restates it,
# because a lifecycle with four owners is how the seams between them get lost.
#
#   BORN at capture. The captain's answer, read back from the board, writes one
#   `acting` record per key that answer named - no more, no fewer.
#   bin/fm-procevent.sh feeds it beside the keyed-answer intake, through the
#   `ack` command below, which is the carrier's ONLY writer.
#
#   SHOWN newest first. A key can carry two acknowledgements at once: the
#   published record, and a click the page itself remembers. Both carry the
#   second they happened, and the NEWER wins. A publication still carrying a
#   ten-minute-old unsettled record must not bury a click made three seconds
#   ago - telling the captain his click did not happen is the one thing this
#   whole behaviour exists to stop. An equal stamp goes to the publication,
#   because only a publication can carry a refusal's reason.
#
#   AGES against one threshold and one clock, measured from the `at` stamp it
#   was born with. Compose hands that stamp to the renderer and derives nothing
#   from it, because the state it feeds reports a consequence that never
#   arrived - and that is exactly the case in which nothing republishes the
#   board. A row that could only age on a republication would report a slow
#   answer and stay silent about a missed one, which is the discrimination the
#   captain asked for, backwards.
#
#   RETIRES only when the handler settles it - a dispatch clears it (`ack <key>
#   --clear`), a refusal replaces it (`ack <key> --refused`). Nothing else
#   retires a record. Not compose: a publication enumerates what the snapshot's
#   options and caps gave it, not every live row, so a key missing from one
#   board says nothing about whether its row still exists. Not a clock either -
#   an unsettled record goes on reporting itself as still waiting however long
#   it has been, which is the report the captain asked for, and is how "the
#   first mate is busy" is told apart from "the first mate missed it".
#
# ONLY the two surfaces the captain clicks carry it: a Captain's Call item and
# a Charted Next row. Every control he named lives on one of those, and an
# Underway row has nothing on it he clicks. Either MAY therefore carry `ack`:
# {kind, at, why?}. `kind` is `acting` (received, being acted on) or `refused`
# (verified and not set in motion); the template renders each one's words in
# the captain's language, because a deterministic publication has no translator
# in the loop. `at` is the epoch second of the click. `why` is the refusal's
# reason and is the one ack field that is captain-facing copy, because the
# first mate writes it. The carrier is state/board-acks/<key>.json.
#
# THE CARRIER KEY HAS NO SURFACE IN IT, AND THAT RESTS ON A PARTITION TWO FILES
# AWAY. A record is keyed by the bare board key, so one `ack <key>` paints one
# row. A decision card's key and a Charted Next row's id are drawn from the
# same namespace - both are task ids - and they stay apart only because the
# snapshot splits them: a card takes `select(.captain_actionable == true)` and
# a gate takes `select(.captain_actionable != true)`, where captain_actionable
# is `.hold_bucket == "live"`. Merge cards escape independently, being prefixed
# `merge.`. So no key can name two rows today. If that partition ever changes -
# a held task also surfaced as a gate - one `ack` would paint two rows and one
# `--clear` would wipe both, contradicting "on the row the captain clicked".
# The key format is deliberately NOT prefixed to guard a collision that cannot
# currently happen: widening a published format is dear and recording the
# dependency is cheap. tests/fm-bearings-snapshot.test.sh asserts the partition
# holds, so a change to it fails there rather than quietly sharing a pill.
#
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lavish-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-lavish-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SESSION_NAME=${FM_BEARINGS_BOARD_NAME:-bearings}
# The live transport, and the two seams it is anchored on. The board has ONE
# definition - the shipped template - and the live board is that same board
# subscribing to fleet events, DERIVED here rather than re-authored, so every
# card type, badge, picker and packet reaches it without anyone maintaining a
# list of them. If either seam moves, build stops and names it instead of
# emitting a board that would look right and never update.
LIVE_TRANSPORT="${FM_BOARD_LIVE_TRANSPORT:-$SCRIPT_DIR/../.agents/skills/bearings/assets/live-transport.js}"
LIVE_ANCHOR='<script id="bearings-data" type="application/json">'
LIVE_ENDPOINT_SLOT='__FM_BOARD_LIVE_ENDPOINT__'
# The other half of the same connection: what the board sends the captain's
# answer back with. bin/fm-board-live.sh's header owns what it proves. It is a
# credential, so it is injected ONLY into a board being written to a file at
# mode 0600, never into one going to stdout, where it would be read in a
# terminal, pasted into a report and captured in a log. That is a mechanism
# and not a convention on purpose: the natural way to look at a derived board
# is to run `derive` without --out, so relying on the caller to remember would
# put the captain's answer credential in a transcript the first time anyone
# debugged a board.
LIVE_TOKEN_SLOT='__FM_BOARD_LIVE_TOKEN__'
BOARD_SCHEMA=fm-bearings-board.v1
PLACEHOLDER_RE='\{(FILL|TRANSLATE)(:[^}]*)?\}'
# The one definition of a routable key, an acceptable captain-facing link, and
# an acceptable Charted Next `filed` date, shared by the payload validator and
# the compose projection so the projection can never emit a value the validator
# then refuses.
# shellcheck disable=SC2016  # a jq program: the $ names are jq's variables, not the shell's
BOARD_JQ_DEFS='
def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
def https_url:
  type == "string"
  and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$");
def link_url:
  https_url
  or (type == "string" and test("^http://(127\\.0\\.0\\.1|localhost)(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
def valid_filed:
  . as $filed
  | type == "string"
  and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
  and (if test("T")
    then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
    else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
    end);
'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

# --- the live board ----------------------------------------------------------
# The board the captain reads goes stale between rebuilds, and nothing about
# that was ever the transport's fault: nothing wrote. The derivation below adds
# the one thing a built page cannot do for itself - subscribe to the fleet's
# own events and repaint the instant one lands - and adds nothing else.
# bin/fm-board-live.mjs owns what an event may change; the transport owns what
# the page says about its own freshness.

# Start this home's live server and print the endpoint a page should use.
# Prints nothing and returns 1 when there is none: a board with no live server
# still renders from the payload built into it and says it is not updating, so
# this can never be the reason a board is not built.
live_endpoint() {
  local out
  out=$("$SCRIPT_DIR/fm-board-live.sh" start 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -m1 '^ws://' || return 1
}

# Write the shipped template with the live transport inserted above the data
# slot, carrying <endpoint>. Above the slot is where the transport must sit: it
# captures the board's markup BEFORE the shipped script renders into it, which
# is what lets a repaint restore first paint exactly and lets the board's own
# error card be undone. Fails rather than emitting a board that cannot update.
derive_live_board() {  # <endpoint> <destination> <may-carry-token 0|1>
  local endpoint=$1 dest=$2 with_token=${3:-0} anchors token
  [ -f "$LIVE_TRANSPORT" ] && [ ! -L "$LIVE_TRANSPORT" ] \
    || { printf 'the live transport is missing: %s\n' "$LIVE_TRANSPORT" >&2; return 1; }
  grep -qF "$LIVE_ENDPOINT_SLOT" "$LIVE_TRANSPORT" \
    || { printf 'the live transport carries no endpoint slot\n' >&2; return 1; }
  grep -qF "$LIVE_TOKEN_SLOT" "$LIVE_TRANSPORT" \
    || { printf 'the live transport carries no answer-token slot\n' >&2; return 1; }
  anchors=$(grep -cxF "$LIVE_ANCHOR" "$TEMPLATE")
  [ "$anchors" -eq 1 ] \
    || { printf 'board template does not carry exactly one data slot opening: %s\n' "$TEMPLATE" >&2; return 1; }
  # A board that cannot send an answer back is a picture of a board, so a
  # board being KEPT refuses rather than being written with buttons that would
  # do nothing. A board going to stdout is an inspection copy: it is emitted
  # with an empty slot, and says on the page that it cannot answer, because
  # the alternative is a credential on a terminal.
  token=""
  if [ "$with_token" = 1 ]; then
    token=$("$SCRIPT_DIR/fm-board-live.sh" token) \
      || { printf 'cannot issue the answer token this board would need to reach firstmate\n' >&2; return 1; }
  fi

  local filled
  filled=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-board-live-transport.XXXXXX") || return 1
  if ! FM_LIVE_ENDPOINT="$endpoint" FM_LIVE_TOKEN="$token" perl -pe \
      "s/\\Q$LIVE_ENDPOINT_SLOT\\E/\$ENV{FM_LIVE_ENDPOINT}/g;
       s/\\Q$LIVE_TOKEN_SLOT\\E/\$ENV{FM_LIVE_TOKEN}/g" "$LIVE_TRANSPORT" > "$filled"; then
    rm -f -- "$filled"
    printf 'cannot set the live endpoint on the transport\n' >&2
    return 1
  fi
  # getline reads the transport verbatim, so nothing in it is interpreted as a
  # pattern or a replacement however it is punctuated.
  if ! awk -v anchor="$LIVE_ANCHOR" -v tfile="$filled" '
      $0 == anchor && !done {
        print "<script id=\"fm-board-live\">";
        while ((getline line < tfile) > 0) print line;
        print "</script>";
        done = 1;
      }
      { print }
    ' "$TEMPLATE" > "$dest"; then
    rm -f -- "$filled"
    printf 'cannot derive the live board\n' >&2
    return 1
  fi
  rm -f -- "$filled"
  if ! grep -qxF '<script id="fm-board-live">' "$dest"; then
    printf 'the live transport did not reach the derived board\n' >&2
    return 1
  fi
  if grep -qF "$LIVE_ENDPOINT_SLOT" "$dest"; then
    printf 'the live endpoint slot survived derivation\n' >&2
    return 1
  fi
  if grep -qF "$LIVE_TOKEN_SLOT" "$dest"; then
    printf 'the answer-token slot survived derivation\n' >&2
    return 1
  fi
  return 0
}

# The board INLINES a packet's drawings into the captain's page, beside the
# answer channel, so the bytes it inlines are held to the figure contract that
# governs a drawing anywhere. The check is not restated here: it is
# `bin/fm-packet.sh svg-check`, the one implementation, run over the payload
# THIS script was handed - `fm-packet.sh card` wrote those drawings, but the
# composing agent edits that file afterwards, so verify's word about the packet
# on disk is not a word about the drawing in this payload.
# The decode flag is spelled --decode on GNU and -D on BSD, so both are tried -
# the same two-spelling fallback bin/fm-remote-home-provision.sh already needs.
# Without it a board carrying any drawing refuses to build on half the
# platforms, blaming the drawing for a flag.
decode_drawing() {  # <base64> <destination>
  printf '%s' "$1" | base64 --decode > "$2" 2>/dev/null && return 0
  printf '%s' "$1" | base64 -D > "$2" 2>/dev/null && return 0
  return 1
}

validate_packet_drawings() {  # <data.json> ; names every refusal on stderr
  local rows key encoded slug tmp problems status=0
  # Every field but the LAST must be one that cannot be empty: tab is an IFS
  # whitespace character, so bash collapses a run of tabs and drops the empty
  # field between them - a figure with no slug would otherwise shift its own
  # drawing out of the variable the loop checks and be inlined unread.
  rows=$(jq -r '.captains_call[]? | select(has("packet"))
    | .key as $k | .packet.figures[]? | [$k, (.svg | @base64), (.slug // "")] | @tsv' "$1") \
    || return 1
  # A board with no drawing on it needs nothing to check it: this script is a
  # jq script, and a home whose cards carry no figures must not need python3.
  [ -n "$rows" ] || return 0
  command -v python3 >/dev/null 2>&1 \
    || { printf 'fm-bearings-board: python3 is required to check a packet drawing\n' >&2; return 1; }
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-figure.XXXXXX") || return 1
  while IFS=$'\t' read -r key encoded slug; do
    [ -n "$key" ] || continue
    if ! decode_drawing "$encoded" "$tmp"; then
      printf 'fm-bearings-board: card %s: a packet drawing could not be read\n' "$key" >&2
      status=1; continue
    fi
    if ! problems=$("$SCRIPT_DIR/fm-packet.sh" svg-check "$tmp" "$slug" 2>&1); then
      printf '%s\n' "$problems" \
        | sed "s|^|fm-bearings-board: card $key: drawing ${slug:-(unnamed)}: |" >&2
      status=1
    fi
  done <<EOF
$rows
EOF
  rm -f -- "$tmp"
  return "$status"
}

# --- the acknowledgement carrier ---------------------------------------------
# One record per board key, written only through `ack`. The key is a board
# routing key, so it satisfies the same slug rule the payload validator applies
# to a card key and a Charted Next id; with no path separator accepted, a key
# can never address anything outside the carrier directory.

acks_dir() { printf '%s/board-acks\n' "$STATE"; }
ack_path() { printf '%s/%s.json\n' "$(acks_dir)" "$1"; }

validate_ack_key() {  # <key>
  case "$1" in
    ''|.|..) fail "not a board key: $1" ;;
  esac
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]{1,128}$' \
    || fail "not a board key: $1"
}

write_ack() {  # <key> <kind> <why-file-or-empty>
  local key=$1 kind=$2 why_file=$3 path dir tmp
  path=$(ack_path "$key")
  dir=$(acks_dir)
  (umask 077; mkdir -p "$dir") || fail "cannot create $dir"
  tmp=$(umask 077; mktemp "$dir/.board-ack.XXXXXX") || fail "cannot stage the acknowledgement for $key"
  if ! jq -n --arg kind "$kind" --arg at "$(date -u +%s)" \
    --rawfile why "${why_file:-/dev/null}" '
      {schema: "fm-board-ack.v1", kind: $kind, at: ($at | tonumber)}
      + (($why | sub("\\s+$"; "")) as $w | if $w == "" then {} else {why: $w} end)' > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the acknowledgement for $key"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the acknowledgement for $key"
  fi
  printf 'ack: %s\n' "$path"
}

command_ack() {
  local key=${1-} mode='' why_file=''
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --acting|--clear) [ -z "$mode" ] || { usage >&2; exit 2; }; mode=${1#--}; shift ;;
      --refused) [ -z "$mode" ] || { usage >&2; exit 2; }; mode=refused; shift ;;
      --why-file) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; why_file=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  validate_ack_key "$key"
  [ -n "$mode" ] || { usage >&2; exit 2; }
  [ -z "$why_file" ] || [ "$mode" = refused ] \
    || fail "--why-file explains a refusal and means nothing without --refused"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  case "$mode" in
    refused)
      [ -n "$why_file" ] || fail "--refused needs --why-file: a refusal the captain cannot read is not a refusal"
      [ -f "$why_file" ] && [ ! -L "$why_file" ] || fail "refusal reason does not exist: $why_file"
      [ -n "$(LC_ALL=C tr -d '[:space:]' < "$why_file")" ] \
        || fail "refusal reason is empty: $why_file"
      write_ack "$key" refused "$why_file"
      ;;
    acting) write_ack "$key" acting '' ;;
    clear)
      rm -f -- "$(ack_path "$key")" || fail "cannot clear the acknowledgement for $key"
      printf 'cleared: %s\n' "$(ack_path "$key")"
      ;;
  esac
}

# Every stored acknowledgement, resolved for one publication: {key: {kind, at,
# why?}}. The stamp is carried through untouched - see AGES in the lifecycle
# block above. A record that is unreadable or not this schema is skipped rather
# than refusing the board: a malformed side-band file must never cost the
# captain every other row. The merge lands in a scratch variable first,
# because a failed command substitution assigns its empty output BEFORE the
# `||` runs - accumulating in place would let one unmergeable record wipe the
# map it had already built and fail the whole publication.
board_acks_map() {
  local dir f key acc='{}' resolved merged
  dir=$(acks_dir)
  [ -d "$dir" ] || { printf '%s\n' "$acc"; return 0; }
  for f in "$dir"/*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    key=${f##*/}; key=${key%.json}
    resolved=$(jq -c '
      select(type == "object" and .schema == "fm-board-ack.v1")
      | select(.kind == "acting" or .kind == "refused")
      | select(.at | type == "number")
      | {kind, at}
        + (if (.why | type == "string") and (.why | length) > 0 then {why: .why} else {} end)
      ' "$f" 2>/dev/null) || continue
    [ -n "$resolved" ] || continue
    merged=$(jq -n --argjson acc "$acc" --arg key "$key" --argjson ack "$resolved" \
      '$acc + {($key): $ack}' 2>/dev/null) || continue
    [ -n "$merged" ] || continue
    acc=$merged
  done
  printf '%s\n' "$acc"
}

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" --arg ph "$PLACEHOLDER_RE" "$BOARD_JQ_DEFS"'
    def nonempty_string: type == "string" and length > 0;
    # A compose placeholder stands in for a value the composer still owes. The
    # enum and count slots accept one so the skeleton validates as a skeleton;
    # build refuses every placeholder before it validates, so a payload that
    # reaches the captain still satisfies the enums below.
    def placeholder: type == "string" and test($ph);
    # Captain-facing copy is a plain string or an {en, hant, hans?} object; the
    # renderer resolves it for the language the captain chose.
    def i18n: type == "object" and (.en | nonempty_string) and (.hant | nonempty_string)
      and ((has("hans") | not) or (.hans | type == "string"));
    def copy: nonempty_string or i18n;
    def copy_or_empty: (type == "string") or i18n;
    def optional_copy($name): (has($name) | not) or (.[$name] | copy);
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | copy);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name): (has($name) | not) or (.[$name] | https_url);
    def optional_link_url($name): (has($name) | not) or (.[$name] | link_url);
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def evidence_item: type == "object" and (.label | copy) and (.url | link_url);
    # The packet the card opens in place (bin/fm-packet.sh card). The template
    # consumes every field here, so every field is typed here: a drawing that
    # is not a drawing, or a section that is not a section, refuses the board
    # rather than reaching the captain as a blank panel.
    #
    # A figure `option` says which option tab that drawing opens in, and the
    # template renders it in the tab whose value matches EXACTLY - and in no
    # tab at all otherwise. So a drawing that names an option this card does
    # not offer refuses the board here, rather than going missing from the one
    # surface the captain decides on.
    def figure_item($values):
      type == "object"
      # The same shape the packet requires, because a slug that is absent here
      # is a slug the drawing check would skip its id-namespace clause over -
      # absence passing for a passed check, at the one boundary whose reason
      # for existing is that this file is edited after the packet wrote it.
      and (.slug | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
      and (.svg | type == "string" and test("^[[:space:]]*<svg\\b"))
      and (.nodes | type == "array") and ([.nodes[] | type == "string"] | all)
      and ((has("option") | not) or (.option == "")
           or ((.option | type == "string")
               and (.option as $o | $values | index($o) != null)));
    # The prose of a packet reaches the page through el()/textContent like
    # every other string in this payload, so it is DATA here rather than
    # markup: one heading and its items, each item a line and the links it
    # named. Nothing in a packet can style or script the surface it is read on.
    def packet_link: type == "object" and (.label | copy) and (.url | link_url);
    def packet_item:
      type == "object"
      and ((has("text") | not) or (.text | copy))
      and ((has("code") | not) or (.code | type == "boolean"))
      and ((has("links") | not)
           or ((.links | type == "array") and ([.links[] | packet_link] | all)))
      and (has("text") or has("links"));
    def packet_section:
      type == "object"
      and (.heading | copy)
      and (.items | type == "array") and ([.items[] | packet_item] | all);
    def optional_packet($values):
      (has("packet") | not)
      or (.packet
        | type == "object"
          and (.sections | type == "array")
          and ([.sections[] | packet_section] | all)
          and (.figures | type == "array")
          and ([.figures[] | figure_item($values)] | all)
          # and unique within the card, for the same reason the packet makes
          # them unique within itself: two drawings sharing a slug share an id
          # namespace once the board inlines them side by side
          and ([.figures[].slug] | length == (unique | length)));
    # The acknowledgement the board shows on the row the captain clicked.
    # `kind` is a closed vocabulary the template translates, `at` the epoch
    # second of the click it ages from, and `why` the only captain-facing copy
    # in it.
    def ack_item:
      type == "object"
      and (.kind == "acting" or .kind == "refused")
      and (.at | type == "number")
      and ((has("why") | not) or (.why | copy));
    def optional_ack: (has("ack") | not) or (.ack == null) or (.ack | ack_item);
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | copy)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | copy)
          and optional_copy("hint")
          and optional_copy("consequence")
          and optional_copy("buys")
          and ((has("files") | not)
               or ((.files | type == "array") and ([.files[] | type == "string"] | all)))
          and ((has("changes") | not)
               or ((.changes | type == "object")
                   and ([.changes | to_entries[]
                         | (.key == "added" or .key == "removed" or .key == "unchanged")
                           and (.value | type == "array")
                           and ([.value[] | copy] | all)] | all)))] | all)
      and (optional_copy("about"))
      and (optional_copy("decide"))
      and (optional_copy("detail"))
      and (optional_copy("if_nothing"))
      and (optional_copy("recommend_why"))
      and (optional_copy("reversible_note"))
      and ((has("reversible") | not) or (.reversible | placeholder)
        or (.reversible == "yes" or .reversible == "no" or .reversible == "partly"))
      and (if .type == "merge" then true
        else ((has("risk") | not) or (.risk | placeholder)
          or (.risk == "low" or .risk == "medium" or .risk == "high")) end)
      and ((has("evidence") | not) or ((.evidence | type == "array") and ([.evidence[] | evidence_item] | all)))
      and (optional_link_url("packet_url"))
      and ([.options[].value] as $values | optional_packet($values))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_copy("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("thin") | not) or (.thin | type == "boolean"))
      and ((has("recommend_value") | not)
        or (.recommend_value | placeholder)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end)
      and optional_ack;
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | copy) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | copy) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | copy) and (.reason | copy_or_empty)
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end)
      and optional_ack;
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and ((has("lang") | not) or (.lang == "en" or .lang == "hant" or .lang == "hans"))
    and (.captains_call | type == "array")
    # One card per keyed-intake address: two cards under one key are two
    # answers `bin/fm-captain-hold.sh` would resolve to the same single task.
    and ([.captains_call[].key] | length == (unique | length))
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not) or (.charted_more | placeholder)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not) or (.charted_warning_more | placeholder)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null || return 1
  validate_packet_drawings "$1"
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
# A build that advertises session names gets the stable `/s/<slug>` address; a
# build without the flag gets the plain open so the board still works there.
# fm-lavish-lib.sh owns that question - including why it is a capability probe
# rather than a version floor - so only a positive verdict adds the flag and
# both "no" and "could not tell" degrade to the plain open exactly as before.
lavish_name_args() {
  if fm_lavish_named_session_support; then
    printf -- '--name\n%s\n' "$BOARD_SESSION_NAME"
  fi
}

establish_board_session() {  # <board>
  local board=$1 real out status version
  local -a name_args=()
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  while IFS= read -r line; do [ -n "$line" ] && name_args+=("$line"); done < <(lavish_name_args)
  out=$(lavish-axi "$board" ${name_args[@]+"${name_args[@]}"}) || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen ${name_args[@]+"${name_args[@]}"}) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: {en: "Reconcile", hant: "重新核對", hans: "重新核对"},
          hint: {
            en: "Re-check the latest state, then close this with evidence or keep it open with a note",
            hant: "重新核對最新狀態，然後附證據關閉，或留下註記讓它保持開放",
            hans: "重新核对最新状态，然后附证据关闭，或留下注记让它保持开放"
          }
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

# --- compose -----------------------------------------------------------------
# The skeleton is a deterministic projection of the snapshot; the composer's
# judgment (ranking, prose, translations, risk, reversibility) is written into
# it afterwards, and build refuses the payload while any placeholder remains.
# The placeholder shapes are owned by PLACEHOLDER_RE above: `{FILL: ...}` marks
# prose or a value the composer writes, and `{TRANSLATE: <english>}` marks a
# translation of the English beside it.

# A scalar from `tasks-axi show`: a value that needed quoting is JSON-quoted
# (\" and \\ inside), so it is decoded as a JSON string.
show_value() {  # <show output> <field>
  local raw
  raw=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$raw" in
    \"*\") printf '%s\n' "$raw" | jq -r . 2>/dev/null || printf '%s\n' "$raw" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# Whether this home's backlog can be read at all. `bin/fm-tasks-axi.sh` refuses
# with exit 2 when tasks-axi is missing or the backlog cannot be addressed,
# while a task that is merely absent from a readable backlog exits 1 - so an
# unreadable backlog is unknown ownership, never absent ownership.
backlog_readable() {
  "$SCRIPT_DIR/fm-tasks-axi.sh" >/dev/null 2>&1
}

# This home's backlog record for a task: {title, kind, repo} or null when the
# backlog cannot be read or the task is not there.
task_record() {  # <task-id>
  local show title kind repo
  command -v tasks-axi >/dev/null 2>&1 || { printf 'null\n'; return 0; }
  show=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" 2>/dev/null) || { printf 'null\n'; return 0; }
  title=$(show_value "$show" title)
  kind=$(show_value "$show" kind)
  repo=$(show_value "$show" repo)
  [ "$repo" != - ] || repo=''
  [ "$kind" != - ] || kind=''
  jq -n --arg title "$title" --arg kind "$kind" --arg repo "$repo" \
    '{title: (if $title == "" then null else $title end),
      kind: (if $kind == "" then null else $kind end),
      repo: (if $repo == "" then null else $repo end)}'
}

# The verified packet's board card for a held task, or null when the task has
# no packet, its packet does not verify, or it is a done packet.
packet_card() {  # <task-id>
  local card
  card=$("$SCRIPT_DIR/fm-packet.sh" card "$1" 2>/dev/null) || { printf 'null\n'; return 0; }
  printf '%s\n' "$card" | jq -c . 2>/dev/null || printf 'null\n'
}

# The card record the call wrote when it was raised, or null when this home has
# none for the task.
#
# THIS is the realtime card the captain asked for: 看板的卡片我要一個realtime方
# 案，不要你每次重建，沒意義. Its content was written at the instant the call was
# raised, by the one site every captain call goes through, so composing a board
# from it is a read rather than a rebuild. `bin/fm-board-card-lib.sh` owns the
# record's format; this reads it and nothing else.
#
# A record WINS over the packet, because the packet is the worker's artifact
# written before the call and the record is the call itself. A call raised
# before this home had records simply has none, and the packet and placeholder
# paths behind it are untouched.
#
# A record that cannot be read or is not the schema this knows becomes null
# here rather than an error. That is deliberate and it is the opposite of
# `--card-file`'s posture: refusing there stops a bad card being RAISED, while
# refusing here would take down the whole board - every other card with it -
# over one unreadable file. The call still shows, seeded the way it was before.
record_card() {  # <task-id>
  local path=$STATE/board-cards/$1.json
  [ -r "$path" ] || { printf 'null\n'; return 0; }
  jq -c '
    # Empty is how the record spells "the call did not say", and the board
    # spells that as absent, so the two are reconciled here and nowhere else.
    def present: . != null and . != "";
    if type != "object" or .schema != "fm-board-card.v1" then null
    else . as $r
      | {key: $r.key, options: ($r.options // []), thin: ($r.thin == true)}
      + (if ($r.title | present) then {title: $r.title} else {} end)
      + (if ($r.repo | present) then {repo: $r.repo} else {} end)
      + (if ($r.decide | present) then {decide: $r.decide} else {} end)
      + (if ($r.if_nothing | present) then {if_nothing: $r.if_nothing} else {} end)
      + (if ($r.recommend_value | present) then {recommend_value: $r.recommend_value} else {} end)
      + (if ($r.recommend_why | present) then {recommend_why: $r.recommend_why} else {} end)
      + (if ($r.close | present) then {close: $r.close} else {} end)
      + (if (($r.figures // []) | length) > 0 then {figures: $r.figures} else {} end)
      # A thin card carries no risk and no reversibility, because nobody
      # assessed either. Carrying the defaults this record writes would put a
      # claim on the card the captain answers that nobody actually made.
      + (if $r.thin == true then {}
         else (if ($r.risk | present) then {risk: $r.risk} else {} end)
            + (if ($r.reversible | present) then {reversible: $r.reversible} else {} end)
         end)
    end' "$path" 2>/dev/null || printf 'null\n'
}

# The task's pull request as board `evidence` links, or [] when no PR is
# recorded. A decision card with no packet behind it still owes the captain
# something to decide against, and the ground truth is the pull request itself:
# the PR, its checks, its commits, and its review comments. The URL is the
# canonical one `bin/fm-pr-check.sh` validated into the task's meta, re-parsed
# here through its own owner so the forge - and therefore which tab is which -
# is read rather than assumed.
pr_evidence() {  # <task-id>
  local url self checks checks_tab comments_tab
  url=$(fm_meta_get "$STATE/$1.meta" pr)
  if [ -z "$url" ] || ! fm_pr_url_parse "$url"; then printf '[]\n'; return 0; fi
  if [ "$FM_PR_PROVIDER" = gitlab ]; then
    self='{"en":"merge request","hant":"這個 MR","hans":"这个 MR"}'
    checks='{"en":"pipelines","hant":"流水線","hans":"流水线"}'
    checks_tab=pipelines
    comments_tab=diffs
  else
    self='{"en":"pull request","hant":"這個 PR","hans":"这个 PR"}'
    checks='{"en":"checks","hant":"檢查","hans":"检查"}'
    checks_tab=checks
    comments_tab=files
  fi
  jq -nc --arg url "$FM_PR_URL" --argjson self "$self" --argjson checks "$checks" \
    --arg checks_tab "$checks_tab" --arg comments_tab "$comments_tab" '
    [{label: $self, url: $url},
     {label: $checks, url: ($url + "/" + $checks_tab)},
     {label: {en: "commits", hant: "提交", hans: "提交"}, url: ($url + "/commits")},
     {label: {en: "review comments", hant: "review 意見", hans: "review 意见"},
      url: ($url + "/" + $comments_tab)}]' 2>/dev/null || printf '[]\n'
}

list_placeholders() {  # <data.json> -> "<path>: <value>" lines
  jq -r --arg re "$PLACEHOLDER_RE" '
    . as $doc
    | [paths(type == "string" and test($re))] | .[]
    | . as $p | ($p | map(tostring) | join(".")) + ": " + ($doc | getpath($p))
  ' "$1"
}

command_compose_check() {  # <data.json>
  local data=$1 found
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  found=$(list_placeholders "$data") || fail "cannot scan the board data: $data"
  if [ -z "$found" ]; then
    printf 'placeholders: none\n'
    return 0
  fi
  printf '%s\n' "$found"
  printf 'placeholders: %s\n' "$(printf '%s\n' "$found" | wc -l | tr -d ' ')"
  return 1
}

command_compose() {
  local lang=hant out='' snapshot_file='' snapshot records='{}' cards='{}' written='{}' links='{}' id record card call link ids tmp readable=true
  local acks='{}'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; command_compose_check "$2"; return $? ;;
      --lang) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; lang=$2; shift 2 ;;
      --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; out=$2; shift 2 ;;
      --snapshot) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; snapshot_file=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$lang" in en|hant|hans) ;; *) fail "--lang must be en, hant, or hans" ;; esac
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  if [ -n "$snapshot_file" ]; then
    [ -f "$snapshot_file" ] || fail "snapshot does not exist: $snapshot_file"
    snapshot=$(cat "$snapshot_file")
  else
    snapshot=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" --json) || fail "cannot read the bearings snapshot"
  fi
  printf '%s\n' "$snapshot" | jq -e '.schema == "fm-bearings.v1"' >/dev/null 2>&1 \
    || fail "the snapshot is not an fm-bearings.v1 projection"
  backlog_readable || readable=false
  # Main-home rows are enriched from this home's own records; secondmate rows
  # keep the snapshot's projection because their books live elsewhere.
  ids=$(printf '%s\n' "$snapshot" | jq -r '
    [ (.decisions_open[]? | select(.verb == "captain-hold" and .owner == "(main)") | .id),
      (.landed[]? | select(.owner == "(main)") | .id),
      (.gates[]? | select(.owner == "(main)" and (.id | startswith("(") | not)) | .id),
      (.candidate_prs[]? | select(.task != "-") | .task) ]
    | unique | .[]')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    record=$(task_record "$id")
    records=$(jq -n --argjson acc "$records" --arg id "$id" --argjson record "$record" '$acc + {($id): $record}')
  done <<EOF
$ids
EOF
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    card=$(packet_card "$id")
    cards=$(jq -n --argjson acc "$cards" --arg id "$id" --argjson card "$card" '$acc + {($id): $card}')
    call=$(record_card "$id")
    written=$(jq -n --argjson acc "$written" --arg id "$id" --argjson call "$call" '$acc + {($id): $call}')
    link=$(pr_evidence "$id")
    links=$(jq -n --argjson acc "$links" --arg id "$id" --argjson link "$link" '$acc + {($id): $link}')
  done <<EOF
$(printf '%s\n' "$snapshot" | jq -r '.decisions_open[]? | select(.verb == "captain-hold" and .owner == "(main)") | .id')
EOF
  # What the captain has already clicked and has not yet seen the consequence
  # of. Read once per publication, and attached below to whichever row carries
  # the key he clicked.
  acks=$(board_acks_map)
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-skeleton.XXXXXX") || fail "cannot stage the board skeleton"
  printf '%s\n' "$snapshot" | jq --arg schema "$BOARD_SCHEMA" --arg lang "$lang" \
    --argjson records "$records" --argjson cards "$cards" --argjson written "$written" \
    --argjson links "$links" \
    --argjson acks "$acks" \
    --argjson readable "$readable" "$BOARD_JQ_DEFS"'
    . as $snap |
    # Every captain-facing string goes through this one guard: the validator
    # refuses an empty en, and an ordinary metadata-only backlog row parses to
    # an empty title, so each projection names the durable value that stands in
    # for its row rather than letting one blank field refuse the whole board.
    def t($s; $fallback):
      ([$s, $fallback] | map(select(type == "string" and length > 0)) | .[0] // "(untitled)") as $v
      | {en: $v, hant: ("{TRANSLATE: " + $v + "}")};
    def fillv($what): "{FILL: " + $what + "}";
    def fill($what): {en: fillv($what), hant: fillv($what)};
    def risk_slot: fillv("low | medium | high");
    def reversible_slot: fillv("yes | no | partly");
    def recommend_slot($values): fillv("recommend one of " + ($values | join(" | ")));
    def i18n($fallback):
      if type != "object" then t(.; $fallback)
      elif (.en | type == "string" and length > 0) and (.hant | type == "string" and length > 0) then .
      else . + t(.en; $fallback) end;
    def slugify:
      gsub("[^A-Za-z0-9._-]"; "-") | .[0:128] | gsub("^-+|-+$"; "")
      | if length == 0 then "row" else . end;
    def record($id): $records[$id] // null;
    # The acknowledgement rides the key the captain actually clicked, which is
    # the card key on a Captain'"'"'s Call item and the emitted row id everywhere
    # else, so this is applied to the built object rather than to the snapshot
    # row it came from.
    def with_ack($key): if $acks[$key] == null then . else . + {ack: $acks[$key]} end;
    def repo_of($id): record($id) | if . == null then null else .repo end;
    def owned: .owner == "(main)";
    # The Charted Next id IS the dispatch.charted routing channel, so a row
    # keeps its real backlog id whenever that id is already a routable key; a
    # row whose id is not stays visible under a display slug and is never
    # offered for dispatch, because the intake could not resolve the slug.
    def charted_id: if owned then .id else (.owner + "/" + .id) end;
    def routable_id: charted_id | slug(128);
    # A card key IS the bin/fm-captain-hold.sh intake address, so a hold this
    # home owns is carded only when its task id is already a routable key; one
    # that is not becomes a warning row naming it, because an unanswerable hold
    # must be visible rather than refusing every other row.
    def held_here: .verb == "captain-hold" and owned;
    def warning_gate: .id | startswith("(");
    def hold_title: (record(.id) | if . == null then null else .title end)
      // (.summary | split(": ") | .[0]);
    def hold_close: record(.id) as $r
      | if $r != null and $r.kind != null and $r.kind != "captain" then {close: "release"} else {} end;
    def placeholder_card:
      {key: .key, type: "decision", repo: repo_of(.id), title: t(hold_title; .key),
       about: fill("about"), decide: fill("decide"), if_nothing: fill("if_nothing"),
       options: [
         {value: "option-a", label: fill("option A label"), consequence: fill("option A consequence")},
         {value: "option-b", label: fill("option B label"), consequence: fill("option B consequence")}],
       recommend_why: fill("recommend_why"),
       recommend_value: recommend_slot(["option-a", "option-b"]),
       reversible: reversible_slot, risk: risk_slot, allow_freeform: true}
      + (($links[.id] // []) | if length == 0 then {} else {evidence: .} end)
      + hold_close;
    def packet_seeded($card): . as $row
      | $card
      + {repo: ($card.repo | if . == null or . == "" then repo_of($row.id) else . end),
         title: ($card.title | i18n($card.key)), decide: ($card.decide | i18n($card.key)),
         if_nothing: ($card.if_nothing | i18n($card.key)),
         about: fill("about"),
         options: [$card.options[] | . as $o
           | .label |= i18n($o.value) | .consequence |= i18n($o.value)
           | if has("buys") then .buys |= i18n($o.value) else . end
           | if has("changes")
             then .changes |= with_entries(.value |= [.[] | i18n($o.value)])
             else . end]}
      + (if $card.recommend_why != null then {recommend_why: ($card.recommend_why | i18n($card.key))} else {} end)
      + ({recommend_value: recommend_slot([$card.options[].value]),
          reversible: reversible_slot, risk: risk_slot}
         | with_entries(select($card[.key] == null)))
      + (if $card.close != null then {close: $card.close} else hold_close end);
    # A card composed from the record the call wrote, which is the only card
    # shape on this board that needs no composer at all.
    #
    # It carries NO fill slot, and that is the point rather than an omission. A
    # packet-seeded card leaves risk, reversibility and the recommendation for
    # a model to fill in afterwards, which is the rebuild the captain refused. A
    # record is complete at the instant it is written: a full card carries its
    # options because --card-file demanded them, and a thin card carries none
    # and says so on its face. Either way the board can be built straight from
    # it, and build refuses a fill slot, so a slot injected here would be a bug
    # that stops the board rather than one that ships a lie.
    def record_seeded($card): . as $row
      | {key: $row.key, type: "decision",
         repo: (($card.repo // "") | if . == "" then repo_of($row.id) else . end),
         title: (if $card.title == null then ($row | t(hold_title; $row.key))
                 else ($card.title | i18n($row.key)) end),
         options: [$card.options[]? | . as $o
           | .label |= i18n($o.value)
           | if has("hint") then .hint |= i18n($o.value) else . end
           | if has("consequence") then .consequence |= i18n($o.value) else . end
           | if has("buys") then .buys |= i18n($o.value) else . end
           | if has("changes")
             then .changes |= with_entries(.value |= [.[] | i18n($o.value)])
             else . end],
         allow_freeform: true}
      # `thin` is what the page says out loud. A call that offered the captain
      # no options must look like one, or he cannot tell an empty card from a
      # card whose options went missing on the way to him.
      + (if $card.thin then {thin: true} else {} end)
      + (if $card.decide != null then {decide: ($card.decide | i18n($row.key))} else {} end)
      + (if $card.if_nothing != null then {if_nothing: ($card.if_nothing | i18n($row.key))} else {} end)
      + (if $card.recommend_why != null then {recommend_why: ($card.recommend_why | i18n($row.key))} else {} end)
      + (if $card.recommend_value != null then {recommend_value: $card.recommend_value} else {} end)
      + (if $card.risk != null then {risk: $card.risk} else {} end)
      + (if $card.reversible != null then {reversible: $card.reversible} else {} end)
      # No figures. The drawings on a card live under `packet.figures` and are
      # read from the figure sections of a verified packet, not from the
      # decision block a --card-file carries, so a record-seeded card has none
      # to give and says nothing rather than hanging an empty slot on it.
      + (($links[$row.id] // []) | if length == 0 then {} else {evidence: .} end)
      + (if $card.close != null then {close: $card.close} else hold_close end);
    # Precedence, most authoritative first: the record the call wrote, then the
    # verified packet the worker wrote, then placeholders for a composer.
    def decision_card: . as $row | ($written[$row.id] // null) as $call
      | ($cards[$row.id] // null) as $card
      | if $call != null then record_seeded($call)
        elif $card == null then placeholder_card
        else packet_seeded($card) end;
    def merge_ready: .checks == "passing" and .mergeable == "MERGEABLE" and .review != "CHANGES_REQUESTED";
    def merge_card: .task as $task
      | ((record($task) | if . == null then null else .title end)
         // ([$snap.in_flight[]? | select(.id == $task) | .name] | .[0])) as $title
      | {key: ("merge." + $task), type: "merge",
         repo: (.repo | split("/") | last),
         title: t("Merge: " + ($title // ("PR #" + .num + " in " + .repo)); $task),
         detail: t("checks " + .checks + ", review " + .review; $task),
         risk: risk_slot,
         options: [
           {value: "merge", label: {en: "Merge now", hant: "立即合併", hans: "立即合并"}},
           {value: "hold", label: {en: "Not yet", hant: "暫緩", hans: "暂缓"}}],
         allow_freeform: true}
      + (if (.url | https_url) then {pr_url: .url} else {} end);
    def merge_ready_prs:
      [ .candidate_prs[]?
        | select((.task | slug(128 - ("merge." | length))) and record(.task) != null and merge_ready) ];
    # A card key IS one intake address, so the board may never carry two cards
    # under it. A task held more than once consolidates into one card whose
    # decide slot names how many questions it must answer; two merge-ready PRs
    # claiming one task get no card at all, because either click would act on
    # whichever PR the task record names, and a wrong merge is worse than an
    # absent card.
    def held_rows: [ .decisions_open[]? | select(held_here and (.key | slug(128))) ];
    def consolidated($n):
      if $n > 1 then {decide: fill("decide: this task is held " + ($n | tostring)
        + " times; consolidate every one of its questions into this card")} else {} end;
    def first_per_key: reduce .[] as $card
      ([]; if ([.[].key] | index($card.key)) == null then . + [$card] else . end);
    # The snapshot reports ONE omitted-gates total and never splits it into
    # queued and warning rows, so each slot names that one total as a shared
    # figure to divide, and points at the sibling count that takes the rest.
    def gates_omitted:
      [ .omitted[]? | .surface | capture("^gates showing (?<shown>[0-9]+) of (?<total>[0-9]+)") ]
      | if length == 0 then 0 else ((.[0].total | tonumber) - (.[0].shown | tonumber)) end;
    def more_slot($kind; $sibling): gates_omitted as $n
      | fillv($kind + " Charted Next rows not shown: your share of the " + ($n | tostring)
        + " gate rows the snapshot omitted, the rest of that same total belonging to "
        + $sibling + ", plus any " + $kind + " rows you cut");
    {
      schema: $schema, home: .home, generated: .generated, lang: $lang,
      prs_live: (.prs | startswith("checked")),
      captains_call: (
        [ held_rows as $rows | $rows[] | . as $row
          | decision_card + consolidated([$rows[] | select(.key == $row.key)] | length) ]
        + [ merge_ready_prs as $prs | $prs[] | . as $pr
          | select([$prs[] | select(.task == $pr.task)] | length == 1)
          | merge_card ]
        | first_per_key | map(with_ack(.key))),
      underway: [ .in_flight[]? | {id, repo, name: t(.name; .id), state, kind,
        doing: t(.doing; .state)} ],
      landed: [ .landed[]?
        | {id: (if owned then .id else (.owner + "/" + .id) end),
           repo: (if owned then repo_of(.id) else null end),
           what: t(.what; .id), owner}
        + (if (.artifact | https_url) then {pr_url: .artifact} else {} end) ],
      charted: (
        [ .gates[]?
          | {id: (charted_id | if slug(128) then . else slugify end),
             repo: (if owned then repo_of(.id) else null end),
             title: t(.title; .id),
             reason: (if (.reason // "-") | . != "-" and . != "" then t(.reason; .id)
               elif .blocked_by != "-" then t("waiting on " + (.blocked_by | gsub(","; ", ")); .id)
               else "" end),
             dispatchable: (owned and routable_id and (warning_gate | not)
               and .blocked_by == "-" and .reason == "-"),
             kind: (if warning_gate then "warning" else "queued" end),
             filed: (.filed | if valid_filed then . else null end)} ]
        + [ .secondmates[]?
          | select(.state == "unknown" or .state == "externally_held")
          | {id: (("secondmate/" + .id) | slugify), repo: null,
             title: t("Secondmate home " + .id + " is "
               + (if .state == "unknown" then "unavailable" else "held outside this home" end); .id),
             reason: ((if (.doing // "") != "" then .doing else (.reason // "-") end)
               | if . == "-" or . == "" then null else . end
               | t(.; "its current state is unreadable from here")),
             dispatchable: false, kind: "warning", filed: null} ]
        + [ .secondmate_reconcile[]?
          | {id: (("reconcile/" + .id) | slugify), repo: null,
             title: t("Secondmate home " + .id + " reports an inventory mismatch"; .id),
             reason: t((.kind // "inventory mismatch")
               + (if ((.ids // []) | length) > 0 then ": " + ((.ids // []) | join(", ")) else "" end); .id),
             dispatchable: false, kind: "warning", filed: null} ]
        + [ .decisions_open[]?
          | select(held_here and ((.key | slug(128)) | not))
          | {id: (("unkeyable-hold/" + .id) | slugify), repo: null,
             title: t("The captain hold on " + .id + " cannot be answered from the board"; "unkeyable-hold"),
             reason: t("its task id is not a routable key, so no card can carry an answer back to it";
               "unkeyable-hold"),
             dispatchable: false, kind: "warning", filed: null} ]
        + [ merge_ready_prs | group_by(.task)[] | select(length > 1)
          | {id: (("merge-collision/" + .[0].task) | slugify), repo: null,
             title: t("Two open pull requests claim the task " + .[0].task; "merge-collision"),
             reason: t("no merge card is offered, because a merge answer keyed to that task names only "
               + "one pull request: " + ([.[] | .url] | join(", ")); "merge-collision"),
             dispatchable: false, kind: "warning", filed: null} ]
        + (if $readable then [] else
          [{id: "backlog-unreadable", repo: null,
            title: t("This home cannot read its own backlog"; "backlog-unreadable"),
            reason: t("merge cards are suppressed: no task record can be read to key or route a merge answer";
              "backlog-unreadable"),
            dispatchable: false, kind: "warning", filed: null}] end)
        | map(with_ack(.id)))
    }
    + (if gates_omitted > 0 then {
        charted_more: more_slot("queued"; "charted_warning_more"),
        charted_warning_more: more_slot("warning"; "charted_more")}
      else {} end)' > "$tmp" || { rm -f -- "$tmp"; fail "cannot compose the board skeleton"; }
  if ! validate_payload "$tmp"; then
    rm -f -- "$tmp"
    fail "the composed skeleton does not satisfy $BOARD_SCHEMA"
  fi
  if [ -n "$out" ]; then
    cat "$tmp" > "$out" || { rm -f -- "$tmp"; fail "cannot write the board skeleton: $out"; }
    printf 'skeleton: %s\n' "$out"
  else
    cat "$tmp"
  fi
  rm -f -- "$tmp"
}

command_build() {
  local data=${1-} board json tmp sid extracted effective owner version pre_reopen_owner leftover
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  # The placeholder refusal runs FIRST, so an unfilled enum or recommendation
  # fails with the slot that is still empty rather than with a validator enum or
  # option-reference error that names nothing the composer can act on.
  leftover=$(list_placeholders "$data") || fail "cannot scan the board data: $data"
  if [ -n "$leftover" ]; then
    printf '%s\n' "$leftover" >&2
    fail "board data still carries compose placeholders (run: fm-bearings-board.sh compose --check $data)"
  fi
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  # The page is derived before the payload goes into it, so the payload is
  # injected into the live board rather than into a page the transport is
  # bolted onto afterwards. A home that cannot run the server still gets its
  # board - built from the same template, painting the same payload - and the
  # build SAYS the board will not update rather than leaving that to be
  # discovered at the surface the captain reads.
  local endpoint="" source_page="$TEMPLATE" derived=""
  if endpoint=$(live_endpoint); then
    derived=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-live.XXXXXX") \
      || fail "cannot stage the live board"
    if derive_live_board "$endpoint" "$derived" 1; then
      source_page=$derived
      printf 'live: %s\n' "$endpoint"
    else
      rm -f -- "$derived"
      derived=""
      printf 'live: no - the board was built without live updates; see the reason above\n' >&2
    fi
  else
    endpoint=""
    printf 'live: no - this home has no live board server, so the board will not update between builds (bin/fm-board-live.sh doctor)\n' >&2
  fi

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || { [ -z "$derived" ] || rm -f -- "$derived"; fail "cannot stage the board payload"; }
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    [ -z "$derived" ] || rm -f -- "$derived"
    fail "cannot reconcile the board payload against landed work"
  fi
  json=$(jq -c . "$effective") || {
    rm -f -- "$effective"
    [ -z "$derived" ] || rm -f -- "$derived"
    fail "cannot compact the board data"
  }
  rm -f -- "$effective"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || {
    [ -z "$derived" ] || rm -f -- "$derived"
    fail "cannot create ${board%/*}"
  }
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || {
    [ -z "$derived" ] || rm -f -- "$derived"
    fail "cannot stage the board"
  }
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$source_page" > "$tmp"; then
    rm -f -- "$tmp"
    [ -z "$derived" ] || rm -f -- "$derived"
    fail "cannot inject the board data"
  fi
  [ -z "$derived" ] || rm -f -- "$derived"
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

command_url() {
  local board real listing url
  board=$(board_path)
  [ -f "$board" ] || fail "no board has been built yet at $board (run /bearings lavish)"
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  real=$(board_realpath "$board") || fail "cannot resolve the board path"
  listing=$(lavish-axi 2>/dev/null) || fail "lavish-axi did not answer"
  url=$(printf '%s\n' "$listing" | awk -v file="$real" '
    index($0, file) == 0 { next }
    { line = $0; sub(/^[^,]*,/, "", line); split(line, f, ",");
      if (f[1] == "open") { gsub(/"/, "", f[2]); print f[2]; exit } }')
  [ -n "$url" ] || fail "the board has no open Lavish session (rebuild with /bearings lavish)"
  printf '%s\n' "$url"
}

command_open() {
  local url
  url=$(command_url) || exit 1
  printf '%s\n' "$url"
  if command -v open >/dev/null 2>&1; then open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1
  else fail "no browser opener found (open or xdg-open)"
  fi
}

command_derive() {
  local data="" out="" endpoint="" derived tmp json
  while [ "$#" -gt 0 ]; do
    case $1 in
      --out) out=${2-}; shift 2 ;;
      --endpoint) endpoint=${2-}; shift 2 ;;
      -*) usage >&2; exit 2 ;;
      *) [ -z "$data" ] || { usage >&2; exit 2; }; data=$1; shift ;;
    esac
  done
  [ -n "$data" ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  if [ -z "$endpoint" ]; then
    endpoint=$(live_endpoint) || fail "no live board server in this home (bin/fm-board-live.sh doctor)"
  fi
  derived=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-derive.XXXXXX") \
    || fail "cannot stage the live board"
  # Only a board being written to a file carries the answer token; see the
  # slot comment above. Without --out this goes to a terminal.
  if [ -n "$out" ]; then
    derive_live_board "$endpoint" "$derived" 1 \
      || { rm -f -- "$derived"; fail "cannot derive the live board"; }
  else
    derive_live_board "$endpoint" "$derived" 0 \
      || { rm -f -- "$derived"; fail "cannot derive the live board"; }
    printf 'fm-bearings-board: printed without the answer token, so this copy cannot send the captain'"'"'s answers; use --out for a board he can act on\n' >&2
  fi
  json=$(jq -c . "$data") || { rm -f -- "$derived"; fail "cannot compact the board data"; }
  json=${json//</\\u003c}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-derived.XXXXXX") \
    || { rm -f -- "$derived"; fail "cannot stage the derived board"; }
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$derived" > "$tmp"; then
    rm -f -- "$derived" "$tmp"
    fail "cannot inject the board data"
  fi
  rm -f -- "$derived"
  if [ -n "$out" ]; then
    if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$out"; }; then
      rm -f -- "$tmp"
      fail "cannot write the derived board: $out"
    fi
  else
    cat "$tmp"
    rm -f -- "$tmp"
  fi
}

case "${1-}" in
  compose) shift; command_compose "$@" ;;
  build) shift; command_build "$@" ;;
  derive) shift; command_derive "$@" ;;
  ack) shift; command_ack "$@" ;;
  path) board_path ;;
  url) command_url ;;
  open) command_open ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
