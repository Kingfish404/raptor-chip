# Raptor LiteX SoC Integration

LiteX SoC integration for the [Raptor](../../) dual-issue out-of-order RISC-V core.

## Quick Start

```bash
# 1. Install LiteX environment
make setup
# 2. Pack RTL
make pack
# 3. Run Verilator simulation (BIOS serial)
make sim
# 4. Run CoreMark benchmark
make coremark
```

## Tang Mega 138K Pro Hardware Flow

```bash
# Install LiteX environment
make setup
# Build the real-FPGA bitstream
make fpga-build
# Load it to the connected board over USB
make fpga-load
# Open the UART console
make fpga-console
```

## MLK-CU07-KU15P Hardware Flow (Xilinx Vivado)

Milianke MLK-CU07-KU15P (Kintex UltraScale+ `xcku15p-ffva1156-2-e`). UART-only bring-up SoC (integrated ROM/SRAM, no DDR4) over the on-board USB-UART.

```bash
# Source the Vivado settings so `vivado` is on PATH, e.g.:
source /opt/Xilinx/2025.2/Vivado/settings64.sh
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/License.lic

# Build the verified BIOS bitstream (synth + P&R via Vivado), then load it:
make fpga-build FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios
make fpga-load FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios

# Open the BIOS console. Press reset if the BIOS banner already timed out.
make fpga-console FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload and run payloads through BIOS serialboot:
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
make coremark-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 COREMARK_ITERATIONS=1000

# Persist to the on-board QSPI flash:
make fpga-flash FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small
```

Expected: `fpga-build` writes `build/mlk_cu07_ku15p/bios/gateware/mlk_cu07_ku15p.bit` plus a zero-error report dashboard (`.../index.html`); BIOS reaches `litex>` after a passing memtest; `main-fpga` reports `memtest: PASS`; `coremark-fpga` prints `Correct operation validated` + an `Iterations/Sec` line.

Notes:
- FPGA goals default to `RAPT_CONFIG=middle` (KU15P-safe). Use `=small` for the compact legacy flow; `=default` builds but is not yet a passing KU15P smoke path.
- `BOOT_MODE=custom` (default) boots `firmware/fpga` from ROM; `BOOT_MODE=bios` boots the LiteX BIOS and is required for serialboot uploads.
- Board pins come from `third_party/security-hw-fpga/board/mlk-cu07-ku15p/`. `UART_PORT` defaults to `/dev/ttyUSB0`; override with `UART_PORT=/dev/ttyUSBx`.
- `fpga-load`/`fpga-flash` drive Vivado in batch mode (`scripts/vivado_load.tcl`, `scripts/vivado_flash.tcl`).

## Experimental KU15P Linux FPGA Flow (Vivado MIG)

Linux-oriented KU15P bitstream: `VARIANT=linux`, LiteX BIOS, on-board 4 GB DDR4 via Xilinx MIG mapped as `main_ram` at `0x80000000` (1 GiB by default). Setting `VARIANT=linux` (or `linux64`) on any FPGA goal auto-activates the **Linux FPGA profile**, which flips the defaults to `FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios WITH_MIG=1 INTEGRATED_MAIN_RAM_SIZE=0`, `SYS_CLK=50000000` (50 MHz), `UART_BAUD=230400`, and the KU15P-safe `middle` preset — override any of them on the command line. The legacy LiteDRAM path is still available via `WITH_LITEDRAM=1`. `make fpga-build VARIANT=linux` only succeeds if the Vivado timing report meets constraints; the bitstream lands under `build/mlk_cu07_ku15p/bios-linux-mig-middle/gateware/`.

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/License.lic

# Build the timing-clean Linux/MIG bitstream, load it, open console
# (VARIANT=linux already implies 230400 baud, MIG, the KU15P board, etc.):
make fpga-build VARIANT=linux
make fpga-load  VARIANT=linux
make fpga-console VARIANT=linux UART_PORT=/dev/ttyUSB0
# Smoke test (~660 B stage0-only image validates serialboot, DDR, relocation): make fpga-smoke-upload VARIANT=linux UART_PORT=/dev/ttyUSB0

# Full OpenSBI+Linux image (press reset if the serialboot window timed out):
make fpga-upload VARIANT=linux UART_PORT=/dev/ttyUSB0

# One-shot build+load, then upload; and QSPI flash:
make fpga VARIANT=linux
make fpga-upload VARIANT=linux UART_PORT=/dev/ttyUSB0
make fpga-build VARIANT=linux && make fpga-flash VARIANT=linux

# See `make help` or the Commands table below for all upload variants.
```

Key conventions:
- The bitstream knobs `BOOT_MODE=bios INTEGRATED_MAIN_RAM_SIZE=0 WITH_MIG=1` are all auto-set by the Linux FPGA profile (`VARIANT=linux`). DDR4 MIG IP `raptor_ddr4_0` maps 1 GiB at `0x80000000`.
- Images live under `build/firmware/linux-fpga/`: stage0 copies `fw_payload.bin` to `0x80000000` + DTB to `LINUX_FPGA_DTB_ADDR` (default `0x83f00000`), jumps with `a0=0, a1=DTB`.
- Payload-only iteration: once the bitstream is loaded, just re-run the matching upload target (`make fpga-upload VARIANT=linux`, `make coremark-fpga VARIANT=linux`, …) — no re-synthesis needed.
- Raw `BIN` uploads (`make fpga-upload VARIANT=linux BIN=…`) carry no OpenSBI args/DTB/relocation; the image must bring its own LiteX MMIO runtime.
- Hardware-changing knobs require a new bitstream; `make fpga VARIANT=linux` (build + load) rebuilds first, while `make fpga-load VARIANT=linux` loads the existing bitstream without rebuilding.

Status: this is still Linux bring-up, not yet equivalent to the verified 512 KiB integrated-RAM BIOS/CoreMark flow. The `middle` preset routes and meets timing at 50 MHz, passes BIOS DDR memtest, and reaches `litex>`; `make coremark-fpga VARIANT=linux` runs CoreMark from MIG DDR. The fully enabled `default` preset still fails KU15P hardware smoke and needs more microarchitecture debugging. Directed xsim checks (`make -C ../../verify xsim-l2-ordered-mmio`, `xsim-l1d-byte-rom`, `xsim-bus-l1d-rlast`, `xsim-ioq-pending-lock`) should each print `PASS`.

## Directory Structure

```
fpga/litex/
+-- Makefile            # Build system (run 'make help')
+-- setup_env.sh        # Environment setup (venv + LiteX install)
+-- raptor_soc.py       # Verilator simulation SoC entry point
+-- raptor_tang_mega_138k_pro.py  # Tang Mega 138K Pro FPGA SoC entry point
+-- raptor_mlk_cu07_ku15p.py      # MLK-CU07-KU15P Vivado/MIG FPGA SoC entry point
+-- README.md           # This file
+-- firmware/           # Sim, integrated-ROM FPGA, and Linux-FPGA stage0 firmware
+-- benchmarks/         # LiteX-native CoreMark/Embench payloads
+-- tests/              # Small standalone LiteX C payloads
+-- scripts/            # LiteX/Vivado patching, reports, load/flash helpers
+-- glsim/              # Gate-level simulation helpers
\-- cores/cpu/raptor/   # LiteX CPU integration files
    +-- __init__.py     # Python package marker
    +-- core.py         # CPU class (AXI4 bus, variants, sources)
    +-- crt0.S          # Startup assembly (trap, .data/.bss init)
    +-- boot-helper.S   # Boot jump helper
    +-- system.h        # Cache flush, CSR macros
    +-- irq.h           # Interrupt management API
    \-- csr-defs.h      # CSR address definitions
```

## CPU Variants

Raptor's microarchitecture preset is selected separately with `RAPT_CONFIG=<name>`, which maps to `hdl/configs/<name>/rapt_config.svh` during RTL packing. The LiteX CPU `VARIANT` still selects SoC/software defaults, but Linux variants also add RTL preprocessor defines through `RAPT_PACK_VFLAGS` (`-DRAPT_LINUX`, and `-DRAPT_RV64` for `linux64`).

| Variant    | Use Case                               |
| ---------- | -------------------------------------- |
| `standard` | Sim & FPGA (BIOS-only, no Linux image) |
| `linux`    | RV32 Linux/OpenSBI boot                |
| `linux64`  | RV64 experiments                       |

Select variant directly with `make sim VARIANT=linux`, or use convenience targets such as `make linux` (sim) and `make fpga-build VARIANT=linux` (KU15P Linux/MIG FPGA).

## Commands

| Command                                | Description                                        |
| -------------------------------------- | -------------------------------------------------- |
| `make setup`                           | Install LiteX + register Raptor CPU                |
| `make pack`                            | Pack RTL into single .sv                           |
| `make sim`                             | Verilator simulation (LiteX BIOS by default)       |
| `make sim-trace`                       | Simulation with FST waveform                       |
| `make coremark`                        | Build + run CoreMark in sim                        |
| `make linux`                           | Build + run Linux payload in sim                   |
| `make fpga-build VARIANT=linux`        | Build KU15P Linux/MIG bitstream (timing-gated)     |
| `make fpga VARIANT=linux`              | Build if needed, then load KU15P Linux bitstream   |
| `make fpga-load VARIANT=linux`         | Load existing KU15P Linux bitstream (timing-gated) |
| `make fpga-smoke-img`                  | Build tiny stage0-only KU15P smoke image           |
| `make fpga-smoke-upload`               | Upload tiny stage0-only smoke image                |
| `make fpga-smoke`                      | From-scratch build/load, then smoke upload         |
| `make fpga-upload VARIANT=linux`       | Upload stage0+OpenSBI+DTB through BIOS serialboot  |
| `make fpga-img`                        | Build stage0+OpenSBI+DTB image (no upload)         |
| `make fpga-opensbi-img`                | Build stage0+standalone OpenSBI+DTB image          |
| `make fpga-opensbi-upload`             | Upload standalone OpenSBI through BIOS serialboot  |
| `make fpga-upload VARIANT=linux BIN=…` | Upload raw flat payload through Linux/MIG BIOS     |
| `make coremark-fpga VARIANT=linux`     | CoreMark through Linux/MIG BIOS serialboot         |
| `make main-fpga VARIANT=linux`         | Main RAM FPGA shell through Linux/MIG BIOS         |
| `make app-fpga-upload VARIANT=linux`   | LiteX-native app bin through Linux/MIG BIOS        |
| `make fpga-console VARIANT=linux`      | Open Linux/MIG FPGA UART console                   |
| `make fpga-tinyos-prepare`             | Build egos/xv6 TinyOS artifacts for checks         |
| `make fpga-tinyos-check`               | Explain egos/xv6 FPGA serialboot requirements      |
| `make fpga-egos-prepare`               | Build `egos.bin` and `disk.img`                    |
| `make fpga-egos-upload`                | Prepare egos, then guard or force raw upload       |
| `make fpga-xv6-prepare`                | Build xv6 `kernel.bin` and `fs.img`                |
| `make fpga-xv6-upload`                 | Prepare xv6, then refuse current RV32 bitstream    |
| `make fpga-flash VARIANT=linux`        | Flash KU15P Linux/MIG bitstream to QSPI            |
| `make fpga-build`                      | Build the selected FPGA board bitstream            |
| `make fpga-load`                       | Load the selected FPGA board volatile bitstream    |
| `make fpga-flash`                      | Flash the selected FPGA board persistent bitstream |
| `make fpga-console`                    | Open the selected FPGA board UART console          |
| `make fpga-upload`                     | Upload firmware to main_ram via BIOS serialboot    |
| `make main-fpga`                       | Build + upload FPGA main firmware                  |
| `make irqtest-fpga`                    | Build + upload minimal IRQ test firmware           |
| `make coremark-fpga`                   | CoreMark to FPGA main_ram via serialboot           |
| `make app-llm-infer`                   | app/ LLM inference benchmark in LiteX sim          |
| `make app-llm-infer-fpga`              | app/ LLM benchmark to FPGA main_ram via serialboot |
| `make clean`                           | Remove build artifacts                             |
| `make help`                            | Show all targets                                   |

## FPGA Firmware Upload (via BIOS serialboot)

The `main-fpga`, `irqtest-fpga`, `coremark-fpga`, and `app-llm-*-fpga` targets iterate firmware without rebuilding the bitstream: firmware is compiled to main_ram (`0x80000000`) and uploaded via BIOS serialboot. Prerequisites: a loaded/flashed BIOS bitstream (`make fpga FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small`), `INTEGRATED_MAIN_RAM_SIZE > 0` (default 512 KB), and UART @ 115200. Uploads use `litex_term --safe` by default; set `SERIALBOOT_SAFE=0` for the faster multi-frame mode.

```bash
# Build + upload main interactive shell:
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload CoreMark (save log for later reporting):
make coremark-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 COREMARK_ITERATIONS=1000 \
    2>&1 | tee /tmp/raptor-ku15p-coremark.log

# RLLMBench FPGA payloads:
make app-llm-infer-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
```

If `litex_term` reports a serialboot timeout, press the board reset button with the same command still running. OpenSBI/Linux runs in sim (`make linux`) and on the experimental KU15P MIG path (`make fpga-* VARIANT=linux`); the verified day-to-day FPGA smoke path is the 512 KiB integrated-RAM BIOS/CoreMark flow above.

## app/ Payloads

The `app/` tree can produce LiteX-native flat binaries when a program links against `app/lib/litex/start.S`, `app/lib/litex/link.ld`, and `app/lib/litex/runtime.c`. This is the preferred route for running app tests on FPGA: build or load a BIOS bitstream once, then use BIOS serialboot instead of re-running place-and-route for every payload.

Current first-class app payloads are the RLLMBench fixed-point LLM workloads. They print `RLLMBENCH_RESULT` and `RLLMBENCH_SCORE` lines on the UART, matching the pk/NPC report format used by `make -C app llm-bench-report-npc`.

```bash
# LiteX simulation
make app-llm-ops
make app-llm-infer
make app-llm-train

# Override when the SoC time CSR is not 1 MHz
make app-llm-infer RLLMBENCH_TIMEBASE_HZ=50000000

# FPGA upload via BIOS serialboot
make app-llm-fpga BENCH=infer FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Generic prebuilt app payload upload
make app-fpga-upload APP_FPGA_BIN=/path/to/app.bin FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Same app payload, but using the KU15P Linux/MIG DDR bitstream
# (VARIANT=linux selects the MIG board + 230400 baud automatically)
make app-fpga-upload VARIANT=linux APP_FPGA_BIN=/path/to/app.bin UART_PORT=/dev/ttyUSB0
```

RLLMBench uses `rdtime` by default and reports `score_per_sec` from physical seconds only. Set `RLLMBENCH_TIMEBASE_HZ` to the real `time` CSR frequency so LiteX simulation, FPGA boards, pk/NPC, and native ports remain directly comparable. When producing reports from copied serial logs, pass the board or simulation core clock as `--core-clock-mhz <MHz>` to `report.py` to derive `score_per_mhz`, the CoreMark/MHz-style work-per-million-core-cycles metric.

## Architecture

```
+--------------------------------------------+
|  Raptor Core (rapt.sv)                     |
|  +- Dual-issue OoO, RV32IMAC + Zb*         |
|  \- AXI4 Master (32-bit addr, 32-bit data) |
+---------+----------------------------------+
          | AXI4 Full
          v
+--------------------------------------------+
|  LiteX SoC Interconnect                    |
|  +- AXI -> Wishbone converter              |
|  +- UART (serial console)                  |
|  +- Timer                                  |
|  +- SRAM (integrated)                      |
|  \- main_ram (integrated, LiteDRAM, or MIG)|
+--------------------------------------------+
```

## Environment Variables

| Variable                   | Description                                       | Default                                                       |
| -------------------------- | ------------------------------------------------- | ------------------------------------------------------------- |
| `RAPTOR_HOME`              | Root of raptor-chip repo                          | Auto-detected                                                 |
| `VARIANT`                  | CPU variant (`standard`, `linux`, `linux64`)      | `standard`                                                    |
| `SYS_CLK`                  | System clock frequency (Hz)                       | `10000000` (`50000000` in linux FPGA profile)                 |
| `SIM_THREADS`              | Verilator evaluation threads per LiteX simulation | `4`                                                           |
| `SIM_TIMEOUT`              | Per-benchmark Embench timeout when overridden     | `1200` for `make embench`                                     |
| `EMBENCH_JOBS`             | Parallel Vsim processes for `make embench`        | Auto-detected                                                 |
| `FPGA_BOARD`               | FPGA board target                                 | `tang_mega_138k_pro` (`mlk_cu07_ku15p` in linux FPGA profile) |
| `BOOT_MODE`                | FPGA boot ROM source                              | `custom` (`bios` in linux FPGA profile)                       |
| `RAPT_CONFIG`              | RTL config preset                                 | `middle` for FPGA goals, otherwise `default`                  |
| `INTEGRATED_MAIN_RAM_SIZE` | FPGA main RAM size at `0x80000000`                | `0x80000` (`0` in linux FPGA profile)                         |
| `WITH_LITEDRAM`            | Use external LiteDRAM/DDR4 for FPGA main RAM      | `0`                                                           |
| `LITEDRAM_SIZE`            | Mapped external LiteDRAM main RAM size            | `0x40000000`                                                  |
| `WITH_MIG`                 | Use external Xilinx DDR4 MIG for FPGA main RAM    | `0` (`1` in linux FPGA profile)                               |
| `MIG_SIZE`                 | Mapped external MIG main RAM size                 | `0x40000000`                                                  |
| `LINUX_FPGA_RAM_SIZE`      | Linux FPGA DDR window advertised in DTB           | `MIG_SIZE`                                                    |
| `LINUX_FPGA_DTB_ADDR`      | Runtime DTB address passed to OpenSBI             | `0x83f00000`                                                  |
| `UART_PORT`                | FPGA UART device                                  | Auto-detected; KU15P prefers `/dev/ttyUSB0`                   |
| `UART_BAUD`                | FPGA UART baud rate                               | `115200` (`230400` in linux FPGA profile)                     |
| `SERIALBOOT_SAFE`          | Use `litex_term --safe` for uploads               | `1`                                                           |
| `GOWIN_APP`                | Gowin IDE app bundle path                         | Auto-detected on macOS                                        |
| `RLLMBENCH_TIMEBASE_HZ`    | RLLMBench `time` CSR frequency in Hz              | `1000000`                                                     |
| `RLLMBENCH_CORE_CLOCK_MHZ` | Core clock for score/MHz reports                  | `SYS_CLK/1e6`                                                 |
| `EXTRA_FLAGS`              | Extra flags for the selected LiteX target script  | (empty)                                                       |

### Embench Simulation

```bash
make embench
# CI-style Linux smoke: one Vsim process, using the host CPUs internally.
make embench SIM_TIMEOUT=300 SIM_THREADS="$(nproc)" EMBENCH_JOBS=1 \
    EMBENCH_NETTLE_SHA256_LOCAL_SCALE=1
```

Per-benchmark logs and `summary.md` are written to `sim/build/<RAPT_CONFIG>/logs/litex/embench-logs/`. A benchmark is successful only after its UART output contains `--- done ---`; a missing binary, Vsim early exit, or timeout is recorded as `ERROR` or `TIMEOUT` and makes `make embench` return nonzero. A non-default `EMBENCH_NETTLE_SHA256_LOCAL_SCALE` keeps SHA-256 as a correctness smoke check and excludes it from the partial aggregate; retain the default scale `562` when reporting an official Embench score. That scale is necessary but not sufficient: the run must also select all 19 canonical workloads and every workload must pass with reference data. Each actual run atomically records its source revision, patch identity, clock, scale, and benchmark selection in `run-config.env`; reports use that manifest and reject an explicitly conflicting scale override.
