#!/usr/bin/env python3
"""Run with: python3 -m unittest discover -s tests -v
Full live-JVM test requires: CRAFTPROBE_JAVA_INTEGRATION=1 and javac/java/jcmd/jfr.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

MODULE_PATH = Path(__file__).resolve().parent.parent / 'linux' / 'craftprobe_agent.py'
spec = importlib.util.spec_from_file_location('craftprobe_linux_agent', MODULE_PATH)
agent = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = agent
spec.loader.exec_module(agent)


class UnitTests(unittest.TestCase):
    def test_jar_matching_excludes_java_probe(self):
        # A java -version process never qualifies, regardless of its working directory.
        self.assertIn('-version', agent.BAD_JAVA_ARGS)
        self.assertIn('server.jar', agent.MINECRAFT_HINTS)
        self.assertNotIn('java', agent.MINECRAFT_HINTS)

    def test_profile_requires_minecraft_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertFalse(agent.plausible_profile(root))
            (root / 'mods').mkdir()
            (root / 'server.properties').write_text('motd=Test', encoding='utf-8')
            self.assertTrue(agent.plausible_profile(root))

    def test_profile_matching_does_not_match_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'Server'
            other = Path(tmp) / 'Server2'
            root.mkdir(); other.mkdir()
            self.assertTrue(agent.same_or_child(str(root), root))
            self.assertFalse(agent.same_or_child(str(other), root))

    def test_process_alive_identity_guard(self):
        identity = {'pid': os.getpid(), 'ticks': agent.proc_start_ticks(os.getpid())}
        self.assertTrue(agent.process_alive(identity))
        identity['ticks'] += 1
        self.assertFalse(agent.process_alive(identity))

    def test_zip_crc_and_path_spaces(self):
        with tempfile.TemporaryDirectory(prefix='Craft Probe ') as tmp:
            source = Path(tmp) / 'stage'; source.mkdir()
            (source / 'CAPTURE_STATUS.json').write_text('{"overall":"OK"}', encoding='utf-8')
            dest = Path(tmp) / 'A Profile_Session-Analyse_2026-10-09_20-00-00.zip'
            agent.make_zip(source, dest)
            with zipfile.ZipFile(dest) as archive:
                self.assertIsNone(archive.testzip())
                self.assertIn('CAPTURE_STATUS.json', archive.namelist())

    def test_late_attach_ignores_old_stalls(self):
        import argparse
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'logs').mkdir()
            log = root / 'logs' / 'latest.log'
            log.write_text("[old] Can't keep up! Running 3000ms behind\n", encoding='utf-8')
            args = argparse.Namespace(profile=root, output=None, ui_events=None, ui_commands=None,
                    session_context=None, pid=None, poll_interval=1, max_duration=0, wait_seconds=0)
            recorder = agent.LinuxRecorder(args)
            recorder.initialize_log_cursor()
            recorder.observe_log()
            self.assertEqual(len(recorder.stalls), 0)
            with log.open('a', encoding='utf-8') as f:
                f.write("[new] Can't keep up! Running 4000ms behind\n")
            recorder.observe_log()
            self.assertEqual(len(recorder.stalls), 1)

    def test_sensitive_command_redacted(self):
        self.assertNotIn('abc123', agent.redact('java --accessToken abc123'))

    def test_events_and_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            eventfile = Path(tmp) / 'events.jsonl'
            commandsfile = Path(tmp) / 'commands.txt'
            agent.Emitter(eventfile).emit('export', 'ZIPs erstellen', step=4)
            event = json.loads(eventfile.read_text().splitlines()[0])
            self.assertEqual(event['step'], 4)
            c = agent.Commands(commandsfile)
            commandsfile.write_text('incident\n')
            self.assertEqual(c.get(), ['incident'])
            self.assertEqual(c.get(), [])
            with commandsfile.open('a') as f:
                f.write('incident\n')
            self.assertEqual(c.get(), ['incident'])


@unittest.skipUnless(os.environ.get('CRAFTPROBE_JAVA_INTEGRATION') == '1', 'Set CRAFTPROBE_JAVA_INTEGRATION=1')
class IntegrationTests(unittest.TestCase):
    def test_running_java_attach_jfr_snapshot_and_zip(self):
        for tool in ['java', 'javac', 'jcmd', 'jfr']:
            if not shutil.which(tool):
                self.skipTest(f'{tool} unavailable')
        with tempfile.TemporaryDirectory(prefix='Craft Probe Integration ') as tmp:
            profile = Path(tmp) / 'Minecraft Profile With Spaces'
            profile.mkdir(); (profile / 'mods').mkdir(); (profile / 'config').mkdir()
            (profile / 'logs').mkdir()
            (profile / 'server.properties').write_text('motd=Test Server\nrcon.password=shh\n', encoding='utf-8')
            (profile / 'mods' / 'example.jar').write_bytes(b'fake-mod-for-hashing')
            (profile / 'logs' / 'latest.log').write_text('[Server thread/INFO] Starting fake game\n')
            source = profile / 'FakeGame.java'
            source.write_text('public class FakeGame { public static void main(String[] a) throws Exception { Thread.sleep(120000); } }')
            subprocess.run(['javac', str(source)], check=True)
            env = os.environ.copy()
            game = subprocess.Popen(['java', '-Dnet.minecraft.server.Main=integration-test', '-cp', str(profile), 'FakeGame'], cwd=profile, env=env)
            probe = None
            try:
                time.sleep(1.8)
                events = Path(tmp) / 'events.jsonl'
                probe = subprocess.Popen([sys.executable, str(MODULE_PATH), '--profile', str(profile),
                                           '--ui-events', str(events), '--poll-interval', '0.5', '--wait-seconds', '8'],
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                deadline = time.time() + 25
                while time.time() < deadline:
                    if events.is_file() and 'JFR-Aufzeichnung aktiv' in events.read_text():
                        break
                    if probe.poll() is not None:
                        break
                    time.sleep(.25)
                self.assertIsNone(probe.poll(), 'Agent stopped before Java exited')
                self.assertIn('Minecraft-Server verbunden', events.read_text())
                self.assertIn('JFR-Aufzeichnung aktiv', events.read_text(), 'Real JVM JFR failed')
                with (profile / 'logs' / 'latest.log').open('a') as f:
                    f.write('[Server thread/WARN] Can\'t keep up! Running 3657ms or 73 ticks behind\n')
                time.sleep(4)
                game.terminate(); game.wait(timeout=10)
                output, _ = probe.communicate(timeout=110)
                self.assertEqual(probe.returncode, 0, output[-3000:])
                zipfiles = list((profile / '_CraftProbe-Exports').glob('*Session-Analyse*.zip'))
                self.assertEqual(len(zipfiles), 1)
                with zipfile.ZipFile(zipfiles[0]) as z:
                    status = json.loads(z.read('CAPTURE_STATUS.json'))
                    self.assertEqual(status['mod_hashes']['ok'], 1)
                    self.assertIn('TIMELINE.tsv', z.namelist())
                    self.assertIn('STALL_EVENTS.tsv', z.namelist())
                    self.assertEqual(status['jfr_recording'], 'OK')
                    self.assertEqual(status['overall'], 'PARTIAL')
                    self.assertEqual(z.read('server.properties').decode().count('shh'), 0)
                perf = list((profile / '_CraftProbe-Exports').glob('*Performance-Diagnose*.zip'))
                self.assertEqual(len(perf), 1)
                with zipfile.ZipFile(perf[0]) as z:
                    self.assertTrue(any(n.endswith('.jfr') for n in z.namelist()), z.namelist())
            finally:
                if game.poll() is None: game.kill(); game.wait()
                if probe and probe.poll() is None: probe.kill(); probe.wait()


if __name__ == '__main__': unittest.main()
