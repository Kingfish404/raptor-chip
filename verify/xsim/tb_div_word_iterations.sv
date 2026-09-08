`include "rapt.svh"

module tb_div_word_iterations #(
    parameter int WordLatency = 33
);
  localparam int X = `RAPT_XLEN;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic [X-1:0] in_a, in_b, out_r;
  logic [4:0] in_op;
  logic in_word, in_valid = 0, in_ready, out_valid;
  logic [7:0] in_tag, out_tag;
  logic [63:0] rng = 64'h6476_3230_2609_0501;
  int tested = 0;
  rapt_ieu_mul #(
      .XLEN(X),
      .TAG_W(8)
  ) dut (
      .*
  );

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  function automatic logic [63:0] random_bits();
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
  endfunction

  function automatic logic [X-1:0] reference_result(logic [X-1:0] a, b, logic [4:0] op,
                                                    bit word_op);
    logic [X-1:0] aa, bb, result_bits;
    bit signed_op;
    signed_op = op == `RAPT_ALU_DIV___ || op == `RAPT_ALU_REM___;
    aa = a;
    bb = b;
    if (X > 32 && word_op) begin
      aa = signed_op ? X'($signed(a[31:0])) : X'(a[31:0]);
      bb = signed_op ? X'($signed(b[31:0])) : X'(b[31:0]);
    end
    // Handle architectural overflow before evaluating simulator division.
    if (signed_op && aa == (X'(1) << (X - 1)) && bb == {X{1'b1}})
      result_bits = op == `RAPT_ALU_DIV___ ? aa : '0;
    else
      case (op)
        `RAPT_ALU_DIV___: result_bits = bb == 0 ? '1 : X'($signed(aa) / $signed(bb));
        `RAPT_ALU_DIVU__: result_bits = bb == 0 ? '1 : aa / bb;
        `RAPT_ALU_REM___: result_bits = bb == 0 ? aa : X'($signed(aa) % $signed(bb));
        default: result_bits = bb == 0 ? aa : aa % bb;
      endcase
    return (X > 32 && word_op) ? X'($signed(result_bits[31:0])) : result_bits;
  endfunction

  task automatic check_div(logic [X-1:0] a, b, logic [4:0] op, bit word_op);
    logic [X-1:0] expected;
    int latency;
    expected = reference_result(a, b, op, word_op);
    @(negedge clock);
    assert (in_ready)
    else $fatal(1, "divider not ready between transactions");
    in_a = a;
    in_b = b;
    in_op = op;
    in_word = word_op;
    in_tag = 8'(tested);
    in_valid = 1;
    tick();
    in_valid = 0;
    latency = (X > 32 && word_op) ? WordLatency : X + 1;
    for (int c = 1; c <= latency; c++) begin
      tick();
      assert (out_valid == (c == latency))
      else $fatal(1, "unexpected divider latency c=%0d expected=%0d", c, latency);
    end
    assert (out_r == expected && out_tag == in_tag)
    else
      $fatal(
          1,
          "division mismatch a=%h b=%h op=%h word=%b got=%h expected=%h",
          a,
          b,
          op,
          word_op,
          out_r,
          expected
      );
    tick();
    assert (!out_valid)
    else $fatal(1, "duplicate divider completion");
    tested++;
  endtask

  task automatic kill_div(input int iterations);
    @(negedge clock);
    in_a = X'(32'h8000_0000);
    in_b = X'(7);
    in_op = `RAPT_ALU_REM___;
    in_word = (X > 32);
    in_valid = 1;
    tick();
    in_valid = 0;
    repeat (iterations) tick();
    flush = 1;
    tick();
    flush = 0;
    repeat (3) begin
      assert (!out_valid && in_ready)
      else $fatal(1, "flushed divider leaked or stayed busy");
      tick();
    end
    check_div(X'(99), X'(7), `RAPT_ALU_REM___, (X > 32));
  endtask

  logic [X-1:0] edge_values[8];
  logic [4:0] operations[4];
  initial begin
    in_a = 0;
    in_b = 0;
    in_op = 0;
    in_word = 0;
    in_tag = 0;
    edge_values = '{X'(0), X'(1), X'(-1), X'(32'h8000_0000),
                   X'(32'h7fff_ffff), X'(64'h8000_0000_0000_0000),
                   X'(64'hfedc_ba98_8000_0000), X'(64'habcd_1234_0000_0000)};
    operations = '{`RAPT_ALU_DIV___, `RAPT_ALU_DIVU__, `RAPT_ALU_REM___, `RAPT_ALU_REMU__};
    tick();
    reset = 0;
    for (int w = 0; w < (X > 32 ? 2 : 1); w++) begin
      foreach (operations[o]) begin
        foreach (edge_values[a])
        foreach (edge_values[b]) check_div(edge_values[a], edge_values[b], operations[o], 1'(w));
        repeat (100) check_div(X'(random_bits()), X'(random_bits()), operations[o], 1'(w));
      end
    end
    kill_div(1);
    kill_div(16);
    kill_div(32);  // Flush wins on the 32-iteration schedule's completion edge.
    $display("PASS: divider arithmetic/tag/latency/flush XLEN=%0d cases=%0d", X, tested);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "divider test timeout");
  end
endmodule
