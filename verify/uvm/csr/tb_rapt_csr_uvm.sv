`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_rou_if.svh"

module tb_rapt_csr_uvm;
  import uvm_pkg::*;
  import rapt_csr_uvm_pkg::*;

  logic clock = 1'b0;
  always #5 clock = ~clock;

  rapt_csr_uvm_if tb_if(clock);
  rou_csr_if #(.XLEN(32)) rou_csr();
  exu_csr_if #(.XLEN(32)) exu_csr();
  csr_bcast_if #(.XLEN(32)) csr_bcast();

  rapt_csr #(.XLEN(32)) dut (
      .clock,
      .hart_id_i('0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .s_int_pending(tb_if.s_int_pending),
      .s_int_cause(tb_if.s_int_cause),
      .timer_irq_i(tb_if.timer_irq),
      .sw_irq_i(tb_if.sw_irq),
      .m_ext_irq_i(tb_if.m_ext_irq),
      .s_ext_irq_i(tb_if.s_ext_irq),
      .reset(tb_if.reset)
  );

  always_comb begin
    rou_csr.pc = tb_if.pc;
    rou_csr.csr_wen = tb_if.csr_wen;
    rou_csr.csr_wdata = tb_if.csr_wdata;
    rou_csr.csr_addr = tb_if.csr_addr;
    rou_csr.ecall = tb_if.ecall;
    rou_csr.ebreak = tb_if.ebreak;
    rou_csr.mret = tb_if.mret;
    rou_csr.sret = tb_if.sret;
    rou_csr.trap = tb_if.trap;
    rou_csr.tval = tb_if.tval;
    rou_csr.cause = tb_if.cause;
    rou_csr.valid = tb_if.valid;
    rou_csr.retire_a = tb_if.retire_a;
    rou_csr.retire_b = tb_if.retire_b;
    exu_csr.raddr = `RAPT_CSR_STVEC__;
    tb_if.sepc = exu_csr.sepc;
    tb_if.mtvec = exu_csr.mtvec;
    tb_if.stvec = exu_csr.rdata;
    tb_if.priv = csr_bcast.priv;
  end

  initial begin
    uvm_config_db#(csr_vif_t)::set(null, "uvm_test_top.env.agent.*", "vif", tb_if);
    run_test("csr_uvm_test");
  end

  initial begin
    #2ms;
    $fatal(1, "UVM CSR SRET test timed out");
  end
endmodule