// Combinational raw FP element operations. No scalar NaN-box checking here:
// the vector decoder owns scalar boxing, mask/FRM legality and authorization.
// operation: 0=min, 1=max, 2=sgnj, 3=sgnjn, 4=sgnjx, 5=class,
//            6=eq, 7=ne, 8=lt, 9=le, 10=gt, 11=ge.
// Comparisons return a single predicate in result[0]; caller packs mask bits.
module rapt_vpu_fp_misc #(
    parameter bit Double = 1
) (
    // FP32 elements deliberately ignore the upper half of the common interface.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [63:0] a,
    b,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [3:0] operation,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  localparam int Width = Double ? 64 : 32;
  localparam int Fraction = Double ? 52 : 23;
  localparam logic [Width-1:0] CanonicalNaN = Width'(Double ? 64'h7ff8000000000000 : 64'h000000007fc00000);
  logic [Width-1:0] x, y, value;
  logic sx, sy, nan_x, nan_y, snan_x, snan_y, zero_x, zero_y;
  logic exp_zero_x, exp_ones_x, fraction_zero_x, equal_value, less_value;
  logic [9:0] classification;
  assign x = a[Width-1:0];
  assign y = b[Width-1:0];
  assign sx = x[Width-1];
  assign sy = y[Width-1];
  assign exp_zero_x = x[Width-2:Fraction] == 0;
  assign exp_ones_x = &x[Width-2:Fraction];
  assign fraction_zero_x = x[Fraction-1:0] == 0;
  assign nan_x = exp_ones_x && !fraction_zero_x;
  assign nan_y = (&y[Width-2:Fraction]) && (y[Fraction-1:0] != 0);
  assign snan_x = nan_x && !x[Fraction-1];
  assign snan_y = nan_y && !y[Fraction-1];
  assign zero_x = x[Width-2:0] == 0;
  assign zero_y = y[Width-2:0] == 0;
  assign equal_value = x == y || (zero_x && zero_y);
  assign less_value = !(zero_x && zero_y) && ((sx != sy) ? sx : (sx ? x > y : x < y));
  always_comb begin
    classification = 0;
    if (nan_x) classification[x[Fraction-1]?9 : 8] = 1;
    else if (exp_ones_x) classification[sx?0 : 7] = 1;
    else if (exp_zero_x) begin
      if (fraction_zero_x) classification[sx?3 : 4] = 1;
      else classification[sx?2 : 5] = 1;
    end else classification[sx?1 : 6] = 1;
    value = 0;
    flags = 0;
    illegal = 0;
    case (operation)
      0, 1: begin
        flags[4] = snan_x || snan_y;
        if (nan_x && nan_y) value = CanonicalNaN;
        else if (nan_x) value = y;
        else if (nan_y) value = x;
        else if (zero_x && zero_y)
          value = {operation[0] ? (sx && sy) : (sx || sy), {(Width - 1) {1'b0}}};
        else value = (less_value ^ operation[0]) ? x : y;
      end
      2: value = {sy,x[Width-2:0]};
      3: value = {!sy,x[Width-2:0]};
      4: value = {sx ^ sy,x[Width-2:0]};
      5: value = Width'(classification);
      6, 7: begin
        flags[4] = snan_x || snan_y;
        value[0] = ((nan_x || nan_y) ? 1'b0 : equal_value) ^ operation[0];
      end
      8, 9, 10, 11: begin
        flags[4] = nan_x || nan_y;
        if (!nan_x && !nan_y) begin
          case (operation)
            8: value[0] = less_value;
            9: value[0] = less_value || equal_value;
            10: value[0] = !less_value && !equal_value;
            default: value[0] = !less_value;
          endcase
        end
      end
      default: illegal = 1;
    endcase
    result = 64'(value);
  end
endmodule
