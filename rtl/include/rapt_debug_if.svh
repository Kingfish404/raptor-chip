/* verilator lint_off DECLFILENAME */
`ifndef RAPT_DEBUG_IF_SVH
`define RAPT_DEBUG_IF_SVH
`include "rapt.svh"

// Hart control separate from DMI/SBA. A resume is held until the hart has
// flushed speculative state and applied its redirect. All controls are inert
// when enable is clear. prv is observation only: debug does not change privilege.
interface rapt_debug_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic enable, step, stepie;
  logic [2:0] ebreak;  // {M, S, U}
  logic resume_valid, resume_ack;
  logic [`RAPT_PC_BITS_OF(XLEN)-1:0] resume_pc;
  logic [2:0] cause;
  logic [1:0] prv;
  logic fetch_block;
  modport dm(
      output enable, step, stepie, ebreak, resume_valid, resume_pc,
      input resume_ack, cause, prv
  );
  modport hart(
      input enable, step, stepie, ebreak, resume_valid, resume_pc,
      output resume_ack, cause, prv, fetch_block
  );
endinterface
`endif
