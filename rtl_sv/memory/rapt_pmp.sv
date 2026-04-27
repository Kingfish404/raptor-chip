`include "rapt.svh"

// Combinational RISC-V PMP permission checker.
//
// Implements 8 entries with OFF / TOR / NA4 / NAPOT match modes,
// first-match priority (entry 0 highest), and L-bit lockdown semantics.
//
// Granularity = 4 bytes (G=0), so all pmpaddr bits are significant and
// NA4 is legal (per Privileged Spec).
//
// Simplification: the caller provides `size_m1` (size in bytes minus 1).
// The checker verifies both `addr` and `addr + size_m1` land in a permitted
// region.  Accesses that straddle two regions trap conservatively whenever
// either end fails the permission check, matching the RISC-V spec intent
// that every byte must be covered by a matching, permitted entry.
//
// Inputs:
//   addr     - physical byte address being accessed (low byte of the access).
//   size_m1  - access size in bytes - 1 (0 for byte, 1 for halfword, 3 for
//              word, 7 for doubleword, 15 for quadword).  Caller can pass 0
//              if size information is unavailable (no straddle protection).
//   priv     - effective privilege level for this access (M/S/U).  Callers
//              must already have applied MSTATUS.MPRV / MPP for loads and
//              stores; fetch and PTW pass the current hart privilege.
//   op_r/_w/_x - which permission bits to check (exactly one should be hi).
//   pmpcfg   - 8× 8-bit cfg bytes (pmpcfg0 packs entries 0..3 low-to-high).
//   pmpaddr  - 8× XLEN raw CSR values (pmpaddr[1:0] are WARL meaningful at G=0).
//
// Output:
//   fault    - 1 when the access must trap (access-fault of caller's type).

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
    input  logic [     7:0] pmpcfg [`RAPT_PMP_NUM],
    input  logic [XLEN-1:0] pmpaddr[`RAPT_PMP_NUM],
    output logic            fault
);
  localparam int N = `RAPT_PMP_NUM;

  // Per-byte-end match vectors.
  logic [N-1:0] entry_match_lo;
  logic [N-1:0] entry_match_hi;
  logic [N-1:0] cfg_r, cfg_w, cfg_x, cfg_l;
  logic [1:0]   cfg_a   [N];

  logic [XLEN-1:0] addr_hi;
  assign addr_hi = addr + {{(XLEN - 4) {1'b0}}, size_m1};

  // pmpaddr is stored in word granules (byte_addr >> 2).
  logic [XLEN-1:0] addr_lo_w;
  logic [XLEN-1:0] addr_hi_w;
  assign addr_lo_w = {2'b00, addr[XLEN-1:2]};
  assign addr_hi_w = {2'b00, addr_hi[XLEN-1:2]};

  // NAPOT decoder: scan pmpaddr from LSB; trailing ones form the size mask.
  // mask[i]=1 where bit i is "inside" the NAPOT region (i.e., should be ignored
  // in the comparison).  region_base = pmpaddr & ~mask, inflated to bytes.
  //
  // Encoding (byte granularity):
  //   NA4  (A=10):   region = { pmpaddr[XLEN-1:0], 2'b00 } ... pmpaddr<<2 + 3
  //   NAPOT(A=11):   let t = position of lowest 0 bit in pmpaddr; size = 2^(t+3) bytes,
  //                  base_bytes = (pmpaddr & ~((1<<t)-1)) << 2.
  //
  // For comparison we shift addr right by 2 and compare against pmpaddr[XLEN-3:0]
  // using a generated match mask.
  logic [XLEN-1:0] addr_w;  // address in 4-byte units (top XLEN-2 bits meaningful)
  assign addr_w = {2'b00, addr[XLEN-1:2]};

  for (genvar i = 0; i < N; i++) begin : gen_entry
    // cfg decode
    assign cfg_r[i] = pmpcfg[i][`RAPT_PMPCFG_R_];
    assign cfg_w[i] = pmpcfg[i][`RAPT_PMPCFG_W_];
    assign cfg_x[i] = pmpcfg[i][`RAPT_PMPCFG_X_];
    assign cfg_l[i] = pmpcfg[i][`RAPT_PMPCFG_L_];
    assign cfg_a[i] = pmpcfg[i][`RAPT_PMPCFG_A_];

    logic [XLEN-1:0] tor_lo, tor_hi;
    if (i == 0) assign tor_lo = '0;
    else assign tor_lo = pmpaddr[i-1];
    assign tor_hi = pmpaddr[i];

    // NAPOT: trailing ones of pmpaddr[i] define region size.
    // Closed-form identity: mask of (trailing-ones | first-zero) bits == pmpaddr ^ (pmpaddr + 1).
    logic [XLEN-1:0] napot_mask;
    logic [XLEN-1:0] napot_base;
    assign napot_mask = pmpaddr[i] ^ (pmpaddr[i] + {{(XLEN-1){1'b0}}, 1'b1});
    assign napot_base = pmpaddr[i] & ~napot_mask;

    logic match_tor_lo, match_na4_lo, match_napot_lo;
    logic match_tor_hi, match_na4_hi, match_napot_hi;
    /* verilator lint_off UNSIGNED */
    assign match_tor_lo   = (addr_lo_w >= tor_lo) && (addr_lo_w < tor_hi);
    assign match_tor_hi   = (addr_hi_w >= tor_lo) && (addr_hi_w < tor_hi);
    /* verilator lint_on UNSIGNED */
    assign match_na4_lo   = (addr_lo_w == pmpaddr[i]);
    assign match_na4_hi   = (addr_hi_w == pmpaddr[i]);
    assign match_napot_lo = ((addr_lo_w & ~napot_mask) == napot_base);
    assign match_napot_hi = ((addr_hi_w & ~napot_mask) == napot_base);

    always_comb begin
      unique case (cfg_a[i])
        `RAPT_PMP_A_OFF: begin
          entry_match_lo[i] = 1'b0;
          entry_match_hi[i] = 1'b0;
        end
        `RAPT_PMP_A_TOR: begin
          entry_match_lo[i] = match_tor_lo;
          entry_match_hi[i] = match_tor_hi;
        end
        `RAPT_PMP_A_NA4: begin
          entry_match_lo[i] = match_na4_lo;
          entry_match_hi[i] = match_na4_hi;
        end
        `RAPT_PMP_A_NAPOT: begin
          entry_match_lo[i] = match_napot_lo;
          entry_match_hi[i] = match_napot_hi;
        end
        default: begin
          entry_match_lo[i] = 1'b0;
          entry_match_hi[i] = 1'b0;
        end
      endcase
    end
  end

  // Per-byte first-match priority encoders.  Lo byte and hi byte may land
  // in different entries when an unaligned access straddles a PMP boundary;
  // each byte must independently find a permitted match (or no match + M).
  logic [N-1:0] fm_lo, fm_hi;
  logic any_match_lo, any_match_hi;
  assign any_match_lo = |entry_match_lo;
  assign any_match_hi = |entry_match_hi;
  always_comb begin
    fm_lo = '0;
    for (int k = 0; k < N; k++) begin
      if (entry_match_lo[k]) begin
        fm_lo[k] = 1'b1;
        break;
      end
    end
  end
  always_comb begin
    fm_hi = '0;
    for (int k = 0; k < N; k++) begin
      if (entry_match_hi[k]) begin
        fm_hi[k] = 1'b1;
        break;
      end
    end
  end

  logic perm_r_lo, perm_w_lo, perm_x_lo, perm_l_lo;
  logic perm_r_hi, perm_w_hi, perm_x_hi, perm_l_hi;
  always_comb begin
    perm_r_lo = 1'b0;
    perm_w_lo = 1'b0;
    perm_x_lo = 1'b0;
    perm_l_lo = 1'b0;
    perm_r_hi = 1'b0;
    perm_w_hi = 1'b0;
    perm_x_hi = 1'b0;
    perm_l_hi = 1'b0;
    for (int k = 0; k < N; k++) begin
      if (fm_lo[k]) begin
        perm_r_lo = cfg_r[k];
        perm_w_lo = cfg_w[k];
        perm_x_lo = cfg_x[k];
        perm_l_lo = cfg_l[k];
      end
      if (fm_hi[k]) begin
        perm_r_hi = cfg_r[k];
        perm_w_hi = cfg_w[k];
        perm_x_hi = cfg_x[k];
        perm_l_hi = cfg_l[k];
      end
    end
  end

  logic is_m;
  assign is_m = (priv == `RAPT_PRIV_M);

  // Per-byte fault:
  //   no match  + !M   → fault (spec 3.7.1: "no matching entry"=deny for U/S)
  //   no match  + M    → allow (privileged bypass)
  //   match + L=0 + M  → allow (M-mode bypasses unlocked entries)
  //   match + (L=1 or !M) → require requested permission
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
