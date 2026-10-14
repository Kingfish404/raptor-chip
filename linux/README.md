# Raptor Linux: RV32 / RV64

This directory provides the Linux build entry points for Raptor. The base kernel and userspace come from [linux-build rv-v6.18.51](https://github.com/Kingfish404/linux-build/releases/tag/rv-v6.18.51). Download URLs, versions, and SHA256 hashes are centralized in `vars.mk`; the Linux source tarball hash is checked against the release's `kernel-source.json`. The existing tiny/Buildroot download and OpenSBI targets remain available.

| XLEN | Userspace | sim / NEMU | LiteX FPGA |
| --- | --- | --- | --- |
| RV32 | Buildroot, ilp32d | 256 MiB, embedded initramfs + OpenSBI payload | 1 GiB, separate kernel/initramfs, Ethernet + SD |
| RV64 | Alpine (default), Debian, Buildroot, lp64d | Same layout; requires a GC DTB/CPU with F/D enabled | Same layout; Alpine is the default netboot distribution |

This release does not provide RV32 Alpine/Debian packages; the build entry points reject those combinations. The workflow reuses distribution root filesystems and rebuilds the kernel and firmware for Raptor; it does not rebuild Alpine/Debian package repositories in this project. Userspace uses BusyBox init; services that require systemd/OpenRC need separate integration.

## Official Debian / Ubuntu on NEMU (systemd)

`distro_boot.py` provides a separate full-distribution path: official Debian 13
nocloud and Ubuntu 24.04 LTS riscv64 userspace, with the distribution's own
`/sbin/init` and systemd. It does not use the BusyBox-init conversion described
above. Ubuntu 24.04 is selected for the RV64GC baseline; this is not support for
Ubuntu 25.10+ and its RVA23 baseline.

Pinned sources are Debian build `20261001-2618` (SHA512) and Ubuntu build
`20260926` (SHA256), obtained from the official HTTPS image sites. Their source
URLs and checksums are in `distro_boot.py`. The platform uses an upstream Linux
kernel built by this repository, not the cloud image's distribution kernel or
its modules. The initially validated kernel artifact is Linux 6.18.51 with
VirtIO block/network, ext4, devtmpfs, RV64 floating point and systemd prerequisites
built in. The artifact manifest is checked before use.

The prepared environment uses 1 GiB RAM, NS16550 UART, CLINT/PLIC, VirtIO
block/network/RNG, and a syscon poweroff mapping to NEMU's finisher. OpenSBI is
rebuilt from the local source in an isolated temporary directory. NEMU is
compiled from the current sources with private Kconfig/generated headers and
objects under each distribution's output directory; shared `nemu/.config` and
the RTL simulator configuration are untouched.

Host prerequisites are the Linux build dependencies listed below, plus QEMU
system/tools, fakeroot, GNU tar, cpio, SDL2/readline/libslirp development files,
and the initialized NEMU Kconfig/fixdep/SoftFloat tools. The rootfs builder uses
the system `/usr/bin/tar` and `/usr/sbin/mke2fs` so a different libc in an
alternative tool installation does not bypass fakeroot ownership handling.
No root mount, loop device, binfmt registration, TAP interface, or host package
installation is performed by this workflow.

Ubuntu extraction must preserve the archive's numeric UID/GID values. If a
sandbox makes fakeroot's ownership operations fail with `Invalid argument`,
run preparation in an environment where fakeroot works; do not work around it
with `--no-same-owner`. A failed preparation leaves its output directory for
inspection, so move it aside or choose a new `DISTRO_WORK` before retrying.

With the existing kernel artifacts, run from the repository root:

```sh
make -C linux nemu-distro-prepare DISTRO_BOOT=debian
make -C linux nemu-distro-check DISTRO_BOOT=debian
make -C linux nemu-distro-prepare DISTRO_BOOT=ubuntu
make -C linux nemu-distro-check DISTRO_BOOT=ubuntu

# Independent control run, using the same kernel and rootfs without changing it:
make -C linux nemu-distro-check DISTRO_BOOT=debian DISTRO_ENGINE=qemu

# Interactive serial root console, without the acceptance timer's shutdown:
make -C linux nemu-distro-run DISTRO_BOOT=debian
make -C linux nemu-distro-run DISTRO_BOOT=ubuntu
```

`nemu-distro-prepare` requires a new `<DISTRO_WORK>/<DISTRO_BOOT>` directory; once prepared,
use `nemu-distro-check` or `nemu-distro-run` directly. The default work directory is
`linux/build/distro-boot`. `DISTRO_TIMEOUT` defaults to 3600 wall-clock seconds.
Checks write `<distro>/{nemu,qemu}-boot.log` and a matching `*-result.json`;
the result binds the log and artifact manifest hashes. NEMU also writes its
instruction/PC snapshots inside that distribution's directory.

To construct a fresh kernel first, select a new output directory rather than
overwriting an older immutable kernel build:

```sh
make -C linux build-rv64-fpga LINUX_DISTRO=debian \
    LINUX_OUTPUT="$PWD/linux/build/distro-kernel-new"
make -C linux nemu-distro-prepare DISTRO_BOOT=debian \
    DISTRO_WORK="$PWD/linux/build/distro-boot-new" \
    DISTRO_KERNEL="$PWD/linux/build/distro-kernel-new"
```

The platform overlay configures the single ext4 root disk, hostname, locale,
timezone, DHCP via systemd-networkd, and local serial root autologin. It disables
cloud-init, interactive firstboot, multipath and Snap startup, and the cloud
Pollinate entropy service; NEMU supplies host entropy through VirtIO RNG and
the boot DTB. It retains distribution libraries, package databases, systemd,
udev, D-Bus and normal service startup. No inbound network forwarding is added.

Acceptance requires systemd as PID 1, `multi-user.target`, an active serial
getty, no failed units, the expected distro/architecture, glibc and package
queries, floating-point arithmetic, a dynamic shell/checksum pipeline, ext4
root writes, and clean guest poweroff with emulator exit status zero. Merely
seeing a welcome banner or login prompt is insufficient. QEMU is a control,
not a substitute for the NEMU result.

NEMU's existing `--disk` backend keeps writes in memory, and QEMU checks use
`-snapshot`: guest changes do **not** survive a new emulator invocation. These
checks do not establish persistent package installation, external Internet
access, current wall-clock time, or FPGA boot. Use `poweroff` to end an
interactive session; NEMU's finisher does not implement guest reboot.
Allow host memory for the entire root disk plus guest RAM and emulator overhead.

## Building and validation

### NEMU multi-hart distribution boot

Set `DISTRO_HARTS=2` or `4` when preparing and running a distribution. The default
is still one hart. Each count uses a separate directory:
`build/distro-boot-smp2/<distro>` or `build/distro-boot-smp4/<distro>`; existing
single-hart artifacts are not rewritten.

```sh
make -C linux nemu-distro-prepare DISTRO_BOOT=debian DISTRO_HARTS=2
make -C linux nemu-distro-check DISTRO_BOOT=debian DISTRO_HARTS=2
make -C linux nemu-distro-prepare DISTRO_BOOT=debian DISTRO_HARTS=4
make -C linux nemu-distro-check DISTRO_BOOT=debian DISTRO_HARTS=4
make -C linux nemu-distro-run DISTRO_BOOT=debian DISTRO_HARTS=4
```

The manifest records the hart count, and `check`/`run` use that recorded value
for both NEMU and the optional `DISTRO_ENGINE=qemu` control. Preparation checks
the kernel's SMP/CPU capacity, builds NEMU with both runtime-selectable backends, and generates
matching CPU, CLINT and PLIC DTB topology. The guest acceptance program checks
the exact online CPU count, pins a pthread to each CPU, and exercises shared AMO
and LR/SC counters plus independent floating-point state. A boot is accepted
only after `RAPTOR_SMP_PASS harts=N ...`, the existing distribution checks, and
clean poweroff. The default `DISTRO_NEMU_BACKEND=rr` uses one host thread.
Select `DISTRO_NEMU_BACKEND=threaded` for one pthread per hart:

```sh
make -C linux nemu-distro-prepare DISTRO_HARTS=4 DISTRO_NEMU_BACKEND=threaded
make -C linux nemu-distro-check DISTRO_HARTS=4 DISTRO_NEMU_BACKEND=threaded
make -C linux nemu-distro-run DISTRO_HARTS=4 DISTRO_NEMU_BACKEND=threaded
```

The default threaded directory is `build/distro-boot-smp4-threaded/debian`.
Use `DISTRO_HARTS=2` for two harts or `DISTRO_BOOT=ubuntu` for Ubuntu.
`DISTRO_NEMU_CLOCK_DIV=16` controls guest time relative to monotonic host time;
the default slows guest time by 16 to accommodate interpreter throughput.
Backend and clock selection are runtime options, recorded in boot receipts.
To switch an already prepared, current NEMU image without rebuilding, supply
its existing `DISTRO_WORK` explicitly and select the other backend. The CPU
count remains tied to its prepared DTB and guest acceptance configuration.
This is functional emulation, not an FPGA multicore result or timing model.
CPU hotplug is outside this validation scope. Store run logs, timings and
investigation notes in ignored build directories rather than this guide.

To validate the prepared default directories:

```sh
for distro in debian ubuntu; do
  for harts in 2 4; do
    make -C linux nemu-distro-check DISTRO_BOOT="$distro" DISTRO_HARTS="$harts" \
      DISTRO_NEMU_BACKEND=threaded DISTRO_NEMU_CLOCK_DIV=16 DISTRO_TIMEOUT=3600 || exit
  done
done
```

This validates the repository-built upstream kernel with official distribution
userspace, not a distribution-packaged kernel, persistent disk writes, FPGA
multicore or multicore DiffTest. See the
[multicore DiffTest guide](../nemu/README.md#multicore-difftest) for
the separate verification work required.

### Existing kernel/initramfs flow

Run these commands from the repository root:

```sh
make -C linux build-rv32-sim
make -C linux build-rv64-sim
make -C linux build-rv64-sim LINUX_DISTRO=debian
make -C linux build-rv32-fpga
make -C linux build-rv64-fpga
make -C linux build-rv64-fpga LINUX_DISTRO=debian

# QEMU: boot, temporary ext4 persistence, reboot retention, and RAM fallback for missing/duplicate data volumes.
python3 linux/check.py linux/build/raptor/v6.18.51/rv64-alpine-sim
```

The default output directory is `linux/build/raptor/v6.18.51/rv<XLEN>-<distro>-<profile>/`. `manifest.json` records the source, configuration, runtime, and file hashes. Existing artifacts are verified and reused without modification. If inputs change, select a new directory with `LINUX_OUTPUT=/absolute/new/path` instead of overwriting old artifacts. `LINUX_PACKAGE` selects an extracted release with a manifest; `LINUX_CROSS` selects the cross toolchain.

Common artifacts are `Image`, `kernel.config`, `fw_dynamic.bin`, and `rootfs.cpio[.gz]`. The `sim` profile also produces `fw_payload.bin`, reserving `0x8fff0000` for the FDT. The kernel includes built-in support for 8250, LiteUART, LiteEth, virtio-net, MMC/LiteSDCard, ext4, script execution, and initramfs. It uses HZ=100 and disables legacy PTYs, ftrace, and related startup overhead while retaining Unix98 PTYs. Large embedded initramfs images use `rootfstype=ramfs` to avoid the default tmpfs capacity limit with 256 MiB RAM. Kernel sources and O= build intermediates use isolated `/tmp/raptor-chip-*` directories. Downloads and completed kernel/rootfs artifacts are cached in `linux/build/netboot-kernels/`, with file locks serializing access; shared `.config` files are not modified.

Build dependencies: Python 3.12+, make, C/C++ compilers, riscv64-linux-gnu GCC/binutils, flex, bison, bc, libssl/libelf development packages, dtc (including fdtget/fdtput), e2fsprogs, and curl. `check.py` also accepts netboot bundles and exercises the actual trampoline and address layout, replacing the hardware DTB with a QEMU DTB. Pass multiple systems in one invocation to check isolation and sharing on a newly created common data disk. QEMU validation additionally requires qemu-system-riscv32/riscv64. The workflow does not install host dependencies automatically.

## Booting sim / NEMU

```sh
make -C linux run-rv32-nemu
make -C linux run-rv64-nemu
make -C linux run-rv64-nemu LINUX_DISTRO=debian
make -C linux run-rv32-sim
make -C linux run-rv64-sim
```

These entry points reuse the root Makefile's GC configuration and boot targets. They **configure sim/NEMU**; do not interleave them with configuration changes from another session. Building Linux alone does not touch sim/NEMU configuration. The new sim kernel uses a fixed command line to select the matching `/sbin/raptor-init`; the corresponding GC DTB still describes devices, memory, and ISA. NEMU provides virtio-net; networking in RTL simulation depends on its actual peripherals, so NEMU's virtual networking support does not imply equivalent RTL simulator support. OpenSBI in the sim payload disables semihosting probing to prevent its EBREAK from being treated as program termination by the RTL test harness. This change applies only to the isolated firmware build directory.

## FPGA netboot and SD persistence

```sh
make -C fpga/litex fpga-netboot-rv64-bundle RAPT_CONFIG=middle
make -C fpga/litex fpga-netboot-rv64-serve RAPT_CONFIG=middle
make -C fpga/litex fpga-netboot-rv64-load RAPT_CONFIG=middle
make -C fpga/litex fpga-netboot-rv64-console RAPT_CONFIG=middle
# At litex>, manually enter the netboot .../boot.json command printed by serve and wait for Linux.
# Add NETBOOT_DISTRO=debian to bundle/serve to select Debian; RV32 defaults to Buildroot.
```

These commands require an existing, matching hardware build. See the [netboot workflow](../fpga/litex/NETBOOT.md) for parameters that allow software updates to reuse a previously validated bitstream. `NETBOOT_DISTRO=legacy` retains the original fw_payload diagnostic path. The default workflow uses this directory's builder and `pack_netboot.py` to create immutable namespaces, validating XLEN, 1 GiB RAM, kernel bounds, CMO initialization, and SD CSRs. Use `pack_netboot.py --help` to manually package `build-*-fpga` artifacts with their exact DTB/CSR inputs.

SD persistence selects a unique ext4 volume with `LABEL=RAPTOR_DATA`; UUID selection is also supported. `/data/shared` is shared across systems; `/home` and `/root` use separate bind mounts for each architecture/distribution/version. `/etc`, programs, and package databases reside in RAM, so packages installed with apk/apt disappear after reboot. Missing cards or duplicate labels fall back to RAM boot with a read-only `/data` placeholder. The runtime never partitions, formats, or repairs SD cards. See [SD persistence](../fpga/litex/SD-PERSISTENCE.md) for the full contract.

Press Enter on the serial console to access the root shell. DHCP and SSH start in the background without blocking login. Networking requires DHCP on the board's network; accessing apk/apt repositories also requires a gateway and DNS. The netboot workflow does not automatically configure host NAT. SSH password authentication is disabled; configure accounts and `authorized_keys` through the serial console. User keys in persistent home/root directories survive reboot on SD.

## Existing release download targets

```sh
make -C linux download             # tiny RV32/RV64
make -C linux download-gc          # fast Buildroot RV32GC/RV64GC
make -C linux download-rv64-alpine
make -C linux download-rv64-debian
make -C linux download-all
```

When switching releases, update `LINUX_BUILD_RELEASE`, `LINUX_BUILD_VERSION`, and the corresponding SHA256 hashes together. Existing release directories can be retained.

## Linux Dependencies

`make opensbi-rv32` and `make opensbi-rv64` use Clang/LLVM and require `ld.lld` for RISC-V PIE firmware. The corresponding GNU targets are `make opensbi-gnu-rv32` and `make opensbi-gnu-rv64`. The unqualified `make opensbi` and `make opensbi-gnu` names remain RV32 compatibility aliases.

```sh
# Arch Linux
sudo pacman -S --needed clang llvm lld riscv64-linux-gnu-gcc

# Debian/Ubuntu
sudo apt update && sudo apt install clang llvm lld gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu

# Fedora/RHEL family
sudo dnf install clang llvm lld gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu
```

If `make opensbi` reports `Your linker does not support creating PIEs`, check that `ld.lld` is available and rebuild:

```sh
command -v ld.lld
ld.lld --version
make opensbi-clean
make opensbi
```

## KU15P FPGA OpenSBI-only upload

The LiteX FPGA flow can package the standalone RV32 OpenSBI build into a small serialboot image, avoiding the much larger prebuilt OpenSBI+Linux payload when you only need to validate OpenSBI, DTB handoff, SBI console, and the MIG-backed main RAM path:

```sh
cd ../fpga/litex
make fpga-opensbi-img-rv32
make opensbi-fpga-rv32-upload

# RV64 equivalents:
make fpga-opensbi-img-rv64
make opensbi-fpga-rv64-upload
```

The image targets run the matching OpenSBI build as needed and write `fpga/litex/build/firmware/linux-fpga/rv32/linux-fpga-opensbi.img` or `fpga/litex/build/firmware/linux-fpga/rv64/linux-fpga-opensbi.img` with stage0 at `0x80000000`, OpenSBI's `fw_payload.bin` staged at `0x80100000`, and the LiteX DTB staged at `0x80800000` by default. Stage0 copies OpenSBI back to `0x80000000`, copies the DTB to `0x83f00000`, then jumps with `a0=0` and `a1=0x83f00000`. Override `LINUX_FPGA_OPENSBI_DTB_OFFSET` if you build a larger custom OpenSBI payload that needs more than the default 8 MiB staging window.

This path uses OpenSBI's standalone `fw_payload.bin`. `fw_dynamic.bin` would need an `fw_dynamic_info` handoff block from stage0, and `fw_jump.bin` needs a defined next-stage address/payload convention, so they are not direct replacements for `fpga-opensbi-upload`.

发行版 netboot bundle 名称包含发行版、Linux 版本、UTC 打包时间和短校验码；现有镜像与清理说明见 [可读 bundle 名称](../fpga/litex/NETBOOT.md#可读的-bundle-名称)。

UART 平台约定：规范 Spike 派生 DTS 与 QEMU virt 均使用 NS16550 IRQ10，NEMU
Linux presets 显式选择 `CONFIG_SERIAL_PLIC_IRQ=10`。更新后需重新配置/构建 NEMU
及 ROM/DTB，已有二进制不会自动改变。自定义旧平台需要 IRQ1 时必须显式设置，
并匹配其专用 DTB。sim/NEMU 的 CU08 LiteUART 地址为 `0x11001800`；旧的
`0xf0001000` 和 `0xf0001800` UART alias 已撤销，不能据此把实际 FPGA 的 timer0 当作 UART。
