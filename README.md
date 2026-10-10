# CraftProbe v0.6.4.1 — Companion Build und Git-Patches (Windows-Fokus)
> **v0.6.4 Entwicklungs-/Testversion:** Die Game-Konsole unterstützt jetzt optional auch Minecraft-Singleplayer-Befehle über eine **separate NeoForge-Companion-Mod** (Quellcode enthalten, JAR muss kompiliert werden). Im Spiel `/craftprobe enable` verwenden. Ohne die Mod bleibt die Clientkonsole lesend; dedizierte Server funktionieren weiterhin per RCON. **Singleplayer-Befehle werden mit den normalen Spielerrechten ausgeführt**, niemals mit stillschweigend erhöhten Serverrechten. Siehe [`docs/COMPANION.md`](docs/COMPANION.md).

**Neu in v0.6.4:** Der Companion-Mod-Build benötigt keine systemweite Gradle-Installation mehr. `CraftProbe.cmd --build-companion` nutzt den abgesicherten Gradle-8.14-Wrapper. Beim ersten Aufruf lädt er das offizielle Wrapper-JAR (SHA-256-geprüft) und die verifizierte Gradle-Distribution. Voraussetzung ist weiterhin **JDK 21**, außerdem Internetzugriff beim ersten Build. `CraftProbe.cmd --companion-doctor` prüft die lokale Java-Toolchain. Vollständige Anleitung: [`docs/COMPANION.md`](docs/COMPANION.md).

**Git-Workflow:** Künftige Versionen liefern neben dem kompletten ZIP eine Git-Mail-Patchdatei (`CraftProbe-vX.Y.Z.patch`) und optional ein Overlay-ZIP. Zuerst v0.6.3 als Basis committen, danach `git am --3way` auf einem Featurebranch ausführen. Siehe [`docs/DEV-WORKFLOW.md`](docs/DEV-WORKFLOW.md).


Der neue **Konsole-Tab** zeigt die aktuelle Minecraft-`latest.log` live und erlaubt **Suche, Schweregradfilter, Pause, Fehlerzähler und das Speichern eines Log-Ausschnitts**. Er funktioniert ohne zusätzliche Minecraft-Mod und auch ohne gestartete CraftProbe-Aufnahme. Während einer Aufnahme lassen sich direkt aus der Konsole Incidents markieren.

**Befehle:** Für dedizierte Server ist optionale Minecraft-**RCON-Befehlseingabe** eingebaut, mit Rückmeldung direkt im Konsole-Tab. RCON ist nur nach aktiver Einrichtung verfügbar; standardmäßig nur localhost, Passwort ausschließlich aus `CRAFTPROBE_RCON_PASSWORD`. Ein Singleplayer-Client hat **keine externe Serverkonsole**. Minecraft-Client-Kommandos sind ab v0.6.3 mit der **optional zu bauenden Companion-Mod** moeglich; ohne Mod bleiben sie deaktiviert. Es gibt keine Tastatureinspritzung.

**Anleitung:** [docs/GAME-CONSOLE.md](docs/GAME-CONSOLE.md). **Teststatus:** C#-Implementierung und automatisierte RCON-/Log-Tests enthalten; tatsächlicher .NET-10-Build und Windows-TUI-Test müssen auf deinem Windows-PC oder in GitHub Actions ausgeführt werden.

Der Windows-Recorder und die Linux-Grundlage aus v0.6.0 bleiben erhalten. Linux/Crafty ist weiterhin bewusst **kein Entwicklungsschwerpunkt**.

---

# CraftProbe

**Historischer Stand v0.6.0 – Linux/Crafty support + shared Terminal.Gui TUI**

## Linux quick start (new in v0.6.0)

CraftProbe can now monitor Minecraft servers **started and owned by Crafty Controller**. The first Linux agent is written in **Python 3.10+ standard library** and needs no additional packages. It does not start or stop the server. The **same C#/.NET 10 Terminal.Gui 2.5.0 TUI** can be built for Linux or Windows.

```bash
./craftprobe --cli --profile '/path/to/Crafty/server/root'
# optional Linux full-screen UI (requires .NET 10 SDK at build time):
./craftprobe --build-tui
./craftprobe
```

Run the agent under the **same Linux user** as the Minecraft JVM so that `jcmd` can attach. A same-major JDK with `jcmd`/`jfr` is strongly recommended (e.g. JDK 21 for Minecraft 1.21.1). The CLI automatically waits for a server started later by Crafty or attaches to one already running. It exports ZIPs into `<server>/_CraftProbe-Exports` and reports JVM start/attach time difference. For Docker, ensure the agent can see and attach to the JVM in the same process namespace. **v0.6.0 had no Crafty API or game-console commands; v0.6.1 adds local log display and opt-in RCON (not Crafty API).**

See **[docs/LINUX-CRAFTY.md](docs/LINUX-CRAFTY.md)** for systemd, Docker, permissions, and known limitations, and **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for the shared UI/IPC and platform-specific diagnostic engines.

### Windows usage

The tested v0.5.2 Windows PowerShell recorder/exporter is retained. The Windows UI now shares its C# source with the Linux TUI. The source package is not a compiled executable; build the Windows TUI using `CraftProbe.cmd --build-tui` or use the original CLI with `CraftProbe.cmd --cli`.

### Current test status

The Linux agent has automated unit tests and an integration test using a real Java 21 JVM, `jcmd`, `JFR.dump` and `jfr summary`, including paths with spaces. A real Crafty/NeoForge deployment and native Linux Terminal.Gui build still require validation. This is a **v0.6.0 test release**, not a production-certified release.

---

**Earlier v0.5.2 – Terminal.Gui TUI: reliable recording lifecycle and four-step export progress (Windows)**

CraftProbe now includes an optional full-screen TUI built with **C#/.NET 10 + Terminal.Gui 2.5.0**, while the existing PowerShell recorder/exporter remains the diagnostic engine.

**Build required for source ZIP:** The source package intentionally does not contain an unverified Windows executable. Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), then run `CraftProbe.cmd --build-tui` once on Windows. After a successful build `craftprobe` launches the TUI automatically. `craftprobe --cli` always starts the original CLI. Automated Windows builds run via GitHub Actions and produce `CraftProbe-Windows-TUI.zip` as a workflow artifact.

**Using the TUI:** The **Aufnahme** screen provides editable dropdowns for Minecraft profiles and export targets. Enter a custom absolute path or select a saved path, optionally add a free-text session context, then press **Aufnahme starten**. Minecraft may already be running. The **Aufnahmen** screen lists past Session and Performance ZIPs; select an entry for details or open it in Explorer. The **Einstellungen** screen reloads saved path selections. During recording, **Alt+E** or the incident button requests the same capture as `E` in the CLI (+5s/+15s follow-ups); use **Notiz speichern** to update user context before export. Close Minecraft normally to finish. Leaving the TUI during an active recording is intentionally blocked.

**Windows compatibility:** Windows 10/11, PowerShell 5.1 for the recorder, .NET 10 for the TUI build/runtime (the published self-contained Windows binary includes the runtime). Terminal.Gui v2.5.0 is pinned.

**Safety:** Recorder logs and data exports are not sent to any cloud. The TUI communicates locally through transient JSONL files under `%LOCALAPPDATA%\CraftProbe\tui-sessions`. These are not part of the Session-Analyse ZIP.

---


### Fixed in v0.5.2

The TUI recording timer stops at the Minecraft-process end event (including crashes); it **does not** continue through the potentially long ZIP export. A separate state line shows `Export laeuft`, and the four export stages are emitted via structured events. Step 4 comes from the exporter when ZIP compression begins. On success the screen retains the frozen duration; on a failed or unconfirmed export it displays an error rather than falsely reporting success. The incident action is available only while Minecraft is actively being recorded. Existing v0.5.1 features are preserved.

### New in v0.5.1

- Three TUI screens: **Aufnahme**, **Aufnahmen**, **Einstellungen**.
- Terminal.Gui `DropDownList` controls for profile and export path, with editable path entry. Saved selections survive restarts.
- Optional free-text session notes, including edits while a recording is running, stored as `SESSION_CONTEXT.json` and included in the summary/ZIP.
- All new ZIPs go to `<profile>/_CraftProbe-Exports/` whenever the requested export path is the Minecraft profile itself. Explicit external export folders are unchanged.
- Session-ZIP sidecar `<name>.session.json` records user notes/time for browsing. Existing older ZIP files without sidecars still appear in the **Aufnahmen** screen.
- Fixes JVM-internal `jcmd` JFR filename quoting for paths with spaces (OS-level quoting alone was insufficient). JFR snapshot validation and visible warnings remain enabled.
- Previous `craftprobe --cli` operation and the stable TUI architecture are preserved.

Portable Windows diagnostics for modded Minecraft.

CraftProbe watches one Minecraft session, correlates Minecraft logs with JVM/JFR data and produces two separate archives:

- **`<Profile>_Session-Analyse_<time>.zip`** — compact default bundle for most debugging and AI-assisted analysis.
- **`<Profile>_Performance-Diagnose_<time>.zip`** — heavy performance evidence such as JFR recordings and full stall/incident thread dumps. Usually only needed for freezes, high MSPT or server-thread stalls.

CraftProbe is launcher-agnostic and contains no fixed drive letters, usernames, Java paths or Minecraft profile names.

## What is new in v0.4.1

CraftProbe can now be started **after Minecraft is already running**.

When an existing Minecraft JVM for the selected profile is found, CraftProbe attaches to it instead of waiting for another launch. The console and exported diagnostics show:

- actual Minecraft process start
- CraftProbe start
- JVM attach time
- the exact start-time difference
- whether this was a **late attach**

Diagnostics collected before CraftProbe started cannot be reconstructed retroactively. CraftProbe therefore marks early milestones that were already over as `NOT_CAPTURED_LATE_ATTACH` instead of pretending that a later JFR snapshot represents startup or world entry. Post-attach rolling JFR, stalls and manual `E` incidents continue normally.

If several matching Minecraft processes are running for the selected profile, CraftProbe asks which PID to attach to.

## What is new in v0.4.0

CraftProbe 0.4.0 focuses on **diagnostic reliability** rather than collecting more data.

- JFR/jcmd calls now work with profile and export paths containing spaces.
- JFR milestone/stall files are validated instead of being assumed valid.
- `CAPTURE_STATUS.json` states whether the capture is `OK`, `BASIC` or `DEGRADED` and identifies missing/failed layers.
- Mod SHA-256 hashing now reports real per-file errors in `mods.csv` instead of silently collapsing to `HASH_ERROR`.
- Recorder sessions can still export when `latest.log` is missing; the missing log is reported as degraded evidence.
- Stalls and incidents get stable IDs, phase classification, ISO timestamps and matching `log-context/` excerpts.
- Pressing **`E`** creates an incident window with immediate, +5 s and +15 s thread evidence.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or newer PowerShell
- A Minecraft profile/game directory containing normal folders such as `mods`, `config`, `logs`, `saves`, etc.
- Java/JDK diagnostic tools are optional. Without a compatible `jcmd.exe`, the compact export still works; JFR and live JVM snapshots are skipped.

## Quick start

1. Download or clone CraftProbe.
2. Run **`CraftProbe.cmd`**.
3. Choose a saved Minecraft profile, or add a new profile path. If CraftProbe was started from inside a Minecraft profile, it offers that profile first.
4. Choose the export target. The built-in default selects the profile, with ZIPs automatically redirected into its `_CraftProbe-Exports` subfolder. Saved export paths can also be selected.
5. Start Minecraft with your normal launcher **or leave it running if it is already open**. CraftProbe will attach to an existing matching JVM when possible.
6. Reproduce the issue or play the test scenario.
7. Optional: press **`E`** in the CraftProbe window when something suspicious happens. It may be pressed slightly before or after the visible issue.
8. Close Minecraft normally. Force-closing still leaves recovery data where possible.
9. Wait for the export to finish.

The profile picker uses the normal Windows Explorer-style folder dialog with a visible breadcrumb/address bar, so a path can be navigated or pasted directly.

You can also drag a profile directory onto `CraftProbe.cmd` or launch it with a path:

```bat
CraftProbe.cmd "D:\Minecraft\Instances\MyPack"
```


## Run `craftprobe` from anywhere

CraftProbe 0.4.1 can install a small launcher into your **user PATH**. No administrator rights are required.

From the extracted CraftProbe folder, run once:

```bat
CraftProbe.cmd --install-path
```

Open a new terminal afterwards. You can then run:

```bat
craftprobe
```

from any directory. The PATH entry points to a stable shim under `%LOCALAPPDATA%\CraftProbe\bin`; reinstalling PATH from a newer CraftProbe release retargets that shim instead of adding another version-specific directory.

Useful commands:

```bat
craftprobe --settings
craftprobe --install-path
craftprobe --remove-path
craftprobe --help
```

### Starting from a Minecraft profile

If `craftprobe` is launched while the terminal is inside a Minecraft profile (or a nearby subdirectory such as `mods` or `config`), CraftProbe detects the profile and asks whether it should be used.

You can choose **not to be asked again for that profile**. CraftProbe remembers either:

- automatically use this profile when started from it, or
- ignore the current-directory suggestion for this profile and show the normal profile selector.

The remembered rule can be removed later with `craftprobe --settings` -> **Rules for startup folders**.

## Saved profile and export paths

CraftProbe 0.4.1 stores path preferences in `%LOCALAPPDATA%\CraftProbe\settings.json`, so they survive CraftProbe updates.

At startup:

- saved Minecraft profiles are shown as a numbered list
- one profile can be marked as the default; pressing Enter selects it
- `N` adds a new path
- `V` opens path management, where saved paths can be removed or another default can be selected
- new paths ask whether they should be saved and whether they should become the default
- the export target defaults to the selected Minecraft profile directory itself
- additional export directories can be saved and selected in the same way

The settings file contains only local folder paths and CraftProbe path preferences.

## Launcher support

CraftProbe identifies the actual Minecraft game directory instead of requiring one launcher's metadata file. It is designed to work with layouts used by:

- CurseForge
- PrismLauncher / MultiMC
- Modrinth App
- other launchers that use a normal Minecraft game directory

For Prism/MultiMC, selecting either the instance directory or its `.minecraft` directory is supported.

## Compact Session archive

The Session archive is the file to share first for most investigations. It contains, among other things:

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
- `STALL_GROUPS.tsv`
- `CAPTURE_STATUS.json`
- `mods.csv` with per-mod SHA-256/hash status
- `log-context/` excerpts around detected events
- compact server-thread excerpts for verified stalls

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

CraftProbe uses a bounded rolling JFR recording so long sessions do not grow without limit. Important early-session periods are preserved separately:

- startup / main-menu phase
- world entry
- world entry + first chunk generation

This keeps early problems from being overwritten by later gameplay.

## Stall detection

A silent `latest.log` alone is **not** considered a stall. CraftProbe tries to distinguish normal server waiting (`waitUntilNextTick`, `waitForTasks`, parked/waiting threads) from a server thread that is actually blocked or busy.

Strong watchdog or severe `Can't keep up!` messages can trigger a capture directly. Heuristic stalls require repeated active server-thread samples, and similar events are deduplicated.

## Privacy

CraftProbe redacts common Minecraft authentication arguments/tokens from the captured Java command line. Nevertheless, always inspect archives before publishing them publicly: Minecraft/mod logs can contain usernames, server addresses, file paths or mod-specific secrets.

See [docs/DATA-COLLECTION.md](docs/DATA-COLLECTION.md) for details.

## Repository layout

```text
.
├─ CraftProbe.cmd
├─ LICENSE
├─ src/
│  ├─ Minecraft-Diagnose-Recorder.ps1
│  ├─ CraftProbe-Settings.ps1
│  └─ Export-Minecraft-Session-Analyse.ps1
├─ docs/
│  ├─ DATA-COLLECTION.md
│  ├─ README-DE.md
│  ├─ RELEASING.md
│  └─ TESTING.md
└─ .github/
   └─ ISSUE_TEMPLATE/
```

The internal PowerShell filename `Minecraft-Diagnose-Recorder.ps1` is intentionally retained; the public launcher and project name are CraftProbe.

## Current scope

This release is Windows-focused. The scripts use Windows process/CIM APIs and `cmd.exe`. Linux/macOS support would require a separate process-discovery and launcher layer.

## License

CraftProbe is released under the [MIT License](LICENSE).

### Export reliability

v0.3.2 introduced recorder-provided session boundaries and verified ZIP creation. v0.4.0 extends this with capture-health reporting, optional `latest.log` during recorder runs, validated JFR artifacts and verified mod hashing.

### v0.6.2 — Konsole navigieren

In **Konsole** gibt es vertikales und horizontales Scrollen (lange Zeilen werden nicht umgebrochen). **Auto-Follow** folgt neuen Logs nur, wenn du am Ende bist; beim Hochscrollen bleibt die Leseposition stehen. **Ganz nach unten** aktiviert Auto-Follow wieder. In der Textansicht funktioniert auch **Strg+End**. Siehe `docs/GAME-CONSOLE.md`.
