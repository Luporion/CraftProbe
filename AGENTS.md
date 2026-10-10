# CraftProbe development instructions

- Public app name: CraftProbe, current version 0.6.4.
- Single repository with Windows PowerShell backend (`src/`) and Linux Python 3.10+ backend (`linux/`); TUI is C# .NET 10 + Terminal.Gui 2.5.0.
- Never assume Linux can run Windows CIM (`Win32_Process`) or `.exe` JDK tools.
- Keep the event protocol documented in `docs/ARCHITECTURE.md` compatible across both backends.
- Preserve `craftprobe --cli` on Linux and `CraftProbe.cmd --cli` on Windows.
- Don't stop or restart Crafty/Minecraft from the agent; server ownership remains with Crafty.
- Always verify JFR dumps; treat missing/invalid captures as non-OK. Do not mislabel attach snapshots as startup recordings.
- Protect against wrong Java PID, PID reuse, path prefix collisions, late attach and missing latest.log.
- Do not include `.jar` mod binaries, worlds, backup archives or credentials in diagnostics.
- Update VERSION, README, CHANGELOG, docs/PROJECT_STATE.md and tests for code changes.
- Tests: `python3 -m unittest discover -s tests -v`, optionally real JVM with `CRAFTPROBE_JAVA_INTEGRATION=1`.
- C# compilation (Linux and Windows) must be validated on GitHub Actions or .NET 10 host before a stable release.

- v0.6.2: Windows Konsole-Tab tailing is read-only for the singleplayer client. RCON only for explicitly configured dedicated servers; never transmit password in exports. Run `dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj` on a .NET 10 machine.

- v0.6.3: optional singleplayer Companion Mod lives in `companion/NeoForge-1.21.1/`. It is client-only, opt-in `/craftprobe enable`, player-permissions only, never server privilege escalation. RCON remains dedicated-server only. Build via Gradle separately; do not mistake source code for a tested mod JAR.

- v0.6.4: Companion Gradle 8.14 bootstrap is checksum-verified, requires JDK 21, no system Gradle. Ship full ZIP, Git format-patch and tested overlay ZIP; include Git commands, do not silently commit to user repository. Never claim NeoForge build tested without network/Gradle.
