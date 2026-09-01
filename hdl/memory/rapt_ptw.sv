`include "rapt.svh"

// Page-table walker.
// RV32 uses Sv32 two-level page tables. RV64 uses the Sv39 three-level format
// expected by upstream xv6-riscv. Permission checks against the access type and
// current privilege are performed by the requesters (L1I/L1D) using the returned
// PTE flags. Leaf PTE A/D bits are updated in hardware on both RV32 and RV64.
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
    input logic sbe,
    input logic req_store,

    output logic bus_arvalid,
    output logic [XLEN-1:0] bus_araddr,
    input  logic bus_arready,
    input  logic bus_rvalid,
    input  logic [XLEN-1:0] bus_rdata,

    output logic bus_awvalid,
    output logic [XLEN-1:0] bus_awaddr,
    output logic bus_wvalid,
    output logic [XLEN-1:0] bus_wdata,
    output logic [7:0] bus_wstrb,
    input  logic bus_wready,
    input  logic bus_werr,

    output logic done,
    output logic fault,
    output logic [XLEN-1:10] result_ptag,
    output logic [XLEN-1:12] result_vtag,
    // pte flags: {D,A,G,U,X,W,R} (bits 7..1 of PTE); valid when done=1
    output logic [6:0] result_pte,

    output logic busy
);

`ifdef RAPT_RV64
  typedef enum logic [2:0] {
    IDLE      = 3'b000,
    LVL2_REQ  = 3'b001,
    LVL2_WAIT = 3'b010,
    LVL1_REQ  = 3'b011,
    LVL1_WAIT = 3'b100,
    LVL0_REQ  = 3'b101,
    LVL0_WAIT = 3'b110,
    AD_UPD    = 3'b111
  } ptw_state_t;

  ptw_state_t state;

  logic [8:0] vpn1, vpn0;
  logic [XLEN-1:12] vtag_q;
  logic [XLEN-1:0] pte_addr;
  logic [XLEN-1:0] ad_pte_addr;
  logic [XLEN-1:0] ad_pte_data;
  logic req_store_q;
  logic killed;

  logic [63:0] pte_data;
  logic pte_v;
  logic pte_r;
  logic pte_w;
  logic pte_x;
  logic pte_a;
  logic pte_d;
  logic pte_leaf;
  logic pte_reserved;
  logic pte_needs_ad_update;
  logic [63:0] pte_data_ad;
  assign pte_data = bus_rdata[63:0];
  assign pte_v = pte_data[0];
  assign pte_r = pte_data[1];
  assign pte_w = pte_data[2];
  assign pte_x = pte_data[3];
  assign pte_a = pte_data[6];
  assign pte_d = pte_data[7];
  assign pte_leaf = pte_r || pte_x;
  assign pte_reserved = (pte_w && !pte_r) || (pte_data[63:54] != 10'h0);
  assign pte_needs_ad_update = !pte_a || (req_store_q && !pte_d);
  assign pte_data_ad = pte_data | 64'h0000_0000_0000_0040
                     | (req_store_q ? 64'h0000_0000_0000_0080 : 64'h0);

  localparam int Rv64PtagPadW = XLEN - 54;
  logic [XLEN-1:10] ptag_lvl2;
  logic [XLEN-1:10] ptag_lvl1;
  logic [XLEN-1:10] ptag_lvl0;
  assign ptag_lvl2 = {{Rv64PtagPadW{1'b0}}, pte_data[53:28], vpn1, vpn0};
  assign ptag_lvl1 = {{Rv64PtagPadW{1'b0}}, pte_data[53:19], vpn0};
  assign ptag_lvl0 = {{Rv64PtagPadW{1'b0}}, pte_data[53:10]};

  assign busy = (state != IDLE);
  assign bus_arvalid = !kill
                     && (state == LVL2_REQ || state == LVL1_REQ || state == LVL0_REQ);
  assign bus_araddr = pte_addr;
  assign bus_awvalid = (state == AD_UPD);
  assign bus_awaddr = ad_pte_addr;
  assign bus_wvalid = (state == AD_UPD);
  assign bus_wdata = ad_pte_data;
  assign bus_wstrb = 8'hff;
  assign result_vtag = vtag_q;

  // SBE is WARL-zero in rapt today. Keep the port so the requester interface
  // stays uniform across RV32/RV64.
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_sbe;
  assign _unused_sbe = sbe;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      done  <= 1'b0;
      fault <= 1'b0;
      killed <= 1'b0;
    end else begin
      done  <= 1'b0;
      fault <= 1'b0;

      unique case (state)
        IDLE: begin
          killed <= 1'b0;
          if (req_valid && mmu_en && !kill) begin
            vpn1 <= vaddr[29:21];
            vpn0 <= vaddr[20:12];
            vtag_q <= vaddr[XLEN-1:12];
            req_store_q <= req_store;
            pte_addr <= XLEN'({satp_ppn, 12'b0}) + (XLEN'(vaddr[38:30]) << 3);
            state <= LVL2_REQ;
          end
        end
        LVL2_REQ: begin
          if (kill) state <= IDLE;
          else if (bus_arready) state <= LVL2_WAIT;
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
                result_ptag <= ptag_lvl2;
                result_pte  <= pte_data_ad[7:1];
                if (pte_needs_ad_update) begin
                  ad_pte_addr <= pte_addr;
                  ad_pte_data <= XLEN'(pte_data_ad);
                  state <= AD_UPD;
                end else begin
                  done <= 1'b1;
                  state <= IDLE;
                end
              end
            end else begin
              if (pte_data[7:4] != 4'h0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                pte_addr <= XLEN'({pte_data[53:10], 12'b0}) + (XLEN'(vpn1) << 3);
                state <= LVL1_REQ;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        LVL1_REQ: begin
          if (kill) state <= IDLE;
          else if (bus_arready) state <= LVL1_WAIT;
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
                result_ptag <= ptag_lvl1;
                result_pte  <= pte_data_ad[7:1];
                if (pte_needs_ad_update) begin
                  ad_pte_addr <= pte_addr;
                  ad_pte_data <= XLEN'(pte_data_ad);
                  state <= AD_UPD;
                end else begin
                  done <= 1'b1;
                  state <= IDLE;
                end
              end
            end else begin
              if (pte_data[7:4] != 4'h0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                pte_addr <= XLEN'({pte_data[53:10], 12'b0}) + (XLEN'(vpn0) << 3);
                state <= LVL0_REQ;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        LVL0_REQ: begin
          if (kill) state <= IDLE;
          else if (bus_arready) state <= LVL0_WAIT;
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
              result_pte  <= pte_data_ad[7:1];
              if (pte_needs_ad_update) begin
                ad_pte_addr <= pte_addr;
                ad_pte_data <= XLEN'(pte_data_ad);
                state <= AD_UPD;
              end else begin
                done <= 1'b1;
                state <= IDLE;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        AD_UPD: begin
          if (bus_wready) begin
            fault <= !(killed || kill) && bus_werr;
            done  <= !(killed || kill) && !bus_werr;
            state <= IDLE;
          end else if (kill) killed <= 1'b1;
        end
        default: state <= IDLE;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (!reset) begin
      `RAPT_SVA_IMM(PTW_READ_RESPONSE_STATE,
                    !bus_rvalid || state inside {LVL2_WAIT, LVL1_WAIT, LVL0_WAIT})
      `RAPT_SVA_IMM(PTW_NO_REQUEST_DURING_RESPONSE, !(bus_arvalid && bus_rvalid))
    end
  end

  `RAPT_SVA_NEXT(
      clock, reset, PTW_KILLED_DRAIN_NO_COMPLETE,
      (killed || kill) && (((state inside {LVL2_WAIT, LVL1_WAIT, LVL0_WAIT}) && bus_rvalid) || ((state == AD_UPD) && bus_wready)),
      !done && !fault)
`else
  typedef enum logic [2:0] {
    IDLE      = 3'b000,
    LVL1_REQ  = 3'b001,
    LVL1_WAIT = 3'b010,
    LVL0_REQ  = 3'b011,
    LVL0_WAIT = 3'b100,
    AD_UPD    = 3'b101
  } ptw_state_t;

  ptw_state_t state;

  logic [9:0] vpn1, vpn0;
  // Sv32 PA is 34 bits; keep all 34 bits so addition can't overflow. The
  // upper two bits are truncated at bus_araddr because the host bus is XLEN.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN+1:0] ppn_a;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [31:0] pte_raw;
  assign pte_raw = bus_rdata[31:0];
  logic [XLEN-1:0] ad_pte_addr;
  logic [31:0] ad_pte_data;
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
  assign bus_arvalid = !kill && (state == LVL1_REQ || state == LVL0_REQ);
  assign bus_araddr = ppn_a[XLEN-1:0];
  assign bus_awvalid = (state == AD_UPD);
  assign bus_awaddr = ad_pte_addr;
  assign bus_wvalid = (state == AD_UPD);
  assign bus_wdata = XLEN'(ad_pte_data);
  assign bus_wstrb = 8'h0f;

  logic pte_v;
  logic pte_r;
  logic pte_w;
  logic pte_x;
  logic pte_a;
  logic pte_d;
  logic pte_leaf;
  logic pte_reserved;
  logic pte_needs_ad_update;
  logic [31:0] pte_data_ad;
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
  assign pte_data_ad = pte_data | 32'h0000_0040
                     | (req_store_q ? 32'h0000_0080 : 32'h0);

  assign ptag_lvl1 = {pte_data[31:20], vpn0};
  assign ptag_lvl0 = pte_data[31:10];

  assign result_vtag = {vpn1, vpn0};

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      done  <= 1'b0;
      fault <= 1'b0;
      killed <= 1'b0;
    end else begin
      done  <= 1'b0;
      fault <= 1'b0;

      unique case (state)
        IDLE: begin
          killed <= 1'b0;
          if (req_valid && mmu_en && !kill) begin
            vpn1  <= vaddr[31:22];
            vpn0  <= vaddr[21:12];
            req_store_q <= req_store;
            ppn_a <= {satp_ppn, 12'b0} + (vaddr[31:22] * 4);
            state <= LVL1_REQ;
          end
        end
        LVL1_REQ: begin
          if (kill) state <= IDLE;
          else if (bus_arready) state <= LVL1_WAIT;
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
                result_pte  <= pte_data_ad[7:1];
                if (pte_needs_ad_update) begin
                  ad_pte_addr <= ppn_a[XLEN-1:0];
                  ad_pte_data <= pte_data_ad;
                  state <= AD_UPD;
                end else begin
                  done <= 1'b1;
                  state <= IDLE;
                end
              end
            end else begin
              if (pte_data[6:4] != 3'h0) begin
                fault <= 1'b1;
                state <= IDLE;
              end else begin
                ppn_a <= {pte_data[31:10], 12'b0} + (vpn0 * 4);
                state <= LVL0_REQ;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        LVL0_REQ: begin
          if (kill) state <= IDLE;
          else if (bus_arready) state <= LVL0_WAIT;
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
              result_pte  <= pte_data_ad[7:1];
              if (pte_needs_ad_update) begin
                ad_pte_addr <= ppn_a[XLEN-1:0];
                ad_pte_data <= pte_data_ad;
                state <= AD_UPD;
              end else begin
                done <= 1'b1;
                state <= IDLE;
              end
            end
          end else if (kill) killed <= 1'b1;
        end
        AD_UPD: begin
          if (bus_wready) begin
            fault <= !(killed || kill) && bus_werr;
            done  <= !(killed || kill) && !bus_werr;
            state <= IDLE;
          end else if (kill) killed <= 1'b1;
        end
        default: state <= IDLE;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (!reset) begin
      `RAPT_SVA_IMM(PTW_READ_RESPONSE_STATE, !bus_rvalid || state inside {LVL1_WAIT, LVL0_WAIT})
      `RAPT_SVA_IMM(PTW_NO_REQUEST_DURING_RESPONSE, !(bus_arvalid && bus_rvalid))
    end
  end


  `RAPT_SVA_NEXT(
      clock, reset, PTW_KILLED_DRAIN_NO_COMPLETE,
      (killed || kill) && (((state inside {LVL1_WAIT, LVL0_WAIT}) && bus_rvalid) || ((state == AD_UPD) && bus_wready)),
      !done && !fault)
`endif

endmodule
