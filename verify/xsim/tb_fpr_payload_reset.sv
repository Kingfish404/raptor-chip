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
  logic [63:0] last_a, last_b, last_c, last_ioq;
  logic last_ioq_valid;
  logic [4:0] last_ioq_addr;
  logic [31:0] rng = 32'h73c9a521;
  int cycles = 0;

  function automatic logic [31:0] random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  task automatic check_reads;
    if ({fpr.alu_rdata_a, fpr.alu_rdata_b, fpr.alu_rdata_c, fpr.ioq_rdata}
        !== {last_a, last_b, last_c, last_ioq})
      $fatal(1, "FPR read mismatch cycle=%0d", cycles);
    if (fpr.ioq_rvalid !== (last_ioq_valid && last_ioq_addr == fpr.ioq_raddr))
      $fatal(1, "FPR IOQ valid mismatch cycle=%0d", cycles);
    if (fpr.alu_read_ready !== !(reset || fpr.alu_wvalid || fpr.ioq_wvalid))
      $fatal(1, "FPR ALU ready mismatch cycle=%0d", cycles);
  endtask

  task automatic tick;
    logic write_busy;
    write_busy = fpr.alu_wvalid || fpr.ioq_wvalid;
    #1;
    clock = 1;
    if (reset) begin
      for (int r = 0; r < 32; r++) expected[r] = 0;
      last_a = 0;
      last_b = 0;
      last_c = 0;
      last_ioq = 0;
      last_ioq_valid = 0;
    end else begin
      if (!write_busy) begin
        if (fpr.alu_ren) begin
          last_a = expected[fpr.alu_raddr_a];
          last_b = expected[fpr.alu_raddr_b];
          last_c = expected[fpr.alu_raddr_c];
        end
        last_ioq = expected[fpr.ioq_raddr];
        last_ioq_addr = fpr.ioq_raddr;
        last_ioq_valid = 1;
      end else begin
        last_ioq_valid = 0;
      end
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
    fpr.alu_ren = 0;
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
    // Exercise both writers, same-address IOQ priority, and f0 writes.
    for (int r = 0; r < 32; r++) begin
      fpr.alu_wvalid = 1;
      fpr.ioq_wvalid = 1;
      fpr.alu_waddr  = 5'(r);
      fpr.ioq_waddr  = 5'(r);
      fpr.alu_wdata  = 64'hffffffff3f800000 ^ 64'(r);
      fpr.ioq_wdata  = 64'h7ff80000deadbeef ^ 64'(r);
      tick();
      fpr.alu_wvalid = 0;
      fpr.ioq_wvalid = 0;
      fpr.alu_ren = 1;
      fpr.alu_raddr_a = 5'(r);
      fpr.alu_raddr_b = 5'(r);
      fpr.alu_raddr_c = 5'(r);
      fpr.ioq_raddr = 5'(r);
      tick();
    end
    for (int n = 0; n < 1000; n++) begin
      reset = n % 31 == 0;
      fpr.alu_ren = 1'(random_word());
      fpr.alu_wvalid = 1'(random_word());
      fpr.ioq_wvalid = 1'(random_word());
      fpr.alu_waddr = 5'(random_word());
      fpr.ioq_waddr = 5'(random_word());
      fpr.alu_wdata = {random_word(), random_word()};
      fpr.ioq_wdata = {random_word(), random_word()};
      fpr.alu_raddr_a = fpr.alu_waddr;
      fpr.alu_raddr_b = fpr.ioq_waddr;
      fpr.alu_raddr_c = 5'(random_word());
      fpr.ioq_raddr = 5'(random_word());
      #1;
      check_reads();  // Address changes alone must not alter clocked data.
      tick();
    end
    $display("PASS: FPR synchronous payload/reset cycles=%0d seed=73c9a521 XLEN=%0d", cycles,
             `RAPT_XLEN);
    $finish;
  end
endmodule
