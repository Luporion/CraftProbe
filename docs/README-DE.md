# CraftProbe – Kurzanleitung (Deutsch)

## Benutzung

1. `CraftProbe.cmd` starten.
2. Minecraft-Profil auswählen, falls es nicht automatisch erkannt wird. Der neue Dialog besitzt die normale Explorer-Adress-/Breadcrumb-Leiste; Pfade lassen sich dort direkt eingeben bzw. einfügen.
3. Minecraft ganz normal mit dem eigenen Launcher starten.
4. Welt laden/erstellen und den Test durchführen.
5. Optional `E` drücken, wenn ein Fehler oder verdächtiger Zustand auffällt. Das darf auch etwas zu früh oder zu spät passieren.
6. Minecraft normal schließen.
7. Warten, bis der Export abgeschlossen ist.

## Ergebnis

### `Session-Analyse.zip`
Die kompakte Standarddiagnose für fast alle Fälle. Sie enthält u. a. `latest.log`, relevante Logs, Configs, Modliste/Hashes, Crashreports, JVM-Metadaten, `DIAGNOSE_SUMMARY.txt`, Timeline und kompakte Stall-Informationen.

### `Performance-Diagnose.zip`
Nur bei Performanceproblemen nötig. Enthält große JFR-Aufzeichnungen und vollständige Stall-/Incident-Thread-Dumps.

In `DIAGNOSE_SUMMARY.txt` steht, ob die Performance-ZIP empfohlen wird.

## Portable Version

CraftProbe hat keine festen Laufwerke, Benutzer-, Profil- oder Java-Pfade. Es versucht das ausgewählte Profil und eine zur laufenden Minecraft-Java-Version passende JDK-Version automatisch zu erkennen.

Unterstützt werden typische Profilstrukturen von CurseForge, Prism/MultiMC, Modrinth App und anderen Launchern.
