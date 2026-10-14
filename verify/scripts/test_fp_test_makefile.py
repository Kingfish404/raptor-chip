"""Check that the public FP Make targets resolve to maintained guest sources."""
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[2]
FP = REPO / "app/tests/fp"


class FpMakefileTest(unittest.TestCase):
    def test_guest_sources_for_both_xlens(self):
        targets = ["arith", "fcsr", "d-arith", "double", "double-unaligned"]
        cases = ["arith", "fcsr", "rm-illegal", "fs", "fs-mem", "compressed-mem",
                 "d-arith", "minmax", "compare", "convert", "fma", "divsqrt"]
        targets += [name + "-spike" for name in cases]
        targets += ["npc-" + name for name in cases]
        env = {k: v for k, v in os.environ.items()
               if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
        for xlen in (32, 64):
            for target in targets:
                with self.subTest(xlen=xlen, target=target):
                    result = subprocess.run(
                        ["make", "--no-print-directory", "-n", "-C", str(FP),
                         f"RAPTOR_HOME={REPO}", f"ISA=rv{xlen}", "MAKE=:", target],
                        env=env, text=True, capture_output=True, check=True)
                    lines = result.stdout.replace("\\\n", " ").splitlines()
                    compiles = [shlex.split(line) for line in lines
                                if line.startswith("riscv64-unknown-elf-gcc ")]
                    self.assertEqual(len(compiles), 1, result.stdout)
                    sources = [arg for arg in compiles[0] if arg.endswith(".S")]
                    self.assertEqual(len(sources), 1, result.stdout)
                    self.assertTrue((FP / sources[0]).is_file(), sources[0])
                    if target == "double":
                        self.assertEqual(sources, ["fp_d_arith.S"])
                        self.assertIn(f"-march=rv{xlen}imafdc", compiles[0])

    def test_coverage_guest_sources_exist(self):
        manifest = json.loads((REPO / "verify/riscof/raptor-rv64s/requirements.json").read_text())
        for entry in manifest["requirements"]:
            for value in entry.get("tests", []):
                match = re.match(r"((?:app|verify)/[^\s()]+)", value)
                if match:
                    with self.subTest(source=match[1]):
                        self.assertTrue((REPO / match[1]).is_file(), value)


if __name__ == "__main__":
    unittest.main()
