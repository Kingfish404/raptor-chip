`include "rapt.svh"

/* verilator lint_off DECLFILENAME */
module rapt_pmp_state #(
    parameter int N = `RAPT_PMP_NUM
) (
    input logic clock,
    input logic reset,
    pmp_update_if.in update,
    pmp_state_if.out state
);
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < N; i++) begin
        state.pmp_raw_addr[i]   <= '0;
        state.pmp_napot_mask[i] <= '0;
      end
      state.pmp_cfg_r      <= '0;
      state.pmp_cfg_w      <= '0;
      state.pmp_cfg_x      <= '0;
      state.pmp_cfg_l      <= '0;
      state.pmp_mode_off   <= '1;
      state.pmp_mode_tor   <= '0;
      state.pmp_mode_na4   <= '0;
      state.pmp_mode_napot <= '0;
    end else begin
      if (update.addr_we) begin
        state.pmp_raw_addr[update.addr_idx]   <= update.raw_addr;
        state.pmp_napot_mask[update.addr_idx] <= update.napot_mask;
      end
      for (int i = 0; i < N; i++) begin
        if (update.cfg_we[i]) begin
          state.pmp_cfg_r[i]      <= update.cfg_r[i];
          state.pmp_cfg_w[i]      <= update.cfg_w[i];
          state.pmp_cfg_x[i]      <= update.cfg_x[i];
          state.pmp_cfg_l[i]      <= update.cfg_l[i];
          state.pmp_mode_off[i]   <= update.mode_off[i];
          state.pmp_mode_tor[i]   <= update.mode_tor[i];
          state.pmp_mode_na4[i]   <= update.mode_na4[i];
          state.pmp_mode_napot[i] <= update.mode_napot[i];
        end
      end
    end
  end
endmodule
/* verilator lint_on DECLFILENAME */

// Combinational RISC-V PMP permission checker.
//
// Uses compact state from the local pmp_state_if replica. NAPOT masks are
// precomputed on CSR writes; NAPOT bases and TOR neighbours are derived from
// each entry's raw pmpaddr value in the checker.
//
//   * `addr_hi = addr + size_m1` (single 4-bit + carry-extend adder)
//   * per-entry XOR / compare for match (parallel, generate-for)
//   * one-hot lowest-set-bit priority via `fm = match & (~match + 1)`
//   * permission select via `perm_x = |(fm & cfg_x_vec)` (1 LUT level)
//
// Functionality is bit-identical to the previous implementation; this is
// purely a synthesis-friendly restructuring (area-for-frequency).
//
// Inputs (live):
//   addr     - byte address
//   size_m1  - access size in bytes - 1 (0..15)
//   priv     - effective privilege level (M/S/U)
//   op_r/_w/_x - which permission to check
//
// Inputs (shadow, 1-cycle delayed copies of pmpcfg/pmpaddr):
//   raw_addr[i], napot_mask[i]   : raw pmpaddr and NAPOT mask
//   cfg_r/w/x/l[i]               : per-entry permission bit-vectors
//   mode_off/tor/na4/napot[i]    : per-entry mode one-hot vectors

module rapt_pmp #(
  parameter int XLEN = `RAPT_XLEN,
  parameter int PADDR_BITS = `RAPT_PADDR_BITS
) (
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [XLEN-1:0] addr,
    input logic [     3:0] size_m1,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [     1:0] priv,
    input logic            op_r,
    input logic            op_w,
    input logic            op_x,

    // Decoded inputs from pmp_state_if
    input logic [PADDR_BITS-3:0] pmp_raw_addr  [`RAPT_PMP_NUM],
    input logic [PADDR_BITS-3:0] pmp_napot_mask[`RAPT_PMP_NUM],
    input logic [`RAPT_PMP_NUM-1:0] pmp_cfg_r,
    input logic [`RAPT_PMP_NUM-1:0] pmp_cfg_w,
    input logic [`RAPT_PMP_NUM-1:0] pmp_cfg_x,
    input logic [`RAPT_PMP_NUM-1:0] pmp_cfg_l,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [`RAPT_PMP_NUM-1:0] pmp_mode_off,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [`RAPT_PMP_NUM-1:0] pmp_mode_tor,
    input logic [`RAPT_PMP_NUM-1:0] pmp_mode_na4,
    input logic [`RAPT_PMP_NUM-1:0] pmp_mode_napot,

    output logic fault,
    output logic fault_lo_o
);
  localparam int N = `RAPT_PMP_NUM;
  localparam int PMPAddrBits = PADDR_BITS - 2;

  // Per-byte-end match vectors.
  logic [N-1:0] entry_match_lo;
  logic [N-1:0] entry_match_hi;

  // pmpaddr granularity = words (G=0 -> byte_addr >> 2). We compute
  // addr_hi_w directly via (addr + size_m1) >> 2 to avoid carrying the
  // unused byte-offset bits of the sum.
  logic [PADDR_BITS-1:0] addr_phys;
  logic [PADDR_BITS-1:0] addr_hi_phys;
  logic [PMPAddrBits-1:0] addr_lo_w;
  logic [PMPAddrBits-1:0] addr_hi_w;
  assign addr_phys = addr[PADDR_BITS-1:0];
  assign addr_hi_phys = addr_phys + {{(PADDR_BITS - 4) {1'b0}}, size_m1};
  assign addr_lo_w = addr_phys[PADDR_BITS-1:2];
  assign addr_hi_w = addr_hi_phys[PADDR_BITS-1:2];
  for (genvar i = 0; i < N; i++) begin : gen_entry
    logic [PMPAddrBits-1:0] tor_lo;
    logic [PMPAddrBits-1:0] napot_base;
    logic match_tor_lo, match_na4_lo, match_napot_lo;
    logic match_tor_hi, match_na4_hi, match_napot_hi;
    if (i == 0) begin : gen_first_tor
      assign tor_lo = '0;
    end else begin : gen_next_tor
      assign tor_lo = pmp_raw_addr[i-1];
    end
    assign napot_base = pmp_raw_addr[i] & ~pmp_napot_mask[i];
    /* verilator lint_off UNSIGNED */
    assign match_tor_lo = (addr_lo_w >= tor_lo) && (addr_lo_w < pmp_raw_addr[i]);
    assign match_tor_hi = (addr_hi_w >= tor_lo) && (addr_hi_w < pmp_raw_addr[i]);
    /* verilator lint_on UNSIGNED */
    assign match_na4_lo = (addr_lo_w == pmp_raw_addr[i]);
    assign match_na4_hi = (addr_hi_w == pmp_raw_addr[i]);
    assign match_napot_lo = ((addr_lo_w & ~pmp_napot_mask[i]) == napot_base);
    assign match_napot_hi = ((addr_hi_w & ~pmp_napot_mask[i]) == napot_base);

    // OR-of-AND with mode one-hot vectors.  Equivalent to the previous
    // unique-case but synthesises as 4xAND + OR-reduce instead of a
    // 4-way mux that may share priority logic with the rest of the chain.
    assign entry_match_lo[i] = (pmp_mode_tor[i]   & match_tor_lo)
                             | (pmp_mode_na4[i]   & match_na4_lo)
                             | (pmp_mode_napot[i] & match_napot_lo);
    assign entry_match_hi[i] = (pmp_mode_tor[i]   & match_tor_hi)
                             | (pmp_mode_na4[i]   & match_na4_hi)
                             | (pmp_mode_napot[i] & match_napot_hi);
  end

  // Lowest-set-bit one-hot priority encoder.
  // Carry-chain isolates the LSB -> ~1 LUT level vs N-deep priority chain.
  logic [N-1:0] fm_lo, fm_hi;
  assign fm_lo = entry_match_lo & ((~entry_match_lo) + {{(N - 1) {1'b0}}, 1'b1});
  assign fm_hi = entry_match_hi & ((~entry_match_hi) + {{(N - 1) {1'b0}}, 1'b1});

  logic any_match_lo, any_match_hi;
  assign any_match_lo = |entry_match_lo;
  assign any_match_hi = |entry_match_hi;

  // One-hot AND + OR-reduce: 1 LUT level instead of N-deep cascade.
  logic perm_r_lo, perm_w_lo, perm_x_lo, perm_l_lo;
  logic perm_r_hi, perm_w_hi, perm_x_hi, perm_l_hi;
  assign perm_r_lo = |(fm_lo & pmp_cfg_r);
  assign perm_w_lo = |(fm_lo & pmp_cfg_w);
  assign perm_x_lo = |(fm_lo & pmp_cfg_x);
  assign perm_l_lo = |(fm_lo & pmp_cfg_l);
  assign perm_r_hi = |(fm_hi & pmp_cfg_r);
  assign perm_w_hi = |(fm_hi & pmp_cfg_w);
  assign perm_x_hi = |(fm_hi & pmp_cfg_x);
  assign perm_l_hi = |(fm_hi & pmp_cfg_l);

  logic is_m;
  assign is_m = (priv == `RAPT_PRIV_M);

  // Per-byte fault:
  //   no match  + !M   -> fault (spec 3.7.1: "no matching entry"=deny for U/S)
  //   no match  + M    -> allow (privileged bypass)
  //   match + L=0 + M  -> allow (M-mode bypasses unlocked entries)
  //   match + (L=1 or !M) -> require requested permission
  function automatic logic byte_fault(input logic any_match, input logic perm_r, input logic perm_w,
                                      input logic perm_x, input logic perm_l);
    logic perm_ok;
    perm_ok = (!op_r || perm_r) && (!op_w || perm_w) && (!op_x || perm_x);
    if (!any_match) begin
      return ~is_m;
    end else if (is_m && !perm_l) begin
      return 1'b0;
    end else begin
      return ~perm_ok;
    end
  endfunction

  logic fault_lo, fault_hi;
  logic data_partial_match_fault;
  assign fault_lo = byte_fault(any_match_lo, perm_r_lo, perm_w_lo, perm_x_lo, perm_l_lo);
  assign fault_hi = byte_fault(any_match_hi, perm_r_hi, perm_w_hi, perm_x_hi, perm_l_hi);
  assign data_partial_match_fault = (op_r || op_w) && any_match_lo
                                  && !(|(fm_lo & entry_match_hi));
  assign fault_lo_o = fault_lo;
  assign fault = fault_lo | fault_hi | data_partial_match_fault;

endmodule
