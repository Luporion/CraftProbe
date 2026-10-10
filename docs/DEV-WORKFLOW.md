# CraftProbe DEV-Workflow (ab v0.6.4)

Jeder Versionsstand wird mit einem vollstaendigen Quell-ZIP und einem Patch geliefert:

- `CraftProbe-vX.Y.Z.zip`: gesamtes Repository ohne `.git`, lokale Build-Caches, Welt und Diagnosearchive.
- `CraftProbe-vX.Y.Z.patch`: **Git-Mail-Patch** vom unmittelbar vorherigen Basisstand. Wird per `git am --3way` angewandt und erzeugt einen Commit.
- `CraftProbe-vX.Y.Z-overlay.zip`: nur geaenderte/neu hinzugefuegte Dateien mit unveraenderter Ordnerstruktur zum Ueberschreiben (fuer manuelle Nutzung, kein Git-History-Commit).
- SHA-256-Pruefsummen fuer Downloads.

## Erstmalige Umstellung: v0.6.3 nach v0.6.4

**Vorbedingung:** `develop` enthaelt den vollstaendigen **v0.6.3-Quellstand**. Eigene Aenderungen zuerst pruefen und committen, sonst `git am` nicht starten. Insbesondere Builds/Caches/Zugangsdaten nicht stagen.

```powershell
cd E:\OneDrive\Entwicklung\Minecraft\CraftProbe
git switch develop
git status
# Nur falls noch nicht committete v0.6.3-Aenderungen vorliegen:
git add -A
git diff --cached --stat
git commit -m "WIP: CraftProbe v0.6.3 baseline"
git push origin develop
# v0.6.4 in eigenem Branch testen:
git switch -c dev/v0.6.4
# .patch-Datei in das Repository-Stammverzeichnis kopieren:
git am --3way .\CraftProbe-v0.6.4.patch
# Download-Patch nach erfolgreicher Anwendung entfernen:
Remove-Item .\CraftProbe-v0.6.4.patch
```

**Wichtig:** `git am` erzeugt bereits den Commit. Nicht noch einmal dieselben Dateien committen. Wenn der Patch nicht zur Basis passt, **nicht** das Overlay-ZIP zusaetzlich darueberkopieren. Erst `git am --abort` und den Versionsstand vergleichen.

## Testen

```powershell
.\CraftProbe.cmd --build-tui
dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj
.\CraftProbe.cmd --companion-doctor
.\CraftProbe.cmd --build-companion
```

Der erste Companion-Build laedt verifiziert Gradle herunter und braucht Internet; fuer JDK 21 `java -version` und `javac -version` pruefen. Die erfolgreiche TUI und die NeoForge-Companion-JAR im Spiel separat validieren.

```powershell
git status
git log -1 --oneline
git push -u origin dev/v0.6.4
```

Die Uebernahme von `dev/v0.6.4` nach `develop` erfolgt nach erfolgreichen Tests per PR oder `git merge --no-ff dev/v0.6.4` auf `develop`, mit anschliessendem Push. `main` und Release-Tag erst nach einer stabilen, getesteten Freigabe aktualisieren.

## Alternative: Overlay ohne Git-Patch

`CraftProbe-v0.6.4-overlay.zip` im Repository entpacken und bestehende Dateien ueberschreiben. Danach `git diff`, `git add -A`, `git diff --cached --stat`, `git commit -m "CraftProbe v0.6.4"`, `git push`. **Nicht** gleichzeitig `git am` und das Overlay anwenden. Das Overlay eignet sich nur, wenn der Quellstand der vorausgesetzten Basisversion entspricht.
