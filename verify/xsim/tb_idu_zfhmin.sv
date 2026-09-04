`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_zfhmin;
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

  task automatic check_zfh(input string name);
    check(idu_rnu.valid_a, {name, " was not accepted"});
    check(!idu_rnu.uop_a.trap, {name, " decoded illegal"});
    check(idu_rnu.uop_a.fp_valid, {name, " did not enter FP/LSU path"});
    check(idu_rnu.uop_a.fp_op == `RAPT_FP_OP_ZFHMIN,
          {name, " has wrong FP operation tag"});
  endtask

  initial begin
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.sys_resume = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_U;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = 3'b111;
    csr_bcast.scounteren = 3'b111;
    csr_bcast.fs = 2'b11;
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

    decode(32'h0000_9107); // flh f2,0(x1)
    check_zfh("FLH");
    check(idu_rnu.uop_a.ren && !idu_rnu.uop_a.wen
          && idu_rnu.uop_a.alu == `RAPT_ALU_LH__, "FLH LSU width/control mismatch");

    decode(32'h0020_9027); // fsh f2,0(x1)
    check_zfh("FSH");
    check(!idu_rnu.uop_a.ren && idu_rnu.uop_a.wen
          && idu_rnu.uop_a.alu == `RAPT_SH_WSTRB, "FSH LSU width/control mismatch");

    decode(32'he400_8153); // fmv.x.h x2,f1
    check_zfh("FMV.X.H");
    check(idu_rnu.uop_a.rd == 2 && !idu_rnu.uop_a.ren && !idu_rnu.uop_a.wen,
          "FMV.X.H integer destination mismatch");

    decode(32'hf400_8153); // fmv.h.x f2,x1
    check_zfh("FMV.H.X");
    check(idu_rnu.uop_a.rd == 0 && idu_rnu.rs1_a == 1,
          "FMV.H.X integer source/FPR destination mismatch");

    decode(32'h4020_8153); check_zfh("FCVT.S.H");
    decode(32'h4400_8153); check_zfh("FCVT.H.S");
    decode(32'h4220_8153); check_zfh("FCVT.D.H");
    decode(32'h4410_8153); check_zfh("FCVT.H.D");

    csr_bcast.fs = 2'b00;
    decode(32'h4020_8153);
    check(idu_rnu.uop_a.trap && idu_rnu.uop_a.cause == `RAPT_CAUSE_ILLEGAL_INST,
          "Zfhmin did not honor mstatus.FS=Off");

    $display("PASS: RVA22U64 Zfhmin decode and LSU controls");
    $finish;
  end
endmodule
