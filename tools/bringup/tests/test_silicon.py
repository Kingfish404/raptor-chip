"""Silicon/native separation, restoration and ordered failure reporting, without devices."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.bringup.client import BringupError
from tools.bringup.io25 import check_gpio
from tools.bringup.native_flash import CONTROL, FIRST, NativeFlash, PartitionSession, SECTOR
from tools.bringup.silicon import Report, bench_evidence, main, scratch, switch_backend
from tools.bringup.tests.test_native_flash import Bus


class ProfileTests(unittest.TestCase):
    def silicon(self, part="mt35xu256aba"):
        bus = Bus()
        bus.registers.update({0x30: 0, 0x34: 0, 0x38: 0x800000})
        if part == "w25q64jw-iq":
            bus.registers.update({0x14: 0xef6017, 0x10: 1})
        flash = NativeFlash(bus, "silicon", part)
        flash.identify()
        return bus, flash

    def test_two_real_descriptors_have_distinct_protocol_status(self):
        for part, expected in (("mt35xu256aba", 0x2c5b19), ("w25q64jw-iq", 0xef6017)):
            bus, flash = self.silicon(part)
            self.assertEqual(flash.identity, expected)
            self.assertEqual(flash.read(0, 4), b"\xff" * 4)
            self.assertFalse(bus.writes)

    def test_crossed_profiles_stop_before_any_mutation(self):
        with self.assertRaises(BringupError):
            NativeFlash(Bus(), "silicon").identify()
        bus, _ = self.silicon()
        with self.assertRaises(BringupError):
            NativeFlash(bus).identify()
        self.assertFalse(bus.writes)

    def test_larger_part_does_not_expand_frozen_aperture_or_boot_write_policy(self):
        bus, flash = self.silicon()
        for offset in (0, 0xfffc, 0x800000, 0x810000, 0x1000000):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                flash.program(offset, b"test")
        self.assertFalse(bus.writes)
        flash.program(0x10000, b"test")
        self.assertIn((CONTROL + 0x18, 0x10000), bus.writes)
        self.assertEqual(flash.read(0x10000, 4), b"test")

    def test_wrong_part_identity_cannot_be_adopted(self):
        bus, _ = self.silicon()
        with self.assertRaises(BringupError):
            NativeFlash(bus, "silicon", "w25q64jw-iq").identify()
        self.assertFalse(bus.writes)

    def test_native_partition_still_rejects_every_lower_write(self):
        bus = Bus()
        flash = NativeFlash(bus)
        flash.identify()
        for address in (0, 0x10000, FIRST - 4):
            with self.assertRaises(ValueError):
                flash.program(address, b"test")
        self.assertFalse(bus.writes)

    def test_silicon_session_backs_up_boot_and_both_neighbours(self):
        bus, flash = self.silicon()
        bus.memory[0] = 0x13
        with tempfile.TemporaryDirectory() as directory:
            result = scratch(flash, Path(directory), 0x10000, b"test", {"chip": "unit"})
            self.assertTrue(result["original_blank_restored"])
            state = json.loads((Path(directory) / "manifest.json").read_text())
            expected = {"00000000", "0000f000", "00010000", "00011000"}
            self.assertEqual(set(state["original"]), expected)
            self.assertIsNone(state["inflight"])
            self.assertEqual(bus.memory[0], 0x13)

    def test_uncertain_command_is_not_retried_or_restored(self):
        bus, flash = self.silicon()
        bus.fail_after_accept = True
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(BringupError):
                scratch(flash, Path(directory), 0x10000, b"test", {})
            self.assertEqual(len(bus.mutations), 1)
            with self.assertRaises(BringupError):
                PartitionSession(flash, directory, [0x10000], {})
            self.assertEqual(len(bus.mutations), 1)

    def test_nonblank_silicon_scratch_stops_before_erase(self):
        bus, flash = self.silicon()
        bus.memory[0x10000] = 0
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(BringupError):
            scratch(flash, Path(directory), 0x10000, b"test", {})
        self.assertFalse(bus.mutations)


class Target:
    def __init__(self):
        self.status = 0x383
        self.events = []
        self.closed = False

    def idcode(self):
        return 0x10001913

    def dmi(self, address, value=None):
        self.events.append(("dmi", address, value))
        if address == 0x10 and value is not None:
            self.status = 0x3083 if value & 2 else 0x383
        return self.status

    def register(self, address):
        return 0 if address == 0x1000 else 0x30000000

    def close(self):
        self.closed = True


class Memory:
    def __init__(self, target):
        self.target = target
        self.words = {0x20000000: 0x300002b7, 0x20000004: 0x00028067,
                      0x20000008: 0x13, 0x2000fffc: 0x13, 0x00100808: 0x30003}
        self.selection = 3

    def require(self):
        pass

    def read32(self, address):
        self.target.events.append(("read", address, self.target.status))
        if address == 0x00100808 and self.target.status & 0x3000:
            self.words[address] = self.selection | self.selection << 16
        return self.words.get(address, 0)

    def write32(self, address, value):
        self.words[address] = value
        if address == 0x00100808:
            self.selection = value

    def read_words(self, address, count):
        return [self.read32(address + 4 * n) for n in range(count)]


class AcceptanceTests(unittest.TestCase):
    def test_gpio_mismatch_releases_outputs_even_if_saved_state_was_enabled(self):
        class GpioBus:
            def __init__(self):
                self.words = {0x10000204: 0, 0x10000208: 5, 0x1000020c: 7}

            def read32(self, address):
                if address == 0x10000200:
                    return 0
                return self.words[address]

            def write32(self, address, value):
                self.words[address] = value

        bus = GpioBus()
        with self.assertRaises(BringupError):
            check_gpio(bus)
        self.assertEqual(bus.words[0x10000208], 0)

    def test_switch_checks_active_while_held_and_never_resumes_absent_bridge(self):
        target = Target()
        switch_backend(target, Memory(target), 0, 1)
        self.assertNotIn(("dmi", 0x10, 0x40000001), target.events)
        reads = [row for row in target.events if row[0:2] == ("read", 0x00100808)]
        self.assertEqual([row[2] for row in reads], [0x383, 0x3083, 0x3083, 0x383])

    def test_failed_step_saves_failure_and_blocks_later_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Report(Path(directory), {})
            def fail():
                raise BringupError("uncertain operation")
            report.step("write", fail)
            report.step("later", lambda: self.fail("must not run"))
            self.assertEqual(report.finish(), 1)
            saved = json.loads(report.path.read_text())
            self.assertFalse(saved["pass"])
            self.assertEqual([r["status"] for r in saved["steps"]], ["FAIL", "NOT_RUN"])

    def test_skip_cannot_become_complete_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Report(Path(directory), {})
            report.step("wire", missing="no instrument")
            self.assertEqual(report.finish(), 0)
            self.assertFalse(report.result["complete"])
            self.assertEqual(report.result["untested"], ["wire"])

    def test_real_debug_cli_selects_serial_executable_and_never_configures_fpga(self):
        target = Target()
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "result"
            with patch("tools.bringup.silicon.OpenOcdTarget", return_value=target) as openocd:
                with patch("tools.bringup.silicon.SbaBytes", return_value=Memory(target)):
                    status = main(["--target", "silicon", "--probe-serial", "selected-probe",
                                   "--board-serial", "fixture", "--chip-serial", "sample",
                                   "--openocd", "/a/wrapper", "--clock-hz", "10000000",
                                   "--phase", "debug", "--output", str(out)])
            self.assertEqual(status, 0)
            self.assertTrue(target.closed)
            self.assertEqual(openocd.call_args.args[0], "selected-probe")
            self.assertEqual(openocd.call_args.args[2], "/a/wrapper")
            self.assertTrue(json.loads((out / "result.json").read_text())["pass"])

    def test_clock_guard_stops_before_probe_connection(self):
        with patch("tools.bringup.silicon.OpenOcdTarget") as openocd:
            with self.assertRaises(SystemExit):
                main(["--probe-serial", "probe", "--board-serial", "fixture",
                      "--chip-serial", "sample", "--clock-hz", "1000000", "--adapter-khz", "500",
                      "--output", "/tmp/unused-acceptance-output"])
            openocd.assert_not_called()

    def test_missing_boot_input_is_logged_before_opening_a_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "result"
            with patch("tools.bringup.silicon.OpenOcdTarget") as openocd:
                status = main(["--probe-serial", "probe", "--board-serial", "fixture",
                               "--chip-serial", "sample", "--clock-hz", "10000000",
                               "--boot-bin", str(Path(directory) / "missing.bin"),
                               "--output", str(out)])
                openocd.assert_not_called()
            self.assertEqual(status, 1)
            result = json.loads((out / "result.json").read_text())
            self.assertEqual(result["steps"][0]["status"], "FAIL")
            self.assertFalse(result["pass"])

    def test_bench_evidence_fails_a_rail_at_current_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bench.json"
            rail = {"name": "rail", "min_v": 1, "max_v": 2, "voltage_v": 1.5,
                    "current_ma": 5, "limit_ma": 5}
            evidence = {"approved_settings": True, "reset_low_observed": True,
                        "clock_hz": 10000000, "rails": [rail]}
            path.write_text(json.dumps(evidence))
            with self.assertRaises(BringupError):
                bench_evidence(path, 10000000)


if __name__ == "__main__":
    unittest.main()
