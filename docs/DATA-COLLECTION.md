# Data collection

The project deliberately separates compact evidence from heavy performance data.

## Session archive

Typical contents:

- `logs/latest.log` (kept complete)
- relevant logs from the same session window
- crash reports from the same session
- configs/defaultconfigs and world `serverconfig`
- KubeJS/configuration data when present
- mod file names, sizes and SHA-256 hashes
- resource pack/datapack/schematic inventories
- JVM version, flags, selected system properties and heap information when `jcmd` is available
- Windows CPU/GPU/OS metadata
- process resource samples
- timeline and stall summary

Caches, backups and known redundant copies are excluded where practical.

## Performance archive

Contains files whose size or diagnostic depth makes them unsuitable for the default bundle:

- `.jfr` recordings
- full verified-stall thread dumps
- full manual-incident thread dumps
- very large supplemental logs moved out of the compact archive

## Time correlation

All recorder events use absolute local timestamps with millisecond precision where possible. `DIAGNOSE_SUMMARY.txt`, `TIMELINE.tsv` and `STALL_EVENTS.tsv` are intended to correlate:

- player-observed incident time
- `latest.log`
- thread dump
- JFR milestone/snapshot
- watchdog/high-MSPT trigger

## Authentication/privacy handling

The Java command line capture redacts common values such as:

- access token
- client ID
- XUID
- UUID
- user/profile property payloads
- JWT-like tokens

This cannot guarantee removal of secrets emitted by individual mods or launchers. Do not publish diagnostic archives without reviewing them.

## Capture-health metadata (v0.4.0)

`CAPTURE_STATUS.json` records whether core evidence was actually captured and validated. CraftProbe distinguishes a running JFR recording from successfully persisted JFR artifacts. Mod hash failures and a missing `latest.log` are also surfaced instead of being silently hidden.

Event correlation files include stable event IDs, ISO timestamps, phase information, and compact `log-context/` excerpts around stalls/incidents.


## Late attach (v0.4.1)

CraftProbe may attach to a Minecraft JVM that was already running before CraftProbe started. In that case the exported metadata records:

- Minecraft process start
- CraftProbe start
- attach/capture-coverage start
- start difference in seconds
- `late_attach: true`

JVM/JFR/thread evidence only exists from the attach point forward. Milestones that already happened are reported as `NOT_CAPTURED_LATE_ATTACH`. This is an expected coverage limitation, not a recorder failure.
