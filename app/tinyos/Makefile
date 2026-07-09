# ============================================================================
# app/tinyos/Makefile — tiny teaching OS integration (egos-2000 / xv6-riscv)
# ============================================================================

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/..)
include $(APP_HOME)/common.mk

# ============================================================================
# Configuration
# ============================================================================
TINYOS_DIR    ?= $(abspath $(APP_HOME)/tinyos)## Source root for tiny teaching OS repositories (inside app/tinyos)
EGOS_REPO_URL ?= https://github.com/yhzhang0128/egos-2000.git## egos-2000 source repository URL
XV6_REPO_URL  ?= https://github.com/mit-pdos/xv6-riscv.git## xv6-riscv source repository URL
OS            ?=## Target OS: egos (RV32/Sv32) or xv6 (RV64/Sv39)
SYNC          ?= 1## Set to 0 to skip source repository update
ARGS          ?= -b -n## Simulator arguments
MAX_INST      ?=## Maximum instruction limit
TIMEOUT       ?=## Wall-clock timeout in seconds (nsim only)
QEMU          ?=## Override QEMU executable (optional)
XV6_CPUS      ?= 3## CPU count for xv6 QEMU
XV6_EXTRA_CFLAGS ?= -Wno-error=unused-but-set-variable## Extra CFLAGS appended to the copied xv6 build tree

# xv6 uses RV64 toolchain; probe in order of preference.
XV6_OBJCOPY ?= $(firstword $(foreach t, \
    riscv64-unknown-elf-objcopy riscv64-elf-objcopy riscv64-none-elf-objcopy \
    riscv64-linux-gnu-objcopy riscv64-unknown-linux-gnu-objcopy, \
    $(if $(shell command -v $t 2>/dev/null),$t)))## Override xv6 objcopy (auto-detected)

# egos uses RV32 toolchain.
EGOS_NOSTDLIB ?= 1## Use app-provided tiny libc for egos (avoids compiler libc dependency)
EGOS_ARCH     ?= rv32imac_zicsr## ISA string for egos
EGOS_ABI      ?= ilp32## ABI for egos
EGOS_RISCV_CC ?= $(firstword $(foreach t, \
    riscv32-unknown-elf-gcc riscv64-unknown-elf-gcc riscv-none-elf-gcc riscv64-elf-gcc, \
    $(if $(shell command -v $t 2>/dev/null),$t)))## Override egos compiler (auto-detected)
EGOS_RISCV_PREFIX := $(patsubst %gcc,%,$(EGOS_RISCV_CC))
EGOS_OBJDUMP  ?= $(EGOS_RISCV_PREFIX)objdump## Override egos objdump (auto-detected)
EGOS_OBJCOPY  ?= $(EGOS_RISCV_PREFIX)objcopy## Override egos objcopy (auto-detected)

EGOS_CFLAGS ?= -march=$(EGOS_ARCH) -mabi=$(EGOS_ABI) \
               -Wl,--gc-sections -ffunction-sections -fdata-sections \
               -fdiagnostics-show-option
EGOS_LDFLAGS ?= -nostdlib $(if $(filter 1,$(EGOS_NOSTDLIB)),-lgcc,-lc -lgcc)

EGOS_RUNTIME_LIBC := $(APP_HOME)/lib/runtime/libc_min.c
EGOS_RUNTIME_INCLUDE := $(APP_HOME)/lib/runtime/include
NSIM_SRC_DIR  := $(APP_HOME)/build/tinyos-nsim-src
EGOS_NSIM_DIR := $(NSIM_SRC_DIR)/egos-2000
XV6_NSIM_DIR  := $(NSIM_SRC_DIR)/xv6-riscv

# Raptor-local modifications to the (gitignored) upstream egos-2000 clone live
# as patches under patches/egos-2000/ (git-tracked via app/.gitignore's
# !tinyos/patches/** allow-rule). The clone stays pristine and re-cloneable;
# the patches are applied onto the build-tree copy at prepare time.
EGOS_PATCH_DIR := $(_THIS_DIR)patches/egos-2000
EGOS_APPS_DEPS := apps/*.* library/egos.h library/*/* Makefile
EGOS_EGOS_DEPS := earth/* grass/* library/egos.h library/*/* Makefile
ifeq ($(EGOS_NOSTDLIB),1)
EGOS_CFLAGS    += -I$(EGOS_RUNTIME_INCLUDE) -DRAPT_LIBC_MIN_MALLOC=1
EGOS_APPS_DEPS += $(EGOS_RUNTIME_LIBC) $(wildcard $(EGOS_RUNTIME_INCLUDE)/*.h)
EGOS_EGOS_DEPS += $(EGOS_RUNTIME_LIBC) $(wildcard $(EGOS_RUNTIME_INCLUDE)/*.h)
endif

EGOS_SIM_IMAGE  := $(EGOS_NSIM_DIR)/tools/egos.bin
EGOS_SIM_SDCARD := $(EGOS_NSIM_DIR)/tools/disk.img
SIM_LIMIT_ARGS  := $(if $(MAX_INST),-m $(MAX_INST)) $(if $(TIMEOUT),-t $(TIMEOUT))
NEMU_LIMIT_ARGS := $(if $(MAX_INST),-m $(MAX_INST))

# ============================================================================
# Helpers
# ============================================================================

# Verify the egos RV32 toolchain can produce a freestanding binary.
define EGOS_TOOLCHAIN_CHECK
	@[ -n "$(EGOS_RISCV_CC)" ] || { \
		echo "[ERR] Cannot find RV32 GCC for egos (tried riscv32-unknown-elf-gcc, riscv64-unknown-elf-gcc, riscv-none-elf-gcc)"; \
		echo "      Minimal Debian/Ubuntu install:"; \
		echo "        sudo apt update"; \
		 echo "        sudo apt install -y build-essential gcc-riscv64-unknown-elf"; \
		echo "      Or run the repository setup: ./setup.sh"; \
		echo "      Or override: EGOS_RISCV_CC=/path/to/riscv64-unknown-elf-gcc"; \
		exit 1; }
	@tmp_c=$$(mktemp /tmp/egos-rv32-check-XXXX.c); \
	printf 'void _start(void){}\n' > $$tmp_c; \
	$(EGOS_RISCV_CC) -march=$(EGOS_ARCH) -mabi=$(EGOS_ABI) -nostdlib $$tmp_c -lgcc \
		-o $${tmp_c%.c}.elf >/dev/null 2>&1 \
	|| { rm -f $$tmp_c $${tmp_c%.c}.elf; \
		echo "[ERR] $(EGOS_RISCV_CC) cannot link $(EGOS_ARCH)/$(EGOS_ABI) freestanding binaries."; \
		echo "      Install an RV32-capable RISC-V GCC with $(EGOS_ARCH)/$(EGOS_ABI) libgcc support:"; \
		echo "        sudo apt update"; \
		 echo "        sudo apt install -y build-essential gcc-riscv64-unknown-elf"; \
		echo "      Or set EGOS_RISCV_CC to a working compiler."; \
		exit 1; }; \
	rm -f $$tmp_c $${tmp_c%.c}.elf
endef

# Build xv6 kernel.bin + copy fs.img to a tmpfs, then run on a simulator.
# $(1)=tag  $(2)=tmp-prefix  $(3)=run-target  $(4)=extra-make-vars  $(5)=limit-args
define xv6-run-body
	@[ -n "$(XV6_OBJCOPY)" ] || { \
		echo "[ERR] Cannot find RV64 objcopy for xv6"; \
		echo "      Minimal Debian/Ubuntu install:"; \
		echo "        sudo apt update"; \
		 echo "        sudo apt install -y build-essential gcc-riscv64-unknown-elf"; \
		echo "      Or override: XV6_OBJCOPY=/path/to/riscv64-unknown-elf-objcopy TOOLPREFIX=/path/to/riscv64-unknown-elf-"; \
		exit 1; }
	@$(MAKE) $(Q) -C "$(XV6_NSIM_DIR)" kernel/kernel fs.img
	@$(XV6_OBJCOPY) -O binary "$(XV6_NSIM_DIR)/kernel/kernel" "$(XV6_NSIM_DIR)/kernel/kernel.bin"
	@tmp_fs=$$(mktemp "$${TMPDIR:-/tmp}/$(2).XXXXXX"); \
	cp "$(XV6_NSIM_DIR)/fs.img" "$$tmp_fs"; \
	echo "[$(1)] RV64 / Sv39 (xv6-riscv)"; \
	echo "[$(1)] kernel=$(XV6_NSIM_DIR)/kernel/kernel.bin"; \
	echo "[$(1)] disk copy=$$tmp_fs"; \
	trap 'rm -f "$$tmp_fs"' EXIT INT TERM; \
	$(MAKE) $(Q) -C $(APP_HOME)/.. $(3) $(4) \
		IMG="$(XV6_NSIM_DIR)/kernel/kernel.bin" DISK="$$tmp_fs" \
		ARGS="$(ARGS) $(5)"; \
	rc=$$?; rm -f "$$tmp_fs"; exit $$rc
endef

# ============================================================================
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "Usage: make -C app/tinyos <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first=1 } \
		/^# =+$$/ { if (state==0) state=1; else if (state==2) { pending=section; state=0 } else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first) printf "\nTargets:\n"; \
			first=0; \
			t=$$0; sub(/:.*/, "", t); \
			d=$$0; sub(/.*## /, "", d); \
			printf "  %-20s %s\n", t, d }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables:"
	@grep -hE '^[A-Z_][A-Z_0-9]*\s*\?=' $(MAKEFILE_LIST) | \
		awk '!seen[$$1]++ { \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-20s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				if (a[2] != "") printf "  %-20s (default: %s)\n", a[1], a[2] } }'
	@echo ""

# ============================================================================
# Source sync
# ============================================================================
sync: ## Clone or update egos-2000 and xv6-riscv source repositories
	@if [ "$(SYNC)" = "0" ]; then \
		echo "[tinyos] sync skipped (SYNC=0)"; \
	else \
		bash $(_THIS_DIR)scripts/clone_sources.sh "$(TINYOS_DIR)" "$(EGOS_REPO_URL)" "$(XV6_REPO_URL)"; \
	fi

# Clone-only helpers: ensure the upstream tree exists locally but never
# fetch/pull updates. Run `make sync` (or set SYNC=1 explicitly) to refresh.
egos-clone: ## Clone egos-2000 if missing (no fetch/pull)
	@if [ ! -d "$(TINYOS_DIR)/egos-2000/.git" ]; then \
		echo "[tinyos] clone: $(EGOS_REPO_URL) -> $(TINYOS_DIR)/egos-2000"; \
		mkdir -p "$(TINYOS_DIR)"; \
		git clone "$(EGOS_REPO_URL)" "$(TINYOS_DIR)/egos-2000"; \
	fi

xv6-clone: ## Clone xv6-riscv if missing (no fetch/pull)
	@if [ ! -d "$(TINYOS_DIR)/xv6-riscv/.git" ]; then \
		echo "[tinyos] clone: $(XV6_REPO_URL) -> $(TINYOS_DIR)/xv6-riscv"; \
		mkdir -p "$(TINYOS_DIR)"; \
		git clone "$(XV6_REPO_URL)" "$(TINYOS_DIR)/xv6-riscv"; \
	fi

egos-nsim-prepare: egos-clone
	@rm -rf "$(EGOS_NSIM_DIR)" && mkdir -p "$(EGOS_NSIM_DIR)"
	@tar -cf - --exclude=.git --exclude=build -C "$(TINYOS_DIR)/egos-2000" . | tar -x -C "$(EGOS_NSIM_DIR)"
	@if ls $(EGOS_PATCH_DIR)/*.patch >/dev/null 2>&1; then \
		for p in $(EGOS_PATCH_DIR)/*.patch; do \
			echo "[tinyos] apply egos patch: $$(basename $$p)"; \
			patch -p1 -d "$(EGOS_NSIM_DIR)" < "$$p" \
				|| { echo "[ERR] Failed to apply $$p (upstream egos-2000 drift? regenerate the patch)"; exit 1; }; \
		done; \
	fi

xv6-nsim-prepare: xv6-clone
	@rm -rf "$(XV6_NSIM_DIR)" && mkdir -p "$(XV6_NSIM_DIR)"
	@tar -cf - --exclude=.git -C "$(TINYOS_DIR)/xv6-riscv" . | tar -x -C "$(XV6_NSIM_DIR)"
	@if [ -n "$(strip $(XV6_EXTRA_CFLAGS))" ]; then \
		printf '\nCFLAGS += %s\n' "$(XV6_EXTRA_CFLAGS)" >> "$(XV6_NSIM_DIR)/Makefile"; \
	fi

# ============================================================================
# egos — RV32 / Sv32
# ============================================================================
egos-toolchain-check:
	$(EGOS_TOOLCHAIN_CHECK)

egos-sim-image: egos-nsim-prepare ## Build egos binary for NPC/nsim/NEMU
	$(EGOS_TOOLCHAIN_CHECK)
	@$(MAKE) $(Q) -C $(EGOS_NSIM_DIR) install \
		RISCV_CC=$(EGOS_RISCV_CC) OBJDUMP=$(EGOS_OBJDUMP) OBJCOPY=$(EGOS_OBJCOPY) \
		CFLAGS="$(EGOS_CFLAGS)" LDFLAGS="$(EGOS_LDFLAGS)" \
		APPS_DEPS="$(EGOS_APPS_DEPS)" EGOS_DEPS="$(EGOS_EGOS_DEPS)"
	@test -f "$(EGOS_SIM_IMAGE)" && test -f "$(EGOS_SIM_SDCARD)"
	@echo "Built egos image: $(EGOS_SIM_IMAGE)  sdcard: $(EGOS_SIM_SDCARD)"

# KU15P RAM-disk image: single flat binary with embedded disk.img.
# Uses PLATFORM_KU15P to fix UART=0xF0001800, CLINT=0x02000000, and embeds
# disk.img above the egos runtime region (KU15P_FLASH_BASE, default 0x80800000
# = FLASH_ROM_BASE; overridable). The result is uploaded via Linux/MIG BIOS
# serialboot to 0x80000000.
EGOS_KU15P_IMAGE := $(EGOS_NSIM_DIR)/tools/egos-ku15p.bin
egos-ku15p-image: egos-nsim-prepare ## Build egos KU15P RAM-disk image (embedded disk.img)
	$(EGOS_TOOLCHAIN_CHECK)
	@$(MAKE) $(Q) -C $(EGOS_NSIM_DIR) ku15p \
		RISCV_CC=$(EGOS_RISCV_CC) OBJDUMP=$(EGOS_OBJDUMP) OBJCOPY=$(EGOS_OBJCOPY) \
		CFLAGS="$(EGOS_CFLAGS)" LDFLAGS="$(EGOS_LDFLAGS)" \
		APPS_DEPS="$(EGOS_APPS_DEPS)" EGOS_DEPS="$(EGOS_EGOS_DEPS)"
	@test -f "$(EGOS_KU15P_IMAGE)" || { echo "[ERR] Missing $(EGOS_KU15P_IMAGE)"; exit 1; }
	@sz=$$(stat -c%s "$(EGOS_KU15P_IMAGE)" 2>/dev/null); echo "Built KU15P egos image: $(EGOS_KU15P_IMAGE) ($$sz bytes)"

egos-cli-nsim: egos-sim-image ## Boot egos on NPC/nsim [RV32/Sv32]
	@echo "[egos-cli-nsim] RV32 / Sv32 (egos-2000)"
	@$(MAKE) $(Q) -C $(APP_HOME)/.. run-npc32 \
		IMG=$(EGOS_SIM_IMAGE) SDCARD=$(EGOS_SIM_SDCARD) \
		ARGS="$(ARGS) --serial-lf-to-cr $(SIM_LIMIT_ARGS)"

# Difftest variant: assumes caller (top-level Makefile) already configured
# nsim with o2_difftest_defconfig and built the NEMU reference shared object.
# Bypasses run-npc32 (which would clobber the difftest config) by invoking
# nsim's run target directly.
egos-cli-nsim-difftest: egos-sim-image ## Boot egos on NPC/nsim with NEMU difftest [RV32/Sv32]
	@echo "[egos-cli-nsim-difftest] RV32 / Sv32 (egos-2000) + NEMU difftest"
	@$(MAKE) $(Q) -C $(NSIM_HOME) run \
		IMG=$(EGOS_SIM_IMAGE) SDCARD=$(EGOS_SIM_SDCARD) \
		ARGS="$(ARGS) --serial-lf-to-cr $(SIM_LIMIT_ARGS)"

egos-cli-nemu: egos-sim-image ## Boot egos on NEMU [RV32/Sv32]
	@echo "[egos-cli-nemu] RV32 / Sv32 (egos-2000)"
	@$(MAKE) $(Q) -C $(APP_HOME)/.. run-nemu32 \
		NEMU_DEFCONFIG=riscv32_tinyos_defconfig \
		IMG=$(EGOS_SIM_IMAGE) SDCARD=$(EGOS_SIM_SDCARD) \
		ARGS="$(ARGS) --serial-lf-to-cr $(NEMU_LIMIT_ARGS)"

egos-cli-qemu: ## Boot egos on QEMU [RV32/Sv32]
	@$(MAKE) $(Q) egos-toolchain-check || exit $$?
	@$(MAKE) $(Q) -C $(TINYOS_DIR)/egos-2000 qemu \
		$(if $(QEMU),QEMU=$(QEMU),) \
		RISCV_CC=$(EGOS_RISCV_CC) OBJDUMP=$(EGOS_OBJDUMP) OBJCOPY=$(EGOS_OBJCOPY) \
		CFLAGS="$(EGOS_CFLAGS)" LDFLAGS="$(EGOS_LDFLAGS)" \
		APPS_DEPS="$(EGOS_APPS_DEPS)" EGOS_DEPS="$(EGOS_EGOS_DEPS)"

# ============================================================================
# xv6 — RV64 / Sv39
# ============================================================================
xv6-cli-nsim: xv6-nsim-prepare ## Boot xv6-riscv on NPC/nsim [RV64/Sv39]
	$(call xv6-run-body,xv6-cli-nsim,xv6-nsim-fs,run-npc64,,$(SIM_LIMIT_ARGS))

xv6-sim-image: xv6-nsim-prepare ## Build xv6 kernel.bin and fs.img without running a simulator
	@[ -n "$(XV6_OBJCOPY)" ] || { \
		echo "[ERR] Cannot find RV64 objcopy for xv6"; \
		echo "      Minimal Debian/Ubuntu install:"; \
		echo "        sudo apt update"; \
		 echo "        sudo apt install -y build-essential gcc-riscv64-unknown-elf"; \
		echo "      Or override: XV6_OBJCOPY=/path/to/riscv64-unknown-elf-objcopy TOOLPREFIX=/path/to/riscv64-unknown-elf-"; \
		exit 1; }
	@$(MAKE) $(Q) -C "$(XV6_NSIM_DIR)" kernel/kernel fs.img
	@$(XV6_OBJCOPY) -O binary "$(XV6_NSIM_DIR)/kernel/kernel" "$(XV6_NSIM_DIR)/kernel/kernel.bin"
	@test -f "$(XV6_NSIM_DIR)/kernel/kernel.bin" && test -f "$(XV6_NSIM_DIR)/fs.img"
	@echo "Built xv6 kernel: $(XV6_NSIM_DIR)/kernel/kernel.bin  disk: $(XV6_NSIM_DIR)/fs.img"

# Difftest variant: assumes caller (top-level Makefile) already configured
# nsim with o2_difftest_defconfig (rebuilt with VFLAGS=-DRAPT_RV64) and
# built the NEMU RV64 reference shared object. Bypasses run-npc64 (which
# would clobber the difftest config) by invoking nsim's run target directly.
xv6-cli-nsim-difftest: xv6-nsim-prepare ## Boot xv6-riscv on NPC/nsim with NEMU difftest [RV64/Sv39]
	@[ -n "$(XV6_OBJCOPY)" ] || { \
		echo "[ERR] Cannot find RV64 objcopy for xv6"; \
		echo "      Minimal Debian/Ubuntu install:"; \
		echo "        sudo apt update"; \
		 echo "        sudo apt install -y build-essential gcc-riscv64-unknown-elf"; \
		echo "      Or override: XV6_OBJCOPY=/path/to/riscv64-unknown-elf-objcopy TOOLPREFIX=/path/to/riscv64-unknown-elf-"; \
		exit 1; }
	@$(MAKE) $(Q) -C "$(XV6_NSIM_DIR)" kernel/kernel fs.img
	@$(XV6_OBJCOPY) -O binary "$(XV6_NSIM_DIR)/kernel/kernel" "$(XV6_NSIM_DIR)/kernel/kernel.bin"
	@tmp_fs=$$(mktemp "$${TMPDIR:-/tmp}/xv6-nsim-fs.XXXXXX"); \
	cp "$(XV6_NSIM_DIR)/fs.img" "$$tmp_fs"; \
	echo "[xv6-cli-nsim-difftest] RV64 / Sv39 (xv6-riscv) + NEMU difftest"; \
	echo "[xv6-cli-nsim-difftest] kernel=$(XV6_NSIM_DIR)/kernel/kernel.bin"; \
	echo "[xv6-cli-nsim-difftest] disk copy=$$tmp_fs"; \
	trap 'rm -f "$$tmp_fs"' EXIT INT TERM; \
	$(MAKE) $(Q) -C $(NSIM_HOME) run VFLAGS="-DRAPT_RV64" \
		IMG="$(XV6_NSIM_DIR)/kernel/kernel.bin" DISK="$$tmp_fs" \
		ARGS="$(ARGS) $(SIM_LIMIT_ARGS)"; \
	rc=$$?; rm -f "$$tmp_fs"; exit $$rc

xv6-cli-nemu: xv6-nsim-prepare ## Boot xv6-riscv on NEMU [RV64/Sv39]
	$(call xv6-run-body,xv6-cli-nemu,xv6-nemu-fs,run-nemu64,NEMU64_DEFCONFIG=riscv64_tinyos_defconfig,$(NEMU_LIMIT_ARGS))

xv6-cli-qemu: ## Boot xv6-riscv on QEMU [RV64/Sv39]
	@xv6_dir="$(TINYOS_DIR)/xv6-riscv"; xv6_fs="$$xv6_dir/fs.img"; \
	if lsof "$$xv6_fs" >/dev/null 2>&1; then \
		tmp_fs=$$(mktemp "$${TMPDIR:-/tmp}/xv6-fs.XXXXXX"); \
		cp "$$xv6_fs" "$$tmp_fs"; \
		echo "[WARN] xv6 fs.img is busy; using temporary image: $$tmp_fs"; \
		trap 'rm -f "$$tmp_fs"' EXIT INT TERM; \
		$(MAKE) $(Q) -C "$$xv6_dir" qemu $(if $(QEMU),QEMU=$(QEMU),) CPUS=$(XV6_CPUS) \
			QEMUOPTS="-machine virt -bios none -kernel kernel/kernel -m 128M -smp $(XV6_CPUS) -nographic -global virtio-mmio.force-legacy=false -drive file=$$tmp_fs,if=none,format=raw,id=x0 -device virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0"; \
		rc=$$?; rm -f "$$tmp_fs"; exit $$rc; \
	else \
		$(MAKE) $(Q) -C "$$xv6_dir" qemu $(if $(QEMU),QEMU=$(QEMU),) CPUS=$(XV6_CPUS); \
	fi

# ============================================================================
# Generic OS dispatch (OS=egos|xv6)
# ============================================================================
cli-nsim: ## Boot OS on NPC/nsim — OS=egos|xv6 {ARGS,MAX_INST,TIMEOUT}
	@[ -n "$(OS)" ] || { echo "[ERR] Set OS=egos|xv6"; exit 1; }
	@$(MAKE) $(Q) $(OS)-$@ ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

cli-nemu: ## Boot OS on NEMU — OS=egos|xv6 {ARGS,MAX_INST}
	@[ -n "$(OS)" ] || { echo "[ERR] Set OS=egos|xv6"; exit 1; }
	@$(MAKE) $(Q) $(OS)-$@ ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

cli-qemu: ## Boot OS on QEMU — OS=egos|xv6 {QEMU}
	@[ -n "$(OS)" ] || { echo "[ERR] Set OS=egos|xv6"; exit 1; }
	@$(MAKE) $(Q) $(OS)-$@ $(if $(QEMU),QEMU=$(QEMU),)

clean: ## Clean tinyos build artifacts
	rm -rf $(NSIM_SRC_DIR)

.PHONY: help sync \
	egos-clone xv6-clone \
	egos-toolchain-check egos-nsim-prepare xv6-nsim-prepare egos-sim-image \
	egos-cli-nsim egos-cli-nsim-difftest egos-cli-nemu egos-cli-qemu \
	xv6-sim-image xv6-cli-nsim xv6-cli-nsim-difftest xv6-cli-nemu xv6-cli-qemu \
	cli-nsim cli-nemu cli-qemu clean
