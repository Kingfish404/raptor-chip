`ifndef YSYX_EX_IF_SVH
`define YSYX_EX_IF_SVH
`include "ysyx.svh"
import ysyx_pkg::*;

interface exu_prf_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  ysyx_pkg::prd_t prd;
  logic [PLEN-1:0] pr1;
  logic [PLEN-1:0] pr2;

  logic [XLEN-1:0] pv1;
  logic [XLEN-1:0] pv2;
  logic pv1_valid;
  logic pv2_valid;

  modport master(output pr1, pr2, input pv1, pv1_valid, pv2, pv2_valid);
  modport slave(input pr1, pr2, output pv1, pv1_valid, pv2, pv2_valid);
endinterface

interface exu_lsu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic rvalid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] rdata;
  logic rready;

  modport master(output rvalid, raddr, ralu, pc, input rdata, rready);
  modport slave(input rvalid, raddr, ralu, pc, output rdata, rready);
endinterface


interface exu_csr_if #(
    parameter bit [7:0] R_W  = 12,
    parameter bit [7:0] XLEN = `YSYX_XLEN
);
  logic [ R_W-1:0] raddr;

  logic [XLEN-1:0] rdata;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;

  modport master(output raddr, input rdata, mtvec, mepc);
  modport slave(input raddr, output rdata, mtvec, mepc);
endinterface

interface exu_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;
  logic btaken;

  logic [$clog2(`YSYX_ROB_SIZE):0] dest;
  logic [XLEN-1:0] result;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  // csr
  logic csr_wen;
  logic [XLEN-1:0] csr_wdata;
  logic [11:0] csr_addr;

  logic ecall;
  logic ebreak;
  logic mret;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic valid;

  modport in(
      input inst, pc, npc, btaken,
      input dest, result, ebreak,
      input prd, rd,
      input csr_wen, csr_wdata, csr_addr, ecall, mret,
      input trap, tval, cause,
      input valid
  );
  modport out(
      output inst, pc, npc, btaken,
      output dest, result, ebreak,
      output prd, rd,
      output csr_wen, csr_wdata, csr_addr, ecall, mret,
      output trap, tval, cause,
      output valid
  );
endinterface

interface exu_ioq_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic [XLEN-1:0] result;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;

  logic wen;
  logic [4:0] alu;
  logic [XLEN-1:0] sq_waddr;
  logic [XLEN-1:0] sq_wdata;

  logic valid;

  modport in(
      input inst, pc, npc,
      input result, dest,
      input prd, rd,
      input wen, alu, sq_waddr, sq_wdata,
      input valid
  );
  modport out(
      output inst, pc, npc,
      output result, dest,
      output prd, rd,
      output wen, alu, sq_waddr, sq_wdata,
      output valid
  );
endinterface

`endif  // YSYX_EX_IF_SVH
