#!/usr/bin/env python3
import unittest
import re
from width_evaluate import (parse_dispatch, parse_frontend, parse_recovery,
                            parse_rob_dispatch,
                            parse_recovery_transaction, parse_rename_checkpoints,
                            parse_alq_selection)

REPORT = """Dispatch stop width: cycles 1, unfilled slots 0, zero-progress cycles 0
Dispatch stop empty: cycles 2, unfilled slots 3, zero-progress cycles 1
Dispatch stop endpoint: cycles 1, unfilled slots 1, zero-progress cycles 0
Dispatch stop recovery: cycles 0, unfilled slots 0, zero-progress cycles 0
Dispatch histogram: [1 2 1]
Dispatch endpoint domain 0: cycles 1
Dispatch accounting: cycles 4, width 2, accepted 4, unfilled 4
"""

ROB_DISPATCH_REPORT = """ROB dispatch steering: candidates 12, accepted 8, bypass 3, oldest blocked 4, pending avg 1.500, peak 5
ROB dispatch blocked domain 0: cycles 1
ROB dispatch blocked domain 1: cycles 2
ROB dispatch blocked domain 2: cycles 0
ROB dispatch blocked domain 3: cycles 0
ROB dispatch blocked domain 4: cycles 1
ROB dispatch pending histogram 0..5: [2 1 0 0 0 1]
ROB dispatch pending domain 0: instruction-cycles 2, peak 1
ROB dispatch pending domain 1: instruction-cycles 4, peak 5
"""


class DispatchParserTest(unittest.TestCase):
    def test_compact_stops_and_endpoints(self):
        compact = re.sub(
            r"Dispatch stop ([a-z_]+): cycles (\d+), unfilled slots (\d+), zero-progress cycles (\d+)\n",
            "", REPORT)
        row = "Dispatch stops (cycles/unfilled_slots/zero_progress_cycles): width=1/0/0 empty=2/3/1 endpoint=1/1/0 recovery=0/0/0\n"
        compact = row + compact.replace("Dispatch endpoint domain 0: cycles 1",
                                        "Dispatch endpoint domains: cycles [1] (index from 0)")
        self.assertEqual(parse_dispatch(compact), parse_dispatch(REPORT))
        for bad in (compact.replace("empty=2/3/1", "empty=2/4/1"),
                    compact.replace("width=1/0/0", "width=1/0/0 width=1/0/0"),
                    compact.replace("endpoint=1/1/0", "endpoint=1/1"),
                    compact.replace("cycles [1]", "cycles [2]")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parse_dispatch(bad)

    def test_compact_rob_domains_and_reasons(self):
        compact = re.sub(r"ROB dispatch blocked domain \d+: cycles \d+\n", "", ROB_DISPATCH_REPORT)
        compact += "ROB dispatch blocked domains: cycles [1 2 0 0 1] (index from 0)\n"
        compact += "ROB branch capacity reasons: cycles [0 0 0 2 0 0 0] (index from 0)\n"
        result = parse_rob_dispatch(compact)
        self.assertEqual(result["blocked_domains"], parse_rob_dispatch(ROB_DISPATCH_REPORT)["blocked_domains"])
        self.assertEqual(result["branch_capacity_reasons"][3], 2)
        self.assertEqual(parse_rob_dispatch(ROB_DISPATCH_REPORT + compact), result)
        for bad in (compact.replace("[1 2 0 0 1]", "[1 3 0 0 1]"),
                    compact.replace("[0 0 0 2 0 0 0]", "[0 0 0 2 0 0]"),
                    compact.replace("[0 0 0 2 0 0 0]", "[0 0 0 1 0 0 0]")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parse_rob_dispatch(bad)

    def test_complete(self):
        result = parse_dispatch(REPORT)
        self.assertEqual(result["accepted"], 4)
        self.assertEqual(result["stops"]["empty"]["zero_progress_cycles"], 1)
        self.assertEqual(result["stops"]["recovery"]["cycles"], 0)

    def test_legacy(self):
        self.assertIsNone(parse_dispatch("old simulator report"))

    def test_earlier_admission_schema(self):
        result = parse_dispatch(re.sub(r", zero-progress cycles \d+", "", REPORT))
        self.assertEqual(result["accepted"], 4)
        self.assertNotIn("zero_progress_cycles", result["stops"]["empty"])

    def test_final_snapshot(self):
        marker = "======== Rename/Dispatch Status ========"
        result = parse_dispatch(marker + "\n" + REPORT + marker + "\n" + REPORT)
        self.assertEqual(result["cycles"], 4)

    def test_legacy_histogram_format(self):
        legacy = REPORT.replace("Dispatch histogram: [1 2 1]",
                                "Dispatch histogram 0: cycles 1\n"
                                "Dispatch histogram 1: cycles 2\n"
                                "Dispatch histogram 2: cycles 1\n")
        self.assertEqual(parse_dispatch(legacy)["histogram"][1], 2)

    def test_bad_totals(self):
        for old, new in [("accepted 4", "accepted 5"), ("domain 0: cycles 1", "domain 0: cycles 2"),
                         ("zero-progress cycles 1", "zero-progress cycles 2"),
                         ("histogram: [1 2 1]", "histogram: [1 3 1]")]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                parse_dispatch(REPORT.replace(old, new))

    def test_branch_capacity_reasons(self):
        bins = ''.join(f'ROB branch capacity reason {r}: cycles {2 if r == 3 else 0}\n'
                       for r in range(7))
        report = ROB_DISPATCH_REPORT + '\n' + bins
        self.assertEqual(parse_rob_dispatch(report)['branch_capacity_reasons'][3], 2)
        for bad in (bins.replace('reason 3: cycles 2', 'reason 3: cycles 1'),
                    bins.replace('reason 0: cycles 0', 'reason 0: cycles 1'),
                    '\n'.join(bins.splitlines()[:-1])):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parse_rob_dispatch(ROB_DISPATCH_REPORT + '\n' + bad)
        with self.assertRaises(ValueError):
            parse_rob_dispatch(report + 'ROB branch capacity reason 0: cycles 0\n')

    def test_rob_dispatch_steering(self):
        result = parse_rob_dispatch(ROB_DISPATCH_REPORT)
        self.assertEqual(result["bypass"], 3)
        self.assertEqual(result["pending_peak"], 5)
        self.assertEqual(result["sample_cycles"], 4)
        self.assertEqual(result["pending_histogram"][5], 1)
        self.assertEqual(result["pending_domains"][1]["instruction_cycles"], 4)
        self.assertEqual(result["blocked_domains"][1], 2)
        self.assertIsNone(parse_rob_dispatch("old simulator report"))
        with self.assertRaises(ValueError):
            parse_rob_dispatch(ROB_DISPATCH_REPORT.replace("domain 4: cycles 1",
                                                           "domain 4: cycles 2"))
        with self.assertRaises(ValueError):
            parse_rob_dispatch(ROB_DISPATCH_REPORT.replace("0..5: [2 1 0 0 0 1]",
                                                           "0..5: [2 1 0 0 0 2]"))
        legacy = ROB_DISPATCH_REPORT.replace(
            "ROB dispatch pending histogram 0..5: [2 1 0 0 0 1]",
            "".join(f"ROB dispatch pending histogram {n}: cycles {c}\n"
                    for n, c in enumerate([2, 1, 0, 0, 0, 1])))
        self.assertEqual(parse_rob_dispatch(legacy)["pending_histogram"][5], 1)
        with self.assertRaises(ValueError):
            parse_rob_dispatch(ROB_DISPATCH_REPORT.replace("domain 1: instruction-cycles 4",
                                                           "domain 1: instruction-cycles 5"))

    def test_truncated(self):
        with self.assertRaises(ValueError):
            parse_dispatch(REPORT.split("Dispatch accounting")[0])

    def test_compact_pending_domains(self):
        compact = re.sub(r"ROB dispatch pending domain \d+: instruction-cycles \d+, peak \d+\n",
                         "", ROB_DISPATCH_REPORT)
        row = "ROB dispatch pending domains 0..1: instruction-cycles [2 4], peak [1 5]\n"
        self.assertEqual(parse_rob_dispatch(compact + row), parse_rob_dispatch(ROB_DISPATCH_REPORT))
        # The final periodic snapshot wins over both legacy and compact rows.
        self.assertEqual(parse_rob_dispatch(ROB_DISPATCH_REPORT + row.replace("[2 4]", "[0 6]")
                                           + compact + row), parse_rob_dispatch(compact + row))
        for bad in (row.replace("[2 4]", "[2]"), row.replace("[1 5]", "[1]"),
                    row.replace("[2 4]", "[2 5]"), row.replace("[1 5]", "[1 6]")):
            with self.subTest(row=bad), self.assertRaises(ValueError):
                parse_rob_dispatch(compact + bad)

    def test_duplicate(self):
        with self.assertRaises(ValueError):
            parse_dispatch(REPORT + REPORT.splitlines()[0])


class FrontendParserTest(unittest.TestCase):
    def test_final_snapshot(self):
        report = "BPU Success: 99, Fail: 6, Rate: 94.3% (b: 3, j: 2, jr: 1), call: 17, ret: 16\n"
        report += "Early resteer: 20 events (decode-stage IFU corrections)\n"
        result = parse_frontend(report + report.replace("resteer: 20", "resteer: 21"))
        self.assertEqual(result["indirect_fail"], 1)
        self.assertEqual(result["decode_resteers"], 21)

    def test_conservation(self):
        with self.assertRaises(ValueError):
            parse_frontend("BPU Success: 99, Fail: 6, Rate: 94.3% (b: 3, j: 2, jr: 2), call: 17, ret: 16")

    def test_missing(self):
        self.assertIsNone(parse_frontend("old report"))


class RenameCheckpointParserTest(unittest.TestCase):
    REPORT = ("Rename checkpoints: pool full 7 cycles, allocation stalls 2 cycles, "
              "occupancy avg 1.625, peak 5; "
              "recovery fence 31 cycles\n")

    def test_complete_and_final(self):
        result = parse_rename_checkpoints(self.REPORT + self.REPORT.replace("peak 5", "peak 6"))
        self.assertEqual(result["full_cycles"], 7)
        self.assertEqual(result["allocation_stall_cycles"], 2)
        self.assertEqual(result["occupancy_average"], 1.625)
        self.assertEqual(result["occupancy_peak"], 6)
        self.assertEqual(result["recovery_fence_cycles"], 31)

    def test_legacy(self):
        report = ("Rename checkpoints: full 7 cycles, occupancy avg 1.625, peak 5; "
                  "recovery fence 31 cycles\n")
        result = parse_rename_checkpoints(report)
        self.assertNotIn("allocation_stall_cycles", result)
        self.assertIsNone(parse_rename_checkpoints("old simulator report"))

    def test_invalid_average(self):
        with self.assertRaises(ValueError):
            parse_rename_checkpoints(self.REPORT.replace("avg 1.625, peak 5", "avg 5.125, peak 5"))


class RecoveryTransactionParserTest(unittest.TestCase):
    def test_complete_final_and_legacy(self):
        report = "Early recovery: redirects 7, pending-fence window 31 cycles\n"
        result = parse_recovery_transaction(report + report.replace("redirects 7", "redirects 8"))
        self.assertEqual(result["early_redirects"], 8)
        self.assertEqual(result["pending_fence_cycles"], 31)
        self.assertIsNone(parse_recovery_transaction("old simulator report"))


class AlqSelectionParserTest(unittest.TestCase):
    def test_compact_summary(self):
        compact = ("ALQ selection: ready-entry cycles 9, issued 8, rebalance extra issues 1; "
                   "reclaim_allocations=2; issue_histogram=[2 2 0 2]; extra_port_issues_ge2=2\n")
        self.assertEqual(parse_alq_selection(compact), parse_alq_selection(self.REPORT))
        self.assertEqual(parse_alq_selection(self.REPORT + compact), parse_alq_selection(compact))
        for bad in (compact.replace("[2 2 0 2]", "[2 2 0 3]"),
                    compact.replace("extra_port_issues_ge2=2", "extra_port_issues_ge2=9")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parse_alq_selection(bad)

    REPORT = """ALQ selection: ready-entry cycles 9, issued 8, rebalance extra issues 1
ALQ issue-slot reclaim: allocations 2
ALQ issue histogram: [2 2 0 2]
ALQ extra physical ports (index >= 2): issues 2
"""

    def test_complete_and_legacy(self):
        result = parse_alq_selection(self.REPORT)
        self.assertEqual(result["issue_histogram"][3], 2)
        self.assertEqual(result["extra_port_issues"], 2)
        self.assertIsNone(parse_alq_selection("old simulator report"))

    def test_conservation(self):
        with self.assertRaises(ValueError):
            parse_alq_selection(self.REPORT.replace("issued 8", "issued 9"))
        with self.assertRaises(ValueError):
            parse_alq_selection(self.REPORT.replace("[2 2 0 2]", "[2 2 0 3]"))

    def test_legacy_histogram_format(self):
        legacy = self.REPORT.replace("ALQ issue histogram: [2 2 0 2]\n",
                                     "ALQ issue histogram 0: cycles 2\n"
                                     "ALQ issue histogram 1: cycles 2\n"
                                     "ALQ issue histogram 2: cycles 0\n"
                                     "ALQ issue histogram 3: cycles 2\n")
        self.assertEqual(parse_alq_selection(legacy)["issue_histogram"][3], 2)


class RecoveryParserTest(unittest.TestCase):
    @staticmethod
    def report():
        result = ("Control lifecycle: allocated 4, resolved 3, retired 2, traps 0, "
                  "killed unresolved 1, killed correct 0, killed wrong 1, reset discarded 0, live 0\n")
        for name in ["correct_retire", "wrong_retire", "wrong_killed"]:
            result += (f"Control latency {name}: count 1, cycles 2, max 2, "
                       f"histogram [0 0 1 0 0 0 0 0]\n")
        return result + "Control pending wrong: union cycles 2, instruction cycles 4, max concurrent 2, live 0\n"

    def test_complete_and_final(self):
        result = parse_recovery(self.report() * 2)
        self.assertEqual(result["allocated"], 4)
        self.assertEqual(result["latency"]["wrong_retire"]["cycles"], 2)

    def test_legacy_histogram_format(self):
        legacy = self.report().replace(", histogram [0 0 1 0 0 0 0 0]", "")
        for name in ["correct_retire", "wrong_retire", "wrong_killed"]:
            for b in range(8):
                legacy += f"Control histogram {name} bucket {b}: count {int(b == 2)}\n"
        self.assertEqual(parse_recovery(legacy)["latency"]["correct_retire"]["histogram"][2], 1)

    def test_invalid(self):
        for old, new in [("allocated 4", "allocated 5"), ("traps 0", "traps 1"),
                         ("max concurrent 2", "max concurrent 1"),
                         ("wrong_retire: count 1, cycles 2, max 2, histogram [0 0 1 0 0 0 0 0]",
                          "wrong_retire: count 1, cycles 2, max 2, histogram [0 0 0 0 0 0 0 0]")]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                parse_recovery(self.report().replace(old, new))

    def test_missing(self):
        self.assertIsNone(parse_recovery("old report"))
        with self.assertRaises(ValueError):
            parse_recovery("Control lifecycle: allocated 1")

    def test_head_partition(self):
        head = "Control pending head domain 2: waiting cycles 1\nControl pending head: ready cycles 1, empty cycles 0\n"
        result = parse_recovery(self.report() + head)
        self.assertEqual(result["pending_head"]["waiting_domains"][2], 1)
        compact = "Control pending head: ready cycles 1, empty cycles 0; waiting_domains=[0 0 1 0 0] (cycles, domain index from 0)\n"
        self.assertEqual(parse_recovery(self.report() + compact)["pending_head"]["waiting_domains"][2], 1)
        with self.assertRaises(ValueError):
            parse_recovery(self.report() + compact.replace("[0 0 1 0 0]", "[0 0 2 0 0]"))
        with self.assertRaises(ValueError):
            parse_recovery(self.report() + head.replace("ready cycles 1", "ready cycles 2"))

    def test_residence_conservation(self):
        residual = "Control pending residual: trap cycles 0, reset cycles 0, live cycles 0\n"
        self.assertEqual(parse_recovery(self.report() + residual)["residual_cycles"]["live"], 0)
        with self.assertRaises(ValueError):
            parse_recovery(self.report() + residual.replace("live cycles 0", "live cycles 1"))


if __name__ == "__main__":
    unittest.main()
