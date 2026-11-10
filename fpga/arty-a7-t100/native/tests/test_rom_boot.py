"""Pure controls for explicit boot-mode propagation and read-only boot checks."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[4]
NATIVE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.bringup.client import BringupError
from tools.bringup.native import fresh_boot, hardware_receipt
from tools.bringup.native_flash import FIRST, RAM

spec = importlib.util.spec_from_file_location("native_rom_build", NATIVE / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class Bus:
    def __init__(self):
        self.words = {0x20000000: 0x300002b7, 0x20000004: 0x00028067}

    def read32(self, address):
        return self.words.get(address, 0)

    def write32(self, address, value):
        self.words[address] = value


class Target:
    def __init__(self, bus, entry):
        self.bus, self.entry = bus, entry
        self.resumed = False

    def halt(self):
        pass

    def reset_halt(self):
        pass

    def resume(self):
        self.resumed = True
        self.bus.words[RAM + 0x1f00] = 0x524a5331
        self.bus.words[RAM + 0x1f04] = 0x524a5332

    def register(self, address):
        if address != 0x7b1:
            raise AssertionError("Unexpected abstract register access")
        return self.entry + 0x94


class Flash:
    def __init__(self, image):
        self.image = image

    def read(self, address, length):
        if address != FIRST or length != len(self.image):
            raise AssertionError("Boot read escaped the approved upper image")
        return self.image


class ReadOnlyBootTest(unittest.TestCase):
    def test_rom_xip_checks_rom_and_xip_pc(self):
        bus = Bus()
        target = Target(bus, 0x30000000)
        result = fresh_boot(target, bus, Flash(b"image"), b"image", 1)
        self.assertTrue(result["fresh_completion"])
        self.assertEqual(result["payload_entry"], 0x30000000)

    def test_wrong_rom_stops_before_resume(self):
        bus = Bus()
        bus.words[0x20000004] = 0x0000006f
        target = Target(bus, 0x30000000)
        with self.assertRaisesRegex(BringupError, "reset ROM differs"):
            fresh_boot(target, bus, Flash(b"image"), b"image", 1)
        self.assertFalse(target.resumed)

    def test_wrong_image_stops_before_resume(self):
        bus = Bus()
        target = Target(bus, 0x30000000)
        with self.assertRaisesRegex(BringupError, "storage differs"):
            fresh_boot(target, bus, Flash(b"wrong"), b"image", 1)
        self.assertFalse(target.resumed)

    def test_reset_alias_pc_is_rejected_for_rom_xip(self):
        bus = Bus()
        with self.assertRaisesRegex(BringupError, "execution address differs"):
            fresh_boot(Target(bus, 0x20000000), bus, Flash(b"image"), b"image", 1)

    def test_old_hardware_receipt_cannot_authorize_new_rom_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = {"native_path": True, "board_serial": "board", "probe_serial": "probe",
                       "bitstream_sha256": "0" * 64, "source_manifest_sha256": "1" * 64,
                       "readonly_boot_sha256": "2" * 64}
            path = root / "receipt.json"
            path.write_text(json.dumps(receipt))
            args = argparse.Namespace(sim=None, hardware_receipt=path, board_serial="board",
                                      probe_serial="probe", command="boot", boot_mode="rom-xip")
            with self.assertRaisesRegex(BringupError, "receipt boot mode differs"):
                hardware_receipt(args, None)


if __name__ == "__main__":
    unittest.main()
