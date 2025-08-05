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

    input reset
);
  typedef enum logic [3:0] {
    LD_A,
    IF_AS,
    IF_D,
    LS_AS,
    LS_D
  } state_load_t;
  typedef enum logic [1:0] {
    LS_S_A = 0,
    LS_S_W = 1,
    LS_S_B = 2
  } state_store_t;

  logic write_done;

  logic is_clint;
  logic [3:0] arid;
  logic [3:0] awid;
  logic clint_arvalid;
  logic [XLEN-1:0] clint_rdata;
  logic [XLEN-1:0] bus_araddr;
  logic arburst;

  assign axi_arid = arid;

  assign axi_awburst = 0;
  assign axi_awlen = 0;
  assign axi_awid = awid;

  state_load_t state_load;
  always @(posedge clock) begin
    if (reset) begin
      state_load <= LD_A;
    end else begin
      unique case (state_load)
        LD_A: begin
          if (l1d_bus.arvalid) begin
            if (is_clint) begin
            end else begin
              state_load <= LS_AS;
              bus_araddr <= l1d_bus.araddr;
              arid <= 'h1;
            end
          end else if (l1i_bus.arvalid) begin
            bus_araddr <= l1i_bus.araddr;
            state_load <= IF_AS;
            arburst <= ((`YSYX_I_SDRAM_ARBURST)
              && (l1i_bus.araddr >= 'ha0000000)
              && (l1i_bus.araddr <= 'hc0000000));
            arid <= 'h2;
          end
        end
        IF_AS: begin
          if (axi_arready) begin
            state_load <= IF_D;
          end
        end
        IF_D: begin
          if (axi_rvalid) begin
            if (arburst) begin
              if (axi_rlast) begin
                state_load <= LD_A;
                arburst <= 0;
              end
            end else begin
              state_load <= LD_A;
            end
          end
        end
        LS_AS: begin
          if (axi_arready) begin
            state_load <= LS_D;
          end
        end
        LS_D: begin
          if (axi_rvalid) begin
            state_load <= LD_A;
          end
        end
        default: state_load <= LD_A;
      endcase
    end
  end

  state_store_t state_store;
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

  // ifu read
  assign l1i_bus.bus_ready = state_load == LD_A;
  assign l1i_bus.rdata = axi_rdata;
  assign l1i_bus.rvalid = (state_load == IF_D) && axi_rvalid;
  assign l1i_bus.rlast = (state_load == IF_D) && axi_rlast;

  // lsu read
  assign is_clint = (l1d_bus.araddr == `YSYX_BUS_RTC_ADDR)
    || (l1d_bus.araddr == `YSYX_BUS_RTC_ADDR_UP);
  assign l1d_bus.rdata = is_clint ? clint_rdata : axi_rdata;
  assign l1d_bus.rvalid = (state_load == LS_D && axi_rvalid) || is_clint;
  assign l1d_bus.wready = axi_bvalid;

  assign axi_arburst = arburst ? 2'b01 : 2'b00;
  assign axi_arsize = (state_load == LD_A || state_load == IF_AS) ? 3'b010 : (
           ({3{l1d_bus.rstrb == 8'h1}} & 3'b000) |
           ({3{l1d_bus.rstrb == 8'h3}} & 3'b001) |
           ({3{l1d_bus.rstrb == 8'hf}} & 3'b010) |
           (3'b000)
         );
  assign axi_arlen = arburst ? 'h1 : 'h0;
  assign axi_araddr = bus_araddr;
  assign axi_arvalid = (state_load == IF_AS) || (state_load == LS_AS);

  assign axi_rready = (state_load == IF_D || state_load == LS_D);

  // lsu write
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

  assign clint_arvalid = (l1d_bus.arvalid && is_clint);
  ysyx_clint clint (
      .clock(clock),
      .araddr(l1d_bus.araddr),
      .arvalid(clint_arvalid),
      .out_rdata(clint_rdata),
      .reset(reset)
  );

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
