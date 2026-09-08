`include "rapt.svh"
`include "rapt_if.svh"

// Combinational L1D access checks. TLB/PTW ownership, request capture and
// fault sequencing remain in rapt_l1d; no pipeline stages are added here.
/* verilator lint_off PINCONNECTEMPTY */
module rapt_l1d_access #(
    parameter int XLEN = `RAPT_XLEN
) (
    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,
    input logic [XLEN-1:0] load_addr,
    input logic [XLEN-1:0] store_addr,
    input logic [XLEN-1:0] ptw_addr,
    input logic [3:0] load_size_m1,
    input logic [7:0] store_walu,
    input logic cmo_mgmt,
    input logic tlb_hit,
    input logic stlb_hit,
    input logic [6:0] dtlb_pte,
    input logic [6:0] dstlb_pte,
    input logic [6:0] ptw_result_pte,
    output logic pmp_load_fault,
    output logic load_unmapped_fault,
    output logic pmp_store_fault_mmu,
    output logic store_unmapped_fault_mmu,
    output logic pmp_ptw_fault,
    output logic pf_load_tlb,
    output logic pf_store_tlb,
    output logic pf_load_ptw,
    output logic pf_store_ptw
);
  // --- PMP checks for loads and MMU-mode stores ---
  // Effective privilege for load/store obeys MSTATUS.MPRV: when MPRV=1 and
  // current privilege is M, accesses use MPP for PMP checks.
  logic [1:0] eff_priv;
  assign eff_priv = (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv)
                    ? csr_bcast.mpp : csr_bcast.priv;

  // The controller supplies the active request's transfer size, not the
  // next LSU request. Addresses here are physical; this block has no state.
  // Treat loads from unmapped physical addresses as access faults (bus error).
  assign load_unmapped_fault = !rapt_pkg::addr_data_span_capable(
      load_addr, load_size_m1, 1'b0);

  // Store PMP (MMU path): store_addr is the translated physical address
  // (meaningful once stlb_hit or immediately after ptw_done).
  // NOTE: bare-mode stores bypass this interface; their PMP enforcement is
  // handled at the IOQ (see backend/lsu/rapt_lsu_ioq.sv).
  // walu is the byte-strobe pattern; popcount-1 = size_m1.
  logic [3:0] store_size_m1;
  always_comb begin
    unique case (store_walu)
      `RAPT_SB_WSTRB: store_size_m1 = 4'd0;
      `RAPT_SH_WSTRB: store_size_m1 = 4'd1;
      `RAPT_SW_WSTRB: store_size_m1 = 4'd3;
      `RAPT_SD_WSTRB: store_size_m1 = 4'd7;
      default:        store_size_m1 = 4'd3;
    endcase
  end
  logic pmp_store_fault_mmu_w;
  logic pmp_store_fault_mmu_r;
  assign pmp_store_fault_mmu = cmo_mgmt
                             ? (pmp_store_fault_mmu_w && pmp_store_fault_mmu_r)
                             : pmp_store_fault_mmu_w;
  // P3: PMA pre-check on the translated store PA. Mirrors load_unmapped_fault
  // -- stops a store to a region with no bus slave from issuing on AXI and
  // hanging the LSU. Bare-mode stores get the same check at the IOQ.
  // Zicbom may maintain a readable ROM alias; stores/AMOs/CBO.ZERO require
  // physical write capability even when the PTE and PMP permit writes.
  assign store_unmapped_fault_mmu = cmo_mgmt
      ? !rapt_pkg::addr_mapped(store_addr) : !rapt_pkg::addr_writable(store_addr);

  // --- Sv32/Sv39 PTE permission check (data access: load/store, not fetch) ---
  // pte bits (rapt_tlb layout): [0]=R [1]=W [2]=X [3]=U [4]=G [5]=A [6]=D.
  // Bit [4]=G (global) does not affect data fault and is not consumed below.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pte_fault_data(input logic [6:0] pte, input logic is_store,
                                          input logic is_cmo, input logic [1:0] priv_eff,
                                          input logic sum_i, input logic mxr_i);
    logic r, w, x, u, a, d;
    logic can_read;
    logic fault;
    r = pte[0];
    w = pte[1];
    x = pte[2];
    u = pte[3];
    a = pte[5];
    d = pte[6];
    can_read = r || (mxr_i && x);
    fault = 1'b0;
    // U-bit rules: U-mode requires U=1; S-mode denies U=1 unless SUM.
    if (priv_eff == `RAPT_PRIV_U) begin
      if (!u) fault = 1'b1;
    end else if (priv_eff == `RAPT_PRIV_S) begin
      if (u && !sum_i) fault = 1'b1;
    end
    if (is_cmo) begin
      // Zicbom access permission is load OR store.  Like a load it requires
      // A, but D is deliberately neither checked nor updated.
      if (!(can_read || w)) fault = 1'b1;
      if (!a) fault = 1'b1;
    end else if (is_store) begin
      if (!w) fault = 1'b1;
      if (!a || !d) fault = 1'b1;
    end else begin
      if (!can_read) fault = 1'b1;
      if (!a) fault = 1'b1;
    end
    return fault;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Perm-fault signals evaluated against currently-visible PTEs.
  assign pf_load_tlb  = tlb_hit  && pte_fault_data(dtlb_pte,  1'b0, 1'b0, eff_priv,
                                                    csr_bcast.sum, csr_bcast.mxr);
  assign pf_store_tlb = stlb_hit && pte_fault_data(dstlb_pte, 1'b1,
                                                    cmo_mgmt, eff_priv,
                                                    csr_bcast.sum, csr_bcast.mxr);
  assign pf_load_ptw  = pte_fault_data(ptw_result_pte, 1'b0, 1'b0, eff_priv,
                                        csr_bcast.sum, csr_bcast.mxr);
  assign pf_store_ptw = pte_fault_data(ptw_result_pte, 1'b1,
                                        cmo_mgmt, eff_priv,
                                        csr_bcast.sum, csr_bcast.mxr);

  // Sv32 reads four-byte PTEs; Sv39 reads eight-byte PTEs. PMP must cover
  // the complete implicit read, including its upper half on RV64.
  // Four independent checks share wiring, not an arbitrated execution unit.
  localparam int LoadCheck = 0, StoreCheck = 1, CmoReadCheck = 2, WalkCheck = 3;
  logic [XLEN-1:0] check_addr[4];
  logic [3:0] check_size_m1[4];
  logic [3:0] check_fault;
  assign check_addr[LoadCheck] = load_addr;
  assign check_addr[StoreCheck] = store_addr;
  assign check_addr[CmoReadCheck] = store_addr;
  assign check_addr[WalkCheck] = ptw_addr;
  assign check_size_m1[LoadCheck] = load_size_m1;
  assign check_size_m1[StoreCheck] = store_size_m1;
  assign check_size_m1[CmoReadCheck] = store_size_m1;
  assign check_size_m1[WalkCheck] = 4'(XLEN / 8 - 1);
  assign pmp_load_fault = check_fault[LoadCheck];
  assign pmp_store_fault_mmu_w = check_fault[StoreCheck];
  assign pmp_store_fault_mmu_r = check_fault[CmoReadCheck];
  assign pmp_ptw_fault = check_fault[WalkCheck]
      || !rapt_pkg::addr_ptw_readable(ptw_addr, 4'(XLEN / 8 - 1));

  for (genvar port_idx = 0; port_idx < 4; port_idx++) begin : g_pmp
    rapt_pmp #(
        .XLEN(XLEN)
    ) u_check (
        .addr(check_addr[port_idx]),
        .size_m1(check_size_m1[port_idx]),
        .priv(eff_priv),
        .op_r(port_idx != StoreCheck),
        .op_w(port_idx == StoreCheck),
        .op_x(1'b0),
        .pmp_raw_addr(pmp_state.pmp_raw_addr),
        .pmp_napot_mask(pmp_state.pmp_napot_mask),
        .pmp_cfg_r(pmp_state.pmp_cfg_r),
        .pmp_cfg_w(pmp_state.pmp_cfg_w),
        .pmp_cfg_x(pmp_state.pmp_cfg_x),
        .pmp_cfg_l(pmp_state.pmp_cfg_l),
        .pmp_mode_off(pmp_state.pmp_mode_off),
        .pmp_mode_tor(pmp_state.pmp_mode_tor),
        .pmp_mode_na4(pmp_state.pmp_mode_na4),
        .pmp_mode_napot(pmp_state.pmp_mode_napot),
        .fault(check_fault[port_idx]),
        .fault_lo_o()
    );
  end

endmodule
/* verilator lint_on PINCONNECTEMPTY */
