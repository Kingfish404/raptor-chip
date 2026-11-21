`include "rapt.svh"
`include "rapt_bpu_dirp_if.svh"

// Bimodal direction predictor: PC-indexed 2-bit saturating counter table.
//
// Indexed by PC[PHT_LEN:1]; GHR is ignored. This is the historical
// "PHT" used by the BPU before TAGE; kept as a low-area baseline flavor.
//
// Synchronous read: the address is registered on `ren`, output combinational
// from the registered address on the next cycle. Bulk reset/init uses grouped
// valid tracking so `mem` remains an unreset array instead of reset flip-flops.
module rapt_bpu_pht #(
    parameter int XLEN    = `RAPT_XLEN,
    parameter int GHR_LEN = 64,
    parameter int PHR_LEN = 8,
    parameter int DEPTH   = `RAPT_PHT_SIZE,
    parameter int IDX_LEN = $clog2(DEPTH)
) (
    `RAPT_BPU_DIRP_PORTS
);
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  // GHR/PHR and update_mispred are intentionally unused.
  logic _u;
  assign _u = |{r_ghr, r_phr, update_phr, update_mispred};
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */

  logic [1:0]         mem         [DEPTH];
  logic [IDX_LEN-1:0] r_idx;
  logic [IDX_LEN-1:0] rd_idx_w;
  logic [IDX_LEN-1:0] up_idx_w;
  logic               valid_bit   [2];
  logic [1:0]         up_cur_ctr;
  logic [1:0]         up_next_ctr;

  assign rd_idx_w = raddr[IDX_LEN-1+1:1];
  assign up_idx_w = update_pc[IDX_LEN-1+1:1];

  if (DEPTH > 32) begin : g_grouped_valid
    logic [IDX_LEN-1:0] valid_idx[2];
    assign valid_idx[0] = r_idx;
    assign valid_idx[1] = up_idx_w;
    rapt_bulk_clear_bits #(
        .Entries  (DEPTH),
        .GroupBits(5),
        .ReadPorts(2)
    ) u_valid (
        .clock      (clock),
        .clear      (reset || init),
        .read_index (valid_idx),
        .read_bit   (valid_bit),
        .write_valid(update_en),
        .write_index(up_idx_w),
        .write_bit  (1'b1)
    );
  end else begin : g_small_valid
    logic [DEPTH-1:0] valid_q;
    always_ff @(posedge clock) begin
      if (reset || init) valid_q <= '0;
      else if (update_en) valid_q[up_idx_w] <= 1'b1;
    end
    assign valid_bit[0] = valid_q[r_idx];
    assign valid_bit[1] = valid_q[up_idx_w];
  end

  // Unwritten entries represent weakly not-taken (2'b01), whose MSB is 0.
  assign rd_taken    = valid_bit[0] && mem[r_idx][1];
  assign up_cur_ctr  = valid_bit[1] ? mem[up_idx_w] : 2'b01;
  assign up_next_ctr = update_taken
      ? ((up_cur_ctr == 2'b11) ? 2'b11 : (up_cur_ctr + 2'b01))
      : ((up_cur_ctr == 2'b00) ? 2'b00 : (up_cur_ctr - 2'b01));

  always_ff @(posedge clock) begin
    if (reset || init) begin
      r_idx <= '0;
    end else begin
      if (ren) r_idx <= rd_idx_w;
      if (update_en) mem[up_idx_w] <= up_next_ctr;
    end
  end
endmodule
