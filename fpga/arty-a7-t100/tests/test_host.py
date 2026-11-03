import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BOARD = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOARD / "scripts"))
sys.path.insert(0, str(BOARD / "scripts/hw"))
from flash import END, FIRST, SECTOR, Flash, Session, checked_range
from flash_image import inspect_image, pack_image
from common import tcl_string


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
            manifest = (Path(path) / "manifest.json").read_bytes()
            flash.corrupt = True
            with self.assertRaises(ValueError):
                session.program(FIRST, b"test")
            self.assertEqual((Path(path) / "manifest.json").read_bytes(), manifest)

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


if __name__ == "__main__":
    unittest.main()
