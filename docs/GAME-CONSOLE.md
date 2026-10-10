# CraftProbe v0.6.3 — Game-Konsole

## 1. Minecraft-Client (Singleplayer / CurseForge)

In der TUI **Konsole** öffnen. CraftProbe liest `<Profil>/logs/latest.log` inkrementell, auch wenn die Aufnahme nicht gestartet wurde oder Minecraft bereits läuft. Das ändert nichts am Spielprozess. Große Logs werden **nicht vollständig eingelesen**: maximal 512 KiB beim ersten Öffnen, 256 KiB pro Aktualisierung, höchstens 1200 Zeilen im Puffer. Das verhindert Einfrieren der TUI bei großen Modpacks.

- **Scrollleisten**: rechts vertikal durch die letzten maximal 1200 Zeilen, unten horizontal für sehr lange Zeilen. Zeilenumbruch ist bewusst deaktiviert; maximal 4096 Zeichen pro Zeile werden für die Anzeige gespeichert (die Original-Logdatei bleibt unverändert).
- **Auto-Follow**: folgt den neusten Zeilen solange du unten bist. Scrollst du mit dem Mausrad, der Tastatur oder der Leiste hoch, bleibt deine Position beim nächsten Log-Update erhalten. Scrollst du wieder ans Ende, wird Auto-Follow erneut aktiviert.
- **Ganz nach unten**: springt sofort zu den jüngsten Logzeilen und aktiviert Auto-Follow. **Strg+End** bewegt den Fokus/Cursor von TextView ans Textende; die Scrollleiste folgt. **End** bewegt den Cursor zum Zeilenende.
- **Suchen**: Groß-/Kleinschreibung wird ignoriert.
- **Filter**: Alle / Warnungen + Fehler / Nur Fehler.
- **Pause / Weiter**: pausiert nur die Loganzeige, nicht Minecraft und nicht die Diagnose.
- **Aktualisieren**: liest wieder aktuelle Logzeilen.
- **Auszug speichern**: speichert die derzeit gepufferten Zeilen nach Filter als TXT unter `<Profil>/_CraftProbe-Exports/log-snippets/`. Vermeide die Weitergabe von Logs mit privaten Angaben.
- **Incident**: während laufender Aufnahme dieselbe manuelle Diagnose wie auf dem Aufnahmebildschirm.
- **Warnungen/Fehler**: Zähler seit Öffnen beziehungsweise Profilwechsel; historischer Anfangspuffer kann enthalten sein. Keine absoluten Sessionzähler.

**Ohne Companion keine direkte Befehlsausfuehrung im Client:** Eine normale Java-Minecraft-Client-JVM bietet keine interaktive stdin-Konsole wie ein Dedicated Server. `latest.log` ist eine Ausgabedatei und kein Befehlskanal. Die Befehlszeile auf dem Konsole-Tab ist **ausschließlich für RCON** bei dedizierten Servern. Es werden keine Tastendrücke in das Spielfenster injiziert. Für echte Singleplayer-Befehle braucht es später eine gesonderte, explizit autorisierte Companion-Mod.

## 2. Dedizierter Minecraft-Server: RCON

In `server.properties` (oder über den Servermanager) bewusst aktivieren:

```properties
enable-rcon=true
rcon.port=25575
rcon.password=EIN_LANGES_ZUFAELLIGES_PASSWORT
```

Server neu starten. Am **gleichen** Rechner wie der Server in einem neuen PowerShell-Fenster:

```powershell
$env:CRAFTPROBE_RCON_PASSWORD = 'DEIN_PASSWORT'
craftprobe
```

Im Tab **Konsole** als RCON-Host `127.0.0.1:25575` eintragen, Befehle z. B. `list` oder `say Test` eingeben und **Senden** drücken. Ein führender Slash wird entfernt. Das Passwort wird **nicht** in Settings oder in eine Diagnose-ZIP geschrieben. Einmalige Umgebungsvariablen gelten nur für das laufende Terminalfenster/Prozess und müssen nach einem Neustart erneut gesetzt werden.

**Sicherheit:** RCON überträgt Passwörter und Befehle unverschlüsselt. CraftProbe erlaubt standardmäßig ausschließlich `localhost`/`127.0.0.1`/`::1`. Für einen entfernten Server ist ein SSH-Tunnel auf `127.0.0.1:25575` die empfohlene Lösung. Das bewusste Ausnahmeschalten über `CRAFTPROBE_RCON_ALLOW_REMOTE=1` wird nicht empfohlen und sollte nur in einem vertrauenswürdigen abgeschotteten Netzwerk erfolgen. **RCON niemals ins öffentliche Internet freigeben!**

RCON ist eine **optionale Serverfunktion**, unabhängig vom CraftProbe-Recorder. Sie benötigt keinen Linux-Agenten und keinen Crafty-API-Zugriff. Bei Crafty verwaltet Crafty den Server weiterhin; der RCON-Port muss explizit aktiviert und lokal erreichbar sein. Die Kommandos haben die Rechte der Serverkonsole: nur auf vertrauenswürdigen Rechnern verwenden.

### Grenzen

- Die Loganzeige liest zunächst die lokale `latest.log` im ausgewählten Profil. Remote-RCON spiegelt noch **keine** Server-Logs in die lokale Live-Log-Ansicht.
- Die aktuelle RCON-Implementierung liest eine Textantwort; sehr lange Server-Antworten können vom RCON-Protokoll auf mehrere Pakete verteilt werden. Vollständige mehrteilige Antworten sind eine spätere Erweiterung.
- Ein Server muss selbst RCON unterstützen und konfiguriert haben. Ohne RCON/Companion-Mod sind keine Befehle an den Client möglich.

## Test

```powershell
.\CraftProbe.cmd --build-tui
.\CraftProbe.cmd
```

Oder für die Protokolltests (.NET 10 SDK):

```powershell
dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj
```

Die Tests enthalten einen lokalen RCON-Testserver (Mock), führen **keinen** Befehl auf einem echten Minecraft-Server aus und testen Logtailing, Rotation, Teilzeilen, Suche, Filter und Default-Sperre für Remote-RCON.

### v0.6.2-Testmatrix

1. Ein Log mit mehr als 180 Zeilen starten: vertikale Scrollleiste und ältere Zeilen müssen erreichbar sein (bis 1200).
2. Eine lange Zeile aufrufen: mit horizontaler Scrollleiste den rechten Teil anzeigen; der Text darf nicht automatisch umbrechen.
3. Zum Logende gehen und neue Zeilen erzeugen: Auto-Follow springt zu den neuen Zeilen.
4. Mit dem Mausrad hochscrollen, neue Zeilen erzeugen: die Leseposition darf nicht zum Ende springen.
5. **Ganz nach unten** drücken: Status **Auto-Follow AN**, nächste Logzeilen folgen wieder. Horizontalposition bleibt erhalten.
6. Filter/Suche, Pause/Weiter, RCON und Profilwechsel einmal testen.
7. Kleineres/größeres Terminalfenster und weiterschreiben: keine TUI-Ausnahme oder verloren gegangene Scrollleisten.

## Neuer Singleplayer-Companion-Modus (v0.6.3)

Siehe [`COMPANION.md`](COMPANION.md) fuer Installation, in-game `/craftprobe enable`, Freigabe, Limitierungen und Sicherheitsmodell. Das bisherige RCON bleibt erhalten.
