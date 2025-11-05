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
  logic atomic_lock;
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] rdata;
  logic trap;
  logic [XLEN-1:0] cause;
  logic rready;

  modport master(output rvalid, raddr, ralu, atomic_lock, pc, input rdata, trap, cause, rready);
  modport slave(input rvalid, raddr, ralu, atomic_lock, pc, output rdata, trap, cause, rready);
endinterface


interface exu_csr_if #(
    parameter bit [7:0] R_W  = 12,
    parameter bit [7:0] XLEN = `YSYX_XLEN
);
  logic [ R_W-1:0] raddr;

  logic [XLEN-1:0] rdata;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic [XLEN-1:0] sepc;

  modport master(output raddr, input rdata, mtvec, mepc, sepc);
  modport slave(input raddr, output rdata, mtvec, mepc, sepc);
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
  logic sret;

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;

  logic valid;

  modport in(
      input inst, pc, npc, btaken,
      input dest, result, ebreak,
      input prd, rd,
      input csr_wen, csr_wdata, csr_addr, ecall, mret, sret,
      input trap, tval, cause,
      input valid
  );
  modport out(
      output inst, pc, npc, btaken,
      output dest, result, ebreak,
      output prd, rd,
      output csr_wen, csr_wdata, csr_addr, ecall, mret, sret,
      output trap, tval, cause,
      output valid
  );
endinterface

interface exu_l1d_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic mmu_en;
  logic [XLEN-1:0] vaddr;
  logic [4:0] walu;
  logic valid;

  logic [XLEN-1:0] paddr;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] reservation;
  logic ready;

  modport master(output mmu_en, vaddr, walu, valid, input paddr, trap, cause, reservation, ready);
  modport slave(input mmu_en, vaddr, walu, valid, output paddr, trap, cause, reservation, ready);
endinterface

interface exu_ioq_bcast_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
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

  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;
  logic [31:0] inst;

  logic valid;

  modport in(
      input pc, npc,
      input result, dest,
      input prd, rd,
      input wen, alu, sq_waddr, sq_wdata,
      input trap, tval, cause, inst,
      input valid
  );
  modport out(
      output pc, npc,
      output result, dest,
      output prd, rd,
      output wen, alu, sq_waddr, sq_wdata,
      output trap, tval, cause, inst,
      output valid
  );
endinterface

`endif  // YSYX_EX_IF_SVH
