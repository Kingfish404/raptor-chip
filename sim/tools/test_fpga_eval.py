#!/usr/bin/env python3
"""Exercise the real harness with fake make/git/simulator tools, without RTL builds."""

import contextlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fpga_eval_summary as summary

SPEC = importlib.util.spec_from_file_location(
    "eval_fpga", Path(__file__).resolve().parents[1] / "scripts" / "eval-fpga.py")
sys.path.insert(0, str(Path(SPEC.origin).parent))
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class CancellationTests(unittest.TestCase):
    def test_term_cleans_owned_child_group(self):
        with tempfile.TemporaryDirectory() as folder:
            pids = Path(folder) / 'pids.json'
            code = (
                'import json,os,subprocess,sys,time; from pathlib import Path; '
                'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); '
                'Path(sys.argv[1]).write_text(json.dumps([os.getpid(),child.pid])); time.sleep(60)'
            )

            def cancel():
                # This signal reaches the temporary handler installed by the runner.
                os.kill(os.getpid(), signal.SIGTERM)

            with harness.stop_on_signals() as stop:
                timer = threading.Timer(0.5, cancel)
                timer.start()
                try:
                    rc = harness.run_command(
                        [sys.executable, '-c', code, str(pids)], stop=stop,
                        stdout=subprocess.DEVNULL)
                finally:
                    timer.cancel()
                    timer.join()
            self.assertEqual(rc, -signal.SIGTERM)
            for pid in json.loads(pids.read_text()):
                stat = Path(f'/proc/{pid}/stat')
                self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z')

    def test_cancel_file_prevents_process_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            cancel = Path(folder) / 'cancel'
            cancel.touch()
            with patch.object(harness.subprocess, 'Popen') as popen:
                self.assertEqual(harness.run_command(
                    ['unused'], stop=threading.Event(), cancel_file=cancel), -signal.SIGTERM)
                popen.assert_not_called()


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eval fixture ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tree = self.root / "tree"
        (self.tree / "sim").mkdir(parents=True)
        self.image(self.tree / "linux/dts/spike-rv64gc.dts")
        self.cal = self.root / "wb" / "cal"
        self.cal.mkdir(parents=True)
        (self.cal / "latency.env").write_text("RL=20\nWL=30\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.make_tool("git", "import sys\nprint('fake-head' if 'rev-parse' in sys.argv else '')\n")
        self.make_tool("make", """import os, shlex, sys
if os.environ.get('FAKE_BUILD_FAIL') and 'all' in sys.argv:
    sys.exit(7)
if 'print-npc-exec' in sys.argv:
    print(shlex.join([os.environ['FAKE_SIM'], '-r', 'fake mrom.bin']))
""")
        self.make_tool("fake-sim", """import json, os, sys
from pathlib import Path
print('FAKE_ARGV=' + json.dumps(sys.argv[1:]))
name = Path(sys.argv[-1]).name
if os.environ.get('FAKE_RUN_FAIL') == name:
    print('[FAIL]')
    sys.exit(3)
if name.startswith('memprobe'):
    print('MEMPROBE chase 1024 cycles_per_access=4.61')
    print('MEMPROBE store 1024 cycles_per_access=32.40')
    print('MEMPROBE verify=1')
elif name.startswith('coremark'):
    print('CoreMark ROI cycles : 12345')
    print('Correct operation validated')
elif name.startswith('pagefault'):
    print('PAGEFAULT demand pages=64 cycles=100 faults=64')
    print('PAGEFAULT resident pages=64 accesses=4096 cycles=200')
    print('PAGEFAULT hot pages=8 accesses=4096 cycles=50')
    print('[PASS]')
elif name in ('linux.bin', 'fw_payload.bin'):
    print('Run /bin/sh as init process')
    print('serial milestone: cycles=1000 insts=300 text=Run /bin/sh as init process')
    print('serial exit milestone reached: login:')
else:
    print('Cycles: 2000')
    print('[PASS]')
print('HIT GOOD TRAP')
""")
        self.image(self.cal / "img/memprobe-rv64/memprobe-riscv64-npc.bin")
        self.image(self.cal / "img/coremark-rv64/coremark-riscv64-npc.bin")
        self.image(self.cal / "img/pagefault-rv64/pagefault-riscv64-npc.bin")
        self.linux = self.image(self.root / "linux.bin")
        for benchmark in summary.BENCHMARKS:
            self.image(self.cal / "img/embench-rv64" / (benchmark + ".bin"))
        self.env = dict(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        EVAL_CAL_DIR=str(self.cal), EVAL_BUILD_ROOT=str(self.root / "build"),
                        EVAL_LOG_ROOT=str(self.root / "logs"), EVAL_MAKE="fake-recursive-make",
                        EVAL_LINUX_IMAGE=str(self.linux), EVAL_MILESTONES="1",
                        EVAL_MEM_ARGS="--mem-serialize-writes", FAKE_SIM=str(self.bin / "fake-sim"))

    def image(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fake binary " + path.name.encode())
        return path

    def make_tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def run_harness(self, tag, workloads, extra=None, unset=()):
        args = ["eval-fpga.py", "--", str(self.tree), tag, "small-cache",
                "-DRAPT_L1D_WRITEBACK=1"] + workloads
        errors = io.StringIO()
        with patch.dict(os.environ, dict(self.env, **(extra or {}))), patch("sys.argv", args), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(errors):
            for name in unset:
                os.environ.pop(name, None)
            with self.assertRaises(SystemExit) as caught:
                harness.main()
        self.last_stderr = errors.getvalue()
        return caught.exception.code

    def test_repository_defaults_are_self_contained_and_use_normal_make(self):
        cal = self.tree / "sim/build/fpga-eval"
        cal.mkdir(parents=True)
        (cal / "latency.env").write_text("RL=20\nWL=30\n")
        for image in ("memprobe-rv64/memprobe-riscv64-npc.bin",
                      "coremark-rv64/coremark-riscv64-npc.bin", "linux-rv64/fw_payload.bin"):
            self.image(cal / "img" / image)
        self.assertEqual(self.run_harness("portable", ["mp", "cm", "lx64"],
                         unset=("EVAL_CAL_DIR", "EVAL_BUILD_ROOT", "EVAL_LOG_ROOT", "EVAL_MAKE",
                                "EVAL_LINUX_IMAGE")), 0)
        run = summary.load_tag(cal / "logs", "portable")[0]
        self.assertEqual(run["logs"]["mp"]["status"], "PASS")
        self.assertEqual(run["logs"]["cm"]["status"], "PASS")
        self.assertEqual(run["logs"]["lx"]["status"], "PASS (serial exit)")
        for image in run["metadata"]["images"].values():
            self.assertTrue(Path(image["path"]).is_relative_to(cal / "img"))
        for cmd in run["metadata"]["commands"]:
            if cmd[0] == "make":
                self.assertIn("MAKE=make", cmd)
                self.assertIn("BUILD_ROOT=" + str(cal / "build"), cmd)
        self.assertFalse((self.root / "build").exists())

    def test_calibration_file_is_required_before_build(self):
        self.assertEqual(self.run_harness("uncalibrated", ["mp"],
                         {"RL": "20", "WL": "30"}, unset=("EVAL_CAL_DIR",)), 2)
        self.assertIn("Missing calibration file:", self.last_stderr)
        self.assertIn("no built-in calibration", self.last_stderr)
        (self.cal / "latency.env").write_text("RL=20\n")
        self.assertEqual(self.run_harness("incomplete-calibration", ["mp"]), 2)
        self.assertIn("must define integer RL and WL", self.last_stderr)
        self.assertFalse((self.root / "build").exists())

    def test_explicit_memory_and_coremark_images_override_portable_defaults(self):
        images = {"EVAL_MEMPROBE_IMAGE": self.image(self.root / "override/memprobe-selected.bin"),
                  "EVAL_COREMARK_IMAGE": self.image(self.root / "override/coremark-selected.bin")}
        # Relative paths are resolved before the simulator changes its working directory.
        overrides = {name: os.path.relpath(path) for name, path in images.items()}
        self.assertEqual(self.run_harness("images", ["mp", "cm"], overrides), 0)
        run = summary.load_tag(self.root / "logs", "images")[0]
        for workload, variable in (("mp", "EVAL_MEMPROBE_IMAGE"), ("cm", "EVAL_COREMARK_IMAGE")):
            self.assertEqual(run["metadata"]["images"][workload]["path"], str(images[variable]))
            self.assertEqual(run["logs"][workload]["status"], "PASS")

    def test_full_suite_and_manifest(self):
        self.assertEqual(self.run_harness("complete", ["mp", "cm", "eb", "lx64"]), 0)
        run = summary.load_tag(self.root / "logs", "complete")[0]
        self.assertEqual(run["logs"]["mp"]["status"], "PASS")
        self.assertEqual(run["logs"]["cm"]["status"], "PASS")
        self.assertEqual(run["logs"]["lx"]["status"], "PASS (serial exit)")
        self.assertAlmostEqual(run["metrics"]["Embench geomean cycles (19/19)"], 2000)
        metadata = run["metadata"]
        self.assertEqual(metadata["read_latency"], 20)
        self.assertEqual(metadata["write_latency"], 30)
        self.assertEqual(len(metadata["images"]), 22)
        for command in metadata["commands"]:
            if command[0] == "make":
                self.assertIn("-j4", command)
                self.assertIn("VERILATOR_JOBS=4", command)
                self.assertIn("DIFFTEST=0", command)
                self.assertIn("VFLAGS=-DRAPT_RV64 -DRAPT_L1D_WRITEBACK=1", command)
            else:
                self.assertIn("--mem-read-latency=20", command)
                self.assertIn("--mem-write-latency=30", command)
                self.assertIn("--mem-serialize-writes", command)
        self.assertGreater(metadata["end"], metadata["start"])

    def test_workload_failure_is_recorded_and_other_workload_runs(self):
        self.assertEqual(self.run_harness("failure", ["mp", "cm"],
                         {"FAKE_RUN_FAIL": "memprobe-riscv64-npc.bin"}), 1)
        run = summary.load_tag(self.root / "logs", "failure")[0]
        self.assertEqual(run["logs"]["mp"]["status"], "FAILED")
        self.assertEqual(run["logs"]["mp"]["rc"], 3)
        self.assertEqual(run["logs"]["cm"]["status"], "PASS")

    def test_build_failure_prevents_workload_launch(self):
        result = self.run_harness("build-failure", ["mp"], {"FAKE_BUILD_FAIL": "1"})
        self.assertIn("Simulator build failed", result)
        self.assertFalse(list((self.root / "logs/build-failure").rglob("mp.log")))
        build = next((self.root / "logs/build-failure").rglob("build.log"))
        self.assertIn("rc=7", build.read_text())

    def test_wrong_embench_names_rejected_even_when_count_is_19(self):
        images = self.cal / "img/embench-rv64"
        (images / "crc32.bin").rename(images / "unexpected.bin")
        result = self.run_harness("wrong-suite", ["eb"])
        self.assertIn("missing: crc32", result)
        self.assertIn("unexpected: unexpected", result)
        self.assertFalse((self.root / "build").exists())

    def test_repeat_is_deterministic_and_existing_tag_is_preserved(self):
        self.assertEqual(self.run_harness("first", ["mp", "cm"]), 0)
        ref = summary.load_tag(self.root / "logs", "first")[0]
        original = Path(ref["logs"]["mp"]["path"]).read_bytes()
        self.assertIn("Tag already has a manifest", self.run_harness("first", ["mp"]))
        self.assertEqual(Path(ref["logs"]["mp"]["path"]).read_bytes(), original)
        self.assertEqual(self.run_harness("repeat", ["mp", "cm"]), 0)
        repeat = summary.load_tag(self.root / "logs", "repeat")[0]
        self.assertIn("(+0.00%)", summary.cell(repeat, "CoreMark ROI cycles", ref))
        self.assertIn("(+0.00%)", summary.cell(repeat, "memprobe chase 1024 B", ref))

    def test_pagefault_end_to_end(self):
        self.assertEqual(self.run_harness("pagefault", ["pf"]), 0)
        run = summary.load_tag(self.root / "logs", "pagefault")[0]
        self.assertEqual(run["logs"]["pf"]["status"], "PASS")
        self.assertEqual(run["metrics"]["Pagefault demand cycles"], 100)
        self.assertEqual(run["metrics"]["Pagefault resident cycles"], 200)
        self.assertEqual(run["metrics"]["Pagefault hot cycles"], 50)
        self.assertIn("pf", run["metadata"]["images"])

    def test_duplicate_log_names_rejected_before_build(self):
        for workloads in (["mp", "mq"], ["mq", "ms"], ["cm", "cm"], ["eb", "eb"]):
            self.assertEqual(self.run_harness("duplicate", workloads), 2)
        self.assertFalse((self.root / "build").exists())

    def test_rv64_only_workloads_rejected_for_rv32(self):
        for workload in ("pf", "lx64"):
            self.assertEqual(self.run_harness("wrong-xlen", [workload], {"EVAL_XLEN": "32"}), 2)
        self.assertFalse((self.root / "build").exists())

    def test_inherited_memory_environment_is_cleared(self):
        self.assertEqual(self.run_harness("env", ["mp"],
                         {"SIM_RANDOM_DELAY": "10", "SIM_RANDOM_SEED": "42",
                          "SIM_MEM_READ_LATENCY": "99", "SIM_MEM_WRITE_LATENCY": "99",
                          "SIM_MEM_SERIALIZE_WRITES": "1"}), 0)
        run = summary.load_tag(self.root / "logs", "env")[0]
        for command in run["metadata"]["commands"]:
            if command[0] == "make":
                for setting in ("SIM_RANDOM_DELAY=0", "SIM_RANDOM_SEED=1",
                                "SIM_MEM_READ_LATENCY=0", "SIM_MEM_WRITE_LATENCY=0",
                                "SIM_MEM_SERIALIZE_WRITES=0", "SIM_MEM_WRITE_OUTSTANDING=1"):
                    self.assertIn(setting, command)

    def test_extra_memory_options_preserve_command_and_manifest(self):
        for tag, args in (("equals", "--mem-serialize-writes --mem-random-delay=4 "
                                    "--mem-random-seed=0x2a --mem-write-outstanding=4"),
                          ("separate", "--mem-random-delay 4 --mem-random-seed 052 --mem-write-outstanding 64")):
            self.assertEqual(self.run_harness(tag, ["mp"], {"EVAL_MEM_ARGS": args}), 0)
            metadata = summary.load_tag(self.root / "logs", tag)[0]["metadata"]
            self.assertEqual(metadata["memory_args"], args.split())
            self.assertEqual((metadata["read_latency"], metadata["write_latency"]), (20, 30))
            command = next(cmd for cmd in metadata["commands"] if cmd[0] != "make")
            begin = command.index("--mem-write-latency=30") + 1
            self.assertEqual(command[begin:begin + len(args.split())], args.split())

    def test_memory_overrides_and_other_options_rejected_before_build(self):
        for args in ("--mem-read-latency=40", "--mem-write-latency 40",
                     "--mem-read-latency", "--serial-exit-on=login:", "-m 1", "image.bin",
                     "--mem-serialize-writes=1", "--mem-random-delay", "--mem-random-seed=",
                     "--mem-random-delay --mem-write-latency=40", "--mem-random-delay=1048575",
                     "--mem-write-outstanding=0", "--mem-write-outstanding=65",
                     "--mem-write-outstanding=-1", "--mem-write-outstanding=4junk"):
            with self.subTest(args=args):
                self.assertEqual(self.run_harness("invalid-memory", ["mp"], {"EVAL_MEM_ARGS": args}), 2)
        with self.assertRaisesRegex(ValueError, "use RL/WL"):
            harness.memory_args("--mem-read-latency=40")
        self.assertFalse((self.root / "build").exists())

    def test_fixed_latency_range_checked_before_build(self):
        for name in ("RL", "WL"):
            for value in ("-1", "1048575", "4294967296", "not-an-integer"):
                with self.subTest(name=name, value=value):
                    self.assertEqual(self.run_harness("invalid-latency", ["mp"], {name: value}), 2)
        self.assertFalse((self.root / "build").exists())



class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_memprobe_does_not_pass_on_rc_alone(self):
        path = self.write("mp.log", "MEMPROBE chase 1024 cycles_per_access=4.61\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(log["status"], "PARTIAL")
        self.assertEqual(log["metrics"]["memprobe chase 1024 B"], 4.61)
        path.write_text(path.read_text() + "MEMPROBE verify=1\nHIT GOOD TRAP\n")
        self.assertEqual(summary.read_log(path)["status"], "PASS")

    def memprobe_run(self, tag, printed, cycles=None, steps=8192, operation="chase"):
        text = f"MEMPROBE {operation} 1024 cycles_per_access={printed}\n"
        if cycles is not None:
            text += f"MEMPROBE detail {operation} bytes=1024 cycles={cycles} steps={steps}\n"
        self.write(f"{tag}/mp.log", text + "MEMPROBE verify=1\nHIT GOOD TRAP\nrc=0\n")
        self.write(f"{tag}/manifest.json", json.dumps({
            "read_latency": 24, "write_latency": 29, "xlen": 64,
            "memory_args": [], "images": {"mp": {"sha256": "same"}}}))
        return summary.load_tag(self.root, tag)[0]

    def test_memprobe_raw_ratios_preserve_printed_values(self):
        ref = self.memprobe_run("ref", "3.16", 25937)
        rob8 = self.memprobe_run("rob8", "3.04", 24916)
        key = "memprobe chase 1024 B"
        self.assertEqual(rob8["logs"]["mp"]["memprobe_details"][key],
                         {"bytes": 1024, "cycles": 24916, "steps": 8192})
        self.assertEqual(rob8["metrics"][key], 3.04)
        self.assertEqual(summary.cell(rob8, key, ref), "3.04 (-3.94%)")
        # Different access counts must be normalized, not compared as total cycles.
        double = self.memprobe_run("double", "3.04", 49832, steps=16384)
        self.assertEqual(summary.cell(double, key, ref), "3.04 (-3.94%)")
        ref = self.memprobe_run("store-ref", "32.05", 262600, operation="store")
        wb = self.memprobe_run("wb", "5.84", 47914, operation="store")
        self.assertEqual(summary.cell(wb, "memprobe store 1024 B", ref), "5.84 (-81.75%)")
        self.assertIn("Truncated cell values", summary.render([ref, wb]))

    def test_memprobe_raw_ratio_requires_valid_details_on_both_runs(self):
        key = "memprobe chase 1024 B"
        ref = self.memprobe_run("ref", "3.16", 25937)
        for tag, cycles, steps in (("missing", None, 8192), ("zero-steps", 24916, 0),
                                   ("zero-cycles", 0, 8192)):
            candidate = self.memprobe_run(tag, "3.04", cycles, steps)
            self.assertEqual(summary.cell(candidate, key, ref), "3.04 (-3.80%)")
        ref = self.memprobe_run("no-details-ref", "3.16")
        candidate = self.memprobe_run("details", "3.04", 24916)
        self.assertEqual(summary.cell(candidate, key, ref), "3.04 (-3.80%)")

    def test_ansi_and_bad_trap_override_zero_status(self):
        path = self.write("cm.log", "\x1b[1;34mCoreMark ROI cycles : 123\x1b[0m\n"
                          "Correct operation validated\nHIT GOOD TRAP\nHIT BAD TRAP\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(log["status"], "FAILED")
        self.assertEqual(log["metrics"]["CoreMark ROI cycles"], 123)

    def test_exact_milestone_beats_progress_bound(self):
        path = self.write("lx.log", "progress: 100 cycles, 20 insts\n"
                          "Run /init as init process\n"
                          "serial milestone: cycles=123 insts=25 text=Run /init as init process\n"
                          "progress: 200 cycles, 40 insts\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(log["metrics"]["Linux Run /init as init process cycles"], 123)
        self.assertFalse(log["intervals"])
        self.assertEqual(log["status"], "PARTIAL (milestones reached)")

    def test_uninstrumented_bounds_and_command_echo(self):
        path = self.write("lx.log", "sim --serial-exit-on='Run /bin/sh as init process'\n"
                          "progress: 100 cycles, 20 insts\nRun /bin/sh as init process\n"
                          "progress: 200 cycles, 40 insts\nStarting syslogd\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(log["intervals"]["Linux Run /bin/sh as init process cycles"], [100, 200])
        self.assertEqual(log["intervals"]["Linux Starting syslogd cycles"], [200, None])

    def test_linux_bootargs_and_colon_aliases(self):
        path = self.write("lx.log", "Kernel command line: init=/bin/sh -- -c 'echo CAL_USER_DONE; login:'\n"
                          "cmd --serial-milestone='serial milestone: cycles=1 insts=1 text=login:'\n"
                          "echo serial exit milestone reached: login:\n"
                          "progress: 100 cycles, 20 insts\nStarting syslogd: OK\n"
                          "mmio-serial.cc:253 serial_sample_milestones "
                          "serial milestone: cycles=123 insts=25 text=Starting syslogd:\n"
                          "progress: 200 cycles, 40 insts\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(log["metrics"], {"Linux Starting syslogd cycles": 123,
                                          "Linux Starting syslogd insts": 25})
        self.assertFalse(log["intervals"])
        self.assertIsNone(log["validation"]["exit_marker"])
        self.assertEqual(log["status"], "PARTIAL (milestones reached)")

    def test_final_pmu_keeps_numeric_rows_without_combining_snapshots(self):
        def snapshot(cycles):
            return ("pmu.cc:0 report_axi_metrics AXI handshakes: AR=2 R=4\n"
                    "pmu.cc:1 perf ======== Instruction Analysis ========\n"
                    f"pmu.cc:2 perf #inst: 10, cycle: {cycles}, IPC: 0.1\n"
                    "pmu.cc:3 perf | IFU, %| L1D, %|\n"
                    f"pmu.cc:4 perf | {cycles}, 50| 3, 2|\n"
                    "pmu.cc:6 statistic Simulate time: 1 us\n")
        path = self.write("cm.log", snapshot(100) + snapshot(200) + "HIT GOOD TRAP\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(len(log["pmu_snapshots"]), 2)
        self.assertEqual(log["pmu_final"]["cycles"], 200)
        self.assertIn("| 200, 50| 3, 2|", log["pmu"])
        self.assertNotIn("| 100, 50| 3, 2|", log["pmu"])
        path.write_text(snapshot(100) + snapshot(200).split("pmu.cc:6")[0] + "rc=-15\n")
        log = summary.read_log(path)
        self.assertIsNone(log["pmu_final"])
        self.assertFalse(log["pmu"])
        path.write_text(snapshot(100))
        self.assertIsNone(summary.read_log(path)["pmu_final"])

    def test_instrumented_pmu_prelude_and_compact_reports(self):
        prelude = ("pmu.cc:1 report_axi_metrics AXI handshakes: cycles=100 AR=2 R=4\n"
                   "pmu.cc:2 report_axi_metrics Posted writes: count=1\n")
        body = ("pmu.cc:4 perf #inst: 10, cycle: 100, IPC: 0.1\n"
                "pmu.cc:5 perf Stalls (cycles): IFU=2\n"
                "pmu.cc:6 statistic Simulate time: 1 us\nrc=0\n")
        for header in ("", "pmu.cc:3 perf ======== Instruction Analysis ========\n"):
            path = self.write("cm.log", prelude + header + body)
            log = summary.read_log(path)
            self.assertEqual(len(log["pmu_snapshots"]), 1)
            self.assertEqual(log["pmu_final"]["cycles"], 100)
            self.assertIn("AXI handshakes: cycles=100 AR=2 R=4", log["pmu"])
            self.assertIn("Posted writes: count=1", log["pmu"])

    def test_serial_exit_logger_can_follow_uart_without_newline(self):
        path = self.write("lx.log", "buildroot login:mmio-serial.cc:279 serial_write_host_byte "
                          "serial exit milestone reached: login:\nHIT GOOD TRAP\nrc=0\n")
        log = summary.read_log(path)
        self.assertEqual(log["status"], "PASS (serial exit)")
        self.assertEqual(log["validation"]["exit_marker"], "login:")

    def test_kernel_panic_cannot_pass_even_when_serial_exit_returns_zero(self):
        marker = "Kernel panic - not syncing"
        for prefix in ("", "[    1.234567] ", "[    1.234567][    T1] "):
            # The serial exit logger can immediately follow the matched UART byte.
            path = self.write("lx.log", prefix + marker +
                              "mmio-serial.cc:279 serial_write_host_byte "
                              "serial exit milestone reached: " + marker +
                              "\nHIT GOOD TRAP\nrc=0\n")
            self.assertEqual(summary.read_log(path)["status"], "FAILED")
            path.write_text(prefix + marker + ": Attempted to kill init!\nrc=0\n")
            self.assertEqual(summary.read_log(path)["status"], "FAILED")
        path.write_text("Kernel command line: panic=10\n"
                        "sim --serial-exit-on='Kernel panic - not syncing'\n"
                        "Oops: nonterminal diagnostic\n"
                        "serial exit milestone reached: login:\nrc=0\n")
        self.assertEqual(summary.read_log(path)["status"], "PASS (serial exit)")

    def test_partial_bare_metal_does_not_get_ratio(self):
        for tag in ("ref", "partial"):
            self.write(f"{tag}/cm.log", "CoreMark ROI cycles : 100\n")
        ref, partial = (summary.load_tag(self.root, tag)[0] for tag in ("ref", "partial"))
        metadata = {"read_latency": 24, "write_latency": 29, "xlen": 64,
                    "memory_args": [], "images": {"cm": {"sha256": "same"}}}
        ref["metadata"] = partial["metadata"] = metadata
        self.assertEqual(summary.cell(partial, "CoreMark ROI cycles", ref), "100 [partial]")

    def test_source_provenance_is_separate_from_workload_compatibility(self):
        ref = {"metadata": {"source_sha256": {"rtl/top.sv": "a", "sim/rtl/mem.sv": "m"}}}
        candidate = {"metadata": {"source_sha256": {"rtl/top.sv": "b", "sim/rtl/mem.sv": "m"}}}
        self.assertIn("matching simulator sources", summary.provenance_note(candidate, ref))
        candidate["metadata"]["source_sha256"]["sim/rtl/mem.sv"] = "n"
        self.assertIn("sim/rtl/mem.sv", summary.provenance_note(candidate, ref))
        candidate["metadata"] = {"binary_sha256": "same"}
        ref["metadata"] = {"binary_sha256": "same"}
        self.assertEqual(summary.provenance_note(candidate, ref), "identical simulator binary")

    def test_partial_suite_has_no_geomean_and_repeats_are_exact(self):
        for tag, factor in (("ref", 1), ("repeat", 1), ("fast", 0.5)):
            self.write(f"{tag}/cfg/manifest.json", json.dumps({
                "read_latency": 20, "write_latency": 20, "xlen": 64, "memory_args": [],
                "images": {"eb-" + bench: {"sha256": bench} for bench in summary.BENCHMARKS}}))
            for bench in summary.BENCHMARKS:
                self.write(f"{tag}/cfg/eb-{bench}.log", f"Cycles: {int(100 * factor)}\n"
                           "[PASS]\nHIT GOOD TRAP\nrc=0\n")
        ref = summary.load_tag(self.root, "ref")[0]
        repeat = summary.load_tag(self.root, "repeat")[0]
        fast = summary.load_tag(self.root, "fast")[0]
        key = "Embench geomean cycles (19/19)"
        self.assertAlmostEqual(ref["metrics"][key], 100)
        self.assertIn("(+0.00%)", summary.cell(repeat, key, ref))
        self.assertIn("(-50.00%)", summary.cell(fast, key, ref))
        self.write("fast/cfg/eb-crc32.log", "Cycles: 10\n[FAIL]\nrc=1\n")
        failed = summary.load_tag(self.root, "fast")[0]
        self.assertNotIn(key, failed["metrics"])
        self.assertIn("[FAILED]", summary.cell(failed, "Embench crc32 cycles", ref))
        self.assertNotIn("%", summary.cell(failed, "Embench crc32 cycles", ref))
        self.assertIn("19 pass", summary.render([ref, repeat]))

    def test_mismatched_and_missing_metadata_keep_only_raw_values(self):
        for tag in ("ref", "candidate"):
            self.write(f"{tag}/cfg/cm.log", "CoreMark ROI cycles : 100\n"
                       "Correct operation validated\nHIT GOOD TRAP\nrc=0\n")
        ref = summary.load_tag(self.root, "ref")[0]
        candidate = summary.load_tag(self.root, "candidate")[0]
        key = "CoreMark ROI cycles"
        self.assertIn("unverified metadata", summary.cell(candidate, key, ref))
        metadata = {"read_latency": 20, "write_latency": 20, "xlen": 64,
                    "memory_args": [], "images": {"cm": {"sha256": "same"}}}
        ref["metadata"] = metadata
        candidate["metadata"] = dict(metadata, write_latency=30)
        self.assertIn("mismatched write_latency", summary.cell(candidate, key, ref))
        candidate["metadata"] = dict(metadata, images={"cm": {"sha256": "other"}})
        self.assertIn("mismatched image cm", summary.cell(candidate, key, ref))
        candidate["metadata"] = dict(metadata, memory_args=["--mem-serialize-writes"])
        self.assertIn("mismatched memory_args", summary.cell(candidate, key, ref))
        self.assertNotIn("%", summary.cell(candidate, key, ref))

    def test_missing_is_not_zero(self):
        run = summary.load_tag(self.root, "absent")[0]
        self.assertFalse(run["metrics"])
        self.assertIn("MISSING", summary.render([run]))

    def test_pagefault_runtime_and_validation(self):
        text = ("PAGEFAULT demand pages=64 cycles=100 faults=64\n"
                "PAGEFAULT resident pages=64 accesses=4096 cycles=200\n"
                "PAGEFAULT hot pages=8 cycles=50 accesses=4096\n"
                "[PASS]\nHIT GOOD TRAP\nrc=0\n")
        path = self.write("pf.log", text)
        log = summary.read_log(path)
        self.assertEqual(log["status"], "PASS")
        self.assertEqual(log["metrics"]["Pagefault hot cycles"], 50)
        path.write_text(text.replace("faults=64", "faults=63"))
        self.assertEqual(summary.read_log(path)["status"], "PARTIAL")
        path.write_text(text + "PAGEFAULT validation failed\n[FAIL status=1]\n")
        self.assertEqual(summary.read_log(path)["status"], "FAILED")
        path.write_text(text.replace("[PASS]", "PAGEFAULT verify=1"))
        self.assertEqual(summary.read_log(path)["status"], "PASS")

    def test_pagefault_hash_and_discovery(self):
        for tag, cycles in (("ref", 100), ("new", 50)):
            self.write(f"{tag}/cfg/pf.log", f"PAGEFAULT demand pages=64 cycles={cycles} faults=64\n"
                       "PAGEFAULT resident pages=64 accesses=4096 cycles=200\n"
                       "PAGEFAULT hot pages=8 accesses=4096 cycles=50\n"
                       "[PASS]\nHIT GOOD TRAP\nrc=0\n")
            self.write(f"{tag}/cfg/manifest.json", json.dumps({
                "read_latency": 24, "write_latency": 29, "xlen": 64,
                "memory_args": [], "images": {"pf": {"sha256": "same"}}}))
        ref = summary.load_tag(self.root, "ref")[0]
        new = summary.load_tag(self.root, "new")[0]
        self.assertIn("(-50.00%)", summary.cell(new, "Pagefault demand cycles", ref))
        new["metadata"]["images"]["pf"]["sha256"] = "changed"
        self.assertIn("mismatched image pf", summary.cell(new, "Pagefault demand cycles", ref))

    def test_coremark_duration_only_failure_is_validated_as_short_roi(self):
        text = (summary.COREMARK_SHORT_WARNING + "\nIterations : 2\n"
                "seedcrc : 0xe9f5\n[0]crclist : 0xe714\n[0]crcmatrix : 0x1fd7\n"
                "[0]crcstate : 0x8e3a\n[0]crcfinal : 0x72be\nErrors detected\n"
                "CoreMark ROI cycles : 1000\nHIT GOOD TRAP\nrc=0\n")
        path = self.write("cm.log", text)
        log = summary.read_log(path)
        self.assertEqual(log["status"], "PASS (CRC-valid short ROI)")
        self.assertTrue(log["validation"]["crc_valid"])
        self.assertFalse(log["validation"]["official_valid"])
        for bad in (text.replace("0x72be", "0x72bf"), text.replace("Iterations : 2", "Iterations : 1"),
                    text + "ERROR! other validation failure\n",
                    text + "[0]ERROR! matrix crc 0x0000 - should be 0x1fd7\n"):
            path.write_text(bad)
            self.assertEqual(summary.read_log(path)["status"], "FAILED")
        path.write_text(text.replace("[0]crcfinal : 0x72be\n", ""))
        self.assertEqual(summary.read_log(path)["status"], "PARTIAL")
        path.write_text(text.replace("CoreMark ROI cycles : 1000\n", ""))
        self.assertEqual(summary.read_log(path)["status"], "PARTIAL")

    def test_coremark_generic_error_is_not_success(self):
        path = self.write("cm.log", "CoreMark ROI cycles : 100\nErrors detected\n"
                          "HIT GOOD TRAP\nrc=0\n")
        self.assertEqual(summary.read_log(path)["status"], "FAILED")


if __name__ == "__main__":
    unittest.main()
