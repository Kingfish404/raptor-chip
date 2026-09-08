`include "rapt.svh"
`include "rapt_soc.svh"

// Independent architectural model for CLINT register and interrupt behavior.
// Parameter tasks exercise both XLENs and the divider bypass/counter paths.
module formal_clint #(
    parameter int XLEN = 32,
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

  clint_bus_if #(.XLEN(XLEN)) bus ();
  assign bus.araddr = araddr;
  assign bus.awaddr = awaddr;
  assign bus.wdata = wdata;
  assign bus.wstrb = wstrb;
  assign bus.wvalid = wvalid;

  logic [63:0] dut_mtime, dut_mtimecmp;
  logic dut_msip;
  logic [DivW-1:0] dut_div_cnt;
  rapt_clint #(
      .XLEN(XLEN),
      .MTIME_DIV(MTIME_DIV)
  ) dut (
      .clock,
      .reset,
      .clint_bus(bus),
      .formal_mtime(dut_mtime),
      .formal_mtimecmp(dut_mtimecmp),
      .formal_msip(dut_msip),
      .formal_mtime_div_cnt(dut_div_cnt)
  );

  logic [63:0] ref_mtime, ref_mtimecmp;
  logic ref_msip;
  logic [DivW-1:0] ref_div_cnt;
  logic [XLEN-1:0] ref_rdata;
  logic [63:0] time_mask, time_data, cmp_mask, cmp_data;

  // Byte-address reference: compare each bus byte's address against every
  // register byte. A transaction belongs to its starting register; bytes
  // beyond that register are ignored. No DUT barrel-shift expression reused.
  always_comb begin
    ref_rdata = '0;
    time_mask = '0;
    time_data = '0;
    cmp_mask = '0;
    cmp_data = '0;
    if (araddr == `RAPT_CLINT_MSIP) ref_rdata[0] = ref_msip;
    for (int reg_byte = 0; reg_byte < 8; reg_byte++) begin
      for (int bus_byte = 0; bus_byte < XLEN / 8; bus_byte++) begin
        if (araddr >= `RAPT_BUS_RTC_ADDR && araddr < XLEN'(`RAPT_BUS_RTC_ADDR)+XLEN'(8)
            && araddr+XLEN'(bus_byte) == XLEN'(`RAPT_BUS_RTC_ADDR)+XLEN'(reg_byte))
          ref_rdata[8*bus_byte+:8] = ref_mtime[8*reg_byte+:8];
        if (araddr >= `RAPT_CLINT_MTIMECMP && araddr < XLEN'(`RAPT_CLINT_MTIMECMP)+XLEN'(8)
            && araddr+XLEN'(bus_byte) == XLEN'(`RAPT_CLINT_MTIMECMP)+XLEN'(reg_byte))
          ref_rdata[8*bus_byte+:8] = ref_mtimecmp[8*reg_byte+:8];
        if (wvalid && wstrb[bus_byte]) begin
          if (awaddr >= `RAPT_BUS_RTC_ADDR && awaddr < XLEN'(`RAPT_BUS_RTC_ADDR)+XLEN'(8)
              && awaddr+XLEN'(bus_byte) == XLEN'(`RAPT_BUS_RTC_ADDR)+XLEN'(reg_byte)) begin
            time_mask[8*reg_byte+:8] = '1;
            time_data[8*reg_byte+:8] = wdata[8*bus_byte+:8];
          end
          if (awaddr >= `RAPT_CLINT_MTIMECMP && awaddr < XLEN'(`RAPT_CLINT_MTIMECMP)+XLEN'(8)
              && awaddr+XLEN'(bus_byte) == XLEN'(`RAPT_CLINT_MTIMECMP)+XLEN'(reg_byte)) begin
            cmp_mask[8*reg_byte+:8] = '1;
            cmp_data[8*reg_byte+:8] = wdata[8*bus_byte+:8];
          end
        end
      end
    end
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      ref_mtime <= '0;
      ref_mtimecmp <= 64'hffff_ffff_ffff_ffff;
      ref_msip <= 1'b0;
      ref_div_cnt <= '0;
    end else begin
      if (MTIME_DIV <= 1) begin
        ref_mtime <= ref_mtime + 64'd1;
      end else if (ref_div_cnt == DivW'(MTIME_DIV - 1)) begin
        ref_mtime <= ref_mtime + 64'd1;
        ref_div_cnt <= '0;
      end else begin
        ref_div_cnt <= ref_div_cnt + DivW'(1);
      end

      if (|time_mask) ref_mtime <= (ref_mtime & ~time_mask) | (time_data & time_mask);

      if (|cmp_mask) ref_mtimecmp <= (ref_mtimecmp & ~cmp_mask) | (cmp_data & cmp_mask);
      if (wvalid && awaddr == `RAPT_CLINT_MSIP && wstrb[0]) ref_msip <= wdata[0];
    end
  end

  logic f_past_valid = 1'b0;
  always_ff @(posedge clock) f_past_valid <= 1'b1;

  always_comb begin
    assume (f_past_valid || reset);
    if (f_past_valid) begin
      assert (dut_mtime == ref_mtime);
      assert (bus.mtime_value == ref_mtime);
      assert (dut_mtimecmp == ref_mtimecmp);
      assert (dut_msip == ref_msip);
      assert (dut_div_cnt == ref_div_cnt);
      assert (bus.rdata == ref_rdata);
      assert (bus.timer_int == (ref_mtime >= ref_mtimecmp));
      assert (bus.sw_int == ref_msip);
    end
  end

  always_ff @(posedge clock) begin
    if (f_past_valid && !reset) begin
      cover (bus.timer_int);
      cover (bus.sw_int);
      cover (wvalid && awaddr == XLEN'(`RAPT_BUS_RTC_ADDR) + XLEN'(7) && wstrb[0]);
      cover (MTIME_DIV > 1 && ref_mtime >= 64'd2);
    end
  end
endmodule
