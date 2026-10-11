# Raptor Chip: Verification Suite

新增 `make -C verify verilator-l1d-permission-stage-rv32 verilator-l1d-permission-stage-rv64`：检查加载权限阶段的 LR 外部干扰、取消和后续恢复。

M-extension privilege/edge regression: `make -C verify rva22s64-m-privileged-edges-run` uses the configured `RVA22S64_XLEN`, `RVA22S64_NPC` and matching reference library. Set `RVA22S64_TEST_CPPFLAGS=-DM_TEST_PRIV=0` (U), `1` (S), or `3` (M, default), and use distinct `BUILD_DIR` values for different configurations. The test checks literal arithmetic edge results, source/destination overlap, and RV64 word sign extension. Three reserved OP-32 encodings exercise this platform's illegal instruction policy, including cause, EPC, original instruction and unchanged rd. This is directed coverage, not full M/profile acceptance.


Unified verification infrastructure for the Raptor Chip RISC-V processor. Full-core tests use the Verilator simulator (`sim/`); differential tests use NEMU. Module, formal, ACT4/Sail and UVM checks have separate harnesses and references. Each target defines its own tool and configuration requirements.

Software test sources live in `app/tests/baremetal/` (freestanding RISC-V programs and shared headers) and `app/tests/host/` (native simulator/reference tests). Build rules, runners, linker scripts and generated vectors stay in `verify`. C++ drivers coupled to RTL testbenches stay with their `xsim` or `vpu` harnesses. Use the current targets below; simulator and STA artifacts follow the profile-isolation rules in `sim/README.md`.

## Maintaining verification drivers

`make -C verify config-macro-check` audits unused/undefined preset macros and exactly one direction predictor; it also runs in `script-unittests`.
`make -C verify bpu-config-check` additionally elaborates all four direction
predictors in RV32/RV64 and verifies that a missing selection fails in both
Verilator and Slang, including Verilator's `-Wno-fatal` mode.

Directed module rules name only their testbench top and any non-RTL helpers. RTL resolves by module name: `rapt_pkg.sv` compiles first and every other `hdl/` file is a Verilator `-v` library (`XSIM_RTL_LIBRARY`; the xsim flow compiles `XSIM_RTL_ALL`). Adding, splitting or renaming RTL therefore needs no rule edits, and testbench stubs take precedence over library modules. All rules share `VERILATOR_DIRECTED_FLAGS` (warnings are not fatal; `make lint` owns lint); a rule appends only what it needs, such as `-G` parameters or `-CFLAGS -O0`. Guest programs compile with `GUEST_CPPFLAGS` (script runners through the exported `CPATH`) and take platform addresses from `app/lib/raptor_platform.h`. The RVA22S64 directed programs are one `RVA22S64_CASES` table (`RVA22S64_RV64_CASES` marks RV64-only sources); `make -C verify rva22s64-directed RVA22S64_XLEN=32|64 RVA22S64_NPC=...` runs them all; RVA22S64 and SQ-checkpoint targets pick the MROM from their own XLEN, so `ISA` need not match.

New directed module checks that run in both XLEN modes should be one `verilator-<name>-rv32 verilator-<name>-rv64` rule using `VERILATOR_DIRECTED_XLEN_RUN`. The target name selects `RAPT_RV64` and the build stem, so the two modes cannot drift apart. `make -C verify script-unittests` runs tool-free helper-script unit tests that have no dedicated check target.

`make -C verify sim-build-isolation-check` tests build-local simulator Kconfig and option-keyed caches. See [simulator configuration and parallel builds](../sim/README.md) for profile selection, cache reuse, and remaining NEMU/tool concurrency limits.

`make -C verify yosys-sq-span-equivalence` uses Yosys SAT to prove the actual SQ address-span helper against full-width modular subtraction for RV32/RV64. Addresses, both two-bit spans and the page-offset-only selector are unconstrained; page and XLEN wrap are included. The proof adapter extracts the RTL helper and translates its single return to a function-result assignment for Yosys. This is a combinational helper proof, not a full SQ lifecycle proof or FPGA STA.

`make -C verify verilator-sq-forward-ring-rv32 verilator-sq-forward-ring-rv64` checks SQ forwarding at 2/4/16/32 entries and one/three load ports. It exhausts all valid masks at every head through 16 entries, checks every single/pair at 32 entries, and runs a seeded byte-enumerated alias oracle with partial stores, stale translation contexts, page/address wrap, FP64 spans, pending allocation and CBO.ZERO. Data is checked even when forwarding is blocked. The existing `verilator-sq-forward-ports` / `verilator-sq-forward-ports-rv64` targets provide additional directed span checks. These are behavioral tests, not a formal equivalence proof or whole-chip FPGA timing acceptance.

`make -C verify verilator-btb-storage-rv32 verilator-btb-storage-rv64` checks two-way BTB storage against a transaction-level reference at three set counts, including the default and a non-power-of-two depth. It exercises simultaneous reads/writes, updates while the read address is held, matching and missing type-only writes, LRU replacement, and reset/init priority. The read latency and write-visible behavior must remain unchanged when the payload arrays infer distributed RAM. These are behavioral checks, not a guarantee of RAM inference or whole-chip FPGA timing.

Binary16 conversion checks use `make -C verify/xsim/fpu/half run flush`. Use separate absolute `BUILD_DIR` paths with `XLEN=32` and `XLEN=64` to avoid stale tool-version caches. `run-softfloat SOFTFLOAT_DIR=/absolute/path` expects `include/softfloat.h` and a built `softfloat.a` in that directory. The reference test covers five rounding modes, every finite source exponent, sparse/dense and random source subnormals, normal/subnormal rounding boundaries, overflow and exception flags. These are component checks, not full-core or FPGA timing acceptance.

`make -C verify verilator-completion-stage-rv32 verilator-completion-stage-rv64` checks the accepted-completion register with distinct full-width packets on every port, sustained traffic, bubbles, repeated flushes and midstream resets. It also exercises each instance's packet-history assertion. These local checks do not replace full-core fast-load/FP/recovery differential tests or FPGA STA.

`make -C verify verilator-cbo-set-rv32 verilator-cbo-set-rv64` checks CBO set scope across every resident word/way, VA page aliases, pending refill cancellation, and retained global maintenance. Repeat with `XSIM_RAPT_CONFIG=small` to check a 64-byte CBO spanning four 16-byte cache lines. `verilator-cbo-tlb-rv32` / `verilator-cbo-tlb-rv64` use real Sv32/Sv39 PTW fills and verify that CBO preserves both DTLB replicas. The ROU dual-commit tests also cover CBO SQ drain, completion generation, fault/wrong-path suppression and ZERO retirement; UVM `memory` and `mmu` exercise decoded CBOs through the complete core.

`make -C verify verilator-ifu-response-stage-rv32 verilator-ifu-response-stage-rv64` checks response capture, sustained delivery, mixed 16/32-bit instruction streams, branch/history event conservation, randomized cache availability and downstream backpressure, fault metadata stability, and recovery with both IFU buffers full. It also checks that a buffered response blocks instruction IO authorization when successive dynamic requests have the same PC. The address-driven scoreboard supports width overrides and `RAPT_FETCH_RESPONSE_STAGE=0` comparisons.

`make -C verify verilator-iq-deferred-reclaim-rv32 verilator-iq-deferred-reclaim-rv64` checks registered vacancy admission with randomized allocation, wakeup, issue and flush. It rejects same-edge reuse of a resident issue slot. This is the integrated `rapt_iq` mode (`ReclaimOnIssue=0`) for every preset; the other reclaim tests exercise the module's optional same-edge mode (`ReclaimOnIssue=1`).

`make -C verify verilator-hum-request-stage-rv32 verilator-hum-request-stage-rv64` checks the registered hit-under-miss B request with the default preset (`XSIM_RAPT_CONFIG=default`, HUM enabled). It covers capture latency, payload and owner stability while an older candidate wakes, simultaneous A/B responses, flush/late response rejection, fallback after A completes, and FLD fallback through A with a full 64-bit FPR write. These are IOQ contract tests, not Linux or FPGA timing acceptance.

Translated MMIO replay regressions use `make -C verify` with these RV32/RV64 pairs:

- `verilator-ioq-mmio-retry-rv32` / `-rv64`: younger request deferral, older load progress, and replay only after both IOQ and ROB heads reach the owner.
- `verilator-translated-mmio-retry-rv32` / `-rv64`: real IOQ/SQ/L1D and Sv32/Sv39 walks, delayed responses, no speculative device read, and exactly one ordered device read. The resulting `tb_translated_mmio_retry` binary also accepts `+FLUSH_RETRY` and `+FLUSH_DEFERRED` for retry/flush collision and deferred-owner cancellation checks.
- `verilator-split-load-retry-rv32` / `-rv64`: retry at every LW/FLD split beat, including RV32's third beat, an intervening aligned load, and fresh merged data.

These tests cover the retry contract, not FPGA timing or Linux networking acceptance.

`make -C verify verilator-l1i-access-sizes-rv32 verilator-l1i-access-sizes-rv64` compares the fixed 2/4-byte fetch permission checks and late result select with the original dynamic-size PMP interface. Each XLEN checks 20,000 cases with fixed seed `9e3779b9`, both lookahead settings, all SRAM-ready/instruction-length combinations, boundary addresses, fault ownership, and unchanged PTW/PTE checks. This is combinational equivalence regression coverage, not a timing benchmark or a formal proof. The targets are also part of `verilator-directed`.

The PMA capability/span and instruction-word proofs use the subcommands `pma-capabilities`, `pma-span` and `ifetch-word-atomic` of `scripts/formal_contract.py` for execution and evidence reporting. Each entry retains its own harness, proof command, timeout and success criterion. Include the shared module when copying these drivers into an isolated tool bundle. Keep scenario assertions in their individual tests; share setup and execution only when their contracts match. Task reviews belong in local `docs.agent/`.

The maintenance inventory for `scripts`, `tests` and `experimental` is kept in `docs.agent/evaluation/verify-artifact-inventory.md`. Scripts need a recorded consumer; requirement tests remain separate when the RI5COF ledger names them; experimental RTL is retained only when it has a formal/synthesis consumer or a documented opt-in experiment.

## Parameterized test scenarios

- `tb_csr_all_contract.sv` contains the `tb_csr_contract` top, which shares one CSR/IEU fixture. Select `+CASE=identity_time` (default), `trap_storage`, `stimecmp`, `fp_aliases`, `status_fields`, `satp_warl`, or `tvec_routes`. Each invocation runs one scenario in a fresh process with its own assertions and timeout. Unknown names fail. The existing named CSR Make targets select the corresponding case for RV32/RV64.
- `app/tests/baremetal/zero_pma.S` tests device CBO.ZERO rejection by default; `PMA_READONLY=1` selects ROM/flash write protection. The existing `rva22s64-zero-pma-run` and `rva22s64-readonly-pma-run` targets retain separate images and result directories. Both scenarios include translated accesses and the RAM recovery/neighbor-block checks.
- The `tb_l1d_pma` top in `tb_l1d_all_contract.sv` covers the LR PMA denial and SRAM-hole load/LR/store scenarios. The original `verilator-l1d-lr-pma-*` targets run the default mode; `verilator-l1d-sram-pma-*` supplies `+SRAM`. The two targets retain separate output names while sharing the fixture and the bus/reservation assertions.
- The ten `tb_idu_*.sv` scenarios share `tb_idu_contract.sv`. Original top-level names and Make targets remain unchanged; the build macros read the shared source while elaborating only the selected top. Assertions and counters therefore remain isolated per scenario.
- The `tb_router_clint_subword` and `tb_router_clint_width` tops share `tb_router_all_contract.sv`; the original top names and targets remain separate, so the subword and native-width matrices still run independently.
- The issue-selection, atomic, load/store, checkpoint, prediction-history and LR families use one shared source per family. The original top names remain separate and the Make macros select the corresponding `*_contract.sv` file; this is source consolidation, not a reduction of scenario coverage.
- All remaining L1D, IOQ, LSU and CSR TB modules are stored in `tb_l1d_all_contract.sv`, `tb_ioq_all_contract.sv`, `tb_lsu_all_contract.sv` and `tb_csr_all_contract.sv`. The top-level module passed by each existing target still selects one scenario; the shared source is only a physical organization boundary.
- Router, PTW and SQ scenarios use the same arrangement in `tb_router_all_contract.sv`, `tb_ptw_all_contract.sv` and `tb_sq_all_contract.sv`. Existing top names continue to select one scenario per build.
- CSR execution/control, L1I epoch, IOQ store and L2 posted-write tasks use module-local `*_tasks.svh` helpers (plus `tb_csr_clear_commit.svh`). These headers intentionally have no include guards: each test module receives its own tasks. Keep scenario-specific assertions and handshakes in the original test modules.

- The `tb_ioq_acquire_publish` top in `tb_ioq_all_contract.sv` covers LR by default and AMOADD with `+AMO`; `+PENDING` selects response blocking. Both relaxed and acquire scenarios run in each invocation. Existing `verilator-ioq-acquire-publish-rv32/-rv64` and `verilator-ioq-amo-acquire-publish-rv32/-rv64` targets remain available; the AMO targets supply `+AMO`. Set `IOQ_ACQUIRE_PLUSARGS=+PENDING` as needed.
- `app/tests/baremetal/plic_access_width.S` covers loads by default and stores with `PLIC_WIDTH_STORE=1`. `PLIC_WIDTH_CASE=0..4` and `PLIC_WIDTH_TRANSLATED=0/1` retain the width and translation matrix. `scripts/plic_access_width.py` selects both directions and keeps separate results for each scenario.

## Quick Start

Run `python3 verify/scripts/test_debug_observers.py` from the repository root to
elaborate the optional NPC AXI/speculation/LRSC observers in RV32/RV64 and the
RV32 pin-level heartbeat/commit probes with `small` and `middle`. This requires
Verilator and checks that diagnostic hierarchy references still resolve; it is
not a functional or timing regression. `RAPT_SPEC_OBSERVE` requires
`RAPT_AXI_OBSERVE`; `RAPT_LRSC_OBSERVE` is independent. Event formats remain
compatible with the existing AXI, wrong-path and LR/SC checkers.

CLINT byte-address checks are available through `rva22s64-clint-subword-run`, `rva22s64-clint-subword-write-run`, `rva22s64-clint-subword-time-run`, and `rva22s64-clint-subword-msip-run`. Select `RVA22S64_XLEN=32` or `64` and the matching simulator/reference paths. Set `RVA22S64_TEST_CPPFLAGS=-DCLINT_SUBWORD_TRANSLATED=1` to exercise real Sv32/Sv39 walks with MPRV effective S-mode. The write probe uses word reads to check every modified and preserved byte independently of subword reads. `verilator-router-clint-subword-rv32/-rv64` covers the real router, all natural widths and byte offsets, masks, AW/W timing and response backpressure.

PLIC supported-access checks use `scripts/plic_access_width.py`. Supply `--xlen 32` or `--xlen 64`, `--npc`, `--reference`, `--mrom`, and an empty `--output` directory. Add `--translated` to exercise real Sv32/Sv39 walks with MPRV effective S-mode; otherwise accesses use Bare mode. The runner builds byte/halfword/FP-double rejection probes and supported word controls for both reads and writes, checks exception addresses and subsequent device state, and records compiler commands, inputs and six timing/seed runs per probe. Use a reference built with the same platform width policy. These checks do not establish the supported widths of other devices or complete PLIC conformance; interrupt pending injection uses the platform extension.

`verilator-l1d-plic-width-rv32/-rv64` checks rejection before a device read request, including captured split metadata. `verilator-ioq-plic-width-rv32/-rv64` checks store rejection before SQ allocation. Their translated cases model translation results; the core runner supplies the real page-walk coverage.

```bash
# Prerequisites: ensure simulator + NEMU are built
make -C .. build-rv32              # Build NPC simulator (difftest config by default)
make -C .. build-nemu32-ref        # Build NEMU reference SO

# Run all lightweight tests
make light                          # fuzz + sigtest

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
├── uvm/                # Whole-chip and module-level UVM verification
│   ├── chip/             # Complete-chip UVM top and self-checking firmware
│   ├── csr/              # CSR UVM environment
│   └── iq/               # Issue-queue UVM environment
├── scripts/            # Test generation, orchestration and checker scripts (+ their test_*.py)
├── riscof/             # ACT4 compliance testing
│   ├── raptor-rv32gc/    # RV32GC test config, UDB config, model macros
│   ├── raptor-rv64gc/    # RV64 M-mode instruction projection
│   ├── raptor-rv64s/     # RV64 supervisor projection and requirement ledger
│   ├── raptor_dut/       # ACT4 DUT runner plugin
│   ├── nemu_ref/         # ACT4 NEMU reference plugin
│   ├── classic/          # Legacy RISCOF config (Sail reference)
│   ├── classic-nemu/     # Legacy RISCOF config (NEMU reference)
│   └── riscv-arch-test/  # ACT4 repo (cloned on setup, gitignored)
├── formal/             # Formal verification (SymbiYosys)
│   ├── rvfi/             # Raptor riscv-formal config (project-owned)
│   │   ├── checks.cfg     # riscv-formal check configuration
│   │   └── wrapper.sv     # RVFI wrapper with unconstrained AXI4
│   ├── riscv-formal/     # riscv-formal repo (auto-cloned, gitignored)
│   ├── *.sby             # Per-block SymbiYosys tasks (bus, PMP, PLIC, CLINT, ...)
│   └── formal_*.sv       # Property harnesses
├── xsim/               # Module-level SystemVerilog testbenches (tb_*.sv)
│   └── fpu/              # Verilator FPU arithmetic/conversion tests
├── subsystem/          # Frontend/backend/memory trace tops (see subsystem/README.md)
├── jtag/               # Debug Module / JTAG DTM smoke (see jtag/README.md)
├── vpu/                # Standalone VPU verification (outputs in build/vpu)
├── riscv-dv-target/    # riscv-dv target settings for Raptor
└── build/              # Generated artifacts (gitignored)
```

## RTL Unit Tests

Component-level FPU tests are grouped with the existing module-level testbenches below `xsim/fpu/`. These FPU tests use Verilator because their differential harnesses include C++ host reference models.

```bash
make unit-fpu                    # Run all FPU component tests
make unit-fpu-fma                # Run one directed component regression
make unit-fpu-mul MUL_N=1000000  # Override a random test count
make unit-fpu-convert CONVERT_N=1000000
```

## In-RTL Assertions (SVA)

Raptor ships inline SVA guarded by `RAPT_ASSERT_EN` for zero default overhead. The assertion macros (`RAPT_SVA`, `RAPT_SVA_IMPLY`, `RAPT_SVA_NEXT`, `RAPT_COVER`, ...) are defined in [hdl/include/rapt_sva.svh](../hdl/include/rapt_sva.svh) and auto-included via `rapt.svh`.

```shell
# Enable assertions for any simulation target
make run-rv32                VFLAGS="-DRAPT_ASSERT_EN"
make microbench-rv32 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42 VFLAGS="-DRAPT_ASSERT_EN"
make cpu-tests-rv32 ARGS="-b -n" VFLAGS="-DRAPT_ASSERT_EN"
```

Failure format: `[<time>] SVA FAIL: <hier>.<LABEL> (<ante>) |-> (<cons>)` followed by `$fatal`.

## Verification Methods

### 1. Random Instruction Fuzzing (`make fuzz`)

Generates random legal RV32/RV64 IMAC instruction sequences, compiles them as bare-metal programs, and runs each with difftest (NPC vs NEMU).

**Configuration:**
```bash
make fuzz SEED=42         # Reproducible seed
make fuzz FUZZ_NUM=100    # Generate 100 programs
make fuzz FUZZ_LEN=500    # 500 instructions each
make fuzz ISA=rv64        # RV64 mode
```

**Instruction mix:** ALU (45%), M-extension (15%), Load/Store (25%), Branch (10%), LUI/AUIPC (5%).

**What it catches:** RAW/WAW/WAR hazards in OoO pipeline, operand bypass errors, branch misprediction recovery bugs, M-extension corner cases (div-by-zero, overflow), load/store alignment issues.

### 2. Signature-based ISA Tests (`make sigtest`)

Deterministic tests targeting known ISA corner cases:

- **alu_r_type**: All R-type ALU ops with boundary values (0, -1, INT_MAX, INT_MIN)
- **alu_i_type**: I-type ops with extreme immediates
- **mul_div**: M-extension with div-by-zero, overflow, signed/unsigned edge cases
- **branch**: All 6 branch types with signed/unsigned boundary comparisons
- **mem_ops**: Load/store round-trip at byte/half/word granularity

Each test stores results to a signature region. Difftest catches any deviation between NPC and NEMU.

### 3. ACT4 Compliance (`make riscof`)

[ACT4](https://github.com/riscv-non-isa/riscv-arch-test) (riscv-arch-test act4 branch) is the RISC-V official architectural certification framework using Sail as the reference model. The default `raptor-rv32gc` profile covers the RV32 I/M/A/F/D/C extensions, including Zcf/Zcd compressed floating-point loads and stores, together with the implemented Z* extensions.

**First-time setup:**
```bash
make riscof-setup         # Clone ACT4 repo + check prerequisites (sail, uv)
make riscof-gen           # Generate self-checking ELFs
make riscof-run           # Execute tests on NPC
```

ACT4 uses a 60-second per-ELF **wall-clock** timeout (`ACT4_TIMEOUT`), separate from the generic 10-second unit-test default. Large floating-point ELFs can take longer than 10 seconds even without contention. For busy hosts, use `make riscof-run JOBS=4 ACT4_TIMEOUT=120`. Explicit legacy `TIMEOUT` overrides remain honored unless `ACT4_TIMEOUT` is supplied. Timeout logs retain the command, elapsed time and captured output; a timeout always counts as failure, even if partial output contains a PASS line.

Requires Sail RISC-V 0.13.1 and `uv` (Python package manager). Install the official Linux x86_64 release in the default project location with:

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

Classic RTL RISCOF (`make -C verify riscof-classic`) uses a separate `RISCOF_CLASSIC_TIMEOUT=600` second wall-clock budget per DUT test. Large F/D vectors can exceed the generic 10-second smoke-test budget, especially with parallel jobs. Explicit `TIMEOUT` overrides are still honored unless `RISCOF_CLASSIC_TIMEOUT` is supplied. For example:

```bash
make -C verify riscof-classic JOBS=4 RISCOF_CLASSIC_TIMEOUT=600
verify/build/riscof-classic-venv/bin/python verify/scripts/test_riscof_classic_runner.py
```

The classic Sail plugin uses `raptor.json` to check page-local misaligned accesses as a whole before splitting, matching Raptor's PMP policy. It keeps Sail 0.13.1's ROM/IO/RAM regions but disables its default MAG and Zama16b declaration; otherwise the RAM MAG overrides the page-local split setting. The `pmpm_misaligned_{na4,napot,tor}` tests use a 16-byte region offset on both DUT and reference: this retains the PMP crossings while separating them from Sail's mandatory page split. These tests remain in the comparison; cross-page behavior is covered separately by the split-page and PMP span regressions.

PMP capacity is now 8 usable entries in 16 architectural CSR slots (upper eight read-only zero), for RV32/RV64 and every preset. ACT4 declares `NUM_PMP_ENTRIES=16`, `NUM_USABLE_PMP_ENTRIES=8`; test headers use `RVMODEL_NUM_PMPS=8`. Historical 16-usable-entry results do not validate this configuration. Classic test headers constrain generated tests to usable entries; they do not by themselves reconfigure Sail's CSR implementation or prove upper-slot read-only-zero behavior.

Run `make -C verify pmp-capacity-check` for RV32/RV64 CSR WARL/upper-slot alias prevention, own/TOR predecessor locks, permission checks, reset/NAPOT, CSR legality, shared L1D checks and NEMU capacity tests. For isolated output, pass `BUILD_DIR=/tmp/<task-directory>`. This is directed component coverage, not full-core, FPGA timing, boot or complete profile validation. The separate `nemu-pmp-priority-check` interval oracle currently reports 216 RV32 partial-overlap discrepancies in both the original 16-entry baseline and this 8-entry revision; that pre-existing issue is not fixed or hidden by the capacity suite.

Each test's `dut/` directory retains `dut.log` and `dut-run.json`. Only a successful simulator termination with a complete, well-formed signature is passed to the signature comparison. On execution failure, partial output is kept as `*.signature.partial` and the comparison signature is empty so the test still fails. This distinguishes execution timeouts from completed architectural mismatches; it does not suppress either failure or change the test selection.

### 4. RISCV-DV Privileged Stress (`make riscv-dv`)

Uses the upstream [chipsalliance/riscv-dv](https://github.com/chipsalliance/riscv-dv) pure-Python generator with a Raptor RV32IMC M-mode target. Generated binaries run on NPC with NEMU instruction-by-instruction difftest; no commercial UVM simulator is needed for M-mode CSR and trap-handler stress. This riscv-dv target is an IMAC smoke configuration and does not represent the full implemented ISA; use the ACT4 RV32GC profile, the RISCOF classic profile, and `app/tests/fp` for broader architectural and F/D coverage.

```bash
make riscv-dv                         # one short privileged smoke test
make riscv-dv-stress                  # illegal-instruction exception stress
make riscv-dv-gen RISCV_DV_TEST=raptor_exception_stress RISCV_DV_SEED=42
make riscv-dv-run RISCV_DV_TEST=raptor_exception_stress
```

Memory timing is a separate, reproducible verification dimension. NPC samples a uniform `0..N` cycle delay independently for every AXI memory beat. The smoke suite defaults to maxima `0 7 31 63 233` with memory seed `1`; the stress target uses memory seeds `1 42 31337`, producing a full delay-by-seed matrix. Generator seed and memory-delay seed are intentionally independent.

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

Each coordinate writes `*.delayN-seedS.run.log` next to its generated binary, so failures retain the exact timing rule needed for replay.

The pyflow backend cannot currently generate random exceptions reliably: its EBREAK templates are unregistered, subprogram callstack state is uninitialized, and illegal-instruction constraints fail to solve. The exception stress target therefore uses pyflow's generated M-mode trap harness and long random stream, then injects 256 register-free `0xffffffff` illegal instructions at `main`. This exercises `mcause`/`mepc`, trap-frame save/restore, and `mret` without depending on those broken upstream paths.

The first run clones pinned revision `b7a0b4b0b51346a3c64f159f81ea262d867c14a9` and creates an isolated Python 3.11 environment under `verify/build/`. Python 3.10 or 3.11 is required because the pinned dependencies still import `imp`, removed in Python 3.12. Setup uses an installed 3.11/3.10 interpreter or provisions a local 3.11 interpreter with `uv` if neither is available.

The upstream Python backend does not implement page-table creation, page-table sections, or page-fault handlers (these functions are `TODO` in `pygen/pygen_src/riscv_asm_program_gen.py`). Run `make riscv-dv-mmu` for a fail-fast capability check. Full Sv32/MMU generation requires riscv-dv's SV/UVM backend and one of its supported simulators (VCS, Questa, Xcelium, or Riviera-PRO); none is installed in the current open-source tool environment.

### 5. Verilator Coverage (`make coverage`)

Collects line and toggle coverage during simulation.

```bash
make coverage-build       # Rebuild NPC with --coverage
make coverage-run         # Run tests to collect data
make coverage-report      # Generate annotated source report
```

**Note:** Coverage build uses Verilator's `--coverage --coverage-line --coverage-toggle` flags (with `-Wno-UNOPTFLAT` for this mode). `coverage-run` drives the instrumented NPC using `fuzz + sigtest` workloads from this `verify/` suite (to avoid non-coverage rebuilds from root targets). Each workload invocation gets a fresh directory under `$(COV_DIR)/raw/`; the simulator writes `coverage-<pid>.dat` there on exit. Only that invocation's files are merged via `verilator_coverage`. Old raw data is retained, and shared source-directory coverage files are neither deleted nor used as fallback input. Use different `COV_DIR` values for parallel suites to keep their aggregate reports and logs independent.

### 5. Formal Verification (`make -C formal`)

Uses [SymbiYosys](https://github.com/YosysHQ/sby) for symbolic equivalence, k-induction, cover reachability, and bounded model checking. Runs from the `formal/` subdirectory.

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

The ALU proof is exhaustive over symbolic RV32 operands for all non-CLMUL operations. CLMUL and CLMULR are also exhaustive; CLMULH exhaustively proves all polynomial basis terms (the implementation is their linear XOR accumulation). PLRU, maptable, CLINT, and PLIC use k-induction and include reachable cover witnesses. CLINT checks RV32/RV64 plus divider-bypass and divided timer paths. PLIC uses k-induction for reduced RV32/RV64 geometries and a four-cycle BMC on the production RV32 geometry (31 sources, two contexts). Its lifecycle covers use three symbolic sources and two contexts to preserve arbitration ties, M/S interrupt routing, and claim/complete behavior while keeping witnesses short. The bus check explores 12 cycles of arbitrary backpressure, while div/sqrt explores 70 cycles to exceed the longest iterative operation.

The DTM proof covers the implemented single-clock simulation transport: all 16 TAP states, IR/DR shifting, IDCODE/DTMCS capture, and DMI request/response sequencing. CDC, busy/sticky status, and reset side effects remain explicitly outside `rapt_dtm`'s current implementation contract.

#### riscv-formal (RVFI)

[riscv-formal](https://github.com/YosysHQ/riscv-formal) performs per-instruction formal verification via the RVFI (RISC-V Formal Interface). The Raptor core exposes RVFI signals through `hdl/backend/rapt_rvfi.sv` (enabled by `-DRAPT_RVFI`), with NRET=2 for dual-commit.

The riscv-formal repository is **auto-cloned** on first use. Project-owned configuration lives in `formal/rvfi/` (tracked in git); the cloned repo is gitignored.

**150 checks** are generated covering RV32IMC instructions (70 insns × 2 channels) plus consistency checks (reg, pc_fwd, pc_bwd, unique, causal).

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

**Engine:** Uses `abc bmc3` (AIGER-based BMC) instead of SMT-based solvers to avoid a false-positive combinational loop detection in the `write_smt2` backend. `checks.cfg` uses depth 8 for instruction checks and final depth 10 for register, forward/backward PC, uniqueness, and causality checks. Shallow bounds can pass vacuously before retirement is reachable; runtime depends on the check and bound.

**Configuration files** (`formal/rvfi/`):
- `checks.cfg` — ISA, nret, solver, depth, yosys-slang script
- `wrapper.sv` — Instantiates `rapt` with unconstrained AXI4 responses via `rvformal_rand_reg`, exposing only RVFI outputs to the testbench

### 6. JTAG / RISC-V Debug Verification (`make jtag`)

Two-layer verification of the `rapt_dtm` + `rapt_dm` blocks introduced for the JTAG / RISC-V Debug Spec 1.0 implementation. Lives in [verify/jtag/](./jtag/README.md) for full details.

**Layer 1 — in-tree compliance probe (runs today):**

```bash
make jtag-selftest        # 23-point DTM/DM compliance probe (no NEMU)
```

Drives JTAG TCK/TMS/TDI directly into the Verilator-built RTL (no GDB / no OpenOCD) and exercises three phases: TAP/IR (IDCODE, BYPASS identity, DTMCS fields, soft-TLR), DM register file (dmcontrol RW + dmactive=0 quiesce, dmstatus, hartinfo, data0 RW, abstractcs static fields), abstract-command semantics (cmderr=2 on unsupported, W1C clear, dropped while !dmactive).

**Layer 2 — upstream `riscv-tests/debug` (P1-blocked stub):**

```bash
make jtag-debug-tests-setup   # Clones riscv-software-src/riscv-tests
make jtag-debug-tests         # Currently exits 1 with checklist
```

Stages the upstream GDB-driven debug-spec suite; `debug-tests` remains an explicit nonzero-exit stub. The remote-bitbang bridge, drained-core halt/resume and 32-bit abstract GPR/selected-CSR access already exist. Debug CSR storage is DM-local, and commit-based stepping is a bring-up mechanism. Full Debug Mode entry/return, memory access/SBA, program-buffer execution and 64-bit abstract transfers remain unsupported. See [JTAG verification](jtag/README.md) for the implemented `openocd-halt-reg` and `gdb-smoke` entry points.

### 7. UVM verification

The whole-chip environment boots self-checking firmware on the actual `rapt` RTL and drives randomized AXI timing, cross-ID response ordering, interrupts, JTAG, reset and external-write notifications through top-level pins. It covers RV32/RV64 and the RV32 RNP wrapper with explicit protocol and result checks.

```bash
make uvm-chip-rv32 UVM_HOME=/path/to/uvm-core
make uvm-chip-rv64 UVM_HOME=/path/to/uvm-core
make uvm-chip-regress UVM_HOME=/path/to/uvm-core
```

See [whole-chip UVM](uvm/chip/README.md) for the scenario matrix, dependencies, reproducible single-case commands and result format.

#### Module-level UVM (`make uvm`)

The module-level layer targets local ordering and protocol bugs that are hard to diagnose through full-core software alone. The first environment covers the out-of-order issue queue with an independent age/operand reference model, directed fast-load tests, randomized CDB/dispatch/flush stimulus, a scoreboard, coverage counters, and inline SVA.

```bash
make uvm-smoke       # Run the simulator's minimal UVM 1.2 runtime check
make uvm-iq-compile  # Compile the complete issue-queue UVM environment
```

See [uvm/README.md](./uvm/README.md) for the installed XSim limitation and current environment coverage. The former standalone verification plan is not distributed here; executable targets in [Makefile](Makefile) define the available checks.

## Linux milestones

The RV32 Linux CI job explicitly uses `--success-marker "Linux version"`: it checks kernel entry and the runner's failure diagnostics. It does not require userspace startup. From the root, `make verify-linux-boot-rv32` instead requires `Run /init as init process`. Memory-stress targets use their separately configured milestone; none of these alone certifies a profile or OS stability.

## Integration with Root Makefile

From the project root:
```bash
make verify-fuzz          # Shortcut for fuzz
make verify-sigtest       # Shortcut for sigtest
make verify-light           # Run all verify targets
```

## RV64 Support

All tools support RV64 via `ISA=rv64`:
```bash
make fuzz ISA=rv64
make sigtest ISA=rv64
```

This automatically sets the correct march/mabi and passes `-DRAPT_RV64` to the build system.

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

M decoder enumeration: `make -C verify verilator-idu-m-encodings-rv32` and `verilator-idu-m-encodings-rv64` exercise every rd/rs1/rs2 tuple in funct7=1 OP/OP-32 across M/S/U. RV32 also sweeps OP-32/OP-IMM-32 funct7, funct3 and correlated register fields. The latter is not a Cartesian register sweep. `scripts/m_elf_coverage.py --elf-dir <M-ELFs> --output <JSON>` records static instruction and register coverage separately from execution results.

The M privilege/edge test also rejects all five RV64 M word operations in RV32, checking their precise illegal-instruction trap and preserved destination.

`rva22s64-bit-xlen-legality-run` checks native REV8 and highest-bit BSETI, then traps on selected XLEN-incompatible shift/REV8 encodings. Use `RVA22S64_TEST_CPPFLAGS=-DBIT_TEST_PRIV=0`, `1`, or `3` for U/S/M. `verilator-idu-bit-immediates-rv32` / `-rv64` enumerate eight immediate families, every 6-bit shift and rd/rs1 combination, plus both REV8 encodings, in M/S/U. A reference with the RV32 shift-immediate matching fix is required.

`verilator-bit-decode-alu-rv32` / `-rv64` assemble deterministic Zba/Zbb/Zbs vectors and compare the real decoder+ALU against independent Python integer expectations in M/S/U. The vector manifest records the seed, compiler command, operands and expected results; it is not an exhaustive operand proof.

`rva22s64-zexth-xlen-run` checks native ZEXT.H, all eight C.ZEXT.H register encodings, and the unimplemented other-XLEN native encoding with precise cause/EPC/tval, preserved destination and trap return. Set `RVA22S64_XLEN` to 32 or 64 and `RVA22S64_TEST_CPPFLAGS=-DZEXTH_TEST_PRIV=0`, `1`, or `3` for U/S/M; provide the frozen NPC and matching reference as for other runners. `verilator-zexth-decode-alu-rv32` / `-rv64` exercise the real decoder and ALU: all 65,536 low-halfword values with upper bits set, both native/compressed forms, every native rd/rs1 pair and all compressed short registers in M/S/U. Each XLEN checks 399,384 cases. This is bounded operand coverage; rejecting the counterpart encoding is the selected platform's unimplemented-encoding policy. C.ZEXT.H interaction coverage does not add Zcb to RVA22's mandatory set.

`verilator-compressed-register-legality-rv32` / `-rv64` check every register and immediate field of C.LWSP, C.LDSP/C.FLWSP and C.ADDIW/C.JAL, plus every C.JR register in M/S/U: 18,528 cases per XLEN. Reserved integer zero-register forms must report illegal instruction with the raw lower parcel as tval; RV32 C.FLWSP f0 and overlapping C.JAL remain legal. FP state is enabled in this module test. `rva22s64-compressed-register-legality-run` exercises representative illegal forms and legal controls on a frozen core. Select `RVA22S64_XLEN=32` or `64` and `RVA22S64_TEST_CPPFLAGS=-DC_REGISTER_TEST_PRIV=0`, `1`, or `3` for U/S/M; the reference must include the compressed zero-register legality repair. These tests cover the selected platform policy, not all compressed encodings.

`verilator-compressed-zero-immediate-rv32` / `-rv64` enumerate all immediate and register fields of C.ADDI4SPN and C.LUI/C.ADDI16SP in M/S/U: 12,288 checks per XLEN. Zero immediates are rejected except the eight existing C.MOP.n encodings (odd n in 1..15); nonzero-immediate C.LUI x0 HINTs remain valid. MOP/HINT checks also require no architectural destination. The core target `rva22s64-compressed-zero-immediate-run` tests all 32 reserved zero-immediate forms, all eight C.MOP.n controls, HINTs and representative legal arithmetic. Set `RVA22S64_TEST_CPPFLAGS=-DC_IMMEDIATE_TEST_PRIV=0`, `1`, or `3`, with the selected XLEN, frozen NPC and corrected reference. Zcmop remains an existing extra implementation; these checks do not make it mandatory for RVA22.

### Optional CSR policy in the NEMU reference

The current Raptor RTL traps accesses to the optional `mcountinhibit` CSR (`0x320`). `nemu/configs/riscv64_ref_defconfig` therefore disables `CONFIG_RV_MCOUNTINHIBIT` while retaining RVA22S64 and F/D. Standalone NEMU RVA22 presets retain their WARL-zero CSR default. Do not skip OpenSBI CSR probes in difftest to hide a mismatch between these policies.

After `make build-nemu64-ref` from the repository root, check the reference:

```sh
python3 verify/scripts/nemu_rva22s64_check.py --xlen 64 \
    --reference nemu/build/riscv64-nemu-interpreter-so \
    --mcountinhibit absent --output /tmp/raptor-nemu64-csr-check.json
```

The absent-CSR checks include OpenSBI's exact `csrr a0, 0x320` probe and register/immediate CSR writes; they require precise illegal-instruction trap state, unchanged destinations and no instruction retirement. This reference regression does not substitute for a Linux boot on the DUT or FPGA.

### Default four-way L1 capacity checks

The default preset uses 64 sets × 64 B × 4 ways = 16 KiB for each L1, with tree-PLRU replacement and a 4 KiB per-way span that keeps every index bit inside the Sv32/Sv39 page offset.

```sh
make -C verify verilator-l1i-16k-rv32 verilator-l1i-16k-rv64 \
  verilator-l1d-16k-rv32 verilator-l1d-16k-rv64
```

These checks fill and read every word of each cache, require all four same-set lines to remain resident without external reads, introduce a conflicting tag beyond the whole capacity, check neighboring-set preservation, and invalidate/refill all sets. They derive sets/ways/capacity/stride from the selected preset, require 64 B lines and at least two sets and ways, and enable assertions; compiler warnings are nonfatal by default (`-Wno-fatal`). The store-coherence test derives its conflict stride and working-set size from the selected preset, preserving eviction coverage as associativity changes. These are functional checks; FPGA utilization and timing require synthesis and implementation of the chosen SoC configuration.

### Streaming cache transactions

`make -C verify verilator-cache-stream-rv32 verilator-cache-stream-rv64 verilator-cache-stream-l2-rv32 verilator-cache-stream-l2-rv64` runs the complete L1D/bus/AXI/optional-L2 path with randomized ready stalls. Tests check early critical-word completion, every resident word across full L1D capacity, CBO set colors and pending fills, 64-byte ZERO AW/W/B counts and delayed/error B, cancelled/error refills, and NA4/TOR/NAPOT boundary word fallback at both cache levels. Repeat with `XSIM_RAPT_CONFIG=small` to cover 16-byte lines. `verilator-cache-stream-rnp-rv32` checks the word-serial RNP bridge: the core keeps one burst owner, while the external RNP side uses one transaction per word and has no error-response encoding.

`default`, `default-w3`, `default-w4`, `default-w8`, and `default-l2` select write-back with four L1D MSHRs and two writeback buffers. `make -C verify verilator-cache-default-rv32 verilator-cache-default-rv64 XSIM_RAPT_CONFIG=<preset>` exercises that preset's policy without a parameter override. The older `cache-stream` targets explicitly select write-through; `cache-stream-wb` explicitly selects write-back.

`make -C verify verilator-wb-ptw-rv32 verilator-wb-ptw-rv64` checks dirty PTE publication, partial store misses against outstanding I/D-side PTW reads, both I/D walkers waiting for an older bus store, and an I-side PTW write invalidating cache state while an older SQ B response arrives. The write-channel case exercises the bus contract; the current Svade walkers do not generate A/D writes. With `XSIM_RAPT_CONFIG=default-l2`, the test checks dirty PTE publication and partial store exclusion through L2 (the held outer-B cases require passthrough L2).

`make -C verify sq-checkpoint-rv32 sq-checkpoint-rv64 SIM_BUILD_PROFILE=<profile> SQ_CHECKPOINT_KIND=cache` checks architectural save/load with dirty victims, eight conflicting L1D lines and a newer partial store after SQ drain. Run it with simulators built from `default` and `default-l2`; add `SQ_CHECKPOINT_REQUIRE_L2=1` for the latter to require captured dirty L2 data. Checkpoints overlay actual dirty L2/L1D SRAM data before committed SQ stores and undo the overlays when execution continues. The runner checks both restore and continued execution with NEMU difftest. The existing `word`, `fp64` and `unaligned` kinds cover pending SQ/AXI stores and split-store drain; use a fresh `BUILD_DIR` for each run.

The BOOM-style write-back preset has a separate L1D/L2 ownership regression: `make -C verify verilator-cache-stream-wb-l2-rv32 verilator-cache-stream-wb-l2-rv64 XSIM_RAPT_CONFIG=default-l2`. It checks dirty L1D releases on L2 eviction and CBO, D-side ownership after a store miss or a resident L2 hit, and an overlapping L1D write-back/CBO. The preset-policy targets also cover this L1D/L2 path in both XLEN modes.

`make -C verify verilator-l2-release-admission-rv32 verilator-l2-release-admission-rv64 XSIM_RAPT_CONFIG=default-l2` checks that a ReleaseData reserves L2 admission from its first beat through gaps between beats and ReleaseAck, then checks the released data remains resident.

`make -C verify verilator-l2-release-probe-rv32 verilator-l2-release-probe-rv64 XSIM_RAPT_CONFIG=default-l2` checks C Release pre-emption while an ordinary victim or CBO waits for Probe. Cases cover dirty data, clean Release, partial word masks, different-tag metadata isolation, and failed outer writeback preserving already-acknowledged ReleaseData. The owner withholds Probe Ack until ReleaseAck; the old ordinary and CBO paths deadlocked in this case.

`make -C verify verilator-l2-owned-read-rv32 verilator-l2-owned-read-rv64 XSIM_RAPT_CONFIG=default-l2` checks twelve owner-Get coherence cases: primary scalar, INCR, FIXED and WRAP reads; clean and dirty Probe Ack; C Release pre-emption; scalar and burst secondary reads; and ordered ownership regrants. It checks dirty data and backpressure, and counts directory reads to verify metadata reuse for equal-tag secondaries and line-local burst beats. A dirty different-tag secondary replacement must be written back before reloading the original tag. The old primary and secondary paths returned stale data before owner Probe; an early reuse candidate also skipped this replacement writeback.

`make -C verify verilator-l2-release-buffer-rv32 verilator-l2-release-buffer-rv64` checks the two Release lists and their shared lowest-free beat pool. It fills both lists with dirty lines, retires one, checks that the other retains its data, and verifies reuse of the freed entries.

`make -C verify verilator-l2-data-array` checks the four-bank data-array geometry and port priority. It also holds a full-line SourceD read between its two row accesses while a SourceC read uses a shared bank, then checks that SourceD retains its first row.

`make -C verify verilator-l2-put-list-rv32 verilator-l2-put-list-rv64` checks the BOOM-sized 40-list/40-beat shared pool, multibeat lists, concurrent push/pop, and full-pool backpressure. `make -C verify verilator-l2-put-buffer-rv32 verilator-l2-put-buffer-rv64 XSIM_RAPT_CONFIG=default-l2` checks the connected single-beat path: all 40 slots, backpressure at slot 41, older-write ordering against an MMIO read, and all 40 ordered write responses.

`make -C verify verilator-l2-secondary-buffer verilator-l2-mshr-scheduler verilator-l2-mshr-frontend` checks the standalone RV64 21-queue/33-entry secondary request buffer, five ordinary plus BC/C reserved MSHR scheduler, and their joined admission/replay fabric. `verilator-l2-secondary-buffer-rv32` checks the RV32 15-queue/35-entry geometry. The scheduler checks same-set priority, reserved-slot pre-emption, C/B/A replay order, bypass on reload, directory-read conflicts and round-robin resource gating. The fabric also checks queued tags and payload ordering. The live L2 uses the secondary queue for same-set requests and different-tag replay; its Release head occupies the reserved C scheduling slot. General BC/C nested metadata forwarding remains incomplete.

`make -C verify verilator-l2-refill-mshrs-rv32 verilator-l2-refill-mshrs-rv64` checks five RV32 or seven RV64 collector contexts, slot-to-AXI-ID remapping, interleaved R beats, sticky errors and metadata retention. `make -C verify verilator-l2-mshr-concurrent-rv32 verilator-l2-mshr-concurrent-rv64 XSIM_RAPT_CONFIG=default-l2` checks three RV32 or five RV64 simultaneous clean read misses through the live L2 and scalar critical-word return before line completion. The live test also checks same-line secondary buffering, FIFO order, restored IDs, and D-side ownership. Different-tag same-set replay and the reserved C Release path have separate directed regressions; the BC slot has no outer B traffic in this last-level configuration.

`make -C verify verilator-l2-line-local-put-rv32 verilator-l2-line-local-put-rv64 XSIM_RAPT_CONFIG=default-l2` checks that bufferable cacheable FIXED, INCR, valid WRAP, and narrow bursts within one line allocate locally. It covers a short masked miss, repeated narrow beats merged into one fetched word, resident address wrapping, local B, untouched-word preservation, and a failed refill returning an error B without installing the line. The associative regressions check a resident short partial burst on this local path.

`make -C verify verilator-l2-cross-line-put-rv32 verilator-l2-cross-line-put-rv64 XSIM_RAPT_CONFIG=default-l2` checks that bufferable cacheable INCR and valid WRAP bursts crossing cache-line boundaries allocate and commit one line at a time. It covers a resident first segment followed by a miss, a narrow boundary write, two full lines without an outer read, a 48-beat burst beyond Put-pool capacity, a three-segment RV64 WRAP that revisits its first line, a second-segment error after the first commits, and a failed refill that drains through WLAST before returning an error B.

`make -C verify verilator-l2-forwarded-error-rv32 verilator-l2-forwarded-error-rv64 XSIM_RAPT_CONFIG=default-l2` checks cacheable forwarded bursts that cannot allocate locally. Resident hit beats are journaled until the matching outer B: an error preserves the old target and older dirty data, while success replays a masked two-beat write before returning B. A legal 256-beat byte-wide INCR burst over four resident lines exercises every journal entry and the shared 40-beat Put pool concurrently. The test checks that no cached byte commits before B and that the first and last words contain the complete replayed data.

`make -C verify verilator-l2-forwarded-client-rv32 verilator-l2-forwarded-client-rv64 XSIM_RAPT_CONFIG=default-l2` checks cacheable non-bufferable scalar and burst writes to resident lines held by the D client. Both paths must issue Probe, hold the successful B until Probe Ack, clear the client owner, preserve unrelated dirty ProbeAckData, and return the updated resident data after B. The two-beat same-line burst permits one Probe; a boundary-crossing burst requires a separate Probe and Ack for each owned line. The test also holds Probe Ack until an unrelated clean C Release receives ReleaseAck while either forwarded path waits for outer B, preventing a Release/Probe wait cycle. C must also finish between the first and last W beats of an active forwarded burst while the next W is stalled. A same-line dirty ReleaseData must commit before the forwarded scalar store and retain its unrelated dirty word; the burst case checks the same ordering when C arrives between W beats. A failed outer B must return an error without probing or changing the old resident data and ownership.

`make -C verify verilator-axi-r-buffer-rv32 verilator-axi-r-buffer-rv64 XSIM_RAPT_CONFIG=default-l2` checks the two-entry outer AXI R buffer, including full backpressure, alternating IDs, error/last fields, sustained one-beat-per-cycle delivery, and AR/AW/W/B passthrough. The write-back L1D/L2 cache-stream targets also instantiate the buffer, matching the `rapt_memory` integration.

`make -C verify verilator-l2-pbmt-boom-rv32 verilator-l2-pbmt-boom-rv64 XSIM_RAPT_CONFIG=default-l2` checks PBMT NC/IO bypass against a hot cacheable alias, preservation of AXI cache attributes and real outer B responses, no allocation for a cold typed write, and alias invalidation after a failed typed write. The older `verilator-l2-pbmt*` targets exercise the legacy posted external DDR-write policy and should be run with the legacy geometry.

Legacy word-response L1D fixtures explicitly select `.LineRefill(0)` to retain their individual-word and partial-line scenarios; production defaults to full line refill. The streaming tests above exercise the production default.

The UVM runner accepts `--l2` with `--top axi`, separating build directories and result names from L2-disabled runs. For example:

```sh
python3 verify/uvm/run.py --uvm-home "$UVM_HOME" --preset default --xlen 64 \
  --top axi --l2 --cases memory pipeline mmu ifetch_mmu pmp faults \
  --seeds 42 --delays 0 7
```

### IOQ registered address preparation

```sh
make -C verify verilator-ioq-address-stage-rv32 verilator-ioq-address-stage-rv64 RAPT_CONFIG=default
```

Covers resident operand wakeup, dispatch-time completion forwarding, request backpressure, flush during preparation, and address ownership through flush and normal queue wraparound. The default `RegisterAddresses=1` prepares an address one cycle after its base operand is stored; both A and HUM B issue require that preparation. `verilator-ioq-overlap-rv32/rv64` additionally checks that unprepared older stores block younger loads before byte-span disambiguation.

### Backend timing boundaries

```sh
make -C verify verilator-fmax-boundaries-rv32 verilator-fmax-boundaries-rv64 RAPT_CONFIG=default
```

These assertion-enabled tests cover the reusable buffered completion arbiter, issue-to-execute registers, and the fixed-position rename packet stage before PRF reads. Checks include simultaneous completions without loss, capacity reservation, rejected completions, generation payloads, wrapped ROB selective cancellation, flush, and three-lane partial consumption with checkpoint retention. The arbiter fixture reserves empty slots before acceptance and does not grant same-cycle dequeue credit. The core now has a dedicated FP completion endpoint; the FP result queues are checked by `verilator-feu-ooo-rv32/rv64`. The operand stage accepts a new batch when the old batch fully drains, and compacts a partially consumed suffix while preserving order.

`verilator-rou-fp-irq-compose-rv32/rv64` exercises the actual FP queue, execution, committed FPR storage and interrupt recovery composition. `formal/zkt_cdb.sby` checks control independence from result data across the buffered arbiter using 12-step BMC; this is a bounded check, not an unbounded proof.

### UART 平台一致性

```sh
python3 verify/scripts/test_uart_platform.py
# 或 make -C verify uart-platform-check
```

独立编译生产 NEMU/sim 串口模型，覆盖 RV32/RV64 的 NS16550 RX IRQ10、CU08
LiteUART `0x11001800` 的收发、旧高地址 alias 拒绝，以及 sim CSR 写掩码。
同时编译规范 DTS，检查 NS16550 interrupt cell 与 NEMU Linux presets 一致。
仅提供宿主环境/MMIO 注册/IRQ 接收端桩，不修改共享 `.config`，不加载 FPGA。
这不是完整 Linux/RTL/PLIC 集成回归，也不验证 LiteUART 完整事件中断仿真。

整核入口 `mmio-transaction-check` 检查 LiteUART 低地址，每个地址覆盖
总线延迟 0/7/63、随机种子 1/42，核对 AXI 响应及实际发送字节；
`mmio-uart-read-check` 检查 NS16550 byte lane 和 read-to-clear 副作用。
`mmio-uart-irq-check` 向 stdin 注入 `K`，由裸机程序检查 M-mode 外部中断、
PLIC claim=10、收到的字符与 completion，然后打印成功标记并写 finisher。
IRQ 测试使用不启用 difftest 的 sim，避免参考模型的异步输入时序干扰。
这些入口需要 `RAPT_AXI_OBSERVE` 构建的 sim；可用脚本直接指定独立构建产物：

```sh
python3 verify/scripts/mmio_transaction_check.py \
  --npc /path/to/riscv64-npc-sim --no-difftest \
  --mrom /path/to/mrom-data.bin --xlen 64 --output /tmp/raptor-chip-mmio64
# 添加 --uart-read 或 --uart-irq 分别运行读副作用或中断测试；RV32 使用对应产物和 --xlen 32。
```

`--no-difftest` 表示仅检查端点/整核测试结果，要求传入关闭 difftest 的 sim，
不会替调用者重建模型。构建开启 difftest 的模型时应传入 `--reference`。


### L1D MSHR 与重放

`make -C verify verilator-wb-mshr-rv32 verilator-wb-mshr-rv64` 检查真实 L1D/bus
组合：Sv32/Sv39 冷页表遍历与四条独立回填重叠、同一物理行合并、跨 ID 交错响应、
关键字提前返回、两个写回缓冲在 B 阻塞时允许无关读推进、同地址读等待写回、队列满
背压、晚到本地存储与已接受 load 的让行/唤醒、存储与回填安装冲突、脏 PTE 发布、
取消、权限错误和总线错误。
`verilator-wb-mshr-l2-rv32/-rv64` 固定使用 `default-l2`，检查 MSHR 回填取得
包含式 L2 的 D-client 所有权，以及脏受害行 Release/ReleaseAck。
`verilator-mshr-ioq-translated-rv32/-rv64` 检查开启翻译后的 IOQ park/wake、
年轻 load 前进和重放上下文保持。
`verilator-l2tlb-cbo-rv32/-rv64` 还检查脏 L1D 下冷 L1 TLB、热 L2 TLB
不会产生页表读取或无关写回。


```sh
make -C verify verilator-mshr-cache-rv32 verilator-mshr-cache-rv64 \
  verilator-mshr-ioq-rv32 verilator-mshr-ioq-rv64 \
  verilator-bus-read-ownership-rv32 verilator-bus-read-ownership-rv64
```

Cache 测试覆盖两行在途、同一行合并、表满重放、不同 ID 反序返回、逐 beat 错误、
权限重检、store/refill 排序及取消后排空；IOQ 测试检查不提前完成、年轻 load 前进、
同周期 wake 与 park、flush 清理。Cache 测试强制双 MSHR；bus 测试使用 default。

整核定向程序校验独立 load、同一行多个消费者、store 后读取和拆分访问：

```sh
python3 verify/scripts/mshr_check.py --npc /path/to/riscv64-npc-sim \
  --mrom /path/to/mrom-data.bin --xlen 64 --output /tmp/raptor-chip-mshr-core64
```

要求 sim 启用 `RAPT_AXI_OBSERVE`、至少两个 MSHR（default 为四个），关闭 difftest。脚本检查实际运算结果、
AXI 响应和 cache→bus 两个同时存活的 miss owner；单独记录外部 AXI 是否重叠，
不把串行 slave 的行为当成并行 DRAM 性能证据。`MSHR_OBS` 仅在仿真观测构建中生成。

## Whole-project regression

From the repository root:

```sh
make regression-plan                         # commands only; no submake or formatting
make regression REGRESSION_BOARD=mlk_cu08_ku15p
make regression REGRESSION_JOBS=3 REGRESSION_TOOL_JOBS=4
make regression REGRESSION_SUITES="coremark sta" REGRESSION_XLENS=32
make regression-test                         # scheduler/validation tests, no EDA tools
```

`regression` first runs **`format FORMAT_SCOPE=all`**, covering HDL and testbenches
in one pass. It edits tracked sources in place and finishes before any build starts. A formatting failure
blocks the build lanes. To leave formatting out of a run, omit `format` from
`REGRESSION_SUITES`; the default is `format coremark sta fpga`.

After formatting, up to `REGRESSION_JOBS` independent lanes run concurrently:

- **CoreMark:** NEMU RV32, sim RV32 with NEMU difftest, NEMU RV64, sim RV64 with
  NEMU difftest. These run serially because NEMU configuration/generated headers
  and AM libraries are shared. Each target gets its own Make invocation, avoiding
  RV32/RV64 target-specific variable inheritance on a shared prerequisite.
- **STA:** SRAM-macro `sta` for each requested XLEN, serially. Each has its own
  packed RTL and yosys-opensta workspace/results; installed scripts, platforms
  and tools are linked read-only by convention, without copying the toolchain.
  SRAM libraries retain the existing shared tool-managed location.
- **FPGA:** `fpga-build` followed by `fpga-timing-ok`, using the selected board
  and a private build directory. It does not load or flash hardware. Explicit
  board selection disables hardware auto-detection. The current strict timing
  gate supports Vivado boards; missing reports or unsupported vendor timing
  checks fail rather than silently pass.

Defaults: `REGRESSION_XLENS="32 64"`, `REGRESSION_BOARD=mlk_cu08_ku15p`,
`REGRESSION_JOBS=3`, `REGRESSION_TOOL_JOBS=4`, `REGRESSION_TIMEOUT=14400`
(seconds per target), `REGRESSION_ITERATIONS=2`. `RAPT_CONFIG`, `STA_PLATFORM`
and `CLK_FREQ_MHZ` select the preset and STA operating point (50 MHz by default
for both XLENs). FPGA uses its existing board/profile clock and boot defaults;
`REGRESSION_XLENS` selects CoreMark/STA variants, not an FPGA XLEN matrix.

The runner owns parallelism independently of parent `make -j`. Each child Make
gets `-jREGRESSION_TOOL_JOBS` (STA uses `-j1`; its backend also runs timing and summary in order). Verilator compilation uses the worker limit, simulation
uses one thread, and Vivado receives the same worker limit. This bounds the
requested concurrency, not total RAM use or every EDA tool's internal threads.
Do not run another NEMU configuration, AM build, formatter, or RTL generator in
the same checkout during this regression. A checkout lock prevents two instances
of this runner from overlapping; existing standalone Make targets do not use it.
Dependencies/toolchains must already be provisioned through the existing setup
flows. Run `make verilog` before starting concurrent lanes when the shared Chisel
decoders are missing or stale; decoder generation is not isolated by the lane directories. This command does not run toolchain installation targets.

A new `/tmp/raptor-chip-regression-*` directory holds independent logs, build
outputs, `summary.txt`, `summary.json`, the post-format tracked source diff and
Git status. Set `REGRESSION_OUTPUT=/absolute/new/directory` to retain outputs in
another location; an existing directory is rejected to avoid mixing runs.
NEMU and AM retain their normal shared build directories. `/tmp` can be cleaned
by the OS, so copy reports elsewhere for long-term retention.

Independent cases continue after failures. A failed FPGA build skips its timing
check. Any failure/skip produces a nonzero overall exit status. CoreMark checks
all three official CRCs and GOOD TRAP; the two-iteration default is a functional
regression, **not a valid EEMBC performance score** (the 10-second duration notice
alone is allowed). STA requires a timing report and rejects reported errors or
violated slack. SRAM placeholder timing retains its existing limitations; a
passing flow is not physical signoff. `summary.json` records commands, status,
exit code, duration, reason, log path, Git HEAD, tracked-diff hash and untracked-file hashes.

### Make interface checks

`make -C verify make-targets-test` checks removed aliases, formatting scopes and
benchmark flag invalidation. `make -C verify sta-flow-check sta-entrypoints-test`
checks the isolated SRAM/DFF runner and offline STA preflight. These checks do
not run synthesis, simulation workloads or FPGA builds.

### HDL review validation

Local results with Verilator 5.052 and the existing dirty worktree:

| Check | Configuration | Result |
| --- | --- | --- |
| `make -C verify verilator-directed` | Default target matrix | All 98 checks passed |
| `make -C verify riscof-classic RISCOF_CLASSIC_TIMEOUT=600 JOBS=2` | small-riscof, RV32 | 1276/1276 passed |
| `make build-rv32 build-rv64` | default | Passed |
| `make -C verify sigtest fuzz` | default, each ISA=rv32/rv64; SEED=42 FUZZ_NUM=20 FUZZ_LEN=200 MEM_RANDOM_DELAY=31 MEM_RANDOM_SEED=42 TIMEOUT=60; separate BUILD_DIR per ISA | Each: 5 signatures and 20 differential fuzz cases passed |
| `make cpu-tests-rv32 cpu-tests-rv64 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42 ARGS="-b -n -t 120"` | default | Passed |
| `make microbench-rv32 microbench-rv64 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42 ARGS="-b -n -t 900" MAINARGS=test` | default | Both XLENs reported MicroBench PASS and GOOD TRAP |
| `make -C verify coverage-build coverage-run-fuzz coverage-run-sigtest coverage-report` | small RV32; SEED=42 FUZZ_NUM=20 FUZZ_LEN=200 TIMEOUT=60 COV_LINE_MIN=50.0; sequential stages | HDL line 67.8%, branch 64.1%; line gate passed |
| `make -C verify issue-select-prove predict-history-prove rename-checkpoint-prove` | Existing parameter matrices | 5 selector, 4 history and 3 checkpoint cases passed |
| `sby -f zkt_cdb.sby` from `verify/formal`, using the repository OSS CAD environment | RV32/RV64, depth 12 | BMC and cover passed; not an unbounded proof |
| `make sta-check XLEN=32 RAPT_CONFIG=small` and XLEN=64 | slang elaboration | Passed |
| `make sta XLEN=32 RAPT_CONFIG=small` | SRAM, nangate45, 50 MHz | Passed; reported slack +18.04 ns and estimated Fmax 164.83 MHz |
| `make sta XLEN=64 RAPT_CONFIG=small` | SRAM, nangate45, 50 MHz | Passed; 647,977 cells, 980,189.79 um2, 93.0 mW, slack +18.04 ns and estimated Fmax 146.98 MHz |
| Linux RV32 kernel-entry workflow | default, difftest enabled | `Linux version 6.18.51` observed; `check_linux_boot.py --success-marker "Linux version"` passed |
| `make -C verify make-targets-test sta-flow-check sta-entrypoints-test` | Local tools | 18 tests passed |
| `make format FORMAT_SCOPE=all` then `make format-check FORMAT_SCOPE=all`; `git diff --check` | Tracked sources; new CDB/priority test files also formatted separately | Passed |

The Linux simulation was interrupted with SIGINT after reaching the entry marker;
the make command consequently returned nonzero. This is kernel-entry evidence,
not a complete userspace boot or completion of the 40-million-instruction run.
STA uses the existing SRAM model and is not physical signoff.

Strict `make lint` / `make lint-rv64` remain nonzero (269 / 264 warnings).
Both elaborate successfully with `LINT_EXTRA=-Wno-fatal`, retaining diagnostics;
that result must not be reported as strict lint passing. The full PDK/FPGA,
LiteX, RV32E and OS workflow matrices have not been established by this run.
Local command logs are under `/tmp/raptor-review-*.log`; they are temporary,
not committed validation artifacts. This record is not an unconditional
submission-ready declaration.
# w4 latency and prediction regression

Run `make -C verify w4-scaling` (or
`python3 verify/scripts/test_w4_scaling.py --build-dir /tmp/w4-scaling`).
This uses the production `default-w4` preset in RV32 and RV64, with assertions,
and checks unselected IQ wake retention, confirmed load wake, fresh-address load
requests, store permission precheck, byte coverage and per-port MMU/PMP store
forwarding, both fetch response stages, recovery, MUL/DIV reuse, and TAGE auxiliary
reads at both 8/7 and 10/9 index widths. Logs and `results.json` are saved under
the build directory. `--filter tb_tage` restricts the Python runner to predictor tests.

## Shared L2 TLB

`RAPT_L2TLB_ENTRIES=256` enables the shared direct-mapped instruction/data
translation cache in every preset except `small` and `middle` (which set zero).
This is independent of the L2 data-cache setting. Run both XLEN variants:

```sh
make -C verify verilator-l2tlb-rv32 verilator-l2tlb-rv64
make -C verify verilator-cached-ptw-rv32 verilator-cached-ptw-rv64
make -C verify verilator-l2tlb-l1i-epoch-rv32 verilator-l2tlb-l1i-epoch-rv64
make -C verify verilator-l2tlb-l1i-sret-rv32 verilator-l2tlb-l1i-sret-rv64
make -C verify verilator-l2tlb-cbo-rv32 verilator-l2tlb-cbo-rv64
```

The table test covers all 256 slots, direct-mapped replacement, ASID/global
matching, root/PBMTE/SBE separation, canonical addresses, full Sv39 PPNs,
arbitration and flush priority. The two-walker test checks cross-client reuse,
Svade faults, PBMT, superpage subpages, concurrent misses/fills, captured request
context, and cancellation during accepted reads or pending fills. The integration
targets enable the shared-cache port on real L1I/L1D instances and exercise
mapping-epoch changes, SRET cancellation and CBO translation/flush semantics.
Existing targets for those testbenches retain the bypass configuration.

### Floating-point out-of-order execution

The FP scheduler reuses `rapt_iq` with three value/tag operands and arithmetic-unit availability. `rapt_fp_registers` renames all 32 FPRs onto ROB result slots; `rapt_fu_result_queue` reserves completion capacity before launch. FP values and accrued flags become architectural only for the actual commit prefix.

```sh
make -C verify verilator-fp-registers-rv32 verilator-fp-registers-rv64
make -C verify verilator-feu-ooo-rv32 verilator-feu-ooo-rv64
make -C verify verilator-rou-fp-ooo-rv32 verilator-rou-fp-ooo-rv64
make -C verify verilator-ioq-fp-ooo-rv32 verilator-ioq-fp-ooo-rv64
make build-rv32 build-rv64 BUILD_PROFILE=fp-ooo-check
make -C verify rva22s64-fp-ooo-run RVA22S64_XLEN=32 RVA22S64_CORE_PROFILE=fp-ooo-check
make -C verify rva22s64-fp-ooo-run RVA22S64_XLEN=64 RVA22S64_CORE_PROFILE=fp-ooo-check
```

The block checks cover f0, RAW/WAR/WAW, same-group renaming, FMA's third source, GPR/FP tag separation, independent completion during DIV, continuous fixed-pipeline launch, randomized mixed-unit traffic, backpressure, canceled/late owners, multi-FP commit and precise flags.

`make -C verify/xsim/fpu all` also checks arithmetic against host references; ADD/SUB, MUL, FMA, S/D conversion and both integer-conversion directions include continuous streams, bubbles and flushes. The host-fenv arithmetic checks cover RNE/RTZ/RDN/RUP; FP-to-integer also checks RMM.

IOQ checks cover younger FLH/FLW/FLD completion, A/B payload selection (including B becoming head before its response), boxing, cancellation and removal without duplicate publication; rerun with `VERILATOR_DIRECTED_FLAGS="--binary --timing --assert -Wno-fatal -j 1 -DRAPT_IOQ_LOAD_RESPONSE_STAGE=1"` for registered responses.

The full-core `fp_ooo.S` checks renamed FP store data, mixed precision, integer round trips and an illegal-rounding trap with younger completed work. Its runner uses NEMU difftest with delay 0/7/63 and seeds 1/42. Existing FP privilege, context, page retry, nested IRQ and checkpoint regressions remain applicable. These functional checks do not establish FPGA frequency or area.

Validation on 2026-10-09 used the `default` preset, assertions enabled, and RV32/RV64 simulators built with `BUILD_PROFILE=fp-ooo-validated` from the working tree based on `f35ea31e`. The generated C++ used `-O0 -g0`; these runs measure functional behavior only. Memory-delay tests used delay maxima 0/63 and seed 1. The longer directed cases used a 180-second host timeout.

| Check | Result |
| --- | --- |
| FP rename, FEU mixed traffic, ROU/FEU commit/recovery, IRQ composition | Passed in RV32/RV64; FEU checked 1,241/1,245 completions |
| FP IOQ A/B publication and head transition | Passed in RV32/RV64 with `RAPT_IOQ_LOAD_RESPONSE_STAGE=0/1` |
| Existing 15 `app/tests/fp` programs | 60/60 NEMU differential runs passed |
| Directed FP/privilege/PMP/cross-page programs (16 XLEN/case combinations) | 32/32 NEMU differential runs passed, including RV64 page retry and nested IRQ |
| `sq-checkpoint-rv32/rv64 SQ_CHECKPOINT_KIND=fp64` | Save, restore and continued execution passed |
| Arithmetic references | ADD/SUB, MUL, FMA, conversion and integer conversion passed serial and continuous-stream checks; DIV/SQRT passed its existing 300,000-case check |
| `sta-check RAPT_CONFIG=default XLEN=32/64 MEMORY=sram/dff` | All four Slang elaborations passed; this is not STA |
| `config-macro-check`; Verilator lint with `LINT_EXTRA=-Wno-fatal` | Passed; lint retains unused-signal, width and naming warnings |

The preset elaboration sweep also passed `small`, `middle`, `default-l2`, `default-w3`, `default-w4` and `default-w8` in both XLENs and memory selections (28/32 combinations including `default`). `large` fails on an unsupported L1I SRAM shape; the pre-change source snapshot reproduces that failure. All 35 modified/new standalone SystemVerilog files for this change passed formatting. A subsequent repair replaced the BPU's formatter-incompatible preprocessor error with an explicit invalid module selection and formatted `tb_operand_value_spill_banked.sv`; repository-wide formatting and `git diff --check` now pass. `make -C verify bpu-config-check` checks all four predictors and rejects missing selections in both XLENs using Verilator (including nonfatal warnings) and Slang, with 20 cases passing. No whole-core STA or FPGA PPA result is claimed.

### Floating-point cycle performance

`scripts/fp_ooo_performance.py` builds `app/tests/baremetal/fp_ooo_perf.S` once per XLEN/case/precision and runs identical images on the pre/post FP-OoO simulators with NEMU difftest enabled. It requires equal retired-instruction counts inside the measured region and reports `baseline_cycles / candidate_cycles`. Each kernel has four warmup iterations followed by 64 measured iterations; CSR timing, loop and call overhead are included, while initialization, UART output and final self-checks are excluded. Independent arithmetic repeatedly overwrites the same destination to exercise WAW renaming; the chain cases have true RAW dependencies. These are synthetic kernels, not estimates of general application speedup.

The 2026-10-09 comparison used worktree snapshots based on `f35ea31e`, the build-time `default` preset (two-wide ordered stages, 32-entry ROB, ITLB/DTLB/L2TLB = 32/16/256, 16 KiB L1I/L1D, write-back L1D, L2 disabled), behavioral SRAM, and bare machine mode. The compiled Verilator source hashes prove that both configurations and every memory RTL source match. The snapshots include the earlier integer-completion and memory/TLB changes on both sides. Later worktree changes to the preset and write-back/PTW logic are excluded. Both host builds used Verilator 5.052 and an effective C++ `-O1 -g0`; host execution time is not a performance metric.

With AXI random delay disabled, the measured cycle counts were:

| Kernel | Baseline cycles | Candidate cycles | Cycle speedup |
| --- | ---: | ---: | ---: |
| Integer control, RV32/RV64 | 2,490 | 2,490 | 1.000x |
| Independent ADD, S/D, RV32/RV64 | 10,615 | 1,087 | 9.765x |
| ADD dependency chain, S/D, RV32/RV64 | 10,615 | 5,179 | 2.050x |
| Independent MUL, S/D, RV32/RV64 | 11,639 | 1,092 | 10.658x |
| Independent FMA, S/D, RV32/RV64 | 15,735 | 1,092 | 14.409x |
| FMA dependency chain, S/D, RV32/RV64 | 15,735 | 10,299 | 1.528x |
| DIV stream, S, RV32/RV64 | 9,079 | 7,483 | 1.213x |
| DIV stream, D, RV32/RV64 | 16,503 | 14,907 | 1.107x |
| DIV + 64 integer ADDs, S/D, RV32/RV64 | 4,599 / 6,455 | 3,396 / 5,252 | 1.354x / 1.229x |
| DIV + 16 independent FP ADDs, S/D, RV32/RV64 | 12,791 / 14,647 | 1,923 / 3,779 | 6.652x / 3.876x |
| Load/add/store, S/D, RV32 | 6,007 / 6,775 | 999 / 2,481 | 6.013x / 2.731x |
| Load/add/store, S/D, RV64 | 6,007 / 6,007 | 1,032 / 999 | 5.821x / 6.013x |
| CoreMark integer control, RV32 | 225,487 | 225,123 | 1.00162x |
| CoreMark integer control, RV64 | 228,463 | 228,126 | 1.00148x |

The full matrix passed 160/160 NEMU differential runs: 19 microbenchmark images plus CoreMark, two XLENs, two revisions, and delay maxima 0/63 with seed 1. The second memory seed and preloaded-output diagnostics add 12/12 passing runs. Each compared pair has the same guest binary hash and ROI retired-instruction count. One RV32 delayed CoreMark run reached its initial 180-second host timeout while printing results; it passed when rerun with a 600-second limit, and both attempt logs are retained. At delay 63, CoreMark ROI cycles are 264,596 → 264,241 (RV32) and 266,654 → 265,989 (RV64); the integer control changes by only +0.13% to +0.25% in cycle speed across the four samples.

The nonallocating partial-store path is an exception: RV64 single-precision load/add/store with AXI delay 0–63 and seed 1 takes 17,292 → 17,650 cycles (2.07% more cycles); seed 42 takes 17,120 → 17,352 (1.36% more). In this kernel the output is only written during warmup. The tested L1D allocates full-word stores, but a missing 32-bit store in RV64 goes to the bus without allocation. With `--preload-output`, output words are first read into cache: the same RV64 S kernel takes 6,007 → 1,386 cycles (4.334x) with either delay 0 or 63. The preloaded D kernel takes 6,007 → 999 (6.013x). This controlled comparison identifies the memory-policy bottleneck; the slowdown should not be hidden by averaging it into compute-only results.

CoreMark uses the same `ITERATIONS=1`, baseline `-O2` guest image for each pair and passes CRC checks. Its simulated duration is below the required ten seconds, so these are cycle comparisons, not official CoreMark scores. No target clock frequency, synthesis timing, area or FPGA utilization was measured; cycle speedups do not establish a wall-clock speedup after implementation.

### Upstream floating-point workload sampling (2026-10-09)

The [CoreMark-PRO integration](../app/benchmarks/coremark-pro/README.md) builds
the unchanged upstream nine-workload suite with F/D for RV32/RV64, using GCC
13.2.0, `-O2`, one context and one worker. All 36 pk/bare-metal ELFs built, and
all 18 bare-metal reference-validation runs passed on QEMU 8.2.2 `virt`.
The four FP workloads also passed full NEMU validation and separate `-v0`
performance-image runs. The initial NEMU check passed 16/18 workloads; both
`zip-test` runs exceeded the 1800-second host timeout during dataset initialization.
After moving NEMU's environment lookups outside its instruction loop, the same
zip images pass in 837.331 seconds (RV32) and 791.343 seconds (RV64). All 18 full
NEMU reference checks now pass. PC/register snapshots confirm the expensive
initialization repeatedly scans a growing string; no benchmark source or input
was changed. Per-workload status directories and phase-aware timeout reports
make subsequent slow runs diagnosable. The repair evidence is in
`build/coremark-pro-fixes/{report.md,results.json,manifest.json}`.
Software-interpreter cycles and these host runtimes are not RTL timing.

`scripts/coremark_pro_performance.py` uses those NEMU runs to capture architectural
checkpoints at 10%, 50%, and 90% of each performance ROI's instruction stream.
Both RTL implementations restore the same checkpoint, warm for 4096 instructions,
and measure approximately 16384 instructions at identical retirement boundaries.
Assertions and NEMU difftest remain enabled. All 24 selected pairs / 48 RTL runs
passed. These sparse windows measure individual execution phases; they do not
estimate full-program speedup or an aggregate/certified benchmark score.

The matched hardware snapshots are the same ones as the synthetic FP comparison:
two-wide, ROB32, 16 KiB L1I/L1D, writeback L1D, no L2, ITLB32/DTLB16/L2TLB256,
behavioral SRAM, bare M-mode, memory delay 0 and seed 1. Both derive from
`f35ea31ebd4044bcca2f1087e82b7762df121be7` with dirty source snapshots identified
by hashes and archives. Later independent memory/TLB changes are excluded.

| Workload | RV32 FP-window speedup | RV64 FP-window speedup |
|---|---:|---:|
| `linear_alg-mid-100x100-sp` | 5.644–5.783× | 3.526–4.081× |
| `loops-all-mid-10k-sp` | 2.114–4.480× | 3.765–5.725× |
| `nnet_test` | 2.788–2.901× | 3.837–4.180× |
| `radix2-big-64k` | 2.059–2.827× | 3.646–4.559× |

FFT's 10% window contains only integer memory-copy work and measures 1.000×
in both XLENs; its two FP windows form the range above. Ranges are observed
samples, not confidence intervals or workload averages. The comparison covers
the combined renaming, scheduling and arithmetic-pipeline changes and cannot
attribute the whole gain to OoO alone. No Fmax, area or FPGA speedup is claimed.

An RV32D sample exposed an assertion false positive: a split load in `MA_DONE`
coincided with a new store handoff, which conservatively raised `load_in_sq`.
The blocked-unissued-load assertion now applies only in `MA_IDLE`; synthesized
logic is unchanged. The minimal waveform, source-only correction, RV32/RV64
split-load regressions, and successful differential reruns establish the scope
of that fix. RV32 FFT cycles also match exactly between the original checkpoint
exit and the runner's bounded-cycle exit.

Local evidence is in `build/coremark-pro-sampled-provenance/{report.md,results.json,manifest.json}`,
with raw runs in `build/coremark-pro-sampled*-rv{32,64}` and full reference logs
in `build/coremark-pro-qemu-system-validation`. Build artifacts and waveforms
remain ignored. Run `python3 scripts/coremark_pro_performance.py --help` from
`verify/` for required simulator/image/report paths and sampling controls.
Its report checks are covered by:

```sh
python3 -m unittest discover -s app/benchmarks/coremark-pro -p 'test_*.py'
python3 -m unittest discover -s verify/scripts -p 'test_coremark_pro_performance.py'
make -C verify verilator-lsu-split-fault-rv32 verilator-lsu-split-fault-rv64
```

Embench F/D integration additionally built 76 application images and 19 LiteX
images, passed all 38 bare-metal NEMU reference checks, and passed RV32/RV64
pk hard-float smoke tests. Default SRAM Slang elaboration and configuration
macro checks passed in both XLENs. Repository-wide `make format-check FORMAT_SCOPE=all`
passes after the BPU configuration-guard and testbench formatting repairs above.

Example invocation, using already built RV64 simulators and boot ROM:

```sh
python3 verify/scripts/fp_ooo_performance.py \
  --xlen 64 \
  --baseline /tmp/raptor-fp-baseline/sim/build/fp-perf-before/riscv64-npc-sim \
  --candidate sim/build/fp-perf-after/riscv64-npc-sim \
  --reference nemu/build/ref/riscv64_ref_defconfig/riscv64-nemu-interpreter-so \
  --mrom verify/build/fp-ooo-app-fixed-rv64/mrom-rv64/mrom-data.bin \
  --coremark abstract-machine/app/am-kernels/benchmarks/coremark_eembc/build/coremark-riscv64-npc.bin \
  --output verify/build/fp-ooo-perf-rv64
```

Use `--cases load_add_store --preload-output` for the cache-resident diagnostic and `--seed 42 --delays 63` for the second delayed-memory sample. RV32 uses the matching simulator, reference, ROM and CoreMark image. Full commands, image/binary hashes, ROI instruction counts and logs are in the ignored `verify/build/fp-ooo-perf-rv32/results.json` and `fp-ooo-perf-rv64/results.json`. Exact compiled RTL archives, Verilator input manifests and host build logs are in `verify/build/fp-ooo-perf-provenance/`; these identify the measured dirty revisions more precisely than the shared Git base.

### Embench cycle benefit from the FP changes

`scripts/embench_performance.py` uses the same archived RTL models and matched
instruction-window method as CoreMark-PRO above. It first validates each complete
benchmark in NEMU and profiles every instruction between `start_trigger` and
`stop_trigger`. All 38 RV32/RV64 reference runs passed, and the profiled ROI lengths
exactly match the standalone interpreter counters. Eighteen of the 19 workloads
execute no FP instructions; wikisort executes only 216 FP arithmetic instructions
per ROI, or 0.01653% of RV32 instructions and 0.01426% of RV64 instructions.

The selected 114 pairs / 228 RTL window runs passed differential checking.
Fifteen workloads have exactly identical cycles at all sampled positions in both
XLENs. The remaining sampled ranges are:

| Workload | RV32 speedup | RV64 speedup |
|---|---:|---:|
| `picojpeg` | 1.000202× | 1.000128–1.000129× |
| `sglib-combined` | 1.006049–1.030962× | 1.006022–1.027151× |
| `slre` | 1.000134–1.000147× | 1.000217–1.000295× |
| `wikisort` | 1.000000–1.006373× | 1.000000–1.006276× |

Sglib's exact same 50% instruction interval also passed with approximately 32K
warmup instructions, measuring 1.017360× on RV32 and 1.014748× on RV64. It executes
no FP arithmetic, so its small gain cannot be attributed to FP arithmetic
throughput; the experiment does not isolate the mechanism of this combined change.

Wikisort additionally passed four complete RTL runs from reset, including the
normal warm-cache pass and result verification. Its full timed ROI changes from
1,191,841 to 1,190,339 cycles on RV32 (1.001262×, 0.1260% fewer cycles), and from
1,322,835 to 1,321,227 on RV64 (1.001217×, 0.1216% fewer cycles).

Three initial checkpoints began on a store and failed identically in both RTL
versions because REF resynchronization can precede that store's buffered memory
write. The selected RV32 edn 90% and RV32/RV64 sglib 10% checkpoints start exactly
one unchanged guest instruction later. The original failures are retained. The
RV64 longer-warmup diagnostic needed the same adjustment while preserving its
exact measured instruction interval. Assertions and difftest remain enabled.

These are local phase measurements plus full wikisort timing, not a whole-suite
Embench score. The combined Embench/CoreMark-PRO evidence is in
`build/fp-benchmark-benefit/{report.md,results.json,manifest.json}`; it records
280 selected RTL runs plus four longer-warmup diagnostics, source and image
hashes, configuration, commands and exclusions. Raw data is in
`build/embench-fp-*`. Run `python3 verify/scripts/embench_performance.py --help`
from the repository root for simulator-manifest and sampling options.
