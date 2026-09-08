/* verilator lint_off DECLFILENAME */
`ifndef RAPT_RO_IF_SVH
`define RAPT_RO_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

// Read-only allocation-owner directory.  The ROB is the sole writer; core
// composition may attach any number of independent completion/early-wakeup
// guards without feeding producer signals back through the ROB module.
interface rob_completion_owner_if #(
    parameter int ENTRIES = `RAPT_ROB_SIZE,
    parameter int INDEX_BITS = ENTRIES > 1 ? $clog2(ENTRIES) : 1,
    parameter int GENERATION_BITS = `RAPT_ROB_GENERATION_BITS,
    parameter int PLEN = `RAPT_PHY_LEN,
    parameter int RLEN = `RAPT_REG_LEN
);
  logic [ENTRIES-1:0] live;
  logic [ENTRIES-1:0] executing;
  logic [GENERATION_BITS-1:0] generation[ENTRIES];
  logic [PLEN-1:0] prd[ENTRIES];
  logic [RLEN-1:0] rd[ENTRIES];
  modport owner(output live, executing, generation, prd, rd);
  modport guard(input live, executing, generation, prd, rd);
endinterface

interface rou_csr_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic [XLEN-1:0] pc;

  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;
  logic fp_flags_valid;
  logic [4:0] fp_flags;
  logic fp_dirty;

  logic ecall;
  logic ebreak;
  logic mret;
  logic sret;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic valid;

  logic [rapt_pkg::index_bits(rapt_pkg::CommitWidth+1)-1:0] retire_count;

  modport in(
      input pc,
      input csr_wen, csr_wdata, csr_addr, fp_flags_valid, fp_flags, fp_dirty,
      input ecall, ebreak, mret, sret,
      input trap, tval, cause,
      input valid,
      input retire_count
  );
  modport out(
      output pc,
      output csr_wen, csr_wdata, csr_addr, fp_flags_valid, fp_flags, fp_dirty,
      output ecall, ebreak, mret, sret,
      output trap, tval, cause,
      output valid,
      output retire_count
  );
endinterface

interface rou_lsu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic store;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest;
  // Retirement marks an existing SQ owner; it never transfers store payload.
  // The virtual address remains an independent ownership assertion witness.
  logic [XLEN-1:0] sq_vaddr;
  logic [XLEN-1:0] pc;
  logic valid;

  logic sq_ready;
  logic sq_empty;
  modport in(input store, dest, sq_vaddr, pc, valid, output sq_ready, sq_empty);
  modport out(output store, dest, sq_vaddr, pc, valid, input sq_ready, sq_empty);
endinterface

interface rou_cmu_if #(
    parameter int Width = rapt_pkg::CommitWidth,
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  typedef struct packed {
    logic [RLEN-1:0] rd;
    logic [31:0] inst;
    logic [XLEN-1:0] pc, npc;
    logic [PLEN-1:0] prd, prs;
    logic ebreak, difftest_skip, valid, c, trap, atomic;
    logic ben, jen, jren, branch_mispredict, btaken;
`ifdef RAPT_RVFI
    logic rvfi_trap;
    logic [XLEN-1:0] rvfi_npc, rvfi_sq_waddr, rvfi_sq_wdata;
    logic [31:0] rvfi_inst;
`endif
  } slot_t;
  slot_t slot[Width];
  logic [XLEN-1:0] next_pc, redirect_pc;
  logic btaken, ben, jen, jren, atomic_sc;
  logic fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] rob_head;
  modport out(
      output slot, next_pc, redirect_pc, btaken, ben, jen, jren, atomic_sc,
      fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap, rob_head
  );
  modport in(
      input slot, next_pc, redirect_pc, btaken, ben, jen, jren, atomic_sc,
      fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap, rob_head
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_RO_IF_SVH
