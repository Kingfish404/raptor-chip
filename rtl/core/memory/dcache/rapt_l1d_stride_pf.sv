`include "rapt.svh"
// PC-indexed L1D IP-stride prefetcher.
// Tracks per-load-PC page-local address deltas within a 4KB page and emits
// physical cache-line prefetch requests that never cross a 4KB page boundary,
// preserving translation, PBMT, and page-level permissions by construction.
module rapt_l1d_stride_pf #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int LineOffset = 6,
    parameter int Entries = 16,
    parameter bit Enable = 1'b1
) (
    input logic clock,
    input logic reset,
    input logic flush,
    input logic train_valid,
    input logic [11:0] train_pc_hash,
    input logic [XLEN-1:0] train_paddr,
    input logic [7:0] train_version,
    output logic pf_valid,
    output logic [XLEN-1:0] pf_addr,
    output logic [7:0] pf_version,
    input logic pf_accept,
    input logic pf_drop
);
  localparam int IdxBits  = $clog2(Entries);
  localparam int TagBits  = 12 - IdxBits;
  localparam int LineBits = 12 - LineOffset;

  if (Enable) begin : g_pf
    logic [Entries-1:0] tbl_valid;
    logic [TagBits-1:0] tbl_tag[Entries];
    logic [11:0] tbl_last_off[Entries];
    logic [11:0] tbl_stride[Entries];
    logic [1:0] tbl_conf[Entries];

    logic pf_valid_q;
    logic [XLEN-1:0] pf_addr_q;
    logic [7:0] pf_version_q;

    wire [IdxBits-1:0] idx = train_pc_hash[IdxBits-1:0];
    wire [TagBits-1:0] tag = train_pc_hash[11:IdxBits];
    wire [11:0] cur_off = train_paddr[11:0];
    wire [LineBits-1:0] cur_line = train_paddr[11:LineOffset];

    logic hit;
    logic [11:0] delta;
    logic stride_match;
    logic [12:0] next_off_13;
    logic [LineBits:0] step_line_ext;
    logic cand_valid;
    logic [LineBits-1:0] cand_line;
    logic [XLEN-1:0] cand_addr;

    always_comb begin
      hit = tbl_valid[idx] && (tbl_tag[idx] == tag);
      delta = cur_off - tbl_last_off[idx];
      stride_match = hit && (delta != 12'd0) && (delta == tbl_stride[idx]);
      next_off_13 = {1'b0, cur_off} + {delta[11], delta};
      step_line_ext = {1'b0, cur_line}
          + (delta[11] ? {LineBits + 1{1'b1}} : {{LineBits{1'b0}}, 1'b1});
      cand_valid = 1'b0;
      cand_line = cur_line;
      if (stride_match && (tbl_conf[idx] >= 2'd2)) begin
        if (!next_off_13[12] && (next_off_13[11:LineOffset] != cur_line)) begin
          cand_valid = 1'b1;
          cand_line = next_off_13[11:LineOffset];
        end else if ((tbl_conf[idx] == 2'd3) && (next_off_13[11:LineOffset] == cur_line)
            && !step_line_ext[LineBits]) begin
          cand_valid = 1'b1;
          cand_line = step_line_ext[LineBits-1:0];
        end
      end
      cand_addr = {train_paddr[XLEN-1:12], cand_line, {LineOffset{1'b0}}};
      if (!rapt_pkg::addr_cacheable(cand_addr) || rapt_pkg::addr_device(cand_addr))
        cand_valid = 1'b0;
    end

    always_ff @(posedge clock) begin
      if (reset) begin
        tbl_valid <= '0;
        pf_valid_q <= 1'b0;
        pf_addr_q <= '0;
        pf_version_q <= '0;
      end else begin
        if (train_valid) begin
          if (!hit) begin
            tbl_valid[idx] <= 1'b1;
            tbl_tag[idx] <= tag;
            tbl_last_off[idx] <= cur_off;
            tbl_stride[idx] <= 12'd0;
            tbl_conf[idx] <= 2'd0;
          end else if (delta != 12'd0) begin
            tbl_last_off[idx] <= cur_off;
            if (delta == tbl_stride[idx]) begin
              tbl_conf[idx] <= (tbl_conf[idx] == 2'd3) ? 2'd3 : (tbl_conf[idx] + 2'd1);
            end else begin
              tbl_stride[idx] <= delta;
              tbl_conf[idx] <= 2'd1;
            end
          end
        end

        if (flush) begin
          pf_valid_q <= 1'b0;
        end else if (train_valid && cand_valid) begin
          pf_valid_q <= 1'b1;
          pf_addr_q <= cand_addr;
          pf_version_q <= train_version;
        end else if (pf_accept || pf_drop) begin
          pf_valid_q <= 1'b0;
        end
      end
    end

    assign pf_valid = pf_valid_q;
    assign pf_addr = pf_addr_q;
    assign pf_version = pf_version_q;
  end else begin : g_no_pf
    assign pf_valid = 1'b0;
    assign pf_addr = '0;
    assign pf_version = '0;
  end
endmodule
