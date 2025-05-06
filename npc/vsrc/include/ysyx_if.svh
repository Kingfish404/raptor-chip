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
  logic ecall;
  logic ebreak;
  logic fence_i;
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
      input system, ecall, ebreak, fence_i, mret, csr_csw,
      input rd, imm, op1, op2, rs1, rs2,
      input qj, qk, dest,
      input pnpc,
      input inst,
      input pc
  );
  modport out(
      output alu_op, jen, ben, wen, ren,
      output system, ecall, ebreak, fence_i, mret, csr_csw,
      output rd, imm, op1, op2, rs1, rs2,
      output qj, qk, dest,
      output pnpc,
      output inst,
      output pc
  );
endinterface

interface exu_pipe_if;
  logic [$clog2(`YSYX_RS_SIZE)-1:0] rs_idx;

  logic [4:0] rd;
  logic [31:0] inst;
  logic [`YSYX_XLEN-1:0] pc;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;
  logic [`YSYX_XLEN-1:0] result;

  // wbu
  logic [`YSYX_XLEN-1:0] npc;
  logic pc_change;
  logic pc_retire;

  // csr
  logic csr_wen;
  logic [`YSYX_XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;

  logic ecall;
  logic ebreak;
  logic fence_i;
  logic mret;

  // store
  logic [$clog2(`YSYX_RS_SIZE)-1:0] sq_idx;
  logic store_commit;

  logic valid;

  modport in(
      input rs_idx,
      input rd, inst, pc,
      input dest, result, npc, pc_change, pc_retire, ebreak, fence_i,
      input csr_wen, csr_wdata, csr_addr, ecall, mret,
      input sq_idx, store_commit,
      input valid
  );
  modport out(
      output rs_idx,
      output rd, inst, pc,
      output dest, result, npc, pc_change, pc_retire, ebreak, fence_i,
      output csr_wen, csr_wdata, csr_addr, ecall, mret,
      output sq_idx, store_commit,
      output valid
  );
endinterface
// verilator lint_on DECLFILENAME

`endif
