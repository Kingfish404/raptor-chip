`ifndef YSYX_EX_IF_SVH
`define YSYX_EX_IF_SVH
`include "ysyx.svh"
import ysyx_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface exu_prf_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  ysyx_pkg::prd_t prd;
  logic [PLEN-1:0] pr1_a;
  logic [PLEN-1:0] pr2_a;

  logic [XLEN-1:0] pv1_a;
  logic [XLEN-1:0] pv2_a;
  logic pv1_a_valid;
  logic pv2_a_valid;

`ifdef YSYX_DUAL_ISSUE
  // Slot B read ports (dual issue)
  logic [PLEN-1:0] pr1_b;
  logic [PLEN-1:0] pr2_b;

  logic [XLEN-1:0] pv1_b;
  logic [XLEN-1:0] pv2_b;
  logic pv1_b_valid;
  logic pv2_b_valid;
`endif

  modport master(
      output pr1_a, pr2_a,
      input pv1_a, pv1_a_valid, pv2_a, pv2_a_valid
`ifdef YSYX_DUAL_ISSUE
      , output pr1_b, pr2_b
      , input pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
`endif
  );
  modport slave(
      input pr1_a, pr2_a,
      output pv1_a, pv1_a_valid, pv2_a, pv2_a_valid
`ifdef YSYX_DUAL_ISSUE
      , input pr1_b, pr2_b
      , output pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
`endif
  );
endinterface

interface exu_lsu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic rvalid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic atomic_lock;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] rdata;
  logic trap;
  logic [XLEN-1:0] cause;
  logic difftest_skip;
  logic rready;

  modport master(output rvalid, raddr, ralu, atomic_lock, pc, input rdata, trap, cause, difftest_skip, rready);
  modport slave(input rvalid, raddr, ralu, atomic_lock, pc, output rdata, trap, cause, difftest_skip, rready);
endinterface


interface exu_csr_if #(
    parameter bit [7:0] R_W  = 12,
    parameter bit [7:0] XLEN = `YSYX_XLEN
);
  logic [ R_W-1:0] raddr;

  logic [XLEN-1:0] rdata;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic [XLEN-1:0] sepc;

  modport master(output raddr, input rdata, mtvec, mepc, sepc);
  modport slave(input raddr, output rdata, mtvec, mepc, sepc);
endinterface

interface exu_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;

  // ROB destination index (0-indexed, directly maps to rob_entry[]).
  logic [$clog2(`YSYX_ROB_SIZE)-1:0] dest;
  logic [XLEN-1:0] result;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  // csr (WB-written; csr_addr lives in uop_pl, not here)
  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic difftest_skip;

  logic valid;

  modport in(
      input pc, npc, btaken,
      input dest, result,
      input prd, rd,
      input csr_wen, csr_wdata,
      input trap, tval, cause,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc, btaken,
      output dest, result,
      output prd, rd,
      output csr_wen, csr_wdata,
      output trap, tval, cause,
      output difftest_skip,
      output valid
  );
endinterface

// Second writeback bus: pure ALU + BRU (branch/JAL/JALR).
// Slot B handles arithmetic and branch-target/condition resolution but never
// CSR / system / trap / MUL — those still go through exu_rou (slot A).
interface exu_rou_b_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;

  logic [$clog2(`YSYX_ROB_SIZE)-1:0] dest;
  logic [XLEN-1:0] result;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  logic difftest_skip;
  logic valid;

  modport in(
      input pc, npc, btaken,
      input dest, result,
      input prd, rd,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc, btaken,
      output dest, result,
      output prd, rd,
      output difftest_skip,
      output valid
  );
endinterface

// Third writeback bus: dedicated BRU for conditional branches (ben).
// Conditional branches never write rd and never produce values consumed
// downstream, so this bus carries only ROB-state + branch-resolution
// fields (no result/prd/rd, no PRF write port, no bypass network entry).
interface exu_rou_c_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;

  logic [$clog2(`YSYX_ROB_SIZE)-1:0] dest;

  logic difftest_skip;
  logic valid;

  modport in(
      input pc, npc, btaken,
      input dest,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc, btaken,
      output dest,
      output difftest_skip,
      output valid
  );
endinterface

// EXU internal: top-level dispatch arbiter <-> Reservation Station.
// Top reads RS free-vector status, drives accept signals back to RS.
interface exu_disp_rs_if #(
    parameter unsigned RS_SIZE = `YSYX_RS_SIZE
);
  // RS -> top status
  logic free_found_a;
  logic free_found_b;
  logic [$clog2(RS_SIZE)-1:0] free_idx_a;
  logic [$clog2(RS_SIZE)-1:0] free_idx_b;
  logic mul_found;        // a MUL is currently selectable in the FU
  // top -> RS dispatch decisions (gated by rou_exu.valid / valid_b)
  logic accept_a;         // slot A is allocated to RS this cycle (uses free_idx_a)
  logic accept_b;         // slot B is allocated to RS this cycle (uses b_rs_idx)
  logic [$clog2(RS_SIZE)-1:0] b_rs_idx;

  modport top(
      input free_found_a, free_found_b, free_idx_a, free_idx_b, mul_found,
      output accept_a, accept_b, b_rs_idx
  );
  modport rs(
      output free_found_a, free_found_b, free_idx_a, free_idx_b, mul_found,
      input accept_a, accept_b, b_rs_idx
  );
endinterface

// EXU internal: top-level dispatch arbiter <-> In-Order Queue.
// `ready` reflects head-of-tail availability; `accept_*` are top-driven.
interface exu_disp_ioq_if #(
    parameter unsigned IOQ_SIZE = `YSYX_IOQ_SIZE
);
  // IOQ -> top status
  logic ready;            // ioq_valid[ioq_tail] == 0
  logic ready_b;          // ioq_valid[ioq_tail+1] == 0 (for dual-enqueue)
  // top -> IOQ dispatch decisions
  logic accept_a;         // slot A enqueued (uses ioq_tail)
  logic accept_b_paired;  // slot B enqueued together with A (uses ioq_tail+1)
  logic accept_b_alone;   // slot B enqueued without A (uses ioq_tail)

  modport top(
      input ready, ready_b,
      output accept_a, accept_b_paired, accept_b_alone
  );
  modport ioq(
      output ready, ready_b,
      input accept_a, accept_b_paired, accept_b_alone
  );

  // Tie unused signal to silence lint when YSYX_DUAL_ISSUE is off.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(IOQ_SIZE)-1:0] _ioq_size_pad;
  /* verilator lint_on UNUSEDSIGNAL */
endinterface

interface exu_l1d_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic mmu_en;
  logic [XLEN-1:0] vaddr;
  logic [4:0] walu;
  logic valid;

  logic [XLEN-1:0] paddr;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] reservation;
  logic ready;

  modport master(output mmu_en, vaddr, walu, valid, input paddr, trap, cause, reservation, ready);
  modport slave(input mmu_en, vaddr, walu, valid, output paddr, trap, cause, reservation, ready);
endinterface

interface exu_ioq_bcast_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [XLEN-1:0] result;
  // ROB destination index (0-indexed, directly maps to rob_entry[]).
  logic [$clog2(`YSYX_ROB_SIZE)-1:0] dest;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  logic wen;
  logic [5:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic difftest_skip;

  logic valid;

  modport in(
      input pc, npc,
      input result, dest,
      input prd, rd,
      input wen, alu, sq_waddr, sq_wdata,
      input trap, tval, cause,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc,
      output result, dest,
      output prd, rd,
      output wen, alu, sq_waddr, sq_wdata,
      output trap, tval, cause,
      output difftest_skip,
      output valid
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // YSYX_EX_IF_SVH
