`include "rapt.svh"
`include "rapt_if.svh"

// Ignored PMP writes still invalidate data verdicts through the existing
// distributed update event. Read-only CSR operations must not do so.
module tb_csr_pmp_flush;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  logic external_s = 0;
  `include "tb_csr_execute_dut.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_csr_clear_commit.svh"
  `include "tb_csr_execute_tasks.svh"
pmp_state_if replica ();
  rapt_pmp_state replica_dut (
      .clock,
      .reset,
      .update(pmp_update),
      .state(replica)
  );
  int writes = 0, reads = 0;
  always @(posedge clock) begin
    if (!reset && rou_csr.valid) begin
      if (rou_csr.csr_wen) begin
        if (!(pmp_update.addr_we || |pmp_update.cfg_we))
          $fatal(1, "PMP write did not invalidate verdicts: CSR=%h", rou_csr.csr_addr);
        writes++;
      end else begin
        if (pmp_update.addr_we || |pmp_update.cfg_we)
          $fatal(1, "read-only PMP CSR operation emitted an update");
        reads++;
      end
    end
  end
  initial begin
    iss = '0;
    clear_commit();
    init_cmu_bcast_defaults();
    repeat (2) @(negedge clock);
    reset = 0;
    write_csr(12'h3b0, XLEN'('h1003));
    write_csr(12'h3a0, XLEN'('h99));  // Locked NAPOT, read-only.
    write_csr(12'h3b0, XLEN'('h2007));
    write_csr(12'h3a0, 0);
    expect_csr(12'h3b0, XLEN'('h1003));
    expect_csr(12'h3a0, XLEN'('h99));
    if (replica.pmp_raw_addr[0] != (`RAPT_PADDR_BITS - 2)'('h1003)
        || !replica.pmp_cfg_l[0] || !replica.pmp_cfg_r[0]
        || replica.pmp_cfg_w[0] || !replica.pmp_mode_napot[0])
      $fatal(1, "ignored write changed locked replica");
    for (int entry = `RAPT_PMP_NUM; entry < `RAPT_PMP_CSR_NUM; entry++) begin
      write_csr(12'h3b0 + 12'(entry), XLEN'('h3000 + entry));
      expect_csr(12'h3b0 + 12'(entry), 0);
    end
    // The upper implemented CSR bank contains no active PMP entries in default.
    write_csr(12'h3a2, '1);
    expect_csr(12'h3a2, 0);
    if (writes != 5 + `RAPT_PMP_CSR_NUM -
        `RAPT_PMP_NUM
        || reads != 3 + `RAPT_PMP_CSR_NUM - `RAPT_PMP_NUM)
      $fatal(1, "PMP flush-event coverage incomplete");
    $display("PASS: PMP ignored-write flush events XLEN=%0d writes=%0d reads=%0d", XLEN, writes,
             reads);
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "PMP flush-event timeout");
  end
endmodule
