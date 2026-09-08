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

`define RAPT_COMPLETION_TYPE(Name, WordT, PhysT, ArchT, RobT, GenerationT) \
  typedef struct packed { \
  rapt_pkg::completion_updates_t updates; \
  WordT pc; \
  WordT npc; \
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
  logic wen; \
  logic [5:0] alu; \
  WordT sq_waddr; \
  WordT sq_wdata; \
  logic [63:0] sq_wdata64; \
  logic sq_fp64; \
  logic trap; \
  WordT tval; \
  WordT cause; \
  logic difftest_skip; \
  logic valid; \
  } Name;

`define RAPT_UOP_TYPE(Name, WordT, ArchT, ScheduleT, ExecuteT) \
  typedef struct packed { \
  ScheduleT schedule; \
  ExecuteT execute; \
  logic       c; \
  logic trap; \
  WordT tval; \
  WordT cause; \
  ArchT rd; \
  WordT imm; \
  WordT pnpc; \
  logic [31:0] inst; \
  `RAPT_UOP_TRACE_FIELD \
  WordT pc; \
  } Name;

`define RAPT_DISPATCH_SLOT_TYPE(Name, UopT, WordT, PhysT, RobT, GenerationT, NumDeps) \
  typedef struct packed { \
  UopT uop; \
  WordT op1; \
  WordT op2; \
  PhysT pr1; \
  PhysT pr2; \
  PhysT prd; \
  PhysT prs; \
  logic [NumDeps-1:0] dep_valid; \
  RobT [NumDeps-1:0] dep_tag; \
  GenerationT [NumDeps-1:0] dep_generation; \
  RobT dest; \
  GenerationT generation; \
  } Name;

`define RAPT_ISSUE_PACKET_TYPE(Name, UopT, WordT, PhysT, RobT, GenerationT) \
  typedef struct packed { \
  logic valid; \
  UopT uop; \
  WordT op1; \
  WordT op2; \
  RobT dest; \
  GenerationT generation; \
  PhysT prd; \
  } Name;

`endif  // RAPT_TYPES_SVH
