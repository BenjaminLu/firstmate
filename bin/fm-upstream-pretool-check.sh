#!/usr/bin/env bash
# PreToolUse seatbelt against a WRITE to the repository this clone was forked
# from - the one its `upstream` remote points at.
#
# Why it exists as a seatbelt rather than an instruction: on 2026-09-19 a worker
# opened a pull request against the original author's repository from one of our
# branches. Nothing was malicious - work in progress simply has no business in
# someone else's repository, and the captain's standing rule is that we send
# that project nothing. An instruction cannot enforce that, because the worker
# reading the instruction is the one who forgets it.
#
# Reads and fetches against upstream stay allowed. The upstream remote is
# deliberate configuration: a fork keeps current by fetching from it, and
# removing or renaming the remote is not the remedy. Only writes are refused.
#
# The protected repository is DERIVED from this clone's own `upstream` remote,
# never hardcoded, so a clone by anyone else protects THEIR upstream and a clone
# with no upstream remote - the common case - is completely unaffected.
#
# This script is the single owner of the classification. See
# docs/upstream-guard.md for the complete contract and validation record.
#
# Scope note: this guard is registered through firstmate's own harness
# configuration, so it covers work in firstmate's checkout and its task
# worktrees. It does NOT reach a clone under projects/, which carries its own
# harness configuration; that remains an open gap recorded in
# docs/upstream-guard.md.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-upstream-pretool-check.sh
#   bin/fm-upstream-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude, Codex, and Cursor, and reads .cwd when the payload carries one. CLI
# mode is used by OpenCode, Pi, and omp after their adapters extract the exact
# command string. --cursor selects Cursor's own deny rendering and marks this
# invocation as the Cursor registration rather than the Claude-settings
# duplicate Cursor also loads.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status.
#   INERT - the resolved repository has no `upstream` remote: exit 0 with no
#           output, exactly like ALLOW.
#   ESCAPE - FM_ALLOW_UPSTREAM_WRITE=1 in the environment allows deliberately.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing git, an unresolvable repository, or an upstream URL
#               this parser cannot read as owner/repo. A guard that wedges the
#               fleet on its own bug is worse than the hole it closes.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode, Pi, and omp consume exit 2 plus stderr.
set -u

# The forge subcommand pairs that WRITE to the repository they name. Each entry
# is "<noun> <verb>". This list is the single owner of the shipped write
# classification: a forge subcommand that is not listed here is treated as a
# read and allowed, which is the direction this guard fails in by design.
FORGE_WRITE_PAIRS='
pr create
pr edit
pr close
pr comment
pr review
pr merge
pr reopen
pr ready
pr lock
pr unlock
issue create
issue edit
issue close
issue comment
issue reopen
issue delete
issue lock
issue unlock
issue pin
issue unpin
issue transfer
issue develop
release create
release edit
release delete
release upload
repo edit
repo delete
repo archive
repo rename
'

# HTTP methods that make `gh api` a write. A bare `gh api <path>` is a GET and
# stays allowed.
API_WRITE_METHODS='POST PATCH PUT DELETE post patch put delete'

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0
PAYLOAD_CWD=""

usage() {
  cat <<'EOF'
Usage: fm-upstream-pretool-check.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Denies a command that would WRITE to the repository this clone's `upstream`
remote points at: opening, editing, closing, commenting on, reviewing or
merging a pull request there, creating or editing an issue there, a writing
`gh api` call against it, or a push to it by remote name or by URL.
Reads and `git fetch` against upstream stay allowed.
The protected repository is derived from this clone's own `upstream` remote; a
clone with no upstream remote is a silent no-op.
Exits 0 to allow and 2 to deny, naming the fork to write to instead.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Set FM_ALLOW_UPSTREAM_WRITE=1 in the session environment to allow deliberately.
Malformed transport, a missing git, and an unreadable upstream URL fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  PAYLOAD_CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // .workspace_root // .workspaceRoot // empty)' 2>/dev/null) || PAYLOAD_CWD=""
fi

[ -n "$CMD" ] || exit 0

# Transport-only prefilter, a strict superset of what the classifier can deny.
# Every deniable command contains `push` (a git push) or `api`, or one of the
# forge nouns this guard classifies. Anything else cannot reach a deny below, so
# skipping it here costs a git call rather than changing a verdict.
case "$CMD" in
  *push*|*api*|*pr\ *|*issue*|*release*|*repo*) ;;
  *) exit 0 ;;
esac

# The single deliberate escape hatch. It is an environment variable rather than
# a flag or a state file so it must be set when the session is launched, which
# makes a genuinely intended upstream contribution possible and an accidental
# one impossible: no in-session tool call can set it for the call that follows.
[ "${FM_ALLOW_UPSTREAM_WRITE:-}" != "1" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0

# Resolve the repository whose upstream remote is protected: the working
# directory the command will run in, falling back to this script's own clone.
# Every step that cannot be confirmed falls through rather than blocking.
# FM_UPSTREAM_GUARD_REPO, when set, is the whole answer: an override that
# silently fell through to somewhere else would judge a repository its caller
# never named.
REPO_DIR=""
if [ -n "${FM_UPSTREAM_GUARD_REPO:-}" ]; then
  CANDIDATES=("$FM_UPSTREAM_GUARD_REPO")
else
  CANDIDATES=("$PAYLOAD_CWD" "$PWD" "$SCRIPT_DIR")
fi
for candidate in "${CANDIDATES[@]}"; do
  [ -n "$candidate" ] || continue
  [ -d "$candidate" ] || continue
  if git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1; then
    REPO_DIR=$candidate
    break
  fi
done
[ -n "$REPO_DIR" ] || exit 0

# An `upstream` remote must actually exist. Its absence is the common case for
# a clone that is not a fork, and it means there is nothing for this guard to
# protect, so it goes completely inert.
git -C "$REPO_DIR" remote get-url upstream >/dev/null 2>&1 || exit 0

# Derive owner/repo from every URL the upstream remote carries, fetch and push
# alike. A URL this parser cannot read - a disabled push URL is written as a
# non-URL placeholder, for instance - contributes nothing instead of failing the
# guard, so one unreadable URL never disarms the readable one beside it.
url_to_slug() {  # <url> -> owner/repo on stdout, empty when unparseable
  local url=$1 path
  case "$url" in
    *://*) path=${url#*://} ; path=${path#*@} ; path=${path#*/} ;;
    *:*/*) path=${url#*:} ; path=${path#*//} ;;
    */*) path=$url ;;
    *) return 0 ;;
  esac
  path=${path%.git}
  path=${path%/}
  # Keep exactly the last two segments: owner/repo.
  local repo=${path##*/}
  local rest=${path%/*}
  local owner=${rest##*/}
  [ -n "$owner" ] && [ -n "$repo" ] || return 0
  case "$owner$repo" in
    *[!A-Za-z0-9._-]*) return 0 ;;
  esac
  printf '%s/%s\n' "$owner" "$repo"
}

PROTECTED_SLUGS=""
while IFS= read -r remote_url; do
  [ -n "$remote_url" ] || continue
  slug=$(url_to_slug "$remote_url")
  [ -n "$slug" ] || continue
  case " $PROTECTED_SLUGS " in
    *" $slug "*) ;;
    *) PROTECTED_SLUGS="$PROTECTED_SLUGS $slug" ;;
  esac
done <<EOF
$(git -C "$REPO_DIR" remote get-url --all upstream 2>/dev/null
  git -C "$REPO_DIR" remote get-url --push --all upstream 2>/dev/null)
EOF

PROTECTED_OWNERS=""
for slug in $PROTECTED_SLUGS; do
  owner=${slug%%/*}
  case " $PROTECTED_OWNERS " in
    *" $owner "*) ;;
    *) PROTECTED_OWNERS="$PROTECTED_OWNERS $owner" ;;
  esac
done

# The fork to name instead, used only to make the refusal actionable. An absent
# or unreadable origin degrades the remedy sentence, never the verdict.
ORIGIN_SLUG=""
origin_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null) || origin_url=""
[ -z "$origin_url" ] || ORIGIN_SLUG=$(url_to_slug "$origin_url")

DENY_REASON=""

# Strip one layer of surrounding quotes from a shell token. Deliberate deeper
# obfuscation is out of scope: the threat model here is an agent mistake, not an
# adversary, and the guard errs toward allowing rather than guessing.
unquote() {  # <token>
  local t=$1
  case "$t" in
    \"*\") t=${t#\"} ; t=${t%\"} ;;
    \'*\') t=${t#\'} ; t=${t%\'} ;;
  esac
  printf '%s' "$t"
}

# Does this token select a protected repository? Reports the match kind on
# stdout: "slug" for the upstream repository itself, "owner" for another
# repository in the same owner's namespace.
token_targets_protected() {  # <token>
  local tok slug owner
  tok=$(unquote "$1")
  for slug in $PROTECTED_SLUGS; do
    case "$tok" in
      "$slug"|"$slug".git) printf 'slug'; return 0 ;;
      *[:/]"$slug"|*[:/]"$slug".git|*[:/]"$slug"/*) printf 'slug'; return 0 ;;
      "$slug"/*) printf 'slug'; return 0 ;;
    esac
  done
  for owner in $PROTECTED_OWNERS; do
    case "$tok" in
      "$owner"/*) printf 'owner'; return 0 ;;
      *[:/]"$owner"/*) printf 'owner'; return 0 ;;
    esac
  done
  return 0
}

# Wrapper words that may stand in front of the real program without changing
# which program runs.
COMMAND_POSITION_WRAPPERS='sudo env command exec time nohup nice stdbuf'

# Does this segment RUN the named program - is that program in command
# position, rather than appearing somewhere in the segment's arguments?
#
# This is what keeps the classification below off `echo git push upstream`,
# off prose that mentions a command, and off a `release create` belonging to
# some unrelated tool. The cost is the converse: a documentation line that
# itself BEGINS `git push upstream ...`, inside a heredoc in the same tool
# call, is indistinguishable from the real command at this level and is
# refused. That is the deliberate direction for a guard whose threat model is
# an agent mistake; FM_ALLOW_UPSTREAM_WRITE=1 covers the deliberate case.
segment_invokes() {  # <program> <token>...
  local want=$1 tok
  shift
  while [ "$#" -gt 0 ]; do
    tok=$(unquote "$1")
    shift
    case "$tok" in
      # A leading VAR=value assignment is a prefix, not the program.
      [A-Za-z_]*=*) continue ;;
    esac
    case " $COMMAND_POSITION_WRAPPERS " in
      *" ${tok##*/} "*) continue ;;
    esac
    [ "${tok##*/}" = "$want" ] && return 0
    return 1
  done
  return 1
}

# Classify one simple command, already split into positional parameters.
classify_segment() {  # <token>...
  local -a toks=("$@")
  local n=${#toks[@]}
  local i j tok next kind
  local has_write_verb=0 write_label="" has_selector=0
  local pair noun verb

  [ "$n" -gt 0 ] || return 0

  # A git push: the remote or URL is the first non-flag token after `push`.
  segment_invokes git "${toks[@]}" || n=0
  for ((i = 0; i < n; i++)); do
    [ "$(unquote "${toks[i]}")" = "push" ] || continue
    for ((j = i + 1; j < n; j++)); do
      tok=$(unquote "${toks[j]}")
      case "$tok" in
        -*) continue ;;
      esac
      if [ "$tok" = "upstream" ]; then
        DENY_REASON="this pushes to the remote named 'upstream', which is the repository this clone was forked from. Our work goes to origin (our own fork) only; upstream is fetch-only here."
        return 1
      fi
      kind=$(token_targets_protected "$tok")
      if [ -n "$kind" ]; then
        DENY_REASON="this pushes to the repository this clone was forked from (${PROTECTED_SLUGS# }). Push to origin (our own fork) instead."
        return 1
      fi
      break
    done
  done

  # A forge write subcommand: a "<noun> <verb>" pair from the owner list above,
  # or `gh api` with a writing method. Only a real forge CLI invocation is
  # classified; the same word pair in any other program is not this guard's.
  n=${#toks[@]}
  segment_invokes gh "${toks[@]}" || segment_invokes gh-axi "${toks[@]}" || return 0
  for ((i = 0; i + 1 < n; i++)); do
    noun=$(unquote "${toks[i]}")
    verb=$(unquote "${toks[i + 1]}")
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      if [ "$pair" = "$noun $verb" ]; then
        has_write_verb=1
        write_label="$noun $verb"
        break
      fi
    done <<EOF
$FORGE_WRITE_PAIRS
EOF
    [ "$has_write_verb" -eq 0 ] || break
  done

  if [ "$has_write_verb" -eq 0 ]; then
    for ((i = 0; i < n; i++)); do
      [ "$(unquote "${toks[i]}")" = "api" ] || continue
      for ((j = i + 1; j < n; j++)); do
        tok=$(unquote "${toks[j]}")
        case "$tok" in
          -X|--method)
            [ $((j + 1)) -lt "$n" ] || break
            next=$(unquote "${toks[j + 1]}")
            for method in $API_WRITE_METHODS; do
              if [ "$next" = "$method" ]; then
                has_write_verb=1
                write_label="api -X $next"
                break
              fi
            done
            ;;
          -X*|--method=*)
            next=${tok#-X}
            next=${next#--method=}
            for method in $API_WRITE_METHODS; do
              if [ "$next" = "$method" ]; then
                has_write_verb=1
                write_label="api -X $next"
                break
              fi
            done
            ;;
        esac
        [ "$has_write_verb" -eq 0 ] || break
      done
      [ "$has_write_verb" -eq 0 ] || break
    done
  fi

  [ "$has_write_verb" -eq 1 ] || return 0

  # A help invocation carries the write verb but performs no write. Refusing
  # `gh pr create --help` would deny the caller the very flag the refusal below
  # tells them to add.
  for ((i = 0; i < n; i++)); do
    case "$(unquote "${toks[i]}")" in
      --help|-h) return 0 ;;
    esac
  done

  # The write names a protected repository only in a repository-selector
  # position: after --repo/-R, or as an api path segment. Matching the slug
  # anywhere in the command would refuse a pull request body that merely
  # mentions upstream, which is legitimate and common.
  for ((i = 0; i < n; i++)); do
    tok=$(unquote "${toks[i]}")
    next=""
    case "$tok" in
      --repo|-R)
        [ $((i + 1)) -lt "$n" ] || continue
        next=${toks[i + 1]}
        ;;
      --repo=*) next=${tok#--repo=} ;;
      -R=*) next=${tok#-R=} ;;
      repos/*|/repos/*|*/repos/*) next=$tok ;;
      *) continue ;;
    esac
    [ -n "$next" ] || continue
    has_selector=1
    kind=$(token_targets_protected "$next")
    case "$kind" in
      slug)
        DENY_REASON="this names the repository this clone was forked from (${PROTECTED_SLUGS# }) on a WRITE command ($write_label). We send that project nothing: run it against our own fork instead. If it genuinely belongs upstream, that is the captain's call - ask, do not route around this."
        return 1
        ;;
      owner)
        DENY_REASON="this names a repository owned by the same account this clone was forked from (upstream is ${PROTECTED_SLUGS# }) on a WRITE command ($write_label). Run it against our own fork instead, or ask the captain if it genuinely belongs there."
        return 1
        ;;
    esac
  done

  # A forge write that names no repository at all is the route the incident
  # actually took. In a clone that HAS an upstream remote, the forge CLI
  # resolves a bare write against the parent repository, so the command reads
  # as local while landing upstream. Refuse it and require the repository be
  # named, which is also the standing instruction to every worker.
  if [ "$has_selector" -eq 0 ]; then
    if [ -n "$ORIGIN_SLUG" ]; then
      DENY_REASON="this WRITE command ($write_label) names no repository, and this clone has an upstream remote (${PROTECTED_SLUGS# }): the forge CLI resolves a bare write against that parent repository, which is exactly how work has landed there by accident before. Name the repository explicitly: add --repo $ORIGIN_SLUG."
    else
      DENY_REASON="this WRITE command ($write_label) names no repository, and this clone has an upstream remote (${PROTECTED_SLUGS# }): the forge CLI resolves a bare write against that parent repository. Name our own fork explicitly with --repo."
    fi
    return 1
  fi

  return 0
}

# Evaluate each simple command separately, so a read of upstream chained to a
# write of our own fork is not read as a write to upstream.
NORMALIZED=$(printf '%s' "$CMD" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|&]/\n/g')

DENIED=0
while IFS= read -r segment; do
  [ -n "$segment" ] || continue
  # Whitespace word splitting with globbing disabled: quotes stay attached to
  # their token and are stripped per token above. This script never executes,
  # sources, evaluates, or expands the command.
  set -f
  # shellcheck disable=SC2086
  set -- $segment
  set +f
  if ! classify_segment "$@"; then
    DENIED=1
    break
  fi
done <<EOF
$NORMALIZED
EOF

[ "$DENIED" -eq 1 ] || exit 0
[ -n "$DENY_REASON" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[upstream-guard] $DENY_REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
