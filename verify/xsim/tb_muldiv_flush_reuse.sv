`include "rapt.svh"
`include "rapt_if.svh"

module tb_muldiv_flush_reuse;
  localparam int XLEN = `RAPT_XLEN;
      localparam int MdqSize = 4;

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if cmu_bcast();
      csr_bcast_if csr_bcast();
  rou_exu_if rou_exu();
  dpu_iq_if #(.RS_SIZE(MdqSize)) disp();
  cdb_if exu_rou();
  cdb_if exu_rou_b();
  cdb_if exu_ioq_bcast();
  cdb_if exu_wb_mul();

  rapt_ieu_muldiv #(
        .MDQ_SIZE(MdqSize)
  ) dut (
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .rou_exu(rou_exu),
      .disp(disp),
      .exu_rou(exu_rou),
      .exu_rou_b(exu_rou_b),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul(exu_wb_mul)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();

      rou_exu.uop = '0;
      rou_exu.op1 = '0;
      rou_exu.op2 = '0;
      rou_exu.pr1 = '0;
      rou_exu.pr2 = '0;
      rou_exu.prd = '0;
      rou_exu.prs = '0;
      rou_exu.dest = '0;
      rou_exu.valid = 1'b0;
`ifdef RAPT_DUAL_ISSUE
      rou_exu.uop_b = '0;
      rou_exu.op1_b = '0;
      rou_exu.op2_b = '0;
      rou_exu.pr1_b = '0;
      rou_exu.pr2_b = '0;
      rou_exu.prd_b = '0;
      rou_exu.prs_b = '0;
      rou_exu.dest_b = '0;
      rou_exu.valid_b = 1'b0;
`endif

      disp.accept_a = 1'b0;
      disp.accept_b = 1'b0;
      disp.b_rs_idx = '0;
      disp.iss_b_block_a = 1'b0;
      disp.iss_b_block_b = 1'b0;

      exu_rou.valid = 1'b0;
      exu_rou.prd = '0;
      exu_rou.result = '0;
      exu_rou_b.valid = 1'b0;
      exu_rou_b.prd = '0;
      exu_rou_b.result = '0;
      exu_ioq_bcast.valid = 1'b0;
      exu_ioq_bcast.prd = '0;
      exu_ioq_bcast.result = '0;
    end
  endtask

  task automatic dispatch_md(
      input logic [4:0] alu,
      input logic [XLEN-1:0] op1,
      input logic [XLEN-1:0] op2,
      input logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest,
      input logic [`RAPT_PHY_LEN-1:0] prd,
      input logic [`RAPT_REG_LEN-1:0] rd,
      input logic [XLEN-1:0] pc
  );
    begin
      check(disp.free_found_a, "MULDIV queue had no free dispatch slot");
      rou_exu.uop = '0;
      rou_exu.uop.pc = pc;
      rou_exu.uop.pnpc = pc + XLEN'(4);
      rou_exu.uop.alu = {1'b0, alu};
      rou_exu.uop.rd = rd;
      rou_exu.op1 = op1;
      rou_exu.op2 = op2;
      rou_exu.prd = prd;
      rou_exu.dest = dest;
      rou_exu.valid = 1'b1;
      disp.accept_a = 1'b1;
      tick(1);
      rou_exu.valid = 1'b0;
      disp.accept_a = 1'b0;
    end
  endtask

  initial begin
    int writeback_count;

    init_inputs();
    tick(4);
    reset = 1'b0;
    tick(1);

    dispatch_md(`RAPT_ALU_DIV___, XLEN'(32'h7000_0000), XLEN'(7),
                5'd3, 6'd17, 5'd5, XLEN'(32'h8000_1000));
    tick(1);
    tick(5);
    check(!exu_wb_mul.valid, "old DIV completed before the flush probe");

    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    #1;
    check(!exu_wb_mul.valid, "MULDIV leaked writeback during flush");
    check(disp.free_found_a && disp.free_idx_a == '0,
          "MULDIV flush did not release the original MDQ slot");

    dispatch_md(`RAPT_ALU_MUL___, XLEN'(6), XLEN'(7),
                5'd9, 6'd21, 5'd8, XLEN'(32'h8000_2000));

    writeback_count = 0;
    for (int cycle = 0; cycle < 48; cycle++) begin
      #1;
      if (exu_wb_mul.valid) begin
        writeback_count++;
        check(exu_wb_mul.dest == 5'd9,
              "post-flush MULDIV writeback used the old ROB destination");
        check(exu_wb_mul.prd == 6'd21,
              "post-flush MULDIV writeback used the old physical destination");
        check(exu_wb_mul.rd == 5'd8,
              "post-flush MULDIV writeback used the old architectural destination");
        check(exu_wb_mul.pc == XLEN'(32'h8000_2000),
              "post-flush MULDIV writeback used the old PC payload");
        check(exu_wb_mul.result == XLEN'(42),
              "post-flush MULDIV result was corrupted");
      end
      tick(1);
    end

    check(writeback_count == 1,
          "flushed DIV leaked a completion or replacement MUL did not complete");
    $display("PASS: MULDIV flush-kill and MDQ reuse xsim checks passed");
    $finish;
  end
endmodule
