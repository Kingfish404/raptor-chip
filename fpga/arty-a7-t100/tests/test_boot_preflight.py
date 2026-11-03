from pathlib import Path
import sys
import tempfile
import unittest

BOARD = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOARD / "scripts"))
sys.path.insert(0, str(BOARD / "scripts/hw"))
from host import Board
from loader import check_loader


class Fixture:
    def __init__(self, *, boot_pass=True, console=True, timeout=False):
        self.words = {}
        self.console = b"BOOT_CHECK_PASS\n" if console else b""
        self.boot_pass = boot_pass
        self.timeout = timeout
        self.last_run = {"running_status": 0x10005, "link_frames": 8}
        self.stopped = False

    def command(self, cmd, address=0, data=b""):
        if cmd == "A":
            self.stopped = True
        if cmd == "S":
            return 0x10000
        if cmd == "Z":
            self.words.clear()
        if cmd == "W":
            for index in range(0, len(data), 4):
                self.words[address + index] = int.from_bytes(data[index:index + 4], "little")
        if cmd == "R":
            return self.words.get(address, 0)

    def run(self, image, half, timeout):
        self.stopped = False
        assert image.name == "boot_check.bin" and half == 4 and timeout == 5
        if self.timeout:
            raise TimeoutError("no CPU finisher")
        return {"pass": self.boot_pass, "finisher": 0x5555,
                "link_frames": 100, "divider_readback": 4}


class BootPreflight(unittest.TestCase):
    def test_loader_pass_is_insufficient_without_cpu_and_console(self):
        for fixture in (Fixture(), Fixture(boot_pass=False), Fixture(console=False),
                        Fixture(timeout=True)):
            with self.subTest(fixture=vars(fixture)):
                result = check_loader(fixture, Path("build"))
                self.assertEqual(len(result["cases"]), 4)
                expected = fixture.boot_pass and bool(fixture.console) and not fixture.timeout
                self.assertEqual(result["pass"], expected)
                self.assertTrue(fixture.stopped)
                if fixture.timeout:
                    self.assertEqual(result["boot"]["link_frames"], 8)

    def test_timeout_preserves_live_diagnostics_before_recovery(self):
        class Stalled(Board):
            def __init__(self, lost_ack):
                self.last_run = {}
                self.calls = []
                self.lost_ack = lost_ack

            def load(self, data):
                pass

            def command(self, cmd, address=0, data=b"", timeout=10):
                self.calls.append(cmd)
                if cmd == "G" and self.lost_ack:
                    raise TimeoutError("missing G acknowledgement")
                return {"S": 0x10005, "L": 8}.get(cmd, 0)

            def packet(self, deadline):
                raise TimeoutError("missing finisher")

        with tempfile.TemporaryDirectory() as path:
            image = Path(path) / "boot.bin"
            image.write_bytes(b"test")
            expected = {"running_status": 0x10005, "link_frames": 8}
            for lost_ack in (False, True):
                with self.subTest(lost_ack=lost_ack):
                    board = Stalled(lost_ack)
                    board.finisher = None
                    with self.assertRaises(TimeoutError):
                        board.run(image, 4, timeout=0)
                    self.assertEqual(board.calls[-2:], ["S", "L"])
                    self.assertNotIn("A", board.calls)
                    self.assertEqual(board.last_run, expected)


if __name__ == "__main__":
    unittest.main()
