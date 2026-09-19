#!/usr/bin/env python3
"""Derive the GitHub-reading bearings board from the shipped template.

The board has ONE definition. This script never authors board content: it
takes the shipped template verbatim, drops the payload into the template's own
data slot, and replaces the template's render script with the GitHub transport
carrying that same render script embedded inside it. Everything the captain
sees therefore comes from the template, including anything added to it after
this file was last touched.

bin/fm-board-github.sh owns the contract and calls this; it is not run alone.
"""
import json
import os
import re
import sys


def escape_for_script_block(text):
    """`<` cannot survive raw inside a <script> block: a payload string holding
    "</script>" would end the block early. Every `<` becomes the \\u003c string
    escape, which JSON and JavaScript both read back as the same character."""
    return text.replace("<", "\\u003c")


def main():
    template_path = sys.argv[1]
    data_path = os.environ["PAGE_DATA"]
    transport_path = os.environ["PAGE_TRANSPORT"]
    board_script = os.environ["PAGE_SCRIPT"]
    data_slot = os.environ["PAGE_SLOT_DATA"]
    script_slot = os.environ["PAGE_SLOT_SCRIPT"]

    template = open(template_path, encoding="utf-8").read()
    transport = open(transport_path, encoding="utf-8").read()
    payload = json.dumps(json.load(open(data_path, encoding="utf-8")),
                         ensure_ascii=False, separators=(",", ":"))

    quoted = '"%s"' % script_slot
    if quoted not in transport:
        sys.stderr.write("error: the transport has no %s string slot\n" % script_slot)
        return 1
    transport = transport.replace(
        quoted, escape_for_script_block(json.dumps(board_script, ensure_ascii=False)), 1)

    if template.count(data_slot) != 1:
        sys.stderr.write("error: the template does not carry exactly one data slot\n")
        return 1
    page = template.replace(data_slot, escape_for_script_block(payload), 1)

    # The render script is the template's last attribute-free <script> block;
    # the transport takes its place and runs it from inside.
    blocks = list(re.finditer(r"<script>\n(.*?)\n</script>", page, re.S))
    if not blocks:
        sys.stderr.write("error: the template has no bare <script> render block\n")
        return 1
    last = blocks[-1]
    page = page[:last.start()] + "<script>\n" + transport + "\n</script>" + page[last.end():]

    sys.stdout.write(page)
    return 0


if __name__ == "__main__":
    sys.exit(main())
