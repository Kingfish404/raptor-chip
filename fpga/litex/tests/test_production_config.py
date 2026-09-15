"""Production CPU packing and removal of temporary board debug instrumentation."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

LITEX = Path(__file__).resolve().parents[1]
REPO = LITEX.parents[1]
sys.path.insert(0, str(LITEX / "cores"))
sys.path.insert(0, str(LITEX / "scripts"))
from cpu.raptor.core import Raptor


class ProductionConfigTest(unittest.TestCase):
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
        files = list((REPO / "hdl").rglob("*.sv")) + [
            LITEX / "ku15p_soc.py", LITEX / "cores/cpu/raptor/core.py",
            LITEX / "Makefile", LITEX / "mk/config.mk",
        ]
        for path in files:
            with self.subTest(path=path):
                text = path.read_text()
                for token in ("RAPT_DBG_ILA", "mark_debug", "with_ila", "dbg_reset", "insert_ila.tcl"):
                    self.assertNotIn(token, text)


if __name__ == "__main__":
    unittest.main()
