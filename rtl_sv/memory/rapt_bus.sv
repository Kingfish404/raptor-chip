`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

module rapt_bus #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    // AXI4 Master bus
    axi4_if.master axi,

    l1i_bus_if.slave l1i_bus,
    l1d_bus_if.slave l1d_bus,

    csr_bcast_if.in csr_bcast,
    cmu_bcast_if.in cmu_bcast,

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

  logic [3:0] arid;
  logic [3:0] awid;
  logic [XLEN-1:0] bus_araddr;
  logic arburst;
  logic [2:0] arsize;

  // Difftest: latch MMIO flag for L1D load requests
  logic l1d_load_is_mmio;

  state_load_t state_load;
  state_store_t state_store;
  /* verilator lint_off UNUSEDSIGNAL */
  state_lds_t  state_load_source;
  /* verilator lint_on UNUSEDSIGNAL */
  state_lds_t  load_bridge;
  state_lds_t  store_bridge;
  state_lds_t  store_source;
  state_lds_t  store_current;

  assign axi.arid = arid;
  assign axi.awburst = 0;
  assign axi.awlen = 0;
  assign axi.awid = (state_store == LS_S_A) ? store_bridge : awid;

  assign load_bridge = l1d_bus.arvalid ? L1D : L1I;
  assign store_bridge = l1i_bus.awvalid ? L1I : L1D;
  assign store_current = (state_store == LS_S_A) ? store_bridge : store_source;
  // ifu read
  assign l1i_bus.rready = (state_load == LD_A && load_bridge == L1I);
  assign l1i_bus.rdata = axi.rdata;
  assign l1i_bus.rvalid = (axi.rid == L1I) && axi.rvalid;
  assign l1i_bus.rlast = (axi.rid == L1I) && axi.rlast;
  // Bus error -> fetch access-fault. AXI rresp 2'b00 = OKAY, anything else
  // (SLVERR/DECERR) is a non-OKAY response that must trap the in-flight fetch.
  assign l1i_bus.rerr = (axi.rid == L1I) && axi.rvalid && (axi.rresp != 2'b00);
  assign l1i_bus.wready = (store_source == L1I) && axi.bvalid;
  assign l1i_bus.werr = (store_source == L1I) && axi.bvalid && (axi.bresp != 2'b00);

  // lsu read.
  // CLINT/PLIC and any other on-cluster MMIO peripherals are addressed uniformly
  // through the AXI master port: a cluster-level address decoder routes
  // local transactions to the shared cluster peripherals and forwards
  // everything else off-chip. The bus is therefore agnostic to the SoC
  // memory map.
  assign l1d_bus.rready = (state_load == LD_A && load_bridge == L1D);
  assign l1d_bus.rdata = axi.rdata;
  assign l1d_bus.rvalid = (axi.rid == L1D) && axi.rvalid;
  assign l1d_bus.difftest_skip = l1d_load_is_mmio;
  // Bus error -> load access-fault. PTW reads share the L1D arid so a PTW
  // bus error also presents here — L1D guards the PTW path separately and
  // will cycle this rerr through the PTW handler.
  assign l1d_bus.rerr = (axi.rid == L1D) && axi.rvalid && (axi.rresp != 2'b00);

  assign axi.arburst = arburst ? 2'b01 : 2'b00;
  assign axi.arsize = arsize;
  assign axi.arlen = arburst ? 'h1 : 'h0;
  assign axi.araddr = bus_araddr;
  assign axi.arvalid = (state_load == LD_AS);
  assign axi.rready = 1;

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
          if (axi.arready) begin
            state_load <= LD_D;
            arburst <= 0;
            bus_araddr <= 'h0;
          end
        end
        LD_D: begin
          if (axi.rvalid && axi.rlast) begin
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

  logic [XLEN-1:0] store_awaddr;
  logic [XLEN-1:0] store_wdata;
  logic [7:0] store_wstrb_aw;
  logic [XLEN/8-1:0] store_wstrb;
  logic store_awvalid;
  logic store_wvalid;

  assign store_awaddr = (store_bridge == L1I) ? l1i_bus.awaddr : l1d_bus.awaddr;
  assign store_wdata  = (store_current == L1I) ? l1i_bus.wdata  : l1d_bus.wdata;
  assign store_wstrb_aw = (store_bridge == L1I) ? l1i_bus.wstrb : l1d_bus.wstrb;
  assign store_wstrb = (store_current == L1I) ? l1i_bus.wstrb[XLEN/8-1:0]
                                               : l1d_bus.wstrb[XLEN/8-1:0];
  assign store_awvalid = (store_bridge == L1I) ? l1i_bus.awvalid : l1d_bus.awvalid;
  assign store_wvalid = (store_current == L1I) ? l1i_bus.wvalid : l1d_bus.wvalid;

  // lsu/IPTW write
  assign l1d_bus.wready = (store_source == L1D) && axi.bvalid;

  assign axi.awsize = store_awvalid
    ? (({3{store_wstrb_aw == 8'h1}} & 3'b000)
      |({3{store_wstrb_aw == 8'h3}} & 3'b001)
      |({3{store_wstrb_aw == 8'hf}} & 3'b010)
      |({3{store_wstrb_aw == 8'hff}} & 3'b011))
    : 3'b000;
  assign axi.awaddr = store_awvalid ? store_awaddr : 'h0;
  assign axi.awvalid = (state_store == LS_S_A) && store_awvalid;

  localparam logic [31:0] ADDR2BITS = $clog2(XLEN / 8);  // 2 for RV32, 3 for RV64
  logic [ADDR2BITS-1:0] awaddr_lo;
  assign awaddr_lo = axi.awaddr[ADDR2BITS-1:0];
  assign axi.wdata = store_wdata << (awaddr_lo * 8);
  assign axi.wvalid = store_wvalid && !write_done;
  assign axi.wlast = axi.wvalid && axi.wready;
  assign axi.wstrb = store_wstrb << awaddr_lo;

  assign axi.bready = (state_store == LS_S_W);
  // Bus error on write response. Stores reaching the bus have already
  // passed bare-mode PMA / MMU PMP checks, so a runtime werr is a configuration
  // hazard — surface it for waves but do not break the existing handshake
  // contract back to LSU (no per-store trap path on the write side today).
  assign l1d_bus.werr = (store_source == L1D) && axi.bvalid && (axi.bresp != 2'b00);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_A;
      write_done <= 0;
      awid <= 'h1;
      store_source <= L1D;
    end else begin
      unique case (state_store)
        LS_S_A: begin
          if (store_awvalid && axi.awready) begin
            store_source <= store_bridge;
            awid <= store_bridge;
            state_store <= LS_S_W;
            if (axi.wready) begin
              write_done <= 1;
            end else begin
              write_done <= 0;
            end
          end
        end
        LS_S_W: begin
          if (axi.bvalid) begin
            state_store <= LS_S_A;
            write_done  <= 0;
          end else if (axi.wready) begin
            write_done <= 1;
          end
        end
        default: state_store <= LS_S_A;
      endcase
    end
  end

  // SVA: stores leaving the core must already have been screened by PMA / PMP
  // checks. A non-OKAY bresp on a committed store flags either a SoC decoder
  // misconfiguration or a PMA / SoC memory-map drift. Use the central SVA macro
  // so this check is completely absent from FPGA/ASIC synthesis.
  `RAPT_SVA_IMPLY(clock, reset, BUS_STORE_BRESP_OK,
                  axi.bvalid, axi.bresp == 2'b00)

endmodule
