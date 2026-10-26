# Native MLK-CU08-KU15P

Raptor support for `xcku15p-ffva1156-2-e`, using SystemVerilog, XDC and batch
Vivado. The native SoC supports RV32/RV64 with BRAM or DDR4 main memory, a boot
ROM, scratch SRAM, an 8250-compatible UART, CLINT and PLIC. The default native
build includes DDR4 and the CM005 A↔B Ethernet forwarder. Its two-port forwarding
path runs independently of CPU execution and DDR calibration; the native UART
remains the CPU console. `CM005_ETHERNET=1` adds a CPU NIC through the existing
three-port switch. The native `ubuntu-*` targets select that NIC and NFS root
boot. This directory is a standalone build; the LiteX SoC for the same board
is a separate flow in `fpga/litex`.

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
`make verilog` if they are missing. With `CM005_BRIDGE=0`, the native Python tools use the standard library.
The default CM005 generator additionally uses the repository Migen, LiteX,
LiteEth and LiteDRAM sources under `third_party/enjoy-digital/` and the Python
environment at `fpga/litex/.venv/bin/python`. The generator fingerprints and
imports those checkout sources, including dirty changes.

## Build and program

The defaults are RV64, preset `small`, 50 MHz CPU clock, DDR4 and
`CM005_BRIDGE=1`. A minimal CPU/UART build can explicitly disable the bridge
and use BRAM to bypass DDR calibration:

```sh
make -C fpga/mlk-cu08-ku15p build XLEN=64 MEMORY=bram CM005_BRIDGE=0
make -C fpga/mlk-cu08-ku15p info XLEN=64 MEMORY=bram CM005_BRIDGE=0
make -C fpga/mlk-cu08-ku15p load XLEN=64 MEMORY=bram CM005_BRIDGE=0
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
build, then requires exactly one matching FPGA on JTAG unless `HW_TARGET`
selects one. Programming is volatile; it does not write configuration flash or
automatically rebuild stale outputs.

Add `XLEN=32` for RV32. `make -C fpga/mlk-cu08-ku15p help` lists every target
and variable. Native builds default to DDR and A↔B forwarding; their CM005 block
preserves the external KU5P network path while KU15P runs its native
CPU/DDR/console. Add `CM005_ETHERNET=1` for the native CPU NIC, or use
`ubuntu-*` below.

The LiteX SoC, including the fixed DDR4 plus CM005 Ethernet netboot profile, is
a separate flow in `fpga/litex`; this directory does not build it. For example,
`make -C fpga/litex FPGA_BOARD=mlk_cu08_ku15p fpga-netboot-rv64-build`. See the
[netboot workflow](../litex/NETBOOT.md#fixed-cu08-and-rk-end-to-end-targets).

## Native Ubuntu 24.04 NFS root

Follow the [shared Ubuntu workflow](../common/UBUNTU.md). `ubuntu-bitstream`
defaults to RV64 `middle-cache`, DDR4, 50 MHz, `CM005_BRIDGE=1` and
`CM005_ETHERNET=1`. The CPU uses the Linux LiteEth ABI on a virtual third
CM005 port. CPU queue congestion and virtual-PHY reset do not block/reset the
A/B forwarding path. The loader MAC/IP are distinct from KU5P; prepare a
separate NFS root and reserve the board's loader address.

```sh
make -C fpga/mlk-cu08-ku15p ubuntu-test
make -C fpga/mlk-cu08-ku15p ubuntu-bitstream
make -C fpga/mlk-cu08-ku15p ubuntu-kernel JOBS=8
make -C fpga/mlk-cu08-ku15p ubuntu-rootfs UBUNTU_SSH_KEY=/path/to/your.pub
make -C fpga/mlk-cu08-ku15p ubuntu-bundle ubuntu-check
make -C fpga/mlk-cu08-ku15p ubuntu-serve
# Reprogram only after work depending on this board's A/B bridge has finished.
make -C fpga/mlk-cu08-ku15p ubuntu-load HW_TARGET='*/<KU15P-JTAG-ID>'
make -C fpga/mlk-cu08-ku15p ubuntu-boot UART_PORT='/dev/serial/by-id/<KU15P-UART>'
```

## Configuration and outputs

| Option | Default | Meaning |
|---|---|---|
| `XLEN` | `64` | `32` or `64` |
| `RAPT_CONFIG` | `small` | CPU preset from `rtl/configs/` |
| `MEMORY` | `ddr` | `bram` or `ddr` main RAM |
| `CM005_BRIDGE` | `1` | CM005 A↔B forwarding; requires `CLOCK_MHZ=50` |
| `CM005_ETHERNET` | `0` | Add the native CPU NIC; enabled by `ubuntu-bitstream` |
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
CU08 platform definition.

## Memory map and software interface

Addresses are generated from `rtl/configs/memory_map.json`:

| Region | Base address | Size / behavior |
|---|---|---|
| CLINT | `0x02000000` | Cluster timer; 1 MHz `mtime` |
| PLIC | `0x0c000000` | Interrupt controller; UART source 1 |
| Scratch SRAM | `0x0f000000` | 8 KiB; includes the ROM monitor's stack |
| UART | `0x10000000` | Byte-spaced 8250 registers, 115200 baud, 8N1 |
| CM005 diagnostics | `0x18000000` | 64 KiB MMIO window when enabled; generated register map |
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

## Native CM005 forwarding

Connect the server/shared-network interface to CM005 A and KU5P to CM005 B.
The datapath, PHY pinout, queues and receive/transmit timing contract are shared
with the [standalone bridge](../litex/CM005-BRIDGE.md). The generated child keeps
both PHY clock trees, the shared E8 reset and all six independent TX clock
buffers. Native board constraints own the 100 MHz reference, UART and DDR pins;
CM005 timing queries are scoped to the child after synthesis. A full native
build gates the bitstream on routed setup/hold, clock/I/O coverage, DRC, clock
methodology and the A-port sampling aperture. The six asynchronous A-port
sampler inputs retain their 2 ns datapath-only bound and 0.025–0.775 ns routed
relative sampling window. The coverage gate recognizes only those six named
partial-input entries and checks each active 2 ns path requirement; ordinary
RGMII ports must have complete setup/hold constraints. MDIO inputs use two-flop
synchronizers, and only MDIO/MDC/shared-reset management pins receive explicit
asynchronous I/O exceptions. See [AMD UG903 on datapath-only hold behavior](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Consequences-of-Setting-Maximum-Delay-or-Minimum-Delay-Constraints-on-a-Path).

The CPU remains held in reset until DDR calibration completes, while the
forwarder uses the native 50 MHz clock and board reset. Re-entering the ROM or
running CPU software leaves forwarding active. FPGA reprogramming or board
reset briefly interrupts the KU5P link. Keep a verified previous bridge bitstream
available when testing a new integrated image.

`cm005-generated/cm005_registers.json` and `.h` in the selected build describe
registers accessed with aligned 32-bit loads/stores: identity `0x434d3035`, version, PHY reset/MDIO controls, MAC
preamble/CRC counts, and per-direction received/forwarded/dropped/error/queued
counts. Independent read/write addresses and byte strobes match the native
peripheral bus. The block has no CPU packet interface or interrupt source.

With the native ROM waiting at `RAPT ready`, capture a diagnostic snapshot:

```sh
python3 fpga/mlk-cu08-ku15p/scripts/cm005_native_probe.py \
  --build "$out" --port /dev/ttyUSB1 --output /tmp/cu08-before
```

This compiles and uploads a small matching-XLEN payload at `0x80000000`, uses a
stack below `0x80020000`, reads CM005 MMIO and Clause-22 PHY registers, and returns
to the ROM without resetting the bridge. It overwrites that DDR payload/stack
area; run it before loading another OS. `--build-only` prepares the payload
without opening the UART. Compare `status.json` snapshots around simultaneous
bidirectional traffic, check CRC/error deltas and payload hashes, and verify
that KU5P retains its boot identity and network access. Invalid PHY IDs are
reported explicitly; they do not establish link status.

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
focused boot waveform, run `make -C fpga/mlk-cu08-ku15p sim XLEN=64 MEMORY=ddr TRACE=1`.
Review `timing_summary.rpt`, `check_timing.rpt`, `cdc.rpt`, `drc.rpt` and
`utilization.rpt` for the exact source/configuration in `manifest.json`.
The output directory also contains `index.html` for browsing all Vivado
reports and `README.md` with synthesis and implementation resource tables.
The native `synth` and `build` actions regenerate both summaries, including
partial reports after a failed Vivado run.
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
