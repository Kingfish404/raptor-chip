import ast
import importlib.util
import json
import os
from pathlib import Path
import pty
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import zlib

FPGA = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(FPGA / "common/scripts"))
import upload

import native_build as build
build.configure(FPGA / "mlk-cu08-ku15p")


class NativeToolsTests(unittest.TestCase):
    def test_source_identity_ignores_chisel_cache_but_tracks_generated_rtl(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            rtl = repo / "hdl/generated/decoder.sv"
            cache = repo / "hdl/chisel/target/out/value/cache.json"
            rtl.parent.mkdir(parents=True)
            cache.parent.mkdir(parents=True)
            rtl.write_text("module decoder; endmodule\n")
            cache.write_text('{"cache": 1}')
            with patch.object(build, "REPO", repo), \
                    patch.object(build, "COMMON", repo / "fpga/common"), \
                    patch.object(build, "BOARD", repo / "fpga/board"):
                before = build.input_hashes()
                self.assertEqual(list(before), ["hdl/generated/decoder.sv"])
                cache.write_text('{"cache": 2}')
                self.assertEqual(build.input_hashes(), before)
                rtl.write_text("module decoder(input wire enable); endmodule\n")
                self.assertNotEqual(build.input_hashes(), before)

    def test_rk_ddr_pin_parity_with_vendor_reference(self):
        reference = FPGA.parent / "third_party/rk-xcku5p-f-v1.2/designs/ddr4_0_ex/imports/example_design.xdc"
        if not reference.exists():
            self.skipTest("optional board reference checkout absent")
        expected = {}
        rename = {"dm_dbi_n": "dm", "dqs_t": "dqs_p", "dqs_c": "dqs_n",
                  "ck_t": "clk_p", "ck_c": "clk_n"}
        for pin, port in re.findall(r'set_property PACKAGE_PIN (\w+)\s+\[\s*get_ports "c0_ddr4_([^"]+)"\s*\]', reference.read_text()):
            stem = port.split("[")[0]
            index = port[len(stem):] if stem in ("adr", "ba", "dq", "dm_dbi_n", "dqs_t", "dqs_c") else ""
            expected["ddram_" + rename.get(stem, stem) + index] = pin
        actual = dict((port, pin) for pin, port in re.findall(
            r"set_property PACKAGE_PIN (\w+) \[get_ports \{([^}]+)\}\]",
            (FPGA / "rk-xcku5p-f/constraints/ddr4.xdc").read_text()))
        self.assertEqual(len(expected), 71)
        self.assertEqual(actual, expected)
        self.assertEqual(len(set(actual.values())), len(actual))

    def test_board_selection_and_device_tree(self):
        try:
            for board, device in (("mlk-cu08-ku15p", "xcku15p"), ("rk-xcku5p-f", "xcku5p")):
                build.configure(FPGA / board)
                self.assertEqual(build.PROFILE["device"], device)
                for xlen in (32, 64):
                    with tempfile.TemporaryDirectory() as temp, patch.object(build, "run"):
                        args = types.SimpleNamespace(xlen=xlen, clock_mhz=50)
                        build.device_tree(args, Path(temp), 131072)
                        tree = (Path(temp) / "native.dts").read_text()
                        self.assertIn(build.PROFILE["compatible"], tree)
                        self.assertIn(build.PROFILE["model"], tree)
        finally:
            build.configure(FPGA / "mlk-cu08-ku15p")

    def test_real_uart_chunk_transport(self):
        master, slave = pty.openpty()
        serial = upload.Serial(os.ttyname(slave))
        data = bytes(range(256)) * 35
        received = bytearray()
        errors = []

        def exact(count):
            result = bytearray()
            while len(result) < count:
                result.extend(os.read(master, count - len(result)))
            return bytes(result)

        def rom():
            try:
                while len(received) < len(data):
                    magic, command, address, length, crc = struct.unpack("<4sBIII", exact(17))
                    self.assertEqual((magic, command, address), (b"RAPT", 1, 0x80000000 + len(received)))
                    self.assertLessEqual(length, 4096)
                    chunk = exact(length)
                    self.assertEqual(zlib.crc32(chunk), crc)
                    received.extend(chunk)
                    os.write(master, b"K")
            except BaseException as exc:
                errors.append(exc)

        thread = threading.Thread(target=rom, daemon=True)
        thread.start()
        try:
            upload.load(serial, 0x80000000, data)
            thread.join(5)
            self.assertFalse(thread.is_alive())
            self.assertFalse(errors, errors)
            self.assertEqual(received, data)
        finally:
            serial.close()
            os.close(slave)
            os.close(master)

    def test_rejection_stops_upload(self):
        class Rejected:
            def __init__(self):
                self.reply = iter((b"E", b"\x03"))
                self.writes = []

            def read(self, **kwargs):
                return next(self.reply)

            def write(self, data):
                self.writes.append(data)

        serial = Rejected()
        with self.assertRaisesRegex(RuntimeError, "error 3"):
            upload.load(serial, 0x80000000, b"x" * 9000)
        self.assertEqual(len(serial.writes), 1)

    def test_memory_map_and_xlen(self):
        regions = build.region_map()
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / "sources").mkdir()
            for xlen, memory, expected in ((32, "bram", 131072), (32, "ddr", 0x40000000),
                                           (64, "ddr", 0x80000000)):
                args = types.SimpleNamespace(xlen=xlen, memory=memory, ram_bytes=131072, clock_mhz=50)
                values, size = build.write_map(args, out)
                self.assertEqual(size, expected)
                self.assertEqual(values["RomBase"], regions["mrom"]["base"])
                self.assertEqual(values["UartBase"], regions["ns16550"]["base"])
                with patch.object(build, "run"):
                    build.device_tree(args, out, size)
                tree = (out / "native.dts").read_text()
                self.assertIn("timebase-frequency = <1000000>", tree)
                self.assertIn("interrupts = <1>", tree)
                self.assertIn(f"0x{expected:x}>", tree)
                self.assertIn(f'riscv,isa-base = "rv{xlen}i"', tree)
                self.assertNotIn("rng-seed", tree)
                # Linux OF fixes the 16550A type: both capacity and TX batch
                # need explicit limits even though IIR reports a non-FIFO UART.
                self.assertIn("fifo-size = <1>", tree)
                self.assertIn("tx-threshold = <0>", tree)
                self.assertIn("no-loopback-test;", tree)
                self.assertNotIn("skip-test;", tree)

    def test_cu08_pin_parity_without_litex(self):
        path = FPGA / "litex/mlk_cu08_ku15p_platform.py"
        tree = ast.parse(path.read_text())
        node = next(n.value for n in tree.body if isinstance(n, ast.Assign) and
                    any(isinstance(t, ast.Name) and t.id == "_io" for t in n.targets))
        constructors = {name: (lambda *args, name=name: (name, *args))
                        for name in ("Pins", "IOStandard", "Subsignal", "Misc")}
        io = eval(compile(ast.Expression(node), str(path), "eval"), {"__builtins__": {}, **constructors})
        constraints = "\n".join(p.read_text() for p in (FPGA / "mlk-cu08-ku15p/constraints").glob("*.xdc"))
        import re
        actual = dict((port, pin) for pin, port in re.findall(
            r"set_property PACKAGE_PIN (\w+) \[get_ports \{([^}]+)\}\]", constraints))
        expected = {}
        for name, num, *items in io:
            if name not in ("clk100", "clk100_ddr", "cpu_resetn", "serial", "user_led", "ddram"):
                continue
            for item in items:
                if item[0] == "Pins":
                    expected[name + (f"[{num}]" if name == "user_led" else "")] = item[1]
                elif item[0] == "Subsignal":
                    signal = item[1]
                    pins = " ".join(s for entry in item[2:] if entry[0] == "Pins" for s in entry[1:]).split()
                    for i, pin in enumerate(pins):
                        if name == "ddram" and signal in ("a", "we_n", "cas_n", "ras_n"):
                            start = {"a": 0, "we_n": 14, "cas_n": 15, "ras_n": 16}[signal]
                            port = f"ddram_adr[{start + i}]"
                        else:
                            port = f"{name}_{signal}" + (f"[{i}]" if len(pins) > 1 else "")
                        expected[port] = pin
        self.assertEqual(actual, expected)
        self.assertEqual(len(set(actual.values())), len(actual))

    def test_load_rejects_stale_and_tampered_results(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / "rapt_cu08.bit").write_bytes(b"test bitstream")
            result = {"identity": "current", "timing_pass": True,
                      "artifacts": {"rapt_cu08.bit": build.sha(out / "rapt_cu08.bit")}}
            (out / "result.json").write_text(json.dumps(result))
            with patch.object(build, "identity", return_value={"sha256": "other"}):
                with self.assertRaisesRegex(RuntimeError, "differ"):
                    build.validate_load(None, out)
            with patch.object(build, "identity", return_value={"sha256": "current"}):
                build.validate_load(None, out)
                (out / "rapt_cu08.bit").write_bytes(b"changed")
                with self.assertRaisesRegex(RuntimeError, "changed"):
                    build.validate_load(None, out)

    def test_software_refresh_requires_identical_hardware(self):
        for change in ("dtb", "rtl", "rom", "constraints", "script", "configuration", "bitstream"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                out = Path(temp)
                files = ("sources/board_sources.sv", "sources/rapt_pack.sv", "sources/board.xdc",
                         "boot.hex", "config.tcl", "native.dtb", "rapt_cu08.bit", "timing.pass",
                         "timing_summary.rpt", "utilization.rpt")
                for name in files:
                    (out / name).parent.mkdir(parents=True, exist_ok=True)
                    (out / name).write_text("original " + name)
                before = {"sha256": "old", "configuration": {"memory": "bram", "clock_mhz": 50},
                          "inputs": {"fpga/common/scripts/native_build.tcl": "original script"},
                          "artifacts": {n: build.sha(out / n) for n in files[:6]}}
                (out / "manifest.json").write_text(json.dumps(before))
                old_bit = build.sha(out / "rapt_cu08.bit")
                result = {"identity": "old", "timing_pass": True, "artifacts": {
                    n: build.sha(out / n) for n in (*files[6:], "manifest.json")}}
                (out / "result.json").write_text(json.dumps(result))

                def prepare(args, destination):
                    after = json.loads(json.dumps(before))
                    after["sha256"] = "new"
                    (out / "native.dtb").write_text("corrected UART properties")
                    changed = {"rtl": "sources/rapt_pack.sv", "rom": "boot.hex",
                               "constraints": "sources/board.xdc", "bitstream": "rapt_cu08.bit"}
                    if change in changed:
                        (out / changed[change]).write_text("modified")
                    if change == "script":
                        after["inputs"]["fpga/common/scripts/native_build.tcl"] = "changed script"
                    if change == "configuration":
                        after["configuration"]["clock_mhz"] = 100
                    after["artifacts"] = {n: build.sha(out / n) for n in files[:6]}
                    (out / "manifest.json").write_text(json.dumps(after))
                    return after

                with patch.object(build, "prepare", side_effect=prepare):
                    if change == "dtb":
                        build.refresh_software(None, out)
                        with patch.object(build, "identity", return_value={"sha256": "new"}):
                            build.validate_load(None, out)
                        self.assertEqual(build.sha(out / "rapt_cu08.bit"), old_bit)
                        self.assertEqual(json.loads((out / "implemented_manifest.json").read_text()), before)
                        self.assertEqual(json.loads((out / "result.json").read_text())["implementation_identity"], "old")
                    else:
                        with self.assertRaisesRegex(RuntimeError, "Hardware inputs changed|artifact changed"):
                            build.refresh_software(None, out)
                        self.assertFalse((out / "result.json").exists())

    def test_refresh_excludes_ddr_files_only_in_bram_mode(self):
        artifacts = dict.fromkeys(("sources/board_sources.sv", "sources/rapt_pack.sv", "boot.hex",
                                  "config.tcl", "sources/rapt_cu08_ddr.sv"), "original")
        manifest = {"configuration": {"memory": "bram"}, "artifacts": artifacts,
                    "inputs": {"fpga/common/scripts/native_build.tcl": "script"}}
        original = build.hardware_inputs(manifest)
        artifacts["sources/rapt_cu08_ddr.sv"] = "changed DDR"
        self.assertEqual(build.hardware_inputs(manifest), original)
        manifest["configuration"]["memory"] = "ddr"
        original = build.hardware_inputs(manifest)
        artifacts["sources/rapt_cu08_ddr.sv"] = "changed again"
        self.assertNotEqual(build.hardware_inputs(manifest), original)



@unittest.skipUnless(shutil.which("tclsh"), "tclsh is required")
class NativeLoadTests(unittest.TestCase):
    def invoke(self, targets="host/ku15p host/0ABC01A", devices="xcku5p", explicit=True):
        harness = r'''
proc open_hw_manager {} {}
proc connect_hw_server {args} {}
proc disconnect_hw_server {} {}
proc close_hw_manager {} {}
proc get_hw_targets {pattern} {return [lsearch -all -inline -glob $::env(TARGETS) $pattern]}
proc open_hw_target {target} {puts "OPENED=$target"}
proc close_hw_target {} {}
proc get_hw_devices {args} {return $::env(DEVICES)}
proc refresh_hw_device {args} {}
proc get_property {property device} {return $device}
proc current_hw_device {device} {}
proc set_property {args} {}
proc program_hw_devices {device} {puts "PROGRAMMED=$device"}
set argv [list $::env(BIT) xcku5p]
if {$::env(EXPLICIT)} {lappend argv */0ABC01A}
set argc [llength $argv]
source $::env(SCRIPT)
'''
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "image.bit").write_bytes(b"test")
            (root / "test.tcl").write_text(harness)
            return subprocess.run(["tclsh", root / "test.tcl"], text=True, capture_output=True,
                env={**os.environ, "TARGETS": targets, "DEVICES": devices, "BIT": str(root / "image.bit"),
                     "EXPLICIT": str(int(explicit)), "SCRIPT": str(
                         FPGA / "common/scripts/vivado_load.tcl")})

    def test_only_requested_target_is_opened(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PROGRAMMED=xcku5p", result.stdout)
        self.assertIn("OPENED=host/0ABC01A", result.stdout)
        self.assertNotIn("OPENED=host/ku15p", result.stdout)

    def test_missing_and_ambiguous_target_are_rejected_before_open(self):
        for targets in ("host/ku15p", "first/0ABC01A second/0ABC01A"):
            with self.subTest(targets=targets):
                result = self.invoke(targets=targets)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("OPENED=", result.stdout)
                self.assertNotIn("PROGRAMMED=", result.stdout)

    def test_wrong_or_duplicate_part_never_programs(self):
        for devices in ("xcku15p", "", "xcku5p xcku5p"):
            with self.subTest(devices=devices):
                result = self.invoke(devices=devices)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("PROGRAMMED=", result.stdout)

    def test_default_scan_still_requires_unique_part(self):
        self.assertEqual(self.invoke(targets="host/0ABC01A", explicit=False).returncode, 0)
        result = self.invoke(explicit=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PROGRAMMED=", result.stdout)


if __name__ == "__main__":
    unittest.main()
