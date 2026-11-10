# Chip top and off-chip link

The chip powers up in a small on-chip ROM and jumps to [Flash XIP](chip-flash.md)
through its JESD251 Profile 1 backend. JTAG can select the private octal-link
backend and reset target using a retained local register. No boot-selection pin
is required; IRQ is an ordinary interrupt input.

The pin-limited configuration in `synth/configs/pin-limited/rtl/` is one tape-out
integration of the Raptor cluster, also used for the optional
[Arty octal-link fixture](../fpga/arty-a7-t100/OCTAL-LINK.md) (`PLATFORM=octal`). The reusable
processor top is `rapt` in `rtl/rapt.sv`.
All memory and peripherals sit on a board-side FPGA behind one octal link, so
this integration needs 18 signal pins and has one clock domain. Everything
here is technology-neutral.

```text
rapt_chip_pads   rapt_pad_in / rapt_pad_out / rapt_pad_bidi around every signal pin
└─ rapt_chip     reset, interrupt and JTAG synchronizers, DIAG divider
   ├─ rapt            cluster: core, L1s, CLINT, PLIC, Debug Module, DTM
   ├─ rapt_chip_boot      retained boot control and reset ROM
   └─ rapt_chip_backend   exclusive AXI/pin ownership
      ├─ rapt_axi_xspi    octal bridge, local link and SRAM control registers
      └─ rapt_axi_flash   NOR SPI / 8D backend, local RAM and Flash control registers
```

The `chip32-middle-16k` preset (`rtl/configs/chip32-middle-16k`) is RV32 only and
pairs the `middle` core with 16 KiB write-back L1s. Over the link at the reset half
period, CoreMark's total cycle count is 16.4 M on `small`, 1.48 M with its core and 8 KiB L1s, and 1.00 M on
`chip32-middle-16k`.

`chip32-dff` (`rtl/configs/chip32-dff`) is a flop-only build of the same chip
top: the `small` core with 4 KiB L1I and 2 KiB write-back L1D, built without
`RAPT_USE_SRAM_MACRO`, so it needs no memory macros. Over the link its CoreMark
total is 1.73 M cycles.

`chip32-small` (`rtl/configs/chip32-small`) is the smallest build of the same chip
top: the `small` core with `RAPT_NO_FPU`, for protocol checks of the link and JTAG on
low-end FPGAs. `RAPT_NO_FPU` removes the FEU, clears F and D in MISA, keeps
`mstatus.FS` Off, and traps every FP instruction and FP CSR access as illegal;
`make -C sim/tb verilator-chip-no-fpu` checks that contract.

## Pins

| Pin | Direction | Pull | Function |
| --- | --- | --- | --- |
| `pad_clk` | in | none | Core clock |
| `pad_reset_n` | in | up | Asynchronous assert, synchronized release |
| `pad_irq` | in | down | PLIC source 1 in both backends |
| `pad_xspi_sclk` | out | | Link clock |
| `pad_xspi_cs_n` | out | | Link frame, active low |
| `pad_xspi_dq[7:0]` | bidirectional | down | Link data |
| `pad_jtag_tck` | in | down | Oversampled; keep below 1/8 of the core clock |
| `pad_jtag_tms`, `pad_jtag_tdi` | in | up | JTAG, synchronized |
| `pad_jtag_tdo` | out | | JTAG, registered |
| `pad_diag` | inout | down | Bridge clock / 1024; Flash DS input |

There is no TRST pin: the TAP resets with the chip or through TMS. The DTM runs
on the core clock with a TCK-rising-edge enable, so a running clock is required
for debug. In the locked bridge mode, `pad_diag` outputs the clock / 1024 heartbeat.
Flash mode releases its output enable and receives the target DS signal on this contact.
Chip reset and the two switch clocks release its output enable. See the
[JESD251D interface contract](chip-xspi.md) for DS and shared Flash reset,
and the [25-signal integration](../synth/configs/io25/README.md) for UART/GPIO.

## Boot control

Chip reset always selects Flash and the on-chip ROM. At reset PC `0x20000000`,
`lui t0, 0x30000; jalr x0, 0(t0)` jumps to XIP at `0x30000000`. Other words in
that 64 KiB ROM window are NOP. Writes return SLVERR. The ROM needs neither
Flash initialization nor JTAG to execute; the subsequent XIP fetch waits for
Flash qualification. Images are raw code linked at `0x30000000`. The ROM does
not authenticate images or change Flash contents.

The local 32-bit boot-control register at **`0x00100808`** is accessible through
DM System Bus Access in either backend, including while the core is in reset.
Ordinary physical CPU MMIO can also reach it; there is no debug privilege filter.
Use uncached accesses. Aligned, single-beat, 32-bit FIXED/INCR accesses are accepted.
Writes require all four byte strobes, zero reserved bits and WLAST. Other
accesses return SLVERR without changing the setting. On RV64 this word uses
byte lanes 0..3. Reads have no side effects and remain stable under backpressure.

| Bits | Access | Meaning |
| --- | --- | --- |
| 0 | RW | Requested backend: 1 Flash, 0 private octal bridge |
| 1 | RW | Requested boot target: 1 ROM jump to XIP, 0 backend reset window |
| 15:2 | RAZ | Reserved; write zero |
| 16 | RO | Active backend |
| 17 | RO | Active ROM selection |
| 31:18 | RAZ | Reserved; write zero |

Reset readback is `0x00030003`. Write values are `3` for Flash ROM-XIP, `0`
for bridge boot at `0x20000000`, `2` for ROM-XIP through the bridge, or `1`
for the low-64-KiB Flash alias at `0x20000000`. This is a fixed target selector;
use the existing DPC abstract register to resume at another arbitrary address.
Requested and active fields survive halt/resume, TAP/DM reset, `ndmreset` and
core reset. Only chip/power-on reset clears them to `3`.

A write changes only the requested fields. At the rising edge of the cluster's
**drained core reset**, the controller snapshots them. An already offered AXI
address stays valid through backpressure and competing requests. That transaction
completes before switching; a parked Flash controller must also be idle.
Initialization or an in-flight Flash operation can delay this boundary.
No new AXI request is accepted during that wait. CS then stays high, SCLK low,
and DQ and DIAG output enables stay zero for **two complete core clocks**.
The active fields change between those clocks and the new backend is enabled
on the following clock. Status reads wait until switching completes. An unchanged
setting causes no switch. Writes while core reset is asserted return SLVERR.

Use JTAG `halt`, write `0x00100808`, assert `dmcontrol.ndmreset` with haltreq,
read back the active fields, deassert ndmreset retaining haltreq, wait for halted,
then verify the active fields again before `resume`. Keep ndmreset asserted until
active readback matches. This resets caches and removes stale instruction/data
state. Keep the chip clock running while an accepted Flash request completes or
returns an error. Never retry an uncertain external mutation automatically.

Flash failure recovery uses the controller's bounded operations, without
abandoning an AXI transfer. Power-up and reset recovery waits are finite;
initialization bounds its status polling and SFDP descriptor scan. WIP polling
counts core clocks, including frames and CS gaps, and expires after
`FlashPollCycles`. A missing DS edge during an octal read expires after
`max(CoreClockHz / 1000 + 1, 4 * FlashHalfPeriod + 16)` core clocks per byte.
At 100 MHz the production waits are 100000001 power-up clocks, 10001 reset
clocks, 100000001 Profile 1 recovery clocks and a 50000000-clock WIP budget;
the missing-DS budget is 100001 clocks. These are clock budgets, not host
wall-time budgets; underclocking lengthens their elapsed time.

An absent, unqualified or stalled Flash returns SLVERR and zero read data.
After the first failed beat the remaining beats of that AXI burst also return
the error. The response ID, burst length, RLAST and backpressure rules remain
intact. No new core requests are offered after halt acknowledgement. Once the
older responses drain, the queued boot-control access completes, and the JTAG
sequence above can select and boot a responding bridge. If an earlier SBA
access itself failed, poll `sbbusy` until clear and clear sticky SBA errors
before the control write. The Flash fault stays latched/unqualified; returning
to Flash requires successful explicit recovery or chip reset, plus a valid
image. A blank but responding Flash instead fetches invalid instructions;
JTAG can still halt, select the bridge and reset-halt normally.

The initialized Flash controller and local RAM are retained while parked, so a
return to Flash preserves the target's established octal protocol. The bridge
is reset while inactive. Chip reset also resets the external Flash through the
shared reset connection. External fixture logic must provide the selected
protocol and release its return drivers in the other mode. IRQ is a synchronized
PLIC source 1 in **both** modes; it never selects boot or owns the DIAG contact.
DIAG drives core-clock/1024 in bridge mode and receives DS in Flash mode.

## Octal link

This is a project-defined octal SDR link, not JEDEC xSPI. Data changes while
SCLK is low and is sampled on the rising edge, one byte per SCLK cycle. One AXI
transaction is one CS_N frame, and one transaction is outstanding at a time.

| Phase | Bytes |
| --- | --- |
| Request | `0xA1` read or `0xA2` write, XLEN/8, ID, LEN, `{BURST, SIZE}`, CACHE, address LSB first |
| Write data | For each beat: data LSB first, then strobe |
| Turnaround | One byte with DQ released by the chip |
| Status | Polled until bit 7 is set; bits 1:0 are the AXI response |
| Read data | All beats, LSB first |

The target buffers a whole read burst before it reports status, so there is no
per-beat flow control and one response covers the burst. On RV32 a 32-byte line
refill costs 10 + 1 + 1 + 32 = 44 bytes, or 88 x half-period core clocks plus
the status polls.

The board-side end is `fpga/common/rtl/rapt_xspi_target.sv`. It oversamples
SCLK, so its clock must be at least four times SCLK. The chip samples read data
one SCLK half period after it drives SCLK low, which has to cover the target's
three-clock launch latency plus pad and board delay.

## Link control register

Address `0x0010_0800` is served inside `rapt_axi_xspi` and never reaches the
pins. Bits 3:0 hold the SCLK half period in core clocks, 4 after reset. Software
may write 2 to 15; lower values are ignored. Raising the core clock past what the
board link can take therefore does not need a new boot image, as long as the boot
code sets the divider first.

## SRAM macro control register

Address `0x0010_0804` is also served locally, without reaching the link pins.
The core uses ordinary 32-bit loads/stores; JTAG uses 32-bit SBA accesses.
Bits 14:0 are writable with byte strobes; reserved bit 15 and bits 31:16 read
zero. Unaligned accesses, other transfer sizes and bursts return SLVERR locally.
On RV64, the 32-bit word
uses AXI byte lanes 4 through 7.

| Bits | Field | Meaning |
| --- | --- | --- |
| 0 | `test` | Bypass the self-timed circuit, for test only |
| 1 | `margin_override` | Use `margin` instead of the built-in setting |
| 5:2 | `margin` | Read/write margin setting |
| 7:6 | `read_assist` | Read assist (word-line under-drive) |
| 10:8 | `write_assist` | Write assist enable and level |
| 13:11 | `write_pulse` | Write assist pulse width |
| 14 | `light_sleep` | Low-leakage retention mode |
| 15 | reserved | Reads zero |

The registered word drives every SRAM wrapper through explicit ports. Behavioral
memories ignore it; macro implementations receive it on their `ctrl` port.
`RAPT_SRAM_CTRL_RESET` supplies the safe default: `16'h0608` for both chip32
presets and zero for presets without an override. External chip reset restores
this value; `ndmreset` preserves the register along with the link bridge.

Software must change the word only while caches are idle, for example from
uncached code with caches disabled or after a fence has drained cache activity.
JTAG must arrange the same quiescence. Halting alone does not drain dirty caches.
Legal combinations come from the macro datasheet; a wrong combination can corrupt
memory. Keep the safe reset value unless the selected macro requires another
documented setting.

## JTAG debug and loading code

JTAG can halt/resume the hart, transfer GPRs and selected debug CSRs, and read or
write physical memory/MMIO through an independent AXI System Bus Access master.
OpenOCD `mdw`, `mww`, byte/halfword accesses, `load_image`, `verify_image` and
`dump_image` reach CLINT, PLIC and the board's memory/flash windows over the octal
link. Flash programming follows the board controller's protocol; the chip adds
no flash-specific registers. SBA supports 8/16/32-bit accesses on this RV32 chip.

`dmcontrol.ndmreset` resets the core, caches, L2 and interrupt peripherals while
keeping the DTM, DM, arbiter/router and octal bridge alive. Accepted core bus
transfers drain before reset; no AXI response ownership is lost. OpenOCD can use
`reset halt`, and SBA remains available while the core is held in reset and after
reset release while halted. The arbiter blocks new core requests after halt is
acknowledged, including speculative instruction refills. Local boot-control SBA
access therefore needs no external bridge responder in this state. A running
chip clock is required; external accesses still need a responsive board/link.
A permanently hung accepted transfer can prevent drain and requires external
chip/board reset.

For a fresh program, use `reset halt`, load and verify RAM through SBA, then
`reset halt` again, `reg pc <entry>` and `resume`. Board RAM/ROM survive
`ndmreset`; the second reset removes stale cache contents. Resume applies DPC
through the normal pipeline recovery path before acknowledging the request.
Without a PC write, it continues at the captured next instruction. Resume also
invalidates L1I so an SBA software-breakpoint patch is refetched. The reset/load
flow is checked by `verification/jtag`'s `openocd-ndmreset-rv32` target.

`dcsr.step` admits one architectural instruction before blocking younger work.
Compressed expansion and AMO internal operations each retain one ROB owner.
Normal steps halt with cause 4 and DPC at the architectural successor, including
taken branch/jump targets. A fault instead updates the normal trap CSRs and halts
at the handler entry before executing it. Such an instruction leaves the ROB but
does not increment `instret`. Interrupts are masked during a step unless
`dcsr.stepie` is set; an enabled interrupt can consume the step with no instruction
executed. WFI already completes without waiting in this implementation.

`dcsr.ebreakm/ebreaks/ebreaku` select debugger entry for EBREAK and C.EBREAK in the
corresponding privilege: cause 1, DPC at EBREAK, no breakpoint exception and no
architectural retirement. With the bit clear, the normal breakpoint exception
applies. `dcsr.prv` reports the privilege at each halt and is read-only; privilege
changes use normal architectural trap/return instructions. Halt requests capture
cause 3; reset-halt requests capture cause 5 when no explicit haltreq is asserted.
There are no execute-address triggers, program buffer, or Debug Mode instruction
execution. `openocd-step` and `gdb-step` exercise the production chip path.

SBA bypasses **L1 and L2 caches**. Halting drains pending stores and responses and
cleans L1D, so on the no-L2 chip presets GDB can read committed stack spills.
A successful memory verification does not invalidate data caches.
Reset discards dirty cache contents. To inspect preserved program data, firmware
must first clean/write back its caches; use a reset-based loading flow when
preserving the previous execution state is unnecessary. Software breakpoints in
ordinary RAM code work on the chip's no-L2 presets. SBA writes to data still
resident in L1D, and SBA access with an enabled L2, require firmware cache
maintenance; resume's L1I invalidation does not make SBA coherent. See
[the JTAG verification guide](https://github.com/Kingfish404/raptor-chip/blob/master/verification/jtag/README.md)
for limits and tests.

## Simulation

```sh
make -C verification verilator-xspi-link-rv32 verilator-xspi-link-rv64
make -C sim/tb verilator-chip-smoke RAPT_CONFIG=chip32-middle-16k
make -C sim/tb verilator-chip RAPT_CONFIG=chip32-middle-16k IMG=/abs/path/program.bin
```

`sim/tb/rapt_tb_chip.sv` connects only pins, so the same bench accepts a gate
netlist of `rapt_chip_pads` with `+define+RAPT_TB_GLS`.

## Implementation boundary

An implementation flow keeps these module names and supplies its own bodies from
a private tree, so no target-specific RTL lands here:

- `rapt_pad_in`, `rapt_pad_out`, `rapt_pad_bidi` in `synth/configs/pin-limited/rtl/rapt_pad.sv`
- `rapt_openram_1rw_<depth>x<width>`, selected by `RAPT_USE_SRAM_MACRO`

See "Foundry and Implementation Confidentiality" in `AGENTS.md` for what stays
outside this repository.
