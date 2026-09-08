// Frozen pre-optimization implementation for equivalence and mapping.
// One integer element. funct6 is the RVV OPIV encoding; decode/legality is
// separate. Truncation and signed comparisons use SEW, never scalar XLEN.
module rapt_vpu_alu_baseline (
    input logic [5:0] funct6,
    input logic [1:0] sew,
    input logic [63:0] a,
    b,
    input logic mask_bit,
    mask_logic,
    output logic [63:0] result
);
  logic [63:0] mask, au, bu;
  logic signed [63:0] sa, sb;
  logic [5:0] shift;
  logic [64:0] carry_sum, borrow_difference;
  always_comb begin
    mask = 64'hffffffffffffffff >> (64 - (8 << sew));
    au = a & mask;
    bu = b & mask;
    sa = $signed(au << (64 - (8 << sew))) >>> (64 - (8 << sew));
    sb = $signed(bu << (64 - (8 << sew))) >>> (64 - (8 << sew));
    shift = b[5:0] & (6'((8 << sew)-1));
    carry_sum = {1'b0,au} + {1'b0,bu} + 65'(mask_bit);
    borrow_difference = {1'b0,au} - {1'b0,bu} - 65'(mask_bit);
    result = '0;
    case (funct6)
      6'h00: result = au + bu;
      6'h02: result = au - bu;
      6'h03: result = bu - au;
      6'h04: result = au < bu ? au : bu;
      6'h05: result = sa < sb ? au : bu;
      6'h06: result = au > bu ? au : bu;
      6'h07: result = sa > sb ? au : bu;
      6'h09: result = au & bu;
      6'h0a: result = au | bu;
      6'h0b: result = au ^ bu;
      6'h10: result = carry_sum[63:0];
      6'h11: result = 64'(carry_sum[8 << sew]);
      6'h12: result = borrow_difference[63:0];
      6'h13: result = 64'(borrow_difference[8 << sew]);
      6'h17: result = mask_bit ? bu : au;
      6'h18: result = 64'(au == bu);
      6'h19: result = 64'(au != bu);
      6'h1a: result = 64'(au < bu);
      6'h1b: result = 64'(sa < sb);
      6'h1c: result = 64'(au <= bu);
      6'h1d: result = 64'(sa <= sb);
      6'h1e: result = 64'(au > bu);
      6'h1f: result = 64'(sa > sb);
      6'h25: result = au << shift;
      6'h28: result = au >> shift;
      6'h29: result = 64'(sa >>> shift);
      default: result = '0;
    endcase
    if (mask_logic) begin
      case (funct6[2:0])
        0: result = 64'(au[0] && !bu[0]);
        1: result = 64'(au[0] && bu[0]);
        2: result = 64'(au[0] || bu[0]);
        3: result = 64'(au[0] != bu[0]);
        4: result = 64'(au[0] || !bu[0]);
        5: result = 64'(!(au[0] && bu[0]));
        6: result = 64'(!(au[0] || bu[0]));
        7: result = 64'(!(au[0] != bu[0]));
        default: ;
      endcase
    end
    result &= mask;
  end
endmodule
