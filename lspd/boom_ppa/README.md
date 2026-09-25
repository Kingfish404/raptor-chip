# BOOM PPA evaluation

This directory records the first reproducible comparison against the existing
LSPD flow. The reference run uses the current Chipyard-generated BOOM v4
`SmallBoomV4Config`, Nangate45, a 10 ns clock, 20% I/O delay, 5 fF output
load, and vectorless activity of 0.1/0.5, matching the Raptor STA settings.

The generated BOOM RTL was emitted with firtool 1.75. The primary tile run uses
firtool's sequential-memory replacement and an abstract memory Liberty model;
the retained `BoomCore` reference uses the no-replacement register form. The
comparable Raptor result is the existing default `rapt_core` run with
`SRAM_MODE=macro`; memory characterization remains approximate for BOOM.

## Full BOOM tile result

The primary comparison uses the generated `BoomTile`, which includes the BOOM
frontend, backend, and L1 memory hierarchy. BOOM SRAMs remain black-box cells
and are assigned an abstract area of 2.2 um²/bit, calibrated from the SRAM
macro Liberty files used by the current Raptor run. This lets the mapped
logic and macro area appear in the same Yosys area report.

| metric | Raptor `rapt_core` | BOOM v4 `BoomTile` |
|---|---:|---:|
| PDK / clock | Nangate45 / 100 MHz | Nangate45 / 100 MHz |
| area (um²) | 1,717,612.31 | 1,530,445.172 |
| WNS (ns) | +4.4114 | -132.8360 |
| TNS (ns) | 0.0 | -275,964.6237 |
| vectorless power (mW) | 114.405 | 68.638 |

On this abstract-memory model, BOOM is 89.1% of Raptor's area and 60.0% of
its vectorless power, but it fails the 100 MHz timing target by a wide margin.
The BOOM abstract SRAM model has no characterized timing arcs or leakage data,
so the timing and power figures should be treated as synthesis-level estimates,
not signoff values.

## Core-level result

| metric | Raptor `rapt_core` | BOOM v4 `BoomCore` |
|---|---:|---:|
| PDK / clock | Nangate45 / 100 MHz | Nangate45 / 100 MHz |
| area (um²) | 1,717,612.31 | 331,360.722 |
| WNS (ns) | +4.4114 | -92.4475 |
| TNS (ns) | 0.0 | -169,795.7971 |
| vectorless power (mW) | 114.405 | 39.373 |

The `BoomCore` result is retained as a microarchitectural reference, but is not
the primary chip comparison because it excludes the BOOM frontend and caches.

## Reproduction artifacts

- [gen_blackboxes.py](gen_blackboxes.py) generates declarations for firtool
  external SRAM wrappers when macro-based experiments are desired.
- [sta.tcl](sta.tcl) runs OpenSTA with the Raptor clock, I/O delay, reset-path,
  load, and vectorless-power conventions.

The BOOM source and generated RTL are intentionally kept outside tracked
source directories; regenerate them from the pinned Chipyard/BOOM workspace
before changing configuration or memory modeling.
