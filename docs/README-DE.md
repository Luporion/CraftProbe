## Neu in v0.4.1

CraftProbe kann jetzt auch **nach Minecraft** gestartet werden. Wenn fuer das gewaehlte Profil bereits eine passende Minecraft-JVM laeuft, haengt CraftProbe sich an diese Sitzung an.

Im Terminal und in der Diagnose werden Minecraft-Start, CraftProbe-Start, Anhaengezeit und die genaue Zeitdifferenz angezeigt. Daten vor dem Anhaengen koennen nicht rueckwirkend per JFR oder Thread-Dump erfasst werden. Bereits vergangene Startup-/World-Entry-Meilensteine werden deshalb ehrlich als `NOT_CAPTURED_LATE_ATTACH` markiert. Die weitere Rolling-JFR-, Stall- und `E`-Incident-Diagnose funktioniert ab dem Anhaengezeitpunkt normal.

# CraftProbe – Kurzanleitung (Deutsch)

## Neu in v0.4.0

- JFR/jcmd funktioniert robust auch bei Profilpfaden mit Leerzeichen.
- JFR-Dateien werden nach dem Schreiben validiert.
- `CAPTURE_STATUS.json` zeigt sofort, ob die Diagnose vollstaendig, eingeschraenkt oder degradiert ist.
- Mod-Hashes werden per SHA-256 direkt gelesen; Fehler stehen einzeln in `mods.csv`.
- Recorder-Sessions koennen auch ohne `latest.log` exportiert werden.
- Stalls/Incidents erhalten eindeutige IDs, Phasen und passende Log-Ausschnitte.
- `E` sammelt jetzt ein Zeitfenster (sofort, +5 s, +15 s) statt nur einen einzelnen Moment.


## Benutzung

1. `CraftProbe.cmd` starten.
2. Ein gespeichertes Minecraft-Profil auswählen oder mit `N` einen neuen Profilpfad hinzufügen.
3. Exportziel auswählen. Standard ist der Minecraft-Profilordner selbst.
4. Minecraft ganz normal mit dem eigenen Launcher starten.
5. Welt laden/erstellen und den Test durchführen.
6. Optional `E` drücken, wenn ein Fehler oder verdächtiger Zustand auffällt. Das darf auch etwas zu früh oder zu spät passieren.
7. Minecraft normal schließen.
8. Warten, bis der Export abgeschlossen ist.

## Gespeicherte Pfade

CraftProbe speichert Profil- und Exportpfade unter `%LOCALAPPDATA%\CraftProbe\settings.json`.

- `Enter` nimmt den markierten Standardpfad.
- `N` fügt einen neuen Pfad hinzu.
- Bei neuen Pfaden fragt CraftProbe, ob der Pfad gespeichert und ob er als Standard gesetzt werden soll.
- `V` öffnet die Verwaltung. Dort können gespeicherte Pfade entfernt oder andere Standards gesetzt werden.
- Beim Export ist der Profilordner selbst der eingebaute Standard. Eigene Exportordner können zusätzlich gespeichert werden.

## Ergebnis

### `Session-Analyse.zip`
Die kompakte Standarddiagnose für fast alle Fälle. Sie enthält u. a. `latest.log`, relevante Logs, Configs, Modliste/Hashes, Crashreports, JVM-Metadaten, `DIAGNOSE_SUMMARY.txt`, Timeline und kompakte Stall-Informationen.

### `Performance-Diagnose.zip`
Nur bei Performanceproblemen nötig. Enthält große JFR-Aufzeichnungen und vollständige Stall-/Incident-Thread-Dumps.

In `DIAGNOSE_SUMMARY.txt` steht, ob die Performance-ZIP empfohlen wird.

## Portable Version

CraftProbe hat keine festen Laufwerke, Benutzer-, Profil- oder Java-Pfade. Es versucht das ausgewählte Profil und eine zur laufenden Minecraft-Java-Version passende JDK-Version automatisch zu erkennen.

Unterstützt werden typische Profilstrukturen von CurseForge, Prism/MultiMC, Modrinth App und anderen Launchern.


## CraftProbe ueberall mit `craftprobe` starten

Einmal im entpackten CraftProbe-Ordner ausfuehren:

```bat
CraftProbe.cmd --install-path
```

Danach ein neues Terminal oeffnen. Ab dann funktioniert `craftprobe` aus jedem Ordner. Mit `craftprobe --settings` kannst du PATH, gespeicherte Profil-/Exportpfade und Regeln fuer erkannte Profilordner verwalten.

Wenn du `craftprobe` direkt in einem Minecraft-Profil oder z. B. in dessen `mods`-/`config`-Ordner startest, erkennt CraftProbe das Profil automatisch und bietet es an. Die Auswahl kann mit **nicht nochmal fragen** pro Profil gemerkt und spaeter in den Einstellungen wieder entfernt werden.


### CraftProbe v0.5.0 TUI

Die grafische Terminaloberflaeche ist optional und benoetigt fuer den einmaligen Build ein .NET 10 SDK (`CraftProbe.cmd --build-tui`). Das Skript `Minecraft-Diagnose-Recorder.ps1` bleibt erhalten, die CLI ist mit `craftprobe --cli` erreichbar. Das TUI sendet `incident`-Kommandos ueber lokale Dateien, keine Netzwerkschnittstelle. Vor einem Release bitte auf Windows pruefen: Profilwahl, Late Attach, laufende Aufnahme, Alt+E, normaler Minecraft-Exit, Erfolg/Fehlschlag beim ZIP-Export und Fallback ohne EXE.
