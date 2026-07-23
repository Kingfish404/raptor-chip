`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_rou_if.svh"

module tb_csr_sret_roundtrip;
  localparam int XLEN = 32;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic s_int_pending;
  logic [XLEN-1:0] s_int_cause;

  rou_csr_if #(.XLEN(XLEN)) rou_csr ();
  exu_csr_if #(.XLEN(XLEN)) exu_csr ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();

  rapt_csr #(.XLEN(XLEN)) dut (
      .clock,
      .hart_id_i('0),
      .rou_csr,
      .exu_csr,
      .csr_bcast,
      .s_int_pending,
      .s_int_cause,
      .timer_irq_i(1'b0),
      .sw_irq_i(1'b0),
      .m_ext_irq_i(1'b0),
      .s_ext_irq_i(1'b0),
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic clear_request;
    begin
      rou_csr.pc = '0;
      rou_csr.csr_wen = 1'b0;
      rou_csr.csr_wdata = '0;
      rou_csr.csr_addr = '0;
      rou_csr.ecall = 1'b0;
      rou_csr.ebreak = 1'b0;
      rou_csr.mret = 1'b0;
      rou_csr.sret = 1'b0;
      rou_csr.trap = 1'b0;
      rou_csr.tval = '0;
      rou_csr.cause = '0;
      rou_csr.valid = 1'b0;
      rou_csr.retire_a = 1'b0;
      rou_csr.retire_b = 1'b0;
    end
  endtask

  task automatic write_csr(input logic [11:0] address, input logic [31:0] data);
    begin
      @(negedge clock);
      rou_csr.csr_addr = address;
      rou_csr.csr_wdata = data;
      rou_csr.csr_wen = 1'b1;
      rou_csr.valid = 1'b1;
      @(posedge clock);
      @(negedge clock);
      clear_request();
    end
  endtask

  task automatic pulse_control(
      input logic do_ecall,
      input logic do_mret,
      input logic do_sret,
      input logic [31:0] pc);
    begin
      @(negedge clock);
      rou_csr.pc = pc;
      rou_csr.ecall = do_ecall;
      rou_csr.mret = do_mret;
      rou_csr.sret = do_sret;
      rou_csr.valid = 1'b1;
      @(posedge clock);
      @(negedge clock);
      clear_request();
    end
  endtask

  task automatic check_csr_zero(input logic [11:0] address, input string name);
    begin
      exu_csr.raddr = address;
      #1;
      check(exu_csr.rdata === 32'h0,
            $sformatf("%s reset value is not deterministic zero: %08x",
                      name, exu_csr.rdata));
    end
  endtask

  initial begin
    clear_request();
    exu_csr.raddr = '0;
    tick(4);
    reset = 1'b0;
    tick(1);

    check_csr_zero(`RAPT_CSR_STVEC__, "stvec");
    check_csr_zero(`RAPT_CSR_SEPC___, "sepc");
    check_csr_zero(`RAPT_CSR_SCAUSE_, "scause");
    check_csr_zero(`RAPT_CSR_STVAL__, "stval");
    check_csr_zero(`RAPT_CSR_SATP___, "satp");
    check_csr_zero(`RAPT_CSR_MEDELEG, "medeleg");
    check_csr_zero(`RAPT_CSR_MIE____, "mie");
    check_csr_zero(`RAPT_CSR_MIP____, "mip");

    // Enter U-mode through MRET with MPP=U, then delegate U-ecall to S-mode.
    write_csr(`RAPT_CSR_MSTATUS, 32'h0);
    write_csr(`RAPT_CSR_MEDELEG, 32'h0000_0100);
    pulse_control(1'b0, 1'b1, 1'b0, 32'h8000_0100);
    check(csr_bcast.priv == `RAPT_PRIV_U, "MRET did not enter U-mode");

    pulse_control(1'b1, 1'b0, 1'b0, 32'h0001_01c0);
    check(csr_bcast.priv == `RAPT_PRIV_S, "delegated U-ecall did not enter S-mode");
    check(exu_csr.sepc == 32'h0001_01c0, "U-ecall captured wrong sepc");

    // Linux advances sepc past ECALL before returning to userspace.
    write_csr(`RAPT_CSR_SEPC___, 32'h0001_01c4);
    check(exu_csr.sepc == 32'h0001_01c4, "sepc update was not visible to SRET");
    pulse_control(1'b0, 1'b0, 1'b1, 32'hc000_1000);
    check(csr_bcast.priv == `RAPT_PRIV_U, "SRET did not return to U-mode");
    check(exu_csr.sepc == 32'h0001_01c4, "SRET corrupted return sepc");

    exu_csr.raddr = `RAPT_CSR_MSTATUS;
    #1;
    check(exu_csr.rdata[`RAPT_CSR_MSTATUS_SPP_] == 1'b0,
          "SRET did not clear SPP");
    check(exu_csr.rdata[`RAPT_CSR_MSTATUS_SPIE] == 1'b1,
          "SRET did not set SPIE");

    $display("PASS: CSR reset and U-ecall/SRET round-trip checks passed");
    $finish;
  end
endmodule
