PWD_DIR=$(abspath .)
YSYX_HOME ?= $(abspath ..)
KERNEL_VERSION:=6.18.22

# ==============================================================================
# Pre-built Linux kernel downloads
# ==============================================================================
# From https://github.com/Kingfish404/linux-build/releases
LINUX_BUILD_VERSION ?= v6.18.22
LINUX_BUILD_VERSION := $(strip $(LINUX_BUILD_VERSION))
LINUX_BUILD_DIR     := $(PWD_DIR)/build
LINUX_BUILD_URL     := https://github.com/Kingfish404/linux-build/releases/download/rv-$(LINUX_BUILD_VERSION)
LINUX_RV32_DIR      := $(LINUX_BUILD_DIR)/linux-riscv-qemu-rv32-m-$(LINUX_BUILD_VERSION)
LINUX_RV64_DIR      := $(LINUX_BUILD_DIR)/linux-riscv-qemu-rv64-m-$(LINUX_BUILD_VERSION)
LINUX_RV32_PAYLOAD  ?= $(LINUX_RV32_DIR)/fw_payload.bin
LINUX_RV64_PAYLOAD  ?= $(LINUX_RV64_DIR)/fw_payload.bin

# Exported for consumers (root Makefile, fpga/litex/Makefile)
export LINUX_RV32_PAYLOAD
export LINUX_RV64_PAYLOAD

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
	curl -L -o $(LINUX_BUILD_DIR)/linux-riscv-qemu-rv32-m-$(LINUX_BUILD_VERSION).tar.gz \
		$(LINUX_BUILD_URL)/linux-riscv-qemu-rv32-m-$(LINUX_BUILD_VERSION).tar.gz
	tar xzf $(LINUX_BUILD_DIR)/linux-riscv-qemu-rv32-m-$(LINUX_BUILD_VERSION).tar.gz -C $(LINUX_BUILD_DIR)
	@echo "RV32 Linux build extracted to $(LINUX_RV32_DIR)"

$(LINUX_RV64_DIR)/fw_payload.bin:
	@mkdir -p $(LINUX_BUILD_DIR)
	curl -L -o $(LINUX_BUILD_DIR)/linux-riscv-qemu-rv64-m-$(LINUX_BUILD_VERSION).tar.gz \
		$(LINUX_BUILD_URL)/linux-riscv-qemu-rv64-m-$(LINUX_BUILD_VERSION).tar.gz
	tar xzf $(LINUX_BUILD_DIR)/linux-riscv-qemu-rv64-m-$(LINUX_BUILD_VERSION).tar.gz -C $(LINUX_BUILD_DIR)
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
	echo "Example: make build_linux make_initramfs build_init install_initramfs build_opensbi_with_kernel"
	echo "Targets:"
	echo "  - build_linux: Build Linux kernel for RISC-V 32-bit architecture"
	echo "  - make_initramfs: Create a simple initramfs image"
	echo "  - build_init: Build the init process payload"
	echo "  - install_initramfs: Configure Linux kernel to use the created initramfs"
	echo "  - build_opensbi_with_kernel: Build OpenSBI with the Linux kernel as payload"

linux: ## Download Linux kernel source
	wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
	tar -xf linux-$(KERNEL_VERSION).tar.xz
	mv linux-$(KERNEL_VERSION) linux
	rm linux-$(KERNEL_VERSION).tar.xz

build_linux: linux ## Build Linux kernel for RISC-V 32-bit
	make -C linux ARCH=riscv -j`nproc` defconfig

	cd linux && \
		./scripts/config --enable CONFIG_NONPORTABLE && \
		./scripts/config --disable CONFIG_ARCH_RV64I && \
		./scripts/config --enable CONFIG_ARCH_RV32I && \
		./scripts/config --disable CONFIG_FPU && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZAWRS && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOM && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOZ

	make -C linux ARCH=riscv -j`nproc` olddefconfig

	make -C linux ARCH=riscv -j`nproc`

make_initramfs: ## Create initramfs image
	mkdir initramfs && \
		cd initramfs && \
 		mkdir --parents {bin,dev,etc,lib,lib64,mnt/root,proc,root/init-linux,sbin,sys,run} && \
		mkdir dev && \
		sudo mknod dev/console c 5 1 && \
		sudo mknod dev/null c 1 3 && \
		sudo mknod dev/sda b 8 0
	(cd initramfs && find . | cpio -o --format=newc | gzip > ../initramfs.cpio.gz)

build_init: ## Build init process payload
	make -C payload init_loop install

install_initramfs: ## Configure kernel to use initramfs
# -> General setup -> Initial RAM filesystem and RAM disk (initramfs/initrd) support
# -> [*] Initramfs source file(s) -> [PATH of initramfs] (e.g. `/home/[username]/initramfs`)
	cd linux && ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE $(PWD_DIR)/initramfs
	make -C linux ARCH=riscv -j`nproc` olddefconfig

OPENSBI_DIR     := $(PWD_DIR)/opensbi
OPENSBI_FW_DIR  := $(OPENSBI_DIR)/build/platform/generic/firmware
OPENSBI_PAYLOAD := $(OPENSBI_FW_DIR)/fw_payload.bin
export OPENSBI_PAYLOAD

$(OPENSBI_DIR)/README.md:
	git clone https://github.com/riscv-software-src/opensbi $(OPENSBI_DIR)

OPENSBI_COMMON_FLAGS = \
	PLATFORM_RISCV_ISA=rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbs \
	PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j$(shell nproc)

opensbi: $(OPENSBI_DIR)/README.md ## Build OpenSBI (standalone, Clang/LLVM)
	make -C $(OPENSBI_DIR) LLVM=1 \
		platform-cflags-y="-Wno-gnu-designator" \
		$(OPENSBI_COMMON_FLAGS)

opensbi-gnu: $(OPENSBI_DIR)/README.md ## Build OpenSBI (GNU toolchain)
	make -C $(OPENSBI_DIR) CROSS_COMPILE=riscv64-linux-gnu- \
		$(OPENSBI_COMMON_FLAGS)

opensbi-with-kernel: $(OPENSBI_DIR)/README.md ## Build OpenSBI with Linux kernel as payload
	make -C $(OPENSBI_DIR) CROSS_COMPILE=riscv64-linux-gnu- \
		FW_PAYLOAD_PATH=$(PWD_DIR)/linux/arch/riscv/boot/Image \
		$(OPENSBI_COMMON_FLAGS)

opensbi-clean: ## Clean OpenSBI build artifacts
	make -C $(OPENSBI_DIR) clean

print-opensbi-payload: ## Print OpenSBI fw_payload.bin path
	@echo $(OPENSBI_PAYLOAD)

clean: ## Clean all build artifacts
	rm -rf linux initramfs initramfs.cpio.gz opensbi payload/build
