# CraftProbe v0.4.1 regression test checklist

Run at least one normal session before publishing the release.

## Required smoke test

1. Use a Minecraft profile whose path contains at least one space (for example `My Pack DEV`).
2. Start `CraftProbe.cmd` using the normal Windows PowerShell 5.1 launcher and launch Minecraft normally.
   - Leave the recorder running for at least 30 seconds before pressing `E`; it must not abort with `Argument types do not match`.
3. Reach the main menu, enter a world, generate some new chunks and keep the game open for at least two minutes after world entry.
4. Press `E` once during gameplay and keep Minecraft running for at least another 20 seconds.
5. Close Minecraft normally.
6. Confirm both export ZIPs are created when JFR/JVM tools are available.

## Check Session-Analyse.zip

- `DIAGNOSE_SUMMARY.txt` exists.
- `CAPTURE_STATUS.json` exists.
- `mods.csv` exists.
- Mod hashes show `HashStatus=OK` for readable JARs; no blanket `HASH_ERROR` result.
- `TIMELINE.tsv` uses ISO timestamps.
- `STALL_EVENTS.tsv` contains a `PHASE` column.
- `STALL_GROUPS.tsv` exists.
- If an incident was marked, `log-context/INCIDENT-0001_latest.log.txt` exists.

## Check Performance-Diagnose.zip

When compatible JDK tooling is available:

- startup JFR exists and is non-empty;
- world-entry JFR exists and is non-empty;
- world-entry +90s JFR exists after a long enough world session;
- final/rolling JFR exists;
- JFR validation text files do not report `INVALID`;
- `INCIDENT-0001` contains immediate, +5s and +15s thread evidence when the game stayed alive long enough.

## Failure/force-close test

Optional but recommended: repeat a short run and kill Minecraft from the launcher/task manager. CraftProbe should still retain the latest valid rolling safeguard JFR where possible and must never report a missing/invalid artifact as `OK`.

## Capture-health rule

A release is not ready if `CAPTURE_STATUS.json` says `OK` while an expected JFR artifact is missing/empty or mod hashing failed.

### Launcher Java probe regression

1. Start CraftProbe and select an instance whose launcher validates Java before launch (CurseForge is a known example).
2. Start Minecraft from the launcher.
3. Confirm CraftProbe does **not** attach to a command line ending in `javaw.exe -version` / `java.exe -version`.
4. Confirm the selected process command line contains a real Minecraft identity such as `--gameDir`, `BootstrapLauncher`, `net.minecraft.client.main.Main`, or the selected profile path.
5. Leave the game running for at least 30 seconds and verify CraftProbe stays in recording mode.


## Late-attach regression tests (v0.4.1)

1. Start Minecraft first, wait until the main menu, then start `craftprobe`. Verify CraftProbe immediately finds the existing JVM and prints Minecraft start, CraftProbe start, attach time and a positive time difference.
2. Enter a world before starting CraftProbe. Verify startup/world-entry JFR states are `NOT_CAPTURED_LATE_ATTACH`, while final rolling JFR after attach is still valid.
3. Start CraftProbe while Minecraft is still loading. If startup/world entry occurs after attach, verify those later milestones can still be captured normally.
4. Run two matching Minecraft JVMs for the same selected profile and verify CraftProbe presents a PID choice rather than silently picking one.
5. Start CraftProbe first and then Minecraft. Verify normal pre-launch behavior is unchanged and `late_attach` is false.
6. Confirm `TIMELINE.tsv`, `_SESSION.txt`, `_END.txt`, `DIAGNOSE_SUMMARY.txt` and `CAPTURE_STATUS.json` all agree on the start/attach times.


## Late attach / DateTime.MinValue regression

1. Start Minecraft before CraftProbe and leave it running in the main menu or world-creation screen.
2. Start `craftprobe` and select that profile.
3. CraftProbe must attach to the existing JVM without `ArgumentOutOfRangeException`.
4. The terminal must show Minecraft start time, CraftProbe start time, and the late-attach time difference.


### CraftProbe v0.5.0 TUI

Die grafische Terminaloberflaeche ist optional und benoetigt fuer den einmaligen Build ein .NET 10 SDK (`CraftProbe.cmd --build-tui`). Das Skript `Minecraft-Diagnose-Recorder.ps1` bleibt erhalten, die CLI ist mit `craftprobe --cli` erreichbar. Das TUI sendet `incident`-Kommandos ueber lokale Dateien, keine Netzwerkschnittstelle. Vor einem Release bitte auf Windows pruefen: Profilwahl, Late Attach, laufende Aufnahme, Alt+E, normaler Minecraft-Exit, Erfolg/Fehlschlag beim ZIP-Export und Fallback ohne EXE.
