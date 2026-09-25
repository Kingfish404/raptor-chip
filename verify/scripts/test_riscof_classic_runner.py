#!/usr/bin/env python3
"""Check the classic DUT runner's fail-closed result handling (no RTL build)."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "verify/riscof/classic/plugins/raptor/riscof_raptor.py"
spec = importlib.util.spec_from_file_location("classic_raptor", PLUGIN)
module = importlib.util.module_from_spec(spec)

# Unit-test the runner without requiring the external RISCOF package.  The
# workflow installs the pinned package before invoking the actual plugin, but
# these tests only exercise helpers and fail-closed simulator handling.
riscof = types.ModuleType("riscof")
riscof.__path__ = []
riscof_utils = types.ModuleType("riscof.utils")
riscof_template = types.ModuleType("riscof.pluginTemplate")
riscof_template.pluginTemplate = type("pluginTemplate", (), {})
riscof.utils = riscof_utils
with patch.dict(sys.modules, {
        "riscof": riscof,
        "riscof.utils": riscof_utils,
        "riscof.pluginTemplate": riscof_template,
}):
    spec.loader.exec_module(module)


class RunnerTest(unittest.TestCase):
    def test_sail_pmp_capacity_matches_model_headers(self):
        for suite, config_name in (("classic", "raptor.json"), ("classic-nemu", "nemu.json")):
            with self.subTest(suite=suite):
                plugin = ROOT / "verify/riscof" / suite / "plugins/sail_cSim"
                pmp = json.loads((plugin / config_name).read_text())["memory"]["pmp"]
                self.assertEqual(pmp["count"], 16)
                self.assertEqual(pmp["usable_count"], 8)
                self.assertRegex((plugin / "env/model_test.h").read_text(),
                                 r"#define\s+RVMODEL_NUM_PMPS\s+8\b")

    def test_shards_partition_the_selected_suite(self):
        script = ROOT / "verify/scripts/filter_riscof_testlist.py"
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.yaml"
            output = Path(directory) / "output.json"
            tests = {f"/suite/rv32i_m/D/src/test_{i:02}.S":
                     {"macros": ["XLEN=32"]} for i in reversed(range(19))}
            source.write_text("".join(f"{name}:\n  macros:\n    - XLEN=32\n"
                                      for name in tests))
            base = [sys.executable, str(script), "--input", str(source),
                    "--output", str(output)]
            seen = set()
            for index in range(4):
                subprocess.run(base + ["--shard-count", "4", "--shard-index", str(index)],
                               check=True, capture_output=True)
                selected = json.loads(output.read_text())
                self.assertEqual(list(selected), sorted(tests)[index::4])
                self.assertFalse(seen.intersection(selected))
                seen.update(selected)
            self.assertEqual(seen, set(tests))
            subprocess.run(base, check=True, capture_output=True)
            self.assertEqual(json.loads(output.read_text()), tests)
            for count, index in [(0, 0), (4, -1), (4, 4)]:
                result = subprocess.run(base + ["--shard-count", str(count),
                                               "--shard-index", str(index)],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_pmp_boundary_relocation_for_both_duts(self):
        script = ROOT / "verify/scripts/filter_riscof_testlist.py"
        modes = ("na4", "napot", "tor", "off")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.yaml"
            output = Path(directory) / "output.yaml"
            source.write_text("".join(
                f"test_{mode}:\n"
                f"  test_path: /suite/rv32i_m/pmp/src/pmpm_misaligned_{mode}.S\n"
                "  macros:\n    - XLEN=32\n"
                for mode in modes))
            for target in ("raptor", "nemu"):
                with self.subTest(target=target):
                    result = subprocess.run(
                        [sys.executable, str(script), "--input", str(source),
                         "--output", str(output), "--target", target],
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    selected = json.loads(output.read_text())
                    self.assertEqual(len(selected), 4)
                    for mode in modes:
                        macros = selected[f"test_{mode}"]["macros"]
                        self.assertIn("XLEN=32", macros)
                        self.assertEqual("RVMODEL_PMP_REGION_OFFSET=16" in macros,
                                         mode != "off")
                    self.assertIn("relocated 3 PMP boundary tests", result.stdout)

    def exercise(self, output="HIT GOOD TRAP\n", rc=0,
                 signature="12345678\n", timeout=False, stale=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            sig = path / "DUT-raptor.signature"
            if stale:
                sig.write_text("deadbeef\n")
            runner = object.__new__(module.raptor)
            runner.npc_bin = "/test path/npc"
            runner.mrom_img = "/test path/rom"
            runner.nsim_home = directory
            runner.timeout = "10"
            runner.mem_random_delay = "0"
            runner.mem_random_seed = "1"

            def simulate(command, **kwargs):
                self.assertEqual(command[0], runner.npc_bin)
                self.assertEqual(kwargs["timeout"], 40)
                self.assertFalse(sig.exists(), "stale signature must be displaced")
                kwargs["stdout"].write(output)
                if signature is not None:
                    sig.write_text(signature)
                if timeout:
                    raise subprocess.TimeoutExpired(command, 40)
                return subprocess.CompletedProcess(command, rc)

            with patch.object(module.subprocess, "run", side_effect=simulate):
                ok = runner._run_dut("test.bin", str(sig), 0x1000, 0x1004, directory)
            status = json.loads((path / "dut-run.json").read_text())
            self.assertEqual(ok, status["completed"])
            if not ok:
                self.assertEqual(sig.read_text(), "")
                if signature is not None:
                    self.assertEqual(Path(str(sig) + ".partial").read_text(), signature)
            return status

    def test_success(self):
        self.assertTrue(self.exercise(stale=True)["completed"])

    def test_nonzero_exit(self):
        self.assertEqual(self.exercise(rc=1)["reason"], "simulator-exit")

    def test_no_success_marker(self):
        self.assertEqual(self.exercise(output="stopped\n")["reason"],
                         "missing-successful-termination")

    def test_timeout_even_with_marker(self):
        self.assertEqual(self.exercise(output="Wall-clock timeout\nHIT GOOD TRAP\n")["reason"],
                         "simulator-timeout")

    def test_external_timeout(self):
        self.assertEqual(self.exercise(timeout=True)["reason"], "runner-timeout")

    def test_missing_signature_cannot_reuse_stale(self):
        self.assertEqual(self.exercise(signature=None, stale=True)["reason"], "missing-signature")

    def test_truncated_or_malformed_signature(self):
        for value in ("", "xyz\n", "12345678\n87654321\n"):
            with self.subTest(value=value):
                self.assertEqual(self.exercise(signature=value)["reason"], "invalid-signature")


if __name__ == "__main__":
    unittest.main()
