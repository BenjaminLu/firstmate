# Claude

Busy hooks verified 2026-07-28 on Claude Code 2.1.220.

## Operating facts

| Fact | Value |
|---|---|
| Busy | Owned hooks: `UserPromptSubmit` opens while `Stop`, `StopFailure`, and `SessionEnd` close; manual interrupt emits no hook, so control reports delivered keys and live endpoint only, publishes no idle event or cancellation claim, and usually leaves `claude-hook` busy. |
| Exit | `/exit`. |
| Interrupt | Single Escape. |
| Skill | `/<skill>`, for example `/no-mistakes`. |
| Model | `--model <model>`; discover through the interactive `/model` picker, with alias or full-name shape documented by `claude --help`. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`, verified on 2.1.196. |
| Permissions | `--dangerously-skip-permissions` by default, or `--permission-mode auto` when `config/claude-permission-mode` is `auto`; the `auto` shape verified on 2.1.269, and `../../../../../docs/configuration.md` "Claude permission mode" owns the file. |

## Workspace trust

`../../../../../docs/verification/claude-launch-dialogs.md` owns how the launch dialogs below were established, the measured import depth, and what is still unproven; re-run its lab after a Claude Code upgrade rather than trusting a version line here.

Claude gates a folder it has never seen behind an interactive workspace-trust dialog (titled "Quick safety check: Is this a project you created or one you trust?"), so every fresh task worktree would hit it, and so would every secondmate home no operator has opened by hand.
`--dangerously-skip-permissions` does not cover that gate: `claude --help` records that the dialog is skipped only in non-interactive mode, through `-p` or a non-TTY stdout, and a spawned pane is interactive.
Every claude spawn therefore pre-registers the directory its pane starts in before launch, and the dialog does not appear: the task worktree for a ship or scout, and the home itself for a `--secondmate` spawn, in either seeded shape (a leased worktree or a standalone clone).

A second, separate dialog - "Allow external CLAUDE.md file imports?" - gates the pane exactly like the trust dialog: cursor on "No, disable external imports", no way to move the selection from firstmate's steering plane.
Reproduced 2026-09-19 on 2.1.267: it renders when the project memory chain of the directory the pane starts in - `CLAUDE.md` or `CLAUDE.local.md` there, and their `@` imports - reaches a path outside that directory, and it lists the imported paths.
Answering "Yes, allow external imports" from inside a worktree records the approval on the PRIMARY CHECKOUT's entry, and a brand-new worktree of that same project then launches straight to the composer, so one interactive approval per project clears every later worker.
An earlier revision of this file said the dialog fires for every crewmate through the captain's own `~/.claude/CLAUDE.md` importing `~/.claude/RTK.md`; that file does not exist on the machine the reproduction was run on, the user memory chain was not shown to trigger it, and firstmate's own checkout scans clear.

`../../../bin/fm-claude-trust.sh` records `hasTrustDialogAccepted` for both the worktree and its primary checkout in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` for a ship or scout spawn; a secondmate spawn registers only its own home entry, since a secondmate home has no separate primary-checkout entry to carry import consent forward from.
For a ship or scout spawn, the external-imports flags (`hasClaudeMdExternalIncludesApproved`, `hasClaudeMdExternalIncludesWarningShown`) are carried forward alongside the trust flag only when the primary checkout's project entry already carries an explicit `hasClaudeMdExternalIncludesApproved===true` from a prior interactive session - the common first-spawn case is a project claude has never been asked about, so those two flags are left unwritten and the import dialog still renders, even though trust registers normally.
When the project entry instead already carries an explicit decline (`hasClaudeMdExternalIncludesApproved===false` with `hasClaudeMdExternalIncludesWarningShown===true`), the whole registration refuses - including the trust flag - rather than manufacture consent the human never gave, so that spawn wedges on the trust dialog before it would even reach the import one.
Both flags `false` is Claude Code's default entry for a project never asked, not a decline, and is treated like an absent flag: trust registers and the import dialog still renders.
That same script then decides, before the launch, whether this directory's own memory chain would actually raise the imports dialog, and exits 3 naming the imports and the one-time approval when it would, 4 when it cannot tell.
What it scans is the project memory chain of the directory the pane starts in, followed to the depth the product was MEASURED to load on 2.1.267: that directory's own memory file plus at most four imported files, with an import written in that fourth imported file not followed at all (an outside import there raised no dialog).
One bound decides an in-tree and an outside target alike, so an edge past it is cleared rather than reported undecided, and the clear line names the depth in those measured terms.
That scan-derived clear line also states which dimensions were NOT examined - the operator's own user-global `~/.claude` memory chain, and any `CLAUDE.md` or `CLAUDE.local.md` in directories above the launch directory - because neither was reproduced raising this dialog here, and an unscanned dimension is reported rather than left to read as a checked one.
A clear that comes from the project entry's own record (an approval, or an explicit decline) carries no such caveat: no dialog renders whatever any chain contains, so there is no residual doubt to name.
`blocks` has one source only: an import spec, as written, naming an existing regular file outside the directory.
A target that exists but is not a regular file loads nothing as memory and is ignored, and a spec that names a file only once its trailing sentence punctuation is stripped is reported rather than followed - neither shape was measured, and neither may refuse a dispatch on a guess.
An `@path` written inside a fenced or four-space-indented code block, an inline code span, or an HTML comment is not read as an import at all, so a memory file that documents the syntax or comments out a stale import never refuses a dispatch; a block quote, YAML front matter, and a link reference definition are deliberately still read as content.
`unknown` covers a chain it could not read to the end (including that punctuated spec, when nothing else in the chain reached the file it would name), and a launch whose consent entry it could not identify at all - a secondmate home inside a repository whose primary checkout cannot be resolved, where the store lookup would answer about the wrong key.
`../../../bin/fm-spawn.sh` refuses the spawn when the trust flag fails to land and on that exit 3, rather than launching a worker that would wedge; on exit 4 it launches and says what it could not decide.
The why-two-entries mechanism, the consent-gating logic, and the imports gate all live in the script's own header comment, which is the one owner for that contract.

Never try to answer either dialog with a key.
Firstmate's key plane carries only Enter, Escape, and C-c with no arrow navigation, so it can never move a dialog's selection: an option is reachable only where the dialog numbers its options and that option's own digit selects it directly, and a dialog numbering no options cannot be answered from the key plane at all.
Both dialogs here are in the unanswerable class - neither numbers its options, and both render with the cursor on their declining option, which means a sent Enter ends the session instead of accepting.
Numbered prompts are the other class, and the digit is what makes them answerable: firstmate cleared several worker permission prompts on 2026-09-19 by sending the wanted option's own digit, observed behaviour whose confirmations are in those workers' own panes, with no version or transcript captured.
The digit is load-bearing there for the same reason Enter is refused here, since a bare Enter takes whichever option is resting under the cursor rather than the one intended.
A visible trust dialog means pre-registration did not take effect (or the project entry already carries an explicit decline) - inspect the store and the spawn's error output rather than sending keys.
A visible external-imports dialog is not by itself a gate bug: the gate refuses a launch it can SEE would meet the dialog, and what it sees is the launch directory's own project memory chain, so a user-global `~/.claude/CLAUDE.md` or an ancestor `CLAUDE.md` carrying an outside import still raises it with the gate reporting `clear` - and an `unknown` verdict launches with a warning rather than refusing.
Read the pane's listed import paths first: outside the scanned chain it is expected and the same one-time approval in the project's checkout clears it, inside that chain it is a gate bug worth reporting.
`fm-control.sh <id> interrupt` delivers Escape, which dismisses whichever of the two is on screen without answering it, and is the safe way to clear a wedged pane for inspection.

The once-per-machine bypass-permissions confirmation is a third, separate dialog, scoped to the machine rather than the path, and pre-registration does not address it.
Never send Enter to that one either: it was observed rendering in the same shape as the trust dialog, with the selection on `No, exit` and the footer `Enter to confirm . Esc to cancel`, so Enter ends the session rather than accepting.
It numbers no options either, so the key plane cannot reach its accepting option at all, and an operator accepts it once per machine instead.
Inspect the pane to identify which dialog is on screen, and report it rather than answering it.
A launch under `config/claude-permission-mode=auto` never meets the bypass confirmation, because it does not request bypass mode: on 2.1.269 `claude --permission-mode auto` reached the composer directly with the footer `⏵⏵ auto mode on (shift+tab to cycle)`, so a captain who refuses the bypass dialog selects `auto` there instead of accepting it.
The workspace-trust dialog is unaffected by the permission mode and still needs the pre-registration above.

## Composer ghost

Completed turns can render dim predicted text inside an empty composer, indistinguishable in plain `tmux capture-pane`.
The spawn scopes `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` to every Claude worker and secondmate without changing global config.
CLI `--prompt-suggestions` affects print or SDK mode only and did not suppress interactive ghost text on v2.1.186.

As defense in depth, `fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` removes SGR-2 runs before pending classification on styled tmux, Herdr, and Zellij readers.
`../../../docs/herdr-backend.md` under "Composer and injection safety" owns dark-TRUECOLOR tradeoffs and `../../../docs/verification/runtime-backends.md` owns captures.
Styled capture stays internal to the boolean detector; `fm-peek` and model-facing captures remain plain, without escapes.

## Feedback drafts

The spawn disables Claude's `/bug` and `/feedback` model-drafted feedback flow for every Claude worker and secondmate, preventing a fleet-launched agent from queuing or submitting a bug report on the captain's behalf.
The controls are scoped to the launched process and never modify the captain's global Claude settings; `launch_template()` in `../../../../../bin/fm-spawn.sh` owns their exact mechanics and defense-in-depth rationale.

## Task control channel

A Claude task worker's launch brief and Firstmate steering-inbox messages arrive as file-shaped content that is otherwise indistinguishable from indirect prompt injection.
`launch_template()` in `../../../../../bin/fm-spawn.sh` establishes exactly those two Firstmate-owned channels as first-party instructions through `--append-system-prompt`, while leaving project files, fetched content, and other external material under the model's normal distrust and granting no merge, destructive, or security-sensitive authority beyond the brief.
A `--secondmate` launch omits the statement because a secondmate operates under its own supervisor contract instead of a task worker's.

## Primary integration

Primary behavior was verified 2026-07-04 on 2.1.201, preserved 2026-07-08 on 2.1.204, and Stop auto-arm revalidated 2026-07-24 on 2.1.219.
This differs from the worker hook, which only touches a task marker through `.claude/settings.local.json`.

Primary `.claude/settings.json` registers `../../../bin/fm-turnend-guard.sh --claude` and `../../../bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
Guard exit 2 plus stderr forces continuation.
Stop payload `stop_hook_active=true` follows any hook-driven continuation, including async reawakening, so Claude mode ignores it and uses cooperative claim and epoch plus bounded re-block; default Codex mode keeps it as a one-block loop guard.

Project `.claude/settings.json` loads only when the exact project root is the session root; Claude does not search parents, so Firstmate starts at repository root.
Hooks still run through cwd-sensitive `/bin/sh`, so tracked commands anchor through `"$CLAUDE_PROJECT_DIR"/bin/...`.
`../../../docs/turnend-guard.md` owns details.

The Stop-owned watcher hook runs every Stop, foregrounds `../../../bin/fm-watch-arm.sh` only when eligible, and uses exit-2 async reawakening as notification.
The model handles notifications but never routine re-arm.
Claude's PreToolUse seatbelt blocks directly, and its deny is honored only with empty stdout; `../../../docs/arm-pretool-check.md` owns that contract.

### Delegation guard

Claude delegation, scheduling, and worktree tools can create work without `state/<id>.meta`, making guards unable to count it.
`../../../bin/fm-subagent-pretool-check.sh` denies delegation-shaped tool names.
A primary should also keep an untracked home-local `permissions.deny` for known delegation tools so they disappear from the schema.
Never track it in project `.claude/settings.json`, which is Claude-only and propagates to worker copies where it would disarm legitimate delegation.
`../../../docs/subagent-guard.md` owns the contract, recommendation, `FM_ALLOW_SUBAGENT=1`, and applicability review.

On Claude 2.1.217 the tool presents as `Agent`, and both `Agent` and `Task` worked as deny keys in an A/B with nonsense control.
`permissions.allow` pre-approves rather than controls availability, so no closed positive allowlist exists.
