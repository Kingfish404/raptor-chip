`include "rapt.svh"
`include "rapt_eu_if.svh"

module tb_fpr_payload_reset;
  logic clock = 0, reset = 1;
  fpr_if fpr ();
  rapt_fpr dut (
      .clock,
      .reset,
      .fpr
  );
  logic [63:0] expected[32];
  logic bypass_valid = 0;
  logic [4:0] bypass_addr;
  logic [63:0] bypass_data;
  logic [31:0] rng = 32'h73c9a521;
  int cycles = 0;

  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  task automatic check_reads;
    logic [63:0] a, b, c;
    a = bypass_valid && bypass_addr == fpr.alu_raddr_a ? bypass_data : expected[fpr.alu_raddr_a];
    b = bypass_valid && bypass_addr == fpr.alu_raddr_b ? bypass_data : expected[fpr.alu_raddr_b];
    c = bypass_valid && bypass_addr == fpr.alu_raddr_c ? bypass_data : expected[fpr.alu_raddr_c];
    if ({fpr.alu_rdata_a, fpr.alu_rdata_b, fpr.alu_rdata_c, fpr.ioq_rdata}
        !== {a, b, c, expected[fpr.ioq_raddr]})
      $fatal(1, "FPR payload/reset mismatch cycle=%0d", cycles);
  endtask
  task automatic tick;
    #1;
    clock = 1;
    if (reset) begin
      for (int r = 0; r < 32; r++) expected[r] = 0;
      bypass_valid = 0;
    end else begin
      bypass_valid = fpr.alu_wvalid;
      bypass_addr = fpr.alu_waddr;
      bypass_data = fpr.alu_wdata;
      if (fpr.alu_wvalid) expected[fpr.alu_waddr] = fpr.alu_wdata;
      if (fpr.ioq_wvalid) expected[fpr.ioq_waddr] = fpr.ioq_wdata;
    end
    #1;
    clock = 0;
    #1;
    cycles++;
    check_reads();
  endtask
  initial begin
    fpr.alu_raddr_a = 0;
    fpr.alu_raddr_b = 0;
    fpr.alu_raddr_c = 0;
    fpr.ioq_raddr = 0;
    fpr.alu_wvalid = 0;
    fpr.ioq_wvalid = 0;
    fpr.alu_waddr = 0;
    fpr.ioq_waddr = 0;
    fpr.alu_wdata = 0;
    fpr.ioq_wdata = 0;
    tick();
    reset = 0;
    // f0 is writable. ALU bypass and IOQ bank priority remain distinct even
    // on simultaneous writes to one register; reset must mask stale bypass.
    for (int r = 0; r < 32; r++) begin
      fpr.alu_raddr_a = 5'(r);
      fpr.alu_raddr_b = 5'(r);
      fpr.alu_raddr_c = 5'(r);
      fpr.ioq_raddr = 5'(r);
      fpr.alu_waddr = 5'(r);
      fpr.ioq_waddr = 5'(r);
      fpr.alu_wdata = 64'hffffffff3f800000 ^ 64'(r);
      fpr.ioq_wdata = 64'h7ff80000deadbeef ^ 64'(r);
      fpr.alu_wvalid = 1;
      fpr.ioq_wvalid = 1;
      tick();
      reset = 1;
      tick();
      tick();
      reset = 0;
      fpr.alu_wvalid = 0;
      fpr.ioq_wvalid = 0;
      tick();
    end
    // Deterministic writes, bubbles, matching/nonmatching reads and warm reset.
    for (int n = 0; n < 1000; n++) begin
      reset = n % 31 == 0;
      fpr.alu_wvalid = 1'(random_word());
      fpr.ioq_wvalid = 1'(random_word());
      fpr.alu_waddr = 5'(random_word());
      fpr.ioq_waddr = 5'(random_word());
      fpr.alu_wdata = {random_word(), random_word()};
      fpr.ioq_wdata = {random_word(), random_word()};
      fpr.alu_raddr_a = fpr.alu_waddr;
      fpr.alu_raddr_b = fpr.ioq_waddr;
      fpr.alu_raddr_c = 5'(random_word());
      fpr.ioq_raddr = fpr.alu_waddr;
      #1;
      check_reads();  // No combinational write-through before the edge.
      tick();
    end
    $display("PASS: FPR payload reset cycles=%0d seed=73c9a521 XLEN=%0d", cycles, `RAPT_XLEN);
    $finish;
  end
endmodule
