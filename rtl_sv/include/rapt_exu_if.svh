/* verilator lint_off DECLFILENAME */
`ifndef RAPT_EX_IF_SVH
`define RAPT_EX_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface exu_prf_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
);
  rapt_pkg::prd_t prd;
  logic [PLEN-1:0] pr1_a;
  logic [PLEN-1:0] pr2_a;

  logic [XLEN-1:0] pv1_a;
  logic [XLEN-1:0] pv2_a;
  logic pv1_a_valid;
  logic pv2_a_valid;

`ifdef RAPT_DUAL_ISSUE
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
`ifdef RAPT_DUAL_ISSUE
      , output pr1_b, pr2_b
      , input pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
`endif
  );
  modport slave(
      input pr1_a, pr2_a,
      output pv1_a, pv1_a_valid, pv2_a, pv2_a_valid
`ifdef RAPT_DUAL_ISSUE
      , input pr1_b, pr2_b
      , output pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
`endif
  );
endinterface

interface exu_lsu_if #(
    parameter int XLEN = `RAPT_XLEN
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
  logic stq_ready;

  // Hit-under-miss B channel (Phase A2, RAPT_LSU_HUM): best-effort second
  // load issued while the A channel waits on a miss.  Completes only on a
  // clean cacheable L1D hit or an SQ forward; no trap/skip side effects
  // (a load that cannot complete on B retries via A, which owns traps).
  logic rvalid_b;
  logic [XLEN-1:0] raddr_b;
  logic [4:0] ralu_b;
  logic [XLEN-1:0] rdata_b;
  logic rready_b;

  modport master(
    output rvalid, raddr, ralu, atomic_lock, pc,
    input rdata, trap, cause, difftest_skip, rready, stq_ready,
    output rvalid_b, raddr_b, ralu_b,
    input rdata_b, rready_b);
  modport slave(
    input rvalid, raddr, ralu, atomic_lock, pc,
    output rdata, trap, cause, difftest_skip, rready, stq_ready,
    input rvalid_b, raddr_b, ralu_b,
    output rdata_b, rready_b);
endinterface

interface exu_load_fast_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN
);
  logic valid;
  logic rebusy;
  logic [PLEN-1:0] prd;

  modport source(output valid, rebusy, prd);
  modport sink(input valid, rebusy, prd);
endinterface


interface exu_csr_if #(
    parameter bit [7:0] R_W  = 12,
    parameter int XLEN = `RAPT_XLEN
);
  logic [ R_W-1:0] raddr;

  logic [XLEN-1:0] rdata;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic [XLEN-1:0] sepc;

  modport master(output raddr, input rdata, mtvec, mepc, sepc);
  modport slave(input raddr, output rdata, mtvec, mepc, sepc);
endinterface

// ---------------------------------------------------------------------------
// Unified writeback / CDB port (Phase 0 of the execution-engine decoupling).
//
// One instance per execution pipeline; rapt_core instantiates one per
// writeback port with the following fixed assignment:
//   [0] ALU-A : full path (ALU + CSR + system + trap + MUL writeback)
//   [1] ALU-B : simple ALU + JAL/JALR link write (never CSR/system/trap/MUL)
//   [2] BRU   : conditional branches only (no result/prd/rd -> tied 0;
//               no PRF write port, no bypass network entry)
//   [3] MEM   : IOQ broadcast (loads / stores / atomics / MMIO)
//
// Fields a pipeline does not produce are tied to '0 by the driver and are
// constant-folded away downstream, so the superset costs no hardware.
// Adding a pipeline = adding one more `exu_wb_if` port, not a new type.
// ---------------------------------------------------------------------------
interface exu_wb_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  // Not every consumer samples every field (e.g. PRF ignores pc/npc); the
  // file-wide UNUSEDSIGNAL pragma does not reach interface-bundle instance
  // scope, so re-disable here.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;
  // BPU mispredict flag (1 = computed npc differs from predicted pnpc).
  // Replaces the previous XLEN-wide `pnpc` field stored in rob_entry_t.
  logic mispredict;

  // ROB destination index (0-indexed, directly maps to rob_entry[]).
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest;
  logic [XLEN-1:0] result;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  // csr (ALU-A only; csr_addr lives in uop_pl, not here)
  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;

  // Memory sideband (MEM only). `alu` bit[5] selects mul/div family and is
  // unused by non-EXU consumers.
  logic wen;
  logic [5:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic difftest_skip;

  logic valid;
  /* verilator lint_on UNUSEDSIGNAL */

  modport in(
      input pc, npc, btaken, mispredict,
      input dest, result,
      input prd, rd,
      input csr_wen, csr_wdata,
      input wen, alu, sq_waddr, sq_wdata,
      input trap, tval, cause,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc, btaken, mispredict,
      output dest, result,
      output prd, rd,
      output csr_wen, csr_wdata,
      output wen, alu, sq_waddr, sq_wdata,
      output trap, tval, cause,
      output difftest_skip,
      output valid
  );
endinterface

// EXU internal: top-level dispatch arbiter <-> Reservation Station.
// Top reads RS free-vector status, drives accept signals back to RS.
interface exu_disp_rs_if #(
    parameter unsigned RS_SIZE = `RAPT_RS_SIZE
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
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE
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

  // Tie unused signal to silence lint when RAPT_DUAL_ISSUE is off.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(IOQ_SIZE)-1:0] _ioq_size_pad;
  /* verilator lint_on UNUSEDSIGNAL */
endinterface

interface exu_l1d_if #(
    parameter int XLEN = `RAPT_XLEN
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

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_EX_IF_SVH
