`timescale 1ns / 1ps
module tb_rapt_arty_prf_probe;
  logic clock = 0, reset = 1, write_i = 0;
  logic [5:0] address_i = 0;
  logic [31:0] data_i = 0;
  wire valid_o;
  wire [31:0] data_o;
  always #25 clock = !clock;
  rapt_arty_prf_probe u_dut (.*);
  initial begin
    #1000;
    @(negedge clock);
    reset = 0;
    for (int address = 1; address < 48; address++) begin
      address_i = 6'(address);
      data_i = 32'h1357_9bdf ^ (32'h0101_0101 * 32'(address));
      write_i = 1;
      @(negedge clock);
      write_i = 0;
      #1;
      if (valid_o !== 1'b1 || data_o !== data_i)
        $fatal(1, "PRF address=%0d valid=%b data=%h expected=%h", address, valid_o, data_o, data_i);
      @(negedge clock);
    end
    $display("RAPT_PRF_PROBE_PASS addresses=1..47");
    $finish;
  end
endmodule
