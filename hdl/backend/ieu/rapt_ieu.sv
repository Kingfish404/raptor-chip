`include "rapt.svh"
`include "rapt_if.svh"

module rapt_ieu #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter bit LocalIntegerWake = 1'b0,
    parameter int unsigned NumIntegerPorts = Cfg.integer_issue_ports,
    parameter int unsigned IntegerSystemPort = Cfg.integer_system_port,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned ALQ_SIZE = Cfg.iq_entries,
    parameter unsigned BRQ_SIZE = rapt_pkg::BranchQueueEntries,
    parameter unsigned MDQ_SIZE = 4,
    parameter unsigned ROB_SIZE = Cfg.rob_entries,
    parameter unsigned PLEN     = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned RLEN     = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned XLEN     = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input CompletionT local_integer_wake[NumCompletions] = '{default: '0},
    input CompletionT branch_wake[NumCompletions] = '{default: '0},
    input CompletionT memory_wake = '0,
    input clock,
    input reset,
    input logic cancel_valid,
    input logic [$clog2(ROB_SIZE)-1:0] cancel_head,
    cancel_owner,
    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    input SlotT dispatch[NumSlots],
    dpu_iq_if.rs disp_alq,
    dpu_iq_if.rs disp_brq,
    dpu_iq_if.rs disp_mdq,

    load_fast_if.sink load_fast,
    input logic integer_system_issue_enable,
    exu_csr_if.master exu_csr,
    output CompletionT wb_integer_raw[NumIntegerPorts],
    output CompletionT wb_branch,
    output CompletionT exu_wb_mul,
    output logic pmu_ooo_valid,
    output logic pmu_ooo_valid_found,
    output logic pmu_ooo_full
);
  IssueT iss_branch;
  IssueT alq_issue[NumIntegerPorts];
  IssueT alq_execute[NumIntegerPorts];
  // The IQ stores operands; selection and the simple ALU execute in one cycle.
  // External load bypass may feed this execute path. Integer results must not
  // feed the same ALQ selector combinationally. Gate cancelled issue packets.
  for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_execute_stage
    logic younger;
    assign younger = ((alq_issue[p].dest < cancel_head) == (cancel_owner < cancel_head))
        ? alq_issue[p].dest > cancel_owner : alq_issue[p].dest < cancel_head;
    always_comb begin
      alq_execute[p] = alq_issue[p];
      alq_execute[p].valid = alq_issue[p].valid && !reset && !cmu_bcast.flush_pipe
          && !(cancel_valid && younger);
    end
  end
  IssueT brq_issue[1];
  logic [NumIntegerPorts-1:0] integer_issue_enable;
  localparam int unsigned IssueCountBits = $clog2(NumIntegerPorts + 1);
  logic [IssueCountBits-1:0] pmu_alq_extra_port_count /* verilator public_flat_rd */;
  logic [IssueCountBits-1:0] pmu_alq_extra_port_count_next;
  assign iss_branch = brq_issue[0];

  // Composition chooses the single CSR/system-capable port and controls its
  // availability independently of the simple-ALU ports. FP owns a separate
  // completion endpoint. Port identity carries no dispatch-lane
  // meaning and the system capability can be relocated at elaboration.
  always_comb begin
    integer_issue_enable = '1;
    integer_issue_enable[IntegerSystemPort] = integer_system_issue_enable;
    pmu_alq_extra_port_count_next = '0;
    for (int p = 2; p < NumIntegerPorts; p++)
    pmu_alq_extra_port_count_next += IssueCountBits'(alq_issue[p].valid);
  end
  // Match rapt_iq's registered selector observations so the simulator samples
  // every issue event on the same architectural edge.
  always_ff @(posedge clock) pmu_alq_extra_port_count <= pmu_alq_extra_port_count_next;

  // ROU admits one serializing system instruction at a time. Capture its
  // CSR address on ALQ admission, before wake/issue arbitration. The CSR value
  // is still read live at execution; counters and read-modify-write data are
  // not sampled early. This removes the ALQ-select -> CSR-address decode path.
  logic [NumSlots-1:0] csr_dispatch_valid;
  logic [11:0] csr_dispatch_addr, csr_read_addr_q;
  for (genvar s = 0; s < NumSlots; s++) begin : g_csr_address
    assign csr_dispatch_valid[s] = disp_alq.accept[s] && dispatch[s].uop.execute.sys.valid;
  end
  always_comb begin
    csr_dispatch_addr = '0;
    for (int s = 0; s < NumSlots; s++)
    csr_dispatch_addr |= {12{csr_dispatch_valid[s]}} & dispatch[s].uop.imm[11:0];
  end
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) csr_read_addr_q <= '0;
    else if (|csr_dispatch_valid) csr_read_addr_q <= csr_dispatch_addr;
  end
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, CSR_DISPATCH_ONE, 1'b1,
                  $onehot0(csr_dispatch_valid))
  `RAPT_SVA_IMPLY(
      clock, reset || cmu_bcast.flush_pipe, CSR_ISSUE_ADDRESS,
      alq_execute[IntegerSystemPort].valid && alq_execute[IntegerSystemPort].uop.execute.sys.valid,
      csr_read_addr_q == alq_execute[IntegerSystemPort].uop.imm[11:0])

  logic [$clog2(ALQ_SIZE):0] occ_alq;
  logic [$clog2(BRQ_SIZE):0] occ_brq;
  logic pmu_alq_full_unused;
  logic pmu_brq_full_unused;

  assign pmu_ooo_valid = (occ_alq != '0) || (occ_brq != '0);
  always_comb begin
    pmu_ooo_valid_found = iss_branch.valid;
    for (int p = 0; p < NumIntegerPorts; p++) pmu_ooo_valid_found |= alq_issue[p].valid;
  end
  assign pmu_ooo_full = (occ_alq == ($clog2(ALQ_SIZE) + 1)'(ALQ_SIZE));

  CompletionT alq_combo[NumCompletions];
  for (genvar p = 0; p < NumCompletions; p++) begin : g_alq_combo
    if (p == NumIntegerPorts + 1) assign alq_combo[p] = memory_wake;
    else assign alq_combo[p] = '0;
  end

  rapt_iq #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .IssueT(IssueT),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .IQ_SIZE  (ALQ_SIZE),
      // Integer queues wake from accepted completions on the next edge; a
      // same-cycle load wake would chain the L1D response, integer select,
      // ALU and the global result broadcast in one cycle.
      .ComboCdbWake(1'b0),
      .LocalOperandWake(LocalIntegerWake),
      .ComboWakePorts(32'(1) << (NumIntegerPorts + 1)),
      .ConfirmCdbWake(1'b0),
      .NumIssuePorts(NumIntegerPorts),
      // Prefer simple ports for general ALU work, leaving the system-capable
      // port available for CSR/system uops when both classes are ready.
      .LastIssuePort(IntegerSystemPort),
      .UniformSimplePorts(1'b1),
      .ROB_SIZE (ROB_SIZE),
      .PLEN     (PLEN),
      .RLEN     (RLEN),
      .XLEN     (XLEN)
  ) u_alq (
      .local_operand_wake(local_integer_wake),
      .combo_source(alq_combo),
      .cancel_valid(cancel_valid),
      .cancel_head(cancel_head),
      .cancel_owner(cancel_owner),
      .completion(completion),
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .dispatch(dispatch),
      .disp         (disp_alq),

      .load_fast    (load_fast),
      .issue_enable (integer_issue_enable),
      .issue(alq_issue),
      .occ_o        (occ_alq),
      .pmu_iq_full  (pmu_alq_full_unused)
  );

  rapt_iq #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .IssueT(IssueT),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .IQ_SIZE (BRQ_SIZE),
      // Branches read operands captured at the queue edge.
      .ComboCdbWake(1'b0),
      .LocalOperandWake(LocalIntegerWake),
      .ConfirmCdbWake(1'b0),
      .ComboWakePorts(~(32'(1) << NumIntegerPorts)),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_brq (
      .local_operand_wake(local_integer_wake),
      .combo_source(branch_wake),
      .cancel_valid(cancel_valid),
      .cancel_head(cancel_head),
      .cancel_owner(cancel_owner),
      .completion(completion),
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .dispatch(dispatch),
      .disp         (disp_brq),

      .load_fast    (load_fast),
      .issue_enable (1'b1),
      .issue(brq_issue),
      .occ_o        (occ_brq),
      .pmu_iq_full  (pmu_brq_full_unused)
  );

  for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_integer_port
    if (p == IntegerSystemPort) begin : g_system
      rapt_ieu_pipe_alu_csr #(
          .UseDispatchCsrAddress(1'b1),
          .ROB_SIZE(ROB_SIZE),
          .XLEN    (XLEN)
      ) u_pipe_alu_csr (
          .cmu_bcast (cmu_bcast),
          .iss       (alq_execute[p]),
          .csr_read_addr(csr_read_addr_q),
          .csr_bcast (csr_bcast),
          .exu_csr   (exu_csr),
          .wb_alu_csr(wb_integer_raw[p])
      );
    end else begin : g_simple
      rapt_ieu_pipe_alu #(
          .XLEN(XLEN)
      ) u_pipe_alu (
          .iss   (alq_execute[p]),
          .wb_alu(wb_integer_raw[p])
      );
    end
  end

  rapt_ieu_pipe_branch #(
      .XLEN(XLEN)
  ) u_pipe_branch (
      .iss      (iss_branch),
      .wb_branch(wb_branch)
  );

  rapt_ieu_muldiv #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .MDQ_SIZE(MDQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_muldiv (
      .cancel_valid(cancel_valid),
      .cancel_head(cancel_head),
      .cancel_owner(cancel_owner),
      .completion(completion),
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .dispatch(dispatch),
      .disp         (disp_mdq),

      .exu_wb_mul   (exu_wb_mul)
  );
  if (!(NumIntegerPorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_ieu configuration");
  end
  if (!(IntegerSystemPort < NumIntegerPorts)) begin : g_invalid_config_1
    $error("Invalid rapt_ieu configuration");
  end
endmodule
