`include "rapt.svh"
`include "rapt_if.svh"

// Floating-point execution unit. Floating-point loads/stores remain in the
// LSU; this unit owns the FP issue queue, scalar arithmetic, conversions,
// flags and FPR writes.
module rapt_feu #(
    parameter unsigned FPQ_SIZE = 4,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    rou_exu_if.monitor rou_exu,
    dpu_iq_if.rs disp_fpq,
    cdb_if.in wb_alu_csr,
    cdb_if.in wb_alu,
    cdb_if.in exu_ioq_bcast,
    cdb_if.in exu_wb_mul,
    load_fast_if.sink load_fast,
    fpr_if.alu fpr,
    cdb_if.out wb_fpu,
    output logic issue_enable,
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);
  iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss ();
  iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_unused ();
  logic [$clog2(FPQ_SIZE):0] fpq_occ_unused;
  logic pmu_fpq_full_unused;

  rapt_iq #(
      .IQ_SIZE       (FPQ_SIZE),
      .IN_ORDER_ISSUE(1'b1),
      .ROB_SIZE      (ROB_SIZE),
      .PLEN          (PLEN),
      .RLEN          (RLEN),
      .XLEN          (XLEN)
  ) u_fpq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_fpq),
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .issue_enable (issue_enable),
      .iss          (iss),
      .iss_b        (iss_unused),
      .occ_o        (fpq_occ_unused),
      .pmu_iq_full  (pmu_fpq_full_unused)
  );

  rapt_pkg::uop_payload_t uop_payload;
  assign uop_payload = uop_pl[iss.dest];

  logic [ 4:0] fp_rd;
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
  logic [63:0] fp_fma_s_result, fp_fma_d_result;
  logic [4:0] fp_fma_s_flags, fp_fma_d_flags;
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
  logic [63:0] fp_single_to_int_w_result, fp_single_to_int_l_result;
  logic [63:0] fp_double_to_int_w_result, fp_double_to_int_l_result;
  logic [4:0] fp_single_to_int_w_flags, fp_single_to_int_l_flags;
  logic [4:0] fp_double_to_int_w_flags, fp_double_to_int_l_flags;
  logic fp_single_to_int_w_ready, fp_single_to_int_l_ready;
  logic fp_double_to_int_w_ready, fp_double_to_int_l_ready;
  logic fp_single_to_int_w_valid, fp_single_to_int_l_valid;
  logic fp_double_to_int_w_valid, fp_double_to_int_l_valid;
  logic [63:0] fp_half_to_fp_result, fp_fp_to_half_result;
  logic [4:0] fp_half_to_fp_flags, fp_fp_to_half_flags;
  logic fp_half_to_fp_ready, fp_half_to_fp_valid;
  logic fp_fp_to_half_ready, fp_fp_to_half_valid;
  logic [63:0] divsqrt_result;
  logic [ 4:0] divsqrt_flags;
  logic divsqrt_ready, divsqrt_result_valid;
  logic fp_fma_s_ready, fp_fma_d_ready;
  logic fp_fma_s_valid, fp_fma_d_valid;
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

  typedef enum logic [4:0] {
    FP_PENDING_DIVSQRT,
    FP_PENDING_FMA_S,
    FP_PENDING_FMA_D,
    FP_PENDING_ADDSUB_S,
    FP_PENDING_ADDSUB_D,
    FP_PENDING_MUL_S,
    FP_PENDING_MUL_D,
    FP_PENDING_CONVERT_NARROW,
    FP_PENDING_CONVERT_WIDEN,
    FP_PENDING_INT_TO_DOUBLE_W,
    FP_PENDING_INT_TO_DOUBLE_L,
    FP_PENDING_INT_TO_SINGLE_W,
    FP_PENDING_INT_TO_SINGLE_L,
    FP_PENDING_SINGLE_TO_INT_W,
    FP_PENDING_SINGLE_TO_INT_L,
    FP_PENDING_DOUBLE_TO_INT_W,
    FP_PENDING_DOUBLE_TO_INT_L,
    FP_PENDING_HALF_TO_FP,
    FP_PENDING_FP_TO_HALF
  } fp_pending_kind_e;

  logic fp_long_op, fp_selected_ready, fp_launch, fp_complete;
  logic fp_divsqrt_launch, fp_fma_launch, fp_addsub_launch, fp_mul_launch;
  logic fp_convert_narrow_launch;
  logic fp_convert_widen_launch;
  logic fp_half_to_fp_launch, fp_fp_to_half_launch;
  logic fp_int_to_fp_launch;
  logic fp_to_int_launch;
  logic fp_pending_q, fp_pending_result_valid;
  logic [1:0] fp_release_q;
  fp_pending_kind_e fp_launch_kind, fp_pending_kind_q;
  logic [63:0] fp_pending_result;
  logic [4:0] fp_pending_flags;
  logic [$clog2(ROB_SIZE)-1:0] fp_pending_dest_q;
  logic [`RAPT_PHY_LEN-1:0] fp_pending_prd_q;
  logic [`RAPT_REG_LEN-1:0] fp_pending_rd_q;
  logic [XLEN-1:0] fp_pending_pc_q, fp_pending_pnpc_q;
  logic fp_pending_c_q;
  logic fp_pending_to_gpr_q;
  logic [4:0] fp_pending_frd_q;

  assign fp_rd = iss.fp_rd;
  assign fpr.alu_raddr_a = iss.fp_rs1;
  assign fpr.alu_raddr_b = iss.fp_rs2;
  assign fpr.alu_raddr_c = iss.fp_rs3;
  assign fp_s1 = fpr.alu_rdata_a[31:0];
  assign fp_d1 = fpr.alu_rdata_a;
  assign fp_addsub_s = iss.fp_op == `RAPT_FP_OP_FADD_S || iss.fp_op == `RAPT_FP_OP_FSUB_S;
  assign fp_addsub_d = iss.fp_op == `RAPT_FP_OP_FADD_D || iss.fp_op == `RAPT_FP_OP_FSUB_D;
  assign fp_mul_s = iss.fp_op == `RAPT_FP_OP_FMUL_S;
  assign fp_mul_d = iss.fp_op == `RAPT_FP_OP_FMUL_D;
  assign fp_fma_s = iss.fp_op == `RAPT_FP_OP_FMADD_S || iss.fp_op ==
      `RAPT_FP_OP_FMSUB_S
      || iss.fp_op == `RAPT_FP_OP_FNMSUB_S || iss.fp_op == `RAPT_FP_OP_FNMADD_S;
  assign fp_fma_d = iss.fp_op == `RAPT_FP_OP_FMADD_D || iss.fp_op ==
      `RAPT_FP_OP_FMSUB_D
      || iss.fp_op == `RAPT_FP_OP_FNMSUB_D || iss.fp_op == `RAPT_FP_OP_FNMADD_D;
  assign fp_divide = iss.fp_op == `RAPT_FP_OP_FDIV_S || iss.fp_op == `RAPT_FP_OP_FDIV_D;
  assign fp_sqrt = iss.fp_op == `RAPT_FP_OP_FSQRT_S || iss.fp_op == `RAPT_FP_OP_FSQRT_D;
  assign fp_divsqrt = fp_divide || fp_sqrt;
  assign fp_minmax = iss.fp_op == `RAPT_FP_OP_FMIN_S || iss.fp_op ==
      `RAPT_FP_OP_FMAX_S
      || iss.fp_op == `RAPT_FP_OP_FMIN_D || iss.fp_op == `RAPT_FP_OP_FMAX_D;
  assign fp_compare = iss.fp_op == `RAPT_FP_OP_FLE_S || iss.fp_op ==
      `RAPT_FP_OP_FLT_S
      || iss.fp_op == `RAPT_FP_OP_FEQ_S || iss.fp_op ==
      `RAPT_FP_OP_FLE_D
      || iss.fp_op == `RAPT_FP_OP_FLT_D || iss.fp_op == `RAPT_FP_OP_FEQ_D;
  assign fp_classify = iss.fp_op == `RAPT_FP_OP_FCLASS_S || iss.fp_op == `RAPT_FP_OP_FCLASS_D;
  assign fp_single_to_int_w = iss.fp_op ==
      `RAPT_FP_OP_FCVT_W_S
      || iss.fp_op == `RAPT_FP_OP_FCVT_WU_S;
  assign fp_single_to_int_l = iss.fp_op ==
      `RAPT_FP_OP_FCVT_L_S
      || iss.fp_op == `RAPT_FP_OP_FCVT_LU_S;
  assign fp_double_to_int_w = iss.fp_op ==
      `RAPT_FP_OP_FCVT_W_D
      || iss.fp_op == `RAPT_FP_OP_FCVT_WU_D;
  assign fp_double_to_int_l = iss.fp_op ==
      `RAPT_FP_OP_FCVT_L_D
      || iss.fp_op == `RAPT_FP_OP_FCVT_LU_D;
  assign fp_int_to_single_w = iss.fp_op ==
      `RAPT_FP_OP_FCVT_S_W
      || iss.fp_op == `RAPT_FP_OP_FCVT_S_WU;
  assign fp_int_to_single_l = iss.fp_op ==
      `RAPT_FP_OP_FCVT_S_L
      || iss.fp_op == `RAPT_FP_OP_FCVT_S_LU;
  assign fp_int_to_double_w = iss.fp_op ==
      `RAPT_FP_OP_FCVT_D_W
      || iss.fp_op == `RAPT_FP_OP_FCVT_D_WU;
  assign fp_int_to_double_l = iss.fp_op ==
      `RAPT_FP_OP_FCVT_D_L
      || iss.fp_op == `RAPT_FP_OP_FCVT_D_LU;
  assign fp_convert_widen = iss.fp_op == `RAPT_FP_OP_FCVT_D_S;
  assign fp_convert_narrow = iss.fp_op == `RAPT_FP_OP_FCVT_S_D;
  assign fp_zfhmin = iss.fp_op == `RAPT_FP_OP_ZFHMIN;
  assign fp_fmv_x_h = fp_zfhmin && uop_payload.inst[31:25] == 7'b1110010;
  assign fp_fmv_h_x = fp_zfhmin && uop_payload.inst[31:25] == 7'b1111010;
  assign fp_fcvt_s_h = fp_zfhmin && uop_payload.inst[31:25] == 7'b0100000
      && uop_payload.inst[24:20] == 5'b00010;
  assign fp_fcvt_d_h = fp_zfhmin && uop_payload.inst[31:25] == 7'b0100001
      && uop_payload.inst[24:20] == 5'b00010;
  assign fp_fcvt_h_s = fp_zfhmin && uop_payload.inst[31:25] == 7'b0100010
      && uop_payload.inst[24:20] == 5'b00000;
  assign fp_fcvt_h_d = fp_zfhmin && uop_payload.inst[31:25] == 7'b0100010
      && uop_payload.inst[24:20] == 5'b00001;
  assign fp_half_to_fp = fp_fcvt_s_h || fp_fcvt_d_h;
  assign fp_fp_to_half = fp_fcvt_h_s || fp_fcvt_h_d;
  assign fp_double = iss.fp_op == `RAPT_FP_OP_FDIV_D || iss.fp_op == `RAPT_FP_OP_FSQRT_D;
  assign fp_rounding_mode = iss.fp_rm == 3'b111 ? csr_bcast.frm : iss.fp_rm;
  assign fp_rm_invalid = (fp_fma_s || fp_fma_d || fp_divsqrt || fp_convert_widen
    || fp_convert_narrow || fp_int_to_double_w || fp_int_to_single_w
    || fp_int_to_double_l || fp_int_to_single_l || fp_single_to_int_w
    || fp_single_to_int_l || fp_double_to_int_w || fp_double_to_int_l
    || fp_addsub_s || fp_addsub_d || fp_mul_s || fp_mul_d
    || fp_half_to_fp || fp_fp_to_half) && fp_rounding_mode > 3'b100;
  assign fp_trap = iss.trap || fp_rm_invalid;
  assign fp_long_op = fp_divsqrt || fp_fma_s || fp_fma_d
          || fp_addsub_s || fp_addsub_d || fp_mul_s || fp_mul_d
          || fp_convert_narrow || fp_convert_widen
          || fp_int_to_double_w || fp_int_to_double_l
          || fp_int_to_single_w || fp_int_to_single_l
          || fp_single_to_int_w || fp_single_to_int_l
          || fp_double_to_int_w || fp_double_to_int_l
          || fp_half_to_fp || fp_fp_to_half;
  assign fp_selected_ready = fp_divsqrt ? divsqrt_ready
            : fp_fma_d ? fp_fma_d_ready : fp_fma_s ? fp_fma_s_ready
          : fp_addsub_d ? fp_addsub_d_ready : fp_addsub_s ? fp_addsub_s_ready
          : fp_mul_d ? fp_mul_d_ready : fp_mul_s ? fp_mul_s_ready
          : fp_convert_narrow ? fp_convert_narrow_ready
          : fp_convert_widen ? fp_convert_widen_ready
          : fp_int_to_double_w ? fp_int_to_double_w_ready
          : fp_int_to_double_l ? fp_int_to_double_l_ready
          : fp_int_to_single_w ? fp_int_to_single_w_ready
          : fp_int_to_single_l ? fp_int_to_single_l_ready
          : fp_single_to_int_w ? fp_single_to_int_w_ready
          : fp_single_to_int_l ? fp_single_to_int_l_ready
          : fp_double_to_int_w ? fp_double_to_int_w_ready
          : fp_double_to_int_l ? fp_double_to_int_l_ready
          : fp_half_to_fp ? fp_half_to_fp_ready
          : fp_fp_to_half_ready;

  always_comb begin
    fp_launch_kind = FP_PENDING_DIVSQRT;
    if (fp_fma_s) fp_launch_kind = FP_PENDING_FMA_S;
    else if (fp_fma_d) fp_launch_kind = FP_PENDING_FMA_D;
    else if (fp_addsub_s) fp_launch_kind = FP_PENDING_ADDSUB_S;
    else if (fp_addsub_d) fp_launch_kind = FP_PENDING_ADDSUB_D;
    else if (fp_mul_s) fp_launch_kind = FP_PENDING_MUL_S;
    else if (fp_mul_d) fp_launch_kind = FP_PENDING_MUL_D;
    else if (fp_convert_narrow) fp_launch_kind = FP_PENDING_CONVERT_NARROW;
    else if (fp_convert_widen) fp_launch_kind = FP_PENDING_CONVERT_WIDEN;
    else if (fp_int_to_double_w) fp_launch_kind = FP_PENDING_INT_TO_DOUBLE_W;
    else if (fp_int_to_double_l) fp_launch_kind = FP_PENDING_INT_TO_DOUBLE_L;
    else if (fp_int_to_single_w) fp_launch_kind = FP_PENDING_INT_TO_SINGLE_W;
    else if (fp_int_to_single_l) fp_launch_kind = FP_PENDING_INT_TO_SINGLE_L;
    else if (fp_single_to_int_w) fp_launch_kind = FP_PENDING_SINGLE_TO_INT_W;
    else if (fp_single_to_int_l) fp_launch_kind = FP_PENDING_SINGLE_TO_INT_L;
    else if (fp_double_to_int_w) fp_launch_kind = FP_PENDING_DOUBLE_TO_INT_W;
    else if (fp_double_to_int_l) fp_launch_kind = FP_PENDING_DOUBLE_TO_INT_L;
    else if (fp_half_to_fp) fp_launch_kind = FP_PENDING_HALF_TO_FP;
    else if (fp_fp_to_half) fp_launch_kind = FP_PENDING_FP_TO_HALF;
  end

  assign fp_launch = iss.valid && fp_long_op && !fp_trap && !fp_pending_q && fp_selected_ready;
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

  always_comb begin
    fp_pending_result_valid = 1'b0;
    fp_pending_result = '0;
    fp_pending_flags = '0;
    unique case (fp_pending_kind_q)
      FP_PENDING_DIVSQRT: begin
        fp_pending_result_valid = divsqrt_result_valid;
        fp_pending_result = divsqrt_result;
        fp_pending_flags = divsqrt_flags;
      end
      FP_PENDING_FMA_S: begin
        fp_pending_result_valid = fp_fma_s_valid;
        fp_pending_result = fp_fma_s_result;
        fp_pending_flags = fp_fma_s_flags;
      end
      FP_PENDING_FMA_D: begin
        fp_pending_result_valid = fp_fma_d_valid;
        fp_pending_result = fp_fma_d_result;
        fp_pending_flags = fp_fma_d_flags;
      end
      FP_PENDING_ADDSUB_S: begin
        fp_pending_result_valid = fp_addsub_s_valid;
        fp_pending_result = fp_addsub_s_result;
        fp_pending_flags = fp_addsub_s_flags;
      end
      FP_PENDING_ADDSUB_D: begin
        fp_pending_result_valid = fp_addsub_d_valid;
        fp_pending_result = fp_addsub_d_result;
        fp_pending_flags = fp_addsub_d_flags;
      end
      FP_PENDING_MUL_S: begin
        fp_pending_result_valid = fp_mul_s_valid;
        fp_pending_result = fp_mul_s_result;
        fp_pending_flags = fp_mul_s_flags;
      end
      FP_PENDING_MUL_D: begin
        fp_pending_result_valid = fp_mul_d_valid;
        fp_pending_result = fp_mul_d_result;
        fp_pending_flags = fp_mul_d_flags;
      end
      FP_PENDING_CONVERT_NARROW: begin
        fp_pending_result_valid = fp_convert_narrow_valid;
        fp_pending_result = fp_convert_narrow_result;
        fp_pending_flags = fp_convert_narrow_flags;
      end
      FP_PENDING_CONVERT_WIDEN: begin
        fp_pending_result_valid = fp_convert_widen_valid;
        fp_pending_result = fp_convert_widen_result;
        fp_pending_flags = fp_convert_widen_flags;
      end
      FP_PENDING_INT_TO_DOUBLE_W: begin
        fp_pending_result_valid = fp_int_to_double_w_valid;
        fp_pending_result = fp_int_to_double_w_result;
        fp_pending_flags = fp_int_to_double_w_flags;
      end
      FP_PENDING_INT_TO_DOUBLE_L: begin
        fp_pending_result_valid = fp_int_to_double_l_valid;
        fp_pending_result = fp_int_to_double_l_result;
        fp_pending_flags = fp_int_to_double_l_flags;
      end
      FP_PENDING_INT_TO_SINGLE_W: begin
        fp_pending_result_valid = fp_int_to_single_w_valid;
        fp_pending_result = fp_int_to_single_w_result;
        fp_pending_flags = fp_int_to_single_w_flags;
      end
      FP_PENDING_INT_TO_SINGLE_L: begin
        fp_pending_result_valid = fp_int_to_single_l_valid;
        fp_pending_result = fp_int_to_single_l_result;
        fp_pending_flags = fp_int_to_single_l_flags;
      end
      FP_PENDING_SINGLE_TO_INT_W: begin
        fp_pending_result_valid = fp_single_to_int_w_valid;
        fp_pending_result = fp_single_to_int_w_result;
        fp_pending_flags = fp_single_to_int_w_flags;
      end
      FP_PENDING_SINGLE_TO_INT_L: begin
        fp_pending_result_valid = fp_single_to_int_l_valid;
        fp_pending_result = fp_single_to_int_l_result;
        fp_pending_flags = fp_single_to_int_l_flags;
      end
      FP_PENDING_DOUBLE_TO_INT_W: begin
        fp_pending_result_valid = fp_double_to_int_w_valid;
        fp_pending_result = fp_double_to_int_w_result;
        fp_pending_flags = fp_double_to_int_w_flags;
      end
      FP_PENDING_DOUBLE_TO_INT_L: begin
        fp_pending_result_valid = fp_double_to_int_l_valid;
        fp_pending_result = fp_double_to_int_l_result;
        fp_pending_flags = fp_double_to_int_l_flags;
      end
      FP_PENDING_HALF_TO_FP: begin
        fp_pending_result_valid = fp_half_to_fp_valid;
        fp_pending_result = fp_half_to_fp_result;
        fp_pending_flags = fp_half_to_fp_flags;
      end
      FP_PENDING_FP_TO_HALF: begin
        fp_pending_result_valid = fp_fp_to_half_valid;
        fp_pending_result = fp_fp_to_half_result;
        fp_pending_flags = fp_fp_to_half_flags;
      end
      default: ;
    endcase
  end

  assign fp_complete  = fp_pending_q && fp_pending_result_valid && !cmu_bcast.flush_pipe;
  assign issue_enable = !fp_pending_q && (fp_release_q == 0);

  rapt_fpu_divsqrt #(
      .XLEN(XLEN)
  ) u_divsqrt (
      .clock(clock),
      .reset(reset),
      .operand_a(fp_d1),
      .operand_b(fpr.alu_rdata_b),
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

  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      fp_pending_q <= 1'b0;
      fp_release_q <= '0;
    end else if (fp_launch) begin
      fp_pending_q <= 1'b1;
      fp_release_q <= '0;
      fp_pending_kind_q <= fp_launch_kind;
      fp_pending_dest_q <= iss.dest;
      fp_pending_prd_q <= iss.prd;
      fp_pending_rd_q <= iss.rd;
      fp_pending_pc_q <= iss.pc;
      fp_pending_pnpc_q <= iss.pnpc;
      fp_pending_c_q <= iss.c;
      fp_pending_to_gpr_q <= fp_to_int_launch;
      fp_pending_frd_q <= fp_rd;
    end else if (fp_complete) begin
      fp_pending_q <= 1'b0;
      fp_release_q <= fp_pending_kind_q == FP_PENDING_DIVSQRT ? 0 : 2;
    end else if (fp_release_q) begin
      fp_release_q <= fp_release_q - 1'b1;
    end
  end

  rapt_fpu_sgnj u_fpu_sgnj (
      .op(iss.fp_op),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .result(fp_sgnj_result)
  );
  rapt_fpu_classify u_fpu_classify (
      .is_double(iss.fp_op == `RAPT_FP_OP_FCLASS_D),
      .operand(fpr.alu_rdata_a),
      .result(fp_classify_result)
  );
  rapt_fpu_compare u_fpu_compare (
      .op(iss.fp_op),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .result(fp_compare_result),
      .flags(fp_compare_flags)
  );
  rapt_fpu_convert_widen u_fpu_convert_widen (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_convert_widen_launch),
      .ready(fp_convert_widen_ready),
      .operand(fpr.alu_rdata_a),
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
      .operand(fpr.alu_rdata_a),
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
      .operand(fpr.alu_rdata_a),
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
      .operand(fpr.alu_rdata_a),
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
      .unsigned_input(iss.fp_op == `RAPT_FP_OP_FCVT_D_WU),
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
      .unsigned_input(iss.fp_op == `RAPT_FP_OP_FCVT_D_LU),
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
      .unsigned_input(iss.fp_op == `RAPT_FP_OP_FCVT_S_WU),
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
      .unsigned_input(iss.fp_op == `RAPT_FP_OP_FCVT_S_LU),
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
      .op(iss.fp_op),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
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
      .op(iss.fp_op),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .rounding_mode(fp_rounding_mode),
      .result(fp_addsub_d_result),
      .flags(fp_addsub_d_flags),
      .result_valid(fp_addsub_d_valid)
  );
  rapt_fpu_mul #(
      .TARGET_DOUBLE(1'b0)
  ) u_fpu_mul_s (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_mul_launch && fp_mul_s),
      .ready(fp_mul_s_ready),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .rounding_mode(fp_rounding_mode),
      .result(fp_mul_s_result),
      .flags(fp_mul_s_flags),
      .result_valid(fp_mul_s_valid)
  );
  rapt_fpu_mul #(
      .TARGET_DOUBLE(1'b1)
  ) u_fpu_mul_d (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_mul_launch && fp_mul_d),
      .ready(fp_mul_d_ready),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .rounding_mode(fp_rounding_mode),
      .result(fp_mul_d_result),
      .flags(fp_mul_d_flags),
      .result_valid(fp_mul_d_valid)
  );
  rapt_fpu_fma #(
      .TARGET_DOUBLE(1'b0)
  ) u_fpu_fma_s (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_fma_launch && fp_fma_s),
      .ready(fp_fma_s_ready),
      .op(iss.fp_op),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .operand_c(fpr.alu_rdata_c),
      .rounding_mode(fp_rounding_mode),
      .result(fp_fma_s_result),
      .flags(fp_fma_s_flags),
      .result_valid(fp_fma_s_valid)
  );
  rapt_fpu_fma #(
      .TARGET_DOUBLE(1'b1)
  ) u_fpu_fma_d (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_fma_launch && fp_fma_d),
      .ready(fp_fma_d_ready),
      .op(iss.fp_op),
      .operand_a(fpr.alu_rdata_a),
      .operand_b(fpr.alu_rdata_b),
      .operand_c(fpr.alu_rdata_c),
      .rounding_mode(fp_rounding_mode),
      .result(fp_fma_d_result),
      .flags(fp_fma_d_flags),
      .result_valid(fp_fma_d_valid)
  );
  rapt_fpu_single_to_int_w u_fpu_single_to_int_w (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch && fp_single_to_int_w),
      .ready(fp_single_to_int_w_ready),
      .operand(fpr.alu_rdata_a),
      .unsigned_result(iss.fp_op == `RAPT_FP_OP_FCVT_WU_S),
      .int64_target(1'b0),
      .rounding_mode(fp_rounding_mode),
      .result(fp_single_to_int_w_result),
      .flags(fp_single_to_int_w_flags),
      .result_valid(fp_single_to_int_w_valid)
  );
  rapt_fpu_single_to_int_w u_fpu_single_to_int_l (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch && fp_single_to_int_l),
      .ready(fp_single_to_int_l_ready),
      .operand(fpr.alu_rdata_a),
      .unsigned_result(iss.fp_op == `RAPT_FP_OP_FCVT_LU_S),
      .int64_target(1'b1),
      .rounding_mode(fp_rounding_mode),
      .result(fp_single_to_int_l_result),
      .flags(fp_single_to_int_l_flags),
      .result_valid(fp_single_to_int_l_valid)
  );
  rapt_fpu_double_to_int_w u_fpu_double_to_int_w (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch && fp_double_to_int_w),
      .ready(fp_double_to_int_w_ready),
      .operand(fpr.alu_rdata_a),
      .unsigned_result(iss.fp_op == `RAPT_FP_OP_FCVT_WU_D),
      .int64_target(1'b0),
      .rounding_mode(fp_rounding_mode),
      .result(fp_double_to_int_w_result),
      .flags(fp_double_to_int_w_flags),
      .result_valid(fp_double_to_int_w_valid)
  );
  rapt_fpu_double_to_int_w u_fpu_double_to_int_l (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch && fp_double_to_int_l),
      .ready(fp_double_to_int_l_ready),
      .operand(fpr.alu_rdata_a),
      .unsigned_result(iss.fp_op == `RAPT_FP_OP_FCVT_LU_D),
      .int64_target(1'b1),
      .rounding_mode(fp_rounding_mode),
      .result(fp_double_to_int_l_result),
      .flags(fp_double_to_int_l_flags),
      .result_valid(fp_double_to_int_l_valid)
  );

  assign fpr.alu_wvalid = (fp_complete && !fp_pending_to_gpr_q)
        || (iss.valid && !fp_long_op && iss.fp_valid && !fp_trap
        && !(fp_classify || fp_compare || fp_single_to_int_w
	    || fp_single_to_int_l || fp_double_to_int_w || fp_double_to_int_l)
	    && iss.fp_op != `RAPT_FP_OP_FMV_X_W && iss.fp_op != `RAPT_FP_OP_FMV_X_D
        && !fp_fmv_x_h);
  assign fpr.alu_waddr = fp_pending_q ? fp_pending_frd_q : fp_rd;
  assign fpr.alu_wdata = fp_pending_q ? fp_pending_result
    : fp_minmax ? fp_compare_result : fp_single_to_int_w ? fp_single_to_int_w_result
    : fp_fmv_h_x ? {48'hffff_ffff_ffff, iss.op1[15:0]}
    : iss.fp_op == `RAPT_FP_OP_FMV_W_X ? {32'hffff_ffff, iss.op1[31:0]}
    : iss.fp_op == `RAPT_FP_OP_FMV_D_X ? iss.op1 : fp_sgnj_result;

  assign wb_fpu.dest = fp_pending_q ? fp_pending_dest_q : iss.dest;
  assign wb_fpu.result = fp_pending_q
        ? (fp_pending_to_gpr_q ? fp_pending_result[XLEN-1:0] : '0)
    : (iss.fp_op == `RAPT_FP_OP_FMV_X_W ? {{(XLEN-32){fp_s1[31]}}, fp_s1}
	    : iss.fp_op == `RAPT_FP_OP_FMV_X_D ? fp_d1[XLEN-1:0]
    : fp_fmv_x_h ? {{(XLEN-16){fpr.alu_rdata_a[15]}}, fpr.alu_rdata_a[15:0]}
    : fp_compare ? fp_compare_result[XLEN-1:0]
    : fp_classify ? {{(XLEN-10){1'b0}}, fp_classify_result}
    : fp_single_to_int_w ? fp_single_to_int_w_result[XLEN-1:0]
    : fp_single_to_int_l ? fp_single_to_int_l_result[XLEN-1:0]
    : fp_double_to_int_w ? fp_double_to_int_w_result[XLEN-1:0]
    : fp_double_to_int_l ? fp_double_to_int_l_result[XLEN-1:0] : '0);
  assign wb_fpu.npc = fp_pending_q
        ? fp_pending_pc_q + (fp_pending_c_q ? 2 : 4)
        : iss.pc + (iss.c ? 2 : 4);
  assign wb_fpu.mispredict = wb_fpu.npc != (fp_pending_q ? fp_pending_pnpc_q : iss.pnpc);
  assign wb_fpu.prd = fp_pending_q ? fp_pending_prd_q : iss.prd;
  assign wb_fpu.rd = fp_pending_q ? fp_pending_rd_q : iss.rd;
  assign wb_fpu.pc = fp_pending_q ? fp_pending_pc_q : iss.pc;
  assign wb_fpu.fp_flags_valid = fp_complete
    || ((fp_minmax || fp_compare || fp_single_to_int_w
    || fp_single_to_int_l || fp_double_to_int_w || fp_double_to_int_l
        ) && iss.valid && !fp_trap);
  assign wb_fpu.fp_flags = fp_pending_q ? fp_pending_flags
        : (fp_double_to_int_l ? fp_double_to_int_l_flags
    : fp_double_to_int_w ? fp_double_to_int_w_flags : fp_single_to_int_l ? fp_single_to_int_l_flags
    : fp_single_to_int_w ? fp_single_to_int_w_flags
    : (fp_minmax || fp_compare) ? fp_compare_flags : divsqrt_flags);
  assign wb_fpu.trap = fp_pending_q ? 1'b0 : fp_trap;
  assign wb_fpu.tval = fp_pending_q ? '0
        : (iss.trap ? iss.tval : fp_rm_invalid ? uop_payload.inst : '0);
  assign wb_fpu.cause = fp_pending_q ? '0
        : (iss.trap ? iss.cause : fp_rm_invalid ? `RAPT_CAUSE_ILLEGAL_INST : '0);
  assign wb_fpu.valid = fp_pending_q ? fp_complete : fp_launch ? 1'b0 : iss.valid;
  assign wb_fpu.btaken = 1'b0;
  assign wb_fpu.csr_wen = 1'b0;
  assign wb_fpu.csr_wdata = '0;
  assign wb_fpu.wen = 1'b0;
  assign wb_fpu.alu = '0;
  assign wb_fpu.sq_waddr = '0;
  assign wb_fpu.sq_wdata = '0;
  assign wb_fpu.sq_wdata64 = '0;
  assign wb_fpu.sq_fp64 = 1'b0;
  assign wb_fpu.difftest_skip = 1'b0;
endmodule
