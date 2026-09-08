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
  logic atomic_release; // atomic read must wait for older SQ writes to complete
  logic ordered;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] rdata;
  logic [63:0] fp_rdata64;
  logic fp_rdata64_req;
  logic fp_rdata64_valid;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] tval;
  logic difftest_skip;
  logic rready;
  logic stq_ready;
  logic rvalid_b;
  logic [XLEN-1:0] raddr_b;
  logic [4:0] ralu_b;
  logic [XLEN-1:0] rdata_b;
  logic rready_b;

  modport master(
      output rvalid, raddr, ralu, atomic_lock, atomic_release, ordered, pc,
      output fp_rdata64_req,
      input rdata, fp_rdata64, fp_rdata64_valid, trap, cause, tval, difftest_skip, rready, stq_ready,
      output rvalid_b, raddr_b, ralu_b,
      input rdata_b, rready_b
  );
  modport slave(
      input rvalid, raddr, ralu, atomic_lock, atomic_release, ordered, pc,
      output rdata, fp_rdata64, fp_rdata64_valid, trap, cause, tval, difftest_skip, rready, stq_ready,
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
  // Cache-block management is authorized by load OR store permission and
  // checks A but not D.  It otherwise uses the precise store-fault path.
  logic cmo_mgmt;
  logic valid;
  logic misaligned;
  logic [XLEN-1:0] paddr;
  logic [1:0] pbmt;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] reservation;
  logic reservation_valid;
  logic [3:0] reservation_size_m1; // exact LR byte extent, valid when reservation_valid
  logic reservation_clear;
  logic reservation_blocked; // pending external write notifications; SC waits
  logic ready;

  modport master(
      output mmu_en, vaddr, walu, cmo_mgmt, valid, misaligned, reservation_clear,
      input paddr, pbmt, trap, cause, reservation, reservation_valid, reservation_size_m1, reservation_blocked, ready
  );
  modport slave(
      input mmu_en, vaddr, walu, cmo_mgmt, valid, misaligned, reservation_clear,
      output paddr, pbmt, trap, cause, reservation, reservation_valid, reservation_size_m1, reservation_blocked, ready
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_LSU_IF_SVH
