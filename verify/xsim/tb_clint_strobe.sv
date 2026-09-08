`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_clint_strobe;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  clint_bus_if #(.XLEN(XLEN)) clint_bus ();
  rapt_clint #(
      .XLEN(XLEN),
      .MTIME_DIV(3)
  ) dut (
      .*
  );
  `include "tb_common.svh"

  task automatic write_reg(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                           input logic [Bytes-1:0] strobes);
    clint_bus.awaddr = addr;
    clint_bus.wdata = data;
    clint_bus.wstrb = strobes;
    clint_bus.wvalid = 1;
    tick(1);
    clint_bus.wvalid = 0;
  endtask

  initial begin
    logic [63:0] expected, payload;
    clint_bus.araddr = 0;
    clint_bus.awaddr = 0;
    clint_bus.wdata = 0;
    clint_bus.wstrb = 0;
    clint_bus.wvalid = 0;
    tick(2);
    reset = 0;
    tick(1);
    // Every mask, including zero, for the low register and the +4 alias.
    for (int half = 0; half < 2; half++) begin
      for (int mask = 0; mask < (1 << Bytes); mask++) begin
        write_reg(XLEN'('h02004000), '1, '1);
        write_reg(XLEN'('h02004004), '1, '1);
        expected = '1;
        payload = 64'h0123456789abcdef ^ (64'(mask) << 16);
        write_reg(XLEN'('h02004000) + XLEN'(half) * XLEN'(4), XLEN'(payload), Bytes'(mask));
        for (int b = 0; b < Bytes; b++)
        if ((mask & (1 << b)) != 0 && (half == 0 || b < 4))
          expected[half*32+b*8+:8] = payload[b*8+:8];
        clint_bus.araddr = XLEN'('h02004000);
        #1;
        check(clint_bus.rdata == XLEN'(expected), "low read lost unselected byte");
        clint_bus.araddr = XLEN'('h02004004);
        #1;
        check(clint_bus.rdata == XLEN'(expected[63:32]), "high alias or byte mask mismatch");
      end
    end
    // MSIP must ignore writes whose byte-zero strobe is clear.
    write_reg(XLEN'('h02000000), XLEN'(1), '1);
    write_reg(XLEN'('h02000000), '0, ~Bytes'(1));
    check(clint_bus.sw_int, "masked MSIP write changed interrupt");
    write_reg(XLEN'('h02000000), '0, Bytes'(1));
    check(!clint_bus.sw_int, "enabled MSIP write did not clear interrupt");
    $display("PASS: CLINT byte masks and high alias XLEN=%0d masks=%0d", XLEN, 2 * (1 << Bytes));
    $finish;
  end
endmodule
