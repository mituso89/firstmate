# Devin

Adapter facts sourced from Devin CLI 3000.6.12 (docs + `devin --help`) and live self-detection on 2026-09-03, then verified live end to end on devin 3000.10.31 on 2026-09-17 (`../../../docs/verification/runtime-backends.md` "Devin").
Devin is verified for crewmate and scout work only; it is refused as a secondmate and primary until its primary supervision integration lands (see `../../../bin/fm-spawn.sh`).

## Operating facts

| Fact | Value |
|---|---|
| Launch | `devin --permission-mode dangerous [--model <m>] -- "<brief>"`. The prompt after `--` starts a supervised interactive session. `dangerous` (aliases `yolo`/`bypass`) auto-approves every tool, the equivalent of Claude's `--dangerously-skip-permissions`. |
| Busy | Owned hooks in the worktree's `.devin/hooks.v1.json`: `UserPromptSubmit` opens a turn; `Stop` and `SessionEnd` close it. Devin emits no `StopFailure`, so `SessionEnd` is the abnormal-end backstop. Source name `devin-hook` (`../../../bin/fm-busy-lib.sh`). |
| Turn-end | The `Stop` hook also touches `state/<id>.turn-ended` for the watcher, like codex's `notify`. |
| Exit | `/exit` (alias `/quit`; bare `exit`/`quit` also work). |
| Interrupt | Double `Escape` cancels a running turn with an empty composer; a single press does not. On an idle Devin a double Escape opens a rewind picker, so the control plane follows with one closing Escape (`../../../bin/fm-control-lib.sh`). A cancel fires no hook, so the busy record stays busy, as with Claude. |
| Skill | `/<skill>`, e.g. `/no-mistakes`. |
| Model | `--model <model>`; accepts fuzzy names (family slug, alias, or partial, e.g. `--model opus`). Discover with `devin models`. |
| Composer | `❭` plus a grey placeholder, read as empty by the shared composer classifier; typed text reads pending. |
| Effort | None. Devin exposes no effort/reasoning CLI flag (thinking level is interactive, `Alt+T`), so the shared effort axis stays in task metadata only, like cursor/kimi. |

## Detection

Detected by process ancestry (`comm=devin`), deliberately NOT by an env marker.
Devin does export `CHISEL_SESSION_DB` to its tool subprocesses, but promoting it to a marker would misidentify a markerless crewmate (codex, opencode, kimi, muse) launched from a devin primary, which inherits it before its own ancestry is consulted.
Because Devin has no marker of its own, the reverse hazard also holds: a Devin worker launched under a claude, pi, grok, cursor, or gemini primary would inherit that primary's marker and be misread, so `../../../bin/fm-spawn.sh` clears all of those at the Devin launch boundary, exactly as it does for muse and gemini.
`../../../bin/fm-harness.sh` owns the detection rule.

## Hook dialect

Devin reuses Claude's hook schema, so the busy wiring mirrors the Claude adapter exactly, with two differences: the file is `.devin/hooks.v1.json` whose ENTIRE contents are the hooks object (no outer `"hooks"` wrapper key), and there is no `StopFailure` event.
Devin also reads `.claude/settings.json` hooks when `read_config_from.claude` is enabled, but firstmate writes the native `.devin/hooks.v1.json` to stay independent of that toggle.

## Herdr restore

Herdr's Devin integration (`herdr integration install devin`) reports each session id, and after a Herdr server restart Herdr types `devin --resume <id>` into a fresh shell in the pane's saved top-level shell directory (verified with devin 3000.11.3 on Herdr 0.9.1, 2026-09-25).
When that directory is not the session's own, Devin stops on `Resume this session from which directory?`: option 1 is the session's original directory, options 2 and 3 and Escape start it in the current directory, and the listed paths are truncated on a normal-width pane.
Firstmate therefore never answers that chooser; `../../../bin/fm-spawn.sh` creates the task pane inside its leased worktree, so the saved directory is the worktree and Devin resumes there with no chooser.
A worker spawned before that change still has its top-level shell in the project and meets the chooser on every restore until a relaunch moves that shell into the worktree; `../../../bin/fm-control.sh <id> relaunch` refuses while the chooser holds the composer, so its first option has to be chosen by hand before that relaunch.

## Live verification

Hook firing, trust behaviour (none under `dangerous`), steering, interrupt, and `/exit` were verified live through tmux, and the Herdr restore behaviour above in a named Herdr lab; the dated record and what remains unverified (full Herdr supervision of a Devin worker, background shells surviving `/exit`) live in `../../../docs/verification/runtime-backends.md` "Devin".

`../../../tests/fm-devin-harness.test.sh` is the portable regression: it pins ancestry detection (including that `CHISEL_SESSION_DB` is not a marker), the control-lib interrupt and exit table, the tmux/Herdr process-name classifier, the crewmate/scout-only kind gate, the `.devin/hooks.v1.json` wiring path, the `devin-hook` busy source, and the loud secondmate refusal, all with real processes and no harness.
`../../../tests/fm-devin-herdr-restore-e2e.test.sh` drives the real spawn, Treehouse, and a Herdr lab restart with a stand-in `devin` and pins that the resumed session runs in the recorded worktree.
A live guard in the `live-harness-optin` family is still pending: Devin is not installed as a test dependency on the CI lanes, so the live spawn check is repeated by hand after a Devin upgrade.
