# Raptor — RISC-V Processor Core

[![Benchmark](https://github.com/Kingfish404/raptor-chip/actions/workflows/benchmark.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/benchmark.yaml)
[![App](https://github.com/Kingfish404/raptor-chip/actions/workflows/app.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/app.yaml)
[![STA](https://github.com/Kingfish404/raptor-chip/actions/workflows/sta.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/sta.yaml)

Raptor is a dual-issue, out-of-order RISC-V core with register renaming, a
reorder buffer, reservation stations, branch prediction, and Sv32/Sv39 virtual
memory support for RV32/RV64. The RTL is written in hand-written SystemVerilog;
Chisel is used only to generate instruction decoders.

The repository also bundles the NEMU software ISS (used as a difftest
reference), a Verilator-based simulator (NPC), an AbstractMachine runtime,
Linux kernel build scripts, and FPGA integration (Gowin Tang boards and Xilinx
KU15P through LiteX).

Repository: <https://github.com/Kingfish404/raptor-chip>

## Core Summary

| Item                 | Value                                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------------- |
| ISA                  | `rv32/64imafdc_zicbom_zicbop_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zimop_zca_zcb_zcmop_zba_zbb_zbc_zbs` |
| Privilege modes      | M, S, U                                                                                                 |
| MMU                  | Sv32 (RV32) / Sv39 PTW path (RV64 xv6 bring-up) / Bare                                                  |
| Interrupts           | CLINT (`mtime`, `mtimecmp`, `msip`) + PLIC (31 sources, M/S contexts)                                   |
| Issue / commit width | 2 / 2                                                                                                   |
| ROB / RS / IOQ / SQ  | 64 / 8 / 8 / 16                                                                                         |
| Register state       | 128-entry renamed integer PRF + separate 32 x 64-bit architectural FPR bank                            |
| BPU                  | TAGE direction predictor + 2-way BTB + 4-entry RSB                                                      |
| L1I / L1D            | 4 KiB 2-way L1I / 2 KiB 2-way write-through L1D, banked SRAM, 64 B lines                                |
| L2                   | Optional 16 KiB direct-mapped unified cache; default config disables it as passthrough                  |
| Bus                  | AXI4, XLEN-bit data/addr, 4-bit ID; up to 8 reads, one single-beat write                                |
| Debug                | RISC-V Debug Module / JTAG DTM bring-up ports at cluster top                                            |
| Verification         | Difftest against NEMU; RVFI/riscv-formal; SVA                                                           |

See [Microarchitecture](./uarch.md) for the complete pipeline description.

## Performance (Verilator, RV32EM, bare-metal)

See [PROFILE](./PROFILE.md) and [Performance Iterations](./perf-iterations.md)
for detailed numbers and the change history.

## Verification

- Difftest — retired instructions can be compared against NEMU, including the
  full-core directed/differential RV32/RV64 F/D test suite under `app/tests/fp`.
- Architectural tests — 35 / 35 `cpu-tests` pass on RV32 and RV64.
- [RISCOF](https://github.com/riscv-software-src/riscof) running
  [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test):
  pass against `sail_c_simulator` on both the RTL DUT
  (`make verify-riscof-classic`) and NEMU (`make verify-riscof-classic-nemu`).
  The classic profile declares RV32 I/M/A/F/D/C/S/U plus the listed Z
  extensions. The retained UDB profile is narrower than the current RTL, and
  the riscv-dv target is an RV32 I/M/C, M-mode, Bare smoke configuration.
- Benchmarks: CoreMark, MicroBench, Embench-IoT, and RLLMBench/LLM-style fixed-point workloads under NPC/NEMU and selected native/LiteX paths.
- System software: nanos-lite, riscv-pk, OpenSBI + Linux boot
  (see [Linux Kernel Boot](./linux_kernel.md)); upstream xv6-riscv and egos-2000 CLI smoke paths are available through `app/tinyos`.

## Documentation

- [Quick Start](./getting-started.md) — build and simulate.
- [Microarchitecture](./uarch.md) — pipeline, modules, interfaces, ISA breakdown.
- [Profile](./PROFILE.md) — benchmarks, cycle-stall breakdown, PPA.
- [Performance Iterations](./perf-iterations.md) — IPC history per commit.
- [Ecosystem](./ecosystem.md) — simulators, SoC memory maps, FPGA, tools.
- [Linux Kernel Boot](./linux_kernel.md) — OpenSBI + Linux on NEMU / NPC.
- [Reference](./REFERENCE.md) — AXI4, PPA references.

## Repository Layout

```
raptor-chip/
├── Makefile              top-level driver
├── env.sh                environment variables (auto-sourced by Makefile)
├── hdl/                   hand-written SystemVerilog RTL
│   ├── chisel/            Chisel decoder generator
│   ├── rapt.sv           cluster-level top (core + CLINT + PLIC + router + debug)
│   ├── rapt_core.sv      single-hart CPU body
│   ├── rapt_pkg.sv       shared types (uop_t, rob_entry_t, ...)
│   ├── frontend/         IFU, IDU, BPU, CSR
│   ├── backend/          RNU, PRF, ROU, EXU, CMU
│   ├── memory/           L1I/L1D, optional L2, TLB, PTW, AXI4 bus
│   ├── perip/            CLINT, PLIC, debug module, JTAG DTM, DPI wrappers
│   ├── include/          config, interfaces, DPI-C
│   └── generated/        Chisel-generated decoders
├── nemu/                 NEMU reference ISS
├── sim/                  NPC Verilator simulator
├── abstract-machine/     AM runtime (nanos-lite, navy-apps)
├── linux/                Linux kernel build scripts
├── fpga/                 FPGA integration (Gowin Tang Nano 20K, LiteX)
└── docs/                 documentation (this directory)
```


The project is licensed under the [Apache License 2.0](../LICENSE). Third-party
components retain their original licenses; see [NOTICE](../NOTICE).
