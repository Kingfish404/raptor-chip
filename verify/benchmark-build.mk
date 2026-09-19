# Load after the upstream benchmark Makefile (-f Makefile -f this-file).
# AM tracks source/header timestamps, but not command-line compiler flags.
CFLAGS += $(if $(filter coremark,$(NAME)),$(COREMARK_OPTIM_CFLAGS),$(if $(filter dhrystone,$(NAME)),$(DHRYSTONE_OPTIM_CFLAGS),))

# Keep a per-ARCH signature so ITERATIONS and other CFLAGS cannot silently
# reuse an object from an earlier benchmark run. Do not clean other arches.
ifeq ($(NAME):$(PLATFORM),coremark:npc)
# A command-line ITERATIONS=N still overrides this simulator default.
ITERATIONS = 2
endif

BENCHMARK_BUILD_STAMP = $(DST_DIR)/.benchmark-build-flags
define benchmark_build_flags
CC=$(CC)
CFLAGS=$(CFLAGS)
endef

.PHONY: benchmark-check-flags
$(BENCHMARK_BUILD_STAMP): benchmark-check-flags
	$(file >$@.tmp,$(benchmark_build_flags))
	@cmp -s "$@.tmp" "$@" && rm -f "$@.tmp" || mv -f "$@.tmp" "$@"
	@echo "Benchmark configuration: ARCH=$(ARCH), ITERATIONS=$(ITERATIONS)"

$(OBJS): $(BENCHMARK_BUILD_STAMP)
