// Shared direct CSR control/timer tasks. Intentionally no include guard.
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
    rou_csr.retire_count = 1'b0;
  end
endtask

task automatic write_csr(input logic [11:0] address, input logic [XLEN-1:0] data);
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

task automatic pulse_control(input logic do_ecall, input logic do_mret, input logic do_sret,
                             input logic [XLEN-1:0] pc);
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
    check(exu_csr.rdata === '0, $sformatf(
          "%s reset value is not deterministic zero: %x", name, exu_csr.rdata));
  end
endtask

task automatic set_stce(input bit enable);
`ifdef RAPT_RV64
  write_csr(`RAPT_CSR_MENVCFG, XLEN'(enable) << 63);
`else
  write_csr(`RAPT_CSR_MENVCFGH, XLEN'(enable) << 31);
`endif
  check(csr_bcast.menvcfg_stce == enable, "STCE broadcast did not track the CSR");
endtask

task automatic write_stimecmp(input logic [63:0] value);
`ifdef RAPT_RV64
  write_csr(`RAPT_CSR_STIMECMP, value);
`else
  write_csr(`RAPT_CSR_STIMECMPH, '1);
  write_csr(`RAPT_CSR_STIMECMP, value[31:0]);
  write_csr(`RAPT_CSR_STIMECMPH, value[63:32]);
`endif
endtask

task automatic check_stip(input bit expected);
  exu_csr.raddr = `RAPT_CSR_MIP____;
  #1;
  check(exu_csr.rdata[5] == expected, "mip.STIP source/read-only behavior is wrong");
  exu_csr.raddr = `RAPT_CSR_SIP____;
  #1;
  check(exu_csr.rdata[5] == expected, "delegated sip.STIP disagrees with mip");
endtask
