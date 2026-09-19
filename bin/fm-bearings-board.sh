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
#                                [--deterministic]
#   fm-bearings-board.sh compose --check <data.json>
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh refresh [--snapshot <file>] [--best-effort]
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
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card - a decision card whose subject landed or
#            whose call closed, a merge card whose work landed - is named on
#            stderr as a `dropped-landed-card:` line, so a rebuild states what
#            it removed instead of quietly shrinking Captain's Call.
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
#            matches the accepted date shapes, and a pr_url or packet_url is
#            emitted only when it satisfies the same link rule the validator
#            applies, so one hand-written `since` word or one malformed link
#            cannot refuse the board either. A held task's title,
#            repo, and kind come from this home's backlog record when
#            `bin/fm-tasks-axi.sh show` can read it; a work item (kind other
#            than captain) gets `close: release`, a question omits close.
#            Copy for a held task comes from the first source that has it.
#            First, the STORED card `bin/fm-captain-hold.sh card <id>` returns:
#            `build` stores what it publishes on each held task, so every later
#            compose and refresh reuses that copy rather than asking the first
#            mate for prose again, and only the fields the card actually
#            carries are published - an optional field it left out stays out
#            rather than being filled with the task id or an option slug.
#            Second, when `bin/fm-packet.sh verify` accepts the held task's
#            packet, the card is seeded from `bin/fm-packet.sh card <id>`.
#            A call with neither - one whose stored card a re-hold retired, one
#            that never had one - still needs copy written once, and gets
#            placeholders for it. Every captain-facing copy field is emitted
#            as {"en": <english>, "hant": "{TRANSLATE: <english>}"} so hant
#            (and optionally hans) is filled without re-typing the English;
#            the fixed merge choices carry their known translations. A card's
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
#            --deterministic emits NO placeholder at all, which is what lets a
#            refresh publish with no model in the loop. Every slot a composer
#            would fill is resolved from structured state instead: a decision
#            card with no stored or packet-seeded copy degrades to its durable
#            title plus the held row's own snapshot summary - already fitted
#            from that title and the hold's reason - as the question to decide,
#            and no invented options; an optional enum or recommendation the
#            evidence does not supply is omitted rather than guessed, and a
#            merge card's
#            risk reads `unassessed`. Neither omitted-rows count is emitted at
#            all, because the snapshot reports ONE omitted total and never says
#            which of those rows were queued work and which were repair
#            notices; splitting it here would assert a count the evidence does
#            not support, and under-reporting a repair notice is the harmful
#            direction. The omission is stated instead as one non-dispatchable
#            warning row carrying that single total. A degraded card
#            is still answerable: the captain can always reconcile it or answer
#            in free form, and the next full build writes real copy once.
#            Copy carries no translation slot either: with no translator in the
#            loop, a string the snapshot supplied is emitted as the plain string
#            the payload contract already accepts, which the board shows in
#            every language, while copy that arrived already translated (a
#            stored or packet-seeded card) keeps its own translations.
# refresh    Recompose the board deterministically and inject it in place at
#            the stable path, WITHOUT establishing, reopening, binding, or
#            arming anything. It is the no-model-in-the-loop republication: it
#            composes with --deterministic, reconciles the payload exactly as
#            build does, and injects it into the board file. It carries the
#            MERGE cards forward: PR discovery is an opt-in the first mate
#            passes, and a fleet event has no one to pass it, so a refresh
#            composes from a snapshot with no PR view and reuses the merge
#            cards the last publication stored rather than deleting the
#            Merge now control the captain opened the board to click. A merge
#            card retires when its work lands - its PR or its task reaches the
#            payload's own landed rows, which retires the stored copy too - or
#            when a compose holding a COMPLETE PR view finds it no longer
#            merge-ready, because only a complete view decides the merge cards
#            by itself. A view missing a repo that failed, a repo that was
#            capped, a repo never queried, or a backlog it could not read is
#            partial, and a partial view carries the stored cards forward
#            instead of retiring them: absence of evidence is not evidence the
#            PR is gone. No forge is read either way. It takes no
#            language of its own: the board PAGE it is republishing already
#            names the language the board was built in, and a refresh reads
#            that back and carries it forward, so a republication can never
#            move the board off what the captain chose; a home whose page
#            carries no payload yet falls back to the compose default.
#            Safe to run on every fleet event: it touches no Lavish session, so
#            the board's URL, its process-event source, and its keyed-answer
#            binding all survive untouched. One home-local exclusive lock
#            covers every board publication, a build's as well as a refresh's,
#            so a build and a fleet trigger can never both be writing the page
#            and the stored cards; a refresh that finds it held stands down as
#            a no-op, while a build waits for it. That lock
#            records its holder, so a publication killed mid-flight is
#            reclaimed by the next one instead of wedging the board, and every
#            stand-down is logged. The whole refresh runs in a child under
#            one FM_BEARINGS_REFRESH_TIMEOUT deadline (default 90 seconds),
#            because the lock is held across a compose whose cost grows with
#            the fleet: one Underway row costs one bin/fm-task-progress.sh
#            read, itself bounded at FM_TASK_PROGRESS_TIMEOUT (default 20
#            seconds). Those reads share one dependency, so a wedged
#            no-mistakes costs every row its full bound rather than one, and
#            a wide enough fleet behind one can outlast the deadline. That
#            deadline is the ONLY stop: nothing inside the compose yields to
#            a clock of its own. A refresh that does not finish publishes
#            nothing and leaves the board exactly as it was - with its own
#            `generated` stamp still telling the captain how old it is, which
#            is the honest answer and the one a half-written board could not
#            give. It refuses
#            when no board has been built yet; with --best-effort that refusal,
#            and every other failure, becomes a silent exit 0 with the reason
#            appended to the bounded state/.bearings-board-refresh.log, so a
#            supervision trigger can never be changed by this side-band
#            publication. Output is `refreshed: <board>`.
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
# to its proof. `detail` is rendered for a MERGE card only, so a decision card
# is composed without it. Links must be https, or http on 127.0.0.1/localhost for a page
# served by lavish-axi.
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
# when known, otherwise its durable identifier. It MAY also carry `progress`,
# the row's own structured progress projection, so the captain reads how far
# along each worker is without asking: {state, detail, step, steps[{step,
# status}], active_for, last_activity, quiet, activity, refreshed}. It comes
# from `bin/fm-task-progress.sh`, which reads structured state only - never a
# worker's terminal - and is emitted for this home's own rows alone, because a
# secondmate's runs are readable in its own home rather than here. The step
# names and state words are the pipeline's own stable vocabulary, so the
# template renders the ladder trilingually from a fixed label map instead of
# carrying translated prose in the payload; `detail` stays the raw evidence
# line. `refreshed` is that row's own read time, which is what makes a stale
# row visible as stale rather than silently old.
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
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REFRESH_LOG_MAX_BYTES=${FM_BEARINGS_REFRESH_LOG_MAX_BYTES:-65536}
case "$REFRESH_LOG_MAX_BYTES" in ''|*[!0-9]*|0) REFRESH_LOG_MAX_BYTES=65536 ;; esac
REFRESH_TIMEOUT=${FM_BEARINGS_REFRESH_TIMEOUT:-90}
case "$REFRESH_TIMEOUT" in ''|*[!0-9]*|0) REFRESH_TIMEOUT=90 ;; esac

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SESSION_NAME=${FM_BEARINGS_BOARD_NAME:-bearings}
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
def nonempty_string: type == "string" and length > 0;
# A compose placeholder stands in for a value the composer still owes. The
# enum slots accept one so a skeleton validates as a skeleton; build refuses
# every placeholder before it validates, so a payload that reaches the captain
# still satisfies the enums.
def placeholder: type == "string" and test($ph);
# Captain-facing copy is a plain string or an {en, hant, hans?} object; the
# renderer resolves it for the language the captain chose.
def i18n: type == "object" and (.en | nonempty_string) and (.hant | nonempty_string)
  and ((has("hans") | not) or (.hans | type == "string"));
def copy: nonempty_string or i18n;
def optional_copy($name): (has($name) | not) or (.[$name] | copy);
def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
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
# ONE definition of a publishable Captain'"'"'s Call item, shared by the payload
# validator and by the stored-card guard that decides whether a durable card
# may be reused. They must never drift: a guard narrower than the validator
# accepts a card that then refuses the WHOLE board, which under --best-effort
# stops every later refresh silently.
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
      and optional_copy("consequence")] | all)
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
  and (optional_https_url("pr_url"))
  and optional_subject
  and (if has("subject") then .type == "decision" else true end)
  and (optional_copy("freeform_hint"))
  and ((has("close") | not) or (.close == "done" or .close == "release"))
  and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
  and ((has("recommend_value") | not)
    or (.recommend_value | placeholder)
    or ((.recommend_value | slug(128))
      and (.recommend_value as $recommend
        | ([.options[].value] | index($recommend) != null))))
  and ([.options[].value] | index("reconcile") == null)
  and (if .type == "merge" then (.risk | nonempty_string) else true end);
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

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" --arg ph "$PLACEHOLDER_RE" "$BOARD_JQ_DEFS"'
    def copy_or_empty: (type == "string") or i18n;
    def name_marker: has("name") and (.name | copy);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_null_string($name):
      (has($name) | not) or (.[$name] == null) or (.[$name] | type == "string");
    # The structured progress projection an Underway row carries
    # (bin/fm-task-progress.sh). Every field is machine vocabulary the template
    # translates, never composed prose, so none of it is copy.
    def progress_step: type == "object" and (.step | nonempty_string)
      and (.status | type == "string");
    def progress_item:
      type == "object"
      and (.state | nonempty_string)
      and (.detail | type == "string")
      and (.quiet | type == "boolean")
      and (.refreshed | nonempty_string)
      and ((.step == null) or (.step | nonempty_string))
      and (.steps | type == "array") and ([.steps[] | progress_step] | all)
      and optional_null_string("active_for")
      and optional_null_string("last_activity")
      and optional_null_string("activity");
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | copy) and (.kind | nonempty_string)
      and ((has("progress") | not) or (.progress == null) or (.progress | progress_item));
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
      and (if .kind == "warning" then .dispatchable == false else true end);
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
  ' "$1" >/dev/null
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
# The installed lavish-axi advertises session names in its own help text; an
# older release gets the plain open so the board still works there. The probe
# reads `--help` rather than the bare session listing, because it runs before
# the session is established and a listing is not inert: it is the same read the
# liveness proof below depends on, so probing with one lets the probe answer a
# question the build has not asked yet.
lavish_name_args() {
  if lavish-axi --help 2>/dev/null | grep -q -- '--name <slug>'; then
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

# Drop every stale decision card and every merge card whose work has landed,
# then give every surviving decision card the standard reconcile choice.
# Injecting it here is what makes "every decision card offers reconcile" a
# property of the board rather than of the composer's memory; the validator
# prevents duplicate decision options.
# A merge card is judged on the payload's own landed rows alone - no captain
# hold to consult, no forge to ask - and dropping one also retires the copy a
# publication stored, because those landed rows are bounded and the card would
# otherwise return as soon as its merge scrolled out of them.
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
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf 'dropped-landed-card: %s (its work already landed)\n' "$key" >&2
    retire_stored_card "$key"
    drop=$drop$key$'\n'
  done < <(jq -r '
    . as $payload
    | .captains_call[]?
    | select(.type == "merge")
    | . as $card
    | select(
        ($payload.landed | any(.id == ($card.key | sub("^merge\\."; ""))))
        or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url))))
    | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select(($dropped | index($card.key)) == null)
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

# The durable card a previous `build` published for this call, or null -
# `bin/fm-captain-hold.sh` retires it when the task is held again, so a card
# that survives is one written for the hold still open.
# A stored card is durable state an earlier session wrote, and anything may
# have written it - `bin/fm-captain-hold.sh card --store` is a public entry
# point that only checks the key. A card this guard accepts and the pipeline
# then refuses costs the WHOLE board, and under --best-effort that stops every
# later refresh in silence, so the guard admits only a card that is
# publishable EXACTLY AS STORED. That means both gates a publication passes,
# in the order it passes them: no compose placeholder anywhere (build and
# refresh both refuse a payload carrying one, before validating it), and then
# the shared call_item rule from its one definition. call_item alone is not
# enough - it deliberately ACCEPTS placeholders, because a composer's skeleton
# is validated while it still carries them, and a stored card is finished copy
# rather than a skeleton. A card that fails either gate degrades this row to
# the packet or placeholder path instead. The reconcile choice is stripped
# first, because it is injected per publication and the validator refuses a
# card that arrives carrying it.
stored_card() {  # <task-id>
  local card
  card=$("$SCRIPT_DIR/fm-captain-hold.sh" card "$1" 2>/dev/null) || { printf 'null\n'; return 0; }
  printf '%s\n' "$card" \
    | jq -c --arg id "$1" --arg ph "$PLACEHOLDER_RE" "$BOARD_JQ_DEFS"'
      if type == "object" and .key == $id then
        (.options = [((.options // [])[]) | select(.value != "reconcile")])
        | if (tojson | test($ph)) then null
          elif call_item then .
          else null end
      else null end' 2>/dev/null \
    || printf 'null\n'
}

# Every merge card a previous publication stored, as {key: card}. A refresh
# composes from a snapshot with no PR view - discovery is an opt-in the first
# mate passes, and a fleet event has no one to pass it - so without this the
# captain's Merge now control would vanish from the page on the next session
# start. The card is read through the same guard a decision card passes, and
# `bin/fm-captain-hold.sh` stores it under the card key, so a merge card and
# the decision card for the same task never collide.
stored_merge_cards() {
  local dir key card acc='{}'
  for dir in "$DATA"/merge.*; do
    [ -f "$dir/board-card.json" ] || continue
    key=${dir##*/}
    card=$(stored_card "$key")
    [ "$card" != null ] || continue
    printf '%s' "$card" | jq -e '.type == "merge"' >/dev/null 2>&1 || continue
    acc=$(jq -n --argjson acc "$acc" --arg key "$key" --argjson card "$card" \
      '$acc + {($key): $card}') || return 1
  done
  printf '%s\n' "$acc"
}

# Retire a stored merge card whose publication just dropped it. The landed
# rows that prove a merge happened are bounded and recent, so a card left on
# disk would come back the moment its PR scrolled out of them.
retire_stored_card() {  # <card-key>
  rm -f -- "$DATA/$1/board-card.json" 2>/dev/null || true
}

# One task's structured progress projection, reduced to the payload shape.
# bin/fm-task-progress.sh owns every read; this maps its document onto the row.
task_progress() {  # <task-id>
  local doc
  doc=$("$SCRIPT_DIR/fm-task-progress.sh" "$1" 2>/dev/null) || return 1
  printf '%s\n' "$doc" | jq -c '
    select(type == "object" and .schema == "fm-task-progress.v1")
    | {state: .state, detail: (.detail // ""),
       step: (.run.step // null),
       steps: [(.run.steps // [])[] | {step: .step, status: .status}],
       active_for: (.run.active_for // null),
       last_activity: (.run.last_activity // null),
       quiet: (.run.quiet // false),
       activity: (.run.activity // null),
       refreshed: .generated}' 2>/dev/null | head -1
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
  local lang=hant out='' snapshot_file='' snapshot records='{}' cards='{}' id record card ids tmp readable=true
  local deterministic=false progress='{}' row merge_cards
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; command_compose_check "$2"; return $? ;;
      --lang) lang=${2-}; shift 2 ;;
      --out) out=${2-}; shift 2 ;;
      --snapshot) snapshot_file=${2-}; shift 2 ;;
      --deterministic) deterministic=true; shift ;;
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
  done <<EOF
$(printf '%s\n' "$snapshot" | jq -r '.decisions_open[]? | select(.verb == "captain-hold" and .owner == "(main)") | .id')
EOF
  # The stored card is the durable copy a previous build published for this
  # call, so a refresh never needs prose from the first mate for a call the
  # captain has already been shown.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    card=$(stored_card "$id")
    cards=$(jq -n --argjson acc "$cards" --arg id "$id" --argjson card "$card" \
      '$acc + (if $card == null then {} else {($id): $card} end)')
  done <<EOF
$(printf '%s\n' "$snapshot" | jq -r '.decisions_open[]? | select(.verb == "captain-hold" and .owner == "(main)") | .id')
EOF
  # A row whose projection produced nothing carries NO progress at all. The
  # payload contract allows that, and it is the only honest answer: a
  # synthesized `unknown` block is indistinguishable from a real read that
  # found nothing, and stamping it with a read time would have the board
  # claim the freshest possible read for the one row nobody read.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    card=$(task_progress "$row") || continue
    [ -n "$card" ] || continue
    progress=$(jq -n --argjson acc "$progress" --arg id "$row" --argjson p "$card" \
      '$acc + {($id): $p}')
  done <<EOF
$(printf '%s\n' "$snapshot" | jq -r '.in_flight[]? | select(.id | contains("/") | not) | .id')
EOF
  merge_cards=$(stored_merge_cards) \
    || fail "cannot read the stored merge cards under $DATA"
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-skeleton.XXXXXX") || fail "cannot stage the board skeleton"
  printf '%s\n' "$snapshot" | jq --arg schema "$BOARD_SCHEMA" --arg lang "$lang" \
    --argjson records "$records" --argjson cards "$cards" \
    --argjson merge_cards "$merge_cards" \
    --argjson progress "$progress" --argjson deterministic "$deterministic" \
    --argjson readable "$readable" --arg ph "$PLACEHOLDER_RE" "$BOARD_JQ_DEFS"'
    . as $snap |
    # Every captain-facing string goes through this one guard: the validator
    # refuses an empty en, and an ordinary metadata-only backlog row parses to
    # an empty title, so each projection names the durable value that stands in
    # for its row rather than letting one blank field refuse the whole board.
    def tv($s; $fallback):
      [$s, $fallback] | map(select(type == "string" and length > 0)) | .[0] // "(untitled)";
    # A deterministic compose has no translator in the loop, so it emits the
    # plain string the payload contract already accepts as copy - the same text
    # in every language - instead of a translation slot nobody will fill.
    def t($s; $fallback): tv($s; $fallback) as $v
      | if $deterministic then $v else {en: $v, hant: ("{TRANSLATE: " + $v + "}")} end;
    def fillv($what): "{FILL: " + $what + "}";
    def fill($what): {en: fillv($what), hant: fillv($what)};
    def risk_slot: fillv("low | medium | high");
    def reversible_slot: fillv("yes | no | partly");
    def recommend_slot($values): fillv("recommend one of " + ($values | join(" | ")));
    def i18n($fallback):
      if type != "object" then t(.; $fallback)
      elif (.en | type == "string" and length > 0) and (.hant | type == "string" and length > 0) then .
      else tv(.en; $fallback) as $v
        | . + (if $deterministic then {en: $v, hant: $v}
               else {en: $v, hant: ("{TRANSLATE: " + $v + "}")} end) end;
    def slugify:
      gsub("[^A-Za-z0-9._-]"; "-") | .[0:128] | gsub("^-+|-+$"; "")
      | if length == 0 then "row" else . end;
    def record($id): $records[$id] // null;
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
      + hold_close;
    # i18n($fallback) fills an ABSENT field with its fallback, which is right
    # for a field the card carries in one language and wrong for one it does
    # not carry at all: the captain would read an option slug as the
    # consequence of choosing it, or the task id as what happens if he does
    # nothing. Every optional field is emitted only when the card carries it.
    def packet_seeded($card): . as $row
      | $card
      + {repo: ($card.repo | if . == null or . == "" then repo_of($row.id) else . end),
         title: ($card.title | i18n($card.key)),
         options: [$card.options[] | . as $o
           | .label |= i18n($o.value)
           | if $o.consequence == null then del(.consequence)
             else .consequence |= i18n($o.value) end]}
      + (if $card.decide != null then {decide: ($card.decide | i18n($card.key))} else {} end)
      + (if $card.if_nothing != null then {if_nothing: ($card.if_nothing | i18n($card.key))} else {} end)
      + (if $card.about != null then {about: ($card.about | i18n($card.key))}
          elif $deterministic then {} else {about: fill("about")} end)
      + (if $card.recommend_why != null then {recommend_why: ($card.recommend_why | i18n($card.key))} else {} end)
      + (if $deterministic then {} else
          ({recommend_value: recommend_slot([$card.options[].value]),
            reversible: reversible_slot, risk: risk_slot}
           | with_entries(select($card[.key] == null))) end)
      + (if $card.close != null then {close: $card.close} else hold_close end)
      | if (.packet_url | link_url) then . else del(.packet_url) end;
    # With no stored and no packet-seeded copy, a deterministic compose still
    # owes the captain a visible, answerable card. It degrades to what
    # structured state actually knows - the durable title, plus the summary
    # fm-bearings-snapshot.sh already fitted for that held row from the title
    # and the hold reason, as the question - and offers no invented options;
    # the reconcile choice and free form still carry an answer back, and the
    # next full build writes real copy once.
    def degraded_card:
      {key: .key, type: "decision", repo: repo_of(.id), title: t(hold_title; .key),
       decide: t(.summary; .key), allow_freeform: true, options: []}
      + hold_close;
    def unseeded_card: if $deterministic then degraded_card else placeholder_card end;
    def decision_card: . as $row | ($cards[$row.id] // null) as $card
      | if $card == null then unseeded_card else packet_seeded($card) end;
    def merge_ready: .checks == "passing" and .mergeable == "MERGEABLE" and .review != "CHANGES_REQUESTED";
    def merge_card: .task as $task
      | ((record($task) | if . == null then null else .title end)
         // ([$snap.in_flight[]? | select(.id == $task) | .name] | .[0])) as $title
      | {key: ("merge." + $task), type: "merge",
         repo: (.repo | split("/") | last),
         title: t("Merge: " + ($title // ("PR #" + .num + " in " + .repo)); $task),
         detail: t("checks " + .checks + ", review " + .review; $task),
         risk: (if $deterministic then "unassessed" else risk_slot end),
         options: [
           {value: "merge", label: {en: "Merge now", hant: "立即合併", hans: "立即合并"}},
           {value: "hold", label: {en: "Not yet", hant: "暫緩", hans: "暂缓"}}],
         allow_freeform: true}
      + (if (.url | https_url) then {pr_url: .url} else {} end);
    def merge_ready_prs:
      [ .candidate_prs[]?
        | select((.task | slug(128 - ("merge." | length))) and record(.task) != null and merge_ready) ];
    # PR discovery is an opt-in the first mate passes; a fleet event has no
    # one to pass it, so a refresh sees no candidate_prs at all. Without a
    # COMPLETE PR view the merge cards the last publication stored are carried
    # forward unchanged - otherwise the captain would open the board and find
    # the Merge now control he asked for gone. Only a complete view is
    # authoritative enough to decide the merge cards alone, and then a PR no
    # longer ready gets no card and the publication retires its stored copy.
    # Complete means every one of these, because each is a way the view can be
    # PARTIAL while still reporting `checked`, and a partial view that dropped
    # a card is indistinguishable from a full one that retired it:
    #   - a repo whose `gh pr list` failed or timed out (prs says
    #     "N repo(s) unavailable")
    #   - a repo whose rows were capped (prs says "capped in N repo(s)")
    #   - repos never queried at all, which prs does not mention: the snapshot
    #     discloses that as an omitted surface instead
    #   - an unreadable backlog, which suppresses EVERY merge card because
    #     merge_ready_prs needs the task record - unknown ownership, not
    #     absent ownership
    def prs_checked: (.prs | startswith("checked"));
    def prs_complete:
      prs_checked
      and ((.prs | test("repo\\(s\\) unavailable")) | not)
      and ((.prs | test("capped in ")) | not)
      and (([.omitted[]? | .surface
             | select(type == "string" and startswith("PR repositories showing"))]
            | length) == 0)
      and $readable;
    def carried_merge_cards:
      if prs_complete then [] else [ $merge_cards[] ] end;
    # A card key IS one intake address, so the board may never carry two cards
    # under it. A task held more than once consolidates into one card, and the
    # composer is told to answer every one of its questions there; two
    # merge-ready PRs claiming one task get no card at all, because either
    # click would act on whichever PR the task record names, and a wrong merge
    # is worse than an absent card.
    # A deterministic compose says nothing about the consolidation. It has no
    # composer to instruct and no rendered slot to say it in, and inventing a
    # sentence for one would be exactly the copy this board refuses to publish
    # unread. The next full build writes the real card.
    def held_rows: [ .decisions_open[]? | select(held_here and (.key | slug(128))) ];
    def consolidated($n):
      if $n <= 1 or $deterministic then {}
      else {decide: fill("decide: this task is held " + ($n | tostring)
        + " times; consolidate every one of its questions into this card")} end;
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
      prs_live: prs_checked,
      captains_call: (
        [ held_rows as $rows | $rows[] | . as $row
          | decision_card + consolidated([$rows[] | select(.key == $row.key)] | length) ]
        + [ merge_ready_prs as $prs | $prs[] | . as $pr
          | select([$prs[] | select(.task == $pr.task)] | length == 1)
          | merge_card ]
        + carried_merge_cards
        | first_per_key),
      underway: [ .in_flight[]? | . as $row
        | {id, repo, name: t(.name; .id), state, kind, doing: t(.doing; .state)}
        + (($progress[$row.id] // null) as $p
          | if $p == null then {} else {progress: $p} end) ],
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
        + (if $deterministic and gates_omitted > 0 then gates_omitted as $n
          | [{id: "charted-omitted", repo: null,
             title: t(($n | tostring) + " more Charted Next rows are not shown here";
               "charted-omitted"),
             reason: t("the fleet snapshot omitted that many rows and does not say which are "
               + "queued work and which are repair notices, so neither count is stated; "
               + "ask firstmate for the full chart"; "charted-omitted"),
             dispatchable: false, kind: "warning", filed: null}] else [] end)
        + (if $readable then [] else
          [{id: "backlog-unreadable", repo: null,
            title: t("This home cannot read its own backlog"; "backlog-unreadable"),
            reason: t("merge cards are suppressed: no task record can be read to key or route a merge answer";
              "backlog-unreadable"),
            dispatchable: false, kind: "warning", filed: null}] end))
    }
    + (if gates_omitted > 0 and ($deterministic | not) then {
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

# Make the store match what was just PUBLISHED. Every decision and merge card
# the publication carries is written to its own key, so the copy the captain
# is about to see is the durable card a later refresh reuses - a decision card
# because a refresh has no first mate to write prose, a merge card because a
# refresh has no PR view to rediscover it with.
# The store must MIRROR the publication, not only grow with it: a merge card
# the publication stopped carrying - because its PR closed unmerged, went red,
# or is simply no longer merge-ready - has to leave the store in the same
# breath, or the very next fleet event carries the dead Merge now control
# straight back onto the page. So every stored merge card the publication does
# not carry is retired here. That is safe only because compose carries the
# stored cards INTO any payload whose PR view was partial, so a card missing
# here really was decided against rather than merely unseen. Decision cards are not swept: a call the payload
# happens not to card this time is still open, and bin/fm-captain-hold.sh
# retires its card when the hold is re-established.
# Copy is read from the COMPOSED payload and membership from the PUBLISHED
# one: the reconcile choice is injected per publication and the validator
# refuses a card that already carries it, so storing the published decision
# card would poison every later compose - but the composed payload still
# carries the cards reconciliation dropped, which must not be stored.
persist_composed_cards() {  # <composed.json> <published.json>
  local composed=$1 published=$2 key tmp
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-card.XXXXXX") || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    jq -c --arg key "$key" '.captains_call[] | select(.key == $key)' "$composed" > "$tmp" 2>/dev/null \
      || continue
    [ -s "$tmp" ] || continue
    "$SCRIPT_DIR/fm-captain-hold.sh" card "$key" --store "$tmp" >/dev/null 2>&1 || true
  done < <(jq -r '.captains_call[]? | select(.type == "decision" or .type == "merge") | .key' \
    "$published" 2>/dev/null)
  rm -f -- "$tmp"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    retire_stored_card "$key"
  done < <(stored_merge_keys_absent_from "$published")
}

# Every stored merge card key the published payload PROVABLY does not carry.
# A read that failed is not a key that is absent: only a definite `false` from
# the payload retires anything, so an unreadable publication keeps every
# stored card rather than sweeping the lot.
stored_merge_keys_absent_from() {  # <published.json>
  local dir key carried
  for dir in "$DATA"/merge.*; do
    [ -f "$dir/board-card.json" ] || continue
    key=${dir##*/}
    carried=$(jq -r --arg key "$key" 'any(.captains_call[]?; .key == $key)' "$1" 2>/dev/null) \
      || continue
    [ "$carried" = false ] || continue
    printf '%s\n' "$key"
  done
}

command_build() {
  local data=${1-} board sid effective owner version pre_reopen_owner leftover lock
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

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  board=$(board_path)
  # The page and the per-task stored cards are one publication, and a
  # fleet-triggered refresh rewrites that same page. Taking the shared lock
  # across both keeps a refresh that started before this build - and therefore
  # composed degraded copy for a card written here - from landing on top of it
  # afterwards. A refresh can hold the lock for at most its own deadline, so
  # that is how long a build waits for it.
  mkdir -p "$STATE" 2>/dev/null || fail "the state directory is unavailable: $STATE"
  board_require_libs
  lock=$(board_lock_path)
  if ! fm_lock_acquire_wait_bounded "$lock" "$REFRESH_TIMEOUT"; then
    rm -f -- "$effective"
    fail "another board publication is still under way (holder pid ${FM_LOCK_HELD_PID:-unknown})"
  fi
  BOARD_LOCK=$lock
  trap board_unlock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! inject_board "$effective" "$board"; then
    rm -f -- "$effective"
    fail "cannot inject the board data into $TEMPLATE"
  fi
  persist_composed_cards "$data" "$effective"
  board_unlock
  trap - EXIT
  rm -f -- "$effective"
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

# --- refresh -----------------------------------------------------------------
# Inject a freshly composed payload into the board in place. No Lavish call, no
# procevent call: the session, its URL, its source and its keyed-answer binding
# are exactly as they were, which is what makes this safe to run on every fleet
# event. Concurrency is a no-op rather than a race - a trigger that finds the
# lock held simply leaves the board to the refresh already under way.

# The language the published board was built in. A refresh republishes the
# board the captain already has, so the language is read back off the page it
# is about to replace rather than re-decided. The page is the one published
# artifact, so there is nowhere else to ask and nothing to keep in step with
# it; a home whose page carries no payload has no language to carry.
published_lang() {
  local board lang=''
  board=$(board_path)
  if [ -f "$board" ]; then
    lang=$(injected_payload "$board" \
      | jq -r 'if (.lang | type) == "string" then .lang else empty end' 2>/dev/null) || lang=''
  fi
  case "$lang" in
    en|hant|hans) printf '%s\n' "$lang" ;;
    *) return 1 ;;
  esac
}

refresh_log() {  # <message>
  local log="$STATE/.bearings-board-refresh.log" size tmp
  mkdir -p "$STATE" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log" 2>/dev/null || {
    printf 'fm-bearings-board: %s\n' "$1" >&2
    return 0
  }
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$REFRESH_LOG_MAX_BYTES" ]; then
    tmp="$log.tmp.${BASHPID:-$$}"
    tail -n 200 "$log" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$log" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

REFRESH_BEST_EFFORT=0
BOARD_LOCK=

# ONE board publication is one exclusive critical section, whichever command
# performs it: a build writes the page and the per-task stored cards, a
# fleet-triggered refresh rewrites that page, so both take the same home-local
# lock rather than racing to be last writer.
board_lock_path() { printf '%s/.bearings-board-refresh.lock\n' "$STATE"; }

# The lock and the deadline owner are loaded only for a publication: no other
# subcommand needs either, and sourcing the wake library creates state/.
board_require_libs() {
  if ! command -v fm_run_timed >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
  fi
  if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
}

# shellcheck disable=SC2329 # Invoked by the EXIT traps below.
board_unlock() {
  [ -n "$BOARD_LOCK" ] || return 0
  fm_lock_release "$BOARD_LOCK" || true
  BOARD_LOCK=
}

refresh_fail() {  # <message>
  if [ "$REFRESH_BEST_EFFORT" -eq 1 ]; then
    refresh_log "$1"
    exit 0
  fi
  fail "$1"
}

# The payload a board page is carrying, read back out of its data block. The
# page is the board's ONE published artifact, so it is the authority on what
# was last published here - there is nothing else to ask and nothing to keep
# in step with it.
injected_payload() {  # <board>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'
}

# Inject <payload.json> into a fresh copy of the template and publish it
# atomically at <board>. Shared by build and refresh so one injection contract,
# including the </script> escape and the round-trip read-back, serves both.
inject_board() {  # <payload.json> <board>
  local data=$1 board=$2 json tmp extracted
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || return 1
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] || return 1
  json=$(jq -c . "$data") || return 1
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}
  (umask 077; mkdir -p "${board%/*}") || return 1
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || return 1
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then rm -f -- "$tmp"; return 1; fi
  extracted=$(injected_payload "$tmp")
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"; return 1
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"; return 1
  fi
}

# The deadline owner. A compose reads a fresh snapshot and one progress
# projection per Underway row, each individually bounded but O(N) in total, and
# it holds the exclusive lock while it does, so a refresh that cannot finish
# would keep every later fleet trigger standing down. The work therefore runs
# in a child under one overall deadline, exactly as the home summary's refresh
# bounds itself; the lock records its owner, so a worker killed at the deadline
# is reclaimed by the next trigger rather than wedging the board for good.
command_refresh() {
  local arg rc=0 said=''
  # Read before anything can fail, so every failure below - in either role -
  # already knows whether --best-effort must absorb it.
  for arg in "$@"; do
    if [ "$arg" = --best-effort ]; then REFRESH_BEST_EFFORT=1; fi
  done
  # The wake library creates the state directory at source time, and this
  # script's errexit would turn that failure into a bare abort no --best-effort
  # caller could absorb, so the condition is named here instead.
  mkdir -p "$STATE" 2>/dev/null \
    || refresh_fail "the state directory is unavailable: $STATE"
  board_require_libs
  if [ "${FM_BEARINGS_BOARD_REFRESH_WORKER:-0}" = 1 ]; then
    refresh_worker "$@"
    return
  fi
  # The worker speaks through this parent, never past it. Killing the worker
  # at the deadline kills its own children too, and the shell it was running
  # says so on stderr - a trigger promised silence must not receive that.
  # Holding the output here means the parent decides what a caller hears:
  # nothing it did not ask for, and nothing at all under --best-effort.
  said=$(fm_run_timed "$REFRESH_TIMEOUT" env FM_BEARINGS_BOARD_REFRESH_WORKER=1 \
    "$SCRIPT_DIR/fm-bearings-board.sh" refresh "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$said" ] || printf '%s\n' "$said"
    return 0
  fi
  [ "$rc" -ne 124 ] \
    || refresh_fail "refresh exceeded its ${REFRESH_TIMEOUT}-second deadline"
  # Any other failure was already reported - and, under --best-effort, already
  # absorbed - by the worker itself; the parent only carries its status.
  if [ "$REFRESH_BEST_EFFORT" -eq 1 ]; then
    [ -z "$said" ] || refresh_log "$said"
    exit 0
  fi
  [ -z "$said" ] || printf '%s\n' "$said" >&2
  exit "$rc"
}

refresh_worker() {
  local board lang lock='' skeleton effective leftover
  local -a compose_args=(--deterministic)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) compose_args+=(--snapshot "${2-}"); shift 2 ;;
      --best-effort) REFRESH_BEST_EFFORT=1; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || refresh_fail "jq is required"
  board=$(board_path)
  if lang=$(published_lang); then compose_args+=(--lang "$lang"); fi
  # Refreshing means refreshing a board that exists. A home that never asked
  # for one is left alone rather than quietly given a page nobody armed.
  [ -f "$board" ] && [ ! -L "$board" ] \
    || refresh_fail "no board has been built yet at $board (run /bearings lavish)"
  lock=$(board_lock_path)
  if ! fm_lock_try_acquire "$lock"; then
    # Another trigger is already publishing a payload at least as fresh. The
    # stand-down is logged as well as printed, because every fleet trigger
    # sends this stdout to /dev/null: a lock that stopped clearing has to leave
    # a trace somewhere a diagnosis can find it.
    refresh_log "refresh: busy (lock held by pid ${FM_LOCK_HELD_PID:-unknown})"
    printf 'refresh: busy\n'
    return 0
  fi
  BOARD_LOCK=$lock
  trap board_unlock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  skeleton=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-refresh.XXXXXX") \
    || refresh_fail "cannot stage the refreshed payload"
  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-refresh-eff.XXXXXX") \
    || { rm -f -- "$skeleton"; refresh_fail "cannot stage the refreshed payload"; }
  # Composed in a child on purpose: a compose refusal is one of the failures
  # --best-effort must absorb, and the shared fail path exits the process.
  if ! "$SCRIPT_DIR/fm-bearings-board.sh" compose "${compose_args[@]}" --out "$skeleton" >/dev/null 2>&1; then
    rm -f -- "$skeleton" "$effective"
    refresh_fail "cannot compose the board payload"
  fi
  # A deterministic compose owes no placeholder; refusing here keeps that a
  # checked property rather than an assumption about the projection above.
  leftover=$(list_placeholders "$skeleton") || leftover=''
  if [ -n "$leftover" ]; then
    rm -f -- "$skeleton" "$effective"
    refresh_fail "the deterministic payload still carries placeholders: $(printf '%s' "$leftover" | tr '\n' ' ')"
  fi
  # Validation runs on the composed payload, exactly where build runs it: the
  # reconcile choice the reconciliation below injects is a value the validator
  # deliberately reserves, so a payload is only ever checked before it.
  if ! validate_payload "$skeleton"; then
    rm -f -- "$skeleton" "$effective"
    refresh_fail "the refreshed payload does not satisfy $BOARD_SCHEMA"
  fi
  if ! effective_payload "$skeleton" "$effective" 2>/dev/null; then
    rm -f -- "$skeleton" "$effective"
    refresh_fail "cannot reconcile the board payload against landed work"
  fi
  rm -f -- "$skeleton"
  if ! inject_board "$effective" "$board"; then
    rm -f -- "$effective"
    refresh_fail "cannot inject the refreshed board payload"
  fi
  rm -f -- "$effective"
  board_unlock
  trap - EXIT
  printf 'refreshed: %s\n' "$board"
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

case "${1-}" in
  compose) shift; command_compose "$@" ;;
  build) shift; command_build "$@" ;;
  refresh) shift; command_refresh "$@" ;;
  path) board_path ;;
  url) command_url ;;
  open) command_open ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
