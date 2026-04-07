# Raptor Chip — Verification Suite

Unified verification infrastructure for the Raptor Chip RISC-V processor.
**Zero RTL modifications required** — all tools reuse the existing Verilator
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
└── build/              # Generated artifacts (gitignored)
```

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

## Integration with Root Makefile

From the project root:
```bash
make verify-fuzz          # Shortcut for verify/ fuzz
make verify-sigtest       # Shortcut for verify/ sigtest
make verify-all           # Run all verify targets
```

## RV64 Support

All tools support RV64 via `ISA=rv64`:
```bash
make fuzz ISA=rv64
make sigtest ISA=rv64
```

This automatically sets the correct march/mabi and passes `-DYSYX_RV64` to
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
