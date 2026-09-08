`include "rapt.svh"
`include "rapt_if.svh"

// Fetch permissions are combinational. Fault ownership, SRAM readiness and
// refill/PTW sequencing remain in the instruction-cache controller.
module rapt_l1i_access #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit Lookahead = 1'b1
) (
    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,
    input logic [XLEN-1:0] pc_ifu,
    ptw_araddr,
    lookahead_n1_addr,
    lookahead_n2_addr,
    input logic sram_data_ready,
    is_c,
    tlb_hit,
    input logic [6:0] itlb_pte,
    ptw_result_pte,
    output logic pf_fetch_tlb,
    pf_fetch_ptw,
    output wire pmp_fetch_pmp_fault,
    pmp_fetch_fault_lo,
    pmp_iptw_fault,
    output wire pmp_n1_fetch_fault,
    pmp_n2_fetch_fault
);
  // Sv32/Sv39 fetch permission check: execute must be allowed for current priv.
  // itlb_pte = {D,A,G,U,X,W,R}; only X/U/A bits influence fetch fault.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pte_fault_fetch(input logic [6:0] pte, input logic [1:0] priv_i);
    /* verilator lint_on UNUSEDSIGNAL */
    logic x, u, a;
    logic fault;
    x = pte[2];
    u = pte[3];
    a = pte[5];
    fault = 1'b0;
    if (!x) fault = 1'b1;
    if (!a) fault = 1'b1;
    if (priv_i == `RAPT_PRIV_U && !u) fault = 1'b1;
    if (priv_i == `RAPT_PRIV_S && u) fault = 1'b1;  // no SUM on fetch
    return fault;
  endfunction

  assign pf_fetch_tlb = tlb_hit && pte_fault_fetch(itlb_pte, csr_bcast.priv);
  assign pf_fetch_ptw = pte_fault_fetch(ptw_result_pte, csr_bcast.priv);


  localparam int Checks = Lookahead ? 4 : 2;
  wire [XLEN-1:0] addr[4];
  wire [3:0] fault;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [3:0] fault_lo;
  /* verilator lint_on UNUSEDSIGNAL */
  assign addr[0] = pc_ifu;
  assign addr[1] = ptw_araddr;
  assign addr[2] = lookahead_n1_addr;
  assign addr[3] = lookahead_n2_addr;
  assign pmp_fetch_pmp_fault = fault[0];
  assign pmp_fetch_fault_lo = fault_lo[0];
  // The existing access-fault output combines PMP with the platform's PTE
  // read PMA so the controller blocks the bus and preserves fetch fault VA.
  assign pmp_iptw_fault = fault[1]
      || !rapt_pkg::addr_ptw_readable(ptw_araddr, 4'(XLEN / 8 - 1));
  assign pmp_n1_fetch_fault = fault[2]
      || (Lookahead && !rapt_pkg::addr_executable(lookahead_n1_addr, 4'd3));
  assign pmp_n2_fetch_fault = fault[3]
      || (Lookahead && !rapt_pkg::addr_executable(lookahead_n2_addr, 4'd3));
  for (genvar port_idx = 0; port_idx < 4; port_idx++) begin : g_check
    if (port_idx < Checks) begin : g_active
      rapt_pmp #(
          .XLEN(XLEN)
      ) u_pmp (
          .addr(addr[port_idx]),
          .size_m1(port_idx == 1 ? 4'(XLEN / 8 - 1)
              : (port_idx == 0 && sram_data_ready && is_c ? 4'd1 : 4'd3)),
          .priv(csr_bcast.priv),
          .op_r(port_idx == 1),
          .op_w(1'b0),
          .op_x(port_idx != 1),
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
          .fault(fault[port_idx]),
          .fault_lo_o(fault_lo[port_idx])
      );
    end else begin : g_unused
      assign fault[port_idx] = 1'b0;
      assign fault_lo[port_idx] = 1'b0;
    end
  end
endmodule
