`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

`ifndef RAPT_NHARTS
`define RAPT_NHARTS 1
`endif

// rapt: cluster-level top. Aggregates one or more `rapt_core` instances and
// the cluster-shared peripherals that, per the RISC-V platform spec, must be
// shared across all harts (CLINT and PLIC today; IMSIC in the future). The
// external port set is identical to the historical single-core top so all
// existing testbenches, SoC wrappers and FPGA targets continue to work
// without changes.
//
// Today (NR_HARTS = 1) the cluster instantiates a single core; the structure
// is laid out with multi-core scaling in mind:
//
//   core (L1s) --l2_client_if--> L2 --AXI4--+--> debug arbiter --> router
//   DM SBA ------------------------------+                    +-> CLINT / PLIC
//                                                            +-> io_master
//
//   - A core holds only its private L1 memory block. The L2 subsystem lives
//     here, outside every core, and always exists: it owns AXI and the
//     outstanding-transaction budgets, plus the L2 cache when RAPT_L2_EN
//     selects one. Its capabilities reach the cores as one parameter,
//     rapt_pkg::L2LinkConfig, so cores never test an L2 macro.
//   - CLINT lives here (was previously inside rapt_bus). A single CLINT
//     services all harts so `mtime` stays globally coherent and IPI / timer
//     interrupts have a single arbitration point.
//   - CLINT register accesses arrive via the L2 subsystem's AXI master. A
//     small 1-master / 3-target AXI router below decodes the CLINT and PLIC
//     address windows and dispatches transactions to on-cluster peripherals
//     or the off-chip `io_master` port. Cores and the L2 subsystem are
//     therefore entirely SoC-memory-map agnostic.
//   - When multi-core / IMSIC arrive, each core gets its own l2_client_if
//     port on the L2 subsystem, and the interrupt fabric scales from the
//     existing single-hart CLINT/PLIC base.
module rapt #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MemoryReadCredits = 8,
    parameter bit L1dWriteBack = `RAPT_L1D_WRITEBACK,
    // Number of hart contexts in this cluster (1..16).
    parameter int NHARTS = `RAPT_NHARTS
) (
    input rapt_pkg::sram_ctrl_t sram_ctrl_i,
    input clock,
    output logic writeback_error_o,
    // Asserted only after core AXI traffic drains; retained integrations may
    // use this boundary to apply a boot setting without resetting the DM.
    output logic core_reset_o,
    // Device writes are reported before a later SC may complete. Pending
    // holds SC while the platform drains a finite batch of notifications.
    input logic external_write_valid_i,
    input logic external_write_pending_i,
    input logic [XLEN-1:0] external_write_first_i,
    input logic [XLEN-1:0] external_write_last_i,


    // AXI4 Master
    output [     3:0] io_master_arcache,
    output [     1:0] io_master_arburst,
    output [     2:0] io_master_arsize,
    output [     7:0] io_master_arlen,
    output [     3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output            io_master_arvalid,
    input             io_master_arready,

    input  [     3:0] io_master_rid,
    input             io_master_rlast,
    input  [XLEN-1:0] io_master_rdata,
    input  [     1:0] io_master_rresp,
    input             io_master_rvalid,
    output            io_master_rready,

    output [     3:0] io_master_awcache,
    output [     1:0] io_master_awburst,
    output [     2:0] io_master_awsize,
    output [     7:0] io_master_awlen,
    output [     3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,
    output            io_master_awvalid,
    input             io_master_awready,

    output              io_master_wlast,
    output [  XLEN-1:0] io_master_wdata,
    output [XLEN/8-1:0] io_master_wstrb,
    output              io_master_wvalid,
    input               io_master_wready,

    input  [3:0] io_master_bid,
    input  [1:0] io_master_bresp,
    input        io_master_bvalid,
    output       io_master_bready,


`ifdef RAPT_RVFI
    // RISC-V Formal Interface (RVFI) outputs -- NRET=CommitWidth channels
    output [rapt_pkg::CommitWidth-1:0] rvfi_valid,
    output [rapt_pkg::CommitWidth*64-1:0] rvfi_order,
    output [rapt_pkg::CommitWidth*32-1:0] rvfi_insn,
    output [rapt_pkg::CommitWidth-1:0] rvfi_trap,
    output [rapt_pkg::CommitWidth-1:0] rvfi_halt,
    output [rapt_pkg::CommitWidth-1:0] rvfi_intr,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_mode,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_ixl,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs1_addr,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs2_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs1_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs2_rdata,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rd_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rd_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_addr,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_rmask,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_wmask,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_wdata,
`endif

    input io_interrupt,

    // Per-source external interrupt lines into the cluster PLIC. Source 0
    // is reserved by the PLIC spec, so external aggregators feed sources
    // 1..NDEV. Wrappers that don't have peripherals tie this to '0.
    input [`RAPT_PLIC_NDEV:1] ext_irq_i,

    // -----------------------------------------------------------------
    // JTAG / RISC-V Debug Module ports (P0 -- see verification/jtag/README.md)
    // -----------------------------------------------------------------
    input  logic jtag_trst_n,
    input  logic jtag_tck_en,
    input  logic jtag_tms,
    input  logic jtag_tdi,
    output logic jtag_tdo,

    input reset
);

  if (NHARTS < 1 || NHARTS > 16) begin : g_invalid_nharts
    $error("rapt supports 1..16 harts (NHARTS=%0d)", NHARTS);
  end

  // ------------------------------------------------------------------
  // Core -> L2 subsystem client port, and the L2 subsystem's AXI master.
  // The cluster-level router muxes the AXI master between cluster-internal
  // slaves and the external io_master port.
  // ------------------------------------------------------------------
  localparam rapt_pkg::l2_link_config_t L2Link = rapt_pkg::L2LinkConfig;
  localparam int PlicNctx = (NHARTS == 1) ? `RAPT_PLIC_NCTX : (2 * NHARTS);
  axi4_if #(.XLEN(XLEN)) core_axi ();
  axi4_if #(.XLEN(XLEN)) offchip_axi ();
  axi4_if #(.XLEN(XLEN)) sb_axi ();
  axi4_if #(.XLEN(XLEN)) merged_axi ();
  logic core_reset, core_block, core_bus_idle;
  logic ndmreset_pending_q, ndmreset_active_q;


  // -----------------------------------------------------------------
  // Debug Transport Module + Debug Module (cluster-level).
  // -----------------------------------------------------------------
  logic                              dmi_req;
  logic                              dmi_wr;
  logic [                       6:0] dmi_addr;
  logic [                      31:0] dmi_wdata;
  logic [                      31:0] dmi_rdata;
  logic [                       1:0] dmi_resp;
  logic [                NHARTS-1:0] dm_haltreq;
  logic [                NHARTS-1:0] dm_resumereq;
  logic                              dm_ndmreset;
  logic [                NHARTS-1:0] dm_halted;
  logic [`RAPT_PC_BITS_OF(XLEN)-1:0] dm_halt_pc;
  logic                              dm_commit_fire;
  rapt_debug_if #(.XLEN(XLEN)) debug ();
  /* verilator lint_off UNUSEDSIGNAL */
  logic [                NHARTS-1:0] dm_resumereq_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  // DM <-> core debug GPR bus (committed view + write port). x0 writes
  // are dropped inside rapt_prf; caller must hold `dm_halted` before
  // pulsing `dm_dbg_gpr_we`.
  logic [XLEN-1:0] dm_dbg_gpr_rdata;
  logic            dm_dbg_gpr_we;
  logic [     4:0] dm_dbg_gpr_addr;
  logic [XLEN-1:0] dm_dbg_gpr_wdata;

  // Per-hart debug mux buses (hart 0 uses direct wires when NHARTS==1).
  logic [`RAPT_PC_BITS_OF(XLEN)-1:0] hart_halt_pc     [NHARTS];
  logic [                  XLEN-1:0] hart_dbg_gpr_rdata[NHARTS];
  logic [                NHARTS-1:0] hart_dbg_gpr_we;
  logic [                NHARTS-1:0] hart_resume_ack;
  logic [                       2:0] hart_dbg_cause   [NHARTS];
  logic [                       1:0] hart_dbg_prv     [NHARTS];

  localparam int DmHartW = (NHARTS <= 1) ? 1 : $clog2(NHARTS);
  wire [DmHartW-1:0] dm_sel_idx = (int'(debug.hartsel) < NHARTS) ? debug.hartsel[DmHartW-1:0] : '0;
  assign dm_halt_pc       = hart_halt_pc[dm_sel_idx];
  assign dm_dbg_gpr_rdata = hart_dbg_gpr_rdata[dm_sel_idx];
  assign debug.resume_ack = hart_resume_ack[dm_sel_idx];
  assign debug.cause      = hart_dbg_cause[dm_sel_idx];
  assign debug.prv        = hart_dbg_prv[dm_sel_idx];
  for (genvar dh = 0; dh < NHARTS; dh++) begin : g_dm_we_demux
    assign hart_dbg_gpr_we[dh] = dm_dbg_gpr_we && (int'(debug.hartsel) == dh);
  end

  // Latch even a short ndmreset request. Keep the old core/L2 alive until
  // every offered/accepted AXI transfer drains, then reset for at least a cycle.
  // The router, arbiter and external bridge retain response ownership throughout.
  assign core_block = dm_ndmreset || ndmreset_pending_q || ndmreset_active_q;
  assign core_reset = reset || ndmreset_active_q;
  assign core_reset_o = core_reset;
  always_ff @(posedge clock) begin
    if (reset) begin
      ndmreset_pending_q <= 1'b0;
      ndmreset_active_q  <= 1'b0;
    end else if (ndmreset_active_q) begin
      if (!dm_ndmreset) begin
        ndmreset_active_q  <= 1'b0;
        ndmreset_pending_q <= 1'b0;
      end
    end else if (dm_ndmreset || ndmreset_pending_q) begin
      ndmreset_pending_q <= 1'b1;
      if (core_bus_idle) ndmreset_active_q <= 1'b1;
    end
  end


  assign io_master_arburst = offchip_axi.arburst;
  assign io_master_arcache = offchip_axi.arcache;
  assign io_master_arsize = offchip_axi.arsize;
  assign io_master_arlen = offchip_axi.arlen;
  assign io_master_arid = offchip_axi.arid;
  assign io_master_araddr = offchip_axi.araddr;
  assign io_master_arvalid = offchip_axi.arvalid;
  assign offchip_axi.arready = io_master_arready;

  assign offchip_axi.rid = io_master_rid;
  assign offchip_axi.rlast = io_master_rlast;
  assign offchip_axi.rdata = io_master_rdata;
  assign offchip_axi.rresp = io_master_rresp;
  assign offchip_axi.rvalid = io_master_rvalid;
  assign io_master_rready = offchip_axi.rready;

  assign io_master_awburst = offchip_axi.awburst;
  assign io_master_awcache = offchip_axi.awcache;
  assign io_master_awsize = offchip_axi.awsize;
  assign io_master_awlen = offchip_axi.awlen;
  assign io_master_awid = offchip_axi.awid;
  assign io_master_awaddr = offchip_axi.awaddr;
  assign io_master_awvalid = offchip_axi.awvalid;
  assign offchip_axi.awready = io_master_awready;

  assign io_master_wlast = offchip_axi.wlast;
  assign io_master_wdata = offchip_axi.wdata;
  assign io_master_wstrb = offchip_axi.wstrb;
  assign io_master_wvalid = offchip_axi.wvalid;
  assign offchip_axi.wready = io_master_wready;

  assign offchip_axi.bid = io_master_bid;
  assign offchip_axi.bresp = io_master_bresp;
  assign offchip_axi.bvalid = io_master_bvalid;
  assign io_master_bready = offchip_axi.bready;

  // ------------------------------------------------------------------
  // Cluster-shared CLINT
  // ------------------------------------------------------------------
  clint_bus_if #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) clint_bus ();

  rapt_clint #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) clint_inst (
      .clock(clock),

      .clint_bus(clint_bus),

      .reset(core_reset)
  );

  // ------------------------------------------------------------------
  // Cluster-shared PLIC
  // ------------------------------------------------------------------
  // Source 0 is hardwired to 0 per spec; the cluster aggregates external
  // sources from `ext_irq_i[NDEV:1]` and additionally exposes the legacy
  // single-bit `io_interrupt` port as PLIC source 1. This means software
  // that programs the PLIC sees the same external IRQ that the legacy
  // single-line MEIP path would have seen, while the core's MEIP is now
  // driven exclusively by the PLIC claim/complete handshake (no bypass).
  plic_bus_if #(
      .XLEN(XLEN),
      .NCTX(PlicNctx)
  ) plic_bus ();

  always_comb begin
    plic_bus.ext_irq = '0;
    plic_bus.ext_irq[`RAPT_PLIC_NDEV:1] = ext_irq_i;
    plic_bus.ext_irq[1] = ext_irq_i[1] | io_interrupt;
  end

  rapt_plic #(
      .XLEN(XLEN),
      .NCTX(PlicNctx)
  ) plic (
      .clock(clock),
      .reset(core_reset),

      .plic_bus(plic_bus)
  );

  rapt_debug_arbiter #(
      .XLEN(XLEN),
      .CoreWriteOutstanding(L2Link.posted_writes > 0 ? L2Link.posted_writes : 1)
  ) debug_arbiter (
      .clock(clock),
      .reset(reset),
      // Halt stops retirement before the instruction cache stops requesting.
      // Keep speculative refills off an unconnected external backend so SBA
      // remains usable after releasing ndmreset with haltreq still asserted.
      // Existing offers drain; debug cache cleaning completes before halted.
      // In multi-hart clusters, halting one hart must not block other harts.
      .core_block_i(core_block || ((NHARTS == 1) && dm_halted[0])),
      .core_idle_o(core_bus_idle),
      .core_axi(core_axi),
      .sb_axi(sb_axi),
      .merged_axi(merged_axi)
  );

  rapt_router #(
      .XLEN(XLEN),
      .WriteOutstanding(L2Link.posted_writes > 0 ? L2Link.posted_writes : 1)
  ) axi_router (
      .clock(clock),
      .reset(reset),

      .core_axi(merged_axi),
      .offchip_axi(offchip_axi),
      .clint_bus(clint_bus),
      .plic_bus(plic_bus)
  );

  // ------------------------------------------------------------------
  // L2 subsystem & CPU cores
  // ------------------------------------------------------------------
  // Hart 0 (`core`) and `l2_subsystem` remain direct children of `rapt` so
  // simulator observation paths (`sim/include/npc_verilog.h`) stay stable.
  // Multi-hart clusters use write-through L1D with back-invalidation probes
  // managed by `rapt_coherence_hub` so every cacheable store updates shared
  // memory/L2 and invalidates sibling L1Ds before returning wr_rsp.
  localparam bit CoreL1dWriteBack = (NHARTS == 1) ? L1dWriteBack : 1'b0;
  localparam rapt_pkg::l2_link_config_t CoreL2Link = (NHARTS == 1) ? L2Link : '{
      cache: L2Link.cache,
      inclusive: 1'b0,
      victim_release: 1'b0,
      store_writeback: 1'b0,
      line_offset: L2Link.line_offset,
      posted_writes: 0
  };
  localparam rapt_pkg::l2_link_config_t SubL2Link = (NHARTS == 1) ? L2Link : '{
      cache: L2Link.cache,
      inclusive: 1'b0,
      victim_release: 1'b0,
      store_writeback: L2Link.store_writeback,
      line_offset: L2Link.line_offset,
      posted_writes: 0
  };
  l2_client_if #(.XLEN(XLEN)) core_l2 ();
  l2_client_if #(.XLEN(XLEN)) l2_sub_client ();
  logic [NHARTS-1:0] hart_wb_err;
  assign writeback_error_o = |hart_wb_err;

  rapt_l2_subsystem #(
      .XLEN(XLEN),
      .L2Link(SubL2Link),
      .MemoryReadCredits(MemoryReadCredits)
  ) l2_subsystem (
      .sram_ctrl_i(sram_ctrl_i),
      .clock(clock),
      .reset(core_reset),
      .client(l2_sub_client),
      .io_master(core_axi)
  );

  // Hart 0 (primary hart).
  rapt_debug_if #(.XLEN(XLEN)) hart0_debug ();
  assign hart0_debug.enable       = debug.enable;
  assign hart0_debug.step         = debug.step && (int'(debug.hartsel) == 0);
  assign hart0_debug.stepie       = debug.stepie;
  assign hart0_debug.ebreak       = debug.ebreak;
  assign hart0_debug.resume_valid = debug.resume_valid && (int'(debug.hartsel) == 0);
  assign hart0_debug.resume_pc    = debug.resume_pc;
  assign hart_resume_ack[0]       = hart0_debug.resume_ack;
  assign hart_dbg_cause[0]        = hart0_debug.cause;
  assign hart_dbg_prv[0]          = hart0_debug.prv;

  rapt_core #(
      .XLEN(XLEN),
      .L1dWriteBack(CoreL1dWriteBack),
      .L2Link(CoreL2Link)
  ) core (
      .sram_ctrl_i(sram_ctrl_i),
      .writeback_error_o(hart_wb_err[0]),
      .external_write_valid_i(external_write_valid_i),
      .external_write_pending_i(external_write_pending_i),
      .external_write_first_i(external_write_first_i),
      .external_write_last_i(external_write_last_i),

      .clock(clock),

      // L1D eviction-store errors are sticky and exported for platform-level
      // fatal-error handling; the cache remains blocked until reset.

      .l2_client(core_l2),

      .clint_timer_int_i(clint_bus.timer_int[0]),
      .clint_sw_int_i   (clint_bus.sw_int[0]),
      .mtime_i          (clint_bus.mtime_value),

`ifdef RAPT_RVFI
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
      .rvfi_mem_wdata(rvfi_mem_wdata),
`endif

      .io_interrupt(plic_bus.meip[0]),
      .s_ext_irq_i (plic_bus.seip[0]),

      .hart_id_i({XLEN{1'b0}}),

      .dm_haltreq_i (dm_haltreq[0]),
      .debug        (hart0_debug),
      .halted_o     (dm_halted[0]),
      .halt_pc_o    (hart_halt_pc[0]),
      .commit_fire_o(dm_commit_fire),

      .dbg_gpr_rdata_o(hart_dbg_gpr_rdata[0]),
      .dbg_gpr_we_i   (hart_dbg_gpr_we[0]),
      .dbg_gpr_addr_i (dm_dbg_gpr_addr),
      .dbg_gpr_wdata_i(dm_dbg_gpr_wdata),

      .reset(core_reset)
  );

  if (NHARTS == 1) begin : g_single_hart_link
    assign l2_sub_client.rd_req_valid        = core_l2.rd_req_valid;
    assign l2_sub_client.rd_req_id           = core_l2.rd_req_id;
    assign l2_sub_client.rd_req_addr         = core_l2.rd_req_addr;
    assign l2_sub_client.rd_req_size         = core_l2.rd_req_size;
    assign l2_sub_client.rd_req_len          = core_l2.rd_req_len;
    assign l2_sub_client.rd_req_burst        = core_l2.rd_req_burst;
    assign l2_sub_client.rd_req_pbmt         = core_l2.rd_req_pbmt;
    assign l2_sub_client.rd_req_noallocate   = core_l2.rd_req_noallocate;
    assign l2_sub_client.rd_req_cacheable    = core_l2.rd_req_cacheable;
    assign core_l2.rd_req_ready              = l2_sub_client.rd_req_ready;
    assign core_l2.rd_rsp_valid              = l2_sub_client.rd_rsp_valid;
    assign core_l2.rd_rsp_id                 = l2_sub_client.rd_rsp_id;
    assign core_l2.rd_rsp_data               = l2_sub_client.rd_rsp_data;
    assign core_l2.rd_rsp_last               = l2_sub_client.rd_rsp_last;
    assign core_l2.rd_rsp_error              = l2_sub_client.rd_rsp_error;
    assign l2_sub_client.rd_rsp_ready        = core_l2.rd_rsp_ready;
    assign l2_sub_client.wr_req_valid        = core_l2.wr_req_valid;
    assign l2_sub_client.wr_req_zero         = core_l2.wr_req_zero;
    assign l2_sub_client.wr_req_id           = core_l2.wr_req_id;
    assign l2_sub_client.wr_req_addr         = core_l2.wr_req_addr;
    assign l2_sub_client.wr_req_size         = core_l2.wr_req_size;
    assign l2_sub_client.wr_req_pbmt         = core_l2.wr_req_pbmt;
    assign l2_sub_client.wr_req_data         = core_l2.wr_req_data;
    assign l2_sub_client.wr_req_strb         = core_l2.wr_req_strb;
    assign core_l2.wr_req_ready              = l2_sub_client.wr_req_ready;
    assign core_l2.wr_rsp_valid              = l2_sub_client.wr_rsp_valid;
    assign core_l2.wr_rsp_id                 = l2_sub_client.wr_rsp_id;
    assign core_l2.wr_rsp_error              = l2_sub_client.wr_rsp_error;
    assign l2_sub_client.wr_rsp_ready        = core_l2.wr_rsp_ready;
    assign core_l2.probe_valid               = l2_sub_client.probe_valid;
    assign core_l2.probe_addr                = l2_sub_client.probe_addr;
    assign core_l2.probe_window              = l2_sub_client.probe_window;
    assign l2_sub_client.probe_ready         = core_l2.probe_ready;
    assign l2_sub_client.probe_release_valid = core_l2.probe_release_valid;
    assign l2_sub_client.probe_release_addr  = core_l2.probe_release_addr;
    assign l2_sub_client.probe_release_data  = core_l2.probe_release_data;
    assign core_l2.probe_release_ready       = l2_sub_client.probe_release_ready;
    assign l2_sub_client.release_valid       = core_l2.release_valid;
    assign l2_sub_client.release_addr        = core_l2.release_addr;
    assign l2_sub_client.release_data        = core_l2.release_data;
    assign l2_sub_client.release_has_data    = core_l2.release_has_data;
    assign l2_sub_client.release_mask        = core_l2.release_mask;
    assign l2_sub_client.release_last        = core_l2.release_last;
    assign core_l2.release_ready             = l2_sub_client.release_ready;
    assign core_l2.release_ack               = l2_sub_client.release_ack;
    assign l2_sub_client.writeback_pending   = core_l2.writeback_pending;
    assign l2_sub_client.cbo_inval           = core_l2.cbo_inval;
    assign l2_sub_client.cbo_block           = core_l2.cbo_block;
    assign l2_sub_client.atomic_lock_req     = core_l2.atomic_lock_req;
    assign core_l2.atomic_lock_stall         = l2_sub_client.atomic_lock_stall;
  end else begin : g_multi_hart
    logic [NHARTS-1:0] hart_rd_req_valid;
    logic [NHARTS-1:0] hart_rd_req_ready;
    logic [       3:0] hart_rd_req_id        [NHARTS];
    logic [  XLEN-1:0] hart_rd_req_addr      [NHARTS];
    logic [       2:0] hart_rd_req_size      [NHARTS];
    logic [       7:0] hart_rd_req_len       [NHARTS];
    logic [       1:0] hart_rd_req_burst     [NHARTS];
    logic [       1:0] hart_rd_req_pbmt      [NHARTS];
    logic [NHARTS-1:0] hart_rd_req_noallocate;
    logic [NHARTS-1:0] hart_rd_req_cacheable;

    logic [NHARTS-1:0] hart_rd_rsp_valid;
    logic [NHARTS-1:0] hart_rd_rsp_ready;
    logic [       3:0] hart_rd_rsp_id        [NHARTS];
    logic [  XLEN-1:0] hart_rd_rsp_data      [NHARTS];
    logic [NHARTS-1:0] hart_rd_rsp_last;
    logic [NHARTS-1:0] hart_rd_rsp_error;

    logic [NHARTS-1:0] hart_wr_req_valid;
    logic [NHARTS-1:0] hart_wr_req_zero;
    logic [NHARTS-1:0] hart_wr_req_ready;
    logic [       3:0] hart_wr_req_id        [NHARTS];
    logic [  XLEN-1:0] hart_wr_req_addr      [NHARTS];
    logic [       2:0] hart_wr_req_size      [NHARTS];
    logic [       1:0] hart_wr_req_pbmt      [NHARTS];
    logic [  XLEN-1:0] hart_wr_req_data      [NHARTS];
    logic [XLEN/8-1:0] hart_wr_req_strb      [NHARTS];

    logic [NHARTS-1:0] hart_wr_rsp_valid;
    logic [NHARTS-1:0] hart_wr_rsp_ready;
    logic [       3:0] hart_wr_rsp_id        [NHARTS];
    logic [NHARTS-1:0] hart_wr_rsp_error;

    logic [NHARTS-1:0] hart_probe_valid;
    logic [  XLEN-1:0] hart_probe_addr       [NHARTS];
    logic [NHARTS-1:0] hart_probe_ready;
    logic [NHARTS-1:0] hart_probe_window;

    logic [NHARTS-1:0] hart_cbo_inval;
    logic [  XLEN-1:6] hart_cbo_block        [NHARTS];

    logic [NHARTS-1:0] hart_atomic_lock_req;
    logic [NHARTS-1:0] hart_atomic_lock_grant;

    mem_link_if #(.XLEN(XLEN)) merged_mem_link ();
    logic merged_rd_req_cacheable;

    // Hart 0 client wiring
    assign hart_rd_req_valid[0]        = core_l2.rd_req_valid;
    assign hart_rd_req_id[0]           = core_l2.rd_req_id;
    assign hart_rd_req_addr[0]         = core_l2.rd_req_addr;
    assign hart_rd_req_size[0]         = core_l2.rd_req_size;
    assign hart_rd_req_len[0]          = core_l2.rd_req_len;
    assign hart_rd_req_burst[0]        = core_l2.rd_req_burst;
    assign hart_rd_req_pbmt[0]         = core_l2.rd_req_pbmt;
    assign hart_rd_req_noallocate[0]   = core_l2.rd_req_noallocate;
    assign hart_rd_req_cacheable[0]    = core_l2.rd_req_cacheable;
    assign core_l2.rd_req_ready        = hart_rd_req_ready[0];
    assign core_l2.rd_rsp_valid        = hart_rd_rsp_valid[0];
    assign core_l2.rd_rsp_id           = hart_rd_rsp_id[0];
    assign core_l2.rd_rsp_data         = hart_rd_rsp_data[0];
    assign core_l2.rd_rsp_last         = hart_rd_rsp_last[0];
    assign core_l2.rd_rsp_error        = hart_rd_rsp_error[0];
    assign hart_rd_rsp_ready[0]        = core_l2.rd_rsp_ready;
    assign hart_wr_req_valid[0]        = core_l2.wr_req_valid;
    assign hart_wr_req_zero[0]         = core_l2.wr_req_zero;
    assign hart_wr_req_id[0]           = core_l2.wr_req_id;
    assign hart_wr_req_addr[0]         = core_l2.wr_req_addr;
    assign hart_wr_req_size[0]         = core_l2.wr_req_size;
    assign hart_wr_req_pbmt[0]         = core_l2.wr_req_pbmt;
    assign hart_wr_req_data[0]         = core_l2.wr_req_data;
    assign hart_wr_req_strb[0]         = core_l2.wr_req_strb;
    assign core_l2.wr_req_ready        = hart_wr_req_ready[0];
    assign core_l2.wr_rsp_valid        = hart_wr_rsp_valid[0];
    assign core_l2.wr_rsp_id           = hart_wr_rsp_id[0];
    assign core_l2.wr_rsp_error        = hart_wr_rsp_error[0];
    assign hart_wr_rsp_ready[0]        = core_l2.wr_rsp_ready;
    assign core_l2.probe_valid         = hart_probe_valid[0];
    assign core_l2.probe_addr          = hart_probe_addr[0];
    assign core_l2.probe_window        = hart_probe_window[0];
    assign hart_probe_ready[0]         = core_l2.probe_ready;
    assign core_l2.probe_release_ready = 1'b0;
    assign core_l2.release_ready       = 1'b0;
    assign core_l2.release_ack         = 1'b0;
    assign hart_cbo_inval[0]           = core_l2.cbo_inval;
    assign hart_cbo_block[0]           = core_l2.cbo_block;
    assign hart_atomic_lock_req[0]     = core_l2.atomic_lock_req;
    assign core_l2.atomic_lock_stall   = !hart_atomic_lock_grant[0];

    // Secondary harts (1 .. NHARTS-1)
    for (genvar h = 1; h < NHARTS; h++) begin : g_hart
      l2_client_if #(.XLEN(XLEN)) hart_l2 ();
      rapt_debug_if #(.XLEN(XLEN)) hart_debug ();
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_commit_fire;
      /* verilator lint_on UNUSEDSIGNAL */

      assign hart_debug.enable       = debug.enable;
      assign hart_debug.step         = debug.step && (int'(debug.hartsel) == h);
      assign hart_debug.stepie       = debug.stepie;
      assign hart_debug.ebreak       = debug.ebreak;
      assign hart_debug.resume_valid = debug.resume_valid && (int'(debug.hartsel) == h);
      assign hart_debug.resume_pc    = debug.resume_pc;
      assign hart_resume_ack[h]      = hart_debug.resume_ack;
      assign hart_dbg_cause[h]       = hart_debug.cause;
      assign hart_dbg_prv[h]         = hart_debug.prv;

      assign hart_rd_req_valid[h]        = hart_l2.rd_req_valid;
      assign hart_rd_req_id[h]           = hart_l2.rd_req_id;
      assign hart_rd_req_addr[h]         = hart_l2.rd_req_addr;
      assign hart_rd_req_size[h]         = hart_l2.rd_req_size;
      assign hart_rd_req_len[h]          = hart_l2.rd_req_len;
      assign hart_rd_req_burst[h]        = hart_l2.rd_req_burst;
      assign hart_rd_req_pbmt[h]         = hart_l2.rd_req_pbmt;
      assign hart_rd_req_noallocate[h]   = hart_l2.rd_req_noallocate;
      assign hart_rd_req_cacheable[h]    = hart_l2.rd_req_cacheable;
      assign hart_l2.rd_req_ready        = hart_rd_req_ready[h];
      assign hart_l2.rd_rsp_valid        = hart_rd_rsp_valid[h];
      assign hart_l2.rd_rsp_id           = hart_rd_rsp_id[h];
      assign hart_l2.rd_rsp_data         = hart_rd_rsp_data[h];
      assign hart_l2.rd_rsp_last         = hart_rd_rsp_last[h];
      assign hart_l2.rd_rsp_error        = hart_rd_rsp_error[h];
      assign hart_rd_rsp_ready[h]        = hart_l2.rd_rsp_ready;
      assign hart_wr_req_valid[h]        = hart_l2.wr_req_valid;
      assign hart_wr_req_zero[h]         = hart_l2.wr_req_zero;
      assign hart_wr_req_id[h]           = hart_l2.wr_req_id;
      assign hart_wr_req_addr[h]         = hart_l2.wr_req_addr;
      assign hart_wr_req_size[h]         = hart_l2.wr_req_size;
      assign hart_wr_req_pbmt[h]         = hart_l2.wr_req_pbmt;
      assign hart_wr_req_data[h]         = hart_l2.wr_req_data;
      assign hart_wr_req_strb[h]         = hart_l2.wr_req_strb;
      assign hart_l2.wr_req_ready        = hart_wr_req_ready[h];
      assign hart_l2.wr_rsp_valid        = hart_wr_rsp_valid[h];
      assign hart_l2.wr_rsp_id           = hart_wr_rsp_id[h];
      assign hart_l2.wr_rsp_error        = hart_wr_rsp_error[h];
      assign hart_wr_rsp_ready[h]        = hart_l2.wr_rsp_ready;
      assign hart_l2.probe_valid         = hart_probe_valid[h];
      assign hart_l2.probe_addr          = hart_probe_addr[h];
      assign hart_l2.probe_window        = hart_probe_window[h];
      assign hart_probe_ready[h]         = hart_l2.probe_ready;
      assign hart_l2.probe_release_ready = 1'b0;
      assign hart_l2.release_ready       = 1'b0;
      assign hart_l2.release_ack         = 1'b0;
      assign hart_cbo_inval[h]           = hart_l2.cbo_inval;
      assign hart_cbo_block[h]           = hart_l2.cbo_block;
      assign hart_atomic_lock_req[h]     = hart_l2.atomic_lock_req;
      assign hart_l2.atomic_lock_stall   = !hart_atomic_lock_grant[h];

      rapt_core #(
          .XLEN(XLEN),
          .L1dWriteBack(CoreL1dWriteBack),
          .L2Link(CoreL2Link)
      ) core (
          .sram_ctrl_i(sram_ctrl_i),
          .writeback_error_o(hart_wb_err[h]),
          .external_write_valid_i(external_write_valid_i),
          .external_write_pending_i(external_write_pending_i),
          .external_write_first_i(external_write_first_i),
          .external_write_last_i(external_write_last_i),
          .clock(clock),
          .l2_client(hart_l2),
          .clint_timer_int_i(clint_bus.timer_int[h]),
          .clint_sw_int_i(clint_bus.sw_int[h]),
          .mtime_i(clint_bus.mtime_value),
          .io_interrupt(plic_bus.meip[h]),
          .s_ext_irq_i(plic_bus.seip[h]),
          .hart_id_i(XLEN'(h)),
          .dm_haltreq_i(dm_haltreq[h]),
          .debug(hart_debug),
          .halted_o(dm_halted[h]),
          .halt_pc_o(hart_halt_pc[h]),
          .commit_fire_o(unused_commit_fire),
          .dbg_gpr_rdata_o(hart_dbg_gpr_rdata[h]),
          .dbg_gpr_we_i(hart_dbg_gpr_we[h]),
          .dbg_gpr_addr_i(dm_dbg_gpr_addr),
          .dbg_gpr_wdata_i(dm_dbg_gpr_wdata),
          .reset(core_reset)
      );
    end

    rapt_coherence_hub #(
        .XLEN(XLEN),
        .NHARTS(NHARTS),
        .PerHartReadCredits(MemoryReadCredits),
        .L2LineOffset(L2Link.line_offset)
    ) coherence_hub (
        .clock(clock),
        .reset(core_reset),
        .rd_req_valid_i(hart_rd_req_valid),
        .rd_req_ready_o(hart_rd_req_ready),
        .rd_req_id_i(hart_rd_req_id),
        .rd_req_addr_i(hart_rd_req_addr),
        .rd_req_size_i(hart_rd_req_size),
        .rd_req_len_i(hart_rd_req_len),
        .rd_req_burst_i(hart_rd_req_burst),
        .rd_req_pbmt_i(hart_rd_req_pbmt),
        .rd_req_noallocate_i(hart_rd_req_noallocate),
        .rd_req_cacheable_i(hart_rd_req_cacheable),
        .rd_rsp_valid_o(hart_rd_rsp_valid),
        .rd_rsp_ready_i(hart_rd_rsp_ready),
        .rd_rsp_id_o(hart_rd_rsp_id),
        .rd_rsp_data_o(hart_rd_rsp_data),
        .rd_rsp_last_o(hart_rd_rsp_last),
        .rd_rsp_error_o(hart_rd_rsp_error),
        .wr_req_valid_i(hart_wr_req_valid),
        .wr_req_zero_i(hart_wr_req_zero),
        .wr_req_ready_o(hart_wr_req_ready),
        .wr_req_id_i(hart_wr_req_id),
        .wr_req_addr_i(hart_wr_req_addr),
        .wr_req_size_i(hart_wr_req_size),
        .wr_req_pbmt_i(hart_wr_req_pbmt),
        .wr_req_data_i(hart_wr_req_data),
        .wr_req_strb_i(hart_wr_req_strb),
        .wr_rsp_valid_o(hart_wr_rsp_valid),
        .wr_rsp_ready_i(hart_wr_rsp_ready),
        .wr_rsp_id_o(hart_wr_rsp_id),
        .wr_rsp_error_o(hart_wr_rsp_error),
        .probe_valid_o(hart_probe_valid),
        .probe_addr_o(hart_probe_addr),
        .probe_ready_i(hart_probe_ready),
        .probe_window_o(hart_probe_window),
        .cbo_inval_i(hart_cbo_inval),
        .cbo_block_i(hart_cbo_block),
        .atomic_lock_req_i(hart_atomic_lock_req),
        .atomic_lock_grant_o(hart_atomic_lock_grant),
        .l2_probe_valid_i(l2_sub_client.probe_valid),
        .l2_probe_addr_i(l2_sub_client.probe_addr),
        .l2_probe_ready_o(l2_sub_client.probe_ready),
        .out_cbo_inval_o(l2_sub_client.cbo_inval),
        .out_cbo_block_o(l2_sub_client.cbo_block),
        .out_mem(merged_mem_link),
        .out_rd_req_cacheable_o(merged_rd_req_cacheable)
    );

    assign l2_sub_client.rd_req_valid        = merged_mem_link.rd_req_valid;
    assign l2_sub_client.rd_req_id           = merged_mem_link.rd_req_id;
    assign l2_sub_client.rd_req_addr         = merged_mem_link.rd_req_addr;
    assign l2_sub_client.rd_req_size         = merged_mem_link.rd_req_size;
    assign l2_sub_client.rd_req_len          = merged_mem_link.rd_req_len;
    assign l2_sub_client.rd_req_burst        = merged_mem_link.rd_req_burst;
    assign l2_sub_client.rd_req_pbmt         = merged_mem_link.rd_req_pbmt;
    assign l2_sub_client.rd_req_noallocate   = merged_mem_link.rd_req_noallocate;
    assign l2_sub_client.rd_req_cacheable    = merged_rd_req_cacheable;
    assign merged_mem_link.rd_req_ready      = l2_sub_client.rd_req_ready;
    assign merged_mem_link.rd_rsp_valid      = l2_sub_client.rd_rsp_valid;
    assign merged_mem_link.rd_rsp_id         = l2_sub_client.rd_rsp_id;
    assign merged_mem_link.rd_rsp_data       = l2_sub_client.rd_rsp_data;
    assign merged_mem_link.rd_rsp_last       = l2_sub_client.rd_rsp_last;
    assign merged_mem_link.rd_rsp_error      = l2_sub_client.rd_rsp_error;
    assign l2_sub_client.rd_rsp_ready        = merged_mem_link.rd_rsp_ready;
    assign l2_sub_client.wr_req_valid        = merged_mem_link.wr_req_valid;
    assign l2_sub_client.wr_req_zero         = merged_mem_link.wr_req_zero;
    assign l2_sub_client.wr_req_id           = merged_mem_link.wr_req_id;
    assign l2_sub_client.wr_req_addr         = merged_mem_link.wr_req_addr;
    assign l2_sub_client.wr_req_size         = merged_mem_link.wr_req_size;
    assign l2_sub_client.wr_req_pbmt         = merged_mem_link.wr_req_pbmt;
    assign l2_sub_client.wr_req_data         = merged_mem_link.wr_req_data;
    assign l2_sub_client.wr_req_strb         = merged_mem_link.wr_req_strb;
    assign merged_mem_link.wr_req_ready      = l2_sub_client.wr_req_ready;
    assign merged_mem_link.wr_rsp_valid      = l2_sub_client.wr_rsp_valid;
    assign merged_mem_link.wr_rsp_id         = l2_sub_client.wr_rsp_id;
    assign merged_mem_link.wr_rsp_error      = l2_sub_client.wr_rsp_error;
    assign l2_sub_client.wr_rsp_ready        = merged_mem_link.wr_rsp_ready;
    assign l2_sub_client.probe_release_valid = 1'b0;
    assign l2_sub_client.probe_release_addr  = '0;
    assign l2_sub_client.probe_release_data  = '0;
    assign l2_sub_client.release_valid       = 1'b0;
    assign l2_sub_client.release_addr        = '0;
    assign l2_sub_client.release_data        = '0;
    assign l2_sub_client.release_has_data    = 1'b0;
    assign l2_sub_client.release_mask        = 1'b0;
    assign l2_sub_client.release_last        = 1'b0;
    assign l2_sub_client.writeback_pending   = 1'b0;
    assign l2_sub_client.atomic_lock_req     = 1'b0;
  end

  assign dm_resumereq_unused = dm_resumereq;


  rapt_dtm dtm_inst (
      .clock    (clock),
      .reset    (reset),
      .trst_n   (jtag_trst_n),
      .tck_en   (jtag_tck_en),
      .tms      (jtag_tms),
      .tdi      (jtag_tdi),
      .tdo      (jtag_tdo),
      .dmi_req  (dmi_req),
      .dmi_wr   (dmi_wr),
      .dmi_addr (dmi_addr),
      .dmi_wdata(dmi_wdata),
      .dmi_rdata(dmi_rdata),
      .dmi_resp (dmi_resp)
  );

  rapt_dm #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) dm_inst (
      .clock             (clock),
      .reset             (reset),
      .dmi_req           (dmi_req),
      .dmi_wr            (dmi_wr),
      .dmi_addr          (dmi_addr),
      .dmi_wdata         (dmi_wdata),
      .dmi_rdata         (dmi_rdata),
      .dmi_resp          (dmi_resp),
      .halted_i          (dm_halted),
      .hart_reset_i      (core_reset),
      .hart_unavailable_i(core_block),
      .halt_pc_i         (`RAPT_PC_SEXT(XLEN, dm_halt_pc)),
      .debug             (debug),
      .haltreq_o         (dm_haltreq),
      .resumereq_o       (dm_resumereq),
      .ndmreset_o        (dm_ndmreset),
      .dbg_gpr_rdata_i   (dm_dbg_gpr_rdata),
      .dbg_gpr_we_o      (dm_dbg_gpr_we),
      .dbg_gpr_addr_o    (dm_dbg_gpr_addr),
      .dbg_gpr_wdata_o   (dm_dbg_gpr_wdata),
      .sb_axi_araddr     (sb_axi.araddr),
      .sb_axi_arid       (sb_axi.arid),
      .sb_axi_arlen      (sb_axi.arlen),
      .sb_axi_arsize     (sb_axi.arsize),
      .sb_axi_arburst    (sb_axi.arburst),
      .sb_axi_arcache    (sb_axi.arcache),
      .sb_axi_arvalid    (sb_axi.arvalid),
      .sb_axi_arready    (sb_axi.arready),
      .sb_axi_rdata      (sb_axi.rdata),
      .sb_axi_rresp      (sb_axi.rresp),
      .sb_axi_rlast      (sb_axi.rlast),
      .sb_axi_rvalid     (sb_axi.rvalid),
      .sb_axi_rready     (sb_axi.rready),
      .sb_axi_awaddr     (sb_axi.awaddr),
      .sb_axi_awid       (sb_axi.awid),
      .sb_axi_awlen      (sb_axi.awlen),
      .sb_axi_awsize     (sb_axi.awsize),
      .sb_axi_awburst    (sb_axi.awburst),
      .sb_axi_awcache    (sb_axi.awcache),
      .sb_axi_awvalid    (sb_axi.awvalid),
      .sb_axi_awready    (sb_axi.awready),
      .sb_axi_wdata      (sb_axi.wdata),
      .sb_axi_wstrb      (sb_axi.wstrb),
      .sb_axi_wlast      (sb_axi.wlast),
      .sb_axi_wvalid     (sb_axi.wvalid),
      .sb_axi_wready     (sb_axi.wready),
      .sb_axi_bresp      (sb_axi.bresp),
      .sb_axi_bvalid     (sb_axi.bvalid),
      .sb_axi_bready     (sb_axi.bready)
  );


endmodule
