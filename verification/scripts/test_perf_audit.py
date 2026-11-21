#!/usr/bin/env python3
"""Unit tests for verification/scripts/perf_audit.py."""

import tempfile
import unittest
from pathlib import Path

import perf_audit

SAMPLE_PMU_LOG = (
    "pmu.cc:1038 perf_compact #inst: 2560, cycle: 1600, IPC: 1.600, CLINT: 0\n"
    "pmu.cc:1046 perf_compact Stalls (cycles/pct_active, overlapping): "
    "IFU=120/7.5% EX|RS=40/2.5% EX|IoQ=10/0.6% L1D=15/0.9% SQ=0/0.0% no-commit=100/6.2%\n"
    "pmu.cc:1051 perf_compact BPU Success: 255, Fail: 1, Rate: 99.6% (b: 1, j: 0, jr: 0)\n"
    "pmu.cc:1083 perf_compact Commit flush: branch 1, non-branch 0\n"
    "pmu.cc:1089 perf_compact IFU stalls: total=120 no-response=80 redirect=20 serializing=20\n"
)


class PerfAuditTest(unittest.TestCase):
    def test_parse_pmu_and_classify(self):
        m = perf_audit.parse_pmu_log(SAMPLE_PMU_LOG)
        self.assertEqual(m["insts"], 2560)
        self.assertEqual(m["cycles"], 1600)
        self.assertAlmostEqual(m["ipc"], 1.6)
        self.assertAlmostEqual(m["bpu_rate_pct"], 99.6)
        self.assertEqual(perf_audit.classify_bottleneck(m), "Retiring-Healthy")

    def test_gen_microbench(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "mb"
            rc = perf_audit.main(["gen-microbench", "--outdir", str(out), "--iters", "32"])
            self.assertEqual(rc, 0)
            names = (out / "manifest.txt").read_text().strip().splitlines()
            self.assertEqual(len(names), 6)
            for n in names:
                self.assertIn("ebreak", (out / f"{n}.S").read_text())


if __name__ == "__main__":
    unittest.main()
