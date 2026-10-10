# Linux and Crafty Controller — CraftProbe v0.6.0

## Supported in this first Linux release

- Running Minecraft server is launched **externally** by Crafty Controller.
- CraftProbe agent runs on Linux (Python >= 3.10, standard library only).
- Finds Minecraft Java processes whose `/proc/<pid>/cwd` or launch parameters match the selected instance folder; ignores short-lived `java -version` processes.
- `jcmd` checks JFR support, starts JFR, captures thread dumps, creates rolling/incident/stall JFR snapshots, and verifies the recording using `jfr summary` when available.
- Exports `Session-Analyse.zip` with logs, mod SHA-256 inventory, configs, user context, timeline/status; `Performance-Diagnose.zip` with JFR and thread dumps when present.
- JSONL events and command-file IPC are shared with Terminal.Gui on Windows and Linux.
- Does **not** stop/restart the server or send Minecraft console commands through Crafty (no Crafty API in v0.6.1; local RCON available separately).
- First-stage stall detection on Linux is **log-triggered**; it cannot claim native TPS/MSPT or Java thread sampling comparable to the Windows engine.

## Requirements and installation

```bash
python3 --version            # Python 3.9 or newer
java -version               # JVM used by Crafty/Minecraft
jcmd -l                     # JDK diagnostic tool; optional but highly recommended
```

Use a JDK with the same major Java version as the Minecraft JVM (for Minecraft 1.21.1 normally Java 21). CraftProbe must be run **as the same Linux UID** that runs the server JVM, with read access to the instance directory. Run `ps -eo user,pid,args | grep java` and `readlink /proc/<pid>/cwd` to verify. Do not run CraftProbe as root merely for convenience.

For a normal Crafty Linux/LXC installation:

```bash
cd /opt/CraftProbe
chmod +x craftprobe scripts/build-tui.sh
./craftprobe --cli --profile '/var/opt/minecraft/servers/MyServer'
```

Replace the example with the **actual server root** containing `server.properties`, `mods`, `logs`, etc. If no JVM is running yet, CraftProbe waits; start the server from Crafty as usual. It will attach automatically. To select among several Java processes matching the same folder:

```bash
./craftprobe --cli --profile '/path/to/server' --pid 12345
```

You can stop the agent gracefully with Ctrl+C or `systemctl stop` (does not stop Minecraft). While recording in an interactive terminal, type `incident` then Enter to mark an incident.

ZIPs appear in `<server>/_CraftProbe-Exports/` by default. Specify `--output /other/location` to store elsewhere. Reports include the time gap between JVM creation and CraftProbe's attach.

## Optional Terminal.Gui TUI

Requires .NET 10 SDK only when **building** the source distribution. It can publish a self-contained Linux executable:

```bash
./craftprobe --build-tui
./craftprobe
```

The TUI has the same three screens (Aufnahme/Aufnahmen/Einstellungen). Enter a server-profile path in the editable dropdown, then start recording. Terminal.Gui is not needed when running as a background service.

## Optional systemd service

Copy `systemd/craftprobe@.service` to `/etc/systemd/system/`, adjust **User=** to the account that owns the Minecraft JVM, and create `/etc/craftprobe/rogler.env`:

```ini
CRAFTPROBE_PROFILE=/var/opt/minecraft/servers/rogler
CRAFTPROBE_OUTPUT=/var/opt/minecraft/servers/rogler
```

Update `ExecStart=` to the actual CraftProbe checkout path (example `/opt/CraftProbe`). Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now craftprobe@rogler.service
journalctl -u craftprobe@rogler -f
```

A persistent service waits for Minecraft and collects evidence when it exits. If you use Crafty's automatic restart feature, the example uses `Restart=always`, so it automatically begins waiting for the next Crafty-managed Minecraft session after an export completes. More robust multi-session daemon functionality is planned for a later version.

## Important Docker note

When Crafty runs in Docker, the Minecraft JVM may be in another PID namespace. The Linux agent running on the host might **not** be able to see or attach to it. Run CraftProbe in the same PID namespace and with matching UID/JDK tool availability, preferably in the Minecraft container environment. Merely having access to a bind-mounted server directory does **not** grant `jcmd` attach access.

## Known limitations and safety

- All evidence begins at attach time. A startup JFR is **not** available retroactively.
- Very early JVM crashes can occur before the agent attaches. Standard error/crash logs may still be included in the export.
- Rolling snapshots keep the latest three snapshots (every 3 minutes); automatic stall snapshots are limited to six and incident JFR captures to ten. JFR maxage/maxsize are bounded, but ZIPs are still subject to disk capacity.
- Log-triggered stall captures depend on Minecraft logging a warning. Other invisible stalls will be missed.
- No automatic Crafty API calls, console command execution, metrics dashboard, or remote Windows-to-Linux control in v0.6.1.
- Java attach may be blocked by permissions, `-XX:+DisableAttachMechanism`, process isolation, or JDK incompatibility. CraftProbe should continue exporting basic logs in that case and report `BASIC` instead of claiming JFR success.
- Exported logs/configs/notes may contain sensitive information. Review before sharing; `server.properties` RCON password is redacted but arbitrary third-party config secrets are not guaranteed to be filtered.
