/* verilator lint_off DECLFILENAME */
`ifndef RAPT_EU_IF_SVH
`define RAPT_EU_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface exu_prf_if #(
    parameter int Width = rapt_pkg::RenameWidth,
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
);
  logic [PLEN-1:0] pr1[Width], pr2[Width];
  logic [XLEN-1:0] pv1[Width], pv2[Width];
  logic pv1_valid[Width], pv2_valid[Width];
  modport master(output pr1, pr2, input pv1, pv2, pv1_valid, pv2_valid);
  modport slave(input pr1, pr2, output pv1, pv2, pv1_valid, pv2_valid);
endinterface

// Architectural FPR bank interface. The serializing FP pipe needs three read
// channels for fused multiply-add and two independent write sources.
interface fpr_if;
  logic [4:0] alu_raddr_a, alu_raddr_b, alu_raddr_c;
  logic [63:0] alu_rdata_a, alu_rdata_b, alu_rdata_c;
  logic [4:0] ioq_raddr;
  logic [63:0] ioq_rdata;

  logic alu_wvalid;
  logic [4:0] alu_waddr;
  logic [63:0] alu_wdata;
  logic ioq_wvalid;
  logic [4:0] ioq_waddr;
  logic [63:0] ioq_wdata;

  modport storage(
      input alu_raddr_a, alu_raddr_b, alu_raddr_c, ioq_raddr,
      output alu_rdata_a, alu_rdata_b, alu_rdata_c, ioq_rdata,
      input alu_wvalid, alu_waddr, alu_wdata,
      input ioq_wvalid, ioq_waddr, ioq_wdata
  );
  modport alu(
      output alu_raddr_a, alu_raddr_b, alu_raddr_c,
      input alu_rdata_a, alu_rdata_b, alu_rdata_c,
      output alu_wvalid, alu_waddr, alu_wdata
  );
  modport ioq(output ioq_raddr, input ioq_rdata, output ioq_wvalid, ioq_waddr, ioq_wdata);
endinterface

interface exu_csr_if #(
    parameter bit [7:0] R_W  = 12,
    parameter int XLEN = `RAPT_XLEN
);
  logic [ R_W-1:0] raddr;

  logic [XLEN-1:0] rdata;
  // CSRRS/CSRRC update source. MIP.SEIP excludes the external interrupt
  // level here, while architectural rdata includes it for rd.
  logic [XLEN-1:0] rmw_data;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic [XLEN-1:0] sepc;

  modport master(output raddr, input rdata, rmw_data, mtvec, mepc, sepc);
  modport slave(input raddr, output rdata, rmw_data, mtvec, mepc, sepc);
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_EU_IF_SVH
