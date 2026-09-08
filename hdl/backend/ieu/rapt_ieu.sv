`include "rapt.svh"
`include "rapt_if.svh"

module rapt_ieu #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned NumIntegerPorts = Cfg.integer_issue_ports,
    parameter int unsigned IntegerSystemPort = Cfg.integer_system_port,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned ALQ_SIZE = Cfg.iq_entries,
    parameter unsigned BRQ_SIZE = 4,
    parameter unsigned MDQ_SIZE = 4,
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
  IssueT brq_issue[1];
  logic [NumIntegerPorts-1:0] integer_issue_enable;
  localparam int unsigned IssueCountBits = $clog2(NumIntegerPorts + 1);
  logic [IssueCountBits-1:0] pmu_alq_extra_port_count /* verilator public_flat_rd */;
  logic [IssueCountBits-1:0] pmu_alq_extra_port_count_next;
  assign iss_branch = brq_issue[0];

  // Composition chooses the single CSR/system-capable port. It may be reserved
  // by the shared integer/FPU completion arbitration; every simple-ALU port
  // remains independently available. Port identity carries no dispatch-lane
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

  rapt_iq #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .IssueT(IssueT),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .IQ_SIZE  (ALQ_SIZE),
      .NumIssuePorts(NumIntegerPorts),
      .ROB_SIZE (ROB_SIZE),
      .PLEN     (PLEN),
      .RLEN     (RLEN),
      .XLEN     (XLEN)
  ) u_alq (
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
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_brq (
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
          .ROB_SIZE(ROB_SIZE),
          .XLEN    (XLEN)
      ) u_pipe_alu_csr (
          .cmu_bcast (cmu_bcast),
          .iss       (alq_issue[p]),
          .csr_bcast (csr_bcast),
          .exu_csr   (exu_csr),
          .wb_alu_csr(wb_integer_raw[p])
      );
    end else begin : g_simple
      rapt_ieu_pipe_alu #(
          .XLEN(XLEN)
      ) u_pipe_alu (
          .iss   (alq_issue[p]),
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
