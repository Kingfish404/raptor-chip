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

`ifdef RAPT_DUAL_ISSUE
  modport master(
      output pr1_a, pr2_a, pr1_b, pr2_b,
      input pv1_a, pv1_a_valid, pv2_a, pv2_a_valid,
      input pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
  );
  modport slave(
      input pr1_a, pr2_a, pr1_b, pr2_b,
      output pv1_a, pv1_a_valid, pv2_a, pv2_a_valid,
      output pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
  );
`else
  modport master(output pr1_a, pr2_a, input pv1_a, pv1_a_valid, pv2_a, pv2_a_valid);
  modport slave(input pr1_a, pr2_a, output pv1_a, pv1_a_valid, pv2_a, pv2_a_valid);
`endif
endinterface

// Architectural FPR bank interface. The serializing FP pipe needs three read
// channels for fused multiply-add and two independent write sources.
interface fpr_if;
  logic [4:0] alu_raddr_a, alu_raddr_b, alu_raddr_c;
  logic [63:0] alu_rdata_a, alu_rdata_b, alu_rdata_c;
  logic [4:0] ioq_raddr;
  logic [63:0] ioq_rdata;

  logic alu_wvalid;
  logic [4:0] alu_waddr;
  logic [63:0] alu_wdata;
  logic ioq_wvalid;
  logic [4:0] ioq_waddr;
  logic [63:0] ioq_wdata;

  modport storage(
      input alu_raddr_a, alu_raddr_b, alu_raddr_c, ioq_raddr,
      output alu_rdata_a, alu_rdata_b, alu_rdata_c, ioq_rdata,
      input alu_wvalid, alu_waddr, alu_wdata,
      input ioq_wvalid, ioq_waddr, ioq_wdata
  );
  modport alu(
      output alu_raddr_a, alu_raddr_b, alu_raddr_c,
      input alu_rdata_a, alu_rdata_b, alu_rdata_c,
      output alu_wvalid, alu_waddr, alu_wdata
  );
  modport ioq(output ioq_raddr, input ioq_rdata, output ioq_wvalid, ioq_waddr, ioq_wdata);
endinterface

interface exu_lsu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic rvalid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic atomic_lock;
  logic ordered;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] rdata;
  logic [63:0] fp_rdata64;
  logic fp_rdata64_req;
  logic fp_rdata64_valid;
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
      output rvalid, raddr, ralu, atomic_lock, ordered, pc,
      output fp_rdata64_req,
      input rdata, fp_rdata64, fp_rdata64_valid, trap, cause, difftest_skip, rready, stq_ready,
      output rvalid_b, raddr_b, ralu_b,
      input rdata_b, rready_b
  );
  modport slave(
      input rvalid, raddr, ralu, atomic_lock, ordered, pc,
      output rdata, fp_rdata64, fp_rdata64_valid, trap, cause, difftest_skip, rready, stq_ready,
      input fp_rdata64_req,
      input rvalid_b, raddr_b, ralu_b,
      output rdata_b, rready_b
  );
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
// Unified writeback / CDB port (execution-engine decoupling).
//
// One instance per execution pipeline; rapt_core instantiates one per
// writeback port with the following fixed assignment:
//   [0] ALU-CSR : full path (ALU + CSR + system + trap)
//   [1] ALU     : simple ALU + JAL/JALR link write (never CSR/system/trap)
//   [2] BRANCH  : conditional branches only (no result/prd/rd -> tied 0;
//                no PRF write port, no bypass network entry)
//   [3] MEM    : IOQ broadcast (loads / stores / atomics / MMIO)
//   [4] MULDIV : MUL/DIV pipe (pure arithmetic, no CSR/trap/MEM sideband)
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

  // csr (ALU-CSR pipe only; csr_addr lives in uop_pl, not here)
  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;
  logic fp_flags_valid;
  logic [4:0] fp_flags;

  // Memory sideband (MEM only). `alu` bit[5] selects mul/div family and is
  // unused by non-EXU consumers.
  logic wen;
  logic [5:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;
  logic [63:0] sq_wdata64;
  logic sq_fp64;

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
      input csr_wen, csr_wdata, fp_flags_valid, fp_flags,
      input wen, alu, sq_waddr, sq_wdata, sq_wdata64, sq_fp64,
      input trap, tval, cause,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc, btaken, mispredict,
      output dest, result,
      output prd, rd,
      output csr_wen, csr_wdata, fp_flags_valid, fp_flags,
      output wen, alu, sq_waddr, sq_wdata, sq_wdata64, sq_fp64,
      output trap, tval, cause,
      output difftest_skip,
      output valid
  );
endinterface

// EXU internal: generic issue queue -> execution pipe (FU + writeback).
// Combinational view of the oldest ready IQ entry; `op1`/`op2` carry the
// fast-confirm MEM-result bypass already applied. One instance per pipe.
interface exu_iq_iss_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  // Not every pipe samples every field (e.g. Branch ignores rd/trap);
  // re-disable UNUSEDSIGNAL inside the bundle scope.
  /* verilator lint_off UNUSEDSIGNAL */
  logic valid;
  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;
  logic [5:0] alu;
  logic [XLEN-1:0] pc;
  logic c;
  logic word;
  logic [XLEN-1:0] imm;
  logic [XLEN-1:0] pnpc;
  logic jen;
  logic jren;
  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest;
  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;
  logic fp_valid;
  logic [5:0] fp_op;
  logic [2:0] fp_rm;
  logic [4:0] fp_rs1;
  logic [4:0] fp_rs2;
  logic [4:0] fp_rs3;
  logic [4:0] fp_rd;
  logic fp_dep1_valid;
  logic fp_dep2_valid;
  logic fp_dep3_valid;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] fp_dep1;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] fp_dep2;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] fp_dep3;
  /* verilator lint_on UNUSEDSIGNAL */

  modport iq(
      output valid, op1, op2, alu, pc, c, word, imm, pnpc, jen, jren,
      output trap, tval, cause, dest, prd, rd,
      output fp_valid, fp_op, fp_rm, fp_rs1, fp_rs2, fp_rs3, fp_rd,
      output fp_dep1_valid, fp_dep2_valid, fp_dep3_valid, fp_dep1, fp_dep2, fp_dep3
  );
  modport fu(
      input valid, op1, op2, alu, pc, c, word, imm, pnpc, jen, jren,
      input trap, tval, cause, dest, prd, rd,
      input fp_valid, fp_op, fp_rm, fp_rs1, fp_rs2, fp_rs3, fp_rd,
      input fp_dep1_valid, fp_dep2_valid, fp_dep3_valid, fp_dep1, fp_dep2, fp_dep3
  );
endinterface

// EXU internal: top-level dispatch arbiter <-> issue queue (IQ/MDQ).
// Top reads the queue's free-vector status, drives accept signals back.
interface exu_disp_rs_if #(
    parameter unsigned RS_SIZE = `RAPT_RS_SIZE
);
  // IQ -> top status
  logic free_found_a;
  logic free_found_b;
  logic [$clog2(RS_SIZE)-1:0] free_idx_a;
  logic [$clog2(RS_SIZE)-1:0] free_idx_b;
  // top -> IQ dispatch decisions (gated by rou_exu.valid / valid_b)
  logic accept_a;         // slot A is allocated this cycle (uses free_idx_a)
  logic accept_b;         // slot B is allocated this cycle (uses b_rs_idx)
  logic [$clog2(RS_SIZE)-1:0] b_rs_idx;
  // Per-slot dispatch sideband, captured into the entry: ineligible for
  // issue port B (CSR / system / trap class -- only the ALU-CSR pipe handles those
  // semantics). Constant 0 for single-issue-port queues.
  logic iss_b_block_a;
  logic iss_b_block_b;

  modport top(
      input free_found_a, free_found_b, free_idx_a, free_idx_b,
      output accept_a, accept_b, b_rs_idx, iss_b_block_a, iss_b_block_b
  );
  modport rs(
      output free_found_a, free_found_b, free_idx_a, free_idx_b,
      input accept_a, accept_b, b_rs_idx, iss_b_block_a, iss_b_block_b
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

  modport top(input ready, ready_b, output accept_a, accept_b_paired, accept_b_alone);
  modport ioq(output ready, ready_b, input accept_a, accept_b_paired, accept_b_alone);

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
  logic reservation_valid;
  logic reservation_clear;
  logic ready;

  modport master(
      output mmu_en, vaddr, walu, valid, reservation_clear,
      input paddr, trap, cause, reservation, reservation_valid, ready
  );
  modport slave(
      input mmu_en, vaddr, walu, valid, reservation_clear,
      output paddr, trap, cause, reservation, reservation_valid, ready
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_EX_IF_SVH
