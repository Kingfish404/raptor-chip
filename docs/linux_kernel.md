---
title: Linux Kernel Boot
---

# Linux Kernel Boot

Raptor boots Linux through an OpenSBI `fw_payload.bin` image:

```text
reset/MROM -> OpenSBI (M-mode) -> Linux (S-mode) -> init/userspace
```

The top-level Makefile is the preferred entry point. It downloads prebuilt
OpenSBI + Linux payloads from `Kingfish404/linux-build` and keeps NEMU/NPC
configuration in sync. By default it fetches `v6.18.51` assets from the
[`rv-v6.18.51` release](https://github.com/Kingfish404/linux-build/releases/tag/rv-v6.18.51).

## Quick Commands

```shell
# Download prebuilt RV32 + RV64 payloads
make linux-download

# RV32 Linux through NEMU / NPC
make linux-boot-nemu32 ARGS="-b -n"
make linux-boot-rv32 ARGS="-b -n"

# RV64 prebuilt payload and NPC paths
make linux-download-rv64
make linux-boot-rv64 ARGS="-b -n"
make linux-boot-nemu64-device

# Hard-float F/D Buildroot payloads (downloaded automatically)
make linux-boot-rv32gc
make linux-boot-rv64gc

# Complete RV32GC Buildroot payload used by the FPGA flow
make linux-download-rv32gc-fpga
```

Useful overrides:

```shell
make linux-boot-rv32 LINUX_BUILD_RELEASE=rv-v6.18.51 LINUX_BUILD_VERSION=v6.18.51 MAX_INST=100000000 ARGS="-b -n"
make linux-boot-rv32 LINUX_RV32_PAYLOAD=/path/to/fw_payload.bin ARGS="-b -n"
```

All NPC Linux boot targets use the matching RV32/RV64 NEMU difftest reference
by default, including the hard-float `rv32gc` and `rv64gc` targets. For focused
simulator diagnosis, pass `DIFF_REF_SO=` explicitly to disable comparison.

Linux uses [RVA22S64 supervisor facilities](./README.md#rva22s64-support),
including Sv39, Svade, Svpbmt and Svinval on RV64. OpenSBI provides the M-mode
execution environment. The RV64 application presets with V and F/D also expose
[RVA23U64](./README.md#rva23u64-support) to userspace.

## Supported Modes

| Mode                | RTL path                              | Status                                                |
| ------------------- | ------------------------------------- | ----------------------------------------------------- |
| RV32 Linux          | Sv32 PTW/TLB + PMP + CLINT/PLIC       | Primary NPC/NEMU flow                                 |
| RV64 Linux          | Sv39 PTW/TLB + NPC/NEMU helpers       | Build and boot targets are wired; current boot result should be checked per commit |
| RV32/RV64 hard-float | `*gc` DTB + Buildroot F/D payload    | NPC targets are wired; payloads are built separately  |
| RV32/RV64 FPGA | LiteX BIOS + MIG DDR4 + OpenSBI/Linux | Ethernet/TFTP netboot targets for KU15P and KU5P |
| RV64 xv6 smoke path | Sv39 PTW/TLB + Svade (software-managed A/D) | Available via `app/tinyos` helpers               |

See [linux/README.md](https://github.com/Kingfish404/raptor-chip/blob/master/linux/README.md) and [app/tinyos/README.md](https://github.com/Kingfish404/raptor-chip/blob/master/app/tinyos/README.md) for the lower-level payload and xv6/egos helpers.

## FPGA netboot

The LiteX BIOS fetches the boot bundle over Ethernet/TFTP. The UART console
is used for the BIOS command and boot logs.

```sh
make -C fpga/litex fpga-netboot-rv64-check RAPT_CONFIG=default
make -C fpga/litex fpga-netboot-rv64-build RAPT_CONFIG=default
```

Follow the netboot guide for host setup, serving the bundle, loading the
bitstream and entering the printed `netboot` command at the BIOS prompt.
Replace `rv64` with `rv32` for RV32. For KU5P use `FPGA_BOARD=rk_xcku5p_f`
throughout. KU15P CU08 defaults to `default`; KU5P RK defaults to `small`, so
select a vector-enabled preset explicitly for RVV on KU5P.
[LiteX netboot workflow](https://github.com/Kingfish404/raptor-chip/blob/master/fpga/litex/NETBOOT.md)

## RVA23U64 on Linux

Use an RV64 vector-enabled build with a matching DTB. Enable
`CONFIG_RISCV_ISA_V` for vector context management and
`CONFIG_RISCV_ISA_SUPM` for the tagged-address ABI. The board and simulator
device trees advertise `v`, the applicable vector extensions and `ssnpm`
from the selected hardware configuration.

```sh
make -C verification/subsystem rva23u64-smoke CONFIG=default
make -C verification/subsystem rva23u64-linux-probe BUILD_DIR=/tmp/raptor-rva23
```

The first command runs RTL tests. The second builds the static `rva23-check`
program. Include it as `/rva23-check` in the netboot initramfs and add
`rdinit=/rva23-check` to the kernel command line. The probe checks vector and
scalar instructions, cache-block operations and pointer masking in U-mode.
Successful completion prints `RVA23_LINUX_PASS`.

The November 19, 2026 integration run passed this probe on the native
MLK-CU08-KU15P target with RV64, `default`, DDR4 and a 50 MHz core. BIOS
loaded Linux over TFTP. For a new board run, record the bitstream and DTB
identities with the boot log.

## Payload Paths

Prebuilt qemu/NEMU payloads live under `linux/build/`. Distro/sim kernels from
`make -C linux build-rv*` land under `linux/build/raptor/<version>/`:

```text
linux/build/linux-riscv-qemu-rv32-fast-<version>/fw_payload.bin
linux/build/linux-riscv-qemu-rv64-m-<version>/fw_payload.bin
linux/build/raptor/v6.18.51/rv32-buildroot-sim/
linux/build/raptor/v6.18.51/rv64-alpine-sim/
```

Use the `linux/Makefile` helpers when another flow needs the exact path:

```shell
make -C linux print-rv32-payload
make -C linux print-rv64-payload
```

## Device Tree

NPC/NEMU Linux payloads use the platform device-tree data packaged with the
payload and simulator ROM flow. The RTL-visible platform devices are:

- CLINT at `0x0200_0000` (standard 0x000c_0000 window)
- PLIC at `0x0c00_0000` (16 MB window, 31 sources, M/S contexts)
- UART/peripheral window at `0x1000_0000`
- Memory at `0x8000_0000` and related platform windows documented in [Ecosystem](./ecosystem.md)

`RAPT_MTIME_FREQ_MHZ` / `RAPT_MTIME_DIV` must match the device-tree
`timebase-frequency`, because CSR `time` and CLINT `mtime` are paced together.

The KU15P Linux DT advertises `zicbom` and `riscv,cbom-block-size` using the
selected RTL preset's `RAPT_CACHE_LINE_BYTES`. The boot firmware enables
supervisor cache maintenance, including `cbo.zero` for the profile. LiteSDCard
DMA is non-coherent; the BIOS calls a legacy no-range CPU cache-maintenance hook
after DMA.

The NEMU RV32GC/RV64GC configurations inject a fresh 256-bit host-random seed
into the external DTB `/chosen/rng-seed` property before each boot. This matches
QEMU's early-boot entropy handoff and works even when a pre-built guest kernel
does not contain a hardware RNG driver. They also expose a virtio-mmio entropy
device at `0x10003000` on PLIC source 3 for ongoing entropy. Guest kernels must
enable `CONFIG_HW_RANDOM=y` and `CONFIG_HW_RANDOM_VIRTIO=y` to use that device;
Buildroot then sees `virtio_rng.0` as `/dev/hwrng`.

## Build From Source

Get the Linux Kernel source code from [The Linux Kernel Archives](https://www.kernel.org/):

```shell
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.51.tar.xz

tar -xf linux-6.18.51.tar.xz
cd linux-6.18.51
```

See more details in [linux/README.md](https://github.com/Kingfish404/raptor-chip/blob/master/linux/README.md).

The repository also keeps source-build helpers in `linux/Makefile`:

```shell
make -C linux build_linux
make -C linux opensbi-with-kernel
```

For day-to-day RTL validation, prefer the top-level `linux-boot-*` targets so
the simulator config, payload path, and difftest reference stay aligned.

## References

- [Build mini linux for your own RISC-V emulator!](https://github.com/CmdBlockZQG/rvcore-mini-linux)
- [给NEMU移植Linux Kernel!](https://github.com/Seeker0472/rapt-linux)
