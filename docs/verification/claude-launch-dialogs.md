# Verification: the dialogs a Claude launch meets before it reads its brief

Active empirical facts for the two interactive Claude Code dialogs that gate a firstmate-launched pane, and for the one this repository could not settle.
[`.agents/skills/harness-adapters/references/harness/claude.md`](../../.agents/skills/harness-adapters/references/harness/claude.md) owns the operating facts and [`bin/fm-claude-trust.sh`](../../bin/fm-claude-trust.sh)'s header owns the contract; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `claude 2.1.267 (Claude Code)` |
| Verified | 2026-09-19 |
| Binary | `/opt/homebrew/Caskroom/claude-code/2.1.267/claude`, a Mach-O arm64 single executable |
| Platform | macOS 24.6.0 (arm64) |
| Lab | a scratch git project and its linked worktrees under this task's own scratchpad, plus a fresh `git clone` of this repository run as its own `FM_HOME` |

Panes were driven with `script(1)` and `expect(1)` because this host has no `tmux`.
No captain fleet state was touched; every project entry the lab created in the operator's own Claude store was removed afterwards.

## The workspace-trust dialog still renders, and pre-registration still removes it

An unregistered linked worktree stopped at `Quick safety check: Is this a project you created or one you trust?` with the selection resting on `No, exit`.

```
❯No,exit
 Yes,Itrustthisfolder
 Entertoconfirm·Esctocancel
```

After `bin/fm-claude-trust.sh <worktree> <project>`, the same worktree reached the composer.

## The external-imports dialog is raised by the PROJECT memory chain

With trust registered and the worktree's own `CLAUDE.md` carrying `@<path outside the worktree>`, the launch stopped at the second dialog and named the import:

```
AllowexternalCLAUDE.mdfileimports?
Thisproject'sCLAUDE.mdimportsfilesoutsidethecurrentworking
directory.Neverallowthisforthird-partyrepositories.
Externalimports:
 /private/tmp/.../scratchpad/dialoglab/outside.md
❯No,disableexternalimports
 Yes,allowexternalimports
```

Answering `Yes, allow external imports` from inside the worktree wrote the decision onto the PRIMARY CHECKOUT's entry, never the worktree's:

```
.../dialoglab/wt    approved= undefined warnShown= undefined
.../dialoglab/proj  approved= true      warnShown= true
```

A second, brand-new worktree of that same project, registered by the same script, then launched straight to the composer.
That is what makes one interactive approval per project the remedy the gate prints, rather than a step that would have to be repeated per worker.

## How deep the import chain is actually followed

Measured 2026-09-19 on the same `claude 2.1.267`, in an isolated scratch project with a linked worktree: workspace trust pre-registered, no external-import decision on record, launched with `claude --permission-mode auto` and killed without answering.
The chain is the worktree's own `CLAUDE.md` (file 1) importing `link1.md`, importing `link2.md`, and so on, with the last edge landing on a file outside the worktree.

| Outside import at hop | Outcome |
|---|---|
| 1 | dialog renders |
| 2 | dialog renders |
| 4 | dialog renders |
| 5 | NO dialog, composer reached (repeated twice, 16s run) |
| 6 | NO dialog |

So the product loads the root memory file plus at most FOUR imported files - five files in the chain - and an import edge written in the file at depth 4 is not followed at all.
"Maximum import depth 5" means five files, not five hops.
The gate encodes that bound once and applies it to an in-tree and an outside target alike, so the same hop can never be treated as unloaded for one and loading for the other.

## What this could NOT establish

- **Whether the operator's own user memory chain can raise the same dialog.** The claim that it does, through `~/.claude/CLAUDE.md` importing `~/.claude/RTK.md`, predates this record; `~/.claude/RTK.md` does not exist on this host and `~/.claude/CLAUDE.md` carries no imports at all. Reproducing it would have required either editing the operator's global memory while other sessions were reading it, or copying their credential into a scratch config directory. Neither was done, so the user chain is not scanned - and because this record cannot support a clean verdict over it, every `clear` line the gate prints names the project memory chain of the launch directory as the thing it examined and states that the user-global chain was not.
- **Whether a memory file above the launch directory can raise it.** Claude Code's project-memory loading reads `CLAUDE.md` and `CLAUDE.local.md` from ancestor directories as well, but no ancestor memory file exists on this host, so nothing was reproduced through one. The gate does not walk ancestors - a single `~/CLAUDE.md` with an outside import would otherwise refuse every dispatch on every project on that host, on an unreproduced trigger - and names that dimension in its clear line instead.
- **Whether a non-regular-file import target is listed at all.** `@../outer` naming an existing DIRECTORY was not put in front of the product. A directory loads nothing as memory, so the gate ignores such a target rather than classifying it; the alternative would refuse a dispatch over prose like "See @../outer for details."
- **Whether trailing sentence punctuation is stripped from `@path`.** Not measured either way, so a spec that names a file only once `.`/`,`/`)` and the like are stripped is reported with both spellings and not followed, rather than decided in either direction.
- **Which markdown forms the product itself skips.** Whether an `@path` inside a code block, an HTML comment, a block quote, front matter, or a link reference definition is read as an import by Claude Code was not put in front of it. The gate excludes the four forms whose purpose is to mark text as not an instruction (fenced and four-space-indented code blocks, inline code spans, HTML comments) so a file documenting the syntax cannot refuse a dispatch, and deliberately still reads the other three as content.
- **The once-per-machine bypass-permissions disclaimer.** `claude --dangerously-skip-permissions` reached the composer with no dialog on this host even with `--settings '{"skipDangerousModePermissionPrompt":false}'` forcing that key off, while `bypassPermissionsModeAccepted` was absent from the store throughout. The condition that raises it was therefore not isolated, and no check was shipped for it.

## A fresh clone reaches its brief

A `git clone` of this repository, given nothing but empty `data/`, `state/`, `config/` and `projects/` directories and one demo project, dispatched its first Claude worker and that worker ran the task end to end:

```
done: hello.txt contains the single line "hello" - fresh-clone worker reached its instructions
```

Committing an outside import into that same demo project's `CLAUDE.md` then turned the next dispatch into a refusal naming the import, the project, and the one-time approval, instead of a launched pane; performing that approval once made the following dispatch succeed.

## What the gate reports, and what each verdict means

| Verdict | Exit | What it says |
|---|---|---|
| `clear` | 0 | Either the project entry already carries Claude Code's own approval or explicit decline - which carries no caveat, because no dialog renders whatever any chain contains - or no import in the launch directory's project memory chain (`CLAUDE.md`, `CLAUDE.local.md` and their `@` imports, followed to the five files measured above) reaches outside it. That second, scan-derived line also states that the operator's user-global `~/.claude` chain and any memory file in directories above the launch directory were not examined, and it says so on stderr - in the operator's words, without paths - because the spawn discards stdout and a caveat the caller throws away is not said at all. |
| `blocks` | 3 | An import spec in that chain, as written, names an existing regular file outside the directory, so the dialog would render. Names the import, the checkout to approve, and the one-time approval; it never writes that approval. |
| `unknown` | 4 | The chain could not be read to the end (an unreadable memory file, a `~` with no `HOME`, an outside-looking import that is not on disk, a spec that names a file only once its trailing punctuation is stripped, a memory path resolving out of the tree), or the project entry Claude Code reads its decision from could not be identified at all. |

The five-file depth is not an `unknown`: it is the measurement above, so an edge past it cannot raise the dialog, and the clear line names the depth it followed rather than implying it followed the chain forever.
The unmeasured TARGET SHAPES cannot produce `blocks`: a target that is not a regular file, a spec that only names a file once its trailing punctuation is stripped, an outside-looking import that is not on disk, and a path that only leaves the tree once its symlink is resolved are each ignored or reported instead, because a dispatch refused on a guess is the failure this gate was built to remove, not one to add.
The unmeasured MARKDOWN FORMS are the exception, and it is deliberate: fenced blocks, inline code spans and HTML comments are skipped, while a block quote, YAML front matter and a link reference definition are still read as content, so an `@path` written in one of those and naming an existing regular file outside the tree does produce `blocks`.
Reproduced 2026-09-19 against this script: a `CLAUDE.md` containing `> quoted example: @<path outside the tree>` exits 3.
The reasoning for reading them is in `bin/fm-claude-trust.sh`'s own header - a quote does not mark its text as an example the way a code span or a comment does - but the sentence a maintainer relies on when judging whether a refusal is even possible has to say that, rather than imply nothing unmeasured can refuse.

## Refreshing this record

```
bin/fm-test-run.sh tests/fm-claude-trust.test.sh
```

covers the gate's logic with no harness.
The dialogs themselves are vendor-rendered, so re-run the lab above after a Claude Code upgrade rather than trusting this page's version line.
