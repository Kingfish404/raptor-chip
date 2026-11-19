---
title: Overview
permalink: /overview.html
---

# Raptor at a glance

Raptor is a configurable RV32/RV64 superscalar, out-of-order RISC-V processor.
It combines register renaming, precise in-order retirement, scalar floating
point, and virtual memory with simulation, Linux boot, and FPGA integration flows.
The default RV64 configuration supports **RVA22S64**.

[Get started](./getting-started.md) · [Read the microarchitecture](./uarch.md) · [Explore the pipeline](./explore.md)

## Default core

Values below describe `rtl/configs/default/rapt_config.svh` and the integrated
`rapt_core`. Other presets and build overrides can differ.

| Block | Default configuration |
| --- | --- |
| Pipeline | Decode / rename / dispatch / commit: 2 each; 2 integer issue ports |
| In-flight state | 32-entry ROB, 64 integer physical registers, 16 branch checkpoints |
| Execution queues | ALQ 8, BRQ 8, MDQ 4, FPQ 8, IOQ 8; unified store queue 16 |
| Floating point | ROB-backed speculative results; 32 × 64-bit committed FPR bank |
| Vector | V 1.0, VLEN=128, ELEN=64; serialized execution with precise ROB ownership |
| Completion | 6 endpoints, all registered before ROB writeback |
| Prediction | TAGE: 1024 bimodal + 3 × 1024 tagged; 128-entry two-way BTB; RAS 16 |
| L1 caches | 16 KiB each, four-way, 64-byte lines; L1D write-back, 4 MSHRs, 2 writeback buffers |
| Translation | ITLB 16, fully associative; DTLB 64, two-way, replicated for load/store; shared L2 TLB 256 |
| Core boundary | `l2_client_if` to the always-present cluster-level `rapt_l2_subsystem` |
| L2 cache | Disabled; `default-l2` enables 512 KiB, eight-way inclusive write-back |
| Addresses | Physical: 32 bits by default; RV64 allows 32–38. RV64 stored PC: 40 bits |
| Platform | M/S/U; Sv32 (RV32), Sv39 (RV64), Bare; 8 usable PMP entries |
| Interrupts / debug | CLINT; PLIC with 31 sources and M/S contexts; Debug Module / JTAG DTM bring-up path |
| Bus | Cluster AXI4, XLEN-bit data/address containers, 4-bit ID, up to 8 reads; buffered writebacks wait for B |

See [pipeline contracts and configuration](./uarch.md) for forwarding, recovery,
cache policy, and preset differences.

## ISA scope

Both XLEN modes implement **IMAFDC**, scalar **Zfhmin**, bit manipulation
**Zba/Zbb/Zbc/Zbs**, and the extensions below. The `default`, `default-*` and
`large` presets also enable **V 1.0** by default.

- **System and hints:** Zicsr, Zifencei, Zicntr, Zihpm, Zicond, Zihintntl, Zihintpause, Zimop.
- **Cache management:** Zicbom, Zicbop, Zicboz.
- **Compressed:** Zca, Zcb, Zcmop, alongside C's F/D memory forms.
- **Execution timing:** Zkt on the default RV64 configuration.
- **Supervisor:** Svinval in both modes and Svpbmt in the default RV64 configuration.

Page-table A/D bits use software management (Svade). Committed Svinval and
SFENCE.VMA select translations by address and ASID by default, preserving unrelated
entries; `RAPT_SFENCE_SELECTIVE=0` restores full invalidation. The
[vector extension](./vpu.md) uses the core's ROB, CSR, MMU and cache contracts.
`RAPT_NO_VPU` selects a scalar build without MISA.V.
Decoder sources live in [`tools/decodegen/`](https://github.com/Kingfish404/raptor-chip/tree/master/tools/decodegen).

## RVA23U64 support

The RV64 `default`, `default-*` and `large` presets enable the mandatory
[RVA23U64 user profile](https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html).
The additions include Zvbb, Zvfhmin, Zvkt, Zfa, Zawrs, and Ssnpm for the
Supm execution environment. `RAPT_NO_RVA23U64` selects the baseline V configuration.

The VPU accepts misaligned vector elements in main memory, including
cross-page accesses. It checks protection and device attributes before split stores.
Zawrs uses the cache's LR reservation and can wake on an external write or a
pending interrupt. The bounded wait lasts up to 1,024 core cycles.

Ssnpm provides U-mode PMLEN values of 0, 7 and 16 via `senvcfg.PMM`.
The simulator and FPGA device trees advertise `ssnpm` so a Linux kernel with
`CONFIG_RISCV_ISA_SUPM` can expose the tagged-address `prctl` interface.
The Linux boot loaders enable supervisor cache maintenance, including `cbo.zero`.
See the [verification commands](../verification/README.md#architectural-programs-and-fuzzing).

## RVA22S64 support

The `default` preset built with `RAPT_RV64` supports **RVA22S64**, the
64-bit supervisor application profile in the
[RISC-V RVA22 specification](https://docs.riscv.org/reference/rva20-rvi20-rva22/v1.0/rva22.html).
This scope includes its mandatory user-mode features and supervisor requirements.

| Area | Raptor support |
| --- | --- |
| Scalar ISA | RV64IMAFDC, Zfhmin, Zba/Zbb/Zbs, counters, CSR/fence instructions, PAUSE, and Zkt |
| Memory | 64-byte cache blocks; Zicbom/Zicbop/Zicboz; misaligned loads/stores in cacheable coherent main memory; LR/SC and AMOs |
| Supervisor | S/U execution, Sv39 and Bare, software-managed A/D bits (Svade), Svpbmt, and Svinval |

The profile statement applies to the default **RV64** configuration. RV32 and
modified presets have their own ISA scope. RVA22S64 treats V and H as optional
extensions. The default core supports V.

The [RV64 supervisor verification guide](https://github.com/Kingfish404/raptor-chip/blob/master/verification/riscof/raptor-rv64s/README.md)
and the current verification commands
record source mappings, tests, and evidence scopes. Support describes the RTL
implementation; formal profile certification is a separate verification claim.

## Run and verify

Start with [RV32/RV64 simulation](./getting-started.md), then follow
[Linux boot](./linux_kernel.md) or [FPGA integration](./ecosystem.md).
NEMU supplies the differential reference for the Verilator simulator.

The repository provides directed F/D tests, ISA signature checks, RISCOF/ACT4,
RVFI/formal, SVA, and differential fuzzing. Test profiles cover different
subsets; see the [verification guide](https://github.com/Kingfish404/raptor-chip/blob/master/verification/README.md)
for commands and prerequisites. A build target alone does not establish a passing
regression or board boot for a particular revision.

[Performance history](./perf-iterations.md) preserves earlier measurements.
Compare results only with matching revision, preset, XLEN, workload, memory
model, and constraints. The homepage and Explorer share one interactive architecture diagram and
illustrative queue-occupancy model. Animation cycles are not RTL measurements.
Both views cover the whole system: Core pipeline expands the execution pipeline,
while Memory & platform expands translation, caches, interconnect, and devices.
Each includes a linked overview of the other; opening it preserves the current
animation cycle and playback state.

## Source map

| Directory | Contents |
| --- | --- |
| `rtl/` | Synthesizable RTL, configuration presets, and generated decoders |
| `tools/` | Scala/Chisel instruction-decoder generator |
| `sim/`, `nemu/` | Verilator simulation and differential reference |
| `verification/` | Directed, formal, ISA, and fuzz verification |
| `app/`, `abstract-machine/` | Programs, benchmarks, and runtime |
| `synth/`, `layout/` | Module synthesis, STA, FPGA OOC estimates, and physical design |
| `fpga/`, `linux/` | Board integration and boot tooling |

[Source repository](https://github.com/Kingfish404/raptor-chip) ·
[Apache 2.0](https://github.com/Kingfish404/raptor-chip/blob/master/LICENSE) ·
[Third-party notices](https://github.com/Kingfish404/raptor-chip/blob/master/NOTICE)
