# JESD251D Profile 1 host interface

The direct Flash backend contains a low-speed JESD251D Profile 1 host for the fixed
MT35XU256ABA descriptor, alongside the legacy W25Q64JW-IQ SPI profile. The JTAG-selected
FPGA bridge uses its own octal SDR AXI transport. Both backends exist in one chip;
the bridge transport is not a JEDEC memory protocol.

The normative reference is *JESD251D, eXpanded Serial Peripheral Interface (xSPI) for
Nonvolatile Memory Devices*, May 2026. Page numbers below are the standard's printed
pages. This document summarizes requirements and their implementation; it does not
redistribute the licensed standard or assert completed chip/board electrical signoff.

## Scope and descriptor

The standard distinguishes a controller from a target. Section 5.3, page 10, requires
an xSPI **target** to provide both 1S-1S-1S and 8D-8D-8D. Section 6.7, pages 14–15,
permits Profile 1, Profile 2, or both. Required target commands in Table 4 are not a
requirement that host firmware expose every command as a public operation.

The selected part's nonvolatile startup configuration must already be known:
single-line protocol with XIP disabled. Hardware RESET# reloads that configuration;
it does not force an arbitrary octal/XIP-configured part into 1S. This host does
not rewrite nonvolatile settings to repair an unsupported startup configuration.

This host accepts the fixed `2c 5b 19` identity and a matching 256 Mbit SFDP density.
It deliberately maps only the existing low 8 MiB Flash aperture. SFDP header, version,
parameter-header bounds, Basic Flash Parameter Table identity/length and density are
checked before configuration. This is a sanity check of a known descriptor, not a
parser for arbitrary vendors, command aliases or mode-entry procedures. An unsupported
identity or malformed SFDP leaves the device unqualified and prevents mutation.

| Property | Selected descriptor |
| --- | --- |
| Startup protocol | 1S-1S-1S, mode 0; known default after shared hardware reset |
| Operational protocol | Profile 1, 8D-8D-8D; all phases use eight lanes and both CK edges |
| Command extension | Repeat the opcode; this choice belongs to this descriptor |
| Address | Four bytes, most significant first; array reads start on an even byte |
| Array read / program32 / erase4k | `FDh` / `8Eh` / `21h` |
| Status / flag status | `05h` / `70h`, no address, eight CK latency cycles |
| Array initial latency | Sixteen CK cycles; returned bytes are selected by DS edges |
| Volatile setup | `81h`: dummy=16, four-byte addressing, XIP disabled, linear wrap, octal+DS |
| Setup verification | `85h` readback; final repeated SR/FSR words must agree |
| Protection | No nonvolatile configuration, protection or lock bits are rewritten |

Section 6.4, page 13, defines repeat **or invert** extensions as target-specific,
reported through SFDP. This host's repeated extension must not be reused for an
inverted-extension target without a separate descriptor and its verification.
Profile 2, 8S SDR memory protocols, quad/dual protocols, dual-octal width, differential
CK, high-speed training, write masks and automatic suspend/resume are not implemented.

The fixed mode-entry sequence and opcodes follow the MT35X datasheet behavior.
Both chip and board hosts use `rapt_spi_nor` and its `rapt_xspi_frame` PHY.
Electrical qualification applies to each build's clock and board connections.

## Pin and reset contract

No logical signal is added. On `rapt_chip_pads25` and `rapt_chip_pads`, **`pad_diag` is
bidirectional**: it remains the heartbeat output in the locked bridge mode and becomes
the Flash DS input in Flash mode. Chip reset and the two switch clocks release
its output enable. The [boot-control register](chip.md#boot-control) selects the
backend at a drained core reset. IRQ remains an ordinary interrupt input.
Both local UARTs
and all three GPIOs on the 25-signal top remain available.

| Contact | Bridge mode | Flash mode |
| --- | --- | --- |
| CK / CS# | Existing private transport | Mode-0 clock / active-low target select |
| DQ[7:0] | Existing bridge lane ownership | Per-lane enables; all eight released during 8D reads |
| DIAG / DS | Heartbeat output | Target read-strobe input, host output disabled |
| External reset | Chip reset | Chip and target hardware reset from the same source |

A pull-down keeps DS low when the target releases it. Do not attach an external
heartbeat driver to this contact. The target's RESET# must share the external chip
reset source and establish its known single-line startup mode. This avoids adding a
reset contact, but requires the shared-reset connection on the board. An externally
reset host with an independently running octal target has lost its protocol contract.
Separate controller-driven RESET# is not provided by this configuration.

JESD251D page 6 makes target POR mandatory, prefers in-band reset and permits a
separate reset signal. The stronger shared-reset requirement above belongs to this
particular integration. Reset during program/erase can leave changed or damaged array
contents; neither external nor software reset rolls back or replays a mutation.
Software RECOVER polls existing WIP in the known protocol before resetting and
reconfiguring the target. Device errors remain latched until successful recovery.

## Protected Arty storage

The pad and chip tops expose `FlashStorageOffset`, `FlashWriteStart` and
`FlashWriteEnd`. The storage offset translates the boot alias, XIP and mutation
OFFSET register from logical aperture offsets to physical Flash bytes. The two
write limits are physical, with an exclusive upper limit. The native NOR request
interface checks the complete mutation span before WREN, including callers that
bypass AXI or host software.

ASIC defaults retain offset zero and physical write range `[0, 0x800000)`. The
Arty A7-100T fixture must use offset `0x800000`, write start `0x800000` and write
end `0x1000000`. The lower 8 MiB of the board flash is reserved and never written
by these tools. For example, logical OFFSET `0x10000` maps to physical `0x810000`.
Do not program a Raptor boot image at physical offset zero on that fixture.
Read-only registers at control offsets `30h/34h/38h` return the storage offset,
physical write start and exclusive physical write end. Before the first Arty
mutation, SBA must read all three successfully and require exactly
`0x800000/0x800000/0x1000000`. A stale bitstream, error or mismatch must stop the
procedure. Do not send a destructive lower-partition command to test this guard.
Raw board tools use physical addresses and must enforce the same upper partition.
A separate native-interface regression rejects program and erase requests below
8 MiB, checks whole-span upper limits and permits the final upper word/sector.
The independent fixture rejects array READ headers below its selected physical
base. The 25-pad CPU test checks its first READ is at 8 MiB and its exact physical
program/erase addresses, so the small fixture's memory indexing cannot hide a
missing storage translation.

## Sampling and timing

`rapt_xspi_frame` uses the core clock for oversampling. It sends controller DDR data
between CK edges, synchronizes DS through four history stages, and pipelines DQ
through two stages. Both DS transitions capture successive bytes. Detection waits one extra core
cycle so that a DQ arrival after DS can settle before the sampled byte is consumed.
The supported digital skew bound is `|tDQ - tDS| <= Tcore/4`: ±25 ns at a 10 MHz
core, ±2.5 ns at 100 MHz. The HP=8 regressions cross the initial sampling edge with
both skew signs at both core rates. This is a digital bound; pad/board setup, hold
and analog margins still need qualification. Data outside this bound can be wrong
without a protocol error and is outside the supported timing contract. Reads use complete
byte pairs; odd CPU addresses and narrow AXI reads select their requested bytes after
an aligned transfer. Sustained DS loss, including a partial word or a missing final byte, produces a
bounded
error and invalidates qualification. A paused complete word can resume before its
deadline without losing bytes. This does not detect every missing edge: if a
target keeps advancing data while dropping isolated DS pulses, the host may still
receive the requested edge count with corrupted data. The link has no CRC; timing
qualification and end-to-end image/data checks remain necessary.
CS changes only with CK low, with explicit setup, hold and high gaps. After the
last requested 8D word the PHY gates CK low and holds CS low for at least one CK
period. This covers Table 25's 0.8-period valid-DS-low to CS-high requirement;
Figure 37 permits additional dummy DS edges during return propagation.

The default half period is `max(8, ceil(CoreClockHz / 10_000_000))` core clocks:
100 MHz core gives 5 MHz CK; 10 MHz core gives 625 kHz CK. Eight core clocks per half
period is the minimum for this 8D PHY. Overrides below eight clocks are unsupported;
other divider changes need timing checks.
The legacy SPI regression may override the divider to two clocks for simulation.

The Arty board adapter also runs this PHY at 10 MHz with half period eight,
producing 625 kHz CK. Identity and status checks establish protocol qualification;
array readback and routed timing remain necessary for each physical build.

All five timing choices pass through the pad top: `FlashHalfPeriod`,
`FlashPowerupCycles`, `FlashResetCycles`, `FlashRecoveryCycles` and `FlashPollCycles`.
Production defaults wait at least one second before initialization and one second
after a Profile 1 in-band reset. The wake/legacy-reset wait is 100 microseconds;
the busy deadline is 500 milliseconds. The initial and recovery waits are distinct.
At 10 MHz, use at least `10_000_001` cycles for both long waits. Directed simulations
explicitly shorten those waits; they do not qualify the worst reset recovery time.

The selected device's ordinary power-up budget differs from recovery after an
interrupted erase. Its recovery also depends on the operation interrupted by reset.
The conservative one-second defaults follow the reference integration's recovery
policy. Changing them requires checking the actual fitted part and reset conditions.
Ensure the shared target RESET# pulse is at least 50 ns and CS is high before release.

Before a board or chip timing claim, constrain and verify the entire CK-to-target-to-
DQ/DS return path, DQ-to-DS skew, pad and translation delay, input setup/hold, output
setup/hold, CS timing and output-enable turnarounds. The core remains configured at
its declared clock frequency. No 100 MHz CPU performance change is hidden in the PHY.
Digital delay regressions do not qualify voltage levels, pads, the board or maximum CK.

## Requirements and evidence matrix

| Requirement | Printed pages | Implementation and verification |
| --- | --- | --- |
| CS changes with CK low | 12, 70–71 | Registered sequencing; independent edge monitor |
| 1S lane, bit and address order | 10, 15 | IO0 TX / IO1 RX, MSB first; SFDP monitor |
| 8D phases on both edges | 11, 13, 16 | Six-byte array header; extension checked |
| Target-specific extension | 13 | Fixed repeated descriptor; no universal claim |
| DS read timing | 11–12 | Both-edge sampling; missing-strobe timeout/recovery |
| Even addresses, byte pairs | 11, 31 | Aligned transfer and AXI byte selection |
| SFDP framing and metadata | 15, 31 | Header/BFPT/density checks; invalid-SFDP rejection |
| Required target command set | 16 | Target obligation; host uses its documented subset |
| Optional 4 KiB erase/reset/config | 17, 38–40 | Key, WEL/status and full erase readback |
| Mutation sequencing | 16, 35–37 | Pre/post SR/FSR, deadlines, verification negatives |
| POR/default mode | 6, 10 | Shared reset; same-binary bridge/Flash/bridge test |
| Electrical/AC timing | 61–71 | Independent physical/board evidence required |

Commands for suspend/resume, write disable and erase of at least 64 KiB are mandatory
for a Profile 1 **target** as applicable in Table 4. The current host API does not use
or expose them. The independent fixture covers the host's selected operations; it is
not a complete target conformance model and cannot certify a manufactured Flash.

Focused digital checks, from the repository root, with outputs outside the checkout:

```sh
make -C verification verilator-xspi-flash-rv32 verilator-xspi-flash-rv64 \
  verilator-xspi-flash-sfdp-rv32 verilator-xspi-flash-sfdp-rv64 \
  verilator-xspi-flash-delayed-rv32 verilator-xspi-flash-delayed-rv64 \
  verilator-xspi-flash-board-edge-rv32 verilator-xspi-flash-board-edge-rv64 \
  BUILD_DIR=/tmp/rapt-xspi-check
for xlen in 32 64; do
  make -C verification "verilator-xspi-tail-skew-plus-rv$xlen" \
    "verilator-xspi-tail-skew-minus-rv$xlen" \
    "verilator-xspi-tail-skew-fast-plus-rv$xlen" \
    "verilator-xspi-tail-skew-fast-minus-rv$xlen" BUILD_DIR=/tmp/rapt-xspi-check
done
make -C verification verilator-chip-xspi-boot-rv32 XSIM_RAPT_CONFIG=chip32-small \
  CROSS_COMPILE=riscv64-unknown-elf- BUILD_DIR=/tmp/rapt-xspi-check
make -C verification verilator-chip-xspi-boot-rv64 XSIM_RAPT_CONFIG=small \
  CROSS_COMPILE=riscv64-unknown-elf- BUILD_DIR=/tmp/rapt-xspi-check
```

The chip tests use the 25-signal top, actual CPU firmware, pin-level JTAG, response
stalls and debug reset, then reselect the bridge with full external reset. They check
DIAG/DS ownership and mutation counts. Retained legacy SPI and private bridge checks
remain necessary. Arty A7-100T is the board validation target; a new source-matched
build, timing review, boot, raw readback, mutation and recovery run are still required.
