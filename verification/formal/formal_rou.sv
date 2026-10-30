// Select a harness explicitly so unused hierarchical monitors are not elaborated.
`ifdef RAPT_FORMAL_ROU_RETIRE
// ---- formal_rou_retire ----
`include "rapt.svh"
`include "rapt_if.svh"

// Full production ROU with hostile external inputs. A bound observer below
// checks immutable allocation metadata against the actual retirement banks.
module formal_rou_retire #(
    parameter bit ValidateCompletionInputs = 1'b0
) (
    input rapt_pkg::uop_t fp_queue_read_uop,
    input logic [2:0][$clog2(rapt_pkg::CoreConfig.rob_entries):0] fp_queue_read_tag,
    input logic clock,
    reset,
    input rapt_pkg::completion_t completion[rapt_pkg::CoreConfig.completion_ports],
    rnu_rou_if.slave rnu_rou,
    exu_prf_if.master exu_prf,
    csr_bcast_if.in csr_bcast,
    input logic candidate_ready[rapt_pkg::SteerScanEntries],
    input logic selected_valid[rapt_pkg::DispatchWidth],
    input logic [rapt_pkg::index_bits(rapt_pkg::SteerScanEntries)-1:0]
        selected_candidate[rapt_pkg::DispatchWidth],
    input logic sq_ready,
    sq_empty,
    writeback_done,
    halt_request,
    input logic timer_irq,
    software_irq,
    external_irq,
    supervisor_irq,
    input logic [`RAPT_XLEN-1:0] supervisor_cause
);
  localparam int E = rapt_pkg::CoreConfig.rob_entries;
  localparam int P = rapt_pkg::CoreConfig.completion_ports;
  rou_cmu_if rou_cmu ();
  rou_csr_if rou_csr ();
  rou_lsu_if rou_lsu ();
  rapt_recovery_if recovery ();
  checkpoint_release_if checkpoint_release ();
  rob_completion_owner_if completion_owner ();
  assign rou_lsu.sq_ready = sq_ready;
  assign rou_lsu.sq_empty = sq_empty;
  rapt_pkg::completion_t accepted_completion[P];
  for (genvar p = 0; p < P; p++) begin : g_external_guard
    if (ValidateCompletionInputs) begin : g_local_validation
      assign accepted_completion[p] = completion[p];
    end else begin : g_production_boundary
      logic accepted;
      // Same guard component and payload policy as rapt_backend. Its memory
      // producer is trusted, so the extra memory-port guard here qualifies a
      // composition boundary; it does not discharge that producer obligation.
      rapt_completion_guard #(
          .Entries(E),
          .IndexBits(rapt_pkg::ROBIndexBits),
          .GenerationBits(rapt_pkg::CoreConfig.rob_generation_bits),
          .PhysBits(rapt_pkg::PLENPkg),
          .ArchBits(rapt_pkg::RLENPkg),
          .EnforcePayload(1'b0)
      ) guard (
          .candidate_valid(completion[p].valid),
          .candidate_index(completion[p].dest),
          .candidate_generation(completion[p].generation),
          .candidate_prd(completion[p].prd),
          .candidate_rd(completion[p].rd),
          .live(completion_owner.live),
          .executing(completion_owner.executing),
          .owner_generation(completion_owner.generation),
          .owner_prd(completion_owner.prd),
          .owner_rd(completion_owner.rd),
          .accept(accepted),
          .identity_match(),
          .payload_match()
      );
      always_comb begin
        accepted_completion[p] = completion[p];
        accepted_completion[p].valid = accepted;
      end
    end
  end
  rapt_rou #(
      .ValidateCompletionInputs(ValidateCompletionInputs)
  ) dut_rou (
      .fp_queue_read_uop,
      .fp_queue_read_tag,
      .completion(accepted_completion),
      .operand_wake(accepted_completion),
      .completion_owner,
      .clock,
      .reset,
      .writeback_done,
      .rnu_rou,
      .recovery,
      .checkpoint_release,
      .exu_prf,
      .candidate_ready,
      .selected_valid,
      .selected_candidate,
      .csr_bcast,
      .clint_timer_trap(timer_irq),
      .clint_sw_trap(software_irq),
      .clint_ext_trap(external_irq),
      .s_int_pending(supervisor_irq),
      .s_int_cause(supervisor_cause),
      .rou_cmu,
      .rou_csr,
      .rou_lsu,
      .dm_haltreq_i(halt_request),
      .writeback_drain(),
      .writeback_clean(),
      .writeback_cbo(),
      .writeback_cbo_invalidate(),
      .writeback_block(),
      .rename_buffer_empty_o(),
      .dispatch(),
      .candidate_domain(),
      .candidate_valid(),
      .halted_o(),
      .halt_pc_o(),
      .commit_fire_o(),
      .pmu_rob_full()
  );
endmodule

// The observer defines its own retirement schema and never calls the DUT's
// compaction helper. PC/instruction histories also retain independent widths.
module formal_rou_retire_properties #(
    parameter int RetireBits = 1,
    parameter int Entries = 4,
    parameter int Lanes = 2,
    parameter int RetireWidth = 2,
    parameter int IndexBits = 2,
    parameter int PcBits = 32,
    parameter int StorageBits = 1,
    parameter int Banks = 2,
    parameter bit BankStorage = 1
) (
    input logic clock,
    reset,
    flush_pipe,
    input logic deq_fire[Lanes],
    input logic [IndexBits-1:0] rob_alloc[Lanes],
    input rapt_pkg::dispatch_slot_t allocation[Lanes],
    input logic [Entries-1:0] rob_entry_busy,
    input logic rob_serializing[Entries],
    input logic serialize_in_flight,
    input logic commit_fire[RetireWidth],
    input logic [IndexBits-1:0] retire_read_index[RetireWidth+1],
    input logic [RetireBits-1:0] read_bits[RetireWidth+1],
    input logic [RetireBits-1:0] entry_view[Entries],
    input logic [11:0] serial_imm
);
  typedef struct packed {rapt_pkg::execution_domain_t domain;} ScheduleT;
  typedef struct packed {logic atomic_sc;} IntT;
  typedef struct packed {
    logic conditional, jump, indirect;
    rapt_pkg::ras_action_t ras;
  } BranchT;
  typedef struct packed {
    logic valid, ecall, ebreak, fence_i, fence, mret, sret;
    rapt_pkg::system_kind_t kind;
  } SystemT;
  typedef struct packed {
    IntT int_op;
    BranchT branch;
    SystemT sys;
  } ExecuteT;
  typedef struct packed {
    ScheduleT schedule;
    ExecuteT execute;
    logic fetch_csr_change, c;
`ifdef RAPT_UOP_HAS_INST
    logic [31:0] inst;
`endif
`ifdef RAPT_RVFI
    logic [31:0] rvfi_inst;
`endif
    logic [PcBits-1:1] pc;
  } RetireT;
  if (RetireBits != $bits(RetireT)) begin : g_bad_schema
    $error("Production retirement metadata does not match the independent schema");
  end
  RetireT commit_uop[RetireWidth+1];
  logic past_valid = 0;
  logic [Entries-1:0] known = '0;
  RetireT expected[Entries];
  logic [PcBits-1:0] expected_pc[Entries];
  logic [31:0] expected_inst[Entries], expected_rvfi[Entries];
  logic [11:0] expected_imm[Entries];
  logic seen_wrap = 0, seen_flush = 0;
  logic previous_allocation_valid = 0;
  logic [IndexBits-1:0] previous_alloc;
  always_ff @(posedge clock) begin
    if (!past_valid) assume (reset);
    past_valid <= 1;
    if (reset) begin
      seen_wrap <= 0;
      seen_flush <= 0;
      previous_allocation_valid <= 0;
    end else begin
      // Flush resets the tail; that transition is not circular allocation.
      if (flush_pipe) previous_allocation_valid <= 0;
      else begin
        for (int s = 0; s < Lanes; s++) begin
          if (deq_fire[s]) begin
            previous_alloc <= rob_alloc[s];
            previous_allocation_valid <= 1;
            if (s == 0) begin
              if (previous_allocation_valid && rob_alloc[s] < previous_alloc) seen_wrap <= 1;
            end else if (rob_alloc[s] < rob_alloc[s-1]) seen_wrap <= 1;
          end
        end
      end
      if (flush_pipe && |known) seen_flush <= 1;
    end
    cover (past_valid && deq_fire[Lanes-1] && !reset);
    cover (past_valid && seen_wrap && deq_fire[0] && !reset);
    cover (past_valid && seen_flush && deq_fire[0] && !reset);
    // One witness must visit every physical owner. Separate per-entry cover
    // traces duplicate the same long prefix for production ROB capacities.
    allocated_all_physical_owners : cover (past_valid && (&known) && !reset);
    cover (past_valid && rob_entry_busy[retire_read_index[0]]
        && rob_serializing[retire_read_index[0]] && serial_imm != 0 && !reset);
  end
  for (genvar e = 0; e < Entries; e++) begin : g_history
    wire [StorageBits-1:0] data;
    RetireT stored;
    if (BankStorage) begin : g_bank
      assign data = formal_rou_retire.dut_rou.g_retire_banks.g_bank[e%Banks].data[e/Banks];
    end else begin : g_flop
      assign data = formal_rou_retire.dut_rou.retire_data[e];
    end
    assign stored = {entry_view[e][RetireBits-1-:$bits(ScheduleT)], data};
    always_ff @(posedge clock) begin
      if (reset) known[e] <= 0;
      else begin
        for (int s = 0; s < Lanes; s++) begin
          if (deq_fire[s] && int'(rob_alloc[s]) == e) begin
            known[e] <= 1;
            expected[e] <= '0;
            expected[e].schedule.domain <= allocation[s].uop.schedule.domain;
            expected[e].execute.int_op.atomic_sc <=
                allocation[s].uop.execute.int_op.alu == `RAPT_ATO_SC__;
            expected[e].execute.branch.conditional <= allocation[s].uop.execute.branch.conditional;
            expected[e].execute.branch.jump <= allocation[s].uop.execute.branch.jump;
            expected[e].execute.branch.indirect <= allocation[s].uop.execute.branch.indirect;
            expected[e].execute.branch.ras <= allocation[s].uop.execute.branch.ras;
            expected[e].execute.sys.valid <= allocation[s].uop.execute.sys.valid;
            expected[e].execute.sys.ecall <= allocation[s].uop.execute.sys.ecall;
            expected[e].execute.sys.ebreak <= allocation[s].uop.execute.sys.ebreak;
            expected[e].execute.sys.fence_i <= allocation[s].uop.execute.sys.fence_i;
            expected[e].execute.sys.fence <= allocation[s].uop.execute.sys.fence;
            expected[e].execute.sys.mret <= allocation[s].uop.execute.sys.mret;
            expected[e].execute.sys.sret <= allocation[s].uop.execute.sys.sret;
            expected[e].execute.sys.kind <= allocation[s].uop.execute.sys.kind;
            // CSR address groups from the privileged ISA encoding, independently
            // expressed as a masked group decode rather than the DUT helper.
            expected[e].fetch_csr_change <= allocation[s].uop.imm[11:0] == 12'h180
                || allocation[s].uop.imm[11:2] == 10'h0e8
                || allocation[s].uop.imm[11:4] == 8'h3b;
            expected[e].c <= allocation[s].uop.c;
`ifdef RAPT_UOP_HAS_INST
            expected[e].inst <= allocation[s].uop.inst;
            expected_inst[e] <= allocation[s].uop.inst;
`endif
`ifdef RAPT_RVFI
            expected[e].rvfi_inst <= allocation[s].uop.rvfi_inst;
            expected_rvfi[e] <= allocation[s].uop.rvfi_inst;
`endif
            expected[e].pc <= allocation[s].uop.pc[PcBits-1:1];
            expected_pc[e] <= {allocation[s].uop.pc[PcBits-1:1], 1'b0};
            expected_imm[e] <= allocation[s].uop.imm[11:0];
          end
        end
      end
      if (past_valid) begin
        if (known[e]) begin
          saved_metadata : assert (stored == expected[e]);
          stored_pc : assert ({stored.pc, 1'b0} == expected_pc[e]);
`ifdef RAPT_UOP_HAS_INST
          stored_instruction : assert (stored.inst == expected_inst[e]);
`endif
`ifdef RAPT_RVFI
          stored_rvfi_instruction : assert (stored.rvfi_inst == expected_rvfi[e]);
`endif
        end
        live_owner_known : assert (!rob_entry_busy[e] || known[e]);
        if (known[e])
          serial_flag :
          assert (rob_serializing[e] == (expected[e].execute.sys.valid
              || expected[e].execute.sys.fence_i || expected[e].execute.sys.fence));
        if (rob_entry_busy[e] && rob_serializing[e])
          serial_admission_blocked : assert (serialize_in_flight);
        if (rob_entry_busy[e] && rob_serializing[e])
          serialized_immediate : assert (serial_imm == expected_imm[e]);
      end
    end
  end
  for (genvar c = 0; c <= RetireWidth; c++) begin : g_read
    assign commit_uop[c] = read_bits[c];
    wire [IndexBits-1:0] index = retire_read_index[c];
    always_ff @(posedge clock) begin
      if (past_valid && known[index]) begin
        retirement_metadata : assert (commit_uop[c] == expected[index]);
        full_pc : assert ({commit_uop[c].pc, 1'b0} == expected_pc[index]);
`ifdef RAPT_UOP_HAS_INST
        full_instruction : assert (commit_uop[c].inst == expected_inst[index]);
`endif
`ifdef RAPT_RVFI
        full_rvfi_instruction : assert (commit_uop[c].rvfi_inst == expected_rvfi[index]);
`endif
      end
      if (c < RetireWidth) retired_lane : cover (past_valid && commit_fire[c] && known[index]);
      else lookahead_owner : cover (past_valid && rob_entry_busy[index] && known[index]);
    end
  end
endmodule

bind rapt_rou formal_rou_retire_properties #(
    .RetireBits($bits(retire_uop_t)),
    .Entries(ROB_SIZE),
    .Lanes(NumSlots),
    .RetireWidth(CommitWidth),
    .IndexBits(RBits),
    .PcBits(PcW),
    .StorageBits(RetireDataBits),
    .Banks(RetireBanks),
    .BankStorage(BankRetireData)
) retire_properties (
    .clock,
    .reset,
    .flush_pipe,
    .deq_fire,
    .rob_alloc,
    .allocation,
    .rob_entry_busy,
    .rob_serializing,
    .serialize_in_flight,
    .commit_fire,
    .retire_read_index,
    .read_bits(commit_uop),
    .entry_view(uop_pl),
    .serial_imm
);
`endif

`ifdef RAPT_FORMAL_ROU_RVFI
// ---- formal_rou_rvfi ----
`include "rapt.svh"
`include "rapt_if.svh"

// Actual ROU-to-RVFI transport, with arbitrary rename, completion, CSR and
// operand inputs. Accepted memory completions define the trace history.
// This does not establish execution correctness or memory/bus correspondence.
module formal_rou_rvfi #(
    parameter bit ValidateCompletionInputs = 1'b1
) (
    input logic clock,
    reset,
    input rapt_pkg::completion_t completion[rapt_pkg::CoreConfig.completion_ports],
    rnu_rou_if.slave rnu_rou,
    exu_prf_if.master exu_prf,
    csr_bcast_if.in csr_bcast,
    input logic candidate_ready[rapt_pkg::SteerScanEntries],
    input logic selected_valid[rapt_pkg::DispatchWidth],
    input logic [rapt_pkg::index_bits(rapt_pkg::SteerScanEntries)-1:0]
        selected_candidate[rapt_pkg::DispatchWidth],
    input logic sq_ready,
    sq_empty,
    writeback_done,
    halt_request,
    input logic timer_irq,
    software_irq,
    external_irq,
    supervisor_irq,
    input logic [`RAPT_XLEN-1:0] supervisor_cause,
    input logic [`RAPT_XLEN-1:0] prf_result[rapt_pkg::CommitWidth]
);
  localparam int X = `RAPT_XLEN;
  localparam int N = rapt_pkg::CommitWidth;
  localparam int E = rapt_pkg::CoreConfig.rob_entries;
  localparam int P = rapt_pkg::CoreConfig.completion_ports;
  localparam int B = X / 8;
  rou_cmu_if rou_cmu ();
  rou_csr_if rou_csr ();
  rou_lsu_if rou_lsu ();
  rapt_recovery_if recovery ();
  checkpoint_release_if checkpoint_release ();
  rob_completion_owner_if completion_owner ();
  assign rou_lsu.sq_ready = sq_ready;
  assign rou_lsu.sq_empty = sq_empty;
  rapt_rou #(
      .ValidateCompletionInputs(ValidateCompletionInputs)
  ) dut_rou (
      .completion,
      .operand_wake(completion),
      .completion_owner,
      .clock,
      .reset,
      .writeback_done,
      .rnu_rou,
      .recovery,
      .checkpoint_release,
      .exu_prf,
      .candidate_ready,
      .selected_valid,
      .selected_candidate,
      .csr_bcast,
      .clint_timer_trap(timer_irq),
      .clint_sw_trap(software_irq),
      .clint_ext_trap(external_irq),
      .s_int_pending(supervisor_irq),
      .s_int_cause(supervisor_cause),
      .rou_cmu,
      .rou_csr,
      .rou_lsu,
      .dm_haltreq_i(halt_request),
      .writeback_drain(),
      .writeback_clean(),
      .writeback_cbo(),
      .writeback_cbo_invalidate(),
      .writeback_block(),
      .rename_buffer_empty_o(),
      .dispatch(),
      .candidate_domain(),
      .candidate_valid(),
      .halted_o(),
      .halt_pc_o(),
      .commit_fire_o(),
      .pmu_rob_full()
  );
  logic [X-1:0] rf[32], physical_result[N];
  for (genvar r = 0; r < 32; r++) assign rf[r] = '0;
  for (genvar c = 0; c < N; c++) begin : g_prf_format
    // The production PRF has this exact x0 branch. Other PRF values are free,
    // so no load/AMO result or SC status is inferred from an assumed PRF value.
    assign physical_result[c] = rou_cmu.slot[c].rd == 0 ? '0 : prf_result[c];
  end
  wire [N-1:0] valid, trapped;
  wire [N*X-1:0] read_data, write_data, memory_address, gpr_data;
  wire [N*B-1:0] read_mask, write_mask;
  wire [N*5-1:0] gpr_address;
  rapt_rvfi #(
      .NRET(N),
      .XLEN(X)
  ) dut_trace (
      .clock,
      .reset,
      .rou_cmu,
      .csr_bcast,
      .rf,
      .rd_wdata(physical_result),
      .rvfi_valid(valid),
      .rvfi_trap(trapped),
      .rvfi_mem_rdata(read_data),
      .rvfi_mem_wdata(write_data),
      .rvfi_mem_addr(memory_address),
      .rvfi_mem_rmask(read_mask),
      .rvfi_mem_wmask(write_mask),
      .rvfi_rd_addr(gpr_address),
      .rvfi_rd_wdata(gpr_data),
      .rvfi_order(),
      .rvfi_insn(),
      .rvfi_halt(),
      .rvfi_intr(),
      .rvfi_mode(),
      .rvfi_ixl(),
      .rvfi_rs1_addr(),
      .rvfi_rs2_addr(),
      .rvfi_rs1_rdata(),
      .rvfi_rs2_rdata(),
      .rvfi_pc_rdata(),
      .rvfi_pc_wdata()
  );

  logic [E-1:0] known = '0;
  logic [E-1:0] from_memory_port = '0;
  logic [X-1:0] expected_address[E], expected_physical[E];
  logic [X-1:0] expected_result[E], expected_write[E];
  logic past_valid = 0;
  always_ff @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume (reset);
    assert (((valid >> 1) & ~valid) == 0);
  end
  for (genvar e = 0; e < E; e++) begin : g_history
    always_ff @(posedge clock) begin
      if (reset || dut_rou.g_rob_state[e].allocate_hit) known[e] <= 0;
      for (int p = 0; p < P; p++) begin
        if (!reset && dut_rou.completion_valid[p] && completion[p].updates.memory
            && int'(completion[p].dest) == e) begin
          known[e] <= 1;
          expected_address[e] <= completion[p].tval;
          expected_physical[e] <= completion[p].sq_waddr;
          expected_result[e] <= completion[p].result;
          expected_write[e] <= completion[p].sq_wdata;
          from_memory_port[e] <= p == rapt_pkg::completion_memory_port(rapt_pkg::CoreConfig);
        end
      end
      if (known[e]) begin
        saved_address : assert (dut_rou.rvfi_mem_addr[e] == expected_address[e]);
        saved_result : assert (dut_rou.rvfi_mem_result[e] == expected_result[e]);
        saved_write_data : assert (dut_rou.rvfi_mem_data[e] == expected_write[e]);
      end
    end
  end
  for (genvar c = 0; c < N; c++) begin : g_retirement
    wire [rapt_pkg::ROBIndexBits-1:0] owner = dut_rou.commit_index[c];
    wire [31:0] insn = rou_cmu.slot[c].inst;
    wire load = insn[6:0] == 7'h03;
    wire atomic = insn[6:0] == 7'h2f;
    wire sc = atomic && insn[31:27] == 5'b00011;
    wire reads = load || (atomic && !sc);
    always_ff @(posedge clock) begin
      if (valid[c]) begin
        // Normalized compressed identity HINTs may have an internal x0
        // destination while RVFI describes the original nonzero register.
        if (rou_cmu.slot[c].rd == 0 && (load || atomic)) begin
          assert (gpr_address[c*5+:5] == 0);
        end
        if (gpr_address[c*5+:5] == 0) assert (gpr_data[c*X+:X] == 0);
        if (write_mask[c*B+:B] != 0) begin
          assert (rou_lsu.valid && rou_lsu.store);
          assert (rou_lsu.dest == owner);
        end
        if (known[owner] && !trapped[c]) begin
          if (read_mask[c*B+:B] != 0) assert (read_data[c*X+:X] == expected_result[owner]);
          if ((read_mask[c*B+:B] | write_mask[c*B+:B]) != 0)
            assert (memory_address[c*X+:X] == expected_address[owner]);
          if (write_mask[c*B+:B] != 0) assert (write_data[c*X+:X] == expected_write[owner]);
        end
      end
      if (valid[c] && known[owner] && from_memory_port[owner] && !trapped[c]) begin
        cover (reads && rou_cmu.slot[c].rd == 0 && expected_result[owner] != 0
            && read_mask[c*B+:B] != 0 && read_data[c*X+:X] != 0);
        if (c == 0) begin
          cover (sc && rou_cmu.slot[c].rd == 0 && expected_result[owner] == 1
              && write_mask[c*B+:B] == 0 && !rou_lsu.store);
          cover (sc && expected_result[owner] == 0 && write_mask[c*B+:B] != 0);
        end
        cover ((read_mask[c*B+:B] | write_mask[c*B+:B]) != 0
            && expected_address[owner] != expected_physical[owner]);
      end
    end
  end
endmodule
`endif
