`include "rapt_soc_if.svh"

// Direct SPI Flash configuration of the chip's off-chip AXI port. Exactly one
// transaction owns the bus/serial engine; responses remain stable under stalls.
// Read-only Flash: 0x30000000..307fffff, low 64 KiB alias at reset PC 0x20000000.
// rapt_chip_boot overlays the reset alias with the on-chip ROM when selected.
// Local 8 KiB RAM: 0x0f000000..0f001fff (contents unspecified after reset).
// 32-bit, single-beat MMIO at 0x00100800; see ../sw/rapt_flash.h and docs.
module rapt_axi_flash #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [23:0] FlashStorageOffset = 24'h000000,
    parameter int unsigned FlashWriteStart = 32'h00000000,
    parameter int unsigned FlashWriteEnd = 32'h00800000,
    parameter int unsigned CoreClockHz = 100_000_000,
    parameter int unsigned HalfPeriod = CoreClockHz > 80_000_000
        ? (CoreClockHz + 9_999_999) / 10_000_000 : 8,
    parameter int unsigned PowerupCycles = CoreClockHz + 1,
    parameter int unsigned ResetCycles = CoreClockHz / 10000 + 1,
    parameter int unsigned RecoveryCycles = CoreClockHz + 1,
    parameter int unsigned PollCycles = CoreClockHz / 2
) (
    input logic clock,
    input logic reset,
    output logic idle_o,
    output rapt_pkg::sram_ctrl_t sram_ctrl_o,
    axi4_if.slave axi,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    input logic [7:0] dq_i,
    input logic ds_i
);
`ifndef SYNTHESIS
  initial begin
    if (FlashStorageOffset > 24'h800000 || FlashWriteStart >= FlashWriteEnd
        || FlashWriteEnd > 32'h01000000)
      $fatal(1, "Invalid Flash mapping/protection parameters");
  end
`endif
  localparam int Bytes = XLEN / 8;
  localparam int LaneBits = $clog2(Bytes);
  localparam logic [1:0] Okay = 2'b00, Slverr = 2'b10, Decerr = 2'b11;
  typedef enum logic [3:0] {
    IDLE,
    READ_BEAT,
    READ_RESP,
    WRITE_BEAT,
    WRITE_RESP,
    SERIAL_REQ,
    SERIAL_WAIT
  } state_t;
  typedef enum logic [1:0] {
    HOLE,
    FLASH,
    RAM,
    REGS
  } region_t;
  state_t state_q;
  region_t region_q;
  logic [XLEN-1:0] addr_q, data_q;
  logic [3:0] id_q;
  logic [7:0] len_q, beat_q;
  logic [2:0] size_q, op_q;
  logic [1:0] burst_q, resp_q;
  logic writing_q, prefer_write_q;
  logic [31:0] offset_q, program_q;
  logic [7:0] ram[0:8191];
  logic serial_ready, serial_done, qualified, octal;
  logic [7:0] serial_error, sr1, sr2;
  logic [23:0] jedec;
  logic [63:0] serial_data;
  logic [31:0] reg_rdata, reg_wdata;
  logic [Bytes-1:0] lane_mask;
  logic reg_write_valid;
  logic [23:0] serial_addr;
  logic [3:0] serial_bytes, beat_bytes;
  logic [XLEN-1:0] next_addr;

  function automatic region_t region(input logic [XLEN-1:0] a);
    if ((a >= XLEN'(32'h30000000) && a < XLEN'(32'h30800000))
        || (a >= XLEN'(32'h20000000) && a < XLEN'(32'h20010000)))
      return FLASH;
    if (a >= XLEN'(32'h0f000000) && a < XLEN'(32'h0f002000)) return RAM;
    if (a >= XLEN'(32'h00100800) && a < XLEN'(32'h0010083c)) return REGS;
    return HOLE;
  endfunction

  // Reject the whole burst before any serial frame or RAM write. FIXED/INCR
  // reads permit AXI unaligned first beats; writes and MMIO stay aligned.
  // Subsequent INCR beats start at the next transfer-size boundary.
  function automatic logic valid_burst(input logic [XLEN-1:0] a, input logic [2:0] size,
                                       input logic [7:0] len, input logic [1:0] burst,
                                       input logic writing);
    logic [XLEN:0] last;
    logic [XLEN:0] span;
    span = (XLEN + 1)'(1) << size;
    if (burst == 1) span = span * ((XLEN + 1)'(len) + 1'b1);
    last = {1'b0, (a & ~((XLEN'(1) << size) - 1'b1))} + span - 1'b1;
    if (size > 3'(LaneBits) || burst > 1) return 1'b0;
    if ((writing || region(a) == REGS) && (a & ((XLEN'(1) << size) - 1'b1)) != 0) return 1'b0;
    if (last[XLEN] || last[XLEN-1:12] != a[XLEN-1:12]) return 1'b0;
    if (region(a) != region(last[XLEN-1:0])) return 1'b0;
    if (region(a) == REGS && (size != 2 || len != 0)) return 1'b0;
    return 1'b1;
  endfunction

  assign idle_o = state_q == IDLE && serial_ready;

  assign axi.awready = state_q == IDLE && (prefer_write_q || !axi.arvalid);
  assign axi.arready = state_q == IDLE && (!prefer_write_q || !axi.awvalid);
  assign axi.wready = state_q == WRITE_BEAT;
  assign axi.bvalid = state_q == WRITE_RESP;
  assign axi.bid = id_q;
  assign axi.bresp = resp_q;
  assign axi.rvalid = state_q == READ_RESP;
  assign axi.rid = id_q;
  assign axi.rdata = data_q;
  assign axi.rresp = resp_q;
  assign axi.rlast = beat_q == len_q;

  always_comb begin
    beat_bytes = 4'((1 << size_q)
        - (int'(addr_q[LaneBits-1:0]) & ((1 << size_q) - 1)));
    next_addr = (addr_q | ((XLEN'(1) << size_q) - 1'b1)) + 1'b1;
    lane_mask = '0;
    for (int i = 0; i < Bytes; i++)
    if (i >= int'(addr_q[LaneBits-1:0]) && i < int'(addr_q[LaneBits-1:0]) + int'(beat_bytes))
      lane_mask[i] = 1'b1;
    reg_wdata = 32'(axi.wdata >> (8 * int'(addr_q[LaneBits-1:0])));
    reg_write_valid = resp_q == Okay && axi.wstrb == lane_mask && axi.wlast;
    reg_rdata = 0;
    case (addr_q[7:0])
      8'h00: reg_rdata = HalfPeriod;
      8'h04: reg_rdata = {16'b0, sram_ctrl_o};
      8'h10: reg_rdata = {sr2, sr1, serial_error, 4'b0, octal, !qualified, !serial_ready, qualified};
      8'h14: reg_rdata = {8'b0, jedec};
      8'h18: reg_rdata = offset_q;
      8'h1c: reg_rdata = program_q;
      8'h24: reg_rdata = 32'h0001_0007;
      8'h28: reg_rdata = 32'h0080_0000;
      8'h2c: reg_rdata = 32'h0000_1000;
      8'h30: reg_rdata = {8'b0, FlashStorageOffset};
      8'h34: reg_rdata = FlashWriteStart;
      8'h38: reg_rdata = FlashWriteEnd;
      default: ;
    endcase
    serial_addr = FlashStorageOffset
        + (writing_q ? offset_q[23:0] : {1'b0, addr_q[22:0]});
    serial_bytes = writing_q ? 4'd4 : beat_bytes;
  end

  rapt_spi_nor #(
      .WriteStart(FlashWriteStart),
      .WriteEnd(FlashWriteEnd),
      .CoreClockHz(CoreClockHz),
      .HalfPeriod(HalfPeriod),
      .PowerupCycles(PowerupCycles),
      .ResetCycles(ResetCycles),
      .RecoveryCycles(RecoveryCycles),
      .PollCycles(PollCycles)
  ) u_nor (
      .clock,
      .reset,
      .req_i(state_q == SERIAL_REQ),
      .ready_o(serial_ready),
      .op_i(op_q),
      .addr_i(serial_addr),
      .bytes_i(serial_bytes),
      .data_i(program_q),
      .done_o(serial_done),
      .data_o(serial_data),
      .error_o(serial_error),
      .qualified_o(qualified),
      .jedec_o(jedec),
      .sr1_o(sr1),
      .sr2_o(sr2),
      .sclk_o,
      .cs_n_o,
      .dq_o,
      .dq_oe_o,
      .dq_i,
      .ds_i,
      .octal_o(octal)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      region_q <= HOLE;
      addr_q <= 0;
      data_q <= 0;
      id_q <= 0;
      len_q <= 0;
      beat_q <= 0;
      size_q <= 0;
      op_q <= 0;
      burst_q <= 0;
      resp_q <= Okay;
      writing_q <= 0;
      prefer_write_q <= 0;
      offset_q <= 0;
      program_q <= 0;
      sram_ctrl_o <= rapt_pkg::SramCtrlReset;
    end else begin
      case (state_q)
        IDLE: begin
          beat_q <= 0;
          data_q <= 0;
          resp_q <= Okay;
          if (axi.awvalid && axi.awready) begin
            writing_q <= 1;
            prefer_write_q <= 0;
            addr_q <= axi.awaddr;
            id_q <= axi.awid;
            len_q <= axi.awlen;
            size_q <= axi.awsize;
            burst_q <= axi.awburst;
            region_q <= region(axi.awaddr);
            if (region(axi.awaddr) == HOLE) resp_q <= Decerr;
            else if (!valid_burst(
                    axi.awaddr, axi.awsize, axi.awlen, axi.awburst, 1'b1
                ) || region(
                    axi.awaddr
                ) == FLASH)
              resp_q <= Slverr;
            state_q <= WRITE_BEAT;
          end else if (axi.arvalid && axi.arready) begin
            writing_q <= 0;
            prefer_write_q <= 1;
            addr_q <= axi.araddr;
            id_q <= axi.arid;
            len_q <= axi.arlen;
            size_q <= axi.arsize;
            burst_q <= axi.arburst;
            region_q <= region(axi.araddr);
            if (region(axi.araddr) == HOLE) resp_q <= Decerr;
            else if (!valid_burst(axi.araddr, axi.arsize, axi.arlen, axi.arburst, 1'b0))
              resp_q <= Slverr;
            state_q <= READ_BEAT;
          end
        end
        READ_BEAT: begin
          data_q <= 0;
          state_q <= READ_RESP;
          if (resp_q == Okay)
            case (region_q)
              FLASH: begin
                op_q <= 0;
                state_q <= SERIAL_REQ;
              end
              RAM: for (int i = 0; i < Bytes; i++)
              if (lane_mask[i]) data_q[8*i+:8] <= ram[{addr_q[12:LaneBits], {LaneBits{1'b0}}}
                  + 13'(i)];
              REGS: begin
              data_q <= XLEN'(reg_rdata) << (8 * int'(addr_q[LaneBits-1:0]));
              case (addr_q[7:0])
                8'h00, 8'h04, 8'h10, 8'h14, 8'h18, 8'h1c, 8'h24, 8'h28, 8'h2c,
                8'h30, 8'h34, 8'h38: ;
                default: resp_q <= Slverr;
              endcase
            end
              default: resp_q <= Decerr;
            endcase
        end
        READ_RESP:
        if (axi.rready) begin
          if (beat_q == len_q) state_q <= IDLE;
          else begin
            beat_q <= beat_q + 1'b1;
            if (burst_q == 1) addr_q <= next_addr;
            state_q <= READ_BEAT;
          end
        end
        WRITE_BEAT:
        if (axi.wvalid) begin
          if (axi.wlast != (beat_q == len_q) || (axi.wstrb & ~lane_mask) != 0) resp_q <= Slverr;
          if (beat_q == len_q) state_q <= WRITE_RESP;
          else begin
            beat_q <= beat_q + 1'b1;
            if (burst_q == 1) addr_q <= next_addr;
          end
          if (resp_q == Okay && axi.wlast == (beat_q == len_q)
              && (axi.wstrb & ~lane_mask) == 0) begin
            if (region_q == RAM) begin
              for (int i = 0; i < Bytes; i++)
              if (axi.wstrb[i])
                ram[{addr_q[12:LaneBits], {LaneBits{1'b0}}}+13'(i)] <= axi.wdata[8*i+:8];
            end else if (region_q == REGS) begin
              case (addr_q[7:0])
                8'h04: begin
                  for (int i = 0; i < 2; i++)
                  if (axi.wstrb[int'(addr_q[LaneBits-1:0])+i])
                    sram_ctrl_o[8*i+:8] <= reg_wdata[8*i+:8] & (i == 1 ? 8'h7f : 8'hff);
                end
                8'h18: if (reg_write_valid) offset_q <= reg_wdata;
                else resp_q <= Slverr;
                8'h1c: if (reg_write_valid) program_q <= reg_wdata;
                else resp_q <= Slverr;
                8'h20: begin
                  if (!reg_write_valid || reg_wdata < 32'h5246_0001
                      || reg_wdata > 32'h5246_0005) resp_q <= Slverr;
                  else if (reg_wdata <= 32'h5246_0002
                      && (offset_q >= 32'h00800000 || offset_q[1:0] != 0
                      || (reg_wdata == 32'h5246_0002 && offset_q[11:0] != 0)))
                    resp_q <= Slverr;
                  else begin op_q <= reg_wdata[2:0]; state_q <= SERIAL_REQ; end
                end
                default: resp_q <= Slverr;
              endcase
            end
          end
        end
        SERIAL_REQ: if (serial_ready) state_q <= SERIAL_WAIT;
        SERIAL_WAIT: if (serial_done) begin
          resp_q <= serial_error == 0 && qualified ? Okay : Slverr;
          data_q <= serial_error == 0 && qualified
              ? XLEN'(serial_data) << (8 * int'(addr_q[LaneBits-1:0])) : '0;
          state_q <= writing_q ? WRITE_RESP : READ_RESP;
        end
        WRITE_RESP: if (axi.bready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (XLEN != 32 && XLEN != 64) $fatal(1, "Direct Flash requires XLEN 32 or 64");
    if (axi.XLEN != XLEN) $fatal(1, "Direct Flash interface width mismatch");
  end
`endif

  `RAPT_SVA(clock, reset, FLASH_SRAM_RESERVED_ZERO, !sram_ctrl_o.reserved)
endmodule
