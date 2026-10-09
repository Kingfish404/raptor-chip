"""Exercise subsystem build invalidation without compiling the RTL."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SubsystemBuildCacheTest(unittest.TestCase):
    def test_all_scopes_track_xlen_config_defines_and_headers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            hdl = root / "hdl"
            (hdl / "include").mkdir(parents=True)
            for config in ("default", "default-l2"):
                directory = hdl / "configs" / config
                directory.mkdir(parents=True)
                (directory / "rapt_config.svh").write_text("// configuration\n")
            header = hdl / "include" / "rapt.svh"
            header.write_text("// common header\n")
            (hdl / "rapt_pkg.sv").write_text("package rapt_pkg; endpackage\n")
            calls = root / "calls.jsonl"
            compiler = root / "fake-verilator"
            compiler.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\nfrom pathlib import Path\n"
                f"with Path({str(calls)!r}).open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                "args=sys.argv[1:]\n"
                "out=Path(args[args.index('--Mdir')+1])\n"
                "top=args[args.index('--top-module')+1]\n"
                "(out/('V'+top)).write_text('compiled')\n"
            )
            compiler.chmod(0o755)
            build = root / "build"
            targets = [str(build / scope / ("Vtb_" + top + "_trace"))
                       for scope, top in (("fe", "frontend"), ("mem", "memory"),
                                          ("be", "backend"))]

            def compile_scopes(config="default", xlen=32, defines=""):
                command = ["make", "--no-print-directory", "-C", str(ROOT / "verify/subsystem"),
                           *targets, f"BUILD_DIR={build}", f"HDL_HOME={hdl}",
                           f"VERILATOR={compiler}", f"CONFIG={config}", f"XLEN={xlen}",
                           f"EXTRA_DEFINES={defines}"]
                result = subprocess.run(command, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return [json.loads(line) for line in calls.read_text().splitlines()]

            self.assertEqual(len(compile_scopes()), 3)
            self.assertEqual(len(compile_scopes()), 3)
            records = compile_scopes(xlen=64)
            self.assertEqual(len(records), 6)
            self.assertTrue(all("-DRAPT_RV64" in args for args in records[-3:]))
            records = compile_scopes(xlen=64, defines="-DRAPT_FETCH_RESPONSE_STAGE=1")
            self.assertEqual(len(records), 9)
            self.assertTrue(all("-DRAPT_FETCH_RESPONSE_STAGE=1" in args for args in records[-3:]))
            records = compile_scopes(config="default-l2", xlen=64,
                                     defines="-DRAPT_FETCH_RESPONSE_STAGE=1")
            self.assertEqual(len(records), 12)
            self.assertTrue(all(f"-I{hdl}/configs/default-l2" in args for args in records[-3:]))
            # Set a newer timestamp deterministically, including on file systems
            # that round two quick writes to the same timestamp.
            newer = max(Path(target).stat().st_mtime_ns for target in targets) + 1
            header.write_text("// changed common header\n")
            os.utime(header, ns=(newer, newer))
            self.assertEqual(len(compile_scopes(config="default-l2", xlen=64,
                                               defines="-DRAPT_FETCH_RESPONSE_STAGE=1")), 15)


if __name__ == "__main__":
    unittest.main()
