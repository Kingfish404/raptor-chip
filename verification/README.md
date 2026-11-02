# Verification

Run commands from the repository root. `make -C verification help` lists supported
entry points and variables. Software payloads live in `app/tests/`; runners,
references and RTL testbenches live here. Keep results outside the source tree
when comparing revisions or configurations.

## Quick start

```sh
make -C verification config-macro-check script-unittests
make -C verification verilator-directed-registry-check
make -C verification verilator-directed BUILD_DIR=/tmp/raptor-directed
make -C verification unit-fpu
```

Verilator module checks need a C++ compiler. Core programs additionally need the
RISC-V toolchain, generated decoders, a matching simulator, NEMU reference library
and MROM. Use `source env.sh`, `make verilog`, and the root `build-rv32` /
`build-rv64` targets to prepare those inputs. `make setup-rtl` provisions the main
RTL development dependencies.

## Maintained verification layers

| Layer | Entry point | Main coverage |
| --- | --- | --- |
| Modules/composition | `verilator-directed[-all]` | Results, ordering, backpressure, faults and recovery |
| XSim | `xsim`, `xsim-lsu-sq-random` | Alternative simulator for the shared directed benches |
| FPU arithmetic | `unit-fpu` | Host/SoftFloat references, rounding, streams and cancellation |
| VPU | `make -C verification/vpu test` | Integer/FP, memory, context and optional Spike comparison |
| Core programs | `rva22s64-directed`, `sigtest` | CSR, privilege, MMU, PMP/PMA, atomics, FP and exceptions |
| Core differential fuzzing | `fuzz`, `riscv-dv`, `cascade-fuzz` | Generated programs with independent references |
| Architecture compliance | `riscof`, `riscof-classic` | ACT4/Sail self-checking ELFs and classic RISCOF signatures |
| Formal | `formal`, `formal-scope`, `formal-signoff` | Safety properties and scoped proof evidence |
| UVM | `uvm`, `uvm-chip-regress` | Module scoreboards and whole-chip AXI, interrupts, debug and faults |
| Debug | `jtag-selftest` | DTM/DM compliance and OpenOCD smoke checks |
| NEMU | `nemu-{unit,isa,multihart}-check` | Reference ISA, VM, devices and replay |
| Trace replay | `make -C verification/subsystem all` | Frontend, backend and memory composition replay |
| Sampling | `make -C verification/performance help` | Capture, reference validation and workload windows |
| Coverage | `coverage` | Instrumented line/toggle collection; no project-wide percentage gate |

The core's private L1 memory connects through `l2_client_if` to the cluster's
`rapt_l2_subsystem` and router. A core or memory-only check stops at that client
port; whole-chip checks include the shared subsystem. Preserve this scope when
interpreting results. A compile, local proof or synthesis run does not establish
whole-core correctness or board timing closure.

## Directed checks

```sh
make -C verification verilator-ioq-store-stage-rv32 verilator-ioq-store-stage-rv64
make -C verification verilator-fetch-prediction-rv32 verilator-fetch-prediction-rv64
make -C verification verilator-l1d-writeback-rv32 verilator-l1d-writeback-rv64
make -C verification verilator-l2-forwarded-client-rv32 verilator-l2-forwarded-client-rv64
make -C verification w4-scaling
python3 verification/scripts/directed_registry.py list
```

`verilator-directed` is the selected gate; `verilator-directed-all` includes every
registered directed check. The registry rejects missing targets and orphaned
configuration overrides. `XSIM_RAPT_CONFIG` selects a preset (`default` by default),
while target suffixes select RV32/RV64. Some tests explicitly select a preset or
parameter matrix; inspect their row in `directed-tests.mk` before overriding it.
`VERILATOR_DIRECTED_DELAY` and `VERILATOR_DIRECTED_SEED` control tests that expose
random bus timing. Shared flags are in `VERILATOR_DIRECTED_FLAGS`.
The supported `xsim-*` aliases select the same rows in `directed-tests.mk`;
there is no separate XSim source/define table. They forward shared delay/seed
settings and translate plusargs for XSim. `LSU_SQ_RANDOM_SEED` still supplies the
legacy SQ seed unless `VERILATOR_DIRECTED_SEED` is explicitly set.
XSim/UVM runners require their completion marker and reject tool/UVM errors even
when the simulator process returns zero.

RTL files resolve by module name, with `rapt_pkg.sv` first and other RTL files as
Verilator libraries. Testbench tops resolve from their actual `module`
declarations, including multiple scenarios in one source file. Neither requires
a filename exception table when RTL or benches are split or renamed. Duplicate
top names fail source discovery.

Add paired checks with `XLEN_TEST(name, top, helpers, flags, plusargs, follow-up)`
in `directed-tests.mk`. `DIRECTED_TEST` handles explicit target lists and parameter
matrices. Only name non-RTL helper sources. Escape recipe-time Make variables as
`$$`. Keep unusual multi-command recipes explicit.

Prefer scenarios in an existing family and shared fixtures in `xsim/`. Check
observable results, accepted transactions, ordering, exceptions and recovery.
Avoid checking private state names, array layout, a particular pipeline stage or
exact cycle counts unless they are part of a documented interface contract.
Storage replication, local arbitration and one-off pipeline experiments do not
need permanent standalone regressions when composition checks cover the outcome.
Use waveforms and a minimal payload when a behavioral failure needs diagnosis.

## Architectural programs and fuzzing

```sh
make -C verification rva22s64-directed RVA22S64_XLEN=32
make -C verification rva22s64-directed RVA22S64_XLEN=64
make verify-sigtest
make verify-fuzz
make verify-coverage
```

The RVA22S64 case table is in `verification/Makefile`; RV64-only cases are skipped
in RV32. Each guest has a separate output directory. Override `RVA22S64_NPC` and
matching `NEMU_SO_32` / `NEMU_SO_64` for externally built simulators/references.
The MROM follows the guest's XLEN independently of `ISA`. Script runners compile
with the shared platform include path; addresses come from
`app/lib/raptor_platform.h`.

Use `ISA=rv32|rv64`, `SEED`, `FUZZ_NUM`, `FUZZ_LEN`, `TIMEOUT`,
`MEM_RANDOM_DELAY` and `MEM_RANDOM_SEED` to make fuzz runs reproducible. Record
preset, XLEN, source fingerprint, seed, command and result together. Inspect the
retained failing program and log before broadening a campaign.

ACT4 uses Sail-generated expectations and self-checking ELFs:

```sh
make -C verification riscof-setup
make -C verification riscof-gen ISA=rv32
make -C verification riscof-run ISA=rv32
make -C verification riscof-gen ISA=rv64
make -C verification riscof-run ISA=rv64
```

`ACT4_CONFIG`, `ACT4_EXTENSIONS`, `ACT4_ELF_DIR` and `ACT4_TIMEOUT` select the
configuration, corpus, output and run budget. Generation success alone does not
prove that tests were selected or executed. See the
[RV64 supervisor configuration](riscof/raptor-rv64s/README.md) for Sv39/Svade and
Zfhmin/D selection. Historical acceptance ledgers are not evidence for current
RTL; retain actual reports with each source/configuration snapshot.

Classic RISCOF remains available through `riscof-classic` and
`riscof-classic-nemu`; it uses its pinned Sail/reference setup independently of
ACT4. `scripts/test_riscof_classic_runner.py` and
`scripts/test_riscof_classic_sail.py` check failure handling without an EDA run.

## External generators and model checking

```sh
make -C verification riscv-tests-setup RISCV_TESTS_ROOT=/tmp/raptor-riscv-tests
make -C verification riscv-tests ISA=rv32 RISCV_TESTS_ROOT=/tmp/raptor-riscv-tests
make -C verification riscv-dv ISA=rv64
make -C verification formal-pono-recovery PONO_OUT=/tmp/raptor-pono
make -C verification cascade-setup CASCADE_ROOT=/tmp/raptor-cascade
make -C verification cascade-fuzz ISA=rv64 CASCADE_ROOT=/tmp/raptor-cascade
```

Pins and options live in `external-verification.mk`. Setup rejects wrong or dirty
upstream revisions. RISCV-DV needs its supported Python environment; its M-mode
projection does not establish complete supervisor, interrupt or ISA coverage.
Cascade needs Spike, the matching NEMU reference and Python 3.11+. Failures and
seeds are retained; timeouts or missing observations must not count as passes.
Pono needs native Slang/Yosys, Pono and btorsim; distinguish bounded runs from
inductive proofs. `extended-campaign` combines isolated lanes and records their
source snapshots and individual budgets.

## Formal, UVM and reference checks

`make -C verification/formal help` lists block formal entry points.
`formal-scope` inventories evidence; `formal-signoff` requires the configured
receipts/reviews. Native elaboration and individual proofs do not qualify
unrelated RTL or prove system-level progress. Keep assumptions, depth, tool
versions, activation witnesses and counterexamples with the result.

`script-unittests` covers shared runner and evidence checks without EDA tools.
Native driver regressions (`python3 verification/scripts/test_formal_drivers.py`)
also need Slang support for `$past` and initialization. Select the compatible
Yosys executable with `RAPTOR_YOSYS_REAL`.

`formal-clint` qualifies the production bus interface, register byte lanes,
timer/interrupt state and both sampling-restore branches. Its reviewed divider
bindings are 1, 3 and the platform default 100. Other divider overrides need
additional bindings. `FORMAL_CLINT_PRESETS` limits presets for focused work.

The [UVM guide](uvm/README.md) covers module environments and the independent
whole-chip scoreboard. Whole-chip runs require a class-capable Verilator and
Accellera sources selected with `UVM_HOME`. The IQ/CSR interface, package and top
are kept together in one source per module family; top names and public targets
are unchanged. XSim's historical larger-class elaboration limitation is separate
from a DUT failure.

NEMU checks use `nemu/check.py NAME`; `NAME --help` lists per-check options.
`nemu/nemu.mk` defines targets, while `nemu/lib`, `nemu/isa`, `nemu/multihart` and
`nemu/tests` hold shared adapters and suites. Vector unit comparisons share
`nemu/tb_vector_units.sv`, with a separate top for each operator and the existing
`vector-<unit>-rtl` commands. The
[NEMU guide](../nemu/README.md#checks) documents model capabilities and VM/replay
limits. These reference-only features are distinct from current RTL support.

## Regression and maintenance

```sh
make regression-plan
make regression REGRESSION_XLENS="32 64" REGRESSION_JOBS=3
make regression-test
make -C verification make-targets-test sta-flow-check sta-entrypoints-test
make format FORMAT_SCOPE=all
make format-check FORMAT_SCOPE=all
```

The whole-project runner formats first, then schedules CoreMark, STA and FPGA
lanes. Use `REGRESSION_SUITES`, `REGRESSION_BOARD`, `REGRESSION_TOOL_JOBS`,
`REGRESSION_TIMEOUT`, `REGRESSION_ITERATIONS` and `REGRESSION_OUTPUT` to select a
run. Shared NEMU/AM configuration must not be changed by another build during
that regression. Inspect `regression-plan` before launching expensive tools.

Application benchmarks and their comparison limits are documented in
[app/README.md](../app/README.md). Physical timing/area checks belong in `synth/`
and `layout/`; run small blocks before composition blocks and reserve full STA
or FPGA implementation for candidates that pass those checks.

For comparisons between prebuilt simulators, use `scripts/width_evaluate.py`
with repeated `--profile LABEL=BINARY` arguments, or
`scripts/execution_port_workloads.py` with profiles and `--workload LABEL=IMAGE`.
Their `--help` output lists input/reference and output options;
`scripts/execution_port_report.py` summarizes the latter's results. Keep the
compared images and memory settings identical. Fixed port/scan-width experiment
targets and PRF/RNU snapshot proofs have been retired; current contract checks,
formal entry points and generic synthesis flows remain available.
