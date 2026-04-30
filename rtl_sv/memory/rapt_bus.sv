`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_dpi_c.svh"

module rapt_bus #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    // AXI4 Master bus
    output [     1:0] axi_arburst,
    output [     2:0] axi_arsize,
    output [     7:0] axi_arlen,
    output [     3:0] axi_arid,
    output [XLEN-1:0] axi_araddr,
    output            axi_arvalid,
    input             axi_arready,

    input  [     3:0] axi_rid,
    input             axi_rlast,
    input  [XLEN-1:0] axi_rdata,
    input  [     1:0] axi_rresp,
    input             axi_rvalid,
    output            axi_rready,

    output [     1:0] axi_awburst,
    output [     2:0] axi_awsize,
    output [     7:0] axi_awlen,
    output [     3:0] axi_awid,
    output [XLEN-1:0] axi_awaddr,   // reqired
    output            axi_awvalid,  // reqired
    input             axi_awready,  // reqired

    output              axi_wlast,   // reqired
    output [  XLEN-1:0] axi_wdata,   // reqired
    output [XLEN/8-1:0] axi_wstrb,
    output              axi_wvalid,  // reqired
    input               axi_wready,  // reqired

    /* verilator lint_off UNUSEDSIGNAL */
    input  [3:0] axi_bid,
    /* verilator lint_on UNUSEDSIGNAL */
    input  [1:0] axi_bresp,
    input        axi_bvalid,  // reqired
    output       axi_bready,  // reqired

    l1i_bus_if.slave l1i_bus,
    l1d_bus_if.slave l1d_bus,

    csr_bcast_if.in csr_bcast,
    cmu_bcast_if.in cmu_bcast,
    output io_timer_trap_o,
    output io_sw_trap_o,

    input reset
);
  typedef enum logic [2:0] {
    LD_A,
    LD_AS,
    LD_D
  } state_load_t;
  typedef enum logic [1:0] {
    LS_S_A = 0,
    LS_S_W = 1,
    LS_S_B = 2
  } state_store_t;
  typedef enum logic [3:0] {
    L1I  = 1,
    L1D  = 2,
    TLBI = 3,
    TLBD = 4
  } state_lds_t;  // load source

  logic write_done;

  logic clint_timer_int;
  logic clint_sw_int;

  logic is_clint;
  logic is_clint_write;
  logic [3:0] arid;
  logic [3:0] awid;
  logic [XLEN-1:0] clint_rdata;
  logic [XLEN-1:0] bus_araddr;
  logic arburst;
  logic [2:0] arsize;

  // Difftest: latch MMIO flag for L1D load requests
  logic l1d_load_is_mmio;

  assign axi_arid = arid;
  assign axi_awburst = 0;
  assign axi_awlen = 0;
  assign axi_awid = awid;

  state_load_t state_load;
  /* verilator lint_off UNUSEDSIGNAL */
  state_lds_t  state_load_source;
  /* verilator lint_on UNUSEDSIGNAL */
  state_lds_t  load_bridge;
  assign load_bridge = l1d_bus.arvalid ? L1D : L1I;
  // ifu read
  assign l1i_bus.rready = (state_load == LD_A && load_bridge == L1I);
  assign l1i_bus.rdata = axi_rdata;
  assign l1i_bus.rvalid = (axi_rid == L1I) && axi_rvalid;
  assign l1i_bus.rlast = (axi_rid == L1I) && axi_rlast;
  // Bus error -> fetch access-fault. AXI rresp 2'b00 = OKAY, anything else
  // (SLVERR/DECERR) is a non-OKAY response that must trap the in-flight fetch.
  assign l1i_bus.rerr = (axi_rid == L1I) && axi_rvalid && (axi_rresp != 2'b00);

  // lsu read
  assign l1d_bus.rready = (state_load == LD_A && load_bridge == L1D);
  assign is_clint = (l1d_bus.araddr == `RAPT_CLINT_MSIP)
    || (l1d_bus.araddr == `RAPT_CLINT_MTIMECMP)
    || (l1d_bus.araddr == `RAPT_CLINT_MTIMECMP_UP)
    || (l1d_bus.araddr == `RAPT_BUS_RTC_ADDR)
    || (l1d_bus.araddr == `RAPT_BUS_RTC_ADDR_UP);
  assign is_clint_write = (l1d_bus.awaddr == `RAPT_CLINT_MSIP)
    || (l1d_bus.awaddr == `RAPT_CLINT_MTIMECMP)
    || (l1d_bus.awaddr == `RAPT_CLINT_MTIMECMP_UP);
  assign l1d_bus.rdata = is_clint ? clint_rdata : axi_rdata;
  assign l1d_bus.rvalid = ((axi_rid == L1D) && axi_rvalid) || is_clint;
  assign l1d_bus.difftest_skip = is_clint || l1d_load_is_mmio;
  // Bus error -> load access-fault. CLINT path never produces non-OKAY
  // responses (synthetic responder). PTW reads share the L1D arid so a PTW
  // bus error also presents here — L1D guards the PTW path separately and
  // will cycle this rerr through the PTW handler.
  assign l1d_bus.rerr = (axi_rid == L1D) && axi_rvalid && (axi_rresp != 2'b00);

  assign axi_arburst = arburst ? 2'b01 : 2'b00;
  assign axi_arsize = arsize;
  assign axi_arlen = arburst ? 'h1 : 'h0;
  assign axi_araddr = bus_araddr;
  assign axi_arvalid = (state_load == LD_AS);
  assign axi_rready = 1;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_load <= LD_A;
      l1d_load_is_mmio <= 1'b0;
      arsize <= 3'b000;
      arburst <= 1'b0;
      bus_araddr <= '0;
      arid <= '0;
      state_load_source <= L1I;
    end else begin
      unique case (state_load)
        LD_A: begin
          if (l1d_bus.arvalid) begin
            if (is_clint) begin
            end else begin
              state_load <= LD_AS;
              bus_araddr <= l1d_bus.araddr;
              arid <= L1D;
              state_load_source <= L1D;
              l1d_load_is_mmio <= rapt_pkg::addr_mmio(l1d_bus.araddr);
              arsize <= (
                ({3{l1d_bus.rstrb == 8'h1}} & 3'b000) |
                ({3{l1d_bus.rstrb == 8'h3}} & 3'b001) |
                ({3{l1d_bus.rstrb == 8'hf}} & 3'b010) |
                ({3{l1d_bus.rstrb == 8'hff}} & 3'b011) |
                (3'b000)
              );
            end
          end else if (l1i_bus.arvalid) begin
            bus_araddr <= l1i_bus.araddr;
            state_load <= LD_AS;
            arburst <= l1i_bus.arburst;
            arid <= L1I;
            arsize <= 3'b010;  // always 4-byte: instructions are 32-bit
            state_load_source <= L1I;
          end
        end
        LD_AS: begin
          if (axi_arready) begin
            state_load <= LD_D;
            arburst <= 0;
            bus_araddr <= 'h0;
          end
        end
        LD_D: begin
          if (axi_rvalid && axi_rlast) begin
            state_load <= LD_A;
            arburst <= 0;
            bus_araddr <= 'h0;
            l1d_load_is_mmio <= 1'b0;
          end
        end
        default: state_load <= LD_A;
      endcase
    end
  end

  assign io_timer_trap_o = clint_timer_int && csr_bcast.timer_int_en;
  assign io_sw_trap_o    = clint_sw_int    && csr_bcast.sw_int_en;
  rapt_clint clint (
      .clock(clock),
      .araddr(l1d_bus.araddr),
      .out_rdata(clint_rdata),
      .awaddr(l1d_bus.awaddr),
      .wdata(l1d_bus.wdata),
      .wvalid(l1d_bus.awvalid && is_clint_write),
      .timer_int(clint_timer_int),
      .sw_int(clint_sw_int),
      .reset(reset)
  );

  state_store_t state_store;
  // lsu write
  // CLINT writes complete immediately without going through AXI
  assign l1d_bus.wready = axi_bvalid
    || (state_store == LS_S_A && l1d_bus.awvalid && is_clint_write);

  assign axi_awsize = l1d_bus.awvalid
    ? (({3{l1d_bus.wstrb == 8'h1}} & 3'b000)
      |({3{l1d_bus.wstrb == 8'h3}} & 3'b001)
      |({3{l1d_bus.wstrb == 8'hf}} & 3'b010)
      |({3{l1d_bus.wstrb == 8'hff}} & 3'b011))
    : 3'b000;
  assign axi_awaddr = l1d_bus.awvalid ? l1d_bus.awaddr : 'h0;
  assign axi_awvalid = (state_store == LS_S_A) && l1d_bus.awvalid && !is_clint_write;

  localparam logic [31:0] ADDR2BITS = $clog2(XLEN / 8);  // 2 for RV32, 3 for RV64
  logic [ADDR2BITS-1:0] awaddr_lo;
  assign awaddr_lo = axi_awaddr[ADDR2BITS-1:0];
  assign axi_wdata = l1d_bus.wdata << (awaddr_lo * 8);
  assign axi_wvalid = ((l1d_bus.wvalid) && !write_done);
  assign axi_wlast = axi_wvalid && axi_wready;
  assign axi_wstrb = l1d_bus.wstrb[XLEN/8-1:0] << awaddr_lo;

  assign axi_bready = (state_store == LS_S_W);
  // Bus error on write response. Stores reaching the bus have already
  // passed bare-mode PMA / MMU PMP checks, so a runtime werr is a configuration
  // hazard — surface it for waves but do not break the existing handshake
  // contract back to LSU (no per-store trap path on the write side today).
  assign l1d_bus.werr = axi_bvalid && (axi_bresp != 2'b00);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_A;
      write_done <= 0;
      awid <= 'h1;
    end else begin
      unique case (state_store)
        LS_S_A: begin
          if (l1d_bus.awvalid && axi_awready && !is_clint_write) begin
            state_store <= LS_S_W;
            if (axi_wready) begin
              write_done <= 1;
            end else begin
              write_done <= 0;
            end
          end
        end
        LS_S_W: begin
          if (axi_bvalid) begin
            state_store <= LS_S_A;
            write_done  <= 0;
          end else if (axi_wready) begin
            write_done <= 1;
          end
        end
        default: state_store <= LS_S_A;
      endcase
    end
  end

  // SVA: stores leaving the core must already have been screened by PMA / PMP
  // checks. A non-OKAY bresp on a committed store flags either a SoC decoder
  // misconfiguration or a PMA / SoC memory-map drift. Keep the assertion only
  // when assertions are explicitly enabled, so synthesis & default sim still
  // ride through the error via the new `werr` reporting path.
`ifdef RAPT_ASSERT_EN
  always_ff @(posedge clock) begin
    `RAPT_ASSERT(!axi_bvalid || axi_bresp == 2'b00, ("bresp error: " + axi_bresp));
  end
`endif

endmodule
