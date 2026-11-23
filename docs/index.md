---
layout: home
title: Raptor
description: Superscalar RV32/RV64 RISC-V core with V 1.0 and the RV64 supervisor profile
---

# A RISC-V core. Room to explore.

Open hardware · RV32 / RV64

A configurable, superscalar out-of-order processor with TAGE prediction,
scalar floating point, [V 1.0](./vpu.md) and Sv32/Sv39 virtual memory.
The default RV64 preset enables the
[RVA23U64 user profile](./README.md#rva23u64-support) and
[RVA23S64 supervisor profile](./README.md#rva23s64-support).

SystemVerilog RTL · Verilator + NEMU difftest · FPGA and LiteX support

[Read the architecture](./uarch.md).

## From source to simulation

From the repository root, after cloning:

```sh
# Prepare the RTL workspace
make setup-rtl

# RV32 · batch mode · no waveform
make run-rv32 ARGS="-b -n"
```

See [Getting started](./getting-started.md) for prerequisites and RV64 commands.
The [default configuration](./uarch.md#default-configuration) documents the RTL defaults.

## Build. Understand. Integrate.

- [Core overview](./README.md): Capabilities, default configuration, and verification scope.
- [Quick start](./getting-started.md): Build RV32 or RV64 and run your first program.
- [Microarchitecture](./uarch.md): Follow fetch, rename, execution, and precise retirement.
- [Linux boot](./linux_kernel.md): OpenSBI, FPGA netboot, and the RV64 KVM probe.
- [Platform integration ↗](./ecosystem.md): FPGA boards, memory maps, and the software stack.
- [Vector extension](./vpu.md): Integrated V 1.0 execution, precise memory faults and verification.
- [Chip top and off-chip link](./chip.md): Chip hierarchy and board-side octal link.
- [Performance evaluation](./performance.md): Current RTL bare-metal, Linux sim, FPGA, and SPEC 2017/2026 results.
- [Performance history](./perf-iterations.md): Earlier measurements tied to their source revisions.
- [References](./REFERENCE.md): AXI protocol diagrams and public PPA resources.

## Follow the instruction.

Default preset · RV32 / RV64 · V 1.0

The homepage and explorer share an interactive diagram.
[Open full explorer →](./explore.md)

**Core pipeline** expands the execution pipeline; **Memory & platform** expands
translation, caches, interconnect, and devices.

Select a block to see its role, default configuration, RTL sources, and current
instructions. Use Tab and Enter, or the block selector, for keyboard navigation.
Both views cover the whole system. Open the overview block to switch
detail views without changing the model cycle. Functional connections, not cycle timing or
a physical floorplan; response and wakeup paths are simplified.
A dashed block marks an optional cache stage.
Connection types include instruction / operand, completion, memory path, address
translation, and optional control paths. The browser offers zoom and Save SVG controls.

Scroll diagram ↔ · select a block for details

Illustrative CoreMark queue model, not an RTL trace or
performance measurement. Bars show modeled occupancy; dots represent instructions.
Playback controls step backward or forward, play, and restart the model.
Playback follows the scalar CoreMark instruction listing in order. Inspect the
VPU, caches and translation paths in the diagram. Dots preview up to five instructions
per block; counts include all instructions. One instruction can occupy the ROB and
an execution unit at the same time, so structure counts should not be added together.

Interactive diagram requires JavaScript.
[Read the architecture manual.](./uarch.md) It provides pipeline and memory contracts as text. See the
[explorer guide](./explore.md) for animation scope and diagram references.

## Find a Makefile command

Makefile + RTL reference

Look up commands here, then run them in your local checkout.
Use `make help` from the repository root for the command list, or follow the
[simulation and verification guide](./getting-started.md).
