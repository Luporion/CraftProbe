## v0.6.2 console scrolling release gate

1. Windows: `CraftProbe.cmd --build-tui` (Terminal.Gui 2.5.0 / .NET 10) and `dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj` must pass.
2. Test vertical scrollbar through 1200 buffered log lines, horizontal scrollbar on >100-character lines, and absence of word wrapping.
3. With live log updates: manual scrolling up must not jump to bottom. "Ganz nach unten" and Ctrl+End should return to the tail and re-enable following.
4. Check filtered search, pause/resume, RCON, profile switching and window resize. Verify no regression in recording/ZIP creation.
5. Only then tag and publish; the deliverable is a source/development preview until Windows UI has been tested.

## v0.6.1 console preview release gate

1. `dotnet run --project tests/CraftProbe.ConsoleTests/CraftProbe.ConsoleTests.csproj` (must pass).
2. Windows: `CraftProbe.cmd --build-tui` and start TUI; open Konsole, filter, pause, save excerpt.
3. Validate recording and incident still work in parallel with live log display.
4. RCON only on an explicitly configured local test server; verify wrong-password feedback and no credentials in ZIP.
5. Verify GitHub Actions Windows/Linux builds. Until then do not tag or publish as stable.

## v0.6.0 Linux release candidate checklist

1. `python3 -m unittest discover -s tests -v` and `CRAFTPROBE_JAVA_INTEGRATION=1 python3 -m unittest discover -s tests -v` on Linux with Java/JDK 21.
2. Build Linux TUI via `./craftprobe --build-tui`; Windows TUI via `CraftProbe.cmd --build-tui` (both require .NET 10 SDK).
3. Test with a real Crafty-started NeoForge server. Verify identical JVM UID/PID namespace, JFR validity, and Session/Performance ZIPs.
4. Check default export path, late attach, crash, clean stop, waiting-then-start, incident commands, and missing JDK tools.
5. Run GitHub Actions matrix Windows/Linux and upload platform archives. Do not tag v0.6.0 until both builds and real-world Crafty test pass.

---

﻿# Releasing CraftProbe

1. Update `VERSION`, `CHANGELOG.md` and README if needed.
2. Run the regression checklist in [`TESTING.md`](TESTING.md), especially with a Minecraft profile path containing spaces.
3. Confirm `CAPTURE_STATUS.json` does not hide failed expected artifacts.
4. Commit and push:

```powershell
git add .
git commit -m "Prepare CraftProbe vX.Y.Z"
git push
```

5. Tag only after the smoke test is clean:

```powershell
git tag -a vX.Y.Z -m "CraftProbe vX.Y.Z"
git push origin vX.Y.Z
```

6. Create the GitHub release from that tag and attach the portable `CraftProbe-vX.Y.Z.zip`.
