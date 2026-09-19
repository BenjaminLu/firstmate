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
#   fm-packet.sh render <task-id>
#   fm-packet.sh serve <task-id>
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
#            session knows", an empty "Evidence" section, a "Figures" section
#            whose drawings break the contract below, or, for
#            kind=needs-decision, a missing or malformed decision block. The
#            decision block is a fenced ```json fm-packet-decision.v1 object:
#              key (the task id), title, decide, if_nothing, reversible
#              (yes|no|partly), optional risk (low|medium|high), options[]
#              (each value + label + consequence, at least two),
#              recommend_value (one of the option values), optional
#              recommend_why, optional close (done|release).
#            Copy fields are a plain string or an {en, hant?, hans?} object.
#            Prints `packet: ok <path>` on success; each problem goes to
#            stderr and the exit is 1. Checking a "Figures" section needs
#            python3; a packet with no such section never calls it.
#
# The "Figures" section. A decision the captain cannot picture is a title and
# three labels. The figures are the drawings that show what the options
# actually differ in, and they live in the packet beside the decision so one
# page carries both. The section is optional for kind=done - a done packet is
# never refused for having none - and required for kind=needs-decision, which
# must also carry one drawing that puts every option together (below). Each
# figure is:
#
#   ### <heading>
#   figure: <slug>                 # lowercase id prefix for every id in the svg
#   caption: <one sentence - what to look at, and what the drawing proves>
#
#   <svg ...> ... </svg>
#
#   - edge <data-edge id>: <what proves this connector>
#
# The drawing is produced through the diagram-design skill, never hand-written
# SVG. There is no line a worker can write to be excused the figures: an
# environment that genuinely cannot draw is a blocker escalated to firstmate,
# who can see whether the drawing was truly impossible. That skill emits a
# standalone HTML file whose SVG carries its own hex palette and a web-font
# link, so the figure is the `<svg>` lifted out of it and EDITED to the
# contract below - a straight paste is refused, by design. The contract is
# baton's, from its references/diagrams.md "The embedding contract" and
# spec.md "The SVG contract" (whose heading says the same thing: what
# diagram-design output must be edited to); it is not a parallel rule set,
# and verify enforces the clauses a script can actually check:
#
#   - every `<text>` carries data-en, data-hant and data-hans, so a language
#     switch re-labels the drawing instead of leaking English onto the
#     Chinese page
#   - no baked-in colour: fill, stroke, color, stop-color and flood-color -
#     as attributes or inside style="" - may only be var(--...), none,
#     currentColor, transparent, inherit or url(#...), so the drawing
#     inherits the page's theme instead of fighting it; a <style> block
#     carrying a hex, rgb() or hsl() literal is refused for the same reason.
#     The rendered page binds the palette a figure draws against: --fg
#     --muted --soft --card --card-2 --bg --rule --rule-strong --accent
#     --accent-tint --amber --seal --ok --link, plus --sans and --mono for
#     font-family. Figures sit on --card, so paper and label masks are
#     fill="var(--card)"
#   - every selectable shape (`<rect>`, `<polygon>`) carries data-node, the
#     latin identity from the source, never the reader's wording
#   - every id inside the svg is prefixed `<slug>-`, and no two figures in one
#     packet share a slug, so two figures inlined on one page cannot collide
#     over a marker id and break each other's arrows
#   - no external font reference, and no <script> or on* handler: the page
#     must render offline inside a sandboxed iframe, and the drawing is
#     static markup. For the same reason every href, xlink:href and src points
#     at a same-document `#fragment`; only an `<a>` may leave the page, and
#     only through http, https or mailto - the schemes the page's prose links
#     already allow, since the svg rides the page unescaped
#   - every connector that draws an arrow (marker-start or marker-end)
#     carries data-edge, and every data-edge has its own evidence line saying
#     what proves that line
#
# verify owns the mechanical half of that contract and only that half. It
# checks absences a script is good at - a missing language attribute, a baked
# colour, an unprefixed id, a connector with no evidence - and it never opens
# the drawing. Whether the picture is legible and correct - a label clipped by
# its box, two boxes overlapping, an arrow pointing at the wrong thing, a
# structure that does not match the code - is checked by eye, in a browser, on
# the rendered page. `packet: ok` means the contract held, never that the
# drawing reads.
#
# For kind=needs-decision, verify additionally requires ONE figure carrying a
# data-node for EVERY option value in the decision block. One drawing per
# option buries the only question the reader has - where the options differ,
# and where they become the same thing - so a drawing that names all but one
# option is refused, naming the one it left out. Nothing labels that figure as
# the comparison: naming every option is what makes it one.
# card       Verify, then print the fm-bearings-board.v1 Captain's Call card
#            composed from the decision block, ready to drop into a board
#            payload. A copy object without `hant` is flattened to its `en`
#            string so the board validator accepts it. --repo names the card's
#            repo; otherwise the task's meta project= basename, else "".
#            When the rendered page's Lavish session is listed open, the card
#            also carries its URL as `packet_url`, so the bearings composer
#            gets the link without a second lookup; a page older than the
#            packet is re-rendered first, so the link never shows a stale
#            packet.
# render     Verify, then write the packet as ONE self-contained HTML page at
#            data/<id>/packet.html: no network, no CDN, no external
#            fonts, sections in packet order, the decision block as a card
#            answering the five questions (decide, per-option consequence, if
#            nothing, reversible, risk) plus the recommendation and why, the
#            markdown sections converted by a small stdlib-only python3
#            converter (headings, lists, fenced code, inline code, bold,
#            links), the "Figures" section's drawings inlined with their
#            captions and per-connector evidence, a copy-the-context button that puts the raw markdown on
#            the clipboard with a selected-text fallback for sandboxed
#            iframes, and an EN / 繁體 / 简体 switch for the page chrome that
#            shares the board's stored choice. Copy objects in the decision
#            block render per language; plain strings render as written. A
#            packet that fails verify is refused. Prints `page: <path>`.
# serve      Render, then open the page with lavish-axi - under the stable
#            session name packet-<task-id> when the installed lavish-axi
#            advertises --name, else keyed - and print `url: <url>` read from
#            the server's listing. A session the captain ended is reopened
#            once, because serve is an explicit ask for their attention.
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
      printf '\n## Figures\n\n'
      # shellcheck disable=SC2016  # markdown code spans in the packet, not shell expansions
      printf '%s\n' 'Drawn through the diagram-design skill, never hand-written SVG; `fm-packet.sh --help` owns the contract verify enforces.'
      printf '%s\n' 'If that skill is not installed where this task runs, that is a blocker to escalate to firstmate, not a line you write here.'
      printf '%s\n\n' 'verify checks the contract, not the picture: render the page and look at the drawing before you report.'
      printf '%s\n' '### {FILL: the heading - what this drawing shows}'
      printf '%s\n' 'figure: {FILL: slug, lowercase, used to prefix every id inside the svg}'
      printf '%s\n\n' 'caption: {FILL: one sentence - what to look at, and what the drawing proves}'
      printf '%s\n\n' '{FILL: the <svg> lifted out of the diagram-design file and edited to the contract - colours only var(--...), data-en/data-hant/data-hans on every <text>, data-node on every shape, and one shape carrying data-node="<option value>" for EVERY option in the decision above}'
      printf '%s\n' '- edge {FILL: the data-edge id}: {FILL: what proves this connector}'
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

# The figures check. The contract it enforces is baton's, stated once in this
# script's header; this function is only the machine half of it. python3 is
# used because an SVG attribute does not fit on one line and a line-oriented
# scanner would pass a broken drawing. It is called only when the packet has a
# Figures section or owes one, so a packet without figures never needs python3.
figures_problems() {  # <packet> <kind> [option-value...] -> one problem per line
  python3 - "$@" <<'PY'
import pathlib, re, sys

packet, kind, options = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
lines = packet.read_text(encoding="utf-8").splitlines()
problems = []

# The headings render decides on, character for character, and the same one
# space the awk section reader and the scaffold already use: a heading two
# readers spell differently is a drawing one of them turns into prose while
# the other passes its svg through unescaped.
def section_heading(line):
    return line[3:].strip() if line.startswith("## ") else None

def figure_heading(line):
    return line[4:].strip() if line.startswith("### ") else None

# Every Figures section, not the first: render routes each one through
# figures_html, so each one's drawings reach the page inlined on verify's word.
body, inside, found = [], False, False
for l in lines:
    h = section_heading(l)
    if h is not None:
        inside = h == "Figures"
        found = found or inside
    elif inside:
        body.append(l)

if not found and kind == "needs-decision":
    problems.append("kind=needs-decision but there is no '## Figures' section; "
                    "draw the options through the diagram-design skill. An environment that "
                    "cannot draw is a blocker to escalate to firstmate, not something to "
                    "declare here")

# ---- split the section into figures at their ### headings -------------------
figures, cur = [], None
for l in body:
    h = figure_heading(l)
    if h is not None:
        cur = {"heading": h, "lines": []}
        figures.append(cur)
    elif cur is not None:
        cur["lines"].append(l)

if found and not figures and kind == "needs-decision":
    problems.append("the Figures section carries no '### ' figure; a needs-decision packet owes "
                    "one drawing that puts every option together")

# ---- per-figure checks ------------------------------------------------------
COLOUR_ATTRS = ("fill", "stroke", "color", "stop-color", "flood-color", "lighting-color")
# The palette the rendered page binds for a figure to draw against; this
# script's header enumerates the same names. A var(--...) outside it resolves
# to nothing and the shape falls back to black on --card, which no clause
# would otherwise catch.
PALETTE = ("fg", "muted", "soft", "card", "card-2", "bg", "rule", "rule-strong",
           "accent", "accent-tint", "amber", "seal", "ok", "link")
COLOUR_OK = re.compile(r"^(?:none|inherit|transparent|currentColor|var\(--(?:%s)\)"
                       r"|url\(#[A-Za-z0-9._:-]+\))$" % "|".join(map(re.escape, PALETTE)))
LITERAL = re.compile(r"#[0-9A-Fa-f]{3,8}\b|\brgba?\(|\bhsla?\(")
ATTR = re.compile(r"""([A-Za-z_:][-\w:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>=`]+))""")
TAG = re.compile(r'''<\s*([A-Za-z][\w:-]*)((?:[^<>"']|"[^"]*"|'[^']*')*)>''', re.S)
EXTERNAL_FONT = re.compile(r"@font-face|@import|fonts\.googleapis\.com|<\s*link\b|url\(\s*['\"]?https?:", re.I)
REF_ATTRS = ("href", "xlink:href", "src")
SCHEME = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*):")
LINK_SCHEMES = ("http", "https", "mailto")

def attrs_of(text):
    out = {}
    for m in ATTR.finditer(text):
        value = next(g for g in m.groups()[1:] if g is not None)
        out[m.group(1).lower()] = value
    return out

def style_decls(value):
    for decl in value.split(";"):
        if ":" in decl:
            k, v = decl.split(":", 1)
            yield k.strip().lower(), v.strip()

figure_nodes, slugs_seen = [], {}
for n, fig in enumerate(figures, 1):
    chunk = "\n".join(fig["lines"])
    name = fig["heading"] or "(no heading)"
    def bad(msg, _name=name, _n=n):
        problems.append("figure %d (%s): %s" % (_n, _name, msg))
    if not fig["heading"]:
        bad("the '###' heading is empty")
    fields = {}
    for l in fig["lines"]:
        m = re.match(r"^(figure|caption):\s*(\S.*?)\s*$", l)
        if m and m.group(1) not in fields:
            fields[m.group(1)] = m.group(2)
    slug = fields.get("figure", "")
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", slug):
        bad("'figure: <slug>' is missing or not lowercase letters, digits and hyphens")
        slug = ""
    elif slug in slugs_seen:
        bad("'figure: %s' is already the slug of figure %d (%s); the prefix only keeps two "
            "drawings off each other's ids while each owns one" % (slug, slugs_seen[slug][0],
                                                                   slugs_seen[slug][1]))
    else:
        slugs_seen[slug] = (n, name)
    if not fields.get("caption"):
        bad("'caption:' is missing or empty")

    svgs = re.findall(r"<svg\b.*?</svg\s*>", chunk, re.S)
    if len(svgs) != 1:
        bad("the figure carries %d inline <svg> block(s); it needs exactly one, "
            "drawn through the diagram-design skill" % len(svgs))
        continue
    svg = svgs[0]

    if re.search(r"<\s*script\b", svg, re.I):
        bad("the svg carries a <script>; a figure is static markup")
    if EXTERNAL_FONT.search(svg):
        bad("the svg references an external font or stylesheet; the page must render offline")
    for block in re.findall(r"<style\b[^>]*>(.*?)</style\s*>", svg, re.S):
        stripped = re.sub(r"url\(\s*#[^)]*\)", "", block)
        if LITERAL.search(stripped):
            bad("a <style> block bakes in a colour literal; colours come from the page's "
                "CSS variables, as var(--...)")

    nodes, edges_drawn, edges_declared = set(), set(), set()
    for m in TAG.finditer(svg):
        tag, at = m.group(1).lower(), attrs_of(m.group(2))
        for k, v in at.items():
            if k.startswith("on"):
                bad("<%s> carries an inline %s handler; a figure is static markup" % (tag, k))
            if k == "id" and slug and not v.startswith(slug + "-"):
                bad("id=\"%s\" is not prefixed \"%s-\"; two figures on one page share one id "
                    "namespace" % (v, slug))
            if k in COLOUR_ATTRS and not COLOUR_OK.match(v.strip()):
                bad("<%s> has %s=\"%s\"; colours come from the page's CSS variables, as "
                    "var(--...)" % (tag, k, v))
            if k in REF_ATTRS:
                ref = v.strip()
                m_scheme = SCHEME.match(ref)
                if m_scheme is None:
                    ok_ref = ref.startswith("#")
                else:
                    ok_ref = m_scheme.group(1).lower() in LINK_SCHEMES and tag == "a"
                if not ok_ref:
                    bad("<%s> has %s=\"%s\"; a drawing points at a same-document #fragment, and "
                        "only an <a> may leave the page, with http, https or mailto" % (tag, k, ref))
            if k == "style":
                for prop, val in style_decls(v):
                    if prop in COLOUR_ATTRS and not COLOUR_OK.match(val):
                        bad("<%s> styles %s: %s; colours come from the page's CSS variables, as "
                            "var(--...)" % (tag, prop, val))
        if tag == "text":
            missing = [a for a in ("data-en", "data-hant", "data-hans") if not at.get(a)]
            if missing:
                bad("a <text> is missing %s; one missing attribute leaks English onto the "
                    "Chinese page" % ", ".join(missing))
        if tag in ("rect", "polygon"):
            if at.get("data-node"):
                nodes.add(at["data-node"])
            else:
                bad("a <%s> carries no data-node; every selectable shape needs its latin "
                    "identity" % tag)
        if at.get("data-edge"):
            edges_drawn.add(at["data-edge"])
        elif tag in ("path", "line", "polyline"):
            style = at.get("style", "")
            if at.get("marker-end") or at.get("marker-start") or "marker-" in style:
                bad("a <%s> draws an arrow with no data-edge; every connector needs one so its "
                    "evidence line can name it" % tag)

    for l in fig["lines"]:
        m = re.match(r"^\s*-\s*edge\s+(\S+)\s*:\s*(\S.*?)\s*$", l)
        if m:
            edges_declared.add(m.group(1))
    for e in sorted(edges_drawn - edges_declared):
        bad("connector data-edge=\"%s\" has no '- edge %s: <what proves it>' line" % (e, e))
    for e in sorted(edges_declared - edges_drawn):
        bad("evidence names edge \"%s\", which the svg does not draw" % e)

    figure_nodes.append((name, nodes))

# ---- the comparison rule ----------------------------------------------------
# A figure carrying a data-node for every option IS the comparison; no separate
# label says so, because a label would be a second declaration of something the
# drawing already proves - and one a worker could type onto a drawing that
# compares nothing.
if kind == "needs-decision" and figure_nodes and options:
    best = max(figure_nodes, key=lambda c: len(set(options) & c[1]))
    missing = [o for o in options if o not in best[1]]
    if len(missing) == len(options):
        problems.append('no figure puts the options together: none draws a shape with '
                        'data-node="%s". Separate drawings bury the only question the reader '
                        'has - where the options differ, and where they become the same thing'
                        % '" or data-node="'.join(options))
    elif missing:
        problems.append('the figure that compares the options (%s) draws no shape with '
                        'data-node="%s"; a comparison that omits an option is not a comparison'
                        % (best[0], '", "'.join(missing)))

print(len(figures))
for line in problems:
    print(line)
PY
}

command_verify() {  # <task-id> ; prints problems to stderr, exit 1 on any
  local id=${1-} packet kind problems=0 n block figcount=0
  local -a opts=()
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
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        opts+=("$line")
      done < <(printf '%s\n' "$block" | jq -r '.options[]?.value | select(type == "string")' 2>/dev/null)
    fi
  fi
  # Looser than the checker's own heading rule on purpose: this only decides
  # whether python3 is needed, and a gate stricter than the parser it guards
  # would wave a section through unchecked.
  if [ "$kind" = needs-decision ] || grep -qE '^##[[:space:]]+Figures[[:space:]]*$' "$packet"; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "fm-packet: python3 is required to check the packet's figures" >&2; problems=$((problems + 1))
    else
      # A checker that dies must never read as a clean packet: take its exit
      # status, which a process substitution would discard. Its first line is
      # the figure count, from the same parse that did the checking.
      local figs status=0
      figs=$(figures_problems "$packet" "$kind" ${opts[@]+"${opts[@]}"}) || status=$?
      if [ "$status" -ne 0 ]; then
        echo "fm-packet: the figures check failed (exit $status); the packet is not verified" >&2
        problems=$((problems + 1))
      fi
      case "${figs%%$'\n'*}" in
        ''|*[!0-9]*) ;;
        *) figcount=${figs%%$'\n'*} ;;
      esac
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "fm-packet: figures: $line" >&2; problems=$((problems + 1))
      done < <(printf '%s\n' "$figs" | tail -n +2)
    fi
  fi
  [ "$problems" -eq 0 ] || exit 1
  printf 'packet: ok %s\n' "$packet"
  [ "$figcount" -eq 0 ] || printf 'figures: %d checked against the contract; legibility is not - render the page and look at the drawing\n' "$figcount"
}

# ---- card -------------------------------------------------------------------

command_card() {
  local id='' repo='' packet project page real packet_url=''
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
  # The served page's URL rides the card only while its session is listed open,
  # so the board never links a page nobody can reach.
  if command -v lavish-axi >/dev/null 2>&1; then
    page=$(page_path "$id")
    if [ -e "$page" ]; then
      [ ! "$packet" -nt "$page" ] || render_page "$id"
      real=$(page_realpath "$page") && packet_url=$(lavish_open_url "$real")
    fi
  fi
  decision_block "$packet" | jq --arg repo "$repo" --arg packet_url "${packet_url:-}" '
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
    + (if has("close") then {close: .close} else {} end)
    + (if $packet_url != "" then {packet_url: $packet_url} else {} end)'
}

# ---- render -----------------------------------------------------------------

page_path() { printf '%s/%s/packet.html\n' "$DATA" "$1"; }

# The page is one self-contained file: no network, no CDN, no external fonts.
# Its chrome follows the bearings board's tokens so the two read as one system;
# the board's Google Fonts import is deliberately left out and the same
# fallback stacks carry the type. Copy objects in the decision block render per
# language through data-en/hant/hans attributes the page's language switch
# reads; plain strings render as written. The raw markdown rides the page for
# the copy button. Stdlib python3 only, as bin/fm-doc-audience-check.sh already
# requires.
render_html() {  # <packet.md> <out.html> <task-id>
  python3 - "$1" "$2" "$3" <<'PY'
import html, json, re, sys, pathlib

src, out, task = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
raw = src.read_text(encoding="utf-8")
lines = raw.splitlines()

# ---- parse: header key: value lines, then ## sections in order -------------
# The heading rules are verify's, character for character (figures_problems
# states the same two): a heading the two read differently is a drawing one of
# them turns into prose while the other passes its svg through unescaped.
def section_heading(line):
    return line[3:].strip() if line.startswith("## ") else None

def figure_heading(line):
    return line[4:].strip() if line.startswith("### ") else None

meta = {}
body_start = 0
for i, line in enumerate(lines):
    if section_heading(line) is not None:
        body_start = i
        break
    m = re.match(r"^([a-z]+): (.*)$", line)
    if m:
        meta[m.group(1)] = m.group(2)
sections = []  # [heading, [lines]]
for line in lines[body_start:]:
    h = section_heading(line)
    if h is not None:
        sections.append([h, []])
    elif sections:
        sections[-1][1].append(line)

DECISION_FENCE = "```json fm-packet-decision.v1"
def split_decision(body):
    """-> (lines without the fenced decision block, decision dict or None)"""
    keep, block, inside, found = [], [], False, None
    for line in body:
        if not inside and line == DECISION_FENCE:
            inside = True; block = []; continue
        if inside and line == "```":
            inside = False; found = json.loads("\n".join(block)); continue
        (block if inside else keep).append(line)
    return keep, found

# ---- language ----------------------------------------------------------------
LANGS = ("en", "hant", "hans")
T = {
  "en": {
    "kind_done": "done", "kind_needs": "needs a decision",
    "risk": "risk {r}", "risk_low": "low", "risk_medium": "medium", "risk_high": "high",
    "rev_yes": "reversible", "rev_no": "cannot be undone", "rev_partly": "partly reversible",
    "k_decide": "decide", "k_options": "options",
    "k_nothing": "if nothing", "k_rev": "reversible?", "k_risk": "risk",
    "k_rec": "recommendation", "k_why": "why", "rec": "rec",
    "m_task": "task", "m_kind": "kind", "m_branch": "branch", "m_head": "head",
    "m_base": "base", "m_generated": "generated", "m_worktree": "local copy",
    "s_changed": "What changed", "s_generated": "generated from the local copy and the PR",
    "s_session": "What only this session knows", "s_decision": "The decision",
    "s_evidence": "Evidence", "s_more": "How to pull more",
    "s_figures": "Figures", "f_edges": "what proves each line",
    "copy": "Copy the context", "copied": "Copied",
    "copy_hint": "the whole packet as markdown, ready for any coding agent",
    "raw_title": "Select all and copy", "close": "Close",
  },
  "hant": {
    "kind_done": "已完成", "kind_needs": "等你決定",
    "risk": "風險 {r}", "risk_low": "低", "risk_medium": "中", "risk_high": "高",
    "rev_yes": "可回頭", "rev_no": "回不去", "rev_partly": "部分可回頭",
    "k_decide": "決定什麼", "k_options": "選項",
    "k_nothing": "什麼都不做", "k_rev": "能不能回頭", "k_risk": "風險",
    "k_rec": "建議", "k_why": "為什麼", "rec": "建議",
    "m_task": "任務", "m_kind": "狀態", "m_branch": "分支", "m_head": "head",
    "m_base": "base", "m_generated": "產生於", "m_worktree": "本機副本",
    "s_changed": "改了什麼", "s_generated": "由本機副本與 PR 產生",
    "s_session": "只有這個 session 知道的事", "s_decision": "這個決定",
    "s_evidence": "證據", "s_more": "怎麼再往下挖",
    "s_figures": "圖解", "f_edges": "每條線的依據",
    "copy": "複製完整 context", "copied": "已複製",
    "copy_hint": "整份 packet 的 markdown，可直接貼給任何 coding agent",
    "raw_title": "全選後複製", "close": "關閉",
  },
  "hans": {
    "kind_done": "已完成", "kind_needs": "等你决定",
    "risk": "风险 {r}", "risk_low": "低", "risk_medium": "中", "risk_high": "高",
    "rev_yes": "可回头", "rev_no": "回不去", "rev_partly": "部分可回头",
    "k_decide": "决定什么", "k_options": "选项",
    "k_nothing": "什么都不做", "k_rev": "能不能回头", "k_risk": "风险",
    "k_rec": "建议", "k_why": "为什么", "rec": "建议",
    "m_task": "任务", "m_kind": "状态", "m_branch": "分支", "m_head": "head",
    "m_base": "base", "m_generated": "生成于", "m_worktree": "本机副本",
    "s_changed": "改了什么", "s_generated": "由本机副本与 PR 生成",
    "s_session": "只有这个 session 知道的事", "s_decision": "这个决定",
    "s_evidence": "证据", "s_more": "怎么再往下挖",
    "s_figures": "图解", "f_edges": "每条线的依据",
    "copy": "复制完整 context", "copied": "已复制",
    "copy_hint": "整份 packet 的 markdown，可直接贴给任何 coding agent",
    "raw_title": "全选后复制", "close": "关闭",
  },
}
SECTION_KEYS = {
    "What changed (generated)": "s_changed", "What only this session knows": "s_session",
    "The decision": "s_decision", "Figures": "s_figures",
    "Evidence": "s_evidence", "How to pull more": "s_more",
}

def esc(s): return html.escape(str(s), quote=True)

def tri(key, **vars):
    """chrome string: EN text plus the three data-* attributes the switch reads"""
    def fmt(l):
        s = T[l][key]
        for k, v in vars.items(): s = s.replace("{" + k + "}", str(v))
        return s
    return (esc(fmt("en")), " ".join('data-%s="%s"' % (l, esc(fmt(l))) for l in LANGS))

def copy_attrs(v):
    """packet copy: a plain string renders as written; an {en,hant?,hans?} object per language"""
    if isinstance(v, dict):
        en = v.get("en", "")
        hant = v.get("hant") or en
        hans = v.get("hans") or hant
        return esc(en), 'data-en="%s" data-hant="%s" data-hans="%s"' % (esc(en), esc(hant), esc(hans))
    return esc(v), ""

def span(cls, text, attrs, tag="span"):
    return "<%s class=\"%s\"%s>%s</%s>" % (tag, cls, (" " + attrs) if attrs else "", text, tag)

# ---- markdown: headings, lists, fenced code, inline code, bold, links --------
SCHEME = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*):")
def safe_href(url):
    m = SCHEME.match(url)
    return m is None or m.group(1).lower() in ("http", "https", "mailto")
def inline(text):
    parts = re.split(r"(`[^`]*`)", text)
    out = []
    for p in parts:
        if p.startswith("`") and p.endswith("`") and len(p) >= 2:
            out.append("<code>%s</code>" % esc(p[1:-1])); continue
        p = esc(p)
        p = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", p)
        def link(m):
            label, url = m.group(1), html.unescape(m.group(2))
            if not safe_href(url):
                return m.group(0)
            return '<a href="%s" target="_blank" rel="noopener" data-lavish-action="open-link">%s</a>' % (esc(url), label)
        p = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, p)
        out.append(p)
    return "".join(out)

def md(body):
    out, i, n = [], 0, len(body)
    def para(buf):
        if buf: out.append("<p>%s</p>" % "<br>".join(inline(l) for l in buf))
    buf = []
    while i < n:
        line = body[i]
        if line.startswith("```"):
            para(buf); buf = []
            lang = line[3:].strip()
            code = []; i += 1
            while i < n and not body[i].startswith("```"):
                code.append(body[i]); i += 1
            i += 1
            out.append('<pre%s><code>%s</code></pre>' % ((' data-lang="%s"' % esc(lang)) if lang else "", esc("\n".join(code))))
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            para(buf); buf = []
            level = min(len(m.group(1)) + 2, 6)
            out.append("<h%d>%s</h%d>" % (level, inline(m.group(2)), level)); i += 1; continue
        lm = re.match(r"^\s*([-*]|\d+[.)])\s+(.*)$", line)
        if lm:
            para(buf); buf = []
            ordered = lm.group(1)[0].isdigit()
            items = []
            while i < n:
                lm = re.match(r"^\s*([-*]|\d+[.)])\s+(.*)$", body[i])
                if not lm or lm.group(1)[0].isdigit() != ordered: break
                items.append(lm.group(2)); i += 1
            tag = "ol" if ordered else "ul"
            out.append("<%s>%s</%s>" % (tag, "".join("<li>%s</li>" % inline(x) for x in items), tag))
            continue
        if not line.strip():
            para(buf); buf = []; i += 1; continue
        buf.append(line); i += 1
    para(buf)
    return "\n".join(out)

# ---- figures: the drawings ride the page as inline SVG ----------------------
# verify has already enforced the SVG contract (this script's header owns it),
# so the svg is inlined as written rather than escaped: that is the whole point
# of carrying it in the packet. Its <text> nodes carry the three languages, so
# the page's language switch re-labels the drawing with everything else, and
# its colours are the page's own CSS variables.
FIG_ATTR = re.compile(r"^(figure|caption):\s*(\S.*?)\s*$")
FIG_EDGE = re.compile(r"^\s*-\s*edge\s+(\S+)\s*:\s*(\S.*?)\s*$")

def figures_html(body):
    head, figures, cur = [], [], None
    for line in body:
        h = figure_heading(line)
        if h is not None:
            cur = (h, []); figures.append(cur)
        elif cur is not None:
            cur[1].append(line)
        else:
            head.append(line)
    out = [md(head)] if "\n".join(head).strip() else []
    for heading, lines in figures:
        chunk = "\n".join(lines)
        fields, edges = {}, []
        for line in lines:
            m = FIG_ATTR.match(line)
            if m and m.group(1) not in fields:
                fields[m.group(1)] = m.group(2); continue
            m = FIG_EDGE.match(line)
            if m:
                edges.append((m.group(1), m.group(2)))
        svg = re.search(r"<svg\b.*?</svg\s*>", chunk, re.S)
        parts = ['<figure class="pk-fig" id="fig-%s">' % esc(fields.get("figure", "")),
                 "<h3 class=\"pk-fig__h\">%s</h3>" % inline(heading)]
        if svg:
            parts.append('<div class="pk-fig__svg">%s</div>' % svg.group(0))
        if fields.get("caption"):
            parts.append('<figcaption class="pk-fig__cap">%s</figcaption>' % inline(fields["caption"]))
        if edges:
            e_text, e_attrs = tri("f_edges")
            parts.append(span("pk-fig__edges-h", e_text, e_attrs))
            parts.append('<ul class="pk-fig__edges">%s</ul>'
                         % "".join("<li><code>%s</code> %s</li>" % (esc(k), inline(v)) for k, v in edges))
        parts.append("</figure>")
        out.append("".join(parts))
    return "\n".join(out)

# ---- the decision card: the five questions and the recommendation ----------
def row(key, value_html, tone=""):
    k_text, k_attrs = tri(key)
    return ('<div class="bb-ctx__row%s">%s%s</div>'
            % ((" bb-ctx__row--" + tone) if tone else "", span("bb-ctx__k", k_text, k_attrs), span("bb-ctx__v", value_html, "")))

def badge(tone, key, **vars):
    text, attrs = tri(key, **vars)
    return span("fm-badge fm-badge--" + tone, text, attrs)

def risk_badge(r):
    word = T["en"]["risk_" + r]  # substituted per language below
    text = esc(T["en"]["risk"].replace("{r}", word))
    attrs = " ".join('data-%s="%s"' % (l, esc(T[l]["risk"].replace("{r}", T[l]["risk_" + r]))) for l in LANGS)
    return span("fm-badge fm-badge--" + {"low": "neutral", "medium": "warn", "high": "danger"}[r], text, attrs)

def rev_badge(rv):
    tone, key = {"yes": ("online", "rev_yes"), "no": ("danger", "rev_no"), "partly": ("warn", "rev_partly")}[rv]
    return badge(tone, key)

def decision_card(d):
    title, title_attrs = copy_attrs(d["title"])
    badges = [badge("solid", "kind_needs")]
    if d.get("risk"): badges.append(risk_badge(d["risk"]))
    badges.append(rev_badge(d["reversible"]))
    parts = ['<section class="fm-card fm-card--poster bb-decision pk-decision" id="pk-decision">',
             '<div class="bb-decision__pad">',
             '<div class="bb-decision__top"><span class="bb-decision__badges">%s</span><span class="bb-decision__repo">%s</span></div>'
             % ("".join(badges), esc(d.get("key", task))),
             span("bb-decision__title", title, title_attrs, tag="h2")]
    ctx = [row("k_decide", span("", *copy_attrs(d["decide"])), "decide")]
    opts = []
    for o in d["options"]:
        label, label_attrs = copy_attrs(o["label"])
        cons, cons_attrs = copy_attrs(o["consequence"])
        rec = ""
        if o["value"] == d.get("recommend_value"):
            rec_text, rec_attrs = tri("rec")
            rec = span("bb-opt__rec", rec_text, rec_attrs)
        opts.append('<div class="bb-opt pk-opt%s"><span class="bb-opt__body">%s%s</span>%s</div>'
                    % (" pk-opt--rec" if rec else "", span("bb-opt__label", label, label_attrs),
                       span("bb-opt__consequence", cons, cons_attrs), rec))
    ctx.append(row("k_options", '<div class="bb-opts">%s</div>' % "".join(opts)))
    ctx.append(row("k_nothing", span("", *copy_attrs(d["if_nothing"])), "nothing"))
    ctx.append(row("k_rev", rev_badge(d["reversible"])))
    if d.get("risk"): ctx.append(row("k_risk", risk_badge(d["risk"])))
    rec_opt = next((o for o in d["options"] if o["value"] == d.get("recommend_value")), None)
    if rec_opt:
        ctx.append(row("k_rec", span("pk-rec", *copy_attrs(rec_opt["label"])), "rec"))
    if d.get("recommend_why"):
        ctx.append(row("k_why", span("", *copy_attrs(d["recommend_why"])), "rec"))
    parts.append('<div class="bb-ctx">%s</div>' % "".join(ctx))
    parts.append("</div></section>")
    return "\n".join(parts)

# ---- assemble ----------------------------------------------------------------
kind = meta.get("kind", "done")
kind_badge = badge("solid" if kind == "needs-decision" else "online", "kind_needs" if kind == "needs-decision" else "kind_done")
meta_rows = []
for key in ("task", "kind", "branch", "head", "base", "generated", "worktree"):
    if key in meta:
        k_text, k_attrs = tri("m_" + key)
        meta_rows.append("<div class=\"pk-meta__row\">%s<span class=\"pk-meta__v\">%s</span></div>"
                         % (span("pk-meta__k", k_text, k_attrs), esc(meta[key])))

section_html = []
for heading, body in sections:
    body, decision = split_decision(body)
    key = SECTION_KEYS.get(heading)
    if key:
        h_text, h_attrs = tri(key)
    else:
        h_text, h_attrs = esc(heading), ""
    sub = ""
    if key == "s_changed":
        s_text, s_attrs = tri("s_generated")
        sub = span("pk-section__sub", s_text, s_attrs)
    inner = figures_html(body) if key == "s_figures" else md(body)
    if decision is not None:
        inner = decision_card(decision) + inner
    section_html.append('<section class="fm-card pk-section" id="%s">%s%s<div class="pk-prose">%s</div></section>'
                        % (esc(key or heading), span("fm-sign fm-sign--eyebrow pk-section__h", h_text, h_attrs, tag="h2"), sub, inner))

copy_t, copy_a = tri("copy"); hint_t, hint_a = tri("copy_hint")
rawt_t, rawt_a = tri("raw_title"); close_t, close_a = tri("close")
raw_js = json.dumps(raw).replace("</", "<\\/").replace("<!--", "<\\!--")

page = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Packet - TASK_ID</title>
<style>
/* Tokens follow the bearings board (Firstmate Design System) so the packet
   page and the board read as one system. No external font import: the page
   must render with no network at all, so the fallback stacks carry the type. */
:root {
  --rust-700: #8f2f17; --rust-600: #a93a1f; --rust-500: #c0452a;
  --rust-400: #d35f3f; --rust-300: #e08365; --rust-100: #f4d8c9; --rust-050: #fbece3;
  --navy-700: #1a2238; --navy-600: #222c49; --navy-500: #2a3656;
  --navy-300: #6c7796; --navy-100: #d9deea;
  --gold-600: #b5791c; --gold-500: #e0a52e; --gold-300: #f0d38c; --gold-100: #f8ecc9;
  --ocean-600: #2f6688; --ocean-500: #3c7ea6; --ocean-200: #b6d4e2; --ocean-050: #e8f1f5;
  --sea-700: #234e3a; --sea-500: #2f6b4f; --sea-200: #b9d4c5; --sea-050: #e9f2ec;
  --paper-000: #fbf4e2; --paper-100: #f6ecd3; --paper-200: #f0e3c4; --paper-300: #e7d6ae;
  --cream-line: #ddc89c;
  --ink-900: #241c14; --ink-700: #3f3224; --ink-500: #6f5e46; --ink-300: #9c8a6c;
  --white: #fffdf7;
  --bg-page: var(--paper-100);
  --surface-card: var(--white);
  --surface-card-warm: var(--paper-000);
  --text-strong: var(--ink-900); --text-body: var(--ink-700);
  --text-muted: var(--ink-500); --text-faint: var(--ink-300);
  --border-default: var(--cream-line); --border-soft: var(--paper-300);
  --status-warn: var(--gold-600); --status-danger: var(--rust-600);
  --font-display: "Cooper Black", Rockwell, Georgia, serif;
  --font-sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, "PingFang TC", "Noto Sans CJK TC", sans-serif;
  --font-mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --fs-h3: 1.4rem; --fs-h4: 1.15rem; --fs-base: 1rem; --fs-sm: 0.9375rem;
  --fs-xs: 0.8125rem; --fs-2xs: 0.6875rem;
  --ls-caps: 0.16em;
  --radius-xs: 6px; --radius-sm: 9px; --radius-md: 12px; --radius-banner: 7px;
  --radius-lg: 18px; --radius-pill: 999px;
  --shadow-sm: 0 1px 2px rgba(36, 28, 20, 0.06), 0 4px 10px rgba(36, 28, 20, 0.06);
  --shadow-hard: 4px 4px 0 var(--ink-900);
  --shadow-hard-sm: 3px 3px 0 var(--ink-900);
  --focus-ring: 0 0 0 3px var(--gold-300);
  --container-app: 900px;
  /* The figure palette: the variable names a figure's SVG is drawn against
     (baton's embedding contract), bound to this page's own tokens so a
     drawing inherits the page instead of carrying its own colours. */
  --fg: var(--text-strong); --muted: var(--text-muted); --soft: var(--text-faint);
  --card: var(--surface-card); --card-2: var(--surface-card-warm); --bg: var(--bg-page);
  --rule: var(--border-default); --rule-strong: var(--ink-300);
  --accent: var(--rust-500); --accent-tint: var(--rust-050);
  --amber: var(--gold-500); --seal: var(--rust-700); --ok: var(--sea-500);
  --link: var(--ocean-600); --sans: var(--font-sans); --mono: var(--font-mono);
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: var(--font-sans); color: var(--text-body); background: var(--bg-page); line-height: 1.55; -webkit-font-smoothing: antialiased; }
a { color: var(--ocean-600); }
.fm-badge { display: inline-flex; align-items: center; gap: 6px; font-size: var(--fs-2xs); font-weight: 800; line-height: 1;
  padding: 5px 9px 4px; text-transform: uppercase; letter-spacing: 0.07em; border-radius: var(--radius-xs);
  border: 1.5px solid var(--ink-900); box-shadow: 2px 2px 0 var(--ink-900); white-space: nowrap; }
.fm-badge--online { background: var(--sea-500); color: var(--paper-000); }
.fm-badge--warn { background: var(--gold-500); color: var(--navy-700); }
.fm-badge--danger { background: var(--rust-600); color: var(--paper-000); }
.fm-badge--neutral { background: var(--paper-000); color: var(--ink-900); }
.fm-badge--solid { background: var(--rust-500); color: var(--paper-000); }
.fm-btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; font-family: var(--font-sans); font-weight: 800;
  line-height: 1; white-space: nowrap; border: 2px solid transparent; border-radius: var(--radius-banner); cursor: pointer; text-decoration: none; }
.fm-btn:focus-visible { outline: none; box-shadow: var(--focus-ring); }
.fm-btn:active { transform: translateY(1px); }
.fm-btn--sm { font-size: var(--fs-xs); padding: 8px 16px; }
.fm-btn--primary { background: var(--rust-500); color: var(--white); border-color: var(--ink-900); box-shadow: var(--shadow-hard-sm); }
.fm-btn--primary:hover { background: var(--rust-600); }
.fm-btn--primary.is-done { background: var(--sea-500); }
.fm-btn--ghost { background: transparent; color: var(--text-muted); border-color: var(--border-default); }
.fm-btn--ghost:hover { color: var(--text-strong); border-color: var(--ink-300); }
.fm-card { background: var(--surface-card); border: 1px solid var(--border-default); border-radius: var(--radius-lg); box-shadow: var(--shadow-sm); overflow: hidden; }
.fm-card--poster { border: 2px solid var(--ink-900); box-shadow: var(--shadow-hard); border-radius: var(--radius-md); }
.fm-sign { display: inline-flex; align-items: center; gap: 8px; font-weight: 800; text-transform: uppercase; letter-spacing: var(--ls-caps); font-size: var(--fs-xs); line-height: 1; }
.fm-sign--eyebrow { color: var(--rust-500); }
.bb-nav { position: sticky; top: 0; z-index: 20; background: var(--paper-100); border-bottom: 1px solid var(--border-default); }
.bb-nav__inner { max-width: var(--container-app); margin: 0 auto; padding: 0 24px; height: 60px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.bb-brand { display: inline-flex; align-items: center; gap: 12px; min-width: 0; }
.bb-brand__disc { display: grid; place-items: center; width: 34px; height: 34px; flex: none; border-radius: 999px; background: var(--rust-500); color: var(--paper-000); border: 2px solid var(--ink-900); box-shadow: var(--shadow-hard-sm); }
.bb-brand__disc svg { width: 60%; height: 60%; }
.bb-brand__wm { font-family: var(--font-display); font-size: 22px; color: var(--text-strong); line-height: 1; }
.bb-meta-mono { font-family: var(--font-mono); font-size: var(--fs-xs); color: var(--text-faint); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.bb-lang { display: inline-flex; flex: none; border: 1.5px solid var(--border-default); border-radius: var(--radius-pill); overflow: hidden; background: var(--surface-card); }
.bb-lang__btn { font-family: var(--font-sans); font-size: var(--fs-xs); font-weight: 700; color: var(--text-muted); background: transparent; border: 0; padding: 6px 12px; cursor: pointer; }
.bb-lang__btn:hover { color: var(--text-strong); }
.bb-lang__btn.is-active { background: var(--navy-700); color: var(--paper-000); }
.bb-lang__btn:focus-visible { outline: none; box-shadow: var(--focus-ring); }
.pk-main { max-width: var(--container-app); margin: 0 auto; padding: 24px 24px 72px; display: flex; flex-direction: column; gap: 18px; }
.pk-head { display: flex; flex-direction: column; gap: 10px; }
.pk-head__badges { display: inline-flex; flex-wrap: wrap; gap: 6px; }
.pk-head h1 { margin: 0; font-family: var(--font-display); font-size: var(--fs-h3); color: var(--text-strong); line-height: 1.2; overflow-wrap: anywhere; }
.pk-meta { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 4px 18px; font-size: var(--fs-xs); }
.pk-meta__row { display: grid; grid-template-columns: 84px minmax(0, 1fr); gap: 8px; min-width: 0; }
.pk-meta__k { font-family: var(--font-mono); font-size: var(--fs-2xs); text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-faint); white-space: nowrap; }
.pk-meta__v { font-family: var(--font-mono); color: var(--text-muted); overflow-wrap: anywhere; }
.pk-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.pk-actions__hint { font-size: var(--fs-xs); color: var(--text-muted); }
.pk-section { padding: 18px 20px; display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.pk-section__h { margin: 0; }
.pk-section__sub { font-size: var(--fs-xs); color: var(--text-faint); margin-top: -6px; }
.pk-prose { font-size: var(--fs-sm); min-width: 0; }
.pk-prose > :first-child { margin-top: 0; } .pk-prose > :last-child { margin-bottom: 0; }
.pk-prose p { margin: 0 0 10px; overflow-wrap: anywhere; }
.pk-prose h3, .pk-prose h4, .pk-prose h5, .pk-prose h6 { margin: 14px 0 6px; color: var(--text-strong); font-size: var(--fs-base); }
.pk-prose ul, .pk-prose ol { margin: 0 0 10px; padding-left: 22px; }
.pk-prose li { margin: 3px 0; overflow-wrap: anywhere; }
.pk-prose code, .bb-decision code { font-family: var(--font-mono); font-size: 0.9em; background: var(--paper-200); border-radius: 4px; padding: 1px 5px; }
.pk-prose pre, .bb-decision pre { margin: 0 0 10px; padding: 12px 14px; background: var(--navy-700); color: var(--paper-000); border-radius: var(--radius-sm); overflow-x: auto; font-size: var(--fs-xs); line-height: 1.5; }
.pk-prose pre code, .bb-decision pre code { background: transparent; padding: 0; color: inherit; font-size: inherit; }
.pk-fig { margin: 0 0 20px; display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.pk-fig:last-child { margin-bottom: 0; }
.pk-fig__h { margin: 0; font-size: var(--fs-base); color: var(--text-strong); }
.pk-fig__svg { overflow-x: auto; padding: 12px; background: var(--card); border: 1px solid var(--border-default); border-radius: var(--radius-sm); }
.pk-fig__svg svg { display: block; max-width: 100%; height: auto; font-family: var(--font-sans); }
.pk-fig__cap { font-size: var(--fs-sm); color: var(--text-body); }
.pk-fig__edges-h { font-family: var(--font-mono); font-size: var(--fs-2xs); text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-faint); }
ul.pk-fig__edges { margin: 0; padding-left: 20px; font-size: var(--fs-xs); color: var(--text-muted); }
ul.pk-fig__edges li { margin: 2px 0; overflow-wrap: anywhere; }
.pk-decision { margin-bottom: 14px; }
.bb-decision__pad { padding: 18px 20px 16px; display: flex; flex-direction: column; gap: 12px; }
.bb-decision__top { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.bb-decision__badges { display: inline-flex; flex-wrap: wrap; gap: 6px; }
.bb-decision__repo { font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint); white-space: nowrap; }
.bb-decision__title { margin: 0; font-size: var(--fs-h4); font-weight: 800; color: var(--text-strong); line-height: 1.25; }
.bb-ctx { display: flex; flex-direction: column; gap: 8px; }
.bb-ctx__row { display: grid; grid-template-columns: 110px minmax(0, 1fr); gap: 8px; align-items: baseline; }
.bb-ctx__k { font-family: var(--font-mono); font-size: var(--fs-2xs); letter-spacing: 0.04em; text-transform: uppercase; color: var(--text-faint); white-space: nowrap; }
.bb-ctx__v { font-size: var(--fs-sm); color: var(--text-muted); line-height: 1.4; min-width: 0; }
.bb-ctx__row--decide .bb-ctx__v { color: var(--text-strong); font-weight: 700; }
.bb-ctx__row--nothing .bb-ctx__k { color: var(--status-warn); }
.bb-ctx__row--nothing .bb-ctx__v { color: var(--text-body); }
.bb-ctx__row--rec .bb-ctx__k { color: var(--sea-700); }
.pk-rec { font-weight: 700; color: var(--text-strong); }
.bb-opts { display: flex; flex-direction: column; gap: 7px; }
.bb-opt { display: flex; align-items: flex-start; gap: 10px; padding: 9px 12px; background: var(--surface-card-warm); border: 1.5px solid var(--border-default); border-radius: var(--radius-sm); }
.pk-opt--rec { border-color: var(--gold-600); }
.bb-opt__body { min-width: 0; flex: 1 1 auto; }
.bb-opt__label { display: block; font-size: var(--fs-sm); font-weight: 700; color: var(--text-strong); line-height: 1.3; }
.bb-opt__consequence { display: block; font-size: var(--fs-xs); color: var(--text-body); margin-top: 3px; padding-top: 3px; border-top: 1px dashed var(--border-soft); }
.bb-opt__rec { flex: none; align-self: center; font-size: var(--fs-2xs); font-weight: 800; text-transform: uppercase; letter-spacing: 0.07em;
  color: var(--navy-700); background: var(--gold-300); border: 1px solid var(--gold-600); border-radius: var(--radius-xs); padding: 3px 7px 2px; }
.pk-raw { border: 2px solid var(--ink-900); border-radius: var(--radius-md); box-shadow: var(--shadow-hard); padding: 16px; width: min(720px, 92vw); background: var(--surface-card); }
.pk-raw::backdrop { background: rgba(36, 28, 20, 0.45); }
.pk-raw textarea { width: 100%; height: 50vh; font-family: var(--font-mono); font-size: var(--fs-xs); border: 1px solid var(--border-default); border-radius: var(--radius-sm); padding: 10px; resize: vertical; }
.pk-raw__foot { display: flex; justify-content: space-between; align-items: center; gap: 10px; margin-top: 10px; }
@media (max-width: 560px) { .bb-ctx__row, .pk-meta__row { grid-template-columns: 1fr; gap: 2px; } }
</style>
</head>
<body>
<header class="bb-nav">
  <div class="bb-nav__inner">
    <span class="bb-brand">
      <span class="bb-brand__disc"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 6v16"/><path d="m19 13 2-1a9 9 0 0 1-18 0l2 1"/><path d="M9 11h6"/><circle cx="12" cy="4" r="2"/></svg></span>
      <span class="bb-brand__wm">packet</span>
      <span class="bb-meta-mono">TASK_ID</span>
    </span>
    <span class="bb-lang" role="group" aria-label="Language">
      <button type="button" class="bb-lang__btn is-active" id="pk-lang-en" lang="en">EN</button>
      <button type="button" class="bb-lang__btn" id="pk-lang-hant" lang="zh-Hant">繁</button>
      <button type="button" class="bb-lang__btn" id="pk-lang-hans" lang="zh-Hans">简</button>
    </span>
  </div>
</header>
<main class="pk-main" data-lavish-action="packet">
  <section class="pk-head">
    <span class="pk-head__badges">KIND_BADGE</span>
    <h1>Packet: TASK_ID</h1>
    <div class="pk-meta">META_ROWS</div>
  </section>
  <div class="pk-actions">
    <button type="button" class="fm-btn fm-btn--sm fm-btn--primary" id="pk-copy" COPY_ATTRS>COPY_TEXT</button>
    <span class="pk-actions__hint" HINT_ATTRS>HINT_TEXT</span>
  </div>
SECTIONS
</main>
<dialog class="pk-raw" id="pk-raw">
  <div class="fm-sign fm-sign--eyebrow" RAWT_ATTRS>RAWT_TEXT</div>
  <textarea id="pk-raw-text" readonly></textarea>
  <div class="pk-raw__foot"><span></span><button type="button" class="fm-btn fm-btn--sm fm-btn--ghost" id="pk-raw-close" CLOSE_ATTRS>CLOSE_TEXT</button></div>
</dialog>
<script>
(function () {
  var RAW = RAW_JS;
  var LANGS = ["en", "hant", "hans"];
  var KEY = "fm-bearings-lang";  /* shared with the bearings board so one choice covers both */
  var lang = "en";
  function stored() { try { var s = window.localStorage && window.localStorage.getItem(KEY); return LANGS.indexOf(s) >= 0 ? s : null; } catch (e) { return null; } }
  function store(l) { try { if (window.localStorage) window.localStorage.setItem(KEY, l); } catch (e) { /* private mode */ } }
  function setLang(l) {
    lang = l;
    document.documentElement.lang = l === "en" ? "en" : (l === "hant" ? "zh-Hant" : "zh-Hans");
    var nodes = document.querySelectorAll("[data-en]");
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i], s = n.getAttribute("data-" + l);
      if (!s && l === "hans") s = n.getAttribute("data-hant");
      n.textContent = s || n.getAttribute("data-en");
    }
    LANGS.forEach(function (x) {
      var b = document.getElementById("pk-lang-" + x);
      b.className = "bb-lang__btn" + (x === l ? " is-active" : "");
      b.setAttribute("aria-pressed", x === l ? "true" : "false");
    });
  }
  LANGS.forEach(function (x) {
    document.getElementById("pk-lang-" + x).addEventListener("click", function () { if (x !== lang) { setLang(x); store(x); } });
  });
  setLang(stored() || "en");

  /* Copy is the one action the page exists to enable, so it has to work
     wherever the page opens. Inside a sandboxed iframe (a served page) the
     async clipboard is often denied; the rungs are the async API, the legacy
     command, then a panel with the text already selected, which needs no
     permission anywhere. */
  var raw = document.getElementById("pk-raw"), rawText = document.getElementById("pk-raw-text");
  function showRaw() {
    rawText.value = RAW;
    if (typeof raw.showModal === "function") raw.showModal(); else raw.setAttribute("open", "");
    rawText.focus(); rawText.select();
  }
  document.getElementById("pk-raw-close").addEventListener("click", function () { if (typeof raw.close === "function") raw.close(); else raw.removeAttribute("open"); });
  var cp = document.getElementById("pk-copy");
  cp.addEventListener("click", function () {
    function done(ok) {
      if (!ok) { showRaw(); return; }
      cp.classList.add("is-done"); cp.textContent = cp.getAttribute("data-copied-" + lang);
      setTimeout(function () { cp.classList.remove("is-done"); cp.textContent = cp.getAttribute("data-" + lang); }, 2000);
    }
    function legacy() {
      try {
        var ta = document.createElement("textarea");
        ta.value = RAW; ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.select();
        var ok = document.execCommand("copy"); ta.remove(); return ok;
      } catch (e) { return false; }
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(RAW).then(function () { done(true); }, function () { done(legacy()); });
    } else { done(legacy()); }
  });
})();
</script>
</body>
</html>
'''
copied_attrs = " ".join('data-copied-%s="%s"' % (l, esc(T[l]["copied"])) for l in LANGS)
slots = {
    "TASK_ID": esc(task), "KIND_BADGE": kind_badge, "META_ROWS": "".join(meta_rows),
    "COPY_ATTRS": copy_a + " " + copied_attrs, "COPY_TEXT": copy_t,
    "HINT_ATTRS": hint_a, "HINT_TEXT": hint_t,
    "RAWT_ATTRS": rawt_a, "RAWT_TEXT": rawt_t,
    "CLOSE_ATTRS": close_a, "CLOSE_TEXT": close_t,
    "SECTIONS": "\n".join(section_html), "RAW_JS": raw_js,
}
page = re.sub(r"\b(?:%s)\b" % "|".join(slots), lambda m: slots[m.group(0)], page)
out.write_text(page, encoding="utf-8")
PY
}

render_page() {  # <task-id> ; writes data/<id>/packet.html beside the verified packet
  local packet page
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to render the packet page"
  packet=$(packet_path "$1"); page=$(page_path "$1")
  [ ! -L "$page" ] || fail "page path is a symlink: $page"
  render_html "$packet" "$page" "$1" || fail "rendering $packet failed"
}

command_render() {  # <task-id> ; prints `page: <path>`
  local id=${1-}
  [ -n "$id" ] || { usage >&2; exit 2; }
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command_verify "$id" >/dev/null || exit 1
  render_page "$id"
  printf 'page: %s\n' "$(page_path "$id")"
}

# ---- serve ------------------------------------------------------------------
# Verified against lavish-axi 0.1.71: `lavish-axi <file>` exits 0 even when it
# refuses to reopen a session the captain ended, so liveness is read from the
# server's own listing (`<file>,<status>,"<url>",...`), exactly as
# bin/fm-bearings-board.sh does. The installed lavish-axi advertises `--name
# <slug>` in its help text; an older release gets the plain open and its keyed
# URL. The probe reads `--help` rather than the bare session listing, because it
# runs before the page's session is opened and a listing is not inert: it is the
# same read the open/reopen decision below depends on, so probing with one lets
# the probe answer a question serve has not asked yet.

page_realpath() {  # <page>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

page_session_name() {  # <task-id> -> the stable lavish session slug
  printf 'packet-%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
}

lavish_names_supported() { lavish-axi --help 2>/dev/null | grep -q -- '--name <slug>'; }

lavish_open_url() {  # <canonical-page-path> -> the open session's url, or nothing
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { gsub(/"/, "", field[2]); print field[2]; exit }
    }'
}

command_serve() {  # <task-id> ; renders, opens the page, prints `page:` and `url:`
  local id=${1-} page real url name
  local -a name_args=()
  [ -n "$id" ] || { usage >&2; exit 2; }
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  command_render "$id" || exit 1
  page=$(page_path "$id")
  real=$(page_realpath "$page") || fail "cannot resolve the page path: $page"
  if lavish_names_supported; then
    name=$(page_session_name "$id")
    name_args=(--name "$name")
  fi
  lavish-axi "$page" ${name_args[@]+"${name_args[@]}"} >/dev/null || fail "cannot open the packet page with lavish-axi"
  url=$(lavish_open_url "$real")
  if [ -z "$url" ]; then
    lavish-axi "$page" --reopen ${name_args[@]+"${name_args[@]}"} >/dev/null || fail "cannot reopen the packet page with lavish-axi"
    url=$(lavish_open_url "$real")
  fi
  [ -n "$url" ] || fail "the packet page has no open Lavish session after opening it (lavish-axi $(lavish-axi --version 2>/dev/null | tr -d '[:space:]'))"
  printf 'url: %s\n' "$url"
}

case "${1-}" in
  scaffold) shift; command_scaffold "$@" ;;
  verify) shift; command_verify "$@" ;;
  card) shift; command_card "$@" ;;
  render) shift; command_render "$@" ;;
  serve) shift; command_serve "$@" ;;
  path)
    shift
    if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then usage >&2; exit 2; fi
    packet_path "$1" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
