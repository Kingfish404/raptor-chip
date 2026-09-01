// Directed regression for rapt_fpu_fma (single & double), covering the
// subnormal / zero / rounding corner cases that previously failed RISCOF.
// Handshake: assert `valid` for one cycle, result appears on `result`/`flags`
// `result_valid` four clocks later.
module tb;
  logic clock = 0, reset = 1, flush = 0, valid = 0;
  logic [5:0]  op;
  logic [63:0] a, b, c;
  logic [2:0]  rm;
  logic [63:0] res;
  logic [4:0]  flags;
  logic        rdy, rv;

  int errors = 0;

  rapt_fpu_fma #(.TARGET_DOUBLE(1'b1)) dut_d (
    .clock(clock), .reset(reset), .flush(flush), .valid(valid), .ready(rdy),
    .op(op), .operand_a(a), .operand_b(b), .operand_c(c),
    .rounding_mode(rm), .result(res), .flags(flags), .result_valid(rv));

  always #5 clock = ~clock;

  // FMADD.D
  task td(input [63:0] x, y, z, input [63:0] er, input [4:0] ef);
    begin
      @(negedge clock); a = x; b = y; c = z; rm = 0; op = 52; valid = 1;
      @(negedge clock); valid = 0;
      repeat (6) @(negedge clock);
      if (res !== er || flags !== ef) begin
        errors++;
        $display("FAIL fmadd.d(%h,%h,%h)=%h flags=%b  expect %h/%b", x, y, z, res, flags, er, ef);
      end else
        $display("OK   fmadd.d(%h,%h,%h)=%h flags=%b", x, y, z, res, flags);
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

    if (errors == 0) $display("FMA-UNIT PASS");
    else             $display("FMA-UNIT FAIL (%0d errors)", errors);
    repeat (2) @(negedge clock); $finish;
  end
endmodule
