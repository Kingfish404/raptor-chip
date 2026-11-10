# Shared 25-signal emulation and KU5P port plan

The [CU08 KU15P fixture](../chip25/README.md) implements the shared composition
and synthesizable Flash slave. The older `fpga/bringup/cu08` fixture remains a
separate private-link carrier. Physical Arty validation and KU emulation results
must be recorded separately. KU5P board integration remains planned below.

The common processor endpoint is `rapt_chip_pads25`. Preserve `chip32-small`,
RV32, the native 10 MHz clock/half period 8, and physical storage/write limits
8 MiB/8 MiB/16 MiB. Keep chip-local UART0/UART1/GPIO unchanged in both modes.
Use the retained SBA boot-control register; IRQ is always an interrupt.

## Shared logic and board boundaries

| Component | Source | Responsibility |
| --- | --- | --- |
| Processor, pads and local I/O | `synth/configs/io25/rtl/` | Actual chip, both backends |
| Private bridge target | `fpga/common/rtl/rapt_xspi_target.sv` | Existing link protocol to AXI |
| Composition | `fpga/common/rtl/rapt_chip25_fixture.sv` | Shared Flash/private-link selection |
| Board RAM/console/loader | Arty blocks reused by the composition | Existing private-link service |
| NOR emulation target | `fpga/common/rtl/rapt_xspi_flash_target.sv` | Pin-level 1S/8D flash slave |
| Board wrappers | Board clock and XDC files | Clock, reset, UART/JTAG/GPIO pin mapping |

The flash slave receives only CK/CS/DQ/reset and returns DQ/DS. It must not
recognize CPU AXI requests or bypass chip PHY transactions. Bridge and Flash
targets share the chip pins with exclusive ownership selected through JTAG
and applied at drained core reset. The physical external Flash pins remain unused in an emulation build.

KU15P uses the existing CU08 100 MHz reference and connector constraint sources,
with a related 10 MHz chip clock. Its wrapper maps onboard UART1 and explicit
CPU JTAG/UART0/GPIO. The emulation pinout repurposes serial contacts; disconnect
the physical chip module. Clock/reset outputs to that module are held low.

## NOR emulation contract

Use a 128 KiB BRAM backing window starting at physical `0x800000`. It contains
the boot probe, scratch sector `0x810000` and its neighbours. Report the fixed
MT35X descriptor's identity and SFDP density. Reads outside the backing window
return erased bytes; mutations outside it fail explicitly. Never truncate high
address bits into the BRAM index or alias a lower physical partition into it.

Implemented contract:

- Single-line mode-0 startup, ID, SFDP, SR/FSR, WREN/WRDI and volatile register
  write/readback. Support four-byte address selection and octal+DS entry last.
- Repeated command extension, four MSB-first address bytes, even array reads,
  16 read-latency clocks, eight status-latency clocks and both DS edges.
- `FD/8E/21` read/program32/erase4k with WEL/WIP, NOR 1-to-0 behavior, whole
  sector erasure, error flags and no automatic retry. Write BRAM one byte/word
  per board clock so erase/program infer real RAM rather than resettable flops.
- Shared hardware reset restores the startup protocol while preserving array
  contents. A reset during an operation must have an explicit tested outcome.
- Separate one-way enables for each DQ lane, released return pins outside read
  phases, and DS released in the private bridge mode.

At 100 MHz board clock and 625 kHz CK there are 80 board clocks per half cycle.
Synchronize CK/CS and capture stable DQ before interpreting an edge. Bound target
launch latency and test it against the chip's existing receiver envelope; do not
replace the source-synchronous return with a combinational AXI shortcut.

## Validation

The target test connects the real `rapt_spi_nor` to the synthesizable slave. It
covers initialization, a full random sector, page/window boundaries, neighbour
preservation, out-of-window mutations, reset retention and interrupted erase.
The composition simulator runs the real 25-signal CPU with the existing native
pin JTAG host for boot, I/O and scratch tests. Keep this decoder independent of
the verification model. These tests do not establish general JESD251 compliance.

Synthesize and time the slave alone before the common composition. Build the
KU15P composition only after both pass. Retain RTL/constraint hashes, tool version,
timing, utilization, clock/CDC/DRC reports, functional netlist and bitstream outside
the repository. A KU bitstream or simulation result must be recorded separately
from physical Arty evidence.

## RK KU5P integration

Add an RK wrapper around the same composition after the KU15P configuration is
qualified. Use the board's existing differential 200 MHz reference, generate
related 100 MHz board and 10 MHz chip clocks, and use its device/package from
`fpga/rk-xcku5p-f`. The slave and private-link RTL need no board pin knowledge.

Select UART1, UART0, three GPIO contacts and the four CPU JTAG contacts from the
RK constraint sources and connector documentation. Confirm voltage, direction
and exclusive ownership before assigning contacts. Do not copy CU08 pin numbers.
Keep unused physical Flash pins released and any attached chip isolated from
the FPGA emulation endpoints.

Run the target test and shared CPU simulation, then export and time the target
before the full RK build. Preserve the same descriptor, backing window, guard,
reset semantics and ROM-XIP boot probe. A separate RK routed build and hardware
receipt are required before reporting that board as validated.
