# CraftProbe v0.6.4 — Singleplayer-Befehle (NeoForge-Companion)

## Wichtig: Was geht jetzt?

Die **Minecraft-Client-Konsole** hat bisher nur `logs/latest.log` gelesen. RCON-Befehle funktionieren ausschliesslich bei konfigurierten dedizierten Servern. v0.6.3 fuegt eine **optionale Client-Mod fuer Minecraft 1.21.1 / NeoForge ab 21.1.249** hinzu, mit der die lokale TUI Befehle wie `/tp Luporion 0 0 0` an den Minecraft-Client senden kann.

**Nicht automatisch funktionsfaehig nach dem TUI-Update:** Die **Companion-JAR** muss erst gebaut und im **Client-Profil** installiert werden. Das ZIP enthaelt ihren Quellcode, keine kompilierte Mod. Ein echter NeoForge-Lauf wurde hier noch nicht verifiziert. Keine Aenderung an der Linux-Agentenbasis.

## Installation

1. **TUI neu bauen:** `./CraftProbe.cmd --build-tui`.
2. **Companion bauen:** JDK 21 mit `java` und `javac` muss im PATH bzw. JAVA_HOME liegen; ein globales `gradle` ist **nicht** erforderlich:

   ```powershell
   .\CraftProbe.cmd --companion-doctor
   .\CraftProbe.cmd --build-companion
   ```

   Der Wrapper ist auf **Gradle 8.14** festgelegt. Beim ersten Aufruf werden `gradle-wrapper.jar` (SHA-256 verifiziert) und anschliessend die Gradle-Binärdistribution (SHA-256 verifiziert) von Gradle heruntergeladen. Dafuer sind eine Internetverbindung und Zugriff auf `services.gradle.org` notwendig; NeoForge-Abhaengigkeiten werden separat durch Gradle aufgeloest. Danach koennen zwischengespeicherte Builds offline moeglich sein, sind aber nicht garantiert.

   Alternativ direkt aus `companion/NeoForge-1.21.1/` `./gradlew.bat build` (Windows) beziehungsweise `./gradlew build` (Linux) ausfuehren. Bei GitHub Actions `CraftProbe Companion build` ausloesen und das JAR-Artefakt herunterladen (nach Commit/Push).
3. Die resultierende `companion/NeoForge-1.21.1/build/libs/craftprobe_companion-0.6.4.jar` nach `Rogler Alpha DEV/mods/` kopieren. **Nicht auf den dedizierten Server installieren**; Client-only.
4. Minecraft neu starten. Eine Singleplayer-Welt betreten, die Cheats erlaubt. Im Minecraft-Chat **`/craftprobe enable`** eingeben. Die Freigabe gilt nur fuer die aktuelle Weltverbindung.
5. CraftProbe starten (oder schon vorher), Tab `Konsole`, Modus **Singleplayer Companion**. Warten auf Status **BEREIT**; z. B. `/tp Luporion 0 0 0` eingeben und **Senden**.
6. Im Spiel das Chatfeedback pruefen: Die TUI quittiert `SENT`, wenn der Client den Befehl abgesendet hat; das ist **keine bestaetigte Erfolgsmeldung**.
7. Bei Bedarf `/craftprobe disable` im Minecraft-Chat verwenden. Beim Verlassen der Welt wird die Freigabe automatisch zurueckgesetzt.

### Beispieltests

Im Singleplayer mit aktivierten Cheats:

```
/time set day
/weather clear
/tp Luporion 0 80 0
```

`/tp Luporion 0 0 0` funktioniert technisch ebenso, kann aber im Gestein oder Void enden. Fuer einen ungefaehrlicheren Test zuerst `0 80 0` verwenden.

Wenn **Cheats deaktiviert** sind, verweigert der integrierte Server entsprechende Befehle. Die Companion-Mod hebt Minecraft-Berechtigungen **nicht** auf und fuehrt **keine Befehle auf entfernten Multiplayer-Servern** aus. Die Spielerrechte sind die Grenze.

## Verbindung & Datenschutz

- Die Companion-Mod oeffnet **keinen Port**. Die TUI tauscht Nachrichten ueber `<Profil>/.craftprobe-bridge/` aus.
- `status.json` ist der Heartbeat (1s); er enthaelt Sessionkennung und zufaelliges Token. TUI vertraut nur frischen Statusdaten und sendet nach explizitem Opt-in.
- Anfragen werden unter `requests/` atomar geschrieben, Antworten unter `responses/` abgeholt. Status/Anfragen/Ausgaben gehoeren nicht in die Diagnose-ZIPs.
- Alle lokalen Programme mit vollem Zugriff auf dein Benutzerprofil koennen theoretisch IPC-Dateien lesen. Die Freigabe im Spiel begrenzt das Risiko, ist aber **kein Schutz gegen kompromittierte Programme mit denselben Benutzerrechten**. Kein freigegebener Ordner / Netzlaufwerk fuer die IPC verwenden.
- `/craftprobe disable` beendet die lokale Freigabe; sie gilt nicht weltuebergreifend. Requests sind zeitlich limitiert; die TUI zeigt `NOT_INSTALLED`, `DISABLED`, `NO_WORLD`, `STALE` oder `READY`.
- Die Antworten aus dem Companion sind zunaechst nur **Transportquittungen**, nicht exakte Brigadier-/Chat-Rueckgaben. Minecraft-Chatausgaben werden nicht vollstaendig in die TUI gespiegelt.

## Testen vor dem Release

```powershell
.\CraftProbe.cmd --build-tui
dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj
.\scripts\Build-Companion.ps1
```

Java-Protokolltest ohne NeoForge/Gradle (auf einem Rechner mit JDK 21, Beispiel Linux):

```bash
mkdir -p /tmp/craftprobe-protocol-test
javac -d /tmp/craftprobe-protocol-test companion/NeoForge-1.21.1/src/main/java/dev/craftprobe/companion/BridgeProtocol.java companion/NeoForge-1.21.1/src/test/java/dev/craftprobe/companion/BridgeProtocolTest.java
java -cp /tmp/craftprobe-protocol-test dev.craftprobe.companion.BridgeProtocolTest
```

Bei einem echten In-Game-Test verifizieren: `/craftprobe enable` ist registriert, `READY` erscheint, Befehl kommt an, `SENT`-Quittung erscheint, Spielerrechte bleiben wirksam, Verbindung nach Weltwechsel verloren, ohne Mod keine Eingabe.

## Server

Bei dedizierten Servern weiter `Server RCON` benutzen. Die Companion-Mod ist bewusst **nicht** fuer Crafty oder Linux-Server ausgelegt. Sie ist eine opt-in Clientfunktion.

## Troubleshooting (v0.6.4)

- **Gradle nicht im PATH:** Kein Fehler mehr; immer `CraftProbe.cmd --build-companion` verwenden.
- **JDK 21 fehlt:** Mit `CraftProbe.cmd --companion-doctor` pruefen, dann `JAVA_HOME` auf das JDK 21 setzen. Ein reines JRE reicht nicht.
- **Wrapper/Download fehlgeschlagen:** Netzwerk, Proxy und TLS-Zugriff auf `services.gradle.org` pruefen. Der Download wird nur nach erfolgreicher SHA-256-Pruefung verwendet.
- **NeoForge-Compilefehler:** Komplette Gradle-Ausgabe schicken. Die Gradle-Bereitstellung funktioniert dann bereits; ein Fehler im NeoForge-Quellcode ist davon getrennt zu diagnostizieren.
- **Gradle-Cache:** Download wird unter `%USERPROFILE%\.gradle\wrapper\dists` oder `~/.gradle/wrapper/dists` abgelegt. Nicht in die Git-ZIP aufnehmen.
