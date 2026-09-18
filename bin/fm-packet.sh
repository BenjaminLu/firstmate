#!/usr/bin/env bash
# fm-packet.sh - the decision packet a worker leaves beside its work.
#
# A `done:` or `needs-decision:` status line is a wake event, not an
# explanation. The packet is the explanation: what changed (generated from
# the worktree and the PR), what only this session knows (the paths tried
# and dropped, the unverified assumptions), the decision the captain is asked
# to make (structured, so the bearings board can render it as a card), the
# evidence, and how to pull more. It lives at data/<task-id>/packet.md, beside
# the brief and the scout report, and survives teardown like the report does.
#
# Usage:
#   fm-packet.sh scaffold <task-id> [--kind done|needs-decision] [--worktree <dir>] [--pr <url>] [--force]
#   fm-packet.sh verify <task-id>
#   fm-packet.sh card <task-id> [--repo <name>]
#   fm-packet.sh path <task-id>
#
# scaffold   Write the packet skeleton. The generated section is filled from
#            the worktree (commits since the default branch, changed files,
#            uncommitted state) and from the PR when one is recorded and `gh`
#            can reach it; every section the worker must write carries a
#            `{FILL: ...}` placeholder. The worktree comes from --worktree,
#            else the task's state/<id>.meta worktree=, else the current
#            directory; the PR comes from --pr, else the meta pr=. An existing
#            packet is refused unless --force, so a filled packet is never
#            overwritten by a re-run.
# verify     Refuse a packet that is still a skeleton: a `{FILL` placeholder
#            left anywhere, fewer than three lines under "What only this
#            session knows", an empty "Evidence" section, or, for
#            kind=needs-decision, a missing or malformed decision block. The
#            decision block is a fenced ```json fm-packet-decision.v1 object:
#              key (the task id), title, decide, if_nothing, reversible
#              (yes|no|partly), optional risk (low|medium|high), options[]
#              (each value + label + consequence, at least two),
#              recommend_value (one of the option values), optional
#              recommend_why, optional close (done|release).
#            Copy fields are a plain string or an {en, hant?, hans?} object.
#            Prints `packet: ok <path>` on success; each problem goes to
#            stderr and the exit is 1.
# card       Verify, then print the fm-bearings-board.v1 Captain's Call card
#            composed from the decision block, ready to drop into a board
#            payload. A copy object without `hant` is flattened to its `en`
#            string so the board validator accepts it. --repo names the card's
#            repo; otherwise the task's meta project= basename, else "".
# path       Print the packet path for the task.
#
# The worker's contract (bin/fm-dod-lib.sh renders it into every ship brief):
# scaffold once, fill every placeholder, run verify, and only then append the
# `done:` or `needs-decision:` line. Firstmate runs verify at the wake and
# steers the worker back when it fails, so a bare status line never reaches
# the captain as if it were the whole story.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

PACKET_SCHEMA=fm-packet.v1
DECISION_SCHEMA=fm-packet-decision.v1

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
fail() { printf 'fm-packet: %s\n' "$*" >&2; exit 1; }

packet_path() { printf '%s/%s/packet.md\n' "$DATA" "$1"; }

meta_value() {  # <task-id> <key>
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] || return 0
  fm_meta_get "$meta" "$2"
}

# ---- scaffold ---------------------------------------------------------------

git_facts() {  # <worktree> -> sets HEAD_SHA BRANCH BASE COMMITS STAT DIRTY
  local wt=$1 default
  HEAD_SHA=""; BRANCH=""; BASE=""; COMMITS=""; STAT=""; DIRTY=""
  git -C "$wt" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 0
  HEAD_SHA=$(git -C "$wt" rev-parse --short=12 HEAD)
  BRANCH=$(git -C "$wt" branch --show-current 2>/dev/null)
  [ -n "$BRANCH" ] || BRANCH="(detached)"
  default=$(git -C "$wt" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  default=${default#origin/}
  if [ -z "$default" ]; then
    if git -C "$wt" rev-parse --verify -q main >/dev/null 2>&1; then default=main
    elif git -C "$wt" rev-parse --verify -q master >/dev/null 2>&1; then default=master
    fi
  fi
  if [ -n "$default" ]; then
    BASE=$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null \
      || git -C "$wt" merge-base HEAD "$default" 2>/dev/null || true)
  fi
  if [ -n "$BASE" ] && [ "$(git -C "$wt" rev-parse "$BASE")" != "$(git -C "$wt" rev-parse HEAD)" ]; then
    COMMITS=$(git -C "$wt" log --oneline "$BASE..HEAD")
    STAT=$(git -C "$wt" diff --stat "$BASE..HEAD" | tail -30)
  else
    COMMITS="(no commits beyond the default branch${default:+ $default})"
    STAT="(no committed changes beyond the default branch)"
  fi
  DIRTY=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
}

pr_facts() {  # <pr-url> -> prints lines
  local url=$1 out
  [ -n "$url" ] || { printf -- '- pr: none recorded\n'; return 0; }
  printf -- '- pr: %s\n' "$url"
  command -v gh >/dev/null 2>&1 || { printf -- '- pr state: not recorded here - ask (gh is not installed)\n'; return 0; }
  out=$(fm_run_timed 15 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh pr view "$url" --json state,isDraft,reviewDecision,statusCheckRollup \
    --jq '"- pr state: \(.state)\(if .isDraft then " (draft)" else "" end); review: \(.reviewDecision // "none"); checks: " + ([.statusCheckRollup[]? | (.conclusion // .state // "pending")] | if length == 0 then "none reported" else (group_by(.) | map("\(.[0]) x\(length)") | join(", ")) end)' 2>/dev/null) \
    || { printf -- '- pr state: not recorded here - ask (the forge did not answer)\n'; return 0; }
  printf '%s\n' "$out"
}

command_scaffold() {
  local id='' kind='done' wt='' pr='' force=0 packet dir now
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  id=$1; shift
  fm_pr_task_id_valid "$id" || fail "invalid task id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2-}; shift 2 ;;
      --worktree) wt=${2-}; shift 2 ;;
      --pr) pr=${2-}; shift 2 ;;
      --force) force=1; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$kind" in done|needs-decision) ;; *) fail "kind must be done or needs-decision" ;; esac
  [ -n "$wt" ] || wt=$(meta_value "$id" worktree)
  [ -n "$wt" ] || wt=$PWD
  [ -d "$wt" ] || fail "worktree does not exist: $wt"
  [ -n "$pr" ] || pr=$(meta_value "$id" pr)
  packet=$(packet_path "$id"); dir=${packet%/*}
  [ ! -L "$packet" ] || fail "packet path is a symlink: $packet"
  if [ -e "$packet" ] && [ "$force" -ne 1 ]; then
    fail "packet already exists (fill it, or pass --force to start over): $packet"
  fi
  mkdir -p "$dir" || fail "cannot create $dir"
  git_facts "$wt"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf '# Packet: %s\n\n' "$id"
    printf 'schema: %s\n' "$PACKET_SCHEMA"
    printf 'task: %s\n' "$id"
    printf 'kind: %s\n' "$kind"
    printf 'generated: %s\n' "$now"
    printf 'worktree: %s\n' "$wt"
    printf 'branch: %s\n' "${BRANCH:-"(not a git worktree)"}"
    printf 'head: %s\n' "${HEAD_SHA:-none}"
    printf 'base: %s\n\n' "${BASE:-none}"
    printf '## What changed (generated)\n\n'
    printf '%s\n\n' "Commits beyond the default branch:"
    printf '%s\n\n' "${COMMITS:-"(not a git worktree)"}"
    printf '%s\n\n' "Files:"
    printf '%s\n\n' "${STAT:-"(not a git worktree)"}"
    printf -- '- uncommitted paths in the worktree at scaffold time: %s\n' "${DIRTY:-unknown}"
    pr_facts "$pr"
    printf '\n## What only this session knows\n\n'
    printf '%s\n' '{FILL: every path you tried and dropped and why it died; every assumption you could not verify; every trap the next person would hit. At least three lines. A diff shows the approach that survived; only you know the ones that did not.}'
    if [ "$kind" = needs-decision ]; then
      printf '\n## The decision\n\n'
      printf '%s\n' '```json fm-packet-decision.v1'
      printf '%s\n' '{'
      printf '  "key": "%s",\n' "$id"
      printf '%s\n' '  "title": "{FILL: one noun phrase naming the decision}",'
      printf '%s\n' '  "decide": "{FILL: the question, as one sentence}",'
      printf '%s\n' '  "if_nothing": "{FILL: what happens if nobody decides}",'
      printf '%s\n' '  "reversible": "{FILL: yes | no | partly}",'
      printf '%s\n' '  "risk": "{FILL: low | medium | high}",'
      printf '%s\n' '  "options": ['
      printf '%s\n' '    {"value": "{FILL: slug}", "label": "{FILL: option A}", "consequence": "{FILL: what choosing A does and costs}"},'
      printf '%s\n' '    {"value": "{FILL: slug}", "label": "{FILL: option B}", "consequence": "{FILL: what choosing B does and costs}"}'
      printf '%s\n' '  ],'
      printf '%s\n' '  "recommend_value": "{FILL: the value you recommend}",'
      printf '%s\n' '  "recommend_why": "{FILL: why, in one or two sentences, pointing at the evidence below}"'
      printf '%s\n' '}'
      printf '%s\n' '```'
    fi
    printf '\n## Evidence\n\n'
    printf '%s\n' '{FILL: file:line for each change that matters, the tests that prove it and how to run them, CI or PR links, screenshots. One item per line.}'
    printf '\n## How to pull more\n\n'
    printf '%s\n' '```sh'
    if [ -n "$BASE" ]; then printf 'git -C %s log %s..HEAD --stat\n' "$wt" "$BASE"; fi
    if [ -n "$pr" ]; then printf 'gh pr view %s --json body,reviews,comments\n' "$pr"; printf 'gh pr diff %s\n' "$pr"; fi
    printf '%s\n' '```'
    printf '%s\n' '{FILL: optional - the files or docs worth reading first, by path, or remove this line}'
  } > "$packet" || fail "cannot write $packet"
  printf 'packet: %s\n' "$packet"
  printf 'kind: %s\n' "$kind"
  printf 'next: fill every {FILL} placeholder, then run: %s/bin/fm-packet.sh verify %s\n' "$FM_ROOT" "$id"
}

# ---- verify -----------------------------------------------------------------

section_body() {  # <packet> <heading text> -> body lines of that ## section
  awk -v want="## $2" '
    /^## / { inside = ($0 == want); next }
    inside { print }
  ' "$1"
}

content_lines() {  # stdin -> count of lines that carry content
  grep -c -v -E '^[[:space:]]*$|^[[:space:]]*(```|#|\{FILL)' || true
}

decision_block() {  # <packet> -> the JSON between the fenced decision markers
  sed -n "/^\`\`\`json $DECISION_SCHEMA\$/,/^\`\`\`\$/p" "$1" | sed '1d;$d'
}

# shellcheck disable=SC2016  # a jq program: $task is jq's variable, not the shell's
decision_jq='
  def copy: (type == "string" and length > 0)
    or (type == "object" and (.en | type == "string" and length > 0)
        and ((has("hant") | not) or (.hant | type == "string"))
        and ((has("hans") | not) or (.hans | type == "string")));
  def slug: type == "string" and test("^[A-Za-z0-9._-]{1,128}$");
  def problem(cond; msg): if cond then empty else msg end;
  [ problem(type == "object"; "decision block is not a JSON object"),
    problem(.key == $task; "decision key must be the task id \($task)"),
    problem(.title | copy; "title is missing or not copy"),
    problem(.decide | copy; "decide is missing or not copy"),
    problem(.if_nothing | copy; "if_nothing is missing or not copy"),
    problem(.reversible == "yes" or .reversible == "no" or .reversible == "partly"; "reversible must be yes, no, or partly"),
    problem((has("risk") | not) or (.risk == "low" or .risk == "medium" or .risk == "high"); "risk must be low, medium, or high"),
    problem((.options | type == "array") and (.options | length >= 2); "options must list at least two choices"),
    problem((.options | type == "array") and ([.options[]? | type == "object" and (.value | slug) and (.label | copy) and (.consequence | copy)] | all); "every option needs value, label, and consequence"),
    problem((.options | type == "array") and ([.options[]?.value] | index("reconcile") == null); "reconcile is reserved for the board"),
    problem(.recommend_value as $r | (.options | type == "array") and ([.options[]?.value] | index($r) != null); "recommend_value must name one of the options"),
    problem((has("recommend_why") | not) or (.recommend_why | copy); "recommend_why must be copy"),
    problem((has("close") | not) or (.close == "done" or .close == "release"); "close must be done or release")
  ] | .[]'

command_verify() {  # <task-id> ; prints problems to stderr, exit 1 on any
  local id=${1-} packet kind problems=0 n block
  [ -n "$id" ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$id" || fail "invalid task id"
  packet=$(packet_path "$id")
  [ ! -L "$packet" ] || fail "packet path is a symlink: $packet"
  [ -f "$packet" ] || fail "no packet at $packet (run: fm-packet.sh scaffold $id)"
  grep -qx "schema: $PACKET_SCHEMA" "$packet" || { echo "fm-packet: missing 'schema: $PACKET_SCHEMA' line" >&2; problems=$((problems + 1)); }
  kind=$(sed -n 's/^kind: //p' "$packet" | head -1)
  case "$kind" in done|needs-decision) ;; *) echo "fm-packet: kind line must be done or needs-decision" >&2; problems=$((problems + 1)) ;; esac
  if grep -q '{FILL' "$packet"; then
    echo "fm-packet: placeholders remain: $(grep -c '{FILL' "$packet") x {FILL" >&2; problems=$((problems + 1))
  fi
  n=$(section_body "$packet" "What only this session knows" | content_lines)
  [ "$n" -ge 3 ] || { echo "fm-packet: 'What only this session knows' has $n content line(s); at least three are required" >&2; problems=$((problems + 1)); }
  n=$(section_body "$packet" "Evidence" | content_lines)
  [ "$n" -ge 1 ] || { echo "fm-packet: 'Evidence' is empty" >&2; problems=$((problems + 1)); }
  if [ "$kind" = needs-decision ]; then
    block=$(decision_block "$packet")
    if [ -z "$block" ]; then
      echo "fm-packet: kind=needs-decision but no \`\`\`json $DECISION_SCHEMA block" >&2; problems=$((problems + 1))
    elif ! printf '%s\n' "$block" | jq -e . >/dev/null 2>&1; then
      echo "fm-packet: the decision block is not valid JSON" >&2; problems=$((problems + 1))
    else
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "fm-packet: decision: $line" >&2; problems=$((problems + 1))
      done < <(printf '%s\n' "$block" | jq -r --arg task "$id" "$decision_jq")
    fi
  fi
  [ "$problems" -eq 0 ] || exit 1
  printf 'packet: ok %s\n' "$packet"
}

# ---- card -------------------------------------------------------------------

command_card() {
  local id='' repo='' packet project
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  id=$1; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=${2-}; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  command_verify "$id" >/dev/null || exit 1
  packet=$(packet_path "$id")
  [ "$(sed -n 's/^kind: //p' "$packet" | head -1)" = needs-decision ] \
    || fail "packet kind is done; a card needs a needs-decision packet"
  if [ -z "$repo" ]; then
    project=$(meta_value "$id" project)
    [ -z "$project" ] || repo=${project##*/}
  fi
  decision_block "$packet" | jq --arg repo "$repo" '
    def flat: if type == "object" then (if (.hant | type) == "string" then . else .en end) else . end;
    {
      key: .key, type: "decision", repo: $repo,
      title: (.title | flat), decide: (.decide | flat), if_nothing: (.if_nothing | flat),
      reversible: .reversible,
      options: [.options[] | {value, label: (.label | flat), consequence: (.consequence | flat)}],
      recommend_value: .recommend_value,
      allow_freeform: true
    }
    + (if has("risk") then {risk: .risk} else {} end)
    + (if has("recommend_why") then {recommend_why: (.recommend_why | flat)} else {} end)
    + (if has("close") then {close: .close} else {} end)'
}

case "${1-}" in
  scaffold) shift; command_scaffold "$@" ;;
  verify) shift; command_verify "$@" ;;
  card) shift; command_card "$@" ;;
  path)
    shift
    if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then usage >&2; exit 2; fi
    packet_path "$1" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
