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
  localparam int PcBits = `RAPT_PC_BITS_OF(XLEN);
  logic [PcBits-1:0] nextpc;
  logic             pc_update;

  logic [PcBits-1:0] npc;
  logic taken;
  // Accepted conditional (primary or auxiliary), never a raw predictor query.
  logic history_valid, history_taken, history_pc_bit;
`ifdef RAPT_FETCH_LOOKAHEAD
  // Auxiliary conditional prediction uses a small independent combinational
  // direction table. Its target is derived statically by IFU.
  logic            aux_query;
  logic [PcBits-1:0] aux_pc;
  // With positional lookup, aux_pc is the fetch-block PC and the branch sits
  // at aux_pc + 2 * (aux_position + 1); otherwise aux_pc is the branch PC.
  logic [3:0]      aux_position;
  logic            aux_taken;
  // Registered packet metadata selects an existing positional direction read.
  logic [3:0]      request_aux_position;
  logic            request_aux_taken;
  logic [$clog2(PHT_SIZE)-1:0] aux_index;
`endif

`ifdef RAPT_FETCH_LOOKAHEAD
  modport out(
      output nextpc, pc_update,
      output history_valid, history_taken, history_pc_bit,
      output aux_query, aux_pc, aux_position, request_aux_position,
      input aux_taken, aux_index, request_aux_taken,
      input npc, taken
  );
  modport in(
      input nextpc, pc_update,
      input history_valid, history_taken, history_pc_bit,
      input aux_query, aux_pc, aux_position, request_aux_position,
      output aux_taken, aux_index, request_aux_taken,
      output npc, taken
  );
`else
  modport out(
      output nextpc, pc_update, history_valid, history_taken, history_pc_bit,
      input npc, taken
  );
  modport in(
      input nextpc, pc_update, history_valid, history_taken, history_pc_bit,
      output npc, taken
  );
`endif
endinterface

// IDU -> BPU BTB training side-channel.
//
// Captures training on decode acceptance, one cycle before the registered
// `ifu_idu.resteer`. BPU applies the captured write with that redirect. This
// repairs prediction failures resolved by the static portion of the instruction:
//   - JAL with wrong / missing BTB target (BPU not-taken, or wrong target)
//   - B-type with BPU-taken but wrong BTB target (stale entry)
//   - Return with a decode-ordered RAS target (speculative; execution validates)
//
// Without this channel an IDU early-resteer would starve the BTB of the
// flush-time training that normally fires on commit-flush, causing the same
// resteer to repeat indefinitely on every recurrence of the offender.
//
// The non-control-alias case (BPU-taken on a regular ALU/LD/ST instruction)
// is intentionally NOT trained here: the BTB has no invalidate port today,
// so we let the alias persist and pay the IDU resteer cost on each hit
// (rare in practice -- empirically ~1 event over a CoreMark run).
interface idu_bpu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  localparam int PcBits = `RAPT_PC_BITS_OF(XLEN);
  logic            train_en;     // Accepted decode correction; registered inside BPU
  logic [PcBits-1:0] train_pc;     // PC of the offending instruction
  logic [PcBits-1:0] train_target; // Correct target PC
  logic [1:0]      train_type;   // 00=COND, 01=DIRE, 11=RETU (matches BPU enum)

  // One accepted decode-order RAS action; both enables mean pop then push.
  // Queries have no side effects. IDU uses the pre-action top for return repair.
  logic push_en, pop_en, ras_valid;
  logic [PcBits-1:0] push_addr;
  logic [PcBits-1:0] ras_addr;
  logic history_valid, history_taken, history_pc_bit, history_recover;

  modport out(
      output train_en, train_pc, train_target, train_type, push_en, pop_en, push_addr,
      output history_valid, history_taken, history_pc_bit, history_recover,
      input ras_valid, ras_addr
  );
  modport in(
      input train_en, train_pc, train_target, train_type, push_en, pop_en, push_addr,
      input history_valid, history_taken, history_pc_bit, history_recover,
      output ras_valid, ras_addr
  );
endinterface

interface ifu_l1i_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int L1I_LEN = `RAPT_L1I_LEN,
    parameter int L1I_LINE_LEN = `RAPT_L1I_LINE_LEN
);
  localparam int PcBits = `RAPT_PC_BITS_OF(XLEN);
  logic [PcBits-1:0] pc;
  logic invalid;
  // Response acceptance and frontend cancellation, including same-PC redirects.
  logic consumed, cancel;
  // An accepted predicted non-sequential next PC. L1I uses this only as a
  // data-SRAM read-ahead hint; it neither changes cache state nor issues a
  // request, so incorrect predictions remain architecturally harmless.
  logic [PcBits-1:0] prefetch_pc;
  logic            prefetch_valid;

  logic [31:0] inst_n0;
`ifdef RAPT_FETCH_LOOKAHEAD
  logic [31:0] inst_n1;       // Next 4-byte-aligned word of the fetch window
  logic        inst_n1_valid; // inst_n1 is tag-matched and SRAM-ready
  // Third word needed only for an unaligned R32+R32 pair. It contains the
  // upper halfword at pc+6.
  logic [31:0] inst_n2;
  logic        inst_n2_valid;
`ifdef RAPT_FETCH_WIDE
  logic [31:0] inst_n3, inst_n4;
  logic inst_n3_valid, inst_n4_valid;
`endif
`endif
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] tval;
  logic valid;

`ifdef RAPT_FETCH_LOOKAHEAD
`ifdef RAPT_FETCH_WIDE
  modport master(
      output pc, invalid, consumed, cancel, prefetch_pc, prefetch_valid,
      input inst_n0, inst_n1, inst_n1_valid, inst_n2, inst_n2_valid,
      input inst_n3, inst_n3_valid, inst_n4, inst_n4_valid,
      input trap, cause, tval, valid
  );
  modport slave(
      input pc, invalid, consumed, cancel, prefetch_pc, prefetch_valid,
      output inst_n0, inst_n1, inst_n1_valid, inst_n2, inst_n2_valid,
      output inst_n3, inst_n3_valid, inst_n4, inst_n4_valid,
      output trap, cause, tval, valid
  );
`else
  modport master(
      output pc, invalid, consumed, cancel, prefetch_pc, prefetch_valid,
      input inst_n0, inst_n1, inst_n1_valid, inst_n2, inst_n2_valid,
      input trap, cause, tval, valid
  );
  modport slave(
      input pc, invalid, consumed, cancel, prefetch_pc, prefetch_valid,
      output inst_n0, inst_n1, inst_n1_valid, inst_n2, inst_n2_valid,
      output trap, cause, tval, valid
  );
`endif
`else
  modport master(
      output pc, invalid, consumed, cancel, prefetch_pc, prefetch_valid,
      input inst_n0, trap, cause, tval, valid
  );
  modport slave(
      input pc, invalid, consumed, cancel, prefetch_pc, prefetch_valid,
      output inst_n0, trap, cause, tval, valid
  );
`endif
endinterface

interface ifu_idu_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int Width = rapt_pkg::DecodeWidth
);
  localparam int PcBits = `RAPT_PC_BITS_OF(XLEN);
  rapt_pkg::fetch_slot_t slot[Width];
  logic valid[Width], ready[Width];
  logic resteer;
  logic [PcBits-1:0] resteer_pc;
  modport master(output slot, valid, input ready, resteer, resteer_pc);
  modport slave(input slot, valid, output ready, resteer, resteer_pc);
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_IF_IF_SVH
