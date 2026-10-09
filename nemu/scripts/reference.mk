# Kconfig and fixdep use relative include/config paths. Keep a private working
# tree per reference defconfig; source links still track normal source edits.
REF_DEFCONFIG ?= riscv32_ref_defconfig
REF_CONFIGS := riscv32_ref_defconfig riscv64_ref_defconfig \
               riscv32_ref_2g_defconfig riscv64_ref_2g_defconfig
ifeq ($(filter $(REF_DEFCONFIG),$(REF_CONFIGS)),)
$(error Unsupported REF_DEFCONFIG=$(REF_DEFCONFIG); choose $(REF_CONFIGS))
endif
REF_DIR := $(NEMU_HOME)/build/ref/$(REF_DEFCONFIG)
REF_DRIVER := $(NEMU_HOME)/scripts/reference.mk

.PHONY: reference reference-build prepare
reference:
	@mkdir -p "$(REF_DIR)"
	+flock "$(REF_DIR)/.build.lock" $(MAKE) -C "$(REF_DIR)" -f "$(REF_DRIVER)" \
		reference-build REF_DEFCONFIG=$(REF_DEFCONFIG)

# Hold the per-profile lock over configuration AND compilation. Different
# profiles run concurrently; callers of the same profile reuse its result.
reference-build: .configured
	+$(MAKE) -C "$(REF_DIR)" -f "$(NEMU_HOME)/Makefile" app \
		BUILD_DIR="$(REF_DIR)" KCONFIG_PATH="$(REF_DIR)/tools/kconfig" \
		FIXDEP_PATH="$(REF_DIR)/tools/fixdep"

prepare:
	@ln -sfn "$(NEMU_HOME)/src" src
	@ln -sfn "$(NEMU_HOME)/configs" configs
	@mkdir -p tools/kconfig tools/fixdep
	@for tool in kconfig fixdep; do \
		for source in "$(NEMU_HOME)/tools/$$tool/"*; do \
			[ "$${source##*/}" = build ] && continue; \
			ln -sfn "$$source" "tools/$$tool/$${source##*/}"; \
		done; \
	done
	+$(MAKE) -s -C tools/kconfig BUILD_DIR="$(REF_DIR)/tools/kconfig/build" NAME=conf
	+$(MAKE) -s -C tools/fixdep BUILD_DIR="$(REF_DIR)/tools/fixdep/build"
	@# SoftFloat is independent of the NEMU configuration. Serialize only its
	@# bootstrap, since all four references share this third-party archive.
	+flock "$(NEMU_HOME)/build/.ref-softfloat.lock" $(MAKE) -s \
		-C "$(NEMU_HOME)/tools/spike-diff" repo/build/libsoftfloat.a

# Timestamp dependencies avoid reapplying an unchanged defconfig. The stamp
# also makes newly added Kconfig inputs effective on the next reference build.
.configured: $(NEMU_HOME)/configs/$(REF_DEFCONFIG) $(NEMU_HOME)/Kconfig \
             $(shell find $(NEMU_HOME)/src -name Kconfig) $(REF_DRIVER) \
             $(NEMU_HOME)/scripts/config.mk | prepare
	tools/kconfig/build/conf -s --defconfig="$(NEMU_HOME)/configs/$(REF_DEFCONFIG)" "$(NEMU_HOME)/Kconfig"
	tools/kconfig/build/conf -s --syncconfig "$(NEMU_HOME)/Kconfig"
	@touch $@

# Recover if generated configuration was explicitly removed from this profile.
ifeq ($(wildcard $(REF_DIR)/.config),)
.configured: prepare
endif
ifeq ($(wildcard $(REF_DIR)/include/config/auto.conf),)
.configured: prepare
endif
ifeq ($(wildcard $(REF_DIR)/include/generated/autoconf.h),)
.configured: prepare
endif
