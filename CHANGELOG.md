# Changelog

## v0.5.0 – Terminal.Gui TUI (development preview)

- Added optional native terminal user interface source (`tui/CraftProbe.Tui`) using pinned Terminal.Gui 2.5.0 and .NET 10.
- Live dashboard for profile, export target, attached Minecraft, JFR state, verified stalls, manual incidents and ZIP export status.
- Added optional JSONL event + command bridge between the existing PowerShell recorder and the TUI. No direct Minecraft modifications.
- TUI incident button (`Alt+E`) reuses the same +5/+15-second incident captures as the CLI's `E` key.
- Added self-contained Windows publish script and GitHub Actions workflow for compilation and artifacts.
- `CraftProbe.cmd` launches the TUI when built, while `craftprobe --cli`, saved path management and PATH installation remain available.
- First version is source-delivered pending actual Windows/.NET 10 compilation and testing. Do not tag as stable before verification.


## 0.4.1

- Fixed late-attach startup crash caused by subtracting 10 seconds from `DateTime.MinValue` while scanning an already-running Minecraft JVM.

Late-attach support release.

### Start after Minecraft
- CraftProbe now checks the selected profile for an already running Minecraft JVM before waiting for a new launch.
- If Minecraft is already running, CraftProbe attaches to that JVM and continues normal JVM/JFR/stall diagnostics from the attach point forward.
- The actual Minecraft process start time is preserved as the session start instead of replacing it with the CraftProbe start time.
- The terminal clearly shows Minecraft start, CraftProbe start, attach time and the time difference between Minecraft and CraftProbe.
- If multiple matching Minecraft JVMs are running for the selected profile, CraftProbe asks which PID/session to use.

### Honest partial-session reporting
- Late attaches are explicitly marked in `_SESSION.txt`, `DIAGNOSE_SUMMARY.txt`, `CAPTURE_STATUS.json`, `TIMELINE.tsv` and `_END.txt`.
- `CAPTURE_STATUS.json` records `late_attach`, actual Minecraft start, CraftProbe start, attach time, start-difference seconds and capture-coverage start.
- JFR milestones that occurred before CraftProbe attached are now reported as `NOT_CAPTURED_LATE_ATTACH` instead of being recreated later and incorrectly appearing complete.
- Startup/world-entry milestone dumps are only created when those milestones actually occur after CraftProbe has attached.
- Rolling/final JFR, incidents and stall evidence continue to work normally after a late attach.
- A late attach without other failures reports capture health as `PARTIAL`, not as a broken diagnosis.

### Process detection
- Retains the v0.4.0 fix that rejects short-lived launcher Java probes such as `javaw.exe -version`.
- Existing-process attachment uses the same strong Minecraft/profile identity checks and a stability re-check before recording starts.

## 0.4.0

- Fixed Minecraft process detection accidentally attaching to short-lived launcher `java -version` probes (notably CurseForge); real launch identity and a 2-second stability confirmation are now required.

Diagnostic reliability and correlation release.

### Reliability
- Fixed a Windows PowerShell 5.1 regression where iterating an empty generic incident queue via `@($list)` could abort the recorder with `Argument types do not match` immediately after startup. Generic-list conversions now use direct enumeration/`ToArray()` instead.
- Replaced `Start-Process -ArgumentList` for JVM tooling with explicit Windows command-line quoting, fixing `jcmd`/`jfr` calls when Minecraft profile or export paths contain spaces.
- JFR snapshots are now validated after creation; when a matching `jfr.exe` is available, `jfr summary` must be able to read the recording before CraftProbe marks it as valid.
- Final/recovery JFR files are validated too, so a running JFR recording is no longer confused with successfully persisted diagnostics.
- Added `CAPTURE_STATUS.json` with explicit `OK`, `BASIC`, `DEGRADED`, `FAILED`, `PARTIAL`, and `NOT_CAPTURED` states for important capture layers.
- Session export no longer requires `latest.log` when recorder session metadata supplies reliable boundaries. Missing `latest.log` is reported as degraded capture quality instead of causing an unconditional abort.
- Replaced mod hashing with direct SHA-256 stream hashing and per-file error details. Added `mods.csv` and hash success/error counts.
- Exporter merges recorder health with log/hash health so a ZIP cannot silently look complete when important evidence failed.

### Correlation
- Stall IDs now use stable `STALL-0001` style IDs and manual markers use `INCIDENT-0001`.
- Added phase classification: `STARTUP`, `MAIN_MENU`, `WORLD_ENTRY`, `EARLY_CHUNKGEN`, `RUNTIME`.
- Timeline and stall tables now use ISO-8601 timestamps with timezone/offset where available.
- Added `log-context/` excerpts around every detected stall and manual incident.
- Added `STALL_GROUPS.tsv` with first/worst/last metadata for recurring server-thread signatures.
- `E` is now an incident window: immediate capture plus follow-up thread dumps at +5 s and +15 s, with an additional +15 s JFR snapshot when available.
- `DIAGNOSE_SUMMARY.txt` now includes capture health, phases, log-context references, grouped stalls, and a clearer Performance-Diagnose recommendation.

### Export layout
- `Session-Analyse.zip` remains the compact default archive.
- `Performance-Diagnose.zip` remains the heavy archive for JFR/full thread dumps. Both include the final summary/capture-health metadata when performance data exists.

## 0.3.2

- Fixed session export aborts when `latest.log` cannot reliably reveal its start time. Recorder runs now pass the actual detected Java process/session start directly to the exporter; `latest.log` remains the fallback for standalone exports.
- The exact `_diagnose_recorder` directory for the current run is passed to the exporter and copied explicitly.
- Export success is now verified by the existence of a newly created, non-empty Session-Analyse ZIP. A successful child-process exit code alone is no longer enough.
- Failed exports now clearly print `EXPORT FEHLGESCHLAGEN` and the recorder raw-data path instead of a misleading success message.
- On success Explorer opens with the finished Session-Analyse ZIP selected; opening the export folder is used as a fallback.
- Recorder/exporter version bumped to 0.3.2.

## 0.3.1

- Fixed Windows PowerShell 5.1 crash (`Argumenttypen stimmen nicht ueberein`) when CraftProbe is launched from inside a detected Minecraft profile.
- Hardened generic-list conversion in saved working-directory rules and path normalization for Windows PowerShell 5.1.
- `Q` now exits CraftProbe cleanly with exit code 0 instead of printing a PowerShell exception/stack trace.
- PATH installation and the existing v0.3.0 settings format remain unchanged.

## 0.3.0

PATH launcher and current-directory profile detection.

### PATH integration
- Added `CraftProbe.cmd --install-path` to make `craftprobe` available from any newly opened terminal without administrator rights.
- Uses a stable shim under `%LOCALAPPDATA%\CraftProbe\bin` instead of adding version-specific release folders directly to PATH.
- Re-running installation from a newer release retargets the shim to that release.
- Added `--remove-path`, `--settings` and `--help`.

### Current-directory workflow
- CraftProbe now preserves the directory from which it was invoked instead of changing into its own program directory.
- When launched from a Minecraft profile, or common subdirectories such as `mods`/`config`, CraftProbe detects the surrounding profile and offers to use it.
- The choice can be remembered per profile with “do not ask again”. Both automatic-use and ignore rules are supported.
- Remembered current-directory rules can be removed again from CraftProbe settings.
- Settings schema bumped to version 2 with automatic compatibility for existing 0.2.x settings.

## 0.2.0

Persistent profile and export path management.

### Path selection
- Added persistent settings in `%LOCALAPPDATA%\CraftProbe\settings.json`.
- Saved Minecraft profile paths are shown as a numbered startup selection.
- Profile paths can be marked as the default, removed again, or replaced with a newly selected path.
- New profile paths ask whether they should be saved and whether they should become the default.
- Added the same save/default/remove workflow for export directories.
- The built-in export default is now the selected Minecraft profile directory itself.
- Missing saved paths are visibly marked instead of silently deleted.
- `CraftProbe.cmd` now optionally accepts both a profile path and an export path.

### Internals
- Added `src/CraftProbe-Settings.ps1` to keep path persistence separate from the diagnostic recorder.
- Direct use of the exporter also defaults to the selected profile directory.
- Recorder/exporter version bumped to 0.2.0.

## 0.1.1

First polished CraftProbe release candidate.

### User experience
- Project/console branding changed to **CraftProbe**.
- Public launcher renamed to `CraftProbe.cmd`.
- Internal recorder filename remains `Minecraft-Diagnose-Recorder.ps1`.
- Replaced the legacy `FolderBrowserDialog` with the native Windows Explorer-style folder picker using `IFileOpenDialog`.
- The profile picker now has the normal breadcrumb/address bar and supports direct path navigation.
- Default export directory renamed to `_CraftProbe-Exports`.

### Repository
- Added MIT `LICENSE`.
- Updated README and German quick guide for CraftProbe.
- Added release instructions in `docs/RELEASING.md`.
- Version bumped to `0.1.1`.

### Diagnostics
- Existing portable v0.1.0 / v7 diagnostic behavior is retained: compact Session archive, separate Performance archive, JFR milestones, rolling JFR, idle-aware stall detection, deduplication, manual `E` incidents, timeline and diagnostic summary.

## 0.1.0

First portable repository release, based on the existing v7 diagnostic workflow.

### Portability
- Removed fixed profile name, drive letter and user-specific paths.
- Removed mandatory `minecraftinstance.json` / CurseForge dependency.
- Added generic Minecraft game-directory detection.
- Added `.minecraft` resolution for Prism/MultiMC-style instances.
- Added optional `-ProfilePath` and `-OutputPath` parameters.
- Added launcher-independent Java process fallback detection.
- Java diagnostic tools are discovered from the Minecraft runtime, `JAVA_HOME`, `PATH` and common JDK locations using environment-derived roots.
- Optional version detection from CurseForge metadata, Prism/MultiMC metadata or `latest.log`.

### Existing diagnostic behaviour retained
- compact Session archive + separate Performance archive
- startup/world-entry JFR milestones
- bounded rolling JFR
- idle-aware stall detection
- stall deduplication and limits
- manual `E` incident capture
- timeline and diagnostic summary
