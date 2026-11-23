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
    parameter unsigned XLEN     = Cfg.xlen,
    parameter bit TagOnly       = 1'b0,
    // Optional registered RR pipeline stage between IQ select and PRF read/ALU.
    // Off (0) preserves 0-cycle-overhead ALU/branch/load latencies; on (1)
    // splits IQ select from PRF read + ALU for higher Fmax.
    parameter bit RegisteredIssueRead = 1'b0,
    parameter int NumReadPorts  = TagOnly ? (2 + 2 * (NumIntegerPorts + 1)) : 2
) (
    input logic [1:0][PLEN-1:0] int_source_regs[NumSlots],
    output logic [PLEN-1:0] operand_read_address[NumReadPorts],
    input logic [XLEN-1:0] operand_read_value[NumReadPorts],
    input logic operand_read_valid[NumReadPorts],
    input CompletionT completion[NumCompletions],
    input CompletionT early_completion[NumCompletions],
    input CompletionT local_integer_wake[NumCompletions],
    input CompletionT branch_wake[NumCompletions],
    input CompletionT memory_wake,
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

`ifdef RAPT_V_EXTENSION
    input logic vector_issue_ready,
    output IssueT vector_issue,
    output logic vector_issue_valid,
    output logic [19:0] vector_issue_imm,
`endif
`ifdef RAPT_H_EXTENSION
    input logic hmem_issue_ready,
    output IssueT hmem_issue,
`endif
    input logic integer_system_issue_enable,
`ifdef RAPT_ZAWRS
    input logic reservation_valid,
    input logic wrs_debug_wakeup,
`endif
    exu_csr_if.master exu_csr,
    output CompletionT wb_integer_raw[NumIntegerPorts],
    output CompletionT wb_branch,
    output CompletionT exu_wb_mul,
    output logic pmu_ooo_valid,
    output logic pmu_ooo_valid_found,
    output logic pmu_ooo_full
);
  typedef logic [XLEN-1:0] result_word_t;
  typedef logic [$bits(dispatch[0].uop.pc)-1:0] result_pc_t;
  typedef logic [PLEN-1:0] result_phys_t;
  typedef logic [RLEN-1:0] result_arch_t;
  typedef logic [$bits(dispatch[0].dest)-1:0] result_owner_t;
  typedef logic [$bits(dispatch[0].generation)-1:0] result_generation_t;
  `RAPT_ALU_COMPLETION_TYPE_PC(alu_result_t, result_word_t, result_pc_t, result_phys_t,
                               result_arch_t, result_owner_t, result_generation_t)
  `RAPT_SYSTEM_COMPLETION_TYPE_PC(system_result_t, result_word_t, result_pc_t, result_phys_t,
                                  result_arch_t, result_owner_t, result_generation_t)
  `RAPT_BRANCH_COMPLETION_TYPE_PC(branch_result_t, result_word_t, result_pc_t, result_phys_t,
                                  result_arch_t, result_owner_t, result_generation_t)
  `RAPT_MDU_COMPLETION_TYPE_PC(mdu_result_t, result_word_t, result_pc_t, result_phys_t,
                               result_arch_t, result_owner_t, result_generation_t)
  localparam int AlqIdxBits = (ALQ_SIZE > 1) ? $clog2(ALQ_SIZE) : 1;
  localparam int BrqIdxBits = (BRQ_SIZE > 1) ? $clog2(BRQ_SIZE) : 1;
  localparam int BranchPort = rapt_pkg::completion_branch_port(Cfg);
  typedef struct packed {
    logic valid;
    rapt_pkg::uop_t uop;
    logic [XLEN-1:0] op1, op2, op3;
    logic [$bits(dispatch[0].dest)-1:0] dest;
    logic [$bits(dispatch[0].generation)-1:0] generation;
    logic [PLEN-1:0] prd;
    logic [AlqIdxBits-1:0] entry_index;
  } alq_issue_t;
  typedef struct packed {
    logic valid;
    rapt_pkg::uop_t uop;
    logic [XLEN-1:0] op1, op2, op3;
    logic [$bits(dispatch[0].dest)-1:0] dest;
    logic [$bits(dispatch[0].generation)-1:0] generation;
    logic [PLEN-1:0] prd;
    logic [BrqIdxBits-1:0] entry_index;
  } brq_issue_t;

  IssueT iss_branch;
  alq_issue_t alq_issue_raw[NumIntegerPorts];
  brq_issue_t brq_issue_raw[1];
  IssueT alq_issue[NumIntegerPorts];
  IssueT alq_execute[NumIntegerPorts];
  IssueT brq_issue[1];
`ifdef RAPT_V_EXTENSION
  logic alq_sys_valid_pre_rr;
  rapt_pkg::uop_t alq_sys_uop_pre_rr;
`endif
  for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_alq_issue_cast
    always_comb begin
      alq_issue[p] = '0;
      alq_issue[p].valid = alq_issue_raw[p].valid;
      alq_issue[p].uop = alq_issue_raw[p].uop;
      alq_issue[p].op1 = alq_issue_raw[p].op1;
      alq_issue[p].op2 = alq_issue_raw[p].op2;
      alq_issue[p].op3 = alq_issue_raw[p].op3;
      alq_issue[p].dest = alq_issue_raw[p].dest;
      alq_issue[p].generation = alq_issue_raw[p].generation;
      alq_issue[p].prd = alq_issue_raw[p].prd;
    end
  end
  always_comb begin
    brq_issue[0] = '0;
    brq_issue[0].valid = brq_issue_raw[0].valid;
    brq_issue[0].uop = brq_issue_raw[0].uop;
    brq_issue[0].op1 = brq_issue_raw[0].op1;
    brq_issue[0].op2 = brq_issue_raw[0].op2;
    brq_issue[0].op3 = brq_issue_raw[0].op3;
    brq_issue[0].dest = brq_issue_raw[0].dest;
    brq_issue[0].generation = brq_issue_raw[0].generation;
    brq_issue[0].prd = brq_issue_raw[0].prd;
  end

  if (TagOnly) begin : g_tag_only_rr
    // Per-entry source physical register tags and constant-operand selectors,
    // captured at dispatch and indexed by entry_index on issue selection.
    logic [1:0][PLEN-1:0] alq_src_regs[ALQ_SIZE];
    logic [1:0] alq_const1[ALQ_SIZE];
    logic alq_const2[ALQ_SIZE];
    logic [1:0][PLEN-1:0] brq_src_regs[BRQ_SIZE];
    logic [1:0] brq_const1[BRQ_SIZE];
    logic brq_const2[BRQ_SIZE];
    always_ff @(posedge clock) begin
      for (int s = 0; s < NumSlots; s++) begin
        if (disp_alq.accept[s]) begin
          alq_src_regs[disp_alq.rs_idx[s]] <= int_source_regs[s];
          alq_const1[disp_alq.rs_idx[s]] <= dispatch[s].op1[1:0];
          alq_const2[disp_alq.rs_idx[s]] <= dispatch[s].op2[0];
        end
        if (disp_brq.accept[s]) begin
          brq_src_regs[disp_brq.rs_idx[s]] <= int_source_regs[s];
          brq_const1[disp_brq.rs_idx[s]] <= dispatch[s].op1[1:0];
          brq_const2[disp_brq.rs_idx[s]] <= dispatch[s].op2[0];
        end
      end
    end

    if (RegisteredIssueRead) begin : g_reg_rr
      // One-stage registered RR/Execute boundary: decouples IQ select from
      // post-issue PRF read + ALU/Branch execution.
      IssueT alq_rr_q[NumIntegerPorts];
      logic [PLEN-1:0] alq_rr_pr1_q[NumIntegerPorts], alq_rr_pr2_q[NumIntegerPorts];
      logic [1:0] alq_rr_const1_q[NumIntegerPorts];
      logic alq_rr_const2_q[NumIntegerPorts];
      for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_alq_rr
        wire [AlqIdxBits-1:0] sel_idx = alq_issue_raw[p].entry_index;
        wire younger = `RAPT_ROB_YOUNGER(alq_rr_q[p].dest, cancel_owner, cancel_head);
        always_ff @(posedge clock) begin
          if (reset || cmu_bcast.flush_pipe) begin
            alq_rr_q[p].valid <= 1'b0;
            alq_rr_pr1_q[p] <= '0;
            alq_rr_pr2_q[p] <= '0;
          end else begin
            alq_rr_q[p] <= alq_issue[p];
            alq_rr_pr1_q[p] <= alq_src_regs[sel_idx][0];
            alq_rr_pr2_q[p] <= alq_src_regs[sel_idx][1];
            alq_rr_const1_q[p] <= alq_const1[sel_idx];
            alq_rr_const2_q[p] <= alq_const2[sel_idx];
          end
        end
        assign operand_read_address[2+2*p] = alq_rr_pr1_q[p];
        assign operand_read_address[2+2*p+1] = alq_rr_pr2_q[p];
        always_comb begin
          alq_execute[p] = alq_rr_q[p];
          alq_execute[p].valid = alq_rr_q[p].valid && !reset && !cmu_bcast.flush_pipe
              && !(cancel_valid && younger);
          alq_execute[p].op1 = (alq_rr_pr1_q[p] != '0) ? operand_read_value[2+2*p]
              : rapt_pkg::derive_op1(
                  XLEN'(alq_rr_const1_q[p]),
                  alq_rr_q[p].uop.pc,
                  alq_rr_q[p].uop.imm,
                  alq_rr_q[p].uop.imm[16:12]
              );
          alq_execute[p].op2 = (alq_rr_pr2_q[p] != '0) ? operand_read_value[2+2*p+1]
              : rapt_pkg::derive_op2(XLEN'(alq_rr_const2_q[p]), alq_rr_q[p].uop.imm);
        end
`ifdef RAPT_SVA_ACTIVE
        wire rr_ops_valid = (alq_rr_pr1_q[p] == '0 || operand_read_valid[2+2*p])
            && (alq_rr_pr2_q[p] == '0 || operand_read_valid[2+2*p+1]);
`endif
        `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IEU_ALQ_RR_VALID,
                        alq_execute[p].valid, rr_ops_valid)
      end
`ifdef RAPT_V_EXTENSION
      wire sys_rr_younger =
      `RAPT_ROB_YOUNGER(alq_rr_q[IntegerSystemPort].dest, cancel_owner, cancel_head)
      ;
      assign alq_sys_valid_pre_rr = alq_rr_q[IntegerSystemPort].valid
          && !reset && !(cancel_valid && sys_rr_younger);
      assign alq_sys_uop_pre_rr = alq_rr_q[IntegerSystemPort].uop;
`endif

      IssueT brq_rr_q;
      logic [PLEN-1:0] brq_rr_pr1_q, brq_rr_pr2_q;
      logic [1:0] brq_rr_const1_q;
      logic brq_rr_const2_q;
      wire [BrqIdxBits-1:0] brq_sel_idx = brq_issue_raw[0].entry_index;
      wire brq_younger = `RAPT_ROB_YOUNGER(brq_rr_q.dest, cancel_owner, cancel_head);
      always_ff @(posedge clock) begin
        if (reset || cmu_bcast.flush_pipe) begin
          brq_rr_q.valid <= 1'b0;
          brq_rr_pr1_q <= '0;
          brq_rr_pr2_q <= '0;
        end else begin
          brq_rr_q <= brq_issue[0];
          brq_rr_pr1_q <= brq_src_regs[brq_sel_idx][0];
          brq_rr_pr2_q <= brq_src_regs[brq_sel_idx][1];
          brq_rr_const1_q <= brq_const1[brq_sel_idx];
          brq_rr_const2_q <= brq_const2[brq_sel_idx];
        end
      end
      assign operand_read_address[2+2*NumIntegerPorts] = brq_rr_pr1_q;
      assign operand_read_address[2+2*NumIntegerPorts+1] = brq_rr_pr2_q;
      always_comb begin
        iss_branch = brq_rr_q;
        iss_branch.valid = brq_rr_q.valid && !reset && !cmu_bcast.flush_pipe
            && !(cancel_valid && brq_younger);
        iss_branch.op1 = (brq_rr_pr1_q != '0) ? operand_read_value[2+2*NumIntegerPorts]
            : rapt_pkg::derive_op1(
                XLEN'(brq_rr_const1_q),
                brq_rr_q.uop.pc,
                brq_rr_q.uop.imm,
                brq_rr_q.uop.imm[16:12]
            );
        iss_branch.op2 = (brq_rr_pr2_q != '0) ? operand_read_value[2+2*NumIntegerPorts+1]
            : rapt_pkg::derive_op2(XLEN'(brq_rr_const2_q), brq_rr_q.uop.imm);
      end
`ifdef RAPT_SVA_ACTIVE
      wire brq_rr_ops_valid = (brq_rr_pr1_q == '0 || operand_read_valid[2+2*NumIntegerPorts])
          && (brq_rr_pr2_q == '0 || operand_read_valid[2+2*NumIntegerPorts+1]);
`endif
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IEU_BRQ_RR_VALID, iss_branch.valid,
                      brq_rr_ops_valid)
    end else begin : g_combo_rr
      // Combinational post-issue PRF read: zero extra latency on ALU, branch,
      // ALU->load, and ROB commit while retaining tag-only IQs and dispatch.
      for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_alq_rr
        wire [AlqIdxBits-1:0] sel_idx = alq_issue_raw[p].entry_index;
        wire [PLEN-1:0] pr1 = alq_src_regs[sel_idx][0];
        wire [PLEN-1:0] pr2 = alq_src_regs[sel_idx][1];
        wire younger = `RAPT_ROB_YOUNGER(alq_issue[p].dest, cancel_owner, cancel_head);
        assign operand_read_address[2+2*p] = pr1;
        assign operand_read_address[2+2*p+1] = pr2;
        always_comb begin
          alq_execute[p] = alq_issue[p];
          alq_execute[p].valid = alq_issue[p].valid && !reset && !cmu_bcast.flush_pipe
              && !(cancel_valid && younger);
          alq_execute[p].op1 = (pr1 != '0) ? operand_read_value[2+2*p]
              : rapt_pkg::derive_op1(
                  XLEN'(alq_const1[sel_idx]),
                  alq_issue[p].uop.pc,
                  alq_issue[p].uop.imm,
                  alq_issue[p].uop.imm[16:12]
              );
          alq_execute[p].op2 = (pr2 != '0) ? operand_read_value[2+2*p+1]
              : rapt_pkg::derive_op2(XLEN'(alq_const2[sel_idx]), alq_issue[p].uop.imm);
        end
`ifdef RAPT_SVA_ACTIVE
        wire rr_ops_valid = (pr1 == '0 || operand_read_valid[2+2*p])
            && (pr2 == '0 || operand_read_valid[2+2*p+1]);
`endif
        `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IEU_ALQ_RR_VALID,
                        alq_execute[p].valid, rr_ops_valid)
      end
`ifdef RAPT_V_EXTENSION
      wire sys_combo_younger =
      `RAPT_ROB_YOUNGER(alq_issue[IntegerSystemPort].dest, cancel_owner, cancel_head)
      ;
      assign alq_sys_valid_pre_rr = alq_issue[IntegerSystemPort].valid
          && !reset && !(cancel_valid && sys_combo_younger);
      assign alq_sys_uop_pre_rr = alq_issue[IntegerSystemPort].uop;
`endif

      wire [BrqIdxBits-1:0] brq_sel_idx = brq_issue_raw[0].entry_index;
      wire [PLEN-1:0] brq_pr1 = brq_src_regs[brq_sel_idx][0];
      wire [PLEN-1:0] brq_pr2 = brq_src_regs[brq_sel_idx][1];
      assign operand_read_address[2+2*NumIntegerPorts] = brq_pr1;
      assign operand_read_address[2+2*NumIntegerPorts+1] = brq_pr2;
      always_comb begin
        iss_branch = brq_issue[0];
        iss_branch.op1 = (brq_pr1 != '0) ? operand_read_value[2+2*NumIntegerPorts]
            : rapt_pkg::derive_op1(
                XLEN'(brq_const1[brq_sel_idx]),
                brq_issue[0].uop.pc,
                brq_issue[0].uop.imm,
                brq_issue[0].uop.imm[16:12]
            );
        iss_branch.op2 = (brq_pr2 != '0) ? operand_read_value[2+2*NumIntegerPorts+1]
            : rapt_pkg::derive_op2(XLEN'(brq_const2[brq_sel_idx]), brq_issue[0].uop.imm);
      end
`ifdef RAPT_SVA_ACTIVE
      wire brq_rr_ops_valid = (brq_pr1 == '0 || operand_read_valid[2+2*NumIntegerPorts])
          && (brq_pr2 == '0 || operand_read_valid[2+2*NumIntegerPorts+1]);
`endif
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IEU_BRQ_RR_VALID, iss_branch.valid,
                      brq_rr_ops_valid)
    end
  end else begin : g_capture_execute
    // The IQ stores operands; selection and the simple ALU execute in one cycle.
    // External load bypass may feed this execute path. Integer results must not
    // feed the same ALQ selector combinationally. Gate cancelled issue packets.
    for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_execute_stage
      logic younger;
      assign younger = `RAPT_ROB_YOUNGER(alq_issue[p].dest, cancel_owner, cancel_head);
      always_comb begin
        alq_execute[p] = alq_issue[p];
        alq_execute[p].valid = alq_issue[p].valid && !reset && !cmu_bcast.flush_pipe
            && !(cancel_valid && younger);
      end
    end
`ifdef RAPT_V_EXTENSION
    assign alq_sys_valid_pre_rr = alq_execute[IntegerSystemPort].valid;
    assign alq_sys_uop_pre_rr = alq_execute[IntegerSystemPort].uop;
`endif
    assign iss_branch = brq_issue[0];
  end

  // Wake-at-Select for TagOnly mode: single-cycle ALU and branch-link picks
  // broadcast their physical destination on the selection edge so dependent
  // consumers wake at posedge T and read bypassed results from PRF at T+2.
  CompletionT ieu_local_wake[NumCompletions];
  for (genvar p = 0; p < NumCompletions; p++) begin : g_ieu_local_wake
    if (TagOnly && RegisteredIssueRead && p < NumIntegerPorts) begin : g_alq_select_wake
`ifdef RAPT_V_EXTENSION
      wire is_vector_issue = alq_issue[p].uop.execute.vector;
`else
      wire is_vector_issue = 1'b0;
`endif
      wire single_cycle_wake = alq_issue[p].valid
          && (alq_issue[p].uop.rd != '0) && (alq_issue[p].prd != '0)
          && !alq_issue[p].uop.trap
          && !alq_issue[p].uop.execute.sys.valid
          && !is_vector_issue;
      always_comb begin
        ieu_local_wake[p] = '0;
        ieu_local_wake[p].valid = single_cycle_wake;
        ieu_local_wake[p].prd = alq_issue[p].prd;
        ieu_local_wake[p].rd = alq_issue[p].uop.rd;
      end
    end else if (TagOnly && RegisteredIssueRead && p == BranchPort) begin : g_brq_select_wake
      wire branch_link_wake = brq_issue[0].valid
          && (brq_issue[0].uop.rd != '0) && (brq_issue[0].prd != '0)
          && !brq_issue[0].uop.trap;
      always_comb begin
        ieu_local_wake[p] = '0;
        ieu_local_wake[p].valid = branch_link_wake;
        ieu_local_wake[p].prd = brq_issue[0].prd;
        ieu_local_wake[p].rd = brq_issue[0].uop.rd;
      end
    end else begin : g_pass_local_wake
      assign ieu_local_wake[p] = local_integer_wake[p];
    end
  end

  logic [NumIntegerPorts-1:0] integer_issue_enable;
`ifdef RAPT_ZAWRS
  logic wrs_active;
`endif
  localparam int unsigned IssueCountBits = $clog2(NumIntegerPorts + 1);
  logic [IssueCountBits-1:0] pmu_alq_extra_port_count /* verilator public_flat_rd */;
  logic [IssueCountBits-1:0] pmu_alq_extra_port_count_next;

`ifdef RAPT_V_EXTENSION
  wire sys_port_is_vector = alq_execute[IntegerSystemPort].uop.execute.vector;
`else
  wire sys_port_is_vector = 1'b0;
`endif

  // Composition chooses the single CSR/system-capable port and controls its
  // availability independently of the simple-ALU ports. FP owns a separate
  // completion endpoint. Port identity carries no dispatch-lane
  // meaning and the system capability can be relocated at elaboration.
  always_comb begin
    integer_issue_enable = '1;
`ifdef RAPT_V_EXTENSION
    integer_issue_enable[IntegerSystemPort] = integer_system_issue_enable && vector_issue_ready;
`else
    integer_issue_enable[IntegerSystemPort] = integer_system_issue_enable;
`endif
`ifdef RAPT_H_EXTENSION
    integer_issue_enable[IntegerSystemPort] &= hmem_issue_ready;
`endif
`ifdef RAPT_ZAWRS
    integer_issue_enable[IntegerSystemPort] &= !wrs_active;
`endif
    if (TagOnly && RegisteredIssueRead && alq_execute[IntegerSystemPort].valid
        && (sys_port_is_vector
            || alq_execute[IntegerSystemPort].uop.execute.sys.valid)) begin
      integer_issue_enable[IntegerSystemPort] = 1'b0;
    end
    pmu_alq_extra_port_count_next = '0;
    for (int p = 2; p < NumIntegerPorts; p++)
    pmu_alq_extra_port_count_next += IssueCountBits'(alq_issue[p].valid);
  end
  // Match rapt_iq's registered selector observations so the simulator samples
  // every issue event on the same architectural edge.
  always_ff @(posedge clock) pmu_alq_extra_port_count <= pmu_alq_extra_port_count_next;

`ifdef RAPT_V_EXTENSION
  always_comb begin
    vector_issue = alq_execute[IntegerSystemPort];
    vector_issue.valid &= vector_issue.uop.execute.vector;
  end
  assign vector_issue_valid = alq_sys_valid_pre_rr && alq_sys_uop_pre_rr.execute.vector;
  assign vector_issue_imm = alq_sys_uop_pre_rr.imm[19:0];
`endif
`ifdef RAPT_H_EXTENSION
  always_comb begin
    hmem_issue = alq_execute[IntegerSystemPort];
    hmem_issue.valid &= !hmem_issue.uop.trap && hmem_issue.uop.execute.sys.valid
        && rapt_pkg::is_hmem_inst(
        hmem_issue.uop.imm
    );
  end
`endif

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
  CompletionT brq_combo[NumCompletions];
  for (genvar p = 0; p < NumCompletions; p++) begin : g_alq_combo
    if (p == rapt_pkg::completion_memory_port(Cfg)) begin : g_memory
      assign alq_combo[p] = memory_wake;
    end else begin : g_none
      assign alq_combo[p] = '0;
    end
    assign brq_combo[p] = (TagOnly && RegisteredIssueRead) ? alq_combo[p] : branch_wake[p];
  end

  rapt_iq #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .IssueT(alq_issue_t),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .IQ_SIZE  (ALQ_SIZE),
      // In TagOnly+RegisteredIssueRead mode, a registered RR stage decouples IQ
      // select from PRF read + ALU, so same-cycle tag-only load wakeup keeps
      // 1-cycle load-to-use without chaining L1D response into ALU execution.
      .ComboCdbWake(TagOnly && RegisteredIssueRead),
      .ReclaimOnIssue(1'b0),
      .ExposeEntryIndex(TagOnly),
      .LocalOperandWake(LocalIntegerWake || (TagOnly && RegisteredIssueRead)),
      .TagOnly(TagOnly),
      .ComboWakePorts(32'(1) << rapt_pkg::completion_memory_port(Cfg)),
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
      .local_operand_wake(ieu_local_wake),
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

      .issue_enable (integer_issue_enable),
      .issue(alq_issue_raw),
      .occ_o        (occ_alq),
      .pmu_iq_full  (pmu_alq_full_unused)
  ,
      .resource_ready('1)
  );

  rapt_iq #(
      .SlotT(SlotT),
      .NumSlots(NumSlots),
      .IssueT(brq_issue_t),
      .Cfg(Cfg),
      .NumCompletions(NumCompletions),
      .CompletionT(CompletionT),
      .IQ_SIZE (BRQ_SIZE),
      // Branches read operands after the registered RR boundary in
      // TagOnly+RegisteredIssueRead mode, so same-cycle tag-only load wakeup
      // keeps 1-cycle load-to-branch latency.
      .ComboCdbWake(TagOnly && RegisteredIssueRead),
      .ReclaimOnIssue(1'b0),
      .ExposeEntryIndex(TagOnly),
      .LocalOperandWake(LocalIntegerWake || (TagOnly && RegisteredIssueRead)),
      .TagOnly(TagOnly),
      .ComboWakePorts((TagOnly && RegisteredIssueRead)
                          ? (32'(1) << rapt_pkg::completion_memory_port(Cfg))
                          : ~(32'(1) << rapt_pkg::completion_branch_port(Cfg))),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_brq (
      .local_operand_wake(ieu_local_wake),
      .combo_source(brq_combo),
      .cancel_valid(cancel_valid),
      .cancel_head(cancel_head),
      .cancel_owner(cancel_owner),
      .completion(completion),
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .dispatch(dispatch),
      .disp         (disp_brq),

      .issue_enable (1'b1),
      .issue(brq_issue_raw),
      .occ_o        (occ_brq),
      .pmu_iq_full  (pmu_brq_full_unused)
  ,
      .resource_ready('1)
  );

  for (genvar p = 0; p < NumIntegerPorts; p++) begin : g_integer_port
    if (p == IntegerSystemPort) begin : g_system
      system_result_t result;
      IssueT scalar_issue;
`ifdef RAPT_ZAWRS
      // A WRS reaches here with the ROB serialized. Keep the completion owner
      // live while the cache and interrupt logic continue to service wakeups.
      localparam int WrsWaitCycles = 1024;
      IssueT wrs_issue_q;
      logic wrs_start, wrs_wakeup, wrs_timeout, wrs_stop, wrs_cancel;
      logic wrs_short_q, wrs_tw_q, wrs_vtw_q;
      logic [$clog2(WrsWaitCycles)-1:0] wrs_count;
      assign wrs_wakeup = !reservation_valid || csr_bcast.wrs_irq_pending || wrs_debug_wakeup;
      assign wrs_start = alq_execute[p].valid && !alq_execute[p].uop.trap
          && alq_execute[p].uop.execute.sys.kind == rapt_pkg::SYS_WRS && !wrs_wakeup;
      assign wrs_timeout = (wrs_short_q || wrs_tw_q || wrs_vtw_q) && (&wrs_count);
      assign wrs_stop = wrs_wakeup || wrs_timeout;
      assign wrs_cancel = cmu_bcast.flush_pipe
          || (cancel_valid && `RAPT_ROB_YOUNGER(wrs_issue_q.dest, cancel_owner, cancel_head));
      always_ff @(posedge clock) begin
        if (reset || wrs_cancel) wrs_active <= 1'b0;
        else if (wrs_active && wrs_stop) wrs_active <= 1'b0;
        else if (wrs_start) wrs_active <= 1'b1;
        if (wrs_start) begin
          wrs_issue_q <= alq_execute[p];
          wrs_short_q <= alq_execute[p].uop.imm[24];
          wrs_tw_q <= !alq_execute[p].uop.imm[24]
              && csr_bcast.priv != `RAPT_PRIV_M && csr_bcast.tw;
          wrs_vtw_q <= !alq_execute[p].uop.imm[24]
              && csr_bcast.virt && !csr_bcast.tw && csr_bcast.hstatus_vtw;
          wrs_count <= '0;
        end else if (wrs_active && !wrs_stop && (wrs_short_q || wrs_tw_q || wrs_vtw_q)) begin
          wrs_count <= wrs_count + 1'b1;
        end
      end
`endif
      always_comb begin
        scalar_issue = alq_execute[p];
`ifdef RAPT_ZAWRS
        if (wrs_active) begin
          scalar_issue = wrs_issue_q;
          scalar_issue.valid = wrs_stop && !wrs_cancel && !reset;
          scalar_issue.uop.trap = wrs_timeout && (wrs_tw_q || wrs_vtw_q) && !wrs_wakeup;
          scalar_issue.uop.cause = !scalar_issue.uop.trap ? '0
              : (wrs_tw_q ? `RAPT_CAUSE_ILLEGAL_INST : `RAPT_CAUSE_VIRT_INST);
        end else if (wrs_start) scalar_issue.valid = 1'b0;
`endif
`ifdef RAPT_V_EXTENSION
        scalar_issue.valid &= !scalar_issue.uop.execute.vector;
`endif
`ifdef RAPT_H_EXTENSION
        scalar_issue.valid &= !(!scalar_issue.uop.trap && scalar_issue.uop.execute.sys.valid
            && rapt_pkg::is_hmem_inst(scalar_issue.uop.imm));
`endif
      end
      always_comb begin
        wb_integer_raw[p] = '0;
        `RAPT_SYSTEM_COMPLETION_COPY(wb_integer_raw[p], result)
`ifdef RAPT_H_EXTENSION
        // A trapping result field carries guest-fault metadata to the ROU.
        if (wb_integer_raw[p].trap) wb_integer_raw[p].result = '0;
`endif
      end
      rapt_ieu_pipe_alu_csr #(
          .CompletionT(system_result_t),
          .UseDispatchCsrAddress(1'b1),
          .XLEN    (XLEN)
      ) u_pipe_alu_csr (
          .cmu_bcast (cmu_bcast),
          .iss       (scalar_issue),
          .csr_read_addr(csr_read_addr_q),
          .csr_bcast (csr_bcast),
          .exu_csr   (exu_csr),
          .wb_alu_csr(result)
      );
    end else begin : g_simple
      alu_result_t result;
      always_comb begin
        wb_integer_raw[p] = '0;
        `RAPT_ALU_COMPLETION_COPY(wb_integer_raw[p], result)
`ifdef RAPT_H_EXTENSION
        if (wb_integer_raw[p].trap) wb_integer_raw[p].result = '0;
`endif
      end
      rapt_ieu_pipe_alu #(
          .CompletionT(alu_result_t),
          .XLEN(XLEN)
      ) u_pipe_alu (
          .iss   (alq_execute[p]),
          .wb_alu(result)
      );
    end
  end

  branch_result_t branch_result;
  mdu_result_t mul_result;
  always_comb begin
    wb_branch = '0;
    `RAPT_BRANCH_COMPLETION_COPY(wb_branch, branch_result)
`ifdef RAPT_H_EXTENSION
    if (wb_branch.trap) wb_branch.result = '0;
`endif
  end
  always_comb begin
    exu_wb_mul = '0;
    `RAPT_MDU_COMPLETION_COPY(exu_wb_mul, mul_result)
  end
  rapt_ieu_pipe_branch #(
      .CompletionT(branch_result_t),
      .XLEN(XLEN)
  ) u_pipe_branch (
      .iss      (iss_branch),
      .wb_branch(branch_result)
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
      .XLEN    (XLEN),
      .TagOnly (TagOnly),
      .ResultT(mdu_result_t)
  ) u_muldiv (
      .early_completion,
      .int_source_regs,
      .operand_read_address(operand_read_address[0:1]),
      .operand_read_value(operand_read_value[0:1]),
      .operand_read_valid(operand_read_valid[0:1]),
      .cancel_valid(cancel_valid),
      .cancel_head(cancel_head),
      .cancel_owner(cancel_owner),
      .completion(completion),
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .dispatch(dispatch),
      .disp         (disp_mdq),

      .exu_wb_mul   (mul_result)
  );
  if (!(NumIntegerPorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_ieu configuration");
  end
  if (!(IntegerSystemPort < NumIntegerPorts)) begin : g_invalid_config_1
    $error("Invalid rapt_ieu configuration");
  end
endmodule
