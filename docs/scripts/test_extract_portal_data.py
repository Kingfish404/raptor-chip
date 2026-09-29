#!/usr/bin/env python3
"""Unit tests for portal data extraction. Uses fixtures plus the live tree."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import extract_portal_data as ext  # noqa: E402


FIXTURE_SV = """
// Fetch unit under test.
// Walks a registered L1I window.
module rapt_ifu #(
    parameter unsigned WIDTH = 2
) (
    input clock,
    input reset
);
  rapt_bpu bpu (
      .clock(clock),
      .reset(reset)
  );
endmodule
"""

FIXTURE_CFG = """
`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
`define RAPT_DECODE_WIDTH 2
`define RAPT_ROB_SIZE 32
`define RAPT_RS_SIZE 8
`define RAPT_IOQ_SIZE 8
`define RAPT_SQ_SIZE 16
`define RAPT_PHY_SIZE 128
`define RAPT_CACHE_LINE_BYTES 64
`define RAPT_L1I_LEN 5
`define RAPT_L1I_N_WAYS 4
`define RAPT_L1D_LEN 5
`define RAPT_L1D_N_WAYS 4
`define RAPT_BPU_DIRP_TAGE
`endif
"""


class ParseSvTest(unittest.TestCase):
    def test_module_and_instance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            path = repo / "hdl" / "frontend" / "rapt_ifu.sv"
            path.parent.mkdir(parents=True)
            path.write_text(FIXTURE_SV, encoding="utf-8")
            parsed = ext.parse_sv_file(path, repo)
            assert parsed is not None
            self.assertEqual(parsed["id"], "rapt_ifu")
            self.assertEqual(parsed["domain"], "frontend")
            self.assertEqual(parsed["instances"][0]["type"], "rapt_bpu")
            self.assertEqual(parsed["instances"][0]["name"], "bpu")
            self.assertIn("Fetch unit", parsed["summary"])
            self.assertEqual(parsed["params"]["WIDTH"], "2")

    def test_skips_sram_instances(self) -> None:
        src = """
module rapt_l1i (
    input clock
);
  rapt_sram_1rw #(
      .WIDTH(32)
  ) data_bank (
      .clock(clock)
  );
  rapt_tlb tlb (
      .clock(clock)
  );
endmodule
"""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            path = repo / "hdl" / "memory" / "rapt_l1i.sv"
            path.parent.mkdir(parents=True)
            path.write_text(src, encoding="utf-8")
            parsed = ext.parse_sv_file(path, repo)
            assert parsed is not None
            types = [i["type"] for i in parsed["instances"]]
            self.assertEqual(types, ["rapt_tlb"])


class ConfigTest(unittest.TestCase):
    def test_conditional_macro_and_package_constant(self) -> None:
        text = """
`define RAPT_ROB_SIZE 32
`define RAPT_SCAN ((`RAPT_ROB_SIZE < 16) ? `RAPT_ROB_SIZE : 16) // bounded
`define RAPT_BPU_DIRP_TAGE
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`else
`define RAPT_XLEN 32
`endif
"""
        for predef, xlen in ((set(), 32), ({"RAPT_RV64"}, 64)):
            defs = ext.parse_defines_ifdef(text, predef)
            self.assertEqual(ext.eval_simple_int(defs["RAPT_SCAN"], defs), 16)
            self.assertEqual(defs["RAPT_XLEN"], str(xlen))
            self.assertEqual(defs["RAPT_BPU_DIRP_TAGE"], "1")
        self.assertEqual(ext.eval_simple_int("rapt_pkg::BranchQueueEntries",
                                            {"rapt_pkg::BranchQueueEntries": "8"}), 8)
        self.assertIsNone(ext.eval_simple_int("`MISSING", {}))
        self.assertIsNone(ext.eval_simple_int("`A", {"A": "`A"}))
        self.assertIsNone(ext.eval_simple_int("unknown_function()", {}))

    def test_cache_kib(self) -> None:
        self.assertEqual(ext.cache_kib(5, 4, 64), 8)

    def test_define_parse(self) -> None:
        defs = ext.parse_defines(FIXTURE_CFG)
        self.assertEqual(defs["RAPT_ROB_SIZE"], "32")
        self.assertIn("RAPT_BPU_DIRP_TAGE", defs)


class MakefileTest(unittest.TestCase):
    def test_help_comments(self) -> None:
        text = """
# ============================================================================
# Setup
# ============================================================================
setup: ## Install dependencies and initialize workspace
help: ## Show this help message
"""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "Makefile").write_text(text, encoding="utf-8")
            data = ext.parse_makefile(repo)
            names = [c["name"] for c in data["commands"]]
            self.assertIn("setup", names)
            self.assertIn("help", names)
            setup = next(c for c in data["commands"] if c["name"] == "setup")
            self.assertEqual(setup["section"], "Setup")


class MermaidTest(unittest.TestCase):
    def test_edges(self) -> None:
        md = """
```mermaid
flowchart TD
  IFU --> IDU --> RNU
  IDU -.Early Resteer.-> IFU
  DPU --> IEU & FEU
```
"""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "README.md").write_text(md, encoding="utf-8")
            data = ext.parse_mermaid(repo)
            pairs = {(e["from"], e["to"]) for e in data["edges"]}
            self.assertIn(("IFU", "IDU"), pairs)
            self.assertIn(("IDU", "RNU"), pairs)
            self.assertIn(("IDU", "IFU"), pairs)
            self.assertIn(("DPU", "IEU"), pairs)
            self.assertIn(("DPU", "FEU"), pairs)


class PayloadTest(unittest.TestCase):
    def test_memory_flow_matches_axi_adapter_then_l2(self) -> None:
        edges = {(edge["from"], edge["to"]) for edge in ext.documented_flow()}
        self.assertIn(("rapt_bus", "rapt_axi_master"), edges)
        self.assertIn(("rapt_axi_master", "rapt_l2"), edges)
        self.assertIn(("rapt_l2", "soc_pmem"), edges)
        self.assertNotIn(("rapt_l2", "rapt_axi_master"), edges)
        for domain, kernel in (("memory", "list"), ("mmio", "")):
            path = ext.path_for_domain(domain, kernel)
            self.assertLess(path.index("rapt_bus"), path.index("rapt_axi_master"))
            self.assertLess(path.index("rapt_axi_master"), path.index("rapt_l2"))

    def test_rv32_selects_sw_not_sd(self) -> None:
        src = """
_start:
  li s2, 1
#if __riscv_xlen == 64
  sd s2, 0(s0)
#else
  sw s2, 0(s0)
#endif
  bnez t0, taken
"""
        text = ext.select_xlen_lines(src, xlen=32)
        self.assertIn("sw s2", text)
        self.assertNotIn("sd s2", text)

    def test_objdump_functions(self) -> None:
        dump = """
8000074e <matrix_mul_matrix>:
80000768:	lh	a4,0(a5)
80000774:	mul	a4,a4,a7
8000077e:	sw	a6,0(t4)
800014fa <putch>:
800014fe:	sb	a0,0(a5)
"""
        funcs = ext.parse_objdump_functions(dump)
        self.assertEqual(funcs["matrix_mul_matrix"][0][0], "lh")
        self.assertEqual(funcs["putch"][0][0], "sb")

    def test_classify(self) -> None:
        self.assertEqual(ext.classify_mnemonic("sw"), "memory")
        self.assertEqual(ext.classify_mnemonic("bnez"), "branch")
        self.assertEqual(ext.classify_mnemonic("csrw"), "system")
        self.assertEqual(ext.classify_mnemonic("addi"), "integer")
        self.assertEqual(ext.classify_mnemonic("mul"), "mul")
        self.assertEqual(ext.classify_coremark("sb", "putch"), "mmio")


class BufferModelNoteTest(unittest.TestCase):
    def test_l1_notes_use_config_kib(self) -> None:
        model = ext.buffer_model({"l1i_kib": 24, "l1d_kib": 12, "l1d_hit": 2}, {})
        self.assertIn("24 KiB", model["rapt_l1i"]["note"])
        self.assertIn("12 KiB", model["rapt_l1d"]["note"])
        self.assertNotIn("8 KiB", model["rapt_l1i"]["note"])
        self.assertNotIn("8 KiB", model["rapt_l1d"]["note"])


class LiveRepoTest(unittest.TestCase):

    def test_build_contains_core_topology(self) -> None:
        repo = ext.repo_root_from(SCRIPT_DIR / "extract_portal_data.py")
        data = ext.build(repo)
        ids = {m["id"] for m in data["modules"]}
        self.assertIn("rapt", ids)
        self.assertIn("rapt_core", ids)
        self.assertIn("rapt_frontend", ids)
        self.assertIn("rapt_backend", ids)
        self.assertIn("rapt_ifu", ids)
        self.assertEqual(data["config"]["values"]["rob_entries"], 32)
        self.assertEqual(data["config"]["values"]["arch_regs"], 32)
        self.assertEqual(data["config"]["values"]["pmp_usable"], 8)
        self.assertEqual(data["config"]["values"]["pmp_csr_slots"], 16)
        self.assertEqual(data["config"]["values"]["l1i_kib"], 16)
        self.assertEqual(data["config"]["values"]["l1d_kib"], 16)
        self.assertEqual(data["config"]["values"]["phys_regs"], 64)
        self.assertEqual(data["config"]["values"]["fetch_response_stage"], 0)
        self.assertEqual(data["config"]["values"]["steer_scan_entries"], 16)
        self.assertEqual(data["config"]["values"]["operand_spill_entries"], 16)
        self.assertEqual(data["config"]["values"]["uoq_entries"], 8)
        self.assertEqual(data["config"]["values"]["store_follower"], 1)
        operand = next(m for m in data["modules"] if m["id"] == "rapt_operand_stage")
        self.assertEqual(operand["file"], "hdl/backend/rapt_rou.sv")
        shown = {n["id"] for n in data["graph"]["nodes"] if n.get("display")}
        for required in (
            "rapt_operand_stage",
            "rapt_ieu_muldiv",
            "rapt_lsu_sq",
            "rapt_tlb",
            "rapt_ptw",
            "rapt_l1d_mshr",
        ):
            self.assertIn(required, shown)
        l1i_n = next(n for n in data["graph"]["nodes"] if n["id"] == "rapt_l1i")
        l1d_n = next(n for n in data["graph"]["nodes"] if n["id"] == "rapt_l1d")
        self.assertIn(f"{data['config']['values']['l1i_kib']} KiB", l1i_n["model_note"])
        self.assertIn(f"{data['config']['values']['l1d_kib']} KiB", l1d_n["model_note"])
        display = {n["id"] for n in data["graph"]["nodes"] if n.get("display")}
        self.assertIn("rapt_ifu", display)
        self.assertTrue(display <= {n["id"] for n in data["graph"]["nodes"]})
        self.assertEqual(data["config"]["values"]["brq_entries"], 8)
        self.assertEqual(data["config"]["values"]["fpq_entries"], 1)
        inst = {(e["from"], e["to"]) for e in data["graph"]["instance_edges"]}
        self.assertIn(("rapt", "rapt_core"), inst)
        self.assertIn(("rapt_core", "rapt_frontend"), inst)
        self.assertIn(("rapt_frontend", "rapt_ifu"), inst)
        self.assertTrue(any(c["name"] == "run-rv32" for c in data["makefile"]["commands"]))
        overview = next(d for d in data["docs"] if d["name"] == "README.md")
        self.assertEqual(overview["title"], "Raptor - RISC-V Processor Core")
        self.assertFalse(overview["summary"].startswith("---"))
        self.assertTrue(data["graph"]["flow_edges"])
        payload = data["payload"]
        self.assertIn("coremark", payload["file"])
        self.assertEqual(payload["xlen"], 32)
        self.assertGreaterEqual(len(payload["instructions"]), 20)
        mnemonics = {i["mnemonic"] for i in payload["instructions"]}
        self.assertTrue({"lh", "mul", "sw"} <= mnemonics)
        self.assertIn("sb", mnemonics)
        domains = {i["domain"] for i in payload["instructions"]}
        self.assertIn("mul", domains)
        self.assertIn("memory", domains)
        self.assertIn("mmio", domains)
        uart = next(i for i in payload["instructions"] if i["domain"] == "mmio")
        self.assertIn("soc_uart", uart["path"])
        list_mem = next(
            i for i in payload["instructions"] if i["domain"] == "memory" and i.get("kernel") == "list"
        )
        self.assertIn("soc_pmem", list_mem["path"])
        node_ids = {n["id"] for n in data["graph"]["nodes"]}
        self.assertIn("soc_uart", node_ids)
        self.assertIn("soc_pmem", node_ids)
        flow_ids = {e["from"] for e in data["graph"]["flow_edges"]} | {
            e["to"] for e in data["graph"]["flow_edges"]
        }
        missing = flow_ids - node_ids
        self.assertFalse(missing, missing)
        display = [n for n in data["graph"]["nodes"] if n.get("display") and n.get("sx")]
        self.assertGreaterEqual(len(display), 12)
        for i, a in enumerate(display):
            for b in display[i + 1 :]:
                dx = abs(a["x"] - b["x"])
                dz = abs(a["z"] - b["z"])
                overlap = dx + 0.04 < (a["sx"] + b["sx"]) / 2 and dz + 0.04 < (
                    a["sz"] + b["sz"]
                ) / 2
                self.assertFalse(overlap, f"{a['id']} overlaps {b['id']}")
        self.assertTrue(all("latency" in n for n in display))
        self.assertIn("rapt_rou", {n["id"] for n in display})
        rob = next(n for n in display if n["id"] == "rapt_rou")
        ifu = next(n for n in display if n["id"] == "rapt_ifu")
        rnu = next(n for n in display if n["id"] == "rapt_rnu")
        pmem = next(n for n in display if n["id"] == "soc_pmem")
        uart = next(n for n in display if n["id"] == "soc_uart")
        self.assertGreater(rob["sz"], ifu["sz"])
        # Schematic y grows downward: smaller z is the top (pipeline) row.
        self.assertLess(ifu["z"], pmem["z"])
        self.assertLess(rnu["z"], pmem["z"])
        self.assertLess(ifu["z"], uart["z"])
        self.assertLess(rnu["z"], uart["z"])
        xs = [n["x"] + n["sx"] / 2 for n in display] + [n["x"] - n["sx"] / 2 for n in display]
        zs = [n["z"] + n["sz"] / 2 for n in display] + [n["z"] - n["sz"] / 2 for n in display]
        aspect = (max(xs) - min(xs)) / max(max(zs) - min(zs), 1e-6)
        self.assertLess(aspect, 4.0, aspect)
        front = next(n for n in display if n["id"] == "rapt_ifu")
        back = next(n for n in display if n["id"] == "rapt_ieu")
        mem = next(n for n in display if n["id"] == "rapt_l1d")
        self.assertLess(front["x"], back["x"])
        self.assertLess(back["z"], mem["z"])
        trace = data["trace"]
        self.assertEqual(trace["kind"], "contract-cycle")
        self.assertEqual(trace["committed"], len(payload["instructions"]))
        self.assertGreater(trace["cycles"], 0)
        for fr in trace["frames"]:
            self.assertLessEqual(len(fr["occ"].get("rapt_idu", [])), 2)
            self.assertLessEqual(len(fr["occ"].get("rapt_cmu", [])), 2)


if __name__ == "__main__":
    unittest.main()
