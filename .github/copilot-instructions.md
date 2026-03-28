# Raptor Chip — Copilot Instructions

Out-of-order RISC-V processor (RV32/RV64 IMAC_Zicsr_Zifencei) with register renaming, ROB, and reservation stations. Hand-written SystemVerilog RTL; Chisel (Scala) used only for decoder generation. Boots Linux v6.18 via OpenSBI.

## Quick Command Reference

All commands run from **project root**. No `source env.sh` needed — the Makefile exports everything.

```shell
make help                              # Show all targets
make setup                             # Install dependencies
make verilog                           # Chisel → SystemVerilog (rtl_sv/generated/)
make sim-npc32                         # Full pipeline: verilog → config → build → run
make run-npc32 ARGS="-b -n"            # RV32 batch, no wave trace
make run-npc64 ARGS="-b -n"            # RV64 mode (auto-invalidates build cache)
make lint                              # Verilator lint (RV32)
make lint-npc64                        # Verilator lint (RV64)
make cpu-tests-npc32 ARGS="-b -n"     # ISA compliance tests
make coremark-npc32 ARGS="-b -n"      # CoreMark benchmark
make microbench-npc32 ARGS="-b -n"    # MicroBench benchmark
make linux-boot-npc32-difftest         # Linux boot with difftest
make sta                               # Static timing analysis
make clean                             # Clean all build artifacts
```

Key overridable variables: `ARGS` (runtime), `VFLAGS` (RTL defines), `IMG` (custom binary), `MAINARGS` (benchmark mode).

## Project Layout

```
rtl_sv/                 # SystemVerilog RTL (hand-written)
  ysyx_pkg.sv           #   Types: uop_t, prd_t, rob_entry_t, rob_state_t
  ysyx.sv               #   Top-level core (pure wiring)
  include/              #   Config (ysyx_config.svh), interfaces (*_if.svh), DPI-C
  frontend/             #   IFU, IDU, BPU (PHT/BTB/GHR/RSB), CSR
  backend/              #   RNU (freelist + maptable), PRF, ROU (UOQ + ROB), EXU (RS + IOQ + ALU + MUL), CMU
  memory/               #   LSU (STQ + SQ), L1I, L1D (banked SRAM), TLB, PTW (Sv32), BUS (AXI4), CLINT
  generated/            #   Chisel-generated decoders (do not edit)
rtl_scala/              # Chisel/Scala source for decoder generation
nsim/                   # NPC Verilator simulator (C++ testbench, Kconfig)
nemu/                   # NEMU software ISS (reference model for difftest)
abstract-machine/       # AM runtime framework
am-kernels/             # Test suites (cpu-tests, alu-tests, cache-tests, am-tests, soc-tests)
nanos-lite/             # NanoS-lite simple OS
navy-apps/              # Applications for nanos-lite
linux/                  # Linux kernel build scripts + payload
fpga/                   # FPGA targets (Gowin Tang Nano 20K, LiteX)
```

## SystemVerilog Conventions

- **Module prefix**: All modules and defines use `ysyx_` prefix
- **Naming**: `ysyx_<component>` or `ysyx_<component>_<subunit>` (e.g., `ysyx_bpu`, `ysyx_bpu_btb`)
- **Types**: `typedef struct packed` with `_t` suffix (`uop_t`, `rob_entry_t`). `typedef enum` for FSMs
- **Interfaces**: `interface` with `<src>_<dst>_if` naming and `modport master/slave`
- **Signals**: `logic` only (never `reg`/`wire`). `always_comb`/`always_ff`/`always_latch` (never `always @`)
- **Ports**: Named connections only (`.port(signal)`), never positional
- **Package**: Global definitions in `ysyx_pkg` — import via `import ysyx_pkg::*`
- **Synthesizability**: RTL must be synthesizable by Yosys (with [yosys-slang](https://github.com/povik/yosys-slang))

## Architecture Essentials

- **Pipeline**: IF0 → IF1 → ID → RN → DI → IS/EX → WB → CM (8 logical stages, single-issue OoO)
- **ROB states**: `ROB_CM=2'b00` (committed/empty), `ROB_WB=2'b01` (written back), `ROB_EX=2'b10` (executing)
- **Operand forwarding priority**: PRF > IOQ > EXU
- **RV64 switch**: `-DYSYX_RV64` (SV) / `CONFIG_ISA64` (C++) / `ISA64=1` (Make). Switching auto-invalidates build cache
- **Config system**: Kconfig-based (`nsim/configs/`). Key presets: `o2_defconfig`, `o2_difftest_defconfig`, `o2linux_defconfig`
- **SRAM**: Synchronous read with write-first bypass (essential for L1I fills)
- **CSR**: Lives in `frontend/` on disk but architecturally belongs to the backend commit path

## Key Pitfalls

- **Difftest** significantly reduces simulation performance — only enable for correctness verification
- **NEMU must be built first** if using difftest (`DIFF_REF_SO` points to `nemu/build/riscv3{2,4}-nemu-interpreter-so`)
- **Build paths must not contain spaces** (GNU Make limitation)
- **Chisel elaboration** (`sbt`) can be slow; generated SV is cached in `rtl_sv/generated/`
- **Single `.config`** — can't have simultaneous RV32 and RV64 configs; rebuild to switch
- **Verilator lint warnings** for UNUSED/DECLFILENAME from generated decoders are pre-existing and expected

## Documentation

Detailed docs live in [docs/](docs/) — link to them, don't duplicate:
- [docs/uarch.md](docs/uarch.md) — Microarchitecture pipeline details
- [docs/linux_kernel.md](docs/linux_kernel.md) — Linux boot procedures
- [docs/PROFILE.md](docs/PROFILE.md) — Performance evaluation (IPC, stall breakdown, PPA)
- [docs/perf-iterations.md](docs/perf-iterations.md) — Performance tracking across commits
- [reference/memory-subsystem.md](reference/memory-subsystem.md) — Memory subsystem design
- [reference/roadmap.md](reference/roadmap.md) — Feature roadmap
