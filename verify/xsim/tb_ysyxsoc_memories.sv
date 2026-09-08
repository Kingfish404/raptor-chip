`timescale 1ns / 1ps
module tb_ysyxsoc_memories;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic [31:0] addr = 0, wdata = 0;
  logic [3:0] strb = 0;
  logic enable = 0, wr = 0;
  logic [1:0] sel = 0, ready, error;
  wire [31:0] rdata[2];
  wire sc, cke, cs, ras, cas, we;
  wire [12:0] sa;
  wire [1:0] ba, dqm;
  wire [15:0] dq;
  wire sck, ce_n;
  wire [3:0] dio;
  sdram_top_apb dram_ctrl (
      .clock(clock),
      .reset(reset),
      .in_paddr(addr),
      .in_psel(sel[0]),
      .in_penable(enable),
      .in_pprot(3'b0),
      .in_pwrite(wr),
      .in_pwdata(wdata),
      .in_pstrb(strb),
      .in_pready(ready[0]),
      .in_prdata(rdata[0]),
      .in_pslverr(error[0]),
      .sdram_clk(sc),
      .sdram_cke(cke),
      .sdram_cs(cs),
      .sdram_ras(ras),
      .sdram_cas(cas),
      .sdram_we(we),
      .sdram_a(sa),
      .sdram_ba(ba),
      .sdram_dqm(dqm),
      .sdram_dq(dq)
  );
  sdram dram (
      .clk(sc),
      .cke(cke),
      .cs(cs),
      .ras(ras),
      .cas(cas),
      .we(we),
      .a(sa),
      .ba(ba),
      .dqm(dqm),
      .dq(dq)
  );
  psram_top_apb psram_ctrl (
      .clock(clock),
      .reset(reset),
      .in_paddr(addr),
      .in_psel(sel[1]),
      .in_penable(enable),
      .in_pprot(3'b0),
      .in_pwrite(wr),
      .in_pwdata(wdata),
      .in_pstrb(strb),
      .in_pready(ready[1]),
      .in_prdata(rdata[1]),
      .in_pslverr(error[1]),
      .qspi_sck(sck),
      .qspi_ce_n(ce_n),
      .qspi_dio(dio)
  );
  psram ps (
      .sck(sck),
      .ce_n(ce_n),
      .dio(dio)
  );
  task automatic access (input int target, input bit write, input logic [31:0] address, data,
                         input logic [3:0] mask, output logic [31:0] result);
    @(negedge clock);
    addr = address;
    wdata = data;
    strb = mask;
    wr = write;
    sel = 2'(1 << target);
    enable = 0;
    @(negedge clock);
    enable = 1;
    for (int n = 0; n < 20000; n++) begin
      @(posedge clock);
      if (ready[target]) begin
        if (error[target]) $fatal(1, "APB error");
        result = rdata[target];
        @(negedge clock);
        sel = 0;
        enable = 0;
        return;
      end
    end
    $fatal(1, "APB timeout target=%0d addr=%h", target, address);
  endtask
  logic [31:0] result, expected, base;
  initial begin
    repeat (4) @(negedge clock);
    reset = 0;
    for (int target = 0; target < 2; target++) begin
      for (int i = 0; i < 12; i++) begin
        base = (target == 0 ? 32'ha0000000 : 32'h80000000) + 32'(i*1020);
        expected = 32'ha1b2c3d4 ^ 32'(i*87654);
        access (target, 1, base, expected, 4'hf, result);
        access (target, 0, base, 0, 4'hf, result);
        if (result !== expected)
          $fatal(
              1,
              "read mismatch target=%0d addr=%h got=%h expected=%h",
              target,
              base,
              result,
              expected
          );
        for (int lane = 0; lane < 4; lane++) begin
          expected[lane*8+:8] = 8'(i + lane + 1);
          access (target, 1, base + 32'(lane), expected, 4'(1 << lane), result);
          access (target, 0, base, 0, 4'hf, result);
          if (result !== expected)
            $fatal(
                1,
                "masked write mismatch target=%0d addr=%h lane=%0d got=%h expected=%h",
                target,
                base,
                lane,
                result,
                expected
            );
        end
      end
    end
    $display("PASS: upstream SDRAM/PSRAM controllers, full-word and all byte lanes");
    $finish;
  end
endmodule
