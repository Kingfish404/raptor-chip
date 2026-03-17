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
// Multi-issue: replicate alloc_req/alloc_pr into arrays of ISSUE_WIDTH.
// ----------------------------------------------------------------------------
interface rnu_fl_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN
);
  // Flush recovery
  logic             flush_pipe;
  logic [RLEN-1:0]  flush_rd_a;
  logic [RLEN-1:0]  flush_rd_b;

  // Allocate port (rename stage → freelist)
  logic             alloc_req;
  logic [PLEN-1:0]  alloc_pr;
  logic             alloc_empty;

  // Deallocate port A (commit slot A → freelist)
  logic             dealloc_req_a;
  logic [PLEN-1:0]  dealloc_pr_a;

  // Deallocate port B (commit slot B, dual commit)
  logic             dealloc_req_b;
  logic [PLEN-1:0]  dealloc_pr_b;

  modport master(
      output flush_pipe, flush_rd_a, flush_rd_b,
      output alloc_req,
      input  alloc_pr, alloc_empty,
      output dealloc_req_a, dealloc_pr_a,
      output dealloc_req_b, dealloc_pr_b
  );
  modport slave(
      input  flush_pipe, flush_rd_a, flush_rd_b,
      input  alloc_req,
      output alloc_pr, alloc_empty,
      input  dealloc_req_a, dealloc_pr_a,
      input  dealloc_req_b, dealloc_pr_b
  );
endinterface

// ----------------------------------------------------------------------------
// Map Table interface
// Speculative MAP (rename) + committed RAT (commit).
// 3 speculative read ports: rs1, rs2, rd_old (old prs mapping for ROB dealloc).
// Multi-issue: replicate write port + read port groups.
// ----------------------------------------------------------------------------
interface rnu_mt_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned PLEN = `YSYX_PHY_LEN
);
  // Flush
  logic             flush_pipe;

  // Speculative rename write
  logic             map_wen;
  logic [RLEN-1:0]  map_waddr;
  logic [PLEN-1:0]  map_wdata;

  // Speculative read port A (rs1)
  logic [RLEN-1:0]  map_raddr_a;
  logic [PLEN-1:0]  map_rdata_a;

  // Speculative read port B (rs2)
  logic [RLEN-1:0]  map_raddr_b;
  logic [PLEN-1:0]  map_rdata_b;

  // Speculative read port C (rd old mapping → prs for ROB)
  logic [RLEN-1:0]  map_raddr_c;
  logic [PLEN-1:0]  map_rdata_c;

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
      output map_wen, map_waddr, map_wdata,
      output map_raddr_a, input map_rdata_a,
      output map_raddr_b, input map_rdata_b,
      output map_raddr_c, input map_rdata_c,
      output rat_wen_a, rat_waddr_a, rat_wdata_a,
      output rat_wen_b, rat_waddr_b, rat_wdata_b
  );
  modport slave(
      input  flush_pipe,
      input  map_wen, map_waddr, map_wdata,
      input  map_raddr_a, output map_rdata_a,
      input  map_raddr_b, output map_rdata_b,
      input  map_raddr_c, output map_rdata_c,
      input  rat_wen_a, rat_waddr_a, rat_wdata_a,
      input  rat_wen_b, rat_waddr_b, rat_wdata_b
  );
endinterface

`endif // YSYX_RNU_INTERNAL_IF_SVH
