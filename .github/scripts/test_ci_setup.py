#!/usr/bin/env python3
"""Exercise CI setup, decoder cache restores and the RISCOF handoff without installs."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / ".github/scripts/setup-ci.sh"


def workflow_run(step_name):
    """Read a literal/folded shell block without requiring PyYAML on the runner."""
    text = (ROOT / ".github/workflows/app.yaml").read_text()
    step = text.split(f"      - name: {step_name}\n", 1)[1].split("      - ", 1)[0]
    match = re.search(r"        run: ([|>]-?)\n((?:          .*\n|\n)+)", step)
    lines = [line[10:] for line in match[2].splitlines() if line.strip()]
    return (" " if match[1].startswith(">") else "\n").join(lines)


class CiSetupTest(unittest.TestCase):
    def shell(self, script, *args, cwd=ROOT, env=None):
        return subprocess.run(["bash", "-c", script, "test", *map(str, args)],
                              cwd=cwd, env=env, text=True, capture_output=True, timeout=30)

    def tools(self, profile):
        env = os.environ.copy()
        env.pop("GITHUB_PATH", None)
        return self.shell('''
source "$1"
sudo() { printf 'sudo %s\\n' "$*"; }
brew_bootstrap() { echo brew-bootstrap; }
brew() { printf 'brew %s\\n' "$*"; }
install_tools "$2"
''', SETUP, profile, env=env)

    def test_tool_profiles(self):
        for profile in ("build", "sim", "riscof", "sta", "nemu", "litex"):
            with self.subTest(profile=profile):
                result = self.tools(profile)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("sudo apt-get update"), 1)
                if profile == "nemu":
                    self.assertNotIn("brew", result.stdout)
                    self.assertIn("gcc-riscv64-linux-gnu", result.stdout)
                else:
                    self.assertEqual(result.stdout.count("brew-bootstrap"), 1)
                    self.assertEqual(result.stdout.count("brew install"), 1)
                if profile in ("build", "sta", "riscof", "nemu"):
                    self.assertNotIn("picolibc", result.stdout)
                if profile == "riscof":
                    self.assertNotIn("verilator", result.stdout)
                    self.assertNotIn("sbt", result.stdout)
                    self.assertIn("libgmp10", result.stdout)
                if profile == "sta":
                    self.assertIn("yosys", result.stdout)
                    self.assertIn("verilator", result.stdout)  # RTL packing
                    self.assertNotIn("riscv64", result.stdout)
                if profile == "build":
                    self.assertIn("verilator", result.stdout)
                    self.assertNotIn("riscv64", result.stdout)
                    self.assertIn("libgmp-dev", result.stdout)
                if profile == "litex":
                    self.assertIn("libslirp-dev", result.stdout)

    def test_invalid_profile_fails_before_installing(self):
        result = self.tools("unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sudo", result.stdout)
        self.assertNotIn("brew install", result.stdout)

    def test_espresso_build_disables_docs_in_fresh_and_existing_caches(self):
        # Use real CMake and a C compiler instead of mocking the helper: the
        # old mock-only cache-miss test hid Espresso's documentation dependency.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "third_party/espresso"
            source.mkdir(parents=True)
            (source / "CMakeLists.txt").write_text('''
cmake_minimum_required(VERSION 3.10)
project(espresso C)
option(BUILD_DOC "Build documentation." ON)
if(BUILD_DOC)
  message(FATAL_ERROR "asciidoctor not found, cannot create man pages")
endif()
add_executable(espresso main.c)
''')
            (source / "main.c").write_text("int main(void) { return 0; }\n")
            for cached_docs in (False, True):
                with self.subTest(existing_cache=cached_docs):
                    if cached_docs:
                        cache = source / "build/CMakeCache.txt"
                        cache.write_text(cache.read_text().replace(
                            "BUILD_DOC:BOOL=OFF", "BUILD_DOC:BOOL=ON"))
                    result = self.shell('''
source "$1"
ROOT_DIR="$2"
clone_build_espresso
"$ROOT_DIR/third_party/espresso/build/espresso"
''', ROOT / "setup-rtl.sh", root)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("BUILD_DOC:BOOL=OFF",
                                  (source / "build/CMakeCache.txt").read_text())

    def decoder_fixture(self, root, complete=True):
        generated = root / "rtl/generated"
        generated.mkdir(parents=True)
        names = ["rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv"]
        for name in names if complete else names[:1]:
            path = generated / name
            path.write_text("module decoder; endmodule\n")
            os.utime(path, (1, 1))
        return generated

    def decoders(self, root, hit):
        return self.shell('''
source "$1"
cd "$2"
clone_build_espresso() { echo espresso-build; }
make() { printf 'make %s\\n' "$*"; }
prepare_decoders "$3"
''', SETUP, root, hit)

    def test_exact_decoder_hit_refreshes_outputs_without_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            generated = self.decoder_fixture(Path(tmp))
            before = {p: p.read_bytes() for p in generated.iterdir()}
            result = self.decoders(tmp, "true")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("espresso-build", result.stdout)
            self.assertNotIn("make -C", result.stdout)
            for path, content in before.items():
                self.assertEqual(path.read_bytes(), content)
                self.assertGreater(path.stat().st_mtime, 1)

    def test_partial_decoder_hit_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.decoder_fixture(Path(tmp), complete=False)
            self.assertNotEqual(self.decoders(tmp, "true").returncode, 0)

    def test_decoder_miss_regenerates_even_if_outputs_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.decoder_fixture(Path(tmp))
            result = self.decoders(tmp, "false")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("espresso-build", result.stdout)
            self.assertIn("make -C tools/decodegen verilog", result.stdout)

    def test_riscof_artifact_preserves_executable_without_object_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, target = root / "source", root / "target"
            profile = source / "sim/build/default-riscof"
            model = profile / "obj_dir-riscv32-test/riscv32-npc-sim"
            model.parent.mkdir(parents=True)
            model.write_text("#!/bin/sh\necho shared-simulator\n")
            model.chmod(0o755)
            (profile / "riscv32-npc-sim").symlink_to("obj_dir-riscv32-test/riscv32-npc-sim")
            capstone = source / "nemu/tools/capstone/repo/libcapstone.so.5"
            capstone.parent.mkdir(parents=True)
            capstone.write_bytes(b"runtime-library")
            reference = source / "sail-riscv/bin/sail_riscv_sim"
            reference.parent.mkdir(parents=True)
            reference.write_text("#!/bin/sh\necho shared-reference\n")
            reference.chmod(0o755)
            manifest = source / "sail-riscv/share/sail-riscv/raptor-reference.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('{"model_version": "0.16"}\n')
            env = dict(os.environ, RUNNER_TEMP=tmp, RAPT_CONFIG="default",
                       GITHUB_WORKSPACE=str(source), GITHUB_PATH=str(root / "github-path"))
            result = self.shell("set -eu\nmake() { :; }\n" +
                                workflow_run("Build shared RISCOF simulator") + "\n" +
                                workflow_run("Build shared Sail reference"), cwd=source, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            target.mkdir()
            env["GITHUB_WORKSPACE"] = str(target)
            result = self.shell("set -eu\n" + workflow_run("Restore shared RISCOF simulator"),
                                cwd=target, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.shell(workflow_run("Restore shared Sail reference"),
                                cwd=target, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(target / reference.relative_to(source))],
                                    text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), "shared-reference")
            self.assertEqual((root / "github-path").read_text().strip(),
                             str(target / "sail-riscv/bin"))
            binary = target / "sim/build/default-riscof/riscv32-npc-sim"
            self.assertFalse(binary.is_symlink())
            self.assertFalse((binary.parent / model.parent.name).exists())
            result = subprocess.run([str(binary)], text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), "shared-simulator")

    def test_riscof_worker_does_not_rebuild_in_recursive_make(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            override = root / "worker.mk"
            override.write_text("""
riscof-classic-setup:
	@echo SETUP
riscof-classic-build-npc:
	@echo UNEXPECTED_REBUILD; exit 1
riscof-classic-run:
	@echo RUN_SUITE
""")
            mrom = root / "mrom.bin"
            mrom.touch()
            command = workflow_run("Run classic RISCOF compliance tests")
            command = command.replace("${{ matrix.shard }}", "0")
            args = shlex.split(command)
            args += ["-f", "Makefile", "-f", str(override), f"MROM_IMG={mrom}"]
            env = os.environ.copy()
            for name in ("MAKEFLAGS", "MAKEOVERRIDES", "MFLAGS"):
                env.pop(name, None)
            result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                                    capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SETUP", result.stdout)
            self.assertIn("RUN_SUITE", result.stdout)
            self.assertNotIn("UNEXPECTED_REBUILD", result.stdout)


if __name__ == "__main__":
    unittest.main()
