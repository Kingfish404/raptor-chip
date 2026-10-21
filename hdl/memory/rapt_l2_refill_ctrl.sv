// Blocking refill admission and outer read phases. Valid/ready controls the
// phase; the data ports own the returned line and its merge writes.
module rapt_l2_refill_ctrl #(
    parameter int XLEN = 64,
    parameter int LINE_LEN = 3,
    parameter int LINE_SIZE = 8,
    parameter int LINE_BITS = XLEN * LINE_SIZE
) (
    input  logic clock,
    input  logic reset,
    input  logic valid_i,
    input  logic start_ar_i,
    output logic ready_o,
    output logic [1:0] phase_o,
    input  logic invalidate_ready_i,
    input  logic ar_done_i,
    input  logic complete_valid_i,
    input  logic [LINE_BITS-1:0] complete_line_i,
    input  logic merge_valid_i,
    input  logic [LINE_LEN-1:0] merge_word_i,
    input  logic [XLEN-1:0] merge_old_i,
    input  logic [XLEN-1:0] merge_data_i,
    input  logic [XLEN/8-1:0] merge_mask_i,
    input  logic beat_valid_i,
    input  logic beat_streamed_i,
    input  logic [LINE_LEN-1:0] beat_word_i,
    input  logic [XLEN-1:0] beat_data_i,
    input  logic beat_store_i,
    input  logic [LINE_LEN-1:0] wanted_word_i,
    input  logic [XLEN-1:0] store_data_i,
    input  logic [XLEN/8-1:0] store_mask_i,
    output logic [XLEN-1:0] line_o[LINE_SIZE],
    input  logic count_clear_i,
    input  logic count_inc_i,
    output logic [LINE_LEN-1:0] count_o,
    input  logic response_clear_i,
    input  logic response_load_i,
    input  logic [1:0] response_data_i,
    output logic [1:0] response_o,
    input  logic up_done_clear_i,
    input  logic up_done_set_i,
    output logic up_done_o
);
  localparam logic [1:0] INVALIDATE = 2'd0, AR = 2'd1, R = 2'd2;

  logic started_q;
  logic [1:0] phase_q;

  assign ready_o = !valid_i;
  assign phase_o = started_q ? phase_q : (start_ar_i ? AR : INVALIDATE);

  function automatic logic [XLEN-1:0] merge_word(input logic [XLEN-1:0] old_data,
                                                 input logic [XLEN-1:0] new_data,
                                                 input logic [XLEN/8-1:0] mask);
    logic [XLEN-1:0] result;
    result = old_data;
    for (int byte_idx = 0; byte_idx < XLEN / 8; byte_idx++)
    if (mask[byte_idx]) result[byte_idx*8+:8] = new_data[byte_idx*8+:8];
    return result;
  endfunction

  always_ff @(posedge clock) begin
    if (!reset) begin
      if (complete_valid_i) begin
        for (int word = 0; word < LINE_SIZE; word++)
        line_o[word] <= complete_line_i[word*XLEN+:XLEN];
      end else if (merge_valid_i) begin
        line_o[merge_word_i] <= merge_word(merge_old_i, merge_data_i, merge_mask_i);
      end else if (beat_valid_i && !beat_streamed_i) begin
        line_o[beat_word_i] <= beat_store_i && beat_word_i == wanted_word_i ?
            merge_word(beat_data_i, store_data_i, store_mask_i) : beat_data_i;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      count_o <= '0;
      response_o <= 2'b00;
      up_done_o <= 1'b0;
    end else begin
      if (count_clear_i) count_o <= '0;
      else if (count_inc_i) count_o <= count_o + 1'b1;
      if (response_load_i) response_o <= response_data_i;
      else if (response_clear_i) response_o <= 2'b00;
      if (up_done_set_i) up_done_o <= 1'b1;
      else if (up_done_clear_i) up_done_o <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || !valid_i) begin
      started_q <= 1'b0;
      phase_q <= INVALIDATE;
    end else begin
      started_q <= 1'b1;
      phase_q <= phase_o;
      unique case (phase_o)
        INVALIDATE: if (invalidate_ready_i) phase_q <= AR;
        AR: if (ar_done_i) phase_q <= R;
        R: begin
          // The parent consumes RLAST and selects the install or error path.
        end
        default: phase_q <= INVALIDATE;
      endcase
    end
  end
endmodule
