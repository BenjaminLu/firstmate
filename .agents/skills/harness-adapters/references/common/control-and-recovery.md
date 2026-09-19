# Control and recovery

Load this with the running or recorded tool reference for trust, skill invocation, interrupt, exit, resume, or recovery.

## Typed data and lifecycle control

The router owns lifecycle-only control and recorded-harness selection.
Conversation and harness-native skill invocation use `../../../bin/fm-send.sh`.
`../../../docs/agent-control.md` owns the data-plane split, and `../../../bin/fm-control-lib.sh` owns executable capabilities.
Tool-reference exit and interrupt values are empirical records, not keys to improvise; a new adapter remains uncontrollable until they land in that owner.
Let the control plane verify postconditions.

## Trust and skill submission

Inspect after spawn within the tool's readiness window.
Select only its documented trust choice from the active Firstmate home, binding `FM_HOME` unless already correct, then inspect again under the router-owned completion postcondition.
No observed dialog proves only that launch.

Each supported harness handles its folder-trust gate differently, and the tool reference owns the detail.
For Claude, load `references/harness/claude.md`; its workspace-trust section owns the non-key-answerable gate and spawn-time pre-registration for every spawn kind.
agy gates every fresh worktree too; the spawn pre-registers it in agy's own store the same way, and a strict post-launch gate answers any dialog that still renders before the spawn reports success.
Cursor suppresses its dialog with launch-time `--trust`, and Muse suppresses its own with `--yolo`.
Grok dodges its gate instead of granting trust, because its project picker appears only outside a project and the spawn starts in the isolated git root.
Pi gates the fresh-worktree case too, but unlike Claude its dialog is answered with Enter, and `references/harness/pi.md` owns that recipe and where the decision persists.
Codex shows a directory-trust dialog on the first run for a repository root.

Use the tool's exact skill form, or natural language only when no separate command is verified or the form remains uncertain.
A successful send or key return is not proof of submission; require the tool-specific postcondition.
Popup, queued-input, and readiness handling belongs to `../../../bin/fm-composer-lib.sh` and the selected backend.

## Worker directory permissions

A worker legitimately reads four directories outside its own worktree, because its own brief sends it to each of them:

- the active Firstmate home, which carries its brief, steering inbox, status file, and packet
- the harness's own scratch root for that session
- the validation tool's data root, which `no-mistakes doctor` prints
- the user skills directory `~/.claude/skills`, where the skills a brief names live

When one of them raises a permission prompt, add that directory in the worker's own pane and clear the dialog there, then inspect the pane under the completion postcondition above to confirm it cleared.
None of these four prompts is escalated, because the captain settled them on 2026-09-19 to stop a stream of them reaching him; that is his standing decision, not a grant firstmate makes on its own judgment.
Two of the four are wider than the brief's own need, and the record has to say what they expose: granting the Firstmate home root exposes `.env` with the Relay pairing token, the mail-plane credentials, and `TYPESAFE_API_KEY`, plus `config/cmux-socket-password` and every other task's briefs, reports, and backlog under `data/`, while granting the validation tool's data root exposes every project's runs and worktrees rather than this task's alone.
A home holding material it does not want a worker to read narrows the grant to that worker's own `state/<id>` and `data/<id>` paths instead of granting the root.

## Interrupt and exit

Use the control plane so capabilities are checked first.
Interrupt preserves the agent and work; exit stops only the agent and preserves its endpoint, isolated copy, and uncommitted changes.
Cleanup and discard are not lifecycle verbs.
The tool reference records repeat, acknowledgement, and clearing behavior, while the executable owner sends or refuses the sequence.

## Resume and recovery

Native resume availability and form belong solely to the selected tool reference.
Use native resume only when both that reference and the recovery procedure call for it.
Deterministic relaunch instead trusts instructions on disk, not a private session.

`../stuck-crewmate-recovery/SKILL.md` owns worker recovery and `../secondmate-provisioning/SKILL.md` owns secondmate recovery; both preserve recorded work.
The router's recovery scenarios select the additional common references for replacement profiles and secondmates.
