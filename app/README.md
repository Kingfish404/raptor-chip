# app/ — RISC-V User-Space Programs

Standalone RISC-V programs that compile to standard ELFs and run on any RISC-V Linux environment (real hardware, QEMU user-mode, or via Raptor's riscv-pk proxy kernel).

## Quick Start

```bash
# Build everything
make all

# Build and run specific test suites via pk on NPC (default)
make isa-tests        # ISA correctness verification
make memory-tests     # Memory subsystem tests
make algo-tests       # Algorithm correctness tests
make demos            # Demo programs
make coremark         # CoreMark benchmark
make embench          # Embench-IoT benchmarks

# Run on NEMU instead of NPC
make isa-tests   RUN_ON=nemu
make tests       RUN_ON=nemu
make demos       RUN_ON=nemu

# Build only (no run)
make tests-build
make demos-build

# Run with QEMU user-mode (after build)
qemu-riscv32 build/rv32/tests/isa/rv_add.elf
qemu-riscv64 build/rv64/tests/isa/rv_add.elf

# Build for RV64
make tests-build ISA64=1
```

## Directory Structure

```
app/
├── Makefile          # Top-level build orchestrator
├── common.mk         # Shared toolchain / flag definitions
├── README.md         # This file
├── tests/            # Correctness verification tests
│   ├── isa/          #   ISA instruction-level tests
│   ├── memory/       #   Memory access pattern tests
│   ├── algo/         #   Algorithm correctness tests
│   └── hello/        #   Minimal hello world
├── demos/            # Interactive demo programs
├── benchmarks/       # Performance benchmarks
│   ├── coremark/     #   CoreMark (auto-cloned from EEMBC)
│   └── embench/      #   Embench-IoT (auto-cloned)
├── lib/              # Picolibc I/O stubs (Linux toolchain only)
├── pk/               # riscv-pk proxy kernel (for running on NPC)
└── build/            # Build outputs (rv32/ or rv64/)
```

## Test Suites

### ISA Verification (`tests/isa/`)

Instruction-level tests using inline assembly. Each test verifies correct behavior of specific ISA instructions, including edge cases.

| Test            | Description                                                                   |
| --------------- | ----------------------------------------------------------------------------- |
| `rv_add`        | ADD/ADDI/SUB, overflow, RV64 ADDW/SUBW                                        |
| `rv_shift`      | SLL/SRL/SRA, shift amount masking, RV64 SLLW/SRAW                             |
| `rv_logic`      | AND/OR/XOR/LUI/AUIPC, bitwise identities                                      |
| `rv_mul_div`    | MUL/MULH/DIV/REM, div-by-zero, overflow (M extension)                         |
| `rv_branch`     | BEQ/BNE/BLT/BGE/BLTU/BGEU, JAL/JALR return address                            |
| `rv_slt`        | SLT/SLTU/SLTI/SLTIU, SEQZ/SNEZ pseudo-instructions                            |
| `rv_bitmanip`   | Zba (sh*add), Zbb (clz/ctz/cpop/min/max/rev8/sext), Zbs (bset/bclr/binv/bext) |
| `rv_compressed` | C extension: patterns that emit compressed instructions                       |
| `rv_zicond`     | Zicond: CZERO.EQZ/CZERO.NEZ, branchless conditional move                      |

### Memory Tests (`tests/memory/`)

| Test             | Description                                                               |
| ---------------- | ------------------------------------------------------------------------- |
| `load_store`     | LB/LH/LW/LD, SB/SH/SW/SD, sign-extension, store-to-load forwarding, fence |
| `memory_pattern` | Sequential, strided, pseudo-random access; memset/memcpy validation       |
| `stack_test`     | Deep recursion, large stack frames, register save/restore, SP alignment   |

### Algorithm Tests (`tests/algo/`)

| Test         | Description                                                            |
| ------------ | ---------------------------------------------------------------------- |
| `sorting`    | Bubble sort, selection sort, quicksort with various input patterns     |
| `crc32`      | CRC-32 table lookup, verified against known IEEE 802.3 test vectors    |
| `math_test`  | Fibonacci, prime sieve, GCD, 4×4 matrix multiply                       |
| `string_ops` | strlen, strcmp, strcpy, memset, memcpy, reverse, itoa, case conversion |

## Demo Programs (`demos/`)

Interactive terminal programs demonstrating various computational patterns.

| Demo         | Description                                                  |
| ------------ | ------------------------------------------------------------ |
| `donut`      | Spinning 3D ASCII donut (fixed-point trig, z-buffer)         |
| `cmatrix`    | Matrix digital rain animation (ANSI color)                   |
| `langton`    | Langton's Ant cellular automaton                             |
| `life`       | Conway's Game of Life (glider, R-pentomino, LWSS)            |
| `hanoi`      | Tower of Hanoi animated solver (8 disks, 255 moves)          |
| `mandelbrot` | Mandelbrot set ASCII renderer (fixed-point Q12)              |
| `sysinfo`    | Print RISC-V ISA info, performance counters, CPI measurement |

## Running with QEMU

All programs are standard static RISC-V ELFs. They can run on any RISC-V Linux userspace:

```bash
# Install QEMU user-mode (Ubuntu/Debian)
sudo apt install qemu-user qemu-user-binfmt

# RV32
qemu-riscv32 app/build/rv32/demos/mandelbrot.elf

# RV64
make demos-build ISA64=1
qemu-riscv64 app/build/rv64/demos/mandelbrot.elf
```

When using the newlib toolchain (`riscv64-unknown-elf-gcc`), programs link against riscv-pk syscall stubs. For the Linux toolchain (`riscv64-linux-gnu-gcc`), QEMU's Linux user-mode emulation handles syscalls natively.

## Running on NPC (via pk)

Programs run on the Raptor NPC simulator via riscv-pk proxy kernel:

```bash
# Run a single test on NPC
make pk-run USER_ELF=app/build/rv32/tests/isa/rv_add.elf

# Run all tests on NPC
make tests ARGS="-b -n"

# Run all tests on NPC with difftest (from project root)
make app-tests-npc32-difftest ARGS="-b -n"
```

## Running on NEMU (via pk)

The same pk+ELF images can also run on NEMU (software ISS). Use `RUN_ON=nemu` to switch the runtime:

```bash
# Run a single test on NEMU
make nemu-run USER_ELF=app/build/rv32/tests/isa/rv_add.elf ARGS="-b"

# Run all tests on NEMU
make tests RUN_ON=nemu ARGS="-b"

# From project root (auto-configures and builds NEMU)
make app-tests-nemu32 ARGS="-b"
make app-demos-nemu32 ARGS="-b"
```

> **Note:** NEMU must be configured first (e.g., `make config-nemu32` from project root).
> Tests running on NEMU can optionally use Spike as a difftest reference (via NEMU's own Kconfig).

## Toolchain

The build system auto-detects available toolchains:

1. `riscv64-unknown-elf-gcc` (newlib) — preferred for bare-metal/pk
2. `riscv64-linux-gnu-gcc` (glibc/picolibc) — works with QEMU user-mode

Install with:
```bash
# macOS
brew tap riscv-software-src/riscv
brew install riscv-software-src/riscv/riscv-gnu-toolchain

# Ubuntu/Debian
sudo apt install gcc-riscv64-unknown-elf  # newlib
sudo apt install gcc-riscv64-linux-gnu    # glibc
```

## Adding New Programs

1. Create a `.c` file in the appropriate directory (`tests/isa/`, `tests/memory/`, `tests/algo/`, or `demos/`)
2. The pattern Makefiles auto-discover `*.c` files — no Makefile edit needed for individual programs
3. For a new test category, add the ELF name to the list in `app/Makefile` and add a run loop
4. Programs should use only standard C library functions (`stdio.h`, `stdlib.h`, `string.h`, `stdint.h`)
5. Tests should print pass/fail summary and return `EXIT_FAILURE` on any failure
