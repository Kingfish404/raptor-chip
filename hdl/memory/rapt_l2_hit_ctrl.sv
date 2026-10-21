// Resident read phases. Valid/ready selects the hit pipeline; the data ports
// capture its request and advance the address, word, and remaining beat count.
module rapt_l2_hit_ctrl #(
    parameter int XLEN = 64,
    parameter int LINE_LEN = 3,
    parameter int ID_W = 4
) (
    input  logic clock,
    input  logic reset,
    input  logic valid_i,
    input  logic start_install_i,
    output logic ready_o,
    output logic [2:0] phase_o,
    input  logic boom_i,
    input  logic lookup_blocked_i,
    input  logic hit_i,
    input  logic probe_needed_i,
    input  logic probe_done_i,
    input  logic probe_commit_i,
    input  logic data_recheck_i,
    input  logic data_advance_i,
    input  logic more_beats_i,
    input  logic install_ready_i,
    input  logic capture_addr_valid_i,
    input  logic [XLEN-1:0] capture_addr_i,
    input  logic capture_word_valid_i,
    input  logic [LINE_LEN-1:0] capture_word_i,
    input  logic capture_len_valid_i,
    input  logic [7:0] capture_len_i,
    input  logic beat_advance_i,
    input  logic error_advance_i,
    input  logic [XLEN-1:0] next_addr_i,
    input  logic [LINE_LEN-1:0] next_word_i,
    output logic [XLEN-1:0] addr_o,
    output logic [LINE_LEN-1:0] word_o,
    output logic [7:0] len_o,
    input  logic response_write_i,
    input  logic [XLEN-1:0] response_data_i,
    input  logic [ID_W-1:0] response_id_i,
    input  logic [1:0] response_code_i,
    input  logic response_last_i,
    input  logic response_secondary_write_i,
    input  logic response_secondary_i,
    input  logic response_ready_i,
    output logic response_valid_o,
    output logic [XLEN-1:0] response_data_o,
    output logic [ID_W-1:0] response_id_o,
    output logic [1:0] response_code_o,
    output logic response_last_o,
    output logic response_secondary_o
);
  localparam logic [2:0] LOOKUP = 3'd0, DATA = 3'd1, PROBE = 3'd2;
  localparam logic [2:0] PROBE_COMMIT = 3'd3, INSTALL_READ = 3'd4;

  logic started_q;
  logic [2:0] phase_q;

  assign ready_o = !valid_i;
  assign phase_o = started_q ? phase_q : (start_install_i ? INSTALL_READ : LOOKUP);

  always_ff @(posedge clock) begin
    if (reset || !valid_i) begin
      started_q <= 1'b0;
      phase_q <= LOOKUP;
    end else begin
      started_q <= 1'b1;
      phase_q <= phase_o;
      unique case (phase_o)
        LOOKUP: if (!lookup_blocked_i && hit_i && boom_i)
          phase_q <= probe_needed_i ? PROBE : DATA;
        PROBE: if (probe_done_i) phase_q <= PROBE_COMMIT;
        PROBE_COMMIT: if (probe_commit_i) phase_q <= LOOKUP;
        DATA: if (data_recheck_i || (data_advance_i && more_beats_i))
          phase_q <= LOOKUP;
        INSTALL_READ: if (!boom_i) phase_q <= LOOKUP;
                      else if (install_ready_i) phase_q <= DATA;
        default: phase_q <= LOOKUP;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      addr_o <= '0;
      word_o <= '0;
      len_o <= '0;
    end else begin
      if (capture_addr_valid_i) addr_o <= capture_addr_i;
      else if (beat_advance_i) addr_o <= next_addr_i;
      if (capture_word_valid_i) word_o <= capture_word_i;
      else if (beat_advance_i) word_o <= next_word_i;
      if (capture_len_valid_i) len_o <= capture_len_i;
      else if (beat_advance_i || error_advance_i) len_o <= len_o - 8'd1;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      response_valid_o <= 1'b0;
      response_last_o <= 1'b0;
      response_code_o <= 2'b00;
      response_id_o <= '0;
      response_data_o <= '0;
      response_secondary_o <= 1'b0;
    end else begin
      if (response_valid_o && response_ready_i) begin
        response_valid_o <= 1'b0;
        response_last_o <= 1'b0;
        response_secondary_o <= 1'b0;
      end
      if (response_write_i) begin
        response_valid_o <= 1'b1;
        response_data_o <= response_data_i;
        response_id_o <= response_id_i;
        response_code_o <= response_code_i;
        response_last_o <= response_last_i;
      end
      if (response_secondary_write_i) response_secondary_o <= response_secondary_i;
    end
  end
endmodule
