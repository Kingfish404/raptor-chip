`include "rapt.svh"
`include "rapt_eu_if.svh"

// Architectural FPR storage for scalar F/D execution.
// FPR width is fixed at 64 for both RV32 and RV64 so S values can be
// NaN-boxed in the same bank used by D operations.
module rapt_fpr (
    input clock,
    input reset,
    fpr_if.storage fpr
);
  logic [63:0] regs[32];
  logic [31:0] regs_valid;  // written-since-reset flag per architectural FP reg
  logic        alu_bypass_valid_q;
  logic [4:0]  alu_bypass_addr_q;
  logic [63:0] alu_bypass_data_q;

  // f0 is treated as a normal register by the REF model (the FP test suite
  // exercises fmv.w.x ft0 and difftest compares fpr[0]), so it is writable
  // here too.  Never-written registers read as 0 (matching the REF model's
  // post-reset state), so the 32x64 data array carries no reset endpoints:
  // only the valid array and bypass control reset.  This removes 2048 data
  // flops from the reset fanout at the cost of one 2:1 mux per read port
  // (valid-gated zero select).
  function automatic logic [63:0] fpr_read(input logic [4:0] addr);
    fpr_read = regs_valid[addr] ? regs[addr] : 64'h0;
  endfunction

  assign fpr.alu_rdata_a = (fpr.ioq_wvalid && fpr.ioq_waddr == fpr.alu_raddr_a)
      ? fpr.ioq_wdata
      : (alu_bypass_valid_q && alu_bypass_addr_q == fpr.alu_raddr_a)
        ? alu_bypass_data_q : fpr_read(fpr.alu_raddr_a);
  assign fpr.alu_rdata_b = (fpr.ioq_wvalid && fpr.ioq_waddr == fpr.alu_raddr_b)
      ? fpr.ioq_wdata
      : (alu_bypass_valid_q && alu_bypass_addr_q == fpr.alu_raddr_b)
        ? alu_bypass_data_q : fpr_read(fpr.alu_raddr_b);
  assign fpr.alu_rdata_c = (fpr.ioq_wvalid && fpr.ioq_waddr == fpr.alu_raddr_c)
      ? fpr.ioq_wdata
      : (alu_bypass_valid_q && alu_bypass_addr_q == fpr.alu_raddr_c)
        ? alu_bypass_data_q : fpr_read(fpr.alu_raddr_c);
  assign fpr.ioq_rdata   = (fpr.ioq_wvalid && fpr.ioq_waddr == fpr.ioq_raddr)
      ? fpr.ioq_wdata
      : fpr_read(fpr.ioq_raddr);

  always_ff @(posedge clock) begin
    if (reset) begin
      regs_valid         <= '0;
      alu_bypass_valid_q <= 1'b0;
      alu_bypass_addr_q  <= '0;
      alu_bypass_data_q  <= '0;
    end else begin
      alu_bypass_valid_q <= fpr.alu_wvalid;
      alu_bypass_addr_q  <= fpr.alu_waddr;
      alu_bypass_data_q  <= fpr.alu_wdata;
      if (fpr.alu_wvalid) begin
        regs[fpr.alu_waddr]       <= fpr.alu_wdata;
        regs_valid[fpr.alu_waddr] <= 1'b1;
      end
      if (fpr.ioq_wvalid) begin
        regs[fpr.ioq_waddr]       <= fpr.ioq_wdata;
        regs_valid[fpr.ioq_waddr] <= 1'b1;
      end
    end
  end
endmodule
