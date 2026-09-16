# CU08 RV64 Linux/network profile

This opt-in profile prepares RV64 Linux with CM005 FMC_C/ETHA Ethernet. It does
not change the normal RV32 or tiny-shell RV64 defaults. Hardware acceptance is
still required: no RV64 routed-timing or board-network PASS is implied.

## Included configuration

- CU08, `VARIANT=linux64`, `RAPT_CONFIG=default`, 50 MHz, MIG, SD card.
- CM005 FMC_C/ETHA (CU08 short edge), fixed 1000 Mb/s full-duplex advertisement.
  This uses the gigabit oversampling receiver and common-source-clock DDR TX; full-SoC timing and board
  traffic validation are required. Confirm the FMC IO supply is 1.8 V.
- BIOS stops at `litex>` after initialization. Select `sdcardboot` or `netboot` manually.
- RV64 **Buildroot** release `linux-riscv-rv64-qemu-rv64-fast-buildroot-v6.18.50`,
  not the tiny-shell image. “fast” describes the kernel preset; this package
  still contains the normal Buildroot `/init` and network services.
- F/D advertised in both device-tree ISA properties for LP64D userspace;
  BIOS/stage0 can continue using soft-float compiler ABIs.
- `/init` starts `S40network`: eth0 DHCP installs address, gateway and DNS.
  A DHCP server/router with Internet access (or a separately configured host
  sharing connection) and a connected cable are prerequisites, not provided
  by this profile. No host network configuration is changed.
- Upload DTB slot at +64 MiB; OpenSBI runtime DTB remains `0x83f00000`.

## Prepare and use

Run from the repository root. Preflight is read-only, checks manifest hashes,
kernel/rootfs network support, image layout, OpenSBI hook and host tools:

```sh
fpga/litex/.venv/bin/python fpga/litex/scripts/rv64_network.py check
fpga/litex/.venv/bin/python fpga/litex/scripts/rv64_network.py build --print-command
```

Prepare LiteX and the cross compiler/dtc normally, then obtain the pinned
release using `make -C linux download-rv64gc`. An alternative extracted package
can be selected with `--package`; preflight rejects tiny-shell or incompatible
layout packages. It compares files to their manifest; release archive trust
comes from the pinned SHA256 in `linux/vars.mk`, not from the manifest alone.

These are explicit mutating operations; do not run duplicate builds of the
same configuration:

```sh
# Generate the contiguous SD image and matching stage0/DTB. No Vivado P&R.
fpga/litex/.venv/bin/python fpga/litex/scripts/rv64_network.py image
# Build the matching bitstream; does NOT load it.
fpga/litex/.venv/bin/python fpga/litex/scripts/rv64_network.py build
# Only after timing passes and the matching SD image is installed:
fpga/litex/.venv/bin/python fpga/litex/scripts/rv64_network.py load
```

All commands use the same explicit Make settings, including RV64 at the parent
Make level. Image and bitstream outputs are isolated under:

```text
fpga/litex/build/rv64-network/
  firmware/linux-fpga/rv64-mlk_cu08_ku15p-default-<firmware-config-id>/linux-fpga.img
  mlk_cu08_ku15p/bios-linux64-mig-sdcard-default-cm005-c-a-manualboot-<fpga-config-id>/
    gateware/mlk_cu08_ku15p.bit
```

RTL packs now live under this build root's `rtl/<preset>-<defines-id>/`, without
rewriting `sim/.config` or `sim/build/default/rapt_pack.sv`. BIOS and supporting
software are copied and patched privately under the FPGA configuration directory.
Configuration IDs distinguish build settings, not immutable source revisions:
keep source inputs stable during a build and verify the final input stamp before
loading. `check` and `--print-command` never invoke Make.

Copy the generated image to `boot.bin` on the board's FAT SD partition only
after independently confirming its device/mount and obtaining approval to
replace that file; sync, verify the destination checksum, and unmount before
insertion. The script never writes an SD card or flash. Do not reuse an RV32
boot.bin: the BIOS embeds stage0/DTB, **not** the full Linux payload. Loading the
bitstream stops at the BIOS prompt. Enter `sdcardboot` to boot the matching SD
image, after which Buildroot attempts DHCP. Missing SD/payload/network infrastructure is
not repaired by loading the bitstream.

## Acceptance still needed

For the exact RV64 bitstream, check setup/hold/pulse-width and MIG bus skew;
then confirm PHY 1000 Mb/s full duplex, Linux eth0 IRQ/data transfer, DHCP lease,
default route, DNS resolution and repeated external HTTP requests. A PHY link,
BIOS TFTP, or RV32 test result is not RV64 Linux networking acceptance.

Peripheral-only regression (no pack/synthesis/hardware):

```sh
PYTHONDONTWRITEBYTECODE=1 fpga/litex/.venv/bin/python fpga/litex/tests/test_rv64_network.py
```
