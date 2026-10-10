# CraftProbe v0.6.3 — Singleplayer command bridge

The Windows/Linux TUI receives recorder events independently of the new client-only bridge. Optional commands use one of two **separate** transports:

- `Singleplayer Companion`: `profile/.craftprobe-bridge/status.json` heartbeat, `requests/<uuid>.json` atomically written by TUI, `responses/<uuid>.json` written by the optional NeoForge client mod. In-game `/craftprobe enable` creates random per-world session/token; the mod only issues commands via the connected player's `sendCommand`, never as a privileged console. No ports or keystroke injection. Status is invalid after 10s; requests after 30s. Status `SENT` acknowledges dispatch only, not the outcome of the Minecraft command.
- `Server RCON`: separately configured authenticated local RCON over TCP; disabled when no password; no remote RCON unless explicitly overridden as documented.

Both preserve the existing log-viewer/recorder/zip code. The Linux agent is unchanged. The on-disk bridge is a local convenience channel, not a sandbox protecting against same-user malware; it must not be shared or included in diagnostic exports. See `docs/COMPANION.md`.

# CraftProbe v0.6.2 architecture

Der `ConsoleLogScrollState` ist ein UI-unabhängiger Zustandsautomat für Follow-Tail, manuelles Scrollen und das Beibehalten der Position bei Log-Buffer-Evictions. `TextView` mit `ScrollBars=true`, `WordWrap=false` und nativen v2-Viewport-Scrollbars zeigt bis zu 1200 gepufferte Zeilen und RCON-Antworten. Der Button „Ganz nach unten“ aktiviert Follow-Tail wieder; Maus-/Tastaturbewegungen vom Ende weg deaktivieren es. Die eigentlichen Recorder-/Export-Komponenten bleiben unverändert.

Der Terminal.Gui **Konsole**-Tab liest `logs/latest.log` direkt mit `MinecraftLogTail` (begrenztes Tail/inkrementell). Er ist unabhängig vom Recorder und schreibt niemals in die Minecraft-JVM. Nur optional `MinecraftRcon` öffnet eine authentifizierte TCP-Verbindung zu einem RCON-fähigen **Dedicated Server**. Die bestehende JSONL-IPC zum PowerShell-Recorder/Linux-Agenten und die ZIP-Logik bleiben unverändert.

# CraftProbe v0.6.0 architecture

## One repository, two platform backends, shared UI/event contract

```text
Terminal.Gui (.NET 10; Windows + Linux)
    |  events.jsonl / commands.txt / session-context.json
    +-- Windows: src/Minecraft-Diagnose-Recorder.ps1 (existing PowerShell)
    |             src/Export-Minecraft-Session-Analyse.ps1
    +-- Linux:   linux/craftprobe_agent.py (Python 3.10+ standard library)
                        | /proc PID/cwd/cmdline/start
                        | jcmd / jfr
                        + logs, SHA256 inventory, config export, ZIPs
```

The CLI can run **without** the UI on either platform. The Linux agent never launches or controls Minecraft; Crafty retains process ownership. A future C# common core may replace both platform backends, but this release does not claim that port has occurred.

## IPC contract

Event file: append-only UTF-8 JSONL. Example:

```json
{"timestamp":"2026-10-09T14:22:31.122+02:00","type":"minecraft","message":"Minecraft-Server verbunden","detail":"PID 4451 | Attach +60s","step":0}
```

Types consumed by the TUI: `starting`, `waiting`, `minecraft`, `jfr`, `jfr_snapshot`, `warning`, `stall`, `incident`, `stopped`, `export`, `completed`, `error`. Export uses `step` in 1..4, sequence JFR → finalize → collect → ZIP.

Command file: append-only newline-terminated `incident`/`e`; optional `stop` on Linux. Context file: JSON object with `notes`. The Linux agent preserves arbitrary UI context only as user evidence, separate from machine-observed events.

## Linux JVM detection and identity

Enumerate `/proc/[pid]/cmdline`, match Java process and Minecraft launch signatures, correlate `/proc/[pid]/cwd` or explicit game/profile paths, reject probes such as `java -version`. Preserve PID **and `/proc/[pid]/stat` start tick count** to guard against PID reuse. Processes for the same profile need an explicit `--pid` when ambiguous.

## Limitations and future work

- Agent uses platform-specific backends rather than a shared C# diagnostic kernel.
- Linux log-based stall detection does not replace JVM CPU profiling and cannot detect every stall.
- Crafty API integration and remote UI remain future work. v0.6.1 provides an independent RCON client for dedicated servers, but no Crafty API.
- .NET TUI requires a platform-specific build; the portable source ZIP is not precompiled.
