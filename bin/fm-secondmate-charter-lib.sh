#!/usr/bin/env bash
# Shared extraction of secondmate registry summary and scope from a charter.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.
#
# The section read comes from bin/fm-dod-lib.sh, the one owner of brief-heading
# parsing, rather than from a local awk. A charter carries the captain's own words
# spliced under `# Charter` by bin/fm-brief.sh, so a charter quoting a fenced block
# whose content starts with `# ` truncated there - and the truncated text is what
# the seeds write into data/secondmates.md, the table work is routed by.
FM_SECONDMATE_CHARTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-dod-lib.sh
. "$FM_SECONDMATE_CHARTER_LIB_DIR/fm-dod-lib.sh"

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  fm_brief_heading_body "$brief" "# $heading"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}
