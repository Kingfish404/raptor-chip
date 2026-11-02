import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from run_samples import matched_window

ROOT = Path(__file__).resolve().parents[2]


class WindowTests(unittest.TestCase):
    xlen = 64

    @classmethod
    def setUpClass(cls):
        if not shutil.which("c++"):
            raise unittest.SkipTest("C++ compiler required")
        cls.temporary = tempfile.TemporaryDirectory()
        cls.work = Path(cls.temporary.name)
        generated = cls.work / "generated"
        generated.mkdir()
        (generated / "autoconf.h").write_text(f"#define CONFIG_ISA{cls.xlen} 1\n")
        driver = cls.work / "driver.cc"
        driver.write_text('''#include <generated/autoconf.h>
#include <sample_window.h>
#include <cstdlib>
#include <cstring>
int main(int argc, char **argv) {
  unsigned width = std::strtoul(argv[2], nullptr, 10);
  bool early = argc > 3 && !std::strcmp(argv[3], "early");
  bool traps = argc > 3 && !std::strcmp(argv[3], "traps");
  bool threads = argc > 3 && !std::strcmp(argv[3], "threads");
#ifdef CONFIG_ISA64
  constexpr uint64_t Root = 0x800000000009452a, Alias = 0x800090000009452a;
  constexpr uint64_t OtherRoot = 0x8000900000012345;
  constexpr uint64_t Worker = 0x3fe0ec5880, Controller = 0x3ff7dadde0;
#else
  constexpr uint64_t Root = 0x8009452a, Alias = 0x8049452a, OtherRoot = 0x80412345;
  constexpr uint64_t Worker = 0xec5880, Controller = 0xf7dadde0;
#endif
  if (threads) {
    sample_window_set_user_satp(Root);
    sample_window_set_user_thread(Worker);
  }
  sample_window_configure(argv[1], 4, 16, false, 0, true);
  sample_window_commit(0x20000000, 0x13, 1, 0, false);
  if (!sample_window_finish(true)) return 2; // Reset is not a measured run.
  sample_window_activate();
  unsigned count = 0;
  for (unsigned cycle = 1; cycle <= (early ? 5u : 100u); cycle++) {
    bool fault = traps && cycle == 5;
    uint32_t inst = traps && cycle == 2 ? 0x73 :
                    traps && cycle == 8 ? 0x100073 : 0x13;
    for (unsigned slot = 0; slot < width; slot++) {
      if (!sample_is_retired(inst, fault)) continue;
      unsigned privilege = threads && cycle == 14 ? 1 : 0;
      uint64_t satp = threads && cycle == 12 ? OtherRoot : Alias;
      uint64_t tp = threads && cycle >= 5 && cycle <= 8 ? Controller : Worker;
      if (!sample_window_accept(privilege, satp, tp)) continue;
      sample_window_commit(0x80000000 + count * 4, inst, cycle, count, !count);
      count++;
    }
    if (sample_window_cycle(cycle, count)) break;
  }
  return sample_window_finish(true) ? 0 : 1;
}
''')
        cls.executable = cls.work / "window-driver"
        subprocess.run(["c++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(cls.work), "-I", str(ROOT / "sim/include"), str(driver),
                        str(ROOT / "sim/csrc/monitor/cpu/sample_window.cc"),
                        "-o", str(cls.executable)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_window(self, width, early=False, traps=False, threads=False):
        output = Path(tempfile.mkdtemp(dir=self.work)) / "window.json"
        process = subprocess.run([str(self.executable), str(output), str(width)] +
                                 (["early"] if early else ["traps"] if traps else
                                  ["threads"] if threads else []), check=False)
        return process.returncode, json.loads(output.read_text())

    def test_single_and_dual_commit_measure_the_same_instruction_stream(self):
        old_rc, before = self.run_window(1)
        new_rc, after = self.run_window(2)
        self.assertEqual((old_rc, new_rc), (0, 0))
        point = dict(start=1000, warmup=4, instructions=16, start_pc="0x80000010")
        measurement = matched_window(before, after, point)
        self.assertEqual(measurement["baseline_cycles"], 16)
        self.assertEqual(measurement["candidate_cycles"], 8)
        self.assertLess(len(before["boundaries"]), 100)
        end = next(row for row in after["boundaries"] if row["instructions"] == 20)
        end["signature"] = "bad"
        with self.assertRaisesRegex(ValueError, "streams diverged"):
            matched_window(before, after, point)
        after["start_pc"] = "0xdeadbeef"
        with self.assertRaisesRegex(ValueError, "measurement PC"):
            matched_window(before, after, point)

    def test_early_stop_is_explicitly_incomplete(self):
        returncode, window = self.run_window(1, early=True)
        self.assertEqual(returncode, 1)
        self.assertFalse(window["complete"])
        with self.assertRaisesRegex(ValueError, "incomplete"):
            matched_window(window, window, dict(warmup=4, instructions=16))

    def test_fault_and_system_exception_cycles_cost_time_but_do_not_retire(self):
        before_rc, before = self.run_window(1)
        after_rc, after = self.run_window(1, traps=True)
        self.assertEqual((before_rc, after_rc), (0, 0))
        result = matched_window(before, after,
                                dict(start=0, warmup=4, instructions=16, start_pc="0x80000010"))
        self.assertEqual(result["baseline_cycles"], 16)
        self.assertEqual(result["candidate_cycles"], 17)

    def test_same_address_space_other_thread_and_kernel_cycles_remain_charged(self):
        old_rc, before = self.run_window(1)
        new_rc, after = self.run_window(1, threads=True)
        self.assertEqual((old_rc, new_rc), (0, 0))
        measured = matched_window(before, after, dict(start=0, warmup=4, instructions=16))
        self.assertEqual(measured["baseline_cycles"], 16)
        self.assertEqual(measured["candidate_cycles"], 22)
        worker = 0x3FE0EC5880 if self.xlen == 64 else 0xEC5880
        self.assertEqual(after["retirement_domain"]["thread_pointer"], hex(worker))


class Window32Tests(WindowTests):
    xlen = 32


if __name__ == "__main__":
    unittest.main()
