`ifndef RAPT_SVA_SVH
`define RAPT_SVA_SVH

// ============================================================================
//  Raptor SVA (SystemVerilog Assertions) infrastructure
//
//  Goals:
//   - One-line, extensible macros for concurrent assertions across modules.
//   - Centrally toggleable: `+define+RAPT_ASSERT_EN` enables checks in
//     non-synthesis builds; otherwise all macros expand to nothing (no
//     synthesis impact, zero sim cost).
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
//    `RAPT_SVA(clock, reset, LSU_SQ_ALIGN,
//              rou_lsu.valid && rou_lsu.store,
//              rou_lsu.sq_vaddr[1:0] == rou_lsu.sq_waddr[1:0])
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
    $fatal(1);                                                          \
  end

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

`else  // assertions disabled or synthesis build -> all expand to no-op

`define RAPT_SVA_IMM(name, cond)
`define RAPT_SVA(clk, rst, name, expr)
`define RAPT_SVA_IMPLY(clk, rst, name, ante, cons)
`define RAPT_SVA_NEXT(clk, rst, name, ante, cons)
`define RAPT_COVER(clk, rst, name, expr)

`endif  // RAPT_SVA_ACTIVE

`endif  // RAPT_SVA_SVH
