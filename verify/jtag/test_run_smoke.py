"""Host orchestration checks with fake tools, independent of RTL builds."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RunnerTest(unittest.TestCase):
    def test_isolated_run_and_failed_client(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            npc = base / 'npc'
            npc.write_text(f'#!{sys.executable}\n' + '''import os,time,sys
from pathlib import Path
assert '--jtag-port=19824' in sys.argv
Path(__file__).with_suffix('.pid').write_text(str(os.getpid()))
print('waiting for OpenOCD', flush=True)
while True: time.sleep(.1)
''')
            ocd = base / 'ocd'
            ocd.write_text(f'#!{sys.executable}\n' + '''import os,sys
assert 'set RAPT_JTAG_PORT 19824' in sys.argv
assert 'set RAPT_GDB_PORT disabled' in sys.argv
print('Examined RISC-V core misa=0x4014112f')
print('t0 (/32): 0xcafef00d')
print('t0 (/32): 0x12345678')
sys.exit(int(os.environ.get('FAKE_RC', '0')))
''')
            for path in (npc, ocd):
                path.chmod(0o755)
            command = [sys.executable, '-B', str(ROOT / 'verify/jtag/run_smoke.py'),
                       'halt', '--npc', str(npc), '--openocd', str(ocd),
                       '--config', str(ROOT / 'hdl/configs/default/rapt_config.svh'),
                       '--openocd-config', str(ROOT / 'verify/jtag/openocd.cfg'),
                       '--port', '19824', '--log-root', str(base / 'logs')]
            for rc in (0, 7):
                result = subprocess.run(command, env={**os.environ, 'FAKE_RC': str(rc)},
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0 if rc == 0 else 1, result.stderr)
                pid = int(npc.with_suffix('.pid').read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            self.assertEqual(len(list((base / 'logs').iterdir())), 2)
            # Resolve the binary through the submake with its selected profile.
            sim = base / 'sim'
            sim.mkdir()
            (sim / 'Makefile').write_text(
                'all:\n\t@test "$(BUILD_PROFILE)" = isolated\n'
                'print-jtag-bin:\n\t@echo ' + str(npc) + '\n')
            result = subprocess.run([
                'make', '-s', '-C', str(ROOT / 'verify/jtag'), 'openocd-halt-reg',
                f'NSIM_HOME={sim}', 'BUILD_PROFILE=isolated',
                f'OPENOCD={ocd}', 'JTAG_PORT=19824',
                f'BUILD_DIR={base / "make-logs"}', f'PYTHON={sys.executable} -B'],
                capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


    def test_port_collision_does_not_reach_client(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            npc = base / 'npc'
            npc.write_text(f'#!{sys.executable}\nimport sys\nprint("bind: address in use")\nsys.exit(1)\n')
            npc.chmod(0o755)
            result = subprocess.run([
                sys.executable, '-B', str(ROOT / 'verify/jtag/run_smoke.py'), 'scan',
                '--npc', str(npc), '--openocd', '/must-not-run',
                '--config', str(ROOT / 'hdl/configs/default/rapt_config.svh'),
                '--openocd-config', str(ROOT / 'verify/jtag/openocd.cfg'),
                '--log-root', str(base / 'logs')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn('child exited', result.stderr)
