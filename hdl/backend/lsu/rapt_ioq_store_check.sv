`include "rapt.svh"
`include "rapt_if.svh"

// Head-store access policy only. Translation and exception sequencing stay
// with the IOQ resident; Zicbom management accepts read OR write permission.
/* verilator lint_off PINCONNECTEMPTY */
module rapt_ioq_store_check #(
    parameter int XLEN = `RAPT_XLEN
) (
    input rapt_pkg::mem_context_t store_context,
    pmp_state_if.in pmp_state,
    input logic [XLEN-1:0] store_addr,
    input logic [3:0] store_size_m1,
    input logic store_valid,
    input logic store_mmu,
    input logic cmo_mgmt,
    output logic [3:0] store_bare_fault_offset,
    output logic store_bare_pmp_trap
);
  // Bare-mode accesses still obey MPRV. MMU-mode stores are checked in L1D.
  logic [1:0] ioq_store_eff_priv;
  logic       pmp_store_bare_fault;
  logic       pmp_load_bare_fault;
  assign ioq_store_eff_priv = store_context.eff_priv;
  // Use the architectural width supplied by the owner: RV32 FSD is eight
  // bytes even though its integer store encoding is SW. CMO passes one byte
  // for its operand permission check; block-zero capability is checked by IOQ.
  //
  // Zicbom management is permitted when either an ordinary load or an
  // ordinary store is permitted. Both predicates share one address, size and
  // privilege, and rapt_pmp_permissions already derives R-only and W-only
  // faults from one range-match tree, so a single instance replaces the two
  // full rapt_pmp CAMs used previously.
  rapt_pmp_permissions #(
      .XLEN(XLEN)
  ) u_pmp_store_cbo (
      .addr          (store_addr),
      .size_m1       (store_size_m1),
      .priv          (ioq_store_eff_priv),
      .op_r          (1'b0),
      .op_w          (1'b1),
      .op_x          (1'b0),
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_store_bare_fault),
      .fault_lo_o    (),
      .fault_read_o  (pmp_load_bare_fault),
      .fault_write_o ()
  );
  logic [3:0] pma_fault_offset;
  logic device_alignment_fault;
  assign device_alignment_fault = !cmo_mgmt && rapt_pkg::addr_device(store_addr)
      && ((store_addr & XLEN'(store_size_m1)) != 0);
  assign pma_fault_offset = !rapt_pkg::addr_device_width_capable(store_addr, store_size_m1)
      ? 4'd0 : rapt_pkg::addr_data_span_fault_offset(store_addr, store_size_m1, 1'b1);
  // PMA rejects the denied byte before any data access; a PMP-only or CMO
  // fault retains its existing address policy. Match the reference ordering.
  assign store_bare_fault_offset = !cmo_mgmt
      && pma_fault_offset != 8 ? pma_fault_offset : 4'd0;
  assign store_bare_pmp_trap = store_valid
                               && !store_mmu
                               && !store_context.mmu_en
                               && ((cmo_mgmt
                                      ? (pmp_store_bare_fault && pmp_load_bare_fault)
                                      : pmp_store_bare_fault)
                                   || device_alignment_fault
                                   || (cmo_mgmt ? !rapt_pkg::addr_mapped(store_addr)
                                                : (pma_fault_offset != 8)));

endmodule
/* verilator lint_on PINCONNECTEMPTY */
