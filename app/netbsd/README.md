# NetBSD for Raptor

This directory supports **two workflows** for running NetBSD 11 on Raptor:

1. **Zero-Modification Official Binary Image Workflow (`riscv64.img.gz`)**:
   Downloads upstream NetBSD 11 `riscv64` daily/release images directly and boots
   them unmodified on QEMU and Raptor FPGA hardware (`rapt_native_io_soc` with
   hardware cache-coherent DMA, `VirtIO-MMIO v2` NIC/Blk/RNG, and `Goldfish RTC`).
2. **Full Cross-Build Workflow (`build.sh` for RV32 & RV64)**:
   Builds NetBSD from source (`netbsd-11`) for RV32 (`riscv32`) and RV64 (`riscv64`),
   plus NEMU and Verilator RTL simulator payloads. Note that
   `patches/riscv-rv32-mmu.patch` only guards `#ifndef _LP64` for RV32; **RV64
   (`GENERIC64` / `riscv64.img`) requires zero NetBSD kernel or userland patches**.

## Fast Official RV64 Image Workflow (QEMU & FPGA)

```sh
cd app/netbsd
make fetch-image-rv64           # Download official riscv64.img.gz + GENERIC64
make qemu-image-pristine-rv64   # Boot unmodified riscv64.img via OpenSBI + U-Boot
```

To clone `riscv64.img` into `build/fpga/netbsd-riscv64.img` with your
`~/.ssh/*.pub` keys, fast `sshd` ciphers (`curve25519-sha256` / `chacha20-poly1305`),
trimmed background daemons (`postfix=NO`, `mdnsd=NO`, `ntpd=NO`), and natively
compiled Raptor `app/` microbenchmarks (`coremark.elf`, `memprobe.elf`,
`cache-timing.elf`, `bpu-collision.elf`, `spectre-v1.elf`, `rv_zicsr.elf`, etc.):

```sh
make prepare-fpga-rv64
make qemu-image-rv64            # SSH forwarded on localhost:2226 -> guest :22
```

### Booting Directly on Raptor FPGA (MLK-CU08-KU15P)

Upstream NetBSD 11 RISC-V leaves `cpu_dcache_*_range` as no-ops on generic RISC-V
cores. Raptor's `rapt_native_io_soc` provides **hardware cache-coherent DMA**
(write-through L1D + hardware `external_write` set invalidation), allowing
unmodified `riscv64.img` and `GENERIC64` to boot reliably over `VirtIO-Net` +
`VirtIO-Blk` (`raptor_qemu_bridge.py --transport udp`):

```sh
# 1. Boot the 100% unmodified official riscv64.img via OpenSBI + U-Boot UEFI (COW):
make -C app/netbsd fpga-boot-pristine-rv64 \
  FPGA_PORT=/dev/ttyUSB0 \
  FPGA_DTB=fpga/mlk-cu08-ku15p/build/<io-soc-dir>/native.dtb

# 2. Boot the SSH + microbenchmark image via UEFI GPT boot:
make -C app/netbsd fpga-boot-rv64 \
  FPGA_PORT=/dev/ttyUSB0 \
  FPGA_DTB=fpga/mlk-cu08-ku15p/build/<io-soc-dir>/native.dtb

# 3. Optional fast direct-kernel boot (skips U-Boot EFI, ~5s faster boot):
make -C app/netbsd fpga-boot-rv64 NETBSD_DIRECT_KERNEL=1 \
  FPGA_PORT=/dev/ttyUSB0 \
  FPGA_DTB=fpga/mlk-cu08-ku15p/build/<io-soc-dir>/native.dtb
```

## Source Build Workflow (`build.sh`, RV32 & RV64)

```sh
cd app/netbsd
make fetch
make list-arch
make build-rv32
make build-rv64
make check-images
```

### QEMU, NEMU, and Verilator RTL Simulation (Source Build)

```sh
make qemu-rv32
make qemu-rv64
make nemu-run-rv32
make nemu-run-rv64
make sim-payload-rv64
```

The simulator targets build a compact `OpenSBI + GENERIC` flat payload (`IMG`) and
attach the GPT disk via `DISK` (`--disk`). The RV32 QEMU boot reaches `root on dk1`
within its 32 MiB initial kernel VA window.

## References

- NetBSD RISC-V QEMU guide: <https://wiki.netbsd.org/ports/qemu_riscv/>
