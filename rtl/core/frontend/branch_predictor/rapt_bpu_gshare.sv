`include "rapt.svh"
`include "rapt_bpu_dirp_if.svh"

// Gshare direction predictor: 2-bit counter table indexed by PC XOR GHR.
//
// Combines the bimodal PHT with global history via XOR. `GH_USED` selects
// how many low bits of the GHR participate (capped at IDX_LEN).
module rapt_bpu_gshare #(
    parameter int XLEN    = `RAPT_XLEN,
    parameter int GHR_LEN = 64,
    parameter int PHR_LEN = 8,
    parameter int DEPTH   = `RAPT_PHT_SIZE,
    parameter int IDX_LEN = $clog2(DEPTH),
    parameter int GH_USED = IDX_LEN
) (
    `RAPT_BPU_DIRP_PORTS
);
  localparam int PcW = `RAPT_PC_BITS_OF(XLEN);
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  logic _u;
  assign _u = |{update_mispred, r_phr, update_phr};
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */

  logic [1:0]         mem         [DEPTH];
  logic [IDX_LEN-1:0] r_idx;

  function automatic logic [IDX_LEN-1:0] mix_idx(input logic [PcW-1:0] pc,
                                                 input logic [GHR_LEN-1:0] g);
    logic [IDX_LEN-1:0] pc_part;
    logic [IDX_LEN-1:0] gh_part;
    pc_part = pc[IDX_LEN-1+1:1];
    gh_part = '0;
    for (int i = 0; i < GH_USED; i++) gh_part[i%IDX_LEN] = gh_part[i%IDX_LEN] ^ g[i];
    return pc_part ^ gh_part;
  endfunction

  logic [IDX_LEN-1:0] rd_idx_w;
  logic [IDX_LEN-1:0] up_idx_w;
  logic               valid_bit   [2];
  logic [1:0]         up_cur_ctr;
  logic [1:0]         up_next_ctr;

  assign rd_idx_w = mix_idx(raddr, r_ghr);
  assign up_idx_w = mix_idx(update_pc, update_ghr);

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
