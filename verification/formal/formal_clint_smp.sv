`include "rapt.svh"
`include "rapt_soc.svh"

// Independent multi-hart architectural model for rapt_clint (NHARTS >= 2).
// Verifies per-hart msip[h] (0x0000+4*h), per-hart mtimecmp[h] (0x4000+8*h),
// shared mtime (0xBFF8), byte-lane partial writes, and per-hart sw_int/timer_int.
module formal_clint_smp #(
    parameter int XLEN = 64,
    parameter int NHARTS = 2,
    parameter int MTIME_DIV = 3
) (
    input logic clock,
    input logic reset,
    input logic [XLEN-1:0] araddr,
    input logic [XLEN-1:0] awaddr,
    input logic [XLEN-1:0] wdata,
    input logic [XLEN/8-1:0] wstrb,
    input logic wvalid
);
  localparam int DivW = (MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV);
  localparam logic [XLEN-1:0] MsipBase = XLEN'(`RAPT_CLINT_MSIP);
  localparam logic [XLEN-1:0] CmpBase = XLEN'(`RAPT_CLINT_MTIMECMP);
  localparam logic [XLEN-1:0] TimeBase = XLEN'(`RAPT_BUS_RTC_ADDR);

  clint_bus_if #(
      .XLEN(XLEN),
      .NHARTS(NHARTS)
  ) bus ();
  assign bus.araddr = araddr;
  assign bus.awaddr = awaddr;
  assign bus.wdata  = wdata;
  assign bus.wstrb  = wstrb;
  assign bus.wvalid = wvalid;

  logic [63:0] dut_mtime, dut_mtimecmp0;
  logic dut_msip0;
  logic [DivW-1:0] dut_div_cnt;
  rapt_clint #(
      .XLEN(XLEN),
      .MTIME_DIV(MTIME_DIV),
      .NHARTS(NHARTS)
  ) dut (
      .clock(clock),
      .reset(reset),
      .clint_bus(bus),
      .formal_mtime(dut_mtime),
      .formal_mtimecmp(dut_mtimecmp0),
      .formal_msip(dut_msip0),
      .formal_mtime_div_cnt(dut_div_cnt)
  );

  logic past_valid;
  initial past_valid = 1'b0;
  always_ff @(posedge clock) past_valid <= 1'b1;
  always_comb if (!past_valid) assume (reset);

  logic [63:0] ref_mtime;
  logic [63:0] ref_mtimecmp[NHARTS];
  logic [NHARTS-1:0] ref_msip;
  logic [DivW-1:0] ref_div_cnt;
  logic [XLEN-1:0] ref_rdata;
  logic [63:0] time_mask, time_data;
  logic [63:0] cmp_mask[NHARTS];
  logic [63:0] cmp_data[NHARTS];
  logic [NHARTS-1:0] msip_we, msip_val;

  always_comb begin
    ref_rdata = '0;
    time_mask = '0;
    time_data = '0;
    msip_we   = '0;
    msip_val  = '0;
    for (int h = 0; h < NHARTS; h++) begin
      cmp_mask[h] = '0;
      cmp_data[h] = '0;
      for (int bb = 0; bb < XLEN / 8; bb++) begin
        if ((araddr & ~XLEN'(7)) == ((MsipBase + XLEN'(h * 4)) & ~XLEN'(7))
            && araddr + XLEN'(bb) == MsipBase + XLEN'(h * 4)) begin
          ref_rdata[8*bb] = ref_msip[h];
        end
        if (wvalid && wstrb[bb]
            && (awaddr & ~XLEN'(7)) == ((MsipBase + XLEN'(h * 4)) & ~XLEN'(7))
            && awaddr + XLEN'(bb) == MsipBase + XLEN'(h * 4)) begin
          msip_we[h]  = 1'b1;
          msip_val[h] = wdata[8*bb];
        end
      end
      for (int rb = 0; rb < 8; rb++) begin
        for (int bb = 0; bb < XLEN / 8; bb++) begin
          if (araddr >= CmpBase + XLEN'(h * 8)
              && araddr < CmpBase + XLEN'(h * 8 + 8)
              && araddr + XLEN'(bb) == CmpBase + XLEN'(h * 8 + rb)) begin
            ref_rdata[8*bb+:8] = ref_mtimecmp[h][8*rb+:8];
          end
          if (wvalid && wstrb[bb]
              && awaddr >= CmpBase + XLEN'(h * 8)
              && awaddr < CmpBase + XLEN'(h * 8 + 8)
              && awaddr + XLEN'(bb) == CmpBase + XLEN'(h * 8 + rb)) begin
            cmp_mask[h][8*rb+:8] = 8'hff;
            cmp_data[h][8*rb+:8] = wdata[8*bb+:8];
          end
        end
      end
    end
    for (int rb = 0; rb < 8; rb++) begin
      for (int bb = 0; bb < XLEN / 8; bb++) begin
        if (araddr >= TimeBase && araddr < TimeBase + XLEN'(8)
            && araddr + XLEN'(bb) == TimeBase + XLEN'(rb)) begin
          ref_rdata[8*bb+:8] = ref_mtime[8*rb+:8];
        end
        if (wvalid && wstrb[bb]
            && awaddr >= TimeBase && awaddr < TimeBase + XLEN'(8)
            && awaddr + XLEN'(bb) == TimeBase + XLEN'(rb)) begin
          time_mask[8*rb+:8] = 8'hff;
          time_data[8*rb+:8] = wdata[8*bb+:8];
        end
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      ref_mtime   <= '0;
      ref_msip    <= '0;
      ref_div_cnt <= '0;
      for (int h = 0; h < NHARTS; h++) ref_mtimecmp[h] <= 64'hffff_ffff_ffff_ffff;
    end else begin
      if (MTIME_DIV <= 1) begin
        if (!(|time_mask)) ref_mtime <= ref_mtime + 64'd1;
      end else if (int'(ref_div_cnt) == MTIME_DIV - 1) begin
        ref_div_cnt <= '0;
        if (!(|time_mask)) ref_mtime <= ref_mtime + 64'd1;
      end else begin
        ref_div_cnt <= ref_div_cnt + DivW'(1);
      end
      if (|time_mask) begin
        ref_mtime <= (ref_mtime & ~time_mask) | (time_data & time_mask);
      end
      for (int h = 0; h < NHARTS; h++) begin
        if (msip_we[h]) ref_msip[h] <= msip_val[h];
        if (|cmp_mask[h]) begin
          ref_mtimecmp[h] <= (ref_mtimecmp[h] & ~cmp_mask[h]) | (cmp_data[h] & cmp_mask[h]);
        end
      end
    end
  end

  always_comb begin
    if (!reset && past_valid) begin
      assert (bus.mtime_value == ref_mtime);
      assert (dut_mtime == ref_mtime);
      assert (dut_mtimecmp0 == ref_mtimecmp[0]);
      assert (dut_msip0 == ref_msip[0]);
      assert (dut_div_cnt == ref_div_cnt);
      assert (bus.rdata == ref_rdata);
      for (int h = 0; h < NHARTS; h++) begin
        assert (dut.mtimecmp_arr[h] == ref_mtimecmp[h]);
        assert (bus.sw_int[h] == ref_msip[h]);
        assert (bus.timer_int[h] == (ref_mtime >= ref_mtimecmp[h]));
      end
    end
  end

  always @(posedge clock) begin
    if (!reset && past_valid) begin
      cover (bus.sw_int[NHARTS-1] && !bus.sw_int[0]);
      cover (bus.timer_int[NHARTS-1] && !bus.timer_int[0]);
    end
  end
endmodule
