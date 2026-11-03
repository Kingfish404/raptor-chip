# Chip top and off-chip link

`rtl/chip/` is the logical and pad-level top of a pin-limited Raptor chip. All
memory and peripherals sit on a board-side FPGA behind one octal link, so the
chip needs only 17 signal pins and has one clock domain. Everything here is
technology-neutral.

```text
rapt_chip_pads   rapt_pad_in / rapt_pad_out / rapt_pad_bidi around every signal pin
└─ rapt_chip     reset, interrupt and JTAG synchronizers, DIAG divider
   ├─ rapt            cluster: core, L1s, CLINT, PLIC, Debug Module, DTM
   └─ rapt_axi_xspi   AXI4 to octal link, local link and SRAM control registers
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
| `pad_irq` | in | down | External interrupt, PLIC source 1, synchronized |
| `pad_xspi_sclk` | out | | Link clock |
| `pad_xspi_cs_n` | out | | Link frame, active low |
| `pad_xspi_dq[7:0]` | bidirectional | down | Link data |
| `pad_jtag_tck` | in | down | Oversampled; keep below 1/8 of the core clock |
| `pad_jtag_tms`, `pad_jtag_tdi` | in | up | JTAG, synchronized |
| `pad_jtag_tdo` | out | | JTAG, registered |
| `pad_diag` | out | | Core clock / 1024 after reset release |

There is no TRST pin: the TAP resets with the chip or through TMS. The DTM runs
on the core clock with a TCK-rising-edge enable, so a running clock is required
for debug. `pad_diag` proves clock, reset and output pads without the link.

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
`reset halt`, and SBA remains available while the core is held in reset. A running
chip clock and a responsive board/link are still required. A permanently hung
bus can prevent drain and requires external chip/board reset.

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
[the JTAG verification guide](../verification/jtag/README.md) for limits and tests.

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

- `rapt_pad_in`, `rapt_pad_out`, `rapt_pad_bidi` in `rtl/chip/rapt_pad.sv`
- `rapt_openram_1rw_<depth>x<width>`, selected by `RAPT_USE_SRAM_MACRO`

See "Foundry and Implementation Confidentiality" in `AGENTS.md` for what stays
outside this repository.
