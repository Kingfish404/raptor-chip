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
  logic [RLEN-1:0] rd;

  logic [31:0] inst;
  logic [XLEN-1:0] pc;

  logic [PLEN-1:0] prd;
  logic [PLEN-1:0] prs;

  logic btaken;
  logic [XLEN-1:0] npc;
  logic ben;
  logic jen;
  logic jren;
  logic atomic_sc;

  logic ebreak;
  logic fence_time;
  logic fence_i;

  logic flush_pipe;
  logic time_trap;

  logic valid;

  modport out(
      output rd, inst, pc,
      output btaken, npc, ben, jen, jren, atomic_sc,
      output prd, prs,
      output ebreak, fence_time, fence_i, flush_pipe, time_trap,
      output valid
  );
  modport in(
      input rd, inst, pc,
      input btaken, npc, ben, jen, jren, atomic_sc,
      input prd, prs,
      input ebreak, fence_time, fence_i, flush_pipe, time_trap,
      input valid
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // YSYX_RO_IF_SVH
