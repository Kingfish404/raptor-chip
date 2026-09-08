# LSPD standalone module synthesis and physical design

This directory provides fast, independent synthesis and static timing analysis
for the major first-level modules instantiated by `hdl/rapt_core.sv`.

The flow uses Yosys with the slang SystemVerilog frontend and OpenSTA. It reuses
the open PDK data and mapping configuration under `third_party/yosys-opensta`
for ASAP7, NanGate45, and SKY130 HD.

RTL parameter contracts use generate-time error checks: invalid configurations
fail elaboration and valid configurations contain no assertion hardware. The
flow uses the frontend's default unroll limit, without ignoring initial blocks
or removing assertion cells. `make -C lspd/syn elaborate MODULE=core` checks
this boundary before technology mapping. ROB/UOQ/IQ entries use generated local
state writers; small procedural port loops express priority within an entry.

The physical-design flow uses the mapped synthesis netlist as OpenROAD input.
It currently enables NanGate45, which has a complete local LEF, Liberty, RC,
and GDS platform setup in this repository. The interface is intentionally
parallel to the synthesis flow so more physical-design platforms can be added
without changing module-level usage.

## Quick start

The root `make sta` entry uses `sim`'s packed whole-chip flow; the module
commands below use LSPD. Normal STA checks the installed tools without fetching
or updating repositories. For explicit whole-chip tool provisioning, run
`make -C sim sta-setup STA_PLATFORM=nangate45` (network access and installation
permissions required). `make -C sim sta-deps` only checks readiness.
The packed-RTL checks first run `synth-frontend-check`. After upgrading Yosys,
rerun `sta-setup`: the Slang plugin must match the new Yosys ABI and be installed
in that version's plugin directory. Copying an old `slang.so` is insufficient.

Before mapping, `make -C sim pack-sram-synth-check` checks the whole-chip RTL
against SRAM macro port contracts; `pack-synth-check` checks behavioral SRAM.
Both use native Slang declaration rules and default expansion limits. Add
`VFLAGS=-DRAPT_RV64` for RV64 and `BUILD_PROFILE=sta-check-rv64` to isolate
outputs; neither check changes the shared simulator configuration.

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

`ppa-all` evaluates different modules concurrently. `ppa-all-pdks` evaluates
the three PDK mappings concurrently for one module. GNU Make's jobserver limits
the active processes, and `--output-sync=target` keeps each module's console
output together. `ppa-matrix` evaluates every selected module on every PDK;
`MODULES_TO_RUN` defaults to all supported modules.

The default parallelism is the smaller of the logical CPU count and available
memory divided by 6 GiB per synthesis job. Override either assumption when
needed:

```sh
make -C lspd ppa-all PDK=nangate45 PARALLEL_JOBS=24
make -C lspd ppa-all PDK=sky130 JOB_MEMORY_MB=8192
```

Large cache/core configurations can consume substantially more memory than
small frontend blocks. Reduce `PARALLEL_JOBS` or increase `JOB_MEMORY_MB` when
running `core`, `l1i`, `l1d`, and enabled `l2` together.

Supported module names are `core`, `bpu`, `ifu`, `fqu`, `stream_queue`, `l1i`, `idu`, `rnu`, `rename_checkpoint`,
`rou`, `prf`, `fpr`, `dpu`, `dispatch_select`, `dispatch_steer`, `issue_select`, `muldiv_fu`, `ieu`, `feu`, `cmu`, `csr`, `lsu`,
`l1d`, `bus`, `axi`, and `l2`. `dpu` isolates K-to-W domain/token compaction;
`dispatch_select` isolates ROB rotation/rank and acceptance accounting;
`dispatch_steer` combines both with indexed domain lookup and selected physical
identities, but not the wide operand payload read.
`issue_select` exposes the combinational issue-selection cone with a clock port
used only as an IO timing reference; it inserts no pipeline registers.
`muldiv_fu` exposes the complete `rapt_ieu_mul` arithmetic unit, including both
multiply and divide paths, with native independent operands, operation, word
mode, tag, and handshake ports. It excludes the MDQ and completion arbiter.
For the RV64 four-entry MDQ tag shape, use `EXTRA_DEFINES='-DRAPT_RV64 -GTAG_W=2'`;
select `SRAM_MODE=flops` because this leaf contains no SRAM. A full-unit worst
path can be in the multiplier and need not describe divider-specific timing.
Use `make -C lspd list` to show the corresponding RTL top modules.

Module-only synthesis adapters live in `lspd/hdl_wrapper/`. Only the selected
top's adapter is parsed, so an unrelated stale wrapper cannot invalidate a
module's report after an interface refactor. They do not enter the product
`hdl/` tree, simulator pack, or tapeout RTL file list. DPU retains its
`stimulus` / `response` adapter. IEU, FEU and LSU expose independent typed dispatch
and completion arrays plus native interface ports; their queue grants and
capacity outputs are flattened per slot with queue-specific index widths.
They add no output reduction or correlated stimulus fan-in to the measured
logic. Select XLEN/ROB/payload types through the preset and `-DRAPT_RV64`, not
independent wrapper width overrides. FPR A/B/C names denote three operands,
not dispatch lanes.

The focused native elaboration gate covers IEU/FEU in RV32, RV64, and scaled
configurations (three dispatch slots, seven completions, seven-entry queue;
IEU also has four integer ports with system port 2):

```sh
python3 verify/scripts/rtl_synthesis_check.py --only execution \
  --output /tmp/execution-wrapper-native-final
```

This gate uses default frontend limits and fingerprints HDL, wrappers and
flow Makefiles. It is elaboration evidence, not mapped area or timing closure;
old stimulus-wrapper PPA is not directly comparable to this new boundary.

LSU has a separate focused group covering RV32, RV64 and an expanded RV64
configuration (three dispatch slots, seven completions, IOQ 16, SQ 32).
Its wrapper preserves the committed-store interface and completion acceptance;
it does not add selective cancellation to the LSU or alter store draining.
Use `--check-structure` to additionally run ordinary `opt` followed by
`check -assert`, failing on remaining structural problems:

```sh
python3 verify/scripts/rtl_synthesis_check.py --only lsu --check-structure \
  --output /tmp/lsu-wrapper-structure-final
# The same stronger check is available for any individual synthesis top:
make -C lspd/syn structure-check MODULE=lsu BUILD_DIR=/tmp/lsu-structure
```

Reports distinguish elaboration-only from optimized structural checks.
Neither performs technology mapping or proves protocol/ISA correctness.

The mapped synthesis flow also fails closed on structural problems: ordinary
`opt; check -assert` runs before synthesis and undriven-value normalization,
and a second `check -assert` guards the final mapped netlist. A missing live
driver must not silently become a constant through `setundef -zero`.
Exercise the actual Tcl flow with valid and deliberately undriven fixtures:

```sh
make -C verify synthesis-driver-check
```

This check uses the installed Yosys/slang and Nangate45 library. It is a tool-flow
regression test, not evidence that every production configuration synthesizes.

STA runs a fatal `check_setup -verbose` constraint audit before timing reports.
Each run first writes `status incomplete` to invalidate an earlier successful
summary; only a completed run writes `status ok`. The summary collector rejects
explicitly incomplete reports even if old netlists/logs remain. Legacy summaries
without a status field remain readable, but are not retroactively certified by
the new audit. Exercise real constrained/unconstrained-clock fixtures with:

```sh
make -C verify sta-constraint-check
```

Constraint coverage is not timing closure: negative slack remains a reported
timing result, not an unconstrained-path error.

Timing schema 2 reports global WNS/TNS and, when a register-to-register path
exists, `reg_setup_budget_ns` (target period minus register-only setup slack).
It no longer estimates `period_min_ns`/`fmax_mhz` from global slack: IO delays
can dominate that slack. The summary table shows register setup budget rather
than Fmax; legacy reports without a register-only metric show N/A. The metric
still depends on the clocks, exceptions, library and interconnect model and is
not a full-design frequency guarantee.

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

Cache data arrays use `SRAM_MODE=macro` by default. This mode preserves
supported L1I, L1D, and L2 arrays as explicit SRAM instances and automatically
generates the abstract Verilog and Liberty models required by synthesis and
STA. Unsupported array shapes fail synthesis instead of silently expanding to
registers. Use `SRAM_MODE=flops` to reproduce the logic-mapped baseline:

```sh
make -C lspd ppa MODULE=l1d RAPT_CONFIG=small PDK=nangate45 SRAM_MODE=flops
```

The generated `sram_model.txt` identifies which mode and model platform were
used for an individual result. `SRAM_PLATFORM=sky130` currently selects the
abstract model shape set; it does not imply that the selected standard-cell
PDK contains characterized Sky130 SRAM macros.

Report generation is separate from synthesis and STA so existing build results
can be summarized without rerunning evaluation. Generate one PDK report with:

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

The table contains mapped cell count and area, WNS/TNS, estimated minimum
period and Fmax, and total vectorless power for every requested module. Missing
build results are shown as `missing` with `N/A` metrics.

`profile_summary.md` records synthesis, STA, and total wall time, CPU time, peak
RSS, and build output size for each module. It also reports the number of RTL
files and nonblank RTL lines retained in the synthesized hierarchy as
reproducible proxies for development complexity. Run
`make -C lspd profile-summary` to regenerate it from existing profile files
without rerunning synthesis.

## Interpretation

This is a pre-layout comparison flow. STA uses ideal clocks, a default input and
output delay of 20% of the requested period, a 5 fF output load, and uniform
vectorless switching activity. Override these with `IO_DELAY_FRAC` and
`OUTPUT_LOAD_FF` when needed.

L1I, L1D, and enabled L2 data arrays are represented by abstract SRAM macros in
the default mode so register and mux expansion does not dominate area and
timing. The bundled placeholder area and timing values are not characterized
for ASAP7, NanGate45, or SKY130 HD and must not be treated as SRAM signoff PPA.
They are intended for architecture-level comparisons until foundry- and
compiler-characterized macro views are supplied. L2 is a passthrough unless
the selected RTL configuration enables `RAPT_L2_EN`.

The three PDKs use different architectures and corners. Compare variants within
one PDK directly; use cross-PDK numbers as directional estimates only.

## Physical design

`make -C lspd pnr` automatically builds the matching `lspd/syn` netlist with
`SRAM_MODE=flops`, then runs floorplanning and PDN generation, placement, CTS,
global and detailed routing, parasitic extraction, and post-route reporting.
Physical SRAM macro placement is not enabled yet, so cache-heavy blocks remain
a logic baseline in this flow.

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

`pd-summary` writes `lspd/pnr/build/<config>/<pdk>/pnr_summary.md` with
post-route instance count, cell and die area, utilization, WNS/TNS, estimated
Fmax, vectorless power, detailed-route violations, runtime, peak memory, and
visualization status.
Use `CORE_UTILIZATION`, `CORE_ASPECT_RATIO`, and `PLACE_DENSITY` to evaluate
floorplan tradeoffs. `PNR_MODE=fast` selects the repository's reduced-runtime
OpenROAD flow for iteration; the default is `standard`. The `viz` target uses
the repository's KLayout batch renderer and Nangate45 layer properties.
