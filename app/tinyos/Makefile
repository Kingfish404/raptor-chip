# ============================================================================
# app/tinyos/Makefile: tiny teaching OS integration
# ============================================================================

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/..)
include $(APP_HOME)/common.mk

TINYOS_DIR ?= $(abspath $(APP_HOME)/tinyos)## Source root for tiny teaching OS repositories (inside app/tinyos)
EGOS_REPO_URL ?= https://github.com/yhzhang0128/egos-2000.git## egos-2000 source repository URL
XV6_REPO_URL ?= https://github.com/mit-pdos/xv6-riscv.git## xv6-riscv source repository URL
OS ?=## Build a single payload: egos or xv6
SYNC ?= 1## Set to 0 to skip source repository update in sync target
ARGS ?= -b -n## Simulator args for tinyos cli-nsim/cli-nemu
MAX_INST ?=## Optional maximum instruction limit for cli-nsim/cli-nemu
TIMEOUT ?=## Optional wall-clock timeout in seconds for cli-nsim
QEMU ?=## Override QEMU executable for cli-qemu targets (optional)
XV6_CPUS ?= 3## CPU count for xv6 qemu cli
XV6_OBJCOPY ?= $(shell if command -v riscv64-unknown-elf-objcopy >/dev/null 2>&1; then echo riscv64-unknown-elf-objcopy; elif command -v riscv64-elf-objcopy >/dev/null 2>&1; then echo riscv64-elf-objcopy; elif command -v riscv64-none-elf-objcopy >/dev/null 2>&1; then echo riscv64-none-elf-objcopy; elif command -v riscv64-linux-gnu-objcopy >/dev/null 2>&1; then echo riscv64-linux-gnu-objcopy; elif command -v riscv64-unknown-linux-gnu-objcopy >/dev/null 2>&1; then echo riscv64-unknown-linux-gnu-objcopy; fi)## Override xv6 objcopy tool
EGOS_NOSTDLIB ?= 1## Build egos with app-provided tiny libc instead of compiler libc
EGOS_ARCH ?= rv32imac_zicsr## ISA string for upstream egos QEMU build
EGOS_ABI ?= ilp32## ABI for upstream egos QEMU build
EGOS_RISCV_CC ?= $(shell if command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then echo riscv32-unknown-elf-gcc; elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then echo riscv64-unknown-elf-gcc; elif command -v riscv-none-elf-gcc >/dev/null 2>&1; then echo riscv-none-elf-gcc; fi)## Override egos compiler (auto-detected by default)
EGOS_RISCV_PREFIX := $(patsubst %gcc,%,$(EGOS_RISCV_CC))
EGOS_OBJDUMP ?= $(EGOS_RISCV_PREFIX)objdump## Override egos objdump tool
EGOS_OBJCOPY ?= $(EGOS_RISCV_PREFIX)objcopy## Override egos objcopy tool
EGOS_CFLAGS ?= -march=$(EGOS_ARCH) -mabi=$(EGOS_ABI) -Wl,--gc-sections -ffunction-sections -fdata-sections -fdiagnostics-show-option
EGOS_RUNTIME_LIBC := $(APP_HOME)/lib/runtime/libc_min.c
NSIM_SRC_DIR := $(APP_HOME)/build/tinyos-nsim-src
EGOS_NSIM_DIR := $(NSIM_SRC_DIR)/egos-2000
XV6_NSIM_DIR := $(NSIM_SRC_DIR)/xv6-riscv
EGOS_APPS_DEPS := apps/*.* library/egos.h library/*/* Makefile
EGOS_EGOS_DEPS := earth/* grass/* library/egos.h library/*/* Makefile
ifeq ($(EGOS_NOSTDLIB),1)
EGOS_CFLAGS += -DRAPT_LIBC_MIN_MALLOC=1
EGOS_APPS_DEPS += $(EGOS_RUNTIME_LIBC)
EGOS_EGOS_DEPS += $(EGOS_RUNTIME_LIBC)
EGOS_LDFLAGS ?= -nostdlib -lgcc
else
EGOS_LDFLAGS ?= -nostdlib -lc -lgcc
endif
EGOS_SIM_CFLAGS := $(EGOS_CFLAGS)
EGOS_SIM_IMAGE := $(EGOS_NSIM_DIR)/tools/egos.bin
EGOS_SIM_SDCARD := $(EGOS_NSIM_DIR)/tools/disk.img
SIM_LIMIT_ARGS := $(if $(MAX_INST),-m $(MAX_INST),) $(if $(TIMEOUT),-t $(TIMEOUT),)
NEMU_LIMIT_ARGS := $(if $(MAX_INST),-m $(MAX_INST),)

define EGOS_TOOLCHAIN_CHECK
	@if [ -z "$(EGOS_RISCV_CC)" ]; then \
		echo "[ERR] Cannot find RISC-V GCC for egos (tried riscv32-unknown-elf-gcc, riscv64-unknown-elf-gcc, riscv-none-elf-gcc)"; \
		exit 1; \
	fi
	@tmp_c=$$(mktemp /tmp/egos-rv32-check-XXXX.c); \
	tmp_elf=$${tmp_c%.c}.elf; \
	printf 'void _start(void){}\n' > $$tmp_c; \
	if ! $(EGOS_RISCV_CC) -march=$(EGOS_ARCH) -mabi=$(EGOS_ABI) -nostdlib $$tmp_c -lgcc -o $$tmp_elf >/dev/null 2>&1; then \
		rm -f $$tmp_c $$tmp_elf; \
		echo "[ERR] $(EGOS_RISCV_CC) cannot link RV32 ilp32 freestanding binaries for egos."; \
		echo "      Install an RV32-capable RISC-V GCC with $(EGOS_ARCH)/$(EGOS_ABI) libgcc support."; \
		exit 1; \
	fi; \
	rm -f $$tmp_c $$tmp_elf
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
sync: ## Clone or update egos-2000 and xv6-riscv repositories
	@if [ "$(SYNC)" = "0" ]; then \
		echo "[tinyos] sync skipped (SYNC=0)"; \
	else \
		bash $(_THIS_DIR)scripts/clone_sources.sh "$(TINYOS_DIR)" "$(EGOS_REPO_URL)" "$(XV6_REPO_URL)"; \
	fi

egos-nsim-prepare: sync ## Prepare upstream egos build copy for NPC/nsim
	@rm -rf "$(EGOS_NSIM_DIR)"
	@mkdir -p "$(EGOS_NSIM_DIR)"
	@git -C "$(TINYOS_DIR)/egos-2000" archive HEAD | tar -x -C "$(EGOS_NSIM_DIR)"
	@echo "[tinyos] prepared egos nsim source copy: $(EGOS_NSIM_DIR)"

xv6-nsim-prepare: sync ## Prepare upstream xv6 build copy for NPC/nsim
	@rm -rf "$(XV6_NSIM_DIR)"
	@mkdir -p "$(XV6_NSIM_DIR)"
	@git -C "$(TINYOS_DIR)/xv6-riscv" archive HEAD | tar -x -C "$(XV6_NSIM_DIR)"
	@echo "[tinyos] prepared xv6 nsim source copy: $(XV6_NSIM_DIR)"

# ============================================================================
# NPC/nsim and NEMU OS images
# ============================================================================
egos-sim-image: egos-nsim-prepare ## Build upstream egos image for NPC/nsim/NEMU
	$(EGOS_TOOLCHAIN_CHECK)
	@$(MAKE) $(Q) -C $(EGOS_NSIM_DIR) install \
		RISCV_CC=$(EGOS_RISCV_CC) OBJDUMP=$(EGOS_OBJDUMP) OBJCOPY=$(EGOS_OBJCOPY) \
		CFLAGS="$(EGOS_SIM_CFLAGS)" \
		LDFLAGS="$(EGOS_LDFLAGS)" APPS_DEPS="$(EGOS_APPS_DEPS)" EGOS_DEPS="$(EGOS_EGOS_DEPS)"
	@test -f "$(EGOS_SIM_IMAGE)"
	@test -f "$(EGOS_SIM_SDCARD)"
	@echo "Built egos NPC/nsim image: $(EGOS_SIM_IMAGE)"
	@echo "Built egos NPC/nsim SD card: $(EGOS_SIM_SDCARD)"

cli-nsim: ## Boot upstream OS image on NPC/nsim where supported (OS=egos|xv6) {OS,ARGS,MAX_INST,TIMEOUT}
	@if [ -z "$(OS)" ]; then echo "[ERR] Set OS=egos|xv6"; exit 1; fi
	@if [ "$(OS)" = "egos" ]; then \
		$(MAKE) $(Q) egos-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"; \
	elif [ "$(OS)" = "xv6" ]; then \
		$(MAKE) $(Q) xv6-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"; \
	else \
		echo "[ERR] Unknown OS=$(OS), expected egos|xv6"; exit 1; \
	fi

cli-nemu: ## Boot upstream OS image on NEMU where supported (OS=egos|xv6) {OS,ARGS,MAX_INST}
	@if [ -z "$(OS)" ]; then echo "[ERR] Set OS=egos|xv6"; exit 1; fi
	@if [ "$(OS)" = "egos" ]; then \
		$(MAKE) $(Q) egos-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"; \
	elif [ "$(OS)" = "xv6" ]; then \
		$(MAKE) $(Q) xv6-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"; \
	else \
		echo "[ERR] Unknown OS=$(OS), expected egos|xv6"; exit 1; \
	fi

cli-qemu: ## Enter upstream OS CLI on QEMU (OS=egos|xv6) {OS,QEMU}
	@if [ -z "$(OS)" ]; then echo "[ERR] Set OS=egos|xv6"; exit 1; fi
	@if [ "$(OS)" = "egos" ]; then \
		$(MAKE) $(Q) egos-toolchain-check || exit $$?; \
		$(MAKE) $(Q) -C $(TINYOS_DIR)/egos-2000 qemu \
			$(if $(QEMU),QEMU=$(QEMU),) \
			RISCV_CC=$(EGOS_RISCV_CC) OBJDUMP=$(EGOS_OBJDUMP) OBJCOPY=$(EGOS_OBJCOPY) \
			CFLAGS="$(EGOS_CFLAGS)" \
			LDFLAGS="$(EGOS_LDFLAGS)" APPS_DEPS="$(EGOS_APPS_DEPS)" EGOS_DEPS="$(EGOS_EGOS_DEPS)"; \
	elif [ "$(OS)" = "xv6" ]; then \
		xv6_dir="$(TINYOS_DIR)/xv6-riscv"; \
		xv6_fs="$$xv6_dir/fs.img"; \
		if lsof "$${xv6_fs}" >/dev/null 2>&1; then \
			tmp_fs=$$(mktemp "$${TMPDIR:-/tmp}/xv6-fs.XXXXXX"); \
			cp "$${xv6_fs}" "$${tmp_fs}"; \
			echo "[WARN] xv6 fs.img is busy; using temporary image: $${tmp_fs}"; \
			trap 'rm -f "$${tmp_fs}"' EXIT INT TERM; \
			$(MAKE) $(Q) -C "$${xv6_dir}" qemu \
				$(if $(QEMU),QEMU=$(QEMU),) \
				CPUS=$(XV6_CPUS) \
				QEMUOPTS="-machine virt -bios none -kernel kernel/kernel -m 128M -smp $(XV6_CPUS) -nographic -global virtio-mmio.force-legacy=false -drive file=$${tmp_fs},if=none,format=raw,id=x0 -device virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0"; \
			rc=$$?; \
			rm -f "$${tmp_fs}"; \
			exit $$rc; \
		else \
			$(MAKE) $(Q) -C "$${xv6_dir}" qemu $(if $(QEMU),QEMU=$(QEMU),) CPUS=$(XV6_CPUS); \
		fi; \
	else \
		echo "[ERR] Unknown OS=$(OS), expected egos|xv6"; exit 1; \
	fi

egos-cli-qemu: ## Enter egos CLI on QEMU
	@$(MAKE) $(Q) cli-qemu OS=egos $(if $(QEMU),QEMU=$(QEMU),)

xv6-cli-qemu: ## Enter xv6 CLI on QEMU
	@$(MAKE) $(Q) cli-qemu OS=xv6 $(if $(QEMU),QEMU=$(QEMU),)

egos-toolchain-check:
	$(EGOS_TOOLCHAIN_CHECK)

egos-cli-nsim: egos-sim-image ## Boot upstream egos image on NPC/nsim
	@$(MAKE) $(Q) -C $(APP_HOME)/.. run-npc32 IMG=$(EGOS_SIM_IMAGE) SDCARD=$(EGOS_SIM_SDCARD) ARGS="$(ARGS) --serial-lf-to-cr $(SIM_LIMIT_ARGS)"

egos-cli-nemu: egos-sim-image ## Boot upstream egos image on NEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/.. run-nemu32 \
		NEMU_DEFCONFIG=riscv32_tinyos_defconfig \
		IMG=$(EGOS_SIM_IMAGE) SDCARD=$(EGOS_SIM_SDCARD) ARGS="$(ARGS) --serial-lf-to-cr $(NEMU_LIMIT_ARGS)"

xv6-cli-nsim: xv6-nsim-prepare ## Boot upstream xv6-riscv on NPC/nsim with fs.img via virtio-blk
	@xv6_dir="$(XV6_NSIM_DIR)"; \
	if [ -z "$(XV6_OBJCOPY)" ]; then echo "[ERR] Cannot find RISC-V objcopy for xv6"; exit 1; fi; \
	$(MAKE) $(Q) -C "$${xv6_dir}" kernel/kernel fs.img; \
	xv6_kernel="$${xv6_dir}/kernel/kernel.bin"; \
	$(XV6_OBJCOPY) -O binary "$${xv6_dir}/kernel/kernel" "$${xv6_kernel}"; \
	xv6_fs="$${xv6_dir}/fs.img"; \
	tmp_fs=$$(mktemp "$${TMPDIR:-/tmp}/xv6-nsim-fs.XXXXXX"); \
	cp "$${xv6_fs}" "$${tmp_fs}"; \
	echo "[xv6-cli-nsim] kernel=$${xv6_kernel}"; \
	echo "[xv6-cli-nsim] disk copy=$${tmp_fs}"; \
	trap 'rm -f "$${tmp_fs}"' EXIT INT TERM; \
	$(MAKE) $(Q) -C $(APP_HOME)/.. run-npc64 \
		IMG="$${xv6_kernel}" DISK="$${tmp_fs}" \
		ARGS="$(ARGS) $(SIM_LIMIT_ARGS)"; \
	rc=$$?; \
	rm -f "$${tmp_fs}"; \
	exit $$rc

xv6-cli-nemu: xv6-nsim-prepare ## Boot upstream xv6-riscv on NEMU with fs.img via virtio-blk
	@xv6_dir="$(XV6_NSIM_DIR)"; \
	if [ -z "$(XV6_OBJCOPY)" ]; then echo "[ERR] Cannot find RISC-V objcopy for xv6"; exit 1; fi; \
	$(MAKE) $(Q) -C "$${xv6_dir}" kernel/kernel fs.img; \
	xv6_kernel="$${xv6_dir}/kernel/kernel.bin"; \
	$(XV6_OBJCOPY) -O binary "$${xv6_dir}/kernel/kernel" "$${xv6_kernel}"; \
	xv6_fs="$${xv6_dir}/fs.img"; \
	tmp_fs=$$(mktemp "$${TMPDIR:-/tmp}/xv6-nemu-fs.XXXXXX"); \
	cp "$${xv6_fs}" "$${tmp_fs}"; \
	echo "[xv6-cli-nemu] kernel=$${xv6_kernel}"; \
	echo "[xv6-cli-nemu] disk copy=$${tmp_fs}"; \
	trap 'rm -f "$${tmp_fs}"' EXIT INT TERM; \
	$(MAKE) $(Q) -C $(APP_HOME)/.. run-nemu64 \
		NEMU64_DEFCONFIG=riscv64_tinyos_defconfig \
		IMG="$${xv6_kernel}" DISK="$${tmp_fs}" \
		ARGS="$(ARGS) $(NEMU_LIMIT_ARGS)"; \
	rc=$$?; \
	rm -f "$${tmp_fs}"; \
	exit $$rc

clean: ## Clean tinyos build artifacts
	rm -rf $(NSIM_SRC_DIR)

.PHONY: help sync \
	egos-toolchain-check egos-nsim-prepare xv6-nsim-prepare \
	egos-sim-image cli-qemu cli-nsim cli-nemu \
        egos-cli-qemu xv6-cli-qemu egos-cli-nsim xv6-cli-nsim egos-cli-nemu xv6-cli-nemu \
	clean
