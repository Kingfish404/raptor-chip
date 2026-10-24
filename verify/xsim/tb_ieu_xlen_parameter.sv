`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_types.svh"

// Deliberately disagree with the build-wide macro. Typed execution units must
// use their own XLEN, including signed operations and MULH's upper product.
module tb_ieu_xlen_parameter #(
    parameter bit CheckMuldiv = 1'b0
);
  import rapt_pkg::*;
  localparam int XLEN = `RAPT_XLEN == 32 ? 64 : 32;
  function automatic core_config_t test_config();
    core_config_t cfg = CoreConfig;
    cfg.xlen = XLEN;
    return cfg;
  endfunction
  localparam core_config_t Cfg = test_config();
  typedef logic [XLEN-1:0] word_t;
  `RAPT_UOP_TYPE(test_uop_t, word_t, arch_reg_t, scheduling_t, execution_payload_t)
  `RAPT_ISSUE_PACKET_TYPE(test_issue_t, test_uop_t, word_t, phys_reg_t, rob_index_t,
                          rob_generation_t)
  `RAPT_DISPATCH_SLOT_TYPE(test_slot_t, test_uop_t, word_t, phys_reg_t, rob_index_t,
                           rob_generation_t, Cfg.completion_dependencies)
  `RAPT_COMPLETION_TYPE(test_completion_t, word_t, phys_reg_t, arch_reg_t, rob_index_t,
                        rob_generation_t)

  logic clock = 1'b0, reset = 1'b1;
  always #5 clock = ~clock;
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  exu_csr_if #(.XLEN(XLEN)) exu_csr ();
  dpu_iq_if #(.RS_SIZE(4)) disp ();
  test_issue_t iss;
  test_completion_t alu_result, mul_result;
  test_completion_t completion[CompletionPorts];
  test_slot_t dispatch[DispatchWidth];

  rapt_ieu_pipe_alu_csr #(
      .XLEN(XLEN),
      .IssueT(test_issue_t),
      .CompletionT(test_completion_t)
  ) alu (
      .cmu_bcast,
      .iss,
      .csr_read_addr(12'b0),
      .csr_bcast,
      .exu_csr,
      .wb_alu_csr(alu_result)
  );
  rapt_ieu_muldiv #(
      .Cfg(Cfg),
      .SlotT(test_slot_t),
      .CompletionT(test_completion_t),
      .MDQ_SIZE(4)
  ) mdq (
      .clock,
      .reset,
      .completion,
      .cancel_valid(1'b0),
      .cancel_head('0),
      .cancel_owner('0),
      .cmu_bcast,
      .dispatch,
      .disp,
      .exu_wb_mul(mul_result)
  );

  `include "tb_core_bcast_defaults.svh"

  task automatic check_alu(input logic [5:0] op, input word_t a, input word_t b,
                           input word_t expected);
    iss = '0;
    iss.valid = 1'b1;
    iss.uop.execute.int_op.alu = op;
    iss.op1 = a;
    iss.op2 = b;
    #1;
    if (!alu_result.valid || alu_result.result !== expected)
      $fatal(
          1,
          "ALU XLEN=%0d macro=%0d op=%h got=%h expected=%h",
          XLEN,
          `RAPT_XLEN,
          op,
          alu_result.result,
          expected
      );
  endtask

  task automatic check_muldiv(input logic [4:0] op, input word_t a, input word_t b,
                              input word_t expected);
    int elapsed;
    @(negedge clock);
    if (!disp.free_found[0]) $fatal(1, "MDQ has no free entry");
    dispatch[0] = '0;
    dispatch[0].dest = rob_index_t'(1);
    dispatch[0].generation = rob_generation_t'(1);
    dispatch[0].uop.rd = arch_reg_t'(1);
    dispatch[0].prd = phys_reg_t'(1);
    dispatch[0].uop.execute.int_op.alu = {1'b0, op};
    dispatch[0].op1 = a;
    dispatch[0].op2 = b;
    disp.rs_idx[0] = disp.free_idx[0];
    disp.accept[0] = 1'b1;
    @(negedge clock);
    disp.accept[0] = 1'b0;
    elapsed = 0;
    while (!mul_result.valid && elapsed < XLEN + 16) begin
      @(negedge clock);
      elapsed++;
    end
    if (!mul_result.valid || mul_result.result !== expected)
      $fatal(
          1,
          "MDQ XLEN=%0d macro=%0d op=%h got=%h expected=%h cycles=%0d",
          XLEN,
          `RAPT_XLEN,
          op,
          mul_result.result,
          expected,
          elapsed
      );
    $display("MDQ XLEN=%0d op=%h cycles after allocation=%0d", XLEN, op, elapsed);
    @(negedge clock);
  endtask

  initial begin
    iss = '0;
    dispatch = '{default: '0};
    completion = '{default: '0};
    for (int s = 0; s < DispatchWidth; s++) begin
      disp.accept[s] = 1'b0;
      disp.rs_idx[s] = '0;
    end
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1'b1);
    exu_csr.rdata = '0;
    exu_csr.rmw_data = '0;
    exu_csr.mepc = '0;
    exu_csr.sepc = '0;
    repeat (3) @(negedge clock);
    reset = 1'b0;
    if (CheckMuldiv) begin
      check_muldiv(`RAPT_ALU_MULH__, word_t'(1) << (XLEN - 1), word_t'(3), ~word_t'(1));
      check_muldiv(`RAPT_ALU_DIV___, word_t'(1) << (XLEN - 1), word_t'(3), word_t'($signed(
                   word_t'(1) << (XLEN - 1)) / 3));
    end else begin
      check_alu(`RAPT_ALU_SRA_, word_t'(1) << (XLEN - 1), word_t'(1), word_t'(3) << (XLEN - 2));
      check_alu(`RAPT_ALU_SRA_, word_t'(1) << (XLEN - 1), word_t'(XLEN - 1), '1);
      check_alu(`RAPT_ALU_ADD_, '1, word_t'(1), '0);
    end
    $display("PASS: execution XLEN=%0d overrides build macro=%0d muldiv=%0d", XLEN, `RAPT_XLEN,
             CheckMuldiv);
    $finish;
  end
endmodule
