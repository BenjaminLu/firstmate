# upstream-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the upstream-write PreToolUse seatbelt.
`bin/fm-upstream-pretool-check.sh` is the single owner of both the decision and the harness transport.
The tracked harness adapters forward command text without classifying it.

It is the fourth member of a family of guards that share the same cross-harness hook machinery:
the watcher-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`), the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`), and the delegation guard (`bin/fm-subagent-pretool-check.sh`, `docs/subagent-guard.md`).

## Purpose and boundary

A fork's clone carries an `upstream` remote pointing at the repository it was forked from.
The forge CLI resolves a bare write in such a clone against that parent repository, and a remote or slug can be named explicitly on any single command.
On 2026-09-19 a worker opened a pull request against the original author's repository from one of our branches.
Nothing was malicious: work in progress simply has no business in someone else's repository.

An instruction cannot enforce that, because the worker reading the instruction is the one who forgets it.
This seatbelt refuses the command before it runs.

The `upstream` remote itself is deliberate configuration and stays exactly as it is.
A fork keeps current by fetching from its parent, so removing or renaming the remote is not the remedy.
Only writes are refused; every read and every fetch against upstream remains allowed.

The guard is not a general sandbox.
It classifies command positions in the submitted text only; it never evaluates, expands, sources, or runs any byte of that text.
Its threat model is agent mistakes, the same as its sibling seatbelts: an accidental `gh pr create`, not a deliberately obfuscated bypass.

## The protected repository is derived, never configured

The guard reads the resolved clone's own `upstream` remote and derives `owner/repo` from every URL that remote carries, fetch and push alike.
Nothing is hardcoded and nothing is read from configuration.

This is the property that makes the guard shippable.
A clone by anyone else protects *their* upstream, and a clone with no `upstream` remote - the common case for a repository that is not a fork - is a complete no-op with no behavior change of any kind.

An upstream URL this parser cannot read as `owner/repo` contributes nothing rather than failing the guard.
That matters in practice: this fleet disables the upstream push URL by setting it to a non-URL placeholder, and the slug must still come from the readable fetch URL beside it.

The repository is resolved in this order, first match winning:

1. `FM_UPSTREAM_GUARD_REPO`, when set, is the whole answer and never falls through to anything else.
2. The `cwd` the harness payload carries.
3. The guard process's own working directory.
4. The clone the script itself lives in.

## Scope: every session, not only the primary

Unlike the cd-guard and the delegation guard, this seatbelt is deliberately **not** scoped to a primary firstmate checkout.
A worker in a task worktree is exactly who opened the pull request this guard exists to refuse, so scoping it to the primary would disarm it against its own incident.

The guard is registered through firstmate's own harness configuration, so it covers firstmate's checkout and every task worktree of it.
It does **not** reach a clone under `projects/`, which carries its own harness configuration and which firstmate does not write to.
That is a known open gap: the protection for project clones has to be installed into each project rather than inherited from here.

## Block vs allow

The discriminator is whether the command WRITES, and whether it selects the protected repository in a repository-selecting position.
The guard is default-allow: a command that does not match a listed write shape is allowed, which is the direction this guard fails in by design.

The guard **blocks**:

- A forge write naming the upstream repository, or another repository in the same owner's namespace, after `--repo`/`-R`/`--repo=`: `pr create`, `pr edit`, `pr close`, `pr comment`, `pr review`, `pr merge`, `pr reopen`, `pr ready`, `pr lock`, `pr unlock`, `issue create`, `issue edit`, `issue close`, `issue comment`, `issue reopen`, `issue delete`, `issue lock`, `issue unlock`, `issue pin`, `issue unpin`, `issue transfer`, `issue develop`, `release create`, `release edit`, `release delete`, `release upload`, `repo edit`, `repo delete`, `repo archive`, and `repo rename`.
- `gh api` with a writing method (`-X`/`--method` naming `POST`, `PATCH`, `PUT`, or `DELETE`) against a `repos/<protected slug>/...` path.
- A forge write that names **no** repository at all, in a clone that has an `upstream` remote. This is the route the incident actually took: the forge CLI resolves such a write against the parent, so the command reads as local while landing upstream. The refusal names the fork to pass to `--repo` instead.
- A `git push` whose remote position holds the remote name `upstream`, or a URL or slug resolving to a protected repository.

The guard **allows** everything else, including these forms that must never be blocked:

- Every read of upstream: `pr view`, `pr list`, `pr diff`, `pr checks`, `issue view`, `issue list`, `repo view`, a bare or explicitly `GET` `gh api`, and `git log upstream/main`.
- `git fetch upstream`, `git fetch --all`, and `git ls-remote upstream`. Syncing from the parent is how a fork keeps current.
- The same writes aimed at our own fork, by `--repo`, by remote name, or by URL.
- The upstream slug appearing as prose rather than as a repository selector, which a pull request body legitimately does: `--body "ports originalauthor/widget#4937"` is allowed.
- The word `push`, or a forge noun-verb pair, appearing anywhere other than command position: `echo git push upstream main`, `grep -rn 'gh pr create' docs/`, and a `release create` belonging to some unrelated tool.

### Accepted non-goals

Consistent with the agent-mistake threat model:

- A documentation line that itself *begins* `git push upstream ...`, inside a heredoc in the same tool call, is indistinguishable from the real command at this level and is refused. `FM_ALLOW_UPSTREAM_WRITE=1` covers the deliberate case.
- Deeper obfuscation - a command reconstructed by substitution, or a slug assembled at run time - is not chased. The guard strips one layer of surrounding quotes from a token and stops there.
- A write to a repository that is neither the upstream nor in its owner's namespace is not this guard's business, whoever owns it.

## The escape hatch

`FM_ALLOW_UPSTREAM_WRITE=1` in the session environment allows deliberately.
It is an environment variable rather than a flag or a state file so it must be set when the session is launched, which makes a genuinely intended upstream contribution possible and an accidental one impossible: no in-session tool call can set it for the call that follows.

Sending work upstream remains the captain's call, and the refusal text says so rather than implying the route is merely inconvenient.

## Transport and step-aside behavior

`bin/fm-upstream-pretool-check.sh` supports every harness-engine entry shape used by the tracked adapters, with pi-signed sharing Pi's shape:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex sends stdin JSON at `.tool_input.command` without `--claude`.
- Grok sends stdin JSON at `.toolInput.command`.
- OpenCode sends the exact command string through `--command <exact string>`.
- Pi, pi-signed, and omp send the exact command string through `--command <exact string>`.
- Cursor sends stdin JSON at `.tool_input.command` and adds `--cursor`, which renders the deny as Cursor's own returned decision object. Without `--cursor` the Cursor-delivered payload is the Claude-settings duplicate Cursor also loads, and allows; `docs/arm-pretool-check.md` owns that shared predicate.

Processing order is cheapest-first: a strict-superset text prefilter, then the escape hatch, then the git calls that resolve the repository and its upstream remote.

A guard that wedges the fleet on its own bug is worse than the hole it closes, so every uncertainty steps aside with exit 0 and no output:
empty stdin, unparseable JSON, a payload with no command, missing `jq` on the stdin path, a missing `git`, no resolvable repository, no `upstream` remote, and an upstream URL that yields no readable slug.

## Output contract

Identical in shape to `docs/cd-guard.md`:

- Allow, and the inert no-upstream-remote case, return exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[upstream-guard] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[upstream-guard] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi, pi-signed, and omp return `{block: true}` only when the checker exits 2.
- `--cursor` renders the deny as `{"permission":"deny","user_message":...}` on stdout with exit 0, because Cursor reads the returned object rather than the exit status.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-upstream-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-primary-upstream-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{block: true}`; piggybacks on the already-loaded primary extension so no extra `-e` flag is needed. |
| omp | `.omp/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{block: true, reason}` and omp surfaces the reason to the model. |
| Cursor | `.cursor/hooks.json` `preToolUse` hook matching `Shell`, forwarding stdin with `--cursor` | Prints Cursor's own decision object on stdout and exits 0. |

This guard runs alongside the watcher-arm and cd seatbelts on every harness; the checks are independent, and any deny blocks the command.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement documented in `docs/arm-pretool-check.md`.

The Pi and omp entries are the primary session's extension, so those two harnesses carry the guard for a primary and not for a crewmate pane.
Claude, Codex, Cursor, and Grok read project-level configuration, which a task worktree of this repository inherits, so on those harnesses the guard covers crewmates too.

## Automated validation

`tests/fm-upstream-pretool-check.test.sh` owns the acceptance matrix.
Every verdict in it comes from a real invocation of the guard against a real fixture repository with real remotes, never from reading the script's source.

The suite proves the decision matrix in both directions, the per-clone slug derivation (two fixture clones with different upstreams, each protecting only its own), the disabled-push-URL case, the complete inertness of a clone with no `upstream` remote, every documented step-aside path, the harness output shaping in all three renderings, the stdin transport in both payload shapes, the per-harness wiring, and the end-to-end incident regression driven from inside a linked task worktree.

Run:

```sh
bash -n bin/fm-upstream-pretool-check.sh
shellcheck bin/fm-upstream-pretool-check.sh tests/fm-upstream-pretool-check.test.sh
node --check .opencode/plugins/fm-primary-upstream-check.js
tests/fm-upstream-pretool-check.test.sh
```

## Live validation record, 2026-09-20

The classifier's verdict comes from git remotes and command text, so it is not harness-dependent and the automated suite above is its regression owner.
What only a real harness can prove is that the wiring actually blocks the tool call, so the Claude registration was exercised live.

The lab was a scratch fork-shaped repository: a plain git repo with `AGENTS.md`, `origin` at `someoperator/widget`, `upstream` at `originalauthor/widget`, `bin/` holding the real `fm-upstream-pretool-check.sh` and `fm-hook-host-lib.sh`, a `.claude/settings.json` carrying only this guard's PreToolUse entry, and a stand-in `gh` on `PATH` whose only job was to append its arguments to a sentinel file.
No live watcher, fleet state, real forge call, or the captain's own checkout was involved.

**Claude Code 2.1.267** - blocked, with the allow direction proven in the same session by the sentinel file rather than by the model's narration:

- `gh pr create --repo originalauthor/widget --title wip --body wip` was denied by the `PreToolUse` hook and left no entry in the sentinel.
- `gh pr create --repo someoperator/widget --title wip --body wip` ran, and appears in the sentinel.
- `gh pr create --title wip --body wip`, the bare write the forge CLI would resolve against the parent, was denied and left no sentinel entry; the refusal named `--repo someoperator/widget` as the remedy.
- `gh pr view 1 --repo originalauthor/widget`, a read of upstream, ran and appears in the sentinel.
- The session's own `gh pr list` and `gh issue list` reads also ran, unaffected.

Launch command:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
```

Codex, Grok, OpenCode, Pi, omp, and Cursor were not re-exercised for this guard.
Each of their registrations is a byte-for-byte structural sibling of the same harness's already live-validated cd-guard entry (`docs/cd-guard.md`, 2026-07-11) with only the script name changed, and this guard's side of each of those contracts - the stdin payload shapes, the three deny renderings, and the exit statuses those adapters consume - is covered by `tests/fm-upstream-pretool-check.test.sh`.
Re-running them against a fork-shaped lab would close that gap.
