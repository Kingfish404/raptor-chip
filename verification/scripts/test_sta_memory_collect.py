import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[2] / "sim/scripts/sta.py"
SPEC = importlib.util.spec_from_file_location("sta_runner", RUNNER)
sta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sta)


class MemoryCollectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backend = self.root / "backend"
        self.work = self.root / "work"
        for name in ("scripts", "platforms/nangate45", "third_party"):
            (self.backend / name).mkdir(parents=True)
        (self.backend / "platforms/nangate45/platform.mk").touch()
        (self.backend / "Makefile").touch()
        self.script = self.backend / "scripts/yosys.tcl"
        self.script.write_text("yosys -import\nsynth -top memory_top -run begin\n")
        (self.backend / "scripts/ppa_summary.py").write_text("print('summary')\n")

    def test_isolated_adapter_preserves_backend_and_reuses_workspace(self):
        original = self.script.read_bytes()
        sta.prepare(self.backend, self.work, "nangate45")
        wrapper = self.work / "synth-scripts/yosys.tcl"
        self.assertEqual(wrapper.read_text(), sta.SYNTH_WRAPPER)
        timestamp = wrapper.stat().st_mtime_ns
        sta.prepare(self.backend, self.work, "nangate45")
        self.assertEqual(wrapper.stat().st_mtime_ns, timestamp)
        self.assertEqual(self.script.read_bytes(), original)
        self.assertEqual((self.work / "synth-scripts/ppa_summary.py").resolve(),
                         self.backend / "scripts/ppa_summary.py")

    def test_wrapper_symlink_is_not_overwritten(self):
        directory = self.work / "synth-scripts"
        directory.mkdir(parents=True)
        (directory / "yosys.tcl").symlink_to(self.script)
        original = self.script.read_bytes()
        with self.assertRaises(SystemExit):
            sta.prepare(self.backend, self.work, "nangate45")
        self.assertEqual(self.script.read_bytes(), original)

    @unittest.skipUnless(shutil.which("yosys"), "Yosys is not installed")
    def test_backend_reimport_still_collects_memory_before_synth(self):
        rtl = self.root / "memory.v"
        rtl.write_text("""module memory_top(input clock, enable,
    input [1:0] address, input [7:0] data, output [7:0] result);
  reg [7:0] memory [0:3];
  always @(posedge clock) if (enable) memory[address] <= data;
  assign result = memory[address];
endmodule
""")
        self.script.write_text(
            f"yosys -import\nyosys read_verilog {rtl}\nyosys proc\n"
            "synth -top memory_top -run begin\n"
            "yosys select -assert-none {t:$memrd*} {t:$memwr*} {t:$meminit*}\n"
            "yosys select -assert-count 1 {t:$mem_v2}\n"
            "yosys check -assert\n")
        (self.backend / "Makefile").write_text(
            ".PHONY: sta show\nsta:\n"
            '\tyosys -Q -T -p "tcl $(SCRIPT_DIR)/yosys.tcl"\n'
            "\tmkdir -p result/nangate45-rapt-50MHz\n"
            "\techo passed > result/nangate45-rapt-50MHz/sta.log\nshow:\n\t@:\n")
        result = subprocess.run(
            [sys.executable, str(RUNNER), "--backend", str(self.backend),
             "--work-dir", str(self.work), "--rtl", str(rtl),
             "--platform", "nangate45", "--frequency", "50"],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(result.stdout.index("Executing MEMORY_COLLECT"),
                        result.stdout.index("Executing SYNTH"))


if __name__ == "__main__":
    unittest.main()
