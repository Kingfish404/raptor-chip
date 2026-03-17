`ifndef YSYX_IF_SVH
`define YSYX_IF_SVH
`include "ysyx.svh"
`include "ysyx_ifu_if.svh"
`include "ysyx_idu_if.svh"
`include "ysyx_rnu_if.svh"
`include "ysyx_rou_if.svh"
`include "ysyx_exu_if.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */

// lsu to l1d interface
interface lsu_l1d_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int L1D_LEN = `YSYX_L1D_LEN
);
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic rvalid;
  logic atomic_lock;

  logic [XLEN-1:0] rdata;
  logic trap;
  logic [XLEN-1:0] cause;
  logic difftest_skip;
  logic rready;

  logic [XLEN-1:0] waddr;
  logic [4:0] walu;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic wready;

  modport master(
      output raddr, ralu, rvalid, atomic_lock,
      input rdata, trap, cause, difftest_skip, rready,
      output waddr, walu, wvalid, wdata,
      input wready
  );
  modport slave(
      input raddr, ralu, rvalid, atomic_lock,
      output rdata, trap, cause, difftest_skip, rready,
      input waddr, walu, wvalid, wdata,
      output wready
  );
endinterface

// instruction cache interface
interface l1i_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic arburst;  // request 2-beat INCR burst (SDRAM)
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;

  modport master(output arvalid, araddr, arburst, input rready, rdata, rvalid, rlast);
  modport slave(input arvalid, araddr, arburst, output rready, rdata, rvalid, rlast);
endinterface

// data cache interface
interface l1d_bus_if #(
    parameter int XLEN = `YSYX_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic [7:0] rstrb;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;
  logic difftest_skip;

  // store
  logic awvalid;
  logic [XLEN-1:0] awaddr;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [7:0] wstrb;
  logic wready;

  modport master(
      output arvalid, araddr, rstrb,
      input rready,
      input rdata, rvalid, rlast, difftest_skip,

      output awvalid, awaddr, wvalid, wdata, wstrb,
      input wready
  );
  modport slave(
      input arvalid, araddr, rstrb,
      output rready,
      output rdata, rvalid, rlast, difftest_skip,

      input awvalid, awaddr, wvalid, wdata, wstrb,
      output wready
  );
endinterface

// csr boardcast
interface csr_bcast_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [1:0] priv;
  logic [21:0] satp_ppn;
  logic [8:0] satp_asid;
  logic immu_en;
  logic dmmu_en;

  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] tvec;
  logic interrupt_en;

  modport in(input priv, satp_ppn, satp_asid, input immu_en, dmmu_en, mtvec, tvec, interrupt_en);
  modport out(output priv, satp_ppn, satp_asid, output immu_en, dmmu_en, mtvec, tvec, interrupt_en);
endinterface

// final commit boardcast
interface cmu_bcast_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;

  logic ben;
  logic jen;
  logic jren;
  logic btaken;

  logic fence_time;
  logic fence_i;

  logic flush_pipe;
  logic time_trap;

  // Per-slot commit info (dual commit)
  logic [RLEN-1:0] rd_a;
  logic [RLEN-1:0] rd_b;
  logic valid_b;

  modport in(
      input rpc, cpc, rd_a, ben, jen, jren, btaken,
      input fence_time, fence_i, flush_pipe, time_trap,
      input rd_b, valid_b
  );
  modport out(
      output rpc, cpc, rd_a, ben, jen, jren, btaken,
      output fence_time, fence_i, flush_pipe, time_trap,
      output rd_b, valid_b
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNDRIVEN */

`endif
