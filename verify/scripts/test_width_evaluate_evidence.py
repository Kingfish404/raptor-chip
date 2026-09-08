"""Check partial-run evidence, independently of simulator correctness."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import width_evaluate


class EvidenceTest(unittest.TestCase):
    def run_failure(self, first_succeeds):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ('ref', 'boot', 'sim', 'bit-riscv32-npc.bin', 'mul-longlong-riscv32-npc.bin'):
                (root / name).write_bytes(b'fixture')
            out = root / 'out'
            out.mkdir()
            (out / 'results.json').write_text('{"complete": true}')
            args = ['width_evaluate.py', '--profile', f'test={root}/sim', '--output', str(out),
                    '--reference', str(root / 'ref'), '--boot', str(root / 'boot'),
                    '--images', str(root), '--case', 'bit', '--case', 'mul-longlong']
            responses = [subprocess.TimeoutExpired('sim', 120)]
            if first_succeeds:
                responses.insert(0, subprocess.CompletedProcess([], 0, 'HIT GOOD TRAP\n#inst: 1, cycle: 2\n'))
            with patch.object(sys, 'argv', args), patch.object(width_evaluate.subprocess, 'run', side_effect=responses):
                with self.assertRaises(subprocess.TimeoutExpired):
                    width_evaluate.main()
            result = json.loads((out / 'results.json').read_text())
            self.assertFalse(result['complete'])
            self.assertFalse(result['profiles'][0]['complete'])
            self.assertEqual(len(result['profiles'][0]['cases']), int(first_succeeds))
            self.assertIn('binary_sha256', result['profiles'][0])

    def test_first_failure_invalidates_old_success(self):
        self.run_failure(False)

    def test_second_failure_preserves_first_case(self):
        self.run_failure(True)

    def test_changed_inputs_do_not_produce_complete_report(self):
        for changed_name in ('sim', 'ref', 'boot', 'bit-riscv32-npc.bin'):
            with self.subTest(changed_name=changed_name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                for name in ('sim', 'ref', 'boot', 'bit-riscv32-npc.bin'):
                    (root / name).write_bytes(b'original')
                out = root / 'out'
                args = ['width_evaluate.py', '--profile', f'test={root}/sim',
                        '--output', str(out), '--reference', str(root / 'ref'),
                        '--boot', str(root / 'boot'), '--images', str(root), '--case', 'bit']

                def mutate(*unused_args, **unused_kwargs):
                    (root / changed_name).write_bytes(b'replaced during execution')
                    return subprocess.CompletedProcess([], 0, 'HIT GOOD TRAP\n#inst: 1, cycle: 2\n')

                with patch.object(sys, 'argv', args), patch.object(
                        width_evaluate.subprocess, 'run', side_effect=mutate):
                    with self.assertRaisesRegex(RuntimeError, 'test input changed during'):
                        width_evaluate.main()
                result = json.loads((out / 'results.json').read_text())
                self.assertFalse(result['complete'])
                self.assertFalse(result['profiles'][0]['complete'])
                self.assertEqual(result['profiles'][0]['cases'], [])
                self.assertIn('HIT GOOD TRAP', (out / 'test-bit.log').read_text())


if __name__ == '__main__':
    unittest.main()
