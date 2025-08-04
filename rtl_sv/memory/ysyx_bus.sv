`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx_bus #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    // AXI4 Master bus
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output io_master_arvalid,
    input io_master_arready,

    input [3:0] io_master_rid,
    input io_master_rlast,
    input [XLEN-1:0] io_master_rdata,
    input [1:0] io_master_rresp,
    input io_master_rvalid,
    output io_master_rready,

    output [     1:0] io_master_awburst,
    output [     2:0] io_master_awsize,
    output [     7:0] io_master_awlen,
    output [     3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,   // reqired
    output            io_master_awvalid,  // reqired
    input             io_master_awready,  // reqired

    output            io_master_wlast,   // reqired
    output [XLEN-1:0] io_master_wdata,   // reqired
    output [     3:0] io_master_wstrb,
    output            io_master_wvalid,  // reqired
    input             io_master_wready,  // reqired

    input  [3:0] io_master_bid,
    input  [1:0] io_master_bresp,
    input        io_master_bvalid,  // reqired
    output       io_master_bready,  // reqired

    l1i_bus_if.slave l1i_bus,
    l1d_bus_if.slave l1d_bus,

    input reset
);
  typedef enum {
    IF_A,
    IF_AS,
    IF_D,
    IF_B,
    LS_A,
    LS_AS,
    LS_R,
    LS_R_FLUSHED
  } state_load_t;
  typedef enum {
    LS_S_A = 0,
    LS_S_W = 1,
    LS_S_B = 2
  } state_store_t;

  logic rvalid;
  logic write_done;

  // lsu read
  logic [XLEN-1:0] io_rdata;
  logic is_clint;

  logic clint_arvalid, clint_arready;
  logic [XLEN-1:0] clint_rdata;
  logic [XLEN-1:0] rdata;

  logic [XLEN-1:0] bus_araddr;
  logic arburst;

  assign io_master_arid = 0;

  assign io_master_awburst = 0;
  assign io_master_awlen = 0;
  assign io_master_awid = 0;

  state_load_t state_load;
  always @(posedge clock) begin
    if (reset) begin
      state_load <= IF_A;
    end else begin
      unique case (state_load)
        IF_A: begin
          if (l1i_bus.arvalid) begin
            bus_araddr <= l1i_bus.araddr;
            state_load <= IF_AS;
          end else if (l1d_bus.arvalid && !is_clint) begin
            bus_araddr <= l1d_bus.araddr;
            state_load <= LS_AS;
          end
        end
        IF_AS: begin
          if (io_master_arready) begin
            state_load <= IF_D;
            arburst <= ifu_sdram_arburst;
          end
        end
        IF_D: begin
          if (io_master_rvalid) begin
            state_load <= IF_B;
            rdata <= io_master_rdata;
          end
        end
        IF_B: begin
          if (arburst) begin
            state_load <= IF_D;
            arburst <= 0;
          end else begin
            state_load <= IF_A;
          end
        end
        LS_A: begin
          if (l1d_bus.arvalid && !is_clint) begin
            if (io_master_arready) begin
              state_load <= LS_R;
            end else begin
              state_load <= LS_AS;
              bus_araddr <= l1d_bus.araddr;
            end
          end else if (is_clint || l1i_bus.arvalid) begin
            state_load <= IF_A;
          end
        end
        LS_AS: begin
          if (io_master_arready) begin
            state_load <= LS_R;
          end
        end
        LS_R: begin
          if (io_master_rvalid) begin
            state_load <= LS_A;
          end
        end
        LS_R_FLUSHED: begin
          if (io_master_rvalid) begin
            state_load <= LS_A;
          end
        end
        default: state_load <= LS_A;
      endcase
    end
  end

  state_store_t state_store;
  always @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_A;
      write_done  <= 0;
    end else begin
      unique case (state_store)
        LS_S_A: begin
          if (l1d_bus.awvalid && io_master_awready) begin
            state_store <= LS_S_W;
            if (io_master_wready) begin
              write_done <= 1;
            end else begin
              write_done <= 0;
            end
          end
        end
        LS_S_W: begin
          if (io_master_bvalid) begin
            state_store <= LS_S_A;
            write_done  <= 0;
          end else if (io_master_wready) begin
            write_done  <= 1;
            state_store <= LS_S_B;
          end
        end
        LS_S_B: begin
          if (io_master_bvalid) begin
            state_store <= LS_S_A;
            write_done  <= 0;
          end
        end
        default: state_store <= LS_S_A;
      endcase
    end
  end

  // ifu read
  assign l1i_bus.bus_ready = state_load == IF_A;
  assign l1i_bus.rready = (state_load == IF_B);
  assign l1i_bus.rdata = rdata;

  assign is_clint = (l1d_bus.araddr == `YSYX_BUS_RTC_ADDR)
    || (l1d_bus.araddr == `YSYX_BUS_RTC_ADDR_UP);
  assign l1d_bus.rdata = is_clint ? clint_rdata : io_rdata;
  assign l1d_bus.rvalid = (state_load == LS_R && rvalid) || is_clint;
  assign l1d_bus.wready = io_master_bvalid;

  // lsu write
  // assign out_lsu_wready = io_master_bvalid;

  // io lsu read
  logic ifu_sdram_arburst;
  assign ifu_sdram_arburst = (
    `YSYX_I_SDRAM_ARBURST && (state_load == IF_AS || state_load == IF_D) &&
    (bus_araddr >= 'ha0000000) && (bus_araddr <= 'hc0000000));
  assign io_master_arburst = ifu_sdram_arburst ? 2'b01 : 2'b00;
  assign io_master_arsize = (state_load == IF_A || state_load == IF_AS) ? 3'b010 : (
           ({3{l1d_bus.rstrb == 8'h1}} & 3'b000) |
           ({3{l1d_bus.rstrb == 8'h3}} & 3'b001) |
           ({3{l1d_bus.rstrb == 8'hf}} & 3'b010) |
           (3'b000)
         );
  assign io_master_arlen = ifu_sdram_arburst ? 'h1 : 'h0;
  assign io_master_araddr = (state_load == LS_A && l1d_bus.arvalid && !is_clint)
    ? l1d_bus.araddr
    : bus_araddr;
  assign io_master_arvalid = ((state_load == IF_AS) || (
    (state_load == LS_A && l1d_bus.arvalid && !is_clint)
    || (state_load == LS_AS)));

  // logic [XLEN-1:0] io_rdata;
  // assign io_rdata = (io_master_araddr[2:2] == 1) ? io_master_rdata[63:32] : io_master_rdata[31:00];
  assign io_rdata = io_master_rdata;
  assign rvalid = io_master_rvalid;
  assign io_master_rready = (state_load == IF_D ||
            state_load == LS_R || state_load == LS_R_FLUSHED);

  // io lsu write
  assign io_master_awsize = l1d_bus.awvalid
    ? (({3{l1d_bus.wstrb == 8'h1}} & 3'b000)
      |({3{l1d_bus.wstrb == 8'h3}} & 3'b001)
      |({3{l1d_bus.wstrb == 8'hf}} & 3'b010))
    : 3'b000;
  assign io_master_awaddr = l1d_bus.awvalid ? l1d_bus.awaddr : 'h0;
  assign io_master_awvalid = (state_store == LS_S_A) && (l1d_bus.awvalid);

  logic [1:0] awaddr_lo;
  logic [XLEN-1:0] wdata;
  logic [3:0] wstrb;
  assign awaddr_lo = io_master_awaddr[1:0];
  assign wdata = {
    ({XLEN{awaddr_lo == 2'b00}} & {{l1d_bus.wdata}})
    |({XLEN{awaddr_lo == 2'b01}} & {{l1d_bus.wdata[23:0]}, {8'b0}})
    |({XLEN{awaddr_lo == 2'b10}} & {{l1d_bus.wdata[15:0]}, {16'b0}})
    |({XLEN{awaddr_lo == 2'b11}} & {{l1d_bus.wdata[7:0]}, {24'b0}})
  };
  assign io_master_wdata = wdata;
  assign io_master_wvalid = (
    (((state_store == LS_S_A) && (l1d_bus.awvalid)) || (state_store == LS_S_W))
    && (l1d_bus.wvalid)
    && !write_done);
  assign io_master_wlast = io_master_wvalid && io_master_wready;
  assign io_master_wstrb = {wstrb};
  assign wstrb = {l1d_bus.wstrb[3:0] << awaddr_lo};

  assign io_master_bready = (state_store == LS_S_B) || (state_store == LS_S_W);

  always @(posedge clock) begin
    `YSYX_ASSERT(io_master_rresp == 2'b00, "rresp == 2'b00");
    `YSYX_ASSERT(io_master_bresp == 2'b00, "bresp == 2'b00");
    if (io_master_awvalid) begin
      if ((0)
          // || (io_master_awaddr >= 'h10000000 && io_master_awaddr <= 'h10000005)
          || (io_master_awaddr >= 'h10001000 && io_master_awaddr <= 'h10001fff)
          || (io_master_awaddr >= 'h10002000 && io_master_awaddr <= 'h1000200f)
          || (io_master_awaddr >= 'h10011000 && io_master_awaddr <= 'h10012000)
          || (io_master_awaddr >= 'h21000000 && io_master_awaddr <= 'h211fffff)
          || (io_master_awaddr >= 'hc0000000))
        begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        // $display("DIFFTEST: skip ref at aw: %h", io_master_awaddr);
      end
    end
    if (io_master_arvalid) begin
      if ((0)
          // || (io_master_araddr >= 'h10000000 && io_master_araddr <= 'h10000010)
          || (io_master_araddr >= 'h10001000 && io_master_araddr <= 'h10001fff)
          || (io_master_araddr >= 'h10002000 && io_master_araddr <= 'h1000200f)
          || (io_master_araddr >= 'h10011000 && io_master_araddr <= 'h10012000)
          || (io_master_araddr >= 'h21000000 && io_master_araddr <= 'h211fffff)
          || (io_master_araddr >= 'hc0000000))
        begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        // $display("DIFFTEST: skip ref at ar: %h", io_master_araddr);
      end
    end
  end

  assign clint_arvalid = (l1d_bus.arvalid && is_clint);
  ysyx_clint clint (
      .clock(clock),
      .araddr(l1d_bus.araddr),
      .arvalid(clint_arvalid),
      .out_arready(clint_arready),
      .out_rdata(clint_rdata),
      .reset(reset)
  );
endmodule
