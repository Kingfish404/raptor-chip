// Uncached read phases and the shared registered outer AR channel. The
// request valid/data ports also admit blocking refills to the same AR register.
module rapt_l2_bypass_ctrl #(
    parameter int XLEN = 64,
    parameter int ID_W = 4
) (
    input  logic clock,
    input  logic reset,
    input  logic valid_i,
    input  logic start_ar_i,
    output logic ready_o,
    output logic [1:0] phase_o,
    input  logic wait_done_i,
    input  logic ar_done_i,
    input  logic r_last_fire_i,
    output logic done_valid_o,
    input  logic done_ready_i,
    input  logic request_valid_i,
    input  logic request_issue_i,
    input  logic [XLEN-1:0] request_addr_i,
    input  logic [ID_W-1:0] request_id_i,
    input  logic [7:0] request_len_i,
    input  logic [2:0] request_size_i,
    input  logic [1:0] request_burst_i,
    input  logic [3:0] request_cache_i,
    input  logic arready_i,
    output logic arvalid_o,
    output logic [XLEN-1:0] araddr_o,
    output logic [ID_W-1:0] arid_o,
    output logic [7:0] arlen_o,
    output logic [2:0] arsize_o,
    output logic [1:0] arburst_o,
    output logic [3:0] arcache_o
);
  localparam logic [1:0] WAIT = 2'd0, AR = 2'd1, R = 2'd2;

  logic started_q;
  logic [1:0] phase_q;

  assign ready_o = !valid_i;
  assign phase_o = started_q ? phase_q : (start_ar_i ? AR : WAIT);
  assign done_valid_o = valid_i && phase_o == R && r_last_fire_i;

  always_ff @(posedge clock) begin
    if (reset || !valid_i) begin
      started_q <= 1'b0;
      phase_q <= WAIT;
    end else begin
      started_q <= 1'b1;
      phase_q <= phase_o;
      unique case (phase_o)
        WAIT: if (wait_done_i) phase_q <= AR;
        AR: if (ar_done_i) phase_q <= R;
        R: if (done_valid_o && done_ready_i) phase_q <= WAIT;
        default: phase_q <= WAIT;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (reset) arvalid_o <= 1'b0;
    else begin
      if (arvalid_o && arready_i) arvalid_o <= 1'b0;
      if (request_issue_i) arvalid_o <= 1'b1;
      if (request_valid_i) begin
        araddr_o <= request_addr_i;
        arid_o <= request_id_i;
        arlen_o <= request_len_i;
        arsize_o <= request_size_i;
        arburst_o <= request_burst_i;
        arcache_o <= request_cache_i;
      end
    end
  end
endmodule
