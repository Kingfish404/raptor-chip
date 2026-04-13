`ifndef YSYX_RNU_INTERNAL_IF_SVH
`define YSYX_RNU_INTERNAL_IF_SVH
`include "ysyx.svh"

// ============================================================================
// RNU Internal Interfaces - connect RNU sub-modules (freelist, maptable).
// PRF interfaces have been removed: PRF now accepts source interfaces
// (exu_rou_if, exu_ioq_bcast_if, rou_cmu_if, cmu_bcast_if) directly.
// For multi-issue, scale read/write port counts via ISSUE_WIDTH parameter.
// ============================================================================

// ----------------------------------------------------------------------------
// Free List interface
// Manages physical register allocation (rename) and deallocation (commit).
// Dual-issue: two allocation ports (alloc_req/alloc_pr, alloc_req_b/alloc_pr_b).
// ----------------------------------------------------------------------------
interface rnu_fl_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN
);
  // Flush recovery
  logic             flush_pipe;
  logic [RLEN-1:0]  flush_rd_a;
  logic [RLEN-1:0]  flush_rd_b;

  // Allocate port A (rename stage -> freelist)
  logic             alloc_req_a;
  logic [PLEN-1:0]  alloc_pr_a;
  logic             alloc_empty_a;

`ifdef YSYX_DUAL_ISSUE
  // Allocate port B (dual issue: second rename slot)
  logic             alloc_req_b;
  logic [PLEN-1:0]  alloc_pr_b;
  logic             alloc_empty_b;  // true if < 2 free registers
`endif

  // Deallocate port A (commit slot A -> freelist)
  logic             dealloc_req_a;
  logic [PLEN-1:0]  dealloc_pr_a;

  // Deallocate port B (commit slot B, dual commit)
  logic             dealloc_req_b;
  logic [PLEN-1:0]  dealloc_pr_b;

  modport master(
      output flush_pipe, flush_rd_a, flush_rd_b,
      output alloc_req_a,
      input  alloc_pr_a, alloc_empty_a,
`ifdef YSYX_DUAL_ISSUE
      output alloc_req_b,
      input  alloc_pr_b, alloc_empty_b,
`endif
      output dealloc_req_a, dealloc_pr_a,
      output dealloc_req_b, dealloc_pr_b
  );
  modport slave(
      input  flush_pipe, flush_rd_a, flush_rd_b,
      input  alloc_req_a,
      output alloc_pr_a, alloc_empty_a,
`ifdef YSYX_DUAL_ISSUE
      input  alloc_req_b,
      output alloc_pr_b, alloc_empty_b,
`endif
      input  dealloc_req_a, dealloc_pr_a,
      input  dealloc_req_b, dealloc_pr_b
  );
endinterface

// ----------------------------------------------------------------------------
// Map Table interface
// Speculative MAP (rename) + committed RAT (commit).
// Slot A: 3 speculative read ports (rs1, rs2, rd_old) + 1 write port.
// Dual-issue slot B: 3 more read ports + 1 more write port.
// ----------------------------------------------------------------------------
interface rnu_mt_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned PLEN = `YSYX_PHY_LEN
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

`ifdef YSYX_DUAL_ISSUE
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
`endif

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
      output map_raddr_a, input map_rdata_a,
      output map_raddr_b, input map_rdata_b,
      output map_raddr_c, input map_rdata_c,
`ifdef YSYX_DUAL_ISSUE
      output map_wen_b, map_waddr_b, map_wdata_b,
      output map_raddr_d, input map_rdata_d,
      output map_raddr_e, input map_rdata_e,
      output map_raddr_f, input map_rdata_f,
`endif
      output rat_wen_a, rat_waddr_a, rat_wdata_a,
      output rat_wen_b, rat_waddr_b, rat_wdata_b
  );
  modport slave(
      input  flush_pipe,
      input  map_wen_a, map_waddr_a, map_wdata_a,
      input  map_raddr_a, output map_rdata_a,
      input  map_raddr_b, output map_rdata_b,
      input  map_raddr_c, output map_rdata_c,
`ifdef YSYX_DUAL_ISSUE
      input  map_wen_b, map_waddr_b, map_wdata_b,
      input  map_raddr_d, output map_rdata_d,
      input  map_raddr_e, output map_rdata_e,
      input  map_raddr_f, output map_rdata_f,
`endif
      input  rat_wen_a, rat_waddr_a, rat_wdata_a,
      input  rat_wen_b, rat_waddr_b, rat_wdata_b
  );
endinterface

`endif // YSYX_RNU_INTERNAL_IF_SVH
