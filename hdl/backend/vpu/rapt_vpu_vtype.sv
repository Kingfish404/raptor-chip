// Stateless RVV configuration calculation. The owning controller commits the
// outputs only for an accepted, authorized vset instruction. No core package,
// preset, ROB width, or physical execution-port identity is captured here.
module rapt_vpu_vtype #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64
) (
    input  logic [XLEN-1:0] requested_vtype,
    input  logic [XLEN-1:0] avl,
    input  logic           avl_max,
    input  logic           keep_vl,
    // Previous tail/mask policy does not affect keep-VL legality.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [XLEN-1:0] current_vtype,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [XLEN-1:0] current_vl,
    output logic [XLEN-1:0] next_vtype,
    output logic [XLEN-1:0] next_vl,
    output logic [XLEN-1:0] vlmax,
    output logic           vill
);
  if ((XLEN != 32 && XLEN != 64) || (ELEN != 32 && ELEN != 64)
      || VLEN < ELEN || VLEN > 65536 || (VLEN & (VLEN-1)) != 0) begin : g_bad_config
    initial $fatal(1, "Unsupported VPU XLEN/VLEN/ELEN");
  end

  // Constant geometry table rather than a runtime multiplier/divider. Entries
  // with SEW > LMUL*ELEN, reserved LMUL=100, or unsupported SEW are absent.
  function automatic int unsigned max_elements(input logic [5:0] geometry);
    int unsigned n;
    n = 0;
    for (int sew = 0; sew <= $clog2(ELEN / 8); sew++) begin
      for (int lm = -$clog2(ELEN / 8); lm <= 3; lm++) begin
        if (lm >= 0 || (8 << sew) <= (ELEN >> (-lm))) begin
          if (geometry == {3'(sew), 3'(lm)}) begin
            if (lm >= 0) n = (VLEN / (8 << sew)) << lm;
            else n = (VLEN / (8 << sew)) >> (-lm);
          end
        end
      end
    end
    return n;
  endfunction

  logic [XLEN-1:0] old_max;
  always_comb begin
    vlmax = XLEN'(max_elements(requested_vtype[5:0]));
    old_max = XLEN'(max_elements(current_vtype[5:0]));
    if (|requested_vtype[XLEN-1:8]) vlmax = 0;
    if (|current_vtype[XLEN-1:8]) old_max = 0;
    vill = vlmax == 0;
    // Reserved keep-VL cases deterministically set vill. In particular, a
    // keep operation cannot recover from the reset/unsupported vill state.
    if (keep_vl && (old_max != vlmax || old_max == 0 || current_vl > vlmax)) vill = 1'b1;
    next_vtype = requested_vtype;
    next_vl = avl < vlmax ? avl : vlmax;
    if (avl_max) next_vl = vlmax;
    if (keep_vl) next_vl = current_vl;
    if (vill) begin
      next_vtype = {1'b1, {(XLEN-1){1'b0}}};
      next_vl = '0;
      vlmax = '0;
    end
  end
endmodule
