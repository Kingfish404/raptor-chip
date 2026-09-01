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
    input logic wvalid
);
  localparam int DivW = (MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV);

  clint_bus_if #(.XLEN(XLEN)) bus();
  assign bus.araddr = araddr;
  assign bus.awaddr = awaddr;
  assign bus.wdata = wdata;
  assign bus.wvalid = wvalid;

  logic [63:0] dut_mtime, dut_mtimecmp;
  logic dut_msip;
  logic [DivW-1:0] dut_div_cnt;
  rapt_clint #(.XLEN(XLEN), .MTIME_DIV(MTIME_DIV)) dut (
      .clock, .reset, .clint_bus(bus),
      .formal_mtime(dut_mtime),
      .formal_mtimecmp(dut_mtimecmp),
      .formal_msip(dut_msip),
      .formal_mtime_div_cnt(dut_div_cnt)
  );

  logic [63:0] ref_mtime, ref_mtimecmp;
  logic ref_msip;
  logic [DivW-1:0] ref_div_cnt;
  logic [XLEN-1:0] ref_rdata;

  always_comb begin
    ref_rdata = '0;
    case (araddr)
      `RAPT_CLINT_MSIP: ref_rdata = XLEN'(ref_msip);
      `RAPT_CLINT_MTIMECMP: ref_rdata = ref_mtimecmp[XLEN-1:0];
      `RAPT_CLINT_MTIMECMP_UP:
        if (XLEN == 32) ref_rdata = ref_mtimecmp[63:32];
      `RAPT_BUS_RTC_ADDR: ref_rdata = ref_mtime[XLEN-1:0];
      `RAPT_BUS_RTC_ADDR_UP:
        if (XLEN == 32) ref_rdata = ref_mtime[63:32];
      default: ref_rdata = '0;
    endcase
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

      if (wvalid) begin
        case (awaddr)
          `RAPT_CLINT_MSIP: ref_msip <= wdata[0];
          `RAPT_CLINT_MTIMECMP: ref_mtimecmp[XLEN-1:0] <= wdata;
          `RAPT_CLINT_MTIMECMP_UP:
            if (XLEN == 32) ref_mtimecmp[63:32] <= wdata;
          default: ;
        endcase
      end
    end
  end

  logic f_past_valid = 1'b0;
  always_ff @(posedge clock) f_past_valid <= 1'b1;

  always_comb begin
    assume(f_past_valid || reset);
    if (f_past_valid) begin
      assert(dut_mtime == ref_mtime);
      assert(dut_mtimecmp == ref_mtimecmp);
      assert(dut_msip == ref_msip);
      assert(dut_div_cnt == ref_div_cnt);
      assert(bus.rdata == ref_rdata);
      assert(bus.timer_int == (ref_mtime >= ref_mtimecmp));
      assert(bus.sw_int == ref_msip);
    end
  end

  always_ff @(posedge clock) begin
    if (f_past_valid && !reset) begin
      cover(bus.timer_int);
      cover(bus.sw_int);
      cover(MTIME_DIV > 1 && ref_mtime >= 64'd2);
    end
  end
endmodule
