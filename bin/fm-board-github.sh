#!/usr/bin/env bash
# fm-board-github.sh - GitHub is the board's store.
#
# THE PROBLEM THIS SOLVES. The bearings board had two surfaces and neither was
# neutral: the desk board is reachable only from the captain's own machine, and
# the remote board kept its payload in a Claude artifact's store, so both the
# data and the answers were reachable only from a first-party session of one
# vendor. A workflow that must run without any one vendor's agent cannot keep
# its captain-facing surface inside one.
#
# GitHub resolves both at once, and it is already here: the repository lives
# there, a public repository's raw content is fetchable over plain HTTPS with
# no credential and no account, and every browser and every coding agent can
# read it. One store, read by anything.
#
#   store    https://raw.githubusercontent.com/<owner>/<repo>/<branch>/board.json
#   page     the shipped board template plus the GitHub transport, published
#            beside it as index.html so the store branch can be served by
#            GitHub Pages without another service
#
# Usage:
#   fm-board-github.sh publish [<data.json>] [--reason <why>] [--force]
#   fm-board-github.sh event <why>
#   fm-board-github.sh page [--out <file>]
#   fm-board-github.sh url [board|page|answer]
#   fm-board-github.sh doctor
#   fm-board-github.sh --help
#
# publish    Resolve the payload, validate it through its contract owner, wrap
#            it in the fm-board-store.v1 envelope, and write the store. With no
#            <data.json> the payload is refreshed from live fleet state (see
#            THE REFRESH below). Prints `published: <url>` on a write and
#            `unchanged: <url>` when the board is byte-identical to what is
#            already published, because republishing the same board only moves
#            the timestamp and buys the captain nothing.
# event      Record that a fleet event may have changed the board and hand the
#            publish to a single coalescing background writer. This is the door
#            the fleet's own event scripts call; it returns immediately and
#            never fails its caller, because publishing a board must not be
#            able to break a spawn, a teardown, or a merge.
# page       Derive the GitHub-reading board page from the shipped template and
#            write it to --out (default: this home's derived page path).
# url        Print the store URL (`board`, the default), the page URL for the
#            configured serving choice (`page`), or the answer intake URL
#            (`answer`). Exits 1 with a reason when the home has no store.
# doctor     Report what is and is not set up here - the address, the shipped
#            assets, whether a payload is waiting, whether anything is
#            published, and what the read path costs - so a fresh clone learns
#            its state instead of finding out at the surface the captain reads.
#            Exits 0 when the home has no store, because that is a complete and
#            supported state.
#
# THE READ PATH IS CREDENTIAL-FREE, AND THAT FORCES A PUBLIC STORE. Measured on
# raw.githubusercontent.com: `access-control-allow-origin: *`, so a page on any
# origin - GitHub Pages, a file:// page opened from a clone, an artifact - may
# fetch it, and `curl` from a clone with nothing configured reads the same
# bytes. Neither works on a private repository: raw returns 404 without a
# token, and a token in a page the captain opens is not credential-free. There
# is no third option. A store is therefore published ONLY to a repository this
# home has named AND acknowledged as public, and publish re-checks the real
# visibility every time and refuses a private one rather than writing a store
# nothing can read. What the board carries - task names, decisions, pull
# request links, whole decision packets - becomes world-readable. That is the
# price of the neutral read, it is stated here because it is a captain's call
# and not a default, and `config/board-store` is where he makes it.
#
# THE STALENESS BOUND IS 300 SECONDS AND IT IS NOT NEGOTIABLE. raw sends
# `cache-control: max-age=300` from a CDN that ignores the query string: a
# never-before-used `?cb=` parameter still returns `x-cache: HIT` with the same
# `source-age`, so cache-busting does not work and a reader cannot be made to
# see a write sooner. GitHub is not a live channel. The envelope therefore
# carries `read_lag_bound_secs` and the page states the bound and the age of
# what it is showing, rather than implying live. Publishing faster than that
# floor cannot reach anyone, so FM_BOARD_PUBLISH_FLOOR_SECS (default 60) is the
# shortest gap between two writes; events inside that window coalesce into the
# next one instead of spending four API calls nobody can observe.
#
# THE WRITE PATH IS THE FLEET. Nothing polls fleet state to notice a change.
# The scripts that already know an event happened - a spawn, a teardown, a
# captain hold, a pull request check, a board build - call `event`, which marks
# the store dirty and hands off to one background writer. `event` is the whole
# seam: a second transport for the same board adds itself here rather than
# adding its own call into those five scripts again.
#
# THE REFRESH, AND WHAT IT WILL NOT INVENT. A board payload is part mechanical
# and part written: the fleet rows and a packet-seeded card come from the
# snapshot, but a decision card's prose is composed by firstmate. So a refresh
# recomposes the mechanical half from live state and carries the written half
# forward by card key. A call that is genuinely new and has no verified packet
# has no prose anywhere, and this script will not write it: the card is left
# out and the board gains a warning row naming it, the same way the board
# already handles a call it cannot address. Firstmate's next build fills it in.
# A placeholder never reaches the store; publish refuses the whole payload.
#
# WHAT THE STORE IS, ON DISK. One orphan commit on a dedicated branch, forced
# into place through GitHub's git data API: a blob, a tree, a parentless
# commit, a forced ref update. Parentless is the point - the branch holds
# exactly one commit no matter how many times the board is published, so a
# board that updates every minute never grows a history, never touches the
# default branch, never touches any working tree, and never starts CI (this
# repository's workflows fire on main and on pull requests to main only). The
# API path is also why no clone, remote, or checkout is needed to publish: the
# store is written from credentials, not from a working copy.
#
# ONE BOARD DEFINITION. The page is DERIVED from the shipped template
# (.agents/skills/bearings/assets/board-template.html) and never re-authored,
# so every card type, badge, packet figure, picker and language the desk board
# gains reaches this one without anyone maintaining a list. Exactly two things
# differ, and both live in .agents/skills/bearings/assets/github-transport.js:
# where the payload comes from, and where an answer goes. Derivation is
# anchored on the template's two seams - its `bearings-data` slot and its
# window.lavish.queuePrompt answer interface - and stops, naming the seam, if
# either moves.
#
# THE PAYLOAD CONTRACT IS NOT OWNED HERE. `bin/fm-bearings-board.sh` states
# fm-bearings-board.v1 once and validates it; this script calls that validator
# rather than keeping a second copy of the rules.
#
# FM_BOARD_GITHUB_TEMPLATE and FM_BOARD_GITHUB_TRANSPORT override the shipped
# asset paths, and FM_BOARD_GITHUB_GH overrides the forge command (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="$FM_HOME/config/board-store"
ASSETS="$FM_ROOT/.agents/skills/bearings/assets"

TEMPLATE="${FM_BOARD_GITHUB_TEMPLATE:-$ASSETS/board-template.html}"
TRANSPORT="${FM_BOARD_GITHUB_TRANSPORT:-$ASSETS/github-transport.js}"
GH="${FM_BOARD_GITHUB_GH:-gh}"

STORE_SCHEMA=fm-board-store.v1
STORE_FILE=board.json
PAGE_FILE=index.html
ANSWER_LABEL=fm-board-answer
DATA_SLOT='__FM_BEARINGS_BOARD_DATA__'
SCRIPT_SLOT='__FM_BEARINGS_BOARD_SCRIPT__'
READ_LAG_BOUND=300

PAYLOAD="$STATE/board-payload.json"
DERIVED="$FM_HOME/.lavish/github-board.html"
DIRTY="$STATE/.board-dirty"
PUBLISHED="$STATE/.board-published"
PAGE_BLOB="$STATE/.board-page-blob"
LOCK="$STATE/.board-publish.lock"

PLACEHOLDER_RE='\{(FILL|TRANSLATE)(:[^}]*)?\}'
PUBLISH_WORK=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

need() {  # <tool>...
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required and is not on PATH"
  done
}

# ---- configuration -------------------------------------------------------
# One local file names the store. There is deliberately NO default: guessing a
# repository from `origin` would publish one home's fleet state to whatever
# that clone happens to point at, and a default that is wrong for everyone but
# convenient for one home is the wrong default. Absent means "this home has no
# store", which doctor reports and publish refuses out loud.

# The store repository must be public, because that is what a credential-free
# read costs. The ANSWER sink does not: submitting an answer needs the captain
# signed in to GitHub either way, so a private repository takes his decisions
# without making his words world-readable. It defaults to the store repository
# and says so, because a captain who has not chosen is publishing his answers.
STORE_REPO=
STORE_BRANCH=
STORE_ACK=
ANSWER_REPO=

read_config() {  # 0 = configured, 1 = absent, fails on malformed
  STORE_REPO=; STORE_BRANCH=fm-board; STORE_ACK=; ANSWER_REPO=
  [ -f "$CONFIG" ] || return 1
  local line key value lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case $line in ''|'#'*) continue ;; esac
    case $line in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) fail "config/board-store line $lineno is not key=value: $line" ;;
    esac
    case $key in
      repo) STORE_REPO=$value ;;
      branch) STORE_BRANCH=$value ;;
      visibility) STORE_ACK=$value ;;
      answer_repo) ANSWER_REPO=$value ;;
      *) fail "config/board-store line $lineno names an unknown key: $key" ;;
    esac
  done < "$CONFIG"
  [ -n "$STORE_REPO" ] || fail "config/board-store names no repo="
  printf '%s' "$STORE_REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
    || fail "config/board-store repo= is not <owner>/<name>: $STORE_REPO"
  printf '%s' "$STORE_BRANCH" | grep -Eq '^[A-Za-z0-9._/-]{1,100}$' \
    || fail "config/board-store branch= is not a branch name: $STORE_BRANCH"
  if [ -n "$ANSWER_REPO" ]; then
    printf '%s' "$ANSWER_REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
      || fail "config/board-store answer_repo= is not <owner>/<name>: $ANSWER_REPO"
  else
    ANSWER_REPO=$STORE_REPO
  fi
  return 0
}

require_store() {
  read_config || fail "this home has no board store: write $CONFIG (see docs/configuration.md \"Board store\")"
}

# The acknowledgement and the measured truth are two different checks and both
# have to pass. The first is the captain's consent to publish fleet state where
# the world can read it; the second is whether the read path actually works.
require_public() {
  [ "$STORE_ACK" = public ] || fail \
    "config/board-store must carry visibility=public: a credential-free read means a public repository, and publishing the fleet's board there makes task names, decisions, pull request links and decision packets world-readable. That is the captain's call to record, not this script's to assume."
  local private
  private=$("$GH" api "repos/$STORE_REPO" --jq '.private' 2>/dev/null) \
    || fail "cannot read $STORE_REPO from the forge; not publishing a store this home cannot verify"
  case $private in
    false) : ;;
    true) fail "$STORE_REPO is private: raw.githubusercontent.com returns 404 there without a token, so the store would be unreadable by the page it is for" ;;
    *) fail "$STORE_REPO visibility could not be established (got '$private'); not publishing" ;;
  esac
}

api_url() { printf 'https://api.github.com/repos/%s/contents/%s?ref=%s\n' "$STORE_REPO" "$STORE_FILE" "$STORE_BRANCH"; }
store_url() { printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "$STORE_REPO" "$STORE_BRANCH" "$STORE_FILE"; }
pages_url() { printf 'https://%s.github.io/%s/\n' "${STORE_REPO%%/*}" "${STORE_REPO#*/}"; }
answer_url() { printf 'https://github.com/%s/issues/new?labels=%s\n' "$ANSWER_REPO" "$ANSWER_LABEL"; }

# ---- page derivation -----------------------------------------------------

# The page's data slot carries the whole fm-board-store.v1 envelope, not the
# bare payload: first paint must be able to say how old it is and where to
# read from, and the transport hands the board half to the shipped renderer.
build_envelope() {  # <payload.json> <out.json> <reason>
  # shellcheck disable=SC2016  # a jq program: the $ names are jq's, not the shell's
  jq -n --slurpfile board "$1" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg schema "$STORE_SCHEMA" \
        --argjson lag "$READ_LAG_BOUND" \
        --arg url "$(store_url)" --arg api "$(api_url)" \
        --arg repo "$ANSWER_REPO" --arg label "$ANSWER_LABEL" \
        --arg reason "$3" \
    '{schema: $schema, published_at: $at, read_lag_bound_secs: $lag,
      published_for: (if $reason == "" then null else $reason end),
      read: {url: $url, api_url: $api},
      answer: {kind: "github-issue", repo: $repo, label: $label},
      board: $board[0]}' > "$2" || fail "the store envelope could not be built"
}

derive_page() {  # <envelope.json> <out>
  local data=$1 out=$2 script
  [ -f "$TEMPLATE" ] || fail "the shipped board template is missing: $TEMPLATE"
  [ -f "$TRANSPORT" ] || fail "the shipped GitHub transport is missing: $TRANSPORT"
  grep -Fq "$DATA_SLOT" "$TEMPLATE" \
    || fail "the template's data slot ($DATA_SLOT) has moved; the page is not derived rather than derived wrong"
  grep -Fq 'window.lavish.queuePrompt' "$TEMPLATE" \
    || fail "the template's answer interface (window.lavish.queuePrompt) has moved; the page is not derived rather than derived wrong"
  grep -Fq "$SCRIPT_SLOT" "$TRANSPORT" \
    || fail "the GitHub transport has no board-script slot ($SCRIPT_SLOT)"
  script=$(extract_board_script) || exit 1
  PAGE_DATA=$data PAGE_SCRIPT=$script PAGE_TRANSPORT=$TRANSPORT \
  PAGE_SLOT_DATA=$DATA_SLOT PAGE_SLOT_SCRIPT=$SCRIPT_SLOT \
    python3 "$SCRIPT_DIR/fm-board-github-page.py" "$TEMPLATE" > "$out.tmp" \
    || { rm -f -- "$out.tmp"; fail "deriving the GitHub board page failed"; }
  mv -f -- "$out.tmp" "$out"
}

# The template's own render script, taken out of the template rather than kept
# as a copy here, so the derived page runs exactly what the desk board runs.
extract_board_script() {
  TEMPLATE_PATH=$TEMPLATE python3 - <<'PY'
import os, re, sys
src = open(os.environ["TEMPLATE_PATH"], encoding="utf-8").read()
# the render script is the last <script> with no attributes
blocks = [m for m in re.finditer(r'<script>\n(.*?)\n</script>', src, re.S)]
if not blocks:
    sys.stderr.write("error: the template has no bare <script> render block\n")
    sys.exit(1)
sys.stdout.write(blocks[-1].group(1))
PY
}

# ---- payload refresh -----------------------------------------------------

has_placeholder() {  # <file>
  grep -Eq "$PLACEHOLDER_RE" "$1"
}

refresh_payload() {  # <out.json>
  local out=$1 fresh
  fresh=$(mktemp "${TMPDIR:-/tmp}/fm-board-fresh.XXXXXX") || exit 1
  if ! "$SCRIPT_DIR/fm-bearings-board.sh" compose --out "$fresh" 2>/dev/null; then
    rm -f -- "$fresh"
    [ -f "$PAYLOAD" ] || fail "no board payload exists yet and live state could not be composed"
    note "refresh: live state could not be composed; publishing the payload already on disk"
    cp -- "$PAYLOAD" "$out"
    return 0
  fi
  if [ -f "$PAYLOAD" ]; then
    jq -n --slurpfile fresh "$fresh" --slurpfile prev "$PAYLOAD" -f "$SCRIPT_DIR/fm-board-merge.jq" > "$out" \
      || { rm -f -- "$fresh"; fail "merging the refreshed board with its written prose failed"; }
  else
    jq -n --slurpfile fresh "$fresh" --slurpfile prev '[]' -f "$SCRIPT_DIR/fm-board-merge.jq" > "$out" \
      || { rm -f -- "$fresh"; fail "projecting the refreshed board failed"; }
  fi
  rm -f -- "$fresh"
}

# ---- the store write -----------------------------------------------------

gh_post() {  # <path> ; body on stdin
  "$GH" api -X POST "repos/$STORE_REPO/git/$1" --input -
}

write_store() {  # <envelope.json> <page.html>
  local envelope=$1 page=$2 data_blob page_blob tree commit page_digest cached
  data_blob=$(blob_for "$envelope") || exit 1
  page_digest=$(digest_of "$page") || exit 1
  cached=$(cached_page_blob "$page_digest") || cached=
  if [ -n "$cached" ]; then
    page_blob=$cached
  else
    page_blob=$(blob_for "$page") || exit 1
    printf '%s\t%s\n' "$page_digest" "$page_blob" > "$PAGE_BLOB"
  fi
  tree=$(jq -n --arg d "$data_blob" --arg p "$page_blob" --arg df "$STORE_FILE" --arg pf "$PAGE_FILE" \
    '{tree: [{path:$df, mode:"100644", type:"blob", sha:$d},
             {path:$pf, mode:"100644", type:"blob", sha:$p}]}' \
    | gh_post trees 2>/dev/null | jq -r '.sha') || fail "the store tree could not be created"
  [ -n "$tree" ] && [ "$tree" != null ] || fail "the store tree could not be created"
  # Parentless on purpose: the branch keeps exactly one commit forever.
  commit=$(jq -n --arg t "$tree" --arg m "board: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{message:$m, tree:$t, parents:[]}' \
    | gh_post commits 2>/dev/null | jq -r '.sha') || fail "the store commit could not be created"
  [ -n "$commit" ] && [ "$commit" != null ] || fail "the store commit could not be created"
  update_ref "$commit" || fail "the store branch could not be updated"
}

blob_for() {  # <file> -> blob sha
  local sha
  sha=$(jq -n --arg c "$(base64 < "$1" | tr -d '\n')" '{content:$c, encoding:"base64"}' \
    | gh_post blobs 2>/dev/null | jq -r '.sha') || return 1
  [ -n "$sha" ] && [ "$sha" != null ] || return 1
  printf '%s\n' "$sha"
}

digest_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

cached_page_blob() {  # <digest> -> blob sha when the cache matches
  [ -f "$PAGE_BLOB" ] || return 1
  awk -v want="$1" -F'\t' '$1 == want { print $2; found = 1 } END { exit found ? 0 : 1 }' "$PAGE_BLOB"
}

update_ref() {  # <commit sha>
  local body
  body=$(jq -n --arg s "$1" '{sha:$s, force:true}')
  if "$GH" api -X PATCH "repos/$STORE_REPO/git/refs/heads/$STORE_BRANCH" --input - <<< "$body" >/dev/null 2>&1; then
    return 0
  fi
  body=$(jq -n --arg s "$1" --arg r "refs/heads/$STORE_BRANCH" '{ref:$r, sha:$s}')
  "$GH" api -X POST "repos/$STORE_REPO/git/refs" --input - <<< "$body" >/dev/null 2>&1
}

# ---- publish -------------------------------------------------------------

command_publish() {
  local data='' reason='' force=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --reason) shift; reason=${1-}; [ -n "$reason" ] || fail "--reason needs a value" ;;
      --force) force=1 ;;
      --*) fail "unknown option: $1" ;;
      *) [ -z "$data" ] || fail "publish takes one payload"; data=$1 ;;
    esac
    shift
  done
  need jq base64 python3
  require_store
  require_public

  mkdir -p "$STATE" "$(dirname "$DERIVED")"
  # Not `local`: the EXIT trap runs after this function's frame is gone, and
  # under `set -u` a trap naming a dead local kills the shell on the way out -
  # after a successful publish, which would report a failure that did not happen.
  PUBLISH_WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-pub.XXXXXX") || exit 1
  trap 'rm -rf -- "${PUBLISH_WORK:-}"' EXIT HUP INT TERM
  local work=$PUBLISH_WORK
  local payload="$work/payload.json"

  if [ -n "$data" ]; then
    [ -f "$data" ] || fail "board data does not exist: $data"
    cp -- "$data" "$payload"
  else
    refresh_payload "$payload"
  fi

  if has_placeholder "$payload"; then
    grep -Eon "$PLACEHOLDER_RE" "$payload" | head -5 >&2 || true
    fail "the payload still carries composer placeholders; refusing to publish a board with holes in it"
  fi
  "$SCRIPT_DIR/fm-bearings-board.sh" validate "$payload" >/dev/null \
    || fail "the payload does not satisfy its contract; nothing published"

  local digest; digest=$(digest_of "$payload")
  if [ "$force" -eq 0 ] && [ -f "$PUBLISHED" ] \
     && [ "$(awk 'NR==1{print $2}' "$PUBLISHED")" = "$digest" ]; then
    cp -- "$payload" "$PAYLOAD"
    rm -f -- "$DIRTY"
    printf 'unchanged: %s\n' "$(store_url)"
    return 0
  fi

  local envelope="$work/store.json"
  build_envelope "$payload" "$envelope" "$reason"

  derive_page "$envelope" "$work/index.html"
  cp -- "$work/index.html" "$DERIVED"
  write_store "$envelope" "$work/index.html"

  cp -- "$payload" "$PAYLOAD"
  printf '%s %s\n' "$(date -u +%s)" "$digest" > "$PUBLISHED"
  rm -f -- "$DIRTY"
  printf 'published: %s\n' "$(store_url)"
}

# ---- the fleet's door ----------------------------------------------------

command_event() {
  local why=${1:-fleet event}
  # A board that cannot be published must never break the work that changed it.
  read_config >/dev/null 2>&1 || exit 0
  mkdir -p "$STATE" 2>/dev/null || exit 0
  printf '%s\t%s\n' "$(date -u +%s)" "$why" >> "$DIRTY" 2>/dev/null || exit 0
  # One writer. A second event while one is running is already covered by the
  # dirty mark the running writer re-reads.
  if command -v flock >/dev/null 2>&1; then
    ( flock -n 9 || exit 0; drain_publishes ) 9>"$LOCK" >/dev/null 2>&1 &
  else
    ( mkdir "$LOCK.d" 2>/dev/null || exit 0
      trap 'rmdir "$LOCK.d" 2>/dev/null || true' EXIT
      drain_publishes ) >/dev/null 2>&1 &
  fi
  exit 0
}

# Coalesce: publish, then if events arrived during the write, wait out the
# floor and publish once more. Nothing here diffs state to find work; the
# dirty mark is written by whoever knew.
drain_publishes() {
  local floor=${FM_BOARD_PUBLISH_FLOOR_SECS:-60} last gap
  case $floor in ''|*[!0-9]*) floor=60 ;; esac
  while [ -f "$DIRTY" ]; do
    if [ -f "$PUBLISHED" ]; then
      last=$(awk 'NR==1{print $1}' "$PUBLISHED")
      case $last in ''|*[!0-9]*) last=0 ;; esac
      gap=$(( $(date -u +%s) - last ))
      [ "$gap" -ge "$floor" ] || sleep $(( floor - gap ))
    fi
    local why; why=$(awk -F'\t' 'END{print $2}' "$DIRTY" 2>/dev/null || true)
    rm -f -- "$DIRTY"
    command_publish --reason "${why:-fleet event}" || return 0
  done
}

# ---- the rest ------------------------------------------------------------

command_page() {
  local out=$DERIVED
  while [ "$#" -gt 0 ]; do
    case $1 in
      --out) shift; out=${1-}; [ -n "$out" ] || fail "--out needs a path" ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done
  need jq python3
  require_store
  [ -f "$PAYLOAD" ] || fail "no board payload exists yet: build a board first"
  mkdir -p "$(dirname "$out")"
  local envelope; envelope=$(mktemp "${TMPDIR:-/tmp}/fm-board-env.XXXXXX") || exit 1
  build_envelope "$PAYLOAD" "$envelope" "page"
  derive_page "$envelope" "$out"
  rm -f -- "$envelope"
  printf 'page: %s\n' "$out"
}

command_url() {
  require_store
  case ${1:-board} in
    board) store_url ;;
    page) pages_url ;;
    answer) answer_url ;;
    *) fail "url takes board, page, or answer" ;;
  esac
}

command_doctor() {
  if ! read_config; then
    printf 'store: none (this home does not publish a board; write %s to start)\n' "$CONFIG"
    exit 0
  fi
  printf 'store: %s\n' "$(store_url)"
  printf 'page: %s\n' "$(pages_url)"
  printf 'answers: %s\n' "$(answer_url)"
  if [ "$ANSWER_REPO" = "$STORE_REPO" ]; then
    printf 'answer sink: the public store repository - the captain'"'"'s own words land where the world can read them; set answer_repo= to a private repository to keep them out of public view\n'
  else
    printf 'answer sink: %s (separate from the public store)\n' "$ANSWER_REPO"
  fi
  if [ "$STORE_ACK" = public ]; then
    printf 'acknowledged: public\n'
  else
    printf 'acknowledged: NO - publish refuses until config/board-store carries visibility=public\n'
  fi
  local private
  if private=$("$GH" api "repos/$STORE_REPO" --jq '.private' 2>/dev/null); then
    case $private in
      false) printf 'visibility: public (the read path works without a credential)\n' ;;
      true) printf 'visibility: PRIVATE - raw returns 404 without a token, so the page could not read this store\n' ;;
      *) printf 'visibility: unknown (the forge answered %s)\n' "$private" ;;
    esac
  else
    printf 'visibility: could not be checked (the forge was unreachable or unauthenticated)\n'
  fi
  [ -f "$TEMPLATE" ] && printf 'template: %s\n' "$TEMPLATE" || printf 'template: MISSING %s\n' "$TEMPLATE"
  [ -f "$TRANSPORT" ] && printf 'transport: %s\n' "$TRANSPORT" || printf 'transport: MISSING %s\n' "$TRANSPORT"
  [ -f "$PAYLOAD" ] && printf 'payload: %s\n' "$PAYLOAD" || printf 'payload: none yet\n'
  if [ -f "$PUBLISHED" ]; then
    printf 'published: %s seconds ago\n' "$(( $(date -u +%s) - $(awk 'NR==1{print $1}' "$PUBLISHED") ))"
  else
    printf 'published: never\n'
  fi
  [ -f "$DIRTY" ] && printf 'pending: %s fleet events waiting for the next write\n' "$(wc -l < "$DIRTY" | tr -d ' ')" || true
  printf 'read lag: up to %s seconds (raw sends cache-control max-age=%s and ignores cache-busting query strings)\n' \
    "$READ_LAG_BOUND" "$READ_LAG_BOUND"
}

case "${1---help}" in
  publish) shift; command_publish "$@" ;;
  event) shift; command_event "$@" ;;
  page) shift; command_page "$@" ;;
  url) shift; command_url "$@" ;;
  doctor) shift; command_doctor "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
