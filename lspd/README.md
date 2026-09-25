# LSPD standalone module synthesis and physical design

This directory provides fast, independent synthesis and static timing analysis for the major first-level modules instantiated by `hdl/rapt_core.sv`.

The flow uses Yosys with the slang SystemVerilog frontend and OpenSTA. It reuses the open PDK data and mapping configuration under `third_party/yosys-opensta` for ASAP7, NanGate45, and SKY130 HD.

RTL parameter contracts use generate-time error checks: invalid configurations fail elaboration and valid configurations contain no assertion hardware. The flow uses the frontend's default unroll limit, without ignoring initial blocks or removing assertion cells. `make -C lspd/syn elaborate MODULE=core` checks this boundary before technology mapping. ROB/UOQ/IQ entries use generated local state writers; small procedural port loops express priority within an entry.

The physical-design flow uses the mapped synthesis netlist as OpenROAD input. It currently enables NanGate45, which has a complete local LEF, Liberty, RC, and GDS platform setup in this repository. The interface is intentionally parallel to the synthesis flow so more physical-design platforms can be added without changing module-level usage.

## Subsystem evaluation

The three composition blocks are registered as `frontend`, `backend`, and
`memory`. They share the existing `syn`, `sta`, `ppa`, `fpga-syn`, and physical
design entry points with `core`:

| Module | Synthesis top | Boundary |
| --- | --- | --- |
| `frontend` | `rapt_frontend` | Fetch/prediction/decode; instruction cache remains in memory |
| `backend` | `rapt_backend_syn_top` | Rename, scheduling, execution, retirement, LSU/SQ, CSR |
| `memory` | `rapt_memory` | L1I/L1D, translation, bus, AXI bridge, optional L2 |

The backend adapter preserves independent native inputs and exports all fields
of its four internally produced broadcast interfaces. Internal interface instances
allow both producers and consumers to use their original modports. It adds no
registers, stimulus correlation, or output reduction. This baseline does not enable
`RAPT_RVFI`; the adapter does not export optional RVFI observation ports.

```sh
source env.sh
for module in frontend backend memory; do
  make -C lspd/syn structure-check MODULE=$module EXTRA_DEFINES=-DRAPT_RV64
done
make -C lspd ppa-all MODULES_TO_RUN="frontend backend memory" \
  RAPT_CONFIG=default PDK=nangate45 EXTRA_DEFINES=-DRAPT_RV64 \
  CLK_FREQ_MHZ=50 SRAM_MODE=macro PARALLEL_JOBS=3
for module in frontend backend memory; do
  make -C lspd fpga-syn MODULE=$module RAPT_CONFIG=default FPGA_XLEN=64 \
    CLK_FREQ_MHZ=50 FPGA_PART=xcku15p-ffva1156-2-e
done
```

For RV32, omit `EXTRA_DEFINES=-DRAPT_RV64` and set `FPGA_XLEN=32`.
ASIC output paths do not encode XLEN or SRAM mode: archive results or override
`BUILD_DIR` for individual runs before switching either setting. FPGA output paths
include XLEN. Default memory parameters select eight read credits, write-through
L1D and the preset's L2 setting (disabled in `default`).

ASIC macro-mode results use abstract SRAM Liberty models, not a fabricated
Nangate45 SRAM implementation. FPGA uses behavioral memories and Vivado OOC
synthesis. Both use a 20 ns clock and 4 ns input/output delays in the commands
above. Synthesis timing is not routed timing; independently optimized block areas
are not additive to the core, and cross-block timing still requires whole-core STA.

For placement/routing and layout images, first explicitly rebuild the netlist
through `lspd/pnr syn`, which forces flop-mapped memories. The physical flow
does not provide matching physical SRAM LEF views:

```sh
make -C lspd/pnr syn MODULE=frontend PDK=nangate45 EXTRA_DEFINES=-DRAPT_RV64 \
  RAPT_CONFIG=default CLK_FREQ_MHZ=50
make -C lspd pnr MODULE=frontend PDK=nangate45 EXTRA_DEFINES=-DRAPT_RV64 \
  RAPT_CONFIG=default CLK_FREQ_MHZ=50 SRAM_MODE=flops
make -C lspd viz MODULE=frontend PDK=nangate45 EXTRA_DEFINES=-DRAPT_RV64 \
  RAPT_CONFIG=default CLK_FREQ_MHZ=50 SRAM_MODE=flops
```

Replace `frontend` with `backend` or `memory` for the other blocks. These commands
rebuild the ASIC baseline with flop-mapped memories; preserve macro-mode reports
first. Physical implementation is a separate evaluation, not implied by an OOC
synthesis pass.

### Initial measurements (2026-09-21)

Default preset, RV64, 50 MHz, L2 disabled, write-through L1D. Native
`structure-check` passed for all three blocks in both RV32 and RV64.

| Block | Nangate45 cells | Area (Liberty units) | ASIC WNS (ns) | FPGA LUTs | FPGA FFs | FPGA setup slack (ns) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| frontend | 131445 | 208370.036 | +10.621 | 15527 | 5320 | +9.065 |
| backend | incomplete | incomplete | incomplete | incomplete | incomplete | incomplete |
| memory | 385722 | 1148329.520 | +7.541 | incomplete | incomplete | incomplete |

Completed ASIC reports passed the constraint audit with zero TNS. Register-only
setup budgets are 5.868 ns (frontend) and 4.731 ns (memory), not full-design Fmax.
Frontend FPGA uses 304 LUTRAMs (included in total LUTs), no BRAM, and no DSP.
FPGA figures are KU15P OOC synthesis estimates, not placement/routing results.
Backend ASIC spent over 20 minutes in Yosys resource-sharing analysis. Its
initial run was stopped before mapping completed; FPGA synthesis was stopped
during timing optimization. Neither is a tool-reported functional failure, but
neither supplies a completed area or timing result. Rerun the commands above
with a larger runtime budget to complete this baseline.
Memory FPGA was also started but stopped before a final report was available.
All incomplete entries above are stopped attempts, not jobs left running by this
evaluation. Whole-chip `make sta` was invoked, but the duplicate run was stopped
after discovering an earlier job using the same output directory; no full-chip
STA pass is claimed. The separate RV64 `make sta-check` slang gate passed.

Raw ASIC reports are under `syn/build/default/nangate45/<module>/50MHz/`;
FPGA reports are under
`fpga/build/default/xcku15p-ffva1156-2-e/rv64/<module>/50MHz/`.
Each completed run retains configuration, source hashes, tool logs, timing and
resource reports. No new physical layout or routed timing result is claimed here.

### Continuation measurements (2026-09-21)

Memory FPGA completed from the frozen source snapshot
`tmp/subsystem-eval-snapshot.8NhqOL`, using the same RV64/default/50 MHz KU15P
configuration. Reports are in `fpga/build/subsystem-snapshot-rv64/memory/`.
The source-manifest check passed. These newer sources are not the same revision
as the initial ASIC measurements above.

| Total LUTs | Logic LUTs | LUTRAMs | FFs | RAMB36 | DSPs | Setup slack (ns) | Hold slack (ns) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 71400 | 68700 | 2700 | 30128 | 32 | 0 | +5.768 | +0.040 |

TNS is zero; Vivado reports all specified timing constraints met. Synthesis took
1726.13 seconds with peak RSS 9548036 KiB. This is OOC synthesis, not routed timing.
The subsequent backend attempt exposed a missing `writeback_drain` output in its
adapter. The adapter now exports that output, and RV32/RV64 snapshot structure
checks passed before restarting backend FPGA synthesis. The memory manifest does
not include the unrelated backend adapter.

Frontend physical implementation completed in 7870.24 seconds with zero reported
routing DRC violations, WNS +9.508 ns and TNS 0. The report lists 318923 instances,
218546 um2 design area, 526713.0625 um2 die area and 42% utilization. The mapped
source-manifest check still passes. Reports and layout images are under
`pnr/build/subsystem-continuation-rv64/frontend/`. This is a standard-cell,
flop-mapped-memory evaluation, not the abstract-SRAM ASIC baseline above; zero
router DRC violations do not constitute foundry signoff.

The live-workspace backend ASIC and memory physical-netlist attempts completed
mapping but failed source-manifest validation after concurrent edits. Their
netlists were removed by the flow and are not accepted results.

Checked on 2026-09-22, backend FPGA completed successfully with a passing source
manifest: 277985 total LUTs (277869 logic, 112 LUTRAM, 4 SRL), 87924 FFs, 27 DSPs
and no BRAM/URAM. Setup slack is +3.806 ns, hold slack +0.046 ns and TNS zero.
Elapsed time was 14386.42 seconds. Reports are in
`fpga/build/subsystem-snapshot-rv64/backend/`. These are OOC synthesis estimates,
not routed timing; the log's earlier memory-thrashing warnings did not prevent
completion.

The optional `SYNTH_SHARE=0` setting disables Yosys SAT resource sharing via
`synth -noshare`. The default remains `SYNTH_SHARE=1`, and the value is tracked in
the synthesis configuration stamp so changing it rebuilds the netlist. New STA
run configurations also record `synth_share`. This is
a runtime/PPA tradeoff experiment, not an established area or timing improvement:
the previous backend run spent 5692 seconds in resource sharing alone.

A separate frozen snapshot, `tmp/subsystem-noshare.YmY5c8`, retains the earlier
HDL snapshot and updated synthesis flow. It runs backend then memory with RV64,
50 MHz, flop-mapped memories and `SYNTH_SHARE=0`, followed by standard PNR and
layout rendering. Outputs are isolated under
`syn/build/subsystem-noshare-rv64/<module>-flops/` and
`pnr/build/subsystem-noshare-rv64/<module>/`. Backend synthesis and STA completed
with a passing source manifest: synthesis took 5763.75 seconds, mapped Liberty
area is 1489494.132 um2, WNS +7.7410 ns and TNS zero. ABC now accounts for 4106
seconds of synthesis CPU work. This does not establish a controlled speedup over
the earlier macro-mode attempt, which used different memory mapping.

Backend standard PNR remains active; memory synthesis follows it in the serial
chain. No final backend physical result or memory no-share result is claimed.
At the latest 2026-09-22 check, backend had run for about 9.5 hours and reached
global routing after writing `3_cts.odb`; OpenROAD remained CPU-active with about
24 GiB resident memory. The serial memory job had not started.
The good/missing-driver synthesis regression passed with resource sharing
disabled. Keep these flop-mapped results separate from the macro-mode baseline.

LSPD physical implementation now accepts `PNR_THREADS` (default `1`) and passes
it explicitly to OpenROAD. For a subsequent isolated experiment, append
`PNR_THREADS=4` to the existing `make -C lspd/pnr pnr` command. The installed
OpenROAD reports four active threads with this option, and Make argument
forwarding has been checked. This is not yet a measured routing speedup; some
stages may remain serial. Running jobs retain their original thread settings.
When using `pnr-all`, budget `PARALLEL_JOBS * PNR_THREADS` CPU threads and memory
for each design; the automatic job-count estimate does not account for this
thread multiplier or the large backend's measured memory footprint.

## Quick start

The root `make sta` entry uses `sim`'s packed whole-chip flow; the module commands below use LSPD. Normal STA checks the installed tools without fetching or updating repositories. For explicit whole-chip tool provisioning, run `make -C sim sta-setup STA_PLATFORM=nangate45` (network access and installation permissions required). `make -C sim sta-deps` only checks readiness. The packed-RTL checks first run `synth-frontend-check`. After upgrading Yosys, rerun `sta-setup`: the Slang plugin must match the new Yosys ABI and be installed in that version's plugin directory. Copying an old `slang.so` is insufficient.

Before mapping, `make -C sim pack-sram-synth-check` checks the whole-chip RTL against SRAM macro port contracts; `pack-synth-check` checks behavioral SRAM. Both use native Slang declaration rules and default expansion limits. Add `VFLAGS=-DRAPT_RV64` for RV64 and `BUILD_PROFILE=sta-check-rv64` to isolate outputs; neither check changes the shared simulator configuration.

```sh
make -C lspd list
make -C lspd doctor PDK=nangate45
make -C lspd ppa MODULE=ifu PDK=nangate45 RAPT_CONFIG=default CLK_FREQ_MHZ=100
make -C lspd ppa MODULE=l1i PDK=nangate45 RAPT_CONFIG=small SRAM_MODE=macro
make -C lspd ppa-all-pdks MODULE=l1d RAPT_CONFIG=small CLK_FREQ_MHZ=80
make -C lspd ppa-all MODULES_TO_RUN="ifu fqu idu rnu" PDK=asap7
make -C lspd ppa-matrix RAPT_CONFIG=small PARALLEL_JOBS=3
make -C lspd ppa-summary PDK=nangate45 RAPT_CONFIG=small
make -C lspd ppa-summary-all-pdks RAPT_CONFIG=small
make -C lspd parallel-info
make -C lspd pd-doctor PDK=nangate45
make -C lspd pnr MODULE=fqu PDK=nangate45 RAPT_CONFIG=small CLK_FREQ_MHZ=100
make -C lspd viz MODULE=fqu PDK=nangate45 RAPT_CONFIG=small CLK_FREQ_MHZ=100
make -C lspd pd-summary PDK=nangate45 RAPT_CONFIG=small MODULES_TO_RUN="fqu cmu"
make -C lspd pnr-all PDK=nangate45 RAPT_CONFIG=small MODULES_TO_RUN="fqu cmu"
```

`ppa-all` evaluates different modules concurrently. `ppa-all-pdks` evaluates the three PDK mappings concurrently for one module. GNU Make's jobserver limits the active processes, and `--output-sync=target` keeps each module's console output together. `ppa-matrix` evaluates every selected module on every PDK; `MODULES_TO_RUN` defaults to all supported modules.

The default parallelism is the smaller of the logical CPU count and available memory divided by 6 GiB per synthesis job. Override either assumption when needed:

```sh
make -C lspd ppa-all PDK=nangate45 PARALLEL_JOBS=24
make -C lspd ppa-all PDK=sky130 JOB_MEMORY_MB=8192
```

Large cache/core configurations can consume substantially more memory than small frontend blocks. Reduce `PARALLEL_JOBS` or increase `JOB_MEMORY_MB` when running `core`, `l1i`, `l1d`, and enabled `l2` together.

Supported module names are `core`, `bpu`, `ifu`, `fqu`, `stream_queue`, `l1i`, `idu`, `rnu`, `rename_checkpoint`, `rou`, `prf`, `fpr`, `dpu`, `dispatch_select`, `dispatch_steer`, `issue_select`, `muldiv_fu`, `ieu`, `feu`, `cmu`, `csr`, `lsu`, `l1d`, `bus`, `axi`, and `l2`. `dpu` isolates K-to-W domain/token compaction; `dispatch_select` isolates ROB rotation/rank and acceptance accounting; `dispatch_steer` combines both with indexed domain lookup and selected physical identities, but not the wide operand payload read. `issue_select` exposes the combinational issue-selection cone with a clock port used only as an IO timing reference; it inserts no pipeline registers. `muldiv_fu` exposes the complete `rapt_ieu_mul` arithmetic unit, including both multiply and divide paths, with native independent operands, operation, word mode, tag, and handshake ports. It excludes the MDQ and completion arbiter. For the RV64 four-entry MDQ tag shape, use `EXTRA_DEFINES='-DRAPT_RV64 -GTAG_W=2'`; select `SRAM_MODE=flops` because this leaf contains no SRAM. A full-unit worst path can be in the multiplier and need not describe divider-specific timing. Use `make -C lspd list` to show the corresponding RTL top modules.

Module-only synthesis adapters live in `lspd/hdl_wrapper/`. Only the selected top's adapter is parsed, so an unrelated stale wrapper cannot invalidate a module's report after an interface refactor. They do not enter the product `hdl/` tree, simulator pack, or tapeout RTL file list. DPU retains its `stimulus` / `response` adapter. IEU, FEU and LSU expose independent typed dispatch and completion arrays plus native interface ports; their queue grants and capacity outputs are flattened per slot with queue-specific index widths. They add no output reduction or correlated stimulus fan-in to the measured logic. Select XLEN/ROB/payload types through the preset and `-DRAPT_RV64`, not independent wrapper width overrides. FPR A/B/C names denote three operands, not dispatch lanes.

The focused native elaboration gate covers IEU/FEU in RV32, RV64, and scaled configurations (three dispatch slots, seven completions, seven-entry queue; IEU also has four integer ports with system port 2):

```sh
python3 verify/scripts/rtl_synthesis_check.py --only execution \
  --output /tmp/execution-wrapper-native-final
```

This gate uses default frontend limits and fingerprints HDL, wrappers and flow Makefiles. It is elaboration evidence, not mapped area or timing closure; old stimulus-wrapper PPA is not directly comparable to this new boundary.

LSU has a separate focused group covering RV32, RV64 and an expanded RV64 configuration (three dispatch slots, seven completions, IOQ 16, SQ 32). Its wrapper preserves the committed-store interface and completion acceptance; it does not add selective cancellation to the LSU or alter store draining. Use `--check-structure` to additionally run ordinary `opt` followed by `check -assert`, failing on remaining structural problems:

```sh
python3 verify/scripts/rtl_synthesis_check.py --only lsu --check-structure \
  --output /tmp/lsu-wrapper-structure-final
# The same stronger check is available for any individual synthesis top:
make -C lspd/syn structure-check MODULE=lsu BUILD_DIR=/tmp/lsu-structure
```

Reports distinguish elaboration-only from optimized structural checks. Neither performs technology mapping or proves protocol/ISA correctness.

The mapped synthesis flow also fails closed on structural problems: ordinary `opt; check -assert` runs before synthesis and undriven-value normalization, and a second `check -assert` guards the final mapped netlist. A missing live driver must not silently become a constant through `setundef -zero`. Exercise the actual Tcl flow with valid and deliberately undriven fixtures:

```sh
make -C verify synthesis-driver-check
```

This check uses the installed Yosys/slang and Nangate45 library. It is a tool-flow regression test, not evidence that every production configuration synthesizes.

STA runs a fatal `check_setup -verbose` constraint audit before timing reports. Each run first writes `status incomplete` to invalidate an earlier successful summary; only a completed run writes `status ok`. The summary collector rejects explicitly incomplete reports even if old netlists/logs remain. Legacy summaries without a status field remain readable, but are not retroactively certified by the new audit. Exercise real constrained/unconstrained-clock fixtures with:

```sh
make -C verify sta-constraint-check
```

Constraint coverage is not timing closure: negative slack remains a reported timing result, not an unconstrained-path error.

Timing schema 2 reports global WNS/TNS and, when a register-to-register path exists, `reg_setup_budget_ns` (target period minus register-only setup slack). It no longer estimates `period_min_ns`/`fmax_mhz` from global slack: IO delays can dominate that slack. The summary table shows register setup budget rather than Fmax; legacy reports without a register-only metric show N/A. The metric still depends on the clocks, exceptions, library and interconnect model and is not a full-design frequency guarantee.

Results are isolated by configuration, PDK, module, and target frequency:

```text
lspd/syn/build/<config>/<pdk>/<module>/<frequency>MHz/
  <top>.netlist.v
  <top>.stat.rpt             # mapped cell counts and Liberty area
  <top>.sta_summary.rpt
  synth.log
  sta.log
  synth.profile             # synthesis wall/CPU time and peak RSS
  sta.profile               # STA wall/CPU time and peak RSS
  run_config.txt            # exact module/config/constraint/define tuple
  source_manifest.sha256    # source hashes used by synthesis
  netlist.sha256            # mapped-netlist hash
  sram_model.txt            # SRAM implementation mode and model provenance
```

Cache data arrays use `SRAM_MODE=macro` by default. This mode preserves supported L1I, L1D, and L2 arrays as explicit SRAM instances and automatically generates the abstract Verilog and Liberty models required by synthesis and STA. Unsupported array shapes fail synthesis instead of silently expanding to registers. Use `SRAM_MODE=flops` to reproduce the logic-mapped baseline:

```sh
make -C lspd ppa MODULE=l1d RAPT_CONFIG=small PDK=nangate45 SRAM_MODE=flops
```

The generated `sram_model.txt` identifies which mode and model platform were used for an individual result. `SRAM_PLATFORM=sky130` currently selects the abstract model shape set; it does not imply that the selected standard-cell PDK contains characterized Sky130 SRAM macros.

Report generation is separate from synthesis and STA so existing build results can be summarized without rerunning evaluation. Generate one PDK report with:

```sh
make -C lspd ppa-summary \
  PDK=nangate45 RAPT_CONFIG=small CLK_FREQ_MHZ=100 \
  MODULES_TO_RUN="ifu fqu idu rnu"
```

Generate reports for all three PDKs from their existing results with:

```sh
make -C lspd ppa-summary-all-pdks \
  RAPT_CONFIG=small CLK_FREQ_MHZ=100 \
  MODULES_TO_RUN="ifu fqu idu rnu"
```

Each generated report is written to:

```text
lspd/syn/build/<config>/<pdk>/ppa_summary.md
lspd/syn/build/<config>/<pdk>/profile_summary.md
```

The table contains mapped cell count and area, WNS/TNS, estimated minimum period and Fmax, and total vectorless power for every requested module. Missing build results are shown as `missing` with `N/A` metrics.

`profile_summary.md` records synthesis, STA, and total wall time, CPU time, peak RSS, and build output size for each module. It also reports the number of RTL files and nonblank RTL lines retained in the synthesized hierarchy as reproducible proxies for development complexity. Run `make -C lspd profile-summary` to regenerate it from existing profile files without rerunning synthesis.

## Interpretation

## FPGA Module Synthesis

`make -C lspd fpga-syn` reuses the module registry, source selection and selected
native interface adapter. It runs Slang elaboration and structural checks, exports
unmapped Verilog, and runs Vivado out-of-context synthesis. The export lowers
Yosys internal bitwise mux cells with `bwmuxmap` and preserves RTL attributes,
including FPGA memory hints. Attribute preservation does not guarantee BRAM
inference: verify LUTRAM/BRAM counts in the utilization report.
It does not use ASIC
Liberty mapping or abstract SRAM macros. Behavioral memories remain available for
Vivado inference; BRAM inference is not guaranteed. This export path is distinct
from direct Vivado SystemVerilog synthesis: compare variants using the same path.

```sh
make -C lspd fpga-syn MODULE=recovery_pending FPGA_XLEN=32 \
  EXTRA_DEFINES='-GEntries=32 -GXlen=32' CLK_FREQ_MHZ=50
make -C lspd fpga-syn MODULE=recovery_pending FPGA_XLEN=64 \
  EXTRA_DEFINES='-GEntries=32 -GXlen=64' CLK_FREQ_MHZ=50
make -C lspd fpga-syn MODULE=rename_checkpoint FPGA_XLEN=64 CLK_FREQ_MHZ=50
```

`FPGA_XLEN` selects the RV64 macro and output directory; independent leaf parameters
must still be provided with `EXTRA_DEFINES`, as shown for recovery's `Xlen`.
Do not pass a conflicting XLEN macro in `EXTRA_DEFINES`.
Defaults are `FPGA_PART=xcku15p-ffva1156-2-e`, `FPGA_THREADS=4`,
`FPGA_XLEN=64`, `RAPT_CONFIG=default`, and `CLK_FREQ_MHZ=100`.
The flow defines `RAPT_FPGA_DSP=1` and uses behavioral memories (`SRAM_MODE=flops`
in the shared LSPD source selector, not forced FPGA flip-flop mapping).
Use `FPGA_BUILD_DIR` to isolate parameter variants; every invocation reruns synthesis
and an exclusive lock prevents concurrent writers to the same output directory.

Results default to `lspd/fpga/build/<config>/<part>/rv<xlen>/<module>/<frequency>MHz/`:
`run_config.txt`, `tools.txt`, source and artifact SHA256 manifests, `export.log`,
`export.profile`, `synth.profile`, `vivado.log`, `module.xdc`, `utilization.rpt`,
`timing.rpt`, `constraints.rpt`, and `synth.dcp`. Source changes during the run fail
the check. Only `status.txt` containing `status ok` marks a completed run; stale
reports from an incomplete run must not be used.

The XDC is loaded before synthesis. Inputs and outputs have delays equal to
`IO_DELAY_FRAC` (default 0.20) times the target period. Review constraint coverage
and slack separately: completion is not a timing-closure certificate. These are
post-synthesis estimates, not routed Fmax or evidence of whole-chip routability.
Module synthesis does not prove functional correctness; retain focused formal or
simulation regressions and the repository's whole-chip `make sta` RTL gate.

For bottleneck work, compare one change at a time in `recovery_pending`,
`rename_checkpoint`, `dispatch_steer`, and the execution/cache modules. Record
both export and Vivado time, LUT/FF/BRAM/DSP counts, and timing under identical
parameters. Module-local improvements still require integration validation.

## ASIC Interpretation

This is a pre-layout comparison flow. STA uses ideal clocks, a default input and output delay of 20% of the requested period, a 5 fF output load, and uniform vectorless switching activity. Override these with `IO_DELAY_FRAC` and `OUTPUT_LOAD_FF` when needed.

L1I, L1D, and enabled L2 data arrays are represented by abstract SRAM macros in the default mode so register and mux expansion does not dominate area and timing. The bundled placeholder area and timing values are not characterized for ASAP7, NanGate45, or SKY130 HD and must not be treated as SRAM signoff PPA. They are intended for architecture-level comparisons until foundry- and compiler-characterized macro views are supplied. L2 is a passthrough unless the selected RTL configuration enables `RAPT_L2_EN`.

The three PDKs use different architectures and corners. Compare variants within one PDK directly; use cross-PDK numbers as directional estimates only.

## Physical design

`make -C lspd pnr` automatically builds the matching `lspd/syn` netlist with `SRAM_MODE=flops`, then runs floorplanning and PDN generation, placement, CTS, global and detailed routing, parasitic extraction, and post-route reporting. Physical SRAM macro placement is not enabled yet, so cache-heavy blocks remain a logic baseline in this flow.

Results use the same configuration/PDK/module/frequency isolation as synthesis:

```text
lspd/pnr/build/<config>/<pdk>/<module>/<frequency>MHz/
  <top>_final.def            # final exchange layout
  <top>_final.odb            # OpenROAD database
  <top>_final.v              # post-route netlist
  <top>_final.spef           # extracted parasitics when RC rules are available
  area_final.rpt
  timing_{max,min}_final.rpt
  power_final.rpt
  <top>_route_drc.rpt
  pnr_metrics.txt
  pnr.profile
  images/
    <top>_layout.png
    <top>_floorplan.png
    <top>_placed.png
    <top>_cts.png
    <top>_grouted.png
```

`pd-summary` writes `lspd/pnr/build/<config>/<pdk>/pnr_summary.md` with post-route instance count, cell and die area, utilization, WNS/TNS, estimated Fmax, vectorless power, detailed-route violations, runtime, peak memory, and visualization status. Use `CORE_UTILIZATION`, `CORE_ASPECT_RATIO`, and `PLACE_DENSITY` to evaluate floorplan tradeoffs. `PNR_MODE=fast` selects the repository's reduced-runtime OpenROAD flow for iteration; the default is `standard`. The `viz` target uses the repository's KLayout batch renderer and Nangate45 layer properties.
