# Arty native Profile 1 validation fixture

This entry connects the real 25-signal chip directly to the existing external
MT35X fixture. It does not instantiate the private bridge target or the old
board-side Flash bank. Ordinary `soc`, private `octal` and the separate bring-up
platform remain independent.

The physical chip core uses the frequency declared in the build. Start at
10 MHz core / half period 8 / 625 kHz CK. The new oversampling PHY needs at least
eight core clocks per half period. The board-side adapter uses the same NOR host
and PHY. A 100 MHz core / half period 10 build would give 5 MHz CK
and needs separate routed timing and board qualification.

The build releases reset after clock lock. The chip starts at its existing reset PC, `0x20000000`, in an
internal read-only ROM. `lui t0, 0x30000; jalr x0, 0(t0)` transfers execution to
the fixed XIP entry `0x30000000`, mapped to physical Flash offset `0x800000`.
The remaining words in the 64 KiB reset window are NOP. ROM writes return
SLVERR. The XIP window, 8 KiB RAM, Flash ABI and 8M/8M/16M protection are unchanged.
The ROM does not validate the external image or alter Flash contents.

Boot selection uses the chip's retained [SBA register](../../../docs/chip.md#boot-control).
BTN1 applies shared reset to chip and Flash; BTN0 also resets the clock generator.
Both restore the chip's default ROM-XIP setting. Debug ndmreset retains it.

The original Flash and CPU JTAG connector locations are retained. UART0 remains
on the external reference connector. UART1 is on onboard USB-UART (A9 input,
D10 output). GPIO0..2 use free ChipKIT IO0..2 (V15/U16/P14). All physical FPGA
signals in this fixture are LVCMOS33. This is an FPGA emulation of the chip and
does not authorize directly connecting 1.8 V chip I/O to the Arty headers.

The external CPU TAP is distinct from FPGA configuration JTAG. Host tools must
select the explicitly authorized Arty and probe serials. Only volatile FPGA
configuration is in scope. Flash offsets below 8 MiB remain immutable; native
upper-region boot and mutation require the reviewed guarded chip configuration.

Qualify each configuration with real chip/native pin simulation, receiver/host
regressions, routed implementation and physical board tests. Keep per-run reports,
binary/source hashes and measurement JSON outside the source tree. Reference
results remain separate evidence. The timing
allocation and fail-closed export checks are described in [CONSTRAINTS.md](CONSTRAINTS.md).

Build commands use an output directory outside the checkout:

```sh
make -C fpga/arty-a7-t100 PLATFORM=jesd programs sim clock-test monitor-test \
  BUILD_ROOT="$RUN_DIR" JOBS=1 \
  CROSS_COMPILE=riscv64-elf- VIVADO="$VIVADO"
make -C fpga/arty-a7-t100 PLATFORM=jesd test
make -C fpga/arty-a7-t100 PLATFORM=jesd rom-test BUILD_ROOT="$RUN_DIR"
```

The Make simulation target uses short counters for development. For a production
wait and complete receive-envelope replay, invoke `native/build.py sim` with
`--full-waits --delay-ns 0 --return-ns 91 --dq-skew-ns 18`. Repeat in a separate
output directory with `--dq-skew-ns -25`. The existing per-lane delay adds0..7ns;
these two complete tuples are+18..25ns and-25..-18ns. The model records actual
arrivals, edge counts, core/CK periods, setup/hold, CS, reset and OE turnarounds.
The monitor rejects any measured lane outside the supported quarter-core bound.

The same Python CLI uses pin-level simulated JTAG or one explicit real CPU probe:

```sh
python3 -m tools.bringup.native --sim "$SIM" --image "$IMAGE_HEX" \
  --output "$RUN_DIR/probe" probe
python3 -m tools.bringup.native --sim "$SIM" --image "$IMAGE_HEX" \
  --boot-bin "$BOOT_BIN" --output "$RUN_DIR/boot" boot
python3 fpga/arty-a7-t100/native/tests/check_pin_result.py \
  "$RUN_DIR/boot/result.json" "$SIM_MANIFEST" --output "$RUN_DIR/qualified.json"
python3 -m tools.bringup.native --sim "$SIM" --image "$IMAGE_HEX" \
  --backup "$RUN_DIR/originals" --output "$RUN_DIR/scratch" scratch
python3 -m tools.bringup.native --sim "$SIM" --image "$IMAGE_HEX" \
  --output "$RUN_DIR/recovery" recover
```

`probe` checks CPU IDCODE, standard SBA, native identity/ABI and the8M/8M/16M
hardware guard readbacks. `boot` compares the approved read-only image and ROM
instructions, clears old markers, reset-halts, resumes and requires a fresh
completion in the XIP window and UART1 signature.
`scratch` requires an explicitly blank owned upper
sector, persists originals and in-flight state before commands, programs up to
1024 words and fully verifies erase/cleanup, boot and both neighbours. An
uncertain or nonblank sector is not automatically adopted or restored.

For an authorized physical run, replace the simulation options with
`--board-serial "$BOARD_SERIAL" --probe-serial "$PROBE_SERIAL"`. Boot, scratch
and recovery also require the reviewed post-configuration `--hardware-receipt`.
That receipt binds the actual configuration and old-reader originals; it is
created only after an authorized volatile configuration succeeds. A preceding
review/runplan records expected board/probe/target/bit hashes separately and
must not claim the bit is already loaded. A physical boot receipt also binds
`boot_mode`. Before loading an automatic-boot bitstream, the approved XIP image
must already be verified at physical `0x800000`; do not rely on a startup delay
to halt an unknown image. A new capture is needed when the authorized current
witness has expired. USB serial and the full Vivado target
identifier are separate observed fields; no suffix interpretation or prefix
matching is accepted. The CLI never configures the FPGA. Use the designated
board/probe and approved reader, and compare protected lower data through
that reader after the test. Native
SBA intentionally cannot read the lower partition and does not fake that check.

The DS/DIAG physical port is an `inout` directly connected to the real chip pad.
The original DIAG data/OE are retained and audited in the full mapped design.
Native-mode simulations check actual pad OE through reset and MMCM relock.
The target AC budget has been
cross-checked against the selected 256 Mb descriptor; the fitted device and
carrier still require electrical qualification.

The FPGA export normalizes the existing8KiB local RAM byte-address ports before
technology mapping. It folds only the three direct RAM address adders, retains
byte enables and transparent same-row write/read behavior, and absorbs the
existing address register through its real CE/reset controls. The original AXI
data register, response cycle and reset-free RAM contents are preserved. Local
proof/replay and actual RAM-cell mapping instructions are in tests/ram_opt. A
RAM-cell resource result does not establish complete fixture fit or routed timing.

`rom-test` checks the reset controller, AXI ROM and backend reset-window behavior in both XLENs,
and three real CPU boots per XLEN (initial boot, shared reset and MMCM relock).
The CPU fixture checks committed ROM instructions, the
XIP destination, native guard readbacks and actual physical READ headers.
It shortens startup counters for functional simulation. Existing production
wait, receiver-envelope, routed DS/OE timing and physical board qualification
remain separate requirements. This source change supplies no qualified bitstream
and does not resolve the outstanding absolute DS/OE timing limit.
