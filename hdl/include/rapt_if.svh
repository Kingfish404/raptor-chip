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
  logic ordered;

  logic [XLEN-1:0] rdata;
  logic trap;
  logic [XLEN-1:0] cause;
  logic difftest_skip;
  logic rready;

  // Hit-under-miss B channel (Phase A2, RAPT_LSU_HUM): a second best-effort
  // load request served ONLY from the cache while the A channel waits on a
  // miss refill (LD_D).  Held-request protocol like A; completes on a clean
  // cacheable hit, otherwise simply never fires rready_b (the load retries
  // via A later, where traps/PMP are raised).  No trap/cause on B.
  logic [XLEN-1:0] raddr_b;
  logic [4:0] ralu_b;
  logic rvalid_b;
  logic [XLEN-1:0] rdata_b;
  logic rready_b;

  logic [XLEN-1:0] waddr;
  logic [4:0] walu;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic wready;

  modport master(
      output raddr, ralu, rvalid, atomic_lock, ordered,
      input rdata, trap, cause, difftest_skip, rready,
      output raddr_b, ralu_b, rvalid_b,
      input rdata_b, rready_b,
      output waddr, walu, wvalid, wdata,
      input wready
  );
  modport slave(
      input raddr, ralu, rvalid, atomic_lock, ordered,
      output rdata, trap, cause, difftest_skip, rready,
      input raddr_b, ralu_b, rvalid_b,
      output rdata_b, rready_b,
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
  logic ar_ptw;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic ptw_rvalid;
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
  logic aw_ptw;
  logic ptw_wready;
  logic ptw_werr;

  modport master(
      output arvalid, araddr, arburst, ar_ptw,
      input rready, rdata, rvalid, ptw_rvalid, rlast, rerr,
      output awvalid, awaddr, wvalid, wdata, wstrb, aw_ptw,
      input wready, werr, ptw_wready, ptw_werr
  );
  modport slave(
      input arvalid, araddr, arburst, ar_ptw,
      output rready, rdata, rvalid, ptw_rvalid, rlast, rerr,
      input awvalid, awaddr, wvalid, wdata, wstrb, aw_ptw,
      output wready, werr, ptw_wready, ptw_werr
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
  logic ar_ptw;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic ptw_rvalid;
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
  logic aw_ptw;
  logic ptw_wready;
  logic ptw_werr;

  modport master(
      output arvalid, araddr, rstrb, ar_ptw,
      input rready,
      input rdata, rvalid, ptw_rvalid, rlast, difftest_skip, rerr,

      output awvalid, awaddr, wvalid, wdata, wstrb, aw_ptw,
      input wready, werr, ptw_wready, ptw_werr
  );
  modport slave(
      input arvalid, araddr, rstrb, ar_ptw,
      output rready,
      output rdata, rvalid, ptw_rvalid, rlast, difftest_skip, rerr,

      input awvalid, awaddr, wvalid, wdata, wstrb, aw_ptw,
      output wready, werr, ptw_wready, ptw_werr
  );
endinterface

// csr boardcast
interface pmp_update_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter int N = `RAPT_PMP_NUM,
    parameter int IDX_W = $clog2(N)
);
  localparam int PMPAddrBits = PADDR_BITS - 2;
  logic                  addr_we;
  logic [IDX_W-1:0]      addr_idx;
  logic [PMPAddrBits-1:0] raw_addr;
  logic [PMPAddrBits-1:0] napot_mask;
  logic [N-1:0]          cfg_we;
  logic [N-1:0]          cfg_r;
  logic [N-1:0]          cfg_w;
  logic [N-1:0]          cfg_x;
  logic [N-1:0]          cfg_l;
  logic [N-1:0]          mode_off;
  logic [N-1:0]          mode_tor;
  logic [N-1:0]          mode_na4;
  logic [N-1:0]          mode_napot;

  modport in(
      input addr_we, addr_idx, raw_addr, napot_mask,
             cfg_we, cfg_r, cfg_w, cfg_x, cfg_l,
             mode_off, mode_tor, mode_na4, mode_napot
  );
  modport out(
      output addr_we, addr_idx, raw_addr, napot_mask,
              cfg_we, cfg_r, cfg_w, cfg_x, cfg_l,
              mode_off, mode_tor, mode_na4, mode_napot
  );
endinterface

interface pmp_state_if #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter int N = `RAPT_PMP_NUM
);
  localparam int PMPAddrBits = PADDR_BITS - 2;
  logic [PMPAddrBits-1:0] pmp_raw_addr[N];
  logic [PMPAddrBits-1:0] pmp_napot_mask[N];
  logic [N-1:0] pmp_cfg_r;
  logic [N-1:0] pmp_cfg_w;
  logic [N-1:0] pmp_cfg_x;
  logic [N-1:0] pmp_cfg_l;
  logic [N-1:0] pmp_mode_off;
  logic [N-1:0] pmp_mode_tor;
  logic [N-1:0] pmp_mode_na4;
  logic [N-1:0] pmp_mode_napot;

  modport in(
      input pmp_raw_addr, pmp_napot_mask,
             pmp_cfg_r, pmp_cfg_w, pmp_cfg_x, pmp_cfg_l,
             pmp_mode_off, pmp_mode_tor, pmp_mode_na4, pmp_mode_napot
  );
  modport out(
      output pmp_raw_addr, pmp_napot_mask,
              pmp_cfg_r, pmp_cfg_w, pmp_cfg_x, pmp_cfg_l,
              pmp_mode_off, pmp_mode_tor, pmp_mode_na4, pmp_mode_napot
  );
endinterface

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
  logic [2:0] frm;
  logic [1:0] fs;

  modport in(
      input priv, satp_ppn, satp_asid,
      input immu_en, dmmu_en, mtvec, tvec, timer_int_en, sw_int_en, ext_int_en,
      input mprv, mpp,
      input tsr, tvm, tw, mcounteren, scounteren,
      input sum, mxr, sbe, frm, fs
  );
  modport out(
      output priv, satp_ppn, satp_asid,
      output immu_en, dmmu_en, mtvec, tvec, timer_int_en, sw_int_en, ext_int_en,
      output mprv, mpp,
      output tsr, tvm, tw, mcounteren, scounteren,
      output sum, mxr, sbe, frm, fs
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
