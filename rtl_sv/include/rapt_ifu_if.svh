/* verilator lint_off DECLFILENAME */
`ifndef RAPT_IF_IF_SVH
`define RAPT_IF_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface ifu_bpu_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int PHT_SIZE = `RAPT_PHT_SIZE,
    parameter int BTB_SIZE = `RAPT_BTB_SIZE,
    parameter int RSB_SIZE = `RAPT_RSB_SIZE
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] nextpc;
  logic             pc_update;

  logic [XLEN-1:0] npc;
  logic taken;

  modport out(output pc, nextpc, pc_update, input npc, taken);
  modport in(input pc, nextpc, pc_update, output npc, taken);
endinterface

// IDU -> BPU BTB training side-channel.
//
// Fires alongside `ifu_idu.resteer` when the IDU detects a BPU prediction
// failure that can be resolved with the *static* portion of the instruction:
//   - JAL with wrong / missing BTB target (BPU not-taken, or wrong target)
//   - B-type with BPU-taken but wrong BTB target (stale entry)
//
// Without this channel an IDU early-resteer would starve the BTB of the
// flush-time training that normally fires on commit-flush, causing the same
// resteer to repeat indefinitely on every recurrence of the offender.
//
// The non-control-alias case (BPU-taken on a regular ALU/LD/ST instruction)
// is intentionally NOT trained here: the BTB has no invalidate port today,
// so we let the alias persist and pay the IDU resteer cost on each hit
// (rare in practice — empirically ~1 event over a CoreMark run).
interface idu_bpu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic            train_en;     // 1-cycle pulse aligned with ifu_idu.resteer
  logic [XLEN-1:0] train_pc;     // PC of the offending instruction
  logic [XLEN-1:0] train_target; // Correct target PC
  logic [1:0]      train_type;   // 00=COND, 01=DIRE (matches BPU enum)

  modport out(output train_en, train_pc, train_target, train_type);
  modport in (input  train_en, train_pc, train_target, train_type);
endinterface

interface ifu_l1i_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int L1I_LEN = `RAPT_L1I_LEN,
    parameter int L1I_LINE_LEN = `RAPT_L1I_LINE_LEN
);
  logic [XLEN-1:0] pc;
  logic invalid;

  logic [31:0] inst_n0;
`ifdef RAPT_DUAL_ISSUE
  logic [31:0] inst_n1;       // Next 4-byte-aligned word for dual-issue
  logic        inst_n1_valid; // inst_n1 is tag-matched and SRAM-ready
`endif
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] tval;
  logic valid;

  modport master(output pc, invalid, input inst_n0,
`ifdef RAPT_DUAL_ISSUE
    input inst_n1, inst_n1_valid,
`endif
    input trap, cause, tval, valid);
  modport slave(input pc, invalid, output inst_n0,
`ifdef RAPT_DUAL_ISSUE
    output inst_n1, inst_n1_valid,
`endif
    output trap, cause, tval, valid);
endinterface

interface ifu_idu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic [31:0] inst_a;
  logic [XLEN-1:0] pc_a;
  logic valid_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot B: second instruction from same fetch group
  logic [31:0] inst_b;
  logic [XLEN-1:0] pc_b;
  logic valid_b;  // IFU determined a second instruction is available
`endif

  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] pnpc;
  logic ready;

  // Early resteer: IDU detected BPU misprediction on non-branch instruction
  logic resteer;
  logic [XLEN-1:0] resteer_pc;

  modport master(
      output inst_a, pc_a, valid_a,
`ifdef RAPT_DUAL_ISSUE
      output inst_b, pc_b, valid_b,
`endif
      output pnpc, trap, cause, tval,
      input ready, resteer, resteer_pc
  );
  modport slave(
      input inst_a, pc_a, valid_a,
`ifdef RAPT_DUAL_ISSUE
      input inst_b, pc_b, valid_b,
`endif
      input pnpc, trap, cause, tval,
      output ready, resteer, resteer_pc
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_IF_IF_SVH
