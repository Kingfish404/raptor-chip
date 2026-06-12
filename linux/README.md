# Build OpenSBI with Linux Kernel Payload

Please see `/linux/Makefile` in this directory for details.

## Linux Dependencies

`make opensbi` uses Clang/LLVM and requires `ld.lld` for RISC-V PIE firmware.
`make opensbi-gnu` uses the RISC-V GNU cross compiler.

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
make linux-fpga-opensbi-img
make linux-fpga-opensbi-upload UART_PORT=/dev/ttyUSB0 UART_BAUD=230400
```

`linux-fpga-opensbi-img` runs `make -C linux opensbi` as needed and writes
`fpga/litex/build/firmware/linux-fpga/linux-fpga-opensbi.img` with stage0 at
`0x80000000`, OpenSBI's `fw_payload.bin` staged at `0x80100000`, and the LiteX
DTB staged at `0x80800000` by default. Stage0 copies OpenSBI back to
`0x80000000`, copies the DTB to `0x83f00000`, then jumps with `a0=0` and
`a1=0x83f00000`. Override `LINUX_FPGA_OPENSBI_DTB_OFFSET` if you build a larger
custom OpenSBI payload that needs more than the default 8 MiB staging window.

This path uses OpenSBI's standalone `fw_payload.bin`. `fw_dynamic.bin` would need
an `fw_dynamic_info` handoff block from stage0, and `fw_jump.bin` needs a defined
next-stage address/payload convention, so they are not direct replacements for
`linux-fpga-opensbi-upload`.
