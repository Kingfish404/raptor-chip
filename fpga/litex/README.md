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

| Variant    | Issue | ROB | L1I  | L1D   | Use Case   |
| ---------- | ----- | --- | ---- | ----- | ---------- |
| `standard` | 2     | 8   | 1 KB | 512 B | Sim & FPGA |
| `linux`    | 2     | 16  | 8 KB | 4 KB  | Linux boot |

Select variant: `make sim VARIANT=linux`

## Commands

| Command          | Description                         |
| ---------------- | ----------------------------------- |
| `make setup`     | Install LiteX + register Raptor CPU |
| `make pack`      | Pack RTL into single .sv            |
| `make sim`       | Verilator simulation                |
| `make sim-trace` | Simulation with FST waveform        |
| `make coremark`  | Build + run CoreMark in sim         |
| `make linux`     | Build + run Linux payload in sim    |
| `make clean`     | Remove build artifacts              |
| `make help`      | Show all targets                    |

## Architecture

```
┌────────────────────────────────────────────┐
│  Raptor Core (ysyx.sv)                     │
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

| Variable      | Description                     | Default       |
| ------------- | ------------------------------- | ------------- |
| `RAPTOR_HOME` | Root of raptor-chip repo        | Auto-detected |
| `VARIANT`     | CPU variant                     | `standard`    |
| `SYS_CLK`     | System clock frequency (Hz)     | `50000000`    |
| `EXTRA_FLAGS` | Extra flags for `raptor_soc.py` | (empty)       |

## Dependencies

- Python 3.8+
- Verilator 5.0+ (for simulation)
- RISC-V GCC toolchain (`riscv64-unknown-elf-gcc`)
- LiteX (installed via `make setup`)
