# Raptor Chip: Verification Suite

Unified verification infrastructure for the Raptor Chip RISC-V processor.
**Zero RTL modifications required**: all tools reuse the existing Verilator
simulator (`sim/`) and NEMU difftest reference model.

## Quick Start

```bash
# Prerequisites: ensure simulator + NEMU are built
make -C .. build-npc32              # Build NPC simulator
make -C .. config-npc32-difftest    # Enable difftest config
make -C .. config-nemu32-ref        # Build NEMU reference SO

# Run all lightweight tests
make all                            # fuzz + sigtest

# Individual targets
make fuzz                           # Random instruction fuzzing
make sigtest                        # Signature-based ISA corner-case tests
make riscof                         # ACT4 official compliance tests (Sail reference)
make riscv-dv                       # riscv-dv M-mode privileged smoke
make riscv-dv-stress                # riscv-dv exception stress
make coverage                       # Verilator line/toggle coverage
```

## Directory Structure

```
verify/
├── uvm/                # Module-level UVM agents, scoreboards, and test plan
│   └── iq/               # Issue-queue UVM environment
├── scripts/            # Test generation and orchestration scripts
├── riscof/             # ACT4 compliance testing
│   ├── raptor-rv32imac/  # RV32 test config, UDB config, model macros
│   └── riscv-arch-test/  # ACT4 repo (cloned on setup, gitignored)
├── formal/             # Formal verification (SymbiYosys)
│   ├── rvfi/             # Raptor riscv-formal config (project-owned)
│   │   ├── checks.cfg     # riscv-formal check configuration
│   │   └── wrapper.sv     # RVFI wrapper with unconstrained AXI4
│   ├── riscv-formal/     # riscv-formal repo (auto-cloned, gitignored)
│   ├── bus.sby           # AXI bus formal property
│   └── exu_mul.sby       # Multiplier formal property
└── build/              # Generated artifacts (gitignored)
```

## In-RTL Assertions (SVA)

Raptor ships inline SVA guarded by `RAPT_ASSERT_EN` for zero default overhead.
The assertion macros (`RAPT_SVA`, `RAPT_SVA_IMPLY`, `RAPT_SVA_NEXT`, `RAPT_COVER`, ...)
are defined in [hdl/include/rapt_sva.svh](../hdl/include/rapt_sva.svh) and
auto-included via `rapt.svh`.

```shell
# Enable assertions for any simulation target
make sim-npc32                VFLAGS="-DRAPT_ASSERT_EN"
make microbench-ysyxsoc       VFLAGS="-DRAPT_ASSERT_EN"
make cpu-tests-npc32 ARGS="-b -n" VFLAGS="-DRAPT_ASSERT_EN"
```

Failure format: `[<time>] SVA FAIL: <hier>.<LABEL> (<ante>) |-> (<cons>)`
followed by `$fatal`.

## Verification Methods

### 1. Random Instruction Fuzzing (`make fuzz`)

Generates random legal RV32/RV64 IMAC instruction sequences, compiles them
as bare-metal programs, and runs each with difftest (NPC vs NEMU).

**Configuration:**
```bash
make fuzz SEED=42         # Reproducible seed
make fuzz FUZZ_NUM=100    # Generate 100 programs
make fuzz FUZZ_LEN=500    # 500 instructions each
make fuzz ISA=rv64        # RV64 mode
```

**Instruction mix:** ALU (45%), M-extension (15%), Load/Store (25%),
Branch (10%), LUI/AUIPC (5%).

**What it catches:** RAW/WAW/WAR hazards in OoO pipeline, operand bypass
errors, branch misprediction recovery bugs, M-extension corner cases (div-by-zero,
overflow), load/store alignment issues.

### 2. Signature-based ISA Tests (`make sigtest`)

Deterministic tests targeting known ISA corner cases:

- **alu_r_type**: All R-type ALU ops with boundary values (0, -1, INT_MAX, INT_MIN)
- **alu_i_type**: I-type ops with extreme immediates
- **mul_div**: M-extension with div-by-zero, overflow, signed/unsigned edge cases
- **branch**: All 6 branch types with signed/unsigned boundary comparisons
- **mem_ops**: Load/store round-trip at byte/half/word granularity

Each test stores results to a signature region. Difftest catches any
deviation between NPC and NEMU.

### 3. ACT4 Compliance (`make riscof`)

[ACT4](https://github.com/riscv-non-isa/riscv-arch-test) (riscv-arch-test act4
branch) is the RISC-V official architectural certification framework using
Sail as the reference model.

**First-time setup:**
```bash
make riscof-setup         # Clone ACT4 repo + check prerequisites (sail, uv)
make riscof-gen           # Generate self-checking ELFs
make riscof-run           # Execute tests on NPC
```

Requires `sail_riscv_sim` and `uv` (Python package manager).

### 4. RISCV-DV Privileged Stress (`make riscv-dv`)

Uses the upstream [chipsalliance/riscv-dv](https://github.com/chipsalliance/riscv-dv)
pure-Python generator with a Raptor RV32IMC M-mode target. Generated binaries
run on NPC with NEMU instruction-by-instruction difftest; no commercial UVM
simulator is needed for M-mode CSR and trap-handler stress.

```bash
make riscv-dv                         # one short privileged smoke test
make riscv-dv-stress                  # illegal-instruction exception stress
make riscv-dv-gen RISCV_DV_TEST=raptor_exception_stress RISCV_DV_SEED=42
make riscv-dv-run RISCV_DV_TEST=raptor_exception_stress
```

Memory timing is a separate, reproducible verification dimension. NPC samples
a uniform `0..N` cycle delay independently for every AXI memory beat. The smoke
suite defaults to maxima `0 7 31 63 233` with memory seed `1`; the stress target
uses memory seeds `1 42 31337`, producing a full delay-by-seed matrix. Generator
seed and memory-delay seed are intentionally independent.

The default delay maxima represent distinct operating conditions:

- `0`: deterministic zero-wait baseline and regression comparison.
- `7`: short SRAM/cache/interconnect jitter.
- `31`: moderate cache-miss and shared-fabric latency.
- `63`: sustained contention and long external-memory responses.
- `233`: extreme backpressure, matching the existing real-system stress setup.

```bash
# Reproduce one timing coordinate exactly.
make riscv-dv-run RISCV_DV_TEST=raptor_exception_stress \
  RISCV_DV_MEM_DELAYS=233 RISCV_DV_MEM_SEEDS=1

# Customize the matrix.
make riscv-dv-run RISCV_DV_MEM_DELAYS="0 3 15 63 233" \
  RISCV_DV_MEM_SEEDS="1 42 31337"
```

Each coordinate writes `*.delayN-seedS.run.log` next to its generated binary,
so failures retain the exact timing rule needed for replay.

The pyflow backend cannot currently generate random exceptions reliably: its
EBREAK templates are unregistered, subprogram callstack state is uninitialized,
and illegal-instruction constraints fail to solve. The exception stress target
therefore uses pyflow's generated M-mode trap harness and long random stream,
then injects 256 register-free `0xffffffff` illegal instructions at `main`.
This exercises `mcause`/`mepc`, trap-frame save/restore, and `mret` without
depending on those broken upstream paths.

The first run clones pinned revision `b7a0b4b0b51346a3c64f159f81ea262d867c14a9`
and creates an isolated Python 3.11 environment under `verify/build/`.
Python 3.10-3.12 is required because the upstream `pyvsc` dependency does not
currently build on Python 3.14.

The upstream Python backend does not implement page-table creation, page-table
sections, or page-fault handlers (these functions are `TODO` in
`pygen/pygen_src/riscv_asm_program_gen.py`). Run `make riscv-dv-mmu` for a
fail-fast capability check. Full Sv32/MMU generation requires riscv-dv's
SV/UVM backend and one of its supported simulators (VCS, Questa, Xcelium, or
Riviera-PRO); none is installed in the current open-source tool environment.

### 5. Verilator Coverage (`make coverage`)

Collects line and toggle coverage during simulation.

```bash
make coverage-build       # Rebuild NPC with --coverage
make coverage-run         # Run tests to collect data
make coverage-report      # Generate annotated source report
```

**Note:** Coverage build uses Verilator's
`--coverage --coverage-line --coverage-toggle` flags (with `-Wno-UNOPTFLAT`
for this mode). `coverage-run` drives the instrumented NPC using
`fuzz + sigtest` workloads from this `verify/` suite (to avoid non-coverage
rebuilds from root targets). Coverage data is written to `coverage.dat` on
simulator exit and then merged/reported via `verilator_coverage`.

### 5. Formal Verification (`make -C formal`)

Uses [SymbiYosys](https://github.com/YosysHQ/sby) for bounded model checking.
Runs from the `formal/` subdirectory.

**Setup:**
```bash
make -C formal setup      # Download oss-cad-suite (yosys, sby, solvers)
```

**Standalone property checks:**
```bash
make -C formal formal_bus       # AXI bus protocol properties
make -C formal formal_exu_mul   # Multiplier correctness properties
```

#### riscv-formal (RVFI)

[riscv-formal](https://github.com/YosysHQ/riscv-formal) performs per-instruction
formal verification via the RVFI (RISC-V Formal Interface). The Raptor core
exposes RVFI signals through `hdl/backend/rapt_rvfi.sv` (enabled by
`-DRAPT_RVFI`), with NRET=2 for dual-commit.

The riscv-formal repository is **auto-cloned** on first use. Project-owned
configuration lives in `formal/rvfi/` (tracked in git); the cloned repo is
gitignored.

**150 checks** are generated covering RV32IMC instructions (70 insns × 2
channels) plus consistency checks (reg, pc_fwd, pc_bwd, unique, causal).

```bash
# Generate checks (auto-clones riscv-formal if needed)
make -C formal formal_rvfi_gen

# Run a single check
make -C formal formal_rvfi_check CHECK=insn_add_ch0

# Run all 150 checks in parallel
make -C formal formal_rvfi

# Clean generated artifacts
make -C formal formal_rvfi_clean
```

**Engine:** Uses `abc bmc3` (AIGER-based BMC) instead of SMT-based solvers to
avoid a false-positive combinational loop detection in the `write_smt2` backend.
Each check takes ~70 seconds with depth 5.

**Configuration files** (`formal/rvfi/`):
- `checks.cfg` — ISA, nret, solver, depth, yosys-slang script
- `wrapper.sv` — Instantiates `rapt` with unconstrained AXI4 responses via
  `rvformal_rand_reg`, exposing only RVFI outputs to the testbench

### 6. JTAG / RISC-V Debug Verification (`make jtag`)

Two-layer verification of the `rapt_dtm` + `rapt_dm` blocks introduced for
the JTAG / RISC-V Debug Spec 1.0 implementation. Lives in
[verify/jtag/](./jtag/README.md) for full details.

**Layer 1 — in-tree compliance probe (runs today):**

```bash
make jtag-selftest        # 23-point DTM/DM compliance probe (no NEMU)
```

Drives JTAG TCK/TMS/TDI directly into the Verilator-built RTL (no GDB / no
OpenOCD) and exercises three phases: TAP/IR (IDCODE, BYPASS identity, DTMCS
fields, soft-TLR), DM register file (dmcontrol RW + dmactive=0 quiesce,
dmstatus, hartinfo, data0 RW, abstractcs static fields), abstract-command
semantics (cmderr=2 on unsupported, W1C clear, dropped while !dmactive).

**Layer 2 — upstream `riscv-tests/debug` (P1-blocked stub):**

```bash
make jtag-debug-tests-setup   # Clones riscv-software-src/riscv-tests
make jtag-debug-tests         # Currently exits 1 with checklist
```

Stages the upstream GDB-driven debug-spec suite. The actual run is gated on
(a) an OpenOCD `remote_bitbang` DPI bridge in `sim/`, (b) halt/resume +
dcsr/dpc CSRs in the core, (c) abstract `access_register`/`access_memory`
in `rapt_dm`. None of these exists yet — the target prints the gap list and
exits non-zero rather than silently passing. OpenOCD config scaffold lives
at [verify/jtag/openocd.cfg](./jtag/openocd.cfg).

### 7. Module-level UVM (`make uvm`)

The module-level layer targets local ordering and protocol bugs that are hard
to diagnose through full-core software alone. The first environment covers the
out-of-order issue queue with an independent age/operand reference model,
directed fast-load tests, randomized CDB/dispatch/flush stimulus, a scoreboard,
coverage counters, and inline SVA.

```bash
make uvm-smoke       # Run the simulator's minimal UVM 1.2 runtime check
make uvm-iq-compile  # Compile the complete issue-queue UVM environment
```

See [uvm/README.md](./uvm/README.md) for the installed XSim limitation and
[uvm/VERIFICATION_PLAN.md](./uvm/VERIFICATION_PLAN.md) for the P0-P2 module
matrix and closure criteria.

## Integration with Root Makefile

From the project root:
```bash
make verify-fuzz          # Shortcut for fuzz
make verify-sigtest       # Shortcut for sigtest
make verify-all           # Run all verify targets
```

## RV64 Support

All tools support RV64 via `ISA=rv64`:
```bash
make fuzz ISA=rv64
make sigtest ISA=rv64
```

This automatically sets the correct march/mabi and passes `-DRAPT_RV64` to
the build system.

## Adding New Tests

### Custom fuzz profiles
Edit `scripts/riscv_fuzz_gen.py` to adjust:
- Instruction weights (the `categories` list)
- Register usage patterns
- Immediate value ranges
- Add new instruction categories (e.g., A-extension AMO ops)

### Custom signature tests
Add generator functions in `scripts/gen_sigtests.py`:
```python
def gen_my_test(xlen):
    asm = [...]  # Assembly lines
    return [("my_test_name", "\n".join(asm))]
```
Then add to `main()`:
```python
all_tests.extend(gen_my_test(args.xlen))
```
