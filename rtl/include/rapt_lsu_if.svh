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
  rapt_pkg::mem_context_t rcontext;
  logic [4:0] ralu;
  logic atomic_lock;
  logic atomic_release; // atomic read must wait for older SQ writes to complete
  logic ordered;
  logic [`RAPT_PC_BITS_OF(XLEN)-1:0] pc;
  logic [XLEN-1:0] rdata;
  logic [63:0] fp_rdata64;
  logic fp_rdata64_req;
  logic fp_rdata64_valid;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] tval;
`ifdef RAPT_H_EXTENSION
  logic [XLEN-1:2] gpaddr;
  logic gptw;
`endif
  logic difftest_skip;
  logic rready;
  // Request released, not completed: replay only at IOQ and ROB head.
  logic rretry;
  logic rmiss, miss_wake;
  logic stq_ready;
  logic sq_busy;
  logic rvalid_b;
  logic [XLEN-1:0] raddr_b;
  rapt_pkg::mem_context_t rcontext_b;
  logic [4:0] ralu_b;
  logic [XLEN-1:0] rdata_b;
  logic rready_b;
  logic rretry_b;

`ifdef RAPT_H_EXTENSION
  modport master(
      output rvalid, raddr, rcontext, ralu, atomic_lock, atomic_release, ordered, pc,
      output fp_rdata64_req,
      input gpaddr, gptw, rdata, fp_rdata64, fp_rdata64_valid, trap, cause, tval,
      input difftest_skip, rready, rretry, rmiss, miss_wake, stq_ready, sq_busy,
      output rvalid_b, raddr_b, rcontext_b, ralu_b,
      input rdata_b, rready_b, rretry_b
  );
  modport slave(
      input rvalid, raddr, rcontext, ralu, atomic_lock, atomic_release, ordered, pc,
      output gpaddr, gptw, rdata, fp_rdata64, fp_rdata64_valid, trap, cause, tval,
      output difftest_skip, rready, rretry, rmiss, miss_wake, stq_ready, sq_busy,
      input fp_rdata64_req,
      input rvalid_b, raddr_b, rcontext_b, ralu_b,
      output rdata_b, rready_b, rretry_b
  );
`else
  modport master(
      output rvalid, raddr, rcontext, ralu, atomic_lock, atomic_release, ordered, pc,
      output fp_rdata64_req,
      input rdata, fp_rdata64, fp_rdata64_valid, trap, cause, tval,
      input difftest_skip, rready, rretry, rmiss, miss_wake, stq_ready, sq_busy,
      output rvalid_b, raddr_b, rcontext_b, ralu_b,
      input rdata_b, rready_b, rretry_b
  );
  modport slave(
      input rvalid, raddr, rcontext, ralu, atomic_lock, atomic_release, ordered, pc,
      output rdata, fp_rdata64, fp_rdata64_valid, trap, cause, tval,
      output difftest_skip, rready, rretry, rmiss, miss_wake, stq_ready, sq_busy,
      input fp_rdata64_req,
      input rvalid_b, raddr_b, rcontext_b, ralu_b,
      output rdata_b, rready_b, rretry_b
  );
`endif
endinterface

interface lsu_l1d_mmu_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic mmu_en;
  rapt_pkg::mem_context_t mem_context;
  logic [XLEN-1:0] vaddr;
  logic [4:0] walu;
  // Cache-block management is authorized by load OR store permission and
  // checks A but not D.  It otherwise uses the precise store-fault path.
  logic cmo_mgmt;
  logic valid;
  logic misaligned;
`ifdef RAPT_H_EXTENSION
  logic guest;
  logic [XLEN-1:2] gpaddr;
  logic gptw;
`endif
  logic [XLEN-1:0] paddr;
  logic [1:0] pbmt;
  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] reservation;
  logic reservation_valid;
  logic [3:0] reservation_size_m1; // exact LR byte extent, valid when reservation_valid
  logic reservation_clear;
  logic reservation_blocked; // pending external write notifications; SC waits
  logic atomic_lock_req;     // request cluster atomic lock (AMO / SC)
  logic atomic_lock_stall;   // 1 = wait for cluster atomic lock grant
  logic ready;

`ifdef RAPT_H_EXTENSION
  modport master(
      output mmu_en, mem_context, vaddr, walu, cmo_mgmt, valid, misaligned, reservation_clear,
      output atomic_lock_req, guest,
      input gpaddr, gptw, paddr, pbmt, trap, cause, reservation, reservation_valid,
      input reservation_size_m1, reservation_blocked, atomic_lock_stall, ready
  );
  modport slave(
      input mmu_en, mem_context, vaddr, walu, cmo_mgmt, valid, misaligned, reservation_clear,
      input atomic_lock_req, guest,
      output gpaddr, gptw, paddr, pbmt, trap, cause, reservation, reservation_valid,
      output reservation_size_m1, reservation_blocked, atomic_lock_stall, ready
  );
`else
  modport master(
      output mmu_en, mem_context, vaddr, walu, cmo_mgmt, valid, misaligned, reservation_clear,
      output atomic_lock_req,
      input paddr, pbmt, trap, cause, reservation, reservation_valid,
      input reservation_size_m1, reservation_blocked, atomic_lock_stall, ready
  );
  modport slave(
      input mmu_en, mem_context, vaddr, walu, cmo_mgmt, valid, misaligned, reservation_clear,
      input atomic_lock_req,
      output paddr, pbmt, trap, cause, reservation, reservation_valid,
      output reservation_size_m1, reservation_blocked, atomic_lock_stall, ready
  );
`endif
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_LSU_IF_SVH
