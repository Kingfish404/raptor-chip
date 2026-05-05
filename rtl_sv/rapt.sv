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
//   - When multi-core / IMSIC arrive, the router grows to N×M and the
//     interrupt fabric scales from the existing single-hart CLINT/PLIC base.
module rapt #(
    parameter int XLEN   = `RAPT_XLEN,
    // Number of hart contexts in this cluster. Currently fixed at 1; the
    // value is threaded through CSR `mhartid`, the CLINT msip/mtimecmp
    // arrays, and PLIC NCTX so that scaling to N>1 only requires (a) a
    // generate block around `rapt_core`, (b) per-hart CLINT register
    // banks (already parameterised inside rapt_clint), and (c) an N×M
    // AXI router (today 1×3). Do NOT raise this without those follow-ups.
    /* verilator lint_off UNUSEDPARAM */
    parameter int NHARTS = 1
    /* verilator lint_on UNUSEDPARAM */
) (
    input clock,

    // AXI4 Master
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

`ifdef RAPT_USE_SLAVE
    // AXI4 Slave (currently unused; preserved for backwards-compat with the
    // historical top-level port list).
    // verilator lint_off UNDRIVEN
    // verilator lint_off UNUSEDSIGNAL
    input  [     1:0] io_slave_arburst,
    input  [     2:0] io_slave_arsize,
    input  [     7:0] io_slave_arlen,
    input  [     3:0] io_slave_arid,
    input  [XLEN-1:0] io_slave_araddr,
    input             io_slave_arvalid,
    output            io_slave_arready,

    output [     3:0] io_slave_rid,
    output            io_slave_rlast,
    output [XLEN-1:0] io_slave_rdata,
    output [     1:0] io_slave_rresp,
    output            io_slave_rvalid,
    input             io_slave_rready,

    input  [     1:0] io_slave_awburst,
    input  [     2:0] io_slave_awsize,
    input  [     7:0] io_slave_awlen,
    input  [     3:0] io_slave_awid,
    input  [XLEN-1:0] io_slave_awaddr,
    input             io_slave_awvalid,
    output            io_slave_awready,

    input             io_slave_wlast,
    input  [XLEN-1:0] io_slave_wdata,
    input  [     3:0] io_slave_wstrb,
    input             io_slave_wvalid,
    output            io_slave_wready,

    output [3:0] io_slave_bid,
    output [1:0] io_slave_bresp,
    output       io_slave_bvalid,
    input        io_slave_bready,
    // verilator lint_on UNDRIVEN
    // verilator lint_on UNUSEDSIGNAL
`endif

`ifdef RAPT_RVFI
    // RISC-V Formal Interface (RVFI) outputs — NRET=2 channels
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

    input io_interrupt,

    // Per-source external interrupt lines into the cluster PLIC. Source 0
    // is reserved by the PLIC spec, so external aggregators feed sources
    // 1..NDEV. Wrappers that don't have peripherals tie this to '0.
    input [`RAPT_PLIC_NDEV:1] ext_irq_i,

    // -----------------------------------------------------------------
    // JTAG / RISC-V Debug Module ports (P0 — see docs-ref/dev.jtag.md)
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
  logic [XLEN-1:0] dm_dbg_gpr_rdata    [`RAPT_REG_SIZE];
  logic            dm_dbg_gpr_we;
  logic [     4:0] dm_dbg_gpr_addr;
  logic [XLEN-1:0] dm_dbg_gpr_wdata;

  assign io_master_arburst = offchip_axi.arburst;
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
      .XLEN(XLEN)
  ) core (
      .clock(clock),

      .io_master(core_axi),

      .clint_timer_int_i(clint_bus.timer_int),
      .clint_sw_int_i   (clint_bus.sw_int),

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

`ifdef RAPT_USE_SLAVE
  // Tie off the unused AXI4 slave port at the cluster boundary. The legacy
  // top kept these in the port list but never wired them; preserving the
  // behaviour avoids surprises for any external consumer.
  assign io_slave_arready = 1'b0;
  assign io_slave_rid     = '0;
  assign io_slave_rlast   = 1'b0;
  assign io_slave_rdata   = '0;
  assign io_slave_rresp   = 2'b00;
  assign io_slave_rvalid  = 1'b0;
  assign io_slave_awready = 1'b0;
  assign io_slave_wready  = 1'b0;
  assign io_slave_bid     = '0;
  assign io_slave_bresp   = 2'b00;
  assign io_slave_bvalid  = 1'b0;
`endif

endmodule
