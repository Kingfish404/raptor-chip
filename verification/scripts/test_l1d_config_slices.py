"""Check that the preset matrix only accepts the intended RV32-only rejection."""

import contextlib
import io
from pathlib import Path
import shutil
import tempfile
import unittest

from check_l1d_config_slices import check_rv64_guard, rv64_guard_include


@unittest.skipUnless(shutil.which("verilator"), "Verilator required")
class Rv32OnlyPresetTest(unittest.TestCase):
    def probe(self, source, rejected):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rapt_config.svh"
            path.write_text(source)
            with contextlib.redirect_stderr(io.StringIO()):
                if rejected:
                    with self.assertRaises(SystemExit):
                        check_rv64_guard(path, "fixture is RV32 only")
                else:
                    check_rv64_guard(path, "fixture is RV32 only")

    def test_expected_rejection(self):
        source = '`ifdef RAPT_RV64\n`include "fixture is RV32 only"\n`endif\n'
        self.assertEqual(rv64_guard_include(source), "fixture is RV32 only")
        self.probe(source, rejected=False)

    def test_accepting_rv64_is_a_failure(self):
        self.probe('`define RAPT_XLEN 64\n', rejected=True)

    def test_other_errors_cannot_replace_the_guard(self):
        self.probe('`include "unrelated missing file"\n', rejected=True)

    def test_additional_errors_are_not_ignored(self):
        self.probe('`include "fixture is RV32 only"\n'
                   '`include "unrelated missing file"\n', rejected=True)


if __name__ == "__main__":
    unittest.main()
