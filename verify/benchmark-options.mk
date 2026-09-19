BENCH_OPT ?= baseline## Benchmark compiler preset (baseline|optimized)
BENCH_OPT := $(strip $(BENCH_OPT))
ifeq ($(filter $(BENCH_OPT),baseline optimized),)
$(error BENCH_OPT must be baseline or optimized)
endif
export BENCH_OPT

# --- CoreMark "optimized" runs with CoreMark/MHz reporting ----------------
# COREMARK_OPTIM_CFLAGS holds aggressive GCC flags that maximize CoreMark/MHz on
# the Raptor core. They are injected into the CoreMark build (consumed by
# the benchmark overlay). BENCH_OPT=baseline keeps the AM baseline flags. The benchmark overlay
# tracks effective compiler flags and rebuilds objects when they change.
# CoreMark/MHz is frequency-independent: iterations * 1e6 / active_cycles
# (mirrors third_party/cvw/benchmarks/coremark's XCFLAGS + score extraction).
COREMARK_OPTIM_PRESET := \
	-O3 -funroll-all-loops -finline-functions \
	-falign-functions=16 -falign-jumps=4 -mbranch-cost=1 \
	-DSKIP_DEFAULT_MEMSET -mtune=sifive-3-series \
	--param=uninlined-function-insns=8 --param=loop-max-datarefs-for-datadeps=0 \
	-fipa-pta -fno-tree-vrp -fwrapv

COREMARK_OPTIM_CFLAGS ?= $(if $(filter optimized,$(BENCH_OPT)),$(COREMARK_OPTIM_PRESET),)
export COREMARK_OPTIM_CFLAGS


# Optimized Dhrystone codegen.
DHRYSTONE_OPTIM_PRESET := \
	-O3 -funroll-loops -finline-functions -falign-functions=16 \
	-fbuiltin -fno-builtin-printf -fno-builtin-puts -fno-builtin-putchar

DHRYSTONE_OPTIM_CFLAGS ?= $(if $(filter optimized,$(BENCH_OPT)),$(DHRYSTONE_OPTIM_PRESET),)
export DHRYSTONE_OPTIM_CFLAGS

