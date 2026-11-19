`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// Backend composition: rename/checkpoints, ROB, dispatch, operand storage,
// issue/execute, completion ownership, LSU/SQ and precise retirement remain
// in one synthesis block. Only decoded uops and memory/control contracts cross.
module rapt_backend #(
    parameter int XLEN = `RAPT_XLEN,
    // Standalone users may supply live idle; the core supplies held completion.
    parameter bit RegisteredDrainCompletion = 1'b0,
    parameter bit CompactFpOperands = 1'b0,
    parameter bit RegisteredDispatchPayload = 1'b0,
    // Rename slots carry rapt_pkg::derive_op* selectors, not constant values.
    parameter bit DerivedConstants = 1'b0,
    parameter bit LocalIntegerWake = 1'b0,
    parameter bit LocalMemoryWake = 1'b0,
    // Keep FP-to-FP queue capture live when the FP broadcast is registered.
    parameter bit LocalFpWake = 1'b0,
    // Reuse the ownership-checked completion register for selected wake ports.
    parameter logic [rapt_pkg::CompletionPorts-1:0] RegisteredOperandWakePorts = '0
) (
    input logic clock,
    input rapt_pkg::sram_ctrl_t sram_ctrl_i,
    input logic writeback_done,
    output logic writeback_drain,
    output logic writeback_clean,
    output logic writeback_cbo,
    output logic writeback_cbo_invalidate,
    output logic [XLEN-1:6] writeback_block,
    idu_rnu_if.slave idu_rnu,
    cmu_bcast_if cmu_bcast,
    csr_bcast_if csr_bcast,
    rapt_recovery_if recovery,
    pmp_update_if pmp_update,
    lsu_l1d_if.master lsu_l1d,
    lsu_l1d_mmu_if.master exu_l1d,
    output logic empty_o,
    output logic sq_empty_o,
    input logic clint_timer_int_i,
    input logic clint_sw_int_i,
    input logic [63:0] mtime_i,
    input logic io_interrupt,
    input logic s_ext_irq_i,
    input logic [XLEN-1:0] hart_id_i,
    input logic dm_haltreq_i,
    rapt_debug_if.hart debug,
    output logic halted_o,
    output logic [`RAPT_PC_BITS_OF(XLEN)-1:0] halt_pc_o,
    output logic commit_fire_o,
    output logic [XLEN-1:0] dbg_gpr_rdata_o,
    input logic dbg_gpr_we_i,
    input logic [4:0] dbg_gpr_addr_i,
    input logic [XLEN-1:0] dbg_gpr_wdata_i,
    input logic [63:0] snapshot_ghr,
    input logic [7:0] snapshot_phr,
    output logic history_restore,
    output logic [63:0] restore_ghr,
    output logic [7:0] restore_phr,
`ifdef RAPT_RVFI
    // RISC-V Formal Interface (RVFI) outputs -- NRET=CommitWidth channels
    output [rapt_pkg::CommitWidth-1:0] rvfi_valid,
    output [rapt_pkg::CommitWidth*64-1:0] rvfi_order,
    output [rapt_pkg::CommitWidth*32-1:0] rvfi_insn,
    output [rapt_pkg::CommitWidth-1:0] rvfi_trap,
    output [rapt_pkg::CommitWidth-1:0] rvfi_halt,
    output [rapt_pkg::CommitWidth-1:0] rvfi_intr,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_mode,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_ixl,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs1_addr,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs2_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs1_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs2_rdata,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rd_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rd_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_addr,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_rmask,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_wmask,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_wdata,
`endif

    input logic reset
);
  // Optional PMU outputs from submodules are not consumed at core level.
  logic pmu_rob_full_unused;
  logic pmu_sq_full_unused;
  logic pmu_ooo_valid_unused;
  logic pmu_ooo_valid_found_unused;
  logic pmu_ooo_full_unused;
  // RNU stage
  rnu_rou_if rnu_operand ();
  logic rou_rename_empty;
  rnu_rou_if rnu_rou ();  // Re-naming => Issue
  checkpoint_release_if checkpoint_release ();  // accepted correct resolutions

  // ROU stage
  rapt_pkg::execution_domain_t dispatch_candidate_domain[rapt_pkg::SteerScanEntries];
  logic dispatch_candidate_valid[rapt_pkg::SteerScanEntries];
  logic dispatch_candidate_ready[rapt_pkg::SteerScanEntries];
  logic [rapt_pkg::index_bits(
rapt_pkg::SteerScanEntries
)-1:0] dispatch_selected_candidate[rapt_pkg::DispatchWidth];
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  logic dispatch_valid[rapt_pkg::DispatchWidth];
  rou_lsu_if rou_lsu ();  // Commit
  rou_cmu_if rou_cmu ();  // Commit

  rou_csr_if rou_csr ();

  dpu_iq_if disp_alq ();
  dpu_iq_if #(.RS_SIZE(rapt_pkg::BranchQueueEntries)) disp_brq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_mdq ();
  dpu_iq_if #(.RS_SIZE(rapt_pkg::CoreConfig.iq_entries)) disp_fpq ();
  dpu_ioq_if disp_ioq ();

  // Integer, branch, memory, MUL/DIV and floating-point producers share the
  // same ownership guard, operand wake and registered ROB completion contract.
  // FP has an independent endpoint so a divide cannot stop an integer port.
  localparam int IntegerIssuePorts = rapt_pkg::CoreConfig.integer_issue_ports;
  // Candidates and accepted packets use the same completion-port layout.
  localparam int BranchPort = rapt_pkg::completion_branch_port(rapt_pkg::CoreConfig);
  localparam int MemoryPort = rapt_pkg::completion_memory_port(rapt_pkg::CoreConfig);
  localparam int MulPort = rapt_pkg::completion_mul_port(rapt_pkg::CoreConfig);
  localparam int FpuPort = rapt_pkg::completion_fpu_port(rapt_pkg::CoreConfig);
  localparam int IntegerSystemPort = rapt_pkg::CoreConfig.integer_system_port;
  rapt_pkg::completion_t wb_integer_raw[IntegerIssuePorts];
`ifdef RAPT_V_EXTENSION
  // Serialized RVV execution with ROB ownership and precise memory faults.
  localparam int VectorRobBits = rapt_pkg::ROBIndexBits;
  localparam int VectorGenerationBits = rapt_pkg::CoreConfig.rob_generation_bits;
  localparam int VectorTagBits = VectorRobBits + VectorGenerationBits;
  typedef struct packed {
    rapt_pkg::pc_t pc;
    rapt_pkg::phys_reg_t prd;
    rapt_pkg::arch_reg_t rd;
  } vector_metadata_t;
  rapt_pkg::issue_packet_t vector_issue;
  rapt_pkg::completion_t wb_integer_ieu[IntegerIssuePorts], vector_completion;
  vector_metadata_t vector_command_metadata, vector_response_metadata;
  logic vector_command_ready, vector_response_valid, vector_authorized;
  logic vector_cancelled, vector_kill_blocked, vector_busy, vector_response_dropped;
  logic vector_trap, vector_dirty, vector_fp_dirty, vector_fp_write, vector_mem_valid;
  logic [4:0] vector_rd, vector_fflags;
  logic [XLEN-1:0] vector_cause, vector_tval, vector_result;
  logic [63:0] vector_fp_result, vector_fp_scalar;
  logic [VectorTagBits-1:0] vector_response_tag, vector_owner_tag;
  logic vector_head_valid, vector_head_safe;

  localparam int VectorIndexBits = $clog2(rapt_pkg::VectorLength) + 1;
  logic vector_mem_ready, vector_mem_write, vector_mem_probe;
  logic [XLEN-1:0] vector_mem_addr;
  logic [1:0] vector_mem_size;
  logic [63:0] vector_mem_wdata, vector_mem_rdata;
  logic [VectorTagBits-1:0] vector_mem_tag, vector_mem_rsp_tag;
  logic [VectorIndexBits-1:0] vector_mem_index, vector_mem_rsp_index;
  logic [2:0] vector_mem_field, vector_mem_rsp_field;
  logic vector_mem_rsp_valid, vector_mem_rsp_ready, vector_mem_rsp_probe;
  logic vector_mem_fault, vector_mem_nonidempotent, vector_mem_response_dropped;
  logic [XLEN-1:0] vector_mem_cause, vector_mem_tval;
  logic vector_memory_q, vector_drain_request, rou_writeback_drain;
  lsu_l1d_if #(.XLEN(XLEN)) scalar_l1d ();
  lsu_l1d_mmu_if #(.XLEN(XLEN)) scalar_mmu ();

  // Vector memory reaches the irrevocable owner only after the complete
  // memory drain, including older posted responses and outstanding fills.
  assign vector_drain_request = vector_busy && vector_memory_q && vector_head_valid
      && vector_owner_tag == {completion_owner.generation[rou_cmu.rob_head], rou_cmu.rob_head}
      && !vector_authorized && !cmu_bcast.flush_pipe;
  assign vector_head_safe = rou_lsu.sq_empty && !cmu_bcast.flush_pipe
      && (!vector_memory_q || (vector_drain_request && writeback_done));
  assign writeback_drain = rou_writeback_drain || vector_drain_request;
  for (genvar p = 0; p < IntegerIssuePorts; p++) begin : g_vector_completion_mux
    if (p == IntegerSystemPort) begin : g_system
      assign wb_integer_raw[p] = vector_response_valid ? vector_completion : wb_integer_ieu[p];
    end else begin : g_other
      assign wb_integer_raw[p] = wb_integer_ieu[p];
    end
  end
  assign vector_command_metadata = {vector_issue.uop.pc, vector_issue.prd, vector_issue.uop.rd};
  assign vector_head_valid = completion_owner.live[rou_cmu.rob_head]
      && completion_owner.executing[rou_cmu.rob_head];
  always_ff @(posedge clock) begin
    if (reset) begin
      vector_owner_tag <= '0;
      vector_memory_q <= 1'b0;
    end else if (vector_issue.valid && vector_command_ready) begin
      vector_owner_tag <= {vector_issue.generation, vector_issue.dest};
      vector_memory_q <= vector_issue.uop.imm[6:0] == 7'h07
          || vector_issue.uop.imm[6:0] == 7'h27;
    end
  end
  always_comb begin
    vector_completion = '0;
    vector_completion.valid = vector_response_valid;
    vector_completion.dest = vector_response_tag[VectorRobBits-1:0];
    vector_completion.generation = vector_response_tag[VectorTagBits-1:VectorRobBits];
    vector_completion.pc = vector_response_metadata.pc;
    vector_completion.npc = vector_response_metadata.pc + rapt_pkg::pc_t'(4);
    vector_completion.prd = vector_response_metadata.prd;
    vector_completion.rd = vector_response_metadata.rd;
    vector_completion.result = vector_result;
    vector_completion.fp_flags_valid = vector_fp_dirty && !vector_trap;
    vector_completion.fp_flags = vector_fflags;
    vector_completion.fp_wen = vector_fp_write && !vector_trap;
    vector_completion.fp_result = vector_fp_result;
    vector_completion.trap = vector_trap;
    vector_completion.cause = 6'(vector_cause);
    vector_completion.tval = vector_tval;
    vector_completion.updates.control_flow = 1'b1;
    vector_completion.updates.system_state = 1'b1;
    vector_completion.updates.exception = 1'b1;
  end
  rapt_vpu_core #(
      .RobBits(VectorRobBits),
      .GenerationBits(VectorGenerationBits),
      .MetadataBits($bits(vector_metadata_t)),
      .XLEN(XLEN),
      .VLEN(rapt_pkg::VectorLength),
      .ELEN(rapt_pkg::VectorElen),
      .BankBits(rapt_pkg::VectorBankBits),
      .Banks(rapt_pkg::VectorBanks),
      .Zvbb(rapt_pkg::VectorBitManip),
      .Zvfhmin(rapt_pkg::VectorHalfConvert),
      .Zvkt(rapt_pkg::VectorDataIndependent),
      .MisalignedMemory(rapt_pkg::VectorMisaligned)
  ) vpu (
      .sram_ctrl_i(sram_ctrl_i),
      .clock(clock),
      .reset(reset),
      .head_safe(vector_head_safe),
      .cmd_metadata(vector_command_metadata),
      .rsp_metadata(vector_response_metadata),
      .authorized(vector_authorized),
      .response_dropped(vector_response_dropped),
      .vector_enabled(csr_bcast.vs != 2'b00),
      .cmd_valid(vector_issue.valid),
      .cmd_ready(vector_command_ready),
      .cmd_tag({vector_issue.generation, vector_issue.dest}),
      .cmd_insn(vector_issue.uop.imm),
      .cmd_rs1(vector_issue.op1),
      .cmd_rs2(vector_issue.op2),
      .cmd_frs1(vector_fp_scalar),
      .cmd_frm(csr_bcast.frm),
      .cmd_fp_enabled(rapt_pkg::FpuEnable && csr_bcast.fs != 2'b00),
      .authorize_valid(vector_head_valid),
      .authorize_ready(),
      .authorize_tag({completion_owner.generation[rou_cmu.rob_head], rou_cmu.rob_head}),
      .kill_valid(cmu_bcast.flush_pipe),
      .kill_tag(vector_owner_tag),
      .cancelled(vector_cancelled),
      .kill_blocked(vector_kill_blocked),
      .busy(vector_busy),
      .rsp_valid(vector_response_valid),
      .rsp_ready(g_completion_guard[IntegerSystemPort].accepted),
      .rsp_tag(vector_response_tag),
      .rsp_trap(vector_trap),
      .rsp_cause(vector_cause),
      .rsp_tval(vector_tval),
      .rsp_rd(vector_rd),
      .rsp_result(vector_result),
      .rsp_dirty(vector_dirty),
      .rsp_fflags(vector_fflags),
      .rsp_fp_dirty(vector_fp_dirty),
      .rsp_fp_write(vector_fp_write),
      .rsp_fp_result(vector_fp_result),
      .mem_valid(vector_mem_valid),
      .mem_ready(vector_mem_ready),
      .mem_write(vector_mem_write),
      .mem_probe(vector_mem_probe),
      .mem_addr(vector_mem_addr),
      .mem_size(vector_mem_size),
      .mem_wdata(vector_mem_wdata),
      .mem_tag(vector_mem_tag),
      .mem_index(vector_mem_index),
      .mem_field(vector_mem_field),
      .mem_rsp_valid(vector_mem_rsp_valid),
      .mem_rsp_ready(vector_mem_rsp_ready),
      .mem_rsp_tag(vector_mem_rsp_tag),
      .mem_rsp_index(vector_mem_rsp_index),
      .mem_rsp_field(vector_mem_rsp_field),
      .mem_rsp_probe(vector_mem_rsp_probe),
      .mem_rdata(vector_mem_rdata),
      .mem_fault(vector_mem_fault),
      .mem_non_idempotent(vector_mem_nonidempotent),
      .mem_cause(vector_mem_cause),
      .mem_tval(vector_mem_tval),
      .mem_response_dropped(vector_mem_response_dropped),
      .host_valid(1'b0),
      .host_ready(),
      .host_write(1'b0),
      .host_addr('0),
      .host_size('0),
      .host_wdata('0),
      .host_rsp_valid(),
      .host_rsp_ready(1'b0),
      .host_rdata()
  );

`ifndef SYNTHESIS
`ifndef RAPT_USE_SRAM_MACRO
`ifdef USE_DPI_C
  // Observe functional VRF SRAMs, rather than reconstructing their contents
  // from completed instructions. These views add no synthesis hardware.
  logic [7:0] vector_byte_view[32*rapt_pkg::VectorLength/8] /* verilator public_flat_rd */;
  logic [XLEN-1:0] vector_csr_view[7] /* verilator public_flat_rd */;
  for (
      genvar byte_index = 0; byte_index < 32 * rapt_pkg::VectorLength / 8; byte_index++
  ) begin : g_vector_observe
    localparam int WordIndex = byte_index / (rapt_pkg::VectorBankBits / 8);
    localparam int BankIndex = WordIndex % rapt_pkg::VectorBanks;
    localparam int RowIndex  = WordIndex / rapt_pkg::VectorBanks;
    localparam int BitOffset = (byte_index % (rapt_pkg::VectorBankBits / 8)) * 8;
    assign vector_byte_view[byte_index] =
        vpu.u_vpu.u_vrf.g_bank[BankIndex].u_sram.mem[RowIndex][BitOffset+:8];
  end
  assign vector_csr_view[0] = XLEN'(vpu.u_vpu.vstart);
  assign vector_csr_view[1] = XLEN'(vpu.u_vpu.vxsat);
  assign vector_csr_view[2] = XLEN'(vpu.u_vpu.vxrm);
  assign vector_csr_view[3] = XLEN'({vpu.u_vpu.vxrm, vpu.u_vpu.vxsat});
  assign vector_csr_view[4] = vpu.u_vpu.vl;
  assign vector_csr_view[5] = vpu.u_vpu.vtype;
  assign vector_csr_view[6] = XLEN'(rapt_pkg::VectorLength/8);
`endif
`endif
`endif

  // One vector element owns the existing L1D/MMU ports until its final
  // response. Serialized admission and the preceding drain exclude scalar
  // requests; the response retains the VPU's element/field identity.
  typedef enum logic [2:0] {
    VM_IDLE,
    VM_CHECK,
    VM_TRANSLATE,
    VM_LOAD_CHECK,
    VM_LOAD,
    VM_STORE,
    VM_RESPONSE
  } vector_mem_state_t;
  vector_mem_state_t vm_state;
  logic vm_write, vm_probe, vm_fault, vm_nonidempotent;
  logic [XLEN-1:0] vm_addr, vm_paddr, vm_cause, vm_tval;
  logic [1:0] vm_size, vm_pbmt;
  logic [63:0] vm_wdata, vm_rdata;
  logic [VectorTagBits-1:0] vm_tag;
  logic [VectorIndexBits-1:0] vm_index;
  logic [2:0] vm_field;
  logic [7:0] vm_context_version;
  logic [3:0] vm_size_m1, vm_access_size_m1, vm_bare_fault_offset;
  logic [4:0] vm_store_alu, vm_load_alu;
  logic [7:0] vm_strobe;
  logic vm_bare_fault, vm_active, vm_wide_split, vm_high_word;
  logic vm_unaligned, vm_preflight, vm_last_byte;
  logic [2:0] vm_byte;
  logic [XLEN-1:0] vm_access_addr, vm_beat_addr;
  logic [63:0] vm_load_data, vm_store_data;
  assign vm_unaligned = rapt_pkg::VectorMisaligned && (vm_addr[2:0] & vm_size_m1[2:0]) != 0;
  assign vm_wide_split = !vm_unaligned && XLEN == 32 && vm_size == 3;
  assign vm_last_byte = vm_byte == vm_size_m1[2:0];
  assign vm_access_size_m1 = vm_unaligned ? 4'd0 : vm_size_m1;
  assign vm_access_addr = vm_addr + XLEN'(vm_unaligned ? vm_byte : 3'd0);
  assign vm_beat_addr = vm_access_addr + XLEN'(vm_wide_split && vm_high_word ? 4 : 0);
  assign vm_load_data = 64'(lsu_l1d.rdata >> (8 * vm_beat_addr[$clog2(XLEN/8)-1:0]));
  assign vm_store_data = vm_wdata >> (vm_unaligned ? (8 * vm_byte)
      : (vm_wide_split && vm_high_word ? 32 : 0));
  rapt_pkg::mem_context_t vm_context;
  pmp_state_if #(.XLEN(XLEN)) vector_pmp ();

  rapt_pmp_state vector_pmp_state (
      .clock(clock),
      .reset(reset),
      .update(pmp_update),
      .state(vector_pmp)
  );
  rapt_ioq_store_check #(
      .XLEN(XLEN)
  ) vector_store_check (
      .store_context(vm_context),
      .pmp_state(vector_pmp),
      .store_addr(vm_access_addr),
      .store_size_m1(vm_access_size_m1),
      .store_valid(vm_state == VM_CHECK && vm_write),
      .store_mmu(1'b0),
      .cmo_mgmt(1'b0),
      .store_bare_fault_offset(vm_bare_fault_offset),
      .store_bare_pmp_trap(vm_bare_fault)
  );

  assign vm_size_m1 = (4'(1) << vm_size) - 1'b1;
  always_comb begin
    case (vm_unaligned ? 2'd0 : vm_size)
      0: begin
        vm_store_alu = `RAPT_SB_WSTRB;
        vm_load_alu = `RAPT_ALU_LBU_;
        vm_strobe = 8'h01;
      end
      1: begin
        vm_store_alu = `RAPT_SH_WSTRB;
        vm_load_alu = `RAPT_ALU_LHU_;
        vm_strobe = 8'h03;
      end
      2: begin
        vm_store_alu = `RAPT_SW_WSTRB;
        vm_load_alu = XLEN == 64 ? `RAPT_ALU_LWU_ : `RAPT_ALU_LW__;
        vm_strobe = 8'h0f;
      end
      default: begin
        vm_store_alu = `RAPT_SD_WSTRB;
        vm_load_alu = `RAPT_ALU_LD__;
        vm_strobe = 8'hff;
      end
    endcase
  end
  // The VPU owns this descriptor until the matching response. Reuse it
  // instead of registering a second copy in the integration bridge.
  assign vm_write = vector_mem_write;
  assign vm_probe = vector_mem_probe;
`ifdef RAPT_SSNPM
  logic [1:0] vm_pmm;
  always_ff @(posedge clock) begin
    if (reset) vm_pmm <= '0;
    else if (vector_mem_valid && vector_mem_ready) vm_pmm <= csr_bcast.data_pmm;
  end
  assign vm_addr = XLEN'(rapt_pkg::mask_pointer(
      64'(vector_mem_addr),
      vm_state == VM_IDLE ? csr_bcast.data_pmm : vm_pmm,
      vm_state == VM_IDLE ? csr_bcast.dmmu_en : vm_context.mmu_en
  ));
`else
  assign vm_addr = vector_mem_addr;
`endif
  assign vm_size = vector_mem_size;
  assign vm_wdata = vector_mem_wdata;
  assign vm_tag = vector_mem_tag;
  assign vm_index = vector_mem_index;
  assign vm_field = vector_mem_field;
  assign vector_mem_ready = vm_state == VM_IDLE;
  assign vm_active = vm_state != VM_IDLE && vm_state != VM_RESPONSE;
  assign vector_mem_rsp_valid = vm_state == VM_RESPONSE;
  assign vector_mem_rsp_tag = vm_tag;
  assign vector_mem_rsp_index = vm_index;
  assign vector_mem_rsp_field = vm_field;
  assign vector_mem_rsp_probe = vm_probe;
  assign vector_mem_rdata = vm_rdata;
  assign vector_mem_fault = vm_fault;
  assign vector_mem_nonidempotent = vm_nonidempotent;
  assign vector_mem_cause = vm_cause;
  assign vector_mem_tval = vm_tval;

  logic vm_store_checked, vm_store_failed, vm_store_device, vm_store_split_device;
  logic [XLEN-1:0] vm_checked_pa, vm_store_cause;
  logic [1:0] vm_checked_pbmt;
  assign vm_store_checked = (vm_state == VM_CHECK && vm_write && !vm_context.mmu_en)
      || (vm_state == VM_TRANSLATE && exu_l1d.ready);
  assign vm_checked_pa = vm_context.mmu_en ? exu_l1d.paddr
      : rapt_pkg::canonical_paddr(vm_access_addr);
  assign vm_checked_pbmt = vm_context.mmu_en ? exu_l1d.pbmt : '0;
  assign vm_store_device = rapt_pkg::addr_device(vm_checked_pa) || vm_checked_pbmt == 2'b10;
  assign vm_store_split_device = vm_store_device && (vm_unaligned || (vm_wide_split && !vm_probe));
  assign vm_store_failed = vm_context.mmu_en ? exu_l1d.trap
      || !rapt_pkg::addr_data_span_capable(vm_checked_pa, vm_access_size_m1, 1'b1)
      || !rapt_pkg::addr_device_width_capable(vm_checked_pa, vm_access_size_m1)
      : vm_bare_fault;
  assign vm_store_cause = vm_context.mmu_en && exu_l1d.trap ? XLEN'(exu_l1d.cause)
      : XLEN'(`RAPT_CAUSE_STORE_ACC_FAULT);

  always_ff @(posedge clock) begin
    if (reset) vm_context_version <= '0;
    else if (cmu_bcast.mem_context_invalidate) vm_context_version <= vm_context_version + 1'b1;
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      vm_state <= VM_IDLE;
      vm_context <= '0;
      vm_fault <= 1'b0;
      vm_nonidempotent <= 1'b0;
      vm_cause <= '0;
      vm_tval <= '0;
      vm_rdata <= '0;
      vm_paddr <= '0;
      vm_pbmt <= '0;
      vm_high_word <= 1'b0;
      vm_byte <= '0;
      vm_preflight <= 1'b0;
    end else begin
      case (vm_state)
        VM_IDLE:
        if (vector_mem_valid && vector_mem_ready) begin
          vm_context <= {
            csr_bcast.dmmu_en,
            (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv) ? csr_bcast.mpp : csr_bcast.priv,
            csr_bcast.sum, csr_bcast.mxr, csr_bcast.menvcfg_pbmte,
            csr_bcast.satp_asid, vm_context_version
          };
          vm_fault <= 1'b0;
          vm_high_word <= 1'b0;
          vm_byte <= '0;
          vm_preflight <= vm_unaligned;
          vm_cause <= vector_mem_write ? XLEN'(`RAPT_CAUSE_STORE_ACC_FAULT)
              : XLEN'(`RAPT_CAUSE_LOAD_ACC_FAULT);
          vm_tval <= vm_addr;
          vm_nonidempotent <= 1'b0;
          vm_rdata <= '0;
          vm_state <= VM_CHECK;
        end
        VM_CHECK: begin
          if (!vm_write) vm_state <= vm_wide_split || vm_unaligned ? VM_LOAD_CHECK : VM_LOAD;
          else if (vm_context.mmu_en) vm_state <= VM_TRANSLATE;
        end
        VM_TRANSLATE: ;  // The bare and translated store checks share the completion path below.
        VM_LOAD_CHECK:
        if (lsu_l1d.rready) begin
          vm_nonidempotent <= lsu_l1d.rnonidempotent;
          if (lsu_l1d.trap || (lsu_l1d.rnonidempotent && (vm_unaligned || !vm_probe))) begin
            vm_fault <= 1'b1;
            vm_cause <= lsu_l1d.trap ? lsu_l1d.cause : XLEN'(`RAPT_CAUSE_LOAD_ACC_FAULT);
            vm_tval <= vm_access_addr;
            vm_state <= VM_RESPONSE;
          end else if (vm_unaligned && !vm_last_byte) vm_byte <= vm_byte + 1'b1;
          else begin
            vm_byte <= '0;
            vm_state <= vm_probe ? VM_RESPONSE : VM_LOAD;
          end
        end
        VM_LOAD:
        if (lsu_l1d.rready) begin
          vm_fault <= lsu_l1d.trap;
          vm_cause <= lsu_l1d.cause;
          vm_nonidempotent <= lsu_l1d.rnonidempotent;
          if (lsu_l1d.trap) begin
            vm_tval <= vm_beat_addr;
            vm_state <= VM_RESPONSE;
          end else if (vm_unaligned) begin
            vm_rdata[8*vm_byte+:8] <= vm_load_data[7:0];
            if (vm_last_byte) vm_state <= VM_RESPONSE;
            else vm_byte <= vm_byte + 1'b1;
          end else if (vm_wide_split && !vm_high_word) begin
            vm_rdata[31:0] <= 32'(lsu_l1d.rdata);
            vm_high_word <= 1'b1;
          end else begin
            if (vm_wide_split) vm_rdata[63:32] <= 32'(lsu_l1d.rdata);
            else vm_rdata <= vm_load_data;
            vm_state <= VM_RESPONSE;
          end
        end
        VM_STORE:
        if (lsu_l1d.wready) begin
          vm_fault <= lsu_l1d.werr;
          vm_cause <= XLEN'(`RAPT_CAUSE_STORE_ACC_FAULT);
          if (!lsu_l1d.werr && vm_wide_split && !vm_high_word) vm_high_word <= 1'b1;
          else if (!lsu_l1d.werr && vm_unaligned && !vm_last_byte) begin
            vm_byte <= vm_byte + 1'b1;
            vm_state <= VM_CHECK;
          end
          else begin
            if (lsu_l1d.werr) vm_tval <= vm_beat_addr;
            vm_state <= VM_RESPONSE;
          end
        end
        VM_RESPONSE: if (vector_mem_rsp_ready) vm_state <= VM_IDLE;
        default: vm_state <= VM_IDLE;
      endcase
      if (vm_store_checked) begin
        vm_paddr <= vm_checked_pa;
        vm_pbmt <= vm_checked_pbmt;
        vm_nonidempotent <= vm_store_device;
        if (vm_store_failed || vm_store_split_device) begin
          vm_fault <= 1'b1;
          vm_cause <= vm_store_cause;
          vm_tval <= vm_access_addr + XLEN'(vm_context.mmu_en || !vm_bare_fault
              ? 4'd0 : vm_bare_fault_offset);
          vm_state <= VM_RESPONSE;
        end else if (vm_preflight) begin
          // Check each byte's translation and protection before the first
          // write. Resolve pieces again through the normal TLB when writing.
          vm_byte <= vm_last_byte ? '0 : vm_byte + 1'b1;
          vm_preflight <= !vm_last_byte;
          vm_state <= vm_last_byte && vm_probe ? VM_RESPONSE : VM_CHECK;
        end else vm_state <= vm_probe ? VM_RESPONSE : VM_STORE;
      end
    end
  end

  assign lsu_l1d.raddr = vm_active ? vm_beat_addr : scalar_l1d.raddr;
  assign lsu_l1d.rcontext = vm_active ? vm_context : scalar_l1d.rcontext;
  assign lsu_l1d.ralu = vm_active ? (vm_wide_split ? `RAPT_ALU_LW__ : vm_load_alu) : scalar_l1d.ralu;
  assign lsu_l1d.rvalid = vm_active ? (vm_state == VM_LOAD_CHECK || vm_state == VM_LOAD) : scalar_l1d.rvalid;
  assign lsu_l1d.rprobe = vm_active ? (vm_probe || vm_state == VM_LOAD_CHECK) : scalar_l1d.rprobe;
  assign lsu_l1d.rmisaligned = vm_active ? vm_unaligned : scalar_l1d.rmisaligned;
  assign lsu_l1d.rcheck_valid = vm_active ? vm_wide_split : scalar_l1d.rcheck_valid;
  assign lsu_l1d.rcheck_offset = vm_active ? '0 : scalar_l1d.rcheck_offset;
  assign lsu_l1d.rcheck_size_m1 = vm_active
      ? (vm_state == VM_LOAD_CHECK ? 4'd7 : 4'd3) : scalar_l1d.rcheck_size_m1;
  assign lsu_l1d.rorig_size_m1 = vm_active ? vm_size_m1 : scalar_l1d.rorig_size_m1;
  assign lsu_l1d.atomic_lock = vm_active ? 1'b0 : scalar_l1d.atomic_lock;
  assign lsu_l1d.ordered = vm_active ? 1'b1 : scalar_l1d.ordered;
  assign lsu_l1d.replay_allowed = vm_active ? 1'b0 : scalar_l1d.replay_allowed;
  assign lsu_l1d.raddr_b = scalar_l1d.raddr_b;
  assign lsu_l1d.rcontext_b = scalar_l1d.rcontext_b;
  assign lsu_l1d.ralu_b = scalar_l1d.ralu_b;
  assign lsu_l1d.rvalid_b = !vm_active && scalar_l1d.rvalid_b;
  assign lsu_l1d.waddr = vm_active ? vm_paddr + XLEN'(vm_wide_split && vm_high_word ? 4 : 0) : scalar_l1d.waddr;
  assign lsu_l1d.wpbmt = vm_active ? vm_pbmt : scalar_l1d.wpbmt;
  assign lsu_l1d.walu = vm_active ? (vm_wide_split ? 8'h0f : vm_strobe) : scalar_l1d.walu;
  assign lsu_l1d.wzero = vm_active ? 1'b0 : scalar_l1d.wzero;
  assign lsu_l1d.wvalid = vm_active ? vm_state == VM_STORE : scalar_l1d.wvalid;
  assign lsu_l1d.wdata = vm_active ? XLEN'(vm_store_data) : scalar_l1d.wdata;
  assign lsu_l1d.wmore = vm_active ? 1'b0 : scalar_l1d.wmore;
  assign lsu_l1d.wprecise = vm_active ? 1'b1 : scalar_l1d.wprecise;

  assign scalar_l1d.idle = !vm_active && lsu_l1d.idle;
  assign scalar_l1d.rdata = lsu_l1d.rdata;
  assign scalar_l1d.trap = !vm_active && lsu_l1d.trap;
  assign scalar_l1d.cause = lsu_l1d.cause;
  assign scalar_l1d.difftest_skip = lsu_l1d.difftest_skip;
  assign scalar_l1d.rready = !vm_active && lsu_l1d.rready;
  assign scalar_l1d.rretry = !vm_active && lsu_l1d.rretry;
  assign scalar_l1d.rmiss = !vm_active && lsu_l1d.rmiss;
  assign scalar_l1d.miss_wake = lsu_l1d.miss_wake;
  assign scalar_l1d.rdata_b = lsu_l1d.rdata_b;
  assign scalar_l1d.rready_b = !vm_active && lsu_l1d.rready_b;
  assign scalar_l1d.rretry_b = !vm_active && lsu_l1d.rretry_b;
  assign scalar_l1d.wready = !vm_active && lsu_l1d.wready;
  assign scalar_l1d.werr = !vm_active && lsu_l1d.werr;
  assign scalar_l1d.rnonidempotent = lsu_l1d.rnonidempotent;

  assign exu_l1d.mmu_en = vm_active ? vm_state == VM_TRANSLATE : scalar_mmu.mmu_en;
  assign exu_l1d.mem_context = vm_active ? vm_context : scalar_mmu.mem_context;
  assign exu_l1d.vaddr = vm_active ? vm_access_addr : scalar_mmu.vaddr;
  assign exu_l1d.walu = vm_active ? vm_store_alu : scalar_mmu.walu;
  assign exu_l1d.cmo_mgmt = vm_active ? 1'b0 : scalar_mmu.cmo_mgmt;
  assign exu_l1d.valid = vm_active ? vm_state == VM_TRANSLATE : scalar_mmu.valid;
  assign exu_l1d.misaligned = vm_active ? vm_unaligned : scalar_mmu.misaligned;
  assign exu_l1d.reservation_clear = !vm_active && scalar_mmu.reservation_clear;
  assign scalar_mmu.paddr = exu_l1d.paddr;
  assign scalar_mmu.pbmt = exu_l1d.pbmt;
  assign scalar_mmu.trap = !vm_active && exu_l1d.trap;
  assign scalar_mmu.cause = exu_l1d.cause;
  assign scalar_mmu.reservation = exu_l1d.reservation;
  assign scalar_mmu.reservation_valid = exu_l1d.reservation_valid;
  assign scalar_mmu.reservation_size_m1 = exu_l1d.reservation_size_m1;
  assign scalar_mmu.reservation_blocked = exu_l1d.reservation_blocked;
  assign scalar_mmu.ready = !vm_active && exu_l1d.ready;

  `RAPT_SVA_IMPLY(
      clock, reset, VECTOR_MEMORY_EXCLUSIVE, vm_active,
      !scalar_l1d.rvalid && !scalar_l1d.rvalid_b && !scalar_l1d.wvalid && !scalar_mmu.valid)
  `RAPT_SVA_IMPLY(clock, reset, VECTOR_MEMORY_RESPONSE_MATCH, vector_mem_rsp_valid,
                  !vector_mem_response_dropped)

  `RAPT_SVA_IMPLY(clock, reset, VECTOR_SCALAR_DEST,
                  vector_response_valid && !vector_trap && !vector_fp_write,
                  vector_rd == vector_response_metadata.rd)
  `RAPT_SVA_IMPLY(clock, reset, VECTOR_NO_AUTHORIZED_KILL, 1'b1, !vector_kill_blocked)
`endif
  rapt_pkg::completion_t wb_fpu;
  rapt_pkg::completion_t wb_branch;
  rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t exu_wb_mul;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t completion_accepted[rapt_pkg::CompletionPorts];
  if (!rapt_pkg::PmaRegionsValid) begin : g_invalid_pma_regions
    $error("Invalid PMA regions: bounds, alignment, overlap or mapped attributes");
  end
  // Guards are independent per producer; candidate order carries no priority.
  // Validate each physical producer before publishing data or ROB control.
  rapt_pkg::completion_t completion_candidate[rapt_pkg::CompletionPorts];
  logic completion_candidate_identity_match[rapt_pkg::CompletionPorts];
  logic completion_candidate_payload_match[rapt_pkg::CompletionPorts];
  rob_completion_owner_if completion_owner ();
  for (genvar p = 0; p < IntegerIssuePorts; p++) begin : g_integer_candidate
    assign completion_candidate[p] = wb_integer_raw[p];
  end
  assign completion_candidate[FpuPort] = wb_fpu;
  assign completion_candidate[BranchPort] = wb_branch;
  assign completion_candidate[MemoryPort] = exu_ioq_bcast;
  assign completion_candidate[MulPort] = exu_wb_mul;
  // Each producer has an independent expression so a branch-queue wake
  // cannot acquire a dependency on the branch packet it is producing.
  function automatic rapt_pkg::completion_t accepted_completion(input rapt_pkg::completion_t packet,
                                                                input logic accepted);
    rapt_pkg::completion_t result;
    result = packet;
    result.valid = packet.valid && accepted;
    return result;
  endfunction

  for (
      genvar integer_port = 0; integer_port < IntegerIssuePorts; integer_port++
  ) begin : g_integer_accept
    assign completion_accepted[integer_port] = accepted_completion(
        wb_integer_raw[integer_port], g_completion_guard[integer_port].accepted
    );
  end
  assign completion_accepted[BranchPort] = accepted_completion(
      wb_branch, g_completion_guard[BranchPort].accepted
  );
  assign completion_accepted[MemoryPort] = accepted_completion(
      exu_ioq_bcast, g_completion_guard[MemoryPort].accepted
  );
  assign completion_accepted[MulPort] = accepted_completion(
      exu_wb_mul, g_completion_guard[MulPort].accepted
  );
  assign completion_accepted[FpuPort] = accepted_completion(
      wb_fpu, g_completion_guard[FpuPort].accepted
  );

  // Dedicated external wake view: no branch producer is on this input.
  rapt_pkg::completion_t branch_wake [rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t memory_wake;
  // Keep the memory-only wake writer independent of the other CDB slots.
  // Match the main operand bus even at the dedicated IEU wake inputs.
  if (RegisteredOperandWakePorts[MemoryPort]) begin : g_registered_memory_wake
    assign memory_wake = completion[MemoryPort];
  end else begin : g_live_memory_wake
    always_comb begin
      memory_wake = exu_ioq_bcast;
      memory_wake.valid = exu_ioq_bcast.valid && g_completion_guard[MemoryPort].accepted;
    end
  end
  for (genvar p = 0; p < IntegerIssuePorts; p++) begin : g_branch_wake
    if (RegisteredOperandWakePorts[p]) begin : g_registered
      assign branch_wake[p] = completion[p];
    end else begin : g_live
      always_comb begin
        branch_wake[p] = wb_integer_raw[p];
        branch_wake[p].valid = wb_integer_raw[p].valid && g_completion_guard[p].accepted;
      end
    end
  end
  assign branch_wake[BranchPort] = '0;
  assign branch_wake[MemoryPort] = memory_wake;
  assign branch_wake[MulPort] = '0;
  assign branch_wake[FpuPort] = RegisteredOperandWakePorts[FpuPort]
      ? completion[FpuPort] : completion_accepted[FpuPort];

  // Register every accepted completion before ROB recovery and retirement.
  // Selected operand ports reuse this boundary; other producer ports retain
  // their accepted same-cycle wake latency.
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_completion_stage
    if (p == BranchPort) begin : g_branch
      rapt_pkg::branch_completion_t accepted, registered;
      assign accepted = rapt_pkg::pack_branch_completion(completion_accepted[p]);
      assign completion[p] = rapt_pkg::expand_branch_completion(registered);
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::branch_completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(accepted),
          .completion(registered)
      );
    end else if (p == MemoryPort) begin : g_lsu
      rapt_pkg::lsu_completion_t accepted, registered;
      assign accepted = rapt_pkg::pack_lsu_completion(completion_accepted[p]);
      assign completion[p] = rapt_pkg::expand_lsu_completion(registered);
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::lsu_completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(accepted),
          .completion(registered)
      );
    end else if (p == MulPort) begin : g_mdu
      rapt_pkg::mdu_completion_t accepted, registered;
      assign accepted = rapt_pkg::pack_mdu_completion(completion_accepted[p]);
      assign completion[p] = rapt_pkg::expand_mdu_completion(registered);
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::mdu_completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(accepted),
          .completion(registered)
      );
    end else if (p == FpuPort) begin : g_fpu
      rapt_pkg::fpu_completion_t accepted, registered;
      assign accepted = rapt_pkg::pack_fpu_completion(completion_accepted[p]);
      assign completion[p] = rapt_pkg::expand_fpu_completion(registered);
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::fpu_completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(accepted),
          .completion(registered)
      );
    end else if (p == IntegerSystemPort) begin : g_system
`ifdef RAPT_V_EXTENSION
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(completion_accepted[p]),
          .completion(completion[p])
      );
`else
      rapt_pkg::system_completion_t accepted, registered;
      assign accepted = rapt_pkg::pack_system_completion(completion_accepted[p]);
      assign completion[p] = rapt_pkg::expand_system_completion(registered);
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::system_completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(accepted),
          .completion(registered)
      );
`endif
    end else begin : g_alu
      rapt_pkg::alu_completion_t accepted, registered;
      assign accepted = rapt_pkg::pack_alu_completion(completion_accepted[p]);
      assign completion[p] = rapt_pkg::expand_alu_completion(registered);
      rapt_completion_stage #(
          .CompletionT(rapt_pkg::alu_completion_t)
      ) stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(accepted),
          .completion(registered)
      );
    end
  end
  // The global wake edge is shared by operand storage and queue allocations.
  // Optional local capture only wakes residents; the registered copy covers
  // owner transfer when an allocation coincides with an early local result.
  rapt_pkg::completion_t operand_wake[rapt_pkg::CompletionPorts];
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_operand_wake
    assign operand_wake[p] = RegisteredOperandWakePorts[p] ? completion[p] : completion_accepted[p];
  end
  if (!(IntegerIssuePorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_core configuration");
  end
  if (!(IntegerSystemPort < IntegerIssuePorts)) begin : g_invalid_config_1
    $error("Invalid rapt_core configuration");
  end
  if (!(rapt_pkg::CompletionPorts == IntegerIssuePorts + rapt_pkg::CompletionFixedPorts)) begin : g_invalid_config_2
    $error("Invalid rapt_core configuration");
  end
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_completion_guard
    logic accepted, guard_accept;
    // The IOQ only loses owners to a precise flush, which also kills its
    // completion. Each owner completes once. The memory port therefore keeps
    // the ROB owner lookup off the load-to-wake path and checks the same
    // identity contract in verification.
    if (p == MemoryPort) begin : g_trusted
      assign accepted = completion_candidate[p].valid;
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, MEMORY_COMPLETION_OWNER_LIVE,
                      completion_candidate[p].valid, guard_accept)
    end else begin : g_guarded
      assign accepted = guard_accept;
    end
    rapt_completion_guard #(
        .Entries(rapt_pkg::CoreConfig.rob_entries),
        .IndexBits(rapt_pkg::ROBIndexBits),
        .GenerationBits(rapt_pkg::CoreConfig.rob_generation_bits),
        .PhysBits(rapt_pkg::PLENPkg),
        .ArchBits(rapt_pkg::RLENPkg),
        .EnforcePayload(1'b0)
    ) guard (
        .candidate_valid(completion_candidate[p].valid),
        .candidate_index(completion_candidate[p].dest),
        .candidate_generation(completion_candidate[p].generation),
        .candidate_prd(completion_candidate[p].prd),
        .candidate_rd(completion_candidate[p].rd),
        .live(completion_owner.live),
        .executing(completion_owner.executing),
        .owner_generation(completion_owner.generation),
        .owner_prd(completion_owner.prd),
        .owner_rd(completion_owner.rd),
        .accept(guard_accept),
        .identity_match(completion_candidate_identity_match[p]),
        .payload_match(completion_candidate_payload_match[p])
    );
    // prd/rd are immutable typed-packet payload, not a second allocation
    // identity. Keep their end-to-end check in verification without placing
    // two wide owner-table muxes on every production completion endpoint.
    `RAPT_SVA_IMPLY(clock, reset, COMPLETION_PAYLOAD_CONSISTENT,
                    completion_candidate[p].valid && completion_candidate_identity_match[p],
                    completion_candidate_payload_match[p])
  end

  // Operand reads happen on the dispatch lanes, after ROB/spill residency.
  exu_prf_if #(.Width(rapt_pkg::DispatchWidth)) exu_prf ();
  exu_csr_if exu_csr ();

`ifndef SYNTHESIS
`ifdef VERILATOR
  typedef enum logic [1:0] {
    P_EMPTY,
    P_VALID,
    P_STALL,
    P_SQUASH
  } pipe_state_e;
  pipe_state_e pipe_decode_state  [  rapt_pkg::DecodeWidth];
  pipe_state_e pipe_rename_state  [  rapt_pkg::RenameWidth];
  pipe_state_e pipe_dispatch_state[rapt_pkg::DispatchWidth];
  pipe_state_e pipe_commit_state  [  rapt_pkg::CommitWidth];
  logic [rapt_pkg::CompletionPorts-1:0] pipe_cdb_valid_mask, pipe_result_wb_valid_mask;
  logic [$clog2(rapt_pkg::CompletionPorts+1)-1:0] pipe_cdb_valid_count;
  logic pipe_cdb_multi_valid, pipe_result_wb_multi_valid;
  for (genvar s = 0; s < rapt_pkg::DecodeWidth; s++) begin : g_pipe_decode_state
    assign pipe_decode_state[s] = cmu_bcast.flush_pipe ? P_SQUASH : !idu_rnu.valid[s] ? P_EMPTY
        : idu_rnu.ready[s] ? P_VALID : P_STALL;
  end
  for (genvar s = 0; s < rapt_pkg::RenameWidth; s++) begin : g_pipe_rename_state
    assign pipe_rename_state[s] = cmu_bcast.flush_pipe ? P_SQUASH : !rnu_rou.valid[s] ? P_EMPTY
        : rnu_rou.ready[s] ? P_VALID : P_STALL;
  end
  for (genvar s = 0; s < rapt_pkg::DispatchWidth; s++) begin : g_pipe_dispatch_state
    assign pipe_dispatch_state[s] = cmu_bcast.flush_pipe ? P_SQUASH : !dispatch_valid[s] ? P_EMPTY
        : P_VALID;
  end
  for (genvar s = 0; s < rapt_pkg::CommitWidth; s++) begin : g_pipe_commit_state
    assign pipe_commit_state[s] = rou_cmu.slot[s].valid ? P_VALID : P_EMPTY;
  end
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_pipe_cdb_state
    assign pipe_cdb_valid_mask[p] = completion[p].valid;
    assign pipe_result_wb_valid_mask[p] = completion[p].valid && completion[p].rd != 0;
  end
  assign pipe_cdb_valid_count = $clog2(
      rapt_pkg::CompletionPorts + 1
  )'($countones(
      pipe_cdb_valid_mask
  ));
  assign pipe_cdb_multi_valid = $countones(pipe_cdb_valid_mask) > 1;
  assign pipe_result_wb_multi_valid = $countones(pipe_result_wb_valid_mask) > 1;
`endif
`endif

  logic clint_timer_trap;
  logic clint_sw_trap;
  logic clint_ext_trap;
  logic s_int_pending;
  logic [`RAPT_XLEN-1:0] s_int_cause;

  // Per-hart interrupt gating. The cluster CLINT supplies raw
  // timer/software interrupt levels; AND them with the per-hart CSR
  // enables (mie / mstatus) before they reach the trap-decision logic in
  // ROU. The external (PLIC) line is gated identically.
  assign clint_timer_trap = clint_timer_int_i && csr_bcast.timer_int_en;
  assign clint_sw_trap    = clint_sw_int_i && csr_bcast.sw_int_en;
  assign clint_ext_trap   = io_interrupt && csr_bcast.ext_int_en;

  // RNU (Re-naming Unit): pure rename: RNQ + freelist + maptable
  logic [`RAPT_PHY_LEN-1:0] rnu_map_snapshot[`RAPT_REG_SIZE];
  logic [`RAPT_PHY_LEN-1:0] rnu_rat_snapshot[`RAPT_REG_SIZE];

  rapt_rnu rnu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .idu_rnu(idu_rnu),
      .rnu_rou(rnu_rou),
      .recovery(recovery),
      .checkpoint_release(checkpoint_release),
      .snapshot_ghr(snapshot_ghr),
      .snapshot_phr(snapshot_phr),
      .history_restore(history_restore),
      .restore_ghr(restore_ghr),
      .restore_phr(restore_phr),

      .map_snapshot(rnu_map_snapshot),
      .rat_snapshot(rnu_rat_snapshot),

      .reset(reset)
  );

  // ROU (Re-Order Unit)
  // The ROU owns the merged registered skid and allocation handshake.
  for (genvar s = 0; s < rapt_pkg::RenameWidth; s++) begin : g_rename_allocation
    assign rnu_operand.slot[s] = rnu_rou.slot[s];
    assign rnu_operand.valid[s] = rnu_rou.valid[s];
    assign rnu_operand.checkpoint_valid[s] = rnu_rou.checkpoint_valid[s];
    assign rnu_operand.checkpoint[s] = rnu_rou.checkpoint[s];
    assign rnu_rou.ready[s] = rnu_operand.ready[s];
  end
  assign rnu_operand.empty = rnu_rou.empty;

  logic drain_completion;
  if (RegisteredDrainCompletion) begin : g_registered_drain
    // The integrated memory drain already registers the complete ordering point.
    assign drain_completion = writeback_done;
  end else begin : g_live_drain
    // Standalone clients may provide live cache status. Capture that status and
    // SQ quiescence together, and discard it when its serialized owner leaves.
    always_ff @(posedge clock) begin
      drain_completion <= writeback_drain && writeback_done && rou_lsu.sq_empty;
      if (reset || cmu_bcast.flush_pipe) drain_completion <= 1'b0;
    end
  end

  localparam int OperandOwnerBits = rapt_pkg::index_bits(rapt_pkg::CoreConfig.rob_entries);
  localparam int OperandGenerationBits = rapt_pkg::CoreConfig.rob_generation_bits;
  localparam int IOQIntegerReadPorts = 1;
  logic [rapt_pkg::PLENPkg-1:0] ioq_operand_address[IOQIntegerReadPorts];
  logic [XLEN-1:0] ioq_operand_value[IOQIntegerReadPorts];
  logic ioq_operand_valid[IOQIntegerReadPorts];
  logic [rapt_pkg::PLENPkg-1:0] extra_operand_address[3+IOQIntegerReadPorts];
  logic [XLEN-1:0] extra_operand_value[3+IOQIntegerReadPorts];
  logic extra_operand_valid[3+IOQIntegerReadPorts];
  logic [rapt_pkg::PLENPkg-1:0] int_operand_address[3];
  logic [XLEN-1:0] int_operand_value[3];
  logic int_operand_valid[3];
  logic [1:0][rapt_pkg::PLENPkg-1:0] int_source_regs[rapt_pkg::DispatchWidth];
  rapt_pkg::uop_t fp_queue_read_uop;
  logic [2:0][OperandOwnerBits:0] fp_queue_read_tag, fp_queue_read_ready_tag;
  logic [2:0][63:0] fp_queue_read_value;
`ifdef RAPT_V_EXTENSION
  logic vector_fp_read;
  rapt_pkg::uop_t vector_fp_read_uop, rou_fp_queue_read_uop;
  logic [2:0][OperandOwnerBits:0] rou_fp_queue_read_tag;
  assign vector_fp_read = vector_issue.valid && vector_issue.uop.imm[6:0] == 7'h57
      && vector_issue.uop.imm[14:12] == 3'b101;
  always_comb begin
    vector_fp_read_uop = '0;
    vector_fp_read_uop.execute.fp.valid = 1'b1;
    vector_fp_read_uop.execute.fp.op = `RAPT_FP_OP_FADD_S;
    vector_fp_read_uop.execute.fp.rs1 = vector_issue.uop.imm[19:15];
  end
  assign rou_fp_queue_read_uop = vector_fp_read ? vector_fp_read_uop : fp_queue_read_uop;
  assign rou_fp_queue_read_tag = vector_fp_read ? '0 : fp_queue_read_tag;
  assign vector_fp_scalar = fp_queue_read_value[0];
`endif
  logic [2:0][OperandGenerationBits-1:0] fp_queue_read_generation;
  logic [2:0][OperandOwnerBits:0] fp_dispatch_tag[rapt_pkg::DispatchWidth];
  logic [2:0][OperandGenerationBits-1:0] fp_dispatch_generation[rapt_pkg::DispatchWidth];
  logic fp_retire_valid[rapt_pkg::CommitWidth];
  logic [63:0] fp_retire_value[rapt_pkg::CommitWidth];
  logic [OperandOwnerBits-1:0] fp_retire_owner[rapt_pkg::CommitWidth];
  logic [OperandGenerationBits-1:0] fp_retire_generation[rapt_pkg::CommitWidth];
  for (genvar s = 0; s < rapt_pkg::DispatchWidth; s++) begin : g_operand_int_dispatch
    assign int_source_regs[s] = {exu_prf.pr2[s], exu_prf.pr1[s]};
  end
  rapt_rou #(
      // Vector scalar moves use the system completion port in this experiment.
`ifdef RAPT_V_EXTENSION
      .FpWritePorts((32'(1) << MemoryPort) | (32'(1) << FpuPort)
                    | (32'(1) << IntegerSystemPort)),
`else
      .FpWritePorts((32'(1) << MemoryPort) | (32'(1) << FpuPort)),
`endif
      .SeparateOperandWake(1'b1),
      .RegisteredDrainCompletion(1'b1),
      .CompactFpOperands(CompactFpOperands),
      .RegisteredDispatchPayload(RegisteredDispatchPayload),
      .DerivedConstants(DerivedConstants)
  ) rou (
`ifdef RAPT_V_EXTENSION
      .fp_queue_read_uop(rou_fp_queue_read_uop),
      .fp_queue_read_tag(rou_fp_queue_read_tag),
`else
      .fp_queue_read_uop(fp_queue_read_uop),
      .fp_queue_read_tag(fp_queue_read_tag),
`endif
      .operand_read_value(fp_queue_read_value),
      .fp_queue_ready_tag(fp_queue_read_ready_tag),
      .fp_queue_read_generation(fp_queue_read_generation),
      .fp_queue_dispatch_tag(fp_dispatch_tag),
      .fp_queue_dispatch_generation(fp_dispatch_generation),
      .fp_retire_valid,
      .fp_retire_value,
      .fp_retire_owner,
      .fp_retire_generation,
      .operand_wake(operand_wake),
      .writeback_done(drain_completion),
`ifdef RAPT_V_EXTENSION
      .writeback_drain(rou_writeback_drain),
`else
      .writeback_drain(writeback_drain),
`endif
      .writeback_clean(writeback_clean),
      .writeback_cbo(writeback_cbo),
      .writeback_cbo_invalidate(writeback_cbo_invalidate),
      .writeback_block(writeback_block),
      .completion(completion),
      .completion_owner(completion_owner),
      .clock(clock),

      .rnu_rou(rnu_operand),
      .rename_buffer_empty_o(rou_rename_empty),
      .recovery(recovery),
      .checkpoint_release(checkpoint_release),

      // issue
      .exu_prf(exu_prf),
      .dispatch(dispatch),
      .candidate_domain(dispatch_candidate_domain),
      .candidate_valid(dispatch_candidate_valid),
      .candidate_ready(dispatch_candidate_ready),
      .selected_valid(dispatch_valid),
      .selected_candidate(dispatch_selected_candidate),

      .csr_bcast(csr_bcast),
      .clint_timer_trap(clint_timer_trap),
      .clint_sw_trap(clint_sw_trap),
      .clint_ext_trap(clint_ext_trap),
      .s_int_pending(s_int_pending),
      .s_int_cause(s_int_cause),

      .rou_cmu(rou_cmu),
      .rou_csr(rou_csr),
      .rou_lsu(rou_lsu),

      .dm_haltreq_i (dm_haltreq_i),
      .debug        (debug),
      .halted_o     (halted_o),
      .halt_pc_o    (halt_pc_o),
      .commit_fire_o(commit_fire_o),

      .pmu_rob_full(pmu_rob_full_unused),

      .reset(reset)
  );

  // PRF (Physical Register File): top-level shared resource
  // Debug: architectural register view (committed + speculative)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] rf    [`RAPT_REG_SIZE]  /* verilator public_flat_rd */;
  logic [XLEN-1:0] rf_map[`RAPT_REG_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef RAPT_RVFI
  logic [XLEN-1:0] rvfi_rd_data[rapt_pkg::CommitWidth];
`endif

  for (genvar r = 0; r < 3; r++) begin : g_existing_integer_read
    assign extra_operand_address[r] = int_operand_address[r];
    assign int_operand_value[r] = extra_operand_value[r];
    assign int_operand_valid[r] = extra_operand_valid[r];
  end
  for (genvar r = 0; r < IOQIntegerReadPorts; r++) begin : g_ioq_integer_read
    assign extra_operand_address[3+r] = ioq_operand_address[r];
    assign ioq_operand_value[r] = extra_operand_value[3+r];
    assign ioq_operand_valid[r] = extra_operand_valid[3+r];
  end
  rapt_prf #(
      .ExtraReadPorts(3 + IOQIntegerReadPorts)
  ) prf (
      .extra_address(extra_operand_address),
      .extra_value(extra_operand_value),
      .extra_valid(extra_operand_valid),
      .completion(operand_wake),
      .clock(clock),
      .reset(reset),

      .prf_rd(exu_prf),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .map_snapshot(rnu_map_snapshot),
      .rat_snapshot(rnu_rat_snapshot),

      .rf    (rf),
      .rf_map(rf_map),

      .dbg_we_i   (dbg_gpr_we_i),
      .dbg_addr_i (dbg_gpr_addr_i),
      .dbg_wdata_i(dbg_gpr_wdata_i),
      .dbg_rdata_o(dbg_gpr_rdata_o)

`ifdef RAPT_RVFI,
      .rvfi_rd_data(rvfi_rd_data)
`endif
  );

  rapt_pkg::dispatch_capacity_t dispatch_capacity[rapt_pkg::ExecutionDomains];
  rapt_pkg::dispatch_grant_t dispatch_grant[rapt_pkg::ExecutionDomains];
  rapt_dpu #(
      .NumCandidates(rapt_pkg::SteerScanEntries)
  ) dpu (
      .clock(clock),
      .reset(reset),
      .candidate_domain(dispatch_candidate_domain),
      .candidate_valid(dispatch_candidate_valid),
      .candidate_ready(dispatch_candidate_ready),
      .selected_valid(dispatch_valid),
      .selected_candidate(dispatch_selected_candidate),
      .capacity(dispatch_capacity),
      .grant(dispatch_grant)
  );

  rapt_dispatch_iq_adapter dispatch_alq (
      .queue(disp_alq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_INTEGER]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_INTEGER])
  );
  rapt_dispatch_iq_adapter dispatch_brq (
      .queue(disp_brq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_BRANCH]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_BRANCH])
  );
  rapt_dispatch_iq_adapter dispatch_mdq (
      .queue(disp_mdq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_MULDIV]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_MULDIV])
  );
  rapt_dispatch_iq_adapter dispatch_fpq (
      .queue(disp_fpq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_FLOAT]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_FLOAT])
  );
  rapt_dispatch_ioq_adapter dispatch_ioq (
      .queue(disp_ioq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_MEMORY]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_MEMORY])
  );

  // Only ALQ/BRQ resident data registers receive these local integer/load/
  // branch-link/MUL copies. ROU, PRF, MUL/DIV, FP and memory consumers keep
  // the global edge. Local capture cannot feed same-cycle selection or
  // dispatch readiness, so a BRQ may capture its own registered link result.
  rapt_pkg::completion_t local_integer_wake[rapt_pkg::CompletionPorts];
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_local_integer_wake
    localparam bit RegisteredLinkOrMul = RegisteredOperandWakePorts[p]
        && (p == BranchPort || p == MulPort);
    localparam bit LocalPort = p < IntegerIssuePorts
        || (LocalMemoryWake && p == MemoryPort) || RegisteredLinkOrMul;
    if (LocalIntegerWake && LocalPort) begin : g_live
      assign local_integer_wake[p] = completion_accepted[p];
    end else begin : g_none
      assign local_integer_wake[p] = '0;
    end
  end
  // FPQ residents capture the live FP result; integer, memory and spill
  // consumers see it on the registered edge, off the FP arbiter path.
  rapt_pkg::completion_t local_fp_wake[rapt_pkg::CompletionPorts];
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_local_fp_wake
    if (LocalFpWake && RegisteredOperandWakePorts[p] && p == FpuPort) begin : g_live
      assign local_fp_wake[p] = completion_accepted[p];
    end else begin : g_none
      assign local_fp_wake[p] = '0;
    end
  end
  rapt_ieu #(
      .LocalIntegerWake(LocalIntegerWake)
  ) ieu (
      .early_completion(completion_accepted),
      .int_source_regs,
      .operand_read_address(int_operand_address[0:1]),
      .operand_read_value(int_operand_value[0:1]),
      .operand_read_valid(int_operand_valid[0:1]),
      .local_integer_wake(local_integer_wake),
      .branch_wake(branch_wake),
      .memory_wake(memory_wake),
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .completion(operand_wake),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .dispatch(dispatch),
      .disp_alq(disp_alq),
      .disp_brq(disp_brq),
      .disp_mdq(disp_mdq),

      .integer_system_issue_enable(1'b1),
`ifdef RAPT_ZAWRS
      .reservation_valid(exu_l1d.reservation_valid),
      .wrs_debug_wakeup(dm_haltreq_i || debug.step),
`endif
`ifdef RAPT_V_EXTENSION
      .vector_issue_ready(vector_command_ready),
      .vector_issue(vector_issue),
      .exu_csr(exu_csr),
      .wb_integer_raw(wb_integer_ieu),
`else
      .exu_csr(exu_csr),
      .wb_integer_raw(wb_integer_raw),
`endif
      .wb_branch(wb_branch),
      .exu_wb_mul(exu_wb_mul),
      .pmu_ooo_valid(pmu_ooo_valid_unused),
      .pmu_ooo_valid_found(pmu_ooo_valid_found_unused),
      .pmu_ooo_full(pmu_ooo_full_unused)
  );

  logic fp_issue_enable_unused;
  if (rapt_pkg::FpuEnable) begin : g_feu
    rapt_feu #(
        .LocalFpWake(LocalFpWake)
    ) feu (
        .early_completion(completion_accepted),
        .int_source_regs,
        .fp_dispatch_tag,
        .fp_dispatch_generation,
        .fp_retire_valid,
        .fp_retire_value,
        .fp_retire_owner,
        .fp_retire_generation,
        .fp_queue_read_uop(fp_queue_read_uop),
        .fp_queue_read_tag(fp_queue_read_tag),
        .operand_read_value(fp_queue_read_value),
        .fp_queue_ready_tag(fp_queue_read_ready_tag),
        .fp_queue_read_generation(fp_queue_read_generation),
        .int_operand_address(int_operand_address[2]),
        .int_operand_value(int_operand_value[2]),
        .int_operand_valid(int_operand_valid[2]),
        .local_fp_wake(local_fp_wake),
        .cancel_valid(recovery.redirect_valid),
        .cancel_head(recovery.head),
        .cancel_owner(recovery.owner),
        .completion(operand_wake),
        .clock(clock),
        .reset(reset),
        .cmu_bcast(cmu_bcast),
        .csr_bcast(csr_bcast),
        .dispatch(dispatch),
        .disp_fpq(disp_fpq),

        .wb_fpu(wb_fpu),
        .wb_accept(g_completion_guard[FpuPort].accepted),
        .completion_ready(1'b1),
        .issue_enable(fp_issue_enable_unused)
    );
  end else begin : g_no_feu
    // FP uops trap at decode and retire through the integer system pipe, so
    // the FP queue, its operand reads and the FPU completion port stay idle.
    assign fp_queue_read_uop = '0;
    assign fp_queue_read_tag = '0;
    assign int_operand_address[2] = '0;
    assign wb_fpu = '0;
    assign fp_issue_enable_unused = 1'b0;
    assign disp_fpq.free_found = '{default: 1'b0};
    assign disp_fpq.free_idx = '{default: '0};
  end

  // CMU (ComMit Unit)
  rapt_cmu cmu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

  rapt_csr csrs (
      .clock  (clock),
      .mtime_i(mtime_i),

      .hart_id_i(hart_id_i),

      .rou_csr(rou_csr),
      .exu_csr(exu_csr),

      .csr_bcast (csr_bcast),
      .pmp_update(pmp_update),

      .s_int_pending(s_int_pending),
      .s_int_cause  (s_int_cause),

      .timer_irq_i(clint_timer_int_i),
      .sw_irq_i   (clint_sw_int_i),
      .m_ext_irq_i(io_interrupt),
      .s_ext_irq_i(s_ext_irq_i),
`ifdef RAPT_V_EXTENSION
      .store_error_i(!vm_active && lsu_l1d.wvalid && lsu_l1d.werr),
`else
      .store_error_i(lsu_l1d.wvalid && lsu_l1d.werr),
`endif
      .store_error_addr_i(lsu_l1d.waddr),
      .store_error_strb_i(lsu_l1d.walu),
`ifdef RAPT_V_EXTENSION
      .vector_dirty_i(vector_response_valid && vector_dirty
                      && g_completion_guard[IntegerSystemPort].accepted),
      .vector_fp_dirty_i(vector_response_valid && vector_fp_dirty && !vector_trap
                         && g_completion_guard[IntegerSystemPort].accepted),
`endif

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  rapt_lsu #(
      .LateOperands(1'b1),
      .IntegerReadPorts(IOQIntegerReadPorts)
  ) lsu (
      .int_source_regs,
      .operand_read_address(ioq_operand_address),
      .operand_read_value(ioq_operand_value),
      .operand_read_valid(ioq_operand_valid),
      .completion(operand_wake),
      .local_fp_wake(local_fp_wake),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
`ifdef RAPT_V_EXTENSION
      .lsu_l1d(scalar_l1d),
      .exu_l1d(scalar_mmu),
`else
      .lsu_l1d(lsu_l1d),
      .exu_l1d(exu_l1d),
`endif
      .dispatch(dispatch),
      .disp_ioq(disp_ioq),

      .exu_ioq_bcast(exu_ioq_bcast),
      .wb_accept(g_completion_guard[MemoryPort].accepted),
      .rou_lsu(rou_lsu),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .pmu_sq_full(pmu_sq_full_unused)
  );

`ifdef RAPT_RVFI
  // RVFI (RISC-V Formal Interface) output generation
  rapt_rvfi rvfi_inst (
      .clock(clock),
      .reset(reset),

      .rou_cmu  (rou_cmu),
      .csr_bcast(csr_bcast),
      .rf       (rf),

      .rd_wdata(rvfi_rd_data),

      .rvfi_valid(rvfi_valid),
      .rvfi_order(rvfi_order),
      .rvfi_insn (rvfi_insn),
      .rvfi_trap (rvfi_trap),
      .rvfi_halt (rvfi_halt),
      .rvfi_intr (rvfi_intr),
      .rvfi_mode (rvfi_mode),
      .rvfi_ixl  (rvfi_ixl),

      .rvfi_rs1_addr (rvfi_rs1_addr),
      .rvfi_rs2_addr (rvfi_rs2_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_addr  (rvfi_rd_addr),
      .rvfi_rd_wdata (rvfi_rd_wdata),

      .rvfi_pc_rdata(rvfi_pc_rdata),
      .rvfi_pc_wdata(rvfi_pc_wdata),

      .rvfi_mem_addr (rvfi_mem_addr),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );
`endif

  // A draining group can accept refill while still occupied; use explicit
  // registered emptiness for I/O-fetch authorization.
  assign empty_o = !(|completion_owner.live) && rnu_operand.empty && rou_rename_empty;
  assign sq_empty_o = rou_lsu.sq_empty;
endmodule
