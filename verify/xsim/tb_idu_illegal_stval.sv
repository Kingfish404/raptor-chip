`include "rapt.svh"
`include "rapt_if.svh"

module tb_idu_illegal_stval;
  localparam int XLEN = 64;

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  ifu_idu_if #(.XLEN(XLEN)) ifu_idu ();
  idu_bpu_if #(.XLEN(XLEN)) idu_bpu ();
  idu_rnu_if #(.XLEN(XLEN)) idu_rnu ();

  rapt_idu #(.XLEN(XLEN)) dut (
      .clock,
      .cmu_bcast,
      .csr_bcast,
      .ifu_idu,
      .idu_bpu,
      .idu_rnu,
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic drive_packet(
      input logic [31:0] inst_a,
      input logic [XLEN-1:0] pc_a,
      input logic [31:0] inst_b,
      input logic [XLEN-1:0] pc_b,
      input logic valid_b,
      input logic [XLEN-1:0] pnpc);
    begin
      ifu_idu.inst_a = inst_a;
      ifu_idu.pc_a = pc_a;
      ifu_idu.inst_b = inst_b;
      ifu_idu.pc_b = pc_b;
      ifu_idu.valid_b = valid_b;
      ifu_idu.pnpc = pnpc;
      ifu_idu.valid_a = 1'b1;
      tick(1);
    end
  endtask

  initial begin
    cmu_bcast.flush_pipe = 1'b0;
    cmu_bcast.sys_resume = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_S;
    csr_bcast.tsr = 1'b0;
    csr_bcast.tvm = 1'b0;
    csr_bcast.tw = 1'b0;
    csr_bcast.mcounteren = 3'b111;
    csr_bcast.scounteren = 3'b111;
    csr_bcast.fs = 2'b11;
    idu_rnu.ready = 1'b1;

    ifu_idu.inst_a = 32'h0000_0013;
    ifu_idu.pc_a = 64'h8000_0000;
    ifu_idu.inst_b = 32'h0000_0013;
    ifu_idu.pc_b = 64'h8000_0004;
    ifu_idu.valid_a = 1'b0;
    ifu_idu.valid_b = 1'b0;
    ifu_idu.pnpc = 64'h8000_0004;
    ifu_idu.trap = 1'b0;
    ifu_idu.cause = '0;
    ifu_idu.tval = '0;

    tick(4);
    reset = 1'b0;
    tick(1);

    // Q0/funct3=100/funct3-low=011 with bit6=1 is a nonzero reserved Zcb
    // encoding.  The decompressor emits its illegal sentinel (zero), but
    // Sstvala must retain the original 16 bits in tval.
    drive_packet(32'h0000_8c40, 64'h8000_0100,
                 32'h0000_0013, 64'h8000_0102, 1'b0, 64'h8000_0102);
    check(idu_rnu.valid_a && idu_rnu.uop_a.trap,
          "reserved compressed instruction did not trap in slot A");
    check(idu_rnu.uop_a.cause == `RAPT_CAUSE_ILLEGAL_INST,
          "reserved compressed instruction reported the wrong cause");
    check(idu_rnu.uop_a.tval == 64'h0000_0000_0000_8c40,
          "slot-A illegal compressed instruction lost its raw stval bits");

    // Exercise the independent slot-B decode path as well.
    drive_packet(32'h0000_0013, 64'h8000_0200,
                 32'h0000_8c40, 64'h8000_0204, 1'b1, 64'h8000_0206);
    check(idu_rnu.valid_b && idu_rnu.uop_b.trap,
          "reserved compressed instruction did not trap in slot B");
    check(idu_rnu.uop_b.tval == 64'h0000_0000_0000_8c40,
          "slot-B illegal compressed instruction lost its raw stval bits");

    // The same mux must preserve all 32 bits for an ordinary illegal opcode.
    drive_packet(32'hffff_ffff, 64'h8000_0300,
                 32'h0000_0013, 64'h8000_0304, 1'b0, 64'h8000_0304);
    check(idu_rnu.uop_a.trap && idu_rnu.uop_a.tval == 64'h0000_0000_ffff_ffff,
          "illegal 32-bit instruction did not remain right-justified in stval");

    $display("PASS: RVA20S64 Sstvala illegal-instruction checks passed");
    $finish;
  end
endmodule
