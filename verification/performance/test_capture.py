import json
from pathlib import Path
import tempfile
import unittest

from capture import FILES, reusable_points
from simpoints import digest
from run_samples import check_checkpoint_domain


class CaptureReuseTests(unittest.TestCase):
    def prepare(self, root):
        directory = root / "sample"
        directory.mkdir()
        for name in FILES:
            (directory / name).write_text(name)
        (directory / "sample.json").write_text(json.dumps({"guest_start": 100}))
        hashes = {name: name + "-hash" for name in ("nemu", "firmware", "dtb")}
        parent = {"schema": "raptor-sample-capture-v1", "complete": True,
                  "inputs": {name: {"sha256": value} for name, value in hashes.items()},
                  "points": [{"id": "original-label", "directory": "sample",
                              "files": {name: digest(directory / name) for name in FILES}}]}
        path = root / "capture.json"
        path.write_text(json.dumps(parent))
        return path, hashes, directory

    def test_reuse_is_by_native_retirement_offset_and_preserves_source_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, hashes, directory = self.prepare(Path(temporary))
            available, sources = reusable_points([path], hashes)
            self.assertEqual(available[100][0], directory)
            self.assertEqual(sources[0]["sha256"], digest(path))

    def test_changed_ram_or_different_firmware_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, hashes, directory = self.prepare(Path(temporary))
            with self.assertRaisesRegex(ValueError, "different input"):
                reusable_points([path], {**hashes, "firmware": "different"})
            (directory / "mem_pmem.bin").write_text("changed RAM")
            with self.assertRaisesRegex(ValueError, "checkpoint changed"):
                reusable_points([path], hashes)

    def test_incomplete_capture_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, hashes, _ = self.prepare(Path(temporary))
            parent = json.loads(path.read_text())
            parent["complete"] = False
            path.write_text(json.dumps(parent))
            with self.assertRaisesRegex(ValueError, "incomplete capture"):
                reusable_points([path], hashes)

    def test_user_thread_identity_is_checked_before_replay(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "state.txt").write_text(
                "xlen=64\npriv=0\ncsr_satp=0x800090000009452a\ngpr4=0x3fe0ec5880\n")
            domain = {"mode": "user", "satp_root": "0x800000000009452a",
                      "thread_pointer": "0x3fe0ec5880"}
            check_checkpoint_domain(directory, domain)
            with self.assertRaisesRegex(ValueError, "different user thread"):
                check_checkpoint_domain(directory, {**domain, "thread_pointer": "0x3ff7dadde0"})
            with self.assertRaisesRegex(ValueError, "address space"):
                check_checkpoint_domain(directory, {**domain, "satp_root": "0x8000000000012345"})


if __name__ == "__main__":
    unittest.main()
