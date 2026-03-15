`include "ysyx.svh"

// Sv32 two-level page table walker.
// Walks vpn[1] → vpn[0] via AXI read channel, produces physical tag or fault.
module ysyx_ptw #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    // Request interface
    input logic            req_valid,  // pulse to start PTW
    input logic [XLEN-1:0] vaddr,      // virtual address to translate
    input logic [    21:0] satp_ppn,   // root page table PPN from satp
    input logic            mmu_en,     // MMU enabled (guard)

    // AXI read channel (shared with cache — active only while busy)
    output logic            bus_arvalid,
    output logic [XLEN-1:0] bus_araddr,
    input  logic            bus_rvalid,
    input  logic [XLEN-1:0] bus_rdata,

    // Result (active for one cycle when done/fault fires)
    output logic             done,         // translation complete (not fault)
    output logic             fault,        // page fault
    output logic [XLEN-1:10] result_ptag,  // physical tag for TLB fill
    output logic [XLEN-1:12] result_vtag,  // virtual tag for TLB fill

    // Status
    output logic busy  // PTW is in-flight
);

  typedef enum logic [1:0] {
    IDLE = 2'b00,
    LVL1 = 2'b10,  // reading first-level PTE (vpn[1])
    LVL0 = 2'b11   // reading second-level PTE (vpn[0])
  } ptw_state_t;

  ptw_state_t state;

  logic [9:0] vpn1, vpn0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1+2:0] ppn_a;
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef YSYX_RV64
  // Sv32 PTEs are 4 bytes; pmem_read returns 8 bytes on RV64.
  // Select correct 32-bit half using ppn_a[2].
  logic [31:0] pte_data;
  assign pte_data = ppn_a[2] ? bus_rdata[63:32] : bus_rdata[31:0];
`else
  wire [31:0] pte_data = bus_rdata[31:0];
`endif

  assign busy = (state != IDLE);
  assign bus_arvalid = (state == LVL1 || state == LVL0);
  assign bus_araddr = ppn_a[XLEN-1:0];

  // Leaf detection: PTE.R or PTE.X set means leaf
  wire pte_leaf = (pte_data[2] || pte_data[1]);

  // Physical tag from PTE
  wire [XLEN-1:10] ptag_lvl1 = {pte_data[31:20], vpn0};
  wire [XLEN-1:10] ptag_lvl0 = pte_data[31:10];

  assign result_vtag = {vpn1, vpn0};

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      done  <= 1'b0;
      fault <= 1'b0;
    end else begin
      done  <= 1'b0;
      fault <= 1'b0;

      unique case (state)
        IDLE: begin
          if (req_valid && mmu_en) begin
            vpn1  <= vaddr[31:22];
            vpn0  <= vaddr[21:12];
            ppn_a <= {satp_ppn, 12'b0} + (vaddr[31:22] * 4);
            state <= LVL1;
          end
        end
        LVL1: begin
          if (!mmu_en) begin
            state <= IDLE;
          end else if (bus_rvalid) begin
            if (pte_data == 0) begin
              fault <= 1'b1;
              state <= IDLE;
            end else if (pte_leaf) begin
              // Superpage (level-1 leaf)
              result_ptag <= ptag_lvl1;
              done <= 1'b1;
              state <= IDLE;
            end else begin
              // Non-leaf: descend to level 0
              ppn_a <= {pte_data[31:10], 12'b0} + (vpn0 * 4);
              state <= LVL0;
            end
          end
        end
        LVL0: begin
          if (!mmu_en) begin
            state <= IDLE;
          end else if (bus_rvalid) begin
            if (pte_data == 0) begin
              fault <= 1'b1;
            end else begin
              result_ptag <= ptag_lvl0;
              done <= 1'b1;
            end
            state <= IDLE;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end

endmodule
