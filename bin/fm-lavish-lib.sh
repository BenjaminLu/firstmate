#!/usr/bin/env bash
# Lavish capability probes shared by the board builder and bootstrap.
#
# WHY THIS IS A CAPABILITY PROBE AND NOT A VERSION FLOOR. The captain's standing
# rule is one captain-facing URL, and the board only has a stable `/s/<slug>`
# address because lavish-axi accepts `--name`. That flag is NOT in the published
# package: lavish-axi 0.1.73 (latest on npm at the time of writing) was fetched
# with `npm pack lavish-axi@0.1.73` and grepped, and contains zero occurrences of
# `--name` anywhere in dist/, README.md or skills/. It is carried by a fork build
# that reports a LOWER version, 0.1.71.
#
# So version ordering does not predict this capability in either direction, and a
# floor cannot stand in for it: a fresh clone installing the newest published
# release clears any floor below 0.1.73 and still has no stable board URL. The
# feature has to be asked about directly.
#
# fm_lavish_named_session_support is the SINGLE owner of that question, because
# a probe in the board builder and a second one in bootstrap would be two
# predicates that agree only until one of them is edited.

# fm_lavish_named_session_support: does the installed lavish-axi accept --name?
#   0 - yes, help advertises it
#   1 - no, help ran and does not advertise it
#   2 - unverifiable: lavish-axi is absent, or its help did not run or printed
#       nothing, so this returns "could not tell" rather than a false verdict
#
# Reads `--help` rather than the bare session listing on purpose: the board
# probes before its session is established, and a listing is not inert - it is
# the same read the board's liveness proof depends on.
fm_lavish_named_session_support() {
  local help_out
  command -v lavish-axi >/dev/null 2>&1 || return 2
  help_out=$(lavish-axi --help 2>/dev/null) || return 2
  [ -n "$help_out" ] || return 2
  case "$help_out" in
    *'--name <slug>'*) return 0 ;;
  esac
  return 1
}
