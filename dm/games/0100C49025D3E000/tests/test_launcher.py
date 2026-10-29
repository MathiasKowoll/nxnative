"""FC27 launcher dry-run contract, compiled from the same source as the app."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[2]


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('xcrun'), 'macOS with Xcode tools')
class FC27Launcher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.work = Path(cls.tmp.name) / 'work'
        cls.work.mkdir()
        cls.exe = Path(cls.tmp.name) / 'FC 27'
        cmd = ['xcrun', 'clang', '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
               '-DFC27_BINARY="fc27-native"', '-DFC27_PATCHED_DIR="patched-v262144"',
               str(HERE / 'app/launcher.m'), '-framework', 'Cocoa', '-o', str(cls.exe)]
        build = subprocess.run(cmd, capture_output=True, text=True)
        if build.returncode:
            raise AssertionError(build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_dry_run_uses_the_fc27_host_and_profile(self):
        env = dict(os.environ, FC27_WORK=str(self.work), FC27_HOST_BINARY='/usr/bin/true', FC27_LAUNCHER_DRYRUN='1')
        run = subprocess.run([str(self.exe)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        out = run.stdout
        self.assertIn(f"cd '{self.work}'", out)
        self.assertIn("export DM_FPS_TARGET='60'", out)
        self.assertIn("export DM_AUDIO='1'", out)
        self.assertIn("unset DM_AUDIO_OFF", out)
        self.assertIn("export DM_PRESENT_INTERVAL='display'", out)
        self.assertIn("export DM_PRESENT_HZ='60'", out)
        self.assertIn("export DM_PRESENT_LINK='0'", out)
        self.assertIn("export DM_PRESENT_UPSCALE='metalfx'", out)
        self.assertIn(f"export DM_NVN_SHMAP='{self.work}/profile/shader_map.tsv'", out)
        self.assertIn("export DM_PSO_PREBUILD='1'", out)
        self.assertIn("export DM_PSO_PREPARE='1'", out)
        unset = next(line.split()[1:] for line in out.splitlines() if line.startswith('unset '))
        self.assertIn('DM_PSO_MANIFEST', unset)
        self.assertIn(f"export DM_PSO_ARCHIVE='{self.work}/pipeline-cache-fc27'", out)
        self.assertIn("export DM_QOS_MAP='1'", out)
        self.assertIn("'/usr/bin/true'", out)
        self.assertIn(f"'{self.work}/patched-v262144' 'main' 'sdk'", out)
        self.assertNotIn("FC27_FPS60", out)
        self.assertNotIn("TOTK_SHADER_CACHE", out)


if __name__ == '__main__':
    unittest.main()
