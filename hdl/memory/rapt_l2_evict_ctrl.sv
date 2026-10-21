// Dirty-victim writeback phases. The parent presents a valid transaction from
// AW through B; capture data ports carry the victim metadata for that transaction.
module rapt_l2_evict_ctrl #(
    parameter int LINE_LEN = 3,
    parameter int WAY_BITS = 2,
    parameter int TAG_BITS = 24
) (
    input  logic clock,
    input  logic reset,
    input  logic valid_i,
    output logic ready_o,
    output logic [1:0] phase_o,
    output logic [LINE_LEN-1:0] word_o,
    input  logic aw_fire_i,
    input  logic read_ready_i,
    input  logic w_fire_i,
    input  logic b_fire_i,
    output logic done_valid_o,
    input  logic done_ready_i,
    input  logic capture_valid_i,
    input  logic capture_way_only_i,
    input  logic [WAY_BITS-1:0] capture_way_i,
    input  logic [TAG_BITS-1:0] capture_tag_i,
    input  logic [1:0] capture_state_i,
    input  logic capture_dirty_i,
    input  logic capture_clients_i,
    input  logic probe_release_i,
    input  logic nested_release_i,
    input  logic nested_dirty_i,
    input  logic [1:0] nested_state_i,
    output logic [WAY_BITS-1:0] victim_way_o,
    output logic [TAG_BITS-1:0] victim_tag_o,
    output logic [1:0] victim_state_o,
    output logic victim_dirty_o,
    output logic victim_clients_o
);
  localparam logic [1:0] AW = 2'd0, READ = 2'd1, W = 2'd2, B = 2'd3;

  logic [1:0] phase_q;
  logic [LINE_LEN-1:0] word_q;

  assign ready_o = !valid_i && phase_q == AW;
  assign phase_o = phase_q;
  assign word_o = word_q;
  assign done_valid_o = valid_i && phase_q == B && b_fire_i;

  always_ff @(posedge clock) begin
    if (reset) begin
      victim_way_o <= '0;
      victim_tag_o <= '0;
      victim_state_o <= '0;
      victim_dirty_o <= 1'b0;
      victim_clients_o <= 1'b0;
    end else begin
      if (probe_release_i) victim_dirty_o <= 1'b1;
      if (capture_valid_i) begin
        victim_way_o <= capture_way_i;
        if (!capture_way_only_i) begin
          victim_tag_o <= capture_tag_i;
          victim_state_o <= capture_state_i;
          victim_dirty_o <= capture_dirty_i;
          victim_clients_o <= capture_clients_i;
        end
      end
      if (nested_release_i) begin
        victim_clients_o <= 1'b0;
        victim_dirty_o <= nested_dirty_i;
        victim_state_o <= nested_state_i;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset || !valid_i) begin
      phase_q <= AW;
      word_q <= '0;
    end else begin
      unique case (phase_q)
        AW: if (aw_fire_i) phase_q <= READ;
        READ: if (read_ready_i) phase_q <= W;
        W: if (w_fire_i) begin
          if (word_q == LINE_LEN'((1 << LINE_LEN) - 1)) phase_q <= B;
          else begin
            word_q <= word_q + 1'b1;
            phase_q <= READ;
          end
        end
        B: if (done_valid_o && done_ready_i) phase_q <= AW;
        default: phase_q <= AW;
      endcase
    end
  end
endmodule
