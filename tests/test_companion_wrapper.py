"""Offline regression tests for CraftProbe's pinned Gradle companion bootstrap."""
from pathlib import Path
import hashlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMPANION = ROOT / 'companion' / 'NeoForge-1.21.1'
DIST_SHA = '61ad310d3c7d3e5da131b76bbf22b5a4c0786e9d892dae8c1658d4b484de3caa'
WRAPPER_SHA = '7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172'


class GradleWrapperTests(unittest.TestCase):
    def test_pinned_distribution(self):
        properties = (COMPANION / 'gradle/wrapper/gradle-wrapper.properties').read_text()
        self.assertIn('gradle-8.14-bin.zip', properties)
        self.assertIn('distributionSha256Sum=' + DIST_SHA, properties)
        self.assertEqual(len(DIST_SHA), 64)

    def test_wrapper_bootstraps_and_checksums_on_both_platforms(self):
        win = (COMPANION / 'scripts/Ensure-GradleWrapper.ps1').read_text()
        sh = (COMPANION / 'gradlew').read_text()
        bat = (COMPANION / 'gradlew.bat').read_text()
        for source in (win, sh):
            self.assertIn(WRAPPER_SHA, source)
            self.assertIn('https://raw.githubusercontent.com/gradle/gradle/v8.14.0/gradle/wrapper/gradle-wrapper.jar', source)
            self.assertIn('https://services.gradle.org/distributions/gradle-8.14-wrapper.jar', source)
            self.assertIn('SHA256' if source is win else 'sha256', source)
        self.assertIn('Ensure-GradleWrapper.ps1', bat)
        self.assertLess(win.index('raw.githubusercontent.com'), win.index('services.gradle.org'))
        self.assertLess(sh.index('raw.githubusercontent.com'), sh.index('services.gradle.org'))
        self.assertIn('org.gradle.wrapper.GradleWrapperMain', bat)
        self.assertIn('org.gradle.wrapper.GradleWrapperMain', sh)

    def test_build_script_prefers_wrapper_not_installed_gradle(self):
        build = (ROOT / 'scripts/Build-Companion.ps1').read_text()
        self.assertIn('gradlew.bat', build)
        self.assertNotIn('Get-Command gradle ', build)
        self.assertIn('javac.exe', build)
        self.assertIn('-CheckOnly', (ROOT / 'CraftProbe.cmd').read_text())

    def test_version_is_consistent(self):
        version = (ROOT / 'VERSION').read_text().strip()
        self.assertEqual(version, '0.6.4.1')
        modprops = (COMPANION / 'gradle.properties').read_text()
        self.assertIn('mod_version=' + version, modprops)
        self.assertIn('CraftProbe v' + version, (ROOT / 'tui/CraftProbe.Tui/Program.cs').read_text())

    def test_wrapper_not_embedded_unverified(self):
        wrapper_jar = COMPANION / 'gradle/wrapper/gradle-wrapper.jar'
        if wrapper_jar.exists():
            self.assertEqual(hashlib.sha256(wrapper_jar.read_bytes()).hexdigest(), WRAPPER_SHA)


if __name__ == '__main__':
    unittest.main()
