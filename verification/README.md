# Verification

Run commands from the repository root. `make -C verification help` lists supported
entry points and variables. Software payloads live in `app/tests/`; runners,
references and RTL testbenches live here. Keep results outside the source tree
when comparing revisions or configurations.

The [25-signal chip integration](../synth/configs/io25/README.md) has paired
`verilator-chip-io25-bus-rv32/rv64` peripheral checks and
`verilator-chip-io25-rv32/rv64` CPU/pad boot checks. Select an RV64-capable preset
for RV64, such as `XSIM_RAPT_CONFIG=small`; `chip32-small` is RV32-only.

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
make -C verification XSIM_RAPT_CONFIG=formal \
  verilator-l1i-reset-dominance-rv32 verilator-l1i-reset-dominance-rv64
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
The L1I reset check reaches a stalled refill through ordinary requests, then checks
cold and warm reset, pending invalidation, pipeline recovery and request reissue.
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
ALU and CLINT checks use their native matrix drivers through these Make targets.
`formal-scope` inventories evidence; `formal-signoff` requires the configured
receipts/reviews. Native elaboration and individual proofs do not qualify
unrelated RTL or prove system-level progress. Keep assumptions, depth, tool
versions, activation witnesses and counterexamples with the result.

`script-unittests` covers shared runner and evidence checks without EDA tools.
Native driver regressions (`python3 verification/scripts/test_formal_drivers.py`)
also need Slang support for `$past` and initialization. Select the compatible
Yosys executable with `RAPTOR_YOSYS_REAL`.

With assertions enabled, `RAPT_FORMAL_NATIVE` lowers clocked implications for
native Slang. Next-cycle checks cancel pending obligations on asynchronous reset;
sampled expressions keep their clock context. Array reads may need named
assertion-only predicates. Enabling this frontend mode is not proof that the
embedded contracts hold; retain their counterexamples and producer obligations.
Formal scope and native matrix drivers honor fixed-XLEN preset declarations.

`formal-clint` qualifies the production bus interface, register byte lanes and
timer/interrupt state. Its default divider bindings are 1, 3, 5, 10, 20, 25, 50 and
100, including FPGA clocks and documented clock/timebase examples. The
Python driver's `clint --dividers` option selects an explicit set; other divider
overrides need additional bindings. `FORMAL_CLINT_PRESETS` limits focused work.

The native CLINT and AXI drivers accept `--reuse-evidence` for a completed matrix
from the same Yosys build. Every requested binding is freshly elaborated. Reuse
requires identical complete frontend graphs, audited induction commands and logs,
and every activation query and witness. Mutation controls run again. The Make
variables are `FORMAL_CLINT_REUSE_EVIDENCE` and `FORMAL_AXI_R_BUFFER_REUSE_EVIDENCE`.

`make -C verification formal-sram FORMAL_SRAM_ARGS=--qualify` also emits SRAM
binding reviews and receipts. It compares each requested preset and synthesis
context with the complete proved memory graph. Add `--presets formal` inside
`FORMAL_SRAM_ARGS` for focused binding work; other profiles remain pending.
The `smtbmc-induction` receipt method checks the fixed native preparation recipe,
actual base and induction passes, complete predicate inventories and every cover
waveform. Macro cases use registered functional port models; physical macros and
timing are outside this RTL equivalence claim.
The SRAM observer samples its initial word without constraining DUT storage,
then checks all bits through partial writes and reads of unwritten data.

`python3 verification/scripts/formal_contract.py completion-guard --output <directory>`
qualifies complete completion-owner guards with unconstrained inputs. The matrix
checks live generation identity, executing state, both payload policies and unused
index encodings against an independent owner-table walk. It includes singleton,
odd and power-of-two table sizes, over-wide indexes, all base profiles and both
synthesis contexts. Five mutations must produce actual counterexamples. Other
parameter overrides and producer/ROB lifetime contracts remain separate work.

`make -C verification formal-debug` runs the common debug contract driver.
Its default `formal` preset exercises RV32/RV64, DM physical addresses of 32 bits
and RV64 38 bits, and arbiter read/write credit pairs (1,1), (2,2), (32,1), (32,4).
Use `FORMAL_DEBUG_ARGS="--blocks dm arbiter --presets formal"` for focused work.
Positive cases require base and induction passes plus a waveform for every cover;
each injected RTL fault must fail an assertion and produce a counterexample.
`--controls skip` is exploratory and records that policy in the result.

The DM checks include precise halt capture, held resume, SBA stalls, malformed
responses, bus errors, byte strobes, busy access, autoincrement and deactivation
while a transfer drains. Its responder needs no fairness assumption. Arbiter
proofs assume legal stalled AXI sources, reserved SBA ID 15, bounded core credits
and responses following accepted addresses; they check ownership, response
routing, backpressure and idle accounting. These producer obligations still need
composition with the actual core, SBA and router.

The step check reuses the complete production ROU wrapper and checks admission
capture, single-lane entry, token preservation, fetch blocking, interrupt masking
and delayed resume acknowledgement. Its four-edge base case and induction prove
unbounded safety; this does not establish instruction execution or retirement.
The reset check composes the production arbiter with a verbatim copy of the
inline controller from `rtl/rapt.sv`, retaining its source offsets and hash.
Upstream core/L2 quiescence, top-level wiring, other parameter domains and system
progress remain open. These debug results emit no whole-unit signoff receipts.

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

## Direct chip Flash

The [direct Flash integration](../docs/chip-flash.md) has paired RV32/RV64
`verilator-spi-flash-*`, `verilator-spi-flash-delayed-*`,
`verilator-spi-flash-identity-*`, `verilator-spi-flash-max-time-*` and
`verilator-spi-flash-boot-*` checks. The
CPU checks build raw firmware using `CROSS_COMPILE` and execute reset-vector XIP,
RAM initialization/execution and Flash erase/program/readback without the custom
FPGA bridge. Set `BUILD_DIR` outside the checkout for images, binaries and logs.

`verilator-chip-xspi-boot-rv32` / `-rv64` execute default ROM-XIP, JTAG/SBA
selection of the bridge, repeated ndmreset, return to Flash with retained octal
protocol, and chip-reset default restoration. They check IRQ in both modes and
released pad ownership during switching. `verilator-chip-io25-rv32` / `-rv64`
exercise two pad-level ROM-XIP boots, reset, JTAG IDCODE, both UARTs, GPIO and a
verified EBREAK good trap. Outputs belong in an external `BUILD_DIR`.
