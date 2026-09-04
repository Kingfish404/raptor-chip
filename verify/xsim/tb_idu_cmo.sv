`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_cmo;
  localparam int XLEN = 64;
  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  ifu_idu_if #(.XLEN(XLEN)) ifu_idu ();
  idu_bpu_if #(.XLEN(XLEN)) idu_bpu ();
  idu_rnu_if #(.XLEN(XLEN)) idu_rnu ();

  rapt_idu #(.XLEN(XLEN)) dut (.*);
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic decode(input logic [31:0] inst);
    ifu_idu.inst_a = inst;
    ifu_idu.valid_a = 1'b1;
    tick(1);
  endtask

  task automatic expect_legal(input logic [4:0] alu, input string name);
    check(idu_rnu.valid_a && !idu_rnu.uop_a.trap, {name, " decoded illegal"});
    check(!idu_rnu.uop_a.ren && idu_rnu.uop_a.wen,
          {name, " did not use the checked CMO/store path"});
    check(idu_rnu.uop_a.alu[4:0] == alu, {name, " has wrong LSU operation tag"});
    check(idu_rnu.uop_a.f_time, {name, " did not serialize at retirement"});
  endtask

  initial begin
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.sys_resume = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_M;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = 3'b111;
    csr_bcast.scounteren = 3'b111;
    csr_bcast.fs = 2'b11;
    csr_bcast.menvcfg_cbie = 2'b00;
    csr_bcast.menvcfg_cbcfe = 1'b0;
    csr_bcast.menvcfg_cbze = 1'b0;
    csr_bcast.senvcfg_cbie = 2'b00;
    csr_bcast.senvcfg_cbcfe = 1'b0;
    csr_bcast.senvcfg_cbze = 1'b0;
    idu_rnu.ready = 1'b1;
    ifu_idu.inst_a = 32'h0000_0013;
    ifu_idu.inst_b = 32'h0000_0013;
    ifu_idu.pc_a = 64'h8000_0000;
    ifu_idu.pc_b = 64'h8000_0004;
    ifu_idu.pnpc = 64'h8000_0004;
    ifu_idu.valid_a = 1'b0;
    ifu_idu.valid_b = 1'b0;
    ifu_idu.trap = 1'b0;
    ifu_idu.cause = '0;
    ifu_idu.tval = '0;
    tick(4);
    reset = 1'b0;
    tick(1);

    // M-mode is never gated by xenvcfg.
    decode(32'h0000_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.INVAL/M");
    decode(32'h0010_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.CLEAN/M");
    decode(32'h0020_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.FLUSH/M");
    decode(32'h0040_a00f); expect_legal(`RAPT_CBO_ZERO_WALU, "CBO.ZERO/M");

    // Zicbop prefetches are architectural HINTs: accepted with no register or
    // memory side effect even when this implementation chooses not to act on them.
    decode(32'h0000_e013);
    check(!idu_rnu.uop_a.trap && !idu_rnu.uop_a.ren && !idu_rnu.uop_a.wen,
          "PREFETCH.I was not accepted as a HINT");
    decode(32'h0010_e013);
    check(!idu_rnu.uop_a.trap && !idu_rnu.uop_a.ren && !idu_rnu.uop_a.wen,
          "PREFETCH.R was not accepted as a HINT");
    decode(32'h0030_e013);
    check(!idu_rnu.uop_a.trap && !idu_rnu.uop_a.ren && !idu_rnu.uop_a.wen,
          "PREFETCH.W was not accepted as a HINT");

    // Zihpm's implementation-defined counters are present as read-only zero.
    decode(32'hc030_20f3); // csrrs x1,hpmcounter3,x0
    check(!idu_rnu.uop_a.trap, "M-mode hpmcounter3 read was illegal");
    decode(32'hb030_90f3); // csrrw x1,mhpmcounter3,x1
    check(!idu_rnu.uop_a.trap, "M-mode mhpmcounter3 WARL-zero write was illegal");
    decode(32'h3230_90f3); // csrrw x1,mhpmevent3,x1
    check(!idu_rnu.uop_a.trap, "M-mode mhpmevent3 WARL-zero write was illegal");
    decode(32'hc830_20f3); // RV32-only hpmcounter3h
    check(idu_rnu.uop_a.trap, "RV64 accepted the RV32-only hpmcounter3h CSR");

    csr_bcast.priv = `RAPT_PRIV_S;
    decode(32'h0040_a00f);
    check(idu_rnu.uop_a.trap && idu_rnu.uop_a.tval == 64'h0040_a00f,
          "S-mode CBO.ZERO ignored menvcfg.CBZE=0");
    csr_bcast.menvcfg_cbie = 2'b01;
    csr_bcast.menvcfg_cbcfe = 1'b1;
    csr_bcast.menvcfg_cbze = 1'b1;
    decode(32'h0000_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.INVAL/S");
    decode(32'h0010_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.CLEAN/S");
    decode(32'h0040_a00f); expect_legal(`RAPT_CBO_ZERO_WALU, "CBO.ZERO/S");

    // U-mode requires both M and S environment enables.
    csr_bcast.priv = `RAPT_PRIV_U;
    decode(32'hc030_20f3);
    check(idu_rnu.uop_a.trap,
          "U-mode accessed hpmcounter3 despite WARL-zero mcounteren[3]");
    decode(32'h0000_a00f);
    check(idu_rnu.uop_a.trap, "U-mode CBO.INVAL ignored senvcfg.CBIE=0");
    csr_bcast.senvcfg_cbie = 2'b01;
    csr_bcast.senvcfg_cbcfe = 1'b1;
    csr_bcast.senvcfg_cbze = 1'b1;
    decode(32'h0000_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.INVAL/U");
    decode(32'h0020_a00f); expect_legal(`RAPT_CBO_MGMT_WALU, "CBO.FLUSH/U");
    decode(32'h0040_a00f); expect_legal(`RAPT_CBO_ZERO_WALU, "CBO.ZERO/U");

    $display("PASS: RVA22 CMO decode and xenvcfg privilege gating");
    $finish;
  end
endmodule
