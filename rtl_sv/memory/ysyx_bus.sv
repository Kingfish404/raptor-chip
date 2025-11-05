`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx_bus #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
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

    output            axi_wlast,   // reqired
    output [XLEN-1:0] axi_wdata,   // reqired
    output [     3:0] axi_wstrb,
    output            axi_wvalid,  // reqired
    input             axi_wready,  // reqired

    input  [3:0] axi_bid,
    input  [1:0] axi_bresp,
    input        axi_bvalid,  // reqired
    output       axi_bready,  // reqired

    l1i_bus_if.slave l1i_bus,
    l1d_bus_if.slave l1d_bus,

    csr_bcast_if.in csr_bcast,
    cmu_bcast_if.in cmu_bcast,
    output io_trap_o,

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

  logic clint_trap;

  logic is_clint;
  logic [3:0] arid;
  logic [3:0] awid;
  logic clint_arvalid;
  logic [XLEN-1:0] clint_rdata;
  logic [XLEN-1:0] bus_araddr;
  logic arburst;
  logic [2:0] arsize;

  assign axi_arid = arid;
  assign axi_awburst = 0;
  assign axi_awlen = 0;
  assign axi_awid = awid;

  state_load_t state_load;
  state_lds_t  state_load_source;
  state_lds_t  load_bridge;
  assign load_bridge = l1d_bus.arvalid ? L1D : L1I;
  // ifu read
  assign l1i_bus.rready = (state_load == LD_A && load_bridge == L1I);
  assign l1i_bus.rdata = axi_rdata;
  assign l1i_bus.rvalid = (axi_rid == L1I) && axi_rvalid;
  assign l1i_bus.rlast = (axi_rid == L1I) && axi_rlast;

  // lsu read
  assign l1d_bus.rready = (state_load == LD_A && load_bridge == L1D);
  assign is_clint = (l1d_bus.araddr == `YSYX_BUS_RTC_ADDR)
    || (l1d_bus.araddr == `YSYX_BUS_RTC_ADDR_UP);
  assign l1d_bus.rdata = is_clint ? clint_rdata : axi_rdata;
  assign l1d_bus.rvalid = ((axi_rid == L1D) && axi_rvalid) || is_clint;

  assign axi_arburst = arburst ? 2'b01 : 2'b00;
  assign axi_arsize = arsize;
  assign axi_arlen = arburst ? 'h1 : 'h0;
  assign axi_araddr = bus_araddr;
  assign axi_arvalid = (state_load == LD_AS);
  assign axi_rready = 1;

  always @(posedge clock) begin
    if (reset) begin
      state_load <= LD_A;
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
              arsize <= (
                ({3{l1d_bus.rstrb == 8'h1}} & 3'b000) |
                ({3{l1d_bus.rstrb == 8'h3}} & 3'b001) |
                ({3{l1d_bus.rstrb == 8'hf}} & 3'b010) |
                (3'b000)
              );
            end
          end else if (l1i_bus.arvalid) begin
            bus_araddr <= l1i_bus.araddr;
            state_load <= LD_AS;
            arburst <= ((`YSYX_I_SDRAM_ARBURST)
              && (l1i_bus.araddr >= 'ha0000000)
              && (l1i_bus.araddr <= 'hc0000000));
            arid <= L1I;
            arsize <= 3'b010;
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
          // TODO: remove while preventing ysyxSoC rresp==3
          if (axi_rvalid) begin
            state_load <= LD_A;
            arburst <= 0;
            bus_araddr <= 'h0;
          end
        end
        default: state_load <= LD_A;
      endcase
    end
  end

  assign clint_arvalid = (l1d_bus.arvalid && is_clint);
  assign io_trap_o = clint_trap && csr_bcast.interrupt_en;
  ysyx_clint clint (
      .clock(clock),
      .araddr(l1d_bus.araddr),
      .arvalid(clint_arvalid),
      .out_rdata(clint_rdata),

      .io_trap_o(clint_trap),
      .io_trap_received_i(cmu_bcast.time_trap),

      .reset(reset)
  );

  state_store_t state_store;
  // lsu write
  assign l1d_bus.wready = axi_bvalid;

  assign axi_awsize = l1d_bus.awvalid
    ? (({3{l1d_bus.wstrb == 8'h1}} & 3'b000)
      |({3{l1d_bus.wstrb == 8'h3}} & 3'b001)
      |({3{l1d_bus.wstrb == 8'hf}} & 3'b010))
    : 3'b000;
  assign axi_awaddr = l1d_bus.awvalid ? l1d_bus.awaddr : 'h0;
  assign axi_awvalid = (state_store == LS_S_A) && (l1d_bus.awvalid);

  logic [1:0] awaddr_lo;
  assign awaddr_lo = axi_awaddr[1:0];
  assign axi_wdata = {
    (({XLEN{awaddr_lo == 2'b00}} & {{l1d_bus.wdata}})
    |({XLEN{awaddr_lo == 2'b01}} & {{l1d_bus.wdata[23:0]}, {8'b0}})
    |({XLEN{awaddr_lo == 2'b10}} & {{l1d_bus.wdata[15:0]}, {16'b0}})
    |({XLEN{awaddr_lo == 2'b11}} & {{l1d_bus.wdata[7:0]}, {24'b0}}))
  };
  assign axi_wvalid = ((l1d_bus.wvalid) && !write_done);
  assign axi_wlast = axi_wvalid && axi_wready;
  assign axi_wstrb = {l1d_bus.wstrb[3:0] << awaddr_lo};

  assign axi_bready = (state_store == LS_S_W);

  always @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_A;
      write_done <= 0;
      awid <= 'h1;
    end else begin
      unique case (state_store)
        LS_S_A: begin
          if (l1d_bus.awvalid && axi_awready) begin
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

  always @(posedge clock) begin
    `YSYX_ASSERT(axi_rresp == 2'b00, "rresp == 2'b00");
    `YSYX_ASSERT(axi_bresp == 2'b00, "bresp == 2'b00");
    if (axi_awvalid) begin
      if ((0)
          // || (axi_awaddr >= 'h10000000 && axi_awaddr <= 'h10000005)
          || (axi_awaddr >= 'h10001000 && axi_awaddr <= 'h10001fff)
          || (axi_awaddr >= 'h10002000 && axi_awaddr <= 'h1000200f)
          || (axi_awaddr >= 'h10011000 && axi_awaddr <= 'h10012000)
          || (axi_awaddr >= 'h21000000 && axi_awaddr <= 'h211fffff)
          || (axi_awaddr >= 'hc0000000))
        begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        // $display("DIFFTEST: skip ref at aw: %h", axi_awaddr);
      end
    end
    if (axi_arvalid) begin
      if ((0)
          // || (axi_araddr >= 'h10000000 && axi_araddr <= 'h10000010)
          || (axi_araddr >= 'h10001000 && axi_araddr <= 'h10001fff)
          || (axi_araddr >= 'h10002000 && axi_araddr <= 'h1000200f)
          || (axi_araddr >= 'h10011000 && axi_araddr <= 'h10012000)
          || (axi_araddr >= 'h21000000 && axi_araddr <= 'h211fffff)
          || (axi_araddr >= 'hc0000000))
        begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        // $display("DIFFTEST: skip ref at ar: %h", axi_araddr);
      end
    end
  end

endmodule
