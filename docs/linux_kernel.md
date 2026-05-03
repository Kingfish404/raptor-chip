# Linux Kernel Boot

Raptor boots Linux through an OpenSBI `fw_payload.bin` image:

```text
reset/MROM -> OpenSBI (M-mode) -> Linux (S-mode) -> init/userspace
```

The top-level Makefile is the preferred entry point. It downloads prebuilt
OpenSBI + Linux payloads from `Kingfish404/linux-build` and keeps NEMU/NPC
configuration in sync. The default `LINUX_BUILD_VERSION` is `v6.18.22`.

## Quick Commands

```shell
# Download prebuilt RV32 + RV64 payloads
make linux-download

# RV32 Linux through NEMU / NPC
make linux-boot-nemu32 ARGS="-b -n"
make linux-boot-npc32 ARGS="-b -n"

# RV32 NPC with NEMU difftest reference
make linux-boot-npc32-difftest ARGS="-b -n"

# RV64 prebuilt payload path is available; the top-level device helper is NEMU-only today
make linux-download-rv64
make linux-boot-nemu64-device
```

Useful overrides:

```shell
make linux-boot-npc32 LINUX_BUILD_VERSION=v6.18.22 MAX_INST=100000000 ARGS="-b -n"
make linux-boot-npc32 LINUX_RV32_PAYLOAD=/path/to/fw_payload.bin ARGS="-b -n"
```

## Supported Modes

| Mode | RTL path | Status |
| ---- | -------- | ------ |
| RV32 Linux | Sv32 PTW/TLB + PMP + CLINT/PLIC | Primary NPC/NEMU flow |
| RV64 Linux payloads | Payload download + NEMU device helper | Available in tooling |
| RV64 xv6 smoke path | Sv39 PTW/TLB + A/D writeback | Available via `app/tinyos` helpers |

See [linux/README.md](../linux/README.md) and [app/tinyos/README.md](../app/tinyos/README.md) for the lower-level payload and xv6/egos helpers.

## Payload Paths

The downloaded payloads live under `linux/build/`:

```text
linux/build/linux-riscv-qemu-rv32-m-<version>/fw_payload.bin
linux/build/linux-riscv-qemu-rv64-m-<version>/fw_payload.bin
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

## Build From Source

Get the Linux Kernel source code from [The Linux Kernel Archives](https://www.kernel.org/):

```shell
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.22.tar.xz

tar -xf linux-6.18.22.tar.xz
cd linux-6.18.22
```

See more details in [linux/README.md](../linux/README.md).

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
