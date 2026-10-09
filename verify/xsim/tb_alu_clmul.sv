`include "rapt.svh"

module tb_alu_clmul;
  localparam int Xlen = `RAPT_XLEN;
  logic [Xlen-1:0] s1, s2, out_r;
  logic [5:0] op;
  logic word;
  int checks;
  logic [31:0] rng_state = 32'h63f42a19;

  rapt_ieu_alu #(.XLEN(Xlen)) dut (.*);

  // Polynomial convolution: compute each output coefficient independently.
  function automatic logic [2*Xlen-1:0] product(input logic [Xlen-1:0] a, b);
    logic [2*Xlen-1:0] result;
    result = '0;
    for (int degree = 0; degree < 2 * Xlen - 1; degree++) begin
      for (int i = 0; i < Xlen; i++) begin
        if (degree >= i && degree - i < Xlen) result[degree] ^= a[i] & b[degree-i];
      end
    end
    return result;
  endfunction

  function automatic logic [31:0] next_random();
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
  endfunction

  task automatic check_pair(input logic [Xlen-1:0] a, b);
    logic [2*Xlen-1:0] expected_product;
    logic [Xlen-1:0] expected;
    expected_product = product(a, b);
    s1 = a;
    s2 = b;
    for (int operation = 0; operation < 3; operation++) begin
      for (int w = 0; w < (Xlen == 64 ? 2 : 1); w++) begin
        word = 1'(w);
        case (operation)
          0: begin
            op = `RAPT_ALU_CLMUL;
            expected = expected_product[Xlen-1:0];
          end
          1: begin
            op = `RAPT_ALU_CLMULH;
            expected = expected_product[2*Xlen-1:Xlen];
          end
          default: begin
            op = `RAPT_ALU_CLMULR;
            expected = expected_product[2*Xlen-2-:Xlen];
          end
        endcase
        if (word) expected = Xlen'($signed(expected[31:0]));
        #1;
        assert (out_r == expected)
        else
          $fatal(
              1,
              "CLMUL RV%0d op=%0d word=%b a=%h b=%h got=%h expected=%h",
              Xlen,
              operation,
              word,
              a,
              b,
              out_r,
              expected
          );
        checks++;
      end
    end
  endtask

  initial begin
    logic [Xlen-1:0] a, b;
    checks = 0;
    check_pair('0, '0);
    check_pair('0, '1);
    check_pair('1, '0);
    check_pair('1, '1);
    for (int i = 0; i < Xlen; i++) begin
      for (int j = 0; j < Xlen; j++) check_pair(Xlen'(1) << i, Xlen'(1) << j);
      check_pair('1, Xlen'(1) << i);
      check_pair(Xlen'(1) << i, '1);
    end
    for (int sample = 0; sample < 2048; sample ++) begin
      for (int part = 0; part < Xlen / 32; part++) begin
        a[32*part+:32] = next_random();
        b[32*part+:32] = next_random();
      end
      check_pair(a, b);
    end
    $display("PASS: RV%0d CLMUL/H/R polynomial convolution, %0d checks", Xlen, checks);
    $finish;
  end
endmodule
