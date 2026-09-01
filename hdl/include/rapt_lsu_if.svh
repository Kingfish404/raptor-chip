/* verilator lint_off DECLFILENAME */
`ifndef RAPT_LSU_IF_SVH
`define RAPT_LSU_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface lsu_pipe_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic rvalid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic atomic_lock;
  logic ordered;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] rdata;
  logic [63:0] fp_rdata64;
  logic fp_rdata64_req;
  logic fp_rdata64_valid;
  logic trap;
  logic [XLEN-1:0] cause;
  logic difftest_skip;
  logic rready;
  logic stq_ready;
  logic rvalid_b;
  logic [XLEN-1:0] raddr_b;
  logic [4:0] ralu_b;
  logic [XLEN-1:0] rdata_b;
  logic rready_b;

  modport master(
      output rvalid, raddr, ralu, atomic_lock, ordered, pc,
      output fp_rdata64_req,
      input rdata, fp_rdata64, fp_rdata64_valid, trap, cause, difftest_skip, rready, stq_ready,
      output rvalid_b, raddr_b, ralu_b,
      input rdata_b, rready_b
  );
  modport slave(
      input rvalid, raddr, ralu, atomic_lock, ordered, pc,
      output rdata, fp_rdata64, fp_rdata64_valid, trap, cause, difftest_skip, rready, stq_ready,
      input fp_rdata64_req,
      input rvalid_b, raddr_b, ralu_b,
      output rdata_b, rready_b
  );
endinterface

interface lsu_l1d_mmu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic mmu_en;
  logic [XLEN-1:0] vaddr;
  logic [4:0] walu;
  logic valid;
  logic [XLEN-1:0] paddr;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] reservation;
  logic reservation_valid;
  logic reservation_clear;
  logic ready;

  modport master(
      output mmu_en, vaddr, walu, valid, reservation_clear,
      input paddr, trap, cause, reservation, reservation_valid, ready
  );
  modport slave(
      input mmu_en, vaddr, walu, valid, reservation_clear,
      output paddr, trap, cause, reservation, reservation_valid, ready
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_LSU_IF_SVH
