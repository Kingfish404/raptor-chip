`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// rapt: cluster-level top. Aggregates one or more `rapt_core` instances and
// the cluster-shared peripherals that, per the RISC-V platform spec, must be
// shared across all harts (CLINT and PLIC today; IMSIC in the future). The
// external port set is identical to the historical single-core top so all
// existing testbenches, SoC wrappers and FPGA targets continue to work
// without changes.
//
// Today (NR_HARTS = 1) the cluster instantiates a single core; the structure
// is laid out with multi-core scaling in mind:
//   - CLINT lives here (was previously inside rapt_bus). A single CLINT
//     services all harts so `mtime` stays globally coherent and IPI / timer
//     interrupts have a single arbitration point.
//   - CLINT register accesses arrive via the regular AXI master port of each
//     core. A small 1-master / 3-target AXI router below decodes the CLINT
//     and PLIC address windows and dispatches transactions to on-cluster
//     peripherals or the off-chip `io_master` port. The per-core bus is
//     therefore entirely SoC-memory-map agnostic.
//   - When multi-core / IMSIC arrive, the router grows to NxM and the
//     interrupt fabric scales from the existing single-hart CLINT/PLIC base.
module rapt #(
    parameter int XLEN   = `RAPT_XLEN,
    parameter int MemoryReadCredits = 8,
    // Number of hart contexts in this cluster. Currently fixed at 1; the
    // value is threaded through CSR `mhartid`, the CLINT msip/mtimecmp
    // arrays, and PLIC NCTX so that scaling to N>1 only requires (a) a
    // generate block around `rapt_core`, (b) per-hart CLINT register
    // banks (already parameterised inside rapt_clint), and (c) an NxM
    // AXI router (today 1x3). Do NOT raise this without those follow-ups.
    /* verilator lint_off UNUSEDPARAM */
    parameter int NHARTS = 1
    /* verilator lint_on UNUSEDPARAM */
) (
    input clock,
    // Device writes are reported before a later SC may complete. Pending
    // holds SC while the platform drains a finite batch of notifications.
    input logic external_write_valid_i = 1'b0,
    input logic external_write_pending_i = 1'b0,
    input logic [XLEN-1:0] external_write_first_i = '0,
    input logic [XLEN-1:0] external_write_last_i = '0,


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
    // JTAG / RISC-V Debug Module ports (P0 -- see verify/jtag/README.md)
    // -----------------------------------------------------------------
    input  logic jtag_trst_n,
    input  logic jtag_tms,
    input  logic jtag_tdi,
    output logic jtag_tdo,

    input reset
);

  // ------------------------------------------------------------------
  // Per-core AXI master signals (internal).
  // The cluster-level router muxes these between cluster-internal slaves
  // and the external io_master port.
  // ------------------------------------------------------------------
  axi4_if #(.XLEN(XLEN)) core_axi ();
  axi4_if #(.XLEN(XLEN)) offchip_axi ();

  // -----------------------------------------------------------------
  // Debug Transport Module + Debug Module (cluster-level).
  // -----------------------------------------------------------------
  logic            dmi_req;
  logic            dmi_wr;
  logic [     6:0] dmi_addr;
  logic [    31:0] dmi_wdata;
  logic [    31:0] dmi_rdata;
  logic [     1:0] dmi_resp;
  logic            dm_haltreq;
  logic            dm_resumereq;
  logic            dm_ndmreset;
  logic            dm_halted;
  logic [XLEN-1:0] dm_halt_pc;
  logic            dm_commit_fire;
  /* verilator lint_off UNUSEDSIGNAL */
  logic            dm_resumereq_unused;
  logic            dm_ndmreset_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  // DM <-> core debug GPR bus (committed view + write port). x0 writes
  // are dropped inside rapt_prf; caller must hold `dm_halted` before
  // pulsing `dm_dbg_gpr_we`.
  logic [XLEN-1:0] dm_dbg_gpr_rdata;
  logic            dm_dbg_gpr_we;
  logic [     4:0] dm_dbg_gpr_addr;
  logic [XLEN-1:0] dm_dbg_gpr_wdata;

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
  clint_bus_if #(.XLEN(XLEN)) clint_bus ();

  rapt_clint clint_inst (
      .clock(clock),

      .clint_bus(clint_bus),

      .reset(reset)
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
  plic_bus_if #(.XLEN(XLEN)) plic_bus ();

  always_comb begin
    plic_bus.ext_irq = '0;
    plic_bus.ext_irq[`RAPT_PLIC_NDEV:1] = ext_irq_i;
    plic_bus.ext_irq[1] = ext_irq_i[1] | io_interrupt;
  end

  rapt_plic plic (
      .clock(clock),
      .reset(reset),

      .plic_bus(plic_bus)
  );

  rapt_router #(
      .XLEN(XLEN)
  ) axi_router (
      .clock(clock),
      .reset(reset),

      .core_axi(core_axi),
      .offchip_axi(offchip_axi),
      .clint_bus(clint_bus),
      .plic_bus(plic_bus)
  );

  // ------------------------------------------------------------------
  // CPU core (single hart today; instantiate-per-hart loop in the future).
  // ------------------------------------------------------------------
  rapt_core #(
      .XLEN(XLEN),
      .MemoryReadCredits(MemoryReadCredits)
  ) core (
      .external_write_valid_i(external_write_valid_i),
      .external_write_pending_i(external_write_pending_i),
      .external_write_first_i(external_write_first_i),
      .external_write_last_i(external_write_last_i),

      .clock(clock),

      .io_master(core_axi),

      .clint_timer_int_i(clint_bus.timer_int),
      .clint_sw_int_i   (clint_bus.sw_int),
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

      // Hart 0; multi-core build will replace with a generate index.
      .hart_id_i({XLEN{1'b0}}),

      .dm_haltreq_i (dm_haltreq),
      .halted_o     (dm_halted),
      .halt_pc_o    (dm_halt_pc),
      .commit_fire_o(dm_commit_fire),

      .dbg_gpr_rdata_o(dm_dbg_gpr_rdata),
      .dbg_gpr_we_i   (dm_dbg_gpr_we),
      .dbg_gpr_addr_i (dm_dbg_gpr_addr),
      .dbg_gpr_wdata_i(dm_dbg_gpr_wdata),

      .reset(reset)
  );

  assign dm_resumereq_unused = dm_resumereq;
  assign dm_ndmreset_unused  = dm_ndmreset;


  rapt_dtm dtm_inst (
      .clock    (clock),
      .reset    (reset),
      .trst_n   (jtag_trst_n),
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

  rapt_dm dm_inst (
      .clock          (clock),
      .reset          (reset),
      .dmi_req        (dmi_req),
      .dmi_wr         (dmi_wr),
      .dmi_addr       (dmi_addr),
      .dmi_wdata      (dmi_wdata),
      .dmi_rdata      (dmi_rdata),
      .dmi_resp       (dmi_resp),
      .halted_i       (dm_halted),
      .halt_pc_i      (dm_halt_pc),
      .commit_fire_i  (dm_commit_fire),
      .haltreq_o      (dm_haltreq),
      .resumereq_o    (dm_resumereq),
      .ndmreset_o     (dm_ndmreset),
      .dbg_gpr_rdata_i(dm_dbg_gpr_rdata),
      .dbg_gpr_we_o   (dm_dbg_gpr_we),
      .dbg_gpr_addr_o (dm_dbg_gpr_addr),
      .dbg_gpr_wdata_o(dm_dbg_gpr_wdata)
  );


endmodule
