`ifndef RAPT_SVA_SVH
`define RAPT_SVA_SVH

// A procedural failure remains a proof obligation in native formal runs.
`ifdef SYNTHESIS
`define RAPT_SVA_FAIL(name)
`elsif RAPT_FORMAL_NATIVE
`define RAPT_SVA_FAIL(name) name``_a: assert (1'b0);
`else
`define RAPT_SVA_FAIL(name) $fatal(1);
`endif

// ============================================================================
//  Raptor SVA (SystemVerilog Assertions) infrastructure
//
//  Goals:
//   - One-line, extensible macros for concurrent assertions across modules.
//   - Centrally toggleable: `+define+RAPT_ASSERT_EN` enables checks in
//     non-synthesis builds; otherwise optional checks expand to nothing.
//     RAPT_SVA_FAIL preserves existing always-on procedural failure checks.
//   - Consistent failure reporting: module hierarchy + assertion name +
//     simulation time are always printed, so cross-module invariant
//     violations are trivially attributable.
//   - Naming convention: assertion labels are uppercase_snake with a
//     domain prefix (e.g. LSU_SQ_ALIGN, ROB_FLUSH_DRAIN).
//
//  Assertion taxonomy this file codifies:
//   - FLUSH_CLEAR    : structure fully cleared on flush (UOQ/RS/IOQ/STQ/...)
//   - FLUSH_SURVIVE  : structure keeps older-than-flush entries (ROB/SQ/...)
//   - COMMIT_DURABLE : commit-time data must come from a durable source
//                      (ROB / architectural state), never from a speculative
//                      queue. Violations cause cross-flush data corruption.
//   - HANDSHAKE      : valid/ready / head<=tail / queue capacity invariants.
//   - ONE_HOT        : priority/mux selectors are one-hot when expected.
//
//  Usage examples:
//    `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_ALIGN,
//              rou_lsu.valid && rou_lsu.store,
//              !$isunknown(rou_lsu.sq_vaddr))
//
//    `RAPT_SVA_NEXT(clock, reset, ROB_FLUSH_DRAIN,
//                   cmu_bcast.flush_pipe,
//                   !uop_queue_valid_any)
//
//  Adding a new check: pick the right macro, give it a LABEL_IN_CAPS,
//  drop it near the signals it guards. No central registry needed.
// ============================================================================

// Assertions/covers must never leak into FPGA/ASIC netlists. Most synthesis
// frontends define SYNTHESIS; keep the real SVA expansion behind both the
// explicit verification knob and the non-synthesis guard.
`ifdef RAPT_ASSERT_EN
`ifndef SYNTHESIS
`define RAPT_SVA_ACTIVE
`endif
`endif

`ifdef RAPT_SVA_ACTIVE

// ---- Immediate (combinational) check inside always_comb/always_ff ----
// Prefer `RAPT_SVA` for clocked checks; use this only inside procedural blocks.
`define RAPT_SVA_IMM(name, cond)                                        \
  if (!(cond)) begin                                                    \
    $display("[%0t] SVA FAIL: %m.%s cond=(%s)",                         \
             $time, `"name`", `"cond`");                                \
    `RAPT_SVA_FAIL(name)                                                \
  end

// Native Slang supports clocked predicates but not sequence implication.
// Preserve sampled expressions in their clock context. The next-cycle monitor
// is assertion-only state; asynchronous reset must cancel pending obligations.
`ifdef RAPT_FORMAL_NATIVE
`define RAPT_SVA(clk, rst, name, expr) \
  name``_a: assert property (@(posedge clk) disable iff (rst) (|(expr))) else $fatal(1);
`define RAPT_SVA_IMPLY(clk, rst, name, ante, cons) \
  `RAPT_SVA(clk, rst, name, !(|(ante)) || |(cons))
`define RAPT_SVA_NEXT(clk, rst, name, ante, cons) \
  wire name``_reset = (rst); \
  logic name``_pending = 1'b0; \
  always_ff @(posedge clk or posedge name``_reset) begin \
    if (name``_reset) name``_pending <= 1'b0; \
    else name``_pending <= |(ante); \
  end \
  `RAPT_SVA(clk, rst, name, !name``_pending || |(cons))
`define RAPT_COVER(clk, rst, name, expr) \
  name``_c: cover property (@(posedge clk) disable iff (rst) (|(expr)));

`else  // Standard SVA

// ---- Basic concurrent assertion: `expr` must hold every posedge `clk` ----
`define RAPT_SVA(clk, rst, name, expr)                                  \
  name``_a: assert property (                                           \
    @(posedge clk) disable iff (rst) (expr)                             \
  ) else begin                                                          \
    $display("[%0t] SVA FAIL: %m.%s expr=(%s)",                         \
             $time, `"name`", `"expr`");                                \
    $fatal(1);                                                          \
  end

// ---- Implication (same cycle): ante |-> cons ----
`define RAPT_SVA_IMPLY(clk, rst, name, ante, cons)                      \
  name``_a: assert property (                                           \
    @(posedge clk) disable iff (rst) ((ante) |-> (cons))                \
  ) else begin                                                          \
    $display("[%0t] SVA FAIL: %m.%s (%s) |-> (%s)",                     \
             $time, `"name`", `"ante`", `"cons`");                      \
    $fatal(1);                                                          \
  end

// ---- Implication (next cycle): ante |=> cons ----
`define RAPT_SVA_NEXT(clk, rst, name, ante, cons)                       \
  name``_a: assert property (                                           \
    @(posedge clk) disable iff (rst) ((ante) |=> (cons))                \
  ) else begin                                                          \
    $display("[%0t] SVA FAIL: %m.%s (%s) |=> (%s)",                     \
             $time, `"name`", `"ante`", `"cons`");                      \
    $fatal(1);                                                          \
  end

// ---- Cover (optional coverage hint) ----
`define RAPT_COVER(clk, rst, name, expr)                                \
  name``_c: cover property (                                            \
    @(posedge clk) disable iff (rst) (expr)                             \
  );

`endif  // RAPT_FORMAL_NATIVE

`else  // assertions disabled or synthesis build -> all expand to no-op

`define RAPT_SVA_IMM(name, cond)
`define RAPT_SVA(clk, rst, name, expr)
`define RAPT_SVA_IMPLY(clk, rst, name, ante, cons)
`define RAPT_SVA_NEXT(clk, rst, name, ante, cons)
`define RAPT_COVER(clk, rst, name, expr)

`endif  // RAPT_SVA_ACTIVE

`endif  // RAPT_SVA_SVH
