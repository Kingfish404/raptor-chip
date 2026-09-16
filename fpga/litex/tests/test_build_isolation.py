"""Config/pack isolation checks. No synthesis, board access or shared outputs."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
REPO = LITEX.parents[1]
sys.path.insert(0, str(LITEX / "scripts"))
from prepare_private_bios import prepare


class BuildIsolationTest(unittest.TestCase):
    def test_selected_vivado_used_for_build_and_load(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-vivado-', dir='/tmp') as tmp:
            root = Path(tmp)
            selected = root / 'selected tool/vivado'
            fallback = root / 'fallback/vivado'
            for executable, label in ((selected, 'selected'), (fallback, 'wrong')):
                executable.parent.mkdir()
                executable.write_text(f'#!/bin/sh\necho {label}\n')
                executable.chmod(0o755)
            (root / 'venv/bin').mkdir(parents=True)
            (root / 'venv/bin/activate').write_text('# fake environment\n')
            board = root / 'board.py'
            board.write_text('import subprocess\nsubprocess.run(["vivado"], check=True)\n')
            extra = ('.PHONY: tool-selection\ntool-selection:\n'
                     '\t@$(call _run_litex_target,)\n'
                     '\t@$(FPGA_LOAD_TOOL_CHECK)\n'
                     '\t@$(FPGA_LOAD_CMD)\n')
            env = {k: v for k, v in os.environ.items() if not k.startswith(('RAPT_', 'MAKE'))}
            env['PATH'] = str(fallback.parent) + os.pathsep + env['PATH']
            result = subprocess.run(['make', '--no-print-directory', '-f', 'Makefile', '-f', '-',
                                     'tool-selection', 'FPGA_BOARD=mlk_cu08_ku15p', 'FPGA_AUTO_DETECT=0',
                                     'VARIANT=linux64', 'BOOT_MODE=custom', f'BUILD_DIR={root}/build',
                                     f'VENV_DIR={root}/venv', f'PYTHON={sys.executable}',
                                     f'FPGA_PY={board}', f'VIVADO={selected}'],
                                    cwd=LITEX, input=extra, text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['selected', 'selected'])

    def config(self, root, **changes):
        values = dict(FPGA_BOARD="mlk_cu08_ku15p", FPGA_AUTO_DETECT="0",
                      VARIANT="linux32", RAPT_CONFIG="default", SYS_CLK="50000000",
                      BUILD_DIR=str(root))
        values.update(changes)
        names = ("PACK_SV", "FPGA_DIR", "FW_LINUX_FPGA_DIR", "RAPT_PACK_VFLAGS", "SIM_DIR")
        extra = ".PHONY: isolation-config\nisolation-config:\n" + "".join(
            f"\t@printf '%s\\n' '{name}=$({name})'\n" for name in names)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("RAPT_", "MAKE"))}
        result = subprocess.run(["make", "--no-print-directory", "-f", "Makefile", "-f", "-",
                                 "isolation-config", *(f"{k}={v}" for k, v in values.items())],
                                cwd=LITEX, input=extra, text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines()
                    if any(line.startswith(name + "=") for name in names))

    def test_make_config_paths_and_read_only_evaluation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "build"
            base = self.config(root)
            self.assertEqual(base, self.config(root))
            for changes in (dict(VARIANT="linux64"), dict(RAPT_CONFIG="small"),
                            dict(SYS_CLK="75000000"), dict(RAPT_PACK_VFLAGS="-DRAPT_ROB_SIZE=32"),
                            dict(MIG_SIZE="0x20000000"),
                            dict(LINUX_ISA="rv32imac_zicsr_zifencei"),
                            dict(WITH_ETHERNET="1"), dict(LINUX_FPGA_INIT="shell")):
                with self.subTest(changes=changes):
                    other = self.config(root, **changes)
                    self.assertNotEqual(base["FPGA_DIR"], other["FPGA_DIR"])
                    self.assertNotEqual(base["FW_LINUX_FPGA_DIR"], other["FW_LINUX_FPGA_DIR"])
            for changes in (dict(VARIANT="linux64"), dict(RAPT_CONFIG="small"),
                            dict(SYS_CLK="75000000"), dict(RAPT_PACK_VFLAGS="-DRAPT_ROB_SIZE=32")):
                self.assertNotEqual(base["PACK_SV"], self.config(root, **changes)["PACK_SV"])
            self.assertFalse(root.exists(), "make inspection must not write config stamps")
            self.assertNotIn("sim/build", base["PACK_SV"])
            self.assertIn("-DRAPT_FPGA_DSP=1", base["RAPT_PACK_VFLAGS"].split())
            fabric = self.config(root, RAPT_PACK_VFLAGS="-DRAPT_FPGA_DSP=0")
            self.assertIn("-DRAPT_FPGA_DSP=0", fabric["RAPT_PACK_VFLAGS"].split())
            self.assertNotIn("-DRAPT_FPGA_DSP=1", fabric["RAPT_PACK_VFLAGS"].split())
            self.assertNotEqual(base["PACK_SV"], fabric["PACK_SV"])
            # This board intentionally forces UART to 115200: an ignored
            # override is not a distinct effective hardware configuration.
            self.assertEqual(base, self.config(root, UART_BAUD="57600"))
            self.assertNotEqual(base["SIM_DIR"], self.config(root, RAPT_CONFIG="small")["SIM_DIR"])
            # Command-line user defines must not suppress required variant,
            # timing or PMEM additions in Make's prerequisite pack.
            custom = self.config(root, VARIANT="linux64", RAPT_PACK_VFLAGS="-DMY_CONFIG=1")
            for flag in ("-DMY_CONFIG=1", "-DRAPT_LINUX", "-DRAPT_RV64",
                         "-DRAPT_CORE_CLOCK_MHZ=50", "-DRAPT_PMEM_BYTES=1073741824"):
                self.assertIn(flag, custom["RAPT_PACK_VFLAGS"])

    @unittest.skipUnless(shutil.which("verilator"), "requires Verilator preprocessing")
    def test_make_and_cpu_adapter_use_same_pack(self):
        sys.path.insert(0, str(LITEX / "cores"))
        from cpu.raptor.core import Raptor
        from unittest.mock import Mock, patch
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for variant in ("linux32", "linux64"):
                values = self.config(root, VARIANT=variant)
                env = {k: v for k, v in os.environ.items() if not k.startswith(("RAPT_", "MAKE"))}
                result = subprocess.run(["make", "--no-print-directory", "pack",
                                         "FPGA_BOARD=mlk_cu08_ku15p", "FPGA_AUTO_DETECT=0",
                                         "RAPT_CONFIG=default", f"VARIANT={variant}", "SYS_CLK=50000000",
                                         f"BUILD_DIR={root}"],
                                        cwd=LITEX, capture_output=True, text=True, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                platform = Mock()
                with patch.dict(os.environ, {"RAPT_CONFIG": "default", "RAPT_PACK_ROOT": str(root / "rtl"),
                                             "RAPT_PACK_VFLAGS": values["RAPT_PACK_VFLAGS"]}):
                    Raptor.add_sources(platform, variant, pmem_size=0x40000000)
                platform.add_source.assert_called_once_with(values["PACK_SV"])
                self.assertFalse((root / ".rapt_config_stamp").exists())
                self.assertFalse((root / ".rapt_pack_vflags_stamp").exists())

    @unittest.skipUnless(shutil.which("verilator"), "requires Verilator preprocessing")
    def test_parallel_real_packs_and_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            configurations = [(preset, bits) for preset in ("default", "small") for bits in (32, 64)]

            def run(config):
                preset, bits = config
                flags = "-DRAPT_LINUX" + (" -DRAPT_RV64" if bits == 64 else "")
                result = subprocess.run([sys.executable, str(LITEX / "scripts/isolated_pack.py"),
                                         "--repo", str(REPO), "--root", str(root),
                                         "--config", preset, "--flags=" + flags],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                path = Path(result.stdout.strip())
                macros = path.with_suffix(".svh").read_text()
                self.assertIn(f"`define RAPT_XLEN {bits}\n", macros)
                self.assertNotIn(f"`define RAPT_XLEN {96 - bits}\n", macros)
                return path

            with ThreadPoolExecutor(max_workers=4) as pool:
                paths = list(pool.map(run, configurations))
            self.assertEqual(len(set(paths)), 4)
            before = {p: (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
                      for p in paths}
            # Same-config contenders reuse an intact cache; another XLEN must
            # neither overwrite it nor force a rebuild on returning to it.
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(run, configurations * 2))
            self.assertEqual(before, {p: (hashlib.sha256(p.read_bytes()).hexdigest(),
                                         p.stat().st_mtime_ns) for p in paths})

    def test_private_bios_preserves_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            software = source / "litex/soc/software"
            (software / "libc").mkdir(parents=True)
            (software / "common.mak").write_text("# user edit\n# Toolchain options\n")
            (software / "libc/Makefile").write_text("# original libc\n")
            (software / "bios").mkdir()
            (software / "bios/boot.c").write_text('void netboot(int nb_params, char **params)\n{\n}\n')
            first = prepare(source, root / "rv32")
            second = prepare(source, root / "rv64")
            (first / "common.mak").write_text("rv32 only")
            self.assertEqual((software / "common.mak").read_text(), "# user edit\n# Toolchain options\n")
            self.assertNotEqual((first / "common.mak").read_text(), (second / "common.mak").read_text())

    @unittest.skipUnless(shutil.which("verilator"), "requires Verilator preprocessing")
    def test_failed_pack_keeps_last_complete_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            (repo / "hdl/configs/default").mkdir(parents=True)
            (repo / "hdl/generated").mkdir()
            (repo / "hdl/configs/default/rapt_config.svh").write_text("`define TEST_WIDTH 32\n")
            (repo / "hdl/rapt_pkg.sv").write_text("package rapt_pkg; endpackage\n")
            source = repo / "hdl/top.sv"
            source.write_text('`include "rapt_config.svh"\nmodule top; endmodule\n')
            for name in ("rapt_idu_decoder.sv", "rapt_idu_decoder_c.sv"):
                (repo / "hdl/generated" / name).write_text("// fixture\n")
            command = [sys.executable, str(LITEX / "scripts/isolated_pack.py"), "--repo", str(repo),
                       "--root", str(root / "output"), "--config", "default"]
            ok = subprocess.run(command, capture_output=True, text=True, check=True)
            output = Path(ok.stdout.strip()).parent
            names = ("rapt_pack.sv", "rapt_pack.svh", ".signature")
            before = {n: (output / n).read_bytes() for n in names}
            source.write_text('`include "missing_test_header.svh"\n')
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("missing_test_header.svh", failed.stderr)
            self.assertNotIn("Traceback", failed.stderr)
            self.assertEqual(before, {n: (output / n).read_bytes() for n in names})

    def test_conflicting_variant_rejected_before_pack(self):
        sys.path.insert(0, str(LITEX / "cores"))
        from cpu.raptor.core import Raptor
        from unittest.mock import Mock, patch
        with patch.dict(os.environ, {"RAPT_PACK_VFLAGS": "-DRAPT_RV64"}), patch("isolated_pack.pack") as pack:
            with self.assertRaisesRegex(ValueError, "linux32 conflicts"):
                Raptor.add_sources(Mock(), "linux32")
            pack.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(["make", "--no-print-directory", "pack", "VARIANT=linux32",
                                     "FPGA_BOARD=mlk_cu08_ku15p", "FPGA_AUTO_DETECT=0",
                                     "RAPT_PACK_VFLAGS=-DRAPT_RV64", f"BUILD_DIR={tmp}"],
                                    cwd=LITEX, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("linux32 conflicts", result.stderr)


if __name__ == "__main__":
    unittest.main()
