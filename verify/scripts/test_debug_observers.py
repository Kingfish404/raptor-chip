#!/usr/bin/env python3
"""Elaborate optional RTL observers so hierarchy changes cannot silently break them."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HDL = ROOT / "hdl"


@unittest.skipUnless(shutil.which("verilator"), "requires Verilator")
class DebugObserversTest(unittest.TestCase):
    def elaborate(self, top, preset, sources, defines):
        with tempfile.TemporaryDirectory(prefix="raptor-observers-") as output:
            command = ["verilator", "--lint-only", "--timing", "-Wno-fatal",
                       "--timescale", "1ns/1ps", "--top-module", top,
                       "--Mdir", output]
            command += ["-D" + define for define in defines]
            command += ["-I" + str(path) for path in (
                HDL / "configs" / preset, HDL / "include",
                HDL / "include/dpic_mock", HDL / "include/npc",
                ROOT / "sim/include", ROOT / "sim/rtl")]
            command += [str(HDL / "rapt_pkg.sv")]
            command += [str(path) for path in sorted(HDL.rglob("*.sv"))
                        if path.name != "rapt_pkg.sv"]
            command += [str(ROOT / path) for path in sources]
            result = subprocess.run(command, cwd=ROOT, capture_output=True,
                                    text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_npc_axi_speculation_and_lrsc_observers(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen):
                defines = ["RAPT_AXI_OBSERVE", "RAPT_SPEC_OBSERVE", "RAPT_LRSC_OBSERVE"]
                if xlen == 64:
                    defines.append("RAPT_RV64")
                self.elaborate("raptSoC", "default", ["sim/rtl/rapt_npc_soc.sv"], defines)

    def test_pin_level_heartbeat_and_commit_observers(self):
        # The physical RNP interface is RV32 only; exercise one and two commit slots.
        for preset in ("small", "middle"):
            with self.subTest(preset=preset):
                self.elaborate("rapt_tb_top", preset, ["sim/rtl/wrap_rnp_soc.sv",
                    "sim/tb/rapt_tb_mem.sv", "sim/tb/rapt_tb_top.sv"], ["RAPT_TB_EBREAK_HALT"])


if __name__ == "__main__":
    unittest.main()
