`ifndef RAPT_TYPES_SVH
`define RAPT_TYPES_SVH

// SystemVerilog has no parameterized packages. These declaration helpers
// construct a consistent type family in the composition scope; generic
// modules receive that family via parameter type. No fixed XLEN/ROB/PRF
// dimensions are captured by the helpers.
`ifdef RAPT_RVFI
`define RAPT_UOP_TRACE_FIELD logic [31:0] rvfi_inst;
`else
`define RAPT_UOP_TRACE_FIELD
`endif

`ifdef RAPT_UOP_HAS_INST
`define RAPT_UOP_INST_FIELD logic [31:0] inst;
`else
`define RAPT_UOP_INST_FIELD
`endif

`define RAPT_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  logic btaken; \
  logic mispredict; \
  RobT dest; \
  GenerationT generation; \
  WordT result; \
  PhysT prd; \
  ArchT rd; \
  logic csr_wen; \
  WordT csr_wdata; \
  logic fp_flags_valid; \
  logic [4:0] fp_flags; \
  logic fp_wen; \
  logic [63:0] fp_result; \
  logic wen; \
  logic [5:0] alu; \
  WordT sq_waddr; \
  WordT sq_wdata; \
  logic [63:0] sq_wdata64; \
  logic sq_fp64; \
  logic trap; \
  WordT tval; \
  logic [5:0] cause; \
  logic difftest_skip; \
  logic valid; \
  } Name;

`define RAPT_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

// Physical completion endpoints carry only fields produced by their execution domain.
// The generic ROB/wake view is reconstructed with zeroed absent sidebands.
`define RAPT_ALU_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  RobT dest; \
  GenerationT generation; \
  WordT result; \
  PhysT prd; \
  ArchT rd; \
  logic valid; \
  } Name;

`define RAPT_ALU_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_ALU_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

`define RAPT_ALU_COMPLETION_COPY(Dst, Src) \
  Dst.updates = Src.updates; \
  Dst.pc = Src.pc; \
  Dst.npc = Src.npc; \
  Dst.dest = Src.dest; \
  Dst.generation = Src.generation; \
  Dst.result = Src.result; \
  Dst.prd = Src.prd; \
  Dst.rd = Src.rd; \
  Dst.valid = Src.valid;

`define RAPT_BRANCH_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  RobT dest; \
  GenerationT generation; \
  logic btaken; \
  logic valid; \
  } Name;

`define RAPT_BRANCH_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_BRANCH_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

`define RAPT_BRANCH_COMPLETION_COPY(Dst, Src) \
  Dst.updates = Src.updates; \
  Dst.pc = Src.pc; \
  Dst.npc = Src.npc; \
  Dst.dest = Src.dest; \
  Dst.generation = Src.generation; \
  Dst.btaken = Src.btaken; \
  Dst.valid = Src.valid;

`define RAPT_MDU_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  RobT dest; \
  GenerationT generation; \
  WordT result; \
  PhysT prd; \
  ArchT rd; \
  logic valid; \
  } Name;

`define RAPT_MDU_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_MDU_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

`define RAPT_MDU_COMPLETION_COPY(Dst, Src) \
  Dst.updates = Src.updates; \
  Dst.pc = Src.pc; \
  Dst.npc = Src.npc; \
  Dst.dest = Src.dest; \
  Dst.generation = Src.generation; \
  Dst.result = Src.result; \
  Dst.prd = Src.prd; \
  Dst.rd = Src.rd; \
  Dst.valid = Src.valid;

`define RAPT_SYSTEM_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  RobT dest; \
  GenerationT generation; \
  WordT result; \
  PhysT prd; \
  ArchT rd; \
  logic csr_wen; \
  WordT csr_wdata; \
  logic trap; \
  WordT tval; \
  logic [5:0] cause; \
  logic difftest_skip; \
  logic valid; \
  } Name;

`define RAPT_SYSTEM_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_SYSTEM_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

`define RAPT_SYSTEM_COMPLETION_COPY(Dst, Src) \
  Dst.updates = Src.updates; \
  Dst.pc = Src.pc; \
  Dst.npc = Src.npc; \
  Dst.dest = Src.dest; \
  Dst.generation = Src.generation; \
  Dst.result = Src.result; \
  Dst.prd = Src.prd; \
  Dst.rd = Src.rd; \
  Dst.csr_wen = Src.csr_wen; \
  Dst.csr_wdata = Src.csr_wdata; \
  Dst.trap = Src.trap; \
  Dst.tval = Src.tval; \
  Dst.cause = Src.cause; \
  Dst.difftest_skip = Src.difftest_skip; \
  Dst.valid = Src.valid;

`define RAPT_FPU_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  RobT dest; \
  GenerationT generation; \
  WordT result; \
  PhysT prd; \
  ArchT rd; \
  logic fp_flags_valid; \
  logic [4:0] fp_flags; \
  logic fp_wen; \
  logic [63:0] fp_result; \
  logic trap; \
  WordT tval; \
  logic [5:0] cause; \
  logic valid; \
  } Name;

`define RAPT_FPU_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_FPU_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

`define RAPT_FPU_COMPLETION_COPY(Dst, Src) \
  Dst.updates = Src.updates; \
  Dst.pc = Src.pc; \
  Dst.npc = Src.npc; \
  Dst.dest = Src.dest; \
  Dst.generation = Src.generation; \
  Dst.result = Src.result; \
  Dst.prd = Src.prd; \
  Dst.rd = Src.rd; \
  Dst.fp_flags_valid = Src.fp_flags_valid; \
  Dst.fp_flags = Src.fp_flags; \
  Dst.fp_wen = Src.fp_wen; \
  Dst.fp_result = Src.fp_result; \
  Dst.trap = Src.trap; \
  Dst.tval = Src.tval; \
  Dst.cause = Src.cause; \
  Dst.valid = Src.valid;

`define RAPT_LSU_COMPLETION_TYPE_PC(Name, WordT, PcT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  PcT pc; \
  PcT npc; \
  RobT dest; \
  GenerationT generation; \
  WordT result; \
  PhysT prd; \
  ArchT rd; \
  logic fp_wen; \
  logic [63:0] fp_result; \
  logic wen; \
  logic [5:0] alu; \
  WordT sq_waddr; \
  WordT sq_wdata; \
  logic [63:0] sq_wdata64; \
  logic sq_fp64; \
  logic trap; \
  WordT tval; \
  logic [5:0] cause; \
  logic difftest_skip; \
  logic valid; \
  } Name;

`define RAPT_LSU_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  `RAPT_LSU_COMPLETION_TYPE_PC(Name, WordT, WordT, PhysT, ArchT, RobT, GenerationT)

`define RAPT_LSU_COMPLETION_COPY(Dst, Src) \
  Dst.updates = Src.updates; \
  Dst.pc = Src.pc; \
  Dst.npc = Src.npc; \
  Dst.dest = Src.dest; \
  Dst.generation = Src.generation; \
  Dst.result = Src.result; \
  Dst.prd = Src.prd; \
  Dst.rd = Src.rd; \
  Dst.fp_wen = Src.fp_wen; \
  Dst.fp_result = Src.fp_result; \
  Dst.wen = Src.wen; \
  Dst.alu = Src.alu; \
  Dst.sq_waddr = Src.sq_waddr; \
  Dst.sq_wdata = Src.sq_wdata; \
  Dst.sq_wdata64 = Src.sq_wdata64; \
  Dst.sq_fp64 = Src.sq_fp64; \
  Dst.trap = Src.trap; \
  Dst.tval = Src.tval; \
  Dst.cause = Src.cause; \
  Dst.difftest_skip = Src.difftest_skip; \
  Dst.valid = Src.valid;

// Architectural fault addresses use the consuming XLEN, independent of PC storage.
// Illegal instruction payloads are unsigned; fetch PCs wrap at their stored width.
`define RAPT_UOP_TVAL(XW, U) \
  (U.trap ? (U.cause == 6'(`RAPT_CAUSE_ILLEGAL_INST) ? (XW)'(U.imm) \
      : `RAPT_PC_SEXT(XW, $bits(U.pc)'(U.pc \
          + (U.fetch_tval_plus2 ? $bits(U.pc)'(2) : $bits(U.pc)'(0))))) : (XW)'(0))

`define RAPT_UOP_TYPE_PC(Name, WordT, PcT, ArchT, ScheduleT, ExecuteT) \
  typedef struct packed { \
  ScheduleT schedule; \
  ExecuteT execute; \
  logic       c; \
  logic trap; \
  logic fetch_tval_plus2; \
  logic [5:0] cause; \
  ArchT rd; \
  logic [31:0] imm; \
  `RAPT_UOP_INST_FIELD \
  `RAPT_UOP_TRACE_FIELD \
  PcT pc; \
  } Name;

`define RAPT_UOP_TYPE(Name, WordT, ArchT, ScheduleT, ExecuteT) \
  `RAPT_UOP_TYPE_PC(Name, WordT, WordT, ArchT, ScheduleT, ExecuteT)

`define RAPT_DISPATCH_SLOT_TYPE(Name, UopT, WordT, PhysT, RobT, GenerationT, NumDeps) \
  typedef struct packed { \
  UopT uop; \
  WordT op1; \
  WordT stable_op1; \
  logic stable_op1_valid; \
  WordT op2; \
  WordT op3; \
  PhysT pr1; \
  PhysT pr2; \
  PhysT pr3; \
  PhysT prd; \
  PhysT prs; \
  logic [NumDeps-1:0] dep_valid; \
  RobT [NumDeps-1:0] dep_tag; \
  GenerationT [NumDeps-1:0] dep_generation; \
  RobT dest; \
  GenerationT generation; \
  logic [2:0][63:0] fp_value; \
  logic [2:0][$bits(RobT):0] fp_tag; \
  logic [31:0] resources; \
  } Name;

`define RAPT_ISSUE_PACKET_TYPE(Name, UopT, WordT, PhysT, RobT, GenerationT) \
  typedef struct packed { \
  logic valid; \
  UopT uop; \
  WordT op1; \
  WordT op2; \
  WordT op3; \
  RobT dest; \
  GenerationT generation; \
  PhysT prd; \
  } Name;

`endif  // RAPT_TYPES_SVH
