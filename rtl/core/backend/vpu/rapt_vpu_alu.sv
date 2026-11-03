// One integer element. funct6 is the RVV OPIV encoding; decode/legality is
// separate. Truncation and signed comparisons use SEW, never scalar XLEN.
module rapt_vpu_alu (
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
    // SEW has only four encodings. Explicit wiring avoids constructing
    // variable left/right shifters merely to sign-extend an operand.
    case (sew)
      0: begin
        mask = 64'hff;
        sa = {{56{a[7]}},a[7:0]};
        sb = {{56{b[7]}},b[7:0]};
        shift = {3'b0,b[2:0]};
      end
      1: begin
        mask = 64'hffff;
        sa = {{48{a[15]}},a[15:0]};
        sb = {{48{b[15]}},b[15:0]};
        shift = {2'b0,b[3:0]};
      end
      2: begin
        mask = 64'hffffffff;
        sa = {{32{a[31]}},a[31:0]};
        sb = {{32{b[31]}},b[31:0]};
        shift = {1'b0,b[4:0]};
      end
      default: begin
        mask = '1;
        sa = $signed(a);
        sb = $signed(b);
        shift = b[5:0];
      end
    endcase
    au = a & mask;
    bu = b & mask;
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
