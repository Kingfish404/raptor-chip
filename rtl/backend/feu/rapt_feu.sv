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
    parameter unsigned XLEN     = Cfg.xlen,
    // FPQ residents also capture this live view; allocation uses `completion`.
    parameter bit LocalFpWake = 1'b0
) (
    input logic [1:0][PLEN-1:0] int_source_regs[NumSlots],
    input logic [2:0][$clog2(ROB_SIZE):0] fp_dispatch_tag[NumSlots],
    input logic [2:0][Cfg.rob_generation_bits-1:0] fp_dispatch_generation[NumSlots],
    input logic fp_retire_valid[Cfg.commit_width],
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [63:0] fp_retire_value[Cfg.commit_width],
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [$clog2(ROB_SIZE)-1:0] fp_retire_owner[Cfg.commit_width],
    input logic [Cfg.rob_generation_bits-1:0] fp_retire_generation[Cfg.commit_width],
    output UopT fp_queue_read_uop,
    output logic [2:0][$clog2(ROB_SIZE):0] fp_queue_read_tag,
    input logic [2:0][63:0] operand_read_value,
    input logic [2:0][$clog2(ROB_SIZE):0] fp_queue_ready_tag,
    input logic [2:0][Cfg.rob_generation_bits-1:0] fp_queue_read_generation,
    output logic [PLEN-1:0] int_operand_address,
    input logic [XLEN-1:0] int_operand_value,
    input logic int_operand_valid,
    input CompletionT completion[NumCompletions],
    input CompletionT early_completion[NumCompletions],
    input CompletionT local_fp_wake[NumCompletions] = '{default: '0},
    input clock,
    input reset,
    input logic cancel_valid,
    input logic [$clog2(ROB_SIZE)-1:0] cancel_head,
    cancel_owner,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    input SlotT dispatch[NumSlots],
    dpu_iq_if.rs disp_fpq,

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
  typedef logic [XLEN-1:0] result_word_t;
  typedef logic [$bits(dispatch[0].uop.pc)-1:0] result_pc_t;
  typedef logic [PLEN-1:0] result_phys_t;
  `RAPT_FPU_COMPLETION_TYPE_PC(fp_result_t, result_word_t, result_pc_t, result_phys_t, arch_t,
                               owner_t, generation_t)

  `RAPT_DISPATCH_SLOT_TYPE(fp_slot_t, UopT, fp_word_t, operand_tag_t, owner_t, generation_t,
                           Cfg.completion_dependencies)
  typedef struct packed {
    logic valid;
    UopT uop;
    fp_word_t op1, op2, op3;
    owner_t dest;
    generation_t generation;
    operand_tag_t prd;
    logic [rapt_pkg::index_bits(FPQ_SIZE)-1:0] entry_index;
  } fp_issue_t;
  `RAPT_COMPLETION_TYPE_PC(fp_wake_t, fp_word_t, result_pc_t, operand_tag_t, arch_t, owner_t,
                           generation_t)
  fp_slot_t fp_dispatch[NumSlots];
  fp_issue_t fp_issue[1];
  /* verilator lint_off UNUSEDSIGNAL */
  fp_issue_t iss;
  /* verilator lint_on UNUSEDSIGNAL */
  // Preserve FP decode boundaries while other issue payload muxes may fold.
  (* keep = "true" *) logic [31:0] issued_encoding;
  (* keep = "true" *) logic [$bits(iss.uop.execute.fp)-1:0] issued_fp;
  fp_wake_t fp_wake[NumCompletions], fp_local_wake[NumCompletions];
  localparam int Simple = 0, AddSub = 1, Product = 2, DivSqrt = 3,
      Widen = 4, Narrow = 5, IntToFp = 6, FpToInt = 7,
      HalfToFp = 8, FpToHalf = 9, Units = 10;
  // Empty-queue bypass depends on registered residents and ticket state.
  // Completion arbitration and the age selector do not control allocation.
  logic [$clog2(FPQ_SIZE):0] fpq_occupancy;
  int dispatch_bypass_choice;
  dpu_iq_if #(
      .RS_SIZE(FPQ_SIZE),
      .Width(NumSlots)
  ) fpq_dispatch ();
  for (genvar s = 0; s < NumSlots; s++) begin : g_operand_dispatch
    assign disp_fpq.free_found[s] = fpq_dispatch.free_found[s];
    assign disp_fpq.free_idx[s] = fpq_dispatch.free_idx[s];
    assign fpq_dispatch.rs_idx[s] = disp_fpq.rs_idx[s];
    assign fpq_dispatch.accept[s] = disp_fpq.accept[s] && dispatch_bypass_choice != int'(s);
  end
  logic [Units-1:0] unit_ready, unit_credit, unit_transfer_ready, arithmetic_ready;
  logic [Units-1:0] raw_valid, unit_accept;
  logic [63:0] raw_result[Units];
  logic [4:0] raw_flags[Units];
  fp_result_t launch_packet, unit_launch[Units], unit_completion[Units];
  logic [$clog2(Units)-1:0] completion_cursor, completion_choice;
  logic [$clog2(Units)-1:0] held_choice;
  logic completion_held;
  logic completion_found;
  logic completion_grant;
  int selected_unit;

  function automatic logic cancelled_now(input logic [$clog2(ROB_SIZE)-1:0] owner);
    return cancel_valid && `RAPT_ROB_YOUNGER(owner, cancel_owner, cancel_head);
  endfunction
  function automatic operand_tag_t float_tag(input logic [RobBits:0] tag);
    return tag == '0 ? '0 : (operand_tag_t'(1) << (OperandTagBits - 1)) | operand_tag_t'(tag);
  endfunction
  function automatic int execution_unit(input UopT uop);
    int unit_id;
    logic [2:0] rm;
    unit_id = Simple;
    case (uop.execute.fp.op)
      `RAPT_FP_OP_FADD_S, `RAPT_FP_OP_FSUB_S: unit_id = AddSub;
      `RAPT_FP_OP_FADD_D, `RAPT_FP_OP_FSUB_D: unit_id = AddSub;
      `RAPT_FP_OP_FMUL_S, `RAPT_FP_OP_FMADD_S, `RAPT_FP_OP_FMSUB_S,
      `RAPT_FP_OP_FNMSUB_S, `RAPT_FP_OP_FNMADD_S: unit_id = Product;
      `RAPT_FP_OP_FMUL_D, `RAPT_FP_OP_FMADD_D, `RAPT_FP_OP_FMSUB_D,
      `RAPT_FP_OP_FNMSUB_D, `RAPT_FP_OP_FNMADD_D: unit_id = Product;
      `RAPT_FP_OP_FDIV_S, `RAPT_FP_OP_FDIV_D,
      `RAPT_FP_OP_FSQRT_S, `RAPT_FP_OP_FSQRT_D: unit_id = DivSqrt;
      `RAPT_FP_OP_FCVT_D_S: unit_id = Widen;
      `RAPT_FP_OP_FCVT_S_D: unit_id = Narrow;
      `RAPT_FP_OP_FCVT_D_W, `RAPT_FP_OP_FCVT_D_WU,
      `RAPT_FP_OP_FCVT_D_L, `RAPT_FP_OP_FCVT_D_LU,
      `RAPT_FP_OP_FCVT_S_W, `RAPT_FP_OP_FCVT_S_WU,
      `RAPT_FP_OP_FCVT_S_L, `RAPT_FP_OP_FCVT_S_LU: unit_id = IntToFp;
      `RAPT_FP_OP_FCVT_W_S, `RAPT_FP_OP_FCVT_WU_S,
      `RAPT_FP_OP_FCVT_L_S, `RAPT_FP_OP_FCVT_LU_S,
      `RAPT_FP_OP_FCVT_W_D, `RAPT_FP_OP_FCVT_WU_D,
      `RAPT_FP_OP_FCVT_L_D, `RAPT_FP_OP_FCVT_LU_D: unit_id = FpToInt;
      `RAPT_FP_OP_ZFHMIN: begin
        if (uop.imm[31:25] == 7'b0100000 || uop.imm[31:25] == 7'b0100001)
          unit_id = HalfToFp;
        else if (uop.imm[31:25] == 7'b0100010) unit_id = FpToHalf;
      end
      default: ;
    endcase
    rm = uop.execute.fp.rm == 3'b111 ? csr_bcast.frm : uop.execute.fp.rm;
    // Illegal rounding modes return a precise exception through the simple
    // pipeline without reserving or launching an arithmetic operation.
    return uop.trap || (unit_id != Simple && rm > 3'b100) ? Simple : unit_id;
  endfunction

  typedef struct packed {
    operand_tag_t tag;
    fp_word_t value;
  } fp_operand_t;
  function automatic fp_operand_t wake_dispatch_operand(input operand_tag_t tag,
                                                        input fp_word_t value);
    logic seen, chosen;
    fp_word_t forwarded;
    fp_operand_t operand;
    seen = 1'b0;
    forwarded = '0;
    // Preserve the first matching completion without cascading tag/value muxes.
    for (int c = 0; c < NumCompletions; c++) begin
      chosen = !seen && fp_wake[c].valid && fp_wake[c].prd != '0 && fp_wake[c].prd == tag;
      seen |= chosen;
      forwarded |= {64{chosen}} & fp_wake[c].result;
    end
    operand.tag = seen ? '0 : tag;
    operand.value = seen ? forwarded : value;
    return operand;
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
      if (rapt_pkg::fp_from_integer(
              dispatch[s].uop.execute.fp.op,
              rapt_pkg::fp_instruction(
                  dispatch[s].uop.execute.memory.load,
                  dispatch[s].uop.execute.memory.store,
                  dispatch[s].uop.imm)
          )) begin
        fp_dispatch[s].op1 = 64'(dispatch[s].op1);
        fp_dispatch[s].pr1 = operand_tag_t'(dispatch[s].pr1);
      end
      fp_dispatch[s].prd = operand_tag_t'(dispatch[s].prd);
      fp_dispatch[s].dest = dispatch[s].dest;
      fp_dispatch[s].generation = dispatch[s].generation;
      fp_dispatch[s].resources = 32'(1) << execution_unit(dispatch[s].uop);
      // Dispatch and a producer may meet on this same edge. Capture its value
      // now; relying only on the queue's next-cycle snoop would lose that pulse.
      {fp_dispatch[s].pr1, fp_dispatch[s].op1} = wake_dispatch_operand(
          fp_dispatch[s].pr1, fp_dispatch[s].op1);
      {fp_dispatch[s].pr2, fp_dispatch[s].op2} = wake_dispatch_operand(
          fp_dispatch[s].pr2, fp_dispatch[s].op2);
      {fp_dispatch[s].pr3, fp_dispatch[s].op3} = wake_dispatch_operand(
          fp_dispatch[s].pr3, fp_dispatch[s].op3);
    end
  end
  function automatic fp_wake_t fp_wake_view(input CompletionT packet);
    fp_wake_view = '0;
    fp_wake_view.valid = packet.valid && !packet.trap && (packet.fp_wen || packet.rd != '0);
    fp_wake_view.prd = packet.fp_wen ? float_tag((RobBits+1)'(packet.dest) + (RobBits+1)'(1))
        : operand_tag_t'(packet.prd);
    fp_wake_view.result = packet.fp_wen ? packet.fp_result : 64'(packet.result);
    fp_wake_view.dest = packet.dest;
    fp_wake_view.generation = packet.generation;
  endfunction
  for (genvar p = 0; p < NumCompletions; p++) begin : g_wake
    assign fp_wake[p] = fp_wake_view(completion[p]);
    assign fp_local_wake[p] = LocalFpWake ? fp_wake_view(local_fp_wake[p]) : '0;
  end
  fp_wake_t early_fp_wake[NumCompletions];
  for (genvar p = 0; p < NumCompletions; p++) begin : g_operand_early
    assign early_fp_wake[p] = fp_wake_view(early_completion[p]);
  end
  assign issue_enable = !reset && !cmu_bcast.flush_pipe;
  assign issued_encoding = fp_issue[0].uop.imm;
  assign issued_fp = fp_issue[0].uop.execute.fp;
  always_comb begin
    iss = fp_issue[0];
    iss.uop.imm = issued_encoding;
    iss.uop.execute.fp = issued_fp;
  end
  // One elastic register-read ticket. Queue payload/data remains the
  // simulation oracle and is dead in synthesis.
  fp_issue_t fpq_selected[1], read_ticket, read_ticket_incoming;
  logic [2:0][RobBits:0] fp_queue_source_tag[FPQ_SIZE], read_ticket_tag;
  logic [2:0][GenerationBits-1:0] fp_queue_source_generation[FPQ_SIZE], read_ticket_generation;
  logic [PLEN-1:0] fp_queue_source_int[FPQ_SIZE], read_ticket_int;
  logic [FPQ_SIZE-1:0] fp_queue_source_valid;
  owner_t fp_queue_source_owner[FPQ_SIZE];
  generation_t fp_queue_source_owner_generation[FPQ_SIZE];
  logic fpq_selected_owner_matches;
  /* verilator lint_off UNUSEDSIGNAL */
  int fpq_selected_index;
  /* verilator lint_on UNUSEDSIGNAL */
  logic read_ticket_fire, read_ticket_space, read_ticket_ready;
  assign fpq_selected_index = int'(fpq_selected[0].entry_index);
  assign fpq_selected_owner_matches = fp_queue_source_valid[fpq_selected_index]
      && fp_queue_source_owner[fpq_selected_index] == fpq_selected[0].dest
      && fp_queue_source_owner_generation[fpq_selected_index] == fpq_selected[0].generation;
  logic [Units-1:0] fpq_resource_ready;
  logic [2:0] fp_sources_used, source_retire_hit;
  logic [2:0][63:0] read_operands;
  logic fp_from_int;
  int read_ticket_unit;
  function automatic logic [2:0][RobBits:0] retag_retired_sources(
      input logic [2:0][RobBits:0] tags, input logic [2:0][GenerationBits-1:0] generations);
    logic [2:0][RobBits:0] migrated;
    migrated = tags;
    for (int k = 0; k < 3; k++) begin
      for (int c = 0; c < Cfg.commit_width; c++) begin
        if (tags[k] != '0 && fp_retire_valid[c]
            && tags[k] == (RobBits+1)'(fp_retire_owner[c]) + (RobBits+1)'(1)
            && generations[k] == fp_retire_generation[c])
          migrated[k] = '0;
      end
    end
    return migrated;
  endfunction
  assign fp_queue_read_uop = read_ticket.uop;
  // An invalidated ticket may retain tags whose owners were flushed or reused.
  // Only a live ticket requests producer resolution from the ROB result bank.
  assign fp_queue_read_tag = read_ticket.valid ? read_ticket_tag : '0;
  assign int_operand_address = read_ticket_int;
  assign read_ticket_unit = execution_unit(read_ticket.uop);
  assign fp_sources_used = rapt_pkg::fp_sources(read_ticket.uop.execute.fp.valid,
      read_ticket.uop.execute.fp.op,
      rapt_pkg::fp_instruction(read_ticket.uop.execute.memory.load,
          read_ticket.uop.execute.memory.store, read_ticket.uop.imm));
  assign fp_from_int = rapt_pkg::fp_from_integer(read_ticket.uop.execute.fp.op,
      rapt_pkg::fp_instruction(read_ticket.uop.execute.memory.load,
          read_ticket.uop.execute.memory.store, read_ticket.uop.imm));
  always_comb begin
    read_ticket_ready = !fp_from_int || int_operand_valid;
    source_retire_hit = '0;
    read_operands = operand_read_value;
    for (int k = 0; k < 3; k++) begin
      for (int c = 0; c < Cfg.commit_width; c++) begin
        if (read_ticket_tag[k] != '0 && fp_retire_valid[c]
            && read_ticket_tag[k] == (RobBits+1)'(fp_retire_owner[c]) + (RobBits+1)'(1)
            && read_ticket_generation[k] == fp_retire_generation[c]) begin
          source_retire_hit[k] = 1'b1;
          // The ticket retags to the architectural bank on the retirement edge.
          // Before that edge the producer result is still readable by its tag.
        end
      end
    end
    for (int k = 0; k < 3; k++) begin
      if (fp_sources_used[k])
        read_ticket_ready &= source_retire_hit[k] || (fp_queue_ready_tag[k] == '0
          && (read_ticket_tag[k] == '0
              || fp_queue_read_generation[k] == read_ticket_generation[k]));
    end
    for (int u = 0; u < Units; u++) begin
      fpq_resource_ready[u] = (unit_credit[u]
          || (unit_completion[u].valid && unit_accept[u]))
          && (u == DivSqrt ? arithmetic_ready[u] : 1'b1);
    end
    if (read_ticket.valid && read_ticket_unit == DivSqrt) fpq_resource_ready[DivSqrt] = 1'b0;
  end
  always_comb begin
    dispatch_bypass_choice = -1;
    for (int s = 0; s < NumSlots; s++) begin
      if (dispatch_bypass_choice < 0 && !read_ticket.valid && fpq_occupancy == '0
          && disp_fpq.accept[s] && fp_dispatch[s].pr1 == '0
          && fp_dispatch[s].pr2 == '0 && fp_dispatch[s].pr3 == '0
          && unit_ready[execution_unit(
              fp_dispatch[s].uop
          )])
        dispatch_bypass_choice = s;
    end
    read_ticket_incoming = fpq_selected[0];
    if (dispatch_bypass_choice >= 0) begin
      read_ticket_incoming = '0;
      read_ticket_incoming.valid = 1'b1;
      read_ticket_incoming.uop = fp_dispatch[dispatch_bypass_choice].uop;
      read_ticket_incoming.prd = fp_dispatch[dispatch_bypass_choice].prd;
      read_ticket_incoming.dest = fp_dispatch[dispatch_bypass_choice].dest;
      read_ticket_incoming.generation = fp_dispatch[dispatch_bypass_choice].generation;
      // The bypass requires resolved tags; dispatch already captured any wake.
      read_ticket_incoming.op1 = fp_dispatch[dispatch_bypass_choice].op1;
      read_ticket_incoming.op2 = fp_dispatch[dispatch_bypass_choice].op2;
      read_ticket_incoming.op3 = fp_dispatch[dispatch_bypass_choice].op3;
    end
  end
  assign read_ticket_fire = read_ticket.valid && unit_ready[read_ticket_unit]
      && !cancelled_now(read_ticket.dest) && !reset && !cmu_bcast.flush_pipe;
  assign read_ticket_space = !read_ticket.valid || read_ticket_fire;
  always_comb begin
    fp_issue[0] = read_ticket;
    fp_issue[0].valid = read_ticket_fire;
    fp_issue[0].op1 = fp_from_int
        ? (read_ticket_int == '0 ? '0 : 64'(int_operand_value)) : read_operands[0];
    fp_issue[0].op2 = read_operands[1];
    fp_issue[0].op3 = read_operands[2];
  end
  always_ff @(posedge clock) begin
    for (int e = 0; e < FPQ_SIZE; e++)
    fp_queue_source_tag[e] <= retag_retired_sources(
        fp_queue_source_tag[e], fp_queue_source_generation[e]
    );
    for (int e = 0; e < FPQ_SIZE; e++) begin
      if (cancelled_now(fp_queue_source_owner[e])) fp_queue_source_valid[e] <= 1'b0;
    end
    if (fpq_selected[0].valid) fp_queue_source_valid[fpq_selected_index] <= 1'b0;
    for (int s = 0; s < NumSlots; s++) begin
      if (fpq_dispatch.accept[s]) begin
        fp_queue_source_valid[disp_fpq.rs_idx[s]] <= 1'b1;
        fp_queue_source_owner[disp_fpq.rs_idx[s]] <= dispatch[s].dest;
        fp_queue_source_owner_generation[disp_fpq.rs_idx[s]] <= dispatch[s].generation;
        fp_queue_source_tag[disp_fpq.rs_idx[s]] <= retag_retired_sources(
            fp_dispatch_tag[s], fp_dispatch_generation[s]);
        fp_queue_source_generation[disp_fpq.rs_idx[s]] <= fp_dispatch_generation[s];
        fp_queue_source_int[disp_fpq.rs_idx[s]] <= int_source_regs[s][0];
      end
    end
    read_ticket_tag <= retag_retired_sources(read_ticket_tag, read_ticket_generation);
    if (read_ticket_fire) read_ticket.valid <= 1'b0;
    if (read_ticket_incoming.valid) begin
      read_ticket <= read_ticket_incoming;
      if (dispatch_bypass_choice >= 0) begin
        read_ticket_tag <= retag_retired_sources(fp_dispatch_tag[dispatch_bypass_choice],
            fp_dispatch_generation[dispatch_bypass_choice]);
        read_ticket_generation <= fp_dispatch_generation[dispatch_bypass_choice];
        read_ticket_int <= int_source_regs[dispatch_bypass_choice][0];
      end else begin
        read_ticket_tag <= retag_retired_sources(fp_queue_source_tag[fpq_selected_index],
            fp_queue_source_generation[fpq_selected_index]);
        read_ticket_generation <= fp_queue_source_generation[fpq_selected_index];
        read_ticket_int <= fp_queue_source_int[fpq_selected_index];
      end
    end
    if (reset || cmu_bcast.flush_pipe) fp_queue_source_valid <= '0;
    if (reset || cmu_bcast.flush_pipe || (read_ticket_incoming.valid ? cancelled_now(
            read_ticket_incoming.dest
        ) : read_ticket.valid && cancelled_now(
            read_ticket.dest
        )))
      read_ticket.valid <= 1'b0;
  end
`ifndef SYNTHESIS
  always_ff @(posedge clock) begin
    if (fpq_selected[0].valid && !fpq_selected_owner_matches) begin
      $display("[%0t] SVA FAIL: %m.N1_FP_SOURCE_OWNER", $time);
      $fatal(1);
    end
    if (read_ticket.valid && !reset && !cmu_bcast.flush_pipe && !cancelled_now(
            read_ticket.dest
        )) begin
      if (!read_ticket_ready) begin
        $display("[%0t] SVA FAIL: %m.N1_FP_RR_READY", $time);
        $fatal(1);
      end
      if (read_ticket_fire && ((fp_from_int && fp_issue[0].op1 !== read_ticket.op1)
          || (fp_sources_used[0] && fp_issue[0].op1 !== read_ticket.op1)
          || (fp_sources_used[1] && fp_issue[0].op2 !== read_ticket.op2)
          || (fp_sources_used[2] && fp_issue[0].op3 !== read_ticket.op3))) begin
        $display("[%0t] SVA FAIL: %m.N1_FP_RR_OPERAND", $time);
        $fatal(1);
      end
    end
  end
`endif
  logic unused_fpq_full;
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
      .ComboCdbWake(1'b1),
      .ComboThirdWake(1'b1),
      .ReadAfterSelect(1'b1),
      .ExposeEntryIndex(1'b1),
      .FilterResources(1'b1),
      .LocalOperandWake(LocalFpWake),
      .NumResources(Units)
  ) u_fpq (
      .local_operand_wake(fp_local_wake),
      .clock,
      .reset,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .cmu_bcast,
      .completion(fp_wake),
      .combo_source(early_fp_wake),
      .dispatch(fp_dispatch),
      .disp(fpq_dispatch),
      // IQ cancels issue.valid on reset/flush. Keep identity selection live so
      // recovery cannot steer the payload mux ahead of FP arithmetic.
      .issue_enable(read_ticket_space),
      .resource_ready(fpq_resource_ready),
      .issue(fpq_selected),
      .occ_o(fpq_occupancy),
      .pmu_iq_full(unused_fpq_full)
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
  logic [63:0] fp_addsub_result;
  logic [4:0] fp_addsub_flags;
  logic fp_addsub_ready, fp_addsub_valid;
  logic [63:0] fp_product_result;
  logic [4:0] fp_product_flags;
  logic fp_product_ready, fp_product_valid;
  logic [63:0] fp_convert_widen_result, fp_convert_narrow_result;
  logic [4:0] fp_convert_widen_flags, fp_convert_narrow_flags;
  logic fp_convert_widen_ready, fp_convert_widen_valid;
  logic fp_convert_narrow_ready, fp_convert_narrow_valid;
  logic [63:0] fp_int_to_fp_result, fp_to_int_result;
  logic [4:0] fp_int_to_fp_flags, fp_to_int_flags;
  logic fp_int_to_fp_ready, fp_to_int_ready;
  logic fp_int_to_fp_valid, fp_to_int_valid;
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
  assign fp_fmv_x_h = fp_zfhmin && iss.uop.imm[31:25] == 7'b1110010;
  assign fp_fmv_h_x = fp_zfhmin && iss.uop.imm[31:25] == 7'b1111010;
  assign fp_fcvt_s_h = fp_zfhmin && iss.uop.imm[31:25] == 7'b0100000
      && iss.uop.imm[24:20] == 5'b00010;
  assign fp_fcvt_d_h = fp_zfhmin && iss.uop.imm[31:25] == 7'b0100001
      && iss.uop.imm[24:20] == 5'b00010;
  assign fp_fcvt_h_s = fp_zfhmin && iss.uop.imm[31:25] == 7'b0100010
      && iss.uop.imm[24:20] == 5'b00000;
  assign fp_fcvt_h_d = fp_zfhmin && iss.uop.imm[31:25] == 7'b0100010
      && iss.uop.imm[24:20] == 5'b00001;
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
  rapt_fpu_integer_to_fp #(
      .MULTI_FORMAT(1'b1)
  ) u_fpu_int_to_fp (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_int_to_fp_launch),
      .ready(fp_int_to_fp_ready),
      .operand(iss.op1),
      .target_double(fp_int_to_double_w || fp_int_to_double_l),
      .int64_input(fp_int_to_double_l || fp_int_to_single_l),
      .unsigned_input(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_WU
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_D_LU
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_WU
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_S_LU),
      .rounding_mode(fp_rounding_mode),
      .result(fp_int_to_fp_result),
      .flags(fp_int_to_fp_flags),
      .result_valid(fp_int_to_fp_valid)
  );
  rapt_fpu_fp_addsub #(
      .MULTI_FORMAT(1'b1)
  ) u_fpu_addsub (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_addsub_launch),
      .ready(fp_addsub_ready),
      .op(iss.uop.execute.fp.op),
      .target_double(fp_addsub_d),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .rounding_mode(fp_rounding_mode),
      .result(fp_addsub_result),
      .flags(fp_addsub_flags),
      .result_valid(fp_addsub_valid)
  );
  // The S and D streams share one 53x53 product resource and owner ring.
  rapt_fpu_fp_product u_mul_fma (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_mul_launch || fp_fma_launch),
      .is_fma(fp_fma_s || fp_fma_d),
      .target_double(fp_mul_d || fp_fma_d),
      .ready(fp_product_ready),
      .op(iss.uop.execute.fp.op),
      .operand_a(fp_operand_a),
      .operand_b(fp_operand_b),
      .operand_c(fp_operand_c),
      .rounding_mode(fp_rounding_mode),
      .result(fp_product_result),
      .flags(fp_product_flags),
      .result_valid(fp_product_valid)
  );
  rapt_fpu_fp_to_int #(
      .MULTI_FORMAT(1'b1)
  ) u_fpu_to_int (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .valid(fp_to_int_launch),
      .ready(fp_to_int_ready),
      .operand(fp_operand_a),
      .source_double(fp_double_to_int_w || fp_double_to_int_l),
      .unsigned_result(iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_WU_S
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_LU_S
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_WU_D
          || iss.uop.execute.fp.op == `RAPT_FP_OP_FCVT_LU_D),
      .int64_target(fp_single_to_int_l || fp_double_to_int_l),
      .rounding_mode(fp_rounding_mode),
      .result(fp_to_int_result),
      .flags(fp_to_int_flags),
      .result_valid(fp_to_int_valid)
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
    launch_packet.npc = iss.uop.pc + (`RAPT_PC_BITS_OF(XLEN))'(iss.uop.c ? 2 : 4);
    launch_packet.fp_wen = !fp_trap && rapt_pkg::fp_writes_register(
        iss.uop.execute.fp.valid, iss.uop.execute.fp.op, iss.uop.imm);
    launch_packet.fp_flags_valid = !fp_trap && (fp_long_op || fp_minmax || fp_compare);
    launch_packet.trap = fp_trap;
    launch_packet.tval = iss.uop.trap ? `RAPT_UOP_TVAL(XLEN, iss.uop) : fp_rm_invalid ? XLEN'(iss.uop.imm) : '0;
    launch_packet.cause = iss.uop.trap ? iss.uop.cause
        : fp_rm_invalid ? 6'(`RAPT_CAUSE_ILLEGAL_INST) : '0;
    launch_packet.updates = '{control_flow:1'b0, memory:1'b0, system_state:1'b1, exception:1'b1};
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
  assign arithmetic_ready[AddSub] = fp_addsub_ready;
  assign raw_valid[AddSub] = fp_addsub_valid;
  assign raw_result[AddSub] = fp_addsub_result;
  assign raw_flags[AddSub] = fp_addsub_flags;
  assign arithmetic_ready[Product] = fp_product_ready;
  assign raw_valid[Product] = fp_product_valid;
  assign raw_result[Product] = fp_product_result;
  assign raw_flags[Product] = fp_product_flags;
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
  assign arithmetic_ready[IntToFp] = fp_int_to_fp_ready;
  assign raw_valid[IntToFp] = fp_int_to_fp_valid;
  assign raw_result[IntToFp] = fp_int_to_fp_result;
  assign raw_flags[IntToFp] = fp_int_to_fp_flags;
  assign arithmetic_ready[FpToInt] = fp_to_int_ready;
  assign raw_valid[FpToInt] = fp_to_int_valid;
  assign raw_result[FpToInt] = fp_to_int_result;
  assign raw_flags[FpToInt] = fp_to_int_flags;
  assign arithmetic_ready[HalfToFp] = fp_half_to_fp_ready;
  assign raw_valid[HalfToFp] = fp_half_to_fp_valid;
  assign raw_result[HalfToFp] = fp_half_to_fp_result;
  assign raw_flags[HalfToFp] = fp_half_to_fp_flags;
  assign arithmetic_ready[FpToHalf] = fp_fp_to_half_ready;
  assign raw_valid[FpToHalf] = fp_fp_to_half_valid;
  assign raw_result[FpToHalf] = fp_fp_to_half_result;
  assign raw_flags[FpToHalf] = fp_fp_to_half_flags;

  for (genvar unit_id = 0; unit_id < Units; unit_id++) begin : g_unit
    // The eight-stage product pipe can launch every cycle. A three-stage
    // pipe needs five credits to launch while its oldest completion pops.
    // DIV/SQRT keeps one iterative owner.
    localparam int Credits = unit_id == DivSqrt ? 1 : (unit_id == Product) ? 12 : 5;
    // Fixed pipelines accept every cycle outside recovery. Their ready outputs
    // include reset/flush, which must qualify transfer rather than selection.
    // Only the iterative engine contributes a registered busy condition.
    assign unit_ready[unit_id] = unit_credit[unit_id]
        && (unit_id == DivSqrt ? arithmetic_ready[unit_id] : 1'b1);
    always_comb begin
      unit_launch[unit_id] = launch_packet;
      unit_launch[unit_id].valid = iss.valid && selected_unit == unit_id;
    end
    rapt_fu_result_queue #(
        .CompletionT(fp_result_t),
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
        .ready(unit_transfer_ready[unit_id]),
        .credit_available(unit_credit[unit_id]),
        .result_valid(raw_valid[unit_id]),
        .result(raw_result[unit_id]),
        .flags(raw_flags[unit_id]),
        .completion(unit_completion[unit_id]),
        .completion_ready(unit_accept[unit_id])
    );
  end
  // Fair completion arbitration. Prefer valid units at or after the cursor,
  // wrapping to the first valid unit only when that suffix is empty.
  logic [Units-1:0] completion_after_cursor, completion_candidates;
  typedef logic [$clog2(Units)-1:0] completion_index_t;
  completion_index_t normalized_cursor;
  assign normalized_cursor = completion_cursor >= completion_index_t'(Units)
      ? completion_cursor - completion_index_t'(Units) : completion_cursor;
  always_comb begin
    for (int u = 0; u < Units; u++)
    completion_after_cursor[u] = unit_completion[u].valid && u >= int'(normalized_cursor);
    for (int u = 0; u < Units; u++)
    completion_candidates[u] = (|completion_after_cursor)
        ? completion_after_cursor[u] : unit_completion[u].valid;
  end
  always_comb begin
    completion_found = 1'b0;
    completion_choice = '0;
    unit_accept = '0;
    for (int u = 0; u < Units; u++) begin
      if (!completion_found && completion_candidates[u]) begin
        completion_found = 1'b1;
        completion_choice = $clog2(Units)'(u);
      end
    end
    if (completion_held && unit_completion[held_choice].valid) begin
      completion_found = 1'b1;
      completion_choice = held_choice;
    end
    completion_grant = completion_found && !reset && !cmu_bcast.flush_pipe;
    wb_fpu = '0;
    `RAPT_FPU_COMPLETION_COPY(wb_fpu, unit_completion[completion_choice])
    // Arbitrate on registered validity only. Late recovery is the final term,
    // so a packet cancelled in its grant cycle drains instead of publishing.
    wb_fpu.valid = completion_grant && !cancelled_now(wb_fpu.dest);
    if (completion_grant && completion_ready) unit_accept[completion_choice] = 1'b1;
  end
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      completion_cursor <= '0;
      completion_held <= 1'b0;
    end else begin
      completion_held <= completion_grant && !completion_ready;
      if (completion_grant && !completion_ready) held_choice <= completion_choice;
      if (completion_grant && completion_ready) completion_cursor <= completion_choice + 1'b1;
    end
  end
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, FP_ISSUE_HAS_UNIT, iss.valid,
                  unit_transfer_ready[selected_unit] && arithmetic_ready[selected_unit])
endmodule
