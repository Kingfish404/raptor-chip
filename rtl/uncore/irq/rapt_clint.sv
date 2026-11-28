`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Core Local INTerrupt controller (standard CLINT layout)
//
// Register map (base 0x02000000):
//   0x0000 + 4*h  msip[h]      (32-bit, bit 0 only)  - M-mode SW interrupt
//   0x4000 + 8*h  mtimecmp[h]  (64-bit)              - per-hart timer compare
//   0xBFF8        mtime        (64-bit, read/write)  - shared real-time counter
//
// Interrupt outputs are active-high level signals per hart:
//   timer_int[h] = (mtime >= mtimecmp[h])
//   sw_int[h]    = msip[h]
module rapt_clint #(
    parameter int XLEN = `RAPT_XLEN,
    // Pace mtime so it ticks at RAPT_MTIME_FREQ_MHZ (DTS timebase-frequency).
    // Override via VFLAGS="-DRAPT_MTIME_FREQ_MHZ=..." or by passing MTIME_DIV at
    // instantiation. See rtl/include/npc/rapt_soc.svh.
    parameter int MTIME_DIV = `RAPT_MTIME_DIV,
    parameter int NHARTS = 1
) (
    input clock,

    clint_bus_if.slave clint_bus,

`ifdef FORMAL
    input reset,
    output logic [63:0] formal_mtime,
    output logic [63:0] formal_mtimecmp,
    output logic formal_msip,
    output logic [((MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV))-1:0]
        formal_mtime_div_cnt
`else
    input reset
`endif
);
  if (NHARTS < 1 || NHARTS > 64) begin : g_invalid_nharts
    $error("rapt_clint supports 1..64 harts (NHARTS=%0d)", NHARTS);
  end

  logic [63:0]             mtime;
  logic [NHARTS-1:0][63:0] mtimecmp_arr;
  // Retain scalar `mtimecmp` alias for hart 0 so existing single-hart
  // testbenches and checkpoint observers remain compatible.
  /* verilator lint_off UNUSEDSIGNAL */
  wire  [63:0]       mtimecmp = mtimecmp_arr[0];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NHARTS-1:0] msip_reg;
  localparam int MTIMEdivW = (MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV);
  logic [MTIMEdivW-1:0] mtime_div_cnt;

`ifdef FORMAL
  assign formal_mtime = mtime;
  assign formal_mtimecmp = mtimecmp_arr[0];
  assign formal_msip = msip_reg[0];
  assign formal_mtime_div_cnt = mtime_div_cnt;
`endif

  // --- Interrupt generation (level-triggered, per hart) ---
  for (genvar h = 0; h < NHARTS; h++) begin : g_hart_irq
    assign clint_bus.timer_int[h] = (mtime >= mtimecmp_arr[h]);
    assign clint_bus.sw_int[h]    = msip_reg[h];
  end
  assign clint_bus.mtime_value = mtime;

  // The router normalizes AXI data/strobes to byte zero of the addressed
  // transfer. Reposition them within the 64-bit register, independently of
  // XLEN, so byte/halfword offsets do not alias or disappear.
  logic [63:0]       register_wdata;
  logic [ 7:0]       register_wstrb;
  logic              mtime_write;
  logic [NHARTS-1:0] mtimecmp_write;
  logic [NHARTS-1:0] msip_write;
  logic [XLEN-1:0]   awaddr_aligned8;
  logic [XLEN-1:0]   araddr_aligned8;

  assign register_wdata  = 64'(clint_bus.wdata) << {clint_bus.awaddr[2:0], 3'b000};
  assign register_wstrb  = 8'(clint_bus.wstrb) << clint_bus.awaddr[2:0];
  assign awaddr_aligned8 = clint_bus.awaddr & ~XLEN'(7);
  assign araddr_aligned8 = clint_bus.araddr & ~XLEN'(7);

  assign mtime_write = clint_bus.wvalid && |register_wstrb
      && (awaddr_aligned8 == `RAPT_BUS_RTC_ADDR);

  for (genvar h = 0; h < NHARTS; h++) begin : g_write_decode
    localparam logic [XLEN-1:0] MtimecmpAddr = `RAPT_CLINT_MTIMECMP + XLEN'(h * 8);
    localparam logic [XLEN-1:0] MsipPairAddr = `RAPT_CLINT_MSIP + XLEN'((h / 2) * 8);
    localparam int MsipByte = ((h & 1) != 0) ? 4 : 0;
    assign mtimecmp_write[h] = clint_bus.wvalid && (awaddr_aligned8 == MtimecmpAddr);
    assign msip_write[h] = clint_bus.wvalid && (awaddr_aligned8 == MsipPairAddr)
        && register_wstrb[MsipByte];
  end

  // Select one 64-bit aligned register before byte alignment, sharing the read shifter.
  logic [63:0] read_register;
  always_comb begin
    read_register = '0;
    if (araddr_aligned8 == `RAPT_BUS_RTC_ADDR) begin
      read_register = mtime;
    end else begin
      for (int h = 0; h < NHARTS; h++) begin
        automatic int cmp_off  = h * 8;
        automatic int pair_off = (h / 2) * 8;
        if (araddr_aligned8 == (`RAPT_CLINT_MTIMECMP + XLEN'(cmp_off))) begin
          read_register = mtimecmp_arr[h];
        end
        if (araddr_aligned8 == (`RAPT_CLINT_MSIP + XLEN'(pair_off))) begin
          if ((h & 1) == 0) read_register[0] = msip_reg[h];
          else read_register[32] = msip_reg[h];
        end
      end
    end
  end
  assign clint_bus.rdata = XLEN'(read_register >> {clint_bus.araddr[2:0], 3'b000});

  // --- Registers ---
  always_ff @(posedge clock) begin
    if (reset) begin
      mtime <= 64'h0;
      for (int h = 0; h < NHARTS; h++) begin
        mtimecmp_arr[h] <= 64'hFFFF_FFFF_FFFF_FFFF;
      end
      msip_reg      <= '0;
      mtime_div_cnt <= '0;
    end else begin
      if (MTIME_DIV <= 1) begin
        if (!mtime_write) mtime <= mtime + 64'h1;
      end else if (mtime_div_cnt == MTIMEdivW'(MTIME_DIV - 1)) begin
        if (!mtime_write) mtime <= mtime + 64'h1;
        mtime_div_cnt <= '0;
      end else begin
        mtime_div_cnt <= mtime_div_cnt + MTIMEdivW'(1);
      end
      // A nonempty time write wins a coincident tick; untouched bytes
      // retain their pre-edge value and the divider phase keeps advancing.
      for (int b = 0; b < 8; b++) begin
        if (mtime_write && register_wstrb[b]) mtime[8*b+:8] <= register_wdata[8*b+:8];
      end
      for (int h = 0; h < NHARTS; h++) begin
        for (int b = 0; b < 8; b++) begin
          if (mtimecmp_write[h] && register_wstrb[b]) begin
            mtimecmp_arr[h][8*b+:8] <= register_wdata[8*b+:8];
          end
        end
        if (msip_write[h]) begin
          msip_reg[h] <= ((h & 1) != 0) ? register_wdata[32] : register_wdata[0];
        end
      end
    end
  end
endmodule
