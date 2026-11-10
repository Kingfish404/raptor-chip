# Shared 25-signal chip emulation

This fixture runs the actual `rapt_chip_pads25` with a synthesizable xSPI NOR
slave on CU08 KU15P. It uses `chip32-small`, RV32, a 10 MHz chip clock, a related
100 MHz board clock and the legacy reset-alias compatibility configuration in the
[Arty bring-up runbook](../arty-a7-t100/CHIP25.md). DDR and vendor memory IP are
not required. FPGA configuration initializes the emulated Flash boot image.

The shared composition is [rapt_chip25_fixture.sv](../common/rtl/rapt_chip25_fixture.sv).
It preserves chip-local UART0/UART1/GPIO and the existing common private link
target. The optional `MODE=bridge` composition reuses the Arty board RAM, loader
and console; qualify that mode separately. `MODE=flash` is the default and the
configuration exercised by the native simulation commands below.

## Flash and memory contract

The slave interprets real CK/CS/DQ edges and returns DQ/DS. CPU requests always
pass through the chip's NOR controller and PHY. The descriptor is MT35X ID
`2c5b19`, repeated command extension, four address bytes, 16 read-latency clocks,
`FD` array read, `8E` four-byte program and `21` 4 KiB erase. Single-line startup,
volatile configuration, SR/FSR, WEL/WIP, NOR 1-to-0 writes and reset are modeled.
This is the fixed chip descriptor's command subset, rather than a general Flash
device model.

| Region | Behavior |
| --- | --- |
| Physical `0x800000..0x81ffff` | 128 KiB BRAM backing, initialized by `flash.hex` |
| Other physical addresses | Reads return `ff`; mutations report an error |
| Chip write guard | Physical `[0x800000, 0x1000000)` |
| Chip reset alias | `0x20000000` maps to physical `0x800000` |
| Explicit XIP window | `0x30000000` maps to physical `0x800000` |
| Chip-local RAM | 8 KiB at `0x0f000000` |
| Local UART0/UART1/GPIO | `0x10000000` / `0x10000100` / `0x10000200` |

The BRAM index never aliases high physical addresses into the backed window.
Target reset preserves bytes; a reset during program/erase abandons the remaining
operation and retains bytes already changed. FPGA reconfiguration reloads the
initial image. HEX indices address the backing store: physical `0x800000` is
`@00000000`. The supplied image is raw reset-alias code. Program and erase use a
synchronous RAM port, including explicit
read/modify/write for programming. The target maps to 32 RAMB36E2 blocks.

The target samples pins at 100 MHz. The chip's half period of eight 10 MHz
cycles gives 625 kHz CK and 80 board clocks per half cycle. This configuration
does not emulate the maximum frequency or analog behavior of a physical Flash.

## Build and simulate

Use the repository's generated decoders, Yosys with Slang, Verilator, the RISC-V
cross compiler and Vivado. No installation is performed by this flow. Keep each
configuration's output directory outside the checkout. Check available memory
and other Vivado jobs before implementation; the launcher defers when resources
or a global process inventory are unavailable.

```sh
RUN_DIR=/path/to/external/chip25-run
make -C fpga/chip25 target-test sim export BUILD_ROOT="$RUN_DIR" JOBS=4
make -C fpga/chip25 build BUILD_ROOT="$RUN_DIR" JOBS=4 VIVADO=vivado
```

`target-test` exercises the real `rapt_spi_nor` against the slave: a complete
random sector, page and backing-window boundaries, NOR behavior, neighbours,
out-of-range mutations, retained reset data and interrupted erase. `export`
produces a source manifest, mapped design and snapshotted Tcl/XDC/clock inputs.
Flash exports require a mapped return path from the target's DS register into
the chip receiver; a constant or missing DS connection fails export.
`build` additionally produces `rapt_chip25.bit`, routed reports, checkpoints,
functional netlists and a matching `artifacts.json`. `synth` stops after synthesis.

The simulator reuses the Arty pin JTAG adapter and native host:

```sh
python3 -m tools.bringup.native \
  --sim "$RUN_DIR/sim/obj/native-sim" --image "$RUN_DIR/sim/flash.hex" \
  --boot-bin "$RUN_DIR/sim/programs/native-boot.bin" \
  --output "$RUN_DIR/boot" boot
python3 -m tools.bringup.io25 \
  --sim "$RUN_DIR/sim/obj/native-sim" --image "$RUN_DIR/sim/flash.hex" \
  --ram-bytes 256 --output "$RUN_DIR/io25"
python3 -m tools.bringup.native \
  --sim "$RUN_DIR/sim/obj/native-sim" --image "$RUN_DIR/sim/flash.hex" \
  --offset 0x810000 --words 16 \
  --backup "$RUN_DIR/originals" --output "$RUN_DIR/scratch" scratch
```

Simulation normally accelerates the two startup waits. For the boot replay, set
`FULL_WAITS=1` with `make sim` in a separate `BUILD_ROOT` and give the native CLI
`--timeout 600` to retain production waits. I/O simulation
checks GPIO pad self-read, both UART register files, RAM compare/restore and
precise single step. UART wire tests need the explicitly selected physical
ports, as described in the Arty runbook.

For a target-only 100 MHz implementation estimate, first run `target-export`.
From that output directory, run Vivado batch with `inputs/build.tcl -tclargs target`.
Its 2 ns maximum input/output and 0.2 ns minimum input allocations are OOC
environment assumptions. The full fixture times the actual related board/chip
paths. Inspect `timing.rpt`, `check_timing.rpt`, `cdc.rpt` and `drc.rpt`; external
asynchronous UART/JTAG/GPIO controls have a 20 ns data-path budget and hold waiver.
Their partial input-delay diagnostics do not qualify an external interface.

## CU08 connections

Use this pinout with the physical chip module disconnected: several released
serial contacts are repurposed for FPGA emulation debug. The wrapper also holds
the physical chip clock and reset outputs low. The onboard UART uses UART1 in
Flash mode (57600 baud for the boot probe); bridge mode uses its packet monitor
at 115200 baud. External debug signals use 1.8 V.

| Function | FPGA pin | Existing connector signal |
| --- | --- | --- |
| 100 MHz reference / reset | P26 / AJ14 | Board oscillator / reset |
| Onboard UART RX / TX | AM11 / AN11 | Board USB UART, 3.3 V |
| Physical chip clock / reset | F18 / F17 | Held low |
| UART0 RX / TX | B12 / A19 | DIAG / DQ3 |
| CPU JTAG TCK / TMS / TDI / TDO | D15 / E15 / L18 / C14 | DQ4 / DQ5 / DQ6 / DQ7 |
| GPIO0 / GPIO1 / GPIO2 | B16 / B17 / A18 | DQ0 / DQ1 / DQ2 |

CPU JTAG is separate from FPGA configuration JTAG. There is no hardware programmer
in this directory. Source simulation and a routed bitstream remain distinct
from testing on a KU board. Keep run-specific measurements and receipts outside
the repository.

The [shared architecture and KU5P port plan](../common/CHIP25-PLAN.md) identifies
the remaining board-specific clock and pin work for RK KU5P.
