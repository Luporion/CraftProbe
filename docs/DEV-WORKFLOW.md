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

## Hotfix v0.6.4.1 nach v0.6.4

Der erste v0.6.4-Download des Wrapper-JARs lieferte HTTP 404. Hotfix v0.6.4.1 versucht zuerst die Datei aus dem offiziellen, versionierten Gradle-GitHub-Repository und validiert weiterhin die offizielle SHA-256-Pruefsumme.

Auf dem lokalen `dev/v0.6.4`-Branch ist die importierte `CraftProbe-v0.6.4.patch` aus dem v0.6.3-Basiscommit bereits **getrackt**. Ausserdem wurden im Basiscommit versehentlich `tests/CraftProbe.ConsoleTests/bin` und `obj` mitcommittet. Vor `git am` die lokale Arbeitskopie pruefen und uncommittete Buildaenderungen ggf. mit `git stash push` sichern. Nach dem Patch die genannten Pfade mit `git rm --cached` aus Git entfernen (aber lokal behalten). Erst danach erneut bauen und committen.

```powershell
# Ausgehend von dev/v0.6.4, nach Sicherung eigener uncommitteter Aenderungen
# .patch-Datei in den Repo-Ordner kopieren
 git am --3way .\CraftProbe-v0.6.4.1.patch
 git rm --cached -r --ignore-unmatch tests/CraftProbe.ConsoleTests/bin tests/CraftProbe.ConsoleTests/obj CraftProbe-v0.6.4.patch
 git commit -m 'chore: stop tracking generated test files and downloaded patch'
 .\CraftProbe.cmd --build-companion
```

Der Git-Mail-Patch erzeugt den v0.6.4.1-Code-Commit automatisch. Nicht zusaetzlich `git commit` fuer denselben Patch ausfuehren. Wenn du eigene Aenderungen gestasht hast, erst nach Tests `git stash list` pruefen und die Aenderungen selektiv wiederherstellen.
