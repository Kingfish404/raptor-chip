# Raptor Chip: Verification Suite

Unified verification infrastructure for the Raptor Chip RISC-V processor.
**Zero RTL modifications required**: all tools reuse the existing Verilator
simulator (`nsim/`) and NEMU difftest reference model.

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
make coverage                       # Verilator line/toggle coverage
```

## Directory Structure

```
verify/
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
are defined in [rtl_sv/include/rapt_sva.svh](../rtl_sv/include/rapt_sva.svh) and
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

### 4. Verilator Coverage (`make coverage`)

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
exposes RVFI signals through `rtl_sv/backend/rapt_rvfi.sv` (enabled by
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
