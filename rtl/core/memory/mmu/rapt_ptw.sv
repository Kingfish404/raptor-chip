`include "rapt.svh"

// Read-only page-table walker.
// RV32 uses Sv32 two-level page tables. RV64 uses Sv39 (and optional two-stage
// Sv39 x Sv39x4 under RAPT_H_EXTENSION). RVA20S64/RVA23S64 mandate Svade: a
// leaf with A=0, or a store leaf with D=0, raises a page fault without writing
// page tables.
module rapt_ptw #(
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,
    input reset,

    input logic req_valid,
    input logic kill,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [XLEN-1:0] vaddr,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn,
    input logic mmu_en,
    input logic pbmte,
    input logic sbe,
    input logic req_store,
`ifdef RAPT_H_EXTENSION
    input logic guest_en,
    input logic vs_en,
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] vsatp_ppn,
    input logic g_en,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [`RAPT_CSR_SATP_PPN_W-1:0] hgatp_ppn,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic vs_priv_s,
    input logic vs_sum,
    input logic vs_mxr,
    input logic vs_pbmte,
    input logic g_mxr,
    input logic req_exec,
`endif

    output logic bus_arvalid,
    output logic [XLEN-1:0] bus_araddr,
    input  logic bus_arready,
    input  logic bus_rvalid,
    input  logic [XLEN-1:0] bus_rdata,

    output logic done,
    output logic fault,
    // An implicit PTE address exceeds the implemented physical address width.
    output logic access_fault,
`ifdef RAPT_H_EXTENSION
    output logic guest_fault,
    output logic [XLEN-1:2] fault_gpa,
    output logic fault_ptw,
    output logic [2:0] result_g_perm,
`endif
    // Preserve every architectural PPN bit until the requester has checked
    // page permissions and PA representability before filling a narrow TLB.
    output logic [XLEN-1:10] result_ptag,
    output logic [XLEN-1:12] result_vtag,
    // pte flags: {D,A,G,U,X,W,R} (bits 7..1 of PTE); valid when done=1
    output logic [6:0] result_pte,
    // Leaf PBMT; valid together with result_pte on done. Sv32 always uses PMA.
    output logic [1:0] result_pbmt,
    // Leaf level: 0 = 4 KiB, 1 = megapage, 2 = Sv39 gigapage, 3 = 64 KiB NAPOT.
    output logic [1:0] result_level,

    output logic busy
);

  // A global non-leaf marks every descendant mapping global. Keep this
  // state local to the accepted walk; IDLE resets it before any new request.
  logic global_q;
  logic pte_address_valid;
  logic [6:0] walk_pte_flags;
  assign walk_pte_flags = {bus_rdata[7:6], bus_rdata[5] | global_q, bus_rdata[4:1]};

`ifdef RAPT_RV64
`ifdef RAPT_H_EXTENSION
  typedef enum logic [3:0] {
    IDLE        = 4'd0,
    LVL2_REQ    = 4'd1,
    LVL2_WAIT   = 4'd2,
    LVL1_REQ    = 4'd3,
    LVL1_WAIT   = 4'd4,
    LVL0_REQ    = 4'd5,
    LVL0_WAIT   = 4'd6,
    G_LVL2_REQ  = 4'd7,
    G_LVL2_WAIT = 4'd8,
    G_LVL1_REQ  = 4'd9,
    G_LVL1_WAIT = 4'd10,
    G_LVL0_REQ  = 4'd11,
    G_LVL0_WAIT = 4'd12
  } ptw_state_t;
`else
  typedef enum logic [2:0] {
    IDLE      = 3'b000,
    LVL2_REQ  = 3'b001,
    LVL2_WAIT = 3'b010,
    LVL1_REQ  = 3'b011,
    LVL1_WAIT = 3'b100,
    LVL0_REQ  = 3'b101,
    LVL0_WAIT = 3'b110
  } ptw_state_t;
`endif

  ptw_state_t state;

  logic [8:0] vpn1, vpn0;
  // One canonical Sv39 VPN owns the walk. Lower-level VPNs are views of it,
  // not separately stored copies; the upper VA bits are sign extension.
  logic [38:12] vtag_q;
  assign vpn1 = vtag_q[29:21];
  assign vpn0 = vtag_q[20:12];
  // Sv39 encodes PTE addresses with up to 56 bits. Keep the architectural
  // page number and PTE index here; the requester rejects addresses outside
  // the implemented platform PA range before issuing a bus transaction.
  logic [55:3] pte_word_addr;
  logic req_store_q;
  logic pbmte_q;
  logic killed;

`ifdef RAPT_H_EXTENSION
  logic guest_en_q;
  logic vs_en_q;
  logic g_en_q;
  logic [`RAPT_CSR_SATP_PPN_W-1:2] hgatp_ppn_q;
  logic vs_priv_s_q;
  logic vs_sum_q;
  logic vs_mxr_q;
  logic vs_pbmte_q;
  logic g_mxr_q;
  logic req_exec_q;
  logic [11:2] va_low_q;
  logic g_implicit_q;
  logic [1:0] vs_next_lvl_q;
  logic [40:2] g_gpa_q;
  logic [6:0] vs_pte_q;
  logic [1:0] vs_pbmt_q;
  logic [1:0] vs_level_q;
  wire in_g_req = state == G_LVL2_REQ || state == G_LVL1_REQ || state == G_LVL0_REQ;
  wire in_g_wait = state == G_LVL2_WAIT || state == G_LVL1_WAIT || state == G_LVL0_WAIT;
  wire in_g_lvl0_wait = state == G_LVL0_WAIT;
  wire active_pbmte = (guest_en_q && !in_g_wait) ? vs_pbmte_q : pbmte_q;
`else
  wire in_g_req = 1'b0;
  wire in_g_lvl0_wait = 1'b0;
  wire active_pbmte = pbmte_q;
`endif
  wire is_lvl0_wait = state == LVL0_WAIT || in_g_lvl0_wait;
  wire va_valid = vaddr[63:39] == {25{vaddr[38]}};

  logic [63:0] pte_data;
  logic pte_v;
  logic pte_r;
  logic pte_w;
  logic pte_x;
  logic pte_u;
  logic pte_a;
  logic pte_d;
  logic pte_leaf;
  logic pte_napot;
  logic pte_reserved;
  logic pte_needs_ad_update;
  assign pte_data = bus_rdata[63:0];
  assign pte_v = pte_data[0];
  assign pte_r = pte_data[1];
  assign pte_w = pte_data[2];
  assign pte_x = pte_data[3];
  assign pte_u = pte_data[4];
  assign pte_a = pte_data[6];
  assign pte_d = pte_data[7];
  assign pte_leaf = pte_r || pte_x;
  assign pte_napot = pte_data[63];
  assign pte_reserved = (pte_w && !pte_r)
                      || (pte_napot && (!rapt_pkg::SvnapotEnable || !pte_leaf
                                        || !is_lvl0_wait || pte_data[13:10] != 4'b1000))
                      || (pte_data[60:54] != 7'b0)
                      || (pte_data[62:61] == 2'b11)
                      || ((pte_data[62:61] != 2'b00) && (!active_pbmte || !pte_leaf));
  assign pte_needs_ad_update = !pte_a || (req_store_q && !pte_d);

  localparam int Rv64PtagPadW = XLEN - 54;
  logic [XLEN-1:10] ptag_lvl2;
  logic [XLEN-1:10] ptag_lvl1;
  logic [XLEN-1:10] ptag_lvl0;
  assign ptag_lvl2 = {{Rv64PtagPadW{1'b0}}, pte_data[53:28], vpn1, vpn0};
  assign ptag_lvl1 = {{Rv64PtagPadW{1'b0}}, pte_data[53:19], vpn0};
  assign ptag_lvl0 = (rapt_pkg::SvnapotEnable && pte_napot)
      ? {{Rv64PtagPadW{1'b0}}, pte_data[53:14], vpn0[3:0]}
      : {{Rv64PtagPadW{1'b0}}, pte_data[53:10]};

`ifdef RAPT_H_EXTENSION
  // Fetch requesters tie vs_sum low, so SUM here only grants HLVX access to a
  // U page, as the L1D TLB-hit check and the reference model do.
  logic vs_priv_ok, vs_op_ok, vs_leaf_ok;
  assign vs_priv_ok = vs_priv_s_q ? (!pte_u || vs_sum_q) : pte_u;
  assign vs_op_ok = req_store_q ? pte_w
      : (req_exec_q ? pte_x : (pte_r || (pte_x && vs_mxr_q)));
  assign vs_leaf_ok = vs_priv_ok && vs_op_ok && !pte_needs_ad_update;

  logic [XLEN-1:10] g_ptag_lvl2, g_ptag_lvl1, g_ptag_lvl0;
  assign g_ptag_lvl2 = {{Rv64PtagPadW{1'b0}}, pte_data[53:28], g_gpa_q[29:12]};
  assign g_ptag_lvl1 = {{Rv64PtagPadW{1'b0}}, pte_data[53:19], g_gpa_q[20:12]};
  assign g_ptag_lvl0 = (rapt_pkg::SvnapotEnable && pte_napot)
      ? {{Rv64PtagPadW{1'b0}}, pte_data[53:14], g_gpa_q[15:12]}
      : {{Rv64PtagPadW{1'b0}}, pte_data[53:10]};

  wire g_store = !g_implicit_q && req_store_q;
  wire g_exec = !g_implicit_q && req_exec_q;
  wire g_op_ok = g_store ? pte_w
      : (g_exec ? pte_x : (pte_r || (pte_x && !g_implicit_q && g_mxr_q)));
  wire g_leaf_ok = pte_u && pte_a && (!g_store || pte_d) && g_op_ok;
  wire [2:0] g_leaf_perm = {pte_w && pte_d, pte_x && pte_a, pte_r && pte_a};

  logic [55:2] vs_step_gpa;
  always_comb begin
    unique case (state)
      IDLE: vs_step_gpa = {vsatp_ppn, vaddr[38:30], 1'b0};
      LVL2_WAIT:
      vs_step_gpa = pte_leaf ? {ptag_lvl2[53:10], va_low_q} : {pte_data[53:10], vpn1, 1'b0};
      LVL1_WAIT:
      vs_step_gpa = pte_leaf ? {ptag_lvl1[53:10], va_low_q} : {pte_data[53:10], vpn0, 1'b0};
      default: vs_step_gpa = {ptag_lvl0[53:10], va_low_q};
    endcase
  end
  wire vs_step_gpa_overflow = vs_step_gpa[55:41] != 15'd0;
`endif

  assign busy = (state != IDLE);
  assign bus_arvalid = !kill && pte_address_valid
      && (state == LVL2_REQ || state == LVL1_REQ || state == LVL0_REQ || in_g_req);
  assign bus_araddr = XLEN'({pte_word_addr, 3'b000});
  assign pte_address_valid = pte_word_addr == 53'((`RAPT_PADDR_BITS - 3)'(pte_word_addr));
`ifdef RAPT_H_EXTENSION
  assign result_vtag = (guest_en_q && !vs_en_q) ? {23'd0, g_gpa_q[40:12]} : (XLEN - 12)'($signed(
      vtag_q
  ));
`else
  assign result_vtag = (XLEN - 12)'($signed(vtag_q));
`endif

  // SBE is WARL-zero in rapt today. Keep the port so the requester interface
  // stays uniform across RV32/RV64.
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_sbe;
  assign _unused_sbe = sbe | pte_u;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      done <= 1'b0;
      fault <= 1'b0;
      access_fault <= 1'b0;
      killed <= 1'b0;
      global_q <= 1'b0;
      pbmte_q <= 1'b0;
      result_pbmt <= 2'b00;
      result_level <= 2'd0;
`ifdef RAPT_H_EXTENSION
      guest_fault <= 1'b0;
      fault_gpa <= '0;
      fault_ptw <= 1'b0;
      result_g_perm <= 3'b111;
      guest_en_q <= 1'b0;
      vs_en_q <= 1'b0;
      g_en_q <= 1'b0;
`endif
    end else begin
      done <= 1'b0;
      fault <= 1'b0;
      access_fault <= 1'b0;
`ifdef RAPT_H_EXTENSION
      guest_fault <= 1'b0;
`endif

      unique case (state)
        IDLE: begin
          killed <= 1'b0;
          global_q <= 1'b0;
          if (req_valid && mmu_en && !kill) begin
            req_store_q <= req_store;
            pbmte_q <= pbmte;
`ifdef RAPT_H_EXTENSION
            guest_en_q <= guest_en;
            vs_en_q <= guest_en && vs_en;
            g_en_q <= guest_en && g_en;
            hgatp_ppn_q <= hgatp_ppn[`RAPT_CSR_SATP_PPN_W-1:2];
            vs_priv_s_q <= vs_priv_s;
            vs_sum_q <= vs_sum;
            vs_mxr_q <= vs_mxr;
            vs_pbmte_q <= vs_pbmte;
            g_mxr_q <= g_mxr;
            req_exec_q <= req_exec;
            va_low_q <= vaddr[11:2];
            if (guest_en && !vs_en) begin
              if (!g_en) begin
                g_gpa_q <= vaddr[40:2];
                result_ptag <= {{Rv64PtagPadW{1'b0}}, vaddr[55:12]};
                result_level <= 2'd0;
                result_pte <= 7'b111_1111;
                result_pbmt <= 2'b00;
                result_g_perm <= 3'b111;
                done <= 1'b1;
              end else if (vaddr[63:41] != 23'd0) begin
                fault <= 1'b1;
                guest_fault <= 1'b1;
                fault_ptw <= 1'b0;
                fault_gpa <= vaddr[63:2];
              end else begin
                g_implicit_q <= 1'b0;
                g_gpa_q <= vaddr[40:2];
                pte_word_addr <= {hgatp_ppn[43:2], vaddr[40:30]};
                state <= G_LVL2_REQ;
              end
            end else if (!va_valid) begin
              fault <= 1'b1;
            end else begin
              vtag_q <= vaddr[38:12];
              if (guest_en && g_en) begin
                if (vs_step_gpa_overflow) begin
                  fault <= 1'b1;
                  guest_fault <= 1'b1;
                  fault_ptw <= 1'b1;
                  fault_gpa <= {8'd0, vs_step_gpa};
                end else begin
                  g_implicit_q <= 1'b1;
                  vs_next_lvl_q <= 2'd2;
                  g_gpa_q <= vs_step_gpa[40:2];
                  pte_word_addr <= {hgatp_ppn[43:2], vs_step_gpa[40:30]};
                  state <= G_LVL2_REQ;
                end
              end else begin
                pte_word_addr <= {guest_en ? vsatp_ppn : satp_ppn, vaddr[38:30]};
                state <= LVL2_REQ;
              end
            end
`else
            // Sv39 effective addresses must be the sign extension of bit 38.
            // Reject a non-canonical address before issuing any implicit PTE
            // access so the requester reports the original virtual address.
            if (!va_valid) begin
              fault <= 1'b1;
            end else begin
              vtag_q <= vaddr[38:12];
              pte_word_addr <= {satp_ppn, vaddr[38:30]};
              state <= LVL2_REQ;
            end
`endif
          end
        end
        LVL2_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= LVL2_WAIT;
        end
        LVL2_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved) begin
              fault <= 1'b1;
              state <= IDLE;
            end else if (pte_leaf) begin
              if (pte_data[27:10] != 18'h0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
`ifdef RAPT_H_EXTENSION
                if (vs_en_q) begin
                  if (!vs_leaf_ok) begin
                    fault <= 1'b1;
                    state <= IDLE;
                  end else if (!g_en_q) begin
                    result_ptag <= ptag_lvl2;
                    result_level <= 2'd2;
                    result_pte <= walk_pte_flags;
                    result_pbmt <= pte_data[62:61];
                    result_g_perm <= 3'b111;
                    done <= 1'b1;
                    state <= IDLE;
                  end else if (vs_step_gpa_overflow) begin
                    fault <= 1'b1;
                    guest_fault <= 1'b1;
                    fault_ptw <= 1'b0;
                    fault_gpa <= {8'd0, vs_step_gpa};
                    state <= IDLE;
                  end else begin
                    vs_pte_q <= walk_pte_flags;
                    vs_pbmt_q <= pte_data[62:61];
                    vs_level_q <= 2'd2;
                    g_implicit_q <= 1'b0;
                    g_gpa_q <= vs_step_gpa[40:2];
                    pte_word_addr <= {hgatp_ppn_q, vs_step_gpa[40:30]};
                    state <= G_LVL2_REQ;
                  end
                end else begin
                  result_ptag <= ptag_lvl2;
                  result_level <= 2'd2;
                  result_pte <= walk_pte_flags;
                  result_pbmt <= pte_data[62:61];
                  result_g_perm <= 3'b111;
                  if (pte_needs_ad_update) fault <= 1'b1;
                  else done <= 1'b1;
                  state <= IDLE;
                end
`else
                result_ptag <= ptag_lvl2;
                result_level <= 2'd2;
                result_pte <= walk_pte_flags;
                result_pbmt <= pte_data[62:61];
                if (pte_needs_ad_update) fault <= 1'b1;
                else done <= 1'b1;
                state <= IDLE;
`endif
              end
            end else begin
              if ({pte_data[7:6], pte_data[4]} != 3'b0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                global_q <= global_q | pte_data[5];
`ifdef RAPT_H_EXTENSION
                if (g_en_q) begin
                  if (vs_step_gpa_overflow) begin
                    fault <= 1'b1;
                    guest_fault <= 1'b1;
                    fault_ptw <= 1'b1;
                    fault_gpa <= {8'd0, vs_step_gpa};
                    state <= IDLE;
                  end else begin
                    g_implicit_q <= 1'b1;
                    vs_next_lvl_q <= 2'd1;
                    g_gpa_q <= vs_step_gpa[40:2];
                    pte_word_addr <= {hgatp_ppn_q, vs_step_gpa[40:30]};
                    state <= G_LVL2_REQ;
                  end
                end else begin
                  pte_word_addr <= {pte_data[53:10], vpn1};
                  state <= LVL1_REQ;
                end
`else
                pte_word_addr <= {pte_data[53:10], vpn1};
                state <= LVL1_REQ;
`endif
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        LVL1_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= LVL1_WAIT;
        end
        LVL1_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved) begin
              fault <= 1'b1;
              state <= IDLE;
            end else if (pte_leaf) begin
              if (pte_data[18:10] != 9'h0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
`ifdef RAPT_H_EXTENSION
                if (vs_en_q) begin
                  if (!vs_leaf_ok) begin
                    fault <= 1'b1;
                    state <= IDLE;
                  end else if (!g_en_q) begin
                    result_ptag <= ptag_lvl1;
                    result_level <= 2'd1;
                    result_pte <= walk_pte_flags;
                    result_pbmt <= pte_data[62:61];
                    result_g_perm <= 3'b111;
                    done <= 1'b1;
                    state <= IDLE;
                  end else if (vs_step_gpa_overflow) begin
                    fault <= 1'b1;
                    guest_fault <= 1'b1;
                    fault_ptw <= 1'b0;
                    fault_gpa <= {8'd0, vs_step_gpa};
                    state <= IDLE;
                  end else begin
                    vs_pte_q <= walk_pte_flags;
                    vs_pbmt_q <= pte_data[62:61];
                    vs_level_q <= 2'd1;
                    g_implicit_q <= 1'b0;
                    g_gpa_q <= vs_step_gpa[40:2];
                    pte_word_addr <= {hgatp_ppn_q, vs_step_gpa[40:30]};
                    state <= G_LVL2_REQ;
                  end
                end else begin
                  result_ptag <= ptag_lvl1;
                  result_level <= 2'd1;
                  result_pte <= walk_pte_flags;
                  result_pbmt <= pte_data[62:61];
                  result_g_perm <= 3'b111;
                  if (pte_needs_ad_update) fault <= 1'b1;
                  else done <= 1'b1;
                  state <= IDLE;
                end
`else
                result_ptag <= ptag_lvl1;
                result_level <= 2'd1;
                result_pte <= walk_pte_flags;
                result_pbmt <= pte_data[62:61];
                if (pte_needs_ad_update) fault <= 1'b1;
                else done <= 1'b1;
                state <= IDLE;
`endif
              end
            end else begin
              if ({pte_data[7:6], pte_data[4]} != 3'b0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                global_q <= global_q | pte_data[5];
`ifdef RAPT_H_EXTENSION
                if (g_en_q) begin
                  if (vs_step_gpa_overflow) begin
                    fault <= 1'b1;
                    guest_fault <= 1'b1;
                    fault_ptw <= 1'b1;
                    fault_gpa <= {8'd0, vs_step_gpa};
                    state <= IDLE;
                  end else begin
                    g_implicit_q <= 1'b1;
                    vs_next_lvl_q <= 2'd0;
                    g_gpa_q <= vs_step_gpa[40:2];
                    pte_word_addr <= {hgatp_ppn_q, vs_step_gpa[40:30]};
                    state <= G_LVL2_REQ;
                  end
                end else begin
                  pte_word_addr <= {pte_data[53:10], vpn0};
                  state <= LVL0_REQ;
                end
`else
                pte_word_addr <= {pte_data[53:10], vpn0};
                state <= LVL0_REQ;
`endif
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        LVL0_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= LVL0_WAIT;
        end
        LVL0_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved || !pte_leaf) begin
              fault <= 1'b1;
              state <= IDLE;
            end else begin
`ifdef RAPT_H_EXTENSION
              if (vs_en_q) begin
                if (!vs_leaf_ok) begin
                  fault <= 1'b1;
                  state <= IDLE;
                end else if (!g_en_q) begin
                  result_ptag <= ptag_lvl0;
                  result_level <= (rapt_pkg::SvnapotEnable && pte_napot) ? 2'd3 : 2'd0;
                  result_pte <= walk_pte_flags;
                  result_pbmt <= pte_data[62:61];
                  result_g_perm <= 3'b111;
                  done <= 1'b1;
                  state <= IDLE;
                end else if (vs_step_gpa_overflow) begin
                  fault <= 1'b1;
                  guest_fault <= 1'b1;
                  fault_ptw <= 1'b0;
                  fault_gpa <= {8'd0, vs_step_gpa};
                  state <= IDLE;
                end else begin
                  vs_pte_q <= walk_pte_flags;
                  vs_pbmt_q <= pte_data[62:61];
                  vs_level_q <= (rapt_pkg::SvnapotEnable && pte_napot) ? 2'd3 : 2'd0;
                  g_implicit_q <= 1'b0;
                  g_gpa_q <= vs_step_gpa[40:2];
                  pte_word_addr <= {hgatp_ppn_q, vs_step_gpa[40:30]};
                  state <= G_LVL2_REQ;
                end
              end else begin
                result_ptag <= ptag_lvl0;
                result_level <= (rapt_pkg::SvnapotEnable && pte_napot) ? 2'd3 : 2'd0;
                result_pte <= walk_pte_flags;
                result_pbmt <= pte_data[62:61];
                result_g_perm <= 3'b111;
                if (pte_needs_ad_update) fault <= 1'b1;
                else done <= 1'b1;
                state <= IDLE;
              end
`else
              result_ptag <= ptag_lvl0;
              result_level <= (rapt_pkg::SvnapotEnable && pte_napot) ? 2'd3 : 2'd0;
              result_pte <= walk_pte_flags;
              result_pbmt <= pte_data[62:61];
              if (pte_needs_ad_update) fault <= 1'b1;
              else done <= 1'b1;
              state <= IDLE;
`endif
            end
          end else if (kill) killed <= 1'b1;
        end
`ifdef RAPT_H_EXTENSION
        G_LVL2_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= G_LVL2_WAIT;
        end
        G_LVL2_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved) begin
              fault <= 1'b1;
              guest_fault <= 1'b1;
              fault_ptw <= g_implicit_q;
              fault_gpa <= {23'd0, g_gpa_q};
              state <= IDLE;
            end else if (pte_leaf) begin
              if (pte_data[27:10] != 18'h0 || !g_leaf_ok) begin
                fault <= 1'b1;
                guest_fault <= 1'b1;
                fault_ptw <= g_implicit_q;
                fault_gpa <= {23'd0, g_gpa_q};
                state <= IDLE;
              end else if (g_implicit_q) begin
                pte_word_addr <= {g_ptag_lvl2[53:10], g_gpa_q[11:3]};
                unique case (vs_next_lvl_q)
                  2'd2: state <= LVL2_REQ;
                  2'd1: state <= LVL1_REQ;
                  default: state <= LVL0_REQ;
                endcase
              end else begin
                result_ptag <= g_ptag_lvl2;
                result_level <= vs_en_q ? vs_level_q : 2'd2;
                result_pte <= vs_en_q ? vs_pte_q : 7'b111_1111;
                result_pbmt <= (vs_en_q && vs_pbmt_q != 2'b00) ? vs_pbmt_q : pte_data[62:61];
                result_g_perm <= g_leaf_perm;
                done <= 1'b1;
                state <= IDLE;
              end
            end else if ({pte_data[7:6], pte_data[4]} != 3'b0) begin
              fault <= 1'b1;
              guest_fault <= 1'b1;
              fault_ptw <= g_implicit_q;
              fault_gpa <= {23'd0, g_gpa_q};
              state <= IDLE;
            end else begin
              pte_word_addr <= {pte_data[53:10], g_gpa_q[29:21]};
              state <= G_LVL1_REQ;
            end
          end else if (kill) killed <= 1'b1;
        end
        G_LVL1_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= G_LVL1_WAIT;
        end
        G_LVL1_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved) begin
              fault <= 1'b1;
              guest_fault <= 1'b1;
              fault_ptw <= g_implicit_q;
              fault_gpa <= {23'd0, g_gpa_q};
              state <= IDLE;
            end else if (pte_leaf) begin
              if (pte_data[18:10] != 9'h0 || !g_leaf_ok) begin
                fault <= 1'b1;
                guest_fault <= 1'b1;
                fault_ptw <= g_implicit_q;
                fault_gpa <= {23'd0, g_gpa_q};
                state <= IDLE;
              end else if (g_implicit_q) begin
                pte_word_addr <= {g_ptag_lvl1[53:10], g_gpa_q[11:3]};
                unique case (vs_next_lvl_q)
                  2'd2: state <= LVL2_REQ;
                  2'd1: state <= LVL1_REQ;
                  default: state <= LVL0_REQ;
                endcase
              end else begin
                result_ptag <= g_ptag_lvl1;
                result_level <= vs_en_q ? vs_level_q : 2'd1;
                result_pte <= vs_en_q ? vs_pte_q : 7'b111_1111;
                result_pbmt <= (vs_en_q && vs_pbmt_q != 2'b00) ? vs_pbmt_q : pte_data[62:61];
                result_g_perm <= g_leaf_perm;
                done <= 1'b1;
                state <= IDLE;
              end
            end else if ({pte_data[7:6], pte_data[4]} != 3'b0) begin
              fault <= 1'b1;
              guest_fault <= 1'b1;
              fault_ptw <= g_implicit_q;
              fault_gpa <= {23'd0, g_gpa_q};
              state <= IDLE;
            end else begin
              pte_word_addr <= {pte_data[53:10], g_gpa_q[20:12]};
              state <= G_LVL0_REQ;
            end
          end else if (kill) killed <= 1'b1;
        end
        G_LVL0_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= G_LVL0_WAIT;
        end
        G_LVL0_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved || !pte_leaf || !g_leaf_ok) begin
              fault <= 1'b1;
              guest_fault <= 1'b1;
              fault_ptw <= g_implicit_q;
              fault_gpa <= {23'd0, g_gpa_q};
              state <= IDLE;
            end else if (g_implicit_q) begin
              pte_word_addr <= {g_ptag_lvl0[53:10], g_gpa_q[11:3]};
              unique case (vs_next_lvl_q)
                2'd2: state <= LVL2_REQ;
                2'd1: state <= LVL1_REQ;
                default: state <= LVL0_REQ;
              endcase
            end else begin
              result_ptag <= g_ptag_lvl0;
              result_level <= vs_en_q
                  ? vs_level_q
                  : ((rapt_pkg::SvnapotEnable && pte_napot) ? 2'd3 : 2'd0);
              result_pte <= vs_en_q ? vs_pte_q : 7'b111_1111;
              result_pbmt <= (vs_en_q && vs_pbmt_q != 2'b00) ? vs_pbmt_q : pte_data[62:61];
              result_g_perm <= g_leaf_perm;
              done <= 1'b1;
              state <= IDLE;
            end
          end else if (kill) killed <= 1'b1;
        end
`endif
        default: state <= IDLE;
      endcase
    end
  end

`ifdef RAPT_SVA_ACTIVE
`ifdef RAPT_H_EXTENSION
  wire ptw_in_wait_state = state inside {LVL2_WAIT, LVL1_WAIT, LVL0_WAIT,
                                         G_LVL2_WAIT, G_LVL1_WAIT, G_LVL0_WAIT};
`else
  wire ptw_in_wait_state = state inside {LVL2_WAIT, LVL1_WAIT, LVL0_WAIT};
`endif
  wire ptw_killed_drain = (killed || kill) && ptw_in_wait_state && bus_rvalid;
`endif

  always_ff @(posedge clock) begin
    if (!reset) begin
      `RAPT_SVA_IMM(PTW_READ_RESPONSE_STATE, !bus_rvalid || ptw_in_wait_state)
      `RAPT_SVA_IMM(PTW_NO_REQUEST_DURING_RESPONSE, !(bus_arvalid && bus_rvalid))
    end
  end

  `RAPT_SVA_NEXT(clock, reset, PTW_KILLED_DRAIN_NO_COMPLETE, ptw_killed_drain, !done && !fault)
`else
  assign result_pbmt = 2'b00;
`ifdef RAPT_H_EXTENSION
  assign guest_fault = 1'b0;
  assign fault_gpa = '0;
  assign fault_ptw = 1'b0;
  assign result_g_perm = 3'b111;
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_h_rv32;
  assign _unused_h_rv32 = guest_en | vs_en | (|vsatp_ppn) | g_en | (|hgatp_ppn)
                        | vs_priv_s | vs_sum | vs_mxr | vs_pbmte | g_mxr | req_exec;
  /* verilator lint_on UNUSEDSIGNAL */
`endif
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_pbmte;
  assign _unused_pbmte = pbmte;
  /* verilator lint_on UNUSEDSIGNAL */
  typedef enum logic [2:0] {
    IDLE      = 3'b000,
    LVL1_REQ  = 3'b001,
    LVL1_WAIT = 3'b010,
    LVL0_REQ  = 3'b011,
    LVL0_WAIT = 3'b100
  } ptw_state_t;

  ptw_state_t state;

  logic [9:0] vpn1, vpn0;
  // Retain Sv32's full PTE address until its high bits have been checked.
  // The 32-bit bus must never issue an aliased read of an unsupported frame.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:2] pte_word_addr;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [31:0] pte_raw;
  assign pte_raw = bus_rdata[31:0];
  logic req_store_q;
  logic killed;

  // SBE: WARL-zero. Keep the port for interface stability.
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_sbe;
  assign _unused_sbe = sbe;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] pte_data;
  assign pte_data = pte_raw;

  assign busy = (state != IDLE);
  assign bus_arvalid = !kill && pte_address_valid && (state == LVL1_REQ || state == LVL0_REQ);
  assign bus_araddr = XLEN'({pte_word_addr, 2'b00});
  assign pte_address_valid = pte_word_addr == 32'(30'(pte_word_addr));

  logic pte_v;
  logic pte_r;
  logic pte_w;
  logic pte_x;
  logic pte_a;
  logic pte_d;
  logic pte_leaf;
  logic pte_reserved;
  logic pte_needs_ad_update;
  logic [XLEN-1:10] ptag_lvl1;
  logic [XLEN-1:10] ptag_lvl0;
  assign pte_v = pte_data[0];
  assign pte_r = pte_data[1];
  assign pte_w = pte_data[2];
  assign pte_x = pte_data[3];
  assign pte_a = pte_data[6];
  assign pte_d = pte_data[7];
  assign pte_leaf = pte_r || pte_x;
  assign pte_reserved = pte_w && !pte_r;
  assign pte_needs_ad_update = !pte_a || (req_store_q && !pte_d);

  assign ptag_lvl1 = {pte_data[31:20], vpn0};
  assign ptag_lvl0 = pte_data[31:10];

  assign result_vtag = {vpn1, vpn0};

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      done  <= 1'b0;
      fault <= 1'b0;
      access_fault <= 1'b0;
      killed <= 1'b0;
      global_q <= 1'b0;
      result_level <= 2'd0;
    end else begin
      done  <= 1'b0;
      fault <= 1'b0;
      access_fault <= 1'b0;

      unique case (state)
        IDLE: begin
          killed <= 1'b0;
          global_q <= 1'b0;
          if (req_valid && mmu_en && !kill) begin
            vpn1  <= vaddr[31:22];
            vpn0  <= vaddr[21:12];
            req_store_q <= req_store;
            pte_word_addr <= {satp_ppn, vaddr[31:22]};
            state <= LVL1_REQ;
          end
        end
        LVL1_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= LVL1_WAIT;
        end
        LVL1_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved) begin
              fault <= 1'b1;
              state <= IDLE;
            end else if (pte_leaf) begin
              if (pte_data[19:10] != 10'h0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                result_ptag <= ptag_lvl1;
                result_level <= 2'd1;
                result_pte  <= walk_pte_flags;
                if (pte_needs_ad_update) begin
                  fault <= 1'b1;
                  state <= IDLE;
                end else begin
                  done <= 1'b1;
                  state <= IDLE;
                end
              end
            end else begin
              if ({pte_data[7:6], pte_data[4]} != 3'b0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                global_q <= global_q | pte_data[5];
                pte_word_addr <= {pte_data[31:10], vpn0};
                state <= LVL0_REQ;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        LVL0_REQ: begin
          if (kill) state <= IDLE;
          else if (!pte_address_valid) begin
            access_fault <= 1'b1;
            state <= IDLE;
          end else if (bus_arready) state <= LVL0_WAIT;
        end
        LVL0_WAIT: begin
          if (bus_rvalid) begin
            if (killed || kill) begin
              state <= IDLE;
            end else if (!pte_v || pte_reserved || !pte_leaf) begin
              fault <= 1'b1;
              state <= IDLE;
            end else begin
              result_ptag <= ptag_lvl0;
              result_level <= 2'd0;
              result_pte  <= walk_pte_flags;
              if (pte_needs_ad_update) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                done <= 1'b1;
                state <= IDLE;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        default: state <= IDLE;
      endcase
    end
  end

`ifdef RAPT_SVA_ACTIVE
  wire ptw_rv32_wait = state inside {LVL1_WAIT, LVL0_WAIT};
  wire ptw_rv32_killed_drain = (killed || kill) && ptw_rv32_wait && bus_rvalid;
`endif

  always_ff @(posedge clock) begin
    if (!reset) begin
      `RAPT_SVA_IMM(PTW_READ_RESPONSE_STATE, !bus_rvalid || ptw_rv32_wait)
      `RAPT_SVA_IMM(PTW_NO_REQUEST_DURING_RESPONSE, !(bus_arvalid && bus_rvalid))
    end
  end

  `RAPT_SVA_NEXT(clock, reset, PTW_KILLED_DRAIN_NO_COMPLETE, ptw_rv32_killed_drain, !done && !fault)
`endif

endmodule
