# Raptor LiteX SoC — minimal C microbenchmarks

Small self-contained C programs that boot directly from `main_ram` (`0x80000000`) on the Raptor LiteX SoC. No AM, no OpenSBI, no device tree — just a `start.S` crt0 plus a single `.c` file with `main()`.

## Why these exist

The standard `am-kernels/microbench` bundle contains stale pre-built object files that target the *old* NPC MMIO RTC address (`0x02000048`). On LiteX that address is unmapped, so the very first call to `uptime()` hangs the AXI bus and looks like a CPU stall.

These tests:

- Use only the **LiteX sim UART** (`0xf0001800`) for I/O.
- Use only the **CLINT mtime register** (`0x0200BFF8`) or the `rdcycle` CSR for timing — both are intercepted in `rapt_bus.sv` and never touch AXI.
- Are short enough to run to completion on Verilator sim within the default `SIM_TIMEOUT=30s` budget.

## Available tests

Build-isolation host checks (temporary outputs only; no synthesis or board access):

```bash
fpga/litex/.venv/bin/python -B fpga/litex/tests/test_build_isolation.py
```

Checks parallel RV32/RV64 default/small preprocessing, cache reuse, Make/CPU pack-path agreement, configuration-specific output paths, read-only Make configuration evaluation with auto-detection disabled, and private BIOS copies.

KU15P DDR/PMA host checks (no shared RTL packing or board access):

```bash
fpga/litex/.venv/bin/python -B fpga/litex/tests/test_ddr_pma.py
make -C verify verilator-addr-classification-ku15p-rv32 verilator-addr-classification-ku15p-rv64
```

Run these from the repository root. They check the 1 GiB pack/default contract and RAM/MMIO PMA boundaries for both XLENs; they do not test physical DDR cells.

| Target          | What it does                                       |
| --------------- | -------------------------------------------------- |
| `test-hello`    | Prints "Hello from Raptor LiteX SoC!" and halts.   |
| `test-fib`      | Iteratively computes fib(40). Exercises the ALU.   |
| `test-prime`    | Counts primes < 2000. Exercises div/mod + branches.|
| `test-memcpy`   | Copies a 64 KiB buffer byte-by-byte.               |
| `test-mul`      | Multiplies 10000 u32 pairs. Exercises MUL unit.    |
| `tests`         | Build all test binaries.                           |
| `tests-run`     | Build + run every test in sequence.                |

## Usage

```bash
cd fpga/litex

# Build + run one test:
make test-hello

# Build + run all:
make tests-run

# Override timeout:
make test-prime SIM_TIMEOUT=60

# Override Verilator threads:
make test-memcpy SIM_THREADS=8
```

Each test prints:

1. A header line identifying the test.
2. Its result (or a short summary).
3. The elapsed cycle count (via `rdcycle`).
4. A terminating `[PASS]` line.

A run is considered successful when the `[PASS]` line appears.

## Production default configuration check

```bash
fpga/litex/.venv/bin/python fpga/litex/tests/test_production_config.py
python3 fpga/litex/tests/test_netboot_profile.py
```

Checks that CPU ILA probes, boot-hold reset and insertion hooks stay removed, and that the fixed netboot profile uses the shared default microarchitecture. Architectural JTAG/DM and simulation-only verification instrumentation remain.

## CPU interrupt adapter check

From the repository root:

```bash
fpga/litex/.venv/bin/python fpga/litex/tests/test_irq_mapping.py
```

This checks the RV32 and RV64 adapter expressions for every external PLIC source: LiteX IRQ `n` maps to PLIC source `n+1` for `n=0..30`. LiteX bit 31 has no corresponding source on the 31-source Raptor PLIC. This is a wiring test, not a test of PLIC claim/complete handling or Linux interrupt delivery.

## Ethernet device tree check

```bash
python3 fpga/litex/tests/test_ethernet_dts.py
```

Checks exported MAC regions and slot sizes, Raptor's IRQ offset, rejection of cached buffers, and compilation with `dtc`. To include a single Ethernet MAC in the FPGA Linux DT, pass `LINUX_FPGA_ETH_CSR=/absolute/path/to/csr.json` to the existing FPGA image/DT build. The JSON must come from the Ethernet gateware actually being loaded. With `WITH_ETHERNET=1`, the build automatically exports the matching SoC CSR map before creating the DT. Without Ethernet, the default preserves a DT without the node. Explicitly specifying a CSR file alone does not add hardware or FMC pins.

## CM005 peripheral checks

```bash
fpga/litex/.venv/bin/python fpga/litex/tests/test_cm005.py
```

Checks immutable CU07/CU08 board configuration and alternating construction in one process, active-high reset duration, and rejects unverified connector mappings, and elaborates CU07/CU08 peripherals (100/1000 Mb/s, both with and without LiteDRAM), checking the CSR layout and emitted DDR I/O constraints. For CU08 FMC_A without LiteDRAM it also checks the nearby Ethernet clock placement and separate RX control/data delays (900/950 ps); other direct-clock variants retain 1000 ps. The C-slot sampler uses separate 460/0 ps clock/data delays. CPU RTL source collection is deliberately omitted. The 100M tests cover byte/nibble conversion with seeded backpressure, packet ends, odd-nibble error signaling, mid-byte reset, and the exact three MDIO writes repeated after PHY reset. This is not synthesis, timing closure or board validation.

The MLK targets accept `WITH_ETHERNET=1 FMC_SLOT=a ETH_PORT=a` in the existing Makefile build commands. CU08 now defaults to short-edge `FMC_SLOT=c ETH_PORT=a`; the new mapping is also elaborated for RV32/RV64 with and without LiteDRAM. Its non-GC RX clock is sampled as data at 1.25 GS/s, with independent routed sampling-window checks. The RX processing clock is 156.25 MHz. Confirm the actual baseboard and 1.8 V FMC VADJ before loading a bitstream. The default `ETH_SPEED=1000` advertises only 1000BASE-T full duplex and restarts auto-negotiation after each PHY reset. Generic Make/Python targets and the opt-in RV32/RV64 network profiles all default to 1000 Mb/s. Explicit 100 Mb/s remains available for legacy tests with a compatible peer, but is not used for current board acceptance. `test_rv32_network.py` verifies the RV32 Make/image target, ISA, output isolation, gigabit policy and rejection of wrong-XLEN/ABI packages; RV64 defaults remain covered by `test_rv64_network.py`. These profile tests do not run synthesis. CM005's reset gate is active HIGH and shared by ETHA/ETHB, so resetting ETHA also resets ETHB.

For functional simulation of the production converters and AMD I/O primitives, generate a standalone design and run `tb_cm005_100m.sv` with Vivado XSim:

```bash
# Run from the repository root, with Vivado tools on PATH.
RAPTOR_CM005_TEST_DIR=$(mktemp -d /tmp/raptor-cm005-100m.XXXXXX)
RAPTOR_CM005_REPO=$PWD
fpga/litex/.venv/bin/python fpga/litex/tests/cm005_100m_xsim.py "$RAPTOR_CM005_TEST_DIR"
cd "$RAPTOR_CM005_TEST_DIR"
xvlog -sv cm005_100m.v "$RAPTOR_CM005_REPO/fpga/litex/tests/tb_cm005_100m.sv" \
    "$XILINX_VIVADO/data/verilog/src/glbl.v"
xelab tb_cm005_100m glbl -L unisims_ver -L secureip -mt 4 \
    -timescale 1ns/1ps -s cm005_100m_tb
xsim cm005_100m_tb -runall
```

Require the explicit `PASS CM005 100M primitives` message and no fatal/error: XSim can return zero after a simulation failure. The test checks 512 bytes in each direction, frame ends, duplicated TX nibbles and functional setup/hold; it does not model PCB skew or replace static timing analysis.

### CU08 short-edge peripheral STA

CU08 short-edge FMC_C/ETHA physical feasibility can be checked separately:

```bash
RAPTOR_CM005_STA_DIR=$(mktemp -d /tmp/raptor-cm005-c-sta.XXXXXX)
fpga/litex/.venv/bin/python -B fpga/litex/tests/cm005_short_edge_sta.py "$RAPTOR_CM005_STA_DIR"
```

This routes the production CRG/PHY and constraints with observable RX logic, without CPU or DDR, and does not load the board. Inspect `peripheral_timing.rpt` and `peripheral_rx.rpt`; successful bitstream generation does not establish timing closure. `cm005_aperture.rpt` must also pass; no non-GC RX clock exception is used. `--litedram` tests the 400 MHz reference-clock variant, still without CPU or DDR datapaths in the routed test design. Use `--speed 1000` for the gigabit path (including common-source-clock DDR TX), in a different output directory. Full-SoC STA and physical Ethernet traffic tests remain separate requirements.

`test_cm005_oversample.py` checks phase and delay-mismatch sweeps, RX_ER, odd nibbles, full-size frames, clock-stop error termination/recovery and mid-byte reset. For the actual sampler primitives, emit with `cm005_oversample_xsim.py` and compile/run `tb_cm005_oversample.sv` using the same XSim flow as above (top `tb_cm005_oversample`). Require its explicit PASS message. The test sweeps 64 phases, three input apertures and three relative delay bounds with +/-20 ps sample spacing variation. Analog metastability MTBF and physical Ethernet BER remain outside these simulations.

### FMC_C gigabit regressions

`test_cm005_gigabit.py` verifies DDR byte pairing across sample-word boundaries, phase/skew/frequency/duty-cycle variation, back-to-back full frames, RX_ER, clock startup/stop/glitches, reset, and errored termination after backpressure.

For the production RX primitives, generate with `cm005_oversample_xsim.py OUTPUT_DIR --speed 1000` and compile/run `tb_cm005_gigabit_oversample.sv` (top `tb_cm005_gigabit_oversample`) using the XSim flow above. Require `PASS CM005 gigabit oversample primitives` and no fatal/error. It checks 55,296 bytes across 64 phases, three apertures, three relative-delay bounds, and three frequency/duty-cycle corners.

Also generate with `--clock-buffers` and compile the same testbench with `xvlog --sv -d RX_CLOCK_BUFFERS`. This exercises the production parallel BUFGCE_DIV `/1` and `/4` buffers from a single 625 MHz source, including divider reset at each phase case. Require the same byte count and PASS marker. Neither clock variant replaces post-route clock/aperture checks or board tests.

`test_cm005_sample_alignment.py` runs the same digital protocol cases with two-sample delayed RXD1/RXD3 and the configurable lane correction enabled. It also checks independent lane advances through seven samples at every sample-word edge. To test this correction with physical primitives, generate with `--speed 1000 --clock-buffers --data-sample-advance 0 2 0 2` and compile the gigabit testbench with both `-d RX_CLOCK_BUFFERS -d RX_ODD_LANE_DELAY`. The latter adds 1.6 ns to odd data lanes in the independent PHY stimulus. Use `xelab --timescale 1ns/1ps` for generated modules without a timescale. Require the same 55,296-byte PASS marker; a zero process exit alone is not sufficient because XSim can return zero after a kernel startup exception.

The independent control calibration is covered by the same digital suite, including DV, RX_ER, frame end, and control-only word-boundary cases. For the experimental CU08/FMC_C/port A control candidate, also generate with `--control-sample-advance 1` and compile with `-d RX_CONTROL_LANE_DELAY`, which adds 0.8 ns to the independent control stimulus. Keep the other two defines above. This is a calibrated digital test, not proof of physical control-lane margin. The one-sample candidate is not enabled by the board configuration: an extreme-aperture primitive test exposed a false RX_ER on a final byte, despite passing the captured-frame replays. Do not treat it as an accepted calibration. For the separate two-sample control candidate, use `--control-sample-advance 2` and additionally compile with `-d RX_CONTROL_DELAY_PS=1600`. This retains all phase/aperture checks but models an independent 1.6 ns control delay; it does not turn the 0.8 ns model's failure into a pass. Board error-rate validation remains required.

An external eleven-probe raw RX ILA CSV can be replayed using `test_cm005_sample_alignment.py --capture CAPTURE.csv`. This diagnostic checks the captured baseline and one-sample correction against the two-sample candidate using the actual Migen receiver, CRC, and (when present) the known 1514-byte stimulus. Baseline/one-sample results are diagnostic: a narrower-margin setting may still pass an individual capture. Use `--require-one-step-failure` only for identified captures reproducing that regression. The two-sample candidate must pass every complete frame. Passing replay does not qualify board timing, analog margin, or BER. Use `--control-offset 1` to replay the independent control calibration. Known-payload checking recognizes both the ramp-pattern 0x88b6 frames and the SHAKE256-derived 0x88b7 pseudo-random diagnostic frames.

`test_cm005_mac_receive.py` exercises the real LiteEth MAC at sys=50 MHz, RX=156.25 MHz, TX=125 MHz, including CDC and width conversion. It checks short preambles, byte-enable/CRC handling, partial final words, full-size frames, TX padding/FCS and no within-frame TX gaps. The byte-domain CRC checker requires `PHY.source.last_be = PHY.source.last`; a converter after the checker cannot supply this retrospectively. The test's simulator adapter only supplies unused read signals for Migen's handling of write-only memory ports; it does not replace the FIFOs or their CDC logic. Valid-FCS frames with isolated PHY errors exercise the first four payload bytes, later payload and final FCS byte, each followed by a clean frame. The current LiteEth byte CRC checker forwards the current input error while delaying data, losing errors during its initial four-byte FIFO fill. `CM005RXFrameError` therefore retains errors until the accepted frame end on the gigabit oversampling path. A negative control reproduces the loss without this adapter; this is separate from CRC corruption detection. Use `--capture CAPTURE.csv` to feed actual decoded ILA bytes through both MAC configurations. This reproduces the shortened-preamble failure of the 32-bit checker without changing receiver sampling phase. Physical timing and board network reliability still require separate validation.

For production TX primitives, generate with `cm005_gigabit_tx_xsim.py OUTPUT_DIR` and compile/run `tb_cm005_gigabit_tx.sv` (top `tb_cm005_gigabit_tx`). Require `PASS CM005 gigabit TX primitives` and no fatal/error. The test checks 6,072 bytes with actual BUFGCE_DIV startup/restart, TX_ER, full-size frames and minimum interframe gap. These are functional primitive tests, not routed timing or hardware throughput/BER claims.

The optional `--experimental-split-clock` generator flag models the physical TX-clock ECO: independent common-source divide-by-two MAC/PHY buffers and a `BUFGCE` with `CE_TYPE=SYNC` for the serial clock, enabled by modeled PLL lock. Run the same testbench in a separate output directory. This is an experimental topology, not the production CRG; passing the functional startup/restart test does not prove routed MAC-to-PHY timing or analog PLL lock behavior.

## Linux BIOS boot-hook check

```bash
python3 fpga/litex/tests/test_bios_linux_override.py
```

Checks both the legacy SD-specific and current shared FATFS binary boot hooks, preservation of unrelated edits when refreshing generated data, and rejection of unknown override markers. Firmware generation must still compile the resulting private BIOS to validate the complete build.

## Netboot workflow contracts

```sh
fpga/litex/.venv/bin/python -m unittest discover -s fpga/litex/tests -p 'test_netboot*.py'
```

Checks firmware packaging, fixed Make profiles, source/bitstream and timing coverage gates, locking, UART command status and colored prompts, static/dynamic BIOS IP handling, TFTP protocol checks and host state restoration. Network checks cover observed LLDP drop accounting, trace overflow/sample boundaries and owned-resource cleanup. These host tests never program a board or change host networking. Hardware acceptance uses `fpga-netboot-rvXX-load`, manual BIOS netboot, and `-test` as documented in [NETBOOT.md](../NETBOOT.md).

## Legacy whole-cache maintenance hook

```bash
python3 fpga/litex/tests/test_cache_maintenance.py
```

Checks all 64 mapped SRAM CBO addresses and surrounding fences, the current set-selection coverage contract, and real RV32/RV64 compilation (when the cross-toolchain is installed). The no-argument LiteX hook must cover every set; `cbo.flush 0(x0)` faults on KU15P and is not a whole-cache trigger. These firmware tests do not replace SD DMA buffer-reuse checks on hardware.
