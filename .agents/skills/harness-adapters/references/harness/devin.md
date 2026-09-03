# Devin

Adapter facts sourced from Devin CLI 3000.6.12 (docs + `devin --help`) and live self-detection on 2026-09-03.
Devin is verified for crewmate and scout work only; it is refused as a secondmate and primary until its primary supervision integration lands (see `../../../bin/fm-spawn.sh`).

## Operating facts

| Fact | Value |
|---|---|
| Launch | `devin --permission-mode dangerous [--model <m>] -- "<brief>"`. The prompt after `--` starts a supervised interactive session. `dangerous` (aliases `yolo`/`bypass`) auto-approves every tool, the equivalent of Claude's `--dangerously-skip-permissions`. |
| Busy | Owned hooks in the worktree's `.devin/hooks.v1.json`: `UserPromptSubmit` opens a turn; `Stop` and `SessionEnd` close it. Devin emits no `StopFailure`, so `SessionEnd` is the abnormal-end backstop. Source name `devin-hook` (`../../../bin/fm-busy-lib.sh`). |
| Turn-end | The `Stop` hook also touches `state/<id>.turn-ended` for the watcher, like codex's `notify`. |
| Exit | `/exit` (alias `/quit`; bare `exit`/`quit` also work). |
| Interrupt | Single `Escape` cancels the running agent (`Ctrl+C` also cancels; Escape is used, matching Claude). |
| Skill | `/<skill>`, e.g. `/no-mistakes`. |
| Model | `--model <model>`; accepts fuzzy names (family slug, alias, or partial, e.g. `--model opus`). Discover with `devin models`. |
| Effort | None. Devin exposes no effort/reasoning CLI flag (thinking level is interactive, `Alt+T`), so the shared effort axis stays in task metadata only, like cursor/kimi. |

## Detection

Detected by process ancestry (`comm=devin`), deliberately NOT by an env marker.
Devin does export `CHISEL_SESSION_DB` to its tool subprocesses, but promoting it to a marker would misidentify a markerless crewmate (codex, opencode, kimi, muse) launched from a devin primary, which inherits it before its own ancestry is consulted.
Because Devin has no marker of its own, the reverse hazard also holds: a Devin worker launched under a claude, pi, grok, cursor, or gemini primary would inherit that primary's marker and be misread, so `../../../bin/fm-spawn.sh` clears all of those at the Devin launch boundary, exactly as it does for muse and gemini.
`../../../bin/fm-harness.sh` owns the detection rule.

## Hook dialect

Devin reuses Claude's hook schema, so the busy wiring mirrors the Claude adapter exactly, with two differences: the file is `.devin/hooks.v1.json` whose ENTIRE contents are the hooks object (no outer `"hooks"` wrapper key), and there is no `StopFailure` event.
Devin also reads `.claude/settings.json` hooks when `read_config_from.claude` is enabled, but firstmate writes the native `.devin/hooks.v1.json` to stay independent of that toggle.

## Live-verification gate

The following ride Devin's docs and its Claude-compatible dialect but still need a live end-to-end spawn to confirm before treating the adapter as fully proven, per `../firstmate-coding-guidelines/SKILL.md` "Harness-dependent checks":
Stop/UserPromptSubmit hook firing in an interactive `--permission-mode dangerous` pane; a single Escape cancelling a turn without repolluting the composer (so no clear key is needed); `/exit` leaving the composer cleanly; and whether a fresh worktree path raises any trust/permission dialog under `dangerous` mode.
Record the dated result in `../../../docs/verification/runtime-backends.md`.

`../../../tests/fm-devin-harness.test.sh` is the portable regression: it pins ancestry detection (including that `CHISEL_SESSION_DB` is not a marker), the control-lib interrupt and exit table, the crewmate/scout-only kind gate, the `.devin/hooks.v1.json` wiring path, the `devin-hook` busy source, and the loud secondmate refusal, all with real processes and no harness.
A live guard in the `live-harness-optin` family is still pending: Devin is not installed as a test dependency on the CI lanes, so the live spawn check above is run by hand before the first real dispatch.
