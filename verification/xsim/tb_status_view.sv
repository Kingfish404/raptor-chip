`include "rapt.svh"
`include "rapt_if.svh"

// Exercise the ROU's separate retirement edges for FP updates and returns,
// and the shared status reset semantics for zero and nonzero RESET_VAL.
module tb_status_view;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  rou_csr_if rou_csr ();
  logic [1:0] checked;
  for (genvar n = 0; n < 2; n++) begin : g_reset
    localparam logic [XLEN-1:0] ResetValue = n == 0 ? '0 : XLEN'(32'h800c6122);
    exu_csr_if exu_csr ();
    csr_bcast_if csr_bcast ();
    pmp_update_if pmp_update ();
    rapt_csr #(
        .RESET_VAL(ResetValue)
    ) dut (
        .clock,
        .reset,
        .hart_id_i('0),
        .mtime_i('0),
        .rou_csr,
        .exu_csr,
        .csr_bcast,
        .pmp_update,
        .s_int_pending(),
        .s_int_cause(),
        .timer_irq_i(1'b0),
        .sw_irq_i(1'b0),
        .m_ext_irq_i(1'b0),
        .s_ext_irq_i(1'b0),
        .store_error_i(1'b0),
        .store_error_addr_i('0),
        .store_error_strb_i('0)
    );
    logic [XLEN-1:0] status;
    initial begin
      checked[n] = 0;
      exu_csr.raddr = `RAPT_CSR_SSTATUS;
      @(negedge clock);
      if (exu_csr.rdata !== ((ResetValue & `RAPT_CSR_SSTATUS_CMASK) | `RAPT_CSR_SSTATUS_HW))
        $fatal(1, "sstatus RESET_VAL view mismatch");
      repeat (5) @(negedge clock);
      #1;
      status = exu_csr.rdata;
      if (status[14:13] != 2'b11 || !status[XLEN-1])
        $fatal(1, "FP dirtiness lost across separate FP/MRET/SRET retirements");
      exu_csr.raddr = `RAPT_CSR_MSTATUS;
      #1;
      if (status !== ((exu_csr.rdata & `RAPT_CSR_SSTATUS_CMASK) | `RAPT_CSR_SSTATUS_HW))
        $fatal(1, "sstatus/mstatus view mismatch after returns");
      checked[n] = 1;
    end
  end
  initial begin
    rou_csr.pc = '0;
    rou_csr.csr_wen = 0;
    rou_csr.csr_wdata = '0;
    rou_csr.csr_addr = '0;
    rou_csr.fp_flags_valid = 0;
    rou_csr.fp_flags = '0;
    rou_csr.fp_dirty = 0;
    rou_csr.ecall = 0;
    rou_csr.ebreak = 0;
    rou_csr.mret = 0;
    rou_csr.sret = 0;
    rou_csr.trap = 0;
    rou_csr.tval = '0;
    rou_csr.cause = '0;
    rou_csr.valid = 0;
    rou_csr.retire_count = '0;
    repeat (2) @(negedge clock);
    reset = 0;
    rou_csr.valid = 1;
    // Return to M first so the following SRET is legal as well.
    rou_csr.csr_wen = 1;
    rou_csr.csr_addr = `RAPT_CSR_MSTATUS;
    rou_csr.csr_wdata = XLEN'(3) << 11;
    @(negedge clock);
    rou_csr.csr_wen = 0;
    rou_csr.fp_dirty = 1;
    @(negedge clock);
    rou_csr.fp_dirty = 0;
    rou_csr.mret = 1;
    @(negedge clock);
    rou_csr.mret = 0;
    rou_csr.sret = 1;
    @(negedge clock);
    rou_csr.sret = 0;
    rou_csr.valid = 0;
    wait (&checked);
    $display("PASS: RV%0d status view reset and serialized FP/return retirement", XLEN);
    $finish;
  end
endmodule
