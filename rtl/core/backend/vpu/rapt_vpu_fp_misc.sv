// Combinational raw FP element operations. No scalar NaN-box checking here:
// the vector decoder owns scalar boxing, mask/FRM legality and authorization.
// operation: 0=min, 1=max, 2=sgnj, 3=sgnjn, 4=sgnjx, 5=class,
//            6=eq, 7=ne, 8=lt, 9=le, 10=gt, 11=ge.
// Comparisons return a single predicate in result[0]; caller packs mask bits.
/* verilator lint_off DECLFILENAME */
module rapt_vpu_fp_misc_multi (
    input logic double_precision,
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [3:0] operation,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  logic sx, sy, nan_x, nan_y, snan_x, snan_y, zero_x, zero_y;
  logic exp_zero_x, exp_ones_x, fraction_zero_x, equal_value, less_value;
  logic [10:0] exp_x, exp_y, max_exp;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [51:0] frac_x, frac_y;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [62:0] mag_x, mag_y;
  logic [63:0] x_packed, y_packed, canonical_nan;
  logic [9:0] classification;
  logic zero_sign;

  assign sx = double_precision ? a[63] : a[31];
  assign sy = double_precision ? b[63] : b[31];
  assign exp_x = double_precision ? a[62:52] : {3'b0, a[30:23]};
  assign exp_y = double_precision ? b[62:52] : {3'b0, b[30:23]};
  assign max_exp = double_precision ? 11'h7ff : 11'h0ff;
  assign frac_x = double_precision ? a[51:0] : {a[22:0], 29'b0};
  assign frac_y = double_precision ? b[51:0] : {b[22:0], 29'b0};
  assign mag_x = double_precision ? a[62:0] : {32'b0, a[30:0]};
  assign mag_y = double_precision ? b[62:0] : {32'b0, b[30:0]};
  assign x_packed = double_precision ? a : {32'b0, a[31:0]};
  assign y_packed = double_precision ? b : {32'b0, b[31:0]};
  assign canonical_nan = double_precision ? 64'h7ff8_0000_0000_0000 : 64'h0000_0000_7fc0_0000;

  assign exp_zero_x = exp_x == 11'd0;
  assign exp_ones_x = exp_x == max_exp;
  assign fraction_zero_x = frac_x == 52'd0;
  assign nan_x = exp_ones_x && !fraction_zero_x;
  assign nan_y = (exp_y == max_exp) && (frac_y != 52'd0);
  assign snan_x = nan_x && !frac_x[51];
  assign snan_y = nan_y && !frac_y[51];
  assign zero_x = mag_x == 63'd0;
  assign zero_y = mag_y == 63'd0;
  assign equal_value = ((sx == sy) && (mag_x == mag_y)) || (zero_x && zero_y);
  assign less_value = !(zero_x && zero_y)
      && ((sx != sy) ? sx : (sx ? (mag_x > mag_y) : (mag_x < mag_y)));
  assign zero_sign = operation[0] ? (sx && sy) : (sx || sy);

  always_comb begin
    classification = 10'd0;
    if (nan_x) classification[frac_x[51]?9 : 8] = 1'b1;
    else if (exp_ones_x) classification[sx?0 : 7] = 1'b1;
    else if (exp_zero_x) begin
      if (fraction_zero_x) classification[sx?3 : 4] = 1'b1;
      else classification[sx?2 : 5] = 1'b1;
    end else classification[sx?1 : 6] = 1'b1;

    result = 64'd0;
    flags = 5'd0;
    illegal = 1'b0;
    case (operation)
      4'd0, 4'd1: begin
        flags[4] = snan_x || snan_y;
        if (nan_x && nan_y) result = canonical_nan;
        else if (nan_x) result = y_packed;
        else if (nan_y) result = x_packed;
        else if (zero_x && zero_y)
          result = double_precision ? {zero_sign, 63'b0} : {32'b0, zero_sign, 31'b0};
        else result = (less_value ^ operation[0]) ? x_packed : y_packed;
      end
      4'd2: result = double_precision ? {sy, a[62:0]} : {32'b0, sy, a[30:0]};
      4'd3: result = double_precision ? {!sy, a[62:0]} : {32'b0, !sy, a[30:0]};
      4'd4: result = double_precision ? {sx ^ sy, a[62:0]} : {32'b0, sx ^ sy, a[30:0]};
      4'd5: result = {54'b0, classification};
      4'd6, 4'd7: begin
        flags[4] = snan_x || snan_y;
        result[0] = ((nan_x || nan_y) ? 1'b0 : equal_value) ^ operation[0];
      end
      4'd8, 4'd9, 4'd10, 4'd11: begin
        flags[4] = nan_x || nan_y;
        if (!nan_x && !nan_y) begin
          case (operation)
            4'd8: result[0] = less_value;
            4'd9: result[0] = less_value || equal_value;
            4'd10: result[0] = !less_value && !equal_value;
            default: result[0] = !less_value;
          endcase
        end
      end
      default: illegal = 1'b1;
    endcase
  end
endmodule
/* verilator lint_on DECLFILENAME */

module rapt_vpu_fp_misc #(
    parameter bit Double = 1
) (
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [3:0] operation,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  rapt_vpu_fp_misc_multi u_misc (
      .double_precision(Double),
      .a(a),
      .b(b),
      .operation(operation),
      .result(result),
      .flags(flags),
      .illegal(illegal)
  );
endmodule
