`include "rapt_soc_if.svh"

// Local boot control and reset ROM, before both serial backends. Serialize the
// route through the last AXI response, including invalid local bursts. The DM
// and this block see only chip reset; core_reset_i is the drained reset boundary.
module rapt_chip_boot #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    input logic core_reset_i,
    input logic backend_idle_i,
    output logic flash_mode_o,
    output logic enable_o,
    axi4_if.slave axi,
    axi4_if.master backend
);
  localparam int Bytes = XLEN / 8;
  localparam int LaneBits = $clog2(Bytes);
  localparam logic [1:0] Okay = 2'b00, Slverr = 2'b10;
  typedef enum logic [3:0] {
    IDLE,
    EXTERNAL_READ,
    EXTERNAL_WRITE,
    LOCAL_READ,
    LOCAL_WRITE,
    LOCAL_RESPONSE,
    SWITCH_WAIT,
    SWITCH_OFF,
    SWITCH_APPLY
  } state_t;
  state_t state_q;
  logic [1:0] requested_q, active_q, apply_value_q;
  logic core_reset_q, apply_q, prefer_write_q, choose_write, choose_read;
  logic read_local, write_local, read_rom, read_ok, write_ok_q;
  logic [XLEN-1:0] address_q, data_q;
  logic [3:0] id_q;
  logic [7:0] length_q, beat_q;
  logic [1:0] response_q, burst_q;
  logic [2:0] size_q;
  logic [XLEN-1:0] next_address;
  logic [31:0] write_word;
  logic switch_due, enable_q;
  logic offer_lock_q, offer_write_q, route_ready;

  function automatic logic control_address(input logic [XLEN-1:0] address);
    return address >= XLEN'(32'h00100808) && address < XLEN'(32'h0010080c);
  endfunction

  function automatic logic rom_address(input logic [XLEN-1:0] address);
    return active_q[1] && address >= XLEN'(32'h20000000) && address < XLEN'(32'h20010000);
  endfunction

  function automatic logic [7:0] rom_byte(input logic [15:0] offset);
    logic [31:0] instruction;
    case (offset[15:2])
      0: instruction = 32'h300002b7;  // lui t0, 0x30000
      1: instruction = 32'h00028067;  // jalr x0, 0(t0)
      default: instruction = 32'h00000013;
    endcase
    return 8'(instruction >> (8 * int'(offset[1:0])));
  endfunction

  function automatic logic [XLEN-1:0] rom_data(input logic [XLEN-1:0] address,
                                               input logic [2:0] size);
    logic [XLEN-1:0] value;
    int first, count;
    first = int'(address[LaneBits-1:0]);
    count = (1 << size) - (first & ((1 << size) - 1));
    value = '0;
    for (int i = 0; i < Bytes; i++)
    if (i >= first && i < first + count)
      value[8*i+:8] = rom_byte({address[15:LaneBits], {LaneBits{1'b0}}} + 16'(i));
    return value;
  endfunction

  assign switch_due = apply_q || (core_reset_i && !core_reset_q && requested_q != active_q);
  assign flash_mode_o = active_q[0];
  assign enable_o = !reset && enable_q;
  // Once offered, an address must survive backpressure, a competing channel,
  // and a reset snapshot. Drain that offer before changing backend ownership.
  assign choose_write = offer_lock_q ? offer_write_q
      : axi.awvalid && (prefer_write_q || !axi.arvalid);
  assign choose_read = axi.arvalid && !choose_write;
  assign route_ready = !switch_due || offer_lock_q;
  assign read_rom = rom_address(axi.araddr);
  assign read_local = control_address(axi.araddr) || read_rom;
  assign write_local = control_address(axi.awaddr) || rom_address(axi.awaddr);
  assign read_ok = read_rom
      ? axi.arsize <= 3'(LaneBits) && axi.arburst <= 1
        && (({1'b0, axi.araddr[11:0]} & ~((13'd1 << axi.arsize) - 1'b1))
            + ((13'd1 << axi.arsize)
            * (axi.arburst == 1 ? 13'(axi.arlen) + 1 : 13'd1)))
            <= 13'h1000
      : axi.araddr == XLEN'(32'h00100808) && axi.arsize == 2 && axi.arlen == 0
        && axi.arburst <= 1;
  assign next_address = (address_q | ((XLEN'(1) << size_q) - 1'b1)) + 1'b1;
  assign write_word = 32'(axi.wdata >> (8 * int'(address_q[LaneBits-1:0])));

  assign backend.araddr = axi.araddr;
  assign backend.arid = axi.arid;
  assign backend.arlen = axi.arlen;
  assign backend.arsize = axi.arsize;
  assign backend.arburst = axi.arburst;
  assign backend.arcache = axi.arcache;
  assign backend.arvalid = !reset && state_q == IDLE && route_ready && choose_read && !read_local;
  assign backend.rready = !reset && state_q == EXTERNAL_READ && axi.rready;
  assign backend.awaddr = axi.awaddr;
  assign backend.awid = axi.awid;
  assign backend.awlen = axi.awlen;
  assign backend.awsize = axi.awsize;
  assign backend.awburst = axi.awburst;
  assign backend.awcache = axi.awcache;
  assign backend.awvalid = !reset && state_q == IDLE && route_ready && choose_write && !write_local;
  assign backend.wdata = axi.wdata;
  assign backend.wstrb = axi.wstrb;
  assign backend.wlast = axi.wlast;
  assign backend.wvalid = !reset && state_q == EXTERNAL_WRITE && axi.wvalid;
  assign backend.bready = !reset && state_q == EXTERNAL_WRITE && axi.bready;
  assign axi.arready = !reset && state_q == IDLE && route_ready && choose_read
      && (read_local || backend.arready);
  assign axi.awready = !reset && state_q == IDLE && route_ready && choose_write
      && (write_local || backend.awready);
  assign axi.wready = !reset && (state_q == LOCAL_WRITE
      || (state_q == EXTERNAL_WRITE && backend.wready));
  assign axi.rvalid = !reset && (state_q == LOCAL_READ
      || (state_q == EXTERNAL_READ && backend.rvalid));
  assign axi.rid = state_q == LOCAL_READ ? id_q : backend.rid;
  assign axi.rdata = state_q == LOCAL_READ ? data_q : backend.rdata;
  assign axi.rresp = state_q == LOCAL_READ ? response_q : backend.rresp;
  assign axi.rlast = state_q == LOCAL_READ ? beat_q == length_q : backend.rlast;
  assign axi.bvalid = !reset && (state_q == LOCAL_RESPONSE
      || (state_q == EXTERNAL_WRITE && backend.bvalid));
  assign axi.bid = state_q == LOCAL_RESPONSE ? id_q : backend.bid;
  assign axi.bresp = state_q == LOCAL_RESPONSE ? response_q : backend.bresp;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      requested_q <= 2'b11;
      active_q <= 2'b11;
      apply_value_q <= 2'b11;
      core_reset_q <= 1'b1;
      apply_q <= 1'b0;
      prefer_write_q <= 1'b1;
      address_q <= '0;
      data_q <= '0;
      id_q <= '0;
      length_q <= '0;
      beat_q <= '0;
      response_q <= Okay;
      size_q <= 0;
      burst_q <= 0;
      write_ok_q <= 1'b0;
      enable_q <= 1'b1;
      offer_lock_q <= 1'b0;
      offer_write_q <= 1'b0;
    end else begin
      core_reset_q <= core_reset_i;
      if (core_reset_i && !core_reset_q) begin
        apply_q <= requested_q != active_q;
        apply_value_q <= requested_q;
      end
      case (state_q)
        IDLE: begin
          beat_q <= 0;
          if ((axi.arvalid && axi.arready) || (axi.awvalid && axi.awready)) offer_lock_q <= 1'b0;
          else if (backend.arvalid || backend.awvalid) begin
            offer_lock_q <= 1'b1;
            offer_write_q <= choose_write;
          end
          if (switch_due && !offer_lock_q) state_q <= SWITCH_WAIT;
          else if (axi.awvalid && axi.awready) begin
            prefer_write_q <= 1'b0;
            if (write_local) begin
              state_q <= LOCAL_WRITE;
              address_q <= axi.awaddr;
              id_q <= axi.awid;
              length_q <= axi.awlen;
              write_ok_q <= axi.awaddr == XLEN'(32'h00100808) && axi.awsize == 2
                  && axi.awlen == 0 && axi.awburst <= 1 && !core_reset_i;
            end else state_q <= EXTERNAL_WRITE;
          end else if (axi.arvalid && axi.arready) begin
            prefer_write_q <= 1'b1;
            if (read_local) begin
              state_q <= LOCAL_READ;
              address_q <= axi.araddr;
              id_q <= axi.arid;
              length_q <= axi.arlen;
              size_q <= axi.arsize;
              burst_q <= axi.arburst;
              response_q <= read_ok ? Okay : Slverr;
              data_q <= '0;
              if (read_ok) begin
                if (read_rom) data_q <= rom_data(axi.araddr, axi.arsize);
                else data_q <= XLEN'({14'b0, active_q, 14'b0, requested_q});
              end
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
          else begin
            beat_q <= beat_q + 1'b1;
            // Burst ROM fetches use FIXED or naturally aligned INCR beats.
            if (burst_q == 1) begin
              address_q <= next_address;
              if (response_q == Okay) data_q <= rom_data(next_address, size_q);
            end
          end
        end
        LOCAL_WRITE:
        if (axi.wvalid) begin
          if (beat_q == length_q) begin
            state_q <= LOCAL_RESPONSE;
            response_q <= Slverr;
            if (write_ok_q && !core_reset_i && axi.wlast && write_word[31:2] == 0
                && axi.wstrb == (Bytes'(4'hf) << int'(address_q[LaneBits-1:0]))) begin
              requested_q <= write_word[1:0];
              response_q <= Okay;
            end
          end else beat_q <= beat_q + 1'b1;
        end
        LOCAL_RESPONSE: if (axi.bready) state_q <= IDLE;
        SWITCH_WAIT:
        if (backend_idle_i) begin
          enable_q <= 1'b0;
          state_q <= SWITCH_OFF;
        end
        SWITCH_OFF: begin
          active_q <= apply_value_q;
          state_q <= SWITCH_APPLY;
        end
        SWITCH_APPLY: begin
          apply_q <= 1'b0;
          enable_q <= 1'b1;
          state_q <= IDLE;
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
