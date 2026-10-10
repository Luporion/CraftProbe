#!/usr/bin/env python3
"""CraftProbe 0.6.1 Linux agent. Python standard library only.

Attaches to a Minecraft Java process started externally (for example by Crafty).
Produces the same JSONL IPC event vocabulary and two ZIP types as the Windows
PowerShell recorder. It does not start, stop, or take ownership of Minecraft.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zipfile

VERSION = "0.6.1"
MINECRAFT_HINTS = (
    "cpw.mods.bootstraplauncher.bootstraplauncher", "net.minecraft.server.main",
    "net.minecraft.client.main.main", "net.fabricmc.loader.impl.launch",
    "net.fabricmc.loader.launch", "org.quiltmc.loader", "neoforge", "modlauncher",
    "minecraft_server", "minecraft-server", "server.jar", "paperclip", "paper.jar",
    "purpur", "spigot", "forge-", "fabric-server", "quilt-server",
)
BAD_JAVA_ARGS = {"-version", "--version", "-showversion", "-help", "--help", "-xshowsettings"}
SECRET_RE = re.compile(r"(?i)(--(?:accessToken|clientId|xuid|uuid|userProperties|profileProperties|password|token)\s+)(\S+)")
STALL_RE = re.compile(r"(?:Can't keep up!|A single server tick took|Skipping \d+ tick)", re.IGNORECASE)
LOG_LIMIT = 64 * 1024 * 1024
CONFIG_LIMIT = 8 * 1024 * 1024
CONFIG_TOTAL_LIMIT = 64 * 1024 * 1024


def iso(t: dt.datetime | None = None) -> str:
    return (t or dt.datetime.now().astimezone()).astimezone().isoformat(timespec="milliseconds")


def safe_name(name: str) -> str:
    return re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', name)


def redact(text: str) -> str:
    return SECRET_RE.sub(r"\1<REDACTED>", text)


def plausible_profile(folder: Path) -> bool:
    return folder.is_dir() and sum((folder / n).exists() for n in (
        "mods", "config", "logs", "saves", "world", "server.properties", "eula.txt",
        "defaultconfigs", "kubejs", "options.txt")) >= 2


def proc_start_ticks(pid: int) -> int | None:
    try:
        # comm is parenthesized and can itself contain spaces/parentheses.
        contents = Path(f"/proc/{pid}/stat").read_text()
        suffix = contents[contents.rfind(")") + 2:].split()
        return int(suffix[19])  # /proc/<pid>/stat field 22, 0-based relative to field 3
    except (OSError, ValueError, IndexError):
        return None


def boot_timestamp() -> float:
    try:
        for line in Path("/proc/stat").read_text().splitlines():
            if line.startswith("btime "):
                return float(line.split()[1])
    except (OSError, ValueError):
        pass
    return time.time() - float(Path("/proc/uptime").read_text().split()[0])


def same_or_child(candidate: str, root: Path) -> bool:
    try:
        folder = Path(candidate).resolve()
        return folder == root or folder.is_relative_to(root)
    except (OSError, ValueError):
        return False


def process_data(pid: int, profile: Path) -> dict | None:
    try:
        args = [a.decode("utf-8", "replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\x00") if a]
        if not args or Path(args[0]).name not in ("java", "javaw"):
            return None
        lowered = [a.lower() for a in args[1:]]
        if any(a in BAD_JAVA_ARGS or a.startswith("-xshowsettings") for a in lowered):
            return None
        cmd = " ".join(args).lower()
        if not any(token in cmd for token in MINECRAFT_HINTS):
            return None
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            cwd = ""
        # Never attach to another server just because it is also a Java Minecraft process.
        linked = same_or_child(cwd, profile)
        if not linked:
            for arg in args[1:]:
                # --gameDir may be supplied as two tokens.
                if same_or_child(arg, profile) or str(profile).lower() in arg.lower():
                    linked = True
                    break
        if not linked:
            return None
        ticks = proc_start_ticks(pid)
        if ticks is None:
            return None
        start = boot_timestamp() + ticks / os.sysconf("SC_CLK_TCK")
        return {"pid": pid, "ticks": ticks, "start": start, "cwd": cwd,
                "command": redact(" ".join(args))[:1200]}
    except (OSError, ValueError):
        return None


def find_processes(profile: Path) -> list[dict]:
    matches = []
    for node in Path('/proc').iterdir():
        if node.name.isdigit():
            found = process_data(int(node.name), profile)
            if found:
                matches.append(found)
    return sorted(matches, key=lambda x: (x['start'], x['pid']))


def process_alive(identity: dict) -> bool:
    return proc_start_ticks(identity['pid']) == identity['ticks']


def tools_for_jvm(pid: int) -> tuple[str | None, str | None]:
    # Prefer the toolchain that belongs to the target JVM if present and executable.
    candidates = []
    try:
        java_exe = Path(os.readlink(f'/proc/{pid}/exe')).resolve()
        candidates.extend([java_exe.parent / 'jcmd', java_exe.parent / 'jfr'])
    except OSError:
        pass
    return (
        str(next((x for x in candidates if x.name == 'jcmd' and x.is_file() and os.access(x, os.X_OK)), None)
            or shutil.which('jcmd') or '') or None,
        str(next((x for x in candidates if x.name == 'jfr' and x.is_file() and os.access(x, os.X_OK)), None)
            or shutil.which('jfr') or '') or None,
    )


def external(argv: list[str], timeout: int = 15) -> dict:
    try:
        p = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, check=False)
        return {"ok": p.returncode == 0, "exit": p.returncode, "output": p.stdout[-6000:]}
    except (OSError, subprocess.TimeoutExpired) as ex:
        return {"ok": False, "exit": None, "output": str(ex)}


class Emitter:
    def __init__(self, path: Path | None):
        self.path = path
        self.events: list[dict] = []
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)

    def emit(self, kind: str, message: str, detail: str = '', step: int = 0) -> None:
        event = {"timestamp": iso(), "type": kind, "message": message,
                 "detail": detail, "step": step}
        print(f"[{event['timestamp'][11:23]}] {message}" + (f" | {detail}" if detail else ''), flush=True)
        self.events.append(event)
        # Background daemon sessions can run for days; bound in-memory UI metadata.
        if len(self.events) > 10000:
            del self.events[:1000]
        if self.path:
            try:
                with self.path.open('a', encoding='utf-8') as f:
                    f.write(json.dumps(event, ensure_ascii=False) + '\n')
            except OSError as ex:
                print(f"WARNING: TUI event write failed: {ex}", file=sys.stderr)


class Commands:
    def __init__(self, path: Path | None):
        self.path = path
        self.events: list[dict] = []
        self.offset = 0

    def get(self) -> list[str]:
        if self.path:
            try:
                with self.path.open('r', encoding='utf-8') as f:
                    f.seek(self.offset)
                    lines = f.readlines()
                    # Only process terminated commands.
                    complete = [line.strip().lower() for line in lines if line.endswith('\n')]
                    self.offset = f.tell() if all(line.endswith('\n') for line in lines) else (
                        f.tell() - len(lines[-1].encode('utf-8')) if lines else f.tell())
                    return complete
            except FileNotFoundError:
                return []
            except OSError:
                return []
        if sys.stdin.isatty():
            try:
                readable, _, _ = select.select([sys.stdin], [], [], 0)
                if readable:
                    return [sys.stdin.readline().strip().lower()]
            except (OSError, ValueError):
                return []
        return []


class LinuxRecorder:
    def __init__(self, args: argparse.Namespace):
        self.profile = args.profile.resolve()
        self.output = (args.output or self.profile).resolve()
        if self.output == self.profile:
            self.output = self.profile / '_CraftProbe-Exports'
        self.emitter = Emitter(args.ui_events)
        self.commands = Commands(args.ui_commands)
        self.context = args.session_context
        self.pid_choice = args.pid
        self.poll_interval = max(.3, args.poll_interval)
        self.max_duration = args.max_duration
        self.wait_seconds = args.wait_seconds
        self.started = dt.datetime.now().astimezone()
        self.active: dict | None = None
        self.attached: dt.datetime | None = None
        self.stopped: dt.datetime | None = None
        self.stop_requested = False
        self.jvm_tool: str | None = None
        self.jfr_tool: str | None = None
        self.jfr_name = ''
        self.jfr_active = False
        self.jfr_results: dict[str, str] = {}
        self.stalls: list[dict] = []
        self.incidents: list[dict] = []
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.log_offset = 0
        self.log_inode: int | None = None
        self.last_stall = 0.0
        self.last_rolling = time.monotonic()
        self.last_wait_report = 0.0
        self.rolling_snapshots: list[str] = []
        self.incident_pending: list[tuple[float, str, str]] = []
        self.pending_jfr: list[tuple[float, str]] = []
        self.tmp: tempfile.TemporaryDirectory | None = None
        self.session_dir: Path | None = None
        self.heavy_dir: Path | None = None

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        self.emitter.emit('warning', message)

    def prepare_dirs(self) -> None:
        self.output.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix='craftprobe-')
        base = Path(self.tmp.name)
        self.session_dir = base / 'session'
        self.heavy_dir = base / 'performance'
        self.session_dir.mkdir()
        self.heavy_dir.mkdir()

    def select_process(self) -> dict | None:
        candidates = find_processes(self.profile)
        if self.pid_choice:
            candidates = [p for p in candidates if p['pid'] == self.pid_choice]
        if len(candidates) > 1:
            pids = ', '.join(str(p['pid']) for p in candidates)
            raise RuntimeError(f'Multiple Minecraft JVMs for this profile: {pids}. Use --pid PID.')
        return candidates[0] if candidates else None

    def cmd(self, name: str, *args: str, timeout: int = 15) -> dict:
        if not self.active or not self.jvm_tool:
            return {"ok": False, "output": 'No jcmd available'}
        return external([self.jvm_tool, str(self.active['pid']), name, *args], timeout)

    def start_jfr(self) -> None:
        assert self.active
        self.jvm_tool, self.jfr_tool = tools_for_jvm(self.active['pid'])
        if not self.jvm_tool:
            self.warn('jcmd unavailable: install a JDK matching the Minecraft Java major version.')
            return
        self.jfr_name = f'CraftProbe_{self.active["pid"]}'
        check = self.cmd('JFR.check')
        if not check['ok']:
            self.warn('JVM attach/JFR check failed: ' + check['output'][:350])
            return
        name = f'name={self.jfr_name}'
        start = self.cmd('JFR.start', name, 'settings=profile', 'maxage=15m', 'maxsize=96m', timeout=20)
        again = self.cmd('JFR.check')
        if again['ok'] and self.jfr_name in again['output']:
            self.jfr_active = True
            self.emitter.emit('jfr', 'JFR-Aufzeichnung aktiv', self.jfr_name)
        else:
            self.warn('JFR.start not verified: ' + start['output'][:350])

    def capture_thread(self, label: str) -> None:
        if not self.jvm_tool or not self.active:
            return
        result = self.cmd('Thread.print', '-l', timeout=14)
        filename = self.heavy_dir / 'threads' / (safe_name(label) + '.txt')
        filename.parent.mkdir(parents=True, exist_ok=True)
        filename.write_text(iso() + '\n' + result['output'], encoding='utf-8')
        if not result['ok']:
            self.warn(f'Thread dump {label} failed: ' + result['output'][:250])

    def snapshot_jfr(self, label: str) -> bool:
        if not self.jfr_active:
            self.jfr_results[label] = 'NOT_AVAILABLE'
            return False
        filename = self.heavy_dir / 'jfr' / (safe_name(label) + '.jfr')
        filename.parent.mkdir(parents=True, exist_ok=True)
        # jcmd's command parser accepts filename=<path> as ONE argv entry, even with spaces.
        result = self.cmd('JFR.dump', f'name={self.jfr_name}', f'filename={filename}', timeout=40)
        if not result['ok'] or not filename.is_file() or filename.stat().st_size < 256:
            self.jfr_results[label] = 'FAILED'
            self.warn(f'JFR snapshot {label} failed: ' + result['output'][:250])
            filename.unlink(missing_ok=True)
            return False
        if self.jfr_tool:
            checked = external([self.jfr_tool, 'summary', str(filename)], timeout=25)
            if not checked['ok']:
                self.jfr_results[label] = 'INVALID'
                self.warn(f'JFR file {label} invalid: ' + checked['output'][:250])
                filename.unlink(missing_ok=True)
                return False
        self.jfr_results[label] = 'OK' if self.jfr_tool else 'UNVERIFIED_NO_JFR_TOOL'
        self.emitter.emit('jfr_snapshot', 'JFR Snapshot gespeichert', filename.name +
                          (' (nicht vollstaendig validiert)' if not self.jfr_tool else ''))
        return True

    def mark_incident(self) -> None:
        num = len(self.incidents) + 1
        identifier = f'INCIDENT-{num:04d}'
        event = {"id": identifier, "time": iso(), "kind": "manual"}
        self.incidents.append(event)
        self.emitter.emit('incident', f'Incident {identifier} markiert')
        self.capture_thread(identifier + '-initial')
        # Timed follow-ups are processed by the main polling loop.
        at = time.monotonic()
        self.incident_pending.extend([(at + 5, identifier, '5s'), (at + 15, identifier, '15s')])
        if num <= 10:
            self.pending_jfr.append((at + 15, identifier))
        else:
            self.warn('Incident JFR evidence limited to first 10 incidents to control archive size.')

    def initialize_log_cursor(self) -> None:
        # Late attachment: do not classify old log warnings as fresh stalls.
        path = self.profile / 'logs' / 'latest.log'
        try:
            st = path.stat()
            self.log_inode, self.log_offset = st.st_ino, st.st_size
        except OSError:
            self.log_inode, self.log_offset = None, 0

    def observe_log(self) -> None:
        path = self.profile / 'logs' / 'latest.log'
        try:
            st = path.stat()
            if st.st_ino != self.log_inode or st.st_size < self.log_offset:
                self.log_inode, self.log_offset = st.st_ino, 0
            with path.open('rb') as f:
                f.seek(self.log_offset)
                sample = f.read(1024 * 1024)
                self.log_offset = f.tell()
            for line in sample.decode('utf-8', 'replace').splitlines():
                if STALL_RE.search(line):
                    now = time.monotonic()
                    if now - self.last_stall < 8:
                        continue
                    self.last_stall = now
                    identifier = f'STALL-{len(self.stalls) + 1:04d}'
                    entry = {"id": identifier, "time": iso(), "log": redact(line[:1000])}
                    self.stalls.append(entry)
                    self.emitter.emit('stall', f'Server-Stall {identifier}', line.strip()[:200])
                    if len(self.stalls) <= 6:
                        self.capture_thread(identifier)
                        self.snapshot_jfr(identifier)
        except FileNotFoundError:
            return
        except (OSError, UnicodeError) as ex:
            self.warn(f'Log read error: {ex}')

    def run(self) -> int:
        if not plausible_profile(self.profile):
            self.emitter.emit('error', 'Minecraft-Serverordner ungueltig', str(self.profile))
            return 2
        self.prepare_dirs()
        self.emitter.emit('starting', 'CraftProbe Linux gestartet', str(self.profile))
        deadline = time.monotonic() + self.wait_seconds if self.wait_seconds else None
        while not self.stop_requested:
            try:
                selected = self.select_process()
            except RuntimeError as ex:
                self.emitter.emit('error', 'Mehrere JVMs gefunden', str(ex))
                self.close_tmp()
                return 3
            if selected:
                self.active = selected
                self.attached = dt.datetime.now().astimezone()
                process_time = dt.datetime.fromtimestamp(selected['start'], dt.timezone.utc).astimezone()
                lag = (self.attached - process_time).total_seconds()
                self.emitter.emit('minecraft', 'Minecraft-Server verbunden',
                                  f'PID {selected["pid"]} | Start {iso(process_time)} | Attach +{lag:.1f}s')
                self.emitter.emit('session', 'Session gestartet', f'Late Attach +{lag:.1f}s')
                self.initialize_log_cursor()
                self.start_jfr()
                self.capture_thread('initial')
                self.snapshot_jfr('initial-attach')
                break
            now = time.monotonic()
            if now - self.last_wait_report >= 60:
                self.emitter.emit('waiting', 'Warte auf Minecraft-Server', 'Gestartet durch Crafty oder andere Verwaltung')
                self.last_wait_report = now
            if deadline and time.monotonic() > deadline:
                self.emitter.emit('error', 'Kein Server gefunden', 'Wartezeit abgelaufen')
                self.close_tmp()
                return 4
            time.sleep(max(self.poll_interval, 1.0))
        if not self.active:
            self.close_tmp()
            return 130
        begin = time.monotonic()
        while process_alive(self.active) and not self.stop_requested:
            if self.max_duration and time.monotonic() - begin >= self.max_duration:
                self.warn('Test limit reached: recording stopped while Minecraft is running.')
                break
            for command in self.commands.get():
                if command in ('incident', 'e'):
                    self.mark_incident()
                elif command == 'stop':
                    self.stop_requested = True
            now = time.monotonic()
            for due, identifier, suffix in list(self.incident_pending):
                if now >= due and process_alive(self.active):
                    self.capture_thread(identifier + '-' + suffix)
                    self.incident_pending.remove((due, identifier, suffix))
            for due, identifier in list(self.pending_jfr):
                if now >= due and process_alive(self.active):
                    self.snapshot_jfr(identifier + '-15s')
                    self.pending_jfr.remove((due, identifier))
            self.observe_log()
            if now - self.last_rolling >= 180 and self.jfr_active:
                name = 'rolling-' + dt.datetime.now().strftime('%H%M%S')
                if self.snapshot_jfr(name):
                    self.rolling_snapshots.append(name)
                    if len(self.rolling_snapshots) > 3:
                        expired = self.rolling_snapshots.pop(0)
                        (self.heavy_dir / 'jfr' / (safe_name(expired) + '.jfr')).unlink(missing_ok=True)
                        self.jfr_results.pop(expired, None)
                self.last_rolling = now
            time.sleep(self.poll_interval)
        self.stopped = dt.datetime.now().astimezone()
        self.emitter.emit('stopped', 'Aufnahme beendet (Minecraft laeuft noch)' if process_alive(self.active)
                          else 'Minecraft beendet / Aufnahme gestoppt', f'PID {self.active["pid"]}')
        self.emitter.emit('export', 'JFR sichern', step=1)
        if process_alive(self.active):
            self.snapshot_jfr('final')
        elif self.jfr_active:
            self.jfr_results['final'] = 'NOT_CAPTURED_PROCESS_EXIT'
        self.emitter.emit('export', 'Recorder abschliessen', step=2)
        self.emitter.emit('export', 'Session-Daten sammeln', step=3)
        try:
            self.export()
        except Exception as ex:
            self.emitter.emit('error', 'Diagnoseexport fehlgeschlagen', str(ex))
            self.close_tmp()
            return 5
        self.close_tmp()
        return 0

    def close_tmp(self) -> None:
        if self.tmp:
            self.tmp.cleanup()
            self.tmp = None

    def read_context(self) -> str:
        if not self.context or not self.context.exists():
            return ''
        try:
            return str(json.loads(self.context.read_text(encoding='utf-8')).get('notes', ''))[:20000]
        except (ValueError, OSError):
            return ''

    def collect_files(self) -> list[str]:
        assert self.session_dir
        copied = []
        total_config = 0
        for folder in ('config', 'defaultconfigs', 'kubejs', 'world/serverconfig', 'logs', 'crash-reports'):
            root = self.profile / folder
            if not root.is_dir():
                continue
            try:
                files = root.rglob('*')
                for source in files:
                    if not source.is_file() or source.is_symlink():
                        continue
                    relative = source.relative_to(self.profile)
                    if any(part.lower() in {'.git', 'cache', 'caches', 'backups', 'backup', 'node_modules'} for part in relative.parts):
                        continue
                    size = source.stat().st_size
                    limit = LOG_LIMIT if folder in ('logs', 'crash-reports') else CONFIG_LIMIT
                    if size > limit:
                        self.warnings.append(f'Skipped large file: {relative} ({size} bytes)')
                        continue
                    if folder not in ('logs', 'crash-reports'):
                        if total_config + size > CONFIG_TOTAL_LIMIT:
                            self.warnings.append(f'Config budget reached: {relative}')
                            continue
                        total_config += size
                    dest = self.session_dir / relative
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, dest)
                    copied.append(str(relative))
            except OSError as ex:
                self.warnings.append(f'Cannot copy {folder}: {ex}')
        for name in ('server.properties', 'eula.txt'):
            path = self.profile / name
            if path.is_file():
                text = path.read_text(encoding='utf-8', errors='replace')
                if name == 'server.properties':
                    text = re.sub(r'(?im)^((?:rcon|query)\.password\s*=).*$', r'\1<REDACTED>', text)
                (self.session_dir / name).write_text(text, encoding='utf-8')
        return copied

    def collect_mods(self) -> tuple[int, int]:
        assert self.session_dir
        folder = self.profile / 'mods'
        dest = self.session_dir / 'mods.csv'
        count = errors = 0
        with dest.open('w', encoding='utf-8', newline='') as f:
            out = csv.writer(f)
            out.writerow(('Filename', 'RelativePath', 'Enabled', 'Size', 'SHA256', 'HashStatus', 'HashError'))
            if folder.is_dir():
                for path in sorted(folder.iterdir()):
                    if not path.is_file() or not (path.name.lower().endswith(('.jar', '.jar.disabled'))):
                        continue
                    count += 1
                    try:
                        hasher = hashlib.sha256()
                        with path.open('rb') as source:
                            for block in iter(lambda: source.read(1024 * 1024), b''):
                                hasher.update(block)
                        out.writerow((path.name, str(path.relative_to(self.profile)), not path.name.lower().endswith('.disabled'),
                                      path.stat().st_size, hasher.hexdigest().upper(), 'OK', ''))
                    except OSError as ex:
                        errors += 1
                        out.writerow((path.name, str(path.relative_to(self.profile)), '', '', '', 'ERROR', str(ex)))
        return count, errors

    def export(self) -> None:
        assert self.active and self.attached and self.session_dir and self.heavy_dir and self.stopped
        copied = self.collect_files()
        mods, errors = self.collect_mods()
        recorded_prior = max(0., self.attached.timestamp() - self.active['start'])
        notes = self.read_context()
        if self.context and self.context.exists():
            shutil.copyfile(self.context, self.session_dir / 'SESSION_CONTEXT.json')
        status = {
            'schema': 1, 'version': VERSION, 'platform': 'linux', 'profile': str(self.profile),
            'minecraft': 'STOPPED' if not process_alive(self.active) else 'STILL_RUNNING',
            'minecraft_pid': self.active['pid'],
            'minecraft_started_at': iso(dt.datetime.fromtimestamp(self.active['start'], dt.timezone.utc)),
            'craftprobe_started_at': iso(self.started), 'attached_at': iso(self.attached),
            'recording_stopped_at': iso(self.stopped), 'late_attach_seconds': round(recorded_prior, 2),
            'jcmd': 'OK' if self.jvm_tool else 'UNAVAILABLE',
            'jfr_recording': 'OK' if self.jfr_active else 'UNAVAILABLE',
            'jfr_files': self.jfr_results, 'startup_jfr': 'NOT_CAPTURED_LATE_ATTACH',
            'mod_hashes': {'total': mods, 'ok': mods - errors, 'errors': errors},
            'stalls': len(self.stalls), 'incidents': len(self.incidents), 'warnings': self.warnings,
        }
        if errors or any(v in ('FAILED', 'INVALID') for v in self.jfr_results.values()):
            status['overall'] = 'DEGRADED'
        elif not self.jfr_active:
            status['overall'] = 'BASIC'
        else:
            status['overall'] = 'PARTIAL'  # Attach after JVM launch: startup cannot be recovered.
        summary = '\n'.join([
            f'CRAFTPROBE v{VERSION} - LINUX / CRAFTY', f'CAPTURE HEALTH: {status["overall"]}',
            f'Profile: {self.profile}', f'Java PID: {self.active["pid"]}',
            f'Minecraft start: {status["minecraft_started_at"]}', f'CraftProbe start: {status["craftprobe_started_at"]}',
            f'Attached: {status["attached_at"]}', f'Late attach: {recorded_prior:.1f} seconds',
            f'Stopped: {status["recording_stopped_at"]}',
            f'JFR: {status["jfr_recording"]} | jcmd: {status["jcmd"]}',
            f'JFR snapshots: {self.jfr_results}', f'Mods hashed: {mods - errors}/{mods}',
            f'Stalls: {len(self.stalls)} | Incidents: {len(self.incidents)}',
            f'Logs/config files copied: {len(copied)}',
            'Startup JFR cannot be reconstructed when attaching to an already running process.',
            'NOTE: Log-based stall detection; not an accurate MSPT profiler.',
            '', 'USER NOTES (not measured evidence):', notes or '(none)', '',
            'WARNINGS:', *[f'- {x}' for x in self.warnings], ''
        ])
        (self.session_dir / 'DIAGNOSE_SUMMARY.txt').write_text(summary, encoding='utf-8')
        (self.session_dir / 'CAPTURE_STATUS.json').write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding='utf-8')
        (self.session_dir / 'STALL_EVENTS.json').write_text(json.dumps(self.stalls, indent=2), encoding='utf-8')
        (self.session_dir / 'INCIDENTS.json').write_text(json.dumps(self.incidents, indent=2), encoding='utf-8')
        with (self.session_dir / 'TIMELINE.tsv').open('w', encoding='utf-8', newline='') as f:
            writer = csv.writer(f, delimiter='\t')
            writer.writerow(('timestamp', 'type', 'message', 'detail', 'step'))
            for event in self.emitter.events:
                writer.writerow((event['timestamp'], event['type'], event['message'], event['detail'], event['step']))
        with (self.session_dir / 'STALL_EVENTS.tsv').open('w', encoding='utf-8', newline='') as f:
            writer = csv.writer(f, delimiter='\t')
            writer.writerow(('id', 'timestamp', 'log_text'))
            for event in self.stalls:
                writer.writerow((event['id'], event['time'], event['log']))
        (self.session_dir / 'system.json').write_text(json.dumps({
            'uname': list(os.uname()), 'python': sys.version.split()[0], 'java_command': self.active['command'],
            'java_cwd': self.active['cwd']}, indent=2), encoding='utf-8')
        stamp = self.stopped.strftime('%Y-%m-%d_%H-%M-%S')
        base = safe_name(self.profile.name)
        shortname = f'{base}_Session-Analyse_{stamp}'
        heavyn = f'{base}_Performance-Diagnose_{stamp}'
        self.emitter.emit('export', 'ZIPs erstellen', step=4)
        analysis = self.output / (shortname + '.zip')
        make_zip(self.session_dir, analysis)
        heavyzip = None
        if any(self.heavy_dir.rglob('*.*')):
            heavyzip = self.output / (heavyn + '.zip')
            (self.heavy_dir / 'CAPTURE_STATUS.json').write_text(json.dumps(status, indent=2), encoding='utf-8')
            make_zip(self.heavy_dir, heavyzip)
        sidecar = analysis.with_suffix('.session.json')
        sidecar.write_text(json.dumps({'schema': 1, 'profile': str(self.profile), 'notes': notes,
                                       'started': iso(self.started), 'stopped': iso(self.stopped),
                                       'late_attach_seconds': recorded_prior}, ensure_ascii=False, indent=2), encoding='utf-8')
        self.emitter.emit('completed', 'Export erfolgreich', str(analysis) + (f' | {heavyzip}' if heavyzip else ''))


def make_zip(source: Path, destination: Path) -> None:
    temp = destination.with_name(destination.name + '.partial')
    try:
        with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=5, allowZip64=True) as archive:
            for path in sorted(source.rglob('*')):
                if path.is_file() and not path.is_symlink():
                    archive.write(path, str(path.relative_to(source)))
        with zipfile.ZipFile(temp, 'r') as archive:
            bad = archive.testzip()
            if bad:
                raise IOError(f'ZIP CRC verification failed: {bad}')
        os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description='CraftProbe Linux agent: attach to Crafty-managed Java process')
    parser.add_argument('--profile', type=Path, required=True, help='Minecraft server directory (mods/logs/server.properties)')
    parser.add_argument('--output', type=Path, help='Where to export ZIPs; profile means _CraftProbe-Exports subfolder')
    parser.add_argument('--pid', type=int, help='Select Minecraft PID if multiple instances share a profile')
    parser.add_argument('--ui-events', type=Path, help='IPC events JSONL file')
    parser.add_argument('--ui-commands', type=Path, help='IPC commands text file')
    parser.add_argument('--session-context', type=Path, help='Optional JSON context from TUI')
    parser.add_argument('--poll-interval', type=float, default=2.0, help='Seconds per monitoring tick')
    parser.add_argument('--wait-seconds', type=int, default=0, help='Timeout waiting for JVM; 0 means indefinite')
    parser.add_argument('--max-duration', type=int, default=0, help='Optional recording time limit, seconds')
    args = parser.parse_args()
    recorder = LinuxRecorder(args)
    def stop(_signal, _frame):
        recorder.stop_requested = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        return recorder.run()
    except (OSError, ValueError, RuntimeError) as ex:
        recorder.emitter.emit('error', 'Linux-Agent Fehler', str(ex))
        recorder.close_tmp()
        return 1


if __name__ == '__main__':
    sys.exit(main())
