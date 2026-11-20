`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"
`include "rapt_soc.svh"

module rapt_csr #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit [7:0] R_W = 12,
    parameter bit [7:0] REG_W = 6,
    parameter bit [XLEN-1:0] RESET_VAL = 0
) (
    input clock,

    // Hart identifier injected by the cluster top. Returned verbatim by
    // CSR reads of `mhartid` (RV Priv Sec.3.1.5). Tied to '0 today since the
    // cluster only instantiates one core; the multi-core wiring is in place.
    input [XLEN-1:0] hart_id_i,
    input logic [63:0] mtime_i,

    rou_csr_if.in    rou_csr,
    exu_csr_if.slave exu_csr,

    csr_bcast_if.out csr_bcast,
    pmp_update_if.out pmp_update,

    // S-level (SEI/SSI/STI) interrupt pending signal to rou (level).
    // Asserts when an enabled S-level source is takeable at its target mode:
    // non-delegated sources trap to M under the M-mode global enable, and
    // delegated sources trap to S under the S-mode global enable (priv<S, or
    // priv==S && sstatus.SIE). s_int_cause carries the cause code (MSB set):
    // M-mode targets first, then SEI(9) > SSI(1) > STI(5) per Priv Sec.3.1.9.
    output logic            s_int_pending,
    output logic [XLEN-1:0] s_int_cause,

    // Interrupt controller level inputs. These drive the hardware-pending
    // bits in mip/sip; trap eligibility is still gated by mie/mstatus below.
    input timer_irq_i,
    input sw_irq_i,
    input m_ext_irq_i,
    input s_ext_irq_i,

    // Completed failed posted store beat; independent of trap/retire valid.
    input store_error_i,
    input [XLEN-1:0] store_error_addr_i,
    input [7:0] store_error_strb_i,
`ifdef RAPT_V_EXTENSION
    // An authorized vector result can contain committed partial state on trap.
    input logic vector_dirty_i,
    input logic vector_fp_dirty_i,
`endif

    input reset
);

  // CBIE=2 is reserved.  Preserve the three architectural choices and map
  // an attempted reserved write to CBIE=3 (invalidate) as a legal WARL value.
  function automatic logic [XLEN-1:0] envcfg_warl(input logic [XLEN-1:0] value,
                                                  input logic [XLEN-1:0] write_mask);
    logic [XLEN-1:0] result;
    begin
      result = value & write_mask;
      if (result[5:4] == 2'b10) result[5:4] = 2'b11;
      return result;
    end
  endfunction
  typedef enum logic [REG_W-1:0] {
    MNONE__ = 0,
    FFLAGS,
    FRM,
    FCSR,
    SSTATUS,
    SIE____,
    STVEC__,

    SCOUNTE,
    MCOUNTE,

    SSCRATC,
    SEPC___,
    SCAUSE_,
    STVAL__,
    SIP____,
    STIMECMP,
    STIMECMPH,
    SATP___,

    MSTATUS,
    MISA___,
    MEDELEG,
    MIDELEG,
    MIE____,
    MTVEC__,

    MSTATUSH,
    MENVCFG,

    MSCRATCH,
    MEPC___,
    MCAUSE_,
    MTVAL__,
    MIP____,

    MCYCLE_,
    MCYCLEH,
    MINSTRET,
    MINSTRETH,
    TIME___,
    TIMEH__,

    MVENDORID,
    MARCHID,
    IMPID__,
    MHARTID,
    SENVCFG,
    // Append new storage slots: the simulator observes legacy CSR indices.
    MENVCFGH
  } csr_t;

  logic [1:0] priv_mode;
`ifdef RAPT_V_EXTENSION
  localparam logic [XLEN-1:0] VectorStatusMask = XLEN'(3) << 9;
`else
  localparam logic [XLEN-1:0] VectorStatusMask = '0;
`endif
  localparam logic [XLEN-1:0] SupervisorStatusMask =
      XLEN'(`RAPT_CSR_SSTATUS_CMASK) | VectorStatusMask;
  logic [XLEN-1:0] csr_state[64];
  // Preserve the simulator's legacy observation array while storing shared
  // status bits only once. RESET_VAL reaches SSTATUS through MSTATUS as well.
  wire [XLEN-1:0] csr[64] /* verilator public_flat_rd */;
  for (genvar i = 0; i < 64; i++) begin : g_csr_view
    if (i == int'(MISA___)) begin : g_misa
      assign csr[i] = XLEN'(rapt_pkg::Misa);
    end else if (i == int'(SSTATUS)) begin : g_sstatus
      assign csr[i] = (csr_state[MSTATUS] & SupervisorStatusMask) | `RAPT_CSR_SSTATUS_HW;
    end else begin : g_storage
      assign csr[i] = csr_state[i];
    end
  end

  // MISA must advertise F and D exactly when the FEU exists.
  if (rapt_pkg::FpuEnable != (`RAPT_MISA >> 5 & 1) || rapt_pkg::FpuEnable != (`RAPT_MISA >> 3 & 1))
  begin : g_misa_fpu_mismatch
    $error("RAPT_MISA F/D bits disagree with RAPT_NO_FPU");
  end

`ifdef RAPT_V_EXTENSION
  if (!rapt_pkg::FpuEnable) begin : g_vector_requires_fpu
    $error("V extension requires the scalar F and D extensions");
  end
  if (rapt_pkg::VectorLength < 128) begin : g_vector_requires_vlen128
    $error("V extension requires VLEN >= 128");
  end
`endif

  // ROU commit_special retires returns alone; FP effects only come from the
  // actual commit prefix. A return cannot share an FP update or a CSR write.
  `RAPT_SVA_IMPLY(clock, reset, CSR_RETURN_RETIRES_ALONE,
                  rou_csr.valid && (rou_csr.mret || rou_csr.sret),
                  !rou_csr.fp_dirty && !rou_csr.csr_wen)

  localparam bit HypEn64 = rapt_pkg::HypervisorEnable && (XLEN == 64);
  logic virt_q  /* verilator public_flat_rd */;
  // mepc/sepc must be halfword aligned with the C extension. Store only the
  // implemented address bits and restore bit 0 at CSR/interface boundaries.
  logic [XLEN-1:1] mepc_half_q, sepc_half_q, vsepc_half_q;
  // Difftest observes these full-width values through Verilator. Keep
  // them materialized in the generated model, not only as optimized aliases.
  logic [XLEN-1:0] mepc_value /* verilator public_flat_rd */;
  logic [XLEN-1:0] sepc_value /* verilator public_flat_rd */;
  logic [XLEN-1:0] vsepc_value;
  assign mepc_value = {mepc_half_q, 1'b0};
  assign sepc_value = {sepc_half_q, 1'b0};
  assign vsepc_value = {vsepc_half_q, 1'b0};
  logic [XLEN-1:0] hstatus_q, hedeleg_q, hideleg_q, hvip_q, htimedelta_q, henvcfg_q;
  logic [3:0] hcounteren_q;
  logic [3:0] hstateen_se0_q;
  logic hstateen0_envcfg_q;
  logic [XLEN-1:0] htval_q, htinst_q, hgatp_q, mtinst_q, mtval2_q;
  logic [XLEN-1:0] vsstatus_q, vstvec_q, vsscratch_q, vscause_q, vstval_q, vsatp_q;
  logic [63:0] vstimecmp_q;
  logic mstatus_mie;
  csr_t waddr_reg, raddr_reg;
  logic [R_W-1:0] raddr, eff_raddr, eff_waddr;

  logic bus_error_pending, bus_error_overflow;
  logic [XLEN-1:0] bus_error_addr;
  logic [7:0] bus_error_strb;
  logic bus_error_ack;
  assign bus_error_ack = rou_csr.valid && rou_csr.csr_wen
      && rou_csr.csr_addr == `RAPT_CSR_MBERR_STATUS;
  always_ff @(posedge clock) begin
    if (reset) begin
      bus_error_pending <= 0;
      bus_error_overflow <= 0;
      bus_error_addr <= '0;
      bus_error_strb <= '0;
    end else begin
      if (bus_error_ack && rou_csr.csr_wdata[0]) bus_error_pending <= 0;
      if (bus_error_ack && rou_csr.csr_wdata[1]) bus_error_overflow <= 0;
      if (store_error_i) begin
`ifndef SYNTHESIS
`ifdef USE_DPI_C
        npc_store_error_event(64'(store_error_addr_i), store_error_strb_i);
`endif
`endif
        // Keep the first unacknowledged event. Hardware wins W1C races.
        bus_error_pending <= 1;
        if (!bus_error_pending || (bus_error_ack && rou_csr.csr_wdata[0])) begin
          bus_error_addr <= store_error_addr_i;
          bus_error_strb <= store_error_strb_i;
        end else bus_error_overflow <= 1;
      end
    end
  end

  // All architectural time observations use the shared platform counter,
  // including software writes to mtime and Sstc comparisons.
  logic [63:0] time64;
  logic [63:0] stimecmp;
  logic sstc_en, stime_irq, vstime_irq;
  assign time64 = mtime_i;

`ifdef RAPT_RV64
  assign sstc_en = csr[MENVCFG][`RAPT_CSR_MENVCFG_STCE];
`else
  assign sstc_en = csr[MENVCFGH][31];
`endif
  localparam int HenvStceBit = XLEN == 64 ? 63 : 0;
  assign stime_irq = sstc_en && (time64 >= stimecmp);
  assign vstime_irq = HypEn64 && sstc_en && henvcfg_q[HenvStceBit]
      && ((time64 + 64'(htimedelta_q)) >= vstimecmp_q);

  // PMP CSR slots are packed according to XLEN; only RAPT_PMP_NUM are usable.
  // Reserved bits [6:5] of each cfg byte are WARL-zero (mask 8'h9F).
  // pmpaddr is stored in its raw CSR form (byte_addr >> 2).
  localparam int PMPAddrW = `RAPT_PMPADDR_BITS;
  localparam int PMPGrain = `RAPT_PMP_GRANULARITY_LOG2 - 2;
  localparam logic [PMPAddrW-1:0] PMPTorLow = (PMPAddrW'(1) << PMPGrain) - 1;
  localparam logic [PMPAddrW-1:0] PMPNapotLow =
      (PMPAddrW'(1) << (PMPGrain > 0 ? PMPGrain - 1 : 0)) - 1;
  // Match pmp_update_if.IDX_W without a hierarchical constant expression.
  localparam int PMPIndexW = $clog2(`RAPT_PMP_NUM);
  localparam int PMPCheckAddrW = `RAPT_PADDR_BITS - 2;
  localparam logic [11:0] PMPAddrBase = `RAPT_CSR_PMPADDR0;
  localparam logic [11:0] PMPAddrLast = `RAPT_CSR_PMPADDR15;
  // Only pmpcfg0-3 / pmpaddr0-15 are decoded (4-bit slot index), so more
  // usable entries would alias onto the decoded slots.
  if (`RAPT_PMP_NUM < 1 || `RAPT_PMP_NUM > 16 || `RAPT_PMP_NUM > `RAPT_PMP_CSR_NUM)
  begin : g_invalid_pmp_num
    $error("rapt_csr decodes at most 16 PMP entries (RAPT_PMP_NUM=%0d)", `RAPT_PMP_NUM);
  end
  // Legalize reserved W=1/R=0 to no permissions, preserving mode and lock.
  // Storage and distributed permission replicas must receive the same byte.
  function automatic logic [7:0] legalize_pmpcfg(input logic [7:0] raw);
    logic [7:0] value;
    value = raw & 8'h9f;
    if (PMPGrain > 0 && value[`RAPT_PMPCFG_A_] == `RAPT_PMP_A_NA4)
      value[`RAPT_PMPCFG_A_] = `RAPT_PMP_A_OFF;
    if (!value[0] && value[1]) value[2:0] = 3'b000;
    return value;
  endfunction

  logic [XLEN-1:0] pmpcfg_legal_wdata;
  for (genvar lane = 0; lane < XLEN / 8; lane++) begin : g_pmpcfg_legal
    assign pmpcfg_legal_wdata[lane*8+:8] = legalize_pmpcfg(rou_csr.csr_wdata[lane*8+:8]);
  end
  logic [7:0]          pmpcfg_r [`RAPT_PMP_CSR_NUM];
  logic [PMPAddrW-1:0] pmpaddr_r[`RAPT_PMP_CSR_NUM];
  for (genvar i = `RAPT_PMP_NUM; i < `RAPT_PMP_CSR_NUM; i++) begin : g_pmp_roz
    assign pmpcfg_r[i] = '0;
    assign pmpaddr_r[i] = '0;
  end

  // A locked TOR entry also protects the preceding address (its lower bound).
  function automatic logic pmp_addr_locked(input logic [3:0] index);
    return pmpcfg_r[index][`RAPT_PMPCFG_L_]
        || ((index < 4'(`RAPT_PMP_NUM - 1))
            && pmpcfg_r[index + 4'd1][`RAPT_PMPCFG_L_]
            && (pmpcfg_r[index + 4'd1][`RAPT_PMPCFG_A_] == `RAPT_PMP_A_TOR));
  endfunction

  // trap handle
  logic smode_medeleg;
  logic smode_mideleg;
  logic smode_handle;

  // mip read-back: CLINT and PLIC levels are reflected as hardware-pending
  // bits. SSIP/STIP/SEIP remain software-writable in csr[MIP____]; SEIP is
  // ORed with the PLIC S-context line so M-mode can still inject S external
  // interrupts if needed.
  logic [XLEN-1:0] mip_eff;
  logic [XLEN-1:0] mstatus_write, sstatus_write, vsstatus_write, hstatus_write, henvcfg_write;
  logic [XLEN-1:0] senvcfg_write, menvcfg_write;
  logic [XLEN-1:0] henvcfg_eff;
  logic [3:0] mstateen_se0_q;
  logic mstateen0_envcfg_q;
  logic eff_data_guest;
  logic vsatp_en, hgatp_en;
  localparam logic [XLEN-1:0] SscofpmfIrqMask =
      rapt_pkg::SscofpmfEnable ? (XLEN'(1) << `RAPT_CSR_MIE_LCOFIE) : '0;
  localparam logic [XLEN-1:0] CounterenWmask =
      XLEN'(rapt_pkg::SscofpmfEnable ? 32'h0000_000f : `RAPT_CSR_COUNTEREN_WMASK);
  localparam logic [4:0] HpmEvent3InhMask = HypEn64 ? 5'b11111 : 5'b11100;
  logic [63:0] mhpmcounter3_q;
  logic mhpmevent3_of_q;
  logic [4:0] mhpmevent3_inh_q;
  logic [7:0] mhpmevent3_sel_q;
  logic [63:0] mhpmevent3_val;
  logic hpm3_inhibited, hpm3_inc, scountovf_en;
  assign mhpmevent3_val = {mhpmevent3_of_q, mhpmevent3_inh_q, 50'b0, mhpmevent3_sel_q};
  assign hpm3_inhibited = (priv_mode == `RAPT_PRIV_M) ? mhpmevent3_inh_q[4]
      : (HypEn64 && virt_q)
        ? ((priv_mode == `RAPT_PRIV_S) ? mhpmevent3_inh_q[1] : mhpmevent3_inh_q[0])
        : ((priv_mode == `RAPT_PRIV_S) ? mhpmevent3_inh_q[3] : mhpmevent3_inh_q[2]);
  assign hpm3_inc = rapt_pkg::SscofpmfEnable && rou_csr.fence_retired
      && (mhpmevent3_sel_q == 8'd1) && !hpm3_inhibited;
  assign scountovf_en = (priv_mode == `RAPT_PRIV_M) ? 1'b1
      : (HypEn64 && virt_q) ? (csr[MCOUNTE][3] & hcounteren_q[3]) : csr[MCOUNTE][3];
  localparam logic [XLEN-1:0] VirtIrqMask = HypEn64 ? XLEN'(12'h444) : '0;
  localparam logic [XLEN-1:0] MedelegWmask = XLEN'(`RAPT_CSR_MEDELEG_WMASK)
      | (HypEn64 ? XLEN'(24'hf0_0400) : '0);
  localparam logic [XLEN-1:0] MidelegWmask = XLEN'(`RAPT_CSR_MIDELEG_WMASK) | SscofpmfIrqMask;
  localparam logic [XLEN-1:0] MieWmask = XLEN'(`RAPT_CSR_MIE_WMASK) | SscofpmfIrqMask | VirtIrqMask;
  localparam logic [XLEN-1:0] SieRmask = XLEN'(`RAPT_CSR_SIE_RMASK) | SscofpmfIrqMask;
  localparam logic [XLEN-1:0] SieWmask = XLEN'(`RAPT_CSR_SIE_WMASK) | SscofpmfIrqMask;
  localparam logic [XLEN-1:0] SipRmask = XLEN'(`RAPT_CSR_SIP_RMASK) | SscofpmfIrqMask;
  localparam logic [XLEN-1:0] SipWmask = XLEN'(`RAPT_CSR_SIP_WMASK) | SscofpmfIrqMask;
  localparam logic [XLEN-1:0] MipWmask = XLEN'(`RAPT_CSR_MIP_WMASK) | SscofpmfIrqMask;
`ifdef RAPT_SSNPM
  localparam bit SsnpmEnable = XLEN == 64;
`else
  localparam bit SsnpmEnable = 1'b0;
`endif
  if (XLEN == 64) begin : g_pmm64
    logic [1:0] senvcfg_pmm, senvcfg_pmm_write;
    logic [1:0] menvcfg_pmm, menvcfg_pmm_write;
    logic [1:0] henvcfg_pmm, henvcfg_pmm_write, hupmm_write;
    logic [1:0] eff_data_priv;
    logic eff_data_mxr;
    assign vsatp_en = HypEn64 && (vsatp_q[63:60] == 4'd8);
    assign hgatp_en = HypEn64 && (hgatp_q[63:60] == 4'd8);
    assign henvcfg_eff = HypEn64 ? (henvcfg_q & (csr[MENVCFG] | ~(64'd3 << 62))) : '0;
    assign senvcfg_pmm = csr[SENVCFG][33:32];
    assign menvcfg_pmm = csr[MENVCFG][33:32];
    assign henvcfg_pmm = henvcfg_eff[33:32];
    assign senvcfg_pmm_write = !SsnpmEnable ? 2'b00
        : (rou_csr.csr_wdata[33:32] == 2'b01 ? senvcfg_pmm : rou_csr.csr_wdata[33:32]);
    assign menvcfg_pmm_write = !rapt_pkg::SmnpmEnable ? 2'b00
        : (rou_csr.csr_wdata[33:32] == 2'b01 ? menvcfg_pmm : rou_csr.csr_wdata[33:32]);
    assign henvcfg_pmm_write = !SsnpmEnable ? 2'b00
        : (rou_csr.csr_wdata[33:32] == 2'b01 ? henvcfg_q[33:32] : rou_csr.csr_wdata[33:32]);
    assign hupmm_write = !SsnpmEnable ? 2'b00
        : (rou_csr.csr_wdata[49:48] == 2'b01 ? hstatus_q[49:48] : rou_csr.csr_wdata[49:48]);
    assign senvcfg_write = envcfg_warl(rou_csr.csr_wdata, XLEN'(`RAPT_CSR_SENVCFG_WMASK))
        | {30'b0, senvcfg_pmm_write, 32'b0};
    assign menvcfg_write = envcfg_warl(rou_csr.csr_wdata, XLEN'(`RAPT_CSR_MENVCFG_WMASK))
        | {30'b0, menvcfg_pmm_write, 32'b0};
    assign henvcfg_write = envcfg_warl(rou_csr.csr_wdata, 64'h0000_0000_0000_00f1)
        | {30'b0, henvcfg_pmm_write, 32'b0}
        | (rou_csr.csr_wdata & csr[MENVCFG] & (64'd3 << 62));
    assign hstatus_write = (rou_csr.csr_wdata & ((64'd15 << 6) | (64'd7 << 20)))
        | (64'd2 << 32) | {14'b0, hupmm_write, 48'b0};
    assign eff_data_priv = (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv)
        ? csr_bcast.mpp : csr_bcast.priv;
    assign eff_data_guest = HypEn64 && (virt_q
        || (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv
            && csr_bcast.mpp != `RAPT_PRIV_M && csr[MSTATUS][39]));
    assign eff_data_mxr = csr_bcast.mxr || (eff_data_guest && vsstatus_q[19]);
    assign csr_bcast.senvcfg_pmm = SsnpmEnable ? senvcfg_pmm : 2'b00;
    assign csr_bcast.data_pmm = (eff_data_priv == `RAPT_PRIV_M || eff_data_mxr) ? 2'b00
        : (eff_data_priv == `RAPT_PRIV_U) ? (SsnpmEnable ? senvcfg_pmm : 2'b00)
        : eff_data_guest ? (SsnpmEnable ? henvcfg_pmm : 2'b00)
        : (rapt_pkg::SmnpmEnable ? menvcfg_pmm : 2'b00);
    assign csr_bcast.data_pmm_sext = (eff_data_priv != `RAPT_PRIV_M)
        && (eff_data_guest ? vsatp_en : (csr[SATP___][`RAPT_CSR_SATP_MODE_] != 0));
  end else begin : g_pmm32
    assign vsatp_en = 1'b0;
    assign hgatp_en = 1'b0;
    assign henvcfg_eff = '0;
    assign csr_bcast.senvcfg_pmm = 2'b00;
    assign senvcfg_write = envcfg_warl(rou_csr.csr_wdata, XLEN'(`RAPT_CSR_SENVCFG_WMASK));
    assign menvcfg_write = envcfg_warl(rou_csr.csr_wdata, XLEN'(`RAPT_CSR_MENVCFG_WMASK));
    assign henvcfg_write = '0;
    assign hstatus_write = '0;
    assign eff_data_guest = 1'b0;
    assign csr_bcast.data_pmm = 2'b00;
    assign csr_bcast.data_pmm_sext = 1'b0;
  end
  assign csr_bcast.mstateen_se0 = rapt_pkg::SmstateenEnable ? mstateen_se0_q : 4'hf;
  assign csr_bcast.mstateen0_envcfg = rapt_pkg::SmstateenEnable ? mstateen0_envcfg_q : 1'b1;
  always_comb begin
    // WARL fields are normalized before deriving the shared S-mode view.
    mstatus_write = (rou_csr.csr_wdata
        & (XLEN'(`RAPT_CSR_MSTATUS_WMASK) | VectorStatusMask
           | (HypEn64 ? (XLEN'(3) << 38) : '0)))
        | `RAPT_CSR_MSTATUS_HW;
    if (mstatus_write[12:11] == 2'b10) mstatus_write[12:11] = 2'b00;
    // Without an FPU, FS is read-only Off (WARL), which makes all FP state trap.
    if (!rapt_pkg::FpuEnable) mstatus_write[14:13] = 2'b00;
    mstatus_write[XLEN-1] = mstatus_write[14:13] == 2'b11
        || ((|VectorStatusMask) && mstatus_write[10:9] == 2'b11);
    sstatus_write = (mstatus_write & SupervisorStatusMask) | `RAPT_CSR_SSTATUS_HW;
    vsstatus_write = '0;
    if (HypEn64) begin
      vsstatus_write = (rou_csr.csr_wdata
          & ((XLEN'(3) << 18) | (rapt_pkg::FpuEnable ? (XLEN'(3) << 13) : '0)
             | VectorStatusMask | (XLEN'(1) << 8) | (XLEN'(1) << 5) | (XLEN'(1) << 1)))
          | (XLEN'(2) << 32);
      vsstatus_write[XLEN-1] = vsstatus_write[14:13] == 2'b11
          || ((|VectorStatusMask) && vsstatus_write[10:9] == 2'b11);
    end
  end
  function automatic logic [11:0] alias_vs_csr(input logic [11:0] addr);
    case (addr)
      `RAPT_CSR_SSTATUS:  return `RAPT_CSR_VSSTATUS;
      `RAPT_CSR_SIE____:  return `RAPT_CSR_VSIE_____;
      `RAPT_CSR_STVEC__:  return `RAPT_CSR_VSTVEC___;
      `RAPT_CSR_SSCRATC:  return `RAPT_CSR_VSSCRATCH;
      `RAPT_CSR_SEPC___:  return `RAPT_CSR_VSEPC____;
      `RAPT_CSR_SCAUSE_:  return `RAPT_CSR_VSCAUSE__;
      `RAPT_CSR_STVAL__:  return `RAPT_CSR_VSTVAL___;
      `RAPT_CSR_SIP____:  return `RAPT_CSR_VSIP_____;
      `RAPT_CSR_STIMECMP: return `RAPT_CSR_VSTIMECMP;
      `RAPT_CSR_SATP___:  return `RAPT_CSR_VSATP____;
      default:            return addr;
    endcase
  endfunction
  always_comb begin
    exu_csr.rmw_data = exu_csr.rdata;
    if (raddr_reg == MIP____)
      exu_csr.rmw_data[`RAPT_CSR_MIE_SEIE] = csr[MIP____][`RAPT_CSR_MIE_SEIE];
  end

  logic [XLEN-1:0] mip_write_mask;
  // With STCE set, STIP is driven exclusively by time >= stimecmp.
  assign mip_write_mask = MipWmask
      & ~(sstc_en ? (XLEN'(1) << `RAPT_CSR_MIE_STIE) : XLEN'(0));

  assign raddr = exu_csr.raddr;
  assign eff_raddr = (HypEn64 && virt_q) ? alias_vs_csr(raddr) : raddr;
  assign eff_waddr = (HypEn64 && virt_q) ? alias_vs_csr(rou_csr.csr_addr) : rou_csr.csr_addr;
  always_comb begin
    case (eff_waddr)
      `RAPT_CSR_FFLAGS:    waddr_reg = FFLAGS;
      `RAPT_CSR_FRM:       waddr_reg = FRM;
      `RAPT_CSR_FCSR:      waddr_reg = FCSR;
      `RAPT_CSR_SSTATUS:   waddr_reg = SSTATUS;
      `RAPT_CSR_SIE____:   waddr_reg = SIE____;
      `RAPT_CSR_STVEC__:   waddr_reg = STVEC__;
      `RAPT_CSR_SCOUNTE:   waddr_reg = SCOUNTE;
      `RAPT_CSR_SENVCFG:   waddr_reg = SENVCFG;
      `RAPT_CSR_SSCRATC:   waddr_reg = SSCRATC;
      `RAPT_CSR_SEPC___:   waddr_reg = SEPC___;
      `RAPT_CSR_SCAUSE_:   waddr_reg = SCAUSE_;
      `RAPT_CSR_STVAL__:   waddr_reg = STVAL__;
      `RAPT_CSR_SIP____:   waddr_reg = SIP____;
      `RAPT_CSR_STIMECMP:  waddr_reg = STIMECMP;
      `RAPT_CSR_STIMECMPH: waddr_reg = STIMECMPH;
      `RAPT_CSR_SATP___:   waddr_reg = SATP___;
      `RAPT_CSR_MSTATUS:   waddr_reg = MSTATUS;
      `RAPT_CSR_MEDELEG:   waddr_reg = MEDELEG;
      `RAPT_CSR_MIDELEG:   waddr_reg = MIDELEG;
      `RAPT_CSR_MIE____:   waddr_reg = MIE____;
      `RAPT_CSR_MTVEC__:   waddr_reg = MTVEC__;
      `RAPT_CSR_MCOUNTE:   waddr_reg = MCOUNTE;
      `RAPT_CSR_MENVCFG:   waddr_reg = MENVCFG;
      `RAPT_CSR_MENVCFGH: waddr_reg = (XLEN == 32) ? MENVCFGH : MNONE__;
      `RAPT_CSR_MSTATUSH:  waddr_reg = MSTATUSH;
      `RAPT_CSR_MSCRATCH:  waddr_reg = MSCRATCH;
      `RAPT_CSR_MEPC___:   waddr_reg = MEPC___;
      `RAPT_CSR_MCAUSE_:   waddr_reg = MCAUSE_;
      `RAPT_CSR_MTVAL__:   waddr_reg = MTVAL__;
      `RAPT_CSR_MIP____:   waddr_reg = MIP____;
      `RAPT_CSR_MCYCLE_:   waddr_reg = MCYCLE_;
      `RAPT_CSR_MCYCLEH:   waddr_reg = (XLEN == 32) ? MCYCLEH : MNONE__;
      `RAPT_CSR_MINSTRET:  waddr_reg = MINSTRET;
      `RAPT_CSR_MINSTRETH: waddr_reg = (XLEN == 32) ? MINSTRETH : MNONE__;
      default:             waddr_reg = MNONE__;
    endcase
  end
  always_comb begin
    case (eff_raddr)
      `RAPT_CSR_FFLAGS:    raddr_reg = FFLAGS;
      `RAPT_CSR_FRM:       raddr_reg = FRM;
      `RAPT_CSR_FCSR:      raddr_reg = FCSR;
      `RAPT_CSR_SSTATUS:   raddr_reg = SSTATUS;
      `RAPT_CSR_SIE____:   raddr_reg = SIE____;
      `RAPT_CSR_STVEC__:   raddr_reg = STVEC__;
      `RAPT_CSR_SCOUNTE:   raddr_reg = SCOUNTE;
      `RAPT_CSR_SENVCFG:   raddr_reg = SENVCFG;
      `RAPT_CSR_SSCRATC:   raddr_reg = SSCRATC;
      `RAPT_CSR_SEPC___:   raddr_reg = SEPC___;
      `RAPT_CSR_SCAUSE_:   raddr_reg = SCAUSE_;
      `RAPT_CSR_STVAL__:   raddr_reg = STVAL__;
      `RAPT_CSR_SIP____:   raddr_reg = SIP____;
      `RAPT_CSR_STIMECMP:  raddr_reg = STIMECMP;
      `RAPT_CSR_STIMECMPH: raddr_reg = STIMECMPH;
      `RAPT_CSR_SATP___:   raddr_reg = SATP___;
      `RAPT_CSR_MSTATUS:   raddr_reg = MSTATUS;
      `RAPT_CSR_MISA___:   raddr_reg = MISA___;
      `RAPT_CSR_MEDELEG:   raddr_reg = MEDELEG;
      `RAPT_CSR_MIDELEG:   raddr_reg = MIDELEG;
      `RAPT_CSR_MIE____:   raddr_reg = MIE____;
      `RAPT_CSR_MCOUNTE:   raddr_reg = MCOUNTE;
      `RAPT_CSR_MENVCFG:   raddr_reg = MENVCFG;
      `RAPT_CSR_MENVCFGH: raddr_reg = (XLEN == 32) ? MENVCFGH : MNONE__;
      `RAPT_CSR_MTVEC__:   raddr_reg = MTVEC__;
      `RAPT_CSR_MSTATUSH:  raddr_reg = MSTATUSH;
      `RAPT_CSR_MSCRATCH:  raddr_reg = MSCRATCH;
      `RAPT_CSR_MEPC___:   raddr_reg = MEPC___;
      `RAPT_CSR_MCAUSE_:   raddr_reg = MCAUSE_;
      `RAPT_CSR_MTVAL__:   raddr_reg = MTVAL__;
      `RAPT_CSR_MIP____:   raddr_reg = MIP____;
      `RAPT_CSR_MCYCLE_:   raddr_reg = MCYCLE_;
      `RAPT_CSR_MCYCLEH:   raddr_reg = (XLEN == 32) ? MCYCLEH : MNONE__;
      `RAPT_CSR_CYCLE__:   raddr_reg = MCYCLE_;
      `RAPT_CSR_CYCLEH_:   raddr_reg = (XLEN == 32) ? MCYCLEH : MNONE__;
      `RAPT_CSR_TIME___:   raddr_reg = TIME___;
      `RAPT_CSR_TIMEH__:   raddr_reg = (XLEN == 32) ? TIMEH__ : MNONE__;
      `RAPT_CSR_MINSTRET:  raddr_reg = MINSTRET;
      `RAPT_CSR_MINSTRETH: raddr_reg = (XLEN == 32) ? MINSTRETH : MNONE__;
      `RAPT_CSR_INSTRET_:  raddr_reg = MINSTRET;
      `RAPT_CSR_INSTRETH:  raddr_reg = (XLEN == 32) ? MINSTRETH : MNONE__;
      `RAPT_CSR_MVENDORID: raddr_reg = MVENDORID;
      `RAPT_CSR_MARCHID__: raddr_reg = MARCHID;
      `RAPT_CSR_IMPID____: raddr_reg = IMPID__;
      `RAPT_CSR_MHARTID__: raddr_reg = MHARTID;
      default:             raddr_reg = MNONE__;
    endcase
  end

  always_comb begin
    case (raddr_reg)
      FFLAGS:    exu_csr.rdata = XLEN'(csr[FCSR][4:0]);
      FRM:       exu_csr.rdata = XLEN'(csr[FCSR][7:5]);
      FCSR:      exu_csr.rdata = XLEN'(csr[FCSR][7:0]);
      SSTATUS:   exu_csr.rdata = csr[SSTATUS];
      SIE____:   exu_csr.rdata = csr[MIE____] & csr[MIDELEG] & SieRmask;
      STVEC__:   exu_csr.rdata = csr[STVEC__];
      SCOUNTE:   exu_csr.rdata = csr[SCOUNTE];
      SENVCFG:   exu_csr.rdata = csr[SENVCFG];
      MCOUNTE:   exu_csr.rdata = csr[MCOUNTE];
      SSCRATC:   exu_csr.rdata = csr[SSCRATC];
      SEPC___:   exu_csr.rdata = sepc_value;
      SCAUSE_:   exu_csr.rdata = csr[SCAUSE_];
      STVAL__:   exu_csr.rdata = csr[STVAL__];
      SIP____:   exu_csr.rdata = mip_eff & csr[MIDELEG] & SipRmask;
      STIMECMP:  exu_csr.rdata = XLEN'(stimecmp[XLEN-1:0]);
      STIMECMPH: exu_csr.rdata = (XLEN == 32) ? XLEN'(stimecmp[63:32]) : '0;
      SATP___:   exu_csr.rdata = csr[SATP___];
      MSTATUS:   exu_csr.rdata = csr[MSTATUS];
      MISA___:   exu_csr.rdata = XLEN'(rapt_pkg::Misa);
      MEDELEG:   exu_csr.rdata = csr[MEDELEG];
      MIDELEG:   exu_csr.rdata = csr[MIDELEG];
      MIE____:   exu_csr.rdata = csr[MIE____];
      MTVEC__:   exu_csr.rdata = csr[MTVEC__];
      MENVCFG:   exu_csr.rdata = csr[MENVCFG];
      MENVCFGH:  exu_csr.rdata = csr[MENVCFGH];
      MSTATUSH:  exu_csr.rdata = csr[MSTATUSH];
      MSCRATCH:  exu_csr.rdata = csr[MSCRATCH];
      MEPC___:   exu_csr.rdata = mepc_value;
      MCAUSE_:   exu_csr.rdata = csr[MCAUSE_];
      MTVAL__:   exu_csr.rdata = csr[MTVAL__];
      MIP____:   exu_csr.rdata = mip_eff;
      MCYCLE_:   exu_csr.rdata = csr[MCYCLE_];
      MCYCLEH:   exu_csr.rdata = csr[MCYCLEH];
      TIME___:   exu_csr.rdata = (HypEn64 && virt_q)
          ? XLEN'(mtime_i + 64'(htimedelta_q)) : XLEN'(mtime_i);
      TIMEH__:   exu_csr.rdata = XLEN'(mtime_i[63:32]);
      MINSTRET:  exu_csr.rdata = csr[MINSTRET];
      MINSTRETH: exu_csr.rdata = csr[MINSTRETH];
      MVENDORID: exu_csr.rdata = XLEN'('d0);
      MARCHID:   exu_csr.rdata = 'd50;
      IMPID__:   exu_csr.rdata = '0;
      MHARTID:   exu_csr.rdata = hart_id_i;
      default: begin
        // PMP CSR reads. RV32: pmpcfg0..3 each packs 4 cfg bytes (entries 4*i..4*i+3).
        // RV64: pmpcfg0 packs entries 0..7 (8 bytes), pmpcfg2 packs entries 8..15;
        //       pmpcfg1/pmpcfg3 are illegal (rejected before CSR execution).
        // Upper read-only-zero slots are supplied by g_pmp_roz.
        if (eff_raddr == `RAPT_CSR_PMPCFG0) begin
          exu_csr.rdata = (XLEN == 64)
                        ? XLEN'({pmpcfg_r[7], pmpcfg_r[6], pmpcfg_r[5], pmpcfg_r[4],
                                 pmpcfg_r[3], pmpcfg_r[2], pmpcfg_r[1], pmpcfg_r[0]})
                        : XLEN'({pmpcfg_r[3], pmpcfg_r[2], pmpcfg_r[1], pmpcfg_r[0]});
        end else if (eff_raddr == `RAPT_CSR_PMPCFG1) begin
          exu_csr.rdata = (XLEN == 64) ? '0
              : XLEN'({pmpcfg_r[7], pmpcfg_r[6], pmpcfg_r[5], pmpcfg_r[4]});
        end else if (eff_raddr == `RAPT_CSR_PMPCFG2) begin
          exu_csr.rdata = (XLEN == 64)
                        ? XLEN'({pmpcfg_r[15], pmpcfg_r[14], pmpcfg_r[13], pmpcfg_r[12],
                                 pmpcfg_r[11], pmpcfg_r[10], pmpcfg_r[9],  pmpcfg_r[8]})
                        : XLEN'({pmpcfg_r[11], pmpcfg_r[10], pmpcfg_r[9], pmpcfg_r[8]});
        end else if (eff_raddr == `RAPT_CSR_PMPCFG3) begin
          exu_csr.rdata = (XLEN == 64) ? '0
                        : XLEN'({pmpcfg_r[15], pmpcfg_r[14], pmpcfg_r[13], pmpcfg_r[12]});
        end else if (eff_raddr >= PMPAddrBase && eff_raddr <= PMPAddrLast) begin
          // Read masking never changes the underlying bit G-1, which must
          // survive NAPOT -> TOR/OFF -> NAPOT without an address write.
          if (int'(eff_raddr[3:0]) >= `RAPT_PMP_NUM) exu_csr.rdata = '0;
          else if (pmpcfg_r[eff_raddr[3:0]][4])
            exu_csr.rdata = XLEN'(pmpaddr_r[eff_raddr[3:0]]) | XLEN'(PMPNapotLow);
          else exu_csr.rdata = XLEN'(pmpaddr_r[eff_raddr[3:0]]) & ~XLEN'(PMPTorLow);
        end else if (rapt_pkg::SscofpmfEnable
            && (eff_raddr == `RAPT_CSR_MHPMCOUNTER3 || eff_raddr == `RAPT_CSR_HPMCOUNTER3)) begin
          exu_csr.rdata = XLEN'(mhpmcounter3_q[XLEN-1:0]);
        end else if (rapt_pkg::SscofpmfEnable && XLEN == 32
            && (eff_raddr == `RAPT_CSR_MHPMCOUNTER3H || eff_raddr == `RAPT_CSR_HPMCOUNTER3H)) begin
          exu_csr.rdata = XLEN'(mhpmcounter3_q[63:32]);
        end else if (rapt_pkg::SscofpmfEnable && eff_raddr == `RAPT_CSR_MHPMEVENT3) begin
          exu_csr.rdata = XLEN'(mhpmevent3_val[XLEN-1:0]);
        end else if (rapt_pkg::SscofpmfEnable && XLEN == 32
            && eff_raddr == `RAPT_CSR_MHPMEVENT3H) begin
          exu_csr.rdata = XLEN'(mhpmevent3_val[63:32]);
        end else if (rapt_pkg::SscofpmfEnable && eff_raddr == `RAPT_CSR_SCOUNTOVF) begin
          exu_csr.rdata = (scountovf_en && mhpmevent3_of_q) ? XLEN'(32'h0000_0008) : '0;
        end else if (rapt_pkg::SmstateenEnable && XLEN == 64 && eff_raddr >=
            `RAPT_CSR_MSTATEEN0
            && eff_raddr <= `RAPT_CSR_MSTATEEN3) begin
          exu_csr.rdata = (XLEN'(mstateen_se0_q[eff_raddr[1:0]]) << 63)
              | (eff_raddr[1:0] == 2'd0 ? (XLEN'(mstateen0_envcfg_q) << 62) : '0);
        end else if (rapt_pkg::SmstateenEnable && XLEN == 32 && eff_raddr >=
            `RAPT_CSR_MSTATEEN0H
            && eff_raddr <= `RAPT_CSR_MSTATEEN3H) begin
          exu_csr.rdata = (XLEN'(mstateen_se0_q[eff_raddr[1:0]]) << 31)
              | (eff_raddr[1:0] == 2'd0 ? (XLEN'(mstateen0_envcfg_q) << 30) : '0);
        end else if (HypEn64) begin
          case (eff_raddr)
            `RAPT_CSR_VSSTATUS:   exu_csr.rdata = vsstatus_q;
            `RAPT_CSR_VSIE_____:  exu_csr.rdata = (csr[MIE____] & hideleg_q & VirtIrqMask) >> 1;
            `RAPT_CSR_VSTVEC___:  exu_csr.rdata = vstvec_q;
            `RAPT_CSR_VSSCRATCH:  exu_csr.rdata = vsscratch_q;
            `RAPT_CSR_VSEPC____:  exu_csr.rdata = vsepc_value;
            `RAPT_CSR_VSCAUSE__:  exu_csr.rdata = vscause_q;
            `RAPT_CSR_VSTVAL___:  exu_csr.rdata = vstval_q;
            `RAPT_CSR_VSIP_____:  exu_csr.rdata = (mip_eff & hideleg_q & VirtIrqMask) >> 1;
            `RAPT_CSR_VSTIMECMP:  exu_csr.rdata = XLEN'(vstimecmp_q);
            `RAPT_CSR_VSATP____:  exu_csr.rdata = vsatp_q;
            `RAPT_CSR_HSTATUS:    exu_csr.rdata = hstatus_q | (XLEN'(2) << 32);
            `RAPT_CSR_HEDELEG:    exu_csr.rdata = hedeleg_q;
            `RAPT_CSR_HIDELEG:    exu_csr.rdata = hideleg_q;
            `RAPT_CSR_HIE____:    exu_csr.rdata = csr[MIE____] & VirtIrqMask;
            `RAPT_CSR_HTIMEDELTA: exu_csr.rdata = htimedelta_q;
            `RAPT_CSR_HCOUNTEREN: exu_csr.rdata = XLEN'(hcounteren_q);
            `RAPT_CSR_HENVCFG:    exu_csr.rdata = henvcfg_eff;
            `RAPT_CSR_HTVAL:      exu_csr.rdata = htval_q;
            `RAPT_CSR_HIP____:    exu_csr.rdata = mip_eff & VirtIrqMask;
            `RAPT_CSR_HVIP___:    exu_csr.rdata = hvip_q & VirtIrqMask;
            `RAPT_CSR_HTINST:     exu_csr.rdata = htinst_q;
            `RAPT_CSR_HGATP:      exu_csr.rdata = hgatp_q;
            `RAPT_CSR_MTINST:     exu_csr.rdata = mtinst_q;
            `RAPT_CSR_MTVAL2:     exu_csr.rdata = mtval2_q;
            `RAPT_CSR_HSTATEEN0, `RAPT_CSR_HSTATEEN1, `RAPT_CSR_HSTATEEN2, `RAPT_CSR_HSTATEEN3:
              exu_csr.rdata = rapt_pkg::SmstateenEnable
                  ? ((XLEN'(hstateen_se0_q[eff_raddr[1:0]] & mstateen_se0_q[eff_raddr[1:0]]) << 63)
                     | (eff_raddr[1:0] == 2'd0
                        ? (XLEN'(hstateen0_envcfg_q & mstateen0_envcfg_q) << 62) : '0))
                  : '0;
            default: exu_csr.rdata = '0;
          endcase
        end else exu_csr.rdata = '0;
      end
    endcase
    if (eff_raddr == `RAPT_CSR_MBERR_STATUS)
      exu_csr.rdata = (XLEN'(bus_error_strb) << 8)
          | (XLEN'(bus_error_overflow) << 1) | XLEN'(bus_error_pending);
    if (eff_raddr == `RAPT_CSR_MBERR_ADDR) exu_csr.rdata = bus_error_addr;
  end

  assign exu_csr.mepc = mepc_value;
  assign exu_csr.sepc = (HypEn64 && virt_q) ? vsepc_value : sepc_value;

  assign mstatus_mie = csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_];

  localparam int MpvBit = XLEN == 64 ? 39 : 0;
  localparam int GvaBit = XLEN == 64 ? 38 : 0;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [63:0] wdata64 = 64'(rou_csr.csr_wdata);
  wire [63:0] mstatus64 = 64'(csr[MSTATUS]);
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] mret_mstatus_next, sret_mstatus_next;
  logic trap_enter, trap_to_s, trap_to_vs;
  logic [XLEN-1:0] trap_cause, vs_trap_cause, trap_tval, trap_epc;
  logic final_is_int;
  logic [5:0] final_code;
  logic is_guest_pf, is_data_gva_cause, is_any_gva_cause, d_mprv_guest;

  assign final_is_int = trap_cause[XLEN-1];
  assign final_code = trap_cause[5:0];
  // medeleg/hedeleg only apply to synchronous exceptions (cause MSB=0) and
  // mideleg/hideleg only to interrupts (cause MSB=1): both cause spaces share
  // the low index bits, e.g. M-timer (7) versus store/AMO access fault (7).
  // ecall/ebreak causes are resolved first, so they use the same delegation.
  assign smode_medeleg = !final_is_int && (7'(final_code) < 7'(XLEN))
      && csr[MEDELEG][final_code[$clog2(XLEN)-1:0]];
  assign smode_mideleg = final_is_int && (7'(final_code) < 7'(XLEN))
      && csr[MIDELEG][final_code[$clog2(XLEN)-1:0]];
  assign smode_handle = (priv_mode == `RAPT_PRIV_S || priv_mode == `RAPT_PRIV_U)
      && (smode_medeleg || smode_mideleg);
  assign trap_to_vs = HypEn64 && virt_q && smode_handle
      && (final_is_int ? hideleg_q[final_code[$clog2(XLEN)-1:0]]
                       : hedeleg_q[final_code[$clog2(XLEN)-1:0]]);
  assign trap_to_s = smode_handle && !trap_to_vs;
  assign vs_trap_cause = (final_is_int
      && (final_code == 6'd2 || final_code == 6'd6 || final_code == 6'd10))
      ? ((XLEN'(1) << (XLEN - 1)) | XLEN'(final_code - 6'd1)) : trap_cause;
  assign is_guest_pf = !final_is_int
      && (final_code == 6'd20 || final_code == 6'd21 || final_code == 6'd23);
  assign is_data_gva_cause = !final_is_int && (
      final_code == 6'd4 || final_code == 6'd5 || final_code == 6'd6 || final_code == 6'd7
      || final_code == 6'd13 || final_code == 6'd15
      || final_code == 6'd21 || final_code == 6'd23);
  assign is_any_gva_cause = is_data_gva_cause || (!final_is_int && (
      final_code == 6'd0 || final_code == 6'd1 || final_code == 6'd3
      || final_code == 6'd12 || final_code == 6'd20));
  assign d_mprv_guest = HypEn64 && (priv_mode == `RAPT_PRIV_M)
      && csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV]
      && (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] != `RAPT_PRIV_M)
      && mstatus64[39];

  always_comb begin
    trap_enter = 1'b0;
    trap_cause = rou_csr.cause;
    trap_tval = rou_csr.tval;
    trap_epc = `RAPT_PC_SEXT(XLEN, rou_csr.pc);
    if (rou_csr.ecall) begin
      trap_enter = 1'b1;
      trap_cause = priv_mode == `RAPT_PRIV_M ? `RAPT_CAUSE_ECALL_M
          : priv_mode == `RAPT_PRIV_S
            ? ((HypEn64 && virt_q) ? `RAPT_CAUSE_ECALL_VS : `RAPT_CAUSE_ECALL_S)
            : `RAPT_CAUSE_ECALL_U;
      trap_tval = '0;
    end else if (!rou_csr.mret && !rou_csr.sret) begin
      if (rou_csr.ebreak) begin
        trap_enter = 1'b1;
        trap_cause = `RAPT_CAUSE_BREAKPOINT;
        trap_tval = trap_epc;
      end else if (rou_csr.trap) begin
        trap_enter = 1'b1;
      end
    end
  end

  always_comb begin
    mret_mstatus_next = csr[MSTATUS];
    mret_mstatus_next[`RAPT_CSR_MSTATUS_MPP_] = `RAPT_PRIV_U;
    mret_mstatus_next[`RAPT_CSR_MSTATUS_MPIE] = 1'b1;
    mret_mstatus_next[`RAPT_CSR_MSTATUS_MIE_] = csr[MSTATUS][`RAPT_CSR_MSTATUS_MPIE];
    if (HypEn64) mret_mstatus_next[MpvBit] = 1'b0;
    if (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] != `RAPT_PRIV_M) begin
      mret_mstatus_next[`RAPT_CSR_MSTATUS_MPRV] = 1'b0;
    end

    sret_mstatus_next = csr[MSTATUS];
    sret_mstatus_next[`RAPT_CSR_MSTATUS_SPP_] = 1'b0;
    sret_mstatus_next[`RAPT_CSR_MSTATUS_SPIE] = 1'b1;
    sret_mstatus_next[`RAPT_CSR_MSTATUS_SIE_] = csr[MSTATUS][`RAPT_CSR_MSTATUS_SPIE];
    sret_mstatus_next[`RAPT_CSR_MSTATUS_MPRV] = 1'b0;
  end

  assign csr_bcast.priv = priv_mode;
  assign csr_bcast.satp_ppn = csr[SATP___][`RAPT_CSR_SATP_PPN_W-1:0];
  assign csr_bcast.satp_asid = csr[SATP___][`RAPT_CSR_SATP_ASID_LSB +: 9];
  assign csr_bcast.immu_en = (HypEn64 && virt_q)
      ? (vsatp_en || hgatp_en)
      : ((csr[SATP___][`RAPT_CSR_SATP_MODE_] != 0) && (priv_mode != `RAPT_PRIV_M));
  assign csr_bcast.dmmu_en = eff_data_guest
      ? (vsatp_en || hgatp_en)
      : ((csr[SATP___][`RAPT_CSR_SATP_MODE_] == 0) ? 1'b0
          : (priv_mode == `RAPT_PRIV_M)
              ? (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV]
                 && (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] != `RAPT_PRIV_M))
              : 1'b1);
  assign csr_bcast.mtvec = csr[MTVEC__];
  // Trap target PC:
  //   - Exceptions (cause[MSB]=0) always go to BASE (MODE ignored).
  //   - Interrupts in Vectored mode (MODE=01) go to BASE + 4*cause. VS-level
  //     interrupts taken in VS-mode use the VS cause (VSEI/VSSI/VSTI - 1).
  //   - Reserved MODE values coerced to Direct by the tvec write mask.
  // BASE is tvec with [1:0] stripped (4-byte aligned).
  logic [XLEN-1:0] mtvec_base, stvec_base, vstvec_base;
  logic [1:0] mtvec_mode, stvec_mode, vstvec_mode;
  logic [XLEN-1:0] vec_offset, vs_vec_offset;
  assign mtvec_base    = {csr[MTVEC__][XLEN-1:2], 2'b00};
  assign stvec_base    = {csr[STVEC__][XLEN-1:2], 2'b00};
  assign vstvec_base   = {vstvec_q[XLEN-1:2], 2'b00};
  assign mtvec_mode    = csr[MTVEC__][1:0];
  assign stvec_mode    = csr[STVEC__][1:0];
  assign vstvec_mode   = vstvec_q[1:0];
  assign vec_offset    = {trap_cause[XLEN-3:0], 2'b00};
  assign vs_vec_offset = {vs_trap_cause[XLEN-3:0], 2'b00};
  assign csr_bcast.tvec = trap_to_vs
    ? (final_is_int && (vstvec_mode == `RAPT_TVEC_MODE_VECTORED)
        ? (vstvec_base + vs_vec_offset) : vstvec_base)
    : trap_to_s
    ? (final_is_int && (stvec_mode == `RAPT_TVEC_MODE_VECTORED)
        ? (stvec_base + vec_offset) : stvec_base)
    : (final_is_int && (mtvec_mode == `RAPT_TVEC_MODE_VECTORED)
        ? (mtvec_base + vec_offset) : mtvec_base);

  // Interrupt eligibility (RISC-V priv spec 1.12 Sec.3.1.9):
  //   An M-mode interrupt i is taken iff mip[i] && mie[i] && !mideleg[i]
  //   AND (priv < M) OR (priv == M && mstatus.MIE).
  //   M-timer/M-sw are NOT delegatable (WARL 0 in mideleg), so the
  //   source-level is always M.
  // CLINT drives only MTIP/MSIP (no S-timer source); we gate them here.
  logic m_int_mask;
  assign m_int_mask = (priv_mode != `RAPT_PRIV_M)
                   || (priv_mode == `RAPT_PRIV_M
                       && csr[MSTATUS][`RAPT_CSR_MSTATUS_MIE_]);
  assign csr_bcast.timer_int_en = m_int_mask && csr[MIE____][`RAPT_CSR_MIE_MTIE];
  assign csr_bcast.sw_int_en    = m_int_mask && csr[MIE____][`RAPT_CSR_MIE_MSIE];
  assign csr_bcast.ext_int_en   = m_int_mask && csr[MIE____][`RAPT_CSR_MIE_MEIE];

  assign csr_bcast.bus_error_int = bus_error_pending && m_int_mask
      && csr[MIE____][`RAPT_BUS_ERROR_IRQ];

  assign mip_eff = (csr[MIP____]
                    & ~((XLEN'(1) << `RAPT_CSR_MIE_MSIE)
                      | (XLEN'(1) << `RAPT_CSR_MIE_MTIE)
                      | (XLEN'(1) << `RAPT_CSR_MIE_MEIE)
                      | (sstc_en ? (XLEN'(1) << `RAPT_CSR_MIE_STIE) : XLEN'(0))
                      | VirtIrqMask))
                 | ({{(XLEN-1){1'b0}}, sw_irq_i} << `RAPT_CSR_MIE_MSIE)
                 | ({{(XLEN-1){1'b0}}, timer_irq_i} << `RAPT_CSR_MIE_MTIE)
                 | ({{(XLEN-1){1'b0}}, stime_irq} << `RAPT_CSR_MIE_STIE)
                 | ({{(XLEN-1){1'b0}}, m_ext_irq_i} << `RAPT_CSR_MIE_MEIE)
                 | ({{(XLEN-1){1'b0}}, s_ext_irq_i} << `RAPT_CSR_MIE_SEIE)
                 | (HypEn64 ? ((hvip_q & VirtIrqMask)
                     | (XLEN'(vstime_irq) << `RAPT_CSR_MIE_VSTIE)) : '0)
                 | (XLEN'(bus_error_pending) << `RAPT_BUS_ERROR_IRQ);
`ifdef RAPT_ZAWRS
  // WRS resumes on an individually enabled pending interrupt (mip & mie != 0).
  assign csr_bcast.wrs_irq_pending = |(mip_eff & csr[MIE____]);
`else
  assign csr_bcast.wrs_irq_pending = 1'b0;
`endif

  // ----- S-level interrupt source evaluation (Priv Sec.3.1.9, H Sec.9.2) ----
  // SEI/SSI/STI/LCOFI and the VS-level sources trap to the mode selected by
  // mideleg and hideleg:
  //   * mideleg[i]=0: M-mode target, gated like MEI/MSI/MTI by m_int_mask.
  //   * mideleg[i]=1, hideleg[i]=0: HS-mode target. Taken iff mip[i] && mie[i]
  //     && ((priv<S) || V=1 || (HS-mode && sstatus.SIE)). M-mode is never
  //     preempted by an S-mode target.
  //   * mideleg[i]=1, hideleg[i]=1 (VS sources only): VS-mode target, taken
  //     only while V=1 and (VU-mode || vsstatus.SIE).
  // M targets win over HS targets, which win over VS targets; within a target
  // the order is SEI > SSI > STI > VSEI > VSSI > VSTI > LCOFI. ROU ranks the
  // bus-error, MEI, MSI and MTI sources above this cause. The trap router
  // consults mideleg/hideleg[cause] to pick the handler.
  // Note: with sstc absent, OpenSBI manually sets mip.STIP from M-mode to
  // signal pending S-timer; mip.STIP/SSIP remain software-writable.
  localparam logic [XLEN-1:0] SLevelIrqMask = (XLEN'(1) << `RAPT_CSR_MIE_SEIE)
                                            | (XLEN'(1) << `RAPT_CSR_MIE_SSIE)
                                            | (XLEN'(1) << `RAPT_CSR_MIE_STIE)
                                            | SscofpmfIrqMask
                                            | VirtIrqMask;
  logic s_int_global_en, vs_int_global_en;
  logic [XLEN-1:0] s_int_enabled;
  logic [XLEN-1:0] s_int_to_m;
  logic [XLEN-1:0] s_int_to_s;
  logic [XLEN-1:0] s_int_to_vs;
  logic [XLEN-1:0] s_int_active;
  assign s_int_global_en = (HypEn64 && virt_q)
      || (priv_mode == `RAPT_PRIV_U)
      || ((priv_mode == `RAPT_PRIV_S) && csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_]);
  assign vs_int_global_en = HypEn64 && virt_q && (
      (priv_mode == `RAPT_PRIV_U)
      || ((priv_mode == `RAPT_PRIV_S) && vsstatus_q[`RAPT_CSR_MSTATUS_SIE_]));
  assign s_int_enabled = mip_eff & csr[MIE____] & SLevelIrqMask;
  assign s_int_to_m = s_int_enabled & ~csr[MIDELEG] & {XLEN{m_int_mask}};
  assign s_int_to_s = s_int_enabled & csr[MIDELEG]
      & ~(HypEn64 ? (hideleg_q & VirtIrqMask) : '0) & {XLEN{s_int_global_en}};
  assign s_int_to_vs = HypEn64
      ? (s_int_enabled & csr[MIDELEG] & hideleg_q & VirtIrqMask & {XLEN{vs_int_global_en}})
      : '0;
  assign s_int_active = (|s_int_to_m) ? s_int_to_m : (|s_int_to_s) ? s_int_to_s : s_int_to_vs;
  assign s_int_pending = |s_int_active;
  assign s_int_cause = (XLEN'(1) << (XLEN-1)) | (
      s_int_active[`RAPT_CSR_MIE_SEIE]  ? XLEN'(`RAPT_CAUSE_SEI)
    : s_int_active[`RAPT_CSR_MIE_SSIE]  ? XLEN'(`RAPT_CAUSE_SSI)
    : s_int_active[`RAPT_CSR_MIE_STIE]  ? XLEN'(`RAPT_CAUSE_STI)
    : s_int_active[`RAPT_CSR_MIE_VSEIE] ? XLEN'(`RAPT_CAUSE_VSEI)
    : s_int_active[`RAPT_CSR_MIE_VSSIE] ? XLEN'(`RAPT_CAUSE_VSSI)
    : s_int_active[`RAPT_CSR_MIE_VSTIE] ? XLEN'(`RAPT_CAUSE_VSTI)
    :                                     XLEN'(`RAPT_CAUSE_LCOFI)
  );
`ifdef RAPT_SVA_ACTIVE
  // The selected cause must be one of the active sources, and its mideleg bit
  // must agree with the chosen target: an M-mode target always wins, and an
  // S-mode target is never taken while running in M-mode.
  logic [$clog2(XLEN)-1:0] s_int_cause_bit;
  logic s_int_cause_active, s_int_cause_deleg;
  assign s_int_cause_bit = s_int_cause[$clog2(XLEN)-1:0];
  assign s_int_cause_active = s_int_active[s_int_cause_bit];
  assign s_int_cause_deleg = csr[MIDELEG][s_int_cause_bit];
`endif
  `RAPT_SVA_IMPLY(clock, reset, CSR_S_INT_CAUSE_ACTIVE, s_int_pending, s_int_cause_active)
  `RAPT_SVA_IMPLY(clock, reset, CSR_S_INT_M_TARGET_FIRST, |s_int_to_m, !s_int_cause_deleg)
  `RAPT_SVA_IMPLY(clock, reset, CSR_S_INT_S_TARGET_BELOW_M, s_int_pending && s_int_cause_deleg,
                  priv_mode != `RAPT_PRIV_M)

  // MPRV / MPP broadcast (consumed by L1D effective-privilege logic)
  assign csr_bcast.mprv = csr[MSTATUS][`RAPT_CSR_MSTATUS_MPRV];
  assign csr_bcast.mpp  = csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_];

  // mstatus privileged guard bits for illegal-inst checks.
  assign csr_bcast.tsr        = csr[MSTATUS][`RAPT_CSR_MSTATUS_TSR_];
  assign csr_bcast.tvm        = csr[MSTATUS][`RAPT_CSR_MSTATUS_TVM_];
  assign csr_bcast.tw         = csr[MSTATUS][`RAPT_CSR_MSTATUS_TW__];
  assign csr_bcast.mcounteren = csr[MCOUNTE][3:0];
  assign csr_bcast.scounteren = csr[SCOUNTE][3:0];
  assign csr_bcast.menvcfg_cbie = csr[MENVCFG][5:4];
  assign csr_bcast.menvcfg_cbcfe = csr[MENVCFG][6];
  assign csr_bcast.menvcfg_cbze = csr[MENVCFG][7];
  assign csr_bcast.menvcfg_stce = sstc_en;
`ifdef RAPT_RV64
  assign csr_bcast.menvcfg_pbmte = csr[MENVCFG][62];
`else
  // Sv32 has no PBMT field.
  assign csr_bcast.menvcfg_pbmte = 1'b0;
`endif
  assign csr_bcast.senvcfg_cbie = csr[SENVCFG][5:4];
  assign csr_bcast.senvcfg_cbcfe = csr[SENVCFG][6];
  assign csr_bcast.senvcfg_cbze = csr[SENVCFG][7];
  assign csr_bcast.sum        = csr[MSTATUS][`RAPT_CSR_MSTATUS_SUM_];
  assign csr_bcast.mxr        = csr[MSTATUS][`RAPT_CSR_MSTATUS_MXR_];
  assign csr_bcast.sbe        = csr[MSTATUSH][`RAPT_CSR_MSTATUSH_SBE];
  assign csr_bcast.frm        = csr[FCSR][7:5];
  assign csr_bcast.fs         = (HypEn64 && virt_q && vsstatus_q[14:13] == 2'b00)
      ? 2'b00 : csr[MSTATUS][14:13];
`ifdef RAPT_V_EXTENSION
  assign csr_bcast.vs = (HypEn64 && virt_q && vsstatus_q[10:9] == 2'b00)
      ? 2'b00 : csr[MSTATUS][10:9];
`else
  assign csr_bcast.vs = 2'b00;
`endif
  /* verilator lint_off UNUSEDSIGNAL */
  wire [63:0] hstatus64 = 64'(hstatus_q);
  wire [63:0] henvcfg64 = 64'(henvcfg_eff);
  wire [63:0] vsatp64 = 64'(vsatp_q);
  wire [63:0] hgatp64 = 64'(hgatp_q);
  /* verilator lint_on UNUSEDSIGNAL */
  assign csr_bcast.virt = HypEn64 && virt_q;
  assign csr_bcast.mpv = HypEn64 && mstatus64[39];
  assign csr_bcast.hstatus_vtvm = HypEn64 && hstatus64[20];
  assign csr_bcast.hstatus_vtw = HypEn64 && hstatus64[21];
  assign csr_bcast.hstatus_vtsr = HypEn64 && hstatus64[22];
  assign csr_bcast.hstatus_hu = HypEn64 && hstatus64[9];
  assign csr_bcast.hstatus_spvp = HypEn64 && hstatus64[8];
  assign csr_bcast.hstatus_hupmm = HypEn64 ? hstatus64[49:48] : 2'b00;
  assign csr_bcast.vs_sum = HypEn64 && vsstatus_q[18];
  assign csr_bcast.vs_mxr = HypEn64 && vsstatus_q[19];
  assign csr_bcast.henvcfg_stce = HypEn64 && henvcfg64[63];
  assign csr_bcast.henvcfg_pbmte = HypEn64 && henvcfg64[62];
  assign csr_bcast.henvcfg_cbie = HypEn64 ? henvcfg64[5:4] : 2'b00;
  assign csr_bcast.henvcfg_cbcfe = HypEn64 && henvcfg64[6];
  assign csr_bcast.henvcfg_cbze = HypEn64 && henvcfg64[7];
  assign csr_bcast.henvcfg_pmm = HypEn64 ? henvcfg64[33:32] : 2'b00;
  assign csr_bcast.hcounteren = HypEn64 ? hcounteren_q : 4'b0000;
  assign csr_bcast.hstateen_se0 = (HypEn64 && rapt_pkg::SmstateenEnable)
      ? (hstateen_se0_q & mstateen_se0_q) : 4'hf;
  assign csr_bcast.hstateen0_envcfg = (HypEn64 && rapt_pkg::SmstateenEnable)
      ? (hstateen0_envcfg_q & mstateen0_envcfg_q) : 1'b1;
  assign csr_bcast.vsatp_ppn = HypEn64 ? vsatp64[`RAPT_CSR_SATP_PPN_W-1:0] : '0;
  assign csr_bcast.vsatp_asid = HypEn64 ? vsatp64[`RAPT_CSR_SATP_ASID_LSB +: 9] : '0;
  assign csr_bcast.vsatp_en = vsatp_en;
  assign csr_bcast.hgatp_ppn = HypEn64 ? hgatp64[`RAPT_CSR_SATP_PPN_W-1:0] : '0;
  assign csr_bcast.hgatp_en = hgatp_en;
  assign csr_bcast.eff_data_guest = eff_data_guest;
  assign csr_bcast.hgatp_flush = HypEn64 && !reset && rou_csr.valid && rou_csr.csr_wen
      && (eff_waddr == `RAPT_CSR_HGATP || eff_waddr == `RAPT_CSR_MENVCFG
          || eff_waddr == `RAPT_CSR_HENVCFG);

  // Incremental PMP update command. Consumers keep local decoded state; only
  // accepted writes toggle this core-wide bus.
  always_comb begin
    automatic int cfg_base;
    automatic int cfg_count;
    automatic logic cfg_write;
    automatic logic [3:0] pidx;
    automatic logic addr_locked;

    pmp_update.addr_we    = 1'b0;
    pmp_update.addr_idx   = '0;
    pmp_update.raw_addr   = '0;
    pmp_update.napot_mask = '0;
    pmp_update.cfg_we     = '0;
    pmp_update.cfg_r      = '0;
    pmp_update.cfg_w      = '0;
    pmp_update.cfg_x      = '0;
    pmp_update.cfg_l      = '0;
    pmp_update.mode_off   = '0;
    pmp_update.mode_tor   = '0;
    pmp_update.mode_na4   = '0;
    pmp_update.mode_napot = '0;

    cfg_base  = 0;
    cfg_count = 0;
    cfg_write = 1'b0;
    unique case (rou_csr.csr_addr)
      `RAPT_CSR_PMPCFG0: begin
        cfg_write = 1'b1;
        cfg_count = (XLEN == 64) ? 8 : 4;
      end
      `RAPT_CSR_PMPCFG1: begin
        cfg_write = (XLEN == 32);
        cfg_base  = 4;
        cfg_count = 4;
      end
      `RAPT_CSR_PMPCFG2: begin
        cfg_write = 1'b1;
        cfg_base  = 8;
        cfg_count = (XLEN == 64) ? 8 : 4;
      end
      `RAPT_CSR_PMPCFG3: begin
        cfg_write = (XLEN == 32);
        cfg_base  = 12;
        cfg_count = 4;
      end
      default: begin
      end
    endcase

    if (rou_csr.valid && rou_csr.csr_wen && cfg_write) begin
      for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
        if (i >= cfg_base && i < cfg_base + cfg_count && !pmpcfg_r[i][`RAPT_PMPCFG_L_]) begin
          pmp_update.cfg_we[i]      = 1'b1;
          pmp_update.cfg_r[i]       = pmpcfg_legal_wdata[(i-cfg_base)*8 + `RAPT_PMPCFG_R_];
          pmp_update.cfg_w[i]       = pmpcfg_legal_wdata[(i-cfg_base)*8 + `RAPT_PMPCFG_W_];
          pmp_update.cfg_x[i]       = pmpcfg_legal_wdata[(i-cfg_base)*8 + `RAPT_PMPCFG_X_];
          pmp_update.cfg_l[i]       = pmpcfg_legal_wdata[(i-cfg_base)*8 + `RAPT_PMPCFG_L_];
          pmp_update.mode_off[i]    = (pmpcfg_legal_wdata[(i-cfg_base)*8 + 3 +: 2]
                                       == `RAPT_PMP_A_OFF);
          pmp_update.mode_tor[i]    = (pmpcfg_legal_wdata[(i-cfg_base)*8 + 3 +: 2]
                                       == `RAPT_PMP_A_TOR);
          pmp_update.mode_na4[i]    = (pmpcfg_legal_wdata[(i-cfg_base)*8 + 3 +: 2]
                                       == `RAPT_PMP_A_NA4);
          pmp_update.mode_napot[i]  = (pmpcfg_legal_wdata[(i-cfg_base)*8 + 3 +: 2]
                                       == `RAPT_PMP_A_NAPOT);
        end
      end
    end

    pidx = rou_csr.csr_addr[3:0];
    addr_locked = pmp_addr_locked(pidx);
    if (rou_csr.valid && rou_csr.csr_wen
      && rou_csr.csr_addr >= PMPAddrBase
      && rou_csr.csr_addr <= PMPAddrLast
      && int'(pidx) <
        `RAPT_PMP_NUM
        && !addr_locked) begin
      pmp_update.addr_we    = 1'b1;
      pmp_update.addr_idx   = PMPIndexW'(pidx);
      pmp_update.raw_addr   = rou_csr.csr_wdata[PMPCheckAddrW-1:0];
      // Predecode the NAPOT interpretation even while OFF/TOR is selected.
      // A later mode-only write can then reuse the preserved address state.
      pmp_update.napot_mask = (pmp_update.raw_addr | PMPCheckAddrW'(PMPNapotLow))
          ^ ((pmp_update.raw_addr | PMPCheckAddrW'(PMPNapotLow)) + PMPCheckAddrW'(1));
    end
    // Even an ignored (locked or unimplemented) PMP write invalidates cached
    // data-access verdicts. Refresh entry zero unchanged to carry that event
    // over the existing update interface without weakening its lock semantics.
    if (rou_csr.valid && rou_csr.csr_wen && !pmp_update.addr_we && !(|pmp_update.cfg_we)
        && ((rou_csr.csr_addr >= `RAPT_CSR_PMPCFG0 && rou_csr.csr_addr <= `RAPT_CSR_PMPCFG3)
            || (rou_csr.csr_addr >= PMPAddrBase && rou_csr.csr_addr <= PMPAddrLast))) begin
      pmp_update.cfg_we[0] = 1'b1;
      pmp_update.cfg_r[0] = pmpcfg_r[0][`RAPT_PMPCFG_R_];
      pmp_update.cfg_w[0] = pmpcfg_r[0][`RAPT_PMPCFG_W_];
      pmp_update.cfg_x[0] = pmpcfg_r[0][`RAPT_PMPCFG_X_];
      pmp_update.cfg_l[0] = pmpcfg_r[0][`RAPT_PMPCFG_L_];
      pmp_update.mode_off[0] = pmpcfg_r[0][4:3] == `RAPT_PMP_A_OFF;
      pmp_update.mode_tor[0] = pmpcfg_r[0][4:3] == `RAPT_PMP_A_TOR;
      pmp_update.mode_na4[0] = pmpcfg_r[0][4:3] == `RAPT_PMP_A_NA4;
      pmp_update.mode_napot[0] = pmpcfg_r[0][4:3] == `RAPT_PMP_A_NAPOT;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      priv_mode <= `RAPT_PRIV_M;
      virt_q <= 1'b0;
      csr_state[MCAUSE_] <= RESET_VAL;
      mepc_half_q <= RESET_VAL[XLEN-1:1];
      csr_state[MTVEC__] <= RESET_VAL;
      csr_state[MSTATUS] <= RESET_VAL | `RAPT_CSR_MSTATUS_HW;
      csr_state[FCSR] <= '0;
      csr_state[SIE____] <= '0;
      csr_state[STVEC__] <= '0;
      csr_state[SSCRATC] <= '0;
      sepc_half_q <= '0;
      csr_state[SCAUSE_] <= '0;
      csr_state[STVAL__] <= '0;
      csr_state[SIP____] <= '0;
      csr_state[SATP___] <= '0;
      csr_state[MEDELEG] <= '0;
      csr_state[MIE____] <= '0;
      csr_state[MSCRATCH] <= '0;
      csr_state[MTVAL__] <= '0;
      csr_state[MIP____] <= '0;
      csr_state[MCYCLE_] <= RESET_VAL;
      csr_state[MCYCLEH] <= RESET_VAL;
      csr_state[MINSTRET] <= RESET_VAL;
      csr_state[MINSTRETH] <= RESET_VAL;
      csr_state[MSTATUSH] <= '0;
      csr_state[MENVCFG] <= '0;
      csr_state[MENVCFGH] <= '0;
      csr_state[MCOUNTE] <= '0;
      csr_state[SCOUNTE] <= '0;
      csr_state[SENVCFG] <= '0;
      csr_state[MIDELEG] <= VirtIrqMask;
      mhpmcounter3_q <= '0;
      mhpmevent3_of_q <= 1'b0;
      mhpmevent3_inh_q <= '0;
      mhpmevent3_sel_q <= '0;
      mstateen_se0_q <= '0;
      mstateen0_envcfg_q <= 1'b0;
      hstatus_q <= HypEn64 ? (XLEN'(2) << 32) : '0;
      hedeleg_q <= '0;
      hideleg_q <= '0;
      hvip_q <= '0;
      htimedelta_q <= '0;
      hcounteren_q <= '0;
      henvcfg_q <= '0;
      hstateen_se0_q <= '0;
      hstateen0_envcfg_q <= 1'b0;
      htval_q <= '0;
      htinst_q <= '0;
      hgatp_q <= '0;
      mtinst_q <= '0;
      mtval2_q <= '0;
      vsstatus_q <= HypEn64 ? (XLEN'(2) << 32) : '0;
      vstvec_q <= '0;
      vsscratch_q <= '0;
      vsepc_half_q <= '0;
      vscause_q <= '0;
      vstval_q <= '0;
      vsatp_q <= '0;
      vstimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF;
      stimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      for (int i = 0; i < `RAPT_PMP_NUM; i++) begin
        pmpcfg_r[i]  <= '0;
        pmpaddr_r[i] <= '0;
      end
    end else begin
`ifdef RAPT_V_EXTENSION
      if (vector_dirty_i || vector_fp_dirty_i) begin
        csr_state[MSTATUS] <= csr[MSTATUS] |
        `RAPT_CSR_MSTATUS_SD
        | (vector_dirty_i ? VectorStatusMask : XLEN'(0)) |
            (vector_fp_dirty_i ? (XLEN'(3) << 13) : XLEN'(0));
        if (HypEn64 && virt_q) begin
          vsstatus_q <= vsstatus_q |
          `RAPT_CSR_MSTATUS_SD
          | (vector_dirty_i ? VectorStatusMask : XLEN'(0)) |
              (vector_fp_dirty_i ? (XLEN'(3) << 13) : XLEN'(0));
        end
      end
`endif
      csr_state[MCYCLE_] <= csr[MCYCLE_] + 1;
      if (csr[MCYCLE_] == '1 && !(rou_csr.valid && rou_csr.csr_wen && waddr_reg == MCYCLE_)) begin
        csr_state[MCYCLEH] <= csr[MCYCLEH] + 1;
      end
      csr_state[MINSTRET] <= csr[MINSTRET] + XLEN'(rou_csr.retire_count);
      if (csr[MINSTRET] + XLEN'(rou_csr.retire_count) < csr[MINSTRET]
          && !(rou_csr.valid && rou_csr.csr_wen && waddr_reg == MINSTRET)) begin
        csr_state[MINSTRETH] <= csr[MINSTRETH] + 1;
      end
      if (hpm3_inc) begin
        mhpmcounter3_q <= mhpmcounter3_q + 64'd1;
        if (&mhpmcounter3_q && !mhpmevent3_of_q) begin
          mhpmevent3_of_q <= 1'b1;
          csr_state[MIP____][`RAPT_CSR_MIE_LCOFIE] <= 1'b1;
        end
      end
      if (rou_csr.valid) begin
        if (rapt_pkg::FpuEnable && rou_csr.fp_dirty) begin
          csr_state[MSTATUS] <= csr[MSTATUS] | `RAPT_CSR_MSTATUS_SD | (XLEN'(3) << 13);
          if (HypEn64 && virt_q) vsstatus_q <= vsstatus_q | `RAPT_CSR_MSTATUS_SD | (XLEN'(3) << 13);
        end
        if (rou_csr.fp_flags_valid) begin
          csr_state[FCSR][4:0] <= csr[FCSR][4:0] | rou_csr.fp_flags;
        end
        if (rou_csr.csr_wen) begin
          if (rapt_pkg::FpuEnable
              && (waddr_reg == FFLAGS || waddr_reg == FRM || waddr_reg == FCSR)) begin
            csr_state[MSTATUS] <= csr[MSTATUS] | `RAPT_CSR_MSTATUS_SD | (XLEN'(3) << 13);
            if (HypEn64 && virt_q)
              vsstatus_q <= vsstatus_q | `RAPT_CSR_MSTATUS_SD | (XLEN'(3) << 13);
          end
          if (eff_waddr == `RAPT_CSR_MBERR_STATUS) begin
            // No generic CSR storage write for platform W1C status.
          end else if (waddr_reg == FFLAGS) begin
            csr_state[FCSR][4:0] <= rou_csr.csr_wdata[4:0];
          end else if (waddr_reg == FRM) begin
            csr_state[FCSR][7:5] <= rou_csr.csr_wdata[2:0];
          end else if (waddr_reg == FCSR) begin
            csr_state[FCSR][7:0] <= rou_csr.csr_wdata[7:0];
          end else if (eff_waddr == `RAPT_CSR_PMPCFG0) begin
            // pmpcfg0: RV32 packs entries 0..3 (4 bytes); RV64 packs entries 0..7 (8 bytes).
            // L-bit locked cfgs ignore further writes (until reset).
            for (int pi = 0; pi < (XLEN == 64 ? 8 : 4); pi++) begin
              if (pi < `RAPT_PMP_NUM && !pmpcfg_r[pi][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi] <= legalize_pmpcfg(rou_csr.csr_wdata[pi*8+:8]);
              end
            end
          end else if (eff_waddr == `RAPT_CSR_PMPCFG1 && XLEN == 32) begin
            for (int pi = 0; pi < 4; pi++) begin
              if (pi + 4 < `RAPT_PMP_NUM && !pmpcfg_r[pi+4][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi+4] <= legalize_pmpcfg(rou_csr.csr_wdata[pi*8+:8]);
              end
            end
          end else if (eff_waddr == `RAPT_CSR_PMPCFG2) begin
            for (int pi = 0; pi < (XLEN == 64 ? 8 : 4); pi++) begin
              if (pi + 8 < `RAPT_PMP_NUM && !pmpcfg_r[pi+8][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi+8] <= legalize_pmpcfg(rou_csr.csr_wdata[pi*8+:8]);
              end
            end
          end else if (eff_waddr == `RAPT_CSR_PMPCFG3 && XLEN == 32) begin
            for (int pi = 0; pi < 4; pi++) begin
              if (pi + 12 < `RAPT_PMP_NUM && !pmpcfg_r[pi+12][`RAPT_PMPCFG_L_]) begin
                pmpcfg_r[pi+12] <= legalize_pmpcfg(rou_csr.csr_wdata[pi*8+:8]);
              end
            end
          end else if (eff_waddr >= PMPAddrBase && eff_waddr <= PMPAddrLast) begin
            // pmpaddr[i] writable unless entry i is locked OR the next entry
            // is locked AND its A-mode is TOR (entry i then forms TOR's lower bound).
            automatic logic [3:0] pidx = eff_waddr[3:0];
            for (int pi = 0; pi < `RAPT_PMP_NUM; pi++) begin
              if (pidx == 4'(pi) && !pmp_addr_locked(pidx)) begin
                pmpaddr_r[pi] <= rou_csr.csr_wdata[PMPAddrW-1:0];
              end
            end
          end else if (rapt_pkg::SscofpmfEnable && eff_waddr == `RAPT_CSR_MHPMCOUNTER3) begin
            if (XLEN == 64) mhpmcounter3_q <= wdata64;
            else mhpmcounter3_q[31:0] <= rou_csr.csr_wdata[31:0];
          end else if (rapt_pkg::SscofpmfEnable && XLEN == 32
              && eff_waddr == `RAPT_CSR_MHPMCOUNTER3H) begin
            mhpmcounter3_q[63:32] <= rou_csr.csr_wdata[31:0];
          end else if (rapt_pkg::SscofpmfEnable && eff_waddr == `RAPT_CSR_MHPMEVENT3) begin
            mhpmevent3_sel_q <= rou_csr.csr_wdata[7:0];
            if (XLEN == 64) begin
              mhpmevent3_of_q <= wdata64[63];
              mhpmevent3_inh_q <= wdata64[62:58] & HpmEvent3InhMask;
            end
          end else if (rapt_pkg::SscofpmfEnable && XLEN == 32
              && eff_waddr == `RAPT_CSR_MHPMEVENT3H) begin
            mhpmevent3_of_q <= rou_csr.csr_wdata[31];
            mhpmevent3_inh_q <= rou_csr.csr_wdata[30:26] & HpmEvent3InhMask;
          end else if (rapt_pkg::SmstateenEnable && XLEN == 64 && eff_waddr >=
              `RAPT_CSR_MSTATEEN0
              && eff_waddr <= `RAPT_CSR_MSTATEEN3) begin
            mstateen_se0_q[eff_waddr[1:0]] <= wdata64[63];
            if (eff_waddr[1:0] == 2'd0) mstateen0_envcfg_q <= wdata64[62];
            // hstateen bits are read-only zero while the matching mstateen bit
            // is clear; drop them so re-enabling mstateen exposes zero.
            if (HypEn64) begin
              hstateen_se0_q[eff_waddr[1:0]] <= hstateen_se0_q[eff_waddr[1:0]] & wdata64[63];
              if (eff_waddr[1:0] == 2'd0) hstateen0_envcfg_q <= hstateen0_envcfg_q & wdata64[62];
            end
          end else if (rapt_pkg::SmstateenEnable && XLEN == 32 && eff_waddr >=
              `RAPT_CSR_MSTATEEN0H
              && eff_waddr <= `RAPT_CSR_MSTATEEN3H) begin
            mstateen_se0_q[eff_waddr[1:0]] <= rou_csr.csr_wdata[31];
            if (eff_waddr[1:0] == 2'd0) mstateen0_envcfg_q <= rou_csr.csr_wdata[30];
          end else if (HypEn64 && rapt_pkg::SmstateenEnable && eff_waddr >=
              `RAPT_CSR_HSTATEEN0
              && eff_waddr <= `RAPT_CSR_HSTATEEN3) begin
            hstateen_se0_q[eff_waddr[1:0]] <= wdata64[63] & mstateen_se0_q[eff_waddr[1:0]];
            if (eff_waddr[1:0] == 2'd0) hstateen0_envcfg_q <= wdata64[62] & mstateen0_envcfg_q;
          end else if (HypEn64 && (eff_waddr[11:8] == 4'h2 || eff_waddr[11:8] == 4'h6
              || eff_waddr == `RAPT_CSR_MTINST || eff_waddr == `RAPT_CSR_MTVAL2)) begin
            case (eff_waddr)
              `RAPT_CSR_VSSTATUS: vsstatus_q <= vsstatus_write;
              `RAPT_CSR_VSIE_____:
                csr_state[MIE____] <= (csr[MIE____] & ~(VirtIrqMask & hideleg_q))
                    | ((rou_csr.csr_wdata << 1) & VirtIrqMask & hideleg_q);
              `RAPT_CSR_VSTVEC___:
                vstvec_q <= {
                  rou_csr.csr_wdata[XLEN-1:2],
                  rou_csr.csr_wdata[1] ? 2'b00 : rou_csr.csr_wdata[1:0]
                };
              `RAPT_CSR_VSSCRATCH: vsscratch_q <= rou_csr.csr_wdata;
              `RAPT_CSR_VSEPC____: vsepc_half_q <= rou_csr.csr_wdata[XLEN-1:1];
              `RAPT_CSR_VSCAUSE__: vscause_q <= rou_csr.csr_wdata;
              `RAPT_CSR_VSTVAL___: vstval_q <= rou_csr.csr_wdata;
              `RAPT_CSR_VSIP_____:
                hvip_q <= (hvip_q & ~(hideleg_q & XLEN'(12'h004)))
                    | ((rou_csr.csr_wdata << 1) & hideleg_q & XLEN'(12'h004));
              `RAPT_CSR_VSTIMECMP: vstimecmp_q <= wdata64;
              `RAPT_CSR_VSATP____: begin
                if (wdata64[63:60] == 4'd0 || wdata64[63:60] == 4'd8)
                  vsatp_q <= XLEN'({wdata64[63:60], 7'b0, wdata64[52:0]});
              end
              `RAPT_CSR_MTINST:     mtinst_q <= rou_csr.csr_wdata;
              `RAPT_CSR_MTVAL2:     mtval2_q <= rou_csr.csr_wdata;
              `RAPT_CSR_HSTATUS:    hstatus_q <= hstatus_write;
              `RAPT_CSR_HEDELEG:    hedeleg_q <= rou_csr.csr_wdata & XLEN'(24'h0c_b1fe);
              `RAPT_CSR_HIDELEG:    hideleg_q <= rou_csr.csr_wdata & VirtIrqMask;
              `RAPT_CSR_HIE____:
                csr_state[MIE____] <= (csr[MIE____] & ~VirtIrqMask)
                    | (rou_csr.csr_wdata & VirtIrqMask);
              `RAPT_CSR_HTIMEDELTA: htimedelta_q <= rou_csr.csr_wdata;
              `RAPT_CSR_HCOUNTEREN: hcounteren_q <= rou_csr.csr_wdata[3:0] & CounterenWmask[3:0];
              `RAPT_CSR_HENVCFG:    henvcfg_q <= henvcfg_write;
              `RAPT_CSR_HTVAL:      htval_q <= rou_csr.csr_wdata;
              `RAPT_CSR_HIP____:
                hvip_q <= (hvip_q & ~XLEN'(12'h004)) | (rou_csr.csr_wdata & XLEN'(12'h004));
              `RAPT_CSR_HVIP___:    hvip_q <= rou_csr.csr_wdata & VirtIrqMask;
              `RAPT_CSR_HTINST:     htinst_q <= rou_csr.csr_wdata;
              `RAPT_CSR_HGATP:
                hgatp_q <= wdata64[63:60] == 4'd8
                    ? XLEN'((64'd8 << 60) | (wdata64 & 64'h0000_0fff_ffff_fffc)) : '0;
              default: begin
              end
            endcase
          end else if (waddr_reg == MEDELEG) begin
            csr_state[MEDELEG] <= rou_csr.csr_wdata & MedelegWmask;
          end else if (waddr_reg == MIDELEG) begin
            // SSI/STI/SEI (and LCOFI with Sscofpmf) are delegatable; the VS
            // interrupt bits are read-only one with H.
            csr_state[MIDELEG] <= (rou_csr.csr_wdata & MidelegWmask) | VirtIrqMask;
          end else if (waddr_reg == MIE____) begin
            csr_state[MIE____] <= rou_csr.csr_wdata & MieWmask;
          end else if (waddr_reg == MCOUNTE || waddr_reg == SCOUNTE) begin
            // CY/TM/IR (and HPM3 with Sscofpmf) are modeled; other bits WARL-zero.
            if (waddr_reg == MCOUNTE) csr_state[MCOUNTE] <= rou_csr.csr_wdata & CounterenWmask;
            else csr_state[SCOUNTE] <= rou_csr.csr_wdata & CounterenWmask;
          end else if (waddr_reg == SENVCFG) begin
            csr_state[SENVCFG] <= senvcfg_write;
          end else if (waddr_reg == MENVCFG) begin
            csr_state[MENVCFG] <= menvcfg_write;
            if (HypEn64) henvcfg_q <= henvcfg_q & (menvcfg_write | ~(XLEN'(3) << 62));
          end else if (waddr_reg == MENVCFGH) begin
            csr_state[MENVCFGH] <= rou_csr.csr_wdata & XLEN'(32'h8000_0000);
          end else if (waddr_reg == STIMECMP) begin
            if (XLEN == 64) begin
              stimecmp <= 64'(rou_csr.csr_wdata);
            end else begin
              stimecmp[31:0] <= rou_csr.csr_wdata[31:0];
            end
          end else if (waddr_reg == STIMECMPH) begin
            if (XLEN == 32) begin
              stimecmp[63:32] <= rou_csr.csr_wdata[31:0];
            end
          end else if (waddr_reg == MSTATUSH) begin
            // SBE/MBE are WARL-zero (little-endian only).
            csr_state[MSTATUSH] <= '0;
          end else if (waddr_reg == MSTATUS) begin
            csr_state[MSTATUS] <= mstatus_write;
          end else if (waddr_reg == SSTATUS) begin
            csr_state[MSTATUS] <= (csr[MSTATUS] & ~SupervisorStatusMask) | sstatus_write;
          end else if (waddr_reg == SIE____) begin
            // sie is a restricted view of mie; write only the SIE-visible bits.
            csr_state[MIE____] <= (csr[MIE____] & ~(csr[MIDELEG] & SieWmask))
                          | (rou_csr.csr_wdata & csr[MIDELEG] & SieWmask);
          end else if (waddr_reg == SIP____) begin
            // sip is a restricted view of mip; only SSIP (and LCOFIP) is writable.
            csr_state[MIP____] <= (csr[MIP____] & ~(csr[MIDELEG] & SipWmask))
                          | (rou_csr.csr_wdata & csr[MIDELEG] & SipWmask);
          end else if (waddr_reg == MIP____) begin
            csr_state[MIP____] <= (csr[MIP____] & ~mip_write_mask)
                | (rou_csr.csr_wdata & mip_write_mask);
            // mip.VSSIP aliases hvip.VSSIP.
            if (HypEn64)
              hvip_q <= (hvip_q & ~XLEN'(12'h004)) | (rou_csr.csr_wdata & XLEN'(12'h004));
          end else if (waddr_reg == MTVEC__ || waddr_reg == STVEC__) begin
            // WARL on MODE field [1:0]: only Direct(00) and Vectored(01) are
            // defined; reserved values (10/11) coerce to Direct(00).
            // BASE field [XLEN-1:2] is fully writable (must be 4-byte aligned).
            if (waddr_reg == MTVEC__) begin
              csr_state[MTVEC__] <= {
                rou_csr.csr_wdata[XLEN-1:2], rou_csr.csr_wdata[1] ? 2'b00 : rou_csr.csr_wdata[1:0]
              };
            end else begin
              csr_state[STVEC__] <= {
                rou_csr.csr_wdata[XLEN-1:2], rou_csr.csr_wdata[1] ? 2'b00 : rou_csr.csr_wdata[1:0]
              };
            end
          end else if (waddr_reg == MEPC___ || waddr_reg == SEPC___) begin
            // WARL: mepc/sepc bit [0] is always 0 per RISC-V priv spec.
            if (waddr_reg == MEPC___) mepc_half_q <= rou_csr.csr_wdata[XLEN-1:1];
            else sepc_half_q <= rou_csr.csr_wdata[XLEN-1:1];
          end else if (waddr_reg == SATP___) begin
            // WARL on satp.MODE (Priv Sec.10.6.1): a write with an unsupported
            // MODE has no effect. Linux probes Sv57/Sv48 by writing satp and
            // reading back MODE, so rejecting unsupported modes is required.
`ifdef RAPT_RV64
            // RV64 accepts Bare(0) or Sv39(8). ASID[15:9] are WARL-zero, so the
            // write/read probe reports ASIDLEN=9, matching the TLB interface.
            if (wdata64[63:60] == 4'd0 || wdata64[63:60] == 4'd8) begin
              csr_state[SATP___] <= XLEN'({wdata64[63:60], 7'b0, wdata64[52:0]});
            end
`else
            // RV32: MODE is bit [31]. Both 0 (Bare) and 1 (Sv32) are supported.
            csr_state[SATP___] <= rou_csr.csr_wdata;
`endif
          end else begin
            // Keep write destinations static so masked CSR bits remain constants.
            case (waddr_reg)
              SSCRATC: csr_state[SSCRATC] <= rou_csr.csr_wdata;
              SCAUSE_: csr_state[SCAUSE_] <= rou_csr.csr_wdata;
              STVAL__: csr_state[STVAL__] <= rou_csr.csr_wdata;
              MSCRATCH: csr_state[MSCRATCH] <= rou_csr.csr_wdata;
              MCAUSE_: csr_state[MCAUSE_] <= rou_csr.csr_wdata;
              MTVAL__: csr_state[MTVAL__] <= rou_csr.csr_wdata;
              MCYCLE_: csr_state[MCYCLE_] <= rou_csr.csr_wdata;
              MCYCLEH: csr_state[MCYCLEH] <= rou_csr.csr_wdata;
              MINSTRET: csr_state[MINSTRET] <= rou_csr.csr_wdata;
              MINSTRETH: csr_state[MINSTRETH] <= rou_csr.csr_wdata;
              default: csr_state[MNONE__] <= rou_csr.csr_wdata;
            endcase
          end
        end
        if (trap_enter) begin
          if (trap_to_vs) begin
            vsepc_half_q <= trap_epc[XLEN-1:1];
            vscause_q <= vs_trap_cause;
            vstval_q <= trap_tval;
            vsstatus_q[5] <= vsstatus_q[1];
            vsstatus_q[1] <= 1'b0;
            vsstatus_q[8] <= (priv_mode == `RAPT_PRIV_S);
            priv_mode <= `RAPT_PRIV_S;
            virt_q <= 1'b1;
          end else if (trap_to_s) begin
            sepc_half_q <= trap_epc[XLEN-1:1];
            csr_state[SCAUSE_] <= trap_cause;
            csr_state[STVAL__] <= trap_tval;
            csr_state[MSTATUS][`RAPT_CSR_MSTATUS_SPIE] <= csr[MSTATUS][`RAPT_CSR_MSTATUS_SIE_];
            csr_state[MSTATUS][`RAPT_CSR_MSTATUS_SIE_] <= 1'b0;
            csr_state[MSTATUS][`RAPT_CSR_MSTATUS_SPP_] <= (priv_mode == `RAPT_PRIV_S);
            if (HypEn64) begin
              htval_q <= is_guest_pf ? rou_csr.tval2 : '0;
              htinst_q <= is_guest_pf ? rou_csr.htinst : '0;
              hstatus_q[6] <= (virt_q && is_any_gva_cause) || rou_csr.explicit_guest_trap;
              hstatus_q[7] <= virt_q;
              if (virt_q) hstatus_q[8] <= (priv_mode == `RAPT_PRIV_S);
            end
            priv_mode <= `RAPT_PRIV_S;
            virt_q <= 1'b0;
          end else begin
            mepc_half_q <= trap_epc[XLEN-1:1];
            csr_state[MCAUSE_] <= trap_cause;
            csr_state[MTVAL__] <= trap_tval;
            csr_state[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] <= priv_mode;
            csr_state[MSTATUS][`RAPT_CSR_MSTATUS_MPIE] <= mstatus_mie;
            csr_state[MSTATUS][`RAPT_CSR_MSTATUS_MIE_] <= 1'b0;
            if (HypEn64) begin
              csr_state[MSTATUS][MpvBit] <= virt_q;
              csr_state[MSTATUS][GvaBit] <= (virt_q && is_any_gva_cause)
                  || (d_mprv_guest && is_data_gva_cause)
                  || rou_csr.explicit_guest_trap;
              mtval2_q <= is_guest_pf ? rou_csr.tval2 : '0;
              mtinst_q <= is_guest_pf ? rou_csr.htinst : '0;
            end
            priv_mode <= `RAPT_PRIV_M;
            virt_q <= 1'b0;
          end
        end else if (rou_csr.mret) begin
          priv_mode <= csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_];
          virt_q <= HypEn64 && (csr[MSTATUS][`RAPT_CSR_MSTATUS_MPP_] != `RAPT_PRIV_M)
              && mstatus64[39];
          csr_state[MSTATUS] <= mret_mstatus_next;
        end else if (rou_csr.sret) begin
          if (HypEn64 && virt_q) begin
            priv_mode <= vsstatus_q[8] ? `RAPT_PRIV_S : `RAPT_PRIV_U;
            virt_q <= 1'b1;
            vsstatus_q <= (vsstatus_q & ~XLEN'(12'h122))
                | (XLEN'(vsstatus_q[5]) << 1) | (XLEN'(1) << 5);
          end else begin
            priv_mode <= csr[MSTATUS][`RAPT_CSR_MSTATUS_SPP_] == 1'b1 ? `RAPT_PRIV_S : `RAPT_PRIV_U;
            virt_q <= HypEn64 && hstatus_q[7];
            if (HypEn64) hstatus_q[7] <= 1'b0;
            csr_state[MSTATUS] <= sret_mstatus_next;
          end
        end
      end

    end
  end

`ifndef SYNTHESIS
`ifdef USE_DPI_C
  logic [63:0] hypervisor_csr_view[34]  /* verilator public_flat_rd */;
  if (XLEN == 64) begin : g_hyp_observe
    assign hypervisor_csr_view[0]  = 64'(csr[MENVCFG]);
    assign hypervisor_csr_view[1]  = 64'(csr[SENVCFG]);
    for (genvar s_idx = 0; s_idx < 4; s_idx++) begin : g_mstateen_obs
      assign hypervisor_csr_view[2 + s_idx] = rapt_pkg::SmstateenEnable
          ? ((64'(mstateen_se0_q[s_idx]) << 63)
             | (s_idx == 0 ? (64'(mstateen0_envcfg_q) << 62) : 64'd0))
          : 64'd0;
      assign hypervisor_csr_view[13 + s_idx] = (HypEn64 && rapt_pkg::SmstateenEnable)
          ? ((64'(hstateen_se0_q[s_idx] & mstateen_se0_q[s_idx]) << 63)
             | (s_idx == 0 ? (64'(hstateen0_envcfg_q & mstateen0_envcfg_q) << 62) : 64'd0))
          : 64'd0;
    end
    assign hypervisor_csr_view[6]  = HypEn64 ? (64'(hstatus_q) | (64'd2 << 32)) : 64'd0;
    assign hypervisor_csr_view[7]  = HypEn64 ? 64'(hedeleg_q) : 64'd0;
    assign hypervisor_csr_view[8]  = HypEn64 ? 64'(hideleg_q) : 64'd0;
    assign hypervisor_csr_view[9]  = HypEn64 ? 64'(csr[MIE____] & VirtIrqMask) : 64'd0;
    assign hypervisor_csr_view[10] = HypEn64 ? 64'(htimedelta_q) : 64'd0;
    assign hypervisor_csr_view[11] = HypEn64 ? 64'(hcounteren_q) : 64'd0;
    assign hypervisor_csr_view[12] = HypEn64 ? 64'(henvcfg_eff) : 64'd0;
    assign hypervisor_csr_view[17] = HypEn64 ? 64'(htval_q) : 64'd0;
    assign hypervisor_csr_view[18] = HypEn64 ? 64'(mip_eff & VirtIrqMask) : 64'd0;
    assign hypervisor_csr_view[19] = HypEn64 ? 64'(hvip_q & VirtIrqMask) : 64'd0;
    assign hypervisor_csr_view[20] = HypEn64 ? 64'(htinst_q) : 64'd0;
    assign hypervisor_csr_view[21] = HypEn64 ? 64'(hgatp_q) : 64'd0;
    assign hypervisor_csr_view[22] = HypEn64 ? 64'(vsstatus_q) : 64'd0;
    assign hypervisor_csr_view[23] = HypEn64
        ? 64'((csr[MIE____] & hideleg_q & VirtIrqMask) >> 1) : 64'd0;
    assign hypervisor_csr_view[24] = HypEn64 ? 64'(vstvec_q) : 64'd0;
    assign hypervisor_csr_view[25] = HypEn64 ? 64'(vsscratch_q) : 64'd0;
    assign hypervisor_csr_view[26] = HypEn64 ? 64'(vsepc_value) : 64'd0;
    assign hypervisor_csr_view[27] = HypEn64 ? 64'(vscause_q) : 64'd0;
    assign hypervisor_csr_view[28] = HypEn64 ? 64'(vstval_q) : 64'd0;
    assign hypervisor_csr_view[29] = HypEn64
        ? 64'((mip_eff & hideleg_q & VirtIrqMask) >> 1) : 64'd0;
    assign hypervisor_csr_view[30] = HypEn64 ? vstimecmp_q : 64'd0;
    assign hypervisor_csr_view[31] = HypEn64 ? 64'(vsatp_q) : 64'd0;
    assign hypervisor_csr_view[32] = HypEn64 ? 64'(mtinst_q) : 64'd0;
    assign hypervisor_csr_view[33] = HypEn64 ? 64'(mtval2_q) : 64'd0;
  end else begin : g_no_hyp_observe
    for (genvar obs_idx = 0; obs_idx < 34; obs_idx++) begin : g_zero_obs
      assign hypervisor_csr_view[obs_idx] = 64'd0;
    end
  end
`endif
`endif

  // Difftest / external visibility shadows: keep sie/sip/mip in lockstep
  // with their architectural read values. The sie/sip
  // CSRs are restricted views of mie/mip; software writes are redirected
  // into csr[MIE____] / csr[MIP____] above, so the SIE/SIP slots would
  // otherwise stay 0 and break difftest's pointer compare against NEMU
  // (which mirrors `CSR_SIE = MIE & SIE_RMASK` after every insn). Use a
  // dedicated combinational shadow (not csr[SIE____]/csr[SIP____] NBA)
  // so the value is current within the same eval as the MIE write.
  logic [XLEN-1:0] csr_sie_shadow /* verilator public_flat_rd */;
  logic [XLEN-1:0] csr_sip_shadow /* verilator public_flat_rd */;
  logic [XLEN-1:0] csr_mip_shadow /* verilator public_flat_rd */;
  assign csr_sie_shadow = csr[MIE____] & csr[MIDELEG] & SieRmask;
  assign csr_sip_shadow = mip_eff & csr[MIDELEG] & SipRmask;
  // csr[MIP____] only holds software-writable pending bits.  MSIP/MTIP and
  // external interrupt levels are folded in by mip_eff, so exporting the raw
  // storage slot makes a following csrr mip diverge from the reference model.
  assign csr_mip_shadow = mip_eff;
endmodule
