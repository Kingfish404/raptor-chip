`ifndef YSYX_IF
`define YSYX_IF
`include "ysyx.svh"

// verilator lint_off DECLFILENAME
interface idu_pipe_if;
  logic [4:0] alu_op;
  logic jen;
  logic ben;
  logic wen;
  logic ren;

  logic system;
  logic ebreak;
  logic fence_i;
  logic ecall;
  logic mret;
  logic [2:0] csr_csw;

  logic [4:0] rd;
  logic [31:0] imm;
  logic [31:0] op1;
  logic [31:0] op2;
  logic [4:0] rs1;
  logic [4:0] rs2;

  logic [$clog2(`YSYX_ROB_SIZE):0] qj;
  logic [$clog2(`YSYX_ROB_SIZE):0] qk;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [`YSYX_XLEN-1:0] pnpc;

  logic [31:0] inst;
  logic [`YSYX_XLEN-1:0] pc;
  modport in(
      input alu_op, jen, ben, wen, ren,
      input system, ebreak, fence_i, ecall, mret, csr_csw,
      input rd, imm, op1, op2, rs1, rs2,
      input qj, qk, dest,
      input pnpc,
      input inst,
      input pc
  );

  modport out(
      output alu_op, jen, ben, wen, ren,
      output system, ebreak, fence_i, ecall, mret, csr_csw,
      output rd, imm, op1, op2, rs1, rs2,
      output qj, qk, dest,
      output pnpc,
      output inst,
      output pc
  );
endinterface

interface exu_pipe_if;
  logic [4:0] rd;
  logic [31:0] inst;
  logic [`YSYX_XLEN-1:0] pc;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;
  logic [`YSYX_XLEN-1:0] result;

  logic [`YSYX_XLEN-1:0] npc;
  logic [`YSYX_XLEN-1:0] pnpc;
  logic pc_change;
  logic pc_retire;
  logic ebreak;

  logic csr_wen;
  logic [`YSYX_XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;
  logic ecall;
  logic mret;

  logic valid;

  modport in(
      input rd, inst, pc,
      input dest, result, npc, pnpc, pc_change, pc_retire, ebreak,
      input csr_wen, csr_wdata, csr_addr, ecall, mret,
      input valid
  );
  modport out(
      output rd, inst, pc,
      output dest, result, npc, pnpc, pc_change, pc_retire, ebreak,
      output csr_wen, csr_wdata, csr_addr, ecall, mret,
      output valid
  );
endinterface
// verilator lint_on DECLFILENAME

`endif
