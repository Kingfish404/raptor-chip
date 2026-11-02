import json
from pathlib import Path
import tempfile
import unittest

from pc_reference import ALGORITHM, PcReference
from simpoints import digest


def signature(pcs):
    value = 0
    for pc in pcs:
        value = (((value << 7) & ((1 << 64) - 1)) | (value >> 57)) ^ pc ^ 0x9E3779B97F4A7C15
    return value


def write_profile(path, pcs, interval):
    rows = []
    for start in range(0, len(pcs), interval):
        count = min(interval, len(pcs) - start)
        rows.append({"schema": "raptor-bbv-v1", "start": start, "instructions": count,
            "blocks": {"0:0:1000": count}, "pc_digest_algorithm": ALGORITHM,
            "pc_digest_start": f"{signature(pcs[:start]):016x}",
            "pc_digest_end": f"{signature(pcs[:start + count]):016x}",
            "last_pc": hex(pcs[start + count - 1]),
            "pc_band": [[hex(pcs[start + i - 1]), f"{signature(pcs[:start + i]):016x}"]
                        for i in range(1, min(count, 64) + 1)]})
    rows.append({"schema": "raptor-bbv-end-v1", "retired": len(pcs), "complete": True})
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


def window(pcs, checkpoint, counts):
    return {"complete": True, "signature_algorithm": ALGORITHM, "start_pc": hex(pcs[checkpoint]),
        "retirement_domain": {"mode": "all"}, "boundaries": [
            {"instructions": count, "last_pc": hex(pcs[checkpoint + count - 1]) if count else "0x0",
             "signature": f"{signature(pcs[checkpoint:checkpoint + count]):016x}"}
            for count in counts]}


class PcReferenceTests(unittest.TestCase):
    def test_checkpoint_digest_is_rebased_and_detects_divergence(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profile.jsonl"
            pcs = [0xFFFFFFFF80001000 + 4 * (i % 17) for i in range(160)]
            write_profile(path, pcs, 8)
            reference = PcReference(path, digest(path), {"mode": "all"})
            actual = window(pcs, 8, [0, 1, 4, 64, 128])
            point = {"checkpoint_start": 8, "start_pc": actual["start_pc"]}
            self.assertTrue(reference.verify(actual, point)["complete"])
            actual["boundaries"][-1]["signature"] = "0000000000000000"
            with self.assertRaisesRegex(ValueError, "differs from native"):
                reference.verify(actual, point)

    def test_unrecorded_progress_and_missing_native_bands_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profile.jsonl"
            pcs = [0x80001000 + 2 * i for i in range(256)]
            write_profile(path, pcs, 128)
            reference = PcReference(path, digest(path), {"mode": "all"})
            actual = window(pcs, 0, [0, 65])
            with self.assertRaisesRegex(ValueError, "no boundary"):
                reference.verify(actual, {"checkpoint_start": 0, "start_pc": actual["start_pc"]})
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            del rows[0]["pc_band"]
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            with self.assertRaises((KeyError, ValueError)):
                PcReference(path, digest(path), {"mode": "all"})

    def test_corrupt_band_and_changed_profile_hash_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profile.jsonl"
            write_profile(path, list(range(128)), 128)
            before = digest(path)
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            rows[0]["pc_band"][2][1] = "1"
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            with self.assertRaisesRegex(ValueError, "differs from the selected"):
                PcReference(path, before, {"mode": "all"})
            with self.assertRaisesRegex(ValueError, "band digest"):
                PcReference(path, digest(path), {"mode": "all"})


if __name__ == "__main__":
    unittest.main()
