/* verilator lint_off UNUSEDPARAM */
package rapt_pkg;
  `include "rapt.svh"
  `include "rapt_types.svh"

  // RISC-V implicit return-stack hints, applied to expanded instructions.
  // Different link registers on JALR denote pop-then-push (coroutine switch).
  typedef struct packed {logic push, pop;} ras_action_t;
  function automatic ras_action_t ras_action(input logic [31:0] inst);
    ras_action_t action;
    logic rd_link, rs1_link;
    rd_link = inst[11:7] == 1 || inst[11:7] == 5;
    rs1_link = inst[19:15] == 1 || inst[19:15] == 5;
    action = '0;
    if (inst[6:0] == 7'b1101111) action.push = rd_link;
    if (inst[6:0] == 7'b1100111 && inst[14:12] == 0) begin
      action.push = rd_link;
      action.pop = rs1_link && (!rd_link || inst[11:7] != inst[19:15]);
    end
    return action;
  endfunction

  // Typed elaboration configuration. Legacy presets are adapted once here;
  // modules receive values/types, not another per-execution-domain macro.
  typedef struct packed {
    int unsigned xlen;
    int unsigned arch_regs;
    int unsigned phys_regs;
    int unsigned rob_entries;
    int unsigned rename_entries;
    int unsigned dispatch_entries;
    int unsigned iq_entries;
    int unsigned ioq_entries;
    int unsigned sq_entries;
    int unsigned decode_width;
    int unsigned rename_width;
    int unsigned dispatch_width;
    int unsigned commit_width;
    int unsigned integer_issue_ports;
    int unsigned integer_system_port;
    bit issue_rebalance;
    bit iq_reclaim_on_issue;
    bit recovery_dispatch_fence;
    bit rob_dispatch_buffered;
    int unsigned steer_scan_entries;
    int unsigned rob_generation_bits;
    int unsigned branch_checkpoints;
    int unsigned completion_ports;
    int unsigned execution_domains;
    int unsigned completion_dependencies;
  } core_config_t;
  localparam core_config_t CoreConfig = '{
      xlen: `RAPT_XLEN,
      arch_regs: `RAPT_REG_SIZE,
      phys_regs: `RAPT_PHY_SIZE,
      rob_entries: `RAPT_ROB_SIZE,
      rename_entries: `RAPT_RIQ_SIZE,
      dispatch_entries: `RAPT_IIQ_SIZE,
      iq_entries: `RAPT_RS_SIZE,
      ioq_entries: `RAPT_IOQ_SIZE,
      sq_entries: `RAPT_SQ_SIZE,
      decode_width: `RAPT_DECODE_WIDTH,
      rename_width: `RAPT_RENAME_WIDTH,
      dispatch_width: `RAPT_DISPATCH_WIDTH,
      commit_width: `RAPT_COMMIT_WIDTH,
      integer_issue_ports: `RAPT_INTEGER_ISSUE_PORTS,
      integer_system_port: `RAPT_INTEGER_SYSTEM_PORT,
      issue_rebalance: `RAPT_ISSUE_REBALANCE,
      iq_reclaim_on_issue: `RAPT_IQ_RECLAIM_ON_ISSUE,
      recovery_dispatch_fence: `RAPT_RECOVERY_DISPATCH_FENCE,
      rob_dispatch_buffered: `RAPT_ROB_DISPATCH_BUFFERED,
      steer_scan_entries: `RAPT_STEER_SCAN_ENTRIES,
      rob_generation_bits: `RAPT_ROB_GENERATION_BITS,
      branch_checkpoints: `RAPT_BRANCH_CHECKPOINTS,
      completion_ports: `RAPT_INTEGER_ISSUE_PORTS + 3,
      execution_domains: 5,
      completion_dependencies: 3
  };
  function automatic int unsigned index_bits(input int unsigned entries);
    return entries > 1 ? $clog2(entries) : 1;
  endfunction

  localparam int unsigned XLENPkg = CoreConfig.xlen;

  localparam unsigned RNUMPkg = CoreConfig.arch_regs;
  localparam unsigned RLENPkg = index_bits(CoreConfig.arch_regs);

  localparam unsigned PNUMPkg = CoreConfig.phys_regs;
  localparam unsigned PLENPkg = index_bits(CoreConfig.phys_regs);

  // One elaborated core configuration. Widths and port counts are not owned
  // by individual execution domains. Consumers may override CompletionPorts.
  localparam int unsigned ROBIndexBits = index_bits(CoreConfig.rob_entries);
  localparam int unsigned ROBEntries = CoreConfig.rob_entries;
  // Simulator-only lifecycle events, sampled on the actual ROB update edge.
  localparam int unsigned CfAllocate = 1, CfResolve = 2, CfMispredict = 4;
  localparam int unsigned CfRetire = 8, CfTrap = 16;
  localparam int unsigned CompletionPorts = CoreConfig.completion_ports;
  typedef logic [ROBIndexBits-1:0] rob_index_t;
  typedef logic [CoreConfig.rob_generation_bits-1:0] rob_generation_t;
  localparam int unsigned BranchCheckpointBits = index_bits(CoreConfig.branch_checkpoints);
  localparam int unsigned BranchCheckpoints = CoreConfig.branch_checkpoints;
  typedef logic [BranchCheckpointBits-1:0] branch_checkpoint_t;
  typedef logic [PLENPkg-1:0] phys_reg_t;
  typedef logic [RLENPkg-1:0] arch_reg_t;
  typedef logic [XLENPkg-1:0] xlen_t;

  // Completion describes architectural effects plus the ROB allocation
  // identity that owns them.  A completed uop need not write a GPR (e.g. a
  // branch or store), but every producer must return dest+generation.
  typedef struct packed {
    logic control_flow;
    logic memory;
    logic system_state;
    logic exception;
  } completion_updates_t;

  `RAPT_COMPLETION_TYPE(completion_t, xlen_t, phys_reg_t, arch_reg_t, rob_index_t, rob_generation_t)

  // Execution-domain registry, owned by core composition/decoder. The
  // router and completion consumers do not enumerate these domain names.
  typedef enum logic [2:0] {
    DOMAIN_INTEGER = 0,
    DOMAIN_BRANCH = 1,
    DOMAIN_MULDIV = 2,
    DOMAIN_FLOAT = 3,
    DOMAIN_MEMORY = 4
  } execution_domain_t;
  localparam int unsigned ExecutionDomains = CoreConfig.execution_domains;
  localparam int unsigned DispatchWidth = CoreConfig.dispatch_width;
  localparam int unsigned SteerScanEntries = CoreConfig.steer_scan_entries;
  localparam int unsigned DecodeWidth = CoreConfig.decode_width;
  localparam int unsigned RenameWidth = CoreConfig.rename_width;
  localparam int unsigned CommitWidth = CoreConfig.commit_width;
  localparam int unsigned IntegerIssuePorts = CoreConfig.integer_issue_ports;
  localparam int unsigned IntegerSystemPort = CoreConfig.integer_system_port;
  // Admission stop reasons are shared with the generated simulator package;
  // C++ must use these constants, never a second hand-numbered enum.
  localparam int unsigned DispatchStopWidth = 0;
  localparam int unsigned DispatchStopEmpty = 1;
  localparam int unsigned DispatchStopFlush = 2;
  localparam int unsigned DispatchStopHalt = 3;
  localparam int unsigned DispatchStopSerialBusy = 4;
  localparam int unsigned DispatchStopSerialWait = 5;
  localparam int unsigned DispatchStopSerialBoundary = 6;
  localparam int unsigned DispatchStopRob = 7;
  localparam int unsigned DispatchStopEndpoint = 8;
  localparam int unsigned DispatchStopReset = 9;
  localparam int unsigned DispatchStopRecovery = 10;
  localparam int unsigned DispatchStopCount = 11;
  typedef logic [index_bits(DispatchStopCount)-1:0] dispatch_stop_t;
  localparam int unsigned QueueIndexBits = index_bits(
      (CoreConfig.iq_entries > CoreConfig.ioq_entries ? CoreConfig.iq_entries : CoreConfig.ioq_entries) > 4
      ? (CoreConfig.iq_entries > CoreConfig.ioq_entries ? CoreConfig.iq_entries : CoreConfig.ioq_entries) : 4
  );
  typedef logic [IntegerIssuePorts-1:0] integer_port_mask_t;
  function automatic integer_port_mask_t integer_system_port_mask();
    integer_port_mask_t result;
    result = '0;
    result[IntegerSystemPort] = 1'b1;
    return result;
  endfunction
  localparam integer_port_mask_t IntegerAluPortMask = '1;
  localparam integer_port_mask_t IntegerSystemPortMask = integer_system_port_mask();
  typedef logic [QueueIndexBits-1:0] queue_index_t;
  typedef struct packed {
    execution_domain_t domain;
    integer_port_mask_t issue_ports;
  } scheduling_t;
  typedef struct packed {
    logic [DispatchWidth-1:0] ready;
    queue_index_t [DispatchWidth-1:0] free_index;
  } dispatch_capacity_t;
  typedef struct packed {
    logic [DispatchWidth-1:0] accept;
    queue_index_t [DispatchWidth-1:0] index;
  } dispatch_grant_t;

  typedef struct packed {
    logic word;
    logic [5:0] alu;
  } int_op_uop_t;

  typedef struct packed {
    logic conditional;
    logic jump;
    logic indirect;
    logic predicted_taken;
  } branch_uop_t;

  typedef struct packed {
    logic store;
    logic load;
    logic atomic;
  } memory_uop_t;

  typedef struct packed {
    logic valid;
    logic [5:0] op;
    logic [2:0] rm;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rs3;
    logic [4:0] rd;
  } fp_uop_t;

  typedef struct packed {
    logic valid;
    logic ecall;
    logic ebreak;
    logic fence_i;
    logic fence;
    logic mret;
    logic sret;
    logic [2:0] csr_csw;
  } sys_uop_t;

  // Domain-owned payload. Queueing/rename/transport preserve this whole
  // record, and execution units interpret only their own sub-record.
  typedef struct packed {
    int_op_uop_t int_op;
    branch_uop_t branch;
    memory_uop_t memory;
    fp_uop_t fp;
    sys_uop_t sys;
  } execution_payload_t;

  `RAPT_UOP_TYPE(uop_t, xlen_t, arch_reg_t, scheduling_t, execution_payload_t)

  typedef struct packed {
    logic [31:0] inst;
    xlen_t pc, pnpc;
    logic trap, predicted_taken;
    xlen_t cause, tval;
  } fetch_slot_t;
  typedef struct packed {
    uop_t uop;
    xlen_t op1, op2;
    arch_reg_t rs1, rs2;
  } decoded_slot_t;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic uop_is_mdq(input rapt_pkg::uop_t u);
    return (u.execute.int_op.alu[5:4] == 2'b01)
        && !u.execute.memory.store && !u.execute.memory.load && !u.execute.memory.atomic
        && !u.execute.sys.valid && !u.trap && !u.execute.sys.ecall && !u.execute.sys.ebreak
        && !u.execute.sys.mret && !u.execute.sys.sret && !u.execute.sys.fence_i && !u.execute.sys.fence
        && !u.execute.branch.conditional && !u.execute.branch.jump && !u.execute.branch.indirect
        && (u.execute.sys.csr_csw == '0);
  endfunction

  // FP loads/stores advertise ren/wen and remain in the IOQ. All other
  // scalar-FP operations execute through the independent FP issue queue.
  function automatic logic uop_is_fp_exec(input rapt_pkg::uop_t u);
    return u.execute.fp.valid && !u.execute.memory.store && !u.execute.memory.load;
  endfunction

  // ALU-CSR-only: CSR / system / trap semantics live exclusively in that pipe.
  // (Conditional branches are checked separately and win: a trap-marked
  // branch resolves on the Branch pipe as before, with trap info already in the
  // ROB from dispatch.)
  function automatic logic uop_requires_alu_csr(input rapt_pkg::uop_t u);
    return u.execute.sys.valid || u.trap || u.execute.sys.ecall || u.execute.sys.ebreak || u.execute.sys.mret || u.execute.sys.sret || (u.execute.sys.csr_csw != '0);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  // Decode policy is centralized here, not replicated by queues or router.
  function automatic scheduling_t schedule_uop(input uop_t u);
    scheduling_t result;
    if ((u.execute.memory.store || u.execute.memory.load) && !u.trap) result.domain = DOMAIN_MEMORY;
    else if (uop_is_mdq(u)) result.domain = DOMAIN_MULDIV;
    else if (uop_is_fp_exec(u)) result.domain = DOMAIN_FLOAT;
    else if (u.execute.branch.conditional) result.domain = DOMAIN_BRANCH;
    else result.domain = DOMAIN_INTEGER;
    result.issue_ports = IntegerAluPortMask;
    if (uop_requires_alu_csr(u)) result.issue_ports = IntegerSystemPortMask;
    return result;
  endfunction

  `RAPT_DISPATCH_SLOT_TYPE(dispatch_slot_t, uop_t, xlen_t, phys_reg_t, rob_index_t,
                           rob_generation_t, CoreConfig.completion_dependencies)

  // The scheduler transports the uop intact; only operand readiness and
  // operand values belong to the scheduler. New execution payload fields do
  // not require another set of IQ registers or field-by-field assignments.
  `RAPT_ISSUE_PACKET_TYPE(issue_packet_t, uop_t, xlen_t, phys_reg_t, rob_index_t, rob_generation_t)

  typedef struct packed {
    logic [XLENPkg-1:0] op1;
    logic [XLENPkg-1:0] op2;

    logic [PLENPkg-1:0] pr1;
    logic [PLENPkg-1:0] pr2;
    logic [PLENPkg-1:0] prd;
    logic [PLENPkg-1:0] prs;
  } prd_t;

  // ROB entry state
  typedef enum logic [1:0] {
    ROB_CM = 2'b00,  // Committed / empty
    ROB_WB = 2'b01,  // Written back, waiting to commit
    ROB_EX = 2'b10,  // Accepted by an execution-domain queue
    ROB_DP = 2'b11   // Allocated, pending execution-domain dispatch
  } rob_state_t;

  // ROB entry: mutable retirement state. Immutable uops remain in the
  // ROB-owned uop_pl array and are not read by execution units.
  typedef struct packed {
    // Physical register mapping
    logic [PLENPkg-1:0] prd;
    logic [PLENPkg-1:0] prs;

    // Architectural register
    logic [RLENPkg-1:0] rd;
    rob_state_t         state;
    logic               busy;
    rob_generation_t    generation;

    // Branch / jump resolution (WB-written)
    logic               btaken;
    logic [XLENPkg-1:0] npc;
    // 1-bit BPU mispredict flag (dispatch-init 0; WB sets when computed
    // npc != predicted pnpc). Replaces an XLEN-wide `pnpc` field that was
    // only ever consumed for the `npc != pnpc` comparison at commit.
    logic               mispredict;

    // Memory
    logic               wen;
    // Store payload belongs to the unified SQ, not the retirement record.

    // CSR (WB-written)
    logic               csr_wen;
    logic [XLENPkg-1:0] csr_wdata;
    logic               fp_flags_valid;
    logic [4:0]         fp_flags;

    // Trap (WB-mutable by EXU port-A and IOQ)
    logic               trap;
    logic [XLENPkg-1:0] tval;
    logic [XLENPkg-1:0] cause;

    // Difftest
    logic difftest_skip;
  } rob_entry_t;

  // Shared address classification functions for L1I/L1D
  // NPC AXI decode/backing memory and the supported LiteX board defaults
  // implement an 8 KiB SRAM. Do not grant PMAs to the old 64 KiB decode tail.
  localparam logic [31:0] SramBase  = 32'h0f000000;
  localparam logic [31:0] SramBytes = 32'h00002000;
  function automatic logic [XLENPkg-1:0] canonical_addr(input logic [XLENPkg-1:0] addr);
    return (XLENPkg == 64) ? XLENPkg'({32'b0, addr[31:0]}) : addr;
  endfunction

  // The implemented physical map is 32-bit. RV64 code may present those
  // addresses either zero-extended or with an all-ones upper half (for
  // example, an address materialised by a sign-extending LUI). Do not simply
  // truncate any other upper half: doing so can turn an invalid speculative
  // address such as 0x00000002_8014572c into a real PMEM request.
  function automatic logic addr_upper_valid(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] zero_extended;
    logic [XLENPkg-1:0] ones_extended;
    zero_extended = XLENPkg'({32'h0000_0000, addr[31:0]});
    ones_extended = XLENPkg'({32'hffff_ffff, addr[31:0]});
    return (addr == zero_extended) || (addr == ones_extended);
  endfunction

  function automatic logic addr_cacheable(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_upper_valid(
        addr
    ) && ((0)  // --- IGNORE ---
    || (a >= XLENPkg'(SramBase) && a < XLENPkg'(SramBase + SramBytes))
    || (a >= 'h20000000 && a < 'h20010000)  // mrom (64KB)
    || (a >= 'h30000000 && a < 'h40000000)  // flash
    || (a >= XLENPkg'(32'h80000000) && a < XLENPkg'(32'h90000000))  // psram (cacheable)
    || (a >= XLENPkg'(32'ha0000000) && a < XLENPkg'(32'ha2000000))  // sdram
    );
  endfunction

  // Physical execute PMA for this platform: RAM/ROM/flash support fetch;
  // device regions do not. PBMT changes access type, not this capability.
  // The executable regions currently coincide with the cacheable map.
  function automatic logic addr_executable(input logic [XLENPkg-1:0] addr,
                                           input logic [3:0] size_m1);
    logic [XLENPkg:0] last_addr;
    last_addr = {1'b0, canonical_addr(addr)} + (XLENPkg + 1)'(size_m1);
    return (size_m1 == 1 || size_m1 == 3) && addr_cacheable(
        addr
    ) && !last_addr[XLENPkg] && addr_cacheable(
        last_addr[XLENPkg-1:0]
    );
  endfunction

  // Platform PMA for implicit page-table reads. The RAM/ROM/flash regions
  // listed by addr_cacheable support PTE reads; device regions do not.
  // This is a physical capability, independent of a leaf's PBMT and PMP.
  // Check the whole naturally aligned Sv32/Sv39 PTE before issuing a read.
  function automatic logic addr_ptw_readable(input logic [XLENPkg-1:0] addr,
                                             input logic [3:0] size_m1);
    logic [XLENPkg:0] last_addr;
    last_addr = {1'b0, canonical_addr(addr)} + (XLENPkg + 1)'(size_m1);
    return (size_m1 == 3 || size_m1 == 7) && ((addr & XLENPkg'(size_m1)) == 0) && addr_cacheable(
        addr
    ) && !last_addr[XLENPkg] && addr_cacheable(
        last_addr[XLENPkg-1:0]
    );
  endfunction

  // AXI4 memory type: Normal WB R/W allocate for cacheable PMA,
  // Normal non-cacheable/non-bufferable for NC, Device non-bufferable for IO.
  // This encodes transaction attributes, not PMP or supported-access PMAs.
  function automatic logic [3:0] axi_cache_attr(input logic [XLENPkg-1:0] addr,
                                                input logic [1:0] pbmt);
    case (pbmt)
      2'b00: return addr_cacheable(addr) ? 4'b1111 : 4'b0000;
      2'b01: return 4'b0010;
      default: return 4'b0000;
    endcase
  endfunction

  // Any physical address that corresponds to a real bus target
  // (cacheable memory or MMIO).  Accesses outside of this predicate
  // are unmapped and must raise an access-fault trap to mimic sail /
  // real-hardware bus-error behaviour.
  function automatic logic addr_mapped(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_upper_valid(
        addr
    ) && ((0)  // --- IGNORE ---
    || (a >= 'h00100000 && a < 'h00101000)  // sifive,test finisher
    || (a >= 'h02000000 && a < 'h020c0000)  // CLINT
    || (a >= 'h0c000000 && a < 'h0d000000)  // PLIC
    || (a >= XLENPkg'(SramBase) && a < XLENPkg'(SramBase + SramBytes))
    || (a >= 'h10000000 && a < 'h10012000)  // UART / GPIO / peripherals
    || (a >= 'h20000000 && a < 'h20010000)  // MROM
    || (a >= 'h21000000 && a < 'h21200000)  // VGA
    || (a >= 'h30000000 && a < 'h40000000)  // FLASH
    || (a >= XLENPkg'(32'h80000000) && a < XLENPkg'(32'h90000000))  // PMEM / PSRAM
    || (a >= XLENPkg'(32'ha0000000) && a < XLENPkg'(32'ha2000000))  // SDRAM
    || (a >= XLENPkg'(32'hf0008000) && a < XLENPkg'(32'hf0008100))  // LiteX SPI SD-card controller
    || (a >= XLENPkg'(32'hf0001000) && a < XLENPkg'(32'hf0001100))  // LiteX UART (egos HARDWARE)
    || (a >= XLENPkg'(32'hf0010000) && a < XLENPkg'(32'hf0020000))  // CLINT alias (egos HARDWARE)
    || (a >= XLENPkg'(32'hc0000000)));  // raptSoC MMIO window
  endfunction

  // Device PMA is independent of page-based cache/order overrides. Physical
  // register accesses must be naturally aligned; ordinary RAM/ROM accesses
  // keep their existing misaligned support and span permission checks.
  function automatic logic addr_device(input logic [XLENPkg-1:0] addr);
    return addr_mapped(addr) && !addr_cacheable(addr);
  endfunction

  // Supported architectural transfer width, independent of fragment size,
  // mapping permission and PBMT. PLIC registers accept aligned 32-bit accesses.
  // Other device widths retain their existing policy pending region audit.
  function automatic logic addr_device_width_capable(input logic [XLENPkg-1:0] addr,
                                                     input logic [3:0] original_size_m1);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return !(a >= 'h0c000000 && a < 'h0d000000) || (original_size_m1 == 4'd3 && a[1:0] == 2'b00);
  endfunction

  // ROM and the memory-mapped flash image are physically read-only.
  // Device register write/size capabilities are a separate PMA contract;
  // this predicate does not imply atomic or reservation support.
  function automatic logic addr_writable(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_mapped(
        addr
    ) && !(a >= 'h20000000 && a < 'h20010000) && !(a >= 'h30000000 && a < 'h40000000);
  endfunction

  // Ordinary data span mapping/permission check. This does not grant device
  // transfer-size, atomic, or block-zero capabilities. Check every byte so
  // a mapped starting address cannot authorize access through a hole.
  // Eight is the no-fault sentinel; otherwise return the first denied byte.
  function automatic logic [3:0] addr_data_span_fault_offset(
      input logic [XLENPkg-1:0] addr, input logic [3:0] size_m1, input logic store_access);
    logic [XLENPkg:0] next_block;
    logic [3:0] boundary_offset;
    logic first_ok, next_ok;
    // Every region boundary in addr_mapped/addr_writable is aligned to at
    // least eight bytes. A scalar span of at most eight bytes therefore
    // visits at most two permission-homogeneous blocks. Decode each block
    // once instead of replicating the full map and an XLEN adder per byte.
    // Keep the bytewise equivalence proof when changing the physical map.
    boundary_offset = 4'd8 - {1'b0, addr[2:0]};
    next_block = {1'b0, canonical_addr(addr) & ~XLENPkg'(7)} + (XLENPkg+1)'(8);
    first_ok = store_access ? addr_writable(canonical_addr(addr))
                           : addr_mapped(canonical_addr(addr));
    next_ok = !next_block[XLENPkg]
        && (store_access ? addr_writable(next_block[XLENPkg-1:0])
                         : addr_mapped(next_block[XLENPkg-1:0]));
    if (!addr_upper_valid(addr) || size_m1 > 7 || !first_ok) return 4'd0;
    if (boundary_offset <= size_m1 && !next_ok) return boundary_offset;
    return 4'd8;
  endfunction

  function automatic logic addr_data_span_capable(
      input logic [XLENPkg-1:0] addr, input logic [3:0] size_m1, input logic store_access);
    return addr_data_span_fault_offset(addr, size_m1, store_access) == 8;
  endfunction

  // Block zero is a distinct supported-access PMA. Ordinary device writes
  // do not authorize expansion into an entire cache block of register writes.
  // PBMT may change a RAM access type without removing this capability.
  function automatic logic addr_zero_capable(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] base_addr, last_addr;
    base_addr = canonical_addr(addr) & ~XLENPkg'(63);
    last_addr = base_addr + XLENPkg'(63);
    return addr_upper_valid(
        addr
    ) && addr_cacheable(
        base_addr
    ) && addr_writable(
        base_addr
    ) && addr_cacheable(
        last_addr
    ) && addr_writable(
        last_addr
    );
  endfunction

  // This platform supports AMOArithmetic and LR/SC only in writable RAM.
  // Capability is independent of a leaf's PBMT and does not itself prove
  // RsrvEventual progress or coherence with external bus masters.
  function automatic logic addr_atomic_capable(input logic [XLENPkg-1:0] addr,
                                               input logic [3:0] size_m1);
    logic [XLENPkg:0] last_addr;
    last_addr = {1'b0, canonical_addr(addr)} + (XLENPkg + 1)'(size_m1);
    return (size_m1 == 3 || (XLENPkg == 64 && size_m1 == 7))
        && ((addr & XLENPkg'(size_m1)) == 0) && !last_addr[XLENPkg]
        && addr_cacheable(
        addr
    ) && addr_writable(
        addr
    ) && addr_cacheable(
        last_addr[XLENPkg-1:0]
    ) && addr_writable(
        last_addr[XLENPkg-1:0]
    );
  endfunction

  // MMIO regions for difftest skip (not modelled in reference ISS)
  function automatic logic addr_mmio(input logic [XLENPkg-1:0] addr);
    logic [XLENPkg-1:0] a;
    a = canonical_addr(addr);
    return addr_upper_valid(
        addr
    ) && ((0)  // --- IGNORE ---
    || (a >= 'h00100000 && a <= 'h00100fff)  // finisher (sifive,test)
    || (a >= 'h02000000 && a <= 'h020bffff)  // CLINT (mtime / mtimecmp / msip)
    || (a >= 'h0c000000 && a <= 'h0cffffff)  // PLIC (claim/complete RMW)
    || (a >= XLENPkg'(32'hf0008000) && a <= XLENPkg'(32'hf00080ff))  // LiteX SPI SD-card controller
    || (a >= XLENPkg'(32'hf0001000) && a <= XLENPkg'(32'hf00010ff))  // LiteX UART (egos HARDWARE)
    || (a >= XLENPkg'(32'hf0010000) && a <= XLENPkg'(32'hf001ffff))  // CLINT alias (egos HARDWARE)
    || (a >= 'h10001000 && a <= 'h10001fff)  // uart
    || (a >= 'h10002000 && a <= 'h1000200f)  // gpio
    || (a >= 'h21000000 && a <= 'h211fffff)  // vga
    || (a >= XLENPkg'(32'hc0000000)));  // raptSoC memory-mapped I/O
  endfunction

endpackage
