`include "rapt_sva.svh"

// Independent, single-element RVV integer multiply/divide engine. op is the
// low three funct6 bits for OPMVV/OPMVX 100xxx. Radix-2 shift/add and restoring
// division avoid technology-dependent combinational multipliers/dividers.
// Requests are already authorized; reset is not an architectural cancellation.
module rapt_vpu_muldiv #(
    parameter bit EarlyOut = 1
) (
    input logic clock,
    reset,
    input logic req_valid,
    output logic req_ready,
    input logic [2:0] op,
    input logic [1:0] sew,
    input logic [63:0] a,
    b,
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
  logic [6:0] count_q, bits_q, bits;
  logic [63:0] mask, mask_q, au, bu, amag, bmag;
  logic aneg, bneg, negative_q, remainder_negative_q;
  logic [127:0] multiplicand_q, product_q, product_next, product_signed;
  logic [63:0] multiplier_q, divisor_q, dividend_q, quotient_next;
  logic [62:0] quotient_q;
  logic [63:0] remainder_q;
  logic [63:0] remainder_next;
  logic [64:0] trial;
  logic [63:0] quotient_signed, remainder_signed;

  assign full_product = negative_q ? -product_q : product_q;
  assign req_ready = !reset && state == IDLE;
  assign rsp_valid = !reset && state == DONE;
  always_comb begin
    bits = 7'(8 << sew);
    mask = 64'hffffffffffffffff >> (64-bits);
    au = a & mask;
    bu = b & mask;
    aneg = a[bits-1] && (op == 6 || op == 7 || (!op[2] && op[0]));
    bneg = b[bits-1] && (op == 7 || (!op[2] && op[0]));
    amag = (aneg ? -au : au) & mask;
    bmag = (bneg ? -bu : bu) & mask;
    product_next = product_q + (multiplier_q[0] ? multiplicand_q : 128'b0);
    product_signed = negative_q ? -product_next : product_next;
    trial = {remainder_q[63:0], dividend_q[63]};
    remainder_next = 64'(trial >= {1'b0,divisor_q} ? trial - {1'b0,divisor_q} : trial);
    quotient_next = {quotient_q[62:0], trial >= {1'b0,divisor_q}};
    quotient_signed = negative_q ? -quotient_next : quotient_next;
    remainder_signed = remainder_negative_q ? -remainder_next[63:0] : remainder_next[63:0];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      op_q <= 0;
      count_q <= 0;
      bits_q <= 0;
      mask_q <= 0;
      negative_q <= 0;
      remainder_negative_q <= 0;
      multiplicand_q <= 0;
      product_q <= 0;
      multiplier_q <= 0;
      divisor_q <= 0;
      dividend_q <= 0;
      quotient_q <= 0;
      remainder_q <= 0;
      result <= 0;
    end else
      case (state)
        IDLE:
        if (req_valid && req_ready) begin
          op_q <= op;
          count_q <= bits;
          bits_q <= bits;
          mask_q <= mask;
          product_q <= 0;
          negative_q <= aneg ^ bneg;
          remainder_negative_q <= aneg;
          if (EarlyOut && op[2] && (amag == 0 || bmag == 0)) begin
            result <= 0;
            state <= DONE;
          end else if (op[2]) begin
            multiplicand_q <= {64'b0,amag};
            multiplier_q <= bmag;
            product_q <= 0;
            state <= MULTIPLY;
          end else if (bu == 0) begin
            result <= op[1] ? au : mask;
            state <= DONE;
          end else if (EarlyOut && amag < bmag) begin
            result <= op[1] ? au : 64'b0;
            state <= DONE;
          end else if (EarlyOut && bmag == 1) begin
            result <= op[1] ? 64'b0 : ((aneg ^ bneg ? -amag : amag) & mask);
            state <= DONE;
          end else begin
            divisor_q <= bmag;
            dividend_q <= amag << (64-bits);
            quotient_q <= 0;
            remainder_q <= 0;
            state <= DIVIDE;
          end
        end
        MULTIPLY: begin
          product_q <= product_next;
          multiplicand_q <= multiplicand_q << 1;
          multiplier_q <= multiplier_q >> 1;
          count_q <= count_q-1'b1;
          if (count_q == 1 || (EarlyOut && multiplier_q[63:1] == 0)) begin
            result <= (op_q == 5 ? product_signed[63:0] : 64'(product_signed >> bits_q)) & mask_q;
            state <= DONE;
          end
        end
        DIVIDE: begin
          remainder_q <= remainder_next[63:0];
          quotient_q <= quotient_next[62:0];
          dividend_q <= dividend_q << 1;
          count_q <= count_q-1'b1;
          if (count_q == 1) begin
            result <= (op_q[1] ? remainder_signed : quotient_signed) & mask_q;
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
                  count_q >= 1 && count_q <= 64)
endmodule
