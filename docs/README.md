---
title: Overview
permalink: /overview.html
---

# Raptor at a glance

Raptor is a configurable RV32/RV64 superscalar, out-of-order RISC-V processor.
It combines register renaming, precise in-order retirement, scalar floating point,
V 1.0 and virtual memory. The default RV64 configuration enables the
[RVA23U64](#rva23u64-support) user profile and the
[RVA23S64](#rva23s64-support) supervisor profile with hardware guest translation.

[Get started](./getting-started.md) | [Read the microarchitecture](./uarch.md) | [Explore the pipeline](./explore.md)

## Default core

Values below describe `rtl/configs/default/rapt_config.svh` and the integrated
`rapt_core`. Other presets and build overrides can differ.

| Block | Default configuration |
| --- | --- |
| Pipeline | Decode / rename / dispatch / commit: 2 each; 2 integer issue ports |
| In-flight state | 32-entry ROB, 64 integer physical registers, 16 branch checkpoints |
| Execution queues | ALQ 8, BRQ 8, MDQ 4, FPQ 8, IOQ 8; unified store queue 16 |
| Floating point | F/D/Zfhmin and RV64 Zfa; ROB-backed speculative results; 32 x 64-bit committed FPRs |
| Vector | V 1.0, 32 registers, VLEN=128, ELEN=64; ROB-head authorization and precise restart |
| Completion | 6 registered endpoints; the VPU shares the integer system port |
| Prediction | TAGE: 1024 bimodal + 3 x 1024 tagged; 512-entry four-way BTB; 32-entry ITT; 32-entry loop predictor; RAS 16 |
| L1 caches | 16 KiB each, four-way, 64-byte lines; L1I hit-under-prefetch + 8-entry FDIP; L1D write-back, 8 MSHRs, 2 writeback buffers, degree-2 IP-stride prefetcher |
| Translation | ITLB 16, fully associative; DTLB 64, two-way, replicated for load/store; shared L2 TLB 512 (four-way) |
| Core boundary | `l2_client_if` to the always-present cluster-level `rapt_l2_subsystem` |
| L2 cache | Disabled; `default-l2` enables 512 KiB, eight-way inclusive write-back |
| Addresses | Physical: 32 bits by default; RV64 allows 32-38. RV64 stored PC: 40 bits |
| Platform | M/S/U, HS/VS/VU on RV64, Sv32/Bare or Sv39/Bare, Sv39x4 for guests, 8 usable PMP entries |
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
- **Supervisor:** Svade and Svinval in both modes. The default RV64 configuration
  provides Svpbmt and the [RVA23S64 facilities](#rva23s64-support).

The compressed FP memory forms include C.FLW/C.FSW and their stack-pointer
forms on RV32, and C.FLD/C.FSD and their stack-pointer forms on both XLENs.
Page-table A/D bits use software management (Svade). Committed Svinval and
SFENCE.VMA select translations by address and ASID by default, preserving unrelated
entries. `RAPT_SFENCE_SELECTIVE=0` selects full invalidation.

| RTL presets | RV32 | RV64 |
| --- | --- | --- |
| `default`, `default-*`, `large` | V 1.0 | RVA23U64 and RVA23S64, including V 1.0 and H |
| `small`, `small-cache`, `middle`, `middle-cache`, `formal` | Vector off by default | Vector off by default |
| `chip32-*` | Vector off by default | RV32-only presets |

The integrated [VPU](./vpu.md) uses VLEN=128 and ELEN=64 by default in both XLEN
modes, including vector FP64 on RV32. `RAPT_NO_VPU` selects a scalar build and
clears MISA.V. F/D are required when building with V. On RV64,
`RAPT_NO_RVA23S64` selects the user profile and baseline supervisor facilities.
`RAPT_NO_RVA23U64` selects baseline V and suppresses the automatic enablement
of both RVA23 profiles. `RAPT_NO_H_EXTENSION` is an individual H override.
Complete RVA23S64 requires H. Inspect the effective preset and overrides
with `sim/scripts/paddr_config.py` from the repository root.

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

The NPC ROM and native FPGA generators can derive ISA properties from the
selected RTL features, including `v` and `ssnpm`. A Linux kernel with
`CONFIG_RISCV_ISA_SUPM` can expose Supm through the tagged-address `prctl`
interface. See [Linux boot and user-mode validation](./linux_kernel.md#rva23u64-on-linux).

## RVA23S64 support

RV64 `default`, `default-*` and `large` enable the supervisor profile on top
of RVA23U64. The profile requires privileged architecture version 1.13 and
the Sha hypervisor facilities. [RISC-V RVA23S64 profile][rva23s64-spec]

| Area | RV64 supervisor implementation |
| --- | --- |
| Sha / H | HS/VS/VU execution, guest CSRs, delegated traps and virtual interrupt state |
| Guest translation | VS-stage Sv39 through `vsatp`, G-stage Sv39x4 through `hgatp`, and Bare at either stage |
| Guest access and fences | HLV/HLVX/HSV, HFENCE/HINVAL and guest page-fault metadata |
| Page tables | Svade, Svpbmt, Svinval, Svvptc, and Svnapot 64 KiB leaf mappings |
| Timers | Sstc with `stimecmp` and `vstimecmp`, including `htimedelta` in guest time |
| Counters | Sscofpmf overflow interrupt and privilege filtering for `mhpmcounter3` |
| State and addressing | Smstateen/Ssstateen, Ssu64xl, and Smnpm/Ssnpm pointer masking |

The shared L2 TLB serves host translations. Guest misses take the two-stage
walker and cache successful translations in the instruction or data L1 TLB.
See [guest translation and traps](./uarch.md#rv64-guest-translation-and-traps).

Use the directed suite for NPC/NEMU differential testing and the ACT4 suite
for architectural compliance tests. [RV64 supervisor verification](./getting-started.md#verify-the-rv64-supervisor-profile)

On Linux, the KVM smoke probe checks guest execution through `/dev/kvm`.
[Linux KVM smoke test](./linux_kernel.md#rva23s64-on-linux)

[rva23s64-spec]: https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html#_rva23s64_profile

## RVA22S64 support

The **RVA22S64** baseline is available on RV64 `default` with
`RAPT_NO_RVA23S64`. Its mandatory user and supervisor requirements
include the facilities below. [RISC-V RVA22 specification][rva22-spec]

| Area | Raptor support |
| --- | --- |
| Scalar ISA | RV64IMAFDC, Zfhmin, Zba/Zbb/Zbs, counters, CSR/fence instructions, PAUSE, and Zkt |
| Memory | 64-byte cache blocks; Zicbom/Zicbop/Zicboz; misaligned loads/stores in cacheable coherent main memory; LR/SC and AMOs |
| Supervisor | S/U execution, Sv39 and Bare, software-managed A/D bits (Svade), Svpbmt, and Svinval |

The RV64 supervisor verification guide records the mapping of baseline
requirements to RTL and tests. [RVA22S64 verification guide][rva22-verification]

[rva22-spec]: https://docs.riscv.org/reference/rva20-rvi20-rva22/v1.0/rva22.html
[rva22-verification]: https://github.com/Kingfish404/raptor-chip/blob/master/verification/riscof/raptor-rv64s/README.md

## Run and verify

Start with [RV32/RV64 simulation](./getting-started.md), then follow
[Linux boot](./linux_kernel.md) or [FPGA integration](./ecosystem.md).
NEMU supplies the differential reference for the Verilator simulator.

The repository provides directed F/D, RVV and RVA23 whole-core tests,
ISA signature checks, RISCOF/ACT4, RVFI/formal, SVA and differential fuzzing.
The [VPU verification guide](./vpu.md#verification-and-integration-scope)
lists the opcode catalog, Spike comparisons, device and fault scenarios.
See the [verification guide](https://github.com/Kingfish404/raptor-chip/blob/master/verification/README.md)
for commands and prerequisites. Record the revision and preset independently for
simulation, open-PDK STA, FPGA timing and physical board runs.

[Current performance evaluation](./performance.md) tracks the active RTL and
aligned gem5 O3 model using Top-Down Microarchitecture Analysis; [Performance
history](./perf-iterations.md) preserves earlier measurements.
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

[Source repository](https://github.com/Kingfish404/raptor-chip) |
[Apache 2.0](https://github.com/Kingfish404/raptor-chip/blob/master/LICENSE) |
[Third-party notices](https://github.com/Kingfish404/raptor-chip/blob/master/NOTICE)
