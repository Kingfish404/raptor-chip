`include "rapt.svh"
`include "rapt_bpu_dirp_if.svh"

// Gshare direction predictor: 2-bit counter table indexed by PC XOR GHR.
//
// Combines the bimodal PHT with global history via XOR. `GH_USED` selects
// how many low bits of the GHR participate (capped at IDX_LEN).
(* keep_hierarchy *)
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
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  wire _u = |{update_mispred, r_phr, update_phr};
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */

  logic [1:0]         mem  [DEPTH];
  logic [IDX_LEN-1:0] r_idx;

  function automatic logic [IDX_LEN-1:0] mix_idx(input logic [XLEN-1:0]    pc,
                                                 input logic [GHR_LEN-1:0] g);
    logic [IDX_LEN-1:0] pc_part;
    logic [IDX_LEN-1:0] gh_part;
    pc_part = pc[IDX_LEN-1+1:1];
    gh_part = '0;
    for (int i = 0; i < GH_USED; i++) gh_part[i%IDX_LEN] = gh_part[i%IDX_LEN] ^ g[i];
    return pc_part ^ gh_part;
  endfunction

  wire [IDX_LEN-1:0] rd_idx_w = mix_idx(raddr, r_ghr);
  wire [IDX_LEN-1:0] up_idx_w = mix_idx(update_pc, update_ghr);

  assign rd_taken = mem[r_idx][1];

  always_ff @(posedge clock) begin
    if (reset || init) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= 2'b01;
      r_idx <= '0;
    end else begin
      if (ren) r_idx <= rd_idx_w;
      if (update_en) begin
        if (update_taken) begin
          if (mem[up_idx_w] != 2'b11) mem[up_idx_w] <= mem[up_idx_w] + 1;
        end else begin
          if (mem[up_idx_w] != 2'b00) mem[up_idx_w] <= mem[up_idx_w] - 1;
        end
      end
    end
  end
endmodule
