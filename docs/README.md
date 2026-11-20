---
title: Overview
permalink: /overview.html
---

# Raptor at a glance

Raptor is a configurable RV32/RV64 superscalar, out-of-order RISC-V processor.
It combines register renaming, precise in-order retirement, scalar floating point,
V 1.0 and virtual memory. The default RV64 configuration supports
[RVA23U64](#rva23u64-support) in user mode and [RVA22S64](#rva22s64-support)
in supervisor mode.

[Get started](./getting-started.md) · [Read the microarchitecture](./uarch.md) · [Explore the pipeline](./explore.md)

## Default core

Values below describe `rtl/configs/default/rapt_config.svh` and the integrated
`rapt_core`. Other presets and build overrides can differ.

| Block | Default configuration |
| --- | --- |
| Pipeline | Decode / rename / dispatch / commit: 2 each; 2 integer issue ports |
| In-flight state | 32-entry ROB, 64 integer physical registers, 16 branch checkpoints |
| Execution queues | ALQ 8, BRQ 8, MDQ 4, FPQ 8, IOQ 8; unified store queue 16 |
| Floating point | F/D/Zfhmin and RV64 Zfa; ROB-backed speculative results; 32 × 64-bit committed FPRs |
| Vector | V 1.0, 32 registers, VLEN=128, ELEN=64; ROB-head authorization and precise restart |
| Completion | 6 registered endpoints; the VPU shares the integer system port |
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

With `default`, both XLEN modes implement **IMAFDC**, scalar **Zfhmin**,
bit manipulation **Zba/Zbb/Zbc/Zbs**, and the extensions below.

- **System and hints:** Zicsr, Zifencei, Zicntr, Zihpm, Zicond, Zihintntl, Zihintpause, Zimop.
- **Cache management:** Zicbom, Zicbop, Zicboz.
- **Compressed:** Zca, Zcb, Zcmop, alongside C's F/D memory forms.
- **Execution timing:** Zkt on the default RV64 configuration.
- **Supervisor:** Svinval in both modes and Svpbmt in the default RV64 configuration.

The compressed FP memory forms include C.FLW/C.FSW and their stack-pointer
forms on RV32, and C.FLD/C.FSD and their stack-pointer forms on both XLENs.
Page-table A/D bits use software management (Svade). Committed Svinval and
SFENCE.VMA select translations by address and ASID by default, preserving unrelated
entries. `RAPT_SFENCE_SELECTIVE=0` selects full invalidation.

| RTL presets | RV32 | RV64 |
| --- | --- | --- |
| `default`, `default-*`, `large` | V 1.0 | V 1.0 with RVA23U64 extensions |
| `small`, `small-cache`, `middle`, `middle-cache`, `formal` | Vector off by default | Vector off by default |
| `chip32-*` | Vector off by default | RV32-only presets |

The integrated [VPU](./vpu.md) uses VLEN=128 and ELEN=64 by default in both XLEN
modes, including vector FP64 on RV32. `RAPT_NO_VPU` selects a scalar build and
clears MISA.V. `RAPT_NO_RVA23U64` keeps baseline V on RV64. F/D are required
when building with V. To inspect the selected RTL's feature flags and vector
geometry, run `sim/scripts/paddr_config.py` from the repository root.

```sh
python3 sim/scripts/paddr_config.py --config rtl/configs/default --hdl rtl --features -- -DRAPT_RV64
```

Decoder sources live in [`tools/decodegen/`](https://github.com/Kingfish404/raptor-chip/tree/master/tools/decodegen).

## RVA23U64 support

The RV64 presets with V and F/D enabled supply the mandatory
[RVA23U64 user profile](https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html).
The profile builds on the shared scalar ISA, 64-byte cache blocks, and the
instruction fetch, atomic and misaligned-access requirements for coherent,
cacheable main memory.

| Area | RV64 profile implementation |
| --- | --- |
| Vector | V 1.0, Zvbb bit manipulation, Zvfhmin binary16 conversions, and Zvkt data-independent execution latency |
| Scalar arithmetic | Zfa FP immediates, min/max variants, quiet comparisons, rounding and modular conversion |
| Wait on reservation | Zawrs waits on the L1D LR reservation. The bounded wait is up to 1,024 core cycles. |
| Vector memory | Misaligned elements across pages in main memory, with checks before split stores |
| Pointer masking | Ssnpm lets the OS provide Supm with PMLEN=0, 7 or 16 in U-mode through `senvcfg.PMM`. |

Zawrs can wake on reservation invalidation or an interrupt. Split vector stores
also check device attributes for every byte before issuing writes.

The simulator and FPGA device trees advertise the effective extensions,
including `v` and `ssnpm` in the profile configuration. A Linux kernel with
`CONFIG_RISCV_ISA_SUPM` can expose Supm through the tagged-address `prctl`
interface. See [Linux boot and user-mode validation](./linux_kernel.md#rva23u64-on-linux).

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

The [RV64 supervisor verification guide](https://github.com/Kingfish404/raptor-chip/blob/master/verification/riscof/raptor-rv64s/README.md)
records the mapping of requirements to RTL and tests. Supervisor support is
currently at RVA22S64. The RVA23S64 target also requires hypervisor facilities
and privileged extensions such as Svnapot, Sstc and Sscofpmf.
[RVA23S64 requirements](https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html#_rva23s64_profile)

## Run and verify

Start with [RV32/RV64 simulation](./getting-started.md), then follow
[Linux boot](./linux_kernel.md) or [FPGA integration](./ecosystem.md).
NEMU supplies the differential reference for the Verilator simulator.

The repository provides directed F/D tests, RVV and RVA23U64 whole-core programs,
ISA signature checks, RISCOF/ACT4, RVFI/formal, SVA and differential fuzzing.
The [VPU verification guide](./vpu.md#verification-and-integration-scope)
lists the opcode catalog, Spike comparisons, device and fault scenarios.
See the [verification guide](https://github.com/Kingfish404/raptor-chip/blob/master/verification/README.md)
for commands and prerequisites. Record the revision and preset independently for
simulation, open-PDK STA, FPGA timing and physical board runs.

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
