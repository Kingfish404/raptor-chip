# Raptor — RISC-V Processor Core

[![AM CPU ISA tests](https://github.com/Kingfish404/raptor-chip/actions/workflows/am-test-cpu.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/am-test-cpu.yaml)
[![AM benchmarks & STA](https://github.com/Kingfish404/raptor-chip/actions/workflows/am-benchmark.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/am-benchmark.yaml)
[![App tests (pk)](https://github.com/Kingfish404/raptor-chip/actions/workflows/app-pk.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/app-pk.yaml)
[![Linux boot](https://github.com/Kingfish404/raptor-chip/actions/workflows/linux-boot.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/linux-boot.yaml)

Raptor is a dual-issue, out-of-order RISC-V core with register renaming, a
reorder buffer, reservation stations, branch prediction, and Sv32 virtual
memory. The RTL is written in hand-written SystemVerilog; Chisel is used only
to generate instruction decoders.

The repository also bundles the NEMU software ISS (used as a difftest
reference), a Verilator-based simulator (NPC), an AbstractMachine runtime,
Linux kernel build scripts, and FPGA integration (Gowin Tang Nano 20K, LiteX).

Repository: <https://github.com/Kingfish404/raptor-chip>

## Core Summary

| Item                 | Value                                                                |
| -------------------- | -------------------------------------------------------------------- |
| ISA                  | `rv32/64imac_zicntr_zicond_zicsr_zifencei_zimop_zcb_zba_zbb_zbc_zbs` |
| Privilege modes      | M, S, U                                                              |
| MMU                  | Sv32 (RV32) / Bare (RV64)                                            |
| Interrupts           | CLINT (`mtime`, `mtimecmp`, `msip`)                                  |
| Issue / commit width | 2 / 2                                                                |
| ROB / RS / IOQ / SQ  | 16 / 8 / 8 / 8                                                       |
| L1I / L1D            | 4-word lines; L1D 2-way, banked SRAM                                 |
| Bus                  | AXI4, XLEN-bit data/addr, 4-bit ID                                   |
| Verification         | RVFI-compliant; difftest against NEMU                                |

See [Microarchitecture](./uarch.md) for the complete pipeline description.

## Performance (Verilator, RV32EM, bare-metal)

See [PROFILE](./PROFILE.md) and [Performance Iterations](./perf-iterations.md)
for detailed numbers and the change history.

## Verification

- Difftest — every retired instruction compared against NEMU.
- Architectural tests — 35 / 35 `cpu-tests` pass on RV32 and RV64.
- [RISCOF](https://github.com/riscv-software-src/riscof) running
  [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test); RVFI trace.
- Benchmarks: CoreMark, MicroBench, Embench-IoT, under both bare-metal and difftest.
- System software: nanos-lite, riscv-pk, OpenSBI + Linux boot
  (see [Linux Kernel Boot](./linux_kernel.md)).

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
├── rtl_scala/            Chisel (decoder generation only)
├── rtl_sv/               hand-written SystemVerilog RTL
│   ├── rapt.sv           top-level core
│   ├── rapt_pkg.sv       shared types (uop_t, rob_entry_t, ...)
│   ├── frontend/         IFU, IDU, BPU, CSR
│   ├── backend/          RNU, PRF, ROU, EXU, CMU
│   ├── memory/           LSU, L1I/L1D, TLB, PTW, AXI4 bus, CLINT
│   ├── include/          config, interfaces, DPI-C
│   └── generated/        Chisel-generated decoders
├── nemu/                 NEMU reference ISS
├── nsim/                 NPC Verilator simulator
├── abstract-machine/     AM runtime (nanos-lite, navy-apps)
├── linux/                Linux kernel build scripts
├── fpga/                 FPGA integration (Gowin Tang Nano 20K, LiteX)
└── docs/                 documentation (this directory)
```


The project is licensed under the [Apache License 2.0](../LICENSE). Third-party
components retain their original licenses; see [NOTICE](../NOTICE).
