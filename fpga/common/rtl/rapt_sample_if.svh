`ifndef RAPT_SAMPLE_IF_SVH
`define RAPT_SAMPLE_IF_SVH

// Optional FPGA architectural replay port. Only present in sampling builds.
// Retirement observation is registered at the backend boundary. The restore
// pulse is generated at the final trampoline mret, before guest execution.
interface rapt_sample_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int Width = rapt_pkg::CommitWidth
);
  logic halt_req, quiescent;
  // bit 0: ROB halted, 1: SQ empty, 2: data side idle, 3: writeback idle.
  logic [3:0] drain_ready;
  logic [$clog2(Width+1)-1:0] count;
  logic [XLEN-1:0] pc[Width];
  logic mret;
  logic [1:0] privilege;
  logic [XLEN-1:0] satp_root;
  logic [XLEN-1:0] thread_pointer;
  logic restore_armed, restore_fire;
  logic [XLEN-1:0] restore_pc, saved_mepc, saved_status;
  logic [63:0] saved_cycle, saved_instret, saved_time, saved_timecmp;
  logic saved_msip;
  logic [4:0] gpr_addr;
  logic [XLEN-1:0] gpr_data;
endinterface

`endif
