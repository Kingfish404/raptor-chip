`include "rapt.svh"

// Independent priority-walk model for the combinational PMP checker.  This
// proves TOR/NA4/NAPOT bounds, lowest-numbered-entry priority, M-mode bypass,
// locked-entry permissions, and split-access rejection together.
module formal_pmp #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter int N = `RAPT_PMP_NUM
) (
    input logic [XLEN-1:0] addr,
    input logic [3:0] size_m1,
    input logic [1:0] priv,
    input logic op_r,
    input logic op_w,
    input logic op_x,
    input logic [PADDR_BITS-3:0] pmp_raw_addr[N],
    input logic [PADDR_BITS-3:0] pmp_napot_mask[N],
    input logic [N-1:0] pmp_cfg_r,
    input logic [N-1:0] pmp_cfg_w,
    input logic [N-1:0] pmp_cfg_x,
    input logic [N-1:0] pmp_cfg_l,
    input logic [N-1:0] pmp_mode_off,
    input logic [N-1:0] pmp_mode_tor,
    input logic [N-1:0] pmp_mode_na4,
    input logic [N-1:0] pmp_mode_napot
);
  logic dut_fault, dut_fault_lo;
  pmp_update_if unused_update();
  pmp_state_if unused_state();
  assign unused_update.addr_we = 1'b0;
  assign unused_update.addr_idx = '0;
  assign unused_update.raw_addr = '0;
  assign unused_update.napot_mask = '0;
  assign unused_update.cfg_we = '0;
  assign unused_update.cfg_r = '0;
  assign unused_update.cfg_w = '0;
  assign unused_update.cfg_x = '0;
  assign unused_update.cfg_l = '0;
  assign unused_update.mode_off = '1;
  assign unused_update.mode_tor = '0;
  assign unused_update.mode_na4 = '0;
  assign unused_update.mode_napot = '0;
  rapt_pmp_state unused_state_dut (.clock(1'b0), .reset(1'b1),
      .update(unused_update), .state(unused_state));
  rapt_pmp #(.XLEN(XLEN), .PADDR_BITS(PADDR_BITS)) dut (.*,
      .fault(dut_fault), .fault_lo_o(dut_fault_lo));

  localparam int AW = PADDR_BITS - 2;
  logic [PADDR_BITS-1:0] addr_hi;
  logic [AW-1:0] lo_word, hi_word;
  logic [AW-1:0] tor_base, napot_base;
  logic lo_match, hi_match;
  logic lo_found, hi_found;
  logic lo_perm, hi_perm;
  logic lo_locked, hi_locked;
  logic same_entry_hi;
  logic ref_fault_lo, ref_fault_hi, ref_partial, ref_fault;

  always_comb begin
    addr_hi = addr[PADDR_BITS-1:0] + PADDR_BITS'(size_m1);
    lo_word = addr[PADDR_BITS-1:2];
    hi_word = addr_hi[PADDR_BITS-1:2];
    lo_found = 1'b0;
    hi_found = 1'b0;
    lo_perm = 1'b0;
    hi_perm = 1'b0;
    lo_locked = 1'b0;
    hi_locked = 1'b0;
    same_entry_hi = 1'b0;

    // First match wins.  The loop guards deliberately express priority
    // directly rather than using the DUT's lowest-set-bit encoder.
    for (int i = 0; i < N; i++) begin
      tor_base = (i == 0) ? '0 : pmp_raw_addr[i-1];
      napot_base = pmp_raw_addr[i] & ~pmp_napot_mask[i];
      lo_match = (pmp_mode_tor[i] && lo_word >= tor_base && lo_word < pmp_raw_addr[i])
          || (pmp_mode_na4[i] && lo_word == pmp_raw_addr[i])
          || (pmp_mode_napot[i] && ((lo_word & ~pmp_napot_mask[i]) == napot_base));
      hi_match = (pmp_mode_tor[i] && hi_word >= tor_base && hi_word < pmp_raw_addr[i])
          || (pmp_mode_na4[i] && hi_word == pmp_raw_addr[i])
          || (pmp_mode_napot[i] && ((hi_word & ~pmp_napot_mask[i]) == napot_base));
      if (!lo_found && lo_match) begin
        lo_found = 1'b1;
        lo_perm = (!op_r || pmp_cfg_r[i]) && (!op_w || pmp_cfg_w[i])
            && (!op_x || pmp_cfg_x[i]);
        lo_locked = pmp_cfg_l[i];
        same_entry_hi = hi_match;
      end
      if (!hi_found && hi_match) begin
        hi_found = 1'b1;
        hi_perm = (!op_r || pmp_cfg_r[i]) && (!op_w || pmp_cfg_w[i])
            && (!op_x || pmp_cfg_x[i]);
        hi_locked = pmp_cfg_l[i];
      end
    end

    ref_fault_lo = !lo_found ? (priv != `RAPT_PRIV_M)
        : ((priv == `RAPT_PRIV_M && !lo_locked) ? 1'b0 : !lo_perm);
    ref_fault_hi = !hi_found ? (priv != `RAPT_PRIV_M)
        : ((priv == `RAPT_PRIV_M && !hi_locked) ? 1'b0 : !hi_perm);
    ref_partial = (op_r || op_w) && lo_found && !same_entry_hi;
    ref_fault = ref_fault_lo || ref_fault_hi || ref_partial;
  end

  always_comb begin
    for (int i = 0; i < N; i++) begin
      // CSR decode always produces exactly one address-matching mode.
      assume(({pmp_mode_off[i], pmp_mode_tor[i], pmp_mode_na4[i], pmp_mode_napot[i]} != 4'b0)
          && (({pmp_mode_off[i], pmp_mode_tor[i], pmp_mode_na4[i], pmp_mode_napot[i]}
              & ({pmp_mode_off[i], pmp_mode_tor[i], pmp_mode_na4[i], pmp_mode_napot[i]}
                 - 4'd1)) == 4'b0));
    end
    assert(dut_fault_lo == ref_fault_lo);
    assert(dut_fault == ref_fault);
  end
endmodule
