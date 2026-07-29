`include "rapt.svh"

module tb_alu_zbb_strlen;
  localparam int XLEN = 64;

  logic [XLEN-1:0] source;
  logic [XLEN-1:0] inverted;
  logic [5:0] op;
  logic word;
  logic [XLEN-1:0] result;

  rapt_exu_alu #(
      .XLEN(XLEN)
  ) dut (
      .s1(source),
      .s2('0),
      .op(op),
      .word(word),
      .out_r(result)
  );

  task automatic check_result(input logic [XLEN-1:0] expected, input string message);
    #1;
    if (result !== expected) begin
      $display("FAIL: %s: got %016h expected %016h", message, result, expected);
      $fatal(1);
    end
  endtask

  initial begin
    word = 1'b0;

    source = 64'h0063_6261_2f76_6564;
    op = `RAPT_ALU_ORCB;
    check_result(64'h00ff_ffff_ffff_ffff, "orc.b marks nonzero bytes");

    inverted = ~result;
    source = inverted;
    op = `RAPT_ALU_CTZ_;
    check_result(64'd56, "ctz locates the first zero byte");
    if ((result >> 3) !== 64'd7) begin
      $display("FAIL: strlen_zbb result: got %0d expected 7", result >> 3);
      $fatal(1);
    end

    source = 64'hffff_ffff_ffff_ffff;
    op = `RAPT_ALU_ORCB;
    check_result(64'hffff_ffff_ffff_ffff, "orc.b handles a full nonzero word");

    source = ~result;
    op = `RAPT_ALU_CTZ_;
    check_result(64'd64, "ctz zero returns XLEN");

    $display("PASS: RV64 strlen_zbb ALU sequence");
    $finish;
  end
endmodule
