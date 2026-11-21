`include "rapt_sva.svh"

// Independent, single-element RVV integer multiply/divide engine. op is the
// low three funct6 bits for OPMVV/OPMVX 100xxx. Radix-2 shift/add and restoring
// division avoid technology-dependent combinational multipliers/dividers.
// Requests are already authorized; reset is not an architectural cancellation.
module rapt_vpu_muldiv #(
    parameter bit EarlyOut = 1,
    parameter bit MultiplyEarlyOut = EarlyOut
) (
    input logic clock,
    input logic reset,
    input logic req_valid,
    output logic req_ready,
    input logic [2:0] op,
    input logic [1:0] sew,
    input logic [63:0] a,
    input logic [63:0] b,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] result,
    output logic [127:0] full_product
);
  typedef enum logic [1:0] {
    IDLE,
    MULTIPLY,
    DIVIDE,
    DONE
  } state_t;
  state_t state;
  logic [2:0] op_q;
  logic [1:0] sew_q;
  logic [6:0] count_q, bits;
  logic [63:0] mask, mask_q_val, au, bu, amag, bmag, amag_aligned, mul_high;
  logic sign_a, sign_b, aneg, bneg, negative_q, remainder_negative_q;
  logic [127:0] shift_reg_q, product_q, product_next, product_signed;
  logic [63:0] op_b_q, quotient_next, remainder_next;
  logic [62:0] quotient_q;
  logic [64:0] trial;
  logic trial_ge, mul_done;
  logic [63:0] quotient_signed, remainder_signed;

  function automatic logic [63:0] sew_mask(input logic [1:0] s);
    case (s)
      2'd0: sew_mask = 64'h0000_0000_0000_00ff;
      2'd1: sew_mask = 64'h0000_0000_0000_ffff;
      2'd2: sew_mask = 64'h0000_0000_ffff_ffff;
      default: sew_mask = 64'hffff_ffff_ffff_ffff;
    endcase
  endfunction

  assign full_product = product_q;
  assign req_ready = !reset && state == IDLE;
  assign rsp_valid = !reset && state == DONE;

  always_comb begin
    case (sew)
      2'd0: begin
        bits = 7'd8;
        sign_a = a[7];
        sign_b = b[7];
      end
      2'd1: begin
        bits = 7'd16;
        sign_a = a[15];
        sign_b = b[15];
      end
      2'd2: begin
        bits = 7'd32;
        sign_a = a[31];
        sign_b = b[31];
      end
      default: begin
        bits = 7'd64;
        sign_a = a[63];
        sign_b = b[63];
      end
    endcase
    mask = sew_mask(sew);
    mask_q_val = sew_mask(sew_q);
    au = a & mask;
    bu = b & mask;
    aneg = sign_a && (op == 3'd6 || op == 3'd7 || (!op[2] && op[0]));
    bneg = sign_b && (op == 3'd7 || (!op[2] && op[0]));
    amag = (aneg ? -au : au) & mask;
    bmag = (bneg ? -bu : bu) & mask;
    case (sew)
      2'd0: amag_aligned = {amag[7:0], 56'b0};
      2'd1: amag_aligned = {amag[15:0], 48'b0};
      2'd2: amag_aligned = {amag[31:0], 32'b0};
      default: amag_aligned = amag;
    endcase

    product_next = product_q + (op_b_q[0] ? shift_reg_q : 128'd0);
    product_signed = negative_q ? -product_next : product_next;
    case (sew_q)
      2'd0: mul_high = {56'b0, product_signed[15:8]};
      2'd1: mul_high = {48'b0, product_signed[31:16]};
      2'd2: mul_high = {32'b0, product_signed[63:32]};
      default: mul_high = product_signed[127:64];
    endcase
    mul_done = (count_q == 7'd1) || (MultiplyEarlyOut && op_b_q[63:1] == 63'd0);

    trial = {shift_reg_q[127:64], shift_reg_q[63]};
    trial_ge = trial >= {1'b0, op_b_q};
    remainder_next = trial_ge ? 64'(trial - {1'b0, op_b_q}) : 64'(trial);
    quotient_next = {quotient_q[62:0], trial_ge};
    quotient_signed = negative_q ? -quotient_next : quotient_next;
    remainder_signed = remainder_negative_q ? -remainder_next : remainder_next;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      op_q <= 3'd0;
      sew_q <= 2'd0;
      count_q <= 7'd0;
      negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      shift_reg_q <= 128'd0;
      product_q <= 128'd0;
      op_b_q <= 64'd0;
      quotient_q <= 63'd0;
      result <= 64'd0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          op_q <= op;
          sew_q <= sew;
          count_q <= bits;
          product_q <= 128'd0;
          negative_q <= aneg ^ bneg;
          remainder_negative_q <= aneg;
          if (MultiplyEarlyOut && op[2] && (amag == 64'd0 || bmag == 64'd0)) begin
            result <= 64'd0;
            state <= DONE;
          end else if (op[2]) begin
            shift_reg_q <= {64'b0, amag};
            op_b_q <= bmag;
            state <= MULTIPLY;
          end else if (bu == 64'd0) begin
            result <= op[1] ? au : mask;
            state <= DONE;
          end else if (EarlyOut && amag < bmag) begin
            result <= op[1] ? au : 64'd0;
            state <= DONE;
          end else if (EarlyOut && bmag == 64'd1) begin
            result <= op[1] ? 64'd0 : ((aneg ^ bneg ? -amag : amag) & mask);
            state <= DONE;
          end else begin
            op_b_q <= bmag;
            shift_reg_q <= {64'd0, amag_aligned};
            quotient_q <= 63'd0;
            state <= DIVIDE;
          end
        end
        MULTIPLY: begin
          shift_reg_q <= shift_reg_q << 1;
          op_b_q <= op_b_q >> 1;
          count_q <= count_q - 7'd1;
          if (mul_done) begin
            product_q <= product_signed;
            result <= (op_q == 3'd5) ? (product_signed[63:0] & mask_q_val) : mul_high;
            state <= DONE;
          end else begin
            product_q <= product_next;
          end
        end
        DIVIDE: begin
          shift_reg_q <= {remainder_next, shift_reg_q[62:0], 1'b0};
          quotient_q <= quotient_next[62:0];
          count_q <= count_q - 7'd1;
          if (count_q == 7'd1) begin
            result <= (op_q[1] ? remainder_signed : quotient_signed) & mask_q_val;
            state <= DONE;
          end
        end
        DONE: if (rsp_valid && rsp_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
  end
  `RAPT_SVA_NEXT(clock, reset, VPU_MULDIV_RESULT_HOLD, rsp_valid && !rsp_ready,
                 rsp_valid && $stable({result, full_product}))
  `RAPT_SVA_IMPLY(clock, reset, VPU_MULDIV_COUNT, state == MULTIPLY || state == DIVIDE,
                  count_q >= 7'd1 && count_q <= 7'd64)
endmodule
