"""Meaningful safety checks at the host/native-SBA boundary; no hardware access."""

import json
from pathlib import Path
import struct
import tempfile
import unittest

from tools.bringup.client import BringupError
from tools.bringup.native_flash import (
    CONTROL, END, ERASE, EXPECTED_ID, FIRST, NativeFlash, PartitionSession,
    PROGRAM, SECTOR, Sba32, XIP, mutation_range,
)


class Bus:
    def __init__(self):
        self.registers = {0: 8, 0x10: 9, 0x14: EXPECTED_ID, 0x24: 0x10007,
                          0x28: END - FIRST, 0x2c: SECTOR,
                          0x30: FIRST, 0x34: FIRST, 0x38: END}
        self.memory = {}
        self.writes = []
        self.mutations = []
        self.halted = True
        self.fail_after_accept = False
        self.corrupt_neighbour = False
        self.startup_reads = 0

    def require_halted(self):
        if not self.halted:
            raise BringupError("core is running")

    def read32(self, address):
        if CONTROL <= address < CONTROL + 0x3c:
            offset = address - CONTROL
            if offset == 0x10 and self.startup_reads:
                self.startup_reads -= 1
                return 6
            return self.registers.get(offset, 0)
        if XIP <= address < XIP + END - FIRST:
            physical = self.registers[0x30] + address - XIP
            return int.from_bytes(bytes(self.memory.get(physical + i, 255) for i in range(4)),
                                  "little")
        raise AssertionError(f"unexpected native bus address {address:08x}")

    def write32(self, address, value):
        self.writes.append((address, value))
        offset = address - CONTROL
        if offset == 0x20:
            physical = self.registers[0x30] + self.registers[0x18]
            if value == PROGRAM:
                word = struct.pack("<I", self.registers[0x1c])
                for i, byte in enumerate(word):
                    self.memory[physical + i] = self.memory.get(physical + i, 255) & byte
            elif value == ERASE:
                for i in range(SECTOR):
                    self.memory.pop(physical + i, None)
            else:
                raise AssertionError("unexpected mutation command")
            self.mutations.append((value, physical))
            if self.corrupt_neighbour:
                self.memory[(physical // SECTOR + 1) * SECTOR] = 0
            if self.fail_after_accept:
                raise BringupError("accepted operation lost its owner")
        else:
            self.registers[offset] = value


class HostSafetyTests(unittest.TestCase):
    def setUp(self):
        self.bus = Bus()
        self.flash = NativeFlash(self.bus)

    def test_guard_readback_blocks_old_or_wrong_bitstream(self):
        self.bus.registers[0x34] = 0
        with self.assertRaises(BringupError):
            self.flash.identify()
        with self.assertRaises(BringupError):
            self.flash.erase(FIRST + SECTOR)
        self.assertFalse(self.bus.writes)

    def test_recovery_checks_live_guards_without_mutating(self):
        self.bus.registers[0x34] = 0
        with self.assertRaises(BringupError):
            self.flash.recover()
        self.assertFalse(self.bus.writes)

    def test_recovery_requires_halted_core(self):
        self.bus.halted = False
        with self.assertRaises(BringupError):
            self.flash.recover()
        self.assertFalse(self.bus.writes)

    def test_initialization_waits_for_real_ready(self):
        self.bus.startup_reads = 4
        result = self.flash.identify()
        self.assertEqual(result["half_period"], 8)
        self.assertEqual(self.bus.startup_reads, 0)
        self.assertFalse(self.bus.writes)

    def test_initialization_error_does_not_recover(self):
        self.bus.registers[0x10] = 0x104
        with self.assertRaises(BringupError):
            self.flash.identify()
        self.assertFalse(self.bus.writes)

    def test_legacy_device_and_unsafe_divider_are_rejected(self):
        for offset, value in ((0x14, 0xef6017), (0, 2)):
            with self.subTest(offset=offset):
                bus = Bus()
                bus.registers[offset] = value
                with self.assertRaises(BringupError):
                    NativeFlash(bus).identify()
                self.assertFalse(bus.writes)

    def test_every_protected_or_wrapped_request_stops_before_io(self):
        self.flash.identify()
        cases = ((0, 4), (FIRST - 4, 4), (END, 4), (END - 4, 8),
                 (FIRST, 0), (FIRST + 2, 4), (-1, 4), (True, 4), (FIRST, 0x100000000))
        for offset, length in cases:
            with self.subTest(offset=offset, length=length):
                with self.assertRaises(ValueError):
                    self.flash.program(offset, bytes(length) if 0 <= length < 32 else b"")
                with self.assertRaises(ValueError):
                    mutation_range(offset, length)
        self.assertFalse(self.bus.writes)

    def test_native_api_does_not_fake_lower_partition_reads(self):
        with self.assertRaises(ValueError):
            self.flash.read(0, SECTOR)

    def test_physical_offsets_are_translated_once(self):
        self.flash.identify()
        offset = FIRST + 0x10204
        self.flash.program(offset, b"test")
        self.assertEqual(self.bus.mutations, [(PROGRAM, offset)])
        self.assertIn((CONTROL + 0x18, 0x10204), self.bus.writes)
        self.assertEqual(self.flash.read(offset + 1, 2), b"es")

    def test_running_core_cannot_mutate(self):
        self.flash.identify()
        self.bus.halted = False
        with self.assertRaises(BringupError):
            self.flash.erase(FIRST + SECTOR)
        self.assertFalse(self.bus.writes)

    def test_whole_image_preflight_prevents_partial_nor_program(self):
        self.flash.identify()
        offset = FIRST + SECTOR
        self.bus.memory[offset + 4] = 0
        with self.assertRaises(ValueError):
            self.flash.program(offset, b"test" + bytes([255]) * 4)
        self.assertFalse(self.bus.writes)

    def test_entire_erase_sector_is_verified(self):
        self.flash.identify()
        offset = FIRST + SECTOR
        self.bus.memory[offset + SECTOR - 1] = 0
        self.flash.erase(offset)
        self.assertEqual(self.bus.mutations, [(ERASE, offset)])
        self.assertEqual(self.flash.read(offset, SECTOR), b"\xff" * SECTOR)

    def session(self, directory, identity="test-board"):
        self.flash.identify()
        return PartitionSession(self.flash, directory, [FIRST + 0x10000], identity)

    def test_first_use_nonblank_sector_is_never_adopted(self):
        with tempfile.TemporaryDirectory() as directory:
            self.bus.memory[FIRST + 0x10000] = 0
            with self.assertRaises(BringupError):
                self.session(directory)
            self.assertFalse(self.bus.mutations)
            state = json.loads((Path(directory) / "manifest.json").read_text())
            self.assertTrue(state["refused"])
            self.assertTrue((Path(directory) / "original-00810000.bin").is_file())

    def test_device_ownership_and_modified_backup_stop_new_session(self):
        with tempfile.TemporaryDirectory() as directory:
            self.session(directory)
            with self.assertRaises(BringupError):
                self.session(directory, "different-board")
            (Path(directory) / "original-00800000.bin").write_bytes(b"changed")
            with self.assertRaises(BringupError):
                self.session(directory)
            self.assertFalse(self.bus.mutations)

    def test_interrupted_acceptance_stays_uncertain_across_reconnect(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.session(directory)
            self.bus.fail_after_accept = True
            with self.assertRaises(BringupError):
                session.program(FIRST + 0x10000, b"test")
            with self.assertRaises(BringupError):
                self.session(directory)
            self.assertEqual(len(self.bus.mutations), 1)
            state = json.loads((Path(directory) / "manifest.json").read_text())
            self.assertIsNotNone(state["inflight"])

    def test_neighbour_corruption_keeps_uncertainty(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.session(directory)
            self.bus.corrupt_neighbour = True
            with self.assertRaises(BringupError):
                session.program(FIRST + 0x10000, b"test")
            self.assertIsNotNone(session.state["inflight"])

    def test_owned_cleanup_compares_boot_and_both_neighbours(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.session(directory)
            session.program(FIRST + 0x10000, b"test")
            session.erase(FIRST + 0x10000)
            session.compare()
            self.assertEqual(self.flash.read(FIRST + 0x10000, SECTOR), b"\xff" * SECTOR)
            self.assertIsNone(self.session(directory).state["inflight"])


class Dmi:
    def __init__(self, statuses):
        self.statuses = iter(statuses)
        self.calls = []

    def dmi(self, address, value=None):
        self.calls.append((address, value))
        return next(self.statuses) if address == 0x38 and value is None else 0


class SbaSafetyTests(unittest.TestCase):
    def test_alignment_and_values_are_validated_before_dmi(self):
        target = Dmi([])
        bus = Sba32(target)
        for address, value in ((1, 0), (0, -1), (0, 0x100000000), (True, 0)):
            with self.assertRaises(ValueError):
                bus.write32(address, value)
        self.assertFalse(target.calls)

    def test_busy_or_missing_capability_is_not_silently_cleared(self):
        for status in (0, 0x20200004):
            with self.subTest(status=status):
                target = Dmi([status])
                with self.assertRaises(BringupError):
                    Sba32(target).require()
                self.assertNotIn((0x38, 0x407000), target.calls)

    def test_error_never_replays_write(self):
        target = Dmi([0, 0x2000])
        with self.assertRaises(BringupError):
            Sba32(target).write32(0x1000, 7)
        self.assertEqual(target.calls.count((0x3c, 7)), 1)
        self.assertNotIn((0x38, 0x407000), target.calls)

    def test_busy_timeout_preserves_the_outstanding_request(self):
        target = Dmi([0x200000])
        with self.assertRaises(BringupError):
            Sba32(target, timeout=0).wait()
        self.assertEqual(target.calls, [(0x38, None)])


class AutoDmi:
    def __init__(self):
        self.configuration = 0
        self.address = 0
        self.data = 0
        self.reads = []
        self.calls = []

    def trigger(self):
        self.reads.append(self.address)
        self.data = self.address ^ 0x12345678
        if self.configuration & 0x10000:
            self.address += 4

    def dmi(self, address, value=None):
        self.calls.append((address, value))
        if address == 0x38:
            if value is not None:
                self.configuration = value
            return 0x20000004 | self.configuration
        if address == 0x39 and value is not None:
            self.address = value
            if self.configuration & 0x100000:
                self.trigger()
        if address == 0x3c and value is None:
            result = self.data
            if self.configuration & 0x8000:
                self.trigger()
            return result
        return 0


class BlockSbaTests(unittest.TestCase):
    def test_block_reads_do_not_issue_a_trailing_access(self):
        target = AutoDmi()
        words = Sba32(target).read_words(0x307ffff4, 3)
        self.assertEqual(target.reads, [0x307ffff4, 0x307ffff8, 0x307ffffc])
        self.assertEqual(words, [a ^ 0x12345678 for a in target.reads])
        self.assertFalse(target.configuration & 0x8000)

    def test_single_word_at_last_address_has_no_speculative_read(self):
        target = AutoDmi()
        self.assertEqual(Sba32(target).read_words(0xfffffffc, 1), [0xfffffffc ^ 0x12345678])
        self.assertEqual(target.reads, [0xfffffffc])

    def test_bad_block_bounds_fail_before_any_dmi(self):
        for address, count in ((0, 0), (0xfffffffc, 2), (0, True), (2, 1)):
            target = AutoDmi()
            with self.assertRaises(ValueError):
                Sba32(target).read_words(address, count)
            self.assertFalse(target.calls)


if __name__ == "__main__":
    unittest.main()
