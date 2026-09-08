# ============================================================================
# app/benchmarks/coremark/Makefile: Build CoreMark as standard ELF
# ============================================================================

_THIS_DIR  := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME   := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk
.DEFAULT_GOAL := build

# ---- Directories ----
COREMARK_DIR := $(APP_HOME)/../abstract-machine/app/am-kernels/benchmarks/coremark_eembc/src
BUILD_DIR    := $(APP_HOME)/build/rv$(XLEN)/coremark
PORTME_DIR   := $(_THIS_DIR)portme

# ---- CoreMark config ----
ITERATIONS ?= 16
# Match hdl/include/npc/rapt_soc.svh and the selected DTS timebase-frequency.
# Override together with the simulator timer when using a custom clock model.
COREMARK_TIMEBASE_HZ ?= 10000000
# COREMARK_OPTIM_CFLAGS: optional aggressive optimization flags injected by the
# top-level `app-coremark-rv{32,64}-optim` targets. Empty by default so the
# plain `app-coremark-*` targets keep the -O2 baseline from CFLAGS_COMMON.
CFLAGS := $(CFLAGS_COMMON) -std=gnu99 \
          -I$(COREMARK_DIR) -I$(PORTME_DIR) \
          $(COREMARK_OPTIM_CFLAGS) \
          -DITERATIONS=$(ITERATIONS) -DPERFORMANCE_RUN=1 \
          -DCOREMARK_TIMEBASE_HZ=$(COREMARK_TIMEBASE_HZ) \
          -DCOMPILER_FLAGS=\""$(ARCH)"\"

# ---- Build rules ----

CORE_SRCS := core_list_join.c core_main.c core_matrix.c core_state.c core_util.c
PORT_SRCS := core_portme.c

OBJS := $(patsubst %.c,$(BUILD_DIR)/%.o,$(CORE_SRCS) $(PORT_SRCS))
ELF  := $(BUILD_DIR)/coremark.elf
CONFIG_STAMP := $(BUILD_DIR)/.build-config
shell_quote = '$(subst ','"'"',$(1))'

# Iterations and optimization flags change code even when sources are unchanged.
$(CONFIG_STAMP): FORCE
	@mkdir -p $(dir $@)
	@printf '%s\n' $(call shell_quote,$(CC) $(CFLAGS) $(_PICOLIBC_IO)) > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

$(OBJS): $(CONFIG_STAMP) $(MAKEFILE_LIST) $(PORTME_DIR)/core_portme.h

$(BUILD_DIR)/core_portme.o: $(PORTME_DIR)/core_portme.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $(PORTME_DIR)/core_portme.c -o $@

$(BUILD_DIR)/%.o: $(COREMARK_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $(COREMARK_DIR)/$*.c -o $@

$(ELF): $(OBJS) $(_PICOLIBC_IO) $(APP_HOME)/lib/pk-user.ld
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(OBJS) $(_PICOLIBC_IO) -o $@
	@$(SIZE) $@

_build: $(ELF)
	@:

# ---- Public targets ----
build: ## Build coremark.elf
	@$(MAKE) $(Q) _build

clean:
	rm -rf $(BUILD_DIR)

-include $(OBJS:.o=.d)

FORCE:
.PHONY: build _build clean FORCE
