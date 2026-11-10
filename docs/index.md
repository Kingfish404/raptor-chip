---
layout: home
title: Raptor
description: Super-scalar, out-of-order RISC-V processor core
---

# A RISC-V core. Room to explore.

Open hardware · RV32 / RV64

A configurable, superscalar out-of-order processor with TAGE prediction,
scalar floating point, and Sv32/Sv39 virtual memory. The default RV64
configuration supports [RVA22S64](./README.md#rva22s64-support).

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
- [Linux boot](./linux_kernel.md): OpenSBI, payloads, and simulator or FPGA boot paths.
- [Platform integration ↗](./ecosystem.md): FPGA boards, memory maps, and the software stack.
- [Standalone VPU](./vpu.md): Vector components and contracts for future core integration.
- [Chip top and off-chip link](./chip.md): Chip hierarchy and board-side octal link.
- [Performance history](./perf-iterations.md): Measurements tied to their source revisions.
- [References](./REFERENCE.md): AXI protocol diagrams and public PPA resources.

## Follow the instruction.

Default preset · RV32 / RV64 · scalar out-of-order core

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
Branches do not redirect; translation,
cache contents, replay, register allocation, and store draining are not simulated.
Their blocks remain available for inspection. Dots preview up to five instructions
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
