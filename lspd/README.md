# LSPD standalone module synthesis and physical design

This directory provides fast, independent synthesis and static timing analysis
for the major first-level modules instantiated by `hdl/rapt_core.sv`.

The flow uses Yosys with the slang SystemVerilog frontend and OpenSTA. It reuses
the open PDK data and mapping configuration under `third_party/yosys-opensta`
for ASAP7, NanGate45, and SKY130 HD.

The physical-design flow uses the mapped synthesis netlist as OpenROAD input.
It currently enables NanGate45, which has a complete local LEF, Liberty, RC,
and GDS platform setup in this repository. The interface is intentionally
parallel to the synthesis flow so more physical-design platforms can be added
without changing module-level usage.

## Quick start

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

Supported module names are `core`, `bpu`, `ifu`, `fqu`, `l1i`, `idu`, `rnu`,
`rou`, `prf`, `fpr`, `exu`, `cmu`, `csr`, `lsu`, `l1d`, `bus`, `axi`, and `l2`.
Use `make -C lspd list` to show the corresponding RTL top modules.

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
