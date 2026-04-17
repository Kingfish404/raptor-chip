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
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;

  // ROB destination index (0-indexed, directly maps to rob_entry[]).
  logic [$clog2(`YSYX_ROB_SIZE)-1:0] dest;
  logic [XLEN-1:0] result;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  // csr
  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;

  logic ecall;
  logic ebreak;
  logic mret;
  logic sret;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic difftest_skip;

  logic valid;

  modport in(
      input inst, pc, npc, btaken,
      input dest, result, ebreak,
      input prd, rd,
      input csr_wen, csr_wdata, csr_addr, ecall, mret, sret,
      input trap, tval, cause,
      input difftest_skip,
      input valid
  );
  modport out(
      output inst, pc, npc, btaken,
      output dest, result, ebreak,
      output prd, rd,
      output csr_wen, csr_wdata, csr_addr, ecall, mret, sret,
      output trap, tval, cause,
      output difftest_skip,
      output valid
  );
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
  logic [31:0] inst;

  logic difftest_skip;

  logic valid;

  modport in(
      input pc, npc,
      input result, dest,
      input prd, rd,
      input wen, alu, sq_waddr, sq_wdata,
      input trap, tval, cause, inst,
      input difftest_skip,
      input valid
  );
  modport out(
      output pc, npc,
      output result, dest,
      output prd, rd,
      output wen, alu, sq_waddr, sq_wdata,
      output trap, tval, cause, inst,
      output difftest_skip,
      output valid
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // YSYX_EX_IF_SVH
