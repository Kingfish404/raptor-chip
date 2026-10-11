`include "rapt.svh"
`include "rapt_if.svh"

// Floating-point execution unit. Floating-point loads/stores remain in the
// LSU; this unit owns the FP issue queue, scalar arithmetic, conversions,
// completion packets. Architectural FPR/flag updates belong to retirement.
module rapt_feu #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter type UopT = rapt_pkg::uop_t,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned FPQ_SIZE = Cfg.iq_entries,
    parameter unsigned ROB_SIZE = Cfg.rob_entries,
    parameter unsigned PLEN     = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned RLEN     = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned XLEN     = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input clock,
    input reset,
    input logic cancel_valid,
    input logic [$clog2(ROB_SIZE)-1:0] cancel_head,
    cancel_owner,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    input SlotT dispatch[NumSlots],
    dpu_iq_if.rs disp_fpq,

    load_fast_if.sink load_fast,
    output CompletionT wb_fpu,
    input logic wb_accept,
    input logic completion_ready = 1'b1,
    output logic issue_enable
);
  localparam int RobBits = $clog2(ROB_SIZE);
  localparam int GenerationBits = $bits(dispatch[0].generation);
  localparam int OperandTagBits = (PLEN > RobBits + 1 ? PLEN : RobBits + 1) + 1;
  typedef logic [63:0] fp_word_t;
  typedef logic [OperandTagBits-1:0] operand_tag_t;
  typedef logic [RobBits-1:0] owner_t;
  typedef logic [GenerationBits-1:0] generation_t;
  typedef logic [RLEN-1:0] arch_t;
  `RAPT_DISPATCH_SLOT_TYPE(fp_slot_t, UopT, fp_word_t, operand_tag_t, owner_t, generation_t,
                           Cfg.completion_dependencies)
  `RAPT_ISSUE_PACKET_TYPE(fp_issue_t, UopT, fp_word_t, operand_tag_t, owner_t, generation_t)
  `RAPT_COMPLETION_TYPE(fp_wake_t, fp_word_t, operand_tag_t, arch_t, owner_t, generation_t)
  fp_slot_t fp_dispatch[NumSlots];
  fp_issue_t fp_issue[1], iss;
  fp_wake_t fp_wake[NumCompletions];
  localparam int Simple = 0, AddS = 1, AddD = 2, ProductS = 3, ProductD = 4,
      DivSqrt = 5, Widen = 6, Narrow = 7, IntDoubleW = 8, IntDoubleL = 9,
      IntSingleW = 10, IntSingleL = 11, SingleInt = 12, DoubleInt = 13,
      HalfToFp = 14, FpToHalf = 15, Units = 16;
  logic [Units-1:0] unit_ready, unit_credit, arithmetic_ready;
  logic [Units-1:0] raw_valid, unit_accept;
  logic [63:0] raw_result[Units];
  logic [4:0] raw_flags[Units];
  CompletionT launch_packet, unit_launch[Units], unit_completion[Units];
  logic [$clog2(Units)-1:0] completion_cursor, completion_choice;
  logic [$clog2(Units)-1:0] held_choice;
  logic completion_held;
  logic completion_found;
  int selected_unit;

  function automatic operand_tag_t float_tag(input logic [RobBits:0] tag);
    return tag == '0 ? '0 : (operand_tag_t'(1) << (OperandTagBits - 1)) | operand_tag_t'(tag);
  endfunction
  function automatic int execution_unit(input UopT uop);
    int unit_id;
    logic [2:0] rm;
    unit_id = Simple;
    case (uop.execute.fp.op)
      `RAPT_FP_OP_FADD_S, `RAPT_FP_OP_FSUB_S: unit_id = AddS;
      `RAPT_FP_OP_FADD_D, `RAPT_FP_OP_FSUB_D: unit_id = AddD;
      `RAPT_FP_OP_FMUL_S, `RAPT_FP_OP_FMADD_S, `RAPT_FP_OP_FMSUB_S,
      `RAPT_FP_OP_FNMSUB_S, `RAPT_FP_OP_FNMADD_S: unit_id = ProductS;
      `RAPT_FP_OP_FMUL_D, `RAPT_FP_OP_FMADD_D, `RAPT_FP_OP_FMSUB_D,
      `RAPT_FP_OP_FNMSUB_D, `RAPT_FP_OP_FNMADD_D: unit_id = ProductD;
      `RAPT_FP_OP_FDIV_S, `RAPT_FP_OP_FDIV_D,
      `RAPT_FP_OP_FSQRT_S, `RAPT_FP_OP_FSQRT_D: unit_id = DivSqrt;
      `RAPT_FP_OP_FCVT_D_S: unit_id = Widen;
      `RAPT_FP_OP_FCVT_S_D: unit_id = Narrow;
      `RAPT_FP_OP_FCVT_D_W, `RAPT_FP_OP_FCVT_D_WU: unit_id = IntDoubleW;
      `RAPT_FP_OP_FCVT_D_L, `RAPT_FP_OP_FCVT_D_LU: unit_id = IntDoubleL;
      `RAPT_FP_OP_FCVT_S_W, `RAPT_FP_OP_FCVT_S_WU: unit_id = IntSingleW;
      `RAPT_FP_OP_FCVT_S_L, `RAPT_FP_OP_FCVT_S_LU: unit_id = IntSingleL;
      `RAPT_FP_OP_FCVT_W_S, `RAPT_FP_OP_FCVT_WU_S,
      `RAPT_FP_OP_FCVT_L_S, `RAPT_FP_OP_FCVT_LU_S: unit_id = SingleInt;
      `RAPT_FP_OP_FCVT_W_D, `RAPT_FP_OP_FCVT_WU_D,
      `RAPT_FP_OP_FCVT_L_D, `RAPT_FP_OP_FCVT_LU_D: unit_id = DoubleInt;
      `RAPT_FP_OP_ZFHMIN: begin
        if (uop.inst[31:25] == 7'b0100000 || uop.inst[31:25] == 7'b0100001)
          unit_id = HalfToFp;
        else if (uop.inst[31:25] == 7'b0100010) unit_id = FpToHalf;
      end
      default: ;
    endcase
    rm = uop.execute.fp.rm == 3'b111 ? csr_bcast.frm : uop.execute.fp.rm;
    // Illegal rounding modes return a precise exception through the simple
    // pipeline without reserving or launching an arithmetic operation.
    return uop.trap || (unit_id != Simple && rm > 3'b100) ? Simple : unit_id;
  endfunction

  // Adapt both register classes to the generic value-capturing issue queue.
  // A tagged ROB result is a floating-point physical identity; GPR tags occupy
  // the other namespace. Both wake from the same accepted completion event.
  for (genvar s = 0; s < NumSlots; s++) begin : g_dispatch
    always_comb begin
      fp_dispatch[s] = '0;
      fp_dispatch[s].uop = dispatch[s].uop;
      fp_dispatch[s].uop.schedule.issue_ports = '1;
      fp_dispatch[s].op1 = dispatch[s].fp_value[0];
      fp_dispatch[s].op2 = dispatch[s].fp_value[1];
      fp_dispatch[s].op3 = dispatch[s].fp_value[2];
      fp_dispatch[s].pr1 = float_tag(dispatch[s].fp_tag[0]);
      fp_dispatch[s].pr2 = float_tag(dispatch[s].fp_tag[1]);
      fp_dispatch[s].pr3 = float_tag(dispatch[s].fp_tag[2]);
      if (rapt_pkg::fp_from_integer(dispatch[s].uop.execute.fp.op, dispatch[s].uop.inst)) begin
        fp_dispatch[s].op1 = 64'(dispatch[s].op1);
        fp_dispatch[s].pr1 = operand_tag_t'(dispatch[s].pr1);
      end
      fp_dispatch[s].prd = operand_tag_t'(dispatch[s].prd);
      fp_dispatch[s].dest = dispatch[s].dest;
      fp_dispatch[s].generation = dispatch[s].generation;
      fp_dispatch[s].resources = 32'(1) << execution_unit(dispatch[s].uop);
      // Dispatch and a producer may meet on this same edge. Capture its value
      // now; relying only on the queue's next-cycle snoop would lose that pulse.
      for (int c = 0; c < NumCompletions; c++) begin
        if (fp_wake[c].valid && fp_wake[c].prd != '0) begin
          if (fp_dispatch[s].pr1 == fp_wake[c].prd) begin
            fp_dispatch[s].pr1 = '0;
            fp_dispatch[s].op1 = fp_wake[c].result;
          end
          if (fp_dispatch[s].pr2 == fp_wake[c].prd) begin
            fp_dispatch[s].pr2 = '0;
            fp_dispatch[s].op2 = fp_wake[c].result;
          end
          if (fp_dispatch[s].pr3 == fp_wake[c].prd) begin
            fp_dispatch[s].pr3 = '0;
            fp_dispatch[s].op3 = fp_wake[c].result;
          end
        end
      end
    end
  end
  for (genvar p = 0; p < NumCompletions; p++) begin : g_wake
    always_comb begin
      fp_wake[p] = '0;
      fp_wake[p].valid = completion[p].valid && !completion[p].trap
          && (completion[p].fp_wen || completion[p].rd != '0);
      fp_wake[p].prd = completion[p].fp_wen
          ? float_tag((RobBits+1)'(completion[p].dest) + (RobBits+1)'(1))
          : operand_tag_t'(completion[p].prd);
      fp_wake[p].result = completion[p].fp_wen ? completion[p].fp_result : 64'(completion[p].result);
      fp_wake[p].dest = completion[p].dest;
      fp_wake[p].generation = completion[p].generation;
    end
  end
  // The core uses accepted data wakeups, with no speculative fast-load pair.
  load_fast_if #(
      .PLEN(OperandTagBits),
      .ROBLEN(RobBits),
      .GENERATION_BITS(GenerationBits),
      .XLEN(64)
  ) fp_fast ();
  assign fp_fast.valid = 1'b0;
  assign fp_fast.rebusy = 1'b0;
  assign fp_fast.prd = '0;
  assign fp_fast.dest = '0;
  assign fp_fast.generation = '0;
  assign fp_fast.rd = '0;
  assign fp_fast.confirmed = 1'b0;
  assign fp_fast.confirmed_prd = '0;
  assign fp_fast.confirmed_dest = '0;
  assign fp_fast.confirmed_generation = '0;
  assign fp_fast.confirmed_rd = '0;
  assign fp_fast.result = '0;
  assign issue_enable = !reset && !cmu_bcast.flush_pipe;
  assign iss = fp_issue[0];
  rapt_iq #(
      .Cfg(Cfg),
      .SlotT(fp_slot_t),
      .IssueT(fp_issue_t),
      .UopT(UopT),
      .NumSlots(NumSlots),
      .NumCompletions(NumCompletions),
      .CompletionT(fp_wake_t),
      .IQ_SIZE(FPQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN(OperandTagBits),
      .RLEN(RLEN),
      .XLEN(64),
      .ThirdOperand(1'b1),
      .FilterResources(1'b1),
      .NumResources(Units)
  ) u_fpq (
      .clock,
      .reset,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .cmu_bcast,
      .completion(fp_wake),
      .dispatch(fp_dispatch),
      .disp(disp_fpq),
      .load_fast(fp_fast),
      .issue_enable,
      .resource_ready(unit_ready),
      .issue(fp_issue),
      .occ_o(),
      .pmu_iq_full()
  );
  logic [63:0] fp_operand_a, fp_operand_b, fp_operand_c;
  assign fp_operand_a = iss.op1;
  assign fp_operand_b = iss.op2;
  assign fp_operand_c = iss.op3;
  logic [31:0] fp_s1;
  logic [63:0] fp_d1;
  logic [63:0] fp_sgnj_result, fp_compare_result;
  logic [9:0] fp_classify_result;
  logic [4:0] fp_compare_flags;
  logic [63:0] fp_addsub_s_result, fp_addsub_d_result;
  logic [4:0] fp_addsub_s_flags, fp_addsub_d_flags;
  logic fp_addsub_s_ready, fp_addsub_d_ready;
  logic fp_addsub_s_valid, fp_addsub_d_valid;
  logic [63:0] fp_mul_s_result, fp_mul_d_result;
  logic [4:0] fp_mul_s_flags, fp_mul_d_flags;
  logic fp_mul_s_ready, fp_mul_d_ready;
  logic fp_mul_s_valid, fp_mul_d_valid;
  logic [63:0] fp_convert_widen_result, fp_convert_narrow_result;
  logic [4:0] fp_convert_widen_flags, fp_convert_narrow_flags;
  logic fp_convert_widen_ready, fp_convert_widen_valid;
  logic fp_convert_narrow_ready, fp_convert_narrow_valid;
  logic [63:0] fp_int_to_double_w_result, fp_int_to_double_l_result;
  logic [63:0] fp_int_to_single_w_result, fp_int_to_single_l_result;
  logic [4:0] fp_int_to_double_w_flags, fp_int_to_double_l_flags;
  logic [4:0] fp_int_to_single_w_flags, fp_int_to_single_l_flags;
  logic fp_int_to_double_w_ready, fp_int_to_double_l_ready;
  logic fp_int_to_single_w_ready, fp_int_to_single_l_ready;
  logic fp_int_to_double_w_valid, fp_int_to_double_l_valid;
  logic fp_int_to_single_w_valid, fp_int_to_single_l_valid;
  logic [63:0] fp_single_to_int_result, fp_double_to_int_result;
  logic [4:0] fp_single_to_int_flags, fp_double_to_int_flags;
  logic fp_single_to_int_ready, fp_double_to_int_ready;
  logic fp_single_to_int_valid, fp_double_to_int_valid;
  logic [63:0] fp_half_to_fp_result, fp_fp_to_half_result;
  logic [4:0] fp_half_to_fp_flags, fp_fp_to_half_flags;
  logic fp_half_to_fp_ready, fp_half_to_fp_valid;
  logic fp_fp_to_half_ready, fp_fp_to_half_valid;
  logic [63:0] divsqrt_result;
  logic [ 4:0] divsqrt_flags;
  logic divsqrt_ready, divsqrt_result_valid;
  logic fp_addsub_s, fp_addsub_d, fp_mul_s, fp_mul_d, fp_fma_s, fp_fma_d;
  logic fp_divide, fp_sqrt, fp_divsqrt, fp_minmax, fp_compare, fp_classify;
  logic fp_convert_widen, fp_convert_narrow;
  logic fp_zfhmin, fp_fmv_x_h, fp_fmv_h_x;
  logic fp_fcvt_s_h, fp_fcvt_d_h, fp_fcvt_h_s, fp_fcvt_h_d;
  logic fp_half_to_fp, fp_fp_to_half;
  logic fp_int_to_double_w, fp_int_to_double_l, fp_int_to_single_w, fp_int_to_single_l;
  logic fp_single_to_int_w, fp_single_to_int_l, fp_double_to_int_w, fp_double_to_int_l;
  logic fp_double, fp_rm_invalid, fp_trap;
  logic [2:0] fp_rounding_mode;

  logic fp_long_op, fp_launch;
  logic fp_divsqrt_launch, fp_fma_launch, fp_addsub_launch, fp_mul_launch;
  logic fp_convert_narrow_launch, fp_convert_widen_launch;
  logic fp_half_to_fp_launch, fp_fp_to_half_launch, fp_int_to_fp_launch, fp_to_int_launch;
  assign fp_s1 = fp_operand_a[31:0];
  assign fp_d1 = fp_operand_a;
  assign fp_addsub_s = iss.uop.execute.fp.op == `RAPT_FP_OP_FADD_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FSUB_S;
  assign fp_addsub_d = iss.uop.execute.fp.op == `RAPT_FP_OP_FADD_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FSUB_D;
  assign fp_mul_s = iss.uop.execute.fp.op == `RAPT_FP_OP_FMUL_S;
  assign fp_mul_d = iss.uop.execute.fp.op == `RAPT_FP_OP_FMUL_D;
  assign fp_fma_s = iss.uop.execute.fp.op == `RAPT_FP_OP_FMADD_S || iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FMSUB_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FNMSUB_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FNMADD_S;
  assign fp_fma_d = iss.uop.execute.fp.op == `RAPT_FP_OP_FMADD_D || iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FMSUB_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FNMSUB_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FNMADD_D;
  assign fp_divide = iss.uop.execute.fp.op == `RAPT_FP_OP_FDIV_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FDIV_D;
  assign fp_sqrt = iss.uop.execute.fp.op == `RAPT_FP_OP_FSQRT_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FSQRT_D;
  assign fp_divsqrt = fp_divide || fp_sqrt;
  assign fp_minmax = iss.uop.execute.fp.op == `RAPT_FP_OP_FMIN_S || iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FMAX_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FMIN_D || iss.uop.execute.fp.op == `RAPT_FP_OP_FMAX_D;
  assign fp_compare = iss.uop.execute.fp.op == `RAPT_FP_OP_FLE_S || iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FLT_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FEQ_S || iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FLE_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FLT_D || iss.uop.execute.fp.op == `RAPT_FP_OP_FEQ_D;
  assign fp_classify = iss.uop.execute.fp.op == `RAPT_FP_OP_FCLASS_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCLASS_D;
  assign fp_single_to_int_w = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_W_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_WU_S;
  assign fp_single_to_int_l = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_L_S
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_LU_S;
  assign fp_double_to_int_w = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_W_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_WU_D;
  assign fp_double_to_int_l = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_L_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_LU_D;
  assign fp_int_to_single_w = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_S_W
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_WU;
  assign fp_int_to_single_l = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_S_L
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_LU;
  assign fp_int_to_double_w = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_D_W
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_WU;
  assign fp_int_to_double_l = iss.uop.execute.fp.op ==
      `RAPT_FP_OP_FCVT_D_L
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_LU;
  assign fp_convert_widen = iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_S;
  assign fp_convert_narrow = iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_D;
  assign fp_zfhmin = iss.uop.execute.fp.op == `RAPT_FP_OP_ZFHMIN;
  assign fp_fmv_x_h = fp_zfhmin && iss.uop.inst[31:25] == 7'b1110010;
  assign fp_fmv_h_x = fp_zfhmin && iss.uop.inst[31:25] == 7'b1111010;
  assign fp_fcvt_s_h = fp_zfhmin && iss.uop.inst[31:25] == 7'b0100000
      && iss.uop.inst[24:20] == 5'b00010;
  assign fp_fcvt_d_h = fp_zfhmin && iss.uop.inst[31:25] == 7'b0100001
      && iss.uop.inst[24:20] == 5'b00010;
  assign fp_fcvt_h_s = fp_zfhmin && iss.uop.inst[31:25] == 7'b0100010
      && iss.uop.inst[24:20] == 5'b00000;
  assign fp_fcvt_h_d = fp_zfhmin && iss.uop.inst[31:25] == 7'b0100010
      && iss.uop.inst[24:20] == 5'b00001;
  assign fp_half_to_fp = fp_fcvt_s_h || fp_fcvt_d_h;
  assign fp_fp_to_half = fp_fcvt_h_s || fp_fcvt_h_d;
  assign fp_double = iss.uop.execute.fp.op == `RAPT_FP_OP_FDIV_D
      || iss.uop.execute.fp.op == `RAPT_FP_OP_FSQRT_D;
  assign fp_rounding_mode = iss.uop.execute.fp.rm == 3'b111 ? csr_bcast.frm : iss.uop.execute.fp.rm;
  assign fp_rm_invalid = (fp_fma_s || fp_fma_d || fp_divsqrt || fp_convert_widen
    || fp_convert_narrow || fp_int_to_double_w || fp_int_to_single_w
    || fp_int_to_double_l || fp_int_to_single_l || fp_single_to_int_w
    || fp_single_to_int_l || fp_double_to_int_w || fp_double_to_int_l
    || fp_addsub_s || fp_addsub_d || fp_mul_s || fp_mul_d
    || fp_half_to_fp || fp_fp_to_half) && fp_rounding_mode > 3'b100;
  assign fp_trap = iss.uop.trap || fp_rm_invalid;
  assign fp_long_op = fp_divsqrt || fp_fma_s || fp_fma_d
          || fp_addsub_s || fp_addsub_d || fp_mul_s || fp_mul_d
          || fp_convert_narrow || fp_convert_widen
          || fp_int_to_double_w || fp_int_to_double_l
          || fp_int_to_single_w || fp_int_to_single_l
          || fp_single_to_int_w || fp_single_to_int_l
          || fp_double_to_int_w || fp_double_to_int_l
          || fp_half_to_fp || fp_fp_to_half;
  assign fp_launch = iss.valid && fp_long_op && !fp_trap;
  assign fp_divsqrt_launch = fp_launch && fp_divsqrt;
  assign fp_fma_launch = fp_launch && (fp_fma_s || fp_fma_d);
  assign fp_addsub_launch = fp_launch && (fp_addsub_s || fp_addsub_d);
  assign fp_mul_launch = fp_launch && (fp_mul_s || fp_mul_d);
  assign fp_convert_narrow_launch = fp_launch && fp_convert_narrow;
  assign fp_convert_widen_launch = fp_launch && fp_convert_widen;
  assign fp_half_to_fp_launch = fp_launch && fp_half_to_fp;
  assign fp_fp_to_half_launch = fp_launch && fp_fp_to_half;
  assign fp_int_to_fp_launch = fp_launch && (fp_int_to_double_w
        || fp_int_to_double_l || fp_int_to_single_w || fp_int_to_single_l);
  assign fp_to_int_launch = fp_launch && (fp_single_to_int_w
        || fp_single_to_int_l || fp_double_to_int_w || fp_double_to_int_l);
  rapt_fpu_divsqrt #(
      .XLEN(XLEN)
  ) u_divsqrt (
      .clock(clock),
      .reset(reset),
      .operand_a(fp_d1),
      .operand_b(fp_operand_b),
      .rounding_mode(fp_rounding_mode),
      .src_is_double(fp_double),
      .dst_is_double(fp_double),
      .divide(fp_divide),
      .sqrt(fp_sqrt),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_divsqrt_launch),
      .ready(divsqrt_ready),
      .result(divsqrt_result),
      .flags(divsqrt_flags),
      .result_valid(divsqrt_result_valid)
  );
  rapt_fpu_sgnj u_fpu_sgnj (
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .result(fp_sgnj_result)
  );
  rapt_fpu_classify u_fpu_classify (
      .is_double(iss.uop.execute.fp.op == `RAPT_FP_OP_FCLASS_D),
      .operand(fp_operand_a),
      .result(fp_classify_result)
  );
  rapt_fpu_compare u_fpu_compare (
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .result(fp_compare_result),
      .flags(fp_compare_flags)
  );
  rapt_fpu_convert_widen u_fpu_convert_widen (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_convert_widen_launch),
      .ready(fp_convert_widen_ready),
      .operand(fp_operand_a),
      .result(fp_convert_widen_result),
      .flags(fp_convert_widen_flags),
      .result_valid(fp_convert_widen_valid)
  );
  rapt_fpu_convert_narrow u_fpu_convert_narrow (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_convert_narrow_launch),
      .ready(fp_convert_narrow_ready),
      .operand(fp_operand_a),
      .rounding_mode(fp_rounding_mode),
      .result(fp_convert_narrow_result),
      .flags(fp_convert_narrow_flags),
      .result_valid(fp_convert_narrow_valid)
  );
  rapt_fpu_half_to_fp u_fpu_half_to_fp (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_half_to_fp_launch),
      .ready(fp_half_to_fp_ready),
      .operand(fp_operand_a),
      .target_double(fp_fcvt_d_h),
      .result(fp_half_to_fp_result),
      .flags(fp_half_to_fp_flags),
      .result_valid(fp_half_to_fp_valid)
  );
  rapt_fpu_fp_to_half u_fpu_fp_to_half (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_fp_to_half_launch),
      .ready(fp_fp_to_half_ready),
      .operand(fp_operand_a),
      .source_double(fp_fcvt_h_d),
      .rounding_mode(fp_rounding_mode),
      .result(fp_fp_to_half_result),
      .flags(fp_fp_to_half_flags),
      .result_valid(fp_fp_to_half_valid)
  );
  rapt_fpu_int_to_fp #(
      .TARGET_DOUBLE(1'b1),
      .INT64_INPUT  (1'b0)
  ) u_fpu_int_to_double_w (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_int_to_fp_launch && fp_int_to_double_w),
      .ready(fp_int_to_double_w_ready),
      .operand(iss.op1),
      .unsigned_input(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_WU),
      .rounding_mode(fp_rounding_mode),
      .result(fp_int_to_double_w_result),
      .flags(fp_int_to_double_w_flags),
      .result_valid(fp_int_to_double_w_valid)
  );
  rapt_fpu_int_to_fp #(
      .TARGET_DOUBLE(1'b1),
      .INT64_INPUT  (1'b1)
  ) u_fpu_int_to_double_l (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_int_to_fp_launch && fp_int_to_double_l),
      .ready(fp_int_to_double_l_ready),
      .operand(iss.op1),
      .unsigned_input(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_LU),
      .rounding_mode(fp_rounding_mode),
      .result(fp_int_to_double_l_result),
      .flags(fp_int_to_double_l_flags),
      .result_valid(fp_int_to_double_l_valid)
  );
  rapt_fpu_int_to_fp #(
      .TARGET_DOUBLE(1'b0),
      .INT64_INPUT  (1'b0)
  ) u_fpu_int_to_single_w (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_int_to_fp_launch && fp_int_to_single_w),
      .ready(fp_int_to_single_w_ready),
      .operand(iss.op1),
      .unsigned_input(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_WU),
      .rounding_mode(fp_rounding_mode),
      .result(fp_int_to_single_w_result),
      .flags(fp_int_to_single_w_flags),
      .result_valid(fp_int_to_single_w_valid)
  );
  rapt_fpu_int_to_fp #(
      .TARGET_DOUBLE(1'b0),
      .INT64_INPUT  (1'b1)
  ) u_fpu_int_to_single_l (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_int_to_fp_launch && fp_int_to_single_l),
      .ready(fp_int_to_single_l_ready),
      .operand(iss.op1),
      .unsigned_input(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_LU),
      .rounding_mode(fp_rounding_mode),
      .result(fp_int_to_single_l_result),
      .flags(fp_int_to_single_l_flags),
      .result_valid(fp_int_to_single_l_valid)
  );
  rapt_fpu_addsub #(
      .TARGET_DOUBLE(1'b0)
  ) u_fpu_addsub_s (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_addsub_launch && fp_addsub_s),
      .ready(fp_addsub_s_ready),
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .rounding_mode(fp_rounding_mode),
      .result(fp_addsub_s_result),
      .flags(fp_addsub_s_flags),
      .result_valid(fp_addsub_s_valid)
  );
  rapt_fpu_addsub #(
      .TARGET_DOUBLE(1'b1)
  ) u_fpu_addsub_d (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_addsub_launch && fp_addsub_d),
      .ready(fp_addsub_d_ready),
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .rounding_mode(fp_rounding_mode),
      .result(fp_addsub_d_result),
      .flags(fp_addsub_d_flags),
      .result_valid(fp_addsub_d_valid)
  );
  // MUL and FMA share each format's product pipeline. Matching their latency
  // lets the common owner queue identify consecutive mixed results in order.
  rapt_fpu_mul_fma #(
      .TARGET_DOUBLE(1'b0)
  ) u_mul_fma_s (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid((fp_mul_launch && fp_mul_s) || (fp_fma_launch && fp_fma_s)),
      .is_fma(fp_fma_s),
      .ready(fp_mul_s_ready),
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .operand_c(fp_operand_c),
      .rounding_mode(fp_rounding_mode),
      .result(fp_mul_s_result),
      .flags(fp_mul_s_flags),
      .result_valid(fp_mul_s_valid)
  );
  rapt_fpu_mul_fma #(
      .TARGET_DOUBLE(1'b1)
  ) u_mul_fma_d (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid((fp_mul_launch && fp_mul_d) || (fp_fma_launch && fp_fma_d)),
      .is_fma(fp_fma_d),
      .ready(fp_mul_d_ready),
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .operand_c(fp_operand_c),
      .rounding_mode(fp_rounding_mode),
      .result(fp_mul_d_result),
      .flags(fp_mul_d_flags),
      .result_valid(fp_mul_d_valid)
  );
  rapt_fpu_single_to_int_w u_fpu_single_to_int (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch && (fp_single_to_int_w || fp_single_to_int_l)),
      .ready(fp_single_to_int_ready),
      .operand(fp_operand_a),
      .unsigned_result(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_WU_S
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_LU_S),
      .int64_target(fp_single_to_int_l),
      .rounding_mode(fp_rounding_mode),
      .result(fp_single_to_int_result),
      .flags(fp_single_to_int_flags),
      .result_valid(fp_single_to_int_valid)
  );
  rapt_fpu_double_to_int_w u_fpu_double_to_int (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch && (fp_double_to_int_w || fp_double_to_int_l)),
      .ready(fp_double_to_int_ready),
      .operand(fp_operand_a),
      .unsigned_result(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_WU_D
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_LU_D),
      .int64_target(fp_double_to_int_l),
      .rounding_mode(fp_rounding_mode),
      .result(fp_double_to_int_result),
      .flags(fp_double_to_int_flags),
      .result_valid(fp_double_to_int_valid)
  );

  assign selected_unit = execution_unit(iss.uop);
  always_comb begin
    launch_packet = '0;
    launch_packet.valid = iss.valid;
    launch_packet.dest = iss.dest;
    launch_packet.generation = iss.generation;
    launch_packet.prd = PLEN'(iss.prd);
    launch_packet.rd = iss.uop.rd;
    launch_packet.pc = iss.uop.pc;
    launch_packet.npc = iss.uop.pc + (iss.uop.c ? XLEN'(2) : XLEN'(4));
    launch_packet.fp_wen = !fp_trap && rapt_pkg::fp_writes_register(
        iss.uop.execute.fp.valid, iss.uop.execute.fp.op, iss.uop.inst);
    launch_packet.fp_flags_valid = !fp_trap && (fp_long_op || fp_minmax || fp_compare);
    launch_packet.trap = fp_trap;
    launch_packet.tval = iss.uop.trap ? iss.uop.tval : fp_rm_invalid ? XLEN'(iss.uop.inst) : '0;
    launch_packet.cause = iss.uop.trap ? iss.uop.cause
        : fp_rm_invalid ? XLEN'(`RAPT_CAUSE_ILLEGAL_INST) : '0;
    launch_packet.updates = '{control_flow:1'b1, memory:1'b0, system_state:1'b1, exception:1'b1};
  end

  logic [63:0] simple_result;
  logic [4:0] simple_flags;
  always_comb begin
    simple_result = fp_sgnj_result;
    if (fp_minmax || fp_compare) simple_result = fp_compare_result;
    else if (fp_classify) simple_result = {54'b0, fp_classify_result};
    else if (fp_fmv_h_x) simple_result = {48'hffff_ffff_ffff, iss.op1[15:0]};
    else if (fp_fmv_x_h) simple_result = {{48{fp_operand_a[15]}}, fp_operand_a[15:0]};
    else if (iss.uop.execute.fp.op == `RAPT_FP_OP_FMV_W_X)
      simple_result = {32'hffff_ffff, iss.op1[31:0]};
    else if (iss.uop.execute.fp.op == `RAPT_FP_OP_FMV_D_X) simple_result = iss.op1;
    else if (iss.uop.execute.fp.op == `RAPT_FP_OP_FMV_X_W) simple_result = {{32{fp_s1[31]}}, fp_s1};
    else if (iss.uop.execute.fp.op == `RAPT_FP_OP_FMV_X_D) simple_result = fp_d1;
    simple_flags = fp_minmax || fp_compare ? fp_compare_flags : '0;
  end
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) raw_valid[Simple] <= 1'b0;
    else begin
      raw_valid[Simple] <= iss.valid && selected_unit == Simple;
      if (iss.valid && selected_unit == Simple) begin
        raw_result[Simple] <= simple_result;
        raw_flags[Simple] <= simple_flags;
      end
    end
  end
  assign arithmetic_ready[Simple] = 1'b1;
  assign arithmetic_ready[AddS] = fp_addsub_s_ready;
  assign raw_valid[AddS] = fp_addsub_s_valid;
  assign raw_result[AddS] = fp_addsub_s_result;
  assign raw_flags[AddS] = fp_addsub_s_flags;
  assign arithmetic_ready[AddD] = fp_addsub_d_ready;
  assign raw_valid[AddD] = fp_addsub_d_valid;
  assign raw_result[AddD] = fp_addsub_d_result;
  assign raw_flags[AddD] = fp_addsub_d_flags;
  assign arithmetic_ready[ProductS] = fp_mul_s_ready;
  assign raw_valid[ProductS] = fp_mul_s_valid;
  assign raw_result[ProductS] = fp_mul_s_result;
  assign raw_flags[ProductS] = fp_mul_s_flags;
  assign arithmetic_ready[ProductD] = fp_mul_d_ready;
  assign raw_valid[ProductD] = fp_mul_d_valid;
  assign raw_result[ProductD] = fp_mul_d_result;
  assign raw_flags[ProductD] = fp_mul_d_flags;
  assign arithmetic_ready[DivSqrt] = divsqrt_ready;
  assign raw_valid[DivSqrt] = divsqrt_result_valid;
  assign raw_result[DivSqrt] = divsqrt_result;
  assign raw_flags[DivSqrt] = divsqrt_flags;
  assign arithmetic_ready[Widen] = fp_convert_widen_ready;
  assign raw_valid[Widen] = fp_convert_widen_valid;
  assign raw_result[Widen] = fp_convert_widen_result;
  assign raw_flags[Widen] = fp_convert_widen_flags;
  assign arithmetic_ready[Narrow] = fp_convert_narrow_ready;
  assign raw_valid[Narrow] = fp_convert_narrow_valid;
  assign raw_result[Narrow] = fp_convert_narrow_result;
  assign raw_flags[Narrow] = fp_convert_narrow_flags;
  assign arithmetic_ready[IntDoubleW] = fp_int_to_double_w_ready;
  assign raw_valid[IntDoubleW] = fp_int_to_double_w_valid;
  assign raw_result[IntDoubleW] = fp_int_to_double_w_result;
  assign raw_flags[IntDoubleW] = fp_int_to_double_w_flags;
  assign arithmetic_ready[IntDoubleL] = fp_int_to_double_l_ready;
  assign raw_valid[IntDoubleL] = fp_int_to_double_l_valid;
  assign raw_result[IntDoubleL] = fp_int_to_double_l_result;
  assign raw_flags[IntDoubleL] = fp_int_to_double_l_flags;
  assign arithmetic_ready[IntSingleW] = fp_int_to_single_w_ready;
  assign raw_valid[IntSingleW] = fp_int_to_single_w_valid;
  assign raw_result[IntSingleW] = fp_int_to_single_w_result;
  assign raw_flags[IntSingleW] = fp_int_to_single_w_flags;
  assign arithmetic_ready[IntSingleL] = fp_int_to_single_l_ready;
  assign raw_valid[IntSingleL] = fp_int_to_single_l_valid;
  assign raw_result[IntSingleL] = fp_int_to_single_l_result;
  assign raw_flags[IntSingleL] = fp_int_to_single_l_flags;
  assign arithmetic_ready[SingleInt] = fp_single_to_int_ready;
  assign raw_valid[SingleInt] = fp_single_to_int_valid;
  assign raw_result[SingleInt] = fp_single_to_int_result;
  assign raw_flags[SingleInt] = fp_single_to_int_flags;
  assign arithmetic_ready[DoubleInt] = fp_double_to_int_ready;
  assign raw_valid[DoubleInt] = fp_double_to_int_valid;
  assign raw_result[DoubleInt] = fp_double_to_int_result;
  assign raw_flags[DoubleInt] = fp_double_to_int_flags;
  assign arithmetic_ready[HalfToFp] = fp_half_to_fp_ready;
  assign raw_valid[HalfToFp] = fp_half_to_fp_valid;
  assign raw_result[HalfToFp] = fp_half_to_fp_result;
  assign raw_flags[HalfToFp] = fp_half_to_fp_flags;
  assign arithmetic_ready[FpToHalf] = fp_fp_to_half_ready;
  assign raw_valid[FpToHalf] = fp_fp_to_half_valid;
  assign raw_result[FpToHalf] = fp_fp_to_half_result;
  assign raw_flags[FpToHalf] = fp_fp_to_half_flags;

  for (genvar unit_id = 0; unit_id < Units; unit_id++) begin : g_unit
    // The eight-stage product pipe can launch every cycle. Other fixed
    // pipelines are at most three stages; DIV/SQRT keeps one iterative owner.
    localparam int Credits = unit_id == DivSqrt ? 1
        : (unit_id == ProductS || unit_id == ProductD) ? 12 : 6;
    assign unit_ready[unit_id] = arithmetic_ready[unit_id] && unit_credit[unit_id];
    always_comb begin
      unit_launch[unit_id] = launch_packet;
      unit_launch[unit_id].valid = iss.valid && selected_unit == unit_id;
    end
    rapt_fu_result_queue #(
        .CompletionT(CompletionT),
        .Depth(Credits),
        .Entries(ROB_SIZE)
    ) pipe (
        .clock,
        .reset,
        .flush(cmu_bcast.flush_pipe),
        .cancel_valid,
        .cancel_head,
        .cancel_owner,
        .launch(unit_launch[unit_id]),
        .ready(unit_credit[unit_id]),
        .result_valid(raw_valid[unit_id]),
        .result(raw_result[unit_id]),
        .flags(raw_flags[unit_id]),
        .completion(unit_completion[unit_id]),
        .completion_ready(unit_accept[unit_id])
    );
  end
  // Fair completion arbitration. Each producer holds its complete identity,
  // data and flags until selected; simultaneous results are buffered locally.
  always_comb begin
    completion_found = 1'b0;
    completion_choice = '0;
    unit_accept = '0;
    for (int offset = 0; offset < Units; offset++) begin
      automatic int index = (int'(completion_cursor) + offset) % Units;
      if (!completion_found && unit_completion[index].valid) begin
        completion_found = 1'b1;
        completion_choice = $clog2(Units)'(index);
      end
    end
    if (completion_held && unit_completion[held_choice].valid) begin
      completion_found = 1'b1;
      completion_choice = held_choice;
    end
    wb_fpu = unit_completion[completion_choice];
    wb_fpu.valid = completion_found && !reset && !cmu_bcast.flush_pipe;
    if (wb_fpu.valid && completion_ready) unit_accept[completion_choice] = 1'b1;
  end
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      completion_cursor <= '0;
      completion_held <= 1'b0;
    end else begin
      completion_held <= wb_fpu.valid && !completion_ready;
      if (wb_fpu.valid && !completion_ready) held_choice <= completion_choice;
      if (wb_fpu.valid && completion_ready) completion_cursor <= completion_choice + 1'b1;
    end
  end
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, FP_ISSUE_HAS_UNIT, iss.valid,
                  unit_ready[selected_unit])
endmodule
