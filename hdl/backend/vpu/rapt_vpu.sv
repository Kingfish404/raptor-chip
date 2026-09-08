`include "rapt_sva.svh"

// Standalone, head-authorized vector engine. Integer execution currently uses
// one natural-aligned element at a time; other RVV classes remain illegal until
// implemented. Host register access is an idle-only debug/context interface,
// not an ISA bypass available during execution. No scalar core package needed.
module rapt_vpu #(
    parameter int XLEN = 64,
    parameter int VLEN = 128,
    parameter int ELEN = 64,
    parameter int TagBits = 10,
    parameter int BankBits = 64,
    parameter int Banks = 2,
    parameter bit OptimizeOperandReads = 1,
    parameter int AddrBits = $clog2(32*VLEN/8)
) (
    input logic clock,
    reset,
    input logic vector_enabled,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [TagBits-1:0] cmd_tag,
    input logic [31:0] cmd_insn,
    input logic [XLEN-1:0] cmd_rs1,
    cmd_rs2,
    input logic [63:0] cmd_frs1,
    input logic [2:0] cmd_frm,
    input logic cmd_fp_enabled,
    input logic authorize_valid,
    output logic authorize_ready,
    input logic [TagBits-1:0] authorize_tag,
    input logic kill_valid,
    input logic [TagBits-1:0] kill_tag,
    output logic cancelled,
    kill_blocked,
    busy,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [TagBits-1:0] rsp_tag,
    output logic rsp_trap,
    output logic [XLEN-1:0] rsp_cause,
    rsp_tval,
    output logic [4:0] rsp_rd,
    output logic [XLEN-1:0] rsp_result,
    output logic rsp_dirty,
    output logic [4:0] rsp_fflags,
    output logic rsp_fp_dirty,
    output logic rsp_fp_write,
    output logic [63:0] rsp_fp_result,
    output logic mem_valid,
    input logic mem_ready,
    output logic mem_write,
    mem_probe,
    output logic [XLEN-1:0] mem_addr,
    output logic [1:0] mem_size,
    output logic [63:0] mem_wdata,
    output logic [TagBits-1:0] mem_tag,
    output logic [$clog2(VLEN):0] mem_index,
    output logic [2:0] mem_field,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input logic [TagBits-1:0] mem_rsp_tag,
    input logic [$clog2(VLEN):0] mem_rsp_index,
    input logic [2:0] mem_rsp_field,
    input logic mem_rsp_probe,
    input logic [63:0] mem_rdata,
    input logic mem_fault,
    mem_non_idempotent,
    input logic [XLEN-1:0] mem_cause,
    mem_tval,
    output logic mem_response_dropped,
    input logic host_valid,
    output logic host_ready,
    input logic host_write,
    input logic [AddrBits-1:0] host_addr,
    input logic [1:0] host_size,
    input logic [63:0] host_wdata,
    output logic host_rsp_valid,
    input logic host_rsp_ready,
    output logic [63:0] host_rdata
);
  localparam int IndexBits = $clog2(VLEN) + 1;
  localparam int RowBits   = $clog2(32 * VLEN / BankBits / Banks);
  typedef struct packed {
    logic [31:0] insn;
    logic [XLEN-1:0] rs1, rs2;
    logic [63:0] frs1;
    logic [2:0] frm;
    logic fp_enabled;
  } command_t;
  typedef struct packed {
    logic trap;
    logic [XLEN-1:0] cause, tval;
    logic [4:0] rd;
    logic [XLEN-1:0] value;
    logic dirty;
    logic [4:0] fflags;
    logic fp_dirty;
    logic fp_write;
    logic [63:0] fp_value;
  } result_t;
  typedef enum logic [5:0] {
    IDLE,
    DECODE,
    CONFIGURE,
    CSR,
    CHECK,
    NEXT_ELEMENT,
    MASK_REQ,
    MASK_RSP,
    A_REQ,
    A_RSP,
    B_REQ,
    B_RSP,
    WRITE_REQ,
    WRITE_RSP,
    FINISH,
    COMPLETE,
    MEMORY_START,
    MEMORY_RUN,
    MULDIV_START,
    MULDIV_RUN,
    OLD_REQ,
    OLD_RSP,
    MASK_WRITE_START,
    MASK_WRITE_RUN,
    REDUCE_START,
    REDUCE_RUN,
    MOVE_START,
    MOVE_RUN,
    SCALAR_CHECK,
    SCALAR_REQ,
    SCALAR_RSP,
    SCAN_START,
    SCAN_RUN,
    SLIDE_ROUTE,
    GATHER_ROUTE,
    FP_START,
    FP_RUN,
    FT_ROUTE,
    FT_REQ,
    FT_RSP,
    FR_START,
    FR_RUN
  } state_t;
  state_t state;
  command_t command_in, engine_command, command_q;
  result_t result_q, response;
  logic owner_ready, owner_busy, engine_valid, engine_ready, result_ready;
  logic [TagBits-1:0] engine_tag, tag_q;
  logic dropped;
  logic fp_recognized, fp_legal, fp_scalar, fp_old, fp_neg_product, fp_neg_addend;
  logic ft_recognized, ft_legal, ft_scalar, ft_write_vector, ft_write_scalar, ft_read_source;
  logic [2:0] ft_operation;
  logic [IndexBits-1:0] ft_source_index, ft_destination_index;
  logic [63:0] ft_result;
  logic raw_fp_recognized, raw_fp_legal;
  logic if_recognized, if_legal, if_to_float, if_unsigned, if_widen, if_narrow, if_double;
  logic [1:0] if_integer_size;
  logic [2:0] if_rm, if_select;
  logic [4:0] if_ready, if_valid, if_illegal;
  logic [4:0][63:0] if_result;
  logic [4:0][4:0] if_flags;
  logic fr_recognized, fr_legal, fr_active, fr_ready, fr_done, fr_trap;
  logic fr_vr_valid, fr_vr_write, fr_vr_rsp_ready;
  logic [AddrBits-1:0] fr_vr_addr;
  logic [1:0] fr_vr_size, fr_op;
  logic [63:0] fr_vr_wdata, fr_a, fr_b, fr_result;
  logic [4:0] fr_flags, fr_service_flags;
  logic fr_req_valid, fr_req_ready, fr_rsp_valid, fr_rsp_ready, fr_double, fr_illegal;
  logic [2:0] fr_rm;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] unused_fr_op;
  logic unused_fr_double, unused_fr_widen, unused_fr_ordered;
  /* verilator lint_on UNUSEDSIGNAL */
  logic raw_narrow, fp_convert, fp_narrow;
  // Only the ELEN64 conversion instance consumes this decoder control.
  /* verilator lint_off UNUSEDSIGNAL */
  logic fp_odd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic convert_ready, convert_valid, convert_illegal;
  logic [63:0] convert_result;
  logic [4:0] convert_flags;
  logic raw_widen, raw_wide_a, fp_widen, fp_wide_a;
  logic [63:0] fp_expanded_a, fp_expanded_b, fp_exec_a, fp_exec_b;
  logic raw_mask_result, fp_misc, fp_mask_result;
  logic [3:0] fp_misc_operation;
  logic [1:0][63:0] fp_misc_result;
  logic [1:0][4:0] fp_misc_flags;
  logic [1:0] fp_misc_illegal;
  logic raw_src_vector, fp_divsqrt, fp_sqrt, fp_uses_vs1;
  logic
      div_ready, div_valid, div_illegal, selected_fp_ready, selected_fp_valid, selected_fp_illegal;
  logic [63:0] div_result, selected_fp_result;
  logic [4:0] div_flags, selected_fp_flags;
  logic [1:0] fp_operation;
  logic [63:0] fp_a, fp_b, fp_c, fp_result_q;
  logic [1:0] fp_ready, fp_valid, fp_illegal;
  logic [1:0][63:0] fp_result;
  logic [1:0][4:0] fp_flags;
  logic [4:0] fp_element_flags;
  logic host_pending;
  logic [IndexBits-1:0] index_q;
  logic [1:0] sew_q, a_size_q, d_size_q, g_a_size, g_d_size;
  logic d_widen, d_wide_a, d_narrow, d_extend, d_a_signed, d_b_signed;
  logic [1:0] d_extend_shift;
  logic [5:0] d_alu_op;
  logic geometry_legal;
  logic d_fixed, d_fraction, fixed_saturated, saturated_q;
  logic [3:0] d_fixed_op;
  logic [63:0] fixed_result;
  logic [127:0] md_full_product, fixed_product_q;
  logic [63:0] a_input, b_input;
  logic [63:0] a_q, b_q, alu_result, scalar_b;
  logic mask_q, enabled_q;
  logic
      d_config,
      d_csr,
      d_integer,
      d_memory,
      d_src_vector,
      d_vs2,
      d_merge,
      d_illegal,
      d_muldiv,
      d_mac,
      d_mask_result,
      d_mask_logic,
      d_carry;
  logic mw_ready, mw_done, mw_vr_valid, mw_vr_write, mw_vr_rsp_ready;
  logic [AddrBits-1:0] mw_vr_addr;
  logic [7:0] mw_vr_wdata;
  logic md_ready, md_valid;
  logic [63:0] md_result, md_result_q, old_q, md_a, md_addend;
  state_t execute_state;
  logic d_iota, d_compress, d_slide, d_gather, d_gather16;
  logic [63:0] gather_index;
  logic [1:0] b_size;
  logic slide_write, slide_read, slide_scalar;
  logic [IndexBits-1:0] slide_index, element_vlmax;
  int signed element_lm;
  int unsigned element_capacity;
  logic [IndexBits-1:0] iota_count_q;
  logic d_mask_prefix, prefix_seen_q, prefix_value;
  logic d_mask_scan, s_ready, s_done, s_trap, s_vr_valid, s_vr_rsp_ready;
  logic [AddrBits-1:0] s_vr_addr;
  logic [XLEN-1:0] s_value;
  logic d_scalar_move, d_element_index;
  logic d_move, c_ready, c_done, c_trap, c_vr_valid, c_vr_write, c_vr_rsp_ready;
  logic [AddrBits-1:0] c_vr_addr;
  logic [1:0] c_vr_size;
  logic [63:0] c_vr_wdata;
  logic d_reduce, r_ready, r_done, r_trap, r_vr_valid, r_vr_write, r_vr_rsp_ready;
  logic [AddrBits-1:0] r_vr_addr;
  logic [1:0] r_vr_size;
  logic [63:0] r_vr_wdata;
  logic m_ready, m_done, m_trap, m_update, m_fof;
  logic [XLEN-1:0] m_cause, m_tval, m_vl;
  logic [$clog2(VLEN)-1:0] m_vstart;
  logic m_vr_valid, m_vr_write, m_vr_rsp_ready;
  logic [AddrBits-1:0] m_vr_addr;
  logic [1:0] m_vr_size;
  logic [63:0] m_vr_wdata;
  logic bad_group;
  logic [XLEN-1:0] cfg_type, cfg_avl, cfg_result;
  logic cfg_max, cfg_keep, cfg_illegal;
  logic csr_write, csr_illegal, csr_dirty;
  logic [XLEN-1:0] csr_rdata, csr_wdata, csr_operand;
  logic [XLEN-1:0] vtype, vl;
  logic [$clog2(VLEN)-1:0] vstart;
  logic [1:0] vxrm;
  /* verilator lint_off UNUSEDSIGNAL */
  logic vxsat;
  /* verilator lint_on UNUSEDSIGNAL */
  logic elem_valid, elem_ready, elem_write, elem_rsp_valid, elem_rsp_ready;
  logic [AddrBits-1:0] elem_addr;
  logic [1:0] elem_size;
  logic [63:0] elem_wdata, elem_rdata;
  logic [Banks-1:0] bank_valid, bank_ready, bank_write, bank_rsp_valid, bank_rsp_ready;
  logic [Banks-1:0][RowBits-1:0] bank_row;
  logic [Banks-1:0][BankBits-1:0] bank_wdata, bank_rdata;
  logic [Banks-1:0][BankBits/8-1:0] bank_be;

  assign command_in = {cmd_insn, cmd_rs1, cmd_rs2, cmd_frs1, cmd_frm, cmd_fp_enabled};
  assign cmd_ready = owner_ready && !host_pending && !host_valid;
  assign busy = owner_busy || host_pending;
  assign engine_ready = state == IDLE;
  assign {rsp_trap, rsp_cause, rsp_tval, rsp_rd, rsp_result, rsp_dirty, rsp_fflags, rsp_fp_dirty, rsp_fp_write, rsp_fp_result} = response;
  rapt_vpu_owner #(
      .TagBits(TagBits),
      .CommandBits($bits(command_t)),
      .ResultBits($bits(result_t))
  ) u_owner (
      .clock(clock),
      .reset(reset),
      .cmd_valid(cmd_valid && !host_pending && !host_valid),
      .cmd_ready(owner_ready),
      .cmd_tag(cmd_tag),
      .cmd_payload(command_in),
      .authorize_valid(authorize_valid),
      .authorize_ready(authorize_ready),
      .authorize_tag(authorize_tag),
      .kill_valid(kill_valid),
      .kill_tag(kill_tag),
      .cancelled(cancelled),
      .kill_blocked(kill_blocked),
      .busy(owner_busy),
      .engine_valid(engine_valid),
      .engine_ready(engine_ready),
      .engine_tag(engine_tag),
      .engine_payload(engine_command),
      .result_valid(state == COMPLETE),
      .result_ready(result_ready),
      .result_tag(tag_q),
      .result_payload(result_q),
      .result_dropped(dropped),
      .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready),
      .rsp_tag(rsp_tag),
      .rsp_payload(response)
  );
  rapt_vpu_decode u_decode (
      .insn(command_q.insn),
      .is_config(d_config),
      .is_csr(d_csr),
      .is_integer(d_integer),
      .is_memory(d_memory),
      .is_reduce(d_reduce),
      .is_move(d_move),
      .is_scalar_move(d_scalar_move),
      .element_index(d_element_index),
      .is_mask_scan(d_mask_scan),
      .mask_prefix(d_mask_prefix),
      .iota(d_iota),
      .compress(d_compress),
      .slide(d_slide),
      .gather(d_gather),
      .gather16(d_gather16),
      .src_vector(raw_src_vector),
      .uses_vs2(d_vs2),
      .merge(d_merge),
      .muldiv(d_muldiv),
      .mac(d_mac),
      .mask_result(raw_mask_result),
      .mask_logic(d_mask_logic),
      .carry(d_carry),
      .widen(raw_widen),
      .wide_a(raw_wide_a),
      .narrow(raw_narrow),
      .extend(d_extend),
      .a_signed(d_a_signed),
      .b_signed(d_b_signed),
      .extend_shift(d_extend_shift),
      .alu_op(d_alu_op),
      .fixed_point(d_fixed),
      .fraction(d_fraction),
      .fixed_op(d_fixed_op),
      .illegal(d_illegal)
  );
  assign d_narrow = if_recognized ? if_narrow : fp_recognized ? fp_narrow : raw_narrow;
  assign d_widen = if_recognized ? if_widen : fp_recognized ? fp_widen : raw_widen;
  assign d_wide_a = fp_recognized ? fp_wide_a : raw_wide_a;
  rapt_vpu_fp_widen u_fp_expand_a (
      .value(fp_a[31:0]),
      .result(fp_expanded_a)
  );
  rapt_vpu_fp_widen u_fp_expand_b (
      .value(fp_b[31:0]),
      .result(fp_expanded_b)
  );
  assign fr_active = state == FR_START || state == FR_RUN;
  rapt_vpu_fp_reduce_decode #(
      .ELEN(ELEN)
  ) u_fr_decode (
      .insn(command_q.insn),
      .sew(vtype[5:3]),
      .frm(command_q.frm),
      .enabled(enabled_q && command_q.fp_enabled),
      .vill(vtype[XLEN-1]),
      .recognized(fr_recognized),
      .legal(fr_legal),
      .operation(unused_fr_op),
      .source_double(unused_fr_double),
      .widen(unused_fr_widen),
      .ordered_sum(unused_fr_ordered)
  );
  rapt_vpu_fp_reduce_engine #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) u_fr_engine (
      .clock(clock),
      .reset(reset),
      .cmd_valid(state == FR_START),
      .cmd_ready(fr_ready),
      .cmd_insn(command_q.insn),
      .cmd_vtype(vtype),
      .cmd_vl(vl),
      .cmd_vstart(vstart),
      .cmd_frm(command_q.frm),
      .cmd_enabled(enabled_q && command_q.fp_enabled),
      .done_valid(fr_done),
      .done_ready(state == FR_RUN),
      .done_trap(fr_trap),
      .done_flags(fr_flags),
      .vr_valid(fr_vr_valid),
      .vr_ready(elem_ready && fr_active),
      .vr_write(fr_vr_write),
      .vr_addr(fr_vr_addr),
      .vr_size(fr_vr_size),
      .vr_wdata(fr_vr_wdata),
      .vr_rsp_valid(elem_rsp_valid && fr_active),
      .vr_rsp_ready(fr_vr_rsp_ready),
      .vr_rdata(elem_rdata),
      .service_req_valid(fr_req_valid),
      .service_req_ready(fr_req_ready),
      .service_op(fr_op),
      .service_double(fr_double),
      .service_rm(fr_rm),
      .service_a(fr_a),
      .service_b(fr_b),
      .service_rsp_valid(fr_rsp_valid),
      .service_rsp_ready(fr_rsp_ready),
      .service_result(fr_result),
      .service_flags(fr_service_flags),
      .service_illegal(fr_illegal)
  );
  assign fr_req_ready = fr_op == 0 ? fp_ready[fr_double] : 1'b1;
  assign fr_rsp_valid = fr_active && (fr_op == 0 ? fp_valid[fr_double] : fr_req_valid);
  assign fr_result = fr_op == 0 ? fp_result[fr_double] : fp_misc_result[fr_double];
  assign fr_service_flags = fr_op == 0 ? fp_flags[fr_double] : fp_misc_flags[fr_double];
  assign fr_illegal = fr_op == 0 ? fp_illegal[fr_double] : fp_misc_illegal[fr_double];
  assign fp_exec_a = fp_widen && !fp_wide_a ? fp_expanded_a : fp_a;
  assign fp_exec_b = fp_widen ? fp_expanded_b : fp_b;
  assign d_mask_result = fp_recognized ? fp_mask_result : raw_mask_result;
  assign d_src_vector = fp_recognized ? (fp_uses_vs1 && !fp_scalar) : raw_src_vector;
  rapt_vpu_fp_decode #(
      .ELEN(ELEN)
  ) u_fp_decode (
      .insn(command_q.insn),
      .sew(vtype[5:3]),
      .frm(command_q.frm),
      .enabled(enabled_q && command_q.fp_enabled),
      .vill(vtype[XLEN-1]),
      .vs2(a_q),
      .vs1(b_q),
      .old_destination(old_q),
      .scalar(command_q.frs1),
      .recognized(raw_fp_recognized),
      .legal(raw_fp_legal),
      .source_scalar(fp_scalar),
      .format_convert(fp_convert),
      .narrow(fp_narrow),
      .round_odd(fp_odd),
      .widen(fp_widen),
      .wide_source_a(fp_wide_a),
      .miscellaneous(fp_misc),
      .mask_result(fp_mask_result),
      .misc_operation(fp_misc_operation),
      .divide_sqrt(fp_divsqrt),
      .sqrt_operation(fp_sqrt),
      .uses_vs1(fp_uses_vs1),
      .uses_old_destination(fp_old),
      .operation(fp_operation),
      .negate_product(fp_neg_product),
      .negate_addend(fp_neg_addend),
      .a(fp_a),
      .b(fp_b),
      .c(fp_c)
  );
  assign fp_recognized = raw_fp_recognized || if_recognized || ft_recognized || fr_recognized;
  assign fp_legal = raw_fp_legal || if_legal || ft_legal || fr_legal;
  assign ft_scalar = ft_recognized && (ft_operation == 2 || ft_operation == 3);
  rapt_vpu_fp_transfer #(
      .ELEN(ELEN),
      .VLEN(VLEN)
  ) u_fp_transfer (
      .insn(command_q.insn),
      .sew(vtype[5:3]),
      .frm(command_q.frm),
      .enabled(enabled_q && command_q.fp_enabled),
      .vill(vtype[XLEN-1]),
      .mask_bit(mask_q),
      .scalar(command_q.frs1),
      .vector_element(state == FT_RSP ? elem_rdata : a_q),
      .index(index_q),
      .vl(IndexBits'(vl)),
      .vlmax(element_vlmax),
      .vstart(IndexBits'(vstart)),
      .recognized(ft_recognized),
      .legal(ft_legal),
      .operation(ft_operation),
      .write_vector(ft_write_vector),
      .write_scalar(ft_write_scalar),
      .read_source(ft_read_source),
      .source_index(ft_source_index),
      .destination_index(ft_destination_index),
      .result(ft_result)
  );
  rapt_vpu_int_fp_decode #(
      .ELEN(ELEN)
  ) u_int_fp_decode (
      .insn(command_q.insn),
      .sew(vtype[5:3]),
      .frm(command_q.frm),
      .enabled(enabled_q && command_q.fp_enabled),
      .vill(vtype[XLEN-1]),
      .recognized(if_recognized),
      .legal(if_legal),
      .to_float(if_to_float),
      .unsigned_integer(if_unsigned),
      .widen(if_widen),
      .narrow(if_narrow),
      .float_double(if_double),
      .integer_size(if_integer_size),
      .rounding_mode(if_rm)
  );
  // Five ISA width pairs: FP32/I16, FP32/I32, FP32/I64, FP64/I32, FP64/I64.
  assign if_select = if_double ? (if_integer_size == 3 ? 3'd4 : 3'd3)
      : if_integer_size == 3 ? 3'd2 : if_integer_size == 2 ? 3'd1 : 3'd0;
  for (genvar pair_index = 0; pair_index < 5; pair_index++) begin : gen_int_fp
    if (pair_index < 2 || ELEN >= 64) begin : gen_supported
      localparam int IntegerBits = pair_index == 0 ? 16 : (pair_index == 1 || pair_index == 3) ? 32 : 64;
      rapt_vpu_int_fp #(
          .FloatDouble(pair_index >= 3),
          .IntBits(IntegerBits)
      ) u_convert (
          .clock(clock),
          .reset(reset),
          .req_valid(state == FP_START && if_recognized && if_select == 3'(pair_index)),
          .req_ready(if_ready[pair_index]),
          .to_float(if_to_float),
          .unsigned_integer(if_unsigned),
          .operand(a_q),
          .rm(if_rm),
          .rsp_valid(if_valid[pair_index]),
          .rsp_ready(state == FP_RUN && if_recognized && if_select == 3'(pair_index)),
          .result(if_result[pair_index]),
          .flags(if_flags[pair_index]),
          .illegal(if_illegal[pair_index])
      );
    end else begin : gen_absent
      assign if_ready[pair_index] = 0;
      assign if_valid[pair_index] = 0;
      assign if_result[pair_index] = 0;
      assign if_flags[pair_index] = 0;
      assign if_illegal[pair_index] = 0;
    end
  end
  for (genvar precision = 0; precision < 2; precision++) begin : gen_fp
    if (precision == 0 || ELEN >= 64) begin : gen_supported
      logic [63:0] misc_result, estimate_result;
      logic [4:0] misc_flags, estimate_flags;
      logic misc_illegal, estimate_illegal, estimate_selected;
      assign estimate_selected = !fr_active && (fp_misc_operation == 12 || fp_misc_operation == 13);
      rapt_vpu_fp_misc #(
          .Double(precision == 1)
      ) u_misc (
          .a(fr_active ? fr_a : fp_a),
          .b(fr_active ? fr_b : fp_b),
          .operation(fr_active ? (fr_op == 2 ? 4'd1 : 4'd0) : fp_misc_operation),
          .result(misc_result),
          .flags(misc_flags),
          .illegal(misc_illegal)
      );
      rapt_vpu_fp_estimate #(
          .Double(precision == 1)
      ) u_estimate (
          .operand(fp_a),
          .reciprocal_sqrt(fp_misc_operation == 13),
          .rm(command_q.frm),
          .result(estimate_result),
          .flags(estimate_flags),
          .illegal(estimate_illegal)
      );
      assign fp_misc_result[precision] = estimate_selected ? estimate_result : misc_result;
      assign fp_misc_flags[precision] = estimate_selected ? estimate_flags : misc_flags;
      assign fp_misc_illegal[precision] = estimate_selected ? estimate_illegal : misc_illegal;
      rapt_vpu_fp_arith #(
          .Double(precision == 1)
      ) u_arith (
          .clock(clock),
          .reset(reset),
          .req_valid((fr_active && fr_req_valid && fr_op == 0 && fr_double == 1'(precision)) || (state == FP_START && !if_recognized && !fp_divsqrt && !fp_misc && !fp_convert && d_size_q == 2'(precision+2))),
          .req_ready(fp_ready[precision]),
          .operation(fr_active ? 2'd1 : fp_operation),
          .a(fr_active ? fr_a : fp_exec_a),
          .b(fr_active ? fr_b : fp_exec_b),
          .c(fr_active ? 64'd0 : fp_c),
          .negate_product(!fr_active && fp_neg_product),
          .negate_addend(!fr_active && fp_neg_addend),
          .rm(fr_active ? fr_rm : command_q.frm),
          .rsp_valid(fp_valid[precision]),
          .rsp_ready((fr_active && fr_rsp_ready && fr_op == 0 && fr_double == 1'(precision)) || (state == FP_RUN && !if_recognized && !fp_divsqrt && !fp_misc && !fp_convert && d_size_q == 2'(precision+2))),
          .result(fp_result[precision]),
          .flags(fp_flags[precision]),
          .illegal(fp_illegal[precision])
      );
    end else begin : gen_absent
      assign fp_misc_result[precision] = 0;
      assign fp_misc_flags[precision] = 0;
      assign fp_misc_illegal[precision] = 0;
      assign fp_ready[precision] = 0;
      assign fp_valid[precision] = 0;
      assign fp_result[precision] = 0;
      assign fp_flags[precision] = 0;
      assign fp_illegal[precision] = 0;
    end
  end
  always_comb begin
    element_lm = int'($signed(vtype[2:0]));
    element_capacity = VLEN >> (int'(vtype[5:3])+3);
    element_vlmax = IndexBits'(element_lm >= 0 ? element_capacity << element_lm : element_capacity >> (-element_lm));
  end
  rapt_vpu_slide #(
      .XLEN(XLEN),
      .VLEN(VLEN)
  ) u_slide (
      .up(!command_q.insn[26]),
      .single(command_q.insn[14:12] == 6),
      .mask_active(1'b1),
      .index(index_q),
      .vl(IndexBits'(vl)),
      .vlmax(element_vlmax),
      .vstart(IndexBits'(vstart)),
      .offset(command_q.insn[14:12] == 3 ? XLEN'(command_q.insn[19:15]) : command_q.rs1),
      .write_element(slide_write),
      .read_source(slide_read),
      .scalar_select(slide_scalar),
      .source_index(slide_index)
  );
  rapt_vpu_fixed u_fixed (
      .op(d_fixed_op),
      .sew(d_size_q),
      .vxrm(vxrm),
      .a(a_q),
      .b(b_q),
      .product(fixed_product_q),
      .result(fixed_result),
      .saturated(fixed_saturated)
  );
  rapt_vpu_alu u_alu (
      .funct6(d_alu_op),
      .sew(d_narrow ? a_size_q : d_size_q),
      .a(a_q),
      .b(b_q),
      .mask_bit(d_carry && command_q.insn[25] ? 1'b0 : mask_q),
      .mask_logic(d_mask_logic),
      .result(alu_result)
  );

  rapt_vpu_geometry #(
      .ELEN(ELEN)
  ) u_geometry (
      .vtype(vtype[7:0]),
      .vd(command_q.insn[11:7]),
      .vs2(command_q.insn[24:20]),
      .vs1(command_q.insn[19:15]),
      .uses_vs2(ft_recognized ? ft_operation != 1 && ft_operation != 3 : d_vs2),
      .src_vector(d_src_vector),
      .masked(!command_q.insn[25]),
      .mask_result(d_mask_result),
      .mask_logic(d_mask_logic),
      .mask_source(d_iota),
      .compress(d_compress),
      .slide_up((d_slide && !command_q.insn[26]) || (ft_recognized && ft_operation == 4)),
      .gather(d_gather),
      .gather16(d_gather16),
      .widen(d_widen),
      .wide_a(d_wide_a),
      .narrow(d_narrow),
      .extend(d_extend),
      .extend_shift(d_extend_shift),
      .a_size(g_a_size),
      .d_size(g_d_size),
      .legal(geometry_legal)
  );
  function automatic logic [63:0] resize_operand(input logic [63:0] value, input logic [1:0] size,
                                                 input logic sign_extend);
    logic [63:0] shifted;
    shifted = value << (64 - (8 << size));
    return sign_extend ? 64'($signed(
        shifted
    ) >>> (64 - (8 << size))) : shifted >> (64 - (8 << size));
  endfunction
  assign a_input = (d_mask_logic || d_iota) ? 64'(elem_rdata[{3'b0,index_q[2:0]}])
      : resize_operand(elem_rdata,a_size_q,d_a_signed);
  assign b_size = d_gather16 ? 2'd1 : sew_q;
  assign gather_index = d_src_vector ? b_q : command_q.insn[14:12] == 3
      ? 64'(command_q.insn[19:15]) : 64'(command_q.rs1);
  assign b_input = d_mask_logic ? 64'(elem_rdata[{3'b0,index_q[2:0]}])
      : resize_operand(elem_rdata,b_size,d_b_signed);
  rapt_vpu_divsqrt #(
      .ELEN(ELEN)
  ) u_fp_divsqrt (
      .clock(clock),
      .reset(reset),
      .req_valid(state == FP_START && fp_divsqrt),
      .req_ready(div_ready),
      .req_double(sew_q == 3),
      .req_sqrt(fp_sqrt),
      .a(fp_a),
      .b(fp_b),
      .rm(command_q.frm),
      .rsp_valid(div_valid),
      .rsp_ready(state == FP_RUN && fp_divsqrt),
      .result(div_result),
      .flags(div_flags),
      .illegal(div_illegal)
  );
  if (ELEN >= 64) begin : gen_fp_convert
    rapt_vpu_fp_convert u_convert (
        .clock(clock),
        .reset(reset),
        .req_valid(state == FP_START && fp_convert),
        .req_ready(convert_ready),
        .req_widen(fp_widen),
        .operand(fp_a),
        .rm(fp_odd ? 3'd6 : command_q.frm),
        .rsp_valid(convert_valid),
        .rsp_ready(state == FP_RUN && fp_convert),
        .result(convert_result),
        .flags(convert_flags),
        .illegal(convert_illegal)
    );
  end else begin : gen_no_fp_convert
    assign convert_ready = 0;
    assign convert_valid = 0;
    assign convert_illegal = 0;
    assign convert_result = 0;
    assign convert_flags = 0;
  end
  assign selected_fp_ready = if_recognized ? if_ready[if_select] : fp_convert ? convert_ready : fp_divsqrt ? div_ready : fp_ready[d_size_q[0]];
  assign selected_fp_valid = if_recognized ? if_valid[if_select] : fp_convert ? convert_valid : fp_divsqrt ? div_valid : fp_valid[d_size_q[0]];
  assign selected_fp_illegal = if_recognized ? if_illegal[if_select] : fp_convert ? convert_illegal : fp_divsqrt ? div_illegal : fp_illegal[d_size_q[0]];
  assign selected_fp_result = if_recognized ? if_result[if_select] : fp_convert ? convert_result : fp_divsqrt ? div_result : fp_result[d_size_q[0]];
  assign selected_fp_flags = if_recognized ? if_flags[if_select] : fp_convert ? convert_flags : fp_divsqrt ? div_flags : fp_flags[d_size_q[0]];
  assign execute_state = ft_recognized ? FT_ROUTE : fp_recognized ? (fp_old ? OLD_REQ : FP_START) : d_mask_result ? MASK_WRITE_START : d_mac ? OLD_REQ : d_muldiv ? MULDIV_START : WRITE_REQ;
  assign prefix_value = !prefix_seen_q && (command_q.insn[16:15] == 3
      || (command_q.insn[16:15] == 2 ? a_q[0] : !a_q[0]));
  rapt_vpu_mask_write #(
      .AddrBits(AddrBits)
  ) u_mask_write (
      .clock(clock),
      .reset(reset),
      .req_valid(state == MASK_WRITE_START),
      .req_ready(mw_ready),
      .req_addr(AddrBits'(int'(command_q.insn[11:7])*(VLEN/8) + (int'(index_q) >> 3))),
      .req_bit(index_q[2:0]),
      .req_value(fp_recognized ? fp_result_q[0] : d_mask_prefix ? prefix_value : alu_result[0]),
      .done_valid(mw_done),
      .done_ready(state == MASK_WRITE_RUN),
      .vr_valid(mw_vr_valid),
      .vr_ready(elem_ready),
      .vr_write(mw_vr_write),
      .vr_addr(mw_vr_addr),
      .vr_wdata(mw_vr_wdata),
      .vr_rsp_valid(elem_rsp_valid),
      .vr_rsp_ready(mw_vr_rsp_ready),
      .vr_rdata(elem_rdata[7:0])
  );
  assign md_a = d_mac && !d_widen && !command_q.insn[28] ? old_q : a_q;
  assign md_addend = (d_widen || command_q.insn[28]) ? old_q : a_q;
  rapt_vpu_muldiv u_muldiv (
      .clock(clock),
      .reset(reset),
      .req_valid(state == MULDIV_START),
      .req_ready(md_ready),
      .op(d_fraction ? 3'd7 : d_mac || d_widen ? 3'd5 : command_q.insn[28:26]),
      .sew(d_size_q),
      .a(md_a),
      .b(b_q),
      .rsp_valid(md_valid),
      .rsp_ready(state == MULDIV_RUN),
      .result(md_result),
      .full_product(md_full_product)
  );

  always_comb begin
    // RV32 scalar operands sign-extend when a vector element is wider.
    scalar_b = 64'($signed(command_q.rs1));
    if (command_q.insn[14:12] == 3'b011) begin
      scalar_b = 64'($signed(command_q.insn[19:15]));
      if (command_q.insn[31:26] == 6'h25 || command_q.insn[31:26] == 6'h28
          || command_q.insn[31:26] == 6'h29 || d_narrow || (d_fixed && d_fixed_op >= 8))
        scalar_b = 64'(command_q.insn[19:15]);
    end
    bad_group = !geometry_legal || ((d_iota || d_compress) && vstart != 0) || (d_mask_prefix && (vstart != 0
        || command_q.insn[11:7] == command_q.insn[24:20]
        || (!command_q.insn[25] && command_q.insn[11:7] == 0)));
    cfg_type = XLEN'(command_q.insn[30:20]);
    cfg_avl = command_q.rs1;
    cfg_max = command_q.insn[19:15] == 0 && command_q.insn[11:7] != 0;
    cfg_keep = command_q.insn[19:15] == 0 && command_q.insn[11:7] == 0;
    if (command_q.insn[31:30] == 2'b11) begin
      cfg_type = XLEN'(command_q.insn[29:20]);
      cfg_avl = XLEN'(command_q.insn[19:15]);
      cfg_max = 0;
      cfg_keep = 0;
    end else if (command_q.insn[31]) cfg_type = command_q.rs2;
    csr_operand = command_q.insn[14] ? XLEN'(command_q.insn[19:15]) : command_q.rs1;
    csr_write = command_q.insn[13:12] == 1 || command_q.insn[19:15] != 0;
    csr_wdata = csr_operand;
    case (command_q.insn[13:12])
      2: csr_wdata = csr_rdata | csr_operand;
      3: csr_wdata = csr_rdata & ~csr_operand;
      default: ;
    endcase
  end
  rapt_vpu_csr #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) u_csr (
      .clock(clock),
      .reset(reset),
      .vector_enabled(enabled_q),
      .cfg_valid(state == CONFIGURE),
      .cfg_vtype(cfg_type),
      .cfg_avl(cfg_avl),
      .cfg_avl_max(cfg_max),
      .cfg_keep_vl(cfg_keep),
      .cfg_illegal(cfg_illegal),
      .cfg_result(cfg_result),
      .csr_valid(state == CSR),
      .csr_addr(command_q.insn[31:20]),
      .csr_write(csr_write),
      .csr_wdata(csr_wdata),
      .csr_rdata(csr_rdata),
      .csr_illegal(csr_illegal),
      .exec_valid(state == FINISH || (state == MEMORY_RUN && m_done && m_update)
          || (state == REDUCE_RUN && r_done && !r_trap)
          || (state == FR_RUN && fr_done && !fr_trap)
          || (state == MOVE_RUN && c_done && !c_trap)
          || (state == SCAN_RUN && s_done && !s_trap)),
      .exec_fault(state == MEMORY_RUN && m_trap),
      .exec_fof(state == MEMORY_RUN && m_fof),
      .exec_vstart(m_vstart),
      .exec_vl(m_vl),
      .exec_saturated(state == FINISH && saturated_q),
      .vtype(vtype),
      .vl(vl),
      .vstart(vstart),
      .vxrm(vxrm),
      .vxsat(vxsat),
      .dirty(csr_dirty)
  );
  rapt_vpu_mask_scan #(
      .XLEN(XLEN),
      .VLEN(VLEN)
  ) u_mask_scan (
      .clock(clock),
      .reset(reset),
      .cmd_valid(state == SCAN_START),
      .cmd_ready(s_ready),
      .cmd_first(command_q.insn[15]),
      .cmd_masked(!command_q.insn[25]),
      .cmd_src(command_q.insn[24:20]),
      .cmd_vill(vtype[XLEN-1]),
      .cmd_vl(vl),
      .cmd_vstart(vstart),
      .done_valid(s_done),
      .done_ready(state == SCAN_RUN),
      .done_trap(s_trap),
      .done_value(s_value),
      .vr_valid(s_vr_valid),
      .vr_ready(elem_ready),
      .vr_addr(s_vr_addr),
      .vr_rsp_valid(elem_rsp_valid),
      .vr_rsp_ready(s_vr_rsp_ready),
      .vr_rdata(elem_rdata[7:0])
  );
  rapt_vpu_move #(
      .VLEN(VLEN)
  ) u_move (
      .clock(clock),
      .reset(reset),
      .cmd_valid(state == MOVE_START),
      .cmd_ready(c_ready),
      .cmd_insn(command_q.insn),
      .cmd_sew(vtype[4:3]),
      .cmd_vill(vtype[XLEN-1]),
      .cmd_vstart(vstart),
      .done_valid(c_done),
      .done_ready(state == MOVE_RUN),
      .done_trap(c_trap),
      .vr_valid(c_vr_valid),
      .vr_ready(elem_ready),
      .vr_write(c_vr_write),
      .vr_addr(c_vr_addr),
      .vr_size(c_vr_size),
      .vr_wdata(c_vr_wdata),
      .vr_rsp_valid(elem_rsp_valid),
      .vr_rsp_ready(c_vr_rsp_ready),
      .vr_rdata(elem_rdata)
  );
  rapt_vpu_reduce #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN)
  ) u_reduce (
      .clock(clock),
      .reset(reset),
      .cmd_valid(state == REDUCE_START),
      .cmd_ready(r_ready),
      .cmd_insn(command_q.insn),
      .cmd_vtype(vtype),
      .cmd_vl(vl),
      .cmd_vstart(vstart),
      .done_valid(r_done),
      .done_ready(state == REDUCE_RUN),
      .done_trap(r_trap),
      .vr_valid(r_vr_valid),
      .vr_ready(elem_ready),
      .vr_write(r_vr_write),
      .vr_addr(r_vr_addr),
      .vr_size(r_vr_size),
      .vr_wdata(r_vr_wdata),
      .vr_rsp_valid(elem_rsp_valid),
      .vr_rsp_ready(r_vr_rsp_ready),
      .vr_rdata(elem_rdata)
  );
  rapt_vpu_memory #(
      .XLEN(XLEN),
      .VLEN(VLEN),
      .ELEN(ELEN),
      .TagBits(TagBits)
  ) u_memory (
      .clock(clock),
      .reset(reset),
      .cmd_valid(state == MEMORY_START),
      .cmd_ready(m_ready),
      .cmd_insn(command_q.insn),
      .cmd_tag(tag_q),
      .cmd_base(command_q.rs1),
      .cmd_stride(command_q.rs2),
      .cmd_vtype(vtype),
      .cmd_vl(vl),
      .cmd_vstart(vstart),
      .done_valid(m_done),
      .done_ready(state == MEMORY_RUN),
      .done_trap(m_trap),
      .done_update(m_update),
      .done_fof(m_fof),
      .done_cause(m_cause),
      .done_tval(m_tval),
      .done_vl(m_vl),
      .done_vstart(m_vstart),
      .vr_valid(m_vr_valid),
      .vr_ready(elem_ready),
      .vr_write(m_vr_write),
      .vr_addr(m_vr_addr),
      .vr_size(m_vr_size),
      .vr_wdata(m_vr_wdata),
      .vr_rsp_valid(elem_rsp_valid),
      .vr_rsp_ready(m_vr_rsp_ready),
      .vr_rdata(elem_rdata),
      .mem_valid(mem_valid),
      .mem_ready(mem_ready),
      .mem_write(mem_write),
      .mem_probe(mem_probe),
      .mem_addr(mem_addr),
      .mem_size(mem_size),
      .mem_wdata(mem_wdata),
      .mem_tag(mem_tag),
      .mem_index(mem_index),
      .mem_field(mem_field),
      .mem_rsp_valid(mem_rsp_valid),
      .mem_rsp_ready(mem_rsp_ready),
      .mem_rsp_tag(mem_rsp_tag),
      .mem_rsp_index(mem_rsp_index),
      .mem_rsp_field(mem_rsp_field),
      .mem_rsp_probe(mem_rsp_probe),
      .mem_rdata(mem_rdata),
      .mem_fault(mem_fault),
      .mem_non_idempotent(mem_non_idempotent),
      .mem_cause(mem_cause),
      .mem_tval(mem_tval),
      .response_dropped(mem_response_dropped)
  );

  // Idle host traffic and the authorized engine share the same element port.
  // An accepted host request excludes commands until its response is consumed.
  assign host_ready = !owner_busy && !host_pending && elem_ready;
  assign host_rsp_valid = host_pending && elem_rsp_valid;
  assign host_rdata = elem_rdata;
  always_ff @(posedge clock) begin
    if (reset) host_pending <= 0;
    else begin
      if (host_valid && host_ready) host_pending <= 1;
      if (host_rsp_valid && host_rsp_ready) host_pending <= 0;
    end
  end
  always_comb begin
    elem_valid = 0;
    elem_write = state == WRITE_REQ;
    elem_size = d_size_q;
    elem_addr = '0;
    elem_wdata = fp_recognized ? fp_result_q : (d_compress || d_slide || d_gather) ? a_q : d_iota ? 64'(iota_count_q) : d_element_index ? 64'(index_q) : d_fixed ? fixed_result : d_extend ? a_q : d_muldiv ? md_result_q : alu_result;
    elem_rsp_ready = state == MASK_RSP || state == A_RSP || state == B_RSP || state == OLD_RSP || state == WRITE_RSP || state == SCALAR_RSP || state == FT_RSP;
    case (state)
      FT_REQ: begin
        elem_valid = 1;
        elem_write = 0;
        elem_size = sew_q;
        elem_addr = AddrBits'(int'(command_q.insn[24:20])*(VLEN/8) + (int'(ft_source_index) << sew_q));
      end
      SCALAR_REQ: begin
        elem_valid = 1;
        elem_write = command_q.insn[14];
        elem_size = sew_q;
        elem_addr = AddrBits'((command_q.insn[14] ? int'(command_q.insn[11:7]) : int'(command_q.insn[24:20]))*(VLEN/8));
        elem_wdata = 64'($signed(command_q.rs1));
      end
      MASK_REQ: begin
        elem_valid = 1;
        elem_size = 0;
        elem_addr = AddrBits'((d_compress ? int'(command_q.insn[19:15])*(VLEN/8) : 0)+(int'(index_q) >> 3));
      end
      A_REQ: begin
        elem_valid = 1;
        elem_addr = AddrBits'(int'(command_q.insn[24:20])*(VLEN/8)
            + ((d_mask_logic || d_iota) ? (int'(index_q) >> 3) : ((d_gather ? int'(gather_index) : d_slide ? int'(slide_index) : int'(index_q)) << a_size_q)));
        elem_size = (d_mask_logic || d_iota) ? 0 : a_size_q;
      end
      B_REQ: begin
        elem_valid = 1;
        elem_addr = AddrBits'(int'(command_q.insn[19:15])*(VLEN/8)
            + (d_mask_logic ? (int'(index_q) >> 3) : (int'(index_q) << b_size)));
        elem_size = d_mask_logic ? 0 : b_size;
      end
      OLD_REQ, WRITE_REQ: begin
        elem_valid = 1;
        elem_addr = AddrBits'(int'(command_q.insn[11:7])*(VLEN/8) + ((ft_recognized ? int'(ft_destination_index) : d_compress ? int'(iota_count_q) : int'(index_q)) << d_size_q));
      end
      default: ;
    endcase
    if (state == MEMORY_START || state == MEMORY_RUN) begin
      elem_valid = m_vr_valid;
      elem_write = m_vr_write;
      elem_addr = m_vr_addr;
      elem_size = m_vr_size;
      elem_wdata = m_vr_wdata;
      elem_rsp_ready = m_vr_rsp_ready;
    end
    if (state == SCAN_START || state == SCAN_RUN) begin
      elem_valid = s_vr_valid;
      elem_write = 0;
      elem_size = 0;
      elem_addr = s_vr_addr;
      elem_wdata = 0;
      elem_rsp_ready = s_vr_rsp_ready;
    end
    if (state == MOVE_START || state == MOVE_RUN) begin
      elem_valid = c_vr_valid;
      elem_write = c_vr_write;
      elem_size = c_vr_size;
      elem_addr = c_vr_addr;
      elem_wdata = c_vr_wdata;
      elem_rsp_ready = c_vr_rsp_ready;
    end
    if (fr_active) begin
      elem_valid = fr_vr_valid;
      elem_write = fr_vr_write;
      elem_size = fr_vr_size;
      elem_addr = fr_vr_addr;
      elem_wdata = fr_vr_wdata;
      elem_rsp_ready = fr_vr_rsp_ready;
    end
    if (state == REDUCE_START || state == REDUCE_RUN) begin
      elem_valid = r_vr_valid;
      elem_write = r_vr_write;
      elem_size = r_vr_size;
      elem_addr = r_vr_addr;
      elem_wdata = r_vr_wdata;
      elem_rsp_ready = r_vr_rsp_ready;
    end
    if (state == MASK_WRITE_START || state == MASK_WRITE_RUN) begin
      elem_valid = mw_vr_valid;
      elem_write = mw_vr_write;
      elem_size = 0;
      elem_addr = mw_vr_addr;
      elem_wdata = {56'b0,mw_vr_wdata};
      elem_rsp_ready = mw_vr_rsp_ready;
    end
    if (!owner_busy) begin
      elem_valid = host_valid && !host_pending;
      elem_write = host_write;
      elem_addr = host_addr;
      elem_size = host_size;
      elem_wdata = host_wdata;
      elem_rsp_ready = host_pending && host_rsp_ready;
    end
  end
  rapt_vpu_element #(
      .VLEN(VLEN),
      .BankBits(BankBits),
      .Banks(Banks),
      .AddrBits(AddrBits)
  ) u_element (
      .clock(clock),
      .reset(reset),
      .req_valid(elem_valid),
      .req_ready(elem_ready),
      .req_write(elem_write),
      .req_addr(elem_addr),
      .req_size(elem_size),
      .req_wdata(elem_wdata),
      .rsp_valid(elem_rsp_valid),
      .rsp_ready(elem_rsp_ready),
      .rsp_rdata(elem_rdata),
      .bank_valid(bank_valid),
      .bank_ready(bank_ready),
      .bank_write(bank_write),
      .bank_row(bank_row),
      .bank_wdata(bank_wdata),
      .bank_be(bank_be),
      .bank_rsp_valid(bank_rsp_valid),
      .bank_rsp_ready(bank_rsp_ready),
      .bank_rdata(bank_rdata)
  );
  rapt_vpu_vrf #(
      .VLEN(VLEN),
      .BankBits(BankBits),
      .Banks(Banks)
  ) u_vrf (
      .clock(clock),
      .reset(reset),
      .req_valid(bank_valid),
      .req_ready(bank_ready),
      .req_write(bank_write),
      .req_row(bank_row),
      .req_wdata(bank_wdata),
      .req_be(bank_be),
      .rsp_valid(bank_rsp_valid),
      .rsp_ready(bank_rsp_ready),
      .rsp_rdata(bank_rdata)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      command_q <= '0;
      tag_q <= '0;
      result_q <= '0;
      index_q <= '0;
      sew_q <= '0;
      a_size_q <= 0;
      d_size_q <= 0;
      a_q <= '0;
      b_q <= '0;
      md_result_q <= 0;
      old_q <= 0;
      fp_result_q <= 0;
      fp_element_flags <= 0;
      saturated_q <= 0;
      fixed_product_q <= 0;
      mask_q <= 1;
      prefix_seen_q <= 0;
      iota_count_q <= 0;
      enabled_q <= 0;
    end else begin
      case (state)
        IDLE:
        if (engine_valid && engine_ready) begin
          command_q <= engine_command;
          tag_q <= engine_tag;
          enabled_q <= vector_enabled;
          result_q <= '0;
          saturated_q <= 0;
          prefix_seen_q <= 0;
          iota_count_q <= 0;
          state <= DECODE;
        end
        DECODE: begin
          if (!enabled_q || (d_illegal && !fp_recognized) || (fp_recognized && !fp_legal)) begin
            result_q.trap <= 1;
            result_q.cause <= XLEN'(2);
            result_q.tval <= XLEN'(command_q.insn);
            state <= COMPLETE;
          end else if (d_config) state <= CONFIGURE;
          else if (d_csr) state <= CSR;
          else if (ft_scalar) begin
            index_q <= 0;
            sew_q <= vtype[4:3];
            d_size_q <= vtype[4:3];
            mask_q <= 1;
            state <= FT_ROUTE;
          end else if (fr_recognized) state <= FR_START;
          else if (d_integer || fp_recognized) state <= CHECK;
          else if (d_memory) state <= MEMORY_START;
          else if (d_mask_scan) state <= SCAN_START;
          else if (d_scalar_move) state <= SCALAR_CHECK;
          else if (d_move) state <= MOVE_START;
          else if (d_reduce) state <= REDUCE_START;
        end
        CONFIGURE, CSR: begin
          result_q.rd <= command_q.insn[11:7];
          result_q.value <= state == CONFIGURE ? cfg_result : csr_rdata;
          result_q.dirty <= csr_dirty;
          if ((state == CONFIGURE && cfg_illegal) || (state == CSR && csr_illegal)) begin
            result_q.rd <= 0;
            result_q.value <= 0;
            result_q.trap <= 1;
            result_q.cause <= XLEN'(2);
            result_q.tval <= XLEN'(command_q.insn);
          end
          state <= COMPLETE;
        end
        SCALAR_CHECK: begin
          sew_q <= vtype[4:3];
          if (vtype[XLEN-1]) begin
            result_q.trap <= 1;
            result_q.cause <= XLEN'(2);
            result_q.tval <= XLEN'(command_q.insn);
            state <= COMPLETE;
          end else if (command_q.insn[14] && XLEN'(vstart) >= vl) state <= FINISH;
          else state <= SCALAR_REQ;
        end
        SCALAR_REQ: if (elem_valid && elem_ready) state <= SCALAR_RSP;
        SCALAR_RSP: if (elem_rsp_valid && elem_rsp_ready) begin
          if (!command_q.insn[14]) begin
            result_q.rd <= command_q.insn[11:7];
            result_q.value <= command_q.insn[11:7] == 0 ? '0 : XLEN'(resize_operand(elem_rdata,sew_q,1'b1));
          end
          state <= FINISH;
        end
        CHECK: begin
          if (vtype[XLEN-1] || bad_group) begin
            result_q.trap <= 1;
            result_q.cause <= XLEN'(2);
            result_q.tval <= XLEN'(command_q.insn);
            state <= COMPLETE;
          end else begin
            index_q <= IndexBits'(vstart);
            sew_q <= vtype[4:3]; a_size_q <= g_a_size; d_size_q <= g_d_size;
            a_q <= 0;
            b_q <= d_widen ? resize_operand(scalar_b,vtype[4:3],d_b_signed) : scalar_b;
            mask_q <= 1;
            state <= NEXT_ELEMENT;
          end
        end
        NEXT_ELEMENT: begin
          if (XLEN'(index_q) >= vl) state <= FINISH;
          else if (d_compress || !command_q.insn[25]) state <= MASK_REQ;
          else if (ft_recognized) state <= FT_ROUTE;
          else if (d_gather) state <= d_src_vector ? B_REQ : GATHER_ROUTE;
          else if (d_slide) state <= SLIDE_ROUTE;
          else if (d_vs2) state <= A_REQ;
          else state <= d_src_vector ? B_REQ : execute_state;
        end
        MASK_REQ: if (elem_valid && elem_ready) state <= MASK_RSP;
        MASK_RSP: if (elem_rsp_valid) begin
          mask_q <= elem_rdata[{3'b0, index_q[2:0]}];
          if (!elem_rdata[{3'b0, index_q[2:0]}] && !d_merge && !d_carry && !(ft_recognized && ft_operation == 0)) begin
            index_q <= index_q + 1'b1;
            state <= NEXT_ELEMENT;
          end else if (ft_recognized) state <= FT_ROUTE;
          else if (OptimizeOperandReads && d_merge && elem_rdata[{3'b0, index_q[2:0]}])
            state <= d_src_vector ? B_REQ : execute_state;
          else state <= d_gather ? (d_src_vector ? B_REQ : GATHER_ROUTE) : d_slide ? SLIDE_ROUTE : d_vs2 ? A_REQ : (d_src_vector ? B_REQ : execute_state);
        end
        GATHER_ROUTE: begin
          if (gather_index < 64'(element_vlmax)) state <= A_REQ;
          else begin a_q <= 0; state <= WRITE_REQ; end
        end
        SLIDE_ROUTE: begin
          if (!slide_write) begin index_q <= index_q+1'b1; state <= NEXT_ELEMENT; end
          else if (slide_read) state <= A_REQ;
          else begin a_q <= slide_scalar ? scalar_b : 64'b0; state <= WRITE_REQ; end
        end
        A_REQ: if (elem_valid && elem_ready) state <= A_RSP;
        A_RSP: if (elem_rsp_valid) begin
          a_q <= a_input;
          if (d_gather) state <= WRITE_REQ;
          else if (OptimizeOperandReads && d_src_vector && a_size_q == sew_q && command_q.insn[24:20] == command_q.insn[19:15]) begin
            b_q <= b_input;
            state <= execute_state;
          end else if (OptimizeOperandReads && d_merge && !mask_q) state <= execute_state;
          else state <= d_src_vector ? B_REQ : execute_state;
        end
        B_REQ: if (elem_valid && elem_ready) state <= B_RSP;
        B_RSP: if (elem_rsp_valid) begin
          b_q <= b_input;
          state <= d_gather ? GATHER_ROUTE : execute_state;
        end
        OLD_REQ: if (elem_valid && elem_ready) state <= OLD_RSP;
        OLD_RSP: if (elem_rsp_valid) begin old_q <= elem_rdata; state <= fp_recognized ? FP_START : MULDIV_START; end
        FT_ROUTE: begin
          fp_element_flags <= 0;
          if (ft_read_source) state <= FT_REQ;
          else if (ft_write_vector) begin fp_result_q <= ft_result; state <= WRITE_REQ; end
          else state <= FINISH;
        end
        FT_REQ: if (elem_valid && elem_ready) state <= FT_RSP;
        FT_RSP: if (elem_rsp_valid && elem_rsp_ready) begin
          if (ft_write_scalar) begin
            result_q.rd <= command_q.insn[11:7]; result_q.fp_write <= 1; result_q.fp_value <= ft_result;
            state <= FINISH;
          end else begin fp_result_q <= ft_result; state <= WRITE_REQ; end
        end
        FP_START: if (fp_misc) begin
          fp_result_q <= fp_misc_result[sew_q[0]]; fp_element_flags <= fp_misc_flags[sew_q[0]];
          state <= fp_mask_result ? MASK_WRITE_START : WRITE_REQ;
        end else if (selected_fp_ready) state <= FP_RUN;
        FP_RUN: if (selected_fp_valid) begin
          fp_result_q <= selected_fp_result; fp_element_flags <= selected_fp_flags;
          state <= WRITE_REQ;
        end
        MULDIV_START: if (md_ready) state <= MULDIV_RUN;
        MULDIV_RUN: if (md_valid) begin
          if (d_fraction) fixed_product_q <= md_full_product;
          md_result_q <= d_mac ? (!d_widen && command_q.insn[27] ? md_addend-md_result : md_addend+md_result) : md_result;
          state <= WRITE_REQ;
        end
        MASK_WRITE_START: if (mw_ready) state <= MASK_WRITE_RUN;
        MASK_WRITE_RUN: if (mw_done) begin
          if (fp_recognized) result_q.fflags <= result_q.fflags | fp_element_flags;
          if (d_mask_prefix) prefix_seen_q <= prefix_seen_q || a_q[0];
          index_q <= index_q+1'b1; state <= NEXT_ELEMENT;
        end
        WRITE_REQ: if (elem_valid && elem_ready) begin
          if (d_fixed) saturated_q <= saturated_q || fixed_saturated;
          state <= WRITE_RSP;
        end
        WRITE_RSP: if (elem_rsp_valid) begin
          if (fp_recognized) result_q.fflags <= result_q.fflags | fp_element_flags;
          if (d_iota || d_compress) iota_count_q <= iota_count_q+(d_compress ? IndexBits'(1) : IndexBits'(a_q[0]));
          index_q <= index_q + 1'b1;
          state <= ft_scalar ? FINISH : NEXT_ELEMENT;
        end
        FINISH: begin result_q.dirty <= csr_dirty; result_q.fp_dirty <= fp_recognized; state <= COMPLETE; end
        SCAN_START: if (s_ready) state <= SCAN_RUN;
        SCAN_RUN: if (s_done) begin
          result_q.trap <= s_trap;
          result_q.cause <= s_trap ? XLEN'(2) : '0;
          result_q.tval <= s_trap ? XLEN'(command_q.insn) : '0;
          result_q.rd <= s_trap ? 5'b0 : command_q.insn[11:7];
          result_q.value <= s_trap || command_q.insn[11:7] == 0 ? '0 : s_value;
          result_q.dirty <= csr_dirty; state <= COMPLETE;
        end
        MOVE_START: if (c_ready) state <= MOVE_RUN;
        MOVE_RUN: if (c_done) begin
          result_q.trap <= c_trap;
          result_q.cause <= c_trap ? XLEN'(2) : '0;
          result_q.tval <= c_trap ? XLEN'(command_q.insn) : '0;
          result_q.dirty <= csr_dirty;
          state <= COMPLETE;
        end
        FR_START: if (fr_ready) state <= FR_RUN;
        FR_RUN: if (fr_done) begin
          result_q.trap <= fr_trap;
          result_q.cause <= fr_trap ? XLEN'(2) : '0;
          result_q.tval <= fr_trap ? XLEN'(command_q.insn) : '0;
          result_q.dirty <= csr_dirty;
          result_q.fflags <= fr_flags;
          result_q.fp_dirty <= !fr_trap;
          state <= COMPLETE;
        end
        REDUCE_START: if (r_ready) state <= REDUCE_RUN;
        REDUCE_RUN: if (r_done) begin
          result_q.trap <= r_trap;
          result_q.cause <= r_trap ? XLEN'(2) : '0;
          result_q.tval <= r_trap ? XLEN'(command_q.insn) : '0;
          result_q.dirty <= csr_dirty;
          state <= COMPLETE;
        end
        MEMORY_START: if (m_ready) state <= MEMORY_RUN;
        MEMORY_RUN: if (m_done) begin
          result_q.trap <= m_trap;
          result_q.cause <= m_cause;
          result_q.tval <= m_tval;
          result_q.dirty <= csr_dirty;
          state <= COMPLETE;
        end
        COMPLETE: if (result_ready) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, VPU_FP_LEGAL_RESULT,
                  (state == FP_RUN && selected_fp_valid) || (state == FP_START && fp_misc),
                  fp_misc ? !fp_misc_illegal[sew_q[0]] : !selected_fp_illegal)
  `RAPT_SVA(clock, reset, VPU_NO_DROPPED_INTERNAL_RESULT, !dropped)
  `RAPT_SVA_IMPLY(clock, reset, VPU_EXCLUDES_HOST, owner_busy, !host_ready && !host_rsp_valid)
  `RAPT_SVA_IMPLY(
      clock, reset, VPU_WRITES_AUTHORIZED, elem_valid && elem_ready && elem_write && owner_busy,
      state == WRITE_REQ || state == MEMORY_RUN || state == MASK_WRITE_RUN || state == REDUCE_RUN || state == FR_RUN || state == MOVE_RUN || state == SCALAR_REQ)
  `RAPT_SVA_IMPLY(clock, reset, VPU_MEMORY_AUTHORIZED, mem_valid, owner_busy && state == MEMORY_RUN)
  `RAPT_SVA_IMPLY(clock, reset, VPU_FPR_COMPLETION_KIND, rsp_valid && rsp_fp_write,
                  !rsp_trap && rsp_fp_dirty && rsp_result == 0)
endmodule
