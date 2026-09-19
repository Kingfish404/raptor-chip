"""Production CPU packing and removal of temporary board debug instrumentation."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch
from litex.build.xilinx.vivado import XilinxVivadoCommands

LITEX = Path(__file__).resolve().parents[1]
REPO = LITEX.parents[1]
sys.path.insert(0, str(LITEX / "cores"))
sys.path.insert(0, str(LITEX / "scripts"))
sys.path.insert(0, str(LITEX))
from cpu.raptor.core import Raptor
from ku15p_soc import configure_ku15p_timing


class ProductionConfigTest(unittest.TestCase):
    def test_mshr_lookup_signals_precede_generate(self):
        source = (REPO / "hdl/memory/rapt_l1d.sv").read_text()
        instance = source.index("begin : g_mshr")
        for signal in ("l1d_addr", "tag_hit", "load_way_hit"):
            with self.subTest(signal=signal):
                declaration = re.search(r"\blogic\s+(?:\[[^\]]+\]\s+)?" + signal + r"\s*;", source)
                self.assertIsNotNone(declaration)
                self.assertLess(declaration.start(), instance,
                                "MSHR ports must not bind forward references as implicit nets")

    def test_vivado_rejects_lookup_address_width_mismatches(self):
        platform = Mock()
        platform.toolchain.pre_synthesis_commands = XilinxVivadoCommands()
        configure_ku15p_timing(platform, Mock(), with_mig=True)
        command, = platform.toolchain.pre_synthesis_commands.resolve(Mock())
        # LiteX resolves signal names, then Vivado substitutes build_name.
        self.assertEqual(command.format(build_name="test_soc"),
                         "set_msg_config -id \"Synth 8-689\" "
                         "-string \"port connection 'lookup_addr'\" -new_severity ERROR")

    def test_cpu_pack_and_finalize(self):
        for variant in ("linux32", "linux64"):
            with self.subTest(variant=variant):
                platform = Mock()
                with patch.dict(os.environ, {"RAPT_PACK_VFLAGS": "", "RAPT_CONFIG": "default"}), patch(
                    "isolated_pack.pack", return_value=Path("/private/rapt_pack.sv")
                ) as pack:
                    Raptor.add_sources(platform, variant, pmem_size=0x40000000)
                    flags = pack.call_args.args[3].split()
                    self.assertEqual(pack.call_args.args[2], "default")
                    self.assertIn("-DRAPT_LINUX", flags)
                    self.assertEqual("-DRAPT_RV64" in flags, variant == "linux64")
                    self.assertIn("-DRAPT_PMEM_BYTES=1073741824", flags)
                    for name in ("ROB_SIZE", "PHY_SIZE", "INTEGER_ISSUE_PORTS",
                                 "DECODE_WIDTH", "RENAME_WIDTH", "DISPATCH_WIDTH", "COMMIT_WIDTH"):
                        self.assertFalse(any(f.startswith("-DRAPT_" + name) for f in flags))
                cpu = Raptor(platform, variant=variant)
                cpu.set_reset_address(0x20000000)
                with patch.object(cpu, "add_sources") as add_sources:
                    cpu.do_finalize()
                add_sources.assert_called_once_with(platform, variant, pmem_size=None)

    def test_no_board_debug_hooks(self):
        files = list((REPO / "hdl").rglob("*.sv")) + list((REPO / "hdl").rglob("*.svh")) + [
            LITEX / "ku15p_soc.py", LITEX / "cores/cpu/raptor/core.py",
            LITEX / "Makefile", LITEX / "mk/config.mk",
        ]
        for path in files:
            with self.subTest(path=path):
                text = path.read_text()
                for token in ("RAPT_DBG_ILA", "mark_debug", "with_ila", "dbg_reset",
                              "insert_ila.tcl", "RAPT_MEMSPEED_TRACE", "rapt_memspeed_trace",
                              "--rapt-memspeed-trace", "MEMSPEED_TRACE", "RAPT_DEBUG_PMP"):
                    self.assertNotIn(token, text)

    @unittest.skipUnless(shutil.which("verilator"), "requires Verilator preprocessor")
    def test_simulator_views_are_excluded_from_synthesis(self):
        for bits in (32, 64):
            for source, probe in (("rapt_backend.sv", "pipe_decode_state"),
                                  ("rapt_iq.sv", "g_iq_pc_probe")):
                for synthesis in (False, True):
                    with self.subTest(bits=bits, source=source, synthesis=synthesis):
                        command = ["verilator", "-E", "-P",
                                   "-I" + str(REPO / "hdl/configs/default"),
                                   "-I" + str(REPO / "hdl/include"),
                                   "-I" + str(REPO / "hdl/include/npc"),
                                   "-I" + str(REPO / "hdl/include/dpic_mock")]
                        if bits == 64:
                            command.append("-DRAPT_RV64")
                        if synthesis:
                            command.append("-DSYNTHESIS")
                        command.append(str(REPO / "hdl/backend" / source))
                        result = subprocess.run(command, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(probe in result.stdout, not synthesis)


if __name__ == "__main__":
    unittest.main()
