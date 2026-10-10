## v0.6.1 console regression tests

- Windows: `dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj` und `CraftProbe.cmd --build-tui`.
- TUI: Konsole-Tab öffnen, `latest.log` initial und bei neuen Logzeilen prüfen, Suchwort/Schweregradfilter, Pause/Weiter, TXT-Export im Unterordner.
- Aufnahme aktiv: Incident aus Konsole markieren, Aufnahmeende/ZIP/Timer verifizieren.
- RCON: lokalen Testserver oder bewusst eingerichteten Dedicated Server auf `127.0.0.1:25575` verwenden; Passwort nur via Umgebungsvariable. Passwortfehler, RCON aus, Netzwerkfehler und Default-Remote-Sperre prüfen.
- **Keine Singleplayer-Befehle erwarten**: ohne Companion-Mod ist die Konsole im Client nur lesend.
- Linux-Agent-Regression: `python3 -m unittest discover -s tests -v`.

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

## v0.5.1 Tests vor Release (P0)

1. `CraftProbe.cmd --build-tui` auf Windows + .NET SDK 10 kompilieren. Danach `CraftProbe.cmd` starten. `--cli` muss weiterhin funktionieren.
2. In **Aufnahme** ein gespeichertes Profil im `DropDownList` auswählen und mit F4 die Optionen öffnen. Alternativ absoluten Profilordner eintippen. Exportziel aus der Liste wählen oder manuell eingeben.
3. Exportziel auf Profilroot stellen. Es muss zu `<profil>\_CraftProbe-Exports` normalisiert werden; `*.zip` dürfen nicht direkt im Profilroot landen. Externes Ziel bleibt unverändert.
4. In den Session-Notizen vor dem Start einen Satz eingeben; dann Aufnahme starten. Während Minecraft läuft den Text ergänzen und **Notiz speichern** drücken. Nach Minecraft-Exit müssen `SESSION_CONTEXT.json` und der Inhalt in `DIAGNOSE_SUMMARY.txt` vorhanden sein.
5. In **Aufnahmen** den erzeugten ZIP-Paar-Eintrag sehen, auswählen und Explorer öffnen. Bereits vorher erzeugte ZIPs direkt im Profilroot müssen ebenfalls sichtbar bleiben.
6. Minecraft bereits gestartet: Zeitdifferenz zum CraftProbe-Start muss angezeigt und korrekt in Diagnosemetadaten erfasst werden.
7. Im Profilnamen `My Pack DEV` mit Leerzeichen JFR starten/dumpen; jede erzeugte Datei mit `jfr summary` prüfen. Windows-Prozessquoting allein ist unzureichend; `jcmd` benötigt für Dateipfade intern `filename="C:\Path With Spaces\file.jfr"`.
8. `E`-Incident, echter Stall, normaler Spiel-Exit und ZIP-Fertigstellung testen. Kein `OK`, wenn JFR-Artefakt fehlt oder unlesbar ist.
9. Nicht veröffentlichen, bevor die Windows-Build- und Laufzeittests erfolgreich durchgeführt wurden.

## v0.5.2 TUI regression tests (Windows / Terminal.Gui 2.5.0)

1. `CraftProbe.cmd --build-tui` with .NET SDK 10; run `CraftProbe.cmd` and confirm TUI v0.5.2 appears.
2. Start recording, launch Minecraft, keep it running for 30+ seconds. The timer advances while recording.
3. Close Minecraft normally. As soon as the `stopped` event arrives, the timer stops; status switches to `Export laeuft` without counting compression time.
4. Confirm four sequential, distinct live log events and the progress line: `[1/4] JFR sichern`, `[2/4] Recorder abschliessen`, `[3/4] Session-Daten sammeln`, `[4/4] ZIPs erstellen`.
5. After successful ZIP verification, the status is `FERTIG` and the timer remains fixed even after several minutes.
6. Repeat with Minecraft force-closed/crashed. The timer stops on game-process exit, even if compression takes minutes or the exporter fails.
7. Simulate an exporter error (e.g. unwritable export destination) and confirm TUI says `FEHLER`, never `FERTIG`. A zero exit code without an explicit completed event is also not treated as success.
8. The incident action becomes unavailable in export/completed/failed state; it remains usable during recording.
9. Start a second session from the same TUI instance. The elapsed duration, event counters, export stage and output are reset; no previous session state leaks.
10. Confirm standalone `craftprobe --cli` export still works with no UI event path.

Note: The TUI updates every ~450 ms; very short steps can pass before a redraw, but the chronological live-event log must retain each emitted stage.

## v0.6.2 — Game Console scrolling

- `dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj`: new pure-C# tests for scroll-state machine and long-line preservation (in addition to existing tail/RCON tests).
- `./CraftProbe.cmd --build-tui` and `./CraftProbe.cmd` in Windows Terminal: verify both visible scrollbars, auto-follow when the log grows, manual scrolling while new logs arrive, and the **Ganz nach unten** button.
- Verify no regression in search, severity filter, pause/resume, RCON local-only protections, incident button, and both recording ZIPs.
- UI interaction needs a real Terminal.Gui/Windows terminal; the standalone scroll state has no GUI dependency.

## v0.6.3 — Companion

- TUI baut mit .NET 10, ConsoleTests inklusive Companion-Testfaelle bestanden.
- Gradle-Companion-Mod baut unter Java 21 und NeoForge 21.1.249; Minecraft startet mit der JAR.
- Singleplayer vor `/craftprobe enable`: keine Befehle. Nach Freigabe `time set day`, `tp` nur bei Cheats/Berechtigung.
- Status wird nach 10s ohne JVM zu STALE; Weltenwechsel deaktiviert; Multiplayer verweigert.
- RCON bleibt funktionsfaehig.

## v0.6.4 — Verified Gradle wrapper / patch workflow

- Ohne globales Gradle: `CraftProbe.cmd --companion-doctor` (mit JDK 21) muss erfolgreich sein.
- `CraftProbe.cmd --build-companion`: Beim ersten Mal nur authentische Wrapper-JAR und Gradle-Distribution herunterladen. SHA-256 muss vor dem Ausfuehren stimmen.
- Mod-JAR aus `companion/NeoForge-1.21.1/build/libs` nur nach erfolgreichem Gradle-Build als benutzbar betrachten.
- GitHub Actions Companion-Build gegen dieselbe Wrapper-Version laufen lassen; Java/NeoForge-Kompatibilitaet unter Minecraft pruefen.
- Fehlerfall: Bei modifiziertem Wrapper-JAR muss der Build verweigert werden. Offline ohne Cache wird eine klare Netzwerkfehlermeldung erwartet.
- Git-Patch auf sauberem v0.6.3-Basisbranch via `git am --3way` anwenden. Gegenpruefen, dass Patch-Datei nicht versehentlich mitcommittet wurde. Overlay-ZIP muss nur geaenderte Dateien enthalten.
- `python3 -m unittest discover -s tests -v` und Java-Protokolltest aus docs/COMPANION.md ausfuehren.
