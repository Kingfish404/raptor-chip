// Stateless FP transfer admission and element routing. FLEN is 64, independent
// of XLEN. Caller owns register geometry/overlap, VRF transactions, completion,
// VS/FS dirty updates and clearing vstart after successful execution.
// vector_element is the raw value fetched at source_index when read_source is
// asserted. Scalar moves use one evaluation per instruction, not a VL loop.
module rapt_vpu_fp_transfer #(
    parameter int ELEN = 64,
    parameter int VLEN = 128,
    parameter int IndexBits = $clog2(VLEN)+1
) (
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [31:0] insn,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [2:0] sew,
    frm,
    input logic enabled,
    vill,
    mask_bit,
    input logic [63:0] scalar,
    vector_element,
    input logic [IndexBits-1:0] index,
    vl,
    vlmax,
    vstart,
    output logic recognized,
    legal,
    // 0 merge, 1 broadcast, 2 extract, 3 insert, 4 slide1up, 5 slide1down.
    output logic [2:0] operation,
    output logic write_vector,
    write_scalar,
    read_source,
    output logic [IndexBits-1:0] source_index,
    destination_index,
    output logic [63:0] result
);
  logic [2:0] selected;
  logic [63:0] scalar_value, vector_value;
  logic slide_write, slide_read, slide_scalar;
  logic [IndexBits-1:0] slide_index;
  rapt_vpu_slide #(
      .VLEN(VLEN),
      .XLEN(64),
      .IndexBits(IndexBits)
  ) u_slide (
      .up(selected == 4),
      .single(1'b1),
      .mask_active(insn[25] || mask_bit),
      .index(index),
      .vl(vl),
      .vlmax(vlmax),
      .vstart(vstart),
      .offset(64'd1),
      .write_element(slide_write),
      .read_source(slide_read),
      .scalar_select(slide_scalar),
      .source_index(slide_index)
  );
  always_comb begin
    recognized = 0;
    selected = 0;
    if (insn[6:0] == 7'h57) begin
      case (insn[31:26])
        6'h17:
        if (insn[14:12] == 5) begin
          recognized = !insn[25] || insn[24:20] == 0;
          selected = insn[25] ? 3'd1 : 3'd0;
        end
        6'h10:
        if (insn[25]) begin
          if (insn[14:12] == 1 && insn[19:15] == 0) begin
            recognized = 1;
            selected = 2;
          end
          if (insn[14:12] == 5 && insn[24:20] == 0) begin
            recognized = 1;
            selected = 3;
          end
        end
        6'h0e, 6'h0f:
        if (insn[14:12] == 5) begin
          recognized = 1;
          selected = insn[26] ? 3'd5 : 3'd4;
        end
        default: ;
      endcase
    end
  end
  always_comb begin
    legal = recognized && enabled && !vill && frm <= 4
        && (sew == 2 || (sew == 3 && ELEN >= 64)) && ELEN >= 32;
    operation = legal ? selected : 3'd0;
    scalar_value = sew == 2 ? (scalar[63:32] == 32'hffffffff
        ? {32'b0,scalar[31:0]} : 64'h7fc00000) : scalar;
    vector_value = sew == 2 ? {32'b0,vector_element[31:0]} : vector_element;
    write_vector = 0;
    write_scalar = 0;
    read_source = 0;
    source_index = 0;
    destination_index = 0;
    result = 0;
    if (legal) begin
      case (selected)
        2: begin
          // Extraction executes even at VL=0 or vstart>=VL, and ignores LMUL.
          write_scalar = 1;
          read_source = 1;
          result = sew == 2 ? {32'hffffffff,vector_element[31:0]} : vector_element;
        end
        3:
        if (vstart < vl) begin
          write_vector = 1;
          result = scalar_value;
        end
        4, 5:
        if (slide_write) begin
          write_vector = 1;
          read_source = slide_read;
          source_index = slide_index;
          destination_index = index;
          result = slide_scalar ? scalar_value : slide_read ? vector_value : 64'd0;
        end
        default:
        if (index >= vstart && index < vl) begin
          write_vector = 1;
          destination_index = index;
          read_source = selected == 0 && !mask_bit;
          source_index = read_source ? index : IndexBits'(0);
          result = read_source ? vector_value : scalar_value;
        end
      endcase
    end
  end
endmodule
