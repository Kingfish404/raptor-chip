# Arty A7-100T octal-link test platform

This design runs `rapt_chip_pads` from the
[pin-limited chip configuration](../../synth/configs/pin-limited/README.md)
with the RV32 `chip32-small` preset, including `RAPT_NO_FPU`. The SoC reaches memory and
devices over the project's octal SDR link. A board half terminates that link and
supplies memory, console, finisher and an external MT35X octal DDR flash backend.

The default `JOIN=internal` uses FPGA routing and a programmable propagation
delay. `JOIN=pins` is a separate bitstream with two independent Pmod interfaces.
The existing fixture has flash and JTAG wiring; it has no Pmod link jumpers.

## Clocks and controls

| Clock | Frequency | Function |
| --- | ---: | --- |
| Reference | 100 MHz | Arty oscillator |
| SoC | 20 MHz | Pad top, core and oversampled JTAG |
| Board | 100 MHz | Link target, BRAM, UART and host commands |
| Flash engine | 10 MHz | Port of the MCU MT35X serial engine |
| External flash CK | 5 MHz | Engine clock / 2 while a frame is active |

Link SCLK is 2.5 MHz after reset and at most 5 MHz at half period 2. The target
therefore oversamples it by at least 20. JTAG defaults to 500 kHz; keep TCK below
2.5 MHz. The MMCM clocks remain related in timing analysis.

BTN0 resets the MMCM and the board, including flash hardware RESET# recovery.
BTN1 resets the SoC while preserving board RAM and an accepted flash operation.
SW0 selects RAM (0) or flash (1). SW0=1 starts autonomous boot after a 10 ms
board startup interval. With SW0=0, the SoC waits for the UART loader.

| LED | Meaning |
| --- | --- |
| 0 | MMCM lock |
| 1 | SoC reset released |
| 2 | Divided DIAG activity |
| 3 | Recent link frame activity |

## Existing 3.3 V fixture

All signals use LVCMOS33. Connect probe voltage reference to 3.3 V and share
ground. Leave probe nRESET/nTRST disconnected; the SoC TAP resets through TMS.
The probe connector pin numbers depend on its breakout; use the signal labels
below. Do not connect a 5 V signal.

| Function | ChipKIT signal | FPGA pin | Connected endpoint |
| --- | --- | --- | --- |
| JTAG TCK | ck13 | P17 | CMSIS-DAP TCK / SWCLK |
| JTAG TMS | ck12 | R17 | CMSIS-DAP TMS / SWDIO |
| JTAG TDI | ck11 | U18 | CMSIS-DAP TDI |
| JTAG TDO | ck10 | V17 | CMSIS-DAP TDO |
| UART RX | ck8 | N15 | 3.3 V UART adapter TX |
| UART TX | ck7 | T16 | 3.3 V UART adapter RX |
| Flash CK | ck27 | V16 | MT35X CK |
| Flash CS# | ck29 | R10 | MT35X CS# |
| Flash RESET# | ck26 | U11 | MT35X RESET# |
| Flash DQS | ck28 | M13 | MT35X DQS |
| Flash DQ7 | ck35 | N16 | MT35X DQ7 |
| Flash DQ6 | ck36 | N14 | MT35X DQ6 |
| Flash DQ5 | ck37 | U17 | MT35X DQ5 |
| Flash DQ4 | ck39 | R18 | MT35X DQ4 |
| Flash DQ3 | ck38 | T18 | MT35X DQ3 |
| Flash DQ2 | ck41 | N17 | MT35X DQ2 |
| Flash DQ1 | ck34 | R16 | MT35X DQ1 |
| Flash DQ0 | ck40 | P18 | MT35X DQ0 |
| Reference | 3V3 | — | Probe VTref; flash and UART 3.3 V reference |
| Ground | GND | — | Probe, flash and UART ground |

The scripts open only the devices you name. `RAPT_PROBE_SERIAL` selects the
CMSIS-DAP probe on the SoC's JTAG pins (the hardware scripts pass it to OpenOCD as
`-c "set RAPT_PROBE_SERIAL ..."`; `tap.cfg` refuses to run without it), and
`RAPT_ARTY_SERIAL` (or `program.py --serial`) selects the one Arty whose volatile
configuration is programmed. The UART is the same DAPLink adapter's virtual COM
port on ck8/ck7. Select it explicitly:

```sh
export RAPT_PROBE_SERIAL=<cmsis-dap-serial>
export RAPT_ARTY_SERIAL=<digilent-serial>
UART="/dev/serial/by-id/usb-ARM_DAPLink_CMSIS-DAP_${RAPT_PROBE_SERIAL}-if00"
```

The Arty on-board quad-SPI configuration flash is not connected to this design.
There is no STARTUPE2 or configuration-memory programming path.

## Optional Pmod pin loopback

Fit these wires only for `JOIN=pins`. Both halves still share clocks and reset,
but their link data, SCLK and CS# cross only the listed FPGA pins.

| Signal | SoC side | FPGA pin | Board side | FPGA pin |
| --- | --- | --- | --- | --- |
| SCLK | JA1 | G13 | JC1 | U12 |
| CS# | JA2 | B11 | JC2 | V12 |
| DQ0 | JA3 | A11 | JC3 | V10 |
| DQ1 | JA4 | D12 | JC4 | V11 |
| DQ2 | JA7 | D13 | JC7 | U14 |
| DQ3 | JA8 | B18 | JC8 | V14 |
| DQ4 | JA9 | A18 | JC9 | T13 |
| DQ5 | JA10 | K16 | JC10 | U13 |
| DQ6 | JB1 | E15 | JD1 | D4 |
| DQ7 | JB2 | E16 | JD2 | D3 |
| Ground | JA5/JA11 | GND | JC5/JC11 | GND |

Header numbers are physical Pmod positions, not zero-based signal indices.

## Memory and flash interface

| CPU address | Size | Function |
| --- | ---: | --- |
| `0x00100000` | 4 bytes | `sifive,test`: `0x5555` success; failure code in bits 31:16 |
| `0x00100800` | 4 bytes | Link half period (served locally), writable 2..15 |
| `0x10000000` | 8 bytes | NS16550-style console TX, divisor, LCR, LSR and scratch |
| `0x10002000` | 512 bytes | Uncached writable flash maintenance registers |
| `0x20000000` | 4 KiB | Boot MROM |
| `0x30000000` | 8 MiB | Read/execute flash window, physical offsets 8..16 MiB |
| `0x80000000` | 256 KiB | Board BRAM |

The maintenance region lies in the SoC's writable device PMA. The flash window
remains read-only to the CPU. The qualified software window ends at physical
16 MiB, following the reference controller's address range. The UART receive
stream is reserved for host commands; CPU console RX and UART interrupts are
not implemented.

Registers are 32-bit and require aligned full-word writes:

| Offset | Register | Meaning |
| --- | --- | --- |
| `0x00` | ID | `0x52504632` |
| `0x04` | STATUS | Busy[0], error[1], trusted ID[2], initialized[3], recovery[4] |
| | | SR[15:8], FSR[23:16], request error[31:24] |
| `0x08` | JEDEC | Must equal `0x002c5b19` |
| `0x0c` | ADDRESS | Physical flash offset, independent of CPU window base |
| `0x10` | LENGTH | Must be 4 for PROGRAM32 |
| `0x14` | COMMAND | See commands below |
| `0x18` | ENGINE_ERROR | Physical engine error, retained for diagnosis |
| `0x1c` | DATA | PROGRAM32 input or raw READ32 result |
| `0x20` | BOOT | Effective boot source, flash in bit 0 |
| `0x24` | ERASE_BYTES | 4096 |
| `0x28` | FIRST | `0x00800000`, first writable physical byte |
| `0x2c` | END | `0x01000000`, exclusive end |

Commands are `0x52410001` ERASE4K, `...02` PROGRAM32, `...03` qualified-ID check,
`...04` acknowledge request error, `...05` raw READ32, and `...06` hardware
RESET# recovery and requalification. Raw reads allow backing up offsets 0 and
`0x10000`. Both register bank and serial engine reject mutations below 8 MiB.
PROGRAM32 cannot cross a word or page boundary; larger writes are split by software.
The serial engine checks SR/FSR before and after mutation, verifies WEL, bounds
timeouts, and invalidates its read buffer. An error is not automatically retried.

`scripts/flash.py` requires the expected ID/geometry. Its session backs up and
compares protected, target and neighbouring sectors. A nonblank target on first
use is refused. Every erase gets a fresh pre-erase backup and a full comparison.
Interrupted writes leave an ownership mismatch for review rather than being adopted.

Boot images have a 16-byte little-endian header: magic `0x52505446`, payload
length, CRC32/IEEE, and RAM entry address. The MROM validates bounds and CRC before
copying to RAM and executing. Bad headers/CRC print a message and use a previously
loaded RAM image; empty RAM prints a loader-wait message. The last 16 RAM bytes
are reserved: `0x8003fff0` selects the link divider; `+4` records its readback.

## Build and simulation

Set output and scratch directories outside the source tree. No reference-project
files are needed to build this vehicle.

```sh
export CROSS_COMPILE=riscv64-elf-
export OUT=/path/to/writable/arty-a7-t100-build
export VIVADO=/path/to/Vivado/bin/vivado
mkdir -p "$OUT/tmp"
export TMPDIR="$OUT/tmp"
make -C fpga/arty-a7-t100 test payloads OUT="$OUT" JOIN=internal
make -C fpga/arty-a7-t100 test-loader test-flash check-host format-check OUT="$OUT"
python3 fpga/arty-a7-t100/scripts/microbench.py --out "$OUT/microbench"
python3 fpga/arty-a7-t100/scripts/regress.py --out "$OUT/internal" \
  --microbench "$OUT/microbench/microbench-test.bin" --timeout 1800
python3 fpga/arty-a7-t100/scripts/regress.py --out "$OUT/internal" --only sba
make -C verification/jtag sba-build RAPT_CONFIG=chip32-small SBA_XLEN=32 \
  BUILD_DIR="$OUT/jtag" JOBS=4
python3 fpga/arty-a7-t100/scripts/test_openocd.py \
  --server "$OUT/jtag/chip-chip32-small-rv32/sba-server" \
  --image "$OUT/internal/jtag_fixture.bin" --out "$OUT/openocd-native"
make -C fpga/arty-a7-t100 build OUT="$OUT" JOIN=internal VIVADO="$VIVADO"
python3 fpga/arty-a7-t100/scripts/test_xsim.py --build "$OUT/internal" \
  --bin "${VIVADO%/vivado}" --out "$OUT/export-sim" \
  --extra-file fpga/arty-a7-t100/rtl/rapt_arty_mapped_cells.v
python3 fpga/arty-a7-t100/scripts/test_xsim.py --build "$OUT/internal" \
  --bin "${VIVADO%/vivado}" --out "$OUT/routed-sim" \
  --netlist "$OUT/internal/routed_funcsim.v" --ideal-clocks
make -C fpga/arty-a7-t100 build OUT="$OUT" JOIN=pins VIVADO="$VIVADO"
```

`SIM_FAST=1` omits tracing and compiles the simulation with C++ -O3; use a
separate OUT directory. The regular build retains waveform support.

The launcher needs the host's global process inventory. It returns 75 if another
Vivado is active, memory is at most 25 GiB, or a sandbox hides that inventory.
Compile jobs and Vivado threads are limited to four. Build evidence includes
source hashes, ROM hash, utilization, setup/hold, clocks, exceptions, DRC, routed
checkpoint, bitstream hash and `artifacts.json`.

The export maps Yosys `$shiftx` cells before writing Verilog. The former flow
emitted negative-base variable part-selects that Vivado mishandled, leaving RAM
addresses at zero and rejecting W/R commands. `test-loader` covers production
115200-baud serial pins, reset, 16/256/4096-byte loads, the RAM limit, and ±2%
host baud error in both RTL and exported Verilog. `--legacy-export --quick`
reproduces the failure. `loader_synth.tcl` and `test_loader.py --netlist` also
check Vivado-mapped gates.

The default export also runs Yosys `synth_xilinx` to map logic and memories to
7-series primitives. A second hardware pass exposed a generic-export/Vivado
synthesis discrepancy: mapped physical source tags lost bit 5, so the first ROM
data load used address zero and the core stalled. The mapped export avoids that
re-inference. `--no-map-xilinx` retains the old generic path for diagnosis only.
The FPGA cell adapters bind falling-edge FFs to standard 7-series cells; unused
cascaded BRAM ports have legal parameters and remain disabled.

`test_xsim.py` checks the exact exported input or a synthesized/routed functional
netlist using vendor primitives and ideal MMCM clocks. Its full test uses real
115200-baud UART pins to load, read, boot and require a finisher plus link frames.
For the internal variant, `--startup` forces only the host run latch and requires
progress beyond
the first ROM data load within 100 us. The short test catches the eight-frame
stall; complete boot remains mandatory. Source-only simulation is insufficient.
The build saves both `synth_funcsim.v` and `routed_funcsim.v` for these checks.
`test_export.py` remains available for generic-export and Icarus diagnostics.
The full vendor test reads the join mode from `sources.json`. For a pin build it
joins SCLK, CS# and DQ only at the testbench's external ports and checks the pin-mode
status value. Use a separate output directory for that run; physical jumper timing
and board validation still require the documented fixture.

`test-flash` uses the serial engine against a strict, delayed MT35X behavioral
model with NOR AND programming and sector erase. It also tests the BRAM substitute
through the same maintenance registers. The board bench uses 20/100/10 MHz and the
real pad top; its accelerated UART is 1 Mbaud. Model program/erase times are
20/100 us for regression speed. Hardware keeps physical SR/FSR polling deadlines.

The ordinary regression covers cpu-tests, all MicroBench test workloads, UART,
flash boot/fallback, firmware flasher, RAM March and divider 2..15. Run `--only step`
for exactly one architectural retirement, successor DPC, and a DPC-write/resume
redirect. The precise-step and SBA/ndmreset debug support is included;
run `--only sba` for pad-level RAM/device access and reset-retention coverage.

## Hardware entry points

Run the scripts under `scripts/hw/` outside the sandbox. `scripts/hw/program.py` verifies the
routed artifact hashes, selects only the authorized Arty, invokes volatile
`program_hw_devices`, and closes its dedicated hw_server. `scripts/hw/cpu.py` captures
console, fresh finisher events and divider readback. `scripts/hw/flash_uart.py` supports
both direct UART maintenance and the firmware flasher. `scripts/hw/boot.py` captures flash
boot across volatile reconfiguration with SW0=1. `scripts/hw/debug.py` runs the fixed
CMSIS-DAP probe via `sudo -n openocd`; `scripts/hw/sba_flash.py` supplies the SBA
flash path. Use a new output directory and `scripts/hw/record.py` to preserve every run.
After programming, run the pre-check before any CPU suite:

```sh
python3 fpga/arty-a7-t100/scripts/hw/loader.py --port "$UART" --build "$BUILD" \
  --output "$RUN/loader"
```

It checks all four hardware address/length cases, then runs `boot_check.bin`.
Boot must produce `BOOT_CHECK_PASS`, a fresh good finisher, nonzero link frames
and divider readback 4 within five seconds. Failures retain live status and
the frame counter before resetting the SoC. CPU suites stop on the first failure.

Create a checked flash image from a prepared binary with:

```sh
python3 fpga/arty-a7-t100/scripts/flash_image.py program.bin program.flash.bin
python3 fpga/arty-a7-t100/scripts/hw/flash_uart.py --port "$UART" --mode program \
  --image program.flash.bin --offset 0x800000 --backup "$RUN/flash-backups" \
  --output "$RUN/flash-program"
```

For GDB register/memory checks and reset-based program loading:

```sh
sudo -n "$(command -v openocd)" -s fpga/arty-a7-t100/scripts \
  -c "set RAPT_PROBE_SERIAL $RAPT_PROBE_SERIAL" -f gdb.cfg
riscv64-elf-gdb program.elf
```

Then use `target extended-remote localhost:3333`, `monitor reset halt`,
`info registers`, `x/4wx 0x80000000`, `load`, `monitor reset halt`, and `continue`.
SBA bypasses caches; reset before and after loading. MROM supplies the RAM entry.
The native `load_image` check in `scripts/hw/debug.py --mode sba` verifies a scratch RAM
copy. The merged debug implementation supports `stepi` and `set $pc`, and cleans
L1D before acknowledging halt. With the dedicated fixture loaded at RAM base,
`set $pc = 0x80000040` followed by `stepi` must report PC `0x80000044`.
Exit with `monitor shutdown`.
