# Direct NOR Flash on the pin-limited chip

The pin-limited chip defaults to its on-chip reset ROM, which jumps to raw
Flash XIP at `0x30000000` without JTAG. The backend supports standard SPI and a
fixed JESD251D Profile 1 octal DDR descriptor; see the
[xSPI contract](chip-xspi.md). IRQ remains PLIC source 1 in either backend.

The [boot-control register](chip.md#boot-control) at `0x00100808` selects the
backend and ROM/reset-window target at the next drained core reset. The pad list
is unchanged. Flash initialization is retained across debug resets and while
parked in bridge mode; chip reset restores ROM-XIP and the shared target reset.
Compile all integration `.sv` files with the processor package first and set
`CoreClockHz` to the actual chip clock (default 100 MHz). The native Arty fixture
uses `PLATFORM=jesd`; the private bridge fixture uses `PLATFORM=octal` and requires
JTAG boot selection before executing board-side ROM code.

## Device and wiring

The legacy SPI profile is **W25Q64JW-IQ, JEDEC ID `ef 60 17`, 1.7-1.95 V supply,
8 MiB, SPI mode 0, MSB first, three-byte addresses**. Initialization also recognizes
the fixed MT35XU256ABA profile `2c 5b 19` described in the xSPI contract; other IDs
are rejected. This is a
conservative command subset, not universal JEDEC xSPI support. The following
legacy-profile details do not describe the separate octal DDR path. QPI, dual/quad
I/O and arbitrary-device SFDP discovery are not implemented.

The chip's external interface requirement is 1.8 V. Use a matching 1.8 V Flash
supply and I/O domain, including pull-ups. W25Q64JV/`ef 40 17` is a 2.7-3.6 V
part and is rejected by this profile; it must not be directly connected as the
1.8 V target. W25Q64JW-IM/`ef 80 17` is also outside this qualified IQ profile.
A JEDEC ID is not a voltage measurement or a substitute for checking the fitted
part, supply, pad levels and board timing. The protocol model does not simulate
voltage or analog margins.

The manufacturer W25Q64JW Rev B datasheet was checked independently for the
selected IQ variant. Its standard SPI commands and status semantics match the
implemented subset; the wake recovery budget matters even when basic opcodes
match another family. The supported profile is recorded below; no nonvolatile
configuration, QE, protection or lock register is silently rewritten.

| JW-IQ property | Controller/model choice |
| --- | --- |
| ID / QE | `ef6017`; IQ has fixed QE=1, retains standard SPI |
| Read / program / erase | `03h`, zero dummy clocks / `02h`, 4 aligned bytes / `20h`, 4 KiB |
| Status | `05h`: WIP bit 0, WEL bit 1; `35h`: SUS bit 7, CMP bit 6 |
| Reset / wake | `66h` then `99h` / `ABh`; each requires up to 30 us recovery |
| Power-up / mutation limits | 5 ms write delay; 3 ms page program; 400 ms sector erase |
| Budgets | 1 s startup, 100 us legacy reset/wake waits, 500 ms per busy phase |

| Chip pin | Flash signal | Direction in direct mode |
| --- | --- | --- |
| `pad_xspi_cs_n` | `/CS` | Output; idle high |
| `pad_xspi_sclk` | `CLK` | Output; idle low |
| `pad_xspi_dq[0]` | DI / IO0 | MOSI output |
| `pad_xspi_dq[1]` | DO / IO1 | Input throughout every frame |
| `pad_xspi_dq[2]` | `/WP` / IO2 | Held high |
| `pad_xspi_dq[3]` | `/HOLD` / IO3 | Held high |
| `pad_xspi_dq[7:4]` | Unconnected | Released |

The package pin list is unchanged. Internally, `rapt_chip.xspi_dq_oe_o` is now an
8-bit lane mask; the bridge branch replicates its original shared enable to all
lanes. Pad replacement wrappers still receive one enable per pad. Provide external
pull-ups on `/CS`, `/WP` and `/HOLD` so they remain inactive during reset, when DQ
outputs are released. For the octal profile, device RESET# must share the chip's external reset source;
`pad_diag` becomes the DS input in Flash mode. The board must not drive this
contact as a heartbeat. See the xSPI contract for direction and timing requirements.
Use 1.8 V supply/I/O levels and the selected device's power sequencing. This
source option does not configure pad supply voltages.

The legacy SPI path in `rapt_xspi_frame` uses registered SCLK, samples MISO on rising SCLK and changes
MOSI during the low phase. Its default half period is
`max(8, ceil(CoreClockHz / 10_000_000))` core clocks, for at most 5 MHz SCLK.
Inter-byte pauses extend the low phase. CS hold and high gaps have explicit
clock-counted delays. This is a functional target rate; board and pad timing
must still be qualified, including the complete SCLK-to-MISO round trip.

## Reset, first instructions and writable storage

At reset, CS returns high and outstanding AXI ownership is discarded. For the legacy profile, startup
waits at least 1 s, releases deep power-down with `ABh`, waits 100 us, polls
`05h` until WIP clears, checks `35h` for suspend, sends `66h` then `99h`, waits
100 us and reads the ID with `9Fh`. The default busy deadline is 500 ms, counted
in core clocks, including status frames and gaps. A final frame can extend that
deadline by one fixed frame duration. Suspended or unrecognized devices remain
unqualified. Firmware cannot fetch successful XIP data from an unqualified device.

| Address range | Direct mode backing |
| --- | --- |
| `0x20000000..0x2000ffff` | On-chip ROM by default; Flash alias only with ROM selection cleared |
| `0x30000000..0x307fffff` | Read-only Flash offsets `0..8388607` |
| `0x0f000000..0x0f001fff` | Local 8 KiB writable RAM |
| `0x00100800..0x0010083b` | Local control registers below |

The reset PC is `0x20000000`, where the on-chip ROM jumps to `0x30000000`.
For default ROM-XIP boot, program a raw image linked at `0x30000000` at the
build's physical storage offset (zero for the default chip, 8 MiB for the native
fixture). There is no metadata header or CRC checker. The low 64 KiB Flash
alias is available only after selecting Flash with the ROM-selection bit
cleared through boot control and a drained core reset. Its separate example
linker script does not describe default ROM-XIP boot. RAM contents are unspecified
after reset: startup must copy
initialized data/code from Flash, clear BSS and establish a stack. The supplied
linker script reserves 2 KiB for the stack and checks the remaining RAM bound.

This configuration adds the RAM inside the chip wrapper as a portable byte array.
Cache SRAM control is independent of that array; the existing control word remains
available. Mapping it to a physical macro is a future implementation decision.
The added storage changes area and must be included in subsequent qualification.
The CPU's CLINT/PLIC/debug remain internal. External main RAM, UART, finisher and
other devices formerly supplied by the FPGA bridge are not provided in direct
mode; accesses to unbacked external windows return DECERR.

A reset during program/erase is **not a rollback**. Deasserting CS can launch
programming of the complete bytes already sent. The device can finish an accepted
operation while the chip resets. Startup waits for existing WIP before software
reset; it never replays the abandoned command or delivers its old response.
After an interrupted mutation, inspect and restore the affected sector explicitly.
Reset also invalidates processor caches; a failed runtime operation requires the
explicit recovery command before new Flash reads or mutation can succeed.

## Control ABI v1

The register base is `0x00100800`. The three mapping words at `30h/34h/38h`
extend the read-only ABI without changing CAP or existing register meanings.
Before any physical board mutation, require successful reads matching that build's
expected map. The Arty fixture requires exactly `0x800000/0x800000/0x1000000`;
an access error or mismatch must stop programming. Never probe its guard by
issuing a destructive command to the lower partition. Use aligned, single-beat 32-bit AXI accesses,
including on RV64; data/strobes occupy the address-selected AXI lanes. Reserved
register accesses, partial parameter/command writes, malformed transfer shapes,
and writes to read-only registers return SLVERR. SRAM control supports its existing
byte enables and keeps bit 15 zero. The half-period register is read-only in this
mode. C/assembly constants are in
[`rapt_flash.h`](../synth/configs/pin-limited/sw/rapt_flash.h).

| Offset | Register | Access | Value / meaning |
| --- | --- | --- | --- |
| `00` | HALF_PERIOD | R | Compiled SPI half period in core clocks |
| `04` | SRAM_CTRL | RW | Existing 15-bit cache SRAM control |
| `10` | STATUS | R | Described below |
| `14` | JEDEC_ID | R | Last observed ID, `0x00ef6017` for this profile |
| `18` | OFFSET | RW | Flash byte offset for mutation |
| `1c` | DATA | RW | Little-endian PROGRAM32 staging word |
| `20` | COMMAND | W | One of the exact keys below |
| `24` | CAP | R | `0x00010007`: ABI 1, program32/erase4k/recover |
| `28` | CAPACITY | R | `0x00800000` bytes |
| `2c` | ERASE_SIZE | R | `0x00001000` bytes |
| `30` | STORAGE_OFFSET | R | Logical-to-physical Flash byte translation |
| `34` | WRITE_START | R | First physical byte permitted for mutation |
| `38` | WRITE_END | R | Exclusive physical mutation limit |

STATUS bit 3 means the octal DDR protocol is active. In the octal profile SR2 is
MT35X flag status (FSR), not Winbond SR2. STATUS bit 0 means the device is qualified; bit 1 means the serial engine is
busy (including initialization); bit 2 means recovery is required. Bits 15:8
hold the last physical error, bits 23:16 cached SR1 and bits 31:24 cached SR2.
ID and status commands refresh their respective snapshots. Diagnostic commands
do not clear a prior physical failure; only successful recovery requalifies the
device. An ordinary register read remains available after a physical failure.
AXI validation failures do not overwrite the last physical error snapshot.

| COMMAND value | Operation |
| --- | --- |
| `0x52460001` | PROGRAM32 at OFFSET from DATA; offset must be 4-byte aligned |
| `0x52460002` | ERASE4K at OFFSET; offset must be 4 KiB aligned |
| `0x52460003` | RECOVER: repeat non-destructive initialization / identity checks |
| `0x52460004` | IDENTIFY: refresh JEDEC ID |
| `0x52460005` | STATUS: refresh SR1 and SR2 |

The COMMAND write completes only when the operation finishes. While it owns the
AXI port, further requests wait. Busy polling happens in hardware, with separate
budgets before and after mutation. There is no interrupt, automatic retry,
background programmer or second production bus. CPU software must handle an
access fault on a failed command; JTAG SBA clients must handle the bus error.
The register interface is not a generic OpenOCD Flash bank driver.

Mutation checks WIP and suspend, rejects active SR1 protection / SR2 complement
protection, issues WREN and verifies WEL, then sends `02h` plus exactly four bytes
or `20h` with no data. Four-byte alignment prevents page wrapping. Completion
polls WIP, requires WEL clear and no suspend, then verifies all four programmed
bytes or **all 4096 bytes** of the erased sector using `03h`, without dummy clocks.
An attempt to restore a NOR zero bit to one fails verification. Protection and
configuration registers are never silently unlocked or rewritten.

Error codes are 1 timeout, 2 identity, 3 device state/protection/suspend, 4 WEL,
5 readback verification, 6 invalid engine address/operation and 7 SFDP validation. A physical failure
returns SLVERR and latches recovery-required. Subsequent AXI Flash reads return zero
with SLVERR, preserving burst ID/count/last. Failed writes are never replayed.
Normal AXI stores to either Flash window always fail; RAM writes retain normal
byte-strobe semantics. FIXED/INCR read bursts and aligned RAM write bursts are
supported up to AXI's 256 beats, within one aperture and one 4 KiB page. WRAP,
reserved burst encodings, oversized transfers and unaligned writes/MMIO are rejected.
An unaligned first read returns only the address-to-size-boundary lanes; subsequent
INCR beats start at the next aligned transfer-size boundary. Errors
still drain the specified write-beat count or return every requested read beat.
AXI protocol-violating masters must still supply the AWLEN-specified W beats.

Execute mutation routines and required trap handlers from RAM, fence outstanding
accesses before issuing COMMAND, and avoid serving code or data from the affected
Flash while it changes. After mutation, invalidate stale data/instruction cache
lines for both aliases (or reset before using the new image). The included CPU
proof reads a previously untouched Flash sector, so it does not rely on a stale
cache line being automatically snooped by this controller.

## Build and verification

The raw boot payload and linker script show startup, SRAM execution and explicit
mutation. They are a small platform example and destructive regression payload:
the test erases Flash sector at offset `0x10000`. Do not deploy that test image to
a device whose contents must be preserved.

```sh
make verilog
make -C verification spi-flash-boot-images CROSS_COMPILE=riscv64-unknown-elf- \
  BUILD_DIR=/tmp/rapt-flash-check
make -C verification verilator-spi-flash-boot-rv32 XSIM_RAPT_CONFIG=chip32-small \
  CROSS_COMPILE=riscv64-unknown-elf- BUILD_DIR=/tmp/rapt-flash-check
make -C verification verilator-spi-flash-boot-rv64 XSIM_RAPT_CONFIG=small \
  CROSS_COMPILE=riscv64-unknown-elf- BUILD_DIR=/tmp/rapt-flash-check
make -C verification verilator-spi-flash-rv32 verilator-spi-flash-rv64 \
  verilator-spi-flash-delayed-rv32 verilator-spi-flash-delayed-rv64 \
  verilator-spi-flash-identity-rv32 verilator-spi-flash-identity-rv64 \
  verilator-spi-flash-max-time-rv32 verilator-spi-flash-max-time-rv64 \
  BUILD_DIR=/tmp/rapt-flash-check
make -C verification verilator-xspi-link-rv32 verilator-xspi-link-rv64 \
  BUILD_DIR=/tmp/rapt-flash-check
make -C verification verilator-chip-xspi-boot-rv32 XSIM_RAPT_CONFIG=chip32-small \
  CROSS_COMPILE=riscv64-unknown-elf- BUILD_DIR=/tmp/rapt-flash-check
make -C verification verilator-chip-xspi-boot-rv64 XSIM_RAPT_CONFIG=small \
  CROSS_COMPILE=riscv64-unknown-elf- BUILD_DIR=/tmp/rapt-flash-check
```

The model is original test code implementing this command subset, not a vendor
model. Directed tests shorten initialization/poll budgets and operation delays;
the CPU benches explicitly shorten the one-second startup/recovery waits. The JW model
starts in deep power-down and enforces 30 us recovery after `ABh`, so release
sequencing is exercised. Protection tests cover SR1 and CMP preflight. The
`spi-flash-max-time` cases retain the documented 3 ms/400 ms operation maxima
and the 500 ms controller busy deadline; the normal tests shorten those latencies.
The `chip-xspi-boot` cases execute default ROM-XIP, use JTAG/SBA to select
bridge boot, repeat core reset to check retention, return to Flash without
resetting its octal protocol, then apply chip reset and check the default.
IRQ propagation and the two-clock released-pad switch interval are checked.
The `chip-io25` cases boot twice through the 25-signal pad top, with JTAG IDCODE,
both UARTs, GPIO and a pin-visible result after checking an EBREAK trap.
No physical Flash, board programming or vendor model qualification is implied. Default and
10 ns return-delay simulations exercise digital sampling; they do not qualify
external I/O timing, maximum frequency or arbitrary devices. SPI reads have no
CRC, so undetected pin-level corruption remains an electrical validation concern.
Before integration, rerun synthesis compatibility, expanded timing with external
serial and OE constraints, reset and gate-level checks, and full physical/GDS
signoff. Existing implementation outputs are not changed by this feature.

Protocol basis: manufacturer-authored [Winbond W25Q64JW datasheet, Rev B](
https://www.mouser.com/datasheet/2/949/W25Q64JW_RevB_11042019-1760399.pdf),
November 4, 2019, sections 6-9: standard SPI instructions, IQ identity, status,
reset/power-down recovery and operation timing. The [manufacturer product page](
https://www.winbond.com/hq/product/code-storage-flash/qspi-nor/w25q-jw/?__locale=en&partNo=W25Q64JWBYIQ)
confirms the 1.7-1.95 V supply range. Confirm the exact fitted IQ variant and
current manufacturer datasheet during board qualification. These references
establish the device profile; digital regressions establish protocol behavior.
Neither establishes chip-pad or board electrical signoff.

## Debug recovery when Flash cannot boot

A blank image, absent peer or missing DS does not require abandoning an AXI
transaction. The NOR controller uses finite startup/reset waits, bounded WIP
polling and a per-byte octal receive timeout. A failed operation clears
qualification, reports its error and finishes the accepted bus burst with SLVERR
and zero read data. It then returns idle, so a pending boot-control access can
complete. See [chip boot control](chip.md#boot-control) for the retained
register and JTAG reset sequence. Hold haltreq and keep the chip clock running;
wait for older work to drain before changing backend. Clear any sticky SBA error
after busy clears. Do not automatically retry a program/erase with an uncertain
physical outcome. Returning to Flash requires successful explicit recovery or
chip reset and a valid image; switching backend does not repair the image.

Simulation startup budgets must match the model's clock progress. Bridge-only
fixtures use explicit accelerated waits and supply no NOR responses, then select
the bridge through JTAG. They leave production timing parameters and the octal
receive timeout unchanged. No-peer, blank-image and mid-array DS-stop tests run
for both XLENs and check a successful bridge boot after recovery.
