# Kurzanleitung (Deutsch)

## Benutzung

1. `Start-Diagnose.cmd` starten.
2. Minecraft-Profil auswählen, falls es nicht automatisch erkannt wird.
3. Minecraft ganz normal mit dem eigenen Launcher starten.
4. Welt laden/erstellen und den Test durchführen.
5. Optional `E` drücken, wenn ein Fehler oder verdächtiger Zustand auffällt.
6. Minecraft normal schließen.
7. Warten, bis der Export abgeschlossen ist.

## Ergebnis

### `Session-Analyse.zip`
Die kompakte Standarddiagnose für fast alle Fälle. Sie enthält u. a. `latest.log`, relevante Logs, Configs, Modliste/Hashes, Crashreports, JVM-Metadaten, `DIAGNOSE_SUMMARY.txt`, Timeline und kompakte Stall-Informationen.

### `Performance-Diagnose.zip`
Nur bei Performanceproblemen nötig. Enthält große JFR-Aufzeichnungen und vollständige Stall-/Incident-Thread-Dumps.

In `DIAGNOSE_SUMMARY.txt` steht, ob die Performance-ZIP empfohlen wird.

## Portable Version

Diese Repository-Version hat keine festen Pfade wie `G:\...`, keinen festen Profilnamen und keinen festen Java/JDK-Pfad. Sie versucht das ausgewählte Profil und eine zum laufenden Minecraft passende JDK-Version automatisch zu erkennen.

Unterstützt werden typische Profilstrukturen von CurseForge, Prism/MultiMC, Modrinth App und anderen Launchern.
