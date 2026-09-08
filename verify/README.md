# Raptor Chip: Verification Suite

新增 `make -C verify verilator-l1d-permission-stage-rv32 verilator-l1d-permission-stage-rv64`：检查加载权限阶段的 LR 外部干扰、取消和后续恢复。

M-extension privilege/edge regression: `make -C verify rva22s64-m-privileged-edges-run`
uses the configured `RVA22S64_XLEN`, `RVA22S64_NPC` and matching reference library.
Set `RVA22S64_TEST_CPPFLAGS=-DM_TEST_PRIV=0` (U), `1` (S), or `3` (M, default),
and use distinct `BUILD_DIR` values for different configurations. The test checks
literal arithmetic edge results, source/destination overlap, and RV64 word
sign extension. Three reserved OP-32 encodings exercise this platform's illegal
instruction policy, including cause, EPC, original instruction and unchanged rd.
This is directed coverage, not full M/profile acceptance.


Unified verification infrastructure for the Raptor Chip RISC-V processor.
Full-core tests use the Verilator simulator (`sim/`); differential tests use
NEMU. Module, formal, ACT4/Sail and UVM checks have separate harnesses and
references. Each target defines its own tool and configuration requirements.

Software test sources live in `app/tests/baremetal/` (freestanding RISC-V
programs and shared headers) and `app/tests/host/` (native simulator/reference
tests). Build rules, runners, linker scripts and generated vectors stay in
`verify`. C++ drivers coupled to RTL testbenches stay with their `xsim` or `vpu`
harnesses. Existing Make target names and output locations are preserved.

## Maintaining verification drivers

The PMA capability/span and instruction-word proofs use the subcommands
`pma-capabilities`, `pma-span` and `ifetch-word-atomic` of
`scripts/formal_contract.py` for execution and evidence reporting. Each entry
retains its own harness, proof command, timeout and success criterion. Include
the shared module when copying these drivers into an isolated tool bundle.
Keep scenario assertions in their individual tests; share setup and execution
only when their contracts match. Task reviews belong in local `docs.agent/`.

The maintenance inventory for `scripts`, `tests` and `experimental` is kept in
`docs.agent/evaluation/verify-artifact-inventory.md`. Scripts need a recorded
consumer; requirement tests remain separate when the RI5COF ledger names them;
experimental RTL is retained only when it has a formal/synthesis consumer or a
documented opt-in experiment.

## Parameterized test scenarios

- `tb_csr_contract.sv` shares one CSR/IEU fixture. Select `+CASE=identity_time`
  (default), `trap_storage`, `stimecmp`, `fp_aliases`, `status_fields`,
  `satp_warl`, or `tvec_routes`. Each invocation runs one scenario in a fresh
  process with its own assertions and timeout. Unknown names fail. The existing
  named CSR Make targets select the corresponding case for RV32/RV64.
- `app/tests/baremetal/zero_pma.S` tests device CBO.ZERO rejection by default;
  `PMA_READONLY=1` selects ROM/flash write protection. The existing
  `rva22s64-zero-pma-run` and `rva22s64-readonly-pma-run` targets retain separate
  images and result directories. Both scenarios include translated accesses
  and the RAM recovery/neighbor-block checks.
- `tb_l1d_pma.sv` covers the LR PMA denial and SRAM-hole load/LR/store
  scenarios. The original `verilator-l1d-lr-pma-*` targets run the default
  mode; `verilator-l1d-sram-pma-*` supplies `+SRAM`. The two targets retain
  separate output names while sharing the fixture and the bus/reservation
  assertions.
- The ten `tb_idu_*.sv` scenarios share `tb_idu_contract.sv`. Original
  top-level names and Make targets remain unchanged; the build macros read the
  shared source while elaborating only the selected top. Assertions and
  counters therefore remain isolated per scenario.
- `tb_router_clint_subword.sv` and `tb_router_clint_width.sv` share
  `tb_router_clint_contract.sv`; the original top names and targets remain
  separate, so the subword and native-width matrices still run independently.
- The issue-selection, atomic, load/store, checkpoint, prediction-history and
  LR families use one shared source per family. The original top names remain
  separate and the Make macros select the corresponding `*_contract.sv` file;
  this is source consolidation, not a reduction of scenario coverage.
- All remaining L1D, IOQ, LSU and CSR TB modules are stored in
  `tb_l1d_all_contract.sv`, `tb_ioq_all_contract.sv`,
  `tb_lsu_all_contract.sv` and `tb_csr_all_contract.sv`. The top-level module
  passed by each existing target still selects one scenario; the shared source
  is only a physical organization boundary.
- Router, PTW and SQ scenarios use the same arrangement in
  `tb_router_all_contract.sv`, `tb_ptw_all_contract.sv` and
  `tb_sq_all_contract.sv`. Existing top names continue to select one scenario
  per build.

- `tb_ioq_acquire_publish.sv` covers LR by default and AMOADD with `+AMO`;
  `+PENDING` selects response blocking. Both relaxed and acquire scenarios run
  in each invocation. Existing `verilator-ioq-acquire-publish-rv32/-rv64` and
  `verilator-ioq-amo-acquire-publish-rv32/-rv64` targets remain available; the
  AMO targets supply `+AMO`. Set `IOQ_ACQUIRE_PLUSARGS=+PENDING` as needed.
- `app/tests/baremetal/plic_access_width.S` covers loads by default and stores with
  `PLIC_WIDTH_STORE=1`. `PLIC_WIDTH_CASE=0..4` and `PLIC_WIDTH_TRANSLATED=0/1`
  retain the width and translation matrix. `scripts/plic_access_width.py`
  selects both directions and keeps separate results for each scenario.

## Quick Start

CLINT byte-address checks are available through
`rva22s64-clint-subword-run`, `rva22s64-clint-subword-write-run`,
`rva22s64-clint-subword-time-run`, and `rva22s64-clint-subword-msip-run`.
Select `RVA22S64_XLEN=32` or `64` and the matching simulator/reference paths.
Set `RVA22S64_TEST_CPPFLAGS=-DCLINT_SUBWORD_TRANSLATED=1` to exercise real
Sv32/Sv39 walks with MPRV effective S-mode. The write probe uses word reads
to check every modified and preserved byte independently of subword reads.
`verilator-router-clint-subword-rv32/-rv64` covers the real router, all
natural widths and byte offsets, masks, AW/W timing and response backpressure.

PLIC supported-access checks use `scripts/plic_access_width.py`. Supply
`--xlen 32` or `--xlen 64`, `--npc`, `--reference`, `--mrom`, and an empty
`--output` directory. Add `--translated` to exercise real Sv32/Sv39 walks
with MPRV effective S-mode; otherwise accesses use Bare mode. The runner
builds byte/halfword/FP-double rejection probes and supported word controls
for both reads and writes, checks exception addresses and subsequent device
state, and records compiler commands, inputs and six timing/seed runs per
probe. Use a reference built with the same platform width policy. These
checks do not establish the supported widths of other devices or complete
PLIC conformance; interrupt pending injection uses the platform extension.

`verilator-l1d-plic-width-rv32/-rv64` checks rejection before a device read
request, including captured split metadata. `verilator-ioq-plic-width-rv32/-rv64`
checks store rejection before SQ allocation. Their translated cases model
translation results; the core runner supplies the real page-walk coverage.

```bash
# Prerequisites: ensure simulator + NEMU are built
make -C .. build-rv32              # Build NPC simulator
make -C .. config-rv32-difftest    # Enable difftest config
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
│   ├── raptor-rv32gc/    # RV32GC test config, UDB config, model macros
│   ├── raptor-rv64gc/    # RV64 M-mode instruction projection
│   ├── raptor-rv64s/     # RV64 supervisor projection and requirement ledger
│   └── riscv-arch-test/  # ACT4 repo (cloned on setup, gitignored)
├── formal/             # Formal verification (SymbiYosys)
│   ├── rvfi/             # Raptor riscv-formal config (project-owned)
│   │   ├── checks.cfg     # riscv-formal check configuration
│   │   └── wrapper.sv     # RVFI wrapper with unconstrained AXI4
│   ├── riscv-formal/     # riscv-formal repo (auto-cloned, gitignored)
│   ├── bus.sby           # AXI bus formal property
│   └── ieu_mul.sby       # IEU multiplier formal property
├── xsim/               # Module-level SystemVerilog testbenches
│   └── fpu/              # Verilator FPU arithmetic/conversion tests
└── build/              # Generated artifacts (gitignored)
```

## RTL Unit Tests

Component-level FPU tests are grouped with the existing module-level
testbenches below `xsim/fpu/`. These FPU tests use Verilator because their
differential harnesses include C++ host reference models.

```bash
make unit-fpu                    # Run all FPU component tests
make unit-fpu-fma                # Run one directed component regression
make unit-fpu-mul MUL_N=1000000  # Override a random test count
make unit-fpu-convert CONVERT_N=1000000
```

## In-RTL Assertions (SVA)

Raptor ships inline SVA guarded by `RAPT_ASSERT_EN` for zero default overhead.
The assertion macros (`RAPT_SVA`, `RAPT_SVA_IMPLY`, `RAPT_SVA_NEXT`, `RAPT_COVER`, ...)
are defined in [hdl/include/rapt_sva.svh](../hdl/include/rapt_sva.svh) and
auto-included via `rapt.svh`.

```shell
# Enable assertions for any simulation target
make sim-rv32                VFLAGS="-DRAPT_ASSERT_EN"
make microbench-random-rv32 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42 VFLAGS="-DRAPT_ASSERT_EN"
make cpu-tests-rv32 ARGS="-b -n" VFLAGS="-DRAPT_ASSERT_EN"
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
Sail as the reference model. The default `raptor-rv32gc` profile covers the
RV32 I/M/A/F/D/C extensions, including Zcf/Zcd compressed floating-point
loads and stores, together with the implemented Z* extensions.

**First-time setup:**
```bash
make riscof-setup         # Clone ACT4 repo + check prerequisites (sail, uv)
make riscof-gen           # Generate self-checking ELFs
make riscof-run           # Execute tests on NPC
```

ACT4 uses a 60-second per-ELF **wall-clock** timeout (`ACT4_TIMEOUT`), separate
from the generic 10-second unit-test default. Large floating-point ELFs can
take longer than 10 seconds even without contention. For busy hosts, use
`make riscof-run JOBS=4 ACT4_TIMEOUT=120`. Explicit legacy `TIMEOUT` overrides
remain honored unless `ACT4_TIMEOUT` is supplied. Timeout logs retain the
command, elapsed time and captured output; a timeout always counts as failure,
even if partial output contains a PASS line.

Requires Sail RISC-V 0.13.1 and `uv` (Python package manager). Install the
official Linux x86_64 release in the default project location with:

```bash
mkdir -p "$HOME/.local/opt/sail-riscv-0.13.1"
curl --fail --location \
  https://github.com/riscv/sail-riscv/releases/download/0.13.1/sail-riscv-Linux-x86_64.tar.gz \
  | tar -xz -C "$HOME/.local/opt/sail-riscv-0.13.1" --strip-components=1
ln -sfn "$HOME/.local/opt/sail-riscv-0.13.1/bin/sail_riscv_sim" \
  "$HOME/.local/bin/sail_riscv_sim"
sail_riscv_sim --version
```

Both ACT4 and classic RISCOF validate the exact Sail version before running.

Classic RTL RISCOF (`make -C verify riscof-classic`) uses a separate
`RISCOF_CLASSIC_TIMEOUT=600` second wall-clock budget per DUT test. Large F/D
vectors can exceed the generic 10-second smoke-test budget, especially with
parallel jobs. Explicit `TIMEOUT` overrides are still honored unless
`RISCOF_CLASSIC_TIMEOUT` is supplied. For example:

```bash
make -C verify riscof-classic JOBS=4 RISCOF_CLASSIC_TIMEOUT=600
verify/build/riscof-classic-venv/bin/python verify/scripts/test_riscof_classic_runner.py
```

The classic Sail plugin uses `raptor.json` to check page-local misaligned
accesses as a whole before splitting, matching Raptor's PMP policy. It keeps
Sail 0.13.1's ROM/IO/RAM regions but disables its default MAG and Zama16b
declaration; otherwise the RAM MAG overrides the page-local split setting. The
`pmpm_misaligned_{na4,napot,tor}` tests use a 16-byte region offset on both
DUT and reference: this retains the PMP crossings while separating them from
Sail's mandatory page split. These tests remain in the comparison; cross-page
behavior is covered separately by the split-page and PMP span regressions.

Each test's `dut/` directory retains `dut.log` and `dut-run.json`. Only a
successful simulator termination with a complete, well-formed signature is
passed to the signature comparison. On execution failure, partial output is
kept as `*.signature.partial` and the comparison signature is empty so the test
still fails. This distinguishes execution timeouts from completed architectural
mismatches; it does not suppress either failure or change the test selection.

### 4. RISCV-DV Privileged Stress (`make riscv-dv`)

Uses the upstream [chipsalliance/riscv-dv](https://github.com/chipsalliance/riscv-dv)
pure-Python generator with a Raptor RV32IMC M-mode target. Generated binaries
run on NPC with NEMU instruction-by-instruction difftest; no commercial UVM
simulator is needed for M-mode CSR and trap-handler stress.
This riscv-dv target is an IMAC smoke configuration and does not represent the
full implemented ISA; use the ACT4 RV32GC profile, the RISCOF classic profile,
and `app/tests/fp` for broader architectural and F/D coverage.

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

Uses [SymbiYosys](https://github.com/YosysHQ/sby) for symbolic equivalence,
k-induction, cover reachability, and bounded model checking. Runs from the
`formal/` subdirectory.

**Setup:**
```bash
make -C formal setup      # Download oss-cad-suite (yosys, sby, solvers)
```

**Standalone property checks:**
```bash
make -C formal formal_bus       # AXI bus protocol properties
make -C formal formal_ieu_alu   # RV32 ALU + Zb*/Zicond equivalence
make -C formal formal_ieu_mul   # Multiplier correctness properties
make -C formal formal_pmp       # RV32/RV64 PMP priority and permissions
make -C formal formal_plru      # 2/4/8-way replacement + invalid priority
make -C formal formal_rnu_maptable # MAP/RAT WAW priority + flush recovery
make -C formal formal_clint     # CLINT timer/register/interrupt semantics
make -C formal formal_plic      # PLIC priority/context/gateway lifecycle
make -C formal formal_dtm       # Single-clock JTAG TAP + DMI transport
make -C formal formal_divsqrt   # FPU div/sqrt control, flush, and liveness
make -C formal all              # All standalone checks above
```

The ALU proof is exhaustive over symbolic RV32 operands for all non-CLMUL
operations. CLMUL and CLMULR are also exhaustive; CLMULH exhaustively proves
all polynomial basis terms (the implementation is their linear XOR
accumulation). PLRU, maptable, CLINT, and PLIC use k-induction and include
reachable cover witnesses. CLINT checks RV32/RV64 plus divider-bypass and
divided timer paths. PLIC uses k-induction for reduced RV32/RV64 geometries and
a four-cycle BMC on the production RV32 geometry (31 sources, two contexts).
Its lifecycle covers use three symbolic sources and two contexts to preserve
arbitration ties, M/S interrupt routing, and claim/complete behavior while
keeping witnesses short. The bus check explores 12 cycles of arbitrary
backpressure, while div/sqrt explores 70 cycles to exceed the longest iterative
operation.

The DTM proof covers the implemented single-clock simulation transport: all 16
TAP states, IR/DR shifting, IDCODE/DTMCS capture, and DMI request/response
sequencing. CDC, busy/sticky status, and reset side effects remain explicitly
outside `rapt_dtm`'s current implementation contract.

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

Stages the upstream GDB-driven debug-spec suite; `debug-tests` remains an
explicit nonzero-exit stub. The remote-bitbang bridge, drained-core halt/resume
and 32-bit abstract GPR/selected-CSR access already exist. Debug CSR storage
is DM-local, and commit-based stepping is a bring-up mechanism. Full Debug
Mode entry/return, memory access/SBA, program-buffer execution and 64-bit
abstract transfers remain unsupported. See [JTAG verification](jtag/README.md)
for the implemented `openocd-halt-reg` and `gdb-smoke` entry points.

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
current environment coverage. The former standalone verification plan is not
distributed here; executable targets in [Makefile](Makefile) define the
available checks.

## Linux milestones

The RV32 Linux CI job explicitly uses `--success-marker "Linux version"`: it
checks kernel entry and the runner's failure diagnostics. It does not require
userspace startup. From the root, `make verify-linux-boot-rv32` instead requires
`Run /init as init process`. Memory-stress targets use their separately
configured milestone; none of these alone certifies a profile or OS stability.

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

M decoder enumeration: `make -C verify verilator-idu-m-encodings-rv32`
and `verilator-idu-m-encodings-rv64` exercise every rd/rs1/rs2 tuple in
funct7=1 OP/OP-32 across M/S/U. RV32 also sweeps OP-32/OP-IMM-32 funct7,
funct3 and correlated register fields. The latter is not a Cartesian register
sweep. `scripts/m_elf_coverage.py --elf-dir <M-ELFs> --output <JSON>` records
static instruction and register coverage separately from execution results.

The M privilege/edge test also rejects all five RV64 M word operations in RV32,
checking their precise illegal-instruction trap and preserved destination.

`rva22s64-bit-xlen-legality-run` checks native REV8 and highest-bit BSETI,
then traps on selected XLEN-incompatible shift/REV8 encodings. Use
`RVA22S64_TEST_CPPFLAGS=-DBIT_TEST_PRIV=0`, `1`, or `3` for U/S/M.
`verilator-idu-bit-immediates-rv32` / `-rv64` enumerate eight immediate
families, every 6-bit shift and rd/rs1 combination, plus both REV8 encodings,
in M/S/U. A reference with the RV32 shift-immediate matching fix is required.

`verilator-bit-decode-alu-rv32` / `-rv64` assemble deterministic Zba/Zbb/Zbs
vectors and compare the real decoder+ALU against independent Python integer
expectations in M/S/U. The vector manifest records the seed, compiler command,
operands and expected results; it is not an exhaustive operand proof.

`rva22s64-zexth-xlen-run` checks native ZEXT.H, all eight C.ZEXT.H register
encodings, and the unimplemented other-XLEN native encoding with precise
cause/EPC/tval, preserved destination and trap return. Set `RVA22S64_XLEN`
to 32 or 64 and `RVA22S64_TEST_CPPFLAGS=-DZEXTH_TEST_PRIV=0`, `1`, or `3`
for U/S/M; provide the frozen NPC and matching reference as for other runners.
`verilator-zexth-decode-alu-rv32` / `-rv64` exercise the real decoder and ALU:
all 65,536 low-halfword values with upper bits set, both native/compressed
forms, every native rd/rs1 pair and all compressed short registers in M/S/U.
Each XLEN checks 399,384 cases. This is bounded operand coverage; rejecting
the counterpart encoding is the selected platform's unimplemented-encoding
policy. C.ZEXT.H interaction coverage does not add Zcb to RVA22's mandatory set.

`verilator-compressed-register-legality-rv32` / `-rv64` check every register and
immediate field of C.LWSP, C.LDSP/C.FLWSP and C.ADDIW/C.JAL, plus every C.JR
register in M/S/U: 18,528 cases per XLEN. Reserved integer zero-register forms
must report illegal instruction with the raw lower parcel as tval; RV32 C.FLWSP
f0 and overlapping C.JAL remain legal. FP state is enabled in this module test.
`rva22s64-compressed-register-legality-run` exercises representative illegal
forms and legal controls on a frozen core. Select `RVA22S64_XLEN=32` or `64`
and `RVA22S64_TEST_CPPFLAGS=-DC_REGISTER_TEST_PRIV=0`, `1`, or `3` for U/S/M;
the reference must include the compressed zero-register legality repair.
These tests cover the selected platform policy, not all compressed encodings.

`verilator-compressed-zero-immediate-rv32` / `-rv64` enumerate all immediate
and register fields of C.ADDI4SPN and C.LUI/C.ADDI16SP in M/S/U: 12,288 checks
per XLEN. Zero immediates are rejected except the eight existing C.MOP.n
encodings (odd n in 1..15); nonzero-immediate C.LUI x0 HINTs remain valid.
MOP/HINT checks also require no architectural destination. The core target
`rva22s64-compressed-zero-immediate-run` tests all 32 reserved zero-immediate
forms, all eight C.MOP.n controls, HINTs and representative legal arithmetic.
Set `RVA22S64_TEST_CPPFLAGS=-DC_IMMEDIATE_TEST_PRIV=0`, `1`, or `3`, with the
selected XLEN, frozen NPC and corrected reference. Zcmop remains an existing
extra implementation; these checks do not make it mandatory for RVA22.
