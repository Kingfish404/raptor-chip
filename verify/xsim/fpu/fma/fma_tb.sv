// Directed regression for rapt_fpu_fma (single & double), covering the
// subnormal / zero / rounding corner cases that previously failed RISCOF.
// Handshake: assert `valid` for one cycle, result appears on `result`/`flags`
// `result_valid` marks the completion cycle.
module tb;
  logic clock = 0, reset = 1, flush = 0, valid = 0;
  logic [5:0] op;
  logic [63:0] a, b, c;
  logic [2:0]  rm;
  logic [63:0] res;
  logic [4:0]  flags;
  logic rdy, rv;
  logic rdy_s, rv_s;
  logic [63:0] res_s;
  logic [4:0]  flags_s;

  int errors = 0;

  rapt_fpu_fma #(
      .TARGET_DOUBLE(1'b1)
  ) dut_d (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(valid),
      .ready(rdy),
      .op(op),
      .operand_a(a),
      .operand_b(b),
      .operand_c(c),
      .rounding_mode(rm),
      .result(res),
      .flags(flags),
      .result_valid(rv)
  );

  rapt_fpu_fma #(
      .TARGET_DOUBLE(1'b0)
  ) dut_s (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(valid),
      .ready(rdy_s),
      .op(op),
      .operand_a(a),
      .operand_b(b),
      .operand_c(c),
      .rounding_mode(rm),
      .result(res_s),
      .flags(flags_s),
      .result_valid(rv_s)
  );

  always #5 clock = ~clock;

  task td_rm(input [63:0] x, y, z, input [2:0] rm_value, input [63:0] er, input [4:0] ef);
    begin
      @(negedge clock);
      a = x;
      b = y;
      c = z;
      rm = rm_value;
      op = 52;
      valid = 1;
      @(negedge clock);
      valid = 0;
      while (!rv) @(negedge clock);
      if (res !== er || flags !== ef) begin
        errors++;
        $display("FAIL fmadd.d(%h,%h,%h)=%h flags=%b  expect %h/%b", x, y, z, res, flags, er, ef);
      end else $display("OK   fmadd.d(%h,%h,%h)=%h flags=%b", x, y, z, res, flags);
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
      @(negedge clock);
      a = x;
      b = y;
      c = z;
      rm = 0;
      op = 48;
      valid = 1;
      @(negedge clock);
      valid = 0;
      while (!rv_s) @(negedge clock);
      if (res_s !== er || flags_s !== ef) begin
        errors++;
        $display("FAIL fmadd.s(%h,%h,%h)=%h flags=%b  expect %h/%b", x, y, z, res_s, flags_s, er,
                 ef);
      end else $display("OK   fmadd.s(%h,%h,%h)=%h flags=%b", x, y, z, res_s, flags_s);
    end
  endtask

  // Exact cancellation residuals of 1/4, 1/2 and 3/4 minimum subnormal.
  // Exercise every rounding mode and fused sign variant, with both result signs.
  task deep_cancellation;
    logic [63:0] sign_bit, x, y, z, expected, actual;
    logic [4:0] actual_flags;
    bit increment;
    for (int d = 0; d < 2; d++) begin
      sign_bit = d ? 64'h8000000000000000 : 64'h0000000080000000;
      for (int variant = 0; variant < 4; variant++) begin
        for (int negative = 0; negative < 2; negative++) begin
          for (int mode = 0; mode < 5; mode++) begin
            for (int quarter = 1; quarter < 4; quarter++) begin
              x = d ? 64'h0010000000000000 | (64'(quarter) << 50)
                    : 64'h0000000000800000 | (64'(quarter) << 21);
              y = d ? 64'h3ff0000000000001 : 64'h000000003f800001;
              z = (x + 1) ^ sign_bit;
              if (negative != 0) begin
                x ^= sign_bit;
                z ^= sign_bit;
              end
              if (variant >= 2) x ^= sign_bit;
              if (variant == 1 || variant == 3) z ^= sign_bit;
              increment = (mode == 0 && quarter > 2)
                || (mode == 2 && negative != 0)
                || (mode == 3 && negative == 0)
                || (mode == 4 && quarter >= 2);
              expected = (negative != 0 ? sign_bit : 64'b0) | 64'(increment);
              if (d == 0) begin
                x |= 64'hffffffff00000000;
                y |= 64'hffffffff00000000;
                z |= 64'hffffffff00000000;
                expected |= 64'hffffffff00000000;
              end
              @(negedge clock);
              a = x;
              b = y;
              c = z;
              rm = 3'(mode);
              op = 6'(51 + d + 2 * variant);
              valid = 1;
              @(negedge clock);
              valid = 0;
              while (!(d != 0 ? rv : rv_s)) @(negedge clock);
              actual = d != 0 ? res : res_s;
              actual_flags = d != 0 ? flags : flags_s;
              if (actual !== expected || actual_flags !== 5'b00011) begin
                errors++;
                $display("FAIL cancellation d=%0d variant=%0d sign=%0d rm=%0d quarter=%0d", d,
                         variant, negative, mode, quarter);
                $display("  got %h/%h expected %h/03", actual, actual_flags, expected);
              end
            end
          end
        end
      end
    end
    $display("FMA deep-cancellation: 240 checks completed");
  endtask

  initial begin
    repeat (2) @(negedge clock);
    reset = 0;

    deep_cancellation();

    // Deep cancellation can also leave an exact minimum subnormal: no UF/NX.
    ts(64'hffff_ffff_01000000, 64'hffff_ffff_3f800000, 64'hffff_ffff_80ffffff,
       64'hffff_ffff_00000001, 5'b00000);
    td(64'h0020000000000000, 64'h3ff0000000000000, 64'h801fffffffffffff, 64'h0000000000000001,
       5'b00000);

    // (1 + ulp) * (1 - ulp) - 1 leaves an exact subnormal requiring a left shift.
    ts(64'hffff_ffff_17000001, 64'hffff_ffff_3f7ffffe, 64'hffff_ffff_97000000,
       64'hffff_ffff_80400000, 5'b00000);
    td(64'h0680000000000001, 64'h3feffffffffffffe, 64'h8680000000000000, 64'h8008000000000000,
       5'b00000);

    // basics
    td(64'h3FF0000000000000, 64'h3FF0000000000000, 64'h3FF0000000000000, 64'h4000000000000000,
       5'b00000);  // 1*1+1 = 2
    td(64'h3FF0000000000000, 64'h3FF0000000000000, 64'hBFF0000000000000, 64'h0000000000000000,
       5'b00000);  // 1*1-1 = +0

    // zero multiplicand must not swallow the addend
    td(64'h3FF0000000000000, 64'h0, 64'h0000000000000001, 64'h0000000000000001,
       5'b00000);  // 1*0 + minsub
    td(64'h5ef0982835de77ff, 64'h0, 64'h0000000000000001, 64'h0000000000000001,
       5'b00000);  // big*0 + minsub (RISCOF inst_252)

    // subnormal normalization (MinExp base)
    td(64'h3FF0000000000000, 64'h0000000000000001, 64'h0, 64'h0000000000000001,
       5'b00000);  // 1*minsub exact

    // total underflow -> +0 with NX|UF
    td(64'h0000000000000001, 64'h0000000000000001, 64'h0, 64'h0000000000000000,
       5'b00011);  // minsub*minsub

    // A tiny opposite-sign product leaves the addend just below the minimum
    // normal value and must round back up to that minimum normal value.
    td(64'h0010000000000000, 64'h93baee6bce4426c6, 64'h0010000000000000, 64'h0010000000000000,
       5'b00001);
    td_rm(64'h0010000000000000, 64'h99a6baae71eb5a39, 64'h800fffffffffffff, 3'b010,
          64'h8010000000000000, 5'b00011);
    ts(64'hffff_ffff_00800000, 64'hffff_ffff_8b3c5d89, 64'hffff_ffff_00800000,
       64'hffff_ffff_00800000, 5'b00001);

    // Unboxed single-precision operands are canonical quiet NaNs.
    ts(64'hffff_eff0_3f800000, 64'hffff_ffff_3f800000, 64'hffff_ffff_3f800000,
       64'hffff_ffff_7fc00000, 5'b00000);

    if (errors == 0) $display("FMA-UNIT PASS");
    else $fatal(1, "FMA-UNIT FAIL (%0d errors)", errors);
    repeat (2) @(negedge clock);
    $finish;
  end
endmodule
