# Changelog

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
