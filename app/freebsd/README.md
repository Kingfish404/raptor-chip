# FreeBSD for Raptor

This directory fetches, verifies, and boots unmodified upstream **FreeBSD 15.0-RELEASE
(`riscv64`)** VM disk images (`FreeBSD-15.0-RELEASE-riscv-riscv64-ufs.raw.xz`) on both
QEMU and Raptor FPGA hardware (`rapt_native_io_soc`).

Zero FreeBSD kernel or world source modifications are required:

- **Boot Chain**: `OpenSBI v1.8` (`CSR_SCOUNTEREN |= 0x07` enabling user-mode
  `rdcycle`, `rdtime`, and `rdinstret`) -> `U-Boot 2025.10` (`EFI_LOADER`) ->
  `EFI/BOOT/BOOTRISCV64.EFI` (`loader.efi`) -> upstream FreeBSD `GENERIC` kernel.
- **Hardware I/O & Coherent DMA**: Raptor's `rapt_native_io_soc` exposes standard
  Modern `VirtIO-MMIO v2` NIC (`vtnet0 @ 0x10002000`), `VirtIO-MMIO v2` Block
  (`vtblk0 @ 0x10001000`) and RNG (`vtrnd0 @ 0x10003000`) via
  `raptor_qemu_bridge.py` (`--transport udp`), `Goldfish RTC`
  (`goldfish_rtc0 @ 0x10004000`), and `NS16550A` UART (`uart0 @ 0x10000000`) with
  hardware cache-coherent DMA.

## Quick Start (QEMU)

```sh
cd app/freebsd
make check
make fetch          # Downloads & SHA256-verifies FreeBSD-15.0-RELEASE .raw.xz
make qemu-pristine  # Boots the 100% unmodified upstream .raw image (-snapshot)
```

To clone the upstream image into `build/fpga/freebsd-riscv64.raw` and pre-install
your `~/.ssh/*.pub` keys, fast `sshd` ciphers (`curve25519-sha256` /
`chacha20-poly1305`), `autoboot_delay="0"`, and natively compiled Raptor `app/`
microbenchmarks (`coremark.elf`, `memprobe.elf`, `cache-timing.elf`,
`bpu-collision.elf`, `spectre-v1.elf`, `rv_zicsr.elf`, etc.):

```sh
make prepare-fpga
make qemu           # SSH forwarded on localhost:2225 -> guest :22
```

## Booting Directly on Raptor FPGA (MLK-CU08-KU15P)

1. Ensure the KU15P `IO_SOC` bitstream (`rv64-default-w4` DDR 50 MHz with
   `--cm005-bridge 1 --cm005-ethernet 1 --virtio-net 1 --qemu-bridge 1`) is built
   and loaded onto the board.
2. Boot either the **unmodified upstream `.raw` image** (copy-on-write in host RAM)
   or the **SSH-provisioned image** (persistent UFS2):

```sh
# Zero-modification upstream .raw boot:
make -C app/freebsd fpga-boot-pristine \
  FPGA_PORT=/dev/ttyUSB0 \
  FPGA_DTB=fpga/mlk-cu08-ku15p/build/<io-soc-dir>/native.dtb

# SSH + microbenchmark provisioned boot:
make -C app/freebsd fpga-boot \
  FPGA_PORT=/dev/ttyUSB0 \
  FPGA_DTB=fpga/mlk-cu08-ku15p/build/<io-soc-dir>/native.dtb
```

Once `vtnet0` acquires its DHCP address, connect via SSH and run microbenchmarks
directly from `/usr/local/bin` or `/opt/raptor/bin`:

```sh
ssh root@<fpga-dhcp-ip> 'uname -a && coremark-quick.elf && cache-timing.elf'
```
