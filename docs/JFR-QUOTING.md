# CraftProbe JFR filename quoting — v0.5.1

## What the earlier diagnostics showed

When a profile directory contains spaces (for example `Rogler Alpha DEV`), `JFR.check` may report a running recording although `JFR.dump` did not write a file. This is not necessarily a failed recorder start. The JVM's `jcmd` diagnostic-command parser splits the `filename=` value on spaces unless that **value itself** is quoted.

A single quoted Windows `CreateProcess` command-line argument is **not** sufficient, because the OS/CRT strips those quotes before `jcmd` parses the command.

## Fix

CraftProbe supplies one argument whose actual value is `filename="C:\\folder with spaces\\snapshot.jfr"`. Its Windows native process-argument encoder escapes the interior quotes so they survive as literal quote characters in `jcmd`'s argv.

Both `JFR.start` (dump-on-exit target) and `JFR.dump` (milestones, incidents, rolling, stall) use the same pattern. Every dump is validated by file size and, when available, `jfr summary`. Successful `JFR.start` alone does not establish that later snapshots exist.

## Confirmed reproduction (JDK jcmd)

A Java process with `JFR.start name=MinecraftAI` yielded:

- `jcmd PID JFR.dump name=MinecraftAI 'filename=/tmp/CraftProbe spaced/out bare.jfr'` → `Unknown argument 'spaced/out'`.
- `jcmd PID JFR.dump name=MinecraftAI 'filename="/tmp/CraftProbe spaced/out quoted.jfr"'` → recording saved successfully, nonzero file size.

This reproduces the Java command parser behavior. CraftProbe's final Windows/.NET+PowerShell integration still requires a real test on Windows before a release.
