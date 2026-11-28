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

## Interactive Boot Guide

Use the paths below when you want an interactive serial shell (`ttyS0`) rather
than batch verification:

1. **NEMU (fastest software simulation, seconds to shell):**

```shell
make linux-download-rv64
make linux-boot-nemu64gc
# Or RVA23 with 1..4 SMP harts:
make linux-boot-nemu-rva23 NEMU_RVA23_HARTS=2
# Or full Alpine 3.24 / Debian 13 / Ubuntu 26.10 userspace:
make -C linux nemu-distro-smoke DISTRO_BOOT=alpine
make -C linux nemu-distro-smoke DISTRO_BOOT=debian
make -C linux nemu-distro-run   DISTRO_BOOT=alpine
```

   Press `Ctrl+C` or run `poweroff` inside the guest to exit.

2. **Verilator RTL simulation (NPC):**

```shell
# Omit -b (batch) to attach stdin/stdout to ttyS0; disable wave tracing (-n)
# and NEMU difftest (DIFF_REF_SO=) for interactive speed.
make linux-boot-rv64gc ARGS="-n" DIFF_REF_SO=
make linux-boot-rv32 ARGS="-n" DIFF_REF_SO=
# Full distribution ext4 boot on Verilator RTL sim (Alpine / Debian / Ubuntu):
make -C linux sim-distro-smoke DISTRO_BOOT=alpine DISTRO_SIM_MILESTONE="OpenRC "
make -C linux sim-distro-run   DISTRO_BOOT=alpine
```

3. **FPGA Alpine 3.24 / Debian 13 / Ubuntu 26.10 and BSD `.img` (serial and SSH):**

```shell
make -C fpga/mlk-cu08-ku15p alpine-kernel JOBS=8
make -C fpga/mlk-cu08-ku15p alpine-rootfs UBUNTU_SSH_KEY=/path/to/your.pub
make -C fpga/mlk-cu08-ku15p alpine-apps alpine-bundle alpine-check alpine-serve
make -C fpga/mlk-cu08-ku15p alpine-load HW_TARGET='*/<BOARD-JTAG-ID>'
make -C fpga/mlk-cu08-ku15p alpine-boot UART_PORT='/dev/serial/by-id/<BOARD-UART>' \
  UBUNTU_HTTP_PROXY=http://192.168.50.1:7890
```

   `alpine-boot`, `debian-boot`, and `ubuntu-boot` attach to the 115200-baud UART
   console with root autologin and support persistent NFS, DDR4 `ramroot`, `squashfs`,
   or block-device roots on both KU15P and KU5P. Unmodified upstream NetBSD 11.1
   (`app/netbsd/`) and FreeBSD 15.0-RELEASE (`app/freebsd/`) `.img` images also boot
   directly over the VirtIO/UEFI bridge (`make -C app/netbsd fpga-boot-rv64`,
   `make -C app/freebsd fpga-boot`).

## Unmodified Upstream Ubuntu `.img` (U-Boot UEFI + `cidata`)

To boot an unmodified upstream Ubuntu RISC-V GPT cloud image (ESP + GRUB
`BOOTRISCV64.EFI` + upstream `linux-image-generic` + `initrd.img` + ext4 root)
through `OpenSBI (fw_dynamic) -> U-Boot (EFI_LOADER) -> GRUB`, use
`linux/uboot_efi.py` with `linux/dts/raptor-rva23-uefi.dts` and a Cloud-Init
NoCloud `cidata` seed disk:

```shell
# 1. Verify GPT, EFI System Partition (ESP), and ext4 root without editing .img
python3 linux/uboot_efi.py inspect-img /path/to/ubuntu-26.04-server-cloudimg-riscv64.img

# 2. Create a NoCloud cidata seed image (SSH key, password, serial autologin)
python3 linux/uboot_efi.py cidata \
  --output /tmp/raptor-uefi/cidata.img \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password ubuntu \
  --serial-autologin

# 3. Package OpenSBI, U-Boot, fresh 256-bit rng-seed DTB, and manifest.json
python3 linux/uboot_efi.py bundle \
  --output-dir /tmp/raptor-uefi/bundle \
  --opensbi /path/to/fw_dynamic.bin \
  --uboot /path/to/u-boot.bin \
  --cidata /tmp/raptor-uefi/cidata.img

# 4. Run interactive UEFI boot under QEMU virt (Ctrl+A then X to exit)
python3 linux/uboot_efi.py qemu-smoke \
  --opensbi /path/to/fw_dynamic.bin \
  --uboot /path/to/u-boot.bin \
  --image /path/to/ubuntu-26.04-server-cloudimg-riscv64.img \
  --cidata /tmp/raptor-uefi/cidata.img \
  --run
```

Generate a matching U-Boot defconfig fragment (enabling `EFI_LOADER`,
VirtIO/NVMe/SDHCI, `EFI_RNG_PROTOCOL`, and `Zicbom` cache maintenance) with:

```shell
python3 linux/uboot_efi.py uboot-config --output /tmp/raptor_rva23_efi.config
```

`raptor-rva23-uefi.dts` sets `systemd.default_timeout_start_sec=600` and
`systemd.default_device_timeout_sec=1800` in `/chosen/bootargs` so 50 MHz FPGA
cores do not hit systemd's 90-second default timeout without modifying the image.

OpenSBI provides the M-mode execution environment. On the default RV64
configuration Linux can use [RVA23S64](./README.md#rva23s64-support),
including Sv39, Sstc and the H extension. The host kernel runs in HS-mode
when H is enabled and can run guests with VS-stage Sv39 and G-stage Sv39x4.
It exposes [RVA23U64](./README.md#rva23u64-support) features to userspace through
the matching kernel configuration and device tree.

## Supported Modes

| Mode                | RTL path                              | Status                                                |
| ------------------- | ------------------------------------- | ----------------------------------------------------- |
| RV32 Linux          | Sv32 PTW/TLB + PMP + CLINT/PLIC       | Primary NPC/NEMU flow                                 |
| RV64 Linux          | Sv39 host translation; H and Sv39x4 for guests | NPC kernel-entry check, NEMU Linux boot and KVM probe |
| RV32/RV64 hard-float | `*gc` DTB + Buildroot F/D payload    | NPC targets are wired; payloads are built separately  |
| RV32/RV64 FPGA | LiteX BIOS + MIG DDR4 + OpenSBI/Linux | Ethernet/TFTP netboot targets for KU15P and KU5P |
| FPGA Linux Distros | RV64 KU5P and CU08-KU15P SoCs | `alpine-*`, `debian-*`, `ubuntu-*` over TFTP + NFS/DDR4/block |
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

<a id="ubuntu-on-native-fpga-socs"></a>
<a id="ubuntu-on-fpga-socs"></a>

### Linux Distributions on FPGA SoCs

The KU5P and CU08-KU15P `alpine-*`, `debian-*`, and `ubuntu-*` targets build a
board kernel, OpenSBI payload, and device tree for the RV64 `default` preset
(or non-vector presets such as `small` for Alpine/Debian). The on-board loader
fetches the firmware and DTB over TFTP, and Linux mounts its root over
persistent NFS, DDR4 `ramroot`/`squashfs`, or VirtIO/NVMe/SDHCI block storage.
[FPGA Linux distribution workflow](https://github.com/Kingfish404/raptor-chip/blob/master/fpga/common/DISTRO.md)

The FPGA I/O options provide a VirtIO-MMIO NIC with non-coherent DMA
and a bridge to host-backed VirtIO block, SDHCI and PCIe/NVMe devices.
Use the Ethernet transport on the board. NPC can connect to the same host
bridge through a local Unix socket.
[QEMU I/O bridge](https://github.com/Kingfish404/raptor-chip/blob/master/tools/qemu_io_bridge/README.md)

## RVA23U64 on Linux

Use an RV64 vector-enabled build with a matching DTB. Enable
`CONFIG_RISCV_ISA_V` for vector context management and
`CONFIG_RISCV_ISA_SUPM` for the tagged-address ABI. Check the generated DTB
for `v`, the applicable vector extensions and `ssnpm`.

```sh
make -C verification/subsystem rva23u64-smoke CONFIG=default
make -C verification/subsystem rva23u64-linux-probe BUILD_DIR=/tmp/raptor-rva23
```

The first command runs RTL tests. The second builds the static `rva23-check`
program. Include it as `/rva23-check` in the netboot initramfs and add
`rdinit=/rva23-check` to the kernel command line. The probe checks vector and
scalar instructions, cache-block operations and pointer masking in U-mode.
Successful completion prints `RVA23_LINUX_PASS`.

The November 19, 2026 integration run passed this probe on the
MLK-CU08-KU15P target with RV64, `default`, DDR4 and a 50 MHz core. BIOS
loaded Linux over TFTP. For a new board run, record the bitstream and DTB
identities with the boot log.

## RVA23S64 on Linux

Build an RV64 `default` system with H and a device tree that advertises it.
Enable `CONFIG_VIRTUALIZATION`, `CONFIG_KVM`, and the userspace options
described above. A probe running as PID 1 in an initramfs also needs
`CONFIG_DEVTMPFS` so it can mount `/dev`.

```sh
make -C verification/subsystem rva23s64-linux-probe BUILD_DIR=/tmp/raptor-rva23s64
```

Run the resulting `rva23s64-check` with access to `/dev/kvm`, or install it
as `/rva23s64-check` in the netboot initramfs and set
`rdinit=/rva23s64-check`. It runs the userspace checks, creates a KVM VM
and a vCPU, and runs a guest program that exits on an MMIO write. The guest
check prints `RVA23_KVM_PASS` before the final `RVA23_LINUX_PASS` marker.

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

- Finisher / syscon poweroff at `0x0010_0000`
- Goldfish RTC (`google,goldfish-rtc`) at `0x0010_1000` (PLIC source 6)
- CLINT at `0x0200_0000` (standard 0x000c_0000 window)
- PLIC at `0x0c00_0000` (16 MB window, 31 sources, M/S contexts)
- UART/peripheral window at `0x1000_0000` (NS16550A UART, VirtIO-Blk at `0x1000_1000`,
  VirtIO-Net at `0x1000_2000`, VirtIO-RNG at `0x1000_3000` on PLIC source 5)
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
