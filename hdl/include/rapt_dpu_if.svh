/* verilator lint_off DECLFILENAME */
`ifndef RAPT_DPU_IF_SVH
`define RAPT_DPU_IF_SVH
`include "rapt.svh"
interface dpu_iq_if #(
    parameter unsigned RS_SIZE = `RAPT_RS_SIZE,
    parameter int Width = rapt_pkg::DispatchWidth
);
  logic free_found[Width], accept[Width];
  logic [rapt_pkg::index_bits(RS_SIZE)-1:0] free_idx[Width], rs_idx[Width];
  modport top(input free_found, free_idx, output accept, rs_idx);
  modport rs(output free_found, free_idx, input accept, rs_idx);
endinterface
interface dpu_ioq_if #(
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE,
    parameter int Width = rapt_pkg::DispatchWidth
);
  logic ready[Width], accept[Width];
  modport top(input ready, output accept);
  modport ioq(output ready, input accept);
endinterface
`endif
