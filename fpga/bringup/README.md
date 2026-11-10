# Returned-chip FPGA platform

This is an explicit MLK-CU08-KU15P board port for the pin-limited chip in
bridge mode. The chip powers up in ROM-XIP; the host selects the bridge through
JTAG/SBA boot control and ndmreset before checking DIAG. IRQ is an ordinary
interrupt input. It does not change the native board or Arty defaults.
Processor/chip sources come from the existing common FPGA source helper,
including `synth/configs/pin-limited/rtl`; generate decoders with `make verilog`
before building. Program builds also require the public `am-kernels` cpu-tests
sources under `abstract-machine/app/am-kernels`, as in the root build flow.
Current integration results require fresh FPGA implementation;
old routed evidence from a different source snapshot does not qualify this port.

Start with [the bring-up guide](../../docs/bringup.md) for wiring, safe power-on,
host commands and the test plan. This directory contains no board programming
target. An emulation image holds the physical chip connector in reset.

```sh
export BRINGUP_WORK=/path/to/large-disk/bringup
make -C fpga/bringup programs sim BUILD_ROOT="$BRINGUP_WORK" JOBS=4
make -C fpga/bringup test
make -C fpga/bringup clock-test BUILD_ROOT="$BRINGUP_WORK"
PYTHONDONTWRITEBYTECODE=1 python3 -m tools.bringup.validate \
  --sim "$BRINGUP_WORK/sim/sim/bringup-sim" \
  --programs "$BRINGUP_WORK/programs/programs" --output "$BRINGUP_WORK/results.json"
make -C fpga/bringup emulation BUILD_ROOT="$BRINGUP_WORK" JOBS=4
```

Run `hardware` in a separate output directory to build the physical chip port.
Run only one Vivado process at a time; the script checks for 25 GiB available
memory and rejects more than four jobs. It snapshots packed sources and the
Tcl/XDC inputs in the work directory. Preserve those files with timing,
utilization, CDC, DRC, I/O and source fingerprint reports.

For a constraint-only audit, run `cu08/build.tcl` in a fresh output directory
with the routed `.dcp` as its first argument, followed by the current XDC,
emulation flag and job count. It reloads all timing constraints, checks the
existing route and generates reports/bitstream without resynthesizing logic.
Use a full build after any RTL change.

`BRINGUP_WAVE=/path/on/output-disk/minimal.vcd` enables waveform capture in a
simulator process. Use a small payload and remove that environment variable for
long cpu-test runs. Pin timing and target state are sufficient to diagnose the
link before looking at core internals. The format command for this isolated
snapshot uses `verible-verilog-format --indentation_spaces=2 --column_limit=100`
only on the bring-up sources and changed board-side target.

The simulation carrier has a bridge target and no NOR. It gates that target
until JTAG selects bridge mode and explicitly overrides only Flash startup,
reset, recovery and WIP polling to 2000/32/4000/4096 chip clocks. The emulation
wrapper's default values remain the production defaults. `Board.power_on()`
waits for halt acknowledgement, writes boot control, applies ndmreset and checks
active selection before resuming. It does not require a reset strap. Production
waits are measured in chip clocks, so a slow simulator must not confuse a host
wall-time deadline with elapsed Flash initialization time.
