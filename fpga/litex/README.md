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

## Directory Structure

```
fpga/litex/
+-- Makefile            # Build system (run 'make help')
+-- setup_env.sh        # Environment setup (venv + LiteX install)
+-- raptor_soc.py       # LiteX SoC definition + sim entry point
+-- README.md           # This file
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

Both variants wrap the same RTL (configured via `rtl_sv/include/rapt_config.svh`). The
variant label is passed to LiteX purely to select SoC-level defaults.

| Variant    | Use Case                                |
| ---------- | --------------------------------------- |
| `standard` | Sim & FPGA (BIOS-only, no Linux image)  |
| `linux`    | Linux boot (integrates OpenSBI + Image) |

Select variant: `make sim VARIANT=linux`

## Commands

| Command                   | Description                                        |
| ------------------------- | -------------------------------------------------- |
| `make setup`              | Install LiteX + register Raptor CPU                |
| `make pack`               | Pack RTL into single .sv                           |
| `make sim`                | Verilator simulation                               |
| `make sim-trace`          | Simulation with FST waveform                       |
| `make coremark`           | Build + run CoreMark in sim                        |
| `make linux`              | Build + run Linux payload in sim                   |
| `make fpga-build`         | Build Tang Mega 138K Pro hardware bitstream        |
| `make fpga-load`          | Load Tang Mega 138K Pro SRAM bitstream             |
| `make fpga-flash`         | Flash Tang Mega 138K Pro external SPI flash        |
| `make fpga-console`       | Open Tang Mega 138K Pro UART console               |
| `make main-fpga`          | Build + upload FPGA main firmware                  |
| `make irqtest-fpga`       | Build + upload minimal IRQ test firmware           |
| `make coremark-fpga`      | CoreMark to FPGA main_ram via serialboot           |
| `make app-llm-infer`      | app/ LLM inference benchmark in LiteX sim          |
| `make app-llm-infer-fpga` | app/ LLM benchmark to FPGA main_ram via serialboot |
| `make clean`              | Remove build artifacts                             |
| `make help`               | Show all targets                                   |

## FPGA Firmware Upload (via BIOS serialboot)

The `main-fpga`, `donut-fpga`, and `irqtest-fpga` targets enable rapid firmware iteration on the Tang Mega 138K Pro without rebuilding the FPGA bitstream (~10 min). Firmware is compiled to main_ram (@ 0x80000000) and uploaded via BIOS serialboot.

**Prerequisites:**
1. Flashed BIOS bitstream: `make fpga-flash BOOT_MODE=bios` (one-time setup)
2. INTEGRATED_MAIN_RAM_SIZE > 0 in the bitstream (default 512 KB)
3. UART connected @ 115200 baud

**Usage:**
```bash
# Build + upload main interactive shell (includes donut, primes, memtest, etc.)
make main-fpga

# Quick alias for main-fpga
make donut-fpga

# Upload minimal IRQ test firmware
make irqtest-fpga

# Upload RLLMBench payloads
make app-llm-ops-fpga
make app-llm-infer-fpga
make app-llm-train-fpga

# Explicit UART port (if auto-detection fails)
make main-fpga UART_PORT=/dev/tty.usbserial-20250303171 UART_BAUD=115200

# Build only (no upload)
make main-fpga-build
```

## app/ Payloads

The `app/` tree can produce LiteX-native flat binaries when a program links
against `app/lib/litex/start.S`, `app/lib/litex/link.ld`, and
`app/lib/litex/runtime.c`. This is the preferred route for running app tests on
FPGA: build or load a BIOS bitstream once, then use BIOS serialboot instead of
re-running Gowin PnR for every payload.

Current first-class app payloads are the RLLMBench fixed-point LLM workloads.
They print `RLLMBENCH_RESULT` and `RLLMBENCH_SCORE` lines on the UART, matching
the pk/NPC report format used by `make -C app llm-bench-report-npc`.

```bash
# LiteX simulation
make app-llm-ops
make app-llm-infer
make app-llm-train

# Override when the SoC time CSR is not 1 MHz
make app-llm-infer RLLMBENCH_TIMEBASE_HZ=50000000

# FPGA upload via BIOS serialboot
make app-llm-fpga BENCH=infer UART_PORT=/dev/tty.usbserial-...

# Generic prebuilt app payload upload
make app-fpga-upload APP_FPGA_BIN=/path/to/app.bin UART_PORT=/dev/tty.usbserial-...
```

RLLMBench uses `rdtime` by default and reports `score_per_sec` from physical
seconds only. Set `RLLMBENCH_TIMEBASE_HZ` to the real `time` CSR frequency so
LiteX simulation, FPGA boards, pk/NPC, and native ports remain directly
comparable. When producing reports from copied serial logs, pass the board or
simulation core clock as `--core-clock-mhz <MHz>` to `report.py` to derive
`score_per_mhz`, the CoreMark/MHz-style work-per-million-core-cycles metric.

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
|  \- LiteDRAM (FPGA targets)                |
+--------------------------------------------+
```

## Environment Variables

| Variable                   | Description                          | Default       |
| -------------------------- | ------------------------------------ | ------------- |
| `RAPTOR_HOME`              | Root of raptor-chip repo             | Auto-detected |
| `VARIANT`                  | CPU variant                          | `standard`    |
| `SYS_CLK`                  | System clock frequency (Hz)          | `50000000`    |
| `FPGA_SYS_CLK`             | Tang Mega hardware clock (Hz)        | `15000000`    |
| `FPGA_BOOT_MODE`           | Tang Mega boot ROM source            | `bios`        |
| `FPGA_SYNTH_MAXFAN`        | Gowin synthesis maxfan guide         | `48`          |
| `FPGA_ROUTE_MAXFAN`        | Gowin route maxfan guide             | `12`          |
| `RLLMBENCH_TIMEBASE_HZ`    | RLLMBench `time` CSR frequency in Hz | `1000000`     |
| `RLLMBENCH_CORE_CLOCK_MHZ` | Core clock for score/MHz reports     | `SYS_CLK/1e6` |
| `EXTRA_FLAGS`              | Extra flags for `raptor_soc.py`      | (empty)       |

## Dependencies

- Python 3.8+
- Verilator 5.0+ (for simulation)
- RISC-V GCC toolchain (`riscv64-unknown-elf-gcc`)
- LiteX (installed via `make setup`)
