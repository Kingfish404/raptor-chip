// Arithmetic register geometry, independent of the core and execution engine.
// Size codes are log2(bytes). EMUL exponents are signed log2(register groups).
module rapt_vpu_geometry #(
    parameter int ELEN = 64
) (
    // Agnostic policy bits do not affect operand geometry.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [7:0] vtype,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [4:0] vd,
    vs2,
    vs1,
    input logic uses_vs2,
    src_vector,
    masked,
    mask_result,
    mask_logic,
    mask_source,
    compress,
    slide_up,
    gather,
    gather16,
    input logic widen,
    wide_a,
    narrow,
    extend,
    input logic [1:0] extend_shift,
    output logic [1:0] a_size,
    d_size,
    output logic legal
);
  localparam logic signed [4:0] MaxSize = 5'($clog2(ELEN / 8));
  logic signed [4:0] sew, lm, asize, dsize, ae, be, de;
  logic [3:0] ag, bg, dg;
  logic [5:0] vd_end, vs2_end, vs1_end;
  logic disjoint_vs2, disjoint_vs1;

  function automatic logic [3:0] groups(input logic signed [4:0] exponent);
    case (exponent)
      5'sd1: return 4'd2;
      5'sd2: return 4'd4;
      5'sd3: return 4'd8;
      default: return 4'd1;
    endcase
  endfunction

  function automatic logic aligned(input logic [4:0] regno, input logic [3:0] count);
    return (regno & (5'(count) - 5'd1)) == 5'd0;
  endfunction

  function automatic logic overlap_ok(input logic [4:0] source, input logic [5:0] source_end,
                                      input logic disjoint, input logic signed [4:0] ssize,
                                      input logic signed [4:0] exponent,
                                      input logic signed [4:0] dest_size);
    if (disjoint) return 1'b1;
    if (dest_size == ssize) return 1'b1;
    if (dest_size < ssize) return vd == source;
    return exponent >= 5'sd0 && vd_end == source_end;
  endfunction

  always_comb begin
    sew = $signed({2'b00, vtype[5:3]});
    lm = $signed({{2{vtype[2]}}, vtype[2:0]});
    asize = sew + $signed({4'b0, wide_a || narrow})
        - (extend ? $signed({3'b0, extend_shift}) : 5'sd0);
    dsize = sew + $signed({4'b0, widen});
    ae = lm + asize - sew;
    be = lm + (gather16 ? (5'sd1 - sew) : 5'sd0);
    de = lm + dsize - sew;
    ag = (mask_logic || mask_source) ? 4'd1 : groups(ae);
    bg = mask_logic ? 4'd1 : groups(be);
    dg = mask_result ? 4'd1 : groups(de);
    vd_end = {1'b0, vd} + {2'b00, dg};
    vs2_end = {1'b0, vs2} + {2'b00, ag};
    vs1_end = {1'b0, vs1} + {2'b00, bg};
    disjoint_vs2 = vd_end <= {1'b0, vs2} || vs2_end <= {1'b0, vd};
    disjoint_vs1 = vd_end <= {1'b0, vs1} || vs1_end <= {1'b0, vd};
    a_size = asize[1:0];
    d_size = dsize[1:0];
    legal = lm >= -MaxSize && lm <= 5'sd3 && sew <= MaxSize && sew <= (MaxSize + lm)
        && asize >= 5'sd0 && dsize >= 5'sd0 && asize <= MaxSize && dsize <= MaxSize
        && ae >= -MaxSize && ae <= 5'sd3 && de >= -MaxSize && de <= 5'sd3
        && (!src_vector || (be >= -5'sd3 && be <= 5'sd3))
        && aligned(vd, dg) && (!uses_vs2 || aligned(vs2, ag)) && (!src_vector || aligned(vs1, bg))
        && (!masked || mask_result || vd != 5'd0);
    if (gather) legal &= disjoint_vs2 && (!src_vector || disjoint_vs1);
    if (slide_up) legal &= disjoint_vs2;
    if (compress) legal &= disjoint_vs2 && (vs1 < vd || {1'b0, vs1} >= vd_end);
    if (mask_source) legal &= vs2 < vd || {1'b0, vs2} >= vd_end;
    else if (uses_vs2)
      legal &= overlap_ok(
          vs2, vs2_end, disjoint_vs2, mask_logic ? -5'sd3 : asize, ae, mask_result ? -5'sd3 : dsize
      );
    if (src_vector)
      legal &= overlap_ok(
          vs1, vs1_end, disjoint_vs1, mask_logic ? -5'sd3 : sew, be, mask_result ? -5'sd3 : dsize
      );
  end
endmodule
