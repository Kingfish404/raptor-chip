/* verilator lint_off DECLFILENAME */
`ifndef RAPT_RECOVERY_IF_SVH
`define RAPT_RECOVERY_IF_SVH
`include "rapt.svh"

// One registered oldest-mispredict transaction.  `redirect_valid` pulses when a new
// owner is published or a later completion replaces it with an older owner;
// `pending` fences decode/rename until precise backend cleanup completes.
// `preserve_fetch` marks that owner's clean retirement: keep its fetched target.
// The owner identity is intentionally transported now so future ROB/IQ/LSQ
// selective-kill consumers do not need another ad-hoc recovery sideband.
interface rapt_recovery_if #(
    parameter int RobEntries = rapt_pkg::CoreConfig.rob_entries,
    parameter int RobBits = rapt_pkg::index_bits(RobEntries),
    parameter int GenerationBits = rapt_pkg::CoreConfig.rob_generation_bits,
    parameter int CheckpointBits = rapt_pkg::BranchCheckpointBits,
    parameter int XLEN = `RAPT_XLEN
);
  logic pending;
  logic redirect_valid;
  logic preserve_fetch;
  logic taken;
  logic [RobBits-1:0] owner;
  logic [RobBits-1:0] head; // age reference for the validated redirect event
  // Retain the owner-generation API for selective recovery consumers.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [GenerationBits-1:0] generation;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [XLEN-1:0] target;
  logic checkpoint_valid;
  logic [CheckpointBits-1:0] checkpoint;
  modport source(
      output pending, redirect_valid, preserve_fetch, taken,
      output owner, head, generation, target, checkpoint_valid, checkpoint
  );
  modport sink(
      input pending, redirect_valid, preserve_fetch, taken,
      input owner, head, generation, target, checkpoint_valid, checkpoint
  );
endinterface

// Correctly resolved control-flow uops can release several independent rename
// checkpoints in one cycle.  Keep this multi-producer lifetime channel
// separate from the single oldest recovery transaction above.
interface checkpoint_release_if #(
    parameter int Ports = rapt_pkg::CompletionPorts,
    parameter int CheckpointBits = rapt_pkg::BranchCheckpointBits
);
  logic valid[Ports];
  logic [CheckpointBits-1:0] checkpoint[Ports];
  modport source(output valid, checkpoint);
  modport sink(input valid, checkpoint);
endinterface

`endif
