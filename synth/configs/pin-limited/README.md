# Pin-limited chip integration

This is one technology-neutral tape-out integration of the Raptor cluster. It
also supplies the chip side of the
[Arty octal-link test platform](../../../fpga/arty-a7-t100/OCTAL-LINK.md).
The reusable processor top is `rapt` in `rtl/rapt.sv`.

```text
rtl/rapt.sv                         reusable cluster
synth/configs/pin-limited/rtl/      chip integration
  rapt_chip.sv                     reset/JTAG/IRQ synchronization and cluster wrapper
  rapt_chip_pads.sv                pad-level top
  rapt_chip_backend.sv             exclusive dual-backend AXI and pin ownership
  rapt_pad.sv                      technology-neutral pad wrappers
  rapt_axi_xspi.sv                 AXI-to-octal-link master
  rapt_xspi_byte.sv                link byte engine
  rapt_axi_flash.sv                direct Flash AXI / local RAM / control
  rapt_spi_nor.sv                  legacy SPI / fixed MT35X Profile 1 command engine
  rapt_xspi_frame.sv               1S / 8D transaction PHY with DS sampling
  rapt_spi_byte.sv                 standalone single-lane SPI byte utility
fpga/common/rtl/rapt_xspi_target.sv board-side link target
fpga/arty-a7-t100/                  FPGA validation platform
```

Compile all of the configuration's RTL files together with the processor sources
under `rtl/`, with `rtl/rapt_pkg.sv` first. Select the core and memory geometry
using the existing presets in `rtl/configs/`: `chip32-middle-16k`, `chip32-dff`,
or `chip32-small` for the Arty build. These presets configure the processor;
this directory defines its pin and board integration.

The same elaborated chip contains both backends. Chip reset selects the small
on-chip ROM and Flash XIP. IRQ is PLIC source 1 in both modes. The retained
[boot-control word](../../../docs/chip.md#boot-control) selects the backend and
reset target at the next drained core reset, with two clocks of released pads.
Compile all `.sv` files, including `rapt_chip_boot.sv`; no boot-selection pin or
compile option is needed. JTAG/DM/core reset retain the requested and active word.
See the [direct Flash manual](../../../docs/chip-flash.md)
for wiring, clock configuration, memory map, explicit program/erase commands and
firmware/CPU regressions. In Flash mode `pad_diag` is the DS input; only the locked
bridge mode drives its heartbeat, while reset and switching release it.
The target RESET# shares the external chip reset source. The
[JESD251D contract](../../../docs/chip-xspi.md) describes this bidirectional contact,
fixed descriptor, conservative recovery waits and protected Arty storage parameters.

The [chip and link manual](../../../docs/chip.md) describes the pins, registers,
protocol, and pad replacement boundary. Technology-specific cells, constraints,
libraries, and implementation results belong in a private workspace.

The maintained build and verification consumers collect this configuration
explicitly:

- `make -C sim/tb verilator-chip-smoke RAPT_CONFIG=chip32-middle-16k`
- `make -C sim/tb verilator-chip-no-fpu`
- `make -C verification/jtag sba-build RAPT_CONFIG=chip32-small`
- `make -C fpga/arty-a7-t100 PLATFORM=octal export`

Add future chip integrations beside this directory, each with its own RTL and
build consumers; keep downstream wrappers outside the reusable `rtl/` tree.

The [25-signal integration](../io25/README.md) reuses this chip with optional local
UART/GPIO peripherals and its own pad top. The default 18-signal top keeps
`LocalIo=0` and ties off the extra logical peripheral ports.
