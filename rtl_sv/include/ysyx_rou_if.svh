`ifndef YSYX_RO_IF_SVH
`define YSYX_RO_IF_SVH
`include "ysyx.svh"
import ysyx_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface rou_csr_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;

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

  logic valid;

  modport in(
      input pc,
      input csr_wen, csr_wdata, csr_addr, ecall, ebreak, mret, sret,
      input trap, tval, cause,
      input valid
  );
  modport out(
      output pc,
      output csr_wen, csr_wdata, csr_addr, ecall, ebreak, mret, sret,
      output trap, tval, cause,
      output valid
  );
endinterface


interface rou_exu_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  ysyx_pkg::uop_t uop;

  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;

  logic [PLEN-1:0] pr1;
  logic [PLEN-1:0] pr2;
  logic [PLEN-1:0] prd;
  logic [PLEN-1:0] prs;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic valid;
  logic ready;

  modport master(
      output uop,
      output op1, op2,
      output pr1, pr2, prd, prs,
      output dest,
      output valid,
      input ready
  );
  modport slave(
      input uop,
      input op1, op2,
      input pr1, pr2, prd, prs,
      input dest,
      input valid,
      output ready
  );
endinterface

interface rou_lsu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic store;
  logic [4:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;
  logic [XLEN-1:0] pc;
  logic valid;

  logic sq_ready;
  modport in(input store, alu, sq_waddr, sq_wdata, pc, valid, output sq_ready);
  modport out(output store, alu, sq_waddr, sq_wdata, pc, valid, input sq_ready);
endinterface


interface rou_cmu_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  // Commit slot A (ROB head)
  logic [RLEN-1:0] rd_a;
  logic [31:0] inst_a;
  logic [XLEN-1:0] pc_a;
  logic [PLEN-1:0] prd_a;
  logic [PLEN-1:0] prs_a;
  logic [XLEN-1:0] npc_a;
  logic ebreak_a;
  logic difftest_skip_a;
  logic valid_a;

  // Commit slot B (ROB head+1, dual commit)
  logic [RLEN-1:0] rd_b;
  logic [31:0] inst_b;
  logic [XLEN-1:0] pc_b;
  logic [PLEN-1:0] prd_b;
  logic [PLEN-1:0] prs_b;
  logic [XLEN-1:0] npc_b;
  logic ebreak_b;
  logic difftest_skip_b;
  logic valid_b;

  // Shared commit signals (merged from active slot)
  logic btaken;
  logic ben;
  logic jen;
  logic jren;
  logic atomic_sc;

  logic fence_time;
  logic fence_i;
  logic flush_pipe;
  logic time_trap;

  modport out(
      output rd_a, inst_a, pc_a, prd_a, prs_a, npc_a,
      output ebreak_a, difftest_skip_a, valid_a,
      output rd_b, inst_b, pc_b, prd_b, prs_b, npc_b,
      output ebreak_b, difftest_skip_b, valid_b,
      output btaken, ben, jen, jren, atomic_sc,
      output fence_time, fence_i, flush_pipe, time_trap
  );
  modport in(
      input rd_a, inst_a, pc_a, prd_a, prs_a, npc_a,
      input ebreak_a, difftest_skip_a, valid_a,
      input rd_b, inst_b, pc_b, prd_b, prs_b, npc_b,
      input ebreak_b, difftest_skip_b, valid_b,
      input btaken, ben, jen, jren, atomic_sc,
      input fence_time, fence_i, flush_pipe, time_trap
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // YSYX_RO_IF_SVH
