`timescale 1ns / 1ps
module tb_rapt_arty_operand_probe;
  logic clock = 0;
  logic reset = 1;
  logic write_i = 0;
  logic [5:0] tag_i = 0;
  logic [31:0] value_i = 0;
  wire ready_o, valid_o;
  wire [ 5:0] tag_o;
  wire [31:0] value_o;
  always #25 clock = !clock;
  rapt_arty_operand_probe u_dut (.*);
  initial begin
    #1000;
    @(negedge clock);
    reset   = 0;
    tag_i   = 6'd32;
    value_i = 32'h80040000;
    write_i = 1;
    @(negedge clock);
    write_i = 0;
    #1;
    $display("OPERAND valid=%b tag=%h value=%h", valid_o, tag_o, value_o);
    if (valid_o !== 1'b1 || tag_o !== 6'd32 || value_o !== 32'h80040000)
      $fatal(1, "physical tag storage mismatch");
    $display("RAPT_OPERAND_PROBE_PASS");
    $finish;
  end
endmodule
