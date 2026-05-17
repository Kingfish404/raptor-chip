`include "rapt.svh"
`include "rapt_bpu_dirp_if.svh"

// Bimodal direction predictor: PC-indexed 2-bit saturating counter table.
//
// Indexed by PC[PHT_LEN:1]; GHR is ignored. This is the historical
// "PHT" used by the BPU before TAGE; kept as a low-area baseline flavor.
//
// Synchronous read: the address is registered on `ren`, output combinational
// from the registered address on the next cycle. (* keep_hierarchy *) keeps
// Yosys from flattening the read-address register into the BPU wrapper,
// which would otherwise create a ~2800-way fan-out on `pc_ifu`.
(* keep_hierarchy *)
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
  wire _u = |{r_ghr, r_phr, update_phr, update_mispred};
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */

  logic [1:0]         mem      [DEPTH];
  logic [IDX_LEN-1:0] r_idx;

  wire [IDX_LEN-1:0] rd_idx_w = raddr[IDX_LEN-1+1:1];
  wire [IDX_LEN-1:0] up_idx_w = update_pc[IDX_LEN-1+1:1];

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
