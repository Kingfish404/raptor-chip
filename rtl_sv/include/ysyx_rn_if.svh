`ifndef YSYX_RN_IF_SVH
`define YSYX_RN_IF_SVH
`include "ysyx.svh"


interface rnu_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  logic c;
  logic [4:0] alu;
  logic jen;
  logic ben;
  logic wen;
  logic ren;
  logic atom;

  logic system;
  logic ecall;
  logic ebreak;
  logic f_i;
  logic f_time;
  logic mret;
  logic [2:0] csr_csw;

  logic trap;
  logic [`YSYX_XLEN-1:0] tval;
  logic [`YSYX_XLEN-1:0] cause;

  logic [RLEN-1:0] rd;

  logic [PLEN-1:0] pr1;
  logic [PLEN-1:0] pr2;
  logic [PLEN-1:0] prd;
  logic [PLEN-1:0] prs;

  logic [XLEN-1:0] imm;
  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;

  logic [XLEN-1:0] pnpc;

  logic [31:0] inst;
  logic [XLEN-1:0] pc;

  logic valid;
  logic ready;

  modport master(
      output c,
      output alu, jen, ben, wen, ren, atom,
      output system, ecall, ebreak, mret, csr_csw,
      output trap, tval, cause,
      output f_i, f_time,
      output rd, imm, op1, op2,
      output pr1, pr2, prd, prs,
      output pnpc,
      output inst,
      output pc,
      output valid,
      input ready
  );
  modport slave(
      input c,
      input alu, jen, ben, wen, ren, atom,
      input system, ecall, ebreak, mret, csr_csw,
      input trap, tval, cause,
      input f_i, f_time,
      input rd, imm, op1, op2,
      input pr1, pr2, prd, prs,
      input pnpc,
      input inst,
      input pc,
      input valid,
      output ready
  );
endinterface

interface exu_prf_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  logic [PLEN-1:0] pr1;
  logic [PLEN-1:0] pr2;

  logic [XLEN-1:0] pv1;
  logic pv1_valid;
  logic [XLEN-1:0] pv2;
  logic pv2_valid;

  modport master(output pr1, pr2, input pv1, pv1_valid, pv2, pv2_valid);
  modport slave(input pr1, pr2, output pv1, pv1_valid, pv2, pv2_valid);
endinterface

interface rou_exu_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  logic c;
  logic [4:0] alu;
  logic jen;
  logic ben;
  logic wen;
  logic ren;
  logic atom;

  logic system;
  logic ecall;
  logic ebreak;
  logic fence_i;
  logic fence_time;
  logic mret;
  logic [2:0] csr_csw;

  logic trap;
  logic [`YSYX_XLEN-1:0] tval;
  logic [`YSYX_XLEN-1:0] cause;

  logic [RLEN-1:0] rd;

  logic [PLEN-1:0] pr1;
  logic [PLEN-1:0] pr2;
  logic [PLEN-1:0] prd;
  logic [PLEN-1:0] prs;

  logic [XLEN-1:0] imm;
  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;

  logic [$clog2(`YSYX_ROB_SIZE):0] qj;
  logic [$clog2(`YSYX_ROB_SIZE):0] qk;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [XLEN-1:0] pnpc;

  logic [31:0] inst;
  logic [XLEN-1:0] pc;

  logic valid;
  logic ready;

  modport master(
      output c,
      output alu, jen, ben, wen, ren, atom,
      output system, ecall, ebreak, mret, csr_csw,
      output trap, tval, cause,
      output fence_i, fence_time,
      output rd, imm, op1, op2,
      output pr1, pr2, prd, prs,
      output qj, qk, dest,
      output pnpc,
      output inst,
      output pc,
      output valid,
      input ready
  );
  modport slave(
      input c,
      input alu, jen, ben, wen, ren, atom,
      input system, ecall, ebreak, mret, csr_csw,
      input trap, tval, cause,
      input fence_i, fence_time,
      input rd, imm, op1, op2,
      input pr1, pr2, prd, prs,
      input qj, qk, dest,
      input pnpc,
      input inst,
      input pc,
      input valid,
      output ready
  );
endinterface

interface exu_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;
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

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic valid;

  modport in(
      input inst, pc, npc,
      input dest, result, ebreak,
      input prd, rd,
      input csr_wen, csr_wdata, csr_addr, ecall, mret,
      input trap, tval, cause,
      input valid
  );
  modport out(
      output inst, pc, npc,
      output dest, result, ebreak,
      output prd, rd,
      output csr_wen, csr_wdata, csr_addr, ecall, mret,
      output trap, tval, cause,
      output valid
  );
endinterface

interface exu_ioq_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [XLEN-1:0] result;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  logic wen;
  logic [4:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;

  logic valid;

  modport in(
      input inst, pc, npc,
      input result, dest,
      input prd, rd,
      input wen, alu, sq_waddr, sq_wdata,
      input valid
  );
  modport out(
      output inst, pc, npc,
      output result, dest,
      output prd, rd,
      output wen, alu, sq_waddr, sq_wdata,
      output valid
  );
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

  logic [XLEN-1:0] npc;
  logic jen;
  logic ben;

  logic ebreak;
  logic fence_time;
  logic fence_i;

  logic flush_pipe;

  logic valid;

  modport out(
      output rd, inst, pc,
      output npc, jen, ben,
      output prd, prs,
      output ebreak, fence_time, fence_i, flush_pipe,
      output valid
  );
  modport in(
      input rd, inst, pc,
      input npc, jen, ben,
      input prd, prs,
      input ebreak, fence_time, fence_i, flush_pipe,
      input valid
  );
endinterface

`endif
