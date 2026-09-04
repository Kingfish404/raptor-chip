# ============================================================================
# app/benchmarks/coremark/Makefile: Build CoreMark as standard ELF
# ============================================================================

_THIS_DIR  := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME   := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

# ---- Directories ----
COREMARK_DIR := $(APP_HOME)/../abstract-machine/app/am-kernels/benchmarks/coremark_eembc/src
BUILD_DIR    := $(APP_HOME)/build/rv$(XLEN)/coremark
PORTME_DIR   := $(_THIS_DIR)portme

# ---- CoreMark config ----
ITERATIONS ?= 16
# COREMARK_OPTIM_CFLAGS: optional aggressive optimization flags injected by the
# top-level `app-coremark-rv{32,64}-optim` targets. Empty by default so the
# plain `app-coremark-*` targets keep the -O2 baseline from CFLAGS_COMMON.
CFLAGS := $(CFLAGS_COMMON) -std=gnu99 \
          -I$(COREMARK_DIR) -I$(PORTME_DIR) \
          $(COREMARK_OPTIM_CFLAGS) \
          -DITERATIONS=$(ITERATIONS) -DPERFORMANCE_RUN=1 \
          -DCOMPILER_FLAGS=\""$(ARCH)"\"

# ---- Build rules ----

CORE_SRCS := core_list_join.c core_main.c core_matrix.c core_state.c core_util.c
PORT_SRCS := core_portme.c

OBJS := $(patsubst %.c,$(BUILD_DIR)/%.o,$(CORE_SRCS) $(PORT_SRCS))
ELF  := $(BUILD_DIR)/coremark.elf

$(BUILD_DIR)/core_portme.o: $(PORTME_DIR)/core_portme.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: $(COREMARK_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $^ $(_PICOLIBC_IO) -o $@
	@$(SIZE) $@

_build: $(ELF)
	@:

# ---- Public targets ----
build: ## Build coremark.elf
	@$(MAKE) $(Q) _build

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build _build clean
