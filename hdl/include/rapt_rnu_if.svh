/* verilator lint_off DECLFILENAME */
`ifndef RAPT_RNU_IF_SVH
`define RAPT_RNU_IF_SVH
`include "rapt.svh"
interface rnu_rou_if #(
    parameter int Width = rapt_pkg::RenameWidth,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int XLEN = `RAPT_XLEN,
    parameter int RLEN = `RAPT_REG_LEN,
    parameter int PLEN = `RAPT_PHY_LEN,
    parameter int CheckpointBits = rapt_pkg::BranchCheckpointBits
);
  typedef struct packed {
    UopT uop;
    logic [XLEN-1:0] op1;
    logic [XLEN-1:0] op2;
    logic [PLEN-1:0] pr1;
    logic [PLEN-1:0] pr2;
    logic [PLEN-1:0] prd;
    logic [PLEN-1:0] prs;
  } slot_t;
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
