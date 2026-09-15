`include "rapt.svh"

// The same scoreboard runs on RTL and a Vivado functional netlist. It checks
// signed/high products, output ownership, bubbles, flushes and DIV arbitration.
module tb_muldiv_fpga;
  localparam int X = `RAPT_XLEN;
  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic [X-1:0] in_a = 0, in_b = 0, out_r;
  logic [4:0] in_op = 0;
  logic in_word = 0, in_valid = 0, in_ready, out_valid;
  logic [3:0] in_tag = 0, out_tag;
`ifdef RAPT_GATE_NETLIST
  rapt_ieu_mul dut (.*);
`else
  rapt_ieu_mul #(
      .XLEN(X),
      .TAG_W(4),
      .UseDsp(1)
  ) dut (
      .*
  );
`endif

  bit [15:0] pending = 0;
  logic [X-1:0] expected[16];
  int accepted = 0, completed = 0, killed = 0, cycle = 0;
  int counts[8];
  int unsigned rng = 32'h6d756c39;
  logic [4:0] ops[8] = '{`RAPT_ALU_MUL___, `RAPT_ALU_MULH__,
      `RAPT_ALU_MULHSU, `RAPT_ALU_MULHU_, `RAPT_ALU_DIV___,
      `RAPT_ALU_DIVU__, `RAPT_ALU_REM___, `RAPT_ALU_REMU__};
  function automatic int unsigned next_random();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  function automatic logic [X-1:0] reference_result();
    logic [X-1:0] a, b, v;
    logic signed [2*X-1:0] sa, sb, product;
    bit signed_a, signed_b;
    signed_a = in_op == `RAPT_ALU_MULH__ || in_op == `RAPT_ALU_MULHSU
        || in_op == `RAPT_ALU_DIV___ || in_op == `RAPT_ALU_REM___;
    signed_b = in_op == `RAPT_ALU_MULH__
        || in_op == `RAPT_ALU_DIV___ || in_op == `RAPT_ALU_REM___;
    a = in_a;
    b = in_b;
    if (X == 64 && in_word) begin
      a = signed_a ? X'($signed(in_a[31:0])) : X'(in_a[31:0]);
      b = signed_b ? X'($signed(in_b[31:0])) : X'(in_b[31:0]);
    end
    sa = signed_a ? {{X{a[X-1]}}, a} : {{X{1'b0}}, a};
    sb = signed_b ? {{X{b[X-1]}}, b} : {{X{1'b0}}, b};
    product = sa * sb;
    case (in_op)
      `RAPT_ALU_MUL___: v = product[X-1:0];
      `RAPT_ALU_MULH__, `RAPT_ALU_MULHSU, `RAPT_ALU_MULHU_: v = product[2*X-1:X];
      `RAPT_ALU_DIV___: v = b == 0 ? '1 : X'(sa / sb);
      `RAPT_ALU_DIVU__: v = b == 0 ? '1 : a / b;
      `RAPT_ALU_REM___: v = b == 0 ? a : X'(sa % sb);
      default: v = b == 0 ? a : a % b;
    endcase
    return X == 64 && in_word ? X'($signed(v[31:0])) : v;
  endfunction

  always @(posedge clock) begin
    cycle++;
    if (reset || flush) begin
      killed += $countones(pending);
      pending = 0;
    end else begin
      assert (!$isunknown({in_ready, out_valid}))
      else $fatal(1, "unknown control");
      if (out_valid) begin
        assert (!$isunknown({out_tag, out_r}) && pending[out_tag])
        else $fatal(1, "stale/unknown completion");
        assert (out_r == expected[out_tag])
        else
          $fatal(
              1, "tag=%0d got=%h expected=%h cycle=%0d", out_tag, out_r, expected[out_tag], cycle
          );
        pending[out_tag] = 0;
        completed++;
      end
      if (in_valid && in_ready) begin
        assert (!pending[in_tag])
        else $fatal(1, "test reused live tag");
        expected[in_tag] = reference_result();
        pending[in_tag] = 1;
        accepted++;
        foreach (ops[i]) if (in_op == ops[i]) counts[i]++;
      end
    end
  end

  initial begin
    // Allow the Xilinx global startup reset to finish in netlist simulation.
    repeat (25) @(negedge clock);
    reset = 0;
    for (int n = 0; n < 12000; n++) begin
      automatic int op_idx;
      automatic int tag_idx;
      automatic logic [31:0] draws[7];
      @(negedge clock);
      foreach (draws[d]) draws[d] = next_random();
      flush = n > 256 && (n % 173 == 0 || n % 173 == 1);
      in_valid = !flush && (n < 256 || (draws[0] % 5 != 0));
      tag_idx = -1;
      for (int t = 0; t < 16; t++) if (!pending[t] && tag_idx < 0) tag_idx = t;
      if (tag_idx < 0) in_valid = 0;
      in_tag = 4'(tag_idx);
      op_idx = n < 256 ? n % 4 : int'(draws[1] % 8);
      in_op = ops[op_idx];
      in_word = X == 64 && (op_idx == 0 || op_idx >= 4) && draws[2][0];
      in_a = X'({draws[3], draws[4]});
      in_b = X'({draws[5], draws[6]});
      case (n % 13)
        0: begin
          in_a = '0;
          in_b = '0;
        end
        1: begin
          in_a = '1;
          in_b = '1;
        end
        2: begin
          in_a = {1'b1, {(X-1){1'b0}}};
          in_b = '1;
        end
        3: in_b = 0;
        4: begin in_a = X'(64'h80000000); in_b = '1; end
        default: ;
      endcase
    end
    @(negedge clock);
    in_valid = 0;
    flush = 0;
    repeat (X + 10) @(negedge clock);
    assert (pending == 0 && completed + killed == accepted)
    else $fatal(1, "completion conservation failed");
    foreach (counts[i])
    assert (counts[i] > 10)
    else $fatal(1, "op coverage %0d", i);
    $display("PASS: muldiv FPGA XLEN=%0d accepted=%0d completed=%0d killed=%0d", X, accepted,
             completed, killed);
    $finish;
  end
endmodule
