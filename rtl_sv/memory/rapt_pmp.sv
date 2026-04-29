`include "rapt.svh"

// Combinational RISC-V PMP permission checker.
//
// Uses precomputed shadow registers from rapt_csr (`csr_bcast.pmp_*`) to
// keep the hot LSU/L1D critical path short.  All NAPOT decoding (XOR+AND),
// TOR neighbour selection and per-entry cfg-bit slicing happen one cycle
// earlier in CSR-update FFs; this module only does:
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
//   napot_mask[i], napot_base[i] : closed-form NAPOT decode
//   tor_lo[i], tor_hi[i]         : pmpaddr[i-1] / pmpaddr[i]
//   cfg_r/w/x/l[i]               : per-entry permission bit-vectors
//   mode_off/tor/na4/napot[i]    : per-entry mode one-hot vectors

module rapt_pmp #(
    parameter bit [7:0] XLEN = `RAPT_XLEN
) (
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [XLEN-1:0] addr,
    input  logic [     3:0] size_m1,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [     1:0] priv,
    input  logic            op_r,
    input  logic            op_w,
    input  logic            op_x,

    // Shadow inputs from csr_bcast.pmp_*
    input  logic [XLEN-1:0]              pmp_napot_mask  [`RAPT_PMP_NUM],
    input  logic [XLEN-1:0]              pmp_napot_base  [`RAPT_PMP_NUM],
    input  logic [XLEN-1:0]              pmp_tor_lo      [`RAPT_PMP_NUM],
    input  logic [XLEN-1:0]              pmp_tor_hi      [`RAPT_PMP_NUM],
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_cfg_r,
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_cfg_w,
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_cfg_x,
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_cfg_l,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_mode_off,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_mode_tor,
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_mode_na4,
    input  logic [`RAPT_PMP_NUM-1:0]     pmp_mode_napot,

    output logic                         fault
);
  localparam int N = `RAPT_PMP_NUM;

  // Per-byte-end match vectors.
  logic [N-1:0] entry_match_lo;
  logic [N-1:0] entry_match_hi;

  logic [XLEN-1:0] addr_hi;
  assign addr_hi = addr + {{(XLEN - 4) {1'b0}}, size_m1};

  // pmpaddr granularity = words (G=0 -> byte_addr >> 2).
  logic [XLEN-1:0] addr_lo_w;
  logic [XLEN-1:0] addr_hi_w;
  assign addr_lo_w = {2'b00, addr[XLEN-1:2]};
  assign addr_hi_w = {2'b00, addr_hi[XLEN-1:2]};

  for (genvar i = 0; i < N; i++) begin : gen_entry
    logic match_tor_lo, match_na4_lo, match_napot_lo;
    logic match_tor_hi, match_na4_hi, match_napot_hi;
    /* verilator lint_off UNSIGNED */
    assign match_tor_lo   = (addr_lo_w >= pmp_tor_lo[i]) && (addr_lo_w < pmp_tor_hi[i]);
    assign match_tor_hi   = (addr_hi_w >= pmp_tor_lo[i]) && (addr_hi_w < pmp_tor_hi[i]);
    /* verilator lint_on UNSIGNED */
    assign match_na4_lo   = (addr_lo_w == pmp_tor_hi[i]);                       // tor_hi == pmpaddr[i]
    assign match_na4_hi   = (addr_hi_w == pmp_tor_hi[i]);
    assign match_napot_lo = ((addr_lo_w & ~pmp_napot_mask[i]) == pmp_napot_base[i]);
    assign match_napot_hi = ((addr_hi_w & ~pmp_napot_mask[i]) == pmp_napot_base[i]);

    // OR-of-AND with mode one-hot vectors.  Equivalent to the previous
    // unique-case but synthesises as 4×AND + OR-reduce instead of a
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
  assign fm_lo = entry_match_lo & ((~entry_match_lo) + {{(N-1){1'b0}}, 1'b1});
  assign fm_hi = entry_match_hi & ((~entry_match_hi) + {{(N-1){1'b0}}, 1'b1});

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
  assign fault_lo = byte_fault(any_match_lo, perm_r_lo, perm_w_lo, perm_x_lo, perm_l_lo);
  assign fault_hi = byte_fault(any_match_hi, perm_r_hi, perm_w_hi, perm_x_hi, perm_l_hi);
  assign fault = fault_lo | fault_hi;

endmodule
