# Project State — v0.6.3

CraftProbe v0.6.3 dev preview basiert auf v0.6.2 (funktionierende Scrollbars + Testbericht) und fuegt die opt-in **Singleplayer-Companion-Befehle** ueber dateibasierte IPC hinzu. Windows-Recorder/Exporter, Linux-Agent, Profile und RCON bleiben erhalten. `docs/COMPANION.md` ist die verbindliche Anleitung.

**Validierung**: Reines Java-21-Protokoll kompiliert und bestanden, ZIP/Version/Bestand geprueft. Ungetestet: echter NeoForge-Modbuild (Gradle offline), .NET-10-Build/TUI und realer Minecraft-Befehl. Vor Release unter Windows das bestehende ConsoleTests-Projekt und NeoForge-Mod bauen und in `Rogler Alpha DEV` pruefen.

# Current project state

CraftProbe v0.6.2 development preview: Windows TUI game-console vertical/horizontal scrolling, bounded log history, auto-follow/preserve-position, and jump-to-bottom. Linux agent from v0.6.0 is unchanged. Compile/validate Terminal.Gui 2.5.0 on Windows and run the ConsoleTests before release.

# CraftProbe status — v0.6.1

Windows-Fokus: neuer TUI-Tab **Konsole** mit begrenztem inkrementellen Logtail, Filtern, Pause, Log-Export und Incident-Markierung. Optionaler direkter RCON-Client für **dedizierte Server**; keine Client-Befehle ohne Companion-Mod. RCON-Secret nur im Prozess-Environment, Remote-Ziele standardmäßig gesperrt; keine Crafty-API angebunden.

Validation: .NET console tests in `tests/CraftProbe.ConsoleTests` + CI; Windows Build und realer Minecraft/RCON-Test auf Zielrechner noch offen.

# CraftProbe status — v0.6.0

Stable basis: v0.5.2 Windows PowerShell recorder + .NET 10 Terminal.Gui 2.5.0 interface.

v0.6.0 adds first Linux support: headless Python 3.10+ agent and shared Terminal.Gui TUI. Crafty starts Minecraft independently; CraftProbe attaches using Linux `/proc` and JDK tools. Default Linux output `<server>/_CraftProbe-Exports`. Both platforms emit the same JSONL UI events and ZIP names.

Tests: `python3 -m unittest discover -s tests -v`; real Java test: `CRAFTPROBE_JAVA_INTEGRATION=1 python3 -m unittest discover -s tests -v`. JFR integration is tested against a mock long-running Java 21 process; not yet proven with a production NeoForge server or Docker Crafty setup. .NET Terminal.Gui Linux compilation requires dotnet 10 and NuGet access, unavailable in the authoring environment.

Open next: Linux TUI real-world test; Crafty Docker vs direct Linux/LXC install; permissions; linux service restart after successful session; Crafty console/RCON; native server MSPT profiling.

Do not remove Windows v0.5.2 code or claim it was fully ported to C#. Avoid committing bin/obj/JFR/session ZIPs. Preserve version docs and perform regression tests for paths with spaces, java -version false positives, and missing JFR.
