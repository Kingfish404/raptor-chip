`include "rapt.svh"
`include "rapt_eu_if.svh"

// Architectural registers f0..f31 remain writable, and all words are 64 bits
// in RV32 and RV64 so single-precision results keep their NaN box.
// Two fixed 32x64 replicas: bank 0 reads FMA rs1/rs2, bank 1 reads FMA
// rs3 and the IOQ store operand. Both ports read on a read cycle; both
// replicas receive every write. Writes pause reads for that edge, allowing
// either writer to use both ports. FP serialization prevents a write from
// coinciding with an issued FP read in the core.
module rapt_fpr (
    input clock,
    input reset,
    fpr_if.storage fpr
);
  logic [31:0] regs_valid;
  logic [4:0] read_addr[4];
  logic [63:0] read_data[4];
  logic [3:0] read_en;
  logic [3:0] read_word_valid_q;
  logic ioq_read_live_q;
  logic [4:0] ioq_read_addr_q;
  logic write_busy;
  logic alu_write, ioq_write, two_writes;
  logic [ 4:0] write_addr;
  logic [63:0] write_data;

  assign write_busy = fpr.alu_wvalid || fpr.ioq_wvalid;
  assign alu_write = !reset && fpr.alu_wvalid;
  assign ioq_write = !reset && fpr.ioq_wvalid;
  // The old flop array gave IOQ priority for a same-address collision.
  assign two_writes = alu_write && ioq_write && fpr.alu_waddr != fpr.ioq_waddr;
  assign write_addr = ioq_write ? fpr.ioq_waddr : fpr.alu_waddr;
  assign write_data = ioq_write ? fpr.ioq_wdata : fpr.alu_wdata;
  assign fpr.alu_read_ready = !reset && !write_busy;

  assign read_addr[0] = fpr.alu_raddr_a;
  assign read_addr[1] = fpr.alu_raddr_b;
  assign read_addr[2] = fpr.alu_raddr_c;
  assign read_addr[3] = fpr.ioq_raddr;
  assign read_en[0] = fpr.alu_ren && fpr.alu_read_ready;
  assign read_en[1] = fpr.alu_ren && fpr.alu_read_ready;
  assign read_en[2] = fpr.alu_ren && fpr.alu_read_ready;
  assign read_en[3] = !reset && !write_busy;

  for (genvar p = 0; p < 2; p++) begin : g_read_bank
    // During writes, A takes the ALU write only if both writers target
    // different registers. B takes IOQ priority. No read/write collision
    // reaches either port.
    rapt_sram_2rw #(
        .ADDR_WIDTH(5),
        .DATA_WIDTH(64)
    ) u_sram (
        .clock,
        .a_en(read_en[2*p] || two_writes),
        .a_wen(two_writes),
        .a_addr(two_writes ? fpr.alu_waddr : read_addr[2*p]),
        .a_wdata(fpr.alu_wdata),
        .a_rdata(read_data[2*p]),
        .b_en(read_en[2*p+1] || alu_write || ioq_write),
        .b_wen(alu_write || ioq_write),
        .b_addr(write_busy ? write_addr : read_addr[2*p+1]),
        .b_wdata(write_data),
        .b_rdata(read_data[2*p+1])
    );
  end
`ifndef SYNTHESIS
  // The simulator's architectural-state probe needs a contiguous register
  // image. Keep it outside synthesis so it does not duplicate the FPGA RAM.
  logic [63:0] monitor_regs[32];
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) monitor_regs[i] <= '0;
    end else begin
      if (alu_write) monitor_regs[fpr.alu_waddr] <= fpr.alu_wdata;
      if (ioq_write) monitor_regs[fpr.ioq_waddr] <= fpr.ioq_wdata;
    end
  end
`endif
  for (genvar p = 0; p < 4; p++) begin : g_read_valid
    always_ff @(posedge clock)
      if (reset) read_word_valid_q[p] <= 1'b0;
      else if (read_en[p]) read_word_valid_q[p] <= regs_valid[read_addr[p]];
  end

  // The data array has no reset pins. Architectural zero after reset is
  // provided by one valid bit per register and a sampled valid bit per read.
  always_ff @(posedge clock) begin
    if (reset) begin
      regs_valid <= '0;
      ioq_read_live_q <= 1'b0;
    end else begin
      ioq_read_live_q <= read_en[3];
      if (read_en[3]) ioq_read_addr_q <= fpr.ioq_raddr;
      if (alu_write) regs_valid[fpr.alu_waddr] <= 1'b1;
      if (ioq_write) regs_valid[fpr.ioq_waddr] <= 1'b1;
    end
  end

  assign fpr.alu_rdata_a = read_word_valid_q[0] ? read_data[0] : 64'b0;
  assign fpr.alu_rdata_b = read_word_valid_q[1] ? read_data[1] : 64'b0;
  assign fpr.alu_rdata_c = read_word_valid_q[2] ? read_data[2] : 64'b0;
  assign fpr.ioq_rdata   = read_word_valid_q[3] ? read_data[3] : 64'b0;
  assign fpr.ioq_rvalid  = ioq_read_live_q && ioq_read_addr_q == fpr.ioq_raddr;
endmodule
