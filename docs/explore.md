---
layout: explore
title: Explorer
permalink: /explore.html
description: Interactive Raptor core, memory, and platform architecture with RTL source links
---

# Inside the core

Follow an instruction. Inspect the hardware behind each step.

Default preset · RV32 / RV64 · scalar out-of-order core

The default RV64 configuration supports [RVA22S64](./README.md#rva22s64-support).
For pipeline contracts and configuration tables, read the
[architecture manual](./uarch.md).

## Architecture views

**Core pipeline** expands fetch, decode,
rename, dispatch, execution, and retirement. **Memory & platform** expands
translation, caches, interconnect, and devices. Each view groups the other part
of the system into a linked overview block. Open that block to switch detail
views without changing the model cycle.

Blocks group related RTL functions. Capacities use the default preset; RV32 and
RV64 share this organization. A dashed block marks an optional cache stage.
Connections show instruction / operand flow, completion, memory paths, address
translation, and optional control paths.

Both views cover the whole system. Open the overview block to switch
detail views without changing the model cycle. Functional connections, not cycle timing or
a physical floorplan; response and wakeup paths are simplified.

## Inspect a block

Select a block to see its role, default configuration, RTL source links, and current
instruction listing, and to emphasize its direct connections. Use Tab and Enter,
or the block selector, for keyboard navigation. Click an overview block's Open
action, press Enter or Space, or choose it in the selector to switch views.
Playback continues at the same cycle.

Scroll diagram ↔ · select a block for details

In the browser, select a zoom level, toggle control paths, or use Save SVG.
Interactive diagram requires JavaScript. The linked
architecture manual provides the hardware descriptions without it.

## Occupancy playback and animation scope

Illustrative CoreMark queue model, not an RTL trace or
performance measurement. Bars show modeled occupancy; dots represent instructions.
Play, step backward or forward, and Restart control the model.

- Branches do not redirect. Translation, cache contents, replay, register allocation,
  and store draining are not simulated. Their blocks remain available for inspection.
- Dots preview up to five instructions per block; counts include all instructions.
  Select a block for its current instruction listing.
- One instruction can occupy the ROB and an execution unit at the same time.
  Counts belong to each structure and should not be added together.

## Diagram references

Grouping and visual hierarchy draw on public diagrams, including the MDS Skylake
overview. Hardware contents are Raptor's own.

- [MDS / Skylake diagram](https://mdsattacks.com/diagram.html): compact whole-core layout,
  shared paths, and block inspection.
- [Intel Golden Cove](https://cdrdv2-public.intel.com/779559/355308-Software-Optimization-Manual-047-Changes-Doc.pdf):
  pipeline hierarchy.
- [AMD Zen 5](https://www.amd.com/content/dam/amd/en/documents/epyc-business-docs/white-papers/amd-epyc-smt-technology-brief.pdf):
  parallel execution domains.
- [Arm Cortex-X4](https://documentation-service.arm.com/static/6585aec6b52744113be620e8):
  memory and translation boundaries.
- [Apple M4](https://www.apple.com/newsroom/2024/05/apple-introduces-m4-chip/): public SoC block grouping.
