`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"
module tb_clint_csr_time;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [63:0] Deadline = 64'h0000000200000000;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  clint_bus_if clint_bus ();
  rou_csr_if rou_csr ();
  exu_csr_if exu_csr ();
  csr_bcast_if csr_bcast ();
  pmp_update_if pmp_update ();
  rapt_clint #(
      .MTIME_DIV(3)
  ) clint (
      .clock,
      .reset,
      .clint_bus
  );
  rapt_csr csr_dut (
      .clock,
      .reset,
      .hart_id_i('0),
      .mtime_i(clint_bus.mtime_value),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .pmp_update,
      .timer_irq_i(clint_bus.timer_int),
      .sw_irq_i(clint_bus.sw_int),
      .m_ext_irq_i(1'b0),
      .s_ext_irq_i(1'b0),
      .store_error_i(1'b0),
      .store_error_addr_i('0),
      .store_error_strb_i('0),
      .s_int_pending(),
      .s_int_cause()
  );
  `include "tb_common.svh"
  task automatic clear_commit;
    rou_csr.valid=0;
    rou_csr.retire_count=0;
    rou_csr.csr_wen=0;
    rou_csr.csr_wdata=0;
    rou_csr.csr_addr=0;
    rou_csr.pc=0;
    rou_csr.ecall=0;
    rou_csr.ebreak=0;
    rou_csr.mret=0;
    rou_csr.sret=0;
    rou_csr.trap=0;
    rou_csr.tval=0;
    rou_csr.cause=0;
    rou_csr.fp_flags_valid=0;
    rou_csr.fp_flags=0;
    rou_csr.fp_dirty=0;
  endtask
  task automatic csr_write(input logic [11:0] addr, input logic [XLEN-1:0] data);
    @(negedge clock);
    rou_csr.valid=1;
    rou_csr.csr_wen=1;
    rou_csr.csr_addr=addr;
    rou_csr.csr_wdata=data;
    tick(1);
    clear_commit();
  endtask
  task automatic mmio_write(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                            input logic [XLEN/8-1:0] mask);
    @(negedge clock);
    clint_bus.awaddr=addr;
    clint_bus.wdata=data;
    clint_bus.wstrb=mask;
    clint_bus.wvalid=1;
    tick(1);
    clint_bus.wvalid = 0;
  endtask
  task automatic write64(input logic [XLEN-1:0] addr, input logic [63:0] data);
    if (XLEN == 32) mmio_write(addr + XLEN'(4), XLEN'(data >> 32), '1);
    mmio_write(addr, XLEN'(data), '1);
  endtask
  task automatic observe_time;
    logic [63:0] snapshot;
    logic expected_irq;
    // All observations below occur between the same two clock edges.
    @(negedge clock);
    snapshot=clint_bus.mtime_value;
    expected_irq=snapshot>=Deadline;
    exu_csr.raddr=`RAPT_CSR_TIME___;
    #1;
    check(exu_csr.rdata == XLEN'(snapshot), "CSR time diverged from writable mtime");
    if (XLEN == 32) begin
      exu_csr.raddr = `RAPT_CSR_TIMEH__;
      #1;
      check(exu_csr.rdata == XLEN'(snapshot >> 32), "CSR timeh diverged from writable mtime");
    end
    exu_csr.raddr = `RAPT_CSR_MIP____;
    #1;
    check(exu_csr.rdata[7] == expected_irq, "MTIP did not follow written mtime");
    check(exu_csr.rdata[5] == expected_irq, "Sstc did not follow shared mtime");
  endtask
  initial begin
    clear_commit();
    exu_csr.raddr=0;
    clint_bus.araddr=0;
    clint_bus.awaddr=0;
    clint_bus.wdata=0;
    clint_bus.wstrb=0;
    clint_bus.wvalid=0;
    tick(3);
    reset = 0;
    tick(1);
    write64(XLEN'('h02004000), Deadline);
    if (XLEN == 64) csr_write(`RAPT_CSR_MENVCFG, XLEN'(1) << 63);
    else begin
      csr_write(`RAPT_CSR_MENVCFGH, XLEN'(1) << 31);
      csr_write(`RAPT_CSR_STIMECMPH, XLEN'(Deadline >> 32));
    end
    csr_write(`RAPT_CSR_STIMECMP, XLEN'(Deadline));
    write64(XLEN'('h0200bff8), 64'h1234567800001111);
    observe_time();
    write64(XLEN'('h0200bff8), 64'h100);
    observe_time();
    write64(XLEN'('h0200bff8), Deadline);
    observe_time();
    write64(XLEN'('h0200bff8), Deadline - 1);
    repeat (5) observe_time();
    write64(XLEN'('h0200bff8), 64'hfffffffffffffffe);
    repeat (5) observe_time();
    mmio_write(XLEN'('h0200bffc), XLEN'('h12345678), (XLEN / 8)'(4'h5));
    observe_time();
    mmio_write(XLEN'('h0200bff8), '0, '0);
    observe_time();
    $display("PASS: real CLINT/CSR shared writable time, rollover and Sstc XLEN=%0d", XLEN);
    $finish;
  end
endmodule
