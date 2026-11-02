#!/usr/bin/env python3
"""Check consolidated public Make interfaces without running workloads."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MakeTargetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="raptor-chip-target-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def make(self, *args, cwd=ROOT):
        env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE") and k != "MFLAGS"}
        return subprocess.run(["make", "--no-print-directory", *args], cwd=cwd, env=env,
                              text=True, capture_output=True, timeout=30)

    def test_removed_aliases_are_not_callable(self):
        for target in ("config-nemu32", "config-rv32", "sim-rv32", "coremark-rv32-difftest",
                       "coremark-rv64-optim", "hdl-format", "all-sv-format", "sta-sram",
                       "sta-dff", "sta-flops", "sta-rv64", "verify-all", "ide-setup"):
            with self.subTest(target=target):
                result = self.make(target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No rule to make target", result.stderr)

    def test_format_check_and_scope(self):
        formatter = self.work / "formatter"
        formatter.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        formatter.chmod(0o755)
        check = self.make("format-check", "FORMAT_SCOPE=rtl", f"VERIBLE_FORMAT={formatter}")
        full = self.make("format", "FORMAT_SCOPE=all", f"VERIBLE_FORMAT={formatter}")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertIn("--verify", check.stdout)
        self.assertNotIn("--inplace", check.stdout)
        self.assertIn("--inplace", full.stdout)
        hdl = {line for line in check.stdout.splitlines() if line.startswith(str(ROOT))}
        all_sv = {line for line in full.stdout.splitlines() if line.startswith(str(ROOT))}
        self.assertTrue(hdl < all_sv)
        self.assertTrue(all(path.startswith(str(ROOT / "rtl")) for path in hdl))

    def test_invalid_selectors_fail(self):
        for setting in ("DIFFTEST=invalid", "FORMAT_SCOPE=invalid", "BENCH_OPT=invalid"):
            result = self.make("help", setting)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be", result.stderr)

    def test_invalid_directed_backend_fails(self):
        result = self.make("-C", "verification", "help", "DIRECTED_SIMULATOR=invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be", result.stderr)

    def test_xsim_zero_exit_requires_completion_without_tool_or_uvm_errors(self):
        tools = self.work / "tools"
        tools.mkdir()
        for name in ("xvlog", "xelab"):
            path = tools / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        xsim = tools / "xsim"
        xsim.write_text('#!/bin/sh\nprintf "%s\\n" "$RAPTOR_TEST_XSIM_LOG" > xsim.log\n')
        xsim.chmod(0o755)
        markers = {
            "uvm-smoke": "XSim UVM elaboration works",
            "uvm-csr-sret": "checked 2000 SRET operations without mtvec contamination",
            "xsim-clint": "PASS: CLINT",
        }
        from unittest.mock import patch
        environment = {"PATH": str(tools) + os.pathsep + os.environ["PATH"]}
        for target, marker in markers.items():
            logs = ("", marker, "ERROR: unexpected exception", marker + "\nUVM_ERROR : 1",
                    marker + "\nUVM_FATAL @ 10: aborted")
            for log in logs:
                with self.subTest(target=target, log=log):
                    with patch.dict(os.environ, dict(environment, RAPTOR_TEST_XSIM_LOG=log)):
                        result = self.make("-C", "verification", target,
                                           f"BUILD_DIR={self.work / 'build'}")
                    self.assertEqual(result.returncode == 0, log == marker, result.stdout)

    def test_benchmark_program_uses_the_selected_profile_image(self):
        for xlen in (32, 64):
            for backend, runner in (("sim", "pk-run"), ("nemu", "nemu-run")):
                with self.subTest(xlen=xlen, backend=backend):
                    result = self.make("-C", "app", "-n", "llm-infer-" + backend, "MAKE=:",
                                       f"ISA64={int(xlen == 64)}", "LLM_OP_ITERS=2",
                                       "LLM_GEN_TOKENS=3", "LLM_INFER_REPEATS=4", "LLM_TRAIN_STEPS=5")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = f"benchmarks/llm/ops2-gen3x4-train5/llm-infer.elf"
                    self.assertIn(expected, result.stdout)
                    self.assertIn(runner, result.stdout)

    def test_xsim_aliases_forward_xlen_and_shared_runtime_arguments(self):
        from unittest.mock import patch
        tools = self.work / "tools"
        tools.mkdir()
        calls = self.work / "calls.jsonl"
        script = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
with open(os.environ['RAPTOR_TEST_TOOL_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + '\n')
if name == 'xsim':
    Path('xsim.log').write_text('PASS: captured shared directed invocation\n')
'''
        for name in ("xvlog", "xelab", "xsim"):
            tool = tools / name
            tool.write_text(script)
            tool.chmod(0o755)
        environment = {"PATH": str(tools) + os.pathsep + os.environ["PATH"],
                       "RAPTOR_TEST_TOOL_CALLS": str(calls)}
        cases = (("csr-sret-roundtrip", "rv32", "tb_csr_sret_roundtrip", (), ()),
                 ("csr-sret-roundtrip", "rv64", "tb_csr_sret_roundtrip", (), ()),
                 ("lsu-sq-random", "rv32", "tb_lsu_sq_random",
                  ("LSU_SQ_RANDOM_SEED=17",), ("SEED=17",)),
                 ("l1d-store-coherence", "rv32", "tb_l1d_store_coherence",
                  ("VERILATOR_DIRECTED_SEED=19", "VERILATOR_DIRECTED_DELAY=9"),
                  ("SEED=19", "BUS_DELAY_MAX=9")))
        for target, isa, top, settings, plusargs in cases:
            with self.subTest(target=target, isa=isa):
                calls.write_text("")
                with patch.dict(os.environ, environment):
                    result = self.make("-C", "verification", "xsim-" + target, f"ISA={isa}",
                                       f"BUILD_DIR={self.work / 'build'}", *settings,
                                       "VERILATOR=unavailable-directed-backend")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                invocations = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertEqual([row[0] for row in invocations], ["xvlog", "xelab", "xsim"])
                compile_args, elaborate_args, run_args = invocations
                self.assertEqual("RAPT_RV64" in compile_args, isa == "rv64")
                self.assertIn(top, elaborate_args)
                self.assertIn(top + "_sim", run_args)
                for value in plusargs:
                    self.assertIn(["-testplusarg", value],
                                  [run_args[i:i + 2] for i in range(len(run_args) - 1)])

    def test_shared_app_build_tracks_flags_and_headers(self):
        compiler = self.work / "compiler"
        compiler.write_text(r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
if '-print-libgcc-file-name' in sys.argv:
    print('/unused/libgcc.a')
else:
    output = Path(sys.argv[sys.argv.index('-o') + 1])
    output.write_text('test executable')
    with open(os.environ['RAPTOR_TEST_COMPILE_LOG'], 'a') as stream:
        stream.write(json.dumps(sys.argv[1:]) + '\n')
''')
        compiler.chmod(0o755)
        from unittest.mock import patch
        cases = (("hello", "app/tests/hello", "build", {}, {}, 1),
                 ("llm", "app/benchmarks/llm", "native-build",
                  {"LLM_OP_ITERS": 1}, {"LLM_OP_ITERS": 2}, 3),
                 ("agent", "app/benchmarks/agent", "native-build",
                  {"AGENT_TOOL_ITERS": 1}, {"AGENT_TOOL_ITERS": 2}, 3))
        for name, folder, target, initial, changed, count in cases:
            with self.subTest(suite=name):
                log = self.work / (name + '.jsonl')
                output = self.work / name
                header = self.work / (name + '.h')
                header.write_text('/* first header */\n')
                path_variable = 'BUILD_DIR' if name == 'hello' else 'NATIVE_BUILD_DIR'
                flags_variable = 'CFLAGS' if name == 'hello' else 'NATIVE_CFLAGS'
                args = ['-C', folder, target, f'CC={compiler}', f'HOST_CC={compiler}',
                        f'{path_variable}={output}', f'PORT_HDR={header}']
                def build(values):
                    settings = [f'{key}={value}' for key, value in values.items()]
                    result = self.make(*args, *settings)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    return len(log.read_text().splitlines())
                with patch.dict(os.environ, RAPTOR_TEST_COMPILE_LOG=str(log)):
                    self.assertEqual(build(initial), count)
                    self.assertEqual(build(initial), count)
                    changed = dict(changed, **{flags_variable: '-O1'})
                    self.assertEqual(build(changed), 2 * count)
                    if name != 'hello':
                        header.write_text('/* changed header */\n')
                        self.assertEqual(build(changed), 3 * count)

    def test_ioq_solver_and_reuse_options_reach_the_correct_stages(self):
        for contract in ("owner", "store"):
            with self.subTest(contract=contract):
                prefix = "FORMAL_IOQ_" + contract.upper()
                reuse = self.work / "prior evidence"
                replays = self.work / "primary input replays.json"
                result = self.make("-n", "formal_ioq_" + contract, "FORMAL_JOBS=3",
                                   f"FORMAL_RESULTS_DIR={self.work}", f"{prefix}_SOLVER=yices",
                                   f"{prefix}_TIMEOUT=47", f"{prefix}_REUSE_EVIDENCE={reuse}",
                                   f"{prefix}_NEGATIVE_REPLAYS={replays}",
                                   f"{prefix}_PRESETS=formal default", "FORMAL_IOQ_OWNER_DEPTH=7",
                                   cwd=ROOT / "verification/formal")
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = result.stdout.replace("\\\n", "").splitlines()
                commands = [shlex.split(line) for line in lines
                            if line.startswith("python3 ") and "ioq_contract.py" in line]
                self.assertEqual(len(commands), 2)
                proof, activation = commands
                for command, stage in zip(commands, ("prove", "activate")):
                    self.assertEqual(command[2], stage)
                    for option, value in (("--solver", "yices"), ("--timeout", "47"),
                                          ("--jobs", "3")):
                        self.assertEqual(command[command.index(option) + 1], value)
                self.assertEqual(proof[proof.index("--reuse-evidence") + 1], str(reuse))
                self.assertNotIn("--reuse-evidence", activation)
                self.assertEqual(proof[proof.index("--negative-replays") + 1], str(replays))
                self.assertNotIn("--negative-replays", activation)
                self.assertIn("--late-operands", proof)
                self.assertEqual(proof[proof.index("--operand-read-ports") + 1], "1")
                self.assertEqual(proof[proof.index("--contract") + 1], contract)
                self.assertEqual(proof[proof.index("--output") + 1],
                                 str(self.work / ("ioq-" + contract)))
                self.assertEqual(activation[activation.index("--evidence") + 1],
                                 str(self.work / ("ioq-" + contract)))
                start = proof.index("--presets") + 1
                self.assertEqual(proof[start:start + 2], ["formal", "default"])
                if contract == "owner":
                    self.assertEqual(proof[proof.index("--depth") + 1], "7")
                else:
                    self.assertNotIn("--depth", proof)

    def test_formal_gate_forwards_indexes_in_inventory_and_signoff_modes(self):
        indexes = [str(self.work / name) for name in ('unit-a.json', 'unit-b.json')]
        for target in ('formal-scope', 'formal-signoff'):
            result = self.make('-n', '-C', 'verification', target,
                               'FORMAL_RECEIPT_INDEXES=' + ' '.join(indexes),
                               f'FORMAL_RECEIPTS={self.work}/receipt.json',
                               f'FORMAL_CONTRACT_REVIEW={self.work}/review.json')
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.replace('\\\n', '').splitlines()
            command = next(shlex.split(line) for line in lines if 'scripts/formal_scope.py' in line)
            self.assertEqual('--signoff' in command, target == 'formal-signoff')
            start, stop = command.index('--receipt-index') + 1, command.index('--receipts')
            self.assertEqual(command[start:stop], indexes)
            self.assertEqual(command[stop + 1], str(self.work / 'receipt.json'))

    def test_decoder_prerequisite_keeps_canonical_output_directory(self):
        # A command-line BUILD_DIR propagates through recursive Make calls.
        # A successful prerequisite must create the generated file it names.
        generated = ROOT / "rtl/generated"
        for folder in ("sim", "verification/formal"):
            with self.subTest(folder=folder):
                result = self.make("-n", "-B", str(generated / "rapt_idu_decoder.sv"),
                                   f"BUILD_DIR={self.work}", cwd=ROOT / folder)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"--target-dir {generated}", result.stdout)
                self.assertNotIn(f"--target-dir {self.work}", result.stdout)

    def test_benchmark_flag_changes_rebuild_objects(self):
        (self.work / "Makefile").write_text(f'''NAME := coremark
PLATFORM := npc
ARCH := riscv32-npc
DST_DIR := .
OBJS := object
CFLAGS = -O2 -DITERATIONS=$(ITERATIONS)
include {ROOT}/verification/benchmark-options.mk
all: object
object:
\t@echo '$(CFLAGS)' > $@
\t@echo compiled >> count
include {ROOT}/verification/benchmark-build.mk
''')
        for mode, count in (("baseline", 1), ("baseline", 1), ("optimized", 2), ("baseline", 3)):
            result = self.make("all", f"BENCH_OPT={mode}", cwd=self.work)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len((self.work / "count").read_text().splitlines()), count)
            flags = (self.work / "object").read_text()
            self.assertEqual("-O3" in flags, mode == "optimized")
            self.assertIn("-DITERATIONS=2", flags)
        result = self.make("all", "ITERATIONS=10", cwd=self.work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-DITERATIONS=10", (self.work / "object").read_text())


if __name__ == "__main__":
    unittest.main()
