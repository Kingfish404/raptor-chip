# 25-signal chip bring-up on Arty

Both explicit chip fixtures instantiate `rapt_chip_pads25` with `chip32-small`,
RV32 and no FPU. The default `PLATFORM=soc` remains the separate LiteX system.

| Setting | `PLATFORM=octal JOIN=internal` | `PLATFORM=jesd` |
| --- | --- | --- |
| Chip clock | 20 MHz | 10 MHz |
| Boot control | JTAG writes 0, then ndmreset | Default 3: Flash ROM-XIP |
| External flash owner | Board adapter to `rapt_spi_nor` | Actual chip NOR host |
| External CK | 625 kHz, half period 8 | 625 kHz, half period 8 |
| RAM | 256 KiB at `0x80000000` | 8 KiB at `0x0f000000` |
| Reset PC | Board ROM at `0x20000000` | Internal ROM at `0x20000000`, jumps to `0x30000000` |
| Flash image | Length/CRC/entry header, copied to RAM | Raw code linked at `0x30000000` |
| External adapter on ck8/ck7 | Packet monitor, 115200 baud | Local UART0 |
| Onboard USB UART | Local UART1 | Local UART1; supplied boot probe uses 57600 baud |

Both fixtures use the chip's retained [boot control](../../docs/chip.md#boot-control).
IRQ remains an interrupt in both modes. Chip reset restores Flash ROM-XIP.

The [bridge wiring and memory map](OCTAL-LINK.md) and
[native fixture](native/README.md) give pin assignments. UART0 uses ck4/ck3 on
the bridge fixture and ck8/ck7 on the native fixture. UART1 always uses the
onboard UART. GPIO0..2 use ck0..2. CPU JTAG and flash wiring are identical in
both fixtures. No Pmod link jumpers are needed for `JOIN=internal`.

## Build before opening the board

Keep outputs outside the checkout and check available memory before Vivado.
Set `RAPT_ARTY_SERIAL`, `RAPT_PROBE_SERIAL` and both UART paths to explicitly
authorized devices. The programmer filters the hardware server and disables
automatic scan-chain opening before selecting one exact target, following
[AMD UG908](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Advanced-Options).
It programs FPGA SRAM only.

```sh
make -C fpga/arty-a7-t100 PLATFORM=octal export payloads test \
  OUT="$RUN/bridge" JOIN=internal SIM_FAST=1
python3 fpga/arty-a7-t100/scripts/microbench.py --out "$RUN/microbench"
python3 fpga/arty-a7-t100/scripts/regress.py --out "$RUN/bridge/internal" \
  --microbench "$RUN/microbench/microbench-test.bin"
make -C fpga/arty-a7-t100 PLATFORM=octal build OUT="$RUN/bridge" JOIN=internal
make -C fpga/arty-a7-t100 PLATFORM=jesd programs sim build \
  BUILD_ROOT="$RUN/native" JOBS=4
```

Inspect routed timing, I/O route budgets, DRC, fingerprints and the implemented
logic's functional simulation. The native receiver keeps its actual 10 ns output
path acceptance limit even though implementation uses a tighter constraint.
Internal timing does not establish the carrier's electrical margin.

## Repeatable board sequence

1. Volatile-program the bridge build on the selected Arty. Run `hw/loader.py`
   with that build: all W/R boundaries, fresh `BOOT_CHECK_PASS`, finisher `5555`,
   link traffic and divider readback must pass before proceeding.
2. Read MT35X ID `2c5b19`, status and geometry. Back up every complete sector to
   be changed, both neighbours, and the protected sectors at 0 and `0x10000`.
   Compare independent reads and preserve immutable originals. Session helpers
   refuse a nonblank first-use target and persist an in-flight mutation marker.
3. Run CPU cases, MicroBench, RAM March and divider sweep with `hw/cpu.py`.
   Run `hw/debug.py` in basic, step and SBA modes. Through GDB, reset-halt,
   load/verify RAM, read/write registers and memory, step, use a RAM software
   breakpoint, resume, and check RAM retention across reset. Preserve failed logs.
4. Test PROGRAM32/readback/ERASE4K through the bridge monitor, CPU flasher and
   JTAG SBA. Require full-sector blank checks and unchanged neighbours. Execute
   the XIP probe.
5. Restore the owned boot sector to its recorded blank state, then program and
   fully compare the raw native boot probe at physical `0x800000`. Use the
   ROM-XIP build and a probe linked at `0x30000000`; no switch setting is needed.
   Open native UART1 capture before configuring the native bitstream; require a
   fresh `JESD1` signature from the new boot.
6. Through native JTAG, read guard registers and require storage/write limits
   `0x800000/0x800000/0x1000000` before any mutation. Use
   `python3 -m tools.bringup.native ` for probe, fresh boot
   and scratch tests. Require the fixed ROM words and a fresh completion in XIP.
   Use `python3 -m tools.bringup.io25` with both explicitly selected UART ports
   for physical TX/RX, GPIO pad readback, RAM restoration and precise stepping.
   A register-only UART result does not count as a wire test.
7. Exercise native XIP at `0x30000000`, then return to the independent bridge
   reader, read ID again, restore every owned sector and compare protected and
   neighbour sectors against the originals. Keep bit/source hashes and logs.

Never issue an array mutation below physical 8 MiB or at/above 16 MiB on this
fixture. An uncertain operation stops the sequence before another reset,
reconfiguration, erase or program. Inspect its persistent state and actual device
status before choosing a recovery procedure; do not rerun with fresh backups.

The same order applies to a returned chip: validate clocks/reset and pin ownership,
identify flash, read the configured hardware limits, establish sector ownership,
then test debug, memory, peripherals, mutation, XIP and boot. Use the fabricated
chip's actual register limits and clock frequency. ASIC defaults use storage
offset zero; the guarded Arty host CLI intentionally refuses that configuration.
The bridge and native flash ABIs and image formats remain distinct.
