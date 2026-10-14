# Native MLK-CU08-KU15P

Standalone Raptor support for `xcku15p-ffva1156-2-e`, using SystemVerilog, XDC and batch
Vivado. Supports RV32/RV64 with BRAM or DDR4 main memory, a boot ROM, scratch
SRAM, an 8250-compatible UART, CLINT and PLIC. No LiteX, Migen or LiteX BIOS
environment is required. The native target provides UART boot; SD, Ethernet,
PCIe and storage drivers are not included.

All commands below run from the **repository root**.

## Prerequisites

- Vivado with support for the target Kintex UltraScale+ device and the DDR4/AXI IP.
- Python 3, GNU Make, `riscv64-unknown-elf-gcc`, `riscv64-unknown-elf-objcopy`
  and the device-tree compiler `dtc` on `PATH`. The compiler must support the
  selected RV32/RV64 architecture and ABI.
- Verilator for RTL preprocessing in every build, and for `lint`, `test` and `sim`.
- For board use: a powered board, a working Vivado JTAG connection and access
  to its UART device. Install the cable drivers required by the JTAG adapter.

Generate the instruction decoders from the repository's Scala sources with
`make verilog` if they are missing. The native Python tools use the standard
library and need no additional Python packages.

## Build and program

The defaults are RV64, preset `small`, 50 MHz CPU clock and 128 KiB BRAM.
Start with BRAM to exercise the UART and loader without DDR calibration:

```sh
make -C fpga/mlk-cu08-ku15p build XLEN=64 MEMORY=bram
make -C fpga/mlk-cu08-ku15p info XLEN=64 MEMORY=bram
make -C fpga/mlk-cu08-ku15p load XLEN=64 MEMORY=bram
```

For DDR, generate and elaborate the vendor IP before the full build:

```sh
make -C fpga/mlk-cu08-ku15p ip-check XLEN=64 MEMORY=ddr
make -C fpga/mlk-cu08-ku15p build XLEN=64 MEMORY=ddr
make -C fpga/mlk-cu08-ku15p info XLEN=64 MEMORY=ddr
make -C fpga/mlk-cu08-ku15p load XLEN=64 MEMORY=ddr
```

Use the same configuration options for `build`, `info` and `load`. `load`
checks source/configuration freshness, artifact hashes and a passing routed
build, then requires exactly one matching FPGA on JTAG. Programming is volatile;
it does not write configuration flash or automatically rebuild stale outputs.

Root shortcuts are also available; select the preset explicitly:

```sh
make fpga-syn FPGA_BOARD=mlk-cu08-ku15p XLEN=64 MEMORY=bram RAPT_CONFIG=small
make fpga-pnr FPGA_BOARD=mlk-cu08-ku15p XLEN=64 MEMORY=ddr RAPT_CONFIG=small
```

## Configuration and outputs

| Option | Default | Meaning |
|---|---|---|
| `XLEN` | `64` | `32` or `64` |
| `RAPT_CONFIG` | `small` | CPU preset from `hdl/configs/` |
| `MEMORY` | `bram` | `bram` or `ddr` main RAM |
| `CLOCK_MHZ` | `50` | CPU clock target: `25`, `50` or `100` MHz |
| `RAM_BYTES` | `131072` | BRAM main RAM size; power of two, 16 KiB–1 MiB |
| `USE_RESET_BUTTON` | `0` | Set to `1` to enable the active-low reset button |
| `DDR_PART` | `MT40A512M16HA-083E` | MIG memory-part selection; see board details below |
| `JOBS` | `4` | Tool parallelism, 1–32 |
| `CROSS` | `riscv64-unknown-elf-` | Cross-toolchain prefix |
| `VIVADO` | `vivado` | Vivado executable |
| `PYTHON` | `python3` | Python executable used by Make |
| `BUILD_ROOT` | This board directory's `build/` | Output root; use a separate root for each board |

`RAM_BYTES` controls BRAM mode only. DDR maps 1 GiB for RV32 and 2 GiB for
RV64. Larger CPU presets, RAM sizes and higher clocks require their own
capacity and timing checks. `CLOCK_MHZ` specifies a constraint, not measured Fmax.

`make info` prints JSON containing the selected configuration and output path.
Each configuration uses its own directory, protected by a build lock. Outputs
include ROM files `boot.elf/bin/hex`, a sample `payload.elf/bin`, the board's
`native.dts/dtb`, source snapshots, `manifest.json`, logs and reports. A successful
full build also produces `rapt_cu08.bit` and a validated `result.json`.

For software-only updates, `make -C fpga/mlk-cu08-ku15p refresh-software`
with the original build options can retain a passing bitstream only when all
regenerated hardware inputs are byte-identical. Hardware changes require a
new `build`; an accepted refresh retains the original implementation manifest.

## Board interfaces and DDR

| Interface | Connection / behavior |
|---|---|
| CPU reference clock | 100 MHz single-ended, P26, LVCMOS18 |
| DDR reference clock | Separate 100 MHz differential input, N24/M24, DIFF_SSTL12 |
| UART RX/TX | AM11/AN11, LVCMOS33, 115200 8N1 |
| Optional reset | AJ14, active low; disabled by default |
| LEDs 0–4 | AD9/AD8/AE8/AF8/AD10: MMCM lock, reset released, DDR ready, heartbeat, writeback error |
| DDR4 data interface | 64 bits; 512-bit MIG AXI interface |

Power-on reset is always enabled. Enable the reset button only after verifying
that the board input is idle high. LED polarity depends on the board wiring;
DDR-ready is asserted continuously in BRAM mode. In DDR mode, the CPU remains
in reset until MIG calibration completes. Calibration status is registered in
the UI clock domain before crossing a two-stage CPU-domain synchronizer.

The CPU clock is derived by an MMCM. The DDR profile uses a separate 100 MHz
reference, 1600 MT/s, CL=12/CWL=9 and a 200 MHz UI clock. A vendor AXI converter
handles data-width conversion and the CPU/UI clock crossing.

The default `MT40A512M16HA-083E` is a reference-design proxy, not identification
of the fitted DRAM. Confirm the installed part and geometry before board use.
Changing `DDR_PART` changes only the MIG part selection; it does not adjust
latencies, geometry or pins automatically.

The board top is [rapt_cu08_top.sv](rtl/rapt_cu08_top.sv). Pin assignments are in
[board.xdc](constraints/board.xdc) and [ddr4.xdc](constraints/ddr4.xdc); the DDR
profile is in [create_ip.tcl](ip/create_ip.tcl). The pinout follows the repository's
CU08 platform definition, but building this target does not import LiteX.

## Memory map and software interface

Addresses are generated from `hdl/configs/memory_map.json`:

| Region | Base address | Size / behavior |
|---|---|---|
| CLINT | `0x02000000` | Cluster timer; 1 MHz `mtime` |
| PLIC | `0x0c000000` | Interrupt controller; UART source 1 |
| Scratch SRAM | `0x0f000000` | 8 KiB; includes the ROM monitor's stack |
| UART | `0x10000000` | Byte-spaced 8250 registers, 115200 baud, 8N1 |
| Boot ROM / reset vector | `0x20000000` | 64 KiB, initialized from `boot.hex` |
| Main RAM | `0x80000000` | `RAM_BYTES` in BRAM mode; 1 GiB RV32 / 2 GiB RV64 in DDR mode |

The platform router allows one outstanding read and one outstanding write,
with FIXED/INCR bursts, byte strobes, IDs and response backpressure. Unsupported
bursts, out-of-range accesses and transactions crossing a 4 KiB or region
boundary return DECERR; ROM writes return SLVERR.

The UART has a 16-byte receive queue, a one-byte transmit holding register,
receive/transmit interrupts and overrun/framing status. Line format is fixed
at 8N1; modem loopback and flow control are not implemented. The generated DTB
sets `fifo-size = <1>`, `tx-threshold = <0>` and `no-loopback-test` for the Linux
8250 driver. CPU, UART and timer clock properties are generated together.

## Serial loading

After JTAG programming, the ROM prints `Raptor native CU08 RV64`
(or `RV32`), followed by `RAPT ready`. Close other programs using the serial
port. Set `out` to the `output` path printed by `make info` for the configuration
you loaded, and replace `/dev/ttyUSB1` with the board's actual UART device:

```sh
out=/absolute/path/reported/by/info
python3 fpga/common/scripts/upload.py --port /dev/ttyUSB1 \
  --memtest 0x80000000:0x10000 \
  --image "0x80000000:$out/payload.bin" --entry 0x80000000 --console
```

This destructively tests 64 KiB of main RAM, uploads the sample payload and
expects `NATIVE PAYLOAD PASS`. Reduce the test range if using less than 64 KiB
of BRAM. Add `--wait-ready` when starting the uploader before a reset; omit it
when the ROM monitor is already waiting.

Uploads use CRC32-checked chunks of at most 4096 bytes. The monitor rejects
writes outside main RAM and never jumps automatically after reset or a failed
upload. A failed upload may have modified its destination; upload it again
before requesting execution.

## OpenSBI and Linux

Use DDR mode and a matching RV32/RV64 OpenSBI generic-platform `fw_payload.bin`,
linked at `0x80000000` and containing a kernel with an embedded initramfs.
Use this build's `native.dtb` for the board description. Build and load the DDR
configuration, then set `out` to its output directory before uploading:

```sh
python3 fpga/common/scripts/upload.py --port /dev/ttyUSB1 \
  --image "0x80000000:/path/to/fw_payload.bin" \
  --image "0x83f00000:$out/native.dtb" \
  --entry 0x80000000 --dtb 0x83f00000 --console
```

Keep the firmware/kernel image and DTB within main RAM and non-overlapping;
choose another DTB address if the image extends into `0x83f00000`. The uploader
rejects overlapping supplied files. The ROM executes `fence rw,rw` and `fence.i`,
then enters M-mode with `a0=0`, `a1=DTB`, `satp=0` and interrupts disabled.

Default boot arguments are `console=ttyS0,115200 earlycon=sbi`. For different
arguments, copy `native.dts`, edit the copy and compile it with `dtc -I dts -O dtb`;
upload that DTB instead. UART transfer of large images is slow at 115200 baud.

## Verification and troubleshooting

These targets describe what to check for the selected configuration; they do
not certify any preset, clock target or physical board in advance.

| Target | Scope |
|---|---|
| `prepare` | Generate firmware, DTB and an immutable RTL/configuration snapshot |
| `lint` | Verilator checks of the native SoC |
| `test` | Host tools, pin/map consistency, UART and AXI regressions |
| `sim` | CPU/ROM serial upload, CRC/range rejection, RAM test and payload execution |
| `ip-check` | Elaborate the board top with generated MIG and AXI IP |
| `peripheral-synth` | Synthesize router, local memories and UART; check BRAM inference |
| `synth` | Whole-board synthesis and estimated resource/timing reports |
| `build` | Full implementation, routed setup/hold and clock/I/O constraint checks, DRC and bitstream |

For example, run the functional matrix with a selected preset:

```sh
for xlen in 32 64; do
  for memory in bram ddr; do
    make -C fpga/mlk-cu08-ku15p test sim \
      XLEN="$xlen" MEMORY="$memory" RAPT_CONFIG=small
  done
done
```

DDR simulation uses a delayed AXI RAM model, not a physical DDR model. For a
focused boot waveform, run `python3 fpga/mlk-cu08-ku15p/build.py --xlen 64 --memory ddr --trace sim`.
Review `timing_summary.rpt`, `check_timing.rpt`, `cdc.rpt`, `drc.rpt` and
`utilization.rpt` for the exact source/configuration in `manifest.json`.
Peripheral synthesis excludes the CPU and board clock/DDR infrastructure.
A passing build gate does not establish CDC sign-off, DDR calibration or
successful software execution on the physical board.

- **No serial banner:** check power, UART device and 115200 8N1 settings. In DDR
  mode, check DDR-ready first: the CPU is held in reset until calibration.
- **DDR-ready stays low:** check reference clocks, reset, fitted memory part,
  pinout and MIG configuration; use BRAM mode to isolate UART/CPU bring-up.
- **Upload errors:** close competing serial clients, check addresses and RAM
  size, then retry the upload before executing it.
- **`load` rejects the build:** use matching options and rebuild after source
  changes. Use `refresh-software` only when its byte-identical hardware check passes.
