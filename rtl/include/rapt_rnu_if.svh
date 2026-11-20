/* verilator lint_off DECLFILENAME */
`ifndef RAPT_RNU_IF_SVH
`define RAPT_RNU_IF_SVH
`include "rapt.svh"
`include "rapt_types.svh"
interface rnu_rou_if #(
    parameter int Width = rapt_pkg::RenameWidth,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int XLEN = `RAPT_XLEN,
    parameter int RLEN = `RAPT_REG_LEN,
    parameter int PLEN = `RAPT_PHY_LEN,
    parameter int CheckpointBits = rapt_pkg::BranchCheckpointBits
);
  typedef logic [`RAPT_PC_BITS_OF(XLEN)-1:0] slot_pc_t;
  typedef logic [XLEN-1:0] slot_word_t;
  typedef logic [PLEN-1:0] slot_phys_t;
  `RAPT_RENAME_SLOT_TYPE(slot_t, UopT, slot_pc_t, slot_word_t, slot_phys_t)
  slot_t slot[Width];
  logic valid[Width];
  logic empty; // Both decoded input and renamed output queues are empty.
  logic ready[Width];
  logic checkpoint_valid[Width];
  logic [CheckpointBits-1:0] checkpoint[Width];
  modport master(output slot, valid, empty, checkpoint_valid, checkpoint, input ready);
  modport slave(input slot, valid, empty, checkpoint_valid, checkpoint, output ready);
endinterface
`endif
