# Changelog

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
