#!/usr/bin/env python3
"""Tests for rtl_structure_check.py on small synthetic trees."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name('rtl_structure_check.py')


def run(files):
    with tempfile.TemporaryDirectory() as tmp:
        rtl = Path(tmp) / 'rtl'
        for rel, text in files.items():
            path = rtl / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return subprocess.run([sys.executable, str(SCRIPT), '--rtl', str(rtl)],
                              capture_output=True, text=True)


GOOD = {
    'rapt.sv': 'module rapt;\n  rapt_core core ();\n  rapt_l2_subsystem l2 ();\nendmodule\n',
    'core/rapt_core.sv': 'module rapt_core;\n  rapt_stream_queue q ();\nendmodule\n',
    'uncore/rapt_l2_subsystem.sv': 'module rapt_l2_subsystem;\n`ifdef RAPT_L2_EN\n`endif\n'
                                   'endmodule\n',
    'common/rapt_stream_queue.sv': 'module rapt_stream_queue; endmodule\n',
}


class StructureCheckTest(unittest.TestCase):
    def test_layered_tree_passes(self):
        result = run(GOOD)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_core_must_not_instantiate_uncore(self):
        files = dict(GOOD)
        files['core/rapt_core.sv'] = 'module rapt_core;\n  rapt_l2_subsystem l2 ();\nendmodule\n'
        result = run(files)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('core instantiates rapt_l2_subsystem from uncore', result.stdout)

    def test_core_must_not_test_l2_macros(self):
        files = dict(GOOD)
        files['core/rapt_core.sv'] = 'module rapt_core;\n`ifdef RAPT_L2_EN\n`endif\nendmodule\n'
        result = run(files)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('tests an L2 macro', result.stdout)

    def test_l2tlb_macros_are_core_owned(self):
        files = dict(GOOD)
        files['core/rapt_core.sv'] = 'module rapt_core;\n`ifdef RAPT_L2TLB_EN\n`endif\nendmodule\n'
        self.assertEqual(run(files).returncode, 0)

    def test_files_outside_zones_fail(self):
        files = dict(GOOD)
        files['stray.sv'] = 'module stray; endmodule\n'
        result = run(files)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stray.sv: not in a known zone', result.stdout)


if __name__ == '__main__':
    unittest.main()
