include $(AM_HOME)/scripts/isa/riscv.mk
include $(AM_HOME)/scripts/platform/ysyxsoc.mk
COMMON_CFLAGS += -march=rv32imc_zicntr_zicond_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32  # overwrite
LDFLAGS       += -melf32lriscv                    # overwrite

AM_SRCS += riscv/ysyxsoc/libgcc/div.S \
           riscv/ysyxsoc/libgcc/muldi3.S \
           riscv/ysyxsoc/libgcc/multi3.c \
           riscv/ysyxsoc/libgcc/ashldi3.c \
           riscv/ysyxsoc/libgcc/unused.c
