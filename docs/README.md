---
title: Overview
permalink: /overview.html
---

# Raptor - RISC-V Processor Core

[![Benchmark](https://github.com/Kingfish404/raptor-chip/actions/workflows/benchmark.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/benchmark.yaml) [![App](https://github.com/Kingfish404/raptor-chip/actions/workflows/app.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/app.yaml) [![STA](https://github.com/Kingfish404/raptor-chip/actions/workflows/sta.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/sta.yaml)

The published homepage is an interactive product surface: a 2D pipeline block diagram extracted from the SystemVerilog tree, plus a documentation shell whose `make` commands come from the repository Makefile. This page is the written overview.

Raptor is a parameterized superscalar, out-of-order RISC-V core with register renaming, a reorder buffer, reservation stations, branch prediction, and Sv32/Sv39 virtual memory support for RV32/RV64.

The repository also bundles the NEMU software ISS (used as a difftest reference), a Verilator-based simulator (NPC), an AbstractMachine runtime, Linux kernel build scripts, and native FPGA integration for MLK-CU08-KU15P and RK-XCKU5P-F, plus LiteX SoCs.

Repository: <https://github.com/Kingfish404/raptor-chip>

## Core Summary

| Item                 | Value                                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------------- |
| ISA                  | `rv32/64imafdc_zba_zbb_zbc_zbs_zfhmin_zicbom_zicbop_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zimop_zca_zcb_zcmop` |
| RV64 extras          | Zkt and Svpbmt on default RV64; Svinval decode is shared by RV32/RV64                                                |
| Privilege modes      | M, S, U                                                                                                 |
| MMU                  | Sv32 (RV32) / Sv39 (RV64) / Bare                                                                        |
| PMP                  | 8 usable entries (TOR / NA4 / NAPOT); 16 CSR slots, upper eight read-only zero                          |
| Interrupts           | CLINT (`mtime`, `mtimecmp`, `msip`) + PLIC (31 sources, M/S contexts)                                   |
| Ordered widths       | Decode 2 / Rename 2 / Dispatch 2 / Commit 2 by default; independently parameterized                    |
| Integer execution    | 2 physical integer issue/ALU ports by default; CSR/system on port 0                                     |
| Queues               | ROB 32, ALQ 8, BRQ 8, MDQ 4, FPQ 8, IOQ 8, unified SQ 16                                               |
| Register state       | 64-entry integer PRF (including 32 architectural mappings); ROB-backed FP results + 32 x 64-bit committed FPR bank |
| Writeback            | 6 completion ports (`N+4`: 2 integer + branch + memory + MUL/DIV + FP), registered before ROB writeback  |
| BPU                  | TAGE direction predictor (1024 bimodal + 3 x 1024 tagged) + 2-way BTB (128) + 16-entry RAS               |
| L1I / L1D            | 16 KiB 4-way each (64 sets x 64 B x 4), banked SRAM; L1D write-back with 4 MSHRs and 2 writeback buffers   |
| TLB                  | ITLB 16, DTLB 16 (load/store replicas); shared 256-entry direct-mapped L2 TLB; Sv32/Sv39 PTWs            |
| L2                   | Default passthrough; `default-l2` enables a 512 KiB, eight-way inclusive L2 with write-back              |
| Bus                  | AXI4, XLEN-bit data/addr, 4-bit ID; up to 8 reads; one B-synchronous write with the default write-back L1D (write-through builds without L2 may post up to 4); stores single-beat, CBO.ZERO multi-beat |
| Debug                | RISC-V Debug Module / JTAG DTM bring-up ports at cluster top                                            |
| Verification         | Difftest against NEMU; RVFI/riscv-formal; SVA                                                           |

See [Microarchitecture](./uarch.md) for the complete pipeline description.

## Performance

See [Getting Started](./getting-started.md) for RV32/RV64 benchmark commands. Compare measurements using the same source revision, configuration, binary, and memory model.

## Verification

- Difftest - retired instructions can be compared against NEMU, including the full-core directed/differential RV32/RV64 F/D test suite under `app/tests/fp`.
- Architectural tests - `cpu-tests` supplies RV32/RV64 smoke coverage. Run the tests against the selected source revision and configuration.
- [RISCOF](https://github.com/riscv-software-src/riscof) running [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test): classic test entry points compare signatures with Sail for the RTL DUT (`make verify-riscof-classic`) and NEMU (`make verify-riscof-classic-nemu`). The classic profile declares RV32 I/M/A/F/D/C/S/U plus the listed Z extensions. ACT4 has separate RV32GC, RV64GC M-mode and RV64 supervisor configurations; see [verification](../verify/README.md). The riscv-dv target is an RV32 I/M/C, M-mode, Bare smoke configuration.
- Benchmarks: CoreMark, MicroBench, Embench-IoT, and RLLMBench/LLM-style fixed-point workloads under NPC/NEMU and selected native/LiteX paths.
- System software: nanos-lite, riscv-pk, OpenSBI + Linux boot (see [Linux Kernel Boot](./linux_kernel.md)); upstream xv6-riscv and egos-2000 CLI smoke paths are available through `app/tinyos`.

## Documentation

- [Quick Start](./getting-started.md) - build and simulate.
- [Microarchitecture](./uarch.md) - pipeline, modules, interfaces, ISA breakdown.
- [Ecosystem](./ecosystem.md) - simulators, SoC memory maps, FPGA, tools.
- [Linux Kernel Boot](./linux_kernel.md) - OpenSBI + Linux on NEMU / NPC.
- [Standalone VPU](./vpu.md) - RVV 1.0 component delivery; not yet integrated into the scalar core.
- [Reference](./REFERENCE.md) - AXI4, PPA references.

## Repository Layout

```
raptor-chip/
|-- Makefile              top-level driver
|-- env.sh                environment variables for direct shell workflows
|-- hdl/                   SystemVerilog RTL
|   |-- chisel/            Chisel decoder generator
|   |-- rapt.sv           cluster-level top (core + CLINT + PLIC + router + debug)
|   |-- rapt_core.sv      single-hart CPU body
|   |-- rapt_pkg.sv       core configuration and shared types
|   |-- frontend/         IFU, FQU, IDU, RNU, BPU, CSR
|   |-- backend/          PRF, ROU, DPU, IEU, FEU, LSU, CMU; standalone VPU (vpu/)
|   |-- memory/           L1I/L1D, optional L2, TLB/L2 TLB, PTW, PMP, AXI4 bus
|   |-- common/           stream queue, issue/rank selectors
|   |-- sram/             1RW/2RW SRAM wrappers (behavioral or macro)
|   |-- configs/          microarchitecture presets (rapt_config.svh)
|   |-- perip/            CLINT, PLIC, debug module, JTAG DTM, DPI wrappers
|   |-- include/          type macros, interfaces, DPI-C
|   `-- generated/        Chisel-generated decoders
|-- nemu/                 NEMU reference ISS
|-- sim/                  NPC Verilator simulator
|-- lspd/                 synthesis/PPA flow and non-product HDL wrappers
|-- abstract-machine/     AM runtime (nanos-lite, navy-apps)
|-- app/                  bare-metal tests, benchmarks, riscv-pk apps
|-- verify/               testbenches, formal, RISCOF, fuzzing
|-- linux/                Linux kernel build scripts
|-- fpga/                 FPGA integration (LiteX boards, Gowin Tang Nano 20K, OOC partitions)
`-- docs/                 documentation (this directory)
```


The project is licensed under the [Apache License 2.0](../LICENSE). Third-party components retain their original licenses; see [NOTICE](../NOTICE).
