// Directed regression for rapt_fpu_fma (single & double), covering the
// subnormal / zero / rounding corner cases that previously failed RISCOF.
// Handshake: assert `valid` for one cycle, result appears on `result`/`flags`
// `result_valid` marks the completion cycle.
module tb;
  logic clock = 0, reset = 1, flush = 0, valid = 0;
  logic [5:0]  op;
  logic [63:0] a, b, c;
  logic [2:0]  rm;
  logic [63:0] res;
  logic [4:0]  flags;
  logic        rdy, rv;
  logic        rdy_s, rv_s;
  logic [63:0] res_s;
  logic [4:0]  flags_s;

  int errors = 0;

  rapt_fpu_fma #(.TARGET_DOUBLE(1'b1)) dut_d (
    .clock(clock), .reset(reset), .flush(flush), .valid(valid), .ready(rdy),
    .op(op), .operand_a(a), .operand_b(b), .operand_c(c),
    .rounding_mode(rm), .result(res), .flags(flags), .result_valid(rv));

  rapt_fpu_fma #(.TARGET_DOUBLE(1'b0)) dut_s (
    .clock(clock), .reset(reset), .flush(flush), .valid(valid), .ready(rdy_s),
    .op(op), .operand_a(a), .operand_b(b), .operand_c(c),
    .rounding_mode(rm), .result(res_s), .flags(flags_s), .result_valid(rv_s));

  always #5 clock = ~clock;

  task td_rm(input [63:0] x, y, z, input [2:0] rm_value,
             input [63:0] er, input [4:0] ef);
    begin
      @(negedge clock); a = x; b = y; c = z; rm = rm_value; op = 52; valid = 1;
      @(negedge clock); valid = 0;
      while (!rv) @(negedge clock);
      if (res !== er || flags !== ef) begin
        errors++;
        $display("FAIL fmadd.d(%h,%h,%h)=%h flags=%b  expect %h/%b", x, y, z, res, flags, er, ef);
      end else
        $display("OK   fmadd.d(%h,%h,%h)=%h flags=%b", x, y, z, res, flags);
    end
  endtask

  // FMADD.D, round-to-nearest-even.
  task td(input [63:0] x, y, z, input [63:0] er, input [4:0] ef);
    td_rm(x, y, z, 3'b000, er, ef);
  endtask

  // FMADD.S; all ordinary single inputs are passed in architectural
  // NaN-boxed form.  A deliberately unboxed operand is passed unchanged.
  task ts(input [63:0] x, y, z, input [63:0] er, input [4:0] ef);
    begin
      @(negedge clock); a = x; b = y; c = z; rm = 0; op = 48; valid = 1;
      @(negedge clock); valid = 0;
      while (!rv_s) @(negedge clock);
      if (res_s !== er || flags_s !== ef) begin
        errors++;
        $display("FAIL fmadd.s(%h,%h,%h)=%h flags=%b  expect %h/%b", x, y, z, res_s, flags_s, er, ef);
      end else
        $display("OK   fmadd.s(%h,%h,%h)=%h flags=%b", x, y, z, res_s, flags_s);
    end
  endtask

  initial begin
    repeat (2) @(negedge clock); reset = 0;

    // basics
    td(64'h3FF0000000000000, 64'h3FF0000000000000, 64'h3FF0000000000000,
       64'h4000000000000000, 5'b00000);              // 1*1+1 = 2
    td(64'h3FF0000000000000, 64'h3FF0000000000000, 64'hBFF0000000000000,
       64'h0000000000000000, 5'b00000);              // 1*1-1 = +0

    // zero multiplicand must not swallow the addend
    td(64'h3FF0000000000000, 64'h0, 64'h0000000000000001,
       64'h0000000000000001, 5'b00000);              // 1*0 + minsub
    td(64'h5ef0982835de77ff, 64'h0, 64'h0000000000000001,
       64'h0000000000000001, 5'b00000);              // big*0 + minsub (RISCOF inst_252)

    // subnormal normalization (MinExp base)
    td(64'h3FF0000000000000, 64'h0000000000000001, 64'h0,
       64'h0000000000000001, 5'b00000);              // 1*minsub exact

    // total underflow -> +0 with NX|UF
    td(64'h0000000000000001, 64'h0000000000000001, 64'h0,
       64'h0000000000000000, 5'b00011);              // minsub*minsub

    // A tiny opposite-sign product leaves the addend just below the minimum
    // normal value and must round back up to that minimum normal value.
    td(64'h0010000000000000, 64'h93baee6bce4426c6, 64'h0010000000000000,
       64'h0010000000000000, 5'b00001);
    td_rm(64'h0010000000000000, 64'h99a6baae71eb5a39, 64'h800fffffffffffff,
       3'b010, 64'h8010000000000000, 5'b00011);
    ts(64'hffff_ffff_00800000, 64'hffff_ffff_8b3c5d89,
       64'hffff_ffff_00800000, 64'hffff_ffff_00800000, 5'b00001);

    // Unboxed single-precision operands are canonical quiet NaNs.
    ts(64'hffff_eff0_3f800000, 64'hffff_ffff_3f800000,
       64'hffff_ffff_3f800000, 64'hffff_ffff_7fc00000, 5'b00000);

    if (errors == 0) $display("FMA-UNIT PASS");
    else             $display("FMA-UNIT FAIL (%0d errors)", errors);
    repeat (2) @(negedge clock); $finish;
  end
endmodule
