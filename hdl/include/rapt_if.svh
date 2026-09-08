/* verilator lint_off DECLFILENAME */
`ifndef RAPT_IF_SVH
`define RAPT_IF_SVH
`include "rapt.svh"
`include "rapt_ifu_if.svh"
`include "rapt_idu_if.svh"
`include "rapt_rnu_if.svh"
`include "rapt_recovery_if.svh"
`include "rapt_rou_if.svh"
`include "rapt_dpu_if.svh"
`include "rapt_cdb_if.svh"
`include "rapt_eu_if.svh"
`include "rapt_lsu_if.svh"

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
  logic idle; // No L1D owner, PTW, maintenance, or incoming request.
  // Original architectural alignment, preserved across aligned split beats.
  logic rmisaligned;
  // Split read: permission/PMA footprint within the aligned data beat.
  logic rcheck_valid;
  logic [2:0] rcheck_offset;
  logic [3:0] rcheck_size_m1;
  // Original architecture width for split requests (rcheck_valid).
  logic [3:0] rorig_size_m1;
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
  // Translation attribute of this committed store beat, held with its PA.
  logic [1:0] wpbmt;
  // Unshifted byte-enable mask.  Eight bits are required for arbitrary
  // RV64 misaligned-store spill sizes (for example, 5--7 bytes of SD).
  logic [7:0] walu;
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic wready;
  logic werr; // Failed committed write beat, qualified by wready.

  modport master(
      output raddr, ralu, rvalid, rmisaligned, rcheck_valid, rcheck_offset, rcheck_size_m1, rorig_size_m1, atomic_lock, ordered,
      input idle, rdata, trap, cause, difftest_skip, rready,
      output raddr_b, ralu_b, rvalid_b,
      input rdata_b, rready_b,
      output waddr, wpbmt, walu, wvalid, wdata,
      input wready, werr
  );
  modport slave(
      input raddr, ralu, rvalid, rmisaligned, rcheck_valid, rcheck_offset, rcheck_size_m1, rorig_size_m1, atomic_lock, ordered,
      output idle, rdata, trap, cause, difftest_skip, rready,
      input raddr_b, ralu_b, rvalid_b,
      output rdata_b, rready_b,
      input waddr, wpbmt, walu, wvalid, wdata,
      output wready, werr
  );
endinterface

// instruction cache interface
interface l1i_bus_if #(
    parameter int XLEN = `RAPT_XLEN
);
  // load
  logic arvalid;
  logic [1:0] rpbmt;
  logic [XLEN-1:0] araddr;
  logic arburst;  // request 2-beat INCR burst (SDRAM)
  logic ar_ptw;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic ptw_rvalid;
  logic ptw_rerr;
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
      output arvalid, rpbmt, araddr, arburst, ar_ptw,
      input rready, rdata, rvalid, ptw_rvalid, ptw_rerr, rlast, rerr,
      output awvalid, awaddr, wvalid, wdata, wstrb, aw_ptw,
      input wready, werr, ptw_wready, ptw_werr
  );
  modport slave(
      input arvalid, rpbmt, araddr, arburst, ar_ptw,
      output rready, rdata, rvalid, ptw_rvalid, ptw_rerr, rlast, rerr,
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
  logic idle; // D-side reads and all writes have completed at mem_link.
  logic [XLEN-1:0] araddr;
  logic [7:0] rstrb;
  logic [1:0] rpbmt;
  logic ar_ptw;
  logic rready;

  logic [XLEN-1:0] rdata;
  logic rvalid;
  logic ptw_rvalid;
  logic ptw_rerr; // Qualified PTE read error; separate from ordinary data.
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
  logic [1:0] wpbmt;
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
      output arvalid, araddr, rstrb, rpbmt, ar_ptw,
      input rready,
      input idle, rdata, rvalid, ptw_rvalid, ptw_rerr, rlast, difftest_skip, rerr,

      output awvalid, awaddr, wvalid, wdata, wstrb, wpbmt, aw_ptw,
      input wready, werr, ptw_wready, ptw_werr
  );
  modport slave(
      input arvalid, araddr, rstrb, rpbmt, ar_ptw,
      output rready,
      output idle, rdata, rvalid, ptw_rvalid, ptw_rerr, rlast, difftest_skip, rerr,

      input awvalid, awaddr, wvalid, wdata, wstrb, wpbmt, aw_ptw,
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
  // The low nine satp.ASID bits are implemented; RV64 ASID[15:9] are
  // WARL-zero so software discovers ASIDLEN=9.
  logic [8:0] satp_asid;
  logic immu_en;
  logic dmmu_en;

  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] tvec;
  logic timer_int_en;
  logic sw_int_en;
  logic ext_int_en;
  logic bus_error_int; // Eligible nondelegatable platform machine interrupt 16.

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
  logic [1:0] menvcfg_cbie;
  logic       menvcfg_cbcfe;
  logic       menvcfg_cbze;
  logic       menvcfg_stce;
  logic       menvcfg_pbmte;
  logic [1:0] senvcfg_cbie;
  logic       senvcfg_cbcfe;
  logic       senvcfg_cbze;

  modport in(
      input priv, satp_ppn, satp_asid,
      input immu_en, dmmu_en, mtvec, tvec, timer_int_en, sw_int_en, ext_int_en, bus_error_int,
      input mprv, mpp,
      input tsr, tvm, tw, mcounteren, scounteren,
      input sum, mxr, sbe, frm, fs,
      input menvcfg_cbie, menvcfg_cbcfe, menvcfg_cbze, menvcfg_stce, menvcfg_pbmte,
      input senvcfg_cbie, senvcfg_cbcfe, senvcfg_cbze
  );
  modport out(
      output priv, satp_ppn, satp_asid,
      output immu_en, dmmu_en, mtvec, tvec, timer_int_en, sw_int_en, ext_int_en, bus_error_int,
      output mprv, mpp,
      output tsr, tvm, tw, mcounteren, scounteren,
      output sum, mxr, sbe, frm, fs,
      output menvcfg_cbie, menvcfg_cbcfe, menvcfg_cbze, menvcfg_stce, menvcfg_pbmte,
      output senvcfg_cbie, senvcfg_cbcfe, senvcfg_cbze
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
  logic atomic_retired;
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


  modport in(
      input rpc, cpc, ben, jen, jren, btaken, atomic_retired, call, ret, rvc,
      input fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap,
      input redirect_pc,
      input rob_head
  );
  modport out(
      output rpc, cpc, ben, jen, jren, btaken, atomic_retired, call, ret, rvc,
      output fence_time, fence_i, flush_pipe, flush_redirect, sys_resume, time_trap,
      output redirect_pc,
      output rob_head
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNDRIVEN */

`endif
