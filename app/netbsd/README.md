# NetBSD for Raptor

This directory builds NetBSD with the official NetBSD `build.sh` cross-build framework. Source, tools, objects, destination files, release artifacts, and simulator payloads stay under `app/netbsd/`.

## Prerequisites

The host needs Git, GNU make, GCC/G++, QEMU, and standard POSIX build tools. Configure the local VPN proxy before fetching sources:

```sh
export http_proxy="http://localhost:9091"
export https_proxy="http://localhost:9091"
```

## Build

```sh
cd app/netbsd
make fetch
make list-arch
make build-rv32
make build-rv64
```

The default source branch is `netbsd-11`. Override it with `make NETBSD_SRC_REF=trunk build-rv64`. The source preparation step also applies the tracked patches under `app/netbsd/patches/`.

Use `make check-images` to inspect kernel formats, GPT partitions, image sizes, and backend limits. Use `make -n <target>` to print the complete command sequence without executing it.

## QEMU

The QEMU targets build the required standalone OpenSBI firmware, decompress the current kernel and disk image, and then execute QEMU:

```sh
make qemu-rv32
make qemu-rv64
```

To inspect the exact commands, use:

```sh
make -n qemu-rv32
make -n qemu-rv64
```

The QEMU targets expect the corresponding release to have been built first with `make build-rv32` or `make build-rv64`. QEMU boots the NetBSD kernel with the GPT disk attached through virtio-blk and uses `root=dk1`.

The RV32 QEMU boot now reaches `root on dk1`. RV32 currently limits managed memory to the initially mapped 32 MiB kernel window, so later userland startup may report `out of swap`; this is separate from the fixed early boot faults.

## NEMU

The release `riscv32.img` and `riscv64.img` files are GPT disks, not flat RAM images. Their sizes are about 1.1 GiB and 1.4 GiB, while the current simulator RAM window is 128 MiB. The Makefile therefore builds a small OpenSBI plus NetBSD flat payload and attaches the GPT disk separately:

```sh
make nemu-run-rv32
make nemu-run-rv64
```

Use `make -n nemu-run-rv32` or `make -n nemu-run-rv64` to inspect the full NEMU configuration, build, DTB preparation, and run commands.

## RTL simulation

RTL simulation consumes the same flat payload through `IMG` and the GPT disk through `DISK`. Build the payloads with `make sim-payload-rv32` or `make sim-payload-rv64`, then use the simulator Makefile with the matching ISA configuration. The payload DTBs are generated for the current 128 MiB RTL RAM window.

Use `make -n sim-payload-rv32` and `make -n sim-payload-rv64` to inspect payload generation. The current RTL path has been verified to load the payload and disk; complete NetBSD guest boot still requires further backend/device validation.

## LiteX

The current LiteX Linux flow does not provide the QEMU virtio-mmio devices or the NetBSD-specific SD-card and DTB handoff required by these GPT images. Do not pass the NetBSD GPT images directly to LiteX `--ram-init` or `serialboot`; a LiteX-specific NetBSD port, matching DTB, and SD boot path are required.

## References

The QEMU command layout follows the NetBSD RISC-V QEMU guide: <https://wiki.netbsd.org/ports/qemu_riscv/>.
