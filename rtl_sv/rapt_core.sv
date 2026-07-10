`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// rapt_core: single-hart CPU body. All previously top-level structures of the
// `rapt` module live here so a cluster (`rapt.sv`) can instantiate one or
// more cores alongside cluster-shared peripherals (CLINT/PLIC today,
// multi-core in the future). External MMIO targeted at cluster-local CLINT or
// PLIC register windows leaves through the standard AXI master interface; the
// cluster router handles the decode, and the resulting timer/software/external
// interrupt levels are gated locally by the per-hart CSR enables before
// reaching the trap/commit logic.
module rapt_core #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    // AXI4 Master
    axi4_if.master io_master,

    // CLINT (cluster-level) interrupt levels. CLINT register accesses are
    // routed through the standard AXI master port; the cluster's address
    // decoder forwards them to the shared rapt_clint instance. Only the
    // resulting timer/software interrupt levels need a dedicated wire back
    // into the per-hart CSR/commit logic.
    input clint_timer_int_i,
    input clint_sw_int_i,

`ifdef RAPT_RVFI
    // RISC-V Formal Interface (RVFI) outputs -- NRET=2 channels
    output [1:0] rvfi_valid,
    output [127:0] rvfi_order,
    output [63:0] rvfi_insn,
    output [1:0] rvfi_trap,
    output [1:0] rvfi_halt,
    output [1:0] rvfi_intr,
    output [3:0] rvfi_mode,
    output [3:0] rvfi_ixl,
    output [9:0] rvfi_rs1_addr,
    output [9:0] rvfi_rs2_addr,
    output [2*XLEN-1:0] rvfi_rs1_rdata,
    output [2*XLEN-1:0] rvfi_rs2_rdata,
    output [9:0] rvfi_rd_addr,
    output [2*XLEN-1:0] rvfi_rd_wdata,
    output [2*XLEN-1:0] rvfi_pc_rdata,
    output [2*XLEN-1:0] rvfi_pc_wdata,
    output [2*XLEN-1:0] rvfi_mem_addr,
    output [2*(XLEN/8)-1:0] rvfi_mem_rmask,
    output [2*(XLEN/8)-1:0] rvfi_mem_wmask,
    output [2*XLEN-1:0] rvfi_mem_rdata,
    output [2*XLEN-1:0] rvfi_mem_wdata,
`endif

    // External M-mode interrupt line (level). In multi-hart cluster builds
    // this is the per-hart slice of `plic_meip` driven by the cluster PLIC.
    input io_interrupt,

    // External S-mode interrupt line (level), normally PLIC S-context SEIP.
    input s_ext_irq_i,

    // Hart identifier driven by the cluster top. Used only to satisfy CSR
    // reads of `mhartid`; no microarchitectural side-effects.
    input [XLEN-1:0] hart_id_i,

    // RISC-V Debug: external halt request from the cluster Debug Module
    // (level). The core stops dispatching new uops while asserted and
    // reports `halted_o` once the ROB has drained.
    input  logic            dm_haltreq_i,
    output logic            halted_o,
    // Resume PC reported to the DM (= npc of the youngest committed
    // instruction). Sampled by rapt_dm into dpc on halt entry.
    output logic [XLEN-1:0] halt_pc_o,
    // Single-cycle pulse: at least one instruction retired this cycle.
    // Sampled by rapt_dm to implement dcsr.step.
    output logic            commit_fire_o,

    // RISC-V Debug: abstract `access_register` GPR view (committed). Indexed
    // by 5-bit architectural reg number; valid only while `halted_o` is
    // asserted (otherwise rename state may be in flight).
    output logic [XLEN-1:0] dbg_gpr_rdata_o[`RAPT_REG_SIZE],
    // Debug GPR write back into the PRF (single-cycle pulse). Caller must
    // guarantee `halted_o`. x0 writes are dropped inside rapt_prf.
    input  logic            dbg_gpr_we_i,
    input  logic [     4:0] dbg_gpr_addr_i,
    input  logic [XLEN-1:0] dbg_gpr_wdata_i,

    input reset
);
  // L1I Cache
  // Optional PMU outputs from submodules are not consumed at core level.
  logic pmu_rob_full_unused;
  logic pmu_sq_full_unused;
  l1i_bus_if l1i_bus ();

  // IFU stage
  ifu_idu_if ifu_idu ();  // Fetch => Decode

  ifu_bpu_if ifu_bpu ();
  ifu_l1i_if ifu_l1i ();

  // IDU stage
  idu_rnu_if idu_rnu ();  // Decode => Re-naming
  idu_bpu_if idu_bpu ();  // Decode -> BPU BTB training (early-resteer)

  // RNU stage
  rnu_rou_if rnu_rou ();  // Re-naming => Issue

  // ROU stage
  rou_exu_if rou_exu ();  // Issue => Execute
  rou_lsu_if rou_lsu ();  // Commit
  rou_cmu_if rou_cmu ();  // Commit

  rou_csr_if rou_csr ();

  // Dispatch-only uop payload snapshot (ROU -> EXU/RS)
  rapt_pkg::uop_payload_t uop_pl[`RAPT_ROB_SIZE];

  // EXU stage: unified writeback (CDB) ports, one per execution pipeline.
  // Index map (see exu_wb_if): ALU-A (full), ALU-B (simple+jump), BRU
  // (conditional branches), MEM (IOQ loads/stores/atomics).
  exu_wb_if exu_rou ();  // ALU-A writeback => ROB/PRF/bypass
  exu_wb_if exu_rou_b ();  // ALU-B writeback (pure arithmetic + JAL/JALR)
  exu_wb_if exu_rou_c ();  // BRU writeback (conditional branches)
  exu_wb_if exu_ioq_bcast ();  // MEM writeback (IOQ broadcast)
  exu_wb_if exu_wb_mul ();  // MUL/DIV pipe writeback

  exu_prf_if exu_prf ();
  exu_csr_if exu_csr ();
  exu_lsu_if exu_lsu ();
  exu_l1d_if exu_l1d ();

  // CMU
  cmu_bcast_if cmu_bcast ();  // Difftest & Debug

  // LSU
  lsu_l1d_if lsu_l1d ();

  // L1D Cache
  l1d_bus_if l1d_bus ();

  // CSR
  csr_bcast_if csr_bcast ();

  logic clint_timer_trap;
  logic clint_sw_trap;
  logic clint_ext_trap;
  logic s_int_pending;
  logic [`RAPT_XLEN-1:0] s_int_cause;

  // Per-hart interrupt gating. The cluster CLINT supplies raw
  // timer/software interrupt levels; AND them with the per-hart CSR
  // enables (mie / mstatus) before they reach the trap-decision logic in
  // ROU. The external (PLIC) line is gated identically.
  assign clint_timer_trap = clint_timer_int_i && csr_bcast.timer_int_en;
  assign clint_sw_trap    = clint_sw_int_i && csr_bcast.sw_int_en;
  assign clint_ext_trap   = io_interrupt && csr_bcast.ext_int_en;

  rapt_bpu bpu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_bpu(ifu_bpu),
      .idu_bpu(idu_bpu),

      .reset(reset)
  );

  // IFU (Instruction Fetch Unit)
  rapt_ifu ifu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_bpu(ifu_bpu),
      .ifu_l1i(ifu_l1i),
      .ifu_idu(ifu_idu),

      .reset(reset)
  );

  rapt_l1i l1i_cache (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),

      .csr_bcast(csr_bcast),

      .reset(reset)
  );

  // IDU (Instruction Decode Unit)
  rapt_idu idu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),

      .ifu_idu(ifu_idu),
      .idu_bpu(idu_bpu),
      .idu_rnu(idu_rnu),

      .reset(reset)
  );

  // RNU (Re-naming Unit): pure rename: RNQ + freelist + maptable
  logic [`RAPT_PHY_LEN-1:0] rnu_map_snapshot[`RAPT_REG_SIZE];
  logic [`RAPT_PHY_LEN-1:0] rnu_rat_snapshot[`RAPT_REG_SIZE];

  rapt_rnu rnu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .idu_rnu(idu_rnu),
      .rnu_rou(rnu_rou),

      .map_snapshot(rnu_map_snapshot),
      .rat_snapshot(rnu_rat_snapshot),

      .reset(reset)
  );

  // ROU (Re-Order Unit)
  rapt_rou rou (
      .clock(clock),

      .rnu_rou(rnu_rou),

      // issue
      .exu_prf(exu_prf),
      .rou_exu(rou_exu),

      .exu_rou(exu_rou),
      .exu_rou_b(exu_rou_b),
      .exu_rou_c(exu_rou_c),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul(exu_wb_mul),

      .csr_bcast(csr_bcast),
      .clint_timer_trap(clint_timer_trap),
      .clint_sw_trap(clint_sw_trap),
      .clint_ext_trap(clint_ext_trap),
      .s_int_pending(s_int_pending),
      .s_int_cause(s_int_cause),

      .rou_cmu(rou_cmu),
      .rou_csr(rou_csr),
      .rou_lsu(rou_lsu),

      .uop_pl(uop_pl),

      .dm_haltreq_i (dm_haltreq_i),
      .halted_o     (halted_o),
      .halt_pc_o    (halt_pc_o),
      .commit_fire_o(commit_fire_o),

      .pmu_rob_full(pmu_rob_full_unused),

      .reset(reset)
  );

  // PRF (Physical Register File): top-level shared resource
  // Debug: architectural register view (committed + speculative)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] rf    [`RAPT_REG_SIZE];
  logic [XLEN-1:0] rf_map[`RAPT_REG_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */

  // Expose committed GPR view to the cluster-level Debug Module.
  assign dbg_gpr_rdata_o = rf;

`ifdef RAPT_RVFI
  logic [XLEN-1:0] rvfi_rd_wdata_a_w;
  logic [XLEN-1:0] rvfi_rd_wdata_b_w;
`endif

  rapt_prf prf (
      .clock(clock),
      .reset(reset),

      .prf_rd(exu_prf),

      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .rou_cmu      (rou_cmu),
      .cmu_bcast    (cmu_bcast),

      .map_snapshot(rnu_map_snapshot),
      .rat_snapshot(rnu_rat_snapshot),

      .rf    (rf),
      .rf_map(rf_map),

      .dbg_we_i   (dbg_gpr_we_i),
      .dbg_addr_i (dbg_gpr_addr_i),
      .dbg_wdata_i(dbg_gpr_wdata_i)

`ifdef RAPT_RVFI,
        .rvfi_rd_wdata_a(rvfi_rd_wdata_a_w)
      , .rvfi_rd_wdata_b(rvfi_rd_wdata_b_w)
`endif
  );

  // EXU (EXecution Unit)
  rapt_exu exu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .rou_exu(rou_exu),

      .exu_rou(exu_rou),
      .exu_rou_b(exu_rou_b),
      .exu_rou_c(exu_rou_c),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul(exu_wb_mul),

      .exu_lsu(exu_lsu),
      .exu_csr(exu_csr),

      .csr_bcast(csr_bcast),
      .exu_l1d  (exu_l1d),

      .uop_pl(uop_pl),

      .reset(reset)
  );

  // CMU (ComMit Unit)
  rapt_cmu cmu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

  rapt_csr csrs (
      .clock(clock),

      .hart_id_i(hart_id_i),

      .rou_csr(rou_csr),
      .exu_csr(exu_csr),

      .csr_bcast(csr_bcast),

      .s_int_pending(s_int_pending),
      .s_int_cause  (s_int_cause),

      .timer_irq_i(clint_timer_int_i),
      .sw_irq_i   (clint_sw_int_i),
      .m_ext_irq_i(io_interrupt),
      .s_ext_irq_i(s_ext_irq_i),

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  rapt_lsu lsu (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .lsu_l1d(lsu_l1d),

      .exu_lsu(exu_lsu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .rou_lsu(rou_lsu),

      .csr_bcast(csr_bcast),

      .pmu_sq_full(pmu_sq_full_unused),

      .reset(reset)
  );

  rapt_l1d l1d_cache (
      .clock(clock),

      .cmu_bcast(cmu_bcast),

      .lsu_l1d(lsu_l1d),
      .l1d_bus(l1d_bus),

      .csr_bcast(csr_bcast),

      .exu_l1d(exu_l1d),
      .rou_cmu(rou_cmu),

      .reset(reset)
  );

  // L2 cache sits between the L1 bus arbiter and the external AXI4 master
  // port. When RAPT_L2_EN is not defined the L2 collapses to a pure
  // passthrough, so this wiring is a no-op for legacy / SoC flows.
  axi4_if l2_axi ();

  rapt_bus bus (
      .clock(clock),

      .axi(l2_axi),

      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),

      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

  rapt_l2 l2 (
      .clock(clock),
      .reset(reset),

      .axi_s(l2_axi),
      .axi_m(io_master)
  );

`ifdef RAPT_RVFI
  // RVFI (RISC-V Formal Interface) output generation
  rapt_rvfi rvfi_inst (
      .clock(clock),
      .reset(reset),

      .rou_cmu  (rou_cmu),
      .csr_bcast(csr_bcast),
      .rf       (rf),

      .rvfi_rd_wdata_a(rvfi_rd_wdata_a_w),
      .rvfi_rd_wdata_b(rvfi_rd_wdata_b_w),

      .rvfi_valid(rvfi_valid),
      .rvfi_order(rvfi_order),
      .rvfi_insn (rvfi_insn),
      .rvfi_trap (rvfi_trap),
      .rvfi_halt (rvfi_halt),
      .rvfi_intr (rvfi_intr),
      .rvfi_mode (rvfi_mode),
      .rvfi_ixl  (rvfi_ixl),

      .rvfi_rs1_addr (rvfi_rs1_addr),
      .rvfi_rs2_addr (rvfi_rs2_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_addr  (rvfi_rd_addr),
      .rvfi_rd_wdata (rvfi_rd_wdata),

      .rvfi_pc_rdata(rvfi_pc_rdata),
      .rvfi_pc_wdata(rvfi_pc_wdata),

      .rvfi_mem_addr (rvfi_mem_addr),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );
`endif

endmodule
