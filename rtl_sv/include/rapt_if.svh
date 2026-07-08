/* verilator lint_off DECLFILENAME */
`ifndef RAPT_IF_SVH
`define RAPT_IF_SVH
`include "rapt.svh"
`include "rapt_ifu_if.svh"
`include "rapt_idu_if.svh"
`include "rapt_rnu_if.svh"
`include "rapt_rou_if.svh"
`include "rapt_exu_if.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */

// lsu to l1d interface
interface lsu_l1d_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int L1D_LEN = `RAPT_L1D_LEN
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
    parameter int XLEN = `RAPT_XLEN
);
  // load
  logic arvalid;
  logic [XLEN-1:0] araddr;
  logic arburst;  // request 2-beat INCR burst (SDRAM)
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic rlast;
  // Bus-error indicator: AXI rresp != OKAY for the routed response beat.
  // Asserted in the same cycle as `rvalid`; treat as fetch access-fault.
  logic rerr;

  // Store path used only by IPTW hardware A-bit updates.
  logic awvalid;
  logic [XLEN-1:0] awaddr;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [7:0] wstrb;
  logic wready;
  logic werr;

  modport master(
      output arvalid, araddr, arburst,
      input rready, rdata, rvalid, rlast, rerr,
      output awvalid, awaddr, wvalid, wdata, wstrb,
      input wready, werr
  );
  modport slave(
      input arvalid, araddr, arburst,
      output rready, rdata, rvalid, rlast, rerr,
      input awvalid, awaddr, wvalid, wdata, wstrb,
      output wready, werr
  );
endinterface

// data cache interface
interface l1d_bus_if #(
    parameter int XLEN = `RAPT_XLEN
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
  // Bus-error indicator on the read channel (AXI rresp != OKAY).
  // Asserted in the same cycle as `rvalid`; treated as load access-fault.
  logic rerr;

  // store
  logic awvalid;
  logic [XLEN-1:0] awaddr;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [7:0] wstrb;
  logic wready;
  // Bus-error indicator on the write response channel (AXI bresp != OKAY).
  // Asserted in the same cycle as the store handshake (`wready` pulse).
  // Currently logged only -- store access-faults are caught in IOQ via
  // bare-mode PMA / PMP / MMU PMP before reaching the bus, so a runtime
  // werr indicates a configuration mismatch worth flagging in waves.
  logic werr;

  modport master(
      output arvalid, araddr, rstrb,
      input rready,
      input rdata, rvalid, rlast, difftest_skip, rerr,

      output awvalid, awaddr, wvalid, wdata, wstrb,
      input wready, werr
  );
  modport slave(
      input arvalid, araddr, rstrb,
      output rready,
      output rdata, rvalid, rlast, difftest_skip, rerr,

      input awvalid, awaddr, wvalid, wdata, wstrb,
      output wready, werr
  );
endinterface

// csr boardcast
interface csr_bcast_if #(
    parameter int XLEN = `RAPT_XLEN
);
  logic [1:0] priv;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn;
  logic [8:0] satp_asid;
  logic immu_en;
  logic dmmu_en;

  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] tvec;
  logic timer_int_en;
  logic sw_int_en;
  logic ext_int_en;

  // MPRV/MPP for load/store effective privilege
  logic mprv;
  logic [1:0] mpp;

  // mstatus.SUM (Supervisor User Memory access) / MXR (Make eXecutable Readable)
  logic sum;
  logic mxr;

  // mstatush.SBE: when set, implicit page-table accesses read big-endian PTEs.
  logic sbe;

  // mstatus privileged-mode guard bits (TSR/TVM/TW) for illegal-inst checks.
  logic tsr;  // trap sret in S-mode when set
  logic tvm;  // trap satp / sfence.vma in S-mode when set
  logic tw;  // trap wfi in U/S when set

  // mcounteren / scounteren low 3 bits (CY/TM/IR) for U/S counter reads.
  logic [2:0] mcounteren;
  logic [2:0] scounteren;

  // PMP raw state. pmpaddr is the raw CSR value (byte address >> 2);
  // pmpcfg is the 8-bit layout L[7] 0[6:5] A[4:3] X[2] W[1] R[0].
  // Used for software CSR reads (rapt_csr.sv).
  logic [7:0] pmpcfg[`RAPT_PMP_NUM];
  logic [XLEN-1:0] pmpaddr[`RAPT_PMP_NUM];

  // PMP shadow registers, precomputed in rapt_csr on every CSR write.
  // These break the long combinational chain inside rapt_pmp:
  //   * napot_mask/base : closed-form NAPOT decode (XOR + AND)
  //   * tor_lo/tor_hi   : pmpaddr[i-1] / pmpaddr[i] for TOR comparison
  //   * cfg_r/w/x/l     : per-entry permission bit-vectors (one-hot AND-OR friendly)
  //   * mode_off/tor/na4/napot : per-entry mode one-hot vectors
  // 1-cycle latency vs raw pmpcfg/pmpaddr -- RISC-V spec requires sfence.vma
  // (or a pipeline flush, which CSR writes already trigger) before PMP
  // changes take effect, so software always sees the new values in time.
  logic [XLEN-1:0] pmp_napot_mask[`RAPT_PMP_NUM];
  logic [XLEN-1:0] pmp_napot_base[`RAPT_PMP_NUM];
  logic [XLEN-1:0] pmp_tor_lo[`RAPT_PMP_NUM];
  logic [XLEN-1:0] pmp_tor_hi[`RAPT_PMP_NUM];
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_r;
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_w;
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_x;
  logic [`RAPT_PMP_NUM-1:0] pmp_cfg_l;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_off;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_tor;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_na4;
  logic [`RAPT_PMP_NUM-1:0] pmp_mode_napot;

  modport in(
      input priv, satp_ppn, satp_asid,
      input immu_en, dmmu_en, mtvec, tvec, timer_int_en, sw_int_en, ext_int_en,
      input mprv, mpp, pmpcfg, pmpaddr,
      input pmp_napot_mask, pmp_napot_base, pmp_tor_lo, pmp_tor_hi,
      input pmp_cfg_r, pmp_cfg_w, pmp_cfg_x, pmp_cfg_l,
      input pmp_mode_off, pmp_mode_tor, pmp_mode_na4, pmp_mode_napot,
      input tsr, tvm, tw, mcounteren, scounteren,
      input sum, mxr, sbe
  );
  modport out(
      output priv, satp_ppn, satp_asid,
      output immu_en, dmmu_en, mtvec, tvec, timer_int_en, sw_int_en, ext_int_en,
      output mprv, mpp, pmpcfg, pmpaddr,
      output pmp_napot_mask, pmp_napot_base, pmp_tor_lo, pmp_tor_hi,
      output pmp_cfg_r, pmp_cfg_w, pmp_cfg_x, pmp_cfg_l,
      output pmp_mode_off, pmp_mode_tor, pmp_mode_na4, pmp_mode_napot,
      output tsr, tvm, tw, mcounteren, scounteren,
      output sum, mxr, sbe
  );
endinterface

// final commit boardcast
interface cmu_bcast_if #(
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  logic [XLEN-1:0] rpc;
  logic [XLEN-1:0] cpc;

  logic ben;
  logic jen;
  logic jren;
  logic btaken;
  logic call;
  logic ret;
  logic rvc;

  logic fence_time;
  logic fence_i;

  logic flush_pipe;
  logic flush_redirect;
  logic sys_resume;
  logic time_trap;

  // Registered commit-redirect target (Phase 1): frontend fetch redirect PC.
  logic [XLEN-1:0] redirect_pc;

  logic [$clog2(`RAPT_ROB_SIZE)-1:0] rob_head;

  // Per-slot commit info (dual commit)
  logic [RLEN-1:0] rd_a;
  logic [RLEN-1:0] rd_b;
  logic valid_b;

  modport in(
      input rpc, cpc, rd_a, ben, jen, jren, btaken, call, ret, rvc,
      input fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap,
      input redirect_pc,
      input rd_b, valid_b,
      input rob_head
  );
  modport out(
      output rpc, cpc, rd_a, ben, jen, jren, btaken, call, ret, rvc,
      output fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap,
      output redirect_pc,
      output rd_b, valid_b,
      output rob_head
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNDRIVEN */

`endif
