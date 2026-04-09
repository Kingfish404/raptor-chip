`ifndef YSYX_IF_IF_SVH
`define YSYX_IF_IF_SVH
`include "ysyx.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface ifu_bpu_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int PHT_SIZE = `YSYX_PHT_SIZE,
    parameter int BTB_SIZE = `YSYX_BTB_SIZE,
    parameter int RSB_SIZE = `YSYX_RSB_SIZE
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] nextpc;
  logic             pc_update;

  logic [XLEN-1:0] npc;
  logic taken;

  modport out(output pc, nextpc, pc_update, input npc, taken);
  modport in(input pc, nextpc, pc_update, output npc, taken);
endinterface

interface ifu_l1i_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int L1I_LEN = `YSYX_L1I_LEN,
    parameter int L1I_LINE_LEN = `YSYX_L1I_LINE_LEN
);
  logic [XLEN-1:0] pc;
  logic invalid;

  logic [31:0] inst_n0;
`ifdef YSYX_DUAL_ISSUE
  logic [31:0] inst_n1;       // Next 4-byte-aligned word for dual-issue
  logic        inst_n1_valid; // inst_n1 is tag-matched and SRAM-ready
`endif
  logic trap;
  logic [XLEN-1:0] cause;
  logic valid;

  modport master(output pc, invalid, input inst_n0,
`ifdef YSYX_DUAL_ISSUE
    input inst_n1, inst_n1_valid,
`endif
    input trap, cause, valid);
  modport slave(input pc, invalid, output inst_n0,
`ifdef YSYX_DUAL_ISSUE
    output inst_n1, inst_n1_valid,
`endif
    output trap, cause, valid);
endinterface

interface ifu_idu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst_a;
  logic [XLEN-1:0] pc_a;
  logic valid_a;

`ifdef YSYX_DUAL_ISSUE
  // Slot B: second instruction from same fetch group
  logic [31:0] inst_b;
  logic [XLEN-1:0] pc_b;
  logic valid_b;  // IFU determined a second instruction is available
`endif

  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] pnpc;
  logic ready;

  // Early resteer: IDU detected BPU misprediction on non-branch instruction
  logic resteer;
  logic [XLEN-1:0] resteer_pc;

  modport master(
      output inst_a, pc_a, valid_a,
`ifdef YSYX_DUAL_ISSUE
      output inst_b, pc_b, valid_b,
`endif
      output pnpc, trap, cause,
      input ready, resteer, resteer_pc
  );
  modport slave(
      input inst_a, pc_a, valid_a,
`ifdef YSYX_DUAL_ISSUE
      input inst_b, pc_b, valid_b,
`endif
      input pnpc, trap, cause,
      output ready, resteer, resteer_pc
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // YSYX_IF_IF_SVH
