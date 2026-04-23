# ============================================================================
# app/common.mk: Shared definitions for app/ build system
#
# Set APP_HOME before including this file.
# ============================================================================

RAPTOR_HOME ?= $(abspath $(APP_HOME)/..)
NSIM_HOME ?= $(RAPTOR_HOME)/nsim

# ---- Toolchain auto-detection ----
# app/ needs a libc-capable toolchain (newlib or glibc), NOT bare-metal riscv64-elf-.
# Always auto-detect; ignore inherited CROSS_COMPILE if it's bare-metal.
_NEED_DETECT := 0
ifeq ($(origin CROSS_COMPILE),undefined)
  _NEED_DETECT := 1
else ifeq ($(CROSS_COMPILE),riscv64-elf-)
  _NEED_DETECT := 1
endif
ifeq ($(_NEED_DETECT),1)
  ifneq ($(shell which riscv64-unknown-elf-gcc 2>/dev/null),)
    CROSS_COMPILE := riscv64-unknown-elf-
  else ifneq ($(shell which riscv64-linux-gnu-gcc 2>/dev/null),)
    CROSS_COMPILE := riscv64-linux-gnu-
  else
    $(warning No RISC-V toolchain with libc found. Run: make -C app setup)
    CROSS_COMPILE := riscv64-unknown-elf-
  endif
endif
CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
SIZE    := $(CROSS_COMPILE)size

# ---- picolibc detection (Ubuntu ships picolibc instead of newlib) ----
# Use picolibc for headers/libc but NOT its bare-metal crt0 (pk_io.c provides
# a pk-compatible _start instead).  -T pk-user.ld suppresses picolibc.ld
# (which places code at 0x80000000, conflicting with pk's memory).
_PICOLIBC_SPECS :=
_PICOLIBC_IO    :=
ifeq ($(shell uname),Linux)
  _PICOLIBC_SPECS := --specs=picolibc.specs -nostartfiles -T$(APP_HOME)/lib/pk-user.ld
  _PICOLIBC_IO    := $(APP_HOME)/lib/pk_io.c
endif

# ---- Architecture ----
ISA64 ?= 0 ## RV64 mode (0=RV32, 1=RV64)
ifeq ($(ISA64),1)
  ARCH   := rv64imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
  ABI    := lp64
  XLEN   := 64
  VFLAGS := -DRAPT_RV64
else
  ARCH   := rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
  ABI    := ilp32
  XLEN   := 32
  VFLAGS :=
endif

# ---- Build helpers ----
Q     := --no-print-directory
NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

CFLAGS_COMMON := $(_PICOLIBC_SPECS) -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O2 -Wall -g -static
