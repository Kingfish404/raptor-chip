# Arty A7-100T

The default build is a Raptor LiteX SoC. It selects a preset from
`rtl/configs/`, connects the onboard 256 MiB DDR3, USB UART and 100 Mb/s MII
Ethernet, and exposes the CPU's JTAG TAP on the ChipKIT pins.
Use `PLATFORM=octal` for the [octal-link test platform](OCTAL-LINK.md).
Use explicit `PLATFORM=jesd` for the separate [native Profile 1 fixture](native/README.md).
Its chip talks directly to the external Flash; the private bridge is not in that path.
The [25-signal bring-up runbook](CHIP25.md) explains their different memory maps,
console pins, boot images and validation order.

## SoC builds

Install the [LiteX environment](../litex/README.md#quick-start), generate the RTL
decoders with `make verilog` when needed, and put Vivado on `PATH`. From the
repository root:

```sh
make -C fpga/arty-a7-t100 info
make -C fpga/arty-a7-t100 prepare XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 synth XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 build XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 load XLEN=32 RAPT_CONFIG=small HW_TARGET='<target-glob>'
make -C fpga/arty-a7-t100 console UART_PORT=/dev/ttyUSB1
```

Defaults are `XLEN=32 RAPT_CONFIG=small MEMORY=ddr CLOCK_MHZ=20`. `XLEN=64`
is supported by the integration, subject to the selected preset's device fit.
The `chip32-*` presets accept RV32 only. Do not infer fit from successful source
generation: both LUT capacity and routed timing must pass for an actual image.
`synth` stops before placement and routing; `build` refuses bitstream generation
when final timing fails. `load` also requires the matching build stamp and a
passing routed timing report. `HW_TARGET` is optional when exactly one target exists.

Use `BUILD_ROOT=/path/to/fpga-work` to keep all build artifacts outside the checkout.
Presets, XLENs and other settings get distinct output directories. `make info`
prints the resolved directory. The root wrapper also works:

```sh
make fpga-build FPGA_BOARD=arty-a7-t100 XLEN=32 RAPT_CONFIG=small
```

`MEMORY=bram RAM_BYTES=131072` builds a smaller bring-up memory without DDR3.
Its BIOS can load bare-metal programs; Linux requires external RAM.

## Clocks and memory

| Domain | Frequency | Function |
| --- | ---: | --- |
| Reference | 100 MHz | Onboard oscillator |
| CPU | 20 MHz default | Cluster, CLINT and sampled JTAG |
| SoC / DDR controller | 80 MHz | LiteX bus, UART, timer and LiteDRAM |
| DDR3 clock | 320 MHz | 640 MT/s, within the board's 667 MT/s rating |
| IDELAY reference | 200 MHz | DDR3 calibration |
| Ethernet reference | 25 MHz | Onboard PHY |

Board memory and Ethernet specifications come from the
[Digilent Arty A7-100T product page](https://digilent.com/shop/arty-a7-100t-artix-7-fpga-development-board/).

`CLOCK_MHZ=20|25|50|100` changes only the CPU clock. An AXI asynchronous bridge
carries all five channels to the SoC domain, and interrupt/reset inputs are
synchronized into the CPU domain. DDR3 clocks stay fixed when slowing the CPU.
The generated Linux DTB uses the CPU frequency as its CLINT timebase; BIOS
peripheral timers continue to use the actual SoC frequency.

The LiteX memory map places ROM at `0x20000000`, scratch SRAM
at `0x0f000000`, RAM at `0x80000000..0x8fffffff`, UART at `0x11001800` and uncached
Ethernet buffers at `0x18000000`. The DDR3 PHY calibrates in BIOS before RAM use.

## CPU JTAG and GDB

The onboard USB JTAG configures the FPGA. CPU debugging uses a separate
CMSIS-DAP JTAG probe on the ChipKIT pins:

| Signal | ChipKIT | FPGA pin |
| --- | --- | --- |
| TCK | ck13 | P17 |
| TMS | ck12 | R17 |
| TDI | ck11 | U18 |
| TDO | ck10 | V17 |

Connect ground and a 3.3 V probe reference. The TAP resets through TMS, so leave
probe nTRST/nRESET disconnected. The supplied configuration uses 500 kHz TCK;
keep TCK at most one tenth of the CPU frequency.

```sh
make -C fpga/arty-a7-t100 debug RAPT_PROBE_SERIAL='<probe-serial>'
# In another terminal:
riscv64-unknown-elf-gdb program.elf
# (gdb) target extended-remote localhost:3333
# (gdb) monitor halt
```

The DM supports halt/resume, register access and physical SBA. Follow the
[debug cache-maintenance rules](../../verification/jtag/README.md#safe-loading-and-inspection)
when loading or patching cached RAM code. The CPU console uses the onboard USB UART.

## Linux and netboot

```sh
make -C fpga/arty-a7-t100 linux-image XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 linux-upload XLEN=32 RAPT_CONFIG=small UART_PORT=/dev/ttyUSB1

make -C fpga/arty-a7-t100 netboot-build XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 netboot-check XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 netboot-bundle XLEN=32 RAPT_CONFIG=small
make -C fpga/arty-a7-t100 netboot-load XLEN=32 RAPT_CONFIG=small
```

The fixed netboot profile selects DDR3, 100 Mb/s onboard Ethernet, 20 MHz CPU,
BIOS and a matching 256 MiB Linux memory map. It uses the shared
[netboot workflow](../litex/NETBOOT.md), including explicit host-interface and
UART selection. The board has no onboard SD card. The BIOS waits for
a command; use `netboot` or `serialboot` to start the selected transport.

The supplied Linux payloads use the GC ISA. A preset such as `chip32-small`
without an FPU needs a matching soft-float kernel/userspace and ISA description;
the supplied GC payload is not a valid Linux configuration for that preset.
Generating a BIOS, DTB or TFTP bundle does not demonstrate DDR calibration,
Ethernet traffic or a Linux login on physical hardware.

## Verification and preset evaluation

`make -C fpga/arty-a7-t100 test` checks clock separation, sampled JTAG edges,
memory geometry, CSR export and the netboot profile. Evaluate device resources
for all presets, with output outside the checkout:

```sh
python3 fpga/common/scripts/evaluate_configs.py --output /path/to/evaluation \
  --boards arty rk cu08 --parallel 2
```

The evaluator archives immutable RTL, constraints, tool/source identities,
reports and checkpoints per board/preset/XLEN, plus `summary.md` and `summary.json`.
These are cluster OOC results. Add board peripherals and complete a board build
before treating a resource fit as a loadable image.
