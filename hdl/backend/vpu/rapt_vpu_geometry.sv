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
  int signed sew, lm, asize, dsize, ae, be, de;
  int unsigned ag, bg, dg;
  function automatic int unsigned groups(input int signed exponent);
    return exponent > 0 ? (1 << exponent) : 1;
  endfunction
  function automatic logic aligned(input logic [4:0] regno, input int unsigned count);
    return (int'(regno) & (count - 1)) == 0 && int'(regno) + count <= 32;
  endfunction
  function automatic logic overlap_ok(input logic [4:0] source, input int unsigned sg,
                                      input int signed ssize, exponent, dest_size);
    if (int'(vd) + dg <= int'(source) || int'(source) + sg <= int'(vd)) return 1;
    if (dest_size == ssize) return 1;
    if (dest_size < ssize) return vd == source;
    return exponent >= 0 && int'(vd) + dg == int'(source) + sg;
  endfunction
  always_comb begin
    sew = int'(vtype[5:3]);
    lm = int'($signed(vtype[2:0]));
    asize = sew + int'(wide_a || narrow) - (extend ? int'(extend_shift) : 0);
    dsize = sew + int'(widen);
    ae = lm+asize-sew;
    be = lm + (gather16 ? 1-sew : 0);
    de = lm+dsize-sew;
    ag = (mask_logic || mask_source) ? 1 : groups(ae);
    bg = mask_logic ? 1 : groups(be);
    dg = mask_result ? 1 : groups(de);
    a_size = 2'(asize);
    d_size = 2'(dsize);
    legal = lm >= -$clog2(ELEN/8) && lm <= 3 && (8 << sew) <= ELEN
        && (lm >= 0 || (8 << sew) <= (ELEN >> (-lm)))
        && asize >= 0 && dsize >= 0 && (8 << asize) <= ELEN && (8 << dsize) <= ELEN
        && ae >= -$clog2(ELEN/8) && ae <= 3 && de >= -$clog2(ELEN/8) && de <= 3
        && (!src_vector || (be >= -3 && be <= 3))
        && aligned(vd,dg) && (!uses_vs2 || aligned(vs2,ag)) && (!src_vector || aligned(vs1,bg))
        && (!masked || mask_result || vd != 0);
    if (gather)
      legal &= (int'(vd)+dg <= int'(vs2) || int'(vs2)+ag <= int'(vd))
        && (!src_vector || int'(vd)+dg <= int'(vs1) || int'(vs1)+bg <= int'(vd));
    if (slide_up) legal &= int'(vd) + dg <= int'(vs2) || int'(vs2) + ag <= int'(vd);
    if (compress)
      legal &= (int'(vd)+dg <= int'(vs2) || int'(vs2)+ag <= int'(vd))
        && (int'(vs1) < int'(vd) || int'(vs1) >= int'(vd)+dg);
    if (mask_source) legal &= int'(vs2) < int'(vd) || int'(vs2) >= int'(vd) + dg;
    else if (uses_vs2)
      legal &= overlap_ok(vs2, ag, mask_logic ? -3 : asize, ae, mask_result ? -3 : dsize);
    if (src_vector)
      legal &= overlap_ok(vs1, bg, mask_logic ? -3 : sew, be, mask_result ? -3 : dsize);
  end
endmodule
