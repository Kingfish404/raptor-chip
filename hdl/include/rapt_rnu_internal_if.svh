/* verilator lint_off DECLFILENAME */
`ifndef RAPT_RNU_INTERNAL_IF_SVH
`define RAPT_RNU_INTERNAL_IF_SVH
`include "rapt.svh"

// ============================================================================
// Map table interface for the standalone formal verification helper.
// PRF interfaces have been removed: PRF now accepts source interfaces
// (typed completion messages, rou_cmu_if, cmu_bcast_if) directly.
// Legacy two-slot helpers use fixed A/B ports. The integrated RNU uses
// width-parameterized interfaces instead.
// ============================================================================

// ----------------------------------------------------------------------------
// Map Table interface
// Speculative MAP (rename) + committed RAT (commit).
// Slot A: 3 speculative read ports (rs1, rs2, rd_old) + 1 write port.
// Dual-issue slot B: 3 more read ports + 1 more write port.
// ----------------------------------------------------------------------------
interface rnu_mt_if #(
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter unsigned PLEN = `RAPT_PHY_LEN
);
  // Flush
  logic             flush_pipe;

  // Speculative rename write A
  logic             map_wen_a;
  logic [RLEN-1:0]  map_waddr_a;
  logic [PLEN-1:0]  map_wdata_a;

  // Speculative read port A (rs1)
  logic [RLEN-1:0]  map_raddr_a;
  logic [PLEN-1:0]  map_rdata_a;

  // Speculative read port B (rs2)
  logic [RLEN-1:0]  map_raddr_b;
  logic [PLEN-1:0]  map_rdata_b;

  // Speculative read port C (rd old mapping -> prs for ROB)
  logic [RLEN-1:0]  map_raddr_c;
  logic [PLEN-1:0]  map_rdata_c;

  // Speculative rename write B (dual issue: younger instruction)
  logic             map_wen_b;
  logic [RLEN-1:0]  map_waddr_b;
  logic [PLEN-1:0]  map_wdata_b;

  // Speculative read port D (slot B rs1)
  logic [RLEN-1:0]  map_raddr_d;
  logic [PLEN-1:0]  map_rdata_d;

  // Speculative read port E (slot B rs2)
  logic [RLEN-1:0]  map_raddr_e;
  logic [PLEN-1:0]  map_rdata_e;

  // Speculative read port F (slot B rd old mapping -> prs_b for ROB)
  logic [RLEN-1:0]  map_raddr_f;
  logic [PLEN-1:0]  map_rdata_f;

  // Committed write A (commit slot A)
  logic             rat_wen_a;
  logic [RLEN-1:0]  rat_waddr_a;
  logic [PLEN-1:0]  rat_wdata_a;

  // Committed write B (commit slot B, dual commit)
  logic             rat_wen_b;
  logic [RLEN-1:0]  rat_waddr_b;
  logic [PLEN-1:0]  rat_wdata_b;

  modport master(
      output flush_pipe,
      output map_wen_a, map_waddr_a, map_wdata_a,
      output map_raddr_a,
      input map_rdata_a,
      output map_raddr_b,
      input map_rdata_b,
      output map_raddr_c,
      input map_rdata_c,
      output map_wen_b, map_waddr_b, map_wdata_b,
      output map_raddr_d,
      input map_rdata_d,
      output map_raddr_e,
      input map_rdata_e,
      output map_raddr_f,
      input map_rdata_f,
      output rat_wen_a, rat_waddr_a, rat_wdata_a,
      output rat_wen_b, rat_waddr_b, rat_wdata_b
  );
  modport slave(
      input flush_pipe,
      input map_wen_a, map_waddr_a, map_wdata_a,
      input map_raddr_a,
      output map_rdata_a,
      input map_raddr_b,
      output map_rdata_b,
      input map_raddr_c,
      output map_rdata_c,
      input map_wen_b, map_waddr_b, map_wdata_b,
      input map_raddr_d,
      output map_rdata_d,
      input map_raddr_e,
      output map_rdata_e,
      input map_raddr_f,
      output map_rdata_f,
      input rat_wen_a, rat_waddr_a, rat_wdata_a,
      input rat_wen_b, rat_waddr_b, rat_wdata_b
  );
endinterface

`endif  // RAPT_RNU_INTERNAL_IF_SVH
