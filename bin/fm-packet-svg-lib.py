# The one reader of a drawing's markup, loaded by BOTH python programs in
# bin/fm-packet.sh rather than written twice. Two readers of one packet is the
# failure this branch has already paid for twice - a non-greedy closing-svg
# match, and a second data-node regex - and a comment saying two copies must
# stay identical is not a thing that keeps them identical. This file is.
import html
import re

# Which bytes are a tag, and which are an attribute inside it, WALKED the way
# the HTML tokenizer walks them rather than matched as a shape. Four times on
# this branch a drawing slipped past a pattern the browser read differently -
# an attribute after a solidus, one with no separator at all, a duplicate name,
# and a bare "<" inside an unquoted value, which ends a regex and does not end
# a value. A shape can always be spelled around; the state walk is what the
# browser will actually do. Anything this cannot read comes back as None, and
# the caller refuses the drawing rather than passing bytes nobody understood.
#
# The states are the spec ones: before-attribute-name, attribute-name,
# after-attribute-name, before-attribute-value, the three attribute-value
# states and after-attribute-value-quoted. A duplicate name keeps the FIRST,
# as the tokenizer does. EOF anywhere inside a tag is eof-in-tag: unreadable.
WHITESPACE = "\t\n\f\r "

def scan_tags(svg):
    """-> [(tag name, {attr: value})] in document order, or None if unreadable"""
    out, i, n = [], 0, len(svg)
    while i < n:
        lt = svg.find("<", i)
        if lt < 0:
            return out
        i = lt + 1
        if svg.startswith("!--", i):
            end = svg.find("-->", i + 3)
            if end < 0:
                return None
            i = end + 3; continue
        if svg.startswith("![CDATA[", i):
            end = svg.find("]]>", i + 8)
            if end < 0:
                return None
            i = end + 3; continue
        if i < n and svg[i] in "!?":
            end = svg.find(">", i)
            if end < 0:
                return None
            i = end + 1; continue
        closing = i < n and svg[i] == "/"
        if closing:
            i += 1
        if i >= n or not svg[i].isalpha():
            # a "<" the tokenizer keeps as text, not the start of a tag
            continue
        start = i
        while i < n and svg[i] not in WHITESPACE and svg[i] not in "/>":
            i += 1
        name = svg[start:i].lower()
        attrs, done = {}, False
        while not done:
            while i < n and (svg[i] in WHITESPACE or svg[i] == "/"):
                i += 1
            if i >= n:
                return None
            if svg[i] == ">":
                i += 1; done = True; break
            astart = i
            while i < n and svg[i] not in WHITESPACE and svg[i] not in "/>=":
                i += 1
            attr = svg[astart:i].lower()
            while i < n and svg[i] in WHITESPACE:
                i += 1
            if i >= n:
                return None
            value = ""
            if svg[i] == "=":
                i += 1
                while i < n and svg[i] in WHITESPACE:
                    i += 1
                if i >= n:
                    return None
                if svg[i] in "\"'":
                    quote = svg[i]; i += 1
                    close = svg.find(quote, i)
                    if close < 0:
                        return None
                    value = html.unescape(svg[i:close]); i = close + 1
                else:
                    vstart = i
                    while i < n and svg[i] not in WHITESPACE and svg[i] != ">":
                        i += 1
                    value = html.unescape(svg[vstart:i])
            if attr:
                attrs.setdefault(attr, value)
        if not closing:
            out.append((name, attrs))
    return out

# The one top-level <svg>, counted by depth: diagram-design nests icon <svg>
# elements inside the drawing, and a non-greedy match would stop at the first
# </svg> and leave the rest of the figure unread. figures_html states this
# same function, character for character - the two must agree on which bytes
# are the drawing, or verify checks one thing and the page shows another.
SVG_TAG = re.compile(r"""<\s*(/?)svg\b((?:[^<>"']|"[^"]*"|'[^']*')*)>""", re.S)

def top_level_svgs(text):
    out, depth, start = [], 0, None
    for m in SVG_TAG.finditer(text):
        if m.group(1):
            if depth > 0:
                depth -= 1
                if depth == 0:
                    out.append(text[start:m.end()]); start = None
        elif m.group(2).rstrip().endswith("/"):
            if depth == 0:
                out.append(m.group(0))
        else:
            if depth == 0:
                start = m.start()
            depth += 1
    return out

