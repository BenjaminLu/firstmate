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

## What this could NOT establish

- **Whether the operator's own user memory chain can raise the same dialog.** The claim that it does, through `~/.claude/CLAUDE.md` importing `~/.claude/RTK.md`, predates this record; `~/.claude/RTK.md` does not exist on this host and `~/.claude/CLAUDE.md` carries no imports at all. Reproducing it would have required either editing the operator's global memory while other sessions were reading it, or copying their credential into a scratch config directory. Neither was done, so the user chain is not scanned and not claimed about.
- **The once-per-machine bypass-permissions disclaimer.** `claude --dangerously-skip-permissions` reached the composer with no dialog on this host even with `--settings '{"skipDangerousModePermissionPrompt":false}'` forcing that key off, while `bypassPermissionsModeAccepted` was absent from the store throughout. The condition that raises it was therefore not isolated, and no check was shipped for it.

## A fresh clone reaches its brief

A `git clone` of this repository, given nothing but empty `data/`, `state/`, `config/` and `projects/` directories and one demo project, dispatched its first Claude worker and that worker ran the task end to end:

```
done: hello.txt contains the single line "hello" - fresh-clone worker reached its instructions
```

Committing an outside import into that same demo project's `CLAUDE.md` then turned the next dispatch into a refusal naming the import, the project, and the one-time approval, instead of a launched pane; performing that approval once made the following dispatch succeed.

## Refreshing this record

```
bin/fm-test-run.sh tests/fm-claude-trust.test.sh
```

covers the gate's logic with no harness.
The dialogs themselves are vendor-rendered, so re-run the lab above after a Claude Code upgrade rather than trusting this page's version line.
