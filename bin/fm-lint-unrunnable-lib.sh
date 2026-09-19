# shellcheck shell=bash
# Shared "the lint could not run" outcome for firstmate's lint owners.
# Usage: . bin/fm-lint-unrunnable-lib.sh; fm_lint_unrunnable "<reason>" "<install command>"
#
# ONE OWNER for the difference between "I found problems" and "I could not run".
# bin/fm-lint.sh (ShellCheck) and bin/fm-lint-workflows.sh (actionlint) both
# refuse to analyse anything when their pinned linter is absent from PATH or
# resolves off its pin. Reported as an ordinary failure, that refusal is
# indistinguishable at a gate from a real finding: the gate shows an issues
# count for a run that analysed no file, and a genuine finding sitting behind
# the same status cannot be told apart from missing tooling.
#
# Two things carry the distinction out of the script, because a gate that pins
# a lint command controls only these two:
#   - Exit status FM_LINT_UNRUNNABLE (69, sysexits EX_UNAVAILABLE), never 1
#     (findings) and never 2 (usage or internal failure).
#   - A fixed three-line message naming the missing tool, its pin, and the exact
#     install command, on stderr where every other diagnostic of these owners
#     goes, leaving stdout as the findings and data stream.
#
# Findings outrank unrunnability. A caller that already has real findings keeps
# reporting them, so this status never hides a problem that was actually found.

FM_LINT_UNRUNNABLE=69

# fm_lint_unrunnable <reason> <install-command>: report and exit with
# FM_LINT_UNRUNNABLE. <reason> names the tool and its pin; <install-command> is
# the exact command from the installer script that owns that pin.
fm_lint_unrunnable() {
  local reason=$1 install=$2 caller
  caller=${BASH_SOURCE[1]:-fm-lint.sh}
  caller=${caller##*/}
  printf '%s: LINT NOT RUN (exit %s): %s\n%s: no file was analysed; this is missing lint tooling, not a lint finding.\n%s: install it with: %s\n' \
    "$caller" "$FM_LINT_UNRUNNABLE" "$reason" "$caller" "$caller" "$install" >&2
  exit "$FM_LINT_UNRUNNABLE"
}
