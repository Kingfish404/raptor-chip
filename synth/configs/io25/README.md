# 25-signal chip integration

`rapt_chip_pads25` adds two local UARTs and three GPIOs to the shared pin-limited
chip. Chip reset defaults to on-chip ROM and Flash XIP. The retained
[boot-control register](../../../docs/chip.md#boot-control) selects either serial
backend and reset target at the next drained core reset. IRQ is always PLIC source 1.

The existing `rapt_chip_pads` top retains its 18 signals and external peripheral
path. Its logical `rapt_chip` uses the default `LocalIo=0`. This configuration
sets `LocalIo=1`; its peripheral requests terminate before either serial backend.

| Pins | Count | Function |
| --- | ---: | --- |
| Clock, reset, IRQ | 3 | Shared chip controls |
| Serial clock, chip select, DQ[7:0] | 10 | FPGA bridge or SPI Flash |
| JTAG TCK, TMS, TDI, TDO | 4 | Debug |
| DIAG / DS | 1 | Bridge heartbeat output / Flash read-strobe input |
| UART0 TX/RX, UART1 TX/RX | 4 | Two independent local UARTs |
| GPIO0, GPIO1, GPIO2 | 3 | Input, push-pull or open-drain output |
| Total | 25 | Independent logical signals |

`pad_diag` is bidirectional: only the locked bridge mode drives the heartbeat;
Flash mode uses it as DS input. Chip reset and switching release it.
The xSPI target RESET# shares the external chip reset source. See
[the xSPI interface contract](../../../docs/chip-xspi.md) before board integration.

The top's new scalar pad names are `pad_uart0_tx`, `pad_uart0_rx`, `pad_uart1_tx`,
`pad_uart1_rx`, `pad_gpio0`, `pad_gpio1`, and `pad_gpio2`. Physical cells, duplicated
package contacts, supply routing and protection belong to the implementation
flow. This RTL does not qualify a package or a manufactured chip.

## Local peripherals

| Address | Device | PLIC source |
| --- | --- | ---: |
| `0x10000000..0x10000007` | UART0 | 2 |
| `0x10000100..0x10000107` | UART1 | 3 |
| `0x10000200..0x1000020f` | Three-bit GPIO | None |

The integration reuses `fpga/common/rtl/rapt_native_uart.sv`: byte-spaced 16550
register layout, fixed 8N1 framing, programmable divisor, 16-byte receive FIFO,
and a transmit holding slot. FIFO identification remains disabled so software
does not assume a 16-byte transmit FIFO. Use byte accesses for UART registers.
Aligned halfword and word accesses also select one register; only its low byte
is meaningful. Poll LSR before transmitting. UART RX inputs require idle-high
levels from the board; the new pads have no internal pulls.

Set `CoreClockHz` to the actual chip clock. The default divisor is rounded for
115200 baud; each programmed divisor represents 16 input clocks per serial bit,
with zero interpreted as one. Interrupt enables and FIFO controls follow the
shared UART implementation. IRQ feeds PLIC source 1 in both backends; both local UART interrupts remain available.

GPIO registers require aligned, single-beat 32-bit accesses:

| Offset | Register | Behavior |
| --- | --- | --- |
| `00` | INPUT | Read-only input after two synchronization registers |
| `04` | OUTPUT | Three output values; reset0 |
| `08` | ENABLE | Three output enables; reset0 releases every pin |
| `0c` | OPEN_DRAIN | Reset7; enabled outputs drive low and release high |

Only bits2:0 are implemented. Byte strobes are honored; an empty write strobe
does nothing. Configure OUTPUT and OPEN_DRAIN before enabling a pin. GPIO0/1 can
implement software I2C with external pull-ups to the board's I/O supply. GPIO2
can provide a select or enable signal for a suitable software-controlled bus.
There is no dedicated I2C or second SPI engine.
Global reset immediately releases GPIO output enables and forces UART TX idle.

One AXI transaction owns the local/external route until its final response.
Local read data is captured once when AR is accepted; response stalls do not
repeat FIFO pops. Local bursts, oversized or unaligned accesses, reserved local
registers and writes to INPUT return SLVERR without peripheral side effects.
Rejected read bursts return their declared number of error beats; rejected
writes drain the declared data beats before responding. The reserved local
decode covers `0x10000000..0x100002ff`; other addresses use the selected backend.

Firmware constants are in [sw/rapt_io25.h](sw/rapt_io25.h).

## Sources and validation

Compile the processor, `synth/configs/pin-limited/rtl/`, this directory's `rtl/`,
and `fpga/common/rtl/rapt_native_uart.sv`, with `rtl/rapt_pkg.sv` first. The public
source helper exposes the complete set as `rtl_sources(repo, io25=True)`.
For an unpacked source list, pass `--single-unit` to Yosys `read_slang` so the
project's shared macros use the same compilation unit as in the packed flows.

From the repository root, use an output directory outside the checkout:

```sh
make -C verification verilator-chip-io25-bus-rv32 verilator-chip-io25-rv32 \
  XSIM_RAPT_CONFIG=chip32-small BUILD_DIR=/tmp/io25-rv32
make -C verification verilator-chip-io25-bus-rv64 verilator-chip-io25-rv64 \
  XSIM_RAPT_CONFIG=small BUILD_DIR=/tmp/io25-rv64
```

Set `CROSS_COMPILE` if the bare-metal toolchain uses a different prefix. Bus
tests exercise both UART directions, independent baud divisors and interrupts,
GPIO input/open-drain controls, byte lanes, rejected bursts, response stalls,
external ownership and reset cancellation. The CPU test boots the same firmware
over bridge, Flash and bridge again, exercising both UARTs through the actual
pad top and reporting success on GPIO. These are digital functional checks;
physical placement, routing, supply integrity and final signoff are separate.
