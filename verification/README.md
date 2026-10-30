# Raptor Chip: Verification Suite

`make -C verification verilator-l1d-permission-stage-rv32
verilator-l1d-permission-stage-rv64` checks LR interference, cancellation and subsequent
recovery in the load permission stage.

M-extension privilege/edge regression: `make -C verification rva22s64-m-privileged-edges-run` uses the configured `RVA22S64_XLEN`, `RVA22S64_NPC` and matching reference library. Set `RVA22S64_TEST_CPPFLAGS=-DM_TEST_PRIV=0` (U), `1` (S), or `3` (M, default), and use distinct `BUILD_DIR` values for different configurations. The test checks literal arithmetic edge results, source/destination overlap, and RV64 word sign extension. Three reserved OP-32 encodings exercise this platform's illegal instruction policy, including cause, EPC, original instruction and unchanged rd.


Unified verification infrastructure for the Raptor Chip RISC-V processor. Full-core tests use the Verilator simulator (`sim/`); differential tests use NEMU. Module, formal, ACT4/Sail and UVM checks have separate harnesses and references. Each target defines its own tool and configuration requirements.

The pinned upstream `riscv-tests`, RV32/RV64 RISCV-DV, Pono and Cascade flows are described
under [External verification flows](#external-verification-flows). Each flow has its own
reference model, configuration limits and result checks.

Software test sources live in `app/tests/baremetal/` (freestanding RISC-V programs and shared headers) and `app/tests/host/` (native simulator/reference tests). Build rules, runners, linker scripts and generated vectors stay in `verify`. C++ drivers coupled to RTL testbenches stay with their `xsim` or `vpu` harnesses. Use the current targets below; simulator and STA artifacts follow the profile-isolation rules in `sim/README.md`.

## Maintaining verification drivers

NEMU checks live in `nemu/`: `nemu/check.py NAME` runs one check, `nemu/nemu.mk`
defines the `nemu-*-check` targets, and `nemu/lib`, `nemu/multihart`, `nemu/isa` and
`nemu/tests` hold the shared harness, multi-hart checks, single-hart checks and unit
tests. Targets and options are listed in [the NEMU guide](../nemu/README.md#checks).

`make -C verification config-macro-check` audits unused/undefined preset macros and exactly one direction predictor; it also runs in `script-unittests`.
`make -C verification bpu-config-check` additionally elaborates all four direction
predictors in RV32/RV64 and verifies that a missing selection fails in both
Verilator and Slang, including Verilator's `-Wno-fatal` mode.

Directed module rules name only their testbench top and any non-RTL helpers. RTL resolves by module name: `rapt_pkg.sv` compiles first and every other `rtl/` file is a Verilator `-v` library (`XSIM_RTL_LIBRARY`; the xsim flow compiles `XSIM_RTL_ALL`). Adding, splitting or renaming RTL therefore needs no rule edits, and testbench stubs take precedence over library modules. All rules share `VERILATOR_DIRECTED_FLAGS` (warnings are not fatal; `make lint` owns lint); a rule appends only what it needs, such as `-G` parameters or `-CFLAGS -O0`. Guest programs compile with `GUEST_CPPFLAGS` (script runners through the exported `CPATH`) and take platform addresses from `app/lib/raptor_platform.h`. The RVA22S64 directed programs are one `RVA22S64_CASES` table (`RVA22S64_RV64_CASES` marks RV64-only sources); `make -C verification rva22s64-directed RVA22S64_XLEN=32|64 RVA22S64_NPC=...` runs them all; RVA22S64 and SQ-checkpoint targets pick the MROM from their own XLEN, so `ISA` need not match.

New directed module checks that run in both XLEN modes should add a row to `directed-tests.mk` using `XLEN_TEST(name, top, helpers, flags, plusargs, follow-up)`. It creates the paired `verilator-<name>-rv32/-rv64` targets through `VERILATOR_DIRECTED_XLEN_RUN`; the target name selects `RAPT_RV64` and the build stem. Escape recipe-time variables as `$$` in the table. `DIRECTED_TEST(target suffixes, build stem, top, helpers, flags, plusargs, follow-up)` records existing single targets and parameter matrices with their original build stems. Both forms preserve recipe-time options and target-specific flags. Keep exceptional multi-command build rules explicit in the main Makefile. `make -C verification script-unittests` runs tool-free helper-script unit tests that have no dedicated check target.

Extend an existing bench's scenario or parameter matrix before copying its fixture. IQ CDB wake and stalled capture share `tb_iq_cdb_wake.sv` (`ComboCdbWake` / `HoldCycles`); W4 store precheck uses the superset `tb_ioq_store_stage` in `tb_ioq_all_contract.sv`. FPU host differential builds share `xsim/fpu/host-diff.mk`; component Makefiles retain their DUT lists, rounding flags and extra references. Yosys drivers import `yosys_common.run_yosys`, not another test runner. The RTL and NEMU classic flows share the Sail plugin and environment under `riscof/classic/plugins/sail_cSim`; `classic-nemu/config.ini` selects its own `nemu.json` and timeout. Run `python3 verification/scripts/test_riscof_classic_sail.py` from the repository root to exercise both profiles without installing RISCOF.

`make -C verification sim-build-isolation-check` tests build-local simulator Kconfig and option-keyed caches. See [simulator configuration and parallel builds](../sim/README.md) for profile selection, cache reuse, and remaining NEMU/tool concurrency limits.

`make -C verification yosys-sq-span-equivalence` uses Yosys SAT to prove the actual SQ address-span helper against full-width modular subtraction for RV32/RV64. Addresses, both two-bit spans and the page-offset-only selector are unconstrained; page and XLEN wrap are included. The proof adapter extracts the RTL helper and translates its single return to a function-result assignment for Yosys. This is a combinational helper proof, not a full SQ lifecycle proof or FPGA STA.

`make -C verification verilator-sq-forward-ring-rv32 verilator-sq-forward-ring-rv64` checks SQ forwarding at 2/4/16/32 entries and one/three load ports. It exhausts all valid masks at every head through 16 entries, checks every single/pair at 32 entries, and runs a seeded byte-enumerated alias oracle with partial stores, stale translation contexts, page/address wrap, FP64 spans, pending allocation and CBO.ZERO. Data is checked even when forwarding is blocked. The existing `verilator-sq-forward-ports` / `verilator-sq-forward-ports-rv64` targets provide additional directed span checks. These are behavioral tests, not a formal equivalence proof or whole-chip FPGA timing acceptance.

`make -C verification verilator-btb-storage-rv32 verilator-btb-storage-rv64` checks two-way BTB storage against a transaction-level reference at three set counts, including the default and a non-power-of-two depth. It exercises simultaneous reads/writes, updates while the read address is held, matching and missing type-only writes, LRU replacement, and reset/init priority. The read latency and write-visible behavior must remain unchanged when the payload arrays infer distributed RAM. These are behavioral checks, not a guarantee of RAM inference or whole-chip FPGA timing.

Binary16 conversion checks use `make -C verification/xsim/fpu/half run flush`. Use separate absolute `BUILD_DIR` paths with `XLEN=32` and `XLEN=64` to avoid stale tool-version caches. `run-softfloat SOFTFLOAT_DIR=/absolute/path` expects `include/softfloat.h` and a built `softfloat.a` in that directory. The reference test covers five rounding modes, every finite source exponent, sparse/dense and random source subnormals, normal/subnormal rounding boundaries, overflow and exception flags. These are component checks, not full-core or FPGA timing acceptance.

`make -C verification verilator-completion-stage-rv32 verilator-completion-stage-rv64` checks the accepted-completion register with distinct full-width packets on every port, sustained traffic, bubbles, repeated flushes and midstream resets. It also exercises each instance's packet-history assertion. These local checks do not replace full-core fast-load/FP/recovery differential tests or FPGA STA.

`make -C verification verilator-cbo-set-rv32 verilator-cbo-set-rv64` checks CBO set scope across every resident word/way, VA page aliases, pending refill cancellation, and retained global maintenance. Repeat with `XSIM_RAPT_CONFIG=small` to check a 64-byte CBO spanning four 16-byte cache lines. `verilator-cbo-tlb-rv32` / `verilator-cbo-tlb-rv64` use real Sv32/Sv39 PTW fills and verify that CBO preserves both DTLB replicas. The ROU dual-commit tests also cover CBO SQ drain, completion generation, fault/wrong-path suppression and ZERO retirement; UVM `memory` and `mmu` exercise decoded CBOs through the complete core.

`make -C verification verilator-ifu-response-stage-rv32 verilator-ifu-response-stage-rv64` checks response capture, sustained delivery, mixed 16/32-bit instruction streams, branch/history event conservation, randomized cache availability and downstream backpressure, fault metadata stability, and recovery with both IFU buffers full. It also checks that a buffered response blocks instruction IO authorization when successive dynamic requests have the same PC. The address-driven scoreboard supports width overrides and `RAPT_FETCH_RESPONSE_STAGE=0` comparisons.

`make -C verification verilator-iq-deferred-reclaim-rv32 verilator-iq-deferred-reclaim-rv64` checks registered vacancy admission with randomized allocation, wakeup, issue and flush. It rejects same-edge reuse of a resident issue slot. This is the integrated `rapt_iq` mode (`ReclaimOnIssue=0`) for every preset; the other reclaim tests exercise the module's optional same-edge mode (`ReclaimOnIssue=1`).

`make -C verification verilator-hum-request-stage-rv32 verilator-hum-request-stage-rv64` checks the registered hit-under-miss B request with the default preset (`XSIM_RAPT_CONFIG=default`, HUM enabled). It covers capture latency, payload and owner stability while an older candidate wakes, simultaneous A/B responses, flush/late response rejection, fallback after A completes, and FLD fallback through A with a full 64-bit FPR write. These are IOQ contract tests, not Linux or FPGA timing acceptance.

Translated MMIO replay regressions use `make -C verification` with these RV32/RV64 pairs:

- `verilator-ioq-mmio-retry-rv32` / `-rv64`: younger request deferral, older load progress, and replay only after both IOQ and ROB heads reach the owner.
- `verilator-translated-mmio-retry-rv32` / `-rv64`: real IOQ/SQ/L1D and Sv32/Sv39 walks, delayed responses, no speculative device read, and exactly one ordered device read. The resulting `tb_translated_mmio_retry` binary also accepts `+FLUSH_RETRY` and `+FLUSH_DEFERRED` for retry/flush collision and deferred-owner cancellation checks.
- `verilator-split-load-retry-rv32` / `-rv64`: retry at every LW/FLD split beat, including RV32's third beat, an intervening aligned load, and fresh merged data.

These tests cover the retry contract, not FPGA timing or Linux networking acceptance.

`make -C verification verilator-l1i-access-sizes-rv32 verilator-l1i-access-sizes-rv64` compares the fixed 2/4-byte fetch permission checks and late result select with the dynamic-size PMP interface. Each XLEN checks 20,000 cases with fixed seed `9e3779b9`, both lookahead settings, all SRAM-ready/instruction-length combinations, boundary addresses, fault ownership, and unchanged PTW/PTE checks. This is combinational equivalence regression coverage, not a timing benchmark or a formal proof. The targets are also part of `verilator-directed`.

The PMA capability/span and instruction-word proofs use the subcommands `pma-capabilities`, `pma-span` and `ifetch-word-atomic` of `scripts/formal_contract.py` for execution and evidence reporting. Each entry retains its own harness, proof command, timeout and success criterion. Include the shared module when copying these drivers into an isolated tool bundle. Keep scenario assertions in their individual tests; share setup and execution only when their contracts match.

`scripts/logic_check.py` runs the `rank-select`, `rob-age-mask`, `rob-dispatch-select`, `issue-select`, `ras`, `predict-history` and `dispatch-admit` proof matrices. Existing Make targets retain their matrices and output directories. The shared runner preserves each harness's assumptions, reset/induction bounds, success marker and generic synthesis command; `--mode prove|synth|all` selects the work (dispatch admission is proof-only). Reports retain the existing case fields and mark completion only after all selected cases pass and source hashes remain unchanged. `issue-select-audit-test` checks this shared failure/reporting behavior. Generic cell counts and logic depth remain synthesis proxies, not physical area or timing.

Issue-selection references use structural per-port/per-entry comparisons and
structural legality/cardinality checks so large geometries do not require a larger
procedural-loop interpretation limit. The port-first oracle, unique active ages,
compatibility, one-hot/disjoint grants and two-port matching conditions are retained.
`yosys_common` respects `RAPTOR_YOSYS_REAL` when selecting a compatible frontend.

Checkpoint scenarios use `scripts/checkpoint_milestones.py fp` or `bus-error`, followed by the existing input/output options. Both run fresh save/exit/load sequences at each named milestone and delay; FP register-state checks and posted-write status/address/error-count checks remain distinct. `rva22s64-bus-error-checkpoint-run` selects the latter.

Scripts in `scripts`, `tests` and `experimental` need a documented consumer. Requirement scenarios named by the RISCOF ledger must remain identifiable; when they share a source, record its selection parameters in the ledger. Experimental RTL is retained only when it has a formal/synthesis consumer or a documented opt-in experiment.

Prefer a target-specific `RVA22S64_TEST_SOURCE` and `RVA22S64_CASE_CPPFLAGS` for guest variants over a separate `.S` file containing only a define and include. The CLINT shared-time, FP nested-interrupt/Svinval retry, floating-point PMP load, exact LR extent, PTW PMA and split-page variants use this arrangement. Their existing Make target names, images and result directories remain separate.

Related helper unit tests share one module: `scripts/test_sta.py` contains STA runner, preflight and summary checks; `test_width_evaluate.py` includes report parsing and interrupted-run evidence; `test_execution_port_workloads.py` includes output validation and aggregation; `test_lrsc_trace_check.py` includes progress-result classification. Existing Make check targets select the relevant classes. FP moves, arithmetic, conversion and coverage targets are defined in `app/tests/fp/Makefile`.

Shared L1D interfaces and DUT wiring live in `xsim/tb_l1d_harness.svh`; CSR execution wiring lives in `xsim/tb_csr_execute_dut.svh`. These are module-local includes without guards. CSR overrides (`TB_CSR_HART_ID`, `TB_CSR_TIME`, `TB_CSR_BUS_ERROR`) are consumed and undefined by the include; clocks, stimulus and checks stay in each test module.

The floating-point boundary programs `fp_tininess_boundary.S`, `fp_product_tininess.S`, `fp_convert_tininess.S` and `fp_fault_state.S` in `app/tests/baremetal/` use assembler macros and literal vector tables. Macro expansion preserves the instruction sequence, operands and expected flags, including static/dynamic rounding and fault-state controls. `fp_fault_state.S` selects F/D fault cases by default and half-precision cases with `FP_FAULT_HALF=1`; both share setup, trap checks and the M/S/U loop while retaining their exact instruction tables and expected trap counts. `app/tests/fp/fp_test_macros.h` shares result/flag checks and failure epilogues while retaining scratch-register behavior and each diagnostic code. The FP Makefile shares compile/run recipes; its `npc-matrix` remains sequential because NEMU configuration is shared. When changing these tables or recipes, compare RV32/RV64 output images and expanded commands as well as running the relevant regressions.

`xsim/tb_lsu_cache_harness.svh` shares SQ/L1D wiring and initialization for half-store visibility, IO splitting and AXI ordering. Each caller retains its bus model and explicitly selects external bus ownership, backpressure or unconnected handoff ports. The include consumes its override macros. L1I mapping/SRET epoch tests share their L1I/L2TLB fixture together with the existing tasks in `tb_l1i_epoch_tasks.svh`.

Backend extensibility/recovery and superscalar-width tests share rename/ROB/commit/PRF/router wiring in `xsim/tb_backend_domain_dut.svh`. The callers retain their configuration, IQ sizes, stimuli and assertions; `TB_BACKEND_VALIDATE_COMPLETIONS` is an optional override consumed by the include.

Bare-metal page-fault tests share Sv32/Sv39 two-page setup and M-mode fault checks in `app/tests/baremetal/page_fault_macros.h`. The `rva22s64-store-cross-page-run` target selects the successful-store portion of `split_page_fault.S` with `CROSS_PAGE_ONLY=1`; `rva22s64-split-page-permissions-run` selects its executable-only second-page fault scenario with `SPLIT_EXEC_ONLY=1`. RV64 delegated-trap and Sv39 tests use `supervisor_trap_macros.h`; Svade repair/retry retains its own handler because it must retry the faulting EPC. Keep register use, trap records and instruction order stable when editing these macros, and compare each caller's compiled image, including both XLEN modes where supported.

RVFI adapter effects, HINT metadata and Bare PMA checks share
`scripts/rvfi_contract.py --contract effects|hints|platform`. The existing
`formal-rvfi-metadata` and `formal-rvfi-platform` Make targets retain separate output
directories, parameter matrices, scopes and required witnesses. Shared Yosys execution
terminates its process group on timeout and requires a conclusive result before recording
an entry; covers and negative controls also require a nonempty waveform. `check-tools`
loads Slang before launching checks; set `RAPTOR_YOSYS_REAL` to a compatible installation.

The NRU, recovery, stream queue, SRAM and L1D data contracts are subcommands of
`scripts/unit_contracts.py`, which shares output, fingerprint and mutation handling.
NRU, stream queue and SRAM use `yosys_common.run_sby` for bounded execution,
status handling and waveform validation. Positive cases require successful prove/cover tasks
and nonempty VCDs; negative controls require an assertion counterexample with a nonempty VCD
and reject tool errors. Each subcommand retains its model construction and parameter matrix.


## Parameterized test scenarios

- `tb_ioq_store_pbmt` in `tb_ioq_all_contract.sv` shares its complete translation matrix with the `tb_ioq_paddr_preload` wrapper. `UnacceptedTraffic=1` replaces the ordinary response delay with changing, unaccepted PA/PBMT/fault payloads while SQ credit is available. Both public tops and Make targets remain separate; the wrapper selects the stronger waiting-phase checks.
- `tb_csr_all_contract.sv` contains the `tb_csr_contract` top, which shares one CSR/IEU fixture. Select `+CASE=identity_time` (default), `trap_storage`, `stimecmp`, `fp_aliases`, `status_fields`, `satp_warl`, or `tvec_routes`. Each invocation runs one scenario in a fresh process with its own assertions and timeout. Unknown names fail. The existing named CSR Make targets select the corresponding case for RV32/RV64.
- `app/tests/baremetal/zero_pma.S` tests device CBO.ZERO rejection by default; `PMA_READONLY=1` selects ROM/flash write protection. The existing `rva22s64-zero-pma-run` and `rva22s64-readonly-pma-run` targets retain separate images and result directories. Both scenarios include translated accesses and the RAM recovery/neighbor-block checks.
- The `tb_l1d_pma` top in `tb_l1d_all_contract.sv` covers the LR PMA denial and SRAM-hole load/LR/store scenarios. The `verilator-l1d-lr-pma-*` targets run the default mode; `verilator-l1d-sram-pma-*` supplies `+SRAM`. The two targets retain separate output names while sharing the fixture and the bus/reservation assertions.
- The ten `tb_idu_*.sv` scenarios share `tb_idu_contract.sv`. Each Make target selects one top-level module from the shared source. Assertions and counters therefore remain isolated per scenario.
- The `tb_router_clint_subword` and `tb_router_clint_width` tops share `tb_router_all_contract.sv`; each top has its own target, so the subword and native-width matrices run independently.
- The issue-selection, atomic, load/store, checkpoint, prediction-history and LR families use one shared source per family. Each scenario has its own top-level module; Make selects that module from the corresponding `*_contract.sv` file.
- All remaining L1D, IOQ, LSU and CSR TB modules are stored in `tb_l1d_all_contract.sv`, `tb_ioq_all_contract.sv`, `tb_lsu_all_contract.sv` and `tb_csr_all_contract.sv`. The top-level module passed by each existing target still selects one scenario; the shared source is only a physical organization boundary.
- Router, PTW and SQ scenarios use the same arrangement in `tb_router_all_contract.sv`, `tb_ptw_all_contract.sv` and `tb_sq_all_contract.sv`. Existing top names continue to select one scenario per build.
- The `tb_fetch_*` scenarios (L1I refill ownership, IFU prediction and hints, TAGE query) share `tb_fetch_contract.sv` in the same way.
- CSR execution/control, L1I epoch, IOQ store and L2 posted-write tasks use module-local `*_tasks.svh` helpers (plus `tb_csr_clear_commit.svh`). These headers intentionally have no include guards: each test module receives its own tasks. Keep scenario-specific assertions and handshakes in the original test modules.

- The `tb_ioq_acquire_publish` top in `tb_ioq_all_contract.sv` covers LR by default and AMOADD with `+AMO`; `+PENDING` selects response blocking. Both relaxed and acquire scenarios run in each invocation. Existing `verilator-ioq-acquire-publish-rv32/-rv64` and `verilator-ioq-amo-acquire-publish-rv32/-rv64` targets remain available; the AMO targets supply `+AMO`. Set `IOQ_ACQUIRE_PLUSARGS=+PENDING` as needed.
- `app/tests/baremetal/plic_access_width.S` covers loads by default and stores with `PLIC_WIDTH_STORE=1`. `PLIC_WIDTH_CASE=0..4` and `PLIC_WIDTH_TRANSLATED=0/1` retain the width and translation matrix. `scripts/plic_access_width.py` selects both directions and keeps separate results for each scenario.

## FPGA network interrupt regression

Run `make -C verification verilator-plic-network-rv32 verilator-plic-network-rv64` for
the actual router and PLIC with S-context source 4. `tb_plic_network` covers
256 consecutive RX services with a queue-nonempty level and shared TX events,
mask/unmask and arrivals during service, simultaneous claim/completion, and
stalled external single-beat/burst responses followed by an internal claim.
Both channel backpressure and delayed write data are exercised; the targets
enable RTL assertions. `+CASE=0..5` selects an individual scenario; case 5 is
the always-ready control corresponding to the current W4 core response path.

Cases 3 and 4 protect a stalled external response from being replaced by a
new PLIC response before the first handshake. The router must preserve all
R-channel fields while `RVALID && !RREADY`; burst tracking alone starts too late.
For a small waveform, compile with `VERILATOR_DIRECTED_FLAGS` including `--trace`
and run the generated model with `+CASE=3 +TRACE` in a build directory.

Run `fpga/litex/.venv/bin/python3 fpga/litex/tests/test_liteeth_rx_irq.py` for the
real LiteEth RX packet writer, eight-slot status FIFO, and CSR bank. It checks
W1C descriptor advancement, IRQ persistence while queued, slot wraparound, and
mask/unmask without losing packets. The router bench models that event contract;
it does not instantiate the FPGA PHY or a CPU executing Linux. Passing these
checks does not establish that a particular board hang has been reproduced.
In particular, the current W4 preset disables L2, bypasses the outer R buffer,
and keeps read-response ready high, so the stalled-response defect alone does
not explain that configuration's network hang.
Board acceptance still requires native-driver bulk transfers with verified
hashes and continued IRQ progress, without the temporary polling module.

## Quick Start

Run `python3 verification/scripts/test_debug_observers.py` from the repository root to
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
verification/
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

Raptor ships inline SVA guarded by `RAPT_ASSERT_EN` for zero default overhead. The assertion macros (`RAPT_SVA`, `RAPT_SVA_IMPLY`, `RAPT_SVA_NEXT`, `RAPT_COVER`, ...) are defined in [rtl/include/rapt_sva.svh](../rtl/include/rapt_sva.svh) and auto-included via `rapt.svh`.

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

ACT4 validates Sail 0.13.1. Classic RISCOF uses a separate, patched Sail 0.16 reference.
Build it with CMake, a C/C++ compiler, curl, patch, Python 3, and GMP development headers
installed (`libgmp-dev` on Ubuntu):

```bash
make -C verification riscof-classic-sail JOBS=2
```

The builder verifies pinned compiler/source archive hashes, applies
[`full-access-pmp-precheck.patch`](riscof/sail/full-access-pmp-precheck.patch), and installs
under `verification/build/sail-riscv`. Classic targets prepend this installation to their tool path;
`RISCOF_CLASSIC_SAIL_PREFIX` selects another installation. Its
`share/sail-riscv/raptor-reference.json` records source, compiler, patch, and executable hashes.
The setup target checks version 0.16 and validates the configured physical-access policy.

Classic RTL RISCOF (`make -C verification riscof-classic`) uses a separate `RISCOF_CLASSIC_TIMEOUT=600` second wall-clock budget per DUT test. Large F/D vectors can exceed the generic 10-second smoke-test budget, especially with parallel jobs. Explicit `TIMEOUT` overrides are still honored unless `RISCOF_CLASSIC_TIMEOUT` is supplied. For example:

```bash
make -C verification riscof-classic JOBS=4 RISCOF_CLASSIC_TIMEOUT=600
verification/build/riscof-classic-venv/bin/python verification/scripts/test_riscof_classic_runner.py
python3 verification/scripts/test_riscof_classic_sail.py
```

Both classic Sail profiles set `memory.pmp.check_full_access_before_split=true` to check each
complete physical access against PMP before any split is performed or announced. Reads,
writes, and concurrency-model write events use the same precheck. The option defaults to
false, preserving upstream behavior. Physical splitting and per-split PMP checks remain
unchanged; `memory.misaligned.default_allowed_within_exp=0` retains upstream's aligned
subaccess decomposition. Virtual address translation still splits at page boundaries.
This selects Raptor/NEMU's complete-access permission policy without combining decomposed
memory events or adding an atomicity guarantee.

The profiles disable the default MAG and Zama16b declaration and supply the LR/SC PMA fields
required since Sail 0.14. They also disable H, its dependent extensions, Sdtrig, and Stateen
to match the classic DUT profiles; Sail 0.16's default H support would otherwise change
exception signature record sizes.

The `pmpm_misaligned_{na4,napot,tor}` tests keep their original region layout and remain in the
signature comparison. A 16-byte relocation cannot move a 4 KiB-grain PMP boundary off a page
boundary, so the former relocation macro is no longer injected. The existing RV32/RV64
`verilator-pmp-permissions-*` regressions also compare full-span PMP decisions with an
independent bytewise oracle.

Each classic Sail invocation has a wall-clock limit of `RISCOF_CLASSIC_TIMEOUT + 30` seconds.
The reference batch budget scales with the selected test count and `JOBS`, avoiding RISCOF's
implicit 300-second limit for the entire reference suite. Compiler, reference-model and batch
failures stop the flow and retain per-test `ref/build.log` and `ref/*.log`. CI builds the shared
simulator and patched Sail reference once, then runs four compliance shards with `JOBS=2`, a
600-second per-DUT budget, and a 180-minute job budget.

PMP capacity is 8 usable entries in 16 architectural CSR slots (upper eight read-only zero), for RV32/RV64 and every preset. ACT4 declares `NUM_PMP_ENTRIES=16`, `NUM_USABLE_PMP_ENTRIES=8`; test headers use `RVMODEL_NUM_PMPS=8`. Classic test headers constrain generated tests to usable entries; they do not by themselves reconfigure Sail's CSR implementation or prove upper-slot read-only-zero behavior.

Run `make -C verification pmp-capacity-check` for RV32/RV64 CSR WARL/upper-slot alias prevention, own/TOR predecessor locks, permission checks, reset/NAPOT, CSR legality, shared L1D checks and NEMU capacity tests. For isolated output, pass `BUILD_DIR=/tmp/<task-directory>`. This is directed component coverage, not full-core, FPGA timing, boot or complete profile validation. The separate `nemu-pmp-priority-check` compares RV32/RV64 access decisions against an independent interval oracle, including partial overlaps where only an interior grain matches.

Each test's `dut/` directory retains `dut.log` and `dut-run.json`. Only a successful simulator termination with a complete, well-formed signature is passed to the signature comparison. On execution failure, partial output is kept as `*.signature.partial` and the comparison signature is empty so the test still fails. This distinguishes execution timeouts from completed architectural mismatches; it does not suppress either failure or change the test selection.

Signature export uses the checkpoint memory view: host RAM, pending cacheable AXI writes,
dirty L2/L1D data, then committed SQ stores in age order. This includes stores that remain
in write-back caches when the finisher stops simulation. Temporary RAM overlays are restored
after copying. The simulator fails if the snapshot is unstable or the output file cannot be opened.

Classic DUT and Sail headers declare the default 4 KiB PMP grain (`RVMODEL_PMP_GRAIN=10`).
Both classic Sail profiles set `memory.pmp.grain=10` and disable NA4, matching the ISA YAMLs.
This also selects the upstream Sv32 PMP test's existing large-grain path: the root-table case
is omitted when its whole page would become unreadable, while the leaf-table checks still run.

### 4. RISCV-DV Privileged Stress (`make riscv-dv`)

Uses the upstream [chipsalliance/riscv-dv](https://github.com/chipsalliance/riscv-dv)
pure-Python generator with Raptor RV32/RV64 IMC M-mode targets selected by `ISA=rv32|rv64`.
Generated binaries run on NPC with NEMU instruction-by-instruction difftest; no commercial
UVM simulator is needed for M-mode CSR and trap-handler stress. The generator projections
do not represent the full implemented ISA or include random atomic/F/D instructions;
use the ACT4 profiles, RISCOF classic and `app/tests/fp` for additional architectural coverage.
Generated programs and logs default to `build/riscv-dv/<ISA>/<test>/`.

```bash
make riscv-dv                         # one short privileged smoke test
make riscv-dv ISA=rv64                # RV64 target, lp64 ABI and matching NPC/MROM
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

The first run clones pinned revision `b7a0b4b0b51346a3c64f159f81ea262d867c14a9` and creates an isolated Python 3.11 environment under `verification/build/`. Python 3.10 or 3.11 is required because the pinned dependencies require the `imp` module available in those versions. Setup uses an installed 3.11/3.10 interpreter or provisions a local 3.11 interpreter with `uv` if neither is available.

The upstream Python backend does not implement page-table creation, page-table sections, or page-fault handlers (these functions are `TODO` in `pygen/pygen_src/riscv_asm_program_gen.py`). Run `make riscv-dv-mmu` for a fail-fast capability check. Full Sv32/MMU generation requires riscv-dv's SV/UVM backend and one of its supported simulators (VCS, Questa, Xcelium, or Riviera-PRO); none is installed in the current open-source tool environment.

### 5. Verilator Coverage (`make coverage`)

Collects line and toggle coverage during simulation.

```bash
make coverage-build       # Rebuild NPC with --coverage
make coverage-run         # Run tests to collect data
make coverage-report      # Generate annotated source report
```

**Note:** Coverage build uses Verilator's `--coverage --coverage-line --coverage-toggle` flags (with `-Wno-UNOPTFLAT` for this mode). `coverage-run` drives the instrumented NPC using `fuzz + sigtest` workloads from this `verification/` suite (to avoid non-coverage rebuilds from root targets). Each workload invocation gets a fresh directory under `$(COV_DIR)/raw/`; the simulator writes `coverage-<pid>.dat` there on exit. Only that invocation's files are merged via `verilator_coverage`. Old raw data is retained, and shared source-directory coverage files are neither deleted nor used as fallback input. Use different `COV_DIR` values for parallel suites to keep their aggregate reports and logs independent.

### 5. Formal Verification (`make -C formal`)

Uses [SymbiYosys](https://github.com/YosysHQ/sby) for symbolic equivalence, k-induction, cover reachability, and bounded model checking. Runs from the `formal/` subdirectory.

**Setup:**
```bash
make -C formal setup      # Download oss-cad-suite (yosys, sby, solvers)
```

**Standalone property checks:**
```bash
make -C formal formal_bus       # AXI bus protocol properties
make -C formal formal_ieu_alu   # RV32/RV64 ALU + Zb*/Zicond equivalence
make -C formal formal_ieu_mul   # Multiplier correctness properties
make -C formal formal_pmp       # RV32/RV64 PMP priority and permissions
make -C formal formal_plru      # 2/4/8-way replacement + invalid priority
make -C formal formal_clint     # CLINT timer/register/interrupt semantics
make -C formal formal_plic      # PLIC priority/context/gateway lifecycle
make -C formal formal_dtm       # Single-clock JTAG TAP + DMI transport
make -C formal formal_divsqrt   # FPU div/sqrt control, flush, and liveness
make -C formal all              # All standalone checks above
```

The ALU target proves all 64 internal operation codes and both word-flag values for arbitrary
RV32/RV64 operands, including unrestricted CLMULH inputs. Its polynomial-coefficient reference
uses the GF(2) definition and result ranges in the
[RISC-V Zbc specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/b-st-ext.html).
It also checks `EnableRareOps=0`: the six documented rare operations return zero. Every preset,
XLEN, DFF/SRAM define, LUTRAM define and synthesis/simulation context is elaborated. Only exact
unoptimized model identity permits sharing proof and activation evidence across bindings.
`FORMAL_ALU_PRESETS` selects focused contexts and `FORMAL_ALU_TIMEOUT` bounds each tool query.

A positive ALU certificate requires no assumptions, initializers, clocked checks or state
transition relation. A direct query over an arbitrary snapshot must prove the entire assertion
predicate UNSAT when negated; one-frame BMC is an additional check. Every opcode/word pair,
counting edge and multi-bit carry-less-product case has a reached waveform. Six mutations
require unrestricted counterexamples. A preserved `--baseline-harness` can demonstrate that
the former one-hot CLMULH test accepts a fault triggered only by multi-bit operands.
The generated gate receipts bind each actual parameter/define combination to its complete
model and activation inventory. Decode legality, dispatch routing, execution-port transport
and architectural instruction retirement require separate contracts.

The shared `scripts/ioq_contract.py prove --contract owner|store` runner selects an explicit
contract without changing module globals; the Make targets below select the same profiles.

`make -C verification formal-ioq-owner` composes the full production IOQ with the actual
dispatch arbiter and capacity adapter. An independent allocation ring records accepted
identities, PC and operation metadata. Independent response histories check A/B request
ownership, held descriptors, scalar data, FP boxing and at-most-once completion. All dispatch
payloads, wakeups, memory responses, CSR/PMP inputs and recovery remain arbitrary; only the
first sampled edge must reset. Internal queue, request and permission-check invariants are
proved rather than assumed. The request's ordered flag may promote while held.
Completion acceptance follows the backend's always-accepted trusted memory port.

Every preset, XLEN, DFF/SRAM define, LUTRAM define, synthesis context, instruction-observation
mode and load-response-stage setting is elaborated at its native queue/dispatch geometry.
Full unoptimized JSON models retain memory, initialization, logic and clocked formal checks;
only source-location attributes are removed for exact model grouping. Proof reads the
archived full model without state cuts. Every original cover requires a reached waveform,
including both response lanes where supported, queue fill/reuse, recovery, atomics and FP
responses. Seven mutations check identity banking, generation, duplicate completion, flush,
response data and FP boxing. Set `FORMAL_IOQ_OWNER_PRESETS` for a focused matrix and
`FORMAL_IOQ_OWNER_TIMEOUT` for each proof task (default 1800 seconds). Results stay under
`FORMAL_RESULTS_DIR`.
`FORMAL_IOQ_OWNER_DEPTH` controls the standard k-induction search and its initial-state check;
reducing it never accepts a bounded result as full safety. `FORMAL_IOQ_OWNER_SOLVER=auto`
uses Bitwuzla for eight-slot dispatch and Yices for smaller native geometries; either engine
can also be selected explicitly. CPU-heavy model compilation/normalization uses separate
worker processes.

The target also reaches each bank/row metadata guard and each per-entry stored-response,
FP-response, early-completion and permission-check history guard. These additional clocked
covers read the original assertion enables. They add no drivers, assumptions or functional
state; deleting the observer cells must recover the exact original unoptimized graph.
Every added guard needs its own reached waveform before the target succeeds.
The activation runner retains VCD and suppresses unused witness export formats; all model,
solver, initialization and reachability arguments remain unchanged.

This is the IOQ producer layer of the backend's trusted memory-completion contract. ROB
allocation/lifetime composition, store-data semantics, address translation, exception
classification and memory/bus correctness still require separate proofs. It does not by
itself qualify the complete LSU, backend or architectural memory behavior.
The signoff inventory keeps admission, identity, response provenance, single completion,
store-data ownership and atomic semantics as distinct required contracts; the producer-layer
proof cannot replace the outstanding store and atomic contracts.

`make -C verification formal-ioq-store` retains that complete producer fixture and adds
independent integer/FP store operand histories from accepted dispatches and registered/live
wakeups. It checks the head SQ payload against those histories, all eleven LR/SC/AMO data
operations at native word/doubleword widths, and old-value response provenance. AMO.W checks
only the bytes enabled for the store; arbitrary upper rs2 bits remain legal. Per-entry
integer and FP wake covers, each supported operation/width, ordinary/FP stores, successful
and failed SC, and notification-blocked SC all require reached VCDs. Eight RTL mutations
must fail. The target uses the same complete native configuration matrix as the producer
runner. Set `FORMAL_IOQ_STORE_PRESETS`, `FORMAL_IOQ_STORE_TIMEOUT` (default 1800 seconds),
`FORMAL_IOQ_STORE_SOLVER` (default Bitwuzla), and `FORMAL_JOBS` as needed.

The SC reference checks a decision sampled from the presented physical address and
reservation interval, and requires notifications to cancel/block it. Reservation inputs
stay arbitrary; this does not establish reservation creation/invalidation, SQ/bus transport,
cache/bus atomicity, address translation, producer lifetime or architectural memory ordering.
It cannot replace those composition obligations or issue whole-RTL signoff.

PLRU, CLINT, and PLIC use k-induction
and include reachable cover witnesses. CLINT checks RV32/RV64 plus divider-bypass and divided
timer paths. PLIC uses k-induction for reduced and production RV32/RV64 geometries (31 sources,
two contexts). Its lifecycle covers use three symbolic sources and two contexts to preserve
arbitration ties, M/S interrupt routing, and claim/complete behavior while keeping witnesses
short. The bus check explores 12 cycles of arbitrary backpressure, while div/sqrt explores
70 cycles to exceed the longest iterative operation.

The default multiplier target composes exhaustive RV32/RV64 arithmetic cases, including
MULW, with an unbounded owner/data transport proof. Arithmetic replaces only the registered
stage-one operands, opcode and word selector. Transport cuts only the combinational result
and proves operand/opcode/word/tag capture and result delivery for arbitrary result values,
flushes and per-tag cancellation. Both DSP attribute paths are checked. Driver checks reject
extra input drivers and leftover arithmetic in the transport abstraction. Operation and
recovery covers plus signedness/result-register mutations validate the model boundaries.
This closes pure multiply streams, not DIV/REM arithmetic or mixed multiply/divide arbitration.
Use `formal_ieu_mul_monolithic` for the optional five-frame BMC reference; a shallow PASS
before the first result is observable does not establish arithmetic correctness.

`make -C verification formal-ieu-div` proves pure DIV/DIVU/REM/REMU streams for
RV32/RV64, including all RV64 W forms, tag widths 1/2/3 and both DSP attribute paths.
The RTL refines a canonical MSB-first divider that appends a dividend bit before
comparing/subtracting, whereas the DUT stores a lookahead bit and places quotient
bits by index. Checked state relations bind the consumed prefix, normalization,
operand signs, tags, remainder bounds and every widened intermediate's truncation.
An age/ranking invariant bounds uninterrupted completion by `XLEN/2 + 2` cycles
after acceptance. Reset, flush, blocked presentations and cancellation remain free.

Four SMT integer lemmas prove the reference's zero-prefix base, Euclidean-step
preservation, quotient/remainder uniqueness and signed truncation. Together with
the RTL's prefix and no-truncation invariants, they establish numerical division;
zero-divisor and modular XLEN/W result encoding are compared directly. This uses
no assumed DUT state or internal progress. Reachability cases include all opcodes,
W encoding, zero operands, sign combinations, MIN/-1, cancellation and busy flush.
Normalization, sign-correction and zero-divisor mutations must yield real RTL
counterexamples. Set `FORMAL_RESULTS_DIR` to a fresh run directory.

`make -C verification formal-ieu-muldiv` first establishes those multiplication
and division prerequisites, then proves arbitrary mixed streams in RV32/RV64,
tag widths 1/2/3 and both DSP attribute paths. The concrete canonical division
state remains checked; only the multiplier's combinational result is free, with
its arithmetic discharged by the prerequisite. Operand/opcode/tag capture,
result transport, output mutual exclusion, cancellation/reuse and synchronous
flush/reset are inductive invariants. Legal requests may be presented while
blocked; invalid-cycle word inputs remain unconstrained. Covers retain the actual
multiplier and include zero-dividend shortcuts, full-width unsigned division,
older MUL drain, DIV-to-MUL reuse, canceled DIV with older MUL, and simultaneous
flush. Ready-while-busy, wrong-unit acceptance and lost older-MUL mutations must
produce real counterexamples. The parent MDQ and architectural retirement still
require separate composition proofs.

The div/sqrt harness checks the result-valid/control contract, including bounded completion,
special cases, and flush. Its induction proof asserts the relation between request age and
the RTL iteration counter. SP/DP iterative completion and busy flush have cover witnesses.
Result and flags may change while result-valid is low; floating-point numeric equivalence
is outside this harness.

The DTM proof covers the implemented single-clock simulation transport: all 16 TAP states, IR/DR shifting, IDCODE/DTMCS capture, and DMI request/response sequencing. CDC, busy/sticky status, and reset side effects remain explicitly outside `rapt_dtm`'s current implementation contract.

`make -C verification/vpu memory-response-formal` proves the full stale-response payload
isolation contract in RV32/RV64. It composes the original reset base and public request-ledger
invariant with one-step corresponding-state equivalence. Only register bits and their direct
constant aliases are induction points; all register bits must be accounted for, and common
combinational names are blacklisted. Stale pending-response covers and a mutation that consumes
unaccepted payloads check reachability and sensitivity. This is not full RVV memory semantics,
external-drain liveness or freshness of a reused tag. `FORMAL_RESULTS_DIR` controls the output
directory and defaults outside the checkout.

`make -C verification formal-scope` inventories every RTL module, interface, package and
conditional/external boundary, including generated decoders, across the discovered presets,
both XLENs and both storage models. Its proposed contract families require semantic review and
actual parameter/configuration bindings. They are not an automatically complete specification.
Review may add contracts but cannot drop candidate obligations or omit supported profiles.
The inventory also names the transport, banking, replacement and recovery contracts of the
recently changed blocks, rather than treating a generic functional receipt as sufficient.
`make -C verification formal-signoff` fails until that review and all current proof receipts
close the required contracts. Set `FORMAL_CONTRACT_REVIEW` and `FORMAL_RECEIPTS` to explicit
review/evidence files; `FORMAL_SCOPE_OUTPUT` selects the output directory. Receipts must bind
current RTL/configuration and harness hashes, raw proof artifacts, parameters, assumptions and
nonempty property-activation witnesses. A bounded or cover result cannot close a sequential
module's unbounded obligation. Elaboration success or a file's presence in a harness does not
grant formal signoff.

Review schema 2 maps each unit's `parameter_bindings` from every supported profile to a
nonempty list of parameter/define dictionaries. Each dictionary creates a separate required
binding for every obligation. A receipt's `parameters` must match one reviewed dictionary
exactly; one geometry cannot close another geometry in the same preset. Missing, duplicate
or legacy unqualified binding tables are rejected. The signoff report records binding hashes
and their definitions alongside pending obligations.

For a combinational unit, `combinational-smt` receipts additionally require an unrestricted
snapshot query with no initialization, assumptions or transition relation. The gate compares
the complete binding model with the proved frontend, verifies the actual parameter/define
settings, and matches every model cover to its reached log entry and fingerprinted waveform.
Extra query constraints, missing covers or mismatched witnesses invalidate the receipt.

`verification/scripts/formal_scope.py graph-identity` can compare two checkouts using an
explicit JSON list of `read_slang` commands with `@ROOT@` paths. It compares unoptimized
RTLIL byte for byte after removing only source-location attributes, preserving initial
state, assumptions and assertions. Compressed original models and source hashes remain
in the external result directory. This establishes elaboration identity only. Reusing
a prior proof additionally requires its original input and toolchain fingerprints,
identical read settings, qualified proof results and nonempty activation witnesses.
The scope gate still requires current receipts and never accepts graph identity alone.

`verification/scripts/formal_scope.py model-classes` uses the same command-manifest format to
elaborate every binding in one checkout and group identical unoptimized models. It retains
all initialization, assumptions, assertions and covers; only source-location attributes are
removed. Each group still needs qualified unbounded proof and activation evidence. Equal
dimensions, successful elaboration or group membership alone grant no formal PASS.

`make -C verification formal-sram` checks every registered 1RW macro shape and the
four-segment 16384x64 wrapper, with byte enables on and off where supported. A stable
symbolic observer address represents every row. Known-bit tracking leaves initial memory
and output values unconstrained, and proves masked/full writes, synchronous reads and
output hold by induction. Every case must also reach read/write/disabled covers; byte-mask,
output-hold and macro-polarity mutations must produce real counterexamples. The macro branch
uses the repository's generated functional stub. This establishes its wrapper contract,
not equivalence to a characterized physical SRAM, other SRAM port types, or cache ordering.
Set `FORMAL_RESULTS_DIR` to a fresh directory for each run. The multiply and VPU response
runners likewise reject nonempty output directories to preserve earlier evidence.

`make -C verification formal-cache-nru` proves lowest-cold-way selection, epoch renewal,
reset and invalidation for 2/4/8/16/32 ways, two or 64 sets and one/two query ports. A stable
symbolic observer represents every set; DUT updates and queries remain unconstrained in
the safety proof. The reference counts marks other than the touched way. Activation
covers use a deterministic sequence of external way touches, invalidation and an update
to another set, avoiding a permutation search for large-way epochs. They assume no DUT
state or progress. Epoch, priority and invalidation mutations must produce counterexamples.
Tag/data arrays and hit/install arbitration require their own contracts.

`make -C verification formal-recovery-pending` proves the oldest live request, held-request
tie priority, enabled-port priority, complete owner/target/generation transport and stale
generation cancellation. Sixteen bindings include sparse/empty masks, non-power-of-two
ROB sizes and 32/40-bit targets, with arbitrary flush and reset after the initial reset.
Activation witnesses exercise applicable idle, new, held, flush, generation, mask and tie
paths. Mask compression, held ties and generation-check mutations must fail. Producer
publication, checkpoint restoration and redirect application remain separate contracts.

`make -C verification formal-stream-queue` compares the production queue with the original
flop reference, including occupancy, pointers, ready/valid and every occupied payload bit.
The matrix exercises asymmetric lanes, non-power-of-two depths, same-cycle reclaim,
banked storage and BRAM prefetch/collision forwarding, including 97-bit payloads.
A stable, arbitrary observer bit proves each payload bit without constraining queue data.
Invalid-address leaves introduced by memory mapping remain unconstrained. Only the first
edge must reset; subsequent reset, flush, input-valid and output-ready patterns are free.
Activation covers exercise full/stalled, simultaneous transfer, wrap, flush and every
output lane where applicable. Wrong-bank-row, missing-forwarding and ignored-flush
mutations must produce counterexamples. This is transport equivalence to the pre-banking
reference; producer packet formation and core-level ordering need separate contracts.
Use a fresh `FORMAL_RESULTS_DIR` for all three targets; an incomplete proof or cover fails
the runner and is never promoted to whole-RTL signoff.

`make -C verification formal-rou-retire` checks the uncut ROU's immutable retirement
metadata against independent allocation histories. It reads the actual banks under
`SYNTHESIS`; the simulation-only payload shadow is not used as a golden memory. An
independently declared schema and full-width PC/instruction histories check every stored
word, all commit reads, the extra next-PC lookahead read, CSR context decoding and the
serialized CSR/fence immediate. Both XLENs and functional/instruction/RVFI layouts run
with both completion-validation modes. Only the first edge must reset. Activation covers
require every physical ROB owner, every retirement lane, lookahead, genuine circular
allocation excluding flush-induced pointer reset, and allocation after flush. Five
mutations exercise write-row selection, read-bank selection, PC, original RVFI identity
and serial-immediate transport. Set `FORMAL_ROU_RETIRE_PRESETS` to a space-separated list
to check production presets, for example `"default default-w3 default-w4 default-w8"`.

In production mode this harness composes actual ownership guard instances with the ROU,
leaving raw completions arbitrary. The real backend trusts its memory completion producer;
the extra guard on that port in this composition explicitly qualifies the boundary. The
LSU producer's ownership contract still needs separate proof. With local validation enabled,
raw requests go directly to the ROU's own guard. These proofs do not establish instruction
execution, rename correctness, complete backend composition or whole-core ISA semantics.
Reports preserve the exact inputs, modes, proof/cover outcomes and counterexample hashes.

`make -C verification formal-l1d-data` independently elaborates the actual L1D geometry
of every preset in both XLEN modes, then proves each distinct geometry with behavioral
SRAM and ideal functional macro stubs. Extra small geometries exercise full, partial and
multiple way groups. `FORMAL_L1D_DATA_PRESETS` optionally selects a subset. Geometry reuse
is guarded by a source audit that rejects additional configuration-sensitive macros.

A stable symbolic set/way/word/byte tracks arbitrary byte strobes and line masks against
the physical diagonal banks. Read/write ways must be legal; other transactions, reset
patterns and initial contents are free. The contract checks synchronous read addressing,
bank and line validity, assembled lines, blocked-write preservation and reserved-port
output hold. A blocked write still reserves its bank. Reset suppresses read validity but
does not erase storage or suppress otherwise enabled writes. Covers exercise every bank
and byte lane, both RV32 words in a chunk, full/partial line writes, partial word writes,
blocked writes, reset-time writes and independent way-group traffic where applicable.
Six mutations must produce real counterexamples.

Narrow division/modulo cells use standard Yosys arithmetic mapping to avoid a known
small-operand slicing failure during preparation. No sequential state or memory is cut.
Assumption count is audited before this optimization; tautological way-range checks may
then disappear. Physical macro equivalence, tag selection, parent arbitration, coherence
and architectural memory ordering require separate proofs. Use a fresh result directory
to preserve the exact configuration-discovery and proof artifacts.

`make -C verification formal-prf` checks architectural/debug x0 in RV32/RV64 with
flop and LUTRAM storage. Physical payload is uninitialized; reset maps do not make
physical register zero contain zero. The x0 checks use the production preset shape.
All discovered presets are selected by default. `FORMAL_PRF_PRESETS` selects a subset,
and `FORMAL_PRF_TIMEOUT` sets the
per-task timeout in seconds. Use a fresh `FORMAL_RESULTS_DIR` for each run.
`RAPTOR_YOSYS_REAL` selects the native Yosys launcher. All branches resolve it before adding
bundled solver tools to `PATH`, and the report records the selected launcher and version.
`make -C verification formal-prf-zero` is a fast regression for just the idle-reset
x0 contract and its two masking mutations; its result explicitly excludes general
data/state history. The full `formal-prf` target retains the larger matrix below.

The full target first elaborates `CoreConfig` for every selected preset and XLEN,
recording its actual architectural/physical counts, read/retirement/writer widths and
address width. It compiles each native binding directly with zero/three late-read ports
and both storage implementations, plus flop-synthesis and LUTRAM-simulation RVFI views.
Equal dimensions do not silently qualify another preset. For example, `default-w8`
requires its actual 128-entry storage, independently of the 96-entry stress geometry.

The same target checks byte history at a stable symbolic physical address, validity
and transient-state priorities, flush, ordinary and late reads, quiescent debug writes,
all LUTRAM read copies and available architectural/RVFI views. It includes 64/96-entry
production-sized shapes, one/eight read and retirement ports, six writers and zero/three
late-read ports. Reset forgets knowledge of payload contents. Active addresses must be
legal, accepted writers must have unique physical destinations, and debug writes must
be quiescent outside reset/flush. Covers exercise writes, debug, overlapping retirement
events and late forwarding during flush. Eight state/forwarding mutations and five view
mapping mutations must yield counterexamples. View mutations also run against the original
uncut monolithic assertions, so a counterexample in a stronger auxiliary lemma alone
cannot satisfy those controls.
An optional `prf_formal.py prove --baseline` supplies preserved pre-fix RTL for four additional
x0 counterexamples. Producer ownership, rename mapping and debug halt delivery need
integration proofs.

The default `FORMAL_PRF_PROOF_STYLE=composed` keeps the actual DUT and its entire storage
transition system. Only the five architectural/RVFI view assertions become their original
activation covers in the history harness. Independent view identities check every physical
row, every byte lane and every committed/speculative/RVFI output. Their direct SMT snapshot
query applies no initialization, transition or environmental predicates. The verifier also
rejects initializers, `$initstate`, clocked property sampling and nontrivial initial,
hierarchical or assumption predicates. This makes the identity a combinational all-state
lemma; a shallow BMC PASS alone cannot certify it.
The direct query uses the bundled Yosys SMT unroller and Bitwuzla; both its original and
expanded formulas are retained. Every activation witness gets its own waveform. Tool
timeouts terminate the process group and produce an incomplete result.

An SMT composition theorem derives the removed byte assertions from unbounded history,
LVT validity and the view identities. Removing any essential premise must make its negative
control satisfiable. Legal-address premises are retained for non-power-of-two zero views.
History, all-state identities, the composition theorem and all activation covers must pass
before a binding is certified. `FORMAL_PRF_PROOF_STYLE=monolithic` retains the original full
induction model for comparison. A standalone `prf_formal.py composed` run requires explicit native
dimensions and records all components and their source fingerprints outside the checkout.

For a flop history timeout, `verification/scripts/prf_formal.py byte-partition` accepts the existing
composed output through `--reference` and writes to an empty `--output` directory. It checks
the current RTL and original history fingerprints, then proves every observer-byte value
without changing DUT inputs or transitions. Three whole-word zero checks are split into
their byte clauses. SMT lemmas check both domain exhaustiveness and whole-word reconstruction;
omitting any byte must fail the corresponding negative control. Certification also requires
the original full activation cover, fresh all-state views and the view-composition theorem.
This is an optional recovery flow; an unfinished partition is never promoted to PASS.
The full composed runner applies this recovery automatically to flop history timeouts or
preparation errors when full activation, views and the composition lemma passed. It starts
with byte decomposition for flop geometries with at least 128 entries. Each binding uses
one byte worker so `FORMAL_JOBS` controls aggregate concurrency. Genuine assertion failures
are retained, and negative controls never use this recovery. Original component statuses
remain in their reports; the qualified row also names and hashes the byte-recovery receipt.
`prf_formal.py composed --history-cover-only` can prepare an uncertified full activation reference
when byte decomposition is planned from the start. `prf_formal.py byte-partition --engine abc-pdr`
changes only the safety engine, retaining the original cover evidence and all property/state
transformations. Byte recovery rejects a bounded history mode even if its metadata says PASS.

Production-sized flop safety jobs use ABC PDR. LUTRAM safety jobs use Bitwuzla after
standard Yosys mapping of only the LVT to registers; all payload RAM copies remain native
SMT arrays. This avoids hundreds of redundant LVT write ports without changing state,
addresses, data bits or assumptions. The original model passes `check -assert` before
mapping. Only generated out-of-range LVT read-mux leaves may become unconstrained inputs;
non-power-of-two geometries retain their legal-address assumptions. Payload memory counts
and single-write-port shapes are audited after mapping. Smaller safety jobs and all covers
also use Bitwuzla. Large jobs may time out. A timeout leaves `complete` false and makes the
target fail even if all covers and smaller shapes pass; it is never treated as proof.
These block contracts do not constitute whole-RTL signoff.

#### riscv-formal (RVFI)

`make -C verification formal-rvfi-metadata` checks the adapter independently of the core.
It proves fault suppression for GPR destinations and memory masks, zero data for `rd=x0`,
integer load/store/LR/SC/AMO mask decoding, metadata passthrough and the unbounded 64-bit
modular order/reset recurrence in RV32/RV64 with 1/2/3/4/8 lanes. Covers activate faulting load/store,
successful/failed SC, LR/AMO and both GPR destination cases on the last lane. Six mutations
must produce genuine counterexamples. The same target checks compressed HINT metadata and
same-group forwarding on every channel of those widths, including a reversed-forwarding
mutation that must choose the wrong older writer. It assumes a contiguous retirement prefix; execution,
producer legality, memory contents, fault cause and complete ISA semantics remain separate.
Select a fresh `FORMAL_RESULTS_DIR` to preserve earlier evidence.

Memory read data comes from the saved completion result, including when `rd=x0` suppresses
the PRF write. Write masks use the saved actual write permission rather than inferred SC
status from the PRF. The address is the original effective address, before physical address
translation or Bare alias canonicalization. Producer correspondence and memory contents
still require separate checks; adapter-input transformation proofs alone do not establish them.

`make -C verification formal-rou-rvfi` checks the actual ROU and RVFI adapter together,
retaining all DUT state. It proves saved memory-completion payloads, effective addresses,
x0 read results, write-mask correspondence to the scalar store-commit endpoint, and the
contiguous retirement prefix. Only the first sampled edge requires reset; rename,
completion, CSR, PRF and backpressure inputs are arbitrary. Covers exercise both lanes,
failed/successful SC and different virtual/physical addresses under these block inputs.
Three mutations must yield bounded counterexamples. This does not establish decoder or
producer legality, core-level reachability, execution/bus data or complete ISA correctness.
The default preset is `formal`; use `FORMAL_ROU_RVFI_PRESETS="formal default"` and
`FORMAL_JOBS` to select independent configurations and concurrency.

`make -C verification formal-rou-rvfi-composed` checks the same safety properties with a
state overapproximation. It preserves payload, reference-history and assertion-monitor
registers, replaces only identifiable DUT control-register outputs with free values, and
audits the resulting graph before proving it. Every original wire, initial attribute,
uncut cell, property and assumption must remain unchanged; each removed FF output must
receive exactly one free driver. This adds possible trajectories without constraining
outputs or private progress. Activation covers run separately on the uncut model.
Both local completion validation and the production externally accepted completion
binding are checked in each XLEN/preset. Address, result-loss and write-permission
mutations must fail on both the abstract and uncut models under both bindings. This target
is optional and is excluded from the default standalone aggregate. Larger presets may
still time out; a timeout never qualifies a contract. As with the uncut check, block-level covers do
not establish complete-core architectural reachability or execution/bus correspondence.

After an RTL merge, regenerate decoders and use a fresh result directory. Prior results
remain evidence for their recorded source fingerprints; they cannot qualify changed RTL.
The following small gate checks configuration, inventory and RVFI contracts in both XLENs:

```bash
make verilog
formal_results=$(mktemp -d)
make -C verification config-macro-check
make -C verification formal-scope FORMAL_SCOPE_OUTPUT="$formal_results/scope"
make -C verification formal-rvfi-metadata formal-rvfi-platform formal-rou-rvfi \
  FORMAL_RESULTS_DIR="$formal_results"
# Optional state-abstraction check, including both completion bindings:
make -C verification formal-rou-rvfi-composed FORMAL_RESULTS_DIR="$formal_results" \
  FORMAL_JOBS=2
```

Select a compatible Slang-enabled Yosys with `RAPTOR_YOSYS_REAL` when needed. Follow this
gate with affected block/ISA regressions and production presets. Neither this gate nor
the generated inventory establishes whole-RTL signoff.

`make -C verification formal-rvfi-platform` qualifies `formal_rvfi_metadata.sv` against the
production physical-access predicates for the `default` and `formal` presets in both XLENs.
It covers all addresses and scalar sizes, including misaligned RAM, holes, read-only memory,
device alignment, PLIC width and RV64 address aliases. Boundary, permission, width and alias
mutations must fail. The reference binds the 256 MiB PMEM/32 MiB SDRAM/8 KiB SRAM map and
selects XLEN from `RISCV_FORMAL_XLEN`. Use it through `RISCV_FORMAL_PMA_MAP` only for Bare
physical-address checks with that map. Different platform overrides and translated addresses
require their own qualified models; PMP and integrated exception delivery remain separate.

The AIG compatibility wrapper keeps ABC's native BLIF parser by default. Tool distributions
that require the older parser can explicitly set `RAPTOR_ABC_BLIF_PARSER=legacy`; that parser
can reject large flattened input files. Parser or mapping failures are tool errors and must
be resolved before interpreting any proof result.

[riscv-formal](https://github.com/YosysHQ/riscv-formal) performs per-instruction formal verification via the RVFI (RISC-V Formal Interface). The Raptor core exposes RVFI signals through `rtl/backend/rapt_rvfi.sv` (enabled by `-DRAPT_RVFI`), with NRET=2 for dual-commit.

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

**Engine:** Uses `abc bmc3` (AIGER-based BMC) instead of SMT-based solvers to avoid a
combinational loop diagnostic in the `write_smt2` backend. `checks.cfg` uses depth 8 for
instruction checks and final depth 10 for register, forward/backward PC, uniqueness, and
causality checks. These are smoke bounds. Before claiming ISA correctness, require covers
for the selected non-trapping instruction on each channel at its check cycle, and reachable
triggering retirements for consistency checks. A shallow PASS without those witnesses can
be vacuous. Check the SBY status files: generated jobs may accept both PASS and FAIL as
expected outcomes. Tool errors and timeouts do not establish correctness.

The optional `RAPT_RVFI_PROTOCOL_ENV` wrapper supplies transaction-driven, error-free AXI
responses with unconstrained per-beat data. It does not establish memory coherence or remove
platform access faults. Match the reference's address validity, PMA spans and memory-mask
conventions to the selected configuration. The compact RV64 PC implementation can replace an
unrepresentable jump target with another invalid address before the subsequent fetch faults;
an all-address-valid reference comparison will reject that representation. Ordinary RAM
supports misaligned splitting, while a span across a permission boundary can fault. Preserve
such counterexamples until independent policy checks and integrated exception proofs explain
them; a corrected model or a component policy proof alone does not close the original job.

**Configuration files** (`formal/rvfi/`):
- `checks.cfg` — ISA, nret, solver, depth, yosys-slang script
- `wrapper.sv` — Instantiates `rapt` with unconstrained AXI4 responses via `rvformal_rand_reg`, exposing only RVFI outputs to the testbench

### 6. JTAG / RISC-V Debug Verification (`make jtag`)

Two-layer verification of the `rapt_dtm` + `rapt_dm` blocks introduced for the JTAG / RISC-V Debug Spec 1.0 implementation. Lives in [verification/jtag/](./jtag/README.md) for full details.

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

M decoder enumeration: `make -C verification verilator-idu-m-encodings-rv32` and `verilator-idu-m-encodings-rv64` exercise every rd/rs1/rs2 tuple in funct7=1 OP/OP-32 across M/S/U. RV32 also sweeps OP-32/OP-IMM-32 funct7, funct3 and correlated register fields. The latter is not a Cartesian register sweep. `scripts/m_elf_coverage.py --elf-dir <M-ELFs> --output <JSON>` records static instruction and register coverage separately from execution results.

The M privilege/edge test also rejects all five RV64 M word operations in RV32, checking their precise illegal-instruction trap and preserved destination.

`rva22s64-bit-xlen-legality-run` checks native REV8 and highest-bit BSETI, then traps on selected XLEN-incompatible shift/REV8 encodings. Use `RVA22S64_TEST_CPPFLAGS=-DBIT_TEST_PRIV=0`, `1`, or `3` for U/S/M. `verilator-idu-bit-immediates-rv32` / `-rv64` enumerate eight immediate families, every 6-bit shift and rd/rs1 combination, plus both REV8 encodings, in M/S/U. A reference with the RV32 shift-immediate matching fix is required.

`verilator-bit-decode-alu-rv32` / `-rv64` assemble deterministic Zba/Zbb/Zbs vectors and compare the real decoder+ALU against independent Python integer expectations in M/S/U. The vector manifest records the seed, compiler command, operands and expected results; it is not an exhaustive operand proof.

`rva22s64-zexth-xlen-run` checks native ZEXT.H, all eight C.ZEXT.H register encodings, and the unimplemented other-XLEN native encoding with precise cause/EPC/tval, preserved destination and trap return. Set `RVA22S64_XLEN` to 32 or 64 and `RVA22S64_TEST_CPPFLAGS=-DZEXTH_TEST_PRIV=0`, `1`, or `3` for U/S/M; provide the frozen NPC and matching reference as for other runners. `verilator-zexth-decode-alu-rv32` / `-rv64` exercise the real decoder and ALU: all 65,536 low-halfword values with upper bits set, both native/compressed forms, every native rd/rs1 pair and all compressed short registers in M/S/U. Each XLEN checks 399,384 cases. This is bounded operand coverage; rejecting the counterpart encoding is the selected platform's unimplemented-encoding policy. C.ZEXT.H interaction coverage does not add Zcb to RVA22's mandatory set.

`verilator-compressed-legality-rv32` / `-rv64` use one decoder bench for 30,816 M/S/U checks per XLEN. Both former `verilator-compressed-register-legality-*` and `verilator-compressed-zero-immediate-*` names alias this combined target, so requesting both builds and runs it once. The register matrix retains 18,528 cases: every register/immediate field of C.LWSP, C.LDSP/C.FLWSP and C.ADDIW/C.JAL, plus every C.JR register. Reserved integer zero-register forms must report illegal instruction with the raw lower parcel as tval; RV32 C.FLWSP f0 and overlapping C.JAL remain legal. FP state is enabled. `rva22s64-compressed-register-legality-run` separately exercises illegal forms and legal controls on a frozen core. Select `RVA22S64_XLEN=32` or `64` and `RVA22S64_TEST_CPPFLAGS=-DC_REGISTER_TEST_PRIV=0`, `1`, or `3` for U/S/M; the reference must include the compressed zero-register legality repair.

The immediate matrix retains 12,288 checks of every C.ADDI4SPN and C.LUI/C.ADDI16SP immediate/register field. Zero immediates are rejected except the eight existing C.MOP.n encodings (odd n in 1..15); nonzero-immediate C.LUI x0 HINTs remain valid. MOP/HINT checks also require no architectural destination. The separate core target `rva22s64-compressed-zero-immediate-run` tests all 32 reserved zero-immediate forms, all eight C.MOP.n controls, HINTs and representative legal arithmetic. Set `RVA22S64_TEST_CPPFLAGS=-DC_IMMEDIATE_TEST_PRIV=0`, `1`, or `3`, with the selected XLEN, frozen NPC and corrected reference. These are selected encoding checks, not exhaustive compressed-extension coverage; Zcmop remains an extra implementation, not mandatory for RVA22.

### Optional CSR policy in the NEMU reference

The current Raptor RTL traps accesses to the optional `mcountinhibit` CSR (`0x320`). `nemu/configs/riscv64_ref_defconfig` therefore disables `CONFIG_RV_MCOUNTINHIBIT` while retaining RVA22S64 and F/D. Standalone NEMU RVA22 presets retain their WARL-zero CSR default. Do not skip OpenSBI CSR probes in difftest to hide a mismatch between these policies.

After `make build-nemu64-ref` from the repository root, check the reference:

```sh
python3 verification/nemu/check.py rva22s64 --xlen 64 \
    --reference nemu/build/riscv64-nemu-interpreter-so \
    --mcountinhibit absent --output /tmp/raptor-nemu64-csr-check.json
```

The absent-CSR checks include OpenSBI's exact `csrr a0, 0x320` probe and register/immediate CSR writes; they require precise illegal-instruction trap state, unchanged destinations and no instruction retirement. This reference regression does not substitute for a Linux boot on the DUT or FPGA.

### Default four-way L1 capacity checks

The default preset uses 64 sets × 64 B × 4 ways = 16 KiB for each L1, with tree-PLRU replacement and a 4 KiB per-way span that keeps every index bit inside the Sv32/Sv39 page offset.

```sh
make -C verification verilator-l1i-16k-rv32 verilator-l1i-16k-rv64 \
  verilator-l1d-16k-rv32 verilator-l1d-16k-rv64
```

These checks fill and read every word of each cache, require all four same-set lines to remain resident without external reads, introduce a conflicting tag beyond the whole capacity, check neighboring-set preservation, and invalidate/refill all sets. They derive sets/ways/capacity/stride from the selected preset, require 64 B lines and at least two sets and ways, and enable assertions; compiler warnings are nonfatal by default (`-Wno-fatal`). The store-coherence test derives its conflict stride and working-set size from the selected preset, preserving eviction coverage as associativity changes. These are functional checks; FPGA utilization and timing require synthesis and implementation of the chosen SoC configuration.

### Streaming cache transactions

`make -C verification verilator-memory-coherence-progress-rv32 verilator-memory-coherence-progress-rv64 XSIM_RAPT_CONFIG=default-w4` connects the real L1D and bus to a bounded-delay memory model. The 18 directed collisions cross store ownership, load-line/PTE address relationships, and ordinary/split/atomic load beats. A further 243 cases cross all 27 request start schedules (load/store/I-PTW start in cycles 0..2, including ties), three address relationships and three load kinds. Independent AR/AW stalls, R gaps and delayed B exercise request ownership. Checks cover transaction counts, load/PTE data, partial stores and neighboring bytes. Each request has its own age monitor beginning at presentation, before AR; unrelated completions cannot hide starvation. Both targets belong to the fast directed gate. Sweep `VERILATOR_DIRECTED_SEED` and `VERILATOR_DIRECTED_DELAY` (0..255); the timeout scales with the configured delay bound. Split cases start at the translated L1D beat; `verilator-split-load-retry-rv32/rv64` checks the LSU beat/retry state machine.

`make -C verification formal-memory-progress` runs the complementary RV32/RV64 formal contract and covers. The default is 40-step bounded model checking with ABC, long enough to pass the 32-cycle deadline for every start time (plus reset and assertion sampling); a PASS is explicitly a bounded result. Unbounded PDR is available through the runner's `--mode prove` option, but is not implied by this gate. It instantiates production L1D and bus control with two sets, one way and two words per line, disables MSHRs/L2, and supplies translated, non-replayable loads. Three one-shot requests start independently in cycles 0..3; their start times, three address relationships and three load kinds are symbolic and held stable. The external model allows independent nondeterministic AR/AW stalls (at most one stalled cycle while the respective slot is free) and produces each R/B beat within two edges after it becomes pending/rearmed, holding it until accepted. Responses are error-free. No assumption forces an internal ready signal, coherence completion or FSM transition. Per-request age assertions check the 32-cycle deadline from presentation, including time before AR. Covers require both entering the unissued/owned-store collision and subsequently completing all three requests on the same trace, plus same-line and PTE-alias completion.

`make -C verification formal-memory-progress-negative` removes only the refill fix in an isolated preprocessed copy and fixes the known failing arrival schedule. It must produce a counterexample to a named progress assertion; compiler errors, solver errors, timeouts and unrelated assertion failures are failures of the negative-control test. Generated packs, source hashes, tool logs and counterexample/cover waveforms are saved under `verification/build/memory-progress/`. `FORMAL_MEMORY_PROGRESS_TIMEOUT` sets the per-task wall-time limit. The reduced formal contract does not establish whole-core liveness, arbitrary traffic fairness, dirty initial cache state, data equivalence, translation, error recovery or full-size cache correctness. Full W4 simulation and the writeback/PTW/MSHR/cancellation tests below provide complementary coverage.

`make -C verification verilator-cache-stream-rv32 verilator-cache-stream-rv64
verilator-cache-stream-l2-rv32 verilator-cache-stream-l2-rv64` runs the complete
L1D/bus/AXI/optional-L2 path with randomized ready stalls. Tests check early critical-word completion,
every resident word across full L1D capacity, CBO set colors and pending fills, 64-byte ZERO AW/W/B
counts and delayed/error B, cancelled/error refills, and PMP page-boundary protection at both cache
levels. With the default 4 KiB PMP grain, the final permitted cache line refills normally while the
adjacent denied page must produce no memory request. Setting `RAPT_PMP_GRANULARITY_LOG2=2` retains
NA4/TOR/NAPOT sub-line fallback coverage, including scalar reads of dirty L2 residents. Repeat with
`XSIM_RAPT_CONFIG=small` to cover 16-byte lines. `verilator-cache-stream-rnp-rv32` checks the word-serial
RNP bridge: the core keeps one burst owner, while the external RNP side uses one transaction per word
and has no error-response encoding.

`default`, `default-w3`, `default-w4`, `default-w8`, and `default-l2` select write-back with four L1D MSHRs and two writeback buffers. `make -C verification verilator-cache-default-rv32 verilator-cache-default-rv64 XSIM_RAPT_CONFIG=<preset>` exercises that preset's policy without a parameter override. The older `cache-stream` targets explicitly select write-through; `cache-stream-wb` explicitly selects write-back.

`make -C verification verilator-wb-ptw-rv32 verilator-wb-ptw-rv64` checks dirty PTE publication, partial store misses against outstanding I/D-side PTW reads, both I/D walkers waiting for an older bus store, and an I-side PTW write invalidating cache state while an older SQ B response arrives. The write-channel case exercises the bus contract; the current Svade walkers do not generate A/D writes. With `XSIM_RAPT_CONFIG=default-l2`, the test checks dirty PTE publication and partial store exclusion through L2 (the held outer-B cases require passthrough L2).

`make -C verification sq-checkpoint-rv32 sq-checkpoint-rv64 SIM_BUILD_PROFILE=<profile> SQ_CHECKPOINT_KIND=cache` checks architectural save/load with dirty victims, eight conflicting L1D lines and a newer partial store after SQ drain. Run it with simulators built from `default` and `default-l2`; add `SQ_CHECKPOINT_REQUIRE_L2=1` for the latter to require captured dirty L2 data. Checkpoints overlay actual dirty L2/L1D SRAM data before committed SQ stores and undo the overlays when execution continues. The runner checks both restore and continued execution with NEMU difftest. The existing `word`, `fp64` and `unaligned` kinds cover pending SQ/AXI stores and split-store drain; use a fresh `BUILD_DIR` for each run.

The BOOM-style write-back preset has a separate L1D/L2 ownership regression: `make -C verification verilator-cache-stream-wb-l2-rv32 verilator-cache-stream-wb-l2-rv64 XSIM_RAPT_CONFIG=default-l2`. It checks dirty L1D releases on L2 eviction and CBO, D-side ownership after a store miss or a resident L2 hit, and an overlapping L1D write-back/CBO. The preset-policy targets also cover this L1D/L2 path in both XLEN modes.

`make -C verification verilator-l2-release-admission-rv32 verilator-l2-release-admission-rv64 XSIM_RAPT_CONFIG=default-l2` checks that a ReleaseData reserves L2 admission from its first beat through gaps between beats and ReleaseAck, then checks the released data remains resident.

`make -C verification verilator-l2-release-probe-rv32 verilator-l2-release-probe-rv64 XSIM_RAPT_CONFIG=default-l2` checks C Release pre-emption while an ordinary victim or CBO waits for Probe. Cases cover dirty data, clean Release, partial word masks, different-tag metadata isolation, and failed outer writeback preserving already-acknowledged ReleaseData. The owner withholds Probe Ack until ReleaseAck; the old ordinary and CBO paths deadlocked in this case.

`make -C verification verilator-l2-owned-read-rv32 verilator-l2-owned-read-rv64 XSIM_RAPT_CONFIG=default-l2` checks twelve owner-Get coherence cases: primary scalar, INCR, FIXED and WRAP reads; clean and dirty Probe Ack; C Release pre-emption; scalar and burst secondary reads; and ordered ownership regrants. It checks dirty data and backpressure, and counts directory reads to verify metadata reuse for equal-tag secondaries and line-local burst beats. A dirty different-tag secondary replacement must be written back before reloading the original tag.

`make -C verification verilator-l2-release-buffer-rv32 verilator-l2-release-buffer-rv64` checks the two Release lists and their shared lowest-free beat pool. It fills both lists with dirty lines, retires one, checks that the other retains its data, and verifies reuse of the freed entries.

`make -C verification verilator-l2-data-array` checks the four-bank data-array geometry and port priority. It also holds a full-line SourceD read between its two row accesses while a SourceC read uses a shared bank, then checks that SourceD retains its first row.

`make -C verification verilator-l2-put-list-rv32 verilator-l2-put-list-rv64` checks the BOOM-sized 40-list/40-beat shared pool, multibeat lists, concurrent push/pop, and full-pool backpressure. `make -C verification verilator-l2-put-buffer-rv32 verilator-l2-put-buffer-rv64 XSIM_RAPT_CONFIG=default-l2` checks the connected single-beat path: all 40 slots, backpressure at slot 41, older-write ordering against an MMIO read, and all 40 ordered write responses.

`make -C verification verilator-l2-secondary-buffer verilator-l2-mshr-scheduler verilator-l2-mshr-frontend` checks the standalone RV64 21-queue/33-entry secondary request buffer, five ordinary plus BC/C reserved MSHR scheduler, and their joined admission/replay fabric. `verilator-l2-secondary-buffer-rv32` checks the RV32 15-queue/35-entry geometry. The scheduler checks same-set priority, reserved-slot pre-emption, C/B/A replay order, bypass on reload, directory-read conflicts and round-robin resource gating. The fabric also checks queued tags and payload ordering. The live L2 uses the secondary queue for same-set requests and different-tag replay; its Release head occupies the reserved C scheduling slot. General BC/C nested metadata forwarding remains incomplete.

`make -C verification verilator-l2-refill-mshrs-rv32 verilator-l2-refill-mshrs-rv64` checks five RV32 or seven RV64 collector contexts, slot-to-AXI-ID remapping, interleaved R beats, sticky errors and metadata retention. `make -C verification verilator-l2-mshr-concurrent-rv32 verilator-l2-mshr-concurrent-rv64 XSIM_RAPT_CONFIG=default-l2` checks three RV32 or five RV64 simultaneous clean read misses through the live L2 and scalar critical-word return before line completion. The live test also checks same-line secondary buffering, FIFO order, restored IDs, and D-side ownership. Different-tag same-set replay and the reserved C Release path have separate directed regressions; the BC slot has no outer B traffic in this last-level configuration.

`make -C verification verilator-l2-line-local-put-rv32 verilator-l2-line-local-put-rv64 XSIM_RAPT_CONFIG=default-l2` checks that bufferable cacheable FIXED, INCR, valid WRAP, and narrow bursts within one line allocate locally. It covers a short masked miss, repeated narrow beats merged into one fetched word, resident address wrapping, local B, untouched-word preservation, and a failed refill returning an error B without installing the line. The associative regressions check a resident short partial burst on this local path.

`make -C verification verilator-l2-cross-line-put-rv32 verilator-l2-cross-line-put-rv64 XSIM_RAPT_CONFIG=default-l2` checks that bufferable cacheable INCR and valid WRAP bursts crossing cache-line boundaries allocate and commit one line at a time. It covers a resident first segment followed by a miss, a narrow boundary write, two full lines without an outer read, a 48-beat burst beyond Put-pool capacity, a three-segment RV64 WRAP that revisits its first line, a second-segment error after the first commits, and a failed refill that drains through WLAST before returning an error B.

`make -C verification verilator-l2-forwarded-error-rv32 verilator-l2-forwarded-error-rv64 XSIM_RAPT_CONFIG=default-l2` checks cacheable forwarded bursts that cannot allocate locally. Resident hit beats are journaled until the matching outer B: an error preserves the old target and older dirty data, while success replays a masked two-beat write before returning B. A legal 256-beat byte-wide INCR burst over four resident lines exercises every journal entry and the shared 40-beat Put pool concurrently. The test checks that no cached byte commits before B and that the first and last words contain the complete replayed data.

`make -C verification verilator-l2-forwarded-client-rv32 verilator-l2-forwarded-client-rv64 XSIM_RAPT_CONFIG=default-l2` checks cacheable non-bufferable scalar and burst writes to resident lines held by the D client. Both paths must issue Probe, hold the successful B until Probe Ack, clear the client owner, preserve unrelated dirty ProbeAckData, and return the updated resident data after B. The two-beat same-line burst permits one Probe; a boundary-crossing burst requires a separate Probe and Ack for each owned line. The test also holds Probe Ack until an unrelated clean C Release receives ReleaseAck while either forwarded path waits for outer B, preventing a Release/Probe wait cycle. C must also finish between the first and last W beats of an active forwarded burst while the next W is stalled. A same-line dirty ReleaseData must commit before the forwarded scalar store and retain its unrelated dirty word; the burst case checks the same ordering when C arrives between W beats. A failed outer B must return an error without probing or changing the old resident data and ownership.

`make -C verification verilator-axi-r-buffer-rv32 verilator-axi-r-buffer-rv64 XSIM_RAPT_CONFIG=default-l2` checks the two-entry outer AXI R buffer, including full backpressure, alternating IDs, error/last fields, sustained one-beat-per-cycle delivery, and AR/AW/W/B passthrough. The write-back L1D/L2 cache-stream targets also instantiate the buffer, matching the `rapt_memory` integration.

`make -C verification verilator-l2-pbmt-boom-rv32 verilator-l2-pbmt-boom-rv64 XSIM_RAPT_CONFIG=default-l2` checks PBMT NC/IO bypass against a hot cacheable alias, preservation of AXI cache attributes and real outer B responses, no allocation for a cold typed write, and alias invalidation after a failed typed write. The older `verilator-l2-pbmt*` targets exercise the legacy posted external DDR-write policy and should be run with the legacy geometry.

Legacy word-response L1D fixtures explicitly select `.LineRefill(0)` to retain their individual-word and partial-line scenarios; production defaults to full line refill. The streaming tests above exercise the production default.

The UVM runner accepts `--l2` with `--top axi`, separating build directories and result names from L2-disabled runs. For example:

```sh
python3 verification/uvm/run.py --uvm-home "$UVM_HOME" --preset default --xlen 64 \
  --top axi --l2 --cases memory pipeline mmu ifetch_mmu pmp faults \
  --seeds 42 --delays 0 7
```

### IOQ registered address preparation

```sh
make -C verification verilator-ioq-address-stage-rv32 verilator-ioq-address-stage-rv64 RAPT_CONFIG=default
```

Covers resident operand wakeup, dispatch-time completion forwarding, request backpressure, flush during preparation, and address ownership through flush and normal queue wraparound. The default `RegisterAddresses=1` prepares an address one cycle after its base operand is stored; both A and HUM B issue require that preparation. `verilator-ioq-overlap-rv32/rv64` additionally checks that unprepared older stores block younger loads before byte-span disambiguation.

### Backend timing boundaries

```sh
make -C verification verilator-fmax-boundaries-rv32 verilator-fmax-boundaries-rv64 RAPT_CONFIG=default
```

These assertion-enabled tests cover the reusable buffered completion arbiter, issue-to-execute registers, and the fixed-position rename packet stage before PRF reads. Checks include simultaneous completions without loss, capacity reservation, rejected completions, generation payloads, wrapped ROB selective cancellation, flush, and three-lane partial consumption with checkpoint retention. The arbiter fixture reserves empty slots before acceptance and does not grant same-cycle dequeue credit. The core has a dedicated FP completion endpoint; the FP result queues are checked by `verilator-feu-ooo-rv32/rv64`. The operand stage accepts a new batch when the old batch fully drains, and compacts a partially consumed suffix while preserving order.

`verilator-rou-fp-irq-compose-rv32/rv64` exercises the actual FP queue, execution, committed FPR storage and interrupt recovery composition. `formal/zkt_cdb.sby` checks control independence from result data across the buffered arbiter using 12-step BMC; this is a bounded check, not an unbounded proof.

### UART platform consistency

```sh
make -C verification uart-platform-check
```

This builds the production NEMU/simulator UART models independently for RV32/RV64. Checks
cover NS16550 RX IRQ10, CU08 LiteUART transmit/receive at `0x11001800`, rejection of the old
high-address alias, and simulator CSR write masks. Canonical DTS compilation checks that the
NS16550 interrupt cells match NEMU Linux presets. Host/MMIO/IRQ receiver stubs keep shared
`.config` files untouched. This does not run a board, Linux/RTL/PLIC integration, or complete
LiteUART event interrupt emulation.

`mmio-transaction-check` exercises the low LiteUART address with bus delays 0/7/63 and seeds
1/42, checking AXI responses and transmitted bytes. `mmio-uart-read-check` checks NS16550
byte lanes and read-to-clear effects. `mmio-uart-irq-check` injects `K` through stdin; a
bare-metal program checks the M-mode external interrupt, PLIC claim 10, received character
and completion, then prints success and writes the finisher. The IRQ check uses a simulator
without difftest to avoid reference-model asynchronous input timing differences.

These flows require a simulator built with `RAPT_AXI_OBSERVE`. An isolated build can be used
explicitly:

```sh
python3 verification/scripts/mmio_transaction_check.py \
  --npc /path/to/riscv64-npc-sim --no-difftest \
  --mrom /path/to/mrom-data.bin --xlen 64 --output /tmp/raptor-chip-mmio64
# Add --uart-read or --uart-irq; RV32 requires matching binaries and --xlen 32.
```

`--no-difftest` checks endpoint/core behavior using a simulator built without difftest; it
does not rebuild that simulator. Use `--reference` with a difftest-enabled model.

### L1D MSHRs and replay

`make -C verification verilator-wb-mshr-rv32 verilator-wb-mshr-rv64` exercises the real
L1D/bus composition: cold Sv32/Sv39 walks overlapping four refills, same-line merging,
interleaved responses across IDs, early critical-word return, independent reads while both
writeback buffers await B, same-address read ordering, full-queue backpressure, late stores
versus accepted loads, store/refill collisions, dirty PTE publication, cancellation,
permission errors and bus errors.

`verilator-wb-mshr-l2-rv32/-rv64` uses `default-l2` and checks inclusive L2 D-client ownership
and dirty victim Release/ReleaseAck. `verilator-mshr-ioq-translated-rv32/-rv64` checks IOQ
park/wake, younger load progress and replay context with translation enabled.
`verilator-l2tlb-cbo-rv32/-rv64` checks that cold L1 TLBs and a warm L2 TLB under a dirty L1D
cause neither page-table reads nor unrelated writebacks.


```sh
make -C verification verilator-mshr-cache-rv32 verilator-mshr-cache-rv64 \
  verilator-mshr-ioq-rv32 verilator-mshr-ioq-rv64 \
  verilator-bus-read-ownership-rv32 verilator-bus-read-ownership-rv64
```

Cache scenarios cover two concurrent lines, same-line merging, replay with a full table,
responses out of ID order, per-beat errors, permission rechecks, store/refill ordering and
drain after cancellation. IOQ scenarios check deferred completion, younger load progress,
simultaneous wake/park and flush. Cache tests force two MSHRs; bus tests use `default`.

Core directed programs check independent loads, multiple consumers of one line,
read-after-store and split accesses:

```sh
python3 verification/scripts/mshr_check.py --npc /path/to/riscv64-npc-sim \
  --mrom /path/to/mrom-data.bin --xlen 64 --output /tmp/raptor-chip-mshr-core64
```

The simulator must enable `RAPT_AXI_OBSERVE`, provide at least two MSHRs (`default` has
four), and disable difftest. The script checks computed values, AXI responses and two live
cache-to-bus miss owners. It records external AXI overlap separately; a serial slave is not
evidence of parallel DRAM performance. `MSHR_OBS` exists only in simulation observer builds.

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

`make -C verification make-targets-test` checks the supported target interface, formatting scopes and
benchmark flag invalidation. `make -C verification sta-flow-check sta-entrypoints-test`
checks the isolated SRAM/DFF runner and offline STA preflight. These checks do
not run synthesis, simulation workloads or FPGA builds.

### W4 latency and prediction regression

Run `make -C verification w4-scaling` (or
`python3 verification/scripts/test_w4_scaling.py --build-dir /tmp/w4-scaling`).
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
make -C verification verilator-l2tlb-rv32 verilator-l2tlb-rv64
make -C verification verilator-cached-ptw-rv32 verilator-cached-ptw-rv64
make -C verification verilator-l2tlb-l1i-epoch-rv32 verilator-l2tlb-l1i-epoch-rv64
make -C verification verilator-l2tlb-l1i-sret-rv32 verilator-l2tlb-l1i-sret-rv64
make -C verification verilator-l2tlb-cbo-rv32 verilator-l2tlb-cbo-rv64
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
make -C verification verilator-fp-registers-rv32 verilator-fp-registers-rv64
make -C verification verilator-feu-ooo-rv32 verilator-feu-ooo-rv64
make -C verification verilator-rou-fp-ooo-rv32 verilator-rou-fp-ooo-rv64
make -C verification verilator-ioq-fp-ooo-rv32 verilator-ioq-fp-ooo-rv64
make build-rv32 build-rv64 BUILD_PROFILE=fp-ooo-check
make -C verification rva22s64-fp-ooo-run RVA22S64_XLEN=32 RVA22S64_CORE_PROFILE=fp-ooo-check
make -C verification rva22s64-fp-ooo-run RVA22S64_XLEN=64 RVA22S64_CORE_PROFILE=fp-ooo-check
```

The block checks cover f0, RAW/WAR/WAW, same-group renaming, FMA's third source, GPR/FP tag separation, independent completion during DIV, continuous fixed-pipeline launch, randomized mixed-unit traffic, backpressure, canceled/late owners, multi-FP commit and precise flags.

`make -C verification/xsim/fpu all` also checks arithmetic against host references; ADD/SUB, MUL, FMA, S/D conversion and both integer-conversion directions include continuous streams, bubbles and flushes. The host-fenv arithmetic checks cover RNE/RTZ/RDN/RUP; FP-to-integer also checks RMM.

IOQ checks cover younger FLH/FLW/FLD completion, A/B payload selection (including B becoming head before its response), boxing, cancellation and removal without duplicate publication; rerun with `VERILATOR_DIRECTED_FLAGS="--binary --timing --assert -Wno-fatal -j 1 -DRAPT_IOQ_LOAD_RESPONSE_STAGE=1"` for registered responses.

The full-core `fp_ooo.S` checks renamed FP store data, mixed precision, integer round trips and an illegal-rounding trap with younger completed work. Its runner uses NEMU difftest with delay 0/7/63 and seeds 1/42. Existing FP privilege, context, page retry, nested IRQ and checkpoint regressions remain applicable. These functional checks do not establish FPGA frequency or area.

### Floating-point cycle performance

`scripts/fp_ooo_performance.py` builds `app/tests/baremetal/fp_ooo_perf.S` once per XLEN/case/precision and runs identical images on the baseline and candidate simulators with NEMU difftest enabled. It requires equal retired-instruction counts inside the measured region and reports `baseline_cycles / candidate_cycles`. Each kernel has four warmup iterations followed by 64 measured iterations; CSR timing, loop and call overhead are included, while initialization, UART output and final self-checks are excluded. Independent arithmetic repeatedly overwrites the same destination to exercise WAW renaming; the chain cases have true RAW dependencies. These are synthetic kernels, not estimates of general application speedup.

For application workloads, use the [CoreMark-PRO](../app/benchmarks/coremark-pro/README.md)
and [Embench](../app/README.md) runners. Record the source revision,
preset, XLEN, memory model, guest binary hash, seeds and completion status.
Compare cycle counts only for matching workloads and configurations; keep
functional failures and timeouts visible in the result set. Timing and resource
claims require separate synthesis or FPGA implementation measurements.

## External verification flows

Run from the repository root with Verilator, a compatible RISC-V cross compiler and the
project dependencies installed. These commands are opt-in; each output directory should
belong to one configuration/run. Store large outputs outside the source checkout.

| Flow | Entry point | Scope and prerequisites |
| --- | --- | --- |
| Upstream self-checking ISA programs | `riscv-tests` | Unmodified physical/single-hart tests, HTIF exit, NEMU lockstep and optional Spike |
| Constrained instruction generation | `riscv-dv` | Python M-mode I/M/C projection, matching RV32/RV64 target, ABI, NPC and MROM |
| Independent recovery model checking | `formal-pono-recovery` | Native Slang/Yosys, Pono and btorsim; complete recovery selector/reference relation |
| Dependency-rich CPU fuzzing | `cascade-fuzz` | Pinned upstream generator, Spike, NPC, matching NEMU, Python 3.11+ |
| Snapshotted long campaigns | `extended-campaign` | Per-lane time budgets, isolated builds, retained failures and source fingerprints |

### Upstream ISA tests and RISCV-DV

`riscv-tests` pins source `3df703cd52d5f0d8224e3c50bf03c6cb70efff98` and test-env
`6de71edb142be36319e380ce782c3d1830c65d68`. Test selection comes from upstream Makefrags;
default groups are `ui um ua uc uf ud uzba uzbb uzbc uzbs uzicond` in the physical `p`
environment. Setup refuses mismatched revisions or dirty dependency checkouts.

```sh
make -C verification riscv-tests-driver-check
make -C verification riscv-tests-setup RISCV_TESTS_ROOT=/tmp/raptor-upstream-tests
make -C verification riscv-tests-list ISA=rv64
make -C verification riscv-tests ISA=rv32 RAPT_CONFIG=small \
  RISCV_TESTS_ROOT=/tmp/raptor-upstream-tests
make -C verification riscv-tests ISA=rv64 RAPT_CONFIG=small \
  RISCV_TESTS_ROOT=/tmp/raptor-upstream-tests
make -C verification riscv-dv ISA=rv32
make -C verification riscv-dv ISA=rv64
```

Override `CROSS_COMPILE`, `RISCV_TESTS_SPIKE`, `RISCV_TESTS_SELECT`, `RISCV_TESTS_GROUPS`,
`RISCV_TESTS_TIMEOUT`, `RISCV_TESTS_JOBS`, `RISCV_TESTS_MEM_DELAYS` and
`RISCV_TESTS_MEM_SEEDS` as needed. NPC and MROM builds are isolated by XLEN/preset.
The optional `--tohost` mailbox requires a RAM address aligned to eight bytes; device/command
zero and odd payload encode exit, with payload one meaning success. Reports require the
actual XLEN, HTIF success, GOOD TRAP and requested difftest activation, and record commands,
exit codes and binary hashes. Empty/misspelled selections, timeouts and changed inputs fail.
Spike uses `Zicclsm` to match ordinary RAM misalignment behavior. A caller-supplied NPC needs
independent build provenance; observing source hashes does not establish binary provenance.

RISCV-DV remains pinned at `b7a0b4b0b51346a3c64f159f81ea262d867c14a9`. The Python flow's
M-mode projection does not establish supervisor paging, real interrupt injection, random
atomics, or complete IMAFDC coverage. Upstream ACT4/Sail architecture tests and RVFI checks
remain separate verification methods.

### Pono and Cascade

```sh
make -C verification advanced-driver-check
make -C verification formal-pono-recovery PONO_OUT=/tmp/raptor-pono-run
make -C verification cascade-setup CASCADE_ROOT=/tmp/raptor-cascade
make -C verification cascade-fuzz ISA=rv64 RAPT_CONFIG=small \
  CASCADE_ROOT=/tmp/raptor-cascade CASCADE_OUT=/tmp/raptor-cascade/run64
```

Pono requires a checked IC3 invariant for safety, a btorsim-replayed cumulative event cover,
and replayable counterexamples for mask, held-tie and generation mutations. The recovery
model assumes first-edge reset and an in-range ROB head; it preserves the complete DUT
transition relation. Set `RAPTOR_YOSYS_REAL`, `PONO`, `BTORSIM` and `PONO_ARGS` explicitly
when using externally installed tools. A bounded run is not an unbounded proof.

Cascade pins `cascade-meta` at `c3de482f2c5451b4c571bc0384da45a84f892084`; setup installs
the dependency pins in `external-verification.mk` in an isolated environment. Build Spike beforehand and set
`CASCADE_SPIKE` if necessary. Controls include `CASCADE_SEEDS`, `CASCADE_BLOCKS`,
`CASCADE_INSTRUCTIONS`, `CASCADE_MEM_DELAYS`, `CASCADE_TIMEOUT`, `CASCADE_ISA_PROFILE`,
`CASCADE_MEM_BYTES` and `CASCADE_MEMORY_SEED`. The adapter compares GPR/FPR checkpoints
against upstream Spike expectations, with NEMU lockstep and memory delays 0/31 by default.
Wrong XLEN/checkpoint, missing registers, failed generation, timeout or mismatch fail the run;
failed seeds are retained. Scope is single-hart M-mode without translation, coverage-feedback
scheduling, automated reduction or supervisor/VM profiling. Optional line/toggle collection
measures that instrumentation only.

`extended-campaign` snapshots the source, builds isolated simulators, and defaults to six
RV32/RV64 fuzz lanes (`small`, `middle-cache`, `default-w4-cache`), one Pono lane and one block
formal lane, each with 10800 seconds of active verification. Builds do not count toward the
budget. Use `EXTENDED_CAMPAIGN_OUT`, `EXTENDED_CAMPAIGN_SECONDS`,
`EXTENDED_CAMPAIGN_PRESETS` and `EXTENDED_CAMPAIGN_XLENS` to configure it; inspect resources
before launching. Direct `scripts/extended_campaign.py --resume` requires the unchanged
snapshot and preserves failures. Elapsed duration and a successful tool installation do not
establish whole-RTL correctness or architecture/profile certification.
