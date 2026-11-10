# Local-I/O silicon diagnostics

These small RV32 programs use the existing AM TRM interface and klib sources,
with a local UART/RAM runtime. Build from the repository root into a new output
directory outside the checkout:

```sh
make -C app/tests/silicon programs BUILD_ROOT="$RUN_DIR/programs" \
  CLOCK_HZ=10000000 CROSS_COMPILE=riscv64-elf-
```

The builder emits ELF, BIN, exact compiler commands, logs and a source/binary
hash manifest. `ram/` images execute at `0x0f000000`; `xip/` images execute at
`0x30000000`. XIP HEX files are emitted separately for the silicon offset-zero
map and the native fixture's protected upper map. They are simulation inputs,
not instructions to program a board. No build or acceptance command configures
an FPGA. The runtime sets UART1 to 57600 8N1 using the supplied actual clock.

| Program | Checks |
| --- | --- |
| `uart-hello` | Chip-executed UART1 greeting and completion |
| `gpio-walk` | Walk three GPIO outputs, read synchronized pad inputs, then release |
| `ram-march` | March C- over an isolated 128-word BSS buffer |
| `irq` | Real UART0 THRE interrupt, PLIC source 2, machine trap/claim/complete |
| `xip-boot` | Copy initialized data from XIP, clear BSS, report fresh UART completion |
| `benchmark` | 1024 xorshift iterations, checked result `0xf620d345` and kernel cycles |

This benchmark is a small deterministic workload, with no CoreMark score claim.
Record compiler commands, binary hashes, actual clock, conditions and cache
state when comparing cycles. Firmware RAM tests complement SBA patterns; neither
test establishes full cache-memory fault coverage or analog margin.

RAM builds reserve 4 KiB for text, put data/BSS above it, leave 2 KiB for stack
and reserve result storage at `0x0f001f00`. The linker rejects overflow. XIP
builds use the same 8 KiB RAM limit. Startup copies initialized data and clears
BSS, with interrupts disabled. Each image reports signature `0x53494c31`,
completion `0x53494c32`, exit code and an absolute cycle timestamp in consecutive
words at the result address. The benchmark adds its checked result and measured
kernel cycles in words 5 and 6. Acceptance loads and verifies RAM through SBA,
reset-halts again to discard stale cache state, sets DPC and resumes.
Diagnostic execution replaces application RAM/register state.

`tools.bringup.silicon` orders the checks and persists results after each step.
`--phase debug` covers TAP, DM, SBA RAM, ROM and reset boot control. The full
phase adds Flash identity/guards, optional scratch mutation and cold boot, UART,
GPIO, PLIC, a halted backend round trip, step and these CPU tests.
The bridge round trip keeps the core halted because a NOR-only fixture has no
responding bridge. It checks held-reset and released-reset SBA status in both
directions; it does not claim bridge execution. The CPU IRQ program covers
machine delivery from UART0. Software-pending PLIC source 1 and optional external
GPIO2-to-IRQ wiring are separate checks.

Missing inputs yield SKIP, not a measured pass. A GPIO pad mismatch releases
every output; successful checks restore the previous GPIO settings. If SBA
communication also fails, inspect the bus
and use the reviewed board reset procedure to establish safe pin state.
`pass` covers the requested automation; `complete` is false if any step was
skipped or not run. Failures
return nonzero, retain an error in JSON and block dependent actions. The saved
JSON includes conditions and input/host hashes. Transport logs record every
DMI request and response. Supply, clock and temperature observations come from
external instruments. Optional `--bench-json` uses this schema, with numeric
values supplied by the board's approved operating limits and actual readings:

```text
{
  "approved_settings": true,
  "reset_low_observed": true,
  "clock_hz": <measured frequency>,
  "rails": [
    {"name": "<rail>", "voltage_v": <measured>, "min_v": <approved>,
     "max_v": <approved>, "current_ma": <measured>, "limit_ma": <approved>}
  ]
}
```

Extra fields can identify instruments, fixture revision, temperature and the
approval reference. The tool compares observations with supplied limits;
it does not obtain them from the device or control a bench supply.

To provision a new silicon NOR with the probe, use the separate
`tools.bringup.provision --target silicon ... install` command described in
[the bring-up guide](../../../docs/bringup.md). It changes only sector zero,
accepts an image up to 4 KiB, preserves immutable original/neighbor sectors,
and leaves the core halted. `restore` uses the same chip/board/probe identity
and backups. An uncertain operation blocks either action. This capability
requires the offset-zero guard readbacks, so it cannot program the Arty's
lower partition. Routine acceptance keeps its boot-write prohibition.

Replay the same acceptance on the native Arty pin simulator:

```sh
python3 fpga/arty-a7-t100/native/build.py sim --out "$RUN_DIR/sim" \
  --config chip32-small --clock-hz 10000000 --jobs 2
python3 -m tools.bringup.silicon --target arty-native \
  --sim "$RUN_DIR/sim/obj/native-sim" \
  --image "$RUN_DIR/programs/xip/xip-boot.arty-native.hex" \
  --boot-bin "$RUN_DIR/programs/xip/xip-boot.bin" \
  --programs "$RUN_DIR/programs/ram" --clock-hz 10000000 --chip-serial SIM \
  --gpio --scratch --backup "$RUN_DIR/originals" --output "$RUN_DIR/acceptance"
python3 -m unittest discover -s tools/bringup/tests -v
```

The native simulation has accelerated startup waits, two-state digital pads,
UART RX tied idle, and external IRQ tied low. It checks real chip RTL through
simulated JTAG pins, target-observed array operations, cold-reset UART output
without DMI traffic, GPIO self-read, CPU tests and measured digital pin arrivals.
It cannot establish supply/current, physical UART RX wiring, IRQ wire continuity,
packaged-device limits or voltage/frequency margin. Use separately controlled
hardware runs for those checks. Physical native runs additionally require the
reviewed configuration/boot receipt, explicit board/probe serials and guarded
scratch backups. Store every run and immutable backup outside the checkout.
