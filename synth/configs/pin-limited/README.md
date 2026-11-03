# Pin-limited chip integration

This is one technology-neutral tape-out integration of the Raptor cluster. It
also supplies the chip side of the [Arty test platform](../../../fpga/arty-a7-t100/README.md).
The reusable processor top is `rapt` in `rtl/rapt.sv`.

```text
rtl/rapt.sv                         reusable cluster
synth/configs/pin-limited/rtl/      chip integration
  rapt_chip.sv                     reset/JTAG/IRQ synchronization and cluster wrapper
  rapt_chip_pads.sv                pad-level top
  rapt_pad.sv                      technology-neutral pad wrappers
  rapt_axi_xspi.sv                 AXI-to-octal-link master
  rapt_xspi_byte.sv                link byte engine
fpga/common/rtl/rapt_xspi_target.sv board-side link target
fpga/arty-a7-t100/                  FPGA validation platform
```

Compile the configuration's five RTL files together with the processor sources
under `rtl/`, with `rtl/rapt_pkg.sv` first. Select the core and memory geometry
using the existing presets in `rtl/configs/`: `chip32-middle-16k`, `chip32-dff`,
or `chip32-small` for the Arty build. These presets configure the processor;
this directory defines its pin and board integration.

The [chip and link manual](../../../docs/chip.md) describes the pins, registers,
protocol, and pad replacement boundary. Technology-specific cells, constraints,
libraries, and implementation results belong in a private workspace.

The maintained build and verification consumers collect this configuration
explicitly:

- `make -C sim/tb verilator-chip-smoke RAPT_CONFIG=chip32-middle-16k`
- `make -C sim/tb verilator-chip-no-fpu`
- `make -C verification/jtag sba-build RAPT_CONFIG=chip32-small`
- `make -C fpga/arty-a7-t100 export`

Add future chip integrations beside this directory, each with its own RTL and
build consumers; keep downstream wrappers outside the reusable `rtl/` tree.
