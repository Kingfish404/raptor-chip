PWD_DIR=$(abspath .)
RAPTOR_HOME ?= $(abspath ..)
KERNEL_VERSION:=6.18.39
NPROC := $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ==============================================================================
# Pre-built Linux kernel variables (single source of truth: linux/vars.mk)
# ==============================================================================
include $(PWD_DIR)/vars.mk

.PHONY: help download-rv32 download-rv64 download all build_linux make_initramfs
.PHONY: build_init install_initramfs check-opensbi-llvm-deps opensbi opensbi-rv32 opensbi-rv64 opensbi-gnu opensbi-gnu-rv32 opensbi-gnu-rv64
.PHONY: opensbi-with-kernel opensbi-clean print-rv32-payload print-rv64-payload
.PHONY: print-opensbi-payload clean

help: ## Show this help message
	@echo "Usage: make <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first_target=1 } \
		/^# =+$$/ { \
			if (state==0) state=1; \
			else if (state==2) { pending=section; state=0 } \
			else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first_target) printf "\nTargets:\n"; \
			first_target=0; \
			target=$$0; sub(/:.*/, "", target); \
			desc=$$0; sub(/.*## /, "", desc); \
			printf "  %-20s %s\n", target, desc }' $(MAKEFILE_LIST)

# ==============================================================================
# Pre-built download targets
# ==============================================================================

$(LINUX_RV32_DIR)/fw_payload.bin:
	@mkdir -p $(LINUX_BUILD_DIR)
	curl -L -o $(LINUX_BUILD_DIR)/$(LINUX_RV32_NAME).tar.gz \
		$(LINUX_BUILD_URL)/$(LINUX_RV32_NAME).tar.gz
	tar xzf $(LINUX_BUILD_DIR)/$(LINUX_RV32_NAME).tar.gz -C $(LINUX_BUILD_DIR)
	@echo "RV32 Linux build extracted to $(LINUX_RV32_DIR)"

$(LINUX_RV64_DIR)/fw_payload.bin:
	@mkdir -p $(LINUX_BUILD_DIR)
	curl -L -o $(LINUX_BUILD_DIR)/$(LINUX_RV64_NAME).tar.gz \
		$(LINUX_BUILD_URL)/$(LINUX_RV64_NAME).tar.gz
	tar xzf $(LINUX_BUILD_DIR)/$(LINUX_RV64_NAME).tar.gz -C $(LINUX_BUILD_DIR)
	@echo "RV64 Linux build extracted to $(LINUX_RV64_DIR)"

download-rv32: $(LINUX_RV32_DIR)/fw_payload.bin ## Download pre-built Linux (RV32)
download-rv64: $(LINUX_RV64_DIR)/fw_payload.bin ## Download pre-built Linux (RV64)
download: download-rv32 download-rv64 ## Download pre-built Linux (RV32 + RV64)
	@echo "Downloaded Linux $(LINUX_BUILD_VERSION) for RV32 and RV64"
	@echo "  RV32: $(LINUX_RV32_DIR)/"
	@echo "  RV64: $(LINUX_RV64_DIR)/"
	@cat $(LINUX_RV32_DIR)/README.md

# Helper targets for querying paths from other Makefiles (e.g. fpga/litex/Makefile).
print-rv32-payload: ## Print RV32 fw_payload.bin path
	@echo $(LINUX_RV32_PAYLOAD)
print-rv64-payload: ## Print RV64 fw_payload.bin path
	@echo $(LINUX_RV64_PAYLOAD)

# ==============================================================================
# Build from source
# ==============================================================================

all: ## Show usage information
	echo "PWD: $(PWD_DIR)"
	echo "Kernel Version: $(KERNEL_VERSION)"
	echo "Help: you should make one of the targets to build linux kernel and related files."
	echo "Example: make build_linux make_initramfs build_init install_initramfs opensbi-with-kernel"
	echo "Targets:"
	echo "  - build_linux: Build Linux kernel for RISC-V 32-bit architecture"
	echo "  - make_initramfs: Create a simple initramfs image"
	echo "  - build_init: Build the init process payload"
	echo "  - install_initramfs: Configure Linux kernel to use the created initramfs"
	echo "  - opensbi-with-kernel: Build OpenSBI with the Linux kernel as payload"

linux: ## Download Linux kernel source
	curl -L -o linux-$(KERNEL_VERSION).tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
	tar -xf linux-$(KERNEL_VERSION).tar.xz
	mv linux-$(KERNEL_VERSION) linux
	rm linux-$(KERNEL_VERSION).tar.xz

build_linux: linux ## Build Linux kernel for RISC-V 32-bit
	make -C linux ARCH=riscv -j$(NPROC) defconfig

	cd linux && \
		./scripts/config --enable CONFIG_NONPORTABLE && \
		./scripts/config --disable CONFIG_ARCH_RV64I && \
		./scripts/config --enable CONFIG_ARCH_RV32I && \
		./scripts/config --disable CONFIG_FPU && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZAWRS && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOM && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOZ

	make -C linux ARCH=riscv -j$(NPROC) olddefconfig

	make -C linux ARCH=riscv -j$(NPROC)

make_initramfs: ## Create initramfs image
	mkdir -p initramfs/bin initramfs/dev initramfs/etc initramfs/lib initramfs/lib64 \
		initramfs/mnt/root initramfs/proc initramfs/root/init-linux initramfs/run \
		initramfs/sbin initramfs/sys
	(cd initramfs && \
		[ -e dev/console ] || sudo mknod dev/console c 5 1; \
		[ -e dev/null ] || sudo mknod dev/null c 1 3; \
		[ -e dev/sda ] || sudo mknod dev/sda b 8 0)
	(cd initramfs && find . | cpio -o -H newc | gzip > ../initramfs.cpio.gz)

build_init: ## Build init process payload
	make -C payload init_loop install

install_initramfs: ## Configure kernel to use initramfs
# -> General setup -> Initial RAM filesystem and RAM disk (initramfs/initrd) support
# -> [*] Initramfs source file(s) -> [PATH of initramfs] (e.g. `/home/[username]/initramfs`)
	cd linux && ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE $(PWD_DIR)/initramfs
	make -C linux ARCH=riscv -j$(NPROC) olddefconfig

OPENSBI_SRC_DIR := $(RAPTOR_HOME)/third_party/riscv-software-src/opensbi
OPENSBI_OUT_DIR := $(PWD_DIR)/opensbi
OPENSBI_RV32_BUILD_DIR := $(OPENSBI_OUT_DIR)/build-rv32
OPENSBI_RV64_BUILD_DIR := $(OPENSBI_OUT_DIR)/build-rv64
OPENSBI_RV32_PAYLOAD := $(OPENSBI_RV32_BUILD_DIR)/platform/generic/firmware/fw_payload.bin
OPENSBI_RV64_PAYLOAD := $(OPENSBI_RV64_BUILD_DIR)/platform/generic/firmware/fw_payload.bin
OPENSBI_PAYLOAD := $(OPENSBI_RV32_PAYLOAD)
export OPENSBI_PAYLOAD

# OpenSBI does not track PLATFORM_RISCV_ISA or compiler-mode changes in its
# generated dependencies. Invalidate only the affected output directory when
# either changes, otherwise an old RV32/RV64 capability set can survive.
define prepare_opensbi_build
	@config='$(1)'; stamp='$(2)/.raptor-build-config'; \
	old=$$(cat "$$stamp" 2>/dev/null || true); \
	if [ "$$old" != "$$config" ]; then \
		echo "[opensbi] build config changed; resetting $(2)"; \
		rm -rf "$(2)"; mkdir -p "$(2)"; \
		printf '%s\n' "$$config" > "$$stamp"; \
	fi
endef

$(OPENSBI_SRC_DIR)/Makefile:
	@echo "error: OpenSBI source not found at $(OPENSBI_SRC_DIR); run make setup"; exit 1

OPENSBI_RV32_FLAGS = \
	PLATFORM_RISCV_ISA=$(RAPTOR_RV32_ISA) \
	PLATFORM_RISCV_XLEN=32 PLATFORM=generic O=$(OPENSBI_RV32_BUILD_DIR) -j$(NPROC)

OPENSBI_RV64_FLAGS = \
	PLATFORM_RISCV_ISA=$(RAPTOR_RV64_ISA) \
	PLATFORM_RISCV_XLEN=64 PLATFORM=generic O=$(OPENSBI_RV64_BUILD_DIR) -j$(NPROC)

check-opensbi-llvm-deps: ## Check LLVM tools required by OpenSBI
	@command -v clang >/dev/null || { echo "error: clang not found. See linux/README.md for distro package commands."; exit 1; }
	@command -v ld.lld >/dev/null || { echo "error: ld.lld not found. See linux/README.md for distro package commands."; exit 1; }
	@command -v llvm-ar >/dev/null || { echo "error: llvm-ar not found. See linux/README.md for distro package commands."; exit 1; }
	@command -v llvm-objcopy >/dev/null || { echo "error: llvm-objcopy not found. See linux/README.md for distro package commands."; exit 1; }

opensbi: opensbi-rv32 ## Compatibility alias: build RV32 OpenSBI

opensbi-rv32: check-opensbi-llvm-deps $(OPENSBI_SRC_DIR)/Makefile ## Build RV32 OpenSBI (standalone, Clang/LLVM)
	$(call prepare_opensbi_build,compiler=llvm mode=standalone xlen=32 isa=$(RAPTOR_RV32_ISA),$(OPENSBI_RV32_BUILD_DIR))
	make -C $(OPENSBI_SRC_DIR) LLVM=1 \
		platform-cflags-y="-Wno-gnu-designator -Wno-sometimes-uninitialized" \
		$(OPENSBI_RV32_FLAGS)

opensbi-rv64: check-opensbi-llvm-deps $(OPENSBI_SRC_DIR)/Makefile ## Build RV64 OpenSBI (standalone, Clang/LLVM)
	$(call prepare_opensbi_build,compiler=llvm mode=standalone xlen=64 isa=$(RAPTOR_RV64_ISA),$(OPENSBI_RV64_BUILD_DIR))
	make -C $(OPENSBI_SRC_DIR) LLVM=1 \
		platform-cflags-y="-Wno-gnu-designator -Wno-sometimes-uninitialized" \
		$(OPENSBI_RV64_FLAGS)

opensbi-gnu: opensbi-gnu-rv32 ## Compatibility alias: build RV32 OpenSBI with GNU

opensbi-gnu-rv32: $(OPENSBI_SRC_DIR)/Makefile ## Build RV32 OpenSBI (GNU toolchain)
	$(call prepare_opensbi_build,compiler=gnu mode=standalone xlen=32 isa=$(RAPTOR_RV32_ISA),$(OPENSBI_RV32_BUILD_DIR))
	make -C $(OPENSBI_SRC_DIR) CROSS_COMPILE=riscv64-linux-gnu- \
		$(OPENSBI_RV32_FLAGS)

opensbi-gnu-rv64: $(OPENSBI_SRC_DIR)/Makefile ## Build RV64 OpenSBI (GNU toolchain)
	$(call prepare_opensbi_build,compiler=gnu mode=standalone xlen=64 isa=$(RAPTOR_RV64_ISA),$(OPENSBI_RV64_BUILD_DIR))
	make -C $(OPENSBI_SRC_DIR) CROSS_COMPILE=riscv64-linux-gnu- \
		$(OPENSBI_RV64_FLAGS)

opensbi-with-kernel: $(OPENSBI_SRC_DIR)/Makefile ## Build OpenSBI with Linux kernel as payload
	$(call prepare_opensbi_build,compiler=gnu mode=payload xlen=32 isa=$(RAPTOR_RV32_ISA),$(OPENSBI_RV32_BUILD_DIR))
	make -C $(OPENSBI_SRC_DIR) CROSS_COMPILE=riscv64-linux-gnu- \
		FW_PAYLOAD_PATH=$(PWD_DIR)/linux/arch/riscv/boot/Image \
		$(OPENSBI_RV32_FLAGS)

opensbi-clean: ## Clean OpenSBI build artifacts
	rm -rf $(OPENSBI_RV32_BUILD_DIR) $(OPENSBI_RV64_BUILD_DIR)

print-opensbi-payload: ## Print OpenSBI fw_payload.bin path
	@echo $(OPENSBI_PAYLOAD)

clean: ## Clean all build artifacts
	rm -rf linux initramfs initramfs.cpio.gz opensbi payload/build
