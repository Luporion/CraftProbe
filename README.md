# Minecraft Diagnose Recorder

Portable Windows diagnostics for large modded Minecraft instances.

The recorder watches one Minecraft session, correlates logs with JVM/JFR data and creates two separate archives:

- **`<Profile>_Session-Analyse_<time>.zip`** — compact default bundle for most debugging and AI-assisted analysis.
- **`<Profile>_Performance-Diagnose_<time>.zip`** — heavy data such as JFR recordings and full stall/incident thread dumps. Only needed for freezes, high MSPT or server-thread stalls.

The project started as a diagnostic workflow for a large NeoForge modpack, but this repository version contains **no fixed drive letters, usernames, launcher paths, Java paths or profile names**.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or newer PowerShell
- A Minecraft profile/game directory containing normal folders such as `mods`, `config`, `logs`, `saves`, etc.
- Java/JDK diagnostic tools are optional. Without a compatible `jcmd.exe`, the basic export still works; JFR and live JVM snapshots are skipped.

## Quick start

1. Download or clone this repository.
2. Run **`Start-Diagnose.cmd`**.
3. Select the Minecraft profile/game directory if it is not detected automatically.
4. Start Minecraft with your normal launcher.
5. Reproduce the issue or play the test scenario.
6. Optional: press **`E`** in the recorder window when something suspicious happens.
7. Close Minecraft normally. Force-closing still leaves periodic recovery data where possible.
8. Wait for `FERTIG` / completion.

You can also drag a profile directory onto `Start-Diagnose.cmd` or launch it with a path:

```bat
Start-Diagnose.cmd "D:\Minecraft\Instances\MyPack"
```

## Launcher support

The recorder is launcher-agnostic and identifies the actual Minecraft game directory rather than requiring a specific launcher metadata file. It is designed to work with layouts used by:

- CurseForge
- PrismLauncher / MultiMC
- Modrinth App
- other launchers that use a normal Minecraft game directory

For Prism/MultiMC, selecting either the instance directory or its `.minecraft` directory is supported.

## What the compact Session archive contains

Among other things:

- complete `logs/latest.log`
- relevant session logs and crash reports
- current mod list with SHA-256 hashes
- important config/defaultconfig/serverconfig files
- KubeJS and datapack metadata when present
- Java/JVM metadata
- process and system information
- `DIAGNOSE_SUMMARY.txt`
- `TIMELINE.tsv`
- `STALL_EVENTS.tsv`
- compact server-thread excerpts for detected stalls

Large and redundant diagnostic files are deliberately excluded.

## Performance archive

The separate Performance archive contains heavy data such as:

- JFR recordings
- startup / world-entry / first-chunk JFR milestones
- rolling JFR state
- full thread dumps from verified stalls
- full thread dumps from manual `E` incidents
- unusually large supplemental diagnostic logs

For most issues, start with only the Session archive. `DIAGNOSE_SUMMARY.txt` states whether the Performance archive is recommended.

## JFR strategy

The recorder uses a bounded rolling JFR recording so long sessions do not grow without limit. Important early-session periods are preserved separately:

- startup / main-menu phase
- world entry
- world entry + first chunk generation

This keeps early problems from being overwritten by later gameplay.

## Stall detection

A silent `latest.log` alone is **not** considered a stall. The recorder tries to distinguish normal server waiting (`waitUntilNextTick`, `waitForTasks`, parked/waiting threads) from a server thread that is actually blocked or busy.

Strong watchdog or severe `Can't keep up!` messages can trigger a capture directly. Heuristic stalls require repeated active server-thread samples and similar events are deduplicated.

## Privacy

The recorder redacts common Minecraft authentication arguments/tokens from the captured Java command line. Nevertheless, always inspect archives before publishing them publicly: Minecraft/mod logs can contain usernames, server addresses, file paths or mod-specific secrets.

See [docs/DATA-COLLECTION.md](docs/DATA-COLLECTION.md) for details.

## Repository layout

```text
.
├─ Start-Diagnose.cmd
├─ src/
│  ├─ Minecraft-Diagnose-Recorder.ps1
│  └─ Export-Minecraft-Session-Analyse.ps1
├─ docs/
│  ├─ DATA-COLLECTION.md
│  └─ README-DE.md
└─ .github/
   └─ ISSUE_TEMPLATE/
```

## Current scope

This release is Windows-focused. The scripts use Windows process/CIM APIs and `cmd.exe`. A Linux/macOS implementation would need a separate process-discovery and launcher wrapper layer.

## License

No license is included yet. Choose a license before publishing the repository if you want others to be able to reuse or contribute code under explicit terms.
