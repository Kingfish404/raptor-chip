`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

module rapt_router #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,
    input reset,

    axi4_if.slave core_axi,
    axi4_if.master offchip_axi,
    clint_bus_if.master clint_bus,
    plic_bus_if.master plic_bus
);
  typedef enum logic [1:0] {
    INT_NONE  = 2'd0,
    INT_CLINT,
    INT_PLIC
  } int_slave_t;

  localparam int IntByteOffW = $clog2(XLEN / 8);

  function automatic logic [XLEN-1:0] internal_rdata_to_axi(input logic [XLEN-1:0] data,
                                                            input logic [IntByteOffW-1:0] byte_off);
    logic [$clog2(XLEN)-1:0] shamt;
    begin
      shamt = {byte_off, 3'b000};
      internal_rdata_to_axi = data << shamt;
    end
  endfunction

  function automatic logic [XLEN-1:0] axi_wdata_to_internal(input logic [XLEN-1:0] data,
                                                            input logic [IntByteOffW-1:0] byte_off);
    logic [$clog2(XLEN)-1:0] shamt;
    begin
      shamt = {byte_off, 3'b000};
      axi_wdata_to_internal = data >> shamt;
    end
  endfunction

  function automatic int_slave_t addr_decode(input logic [XLEN-1:0] a);
    if ((a >= `RAPT_CLINT_BASE) && (a < (`RAPT_CLINT_BASE + XLEN'(32'h000c0000)))) begin
      addr_decode = INT_CLINT;
    end else if ((a >= `RAPT_PLIC_BASE) && (a < `RAPT_PLIC_BASE + `RAPT_PLIC_SIZE)) begin
      addr_decode = INT_PLIC;
    end else begin
      addr_decode = INT_NONE;
    end
  endfunction

  // Live read addresses fan out to all internal slaves (combinational reads).
  assign clint_bus.araddr = core_axi.araddr;
  assign plic_bus.araddr  = core_axi.araddr;

  // ----- Read channel router -----
  typedef enum logic [1:0] {
    R_IDLE,
    R_INT,
    R_IO
  } r_state_t;

  r_state_t r_state, r_state_next;
  logic       [     3:0] r_int_id;
  logic       [XLEN-1:0] r_int_data;

  int_slave_t            ar_int;
  logic                  ar_is_int;
  assign ar_int = addr_decode(core_axi.araddr);
  assign ar_is_int = (ar_int != INT_NONE);

  assign offchip_axi.arvalid = core_axi.arvalid && !ar_is_int && (r_state == R_IDLE);
  assign offchip_axi.arburst = core_axi.arburst;
  assign offchip_axi.arsize = core_axi.arsize;
  assign offchip_axi.arlen = core_axi.arlen;
  assign offchip_axi.arid = core_axi.arid;
  assign offchip_axi.araddr = core_axi.araddr;

  assign core_axi.arready = (r_state == R_IDLE) && (ar_is_int ? 1'b1 : offchip_axi.arready);

  assign plic_bus.ar_commit = (r_state == R_IDLE) && core_axi.arvalid && core_axi.arready
                              && (ar_int == INT_PLIC);

  assign core_axi.rvalid = (r_state == R_INT) || ((r_state == R_IO) && offchip_axi.rvalid);
  assign core_axi.rdata = (r_state == R_INT) ? r_int_data : offchip_axi.rdata;
  assign core_axi.rid = (r_state == R_INT) ? r_int_id : offchip_axi.rid;
  assign core_axi.rlast = (r_state == R_INT) ? 1'b1 : offchip_axi.rlast;
  assign core_axi.rresp = (r_state == R_INT) ? 2'b00 : offchip_axi.rresp;

  assign offchip_axi.rready = (r_state == R_IO) && core_axi.rready;

  always_comb begin
    r_state_next = r_state;
    unique case (r_state)
      R_IDLE: begin
        if (core_axi.arvalid && core_axi.arready) r_state_next = ar_is_int ? R_INT : R_IO;
      end
      R_INT: begin
        if (core_axi.rvalid && core_axi.rready) r_state_next = R_IDLE;
      end
      R_IO: begin
        if (offchip_axi.rvalid && offchip_axi.rready && offchip_axi.rlast) r_state_next = R_IDLE;
      end
      default: r_state_next = R_IDLE;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      r_state    <= R_IDLE;
      r_int_id   <= '0;
      r_int_data <= '0;
    end else begin
      r_state <= r_state_next;
      if (r_state == R_IDLE && core_axi.arvalid && core_axi.arready && ar_is_int) begin
        r_int_id <= core_axi.arid;
        unique case (ar_int)
          INT_CLINT:
          r_int_data <= internal_rdata_to_axi(clint_bus.rdata, core_axi.araddr[IntByteOffW-1:0]);
          INT_PLIC:
          r_int_data <= internal_rdata_to_axi(plic_bus.rdata, core_axi.araddr[IntByteOffW-1:0]);
          default: r_int_data <= '0;
        endcase
      end
    end
  end

  // ----- Write channel router -----
  typedef enum logic [2:0] {
    W_IDLE,
    W_INT_W,
    W_INT_B,
    W_IO_W,
    W_IO_B
  } w_state_t;

  w_state_t w_state, w_state_next;
  int_slave_t            w_int_target;
  logic       [     3:0] w_int_id;
  logic       [XLEN-1:0] w_int_awaddr;
  logic       [XLEN-1:0] w_int_data;

  assign clint_bus.awaddr = (w_int_target == INT_CLINT) ? w_int_awaddr : '0;
  assign plic_bus.awaddr  = (w_int_target == INT_PLIC) ? w_int_awaddr : '0;

  int_slave_t aw_int;
  logic       aw_is_int;
  assign aw_int = addr_decode(core_axi.awaddr);
  assign aw_is_int = (aw_int != INT_NONE);

  assign offchip_axi.awvalid = (w_state == W_IDLE) && core_axi.awvalid && !aw_is_int;
  assign offchip_axi.awburst = core_axi.awburst;
  assign offchip_axi.awsize = core_axi.awsize;
  assign offchip_axi.awlen = core_axi.awlen;
  assign offchip_axi.awid = core_axi.awid;
  assign offchip_axi.awaddr = core_axi.awaddr;

  assign core_axi.awready = (w_state == W_IDLE) && (aw_is_int ? 1'b1 : offchip_axi.awready);

  assign offchip_axi.wvalid = (w_state == W_IO_W) && core_axi.wvalid;
  assign offchip_axi.wlast = core_axi.wlast;
  assign offchip_axi.wdata = core_axi.wdata;
  assign offchip_axi.wstrb = core_axi.wstrb;

  assign core_axi.wready = (w_state == W_INT_W) || ((w_state == W_IO_W) && offchip_axi.wready);

  assign w_int_data = axi_wdata_to_internal(core_axi.wdata, w_int_awaddr[IntByteOffW-1:0]);
  assign clint_bus.wdata = w_int_data;
  assign plic_bus.wdata = w_int_data;
  assign clint_bus.wvalid = (w_state == W_INT_W) && core_axi.wvalid && core_axi.wready
                            && (w_int_target == INT_CLINT);
  assign plic_bus.wvalid  = (w_state == W_INT_W) && core_axi.wvalid && core_axi.wready
                            && (w_int_target == INT_PLIC);

  assign core_axi.bvalid = (w_state == W_INT_B) || ((w_state == W_IO_B) && offchip_axi.bvalid);
  assign core_axi.bid = (w_state == W_INT_B) ? w_int_id : offchip_axi.bid;
  assign core_axi.bresp = (w_state == W_INT_B) ? 2'b00 : offchip_axi.bresp;

  assign offchip_axi.bready = (w_state == W_IO_B) && core_axi.bready;

  always_comb begin
    w_state_next = w_state;
    unique case (w_state)
      W_IDLE: begin
        if (core_axi.awvalid && core_axi.awready) w_state_next = aw_is_int ? W_INT_W : W_IO_W;
      end
      W_INT_W: begin
        if (core_axi.wvalid && core_axi.wready) w_state_next = W_INT_B;
      end
      W_INT_B: begin
        if (core_axi.bvalid && core_axi.bready) w_state_next = W_IDLE;
      end
      W_IO_W: begin
        if (core_axi.wvalid && core_axi.wready && core_axi.wlast) w_state_next = W_IO_B;
      end
      W_IO_B: begin
        if (offchip_axi.bvalid && offchip_axi.bready) w_state_next = W_IDLE;
      end
      default: w_state_next = W_IDLE;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      w_state      <= W_IDLE;
      w_int_target <= INT_NONE;
      w_int_id     <= '0;
      w_int_awaddr <= '0;
    end else begin
      w_state <= w_state_next;
      if (w_state == W_IDLE && core_axi.awvalid && core_axi.awready && aw_is_int) begin
        w_int_target <= aw_int;
        w_int_id     <= core_axi.awid;
        w_int_awaddr <= core_axi.awaddr;
      end
    end
  end
endmodule
