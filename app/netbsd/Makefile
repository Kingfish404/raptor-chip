NETBSD_HOME   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RAPTOR_HOME   ?= $(abspath $(NETBSD_HOME)/../..)
NPROC         ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

NETBSD_SRC_URL      ?= https://github.com/NetBSD/src.git
NETBSD_SRC_REF      ?= netbsd-11
NETBSD_SRC_DIR      ?= $(NETBSD_HOME)/src
NETBSD_BUILD_DIR    ?= $(NETBSD_HOME)/build
NETBSD_SOURCE_BASE  ?= https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/source/sets
NETBSD_SRC_ARCHIVES := \
	$(NETBSD_BUILD_DIR)/src-$(subst /,_,$(NETBSD_SRC_REF)).tgz \
	$(NETBSD_BUILD_DIR)/sharesrc-$(subst /,_,$(NETBSD_SRC_REF)).tgz \
	$(NETBSD_BUILD_DIR)/syssrc-$(subst /,_,$(NETBSD_SRC_REF)).tgz \
	$(NETBSD_BUILD_DIR)/gnusrc-$(subst /,_,$(NETBSD_SRC_REF)).tgz
NETBSD_PATCH_DIR   ?= $(NETBSD_HOME)/patches
NETBSD_PATCHES     := $(wildcard $(NETBSD_PATCH_DIR)/*.patch)
NETBSD_TOOLS_DIR    ?= $(NETBSD_BUILD_DIR)/tools
NETBSD_OBJ_DIR      ?= $(NETBSD_BUILD_DIR)/obj
NETBSD_DEST_DIR     ?= $(NETBSD_BUILD_DIR)/destdir
NETBSD_RELEASE_DIR  ?= $(NETBSD_BUILD_DIR)/releasedir

NETBSD_MACHINE      ?= riscv
NETBSD_RV32_ARCH    ?= riscv32
NETBSD_RV64_ARCH    ?= riscv64
NETBSD_RV32_RELEASE ?= $(NETBSD_BUILD_DIR)/rv32/releasedir/riscv-riscv32
NETBSD_RV64_RELEASE ?= $(NETBSD_BUILD_DIR)/rv64/releasedir/riscv-riscv64
NETBSD_RV32_KERNEL  ?= $(NETBSD_RV32_RELEASE)/binary/kernel/netbsd-GENERIC
NETBSD_RV64_KERNEL  ?= $(NETBSD_RV64_RELEASE)/binary/kernel/netbsd-GENERIC64
NETBSD_RV32_DISK    ?= $(NETBSD_RV32_RELEASE)/binary/gzimg/riscv32.img
NETBSD_RV64_DISK    ?= $(NETBSD_RV64_RELEASE)/binary/gzimg/riscv64.img
NETBSD_RV32_KERNEL_GZ ?= $(NETBSD_RV32_KERNEL).gz
NETBSD_RV64_KERNEL_GZ ?= $(NETBSD_RV64_KERNEL).gz
NETBSD_RV32_DISK_GZ   ?= $(NETBSD_RV32_DISK).gz
NETBSD_RV64_DISK_GZ   ?= $(NETBSD_RV64_DISK).gz
NETBSD_OBJCOPY      ?= riscv64-linux-gnu-objcopy
NETBSD_SIM_DIR      ?= $(NETBSD_BUILD_DIR)/sim
NETBSD_RV32_SIM_DIR ?= $(NETBSD_SIM_DIR)/rv32
NETBSD_RV64_SIM_DIR ?= $(NETBSD_SIM_DIR)/rv64
NETBSD_RV32_KERNEL_BIN ?= $(NETBSD_RV32_SIM_DIR)/netbsd-GENERIC.bin
NETBSD_RV64_KERNEL_BIN ?= $(NETBSD_RV64_SIM_DIR)/netbsd-GENERIC64.bin
NETBSD_RV32_DTB     ?= $(NETBSD_RV32_SIM_DIR)/qemu-virt.dtb
NETBSD_RV64_DTB     ?= $(NETBSD_RV64_SIM_DIR)/qemu-virt.dtb
NETBSD_RV32_PAYLOAD_ELF ?= $(NETBSD_RV32_SIM_DIR)/opensbi/platform/generic/firmware/fw_payload.elf
NETBSD_RV64_PAYLOAD_ELF ?= $(NETBSD_RV64_SIM_DIR)/opensbi/platform/generic/firmware/fw_payload.elf
NETBSD_RV32_PAYLOAD ?= $(NETBSD_RV32_SIM_DIR)/opensbi/platform/generic/firmware/fw_payload.bin
NETBSD_RV64_PAYLOAD ?= $(NETBSD_RV64_SIM_DIR)/opensbi/platform/generic/firmware/fw_payload.bin
NETBSD_OPENSBI_SRC  ?= $(RAPTOR_HOME)/third_party/riscv-software-src/opensbi
NETBSD_OPENSBI_RV32_QEMU_DIR ?= $(NETBSD_BUILD_DIR)/opensbi-rv32-qemu
NETBSD_OPENSBI_RV32_QEMU_BIOS ?= $(NETBSD_OPENSBI_RV32_QEMU_DIR)/platform/generic/firmware/fw_dynamic.bin
NETBSD_OPENSBI_RV64_QEMU_DIR ?= $(NETBSD_BUILD_DIR)/opensbi-rv64-qemu
NETBSD_OPENSBI_RV64_QEMU_BIOS ?= $(NETBSD_OPENSBI_RV64_QEMU_DIR)/platform/generic/firmware/fw_dynamic.bin
NETBSD_NEMU_ROM_DIR ?= $(RAPTOR_HOME)/nemu/src/memory/rom

.PHONY: help check check-images fetch list-arch tools tools-rv32 tools-rv64 \
	build-rv32 build-rv64 rv32 rv64 sim-payload-rv32 sim-payload-rv64 \
	opensbi-rv32-qemu opensbi-rv64-qemu nemu-prepare-rv32 nemu-prepare-rv64 \
	nemu-run-rv32 nemu-run-rv64 qemu-rv32 qemu-rv64 clean

help: ## Show NetBSD build targets
	@echo "Usage: make <target> [VAR=value ...]"
	@echo
	@echo "Targets:"
	@echo "  fetch       Clone/update the NetBSD source tree"
	@echo "  check-images  Check image sizes, formats, and simulator limits"
	@echo "  list-arch   Show architectures supported by this source tree"
	@echo "  tools-rv32  Build the NetBSD cross-toolchain for RV32"
	@echo "  tools-rv64  Build the NetBSD cross-toolchain for RV64"
	@echo "  rv32        Build the RV32 NetBSD release (if supported by source)"
	@echo "  rv64        Build the RV64 NetBSD release"
	@echo "  sim-payload-rv32  Build RV32 OpenSBI+NetBSD flat payload for NEMU/RTL sim"
	@echo "  sim-payload-rv64  Build RV64 OpenSBI+NetBSD flat payload for NEMU/RTL sim"
	@echo "  opensbi-rv32-qemu  Build RV32 OpenSBI firmware for QEMU"
	@echo "  opensbi-rv64-qemu  Build RV64 OpenSBI firmware for QEMU"
	@echo "  nemu-prepare-rv32  Generate NEMU RV32 QEMU DTB alias"
	@echo "  nemu-prepare-rv64  Generate NEMU RV64 QEMU DTB alias"
	@echo "  nemu-run-rv32  Build and run NEMU RV32 with NetBSD disk"
	@echo "  nemu-run-rv64  Build and run NEMU RV64 with NetBSD disk"
	@echo "  qemu-rv32   Run NetBSD RV32 under QEMU"
	@echo "  qemu-rv64   Run NetBSD RV64 under QEMU"
	@echo
	@echo "Network: export http_proxy=http://localhost:9091 https_proxy=http://localhost:9091"

check: ## Check host tools needed to fetch and build NetBSD
	@for tool in git make gcc g++ awk sed; do \
		command -v $$tool >/dev/null || { echo "error: required host tool not found: $$tool"; exit 1; }; \
	done
	@echo "NetBSD host prerequisites found"

check-images: ## Check NetBSD image formats and backend memory limits
	@set -eu; \
	for tool in file stat; do command -v $$tool >/dev/null || { echo "error: required host tool not found: $$tool"; exit 1; }; done; \
	for image in "$(NETBSD_RV32_KERNEL)" "$(NETBSD_RV64_KERNEL)" "$(NETBSD_RV32_DISK)" "$(NETBSD_RV64_DISK)"; do \
		test -f "$$image" || { echo "error: missing NetBSD artifact: $$image"; exit 1; }; \
		echo "artifact: $$image ($$(stat -c%s "$$image") bytes)"; \
		file "$$image"; \
	done; \
	rv32_disk_size=$$(stat -c%s "$(NETBSD_RV32_DISK)"); \
	rv64_disk_size=$$(stat -c%s "$(NETBSD_RV64_DISK)"); \
	rv32_kernel_size=$$(stat -c%s "$(NETBSD_RV32_KERNEL)"); \
	rv64_kernel_size=$$(stat -c%s "$(NETBSD_RV64_KERNEL)"); \
	printf '%s\n' 'backend compatibility:'; \
	printf '  NEMU/RTL sim RAM IMG window: 128 MiB (0x08000000)\n'; \
	printf '  NetBSD RV32 kernel: %s bytes, disk: %s bytes\n' "$$rv32_kernel_size" "$$rv32_disk_size"; \
	printf '  NetBSD RV64 kernel: %s bytes, disk: %s bytes\n' "$$rv64_kernel_size" "$$rv64_disk_size"; \
	printf '%s\n' '  NEMU/RTL sim: use fw_payload.bin as IMG and the GPT image via --disk; do not pass the GPT image as IMG.'; \
	printf '%s\n' '  LiteX: the QEMU virtio/GPT image is not a direct --ram-init or serialboot payload; a LiteX-specific NetBSD port/DTB and SD boot flow are required.'; \
	printf '%s\n' '  Build simulator payloads with: make sim-payload-rv32 sim-payload-rv64'; \
	if command -v fdisk >/dev/null; then \
		fdisk -l "$(NETBSD_RV32_DISK)" 2>/dev/null | sed -n '1,14p'; \
		fdisk -l "$(NETBSD_RV64_DISK)" 2>/dev/null | sed -n '1,14p'; \
	else \
		echo 'warning: fdisk not found; GPT partition details were not checked'; \
	fi


$(NETBSD_BUILD_DIR)/src-$(subst /,_,$(NETBSD_SRC_REF)).tgz:
	@mkdir -p $(NETBSD_BUILD_DIR)
	/usr/bin/curl --http1.1 -L --fail --retry 8 --retry-all-errors \
		-o $@ $(NETBSD_SOURCE_BASE)/src.tgz

$(NETBSD_BUILD_DIR)/sharesrc-$(subst /,_,$(NETBSD_SRC_REF)).tgz:
	@mkdir -p $(NETBSD_BUILD_DIR)
	/usr/bin/curl --http1.1 -L --fail --retry 8 --retry-all-errors \
		-o $@ $(NETBSD_SOURCE_BASE)/sharesrc.tgz

$(NETBSD_BUILD_DIR)/syssrc-$(subst /,_,$(NETBSD_SRC_REF)).tgz:
	@mkdir -p $(NETBSD_BUILD_DIR)
	/usr/bin/curl --http1.1 -L --fail --retry 8 --retry-all-errors \
		-o $@ $(NETBSD_SOURCE_BASE)/syssrc.tgz

$(NETBSD_BUILD_DIR)/gnusrc-$(subst /,_,$(NETBSD_SRC_REF)).tgz:
	@mkdir -p $(NETBSD_BUILD_DIR)
	/usr/bin/curl --http1.1 -L --fail --retry 8 --retry-all-errors \
		-o $@ $(NETBSD_SOURCE_BASE)/gnusrc.tgz

$(NETBSD_SRC_DIR)/build.sh: $(NETBSD_SRC_ARCHIVES)
	@set -eu; \
	rm -rf $(NETBSD_SRC_DIR) $(NETBSD_BUILD_DIR)/src-unpack; \
	mkdir -p $(NETBSD_BUILD_DIR)/src-unpack; \
	for archive in $(NETBSD_SRC_ARCHIVES); do tar -xzf "$$archive" -C $(NETBSD_BUILD_DIR)/src-unpack; done; \
	test -d $(NETBSD_BUILD_DIR)/src-unpack/usr/src; \
	mv $(NETBSD_BUILD_DIR)/src-unpack/usr/src $(NETBSD_SRC_DIR); \
	test -x $(NETBSD_SRC_DIR)/build.sh; \
	test -d $(NETBSD_SRC_DIR)/share/mk; \
	test -d $(NETBSD_SRC_DIR)/sys; \
	for patch_file in $(NETBSD_PATCHES); do \
		patch -d $(NETBSD_SRC_DIR) -p1 -N --forward < "$$patch_file" || \
		{ patch_status=$$?; test $$patch_status -eq 1 || exit $$patch_status; }; \
	done; \
	rm -rf $(NETBSD_BUILD_DIR)/src-unpack

fetch: $(NETBSD_SRC_DIR)/build.sh ## Fetch the NetBSD source tree
	@echo "NetBSD source: $(NETBSD_SRC_DIR)"

list-arch: fetch ## Show source-supported MACHINE/MACHINE_ARCH pairs
	$(NETBSD_SRC_DIR)/build.sh -m 'riscv*' list-arch

define netbsd_build
	@mkdir -p $(NETBSD_BUILD_DIR)/$(1)/obj $(NETBSD_BUILD_DIR)/$(1)/destdir $(NETBSD_BUILD_DIR)/$(1)/releasedir
	$(NETBSD_SRC_DIR)/build.sh -U -u -j$(NPROC) \
		-O $(NETBSD_BUILD_DIR)/$(1)/obj \
		-T $(NETBSD_BUILD_DIR)/$(1)/tools \
		-D $(NETBSD_BUILD_DIR)/$(1)/destdir \
		-R $(NETBSD_BUILD_DIR)/$(1)/releasedir \
		-m $(NETBSD_MACHINE) -a $(2) release
endef

define netbsd_release_kernel
	$(NETBSD_SRC_DIR)/build.sh -U -u -j$(NPROC) \
		-O $(NETBSD_BUILD_DIR)/$(1)/obj \
		-T $(NETBSD_BUILD_DIR)/$(1)/tools \
		-D $(NETBSD_BUILD_DIR)/$(1)/destdir \
		-R $(NETBSD_BUILD_DIR)/$(1)/releasedir \
		-m $(NETBSD_MACHINE) -a $(2) releasekernel=$(3)
endef

tools-rv32: fetch check ## Build the RV32 NetBSD cross-toolchain
	$(NETBSD_SRC_DIR)/build.sh -U -u -j$(NPROC) \
		-O $(NETBSD_BUILD_DIR)/rv32/obj -T $(NETBSD_BUILD_DIR)/rv32/tools \
		-D $(NETBSD_BUILD_DIR)/rv32/destdir -R $(NETBSD_BUILD_DIR)/rv32/releasedir \
		-m $(NETBSD_MACHINE) -a $(NETBSD_RV32_ARCH) tools

tools-rv64: fetch check ## Build the RV64 NetBSD cross-toolchain
	$(NETBSD_SRC_DIR)/build.sh -U -u -j$(NPROC) \
		-O $(NETBSD_BUILD_DIR)/rv64/obj -T $(NETBSD_BUILD_DIR)/rv64/tools \
		-D $(NETBSD_BUILD_DIR)/rv64/destdir -R $(NETBSD_BUILD_DIR)/rv64/releasedir \
		-m $(NETBSD_MACHINE) -a $(NETBSD_RV64_ARCH) tools

build-rv32: fetch check ## Build the RV32 NetBSD release
	$(call netbsd_build,rv32,$(NETBSD_RV32_ARCH))
	$(call netbsd_release_kernel,rv32,$(NETBSD_RV32_ARCH),GENERIC)

build-rv64: fetch check ## Build the RV64 NetBSD release
	$(call netbsd_build,rv64,$(NETBSD_RV64_ARCH))
	$(call netbsd_release_kernel,rv64,$(NETBSD_RV64_ARCH),GENERIC64)

rv32: build-rv32 ## Alias for the RV32 release build
rv64: build-rv64 ## Alias for the RV64 release build


$(NETBSD_RV32_KERNEL_BIN): $(NETBSD_RV32_KERNEL_GZ)
	@mkdir -p $(dir $@)
	gzip -dc $< > $(NETBSD_RV32_KERNEL)
	$(NETBSD_OBJCOPY) -O binary $(NETBSD_RV32_KERNEL) $@

$(NETBSD_RV64_KERNEL_BIN): $(NETBSD_RV64_KERNEL_GZ)
	@mkdir -p $(dir $@)
	gzip -dc $< > $(NETBSD_RV64_KERNEL)
	$(NETBSD_OBJCOPY) -O binary $(NETBSD_RV64_KERNEL) $@

$(NETBSD_RV32_DTB):
	@mkdir -p $(dir $@)
	qemu-system-riscv32 -M virt,dumpdtb=$@ -m 128M -bios none

$(NETBSD_RV64_DTB):
	@mkdir -p $(dir $@)
	qemu-system-riscv64 -M virt,dumpdtb=$@ -m 128M -bios none

$(NETBSD_RV32_PAYLOAD_ELF) $(NETBSD_RV32_PAYLOAD): $(NETBSD_RV32_KERNEL_BIN) $(NETBSD_RV32_DTB)
	@mkdir -p $(NETBSD_RV32_SIM_DIR)/opensbi
	$(MAKE) -C $(NETBSD_OPENSBI_SRC) LLVM=1 \
		PLATFORM_RISCV_ISA=rv32imac_zicsr_zifencei \
		PLATFORM_RISCV_XLEN=32 PLATFORM=generic FW_PAYLOAD=y \
		FW_PAYLOAD_PATH=$(abspath $(NETBSD_RV32_KERNEL_BIN)) \
		FW_FDT_PATH=$(abspath $(NETBSD_RV32_DTB)) \
		FW_PAYLOAD_OFFSET=0x200000 FW_PAYLOAD_FDT_OFFSET=0x2200000 \
		O=$(NETBSD_RV32_SIM_DIR)/opensbi -j$(NPROC)
	@test -f $(NETBSD_RV32_PAYLOAD_ELF); test -f $(NETBSD_RV32_PAYLOAD)

$(NETBSD_RV64_PAYLOAD_ELF) $(NETBSD_RV64_PAYLOAD): $(NETBSD_RV64_KERNEL_BIN) $(NETBSD_RV64_DTB)
	@mkdir -p $(NETBSD_RV64_SIM_DIR)/opensbi
	$(MAKE) -C $(NETBSD_OPENSBI_SRC) LLVM=1 \
		PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
		PLATFORM_RISCV_XLEN=64 PLATFORM=generic FW_PAYLOAD=y \
		FW_PAYLOAD_PATH=$(abspath $(NETBSD_RV64_KERNEL_BIN)) \
		FW_FDT_PATH=$(abspath $(NETBSD_RV64_DTB)) \
		FW_PAYLOAD_OFFSET=0x200000 FW_PAYLOAD_FDT_OFFSET=0x2200000 \
		O=$(NETBSD_RV64_SIM_DIR)/opensbi -j$(NPROC)
	@test -f $(NETBSD_RV64_PAYLOAD_ELF); test -f $(NETBSD_RV64_PAYLOAD)

sim-payload-rv32: $(NETBSD_RV32_PAYLOAD_ELF) $(NETBSD_RV32_PAYLOAD) ## Build RV32 flat payload for NEMU/RTL sim
	@echo "RV32 simulator IMG: $(NETBSD_RV32_PAYLOAD)"
	@echo "RV32 QEMU BIOS: $(NETBSD_RV32_PAYLOAD_ELF)"
	@echo "RV32 simulator disk: $(NETBSD_RV32_DISK)"

sim-payload-rv64: $(NETBSD_RV64_PAYLOAD_ELF) $(NETBSD_RV64_PAYLOAD) ## Build RV64 flat payload for NEMU/RTL sim
	@echo "RV64 simulator IMG: $(NETBSD_RV64_PAYLOAD)"
	@echo "RV64 QEMU BIOS: $(NETBSD_RV64_PAYLOAD_ELF)"
	@echo "RV64 simulator disk: $(NETBSD_RV64_DISK)"

nemu-prepare-rv32: ## Generate the NEMU RV32 QEMU DTB expected by device configs
	$(MAKE) -C $(NETBSD_NEMU_ROM_DIR) build_dtb
	ln -sf qemu-rv32ima.dtb $(NETBSD_NEMU_ROM_DIR)/spike-rv32ima.dtb
	ln -sf qemu-rv32ima.dtb $(NETBSD_NEMU_ROM_DIR)/spike-rv32ima-256m.dtb

nemu-prepare-rv64: ## Generate the NEMU RV64 QEMU DTB expected by device configs
	$(MAKE) -C $(NETBSD_NEMU_ROM_DIR) build_dtb
	ln -sf qemu-rv64ima.dtb $(NETBSD_NEMU_ROM_DIR)/spike-rv64ima.dtb
	ln -sf qemu-rv64ima.dtb $(NETBSD_NEMU_ROM_DIR)/spike-rv64ima-256m.dtb

opensbi-rv32-qemu: ## Build RV32 OpenSBI firmware compatible with QEMU virt
	@test -f $(NETBSD_OPENSBI_SRC)/Makefile || { echo "error: OpenSBI source not found at $(NETBSD_OPENSBI_SRC)"; exit 1; }
	$(MAKE) -C $(NETBSD_OPENSBI_SRC) LLVM=1 \
		PLATFORM_RISCV_ISA=rv32imac_zicsr_zifencei \
		PLATFORM_RISCV_XLEN=32 PLATFORM=generic \
		O=$(NETBSD_OPENSBI_RV32_QEMU_DIR) -j$(NPROC)

opensbi-rv64-qemu: ## Build RV64 OpenSBI firmware compatible with QEMU virt
	@test -f $(NETBSD_OPENSBI_SRC)/Makefile || { echo "error: OpenSBI source not found at $(NETBSD_OPENSBI_SRC)"; exit 1; }
	$(MAKE) -C $(NETBSD_OPENSBI_SRC) LLVM=1 \
		PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
		PLATFORM_RISCV_XLEN=64 PLATFORM=generic \
		O=$(NETBSD_OPENSBI_RV64_QEMU_DIR) -j$(NPROC)

nemu-run-rv32: sim-payload-rv32 nemu-prepare-rv32 ## Build and run NEMU RV32 with NetBSD disk
	@test -f $(NETBSD_RV32_DISK_GZ) || { echo "error: missing $(NETBSD_RV32_DISK_GZ); run make build-rv32 first"; exit 1; }
	gzip -dkf $(NETBSD_RV32_DISK_GZ)
	$(MAKE) -C $(RAPTOR_HOME)/nemu NEMU_HOME=$(RAPTOR_HOME)/nemu riscv32_linux_device_defconfig
	$(MAKE) -C $(RAPTOR_HOME)/nemu NEMU_HOME=$(RAPTOR_HOME)/nemu -j$(NPROC)
	cd $(RAPTOR_HOME)/nemu && NEMU_HOME=$(RAPTOR_HOME)/nemu ./build/riscv32-nemu-interpreter -b --disk=$(abspath $(NETBSD_RV32_DISK)) $(abspath $(NETBSD_RV32_PAYLOAD))

nemu-run-rv64: sim-payload-rv64 nemu-prepare-rv64 ## Build and run NEMU RV64 with NetBSD disk
	@test -f $(NETBSD_RV64_DISK_GZ) || { echo "error: missing $(NETBSD_RV64_DISK_GZ); run make build-rv64 first"; exit 1; }
	gzip -dkf $(NETBSD_RV64_DISK_GZ)
	$(MAKE) -C $(RAPTOR_HOME)/nemu NEMU_HOME=$(RAPTOR_HOME)/nemu riscv64_linux_device_defconfig
	$(MAKE) -C $(RAPTOR_HOME)/nemu NEMU_HOME=$(RAPTOR_HOME)/nemu -j$(NPROC)
	cd $(RAPTOR_HOME)/nemu && NEMU_HOME=$(RAPTOR_HOME)/nemu ./build/riscv64-nemu-interpreter -b --disk=$(abspath $(NETBSD_RV64_DISK)) $(abspath $(NETBSD_RV64_PAYLOAD))

qemu-rv32: opensbi-rv32-qemu ## Build prerequisites and run NetBSD RV32 under QEMU
	@test -f $(NETBSD_RV32_KERNEL_GZ) || { echo "error: missing $(NETBSD_RV32_KERNEL_GZ); run make build-rv32 first"; exit 1; }
	@test -f $(NETBSD_RV32_DISK_GZ) || { echo "error: missing $(NETBSD_RV32_DISK_GZ); run make build-rv32 first"; exit 1; }
	gzip -dkf $(NETBSD_RV32_KERNEL_GZ) $(NETBSD_RV32_DISK_GZ)
	exec qemu-system-riscv32 -M virt -m 2G -bios $(NETBSD_OPENSBI_RV32_QEMU_BIOS) -kernel $(NETBSD_RV32_KERNEL) -drive if=none,file=$(NETBSD_RV32_DISK),id=hd0,format=raw -device virtio-blk-device,drive=hd0 -device virtio-rng-device -netdev type=user,id=net0 -device virtio-net-device,netdev=net0,mac=00:11:22:33:44:55 -append "root=dk1" -nographic

qemu-rv64: opensbi-rv64-qemu ## Build prerequisites and run NetBSD RV64 under QEMU
	@test -f $(NETBSD_RV64_KERNEL_GZ) || { echo "error: missing $(NETBSD_RV64_KERNEL_GZ); run make build-rv64 first"; exit 1; }
	@test -f $(NETBSD_RV64_DISK_GZ) || { echo "error: missing $(NETBSD_RV64_DISK_GZ); run make build-rv64 first"; exit 1; }
	gzip -dkf $(NETBSD_RV64_KERNEL_GZ) $(NETBSD_RV64_DISK_GZ)
	exec qemu-system-riscv64 -M virt -m 4G -bios $(NETBSD_OPENSBI_RV64_QEMU_BIOS) -kernel $(NETBSD_RV64_KERNEL) -drive if=none,file=$(NETBSD_RV64_DISK),id=hd0,format=raw -device virtio-blk-device,drive=hd0 -device virtio-rng-device -netdev type=user,id=net0 -device virtio-net-device,netdev=net0,mac=00:11:22:33:44:55 -append "root=dk1" -nographic

clean: ## Remove NetBSD source and build artifacts
	rm -rf $(NETBSD_SRC_DIR) $(NETBSD_BUILD_DIR)
