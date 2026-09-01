/* verilator lint_off DECLFILENAME */
`ifndef RAPT_EU_IF_SVH
`define RAPT_EU_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface exu_prf_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
);
  logic [PLEN-1:0] pr1_a;
  logic [PLEN-1:0] pr2_a;

  logic [XLEN-1:0] pv1_a;
  logic [XLEN-1:0] pv2_a;
  logic pv1_a_valid;
  logic pv2_a_valid;

`ifdef RAPT_DUAL_ISSUE
  // Slot B read ports (dual issue)
  logic [PLEN-1:0] pr1_b;
  logic [PLEN-1:0] pr2_b;

  logic [XLEN-1:0] pv1_b;
  logic [XLEN-1:0] pv2_b;
  logic pv1_b_valid;
  logic pv2_b_valid;
`endif

`ifdef RAPT_DUAL_ISSUE
  modport master(
      output pr1_a, pr2_a, pr1_b, pr2_b,
      input pv1_a, pv1_a_valid, pv2_a, pv2_a_valid,
      input pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
  );
  modport slave(
      input pr1_a, pr2_a, pr1_b, pr2_b,
      output pv1_a, pv1_a_valid, pv2_a, pv2_a_valid,
      output pv1_b, pv1_b_valid, pv2_b, pv2_b_valid
  );
`else
  modport master(output pr1_a, pr2_a, input pv1_a, pv1_a_valid, pv2_a, pv2_a_valid);
  modport slave(input pr1_a, pr2_a, output pv1_a, pv1_a_valid, pv2_a, pv2_a_valid);
`endif
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
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic [XLEN-1:0] sepc;

  modport master(output raddr, input rdata, mtvec, mepc, sepc);
  modport slave(input raddr, output rdata, mtvec, mepc, sepc);
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_EU_IF_SVH
