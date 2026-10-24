#!/usr/bin/env python3
from __future__ import annotations

import unittest

import pipeline_model as pm


def addi(i: str, dest: str, src: str = "x0") -> dict:
    return {"asm": f"addi {dest},{src},{i}", "mnemonic": "addi", "operands": f"{dest}, {src}, {i}", "domain": "integer", "kernel": "matrix"}


class ParseRegsTest(unittest.TestCase):
    def test_alu(self) -> None:
        d, s = pm.parse_regs("addi", "a0, x0, 1")
        self.assertEqual(d, "a0")
        self.assertEqual(s, ["x0"])

    def test_load(self) -> None:
        d, s = pm.parse_regs("lh", "a4, 0(a5)")
        self.assertEqual(d, "a4")
        self.assertEqual(s, ["a5"])

    def test_store(self) -> None:
        d, s = pm.parse_regs("sw", "a6, 0(t4)")
        self.assertIsNone(d)
        self.assertEqual(s, ["a6", "t4"])


class PipelineTest(unittest.TestCase):
    def test_retires_linear_alu(self) -> None:
        ins = [addi(str(i), "a0") for i in range(8)]
        trace = pm.simulate(ins, {"decode_width": 2, "m_fast": 1, "fetch_response_stage": 1})
        self.assertEqual(trace["committed"], 8)
        self.assertLessEqual(trace["widths"]["decode"], 2)
        for frame in trace["frames"]:
            for node, occ in frame["occ"].items():
                if node == "rapt_idu":
                    self.assertLessEqual(len(occ), 2)
                if node == "rapt_cmu":
                    self.assertLessEqual(len(occ), 2)
                if node == "rapt_ieu":
                    self.assertLessEqual(len(occ), 8 + 4 + 4)

    def test_l1d_hit_at_least_two_cycles(self) -> None:
        ins = [{
            "asm": "lh a4,0(a5)",
            "mnemonic": "lh",
            "operands": "a4, 0(a5)",
            "domain": "memory",
            "kernel": "matrix",
        }]
        trace = pm.simulate(ins, {"decode_width": 2, "m_fast": 1})
        dwell = 0
        for frame in trace["frames"]:
            if 0 in frame["occ"].get("rapt_l1d", []):
                dwell += 1
        self.assertGreaterEqual(dwell, 2)

    def test_no_fqu_skip(self) -> None:
        ins = [addi("1", "t0"), addi("2", "t1")]
        trace = pm.simulate(ins, {"decode_width": 2, "fetch_response_stage": 1})
        seen_fqu = {idx for fr in trace["frames"] for idx in fr["occ"].get("rapt_fqu", [])}
        self.assertEqual(seen_fqu, {0, 1})

    def test_decode_width(self) -> None:
        ins = [addi(str(i), "a0") for i in range(6)]
        trace = pm.simulate(ins, {"decode_width": 2})
        for fr in trace["frames"]:
            self.assertLessEqual(len(fr["occ"].get("rapt_ifu", [])), 2)

    def test_completion_and_retirement_are_per_cycle_events(self) -> None:
        instructions = [addi("1", "t0"),
            {"asm": "lw a0,0(a1)", "mnemonic": "lw", "operands": "a0,0(a1)", "domain": "memory", "kernel": "list"},
            {"asm": "mul t1,t0,a0", "mnemonic": "mul", "operands": "t1,t0,a0", "domain": "mul"},
            {"asm": "beq a0,a1,0", "mnemonic": "beq", "operands": "a0,a1,0", "domain": "branch"},
            {"asm": "fadd.d f0,f1,f2", "mnemonic": "fadd.d", "operands": "f0,f1,f2", "domain": "fp"},
        ]
        trace = pm.simulate(instructions, {"m_fast": 1})
        retired = [idx for f in trace["frames"] for idx in f["occ"].get("rapt_cmu", [])]
        completed = [idx for f in trace["frames"] for idx in f["occ"].get("rapt_completion_stage", [])]
        self.assertEqual(retired, list(range(len(instructions))))
        self.assertEqual(sorted(completed), list(range(len(instructions))))
        self.assertEqual(trace["frames"][-1]["retired_total"], len(instructions))
        for idx in retired:
            completion_cycle = next(f["t"] for f in trace["frames"] if idx in f["occ"].get("rapt_completion_stage", []))
            retirement_cycle = next(f["t"] for f in trace["frames"] if idx in f["occ"].get("rapt_cmu", []))
            self.assertGreater(retirement_cycle, completion_cycle)

    def test_waiting_queues_and_execution_are_disjoint_and_bounded(self) -> None:
        trace = pm.simulate([addi(str(i), "a0") for i in range(40)], {
            "integer_issue_ports": 1, "alq_entries": 2, "rnq_entries": 3, "uoq_entries": 2,
        })
        for frame in trace["frames"]:
            self.assertLessEqual(len(frame["queues"]["alq"]), 2)
            self.assertLessEqual(len(frame["queues"]["rnu"]), 3)
            self.assertLessEqual(len(frame["queues"]["uoq"]), 2)
            self.assertLessEqual(len(frame["executing"]["alq"]), 1)
            for kind in ("alq", "brq", "mdq", "fpq", "ioq"):
                self.assertFalse(set(frame["queues"][kind]) & set(frame["executing"][kind]))


if __name__ == "__main__":
    unittest.main()
