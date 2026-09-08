`include "rapt.svh"
`include "rapt_if.svh"

module tb_muldiv_flush_reuse #(
    parameter bit CheckOperandIndependence = 0
);
  localparam int XLEN = `RAPT_XLEN;
  localparam int MdqSize = 4;
  localparam int RobBits = $clog2(`RAPT_ROB_SIZE);

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  logic dispatch_ready[rapt_pkg::DispatchWidth];
  dpu_iq_if #(.RS_SIZE(MdqSize)) disp ();
  rapt_pkg::completion_t exu_rou;
  rapt_pkg::completion_t exu_rou_b;
  rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t exu_wb_mul;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  assign completion[0] = exu_rou;
  assign completion[1] = exu_rou_b;
  assign completion[2] = '0;
  assign completion[3] = exu_ioq_bcast;
  assign completion[4] = exu_wb_mul;

  rapt_ieu_muldiv #(
      .MDQ_SIZE(MdqSize)
  ) dut (
      .completion(completion),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .dispatch(dispatch),
      .disp(disp),

      .exu_wb_mul(exu_wb_mul)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();

      dispatch[0].uop = '0;
      dispatch[0].op1 = '0;
      dispatch[0].op2 = '0;
      dispatch[0].pr1 = '0;
      dispatch[0].pr2 = '0;
      dispatch[0].prd = '0;
      dispatch[0].prs = '0;
      dispatch[0].dest = '0;

`ifdef RAPT_DUAL_ISSUE
      dispatch[1].uop = '0;
      dispatch[1].op1 = '0;
      dispatch[1].op2 = '0;
      dispatch[1].pr1 = '0;
      dispatch[1].pr2 = '0;
      dispatch[1].prd = '0;
      dispatch[1].prs = '0;
      dispatch[1].dest = '0;

`endif

      disp.accept[0] = 1'b0;
      disp.accept[1] = 1'b0;
      disp.rs_idx[1] = '0;

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
      input logic [4:0] alu, input logic [XLEN-1:0] op1, input logic [XLEN-1:0] op2,
      input logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest, input logic [`RAPT_PHY_LEN-1:0] prd,
      input logic [`RAPT_REG_LEN-1:0] rd, input logic [XLEN-1:0] pc, input logic word_op,
      input logic [`RAPT_PHY_LEN-1:0] wait_pr1 = '0);
    begin
      check(disp.free_found[0], "MULDIV queue had no free dispatch slot");
      dispatch[0].uop = '0;
      dispatch[0].uop.pc = pc;
      dispatch[0].uop.pnpc = pc + XLEN'(4);
      dispatch[0].uop.execute.int_op.alu = {1'b0, alu};
      dispatch[0].uop.rd = rd;
      dispatch[0].uop.execute.int_op.word = word_op;
      dispatch[0].op1 = op1;
      dispatch[0].op2 = op2;
      dispatch[0].pr1 = wait_pr1;
      dispatch[0].pr2 = '0;
      dispatch[0].prd = prd;
      dispatch[0].dest = dest;

      disp.accept[0] = 1'b1;
      tick(1);

      disp.accept[0] = 1'b0;
    end
  endtask

  int paired_mdq_issues = 0, paired_mdq_completions = 0, differing_mdq_issues = 0;
  if (CheckOperandIndependence) begin : g_pair
    rapt_pkg::dispatch_slot_t other_dispatch[rapt_pkg::DispatchWidth];
    rapt_pkg::completion_t other_completion[rapt_pkg::CompletionPorts];
    rapt_pkg::completion_t other_wb;
    dpu_iq_if #(.RS_SIZE(MdqSize)) other_disp ();
    rapt_ieu_muldiv #(
        .MDQ_SIZE(MdqSize)
    ) other (
        .completion(other_completion),
        .clock,
        .reset,
        .cmu_bcast,
        .dispatch(other_dispatch),
        .disp(other_disp),
        .exu_wb_mul(other_wb)
    );
    for (genvar s = 0; s < rapt_pkg::DispatchWidth; s++) begin
      assign other_disp.accept[s] = disp.accept[s];
      assign other_disp.rs_idx[s] = disp.rs_idx[s];
      always_comb begin
        other_dispatch[s] = dispatch[s];
        other_dispatch[s].op1 = ~dispatch[s].op1;
        other_dispatch[s].op2 = ~dispatch[s].op2;
      end
    end
    for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin
      if (p == 4) assign other_completion[p] = other_wb;
      else
        always_comb begin
          other_completion[p] = completion[p];
          other_completion[p].result = ~completion[p].result;
        end
    end
    always @(posedge clock)
      if (!reset) begin
        for (int s = 0; s < rapt_pkg::DispatchWidth; s++)
        assert ({disp.free_found[s], disp.free_idx[s]} == {other_disp.free_found[s], other_disp.free_idx[s]})
        else $fatal(1, "operand-dependent MDQ capacity/allocation");
        assert ({dut.sel_found, dut.fu_in_ready} == {other.sel_found, other.fu_in_ready})
        else $fatal(1, "operand-dependent MDQ issue timing");
        if (dut.sel_found)
          assert (dut.sel_idx == other.sel_idx)
          else $fatal(1, "operand-dependent MDQ issue identity");
        if (!cmu_bcast.flush_pipe && dut.sel_found && dut.fu_in_ready) begin
          paired_mdq_issues++;
          if (dut.mdq_vj[dut.sel_idx] != other.mdq_vj[other.sel_idx]
            || dut.mdq_vk[dut.sel_idx] != other.mdq_vk[other.sel_idx])
            differing_mdq_issues++;
        end
        assert (exu_wb_mul.valid == other_wb.valid)
        else $fatal(1, "operand-dependent MDQ completion timing");
        if (exu_wb_mul.valid) begin
          automatic rapt_pkg::completion_t a = exu_wb_mul, b = other_wb;
          a.result = '0;
          b.result = '0;
          assert (a == b)
          else $fatal(1, "operand-dependent MDQ completion identity");
          paired_mdq_completions++;
        end
      end
  end

  task automatic mdq_wakeup_cases;
    int count;
    for (int mode = 0; mode < 3; mode++) begin
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      if (mode == 0) begin
        exu_rou.valid = 1;
        exu_rou.prd = `RAPT_PHY_LEN'(17);
        exu_rou.result = XLEN'(6);
      end
      if (mode == 2)
        dispatch_md(`RAPT_ALU_MUL___, XLEN'(6), XLEN'(7), RobBits'(20), `RAPT_PHY_LEN'(17), 5'd5,
                    XLEN'('h80003000), 0);
      dispatch_md(`RAPT_ALU_MUL___, XLEN'(0), XLEN'(mode == 2 ? 2 : 7), RobBits'(21),
                  `RAPT_PHY_LEN'(18), 5'd6, XLEN'('h80003004), 0, `RAPT_PHY_LEN'(17));
      exu_rou.valid = 0;
      if (mode == 1) begin
        repeat (3) begin
          tick(1);
          check(!exu_wb_mul.valid, "unready MDQ consumer completed");
        end
        exu_ioq_bcast.valid = 1;
        exu_ioq_bcast.prd = `RAPT_PHY_LEN'(17);
        exu_ioq_bcast.result = XLEN'(6);
        tick(1);
        exu_ioq_bcast.valid = 0;
      end
      count = 0;
      repeat (20) begin
        #1;
        if (exu_wb_mul.valid) begin
          count++;
          check(exu_wb_mul.dest == RobBits'(21) || (mode == 2 && exu_wb_mul.dest == RobBits'(20)),
                "unexpected MDQ wakeup identity");
          check(exu_wb_mul.result == XLEN'(mode == 2 && exu_wb_mul.dest == RobBits'(21) ? 84 : 42),
                "MDQ wakeup/self-forward arithmetic mismatch");
        end
        tick(1);
      end
      check(count == (mode == 2 ? 2 : 1), "MDQ wakeup completion count");
      $display("PASS: MDQ wakeup mode=%0d XLEN=%0d", mode, XLEN);
    end
  endtask

  assign disp.rs_idx[0] = disp.free_idx[0];
  initial begin
    int writeback_count;

    init_inputs();
    tick(4);
    reset = 1'b0;
    tick(1);

    dispatch_md(`RAPT_ALU_DIV___, XLEN'(32'h7000_0000), XLEN'(7), RobBits'(3), `RAPT_PHY_LEN'(17),
                5'd5, XLEN'(32'h8000_1000), 1'b0);
    tick(1);
    tick(5);
    check(!exu_wb_mul.valid, "old DIV completed before the flush probe");

    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    #1;
    check(!exu_wb_mul.valid, "MULDIV leaked writeback during flush");
    check(disp.free_found[0] && disp.free_idx[0] == '0,
          "MULDIV flush did not release the original MDQ slot");

    dispatch_md(`RAPT_ALU_MUL___, XLEN'(6), XLEN'(7), RobBits'(9), `RAPT_PHY_LEN'(21), 5'd8,
                XLEN'(32'h8000_2000), 1'b0);

    writeback_count = 0;
    for (int cycle = 0; cycle < 48; cycle++) begin
      #1;
      if (exu_wb_mul.valid) begin
        writeback_count++;
        check(exu_wb_mul.dest == RobBits'(9),
              "post-flush MULDIV writeback used the old ROB destination");
        check(exu_wb_mul.prd == `RAPT_PHY_LEN'(21),
              "post-flush MULDIV writeback used the old physical destination");
        check(exu_wb_mul.rd == 5'd8,
              "post-flush MULDIV writeback used the old architectural destination");
        check(exu_wb_mul.pc == XLEN'(32'h8000_2000),
              "post-flush MULDIV writeback used the old PC payload");
        check(exu_wb_mul.result == XLEN'(42), "post-flush MULDIV result was corrupted");
      end
      tick(1);
    end

    check(writeback_count == 1,
          "flushed DIV leaked a completion or replacement MUL did not complete");

`ifdef RAPT_RV64
    // W-form DIV/REM must normalize operands to 32 bits before iterating,
    // then sign-extend the 32-bit architectural result to XLEN.
    dispatch_md(`RAPT_ALU_REM___, 64'hf641_b4b4_2611_af1e, 64'hfc6a_47a7_3bc8_996b, RobBits'(10),
                `RAPT_PHY_LEN'(22), 5'd18, 64'h8000_3000, 1'b1);
    writeback_count = 0;
    for (int cycle = 0; cycle < 80; cycle++) begin
      #1;
      if (exu_wb_mul.valid) begin
        writeback_count++;
        check(exu_wb_mul.result == 64'h0000_0000_2611_af1e, "RV64 REMW used upper operand bits");
      end
      tick(1);
    end
    check(writeback_count == 1, "RV64 REMW did not complete exactly once");

    dispatch_md(`RAPT_ALU_DIVU__, 64'h0123_4567_89ab_cdef, 64'hdead_beef_0000_0000, RobBits'(11),
                `RAPT_PHY_LEN'(23), 5'd19, 64'h8000_4000, 1'b1);
    writeback_count = 0;
    for (int cycle = 0; cycle < 80; cycle++) begin
      #1;
      if (exu_wb_mul.valid) begin
        writeback_count++;
        check(exu_wb_mul.result == 64'hffff_ffff_ffff_ffff,
              "RV64 DIVUW did not apply 32-bit divide-by-zero semantics");
      end
      tick(1);
    end
    check(writeback_count == 1, "RV64 DIVUW did not complete exactly once");

    dispatch_md(`RAPT_ALU_REMU__, 64'hffff_ffff_d109_5000, 64'h0000_0000_ffff_ffff, RobBits'(12),
                `RAPT_PHY_LEN'(24), 5'd20, 64'h8000_5000, 1'b1);
    writeback_count = 0;
    for (int cycle = 0; cycle < 80; cycle++) begin
      #1;
      if (exu_wb_mul.valid) begin
        writeback_count++;
        check(exu_wb_mul.result == 64'hffff_ffff_d109_5000,
              "RV64 REMUW did not sign-extend a nonzero remainder");
      end
      tick(1);
    end
    check(writeback_count == 1, "RV64 REMUW did not complete exactly once");

    dispatch_md(`RAPT_ALU_REMU__, 64'hffff_ffff_d109_5000, 64'h1234_5678_0000_0000, RobBits'(13),
                `RAPT_PHY_LEN'(25), 5'd21, 64'h8000_6000, 1'b1);
    writeback_count = 0;
    for (int cycle = 0; cycle < 80; cycle++) begin
      #1;
      if (exu_wb_mul.valid) begin
        writeback_count++;
        check(exu_wb_mul.result == 64'hffff_ffff_d109_5000,
              "RV64 REMUW divide-by-zero result was not sign-extended");
      end
      tick(1);
    end
    check(writeback_count == 1, "RV64 REMUW divide-by-zero did not complete exactly once");
`endif

    if (CheckOperandIndependence) begin
      mdq_wakeup_cases();
      check(paired_mdq_issues >= 6 && paired_mdq_completions >= 5 && differing_mdq_issues >= 6,
            "insufficient paired MDQ coverage");
      $display("PASS: paired MDQ issues=%0d completions=%0d differing=%0d XLEN=%0d",
               paired_mdq_issues, paired_mdq_completions, differing_mdq_issues, XLEN);
    end
    $display("PASS: MULDIV flush-kill and MDQ reuse xsim checks passed");
    $finish;
  end
endmodule
