"""Explicit sector-zero provisioning: real guard checks, exact restore, no uncertain replay."""

from pathlib import Path
import tempfile
import unittest

from tools.bringup.client import BringupError
from tools.bringup.native_flash import SECTOR
from tools.bringup.provision import BootFlash, BootSession
from tools.bringup.tests.test_native_flash import Bus


class ProvisionTests(unittest.TestCase):
    def setup_flash(self):
        bus = Bus()
        bus.registers.update({0x30: 0, 0x34: 0, 0x38: 0x800000})
        flash = BootFlash(bus, "mt35xu256aba")
        flash.identify()
        return bus, flash

    def test_native_arty_guard_cannot_authorize_a_sector_zero_write(self):
        bus = Bus()
        flash = BootFlash(bus, "mt35xu256aba")
        with self.assertRaises(BringupError):
            flash.identify()
        with self.assertRaises(BringupError):
            flash.erase(0)
        self.assertFalse(bus.writes)

    def test_provision_capability_is_limited_to_first_sector(self):
        bus, flash = self.setup_flash()
        for offset, length in ((SECTOR, 4), (SECTOR-4, 8), (0x10000, 4), (0, 0)):
            with self.assertRaises(ValueError):
                flash.mutation_range(offset, length)
        self.assertFalse(bus.writes)

    def test_install_and_restore_nonblank_original_with_persistent_ownership(self):
        bus, flash = self.setup_flash()
        for i, byte in enumerate(b"ORIG"):
            bus.memory[i] = byte
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            session = BootSession(flash, path, {"chip": "unit"})
            session.install(b"new")
            self.assertEqual(flash.read(0, 4), b"new\xff")
            resumed = BootSession(flash, path, {"chip": "unit"})
            resumed.restore()
            self.assertEqual(flash.read(0, SECTOR), b"ORIG" + b"\xff" * (SECTOR-4))
            self.assertIsNone(resumed.state["inflight"])
            self.assertEqual(resumed.state["current"], resumed.state["original"])

    def test_changed_backup_or_owner_or_live_neighbor_blocks_writes(self):
        for corrupt in ("owner", "backup", "neighbor"):
            bus, flash = self.setup_flash()
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp)
                session = BootSession(flash, path, {"chip": "one"})
                if corrupt == "owner":
                    with self.assertRaises(BringupError):
                        BootSession(flash, path, {"chip": "two"})
                elif corrupt == "backup":
                    session.original_path(0).write_bytes(b"changed")
                    with self.assertRaises(BringupError):
                        session.install(b"test")
                else:
                    bus.memory[SECTOR] = 0
                    with self.assertRaises(BringupError):
                        session.install(b"test")
                self.assertFalse(bus.mutations)

    def test_accepted_erase_with_lost_reply_refuses_reconnect_and_restore(self):
        bus, flash = self.setup_flash()
        with tempfile.TemporaryDirectory() as temp:
            session = BootSession(flash, temp, {})
            bus.fail_after_accept = True
            with self.assertRaises(BringupError):
                session.install(b"test")
            with self.assertRaises(BringupError):
                BootSession(flash, temp, {})
            with self.assertRaises(BringupError):
                session.restore()
            self.assertEqual(len(bus.mutations), 1)


if __name__ == "__main__":
    unittest.main()
