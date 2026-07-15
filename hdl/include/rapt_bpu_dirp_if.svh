// Unified direction-predictor (dirp) port macro for the BPU.
//
// All conditional-branch direction predictors (static, bimodal, gshare,
// tage, ...) expose the same signature so the BPU wrapper can pick one
// via `RAPT_BPU_DIRP_*` define without touching the surrounding logic.
//
// Signals:
//   clock, reset      -- clocking/reset
//   ren / raddr / r_ghr
//     Synchronous read port. On `ren` the implementation latches `raddr`
//     and `r_ghr`; `rd_taken` becomes valid on the next cycle.
//   rd_taken          -- predicted direction (1 = taken)
//   update_en         -- pulses on every committed COND branch
//   update_pc         -- PC of the committed branch
//   update_ghr        -- committed (architectural) GHR snapshot
//   update_taken      -- true direction at retire
//   update_mispred    -- qualifies allocation-class updates (e.g. TAGE
//                       allocation, gshare counter weighting); the
//                       baseline counter update should run on every
//                       `update_en` regardless of this bit.
//   init              -- bulk reset (fence_time / cfi_flush)
//
// Predictors that do not use GHR are free to leave it unconnected.
`ifndef RAPT_BPU_DIRP_IF_SVH
`define RAPT_BPU_DIRP_IF_SVH

`define RAPT_BPU_DIRP_PORTS                  \
    input  logic                clock,       \
    input  logic                reset,       \
    input  logic                ren,         \
    input  logic [XLEN-1:0]     raddr,       \
    input  logic [GHR_LEN-1:0]  r_ghr,       \
    input  logic [PHR_LEN-1:0]  r_phr,       \
    output logic                rd_taken,    \
    input  logic                update_en,   \
    input  logic [XLEN-1:0]     update_pc,   \
    input  logic [GHR_LEN-1:0]  update_ghr,  \
    input  logic [PHR_LEN-1:0]  update_phr,  \
    input  logic                update_taken,\
    input  logic                update_mispred, \
    input  logic                init

`endif
