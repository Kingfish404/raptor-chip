# Build OpenSBI with Linux Kernel Payload

Please see `/linux/Makefile` in this directory for details.

## Pre-built release images

Raptor downloads its pre-built Linux images from the
[`linux-build` rv-v6.18.49 release](https://github.com/Kingfish404/linux-build/releases/tag/rv-v6.18.49)
into the ignored `linux/build/` directory. Downloads are checked against the
SHA-256 digests published by GitHub before extraction.

```sh
# Standard RV32/RV64 simulator payloads.
make download

# Fast RV32GC/RV64GC Buildroot Images used by RTL simulation.
make download-gc

# Complete RV32GC Buildroot payload used by the FPGA SD-card image.
make download-rv32gc-fpga

# Fetch every release asset used by the repository.
make download-all
```

The release tag and asset version are separate variables. The current
`rv-v6.18.49` release publishes files suffixed with `v6.18.49`. Override `LINUX_BUILD_RELEASE`,
`LINUX_BUILD_VERSION`, and the corresponding `*_SHA256` value together when
selecting another release.

## Linux Dependencies

`make opensbi-rv32` and `make opensbi-rv64` use Clang/LLVM and require `ld.lld`
for RISC-V PIE firmware. The corresponding GNU targets are
`make opensbi-gnu-rv32` and `make opensbi-gnu-rv64`. The unqualified
`make opensbi` and `make opensbi-gnu` names remain RV32 compatibility aliases.

```sh
# Arch Linux
sudo pacman -S --needed clang llvm lld riscv64-linux-gnu-gcc

# Debian/Ubuntu
sudo apt update && sudo apt install clang llvm lld gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu

# Fedora/RHEL family
sudo dnf install clang llvm lld gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu
```

If `make opensbi` reports `Your linker does not support creating PIEs`, check
that `ld.lld` is available and rebuild:

```sh
command -v ld.lld
ld.lld --version
make opensbi-clean
make opensbi
```

## KU15P FPGA OpenSBI-only upload

The LiteX FPGA flow can package the standalone RV32 OpenSBI build into a small
serialboot image, avoiding the much larger prebuilt OpenSBI+Linux payload when
you only need to validate OpenSBI, DTB handoff, SBI console, and the MIG-backed
main RAM path:

```sh
cd ../fpga/litex
make fpga-opensbi-img-rv32
make opensbi-fpga-rv32-upload

# RV64 equivalents:
make fpga-opensbi-img-rv64
make opensbi-fpga-rv64-upload
```

The image targets run the matching OpenSBI build as needed and write
`fpga/litex/build/firmware/linux-fpga/rv32/linux-fpga-opensbi.img` or
`fpga/litex/build/firmware/linux-fpga/rv64/linux-fpga-opensbi.img` with stage0 at
`0x80000000`, OpenSBI's `fw_payload.bin` staged at `0x80100000`, and the LiteX
DTB staged at `0x80800000` by default. Stage0 copies OpenSBI back to
`0x80000000`, copies the DTB to `0x83f00000`, then jumps with `a0=0` and
`a1=0x83f00000`. Override `LINUX_FPGA_OPENSBI_DTB_OFFSET` if you build a larger
custom OpenSBI payload that needs more than the default 8 MiB staging window.

This path uses OpenSBI's standalone `fw_payload.bin`. `fw_dynamic.bin` would need
an `fw_dynamic_info` handoff block from stage0, and `fw_jump.bin` needs a defined
next-stage address/payload convention, so they are not direct replacements for
`fpga-opensbi-upload`.
