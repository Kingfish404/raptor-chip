import unittest

from filter_profile import derive, root
from simpoints import make_plan


class UserDomainTests(unittest.TestCase):
    def test_coalesces_uncertain_boundaries_and_preserves_absolute_capture_offsets(self):
        satp = 0x800090000009452A
        selected = root(satp)
        rows = []
        for index, (user, kernel) in enumerate([(100, 0), (70, 30), (100, 0), (20, 80)]):
            blocks = {f"0:{satp:x}:{0x1000 + index * 4:x}": user}
            if kernel:
                blocks[f"1:{satp:x}:ffffffff80000000"] = kernel
            rows.append({"schema": "raptor-bbv-v1", "start": index * 100,
                         "instructions": 100, "guest_start": 10000 + index * 100,
                         "start_pc": hex(0x1000 + index * 4), "blocks": blocks,
                         "start_signature": f"{index:016x}", "end_signature": f"{index+1:016x}"})
            rows[-1].update(pc_digest_algorithm="rotate-xor-pc-v1", pc_digest_start="0",
                            pc_digest_end="1", pc_band=[["0x1000", "1"]], last_pc="0x1000")
        filtered = list(derive(rows, selected))
        self.assertEqual([row["instructions"] for row in filtered], [170, 120])
        self.assertEqual([row["start"] for row in filtered], [0, 170])
        self.assertEqual([row["guest_start"] for row in filtered], [10000, 10200])
        self.assertEqual(filtered[0]["end_signature"], filtered[1]["start_signature"])
        self.assertEqual(sum(filtered[1]["blocks"].values()), 120)
        for row in filtered:
            self.assertTrue(all(field not in row for field in (
                "pc_digest_algorithm", "pc_digest_start", "pc_digest_end", "pc_band", "last_pc")))

    def test_asid_rollover_preserves_process_root_and_requires_pure_user_start(self):
        satp = 0x800090000009452A
        self.assertEqual(root(satp), root(0x800010000009452A))
        self.assertNotEqual(root(satp), root(satp + 1))
        mixed = {"instructions": 100, "blocks": {f"0:{satp:x}:1000": 90,
                 f"1:{satp:x}:ffffffff80000000": 10}}
        self.assertEqual(list(derive([mixed], root(satp))), [])

    def test_verified_capture_can_anchor_a_mixed_interval_without_guessing_its_first_pc(self):
        satp = 0x800090000009452A
        rows = [{"start": i * 100, "instructions": 100, "guest_start": 1000 + i * 100,
                 "start_pc": hex(0x1000 + i * 4), "start_signature": str(i),
                 "end_signature": str(i + 1), "blocks": {
                     f"0:{satp:x}:1000": 90, f"1:{satp:x}:ffffffff80000000": 10}}
                for i in range(4)]
        boundary = {1100: {"pc": "0x1004", "signature": "1"},
                    1300: {"pc": "0x100c", "signature": "3"}}
        filtered = list(derive(rows, root(satp), boundary))
        self.assertEqual([row["guest_start"] for row in filtered], [1100, 1300])
        self.assertEqual([row["instructions"] for row in filtered], [180, 90])
        boundary[1100]["signature"] = "wrong"
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            list(derive(rows, root(satp), boundary))


if __name__ == "__main__":
    unittest.main()
