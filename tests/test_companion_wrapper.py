"""Offline regression checks for the Gradle 8.14 wrapper hotfix (v0.6.4.2)."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile
import unittest
import shutil

ROOT = Path(__file__).resolve().parents[1]
COMPANION = ROOT / 'companion' / 'NeoForge-1.21.1'
DIST_SHA = '61ad310d3c7d3e5da131b76bbf22b5a4c0786e9d892dae8c1658d4b484de3caa'
WRAPPER_SHA = '7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172'
OFFICIAL_URL = 'https://raw.githubusercontent.com/gradle/gradle/v8.14.0/gradle/wrapper/gradle-wrapper.jar'
BAD_URL = 'https://services.gradle.org/distributions/gradle-8.14-wrapper.jar'


class GradleWrapperTests(unittest.TestCase):
    def test_pinned_distribution(self):
        properties = (COMPANION / 'gradle/wrapper/gradle-wrapper.properties').read_text()
        self.assertIn('gradle-8.14-bin.zip', properties)
        self.assertIn('distributionSha256Sum=' + DIST_SHA, properties)

    def test_official_source_and_hash_on_both_platforms(self):
        win = (COMPANION / 'scripts/Ensure-GradleWrapper.ps1').read_text()
        sh = (COMPANION / 'gradlew').read_text()
        bat = (COMPANION / 'gradlew.bat').read_text()
        for source in (win, sh):
            self.assertIn(WRAPPER_SHA, source)
            self.assertIn(OFFICIAL_URL, source)
            self.assertNotIn(BAD_URL, source)
        self.assertIn('Ensure-GradleWrapper.ps1', bat)
        self.assertIn('org.gradle.wrapper.GradleWrapperMain', bat)
        self.assertIn('org.gradle.wrapper.GradleWrapperMain', sh)

    def test_windows_does_not_depend_on_get_file_hash(self):
        win = (COMPANION / 'scripts/Ensure-GradleWrapper.ps1').read_text()
        hasher = (COMPANION / 'scripts/Get-CraftProbeSha256.ps1').read_text()
        self.assertNotIn('Get-FileHash', win)
        self.assertIn("Get-CraftProbeSha256.ps1", win)
        self.assertIn('[System.Security.Cryptography.SHA256]::Create()', hasher)
        self.assertIn('[System.IO.File]::Open(', hasher)
        self.assertIn('$Stream.Dispose()', hasher)
        self.assertIn('$Hasher.Dispose()', hasher)
        self.assertIn('Get-CraftProbeSha256 -LiteralPath $Temp', win)
        self.assertIn('Get-CraftProbeSha256 -LiteralPath $Jar', win)

    def test_download_hash_filesystem_are_separate_errors(self):
        win = (COMPANION / 'scripts/Ensure-GradleWrapper.ps1').read_text()
        sh = (COMPANION / 'gradlew').read_text()
        for marker in ('Wrapper-DOWNLOAD', 'Wrapper-SHA256', 'Wrapper-DATEISYSTEM'):
            self.assertIn(marker, win)
        for marker in ('DOWNLOAD failed', 'SHA256 mismatch', 'FILESYSTEM failure'):
            self.assertIn(marker, sh)
        self.assertIn('finally {', win)
        self.assertIn('Remove-Item -LiteralPath $Temp', win)

    def test_linux_rejects_tampered_cached_wrapper_without_java(self):
        if not shutil.which('bash') or not shutil.which('python3'):
            self.skipTest('bash and python3 are not installed')
        with tempfile.TemporaryDirectory(prefix='craftprobe-wrapper-test-') as tmp:
            folder = Path(tmp)
            shutil.copy2(COMPANION / 'gradlew', folder / 'gradlew')
            jar = folder / 'gradle/wrapper/gradle-wrapper.jar'
            jar.parent.mkdir(parents=True)
            jar.write_bytes(b'not-the-gradle-wrapper')
            run = subprocess.run(['bash', str(folder / 'gradlew'), '--version'],
                                 capture_output=True, text=True, timeout=15)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn('SHA256 mismatch', run.stderr + run.stdout)
            self.assertEqual(jar.read_bytes(), b'not-the-gradle-wrapper')

    def test_build_script_prefers_wrapper_not_installed_gradle(self):
        build = (ROOT / 'scripts/Build-Companion.ps1').read_text()
        self.assertIn('gradlew.bat', build)
        self.assertNotIn('Get-Command gradle ', build)
        self.assertIn('javac.exe', build)
        self.assertIn('-CheckOnly', (ROOT / 'CraftProbe.cmd').read_text())

    def test_version_consistency(self):
        version = (ROOT / 'VERSION').read_text().strip()
        self.assertEqual(version, '0.6.4.2')
        modprops = (COMPANION / 'gradle.properties').read_text()
        self.assertIn('mod_version=' + version, modprops)
        self.assertIn('CraftProbe v' + version, (ROOT / 'tui/CraftProbe.Tui/Program.cs').read_text())

    def test_wrapper_not_embedded_unverified(self):
        jar = COMPANION / 'gradle/wrapper/gradle-wrapper.jar'
        if jar.is_file():
            self.assertEqual(hashlib.sha256(jar.read_bytes()).hexdigest(), WRAPPER_SHA)


if __name__ == '__main__':
    unittest.main()
