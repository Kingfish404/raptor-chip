`include "rapt_soc_if.svh"

// Local peripherals precede either serial backend. One accepted AXI transaction
// owns the route through its last response; peripheral reads take effect once
// at AR acceptance and their result is held through response backpressure.
module rapt_chip_local_io #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int unsigned CoreClockHz = 100_000_000
) (
    input logic clock,
    input logic reset,
    axi4_if.slave axi,
    axi4_if.master backend,
    input logic [1:0] uart_rx_i,
    output logic [1:0] uart_tx_o,
    output logic [1:0] uart_irq_o,
    input logic [2:0] gpio_i,
    output logic [2:0] gpio_o,
    output logic [2:0] gpio_oe_o
);
  localparam int Bytes = XLEN / 8;
  localparam int LaneBits = $clog2(Bytes);
  localparam logic [1:0] Okay = 2'b00, Slverr = 2'b10;
  typedef enum logic [2:0] {
    IDLE,
    EXTERNAL_READ,
    EXTERNAL_WRITE,
    LOCAL_READ,
    LOCAL_WRITE,
    LOCAL_RESPONSE
  } state_t;
  state_t state_q;
  logic prefer_write_q, choose_write, choose_read;
  logic offer_lock_q, offer_write_q;
  logic read_local, write_local, read_accept, write_accept, read_ok, write_ok;
  logic access_ok_q;
  logic [XLEN-1:0] address_q, read_data_q;
  logic [3:0] id_q;
  logic [7:0] length_q, beat_q;
  logic [2:0] size_q;
  logic [1:0] response_q;
  logic [1:0] uart_read, uart_write, uart_irq, uart_tx;
  logic [7:0] uart_data[2];
  logic [2:0] uart_address;
  logic [7:0] uart_wdata;
  logic [31:0] read_word;
  logic [Bytes-1:0] write_mask;
  logic valid_write, commit_write;
  logic [2:0] gpio_value_q, gpio_enable_q, gpio_open_drain_q;
  (* ASYNC_REG = "TRUE" *) logic [2:0] gpio_meta_q, gpio_sync_q;

  function automatic logic local_address(input logic [XLEN-1:0] address);
    return address >= XLEN'(32'h10000000) && address < XLEN'(32'h10000300);
  endfunction

  function automatic logic valid_access(input logic [XLEN-1:0] address, input logic [2:0] size,
                                        input logic [7:0] length, input logic [1:0] burst,
                                        input logic writing);
    if (length != 0 || size > 2 || burst > 1) return 1'b0;
    if ((address & ((XLEN'(1) << size) - 1'b1)) != 0) return 1'b0;
    case (address[9:8])
      0, 1: return address[7:0] < 8;
      2: return size == 2 && (address[7:0] == 4 || address[7:0] == 8
          || address[7:0] == 12 || (!writing && address[7:0] == 0));
      default: return 1'b0;
    endcase
  endfunction

  assign read_local = local_address(axi.araddr);
  assign write_local = local_address(axi.awaddr);
  // Preserve an offered backend address until acceptance. A late request on
  // the competing channel must not withdraw VALID from a stalled transfer.
  assign choose_write = offer_lock_q ? offer_write_q
      : axi.awvalid && (prefer_write_q || !axi.arvalid);
  assign choose_read = axi.arvalid && !choose_write;
  assign read_accept = axi.arvalid && axi.arready;
  assign write_accept = axi.awvalid && axi.awready;
  assign read_ok = valid_access(axi.araddr, axi.arsize, axi.arlen, axi.arburst, 1'b0);
  assign write_ok = valid_access(axi.awaddr, axi.awsize, axi.awlen, axi.awburst, 1'b1);

  assign backend.araddr = axi.araddr;
  assign backend.arid = axi.arid;
  assign backend.arlen = axi.arlen;
  assign backend.arsize = axi.arsize;
  assign backend.arburst = axi.arburst;
  assign backend.arcache = axi.arcache;
  assign backend.arvalid = !reset && state_q == IDLE && choose_read && !read_local;
  assign backend.rready = !reset && state_q == EXTERNAL_READ && axi.rready;
  assign backend.awaddr = axi.awaddr;
  assign backend.awid = axi.awid;
  assign backend.awlen = axi.awlen;
  assign backend.awsize = axi.awsize;
  assign backend.awburst = axi.awburst;
  assign backend.awcache = axi.awcache;
  assign backend.awvalid = !reset && state_q == IDLE && choose_write && !write_local;
  assign backend.wdata = axi.wdata;
  assign backend.wstrb = axi.wstrb;
  assign backend.wlast = axi.wlast;
  assign backend.wvalid = !reset && state_q == EXTERNAL_WRITE && axi.wvalid;
  assign backend.bready = !reset && state_q == EXTERNAL_WRITE && axi.bready;

  assign axi.arready = !reset && state_q == IDLE && choose_read
      && (read_local || backend.arready);
  assign axi.awready = !reset && state_q == IDLE && choose_write
      && (write_local || backend.awready);
  assign axi.wready = !reset && (state_q == LOCAL_WRITE
      || (state_q == EXTERNAL_WRITE && backend.wready));
  assign axi.rvalid = !reset && (state_q == LOCAL_READ
      || (state_q == EXTERNAL_READ && backend.rvalid));
  assign axi.rdata = state_q == LOCAL_READ ? read_data_q : backend.rdata;
  assign axi.rid = state_q == LOCAL_READ ? id_q : backend.rid;
  assign axi.rresp = state_q == LOCAL_READ ? response_q : backend.rresp;
  assign axi.rlast = state_q == LOCAL_READ ? beat_q == length_q : backend.rlast;
  assign axi.bvalid = !reset && (state_q == LOCAL_RESPONSE
      || (state_q == EXTERNAL_WRITE && backend.bvalid));
  assign axi.bid = state_q == LOCAL_RESPONSE ? id_q : backend.bid;
  assign axi.bresp = state_q == LOCAL_RESPONSE ? response_q : backend.bresp;

  assign gpio_o = gpio_value_q;
  // Open drain releases high values. Reset releases every GPIO, including when
  // an external device drives it while the chip clock is stopped in reset.
  assign gpio_oe_o = reset ? '0 : gpio_enable_q & ~(gpio_open_drain_q & gpio_value_q);
  assign uart_irq_o = reset ? '0 : uart_irq;
  assign uart_tx_o = reset ? '1 : uart_tx;
  assign uart_address = state_q == IDLE ? axi.araddr[2:0] : address_q[2:0];
  assign uart_wdata = 8'(axi.wdata >> (8 * int'(address_q[LaneBits-1:0])));

  always_comb begin
    write_mask = '0;
    for (int i = 0; i < Bytes; i++)
    if (i >= int'(address_q[LaneBits-1:0]) && i < int'(address_q[LaneBits-1:0]) + (1 << size_q))
      write_mask[i] = 1'b1;
    valid_write = access_ok_q && axi.wlast && (axi.wstrb & ~write_mask) == 0;
    commit_write = !reset && state_q == LOCAL_WRITE && axi.wvalid && valid_write;
    uart_read = '0;
    uart_write = '0;
    for (int i = 0; i < 2; i++) begin
      uart_read[i] = !reset && state_q == IDLE && read_accept && read_local && read_ok
          && axi.araddr[9:8] == 2'(i);
      uart_write[i] = commit_write && address_q[9:8] == 2'(i)
          && axi.wstrb[address_q[LaneBits-1:0]];
    end
    read_word = '0;
    case (axi.araddr[9:8])
      0: read_word = {24'b0, uart_data[0]};
      1: read_word = {24'b0, uart_data[1]};
      2:
      case (axi.araddr[7:0])
        0: read_word = {29'b0, gpio_sync_q};
        4: read_word = {29'b0, gpio_value_q};
        8: read_word = {29'b0, gpio_enable_q};
        12: read_word = {29'b0, gpio_open_drain_q};
        default: ;
      endcase
      default: ;
    endcase
  end

  for (genvar i = 0; i < 2; i++) begin : g_uart
    rapt_native_uart #(
        .ClockHz(CoreClockHz)
    ) u_uart (
        .clk(clock),
        .reset,
        .rx(uart_rx_i[i]),
        .tx(uart_tx[i]),
        .irq(uart_irq[i]),
        .rd(uart_read[i]),
        .wr(uart_write[i]),
        .addr(uart_address),
        .wdata(uart_wdata),
        .rdata(uart_data[i])
    );
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      prefer_write_q <= 1'b1;
      offer_lock_q <= 1'b0;
      offer_write_q <= 1'b0;
      access_ok_q <= 1'b0;
      address_q <= '0;
      read_data_q <= '0;
      id_q <= '0;
      length_q <= '0;
      beat_q <= '0;
      size_q <= '0;
      response_q <= Okay;
      gpio_value_q <= '0;
      gpio_enable_q <= '0;
      gpio_open_drain_q <= '1;
      gpio_meta_q <= '0;
      gpio_sync_q <= '0;
    end else begin
      gpio_meta_q <= gpio_i;
      gpio_sync_q <= gpio_meta_q;
      if (commit_write && address_q[9:8] == 2 && axi.wstrb[address_q[LaneBits-1:0]]) begin
        case (address_q[7:0])
          4: gpio_value_q <= uart_wdata[2:0];
          8: gpio_enable_q <= uart_wdata[2:0];
          12: gpio_open_drain_q <= uart_wdata[2:0];
          default: ;
        endcase
      end
      case (state_q)
        IDLE: begin
          beat_q <= '0;
          if (read_accept || write_accept) offer_lock_q <= 1'b0;
          else if (backend.arvalid || backend.awvalid) begin
            offer_lock_q <= 1'b1;
            offer_write_q <= choose_write;
          end
          if (write_accept) begin
            prefer_write_q <= 1'b0;
            if (write_local) begin
              state_q <= LOCAL_WRITE;
              address_q <= axi.awaddr;
              id_q <= axi.awid;
              length_q <= axi.awlen;
              size_q <= axi.awsize;
              access_ok_q <= write_ok;
            end else state_q <= EXTERNAL_WRITE;
          end else if (read_accept) begin
            prefer_write_q <= 1'b1;
            if (read_local) begin
              state_q <= LOCAL_READ;
              id_q <= axi.arid;
              length_q <= axi.arlen;
              response_q <= read_ok ? Okay : Slverr;
              read_data_q <= read_ok
                  ? XLEN'(read_word) << (8 * int'(axi.araddr[LaneBits-1:0])) : '0;
            end else state_q <= EXTERNAL_READ;
          end
        end
        EXTERNAL_READ:
        if (backend.rvalid && axi.rready && backend.rlast) state_q <= IDLE;
        EXTERNAL_WRITE:
        if (backend.bvalid && axi.bready) state_q <= IDLE;
        LOCAL_READ:
        if (axi.rready) begin
          if (beat_q == length_q) state_q <= IDLE;
          else beat_q <= beat_q + 1'b1;
        end
        LOCAL_WRITE:
        if (axi.wvalid) begin
          if (beat_q == length_q) begin
            state_q <= LOCAL_RESPONSE;
            response_q <= valid_write ? Okay : Slverr;
          end else beat_q <= beat_q + 1'b1;
        end
        LOCAL_RESPONSE:
        if (axi.bready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
