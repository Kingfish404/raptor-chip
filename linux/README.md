# Raptor Linux: RV32 / RV64

This directory provides the Linux build entry points for Raptor. The base kernel and userspace come from [linux-build rv-v6.18.51](https://github.com/Kingfish404/linux-build/releases/tag/rv-v6.18.51). Download URLs, versions, and SHA256 hashes are centralized in `vars.mk`; the Linux source tarball hash is checked against the release's `kernel-source.json`. The existing tiny/Buildroot download and OpenSBI targets remain available.

| XLEN | Userspace | sim / NEMU | LiteX FPGA |
| --- | --- | --- | --- |
| RV32 | Buildroot, ilp32d | 256 MiB, embedded initramfs + OpenSBI payload | 1 GiB, separate kernel/initramfs, Ethernet + SD |
| RV64 | Alpine (default), Debian, Buildroot, lp64d | Same layout; requires a GC DTB/CPU with F/D enabled | Same layout; Alpine is the default netboot distribution |

This release does not provide RV32 Alpine/Debian packages; the build entry points reject those combinations. The workflow reuses distribution root filesystems and rebuilds the kernel and firmware for Raptor; it does not rebuild Alpine/Debian package repositories in this project. Userspace uses BusyBox init; services that require systemd/OpenRC need separate integration.

## Building and validation

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
