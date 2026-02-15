# Copilot Instructions - Raptor Chip

## Project Overview

Out-of-order RISC-V (RV32IMAC_Zicsr_Sv32) processor core ("raptor") with register renaming, ROB, reservation stations, and Sv32 virtual memory. Features LR/SC + AMO atomics, compressed instructions (RVC), and boots Linux 6.12 via OpenSBI. The RTL is hand-written **SystemVerilog** with Chisel used only for decoder generation. Verification uses Verilator simulation with differential testing against NEMU (a reference ISA emulator).

## Architecture (Pipeline Stages)

```
IFU → IDU → RNU (rename) → ROU (ROB/dispatch) → EXU (RS/IOQ) → CMU (commit)
                                                    ↕
                                              LSU ↔ L1D ↔ BUS ↔ AXI4
```

- **Frontend** (`rtl_sv/frontend/`): IFU (3-state FSM, fetch + PC mux), L1I (direct-mapped + TLB + IFQ + Sv32 PTW), BPU (bimodal PHT + BTB + GHR + RSB), IDU (RVC expansion + Chisel decoders, `csr_addr_valid()`)
- **Backend** (`rtl_sv/backend/` + `rtl_sv/frontend/ysyx_csr.sv`):
  - **RNU** (rename): pure rename stage (`ysyx_rnu.sv`) + RNQ (circular, `RIQ_SIZE`) + 2 sub-modules:
    - `ysyx_rnu_freelist.sv` - physical register free list (circular FIFO, `rnu_fl_if`, flush recovery via in-flight count rewind)
    - `ysyx_rnu_maptable.sv` - speculative MAP + committed RAT (`rnu_mt_if`, 3 read ports, flush: MAP←RAT, exposes `map_snapshot`/`rat_snapshot`)
  - **PRF** (`ysyx_prf.sv`): multi-ported physical register file (2R/2W), instantiated at top level (`ysyx.sv`) — valid + transient tracking, flush invalidates transient entries. Write port A: `exu_rou_if`, Write port B: `exu_ioq_bcast_if`, Read: `exu_prf_if`
  - **ROU** (ROB/dispatch): UOQ (dispatch queue, `IIQ_SIZE`) + ROB (`rob_entry_t[]`, `ROB_SIZE`, states: `ROB_EX`→`ROB_WB`→`ROB_CM`), operand bypass (PRF > IOQ > EXU), async trap from CLINT
  - **EXU**: RS (`RS_SIZE`, priority issue, operand forwarding) + IOQ (`IOQ_SIZE`, in-order, for ld/st/amo/Zicsr) + ALU (combinational RV32I) + MUL (Booth's / iterative div, or fast single-cycle mode)
  - **CMU** (commit): lightweight broadcast unit (retire PC, branch resolution, flush, fence)
  - **CSR** (`ysyx_csr.sv`): M/S-mode CSR file, trap delegation, privilege transitions, MMU broadcasts (`immu_en`/`dmmu_en`, `satp_ppn`, `tvec`)
- **Memory** (`rtl_sv/memory/`): LSU (STQ + SQ, store-to-load forwarding CAM), L1I (direct-mapped, ITLB, Sv32 PTW, IFQ), L1D (direct-mapped, load TLB + store STLB, Sv32 PTW, write-through, LR/SC reservation), BUS (AXI4 bridge, L1D priority, CLINT internal), CLINT (64-bit mtime, periodic timer interrupt)
- **Top-level**: `rtl_sv/ysyx.sv` (bare core, pure wiring — instantiates all stages + PRF), `rtl_sv/ysyx_npc_soc.sv` (SoC wrapper for Verilator sim)
- **Config/types**: `rtl_sv/include/ysyx_config.svh` (params incl. `YSYX_ISSUE_WIDTH`, cache/BPU/queue sizes), `rtl_sv/ysyx_pkg.sv` (`uop_t`, `prd_t`, `rob_entry_t`, `rob_state_t` types)
- **Interfaces**: `rtl_sv/include/ysyx_*_if.svh` (inter-module: `ifu_idu_if`, `idu_rnu_if`, `rnu_rou_if`, `rou_exu_if`, `exu_rou_if`, `exu_ioq_bcast_if`, `exu_prf_if`, `exu_lsu_if`, `exu_csr_if`, `exu_l1d_if`, `rou_cmu_if`, `rou_csr_if`, `rou_lsu_if`, `cmu_bcast_if`, `csr_bcast_if`, `lsu_l1d_if`, `l1i_bus_if`, `l1d_bus_if`), `rtl_sv/include/ysyx_rnu_internal_if.svh` (`rnu_fl_if`, `rnu_mt_if`)

## Key Commands (all from project root)

```shell
make help              # Show all targets
make verilog           # Chisel → SV decoders (output: rtl_sv/generated/)
make npc-sim           # Full pipeline: verilog + config + build + run
make npc-run ARGS="-b -n"  # Run NPC sim (batch, no wave)
make nemu-run          # Build & run NEMU reference emulator
make coremark ARGS="-b -n" # CoreMark on NPC
make lint              # Verilator lint
make sta               # Static timing analysis (Yosys + OpenSTA)
make pack              # Pack all SV into single file
```

No `source env.sh` needed - the Makefile exports all environment variables automatically.

## SystemVerilog Conventions

- **All modules/defines use `ysyx_` prefix**: `ysyx_ifu`, `ysyx_exu`, `YSYX_OP_LUI___`, `YSYX_ALU_ADD_`
- **Interfaces for inter-module signals**, named `<src>_<dst>_if` (e.g., `ifu_idu_if`, `exu_rou_if`). Modports: `master`/`slave` for request/response, `in`/`out` for broadcasts
- **Internal sub-module interfaces** in `ysyx_rnu_internal_if.svh`, named `rnu_<component>_if` (e.g., `rnu_fl_if`, `rnu_mt_if`)
- **Valid/ready handshaking** on all interfaces
- Use `logic` (not `reg`/`wire`), `always_comb`, `always_ff`, `typedef enum logic` for FSMs, `typedef struct packed` for bundles (e.g., `rob_entry_t` for ROB entries)
- **State machines**: `unique case` with named enum states (`IDLE`, `VALID`, `STALL`)
- **Sequential**: `always @(posedge clock)` with synchronous reset inside the block
- **Named port connections** only (`.port(signal)`), never positional
- RTL must be **synthesizable by Yosys** (with yosys-slang plugin)

## DPI-C & Simulation

- DPI-C calls are **macro-wrapped** (e.g., `` `YSYX_DPI_C_PMEM_READ``), defined in two variants:
  - `rtl_sv/include/dpic/ysyx_dpi_c.svh` - real calls for Verilator simulation
  - `rtl_sv/include/dpic_mock/ysyx_dpi_c.svh` - no-ops for synthesis/formal
- **Differential testing** (difftest) compares NPC vs NEMU instruction-by-instruction; enabled by default
- Simulator config uses **Kconfig** in `nsim/configs/` - profiles: `o2_defconfig` (standalone), `o2linux_defconfig`, `o2soc_defconfig`

## Chisel (Scala) - Decoder Only

`rtl_scala/src/main/scala/` generates only the instruction decoders (`ysyx_idu_decoder.sv`, `ysyx_idu_decoder_c.sv`). All other RTL is hand-written SV. Run `make verilog` to regenerate; output goes to `rtl_sv/generated/`.

## Configuration & Parameters

Microarchitecture tunables are in `rtl_sv/include/ysyx_config.svh`:
- **Cache**: `L1I_LINE_LEN` (line words), `L1I_LEN` (index bits, 2^6=64 entries), `L1D_LEN` (index bits, 2^7=128 entries)
- **BPU**: `PHT_SIZE` (512), `BTB_SIZE` (64), `RSB_SIZE` (8)
- **OoO queues**: `RIQ_SIZE` (rename queue, 4), `IIQ_SIZE` (dispatch queue, 4), `ROB_SIZE` (8), `RS_SIZE` (4), `IOQ_SIZE` (4), `SQ_SIZE` (store queue, 8)
- **Registers**: `PHY_SIZE` (64 physical), `REG_SIZE` (32 architectural)
- **Issue**: `YSYX_ISSUE_WIDTH` (1, single-issue)
- **MUL mode**: `YSYX_M_FAST` (1 = single-cycle for sim, 0 = iterative Booth's)

Interface `parameter` declarations default to these macros.

## CI / Testing

CI runs 5 parallel jobs: PPA eval (benchmarks + STA), Linux boot on NPC, ysyxSoC integration, LiteX SoC, and NEMU Linux boot. Key verification methods:
- **Difftest**: instruction-level comparison vs NEMU reference
- **Benchmarks**: CoreMark and microbench on `riscv32-npc` and `riscv32e-npc` variants
- **RISC-V Architecture Tests**: compliance suite
- **Linux boot**: end-to-end test booting Linux 6.12 via OpenSBI

## Workflow - Code & Documentation Consistency

After completing any code modification (new modules, interface changes, refactoring, parameter additions, etc.), **always** perform a final consistency check:

1. **Review changed modules/interfaces** - identify all files that were created, deleted, or modified.
2. **Update documentation** - ensure the following docs accurately reflect the changes:
   - `.github/copilot-instructions.md` - Architecture, conventions, config sections
   - `docs/uarch.md` - pipeline diagrams, module descriptions
   - `docs/README.md` - project structure, code style notes
   - `README.md` - top-level project overview (if architecture/build commands changed)
3. **Verify consistency** - confirm that module names, interface names, type names, parameter names, and file paths mentioned in documentation match the actual codebase.
4. **Run verification** - after documentation updates, run:
   - `make lint` and `make npc-run ARGS="-b -n"` to ensure nothing is broken
   - For **microarchitecture / performance-related changes**, also run `make coremark ARGS="-b -n"` and `make microbench ARGS="-b -n"`, then append a new row to `docs/perf-iterations.md` recording the commit, change description, IPC, cycle count, and stall breakdown.
