// Select a harness explicitly so unused hierarchical monitors are not elaborated.
// ---- formal_ioq_owner ----
`include "rapt.svh"
`include "rapt_if.svh"

// Full production IOQ and dispatch arbitration. Only the first edge resets;
// dispatch payloads, wakeups, memory responses, CSR/PMP and recovery stay free.
// This producer-layer contract does not establish ROB allocation/lifetime or
// memory contents, address translation or exception classification.
module formal_ioq_owner (
    input logic clock,
    input logic reset,
    input rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth],
    input rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts],
    input rapt_pkg::completion_t local_fp_wake[rapt_pkg::CompletionPorts],
    input rapt_pkg::execution_domain_t candidate_domain[rapt_pkg::SteerScanEntries],
    input logic candidate_valid[rapt_pkg::SteerScanEntries],
    input rapt_pkg::dispatch_capacity_t other_capacity[rapt_pkg::ExecutionDomains],
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,
    lsu_pipe_if.master exu_lsu,
    lsu_l1d_mmu_if.master exu_l1d
);
  localparam int E = rapt_pkg::CoreConfig.ioq_entries;
  localparam int N = rapt_pkg::DispatchWidth;
  localparam int I = $clog2(E);
  localparam int C = $clog2(E + 1);
  localparam int X = rapt_pkg::CoreConfig.xlen;
  localparam int Pc = $bits(dispatch[0].uop.pc);
  localparam int Gen = $bits(dispatch[0].generation);
  localparam int Phys = $bits(dispatch[0].prd);
  localparam int Arch = $bits(dispatch[0].uop.rd);
  localparam int Rob = $bits(dispatch[0].dest);
  dpu_ioq_if disp ();
  rapt_pkg::dispatch_capacity_t capacity[rapt_pkg::ExecutionDomains];
  rapt_pkg::dispatch_grant_t grant[rapt_pkg::ExecutionDomains];
  logic candidate_ready[rapt_pkg::SteerScanEntries];
  logic selected_valid[N];
  logic [rapt_pkg::index_bits(rapt_pkg::SteerScanEntries)-1:0] selected_candidate[N];
  for (genvar d = 0; d < rapt_pkg::ExecutionDomains; d++) begin : g_capacity
    if (d != int'(rapt_pkg::DOMAIN_MEMORY)) assign capacity[d] = other_capacity[d];
  end
  rapt_dpu #(
      .NumCandidates(rapt_pkg::SteerScanEntries)
  ) dpu (
      .clock,
      .reset,
      .candidate_domain,
      .candidate_valid,
      .candidate_ready,
      .selected_valid,
      .selected_candidate,
      .capacity,
      .grant
  );
  rapt_dispatch_ioq_adapter adapter (
      .queue(disp),
      .capacity(capacity[rapt_pkg::DOMAIN_MEMORY]),
      .grant(grant[rapt_pkg::DOMAIN_MEMORY])
  );
  rapt_pkg::lsu_completion_t result;
  rapt_lsu_ioq #(
      .ResultT(rapt_pkg::lsu_completion_t)
  ) dut (
      .clock,
      .reset,
      .dispatch,
      .completion,
      .local_fp_wake,
      .cmu_bcast,
      .csr_bcast,
      .pmp_state,
      .disp,
      .exu_lsu,
      .exu_l1d,
      .exu_ioq_bcast(result),
      .wb_accept(result.valid),
      .sq_store_payload(),
      .sq_handoff_valid(),
      .sq_forward_pending(),
      .sq_handoff_alu(),
      .sq_waddr_hi(),
      .sq_waddr_third(),
      .sq_wpbmt(),
      .sq_context(),
      .sq_acquire(),
      .pmu_ioq_full()
  );

  // Independent allocation history. The reference chooses its own physical
  // indices from the accepted prefix, never the DUT's allocation decoder.
  logic past_valid = 0;
  logic [E-1:0] live, completed;
  logic [I-1:0] head, tail;
  logic [C-1:0] count;
  logic [I-1:0] allocate_index[N];
  int unsigned accepted;
  logic [Rob-1:0] owner[E];
  logic [Gen-1:0] generation[E];
  logic [Phys-1:0] prd[E];
  logic [Arch-1:0] rd[E];
  logic [Pc-1:0] pc[E];
  logic compressed[E];
  logic is_load[E], is_sc[E], is_lr[E], is_fp[E], release_request[E];
  logic [5:0] fp_op[E];
  logic [E-1:0] response_known;
  logic [X-1:0] response_data[E];
  logic [63:0] response_fp[E];
  wire a_response = exu_lsu.rvalid && exu_lsu.rready;
  wire b_response = exu_lsu.rvalid_b && exu_lsu.rready_b;
  wire [I-1:0] a_owner = dut.load_req_idx_q;
  wire [I-1:0] b_owner = dut.b_req_idx_q;
  wire [I-1:0] output_owner = dut.bcast_idx;
  wire [X-1:0] expected_data = a_response && a_owner == output_owner ? exu_lsu.rdata
      : b_response && b_owner == output_owner ? exu_lsu.rdata_b : response_data[output_owner];
  wire [63:0] expected_fp = a_response && a_owner == output_owner ? exu_lsu.fp_rdata64
      : b_response && b_owner == output_owner ? 64'(exu_lsu.rdata_b) : response_fp[output_owner];
  typedef struct packed {
    logic [I-1:0] owner;
    logic [X-1:0] address;
    rapt_pkg::mem_context_t context_snapshot;
    logic [4:0] operation;
  } request_t;
  request_t request_a, request_b, held_a, held_b;
  wire [Pc+2:0] request_a_side = {
    exu_lsu.pc, exu_lsu.atomic_lock, exu_lsu.atomic_release, exu_lsu.fp_rdata64_req
  };
  logic [Pc+2:0] held_a_side;
  logic held_a_ordered;
  logic a_held, b_held;
  assign request_a = {a_owner, exu_lsu.raddr, exu_lsu.rcontext, exu_lsu.ralu};
  assign request_b = {b_owner, exu_lsu.raddr_b, exu_lsu.rcontext_b, exu_lsu.ralu_b};
  logic seen_flush, seen_wrap;
  logic [E-1:0] ever_allocated;
  always_comb begin
    accepted = 0;
    for (int s = 0; s < N; s++) begin
      allocate_index[s] = I'((int'(tail) + accepted) % E);
      if (disp.accept[s]) accepted++;
    end
  end
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    past_valid <= 1;
    if (reset || cmu_bcast.flush_pipe) begin
      live <= '0;
      completed <= '0;
      response_known <= '0;
      head <= '0;
      tail <= '0;
      count <= '0;
      a_held <= 0;
      b_held <= 0;
    end else begin
      held_a <= request_a;
      held_b <= request_b;
      held_a_side <= request_a_side;
      held_a_ordered <= exu_lsu.ordered;
      a_held <= exu_lsu.rvalid && !(exu_lsu.rready || exu_lsu.rretry || exu_lsu.rmiss);
      b_held <= exu_lsu.rvalid_b && !(exu_lsu.rready_b || exu_lsu.rretry_b);
      count <= C'(int'(count) + accepted - int'(dut.ioq_valid_found));
      tail <= I'((int'(tail) + accepted) % E);
      if (a_response) begin
        response_known[a_owner] <= 1;
        response_data[a_owner] <= exu_lsu.rdata;
        response_fp[a_owner] <= exu_lsu.fp_rdata64;
      end
      if (b_response) begin
        response_known[b_owner] <= 1;
        response_data[b_owner] <= exu_lsu.rdata_b;
        response_fp[b_owner] <= 64'(exu_lsu.rdata_b);
      end
      if (result.valid) completed[dut.bcast_idx] <= 1;
      if (dut.ioq_valid_found) begin
        live[head] <= 0;
        completed[head] <= 0;
        response_known[head] <= 0;
        head <= head + 1'b1;
      end
      for (int s = 0; s < N; s++) begin
        if (disp.accept[s]) begin
          live[allocate_index[s]] <= 1;
          completed[allocate_index[s]] <= 0;
          response_known[allocate_index[s]] <= 0;
          owner[allocate_index[s]] <= dispatch[s].dest;
          generation[allocate_index[s]] <= dispatch[s].generation;
          prd[allocate_index[s]] <= dispatch[s].prd;
          rd[allocate_index[s]] <= dispatch[s].uop.rd;
          pc[allocate_index[s]] <= dispatch[s].uop.pc;
          compressed[allocate_index[s]] <= dispatch[s].uop.c;
          is_load[allocate_index[s]] <= dispatch[s].uop.execute.memory.load;
          is_sc[allocate_index[s]] <= dispatch[s].uop.execute.memory.atomic
              && dispatch[s].uop.execute.int_op.alu == `RAPT_ATO_SC__;
          is_lr[allocate_index[s]] <= dispatch[s].uop.execute.memory.atomic
              && dispatch[s].uop.execute.int_op.alu == `RAPT_ATO_LR__;
          release_request[allocate_index[s]] <= dispatch[s].uop.execute.memory.atomic
              && dispatch[s].uop.execute.memory.rl;
          is_fp[allocate_index[s]] <= dispatch[s].uop.execute.fp.valid;
          fp_op[allocate_index[s]] <= dispatch[s].uop.execute.fp.op;
        end
      end
    end
    if (reset) begin
      ever_allocated <= '0;
      seen_flush <= 0;
      seen_wrap <= 0;
    end else begin
      if (cmu_bcast.flush_pipe && |live) seen_flush <= 1;
      if (!cmu_bcast.flush_pipe) begin
        for (int s = 0; s < N; s++) begin
          if (disp.accept[s]) begin
            ever_allocated[allocate_index[s]] <= 1;
            if (ever_allocated[allocate_index[s]]) seen_wrap <= 1;
          end
        end
      end
    end
    if (past_valid) begin
      cancellation : assert (!(reset || cmu_bcast.flush_pipe) || !result.valid);
      occupancy :
      assert (live == dut.ioq_valid && head == dut.ioq_head
          && tail == dut.ioq_tail_a && int'(count) + int'(dut.ioq_free_q) == E);
      count_matches_slots : assert ($countones(live) == int'(count));
      ring_tail : assert (tail == I'(int'(head) + int'(count)));
      if (dut.g_precheck_state.legacy_check_valid)
        checked_head_owner : assert (live[head] && dut.ioq_wen[head]);
      if (!reset && !cmu_bcast.flush_pipe) begin
        admission_credit : assert (accepted <= E - int'(count));
        if (exu_lsu.rvalid)
          request_a_live :
          assert (live[a_owner] && !completed[a_owner]
            && is_load[a_owner] && !response_known[a_owner]);
        if (exu_lsu.rvalid_b)
          request_b_live :
          assert (live[b_owner] && !completed[b_owner]
            && is_load[b_owner] && !response_known[b_owner]);
        if (exu_lsu.rvalid && exu_lsu.rvalid_b) distinct_requests : assert (a_owner != b_owner);
        if (exu_lsu.rvalid && dut.ioq_atom[a_owner])
          atomic_request_checked :
          assert (a_owner == head && !dut.head_store_fault
              && (!dut.ioq_wen[a_owner] || dut.head_store_check_valid_q));
        if (exu_lsu.rvalid_b)
          plain_b_request :
          assert (!dut.ioq_atom[b_owner]
              && !(X == 32 && is_fp[b_owner] && fp_op[b_owner] == `RAPT_FP_OP_FLD));
        if (a_held) begin
          request_a_stable :
          assert (exu_lsu.rvalid && request_a == held_a && request_a_side == held_a_side);
          ordered_promotion_holds : assert (!held_a_ordered || exu_lsu.ordered);
        end
        if (b_held) request_b_stable : assert (exu_lsu.rvalid_b && request_b == held_b);
        if (exu_lsu.rvalid) begin
          request_pc : assert (exu_lsu.pc == pc[a_owner]);
          request_kind :
          assert (exu_lsu.atomic_lock == is_lr[a_owner]
              && exu_lsu.atomic_release == release_request[a_owner]
              && exu_lsu.fp_rdata64_req == (is_fp[a_owner] && fp_op[a_owner] == `RAPT_FP_OP_FLD));
        end
        for (int s = 0; s < N; s++) if (disp.accept[s]) assert (!live[allocate_index[s]]);
        if (result.valid) begin
          completion_live_once : assert (live[dut.bcast_idx] && !completed[dut.bcast_idx]);
          completion_identity :
          assert ({result.dest, result.generation, result.prd, result.rd}
              == {owner[dut.bcast_idx], generation[dut.bcast_idx],
                  prd[dut.bcast_idx], rd[dut.bcast_idx]});
          completion_pc : assert (result.pc == pc[dut.bcast_idx]);
          completion_updates :
          assert (result.updates.memory && result.updates.exception && $countones(
              result.updates
          ) == 2);
          if (!result.trap)
            completion_npc :
            assert (result.npc == pc[dut.bcast_idx] + Pc'(compressed[dut.bcast_idx] ? 2 : 4));
          if (is_load[output_owner] && !is_sc[output_owner] && !result.trap) begin
            response_owned :
            assert (response_known[output_owner]
                || (a_response && a_owner == output_owner)
                || (b_response && b_owner == output_owner));
            response_value : assert (result.result == expected_data);
          end
          fp_enable :
          assert (result.fp_wen == (!result.trap && is_load[output_owner] && is_fp[output_owner]));
          if (result.fp_wen) begin
            if (fp_op[output_owner] == `RAPT_FP_OP_FLD)
              fp_double_value :
              assert (result.fp_result == expected_fp);
              else if (fp_op[output_owner] == `RAPT_FP_OP_ZFHMIN)
                fp_half_boxing :
                assert (result.fp_result == {48'hffff_ffff_ffff, result.result[15:0]});
                else
                  fp_single_boxing :
                  assert (result.fp_result == {32'hffff_ffff, result.result[31:0]});
          end
        end
        if (dut.ioq_valid_found) begin
          removal_live : assert (count != 0 && live[head]);
          removal_completed : assert (completed[head] || (result.valid && dut.bcast_idx == head));
        end
      end
    end
    all_physical_slots : cover (past_valid && (&ever_allocated) && !reset);
    full_queue : cover (past_valid && int'(count) == E && !reset);
    reuse_after_wrap : cover (past_valid && seen_wrap && result.valid && !reset);
    recovery_then_completion : cover (past_valid && seen_flush && result.valid && !reset);
    simultaneous_allocate_remove :
    cover (past_valid && accepted != 0 && dut.ioq_valid_found && !reset && !cmu_bcast.flush_pipe);
    head_completion : cover (past_valid && result.valid && !dut.early_bcast_select && !reset);
    early_completion : cover (past_valid && result.valid && dut.early_bcast_select && !reset);
    if (!`RAPT_IOQ_LOAD_RESPONSE_STAGE)
      live_a_completion : cover (past_valid && result.valid && dut.early_bcast_live_a && !reset);
`ifdef RAPT_LSU_HUM
    if (!`RAPT_IOQ_LOAD_RESPONSE_STAGE)
      live_b_completion : cover (past_valid && result.valid && dut.early_bcast_live_b && !reset);
`endif
    stored_response_completion :
    cover (past_valid && result.valid && dut.early_bcast_select
        && !dut.early_bcast_live_a && !dut.early_bcast_live_b && !reset);
    store_completion : cover (past_valid && result.valid && result.wen && !reset);
    trap_completion : cover (past_valid && result.valid && result.trap && !reset);
    fp_completion : cover (past_valid && result.valid && result.fp_wen && !reset);
    a_response_captured : cover (past_valid && a_response && !reset && !cmu_bcast.flush_pipe);
`ifdef RAPT_LSU_HUM
    b_response_captured : cover (past_valid && b_response && !reset && !cmu_bcast.flush_pipe);
`endif
    held_request_completion : cover (past_valid && a_held && result.valid && !reset);
    integer_load_response :
    cover (past_valid && result.valid && !result.trap
        && is_load[output_owner] && !is_sc[output_owner] && !is_fp[output_owner] && !reset);
    atomic_load_response :
    cover (past_valid && result.valid && !result.trap
        && is_load[output_owner] && !is_sc[output_owner] && dut.ioq_atom[output_owner] && !reset);
    sc_completion :
    cover (past_valid && result.valid && !result.trap && is_sc[output_owner] && !reset);
    fp_double_response :
    cover (past_valid && result.valid && result.fp_wen
        && fp_op[output_owner] == `RAPT_FP_OP_FLD && !reset);
    fp_single_response :
    cover (past_valid && result.valid && result.fp_wen
        && fp_op[output_owner] == `RAPT_FP_OP_FLW && !reset);
    fp_half_response :
    cover (past_valid && result.valid && result.fp_wen
        && fp_op[output_owner] == `RAPT_FP_OP_ZFHMIN && !reset);
  end
  for (genvar e = 0; e < E; e++) begin : g_resident
    wire [I-1:0] age = I'(e) - head;
    always_ff @(posedge clock) begin
      if (past_valid) ring_membership : assert (live[e] == (int'(age) < int'(count)));
      if (past_valid && dut.store_prechecked[e])
        prechecked_owner : assert (live[e] && dut.ioq_wen[e] && !dut.ioq_atom[e]);
      if (past_valid && live[e]) begin
        resident_owner : assert (dut.ioq_dest[e] == owner[e]);
        resident_pc : assert (dut.ioq_pc[e] == pc[e] && dut.ioq_c[e] == compressed[e]);
        resident_lane : assert (int'(dut.ioq_payload_lane[e]) < N);
        resident_completed : assert (dut.ioq_early_bcasted[e] == completed[e]);
        if (completed[e])
          early_response_owner :
          assert (response_known[e] && is_load[e] && !dut.ioq_wen[e] && !dut.ioq_atom[e]);
        resident_response : assert (dut.ioq_complete[e] == response_known[e]);
        resident_load_type :
        assert (dut.ioq_ren[e] == is_load[e]
            && (dut.ioq_atom[e] && dut.ioq_alu[e] == `RAPT_ATO_SC__) == is_sc[e]
            && (dut.ioq_atom[e] && dut.ioq_alu[e] == `RAPT_ATO_LR__) == is_lr[e]
            && dut.ioq_release[e] == release_request[e]
            && dut.ioq_fp_valid[e] == is_fp[e] && dut.ioq_fp_op[e] == fp_op[e]);
        if (response_known[e]) begin
          stored_response_data : assert (dut.ioq_rdata[e] == response_data[e]);
          if (is_fp[e] && fp_op[e] == `RAPT_FP_OP_FLD)
            stored_fp_data : assert (dut.ioq_fp_rdata64[e] == response_fp[e]);
        end
      end
    end
    for (genvar s = 0; s < N; s++) begin : g_bank
      wire [Gen+Phys+Arch-1:0] resident = dut.g_payload_bank[s].completion_info[e];
      always_ff @(posedge clock) begin
        if (past_valid && live[e] && int'(dut.ioq_payload_lane[e]) == s)
          resident_metadata : assert (resident == {generation[e], prd[e], rd[e]});
      end
    end
  end
endmodule

`ifdef RAPT_FORMAL_IOQ_STORE
// ---- formal_ioq_store ----

// Owned store operands, AMO byte results and sampled SC decisions.
module formal_ioq_store (
    input logic clock,
    input logic reset,
    input rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth],
    input rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts],
    input rapt_pkg::completion_t local_fp_wake[rapt_pkg::CompletionPorts],
    input rapt_pkg::execution_domain_t candidate_domain[rapt_pkg::SteerScanEntries],
    input logic candidate_valid[rapt_pkg::SteerScanEntries],
    input rapt_pkg::dispatch_capacity_t other_capacity[rapt_pkg::ExecutionDomains],
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,
    lsu_pipe_if.master exu_lsu,
    lsu_l1d_mmu_if.master exu_l1d
);
  localparam int E = rapt_pkg::CoreConfig.ioq_entries;
  localparam int N = rapt_pkg::DispatchWidth;
  localparam int P = rapt_pkg::CompletionPorts;
  localparam int X = rapt_pkg::CoreConfig.xlen;
  localparam int Phys = $bits(dispatch[0].pr2);
  localparam int Ftag = $bits(dispatch[0].fp_tag[1]);
  localparam int I = $clog2(E);
  formal_ioq_owner base (.*);

  // These histories start at the independently accepted dispatch prefix.
  // They never use the DUT's operand banks or allocation decoder as a reference.
  logic [Phys-1:0] source_tag[E];
  logic [X-1:0] source_value[E];
  logic [Ftag-1:0] float_tag[E];
  logic [63:0] float_value[E];
  logic atomic_op[E], acquire_op[E], word_op[E], write_op[E], float_op[E];
  logic [5:0] opcode[E], fp_opcode[E];
  logic [4:0] store_width[E];

  function automatic logic int_hit(input logic [Phys-1:0] tag);
    logic found;
    found = 0;
    for (int p = 0; p < P; p++)
    found |= tag != 0 && completion[p].valid && completion[p].prd == tag;
    return found;
  endfunction

  // All broadcasts are left arbitrary, including duplicate physical tags.
  // The hardware specifies an OR mux for that out-of-contract case as well.
  function automatic logic [X-1:0] int_value(input logic [Phys-1:0] tag,
                                             input logic [X-1:0] fallback);
    logic [X-1:0] value;
    value = '0;
    for (int p = 0; p < P; p++)
    if (tag != 0 && completion[p].valid && completion[p].prd == tag) value |= completion[p].result;
    return int_hit(tag) ? value : fallback;
  endfunction

  function automatic logic fp_match(input logic [Ftag-1:0] tag,
                                    input rapt_pkg::completion_t packet);
    return tag != 0 && packet.valid && packet.fp_wen && !packet.trap
        && tag == Ftag'(packet.dest) + Ftag'(1);
  endfunction

  always_ff @(posedge clock) begin
    for (int e = 0; e < E; e++) begin
      if (base.live[e]) begin
        if (int_hit(source_tag[e])) begin
          source_tag[e] <= '0;
          source_value[e] <= int_value(source_tag[e], source_value[e]);
        end
        if (float_tag[e] != 0) begin
          for (int p = 0; p < P; p++) begin
            if (fp_match(float_tag[e], completion[p])) begin
              float_tag[e] <= '0;
              float_value[e] <= completion[p].fp_result;
            end
            if (fp_match(float_tag[e], local_fp_wake[p])) begin
              float_tag[e] <= '0;
              float_value[e] <= local_fp_wake[p].fp_result;
            end
          end
        end
      end
    end
    for (int s = 0; s < N; s++) begin
      if (base.disp.accept[s]) begin
        source_tag[base.allocate_index[s]] <= int_hit(dispatch[s].pr2) ? '0 : dispatch[s].pr2;
        source_value[base.allocate_index[s]] <= int_value(dispatch[s].pr2, dispatch[s].op2);
        float_tag[base.allocate_index[s]] <= dispatch[s].fp_tag[1];
        float_value[base.allocate_index[s]] <= dispatch[s].fp_value[1];
        for (int p = 0; p < P; p++) begin
          // Allocation observes the registered completion stream. The live
          // FEU stream is resident-only, matching the backend's two phases.
          if (fp_match(dispatch[s].fp_tag[1], completion[p])) begin
            float_tag[base.allocate_index[s]] <= '0;
            float_value[base.allocate_index[s]] <= completion[p].fp_result;
          end
        end
        atomic_op[base.allocate_index[s]] <= dispatch[s].uop.execute.memory.atomic;
        acquire_op[base.allocate_index[s]] <= dispatch[s].uop.execute.memory.atomic
            && dispatch[s].uop.execute.memory.aq;
        word_op[base.allocate_index[s]] <= dispatch[s].uop.execute.int_op.word;
        write_op[base.allocate_index[s]] <= dispatch[s].uop.execute.memory.store;
        float_op[base.allocate_index[s]] <= dispatch[s].uop.execute.fp.valid;
        opcode[base.allocate_index[s]] <= dispatch[s].uop.execute.int_op.alu;
        fp_opcode[base.allocate_index[s]] <= dispatch[s].uop.execute.fp.op;
        store_width[base.allocate_index[s]] <= dispatch[s].uop.execute.memory.atomic
            ? ((X == 32 || dispatch[s].uop.execute.int_op.word) ? 5'd15 : 5'd31)
            : dispatch[s].uop.execute.int_op.alu[4:0];
      end
    end
  end

  // Independent width-normalized AMO reference. Only active store bytes are
  // architectural; AMO.W on RV64 leaves the upper payload bits unspecified.
  function automatic logic [X-1:0] atomic_value(input logic [5:0] operation, input logic narrow,
                                                input logic [X-1:0] old_value,
                                                input logic [X-1:0] operand);
    logic [X-1:0] old_unsigned, operand_unsigned, value;
    logic signed [X-1:0] old_signed, operand_signed;
    old_unsigned = narrow ? X'(old_value[31:0]) : old_value;
    operand_unsigned = narrow ? X'(operand[31:0]) : operand;
    old_signed = narrow ? X'($signed(old_value[31:0])) : $signed(old_value);
    operand_signed = narrow ? X'($signed(operand[31:0])) : $signed(operand);
    value = '0;
    case (operation)
      `RAPT_ATO_SC__, `RAPT_ATO_SWAP: value = operand_unsigned;
      `RAPT_ATO_ADD_: value = old_unsigned + operand_unsigned;
      `RAPT_ATO_XOR_: value = old_unsigned ^ operand_unsigned;
      `RAPT_ATO_AND_: value = old_unsigned & operand_unsigned;
      `RAPT_ATO_OR__: value = old_unsigned | operand_unsigned;
      `RAPT_ATO_MIN_: value = old_signed < operand_signed ? old_unsigned : operand_unsigned;
      `RAPT_ATO_MAX_: value = old_signed > operand_signed ? old_unsigned : operand_unsigned;
      `RAPT_ATO_MINU: value = old_unsigned < operand_unsigned ? old_unsigned : operand_unsigned;
      `RAPT_ATO_MAXU: value = old_unsigned > operand_unsigned ? old_unsigned : operand_unsigned;
      default: value = '0;
    endcase
    return narrow ? X'(value[31:0]) : value;
  endfunction

  wire [I-1:0] head = base.head;
  wire narrow = X == 32 || word_op[head];
  wire [X-1:0] byte_mask = narrow ? X'(32'hffff_ffff) : '1;
  wire [X-1:0] reference_amo = atomic_value(opcode[head], narrow,
      base.response_data[head], source_value[head]);
  wire is_float_store = float_op[head]
      && (fp_opcode[head] == `RAPT_FP_OP_FSW || fp_opcode[head] == `RAPT_FP_OP_FSD
          || (fp_opcode[head] == `RAPT_FP_OP_ZFHMIN && write_op[head]));
  wire [X-1:0] reference_store = atomic_op[head] ? reference_amo
      : is_float_store ? float_value[head][X-1:0] : source_value[head];
  wire head_store_owned = base.live[head] && write_op[head] && source_tag[head] == 0
      && (!is_float_store || float_tag[head] == 0);
  wire amo_data_owned = !atomic_op[head] || opcode[head] == `RAPT_ATO_SC__
      || (base.response_known[head] && base.dut.ioq_complete[head]);

  // Reservation validity and addresses remain arbitrary. Check the sampled
  // decision protocol here; reservation creation/invalidation and atomicity
  // with the actual cache/bus require a separate composition proof.
  logic sc_valid, sc_match;
  logic [I-1:0] sc_head;
  wire sc_head_owned = base.live[head] && atomic_op[head] && opcode[head] == `RAPT_ATO_SC__;
  wire sc_sample = sc_head_owned && base.dut.ioq_pr1[head] == 0
      && source_tag[head] == 0 && !base.dut.ioq_mmu_en[head]
      && base.dut.head_store_check_valid_q;
  wire [X-1:0] sc_address = base.dut.ioq_context[head].mmu_en ? base.dut.ioq_paddr[head]
      : rapt_pkg::canonical_paddr(base.dut.ioq_eff_addr[head]);
  wire [X:0] sc_last = {1'b0, sc_address} + (narrow ? (X+1)'(3) : (X+1)'(7));
  wire [X:0] reservation_last = {1'b0, exu_l1d.reservation}
      + (X+1)'(exu_l1d.reservation_size_m1);
  wire sampled_match = exu_l1d.reservation_valid && sc_address >= exu_l1d.reservation
      && sc_last <= reservation_last;
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe || base.dut.ioq_valid_found || exu_l1d.reservation_blocked)
      sc_valid <= 0;
    else begin
      sc_valid <= sc_sample;
      if (sc_sample) begin
        sc_head <= head;
        sc_match <= sampled_match;
      end
    end
  end

  for (genvar e = 0; e < E; e++) begin : g_operand
    always_ff @(posedge clock) begin
      if (base.past_valid && base.live[e]) begin
        integer_tag_owner : assert (base.dut.ioq_pr2[e] == source_tag[e]);
        integer_data_owner : assert (base.dut.ioq_vk[e] == source_value[e]);
        fp_tag_owner : assert (base.dut.ioq_fp_store_tag[e] == float_tag[e]);
        fp_data_owner : assert (base.dut.ioq_fp_store_data[e] == float_value[e]);
        normalized_store_width :
        assert (store_width[e] == (atomic_op[e]
            ? ((X == 32 || word_op[e]) ? 5'd15 : 5'd31) : opcode[e][4:0]));
        operation_owner :
        assert (base.dut.ioq_atom[e] == atomic_op[e]
            && base.dut.ioq_wen[e] == write_op[e]
            && base.dut.ioq_fp_valid[e] == float_op[e]
            && base.dut.ioq_fp_op[e] == fp_opcode[e]
            && base.dut.ioq_acquire[e] == acquire_op[e] && base.dut.ioq_word[e] == word_op[e]
            && base.dut.ioq_alu[e] == opcode[e] && base.dut.ioq_store_walu[e] == store_width[e]);
      end
      integer_wake :
      cover (base.past_valid && base.live[e] && write_op[e] && !float_op[e]
          && !atomic_op[e] && int_hit(
          source_tag[e]
      ) && !reset && !cmu_bcast.flush_pipe);
      fp_registered_wake :
      cover (base.past_valid && base.live[e] && float_op[e] && write_op[e]
          && !atomic_op[e] && fp_match(
          float_tag[e], completion[0]
      ) && !reset && !cmu_bcast.flush_pipe);
      fp_local_wake :
      cover (base.past_valid && base.live[e] && float_op[e] && write_op[e]
          && !atomic_op[e] && fp_match(
          float_tag[e], local_fp_wake[0]
      ) && !reset && !cmu_bcast.flush_pipe);
    end
  end

  always_ff @(posedge clock) begin
    if (base.past_valid && !reset && !cmu_bcast.flush_pipe) begin
      sc_stage_valid : assert (base.dut.sc_decision_ready == (sc_valid && sc_head == head));
      if (sc_valid && sc_head == head)
        sc_stage_match : assert (base.dut.reservation_match == sc_match);
      if (head_store_owned && amo_data_owned) begin
        sq_owned_data :
        assert ((base.dut.sq_store_payload.sq_wdata & byte_mask) == (reference_store & byte_mask));
        if (!atomic_op[head]) begin
          sq_full_store_data : assert (base.dut.sq_store_payload.sq_wdata == reference_store);
          sq_float64_data : assert (base.dut.sq_store_payload.sq_wdata64 == float_value[head]);
        end
        sq_store_size : assert (base.dut.sq_handoff_alu == store_width[head]);
      end
      if (base.result.valid && !base.dut.early_bcast_select && !base.result.trap
          && atomic_op[head]) begin
        if (opcode[head] == `RAPT_ATO_SC__) begin
          sc_decision_present :
          assert (sc_valid && sc_head == head && !exu_l1d.reservation_blocked);
          sc_result : assert (base.result.result == (sc_match ? X'(0) : X'(1)));
          sc_write_enable : assert (base.result.wen == sc_match);
          sc_clear : assert (exu_l1d.reservation_clear);
        end else if (base.is_load[head]) begin
          amo_old_value : assert (base.result.result == base.response_data[head]);
        end
      end
      if (sc_head_owned && exu_l1d.reservation_blocked) begin
        sc_notification_blocks : assert (!base.result.valid && !base.dut.sq_handoff_valid);
      end
    end
    store_integer :
    cover (base.past_valid && base.result.valid && base.result.wen
        && head_store_owned && !atomic_op[head] && !is_float_store
        && !base.result.trap && !reset);
    store_float :
    cover (base.past_valid && base.result.valid && base.result.wen
        && head_store_owned && is_float_store && !atomic_op[head]
        && !base.result.trap && !reset);
    sc_success :
    cover (base.past_valid && sc_head_owned && base.result.valid
        && base.result.wen && !base.result.trap && !reset);
    sc_failure :
    cover (base.past_valid && sc_head_owned && base.result.valid
        && !base.result.wen && !base.result.trap && !reset);
    sc_notification :
    cover (base.past_valid && sc_head_owned && sc_valid && exu_l1d.reservation_blocked && !reset);
  end
  wire atomic_access_flags = opcode[head] == `RAPT_ATO_LR__
      ? base.is_load[head] && !write_op[head]
      : opcode[head] == `RAPT_ATO_SC__ ? write_op[head] && !base.is_load[head]
      : write_op[head] && base.is_load[head];
  wire atomic_commit = base.past_valid && base.result.valid && atomic_access_flags
      && (opcode[head] == `RAPT_ATO_LR__ || (head_store_owned && amo_data_owned))
      && !base.dut.early_bcast_select && atomic_op[head] && !base.result.trap && !reset;
  `define RAPT_FORMAL_AMO_COVER(Name, Operation) \
  Name``_word: cover (atomic_commit && opcode[head] == Operation && (X == 32 || word_op[head])); \
  if (X == 64) Name``_double: cover (atomic_commit && opcode[head] == Operation && !word_op[head]);
  always_ff @(posedge clock) begin
    `RAPT_FORMAL_AMO_COVER(lr, `RAPT_ATO_LR__)
    `RAPT_FORMAL_AMO_COVER(sc, `RAPT_ATO_SC__)
    `RAPT_FORMAL_AMO_COVER(swap, `RAPT_ATO_SWAP)
    `RAPT_FORMAL_AMO_COVER(add, `RAPT_ATO_ADD_)
    `RAPT_FORMAL_AMO_COVER(xor_op, `RAPT_ATO_XOR_)
    `RAPT_FORMAL_AMO_COVER(and_op, `RAPT_ATO_AND_)
    `RAPT_FORMAL_AMO_COVER(or_op, `RAPT_ATO_OR__)
    `RAPT_FORMAL_AMO_COVER(min_signed, `RAPT_ATO_MIN_)
    `RAPT_FORMAL_AMO_COVER(max_signed, `RAPT_ATO_MAX_)
    `RAPT_FORMAL_AMO_COVER(min_unsigned, `RAPT_ATO_MINU)
    `RAPT_FORMAL_AMO_COVER(max_unsigned, `RAPT_ATO_MAXU)
  end
  `undef RAPT_FORMAL_AMO_COVER
endmodule
`endif
