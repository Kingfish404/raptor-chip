import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BOARD = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOARD / "scripts"))
sys.path.insert(0, str(BOARD / "scripts/hw"))
from flash import END, FIRST, SECTOR, Flash, Session, checked_range
from flash_image import inspect_image, pack_image
from common import tcl_string
import sources


class FakeFlash:
    identity = 0x2c5b19

    def __init__(self):
        self.sectors = {}
        self.mutations = []
        self.corrupt = False

    def read(self, offset, length):
        data = bytearray()
        for address in range(offset, offset + length):
            sector = address // SECTOR * SECTOR
            data.append(self.sectors.get(sector, b"\xff" * SECTOR)[address % SECTOR])
        return bytes(data)

    def program(self, offset, data):
        checked_range(offset, len(data))
        self.mutations.append(("program", offset))
        for index, value in enumerate(data):
            address = offset + index
            sector = address // SECTOR * SECTOR
            self.sectors.setdefault(sector, bytearray(b"\xff" * SECTOR))
            self.sectors[sector][address % SECTOR] &= value
        if self.corrupt:
            self.sectors[offset // SECTOR * SECTOR][-1] = 0

    def erase(self, offset):
        checked_range(offset, SECTOR, SECTOR)
        self.mutations.append(("erase", offset))
        self.sectors[offset] = bytearray(b"\xff" * SECTOR)


class HostChecks(unittest.TestCase):
    def test_fingerprint_ignores_generated_board_outputs(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            board = root / "fpga/arty-a7-t100"
            inputs = (root / "rtl/rapt_pkg.sv",
                      root / "fpga/common/rtl/rapt_native_uart.sv",
                      root / "fpga/common/rtl/rapt_xspi_target.sv", board / "octal.mk")
            for source in inputs:
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("source\n")
            with patch.object(sources, "ROOT", root), patch.object(sources, "BOARD", board):
                baseline = sources.fingerprint(sources.input_files())
                for generated in ("build/soc/design.bit", "tests/__pycache__/test.pyc",
                                  "scripts/.Xil/cache.bin"):
                    output = board / generated
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(b"generated output")
                self.assertEqual(sources.fingerprint(sources.input_files()), baseline)
                (board / "octal.mk").write_text("changed configuration\n")
                self.assertNotEqual(sources.fingerprint(sources.input_files()), baseline)

    def test_image_crc_and_entry(self):
        data = pack_image(b"abcd1234")
        self.assertEqual(inspect_image(data)["length"], 8)
        for byte in (0, 4, 8, 12, 16):
            bad = bytearray(data)
            bad[byte] ^= 1
            with self.subTest(byte=byte), self.assertRaises(ValueError):
                inspect_image(bad)
        for payload in (b"", bytes(0x3e001)):
            with self.assertRaises(ValueError):
                pack_image(payload)

    def test_mutation_bounds(self):
        checked_range(FIRST, 4)
        checked_range(END - 4, 4)
        for offset, length in ((0, 4), (0x10000, 4096), (FIRST - 4, 4),
                               (END - 4, 8), (END, 4), (FIRST + 1, 4), (FIRST, 0)):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                checked_range(offset, length)

    def test_unknown_id_never_writes(self):
        class Unknown:
            writes = []

            def read32(self, address):
                return {0x10002000: 0x52504632, 0x10002008: 0xffffff}.get(address, 0)

            def write32(self, address, value):
                self.writes.append((address, value))

        io = Unknown()
        with self.assertRaises(ValueError):
            Flash(io)
        self.assertEqual(io.writes, [])

    def test_first_use_nonblank_refuses(self):
        flash = FakeFlash()
        flash.sectors[FIRST] = bytearray(SECTOR)
        with tempfile.TemporaryDirectory() as path:
            with self.assertRaisesRegex(ValueError, "not blank"):
                Session(flash, path, [FIRST])
            manifest = json.loads((Path(path) / "manifest.json").read_text())
            self.assertTrue(manifest["refused"])
            self.assertTrue((Path(path) / "original-00000000.bin").exists())
            self.assertEqual(flash.mutations, [])

    def test_restore_and_resume_compare(self):
        flash = FakeFlash()
        with tempfile.TemporaryDirectory() as path:
            session = Session(flash, path, [FIRST])
            session.program(FIRST + 0xfc, b"test")
            Session(flash, path, [FIRST]).compare()
            session.erase(FIRST)
            self.assertEqual(flash.read(FIRST, SECTOR), b"\xff" * SECTOR)
            self.assertTrue(list(Path(path).glob("pre-erase-*.bin")))

    def test_changed_protected_or_target_refuses(self):
        for sector in (0, 0x10000, FIRST, FIRST + SECTOR):
            flash = FakeFlash()
            with tempfile.TemporaryDirectory() as path:
                session = Session(flash, path, [FIRST])
                flash.sectors[sector] = bytearray(SECTOR)
                with self.subTest(sector=sector), self.assertRaises(ValueError):
                    session.erase(FIRST)
                self.assertEqual(flash.mutations, [])

    def test_corruption_does_not_become_owned(self):
        flash = FakeFlash()
        with tempfile.TemporaryDirectory() as path:
            session = Session(flash, path, [FIRST])
            manifest = json.loads((Path(path) / "manifest.json").read_text())
            flash.corrupt = True
            with self.assertRaises(ValueError):
                session.program(FIRST, b"test")
            failed = json.loads((Path(path) / "manifest.json").read_text())
            self.assertEqual(failed["current"], manifest["current"])
            self.assertEqual(failed["inflight"]["operation"], "program")
            with self.assertRaisesRegex(ValueError, "uncertain"):
                Session(flash, path, [FIRST])

    def test_interrupted_blank_erase_cannot_be_retried(self):
        flash = FakeFlash()
        with tempfile.TemporaryDirectory() as path:
            session = Session(flash, path, [FIRST])
            with patch.object(flash, "erase", side_effect=TimeoutError("lost reply")):
                with self.assertRaises(TimeoutError):
                    session.erase(FIRST)
            # Matching old contents cannot prove a submitted erase is no longer busy.
            self.assertEqual(flash.read(FIRST, SECTOR), b"\xff" * SECTOR)
            with self.assertRaisesRegex(ValueError, "uncertain"):
                Session(flash, path, [FIRST])
            with self.assertRaisesRegex(ValueError, "uncertain"):
                session.erase(FIRST)
            self.assertEqual(flash.mutations, [])

    def test_nor_and_ownership_preflight(self):
        flash = FakeFlash()
        with tempfile.TemporaryDirectory() as path:
            session = Session(flash, path, [FIRST])
            session.program(FIRST, bytes(4))
            for offset, data in ((FIRST, b"\xff" * 4), (FIRST + SECTOR, b"test")):
                before = list(flash.mutations)
                with self.assertRaises(ValueError):
                    session.program(offset, data)
                self.assertEqual(flash.mutations, before)

    def test_tcl_quotes_paths_without_substitution(self):
        value = 'a $private [error BAD] {x} "q" \\ tab\tline\n'
        script = "set value " + tcl_string(value) + "\nputs -nonewline $value\n"
        result = subprocess.run(["tclsh"], input=script, text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout, value)

    def test_programmer_never_opens_a_different_or_ambiguous_target(self):
        authorized = "localhost/xilinx_tcf/Digilent/TESTSERIALA"
        unrelated = "localhost/xilinx_tcf/Digilent/OTHERSERIALA"
        for inventory, success in (([unrelated, authorized], True), ([unrelated], False),
                                   ([authorized, authorized], False)):
            setup = "set argv {dummy.bit 1234 TESTSERIAL}\n"
            setup += "set inventory {" + " ".join(inventory) + "}\n"
            setup += """
proc set_param args {}
proc open_hw_manager args {}
proc connect_hw_server args {}
proc get_hw_targets args {global inventory; return $inventory}
proc get_property {key object} {
    if {$key eq "NAME"} {return $object}
    if {$key eq "PART"} {return xc7a100tcsg324-1}
    error "unexpected property"
}
proc current_hw_target {target} {global selected; set selected $target}
proc open_hw_target {} {global selected; puts "OPEN:$selected"}
proc get_hw_devices args {return fpga}
proc refresh_hw_device args {}
proc set_property args {}
proc program_hw_devices args {puts PROGRAM_VOLATILE}
proc close_hw_target args {}
proc disconnect_hw_server args {}
proc close_hw_manager args {}
"""
            setup += "source " + tcl_string(BOARD / "scripts/hw/program.tcl") + "\n"
            result = subprocess.run(["tclsh"], input=setup, capture_output=True, text=True)
            with self.subTest(inventory=inventory):
                self.assertEqual(result.returncode == 0, success)
                if success:
                    self.assertIn("OPEN:" + authorized, result.stdout)
                    self.assertIn("PROGRAM_VOLATILE", result.stdout)
                else:
                    self.assertNotIn("OPEN:", result.stdout)
                    self.assertNotIn("PROGRAM_VOLATILE", result.stdout)
                self.assertNotIn("OPEN:" + unrelated, result.stdout)


if __name__ == "__main__":
    unittest.main()
