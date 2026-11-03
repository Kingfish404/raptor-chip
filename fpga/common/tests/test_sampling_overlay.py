import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "fpga/common/scripts"))
from rtl_pack import pack
from sampling_overlay import HOOKS, sampling_sources, source_digest


class SamplingOverlayTests(unittest.TestCase):
    def test_overlay_changes_only_disposable_copies_of_the_declared_hooks(self):
        before = source_digest(ROOT)
        with sampling_sources(ROOT) as (shadow, receipt):
            self.assertTrue(receipt["intrusive_hardware"])
            self.assertEqual(receipt["production_source_sha256"], before)
            for name in HOOKS:
                self.assertNotIn("RAPT_SAMPLING", (ROOT / name).read_text())
                self.assertIn("RAPT_SAMPLING", (shadow / name).read_text())
            self.assertIn("if (sample.restore_fire)",
                          (shadow / "rtl/core/backend/commit/rapt_csr.sv").read_text())
            self.assertIn("mtime <= restore_time_i;",
                          (shadow / "rtl/uncore/irq/rapt_clint.sv").read_text())
            self.assertTrue((shadow / "rtl/include/rapt_sample_if.svh").is_file())
            for path in (ROOT / "rtl").rglob("*"):
                relative = str(path.relative_to(ROOT))
                if path.is_file() and relative not in HOOKS:
                    self.assertEqual(path.read_bytes(), (shadow / relative).read_bytes(), relative)
            json.dumps(receipt)
        self.assertFalse(shadow.exists())
        self.assertEqual(source_digest(ROOT), before)

    def test_incompatible_source_fails_without_changing_the_input_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            for name in ("rtl", "sim/include", "sim/rtl"):
                shutil.copytree(ROOT / name, repo / name)
            top = repo / "rtl/rapt.sv"
            text = top.read_text()
            self.assertIn("    input clock,", text)
            top.write_text(text.replace("    input clock,", "    input wire clock,", 1))
            before = source_digest(repo)
            with self.assertRaisesRegex(RuntimeError, "overlay no longer matches"):
                with sampling_sources(repo):
                    self.fail("an incompatible overlay was accepted")
            self.assertEqual(source_digest(repo), before)

    @unittest.skipUnless(shutil.which("verilator"), "Verilator required")
    def test_legacy_flag_alone_cannot_enable_an_unwired_production_core(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "requires the FPGA --sampling"):
                pack(ROOT, Path(temporary), "small", "-DRAPT_SAMPLING")

    @unittest.skipUnless(shutil.which("verilator"), "Verilator required")
    def test_rv32_rv64_normal_exports_exclude_the_experimental_interface(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            for xlen in (32, 64):
                for preset in ("small", "default-w4"):
                    with self.subTest(xlen=xlen, preset=preset):
                        flags = "-DRAPT_RV64" if xlen == 64 else ""
                        normal = pack(ROOT, cache / "normal", preset, flags, immutable=True)
                        self.assertNotIn("rapt_sample_if", normal.read_text())
                        self.assertNotIn("sample_writeback_drain", normal.read_text())
                        with sampling_sources(ROOT) as (shadow, _receipt):
                            experiment = pack(shadow, cache / "experiment", preset,
                                              flags + " -DRAPT_SAMPLING", immutable=True)
                        text = experiment.read_text()
                        self.assertIn("interface rapt_sample_if", text)
                        self.assertIn("if (sample.restore_fire)", text)
                        self.assertIn("sample_writeback_drain", text)


if __name__ == "__main__":
    unittest.main()
