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
├── Makefile            # Build system (run 'make help')
├── setup_env.sh        # Environment setup (venv + LiteX install)
├── raptor_soc.py       # LiteX SoC definition + sim entry point
├── README.md           # This file
└── cores/cpu/raptor/   # LiteX CPU integration files
    ├── __init__.py     # Python package marker
    ├── core.py         # CPU class (AXI4 bus, variants, sources)
    ├── crt0.S          # Startup assembly (trap, .data/.bss init)
    ├── boot-helper.S   # Boot jump helper
    ├── system.h        # Cache flush, CSR macros
    ├── irq.h           # Interrupt management API
    └── csr-defs.h      # CSR address definitions
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

| Command             | Description                                 |
| ------------------- | ------------------------------------------- |
| `make setup`        | Install LiteX + register Raptor CPU         |
| `make pack`         | Pack RTL into single .sv                    |
| `make sim`          | Verilator simulation                        |
| `make sim-trace`    | Simulation with FST waveform                |
| `make coremark`     | Build + run CoreMark in sim                 |
| `make linux`        | Build + run Linux payload in sim            |
| `make fpga-build`   | Build Tang Mega 138K Pro hardware bitstream |
| `make fpga-load`    | Load Tang Mega 138K Pro SRAM bitstream      |
| `make fpga-flash`   | Flash Tang Mega 138K Pro external SPI flash |
| `make fpga-console` | Open Tang Mega 138K Pro UART console        |
| `make clean`        | Remove build artifacts                      |
| `make help`         | Show all targets                            |

## Architecture

```
┌────────────────────────────────────────────┐
│  Raptor Core (rapt.sv)                     │
│  ├─ Dual-issue OoO, RV32IMAC + Zb*         │
│  └─ AXI4 Master (32-bit addr, 32-bit data) │
└─────────┬──────────────────────────────────┘
          │ AXI4 Full
          ▼
┌────────────────────────────────────────────┐
│  LiteX SoC Interconnect                    │
│  ├─ AXI → Wishbone converter               │
│  ├─ UART (serial console)                  │
│  ├─ Timer                                  │
│  ├─ SRAM (integrated)                      │
│  └─ LiteDRAM (FPGA targets)                │
└────────────────────────────────────────────┘
```

## Environment Variables

| Variable            | Description                     | Default       |
| ------------------- | ------------------------------- | ------------- |
| `RAPTOR_HOME`       | Root of raptor-chip repo        | Auto-detected |
| `VARIANT`           | CPU variant                     | `standard`    |
| `SYS_CLK`           | System clock frequency (Hz)     | `50000000`    |
| `FPGA_SYS_CLK`      | Tang Mega hardware clock (Hz)   | `15000000`    |
| `FPGA_BOOT_MODE`    | Tang Mega boot ROM source       | `bios`        |
| `FPGA_SYNTH_MAXFAN` | Gowin synthesis maxfan guide    | `48`          |
| `FPGA_ROUTE_MAXFAN` | Gowin route maxfan guide        | `12`          |
| `EXTRA_FLAGS`       | Extra flags for `raptor_soc.py` | (empty)       |

## Dependencies

- Python 3.8+
- Verilator 5.0+ (for simulation)
- RISC-V GCC toolchain (`riscv64-unknown-elf-gcc`)
- LiteX (installed via `make setup`)
