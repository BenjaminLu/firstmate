#!/usr/bin/env bash
# fm-claude-launch-lib.sh - the shared resolver for how a Claude worker launches:
# the permission posture the launch carries, and the directories the worker may
# read outside its own worktree.
#
# Sourced, never executed. Two consumers share one resolution so they cannot
# disagree: bin/fm-spawn.sh turns both results into launch flags, and
# bin/fm-session-start.sh prints the posture in its digest, so a session can
# never be wrong about which posture its own workers run in.
#
# The operator-facing posture contract - accepted tokens, the shipped default,
# what a bad value does - is owned by bin/fm-spawn.sh's header and
# docs/configuration.md "Claude permission mode". This file owns the resolution
# and the directory derivation only.
#
# DIRECTORY GRANT (fm_claude_grant_resolve).
# A worker legitimately reads four directories outside its own worktree because
# its own brief sends it to each of them. Each one is derived per launch from
# the running system, so nothing machine-specific is ever committed and no
# operator has to discover and hand-write them into a settings file:
#
#   1. the active Firstmate home, which carries the brief, the steering inbox,
#      the status file, and the packet - the caller's resolved FM_HOME
#   2. the Claude scratch root for this user - /tmp/claude-<uid>, plus its
#      resolved spelling when /tmp is a symlink. macOS resolves /tmp to
#      /private/tmp and reports the RESOLVED path to the agent, so a grant
#      written only one way can miss the path the worker is actually handed;
#      both spellings are emitted when they differ (verified: this host's
#      scratchpad is /private/tmp/claude-501/... while /tmp/claude-501 is the
#      same directory)
#   3. the validation tool's data root, read from `no-mistakes doctor`'s own
#      "data directory" line rather than assumed to be ~/.no-mistakes
#   4. the user skills directory, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills,
#      where the skills a brief names live
#
# EXISTENCE IS NOT A FILTER. A machine configured with nothing has not created
# its scratch root or its skills directory yet, and those are exactly the grants
# it will need; filtering on existence would drop them precisely on the fresh
# clone this derivation exists for.
#
# THE GRANT RIDES `claude --add-dir`, NOT THE INLINE SETTINGS. The obvious place
# for it is a permissions.additionalDirectories key in the --settings object the
# launch already carries, and that was tried first. It was refused: --settings is
# a high-precedence settings source, and whether Claude Code unions or REPLACES
# a `permissions` key from lower scopes could not be measured here (the attempts
# and why each failed are in docs/verification/runtime-backends.md). If it
# replaces, the operator's own permissions.allow rules stop reaching workers,
# which is the prompt storm this derivation exists to prevent. --add-dir carries
# the same directories and writes no settings key at all, so the question stops
# needing an answer rather than being accepted as a risk.
#
# WHAT CANNOT BE DERIVED IS NAMED, NEVER DROPPED SILENTLY. A directory whose
# SOURCE does not resolve - no-mistakes absent or its doctor line unreadable,
# neither CLAUDE_CONFIG_DIR nor HOME set, a path carrying a newline that this
# line-separated list cannot represent - is left out of the grant AND listed in
# FM_CLAUDE_DIRS_UNRESOLVED, so the caller reports what the worker did not get
# instead of launching a short list quietly.
set -u

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# The posture an unconfigured home launches with. This is the posture the fleet
# actually runs; `bypass` is the deliberate opt-in, not what a clone inherits.
FM_CLAUDE_PERMISSION_DEFAULT=auto
FM_CLAUDE_PERMISSION_FILE=claude-permission-mode
# Bound on the validation tool's doctor call, in seconds: it contacts its own
# daemon, and a worker launch must not hang behind an unhealthy one. A constant
# rather than an override, because the requirement is that the call IS bounded,
# not that the bound is settable; nothing in this repo needs a different one.
FM_CLAUDE_DOCTOR_TIMEOUT=10

# fm_claude_permission_resolve <config-dir>
# Sets FM_CLAUDE_PERMISSION_SOURCE to `default`, `config` or `unresolved`, and
# with it FM_CLAUDE_PERMISSION_MODE and FM_CLAUDE_PERMISSION_FLAG. Returns 1 on
# `unresolved`, with the operator-facing reason in FM_CLAUDE_PERMISSION_ERROR -
# empty only when the inspection itself failed and has already printed its own
# diagnostic.
#
# SOURCE is what every reader keys on, and that is the point rather than a
# detail. The mode and the flag are cleared on every failure path, so a reader
# that keyed on "is the error string populated" instead would read a cleared
# mode back as the shipped default and state it confidently. A posture this
# cannot resolve is its own answer, never the default one.
fm_claude_permission_resolve() {
  local config=$1 present token path
  path="$config/$FM_CLAUDE_PERMISSION_FILE"
  # Every FM_CLAUDE_* name this file assigns is an OUTPUT GLOBAL, read by the
  # scripts that source it rather than here. Whether ShellCheck happens to see a
  # read inside this file depends on how the helpers are arranged today, and a
  # rearrangement that removed one broke CI once; marking them all keeps that
  # from being rediscovered one name at a time.
  # shellcheck disable=SC2034
  FM_CLAUDE_PERMISSION_MODE=$FM_CLAUDE_PERMISSION_DEFAULT
  # shellcheck disable=SC2034
  FM_CLAUDE_PERMISSION_SOURCE=default
  # shellcheck disable=SC2034
  FM_CLAUDE_PERMISSION_FLAG=
  # shellcheck disable=SC2034
  FM_CLAUDE_PERMISSION_ERROR=
  if ! present=$(fm_config_source_present "$path"); then
    FM_CLAUDE_PERMISSION_MODE=
    FM_CLAUDE_PERMISSION_SOURCE=unresolved
    return 1
  fi
  if [ "$present" = 1 ]; then
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      FM_CLAUDE_PERMISSION_MODE=
      FM_CLAUDE_PERMISSION_SOURCE=unresolved
      FM_CLAUDE_PERMISSION_ERROR="config/$FM_CLAUDE_PERMISSION_FILE must be a readable regular file holding one of: auto, bypass"
      return 1
    fi
    token=$(tr -d '[:space:]' <"$path" || true)
    case $token in
    auto | bypass)
      FM_CLAUDE_PERMISSION_MODE=$token
      FM_CLAUDE_PERMISSION_SOURCE=config
      ;;
    *)
      FM_CLAUDE_PERMISSION_MODE=
      FM_CLAUDE_PERMISSION_SOURCE=unresolved
      FM_CLAUDE_PERMISSION_ERROR="config/$FM_CLAUDE_PERMISSION_FILE holds '$token'; accepted values are: auto (--permission-mode auto, and the default when the file is absent), bypass (--dangerously-skip-permissions)"
      return 1
      ;;
    esac
  fi
  case $FM_CLAUDE_PERMISSION_MODE in
  bypass) FM_CLAUDE_PERMISSION_FLAG='--dangerously-skip-permissions' ;;
  *) FM_CLAUDE_PERMISSION_FLAG='--permission-mode auto' ;;
  esac
  return 0
}

# fm_claude_permission_describe
# One line naming the posture in force and what selected it, for a reader who
# has run fm_claude_permission_resolve. Silence is what let an inverted default
# stand unnoticed, so this line is printed whether or not anything is wrong -
# and an unresolved posture gets its own line rather than being described as
# the default, because a section that exists to end a silence must not replace
# it with a confident sentence that is false.
#
# The unresolved branch is FIRST and is reached through SOURCE, never through
# an empty-or-not test on the error string. One of the two unresolved paths
# carries no reason of its own, and a presence test would send exactly that
# path into the default branch.
fm_claude_permission_describe() {
  case ${FM_CLAUDE_PERMISSION_SOURCE:-unresolved} in
  unresolved)
    printf 'UNRESOLVED - %s. Every Claude spawn from this home refuses until that is fixed.\n' \
      "${FM_CLAUDE_PERMISSION_ERROR:-config/$FM_CLAUDE_PERMISSION_FILE could not be inspected, so the posture this home would launch with is unknown}"
    return 0
    ;;
  config)
    printf 'Claude workers launch %s (%s), selected by config/%s.\n' \
      "$FM_CLAUDE_PERMISSION_FLAG" "$FM_CLAUDE_PERMISSION_MODE" "$FM_CLAUDE_PERMISSION_FILE"
    ;;
  *)
    printf 'Claude workers launch %s (%s), the shipped default: this home has no config/%s.\n' \
      "$FM_CLAUDE_PERMISSION_FLAG" "$FM_CLAUDE_PERMISSION_MODE" "$FM_CLAUDE_PERMISSION_FILE"
    ;;
  esac
  if [ "${FM_CLAUDE_PERMISSION_MODE:-}" = bypass ]; then
    printf 'Every permission check is skipped in that posture; auto is the safer one.\n'
  fi
}

# fm_claude_no_mistakes_data_root
# The validation tool's data root as the tool itself reports it. Prints nothing
# and returns 1 when the tool is absent, the call does not finish inside its
# bound, or the line does not carry an absolute path - a root this cannot read
# is reported unresolved, never guessed.
fm_claude_no_mistakes_data_root() {
  local out root esc
  command -v no-mistakes >/dev/null 2>&1 || return 1
  out=$(fm_run_timed "$FM_CLAUDE_DOCTOR_TIMEOUT" no-mistakes doctor 2>/dev/null) || {
    [ -n "$out" ] || return 1
  }
  esc=$(printf '\033')
  root=$(printf '%s\n' "$out" |
    sed -e "s/${esc}\[[0-9;]*[A-Za-z]//g" |
    sed -n 's/^.*data directory[[:space:]][[:space:]]*//p' |
    head -n 1)
  root=${root%"${root##*[![:space:]]}"}
  case $root in
  /*) printf '%s\n' "$root" ;;
  *) return 1 ;;
  esac
}

# fm_claude_grant_resolve <fm-home>
# Sets FM_CLAUDE_DIRS (one absolute directory per line, declaration order,
# deduplicated) and FM_CLAUDE_DIRS_UNRESOLVED. The caller turns the first into
# the launch's --add-dir arguments, quoting each for the shell itself.
#
# It SETS rather than prints, and that is load bearing: a caller that read the
# grant through command substitution would fork away the unresolved list, and
# the unresolved list is the half that has to be reported. Printing the grant
# and reporting what is missing must not be separable.
fm_claude_grant_resolve() {
  local home=${1:-} uid tmp_root data_root config_dir
  # Output globals; see the note in fm_claude_permission_resolve above.
  # shellcheck disable=SC2034
  FM_CLAUDE_DIRS=
  # shellcheck disable=SC2034
  FM_CLAUDE_DIRS_UNRESOLVED=

  if [ -n "$home" ]; then
    fm_claude_grant__add "$home"
  else
    fm_claude_grant__miss "firstmate-home(no resolved FM_HOME)"
  fi

  uid=$(id -u 2>/dev/null || true)
  if [ -n "$uid" ]; then
    fm_claude_grant__add "/tmp/claude-$uid"
    tmp_root=$(cd /tmp 2>/dev/null && pwd -P) || tmp_root=
    if [ -n "$tmp_root" ] && [ "$tmp_root" != /tmp ]; then
      fm_claude_grant__add "$tmp_root/claude-$uid"
    fi
  else
    fm_claude_grant__miss "claude-scratch-root(no user id)"
  fi

  if data_root=$(fm_claude_no_mistakes_data_root); then
    fm_claude_grant__add "$data_root"
  else
    fm_claude_grant__miss 'no-mistakes-data-root(no absolute "data directory" line from no-mistakes doctor)'
  fi

  config_dir=${CLAUDE_CONFIG_DIR:-}
  if [ -z "$config_dir" ] && [ -n "${HOME:-}" ]; then
    config_dir="$HOME/.claude"
  fi
  if [ -n "$config_dir" ]; then
    fm_claude_grant__add "$config_dir/skills"
  else
    fm_claude_grant__miss "user-skills-dir(neither CLAUDE_CONFIG_DIR nor HOME is set)"
  fi

  # shellcheck disable=SC2034
  FM_CLAUDE_DIRS=${FM_CLAUDE_DIRS%$'\n'}
  # shellcheck disable=SC2034
  FM_CLAUDE_DIRS_UNRESOLVED=${FM_CLAUDE_DIRS_UNRESOLVED# }
}

# fm_claude_grant__add <directory>
# Append one directory to the grant, unless it is already there or cannot be
# represented. FM_CLAUDE_DIRS is newline separated, so a path CONTAINING a
# newline would silently become two directories the launch then grants; it is
# refused by name instead. Every other character survives, because the caller
# shell-quotes each path onto the launch command rather than embedding it in a
# quoted JSON string.
fm_claude_grant__add() {
  local dir=$1 existing
  case $dir in
  *$'\n'*)
    fm_claude_grant__miss "$(printf '%s' "$dir" | tr '\n' ' ')(path contains a newline)"
    return 0
    ;;
  esac
  while IFS= read -r existing; do
    [ "$existing" = "$dir" ] && return 0
  done <<EOF
$FM_CLAUDE_DIRS
EOF
  FM_CLAUDE_DIRS="$FM_CLAUDE_DIRS$dir"$'\n'
}

# fm_claude_grant__miss <source(why)>
# Record one directory the grant does not carry, so the caller can say which.
fm_claude_grant__miss() {
  FM_CLAUDE_DIRS_UNRESOLVED="$FM_CLAUDE_DIRS_UNRESOLVED $1"
}
