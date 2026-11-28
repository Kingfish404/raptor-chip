FREEBSD_HOME  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RAPTOR_HOME   ?= $(abspath $(FREEBSD_HOME)/../..)
PYTHON        ?= python3
NPROC         ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

FREEBSD_RELEASE     ?= 15.0-RELEASE
FREEBSD_ARCH        ?= riscv-riscv64
FREEBSD_MIRROR      ?= https://download.freebsd.org/releases/VM-IMAGES/$(FREEBSD_RELEASE)/riscv64/Latest
FREEBSD_IMG_STEM    := FreeBSD-$(FREEBSD_RELEASE)-$(FREEBSD_ARCH)-ufs.raw
FREEBSD_BUILD_DIR   ?= $(FREEBSD_HOME)/build
FREEBSD_DL_DIR      ?= $(FREEBSD_BUILD_DIR)/downloads
FREEBSD_RAW_XZ      := $(FREEBSD_DL_DIR)/$(FREEBSD_IMG_STEM).xz
FREEBSD_SHA256_FILE := $(FREEBSD_DL_DIR)/CHECKSUM.SHA256
FREEBSD_RAW_IMG     := $(FREEBSD_DL_DIR)/$(FREEBSD_IMG_STEM)
FREEBSD_FPGA_IMG    ?= $(FREEBSD_BUILD_DIR)/fpga/freebsd-riscv64.raw
FREEBSD_WORK_DIR    ?= $(FREEBSD_BUILD_DIR)/fpga-work

OS_BOOT_TOOL := $(RAPTOR_HOME)/tools/qemu_io_bridge/os_image_boot.py
QEMU_CPU     ?= rv64,zba=true,zbb=true,zbc=true,zbs=true,zicbom=true,zicboz=true,svpbmt=true,sstc=false,v=true
QEMU_MEM     ?= 4G
QEMU_SMP     ?= 2

FPGA_BOARD   ?= $(RAPTOR_HOME)/fpga/mlk-cu08-ku15p
FPGA_BOARD_DTS := $(FPGA_BOARD)/build/rv64-default-w4-ddr-50MHz-*/native.dts
FPGA_IO_DTS    := $(firstword $(shell grep -l "virtio_mmio@10001000" $(FPGA_BOARD_DTS) 2>/dev/null))
FPGA_DTB       ?= $(patsubst %/native.dts,%/native.dtb,$(FPGA_IO_DTS))
FPGA_PORT    ?= /dev/ttyUSB0
FPGA_SERVER  ?= 192.168.50.1
FPGA_LOADER  ?= 192.168.50.92
FPGA_BRIDGE  ?= 192.168.50.93
FPGA_MAC     ?= 02:52:41:50:15:01

.PHONY: help check fetch check-images firmware prepare-fpga qemu qemu-pristine \
	fpga-boot fpga-boot-pristine clean

help: ## Show FreeBSD targets
	@echo "Usage: make <target> [VAR=value ...]"
	@echo
	@echo "Targets:"
	@echo "  fetch              Download & verify official FreeBSD $(FREEBSD_RELEASE) RISC-V .raw.xz"
	@echo "  check-images       Inspect verified raw image and GPT partition layout"
	@echo "  firmware           Build OpenSBI + U-Boot UEFI firmware (U-mode counters enabled)"
	@echo "  prepare-fpga       Provision cloned image with SSH keys & Raptor microbenchmarks"
	@echo "  qemu               Boot provisioned FreeBSD image under QEMU (VirtIO-MMIO v2)"
	@echo "  qemu-pristine      Boot unmodified upstream FreeBSD image under QEMU (-snapshot)"
	@echo "  fpga-boot          Boot provisioned FreeBSD image on Raptor FPGA (VirtIO + UDP RQIO)"
	@echo "  fpga-boot-pristine Boot unmodified upstream FreeBSD .raw directly on Raptor FPGA"

check: ## Check host prerequisites
	@for tool in curl xz sha256sum dtc fdtput qemu-system-riscv64 $(PYTHON); do \
		command -v $$tool >/dev/null || { echo "error: missing host tool: $$tool"; exit 1; }; \
	done
	@echo "FreeBSD host prerequisites found"

$(FREEBSD_SHA256_FILE):
	@mkdir -p $(FREEBSD_DL_DIR)
	curl --http1.1 -L --fail --retry 5 -o $@ $(FREEBSD_MIRROR)/CHECKSUM.SHA256

$(FREEBSD_RAW_XZ): $(FREEBSD_SHA256_FILE)
	@mkdir -p $(FREEBSD_DL_DIR)
	curl --http1.1 -L --fail --retry 5 -C - -o $@ $(FREEBSD_MIRROR)/$(FREEBSD_IMG_STEM).xz
	cd $(FREEBSD_DL_DIR) && grep "$(FREEBSD_IMG_STEM).xz" CHECKSUM.SHA256 | sha256sum -c -

$(FREEBSD_RAW_IMG): $(FREEBSD_RAW_XZ)
	xz -dkf $(FREEBSD_RAW_XZ)

fetch: $(FREEBSD_RAW_IMG) ## Download and SHA256-verify upstream FreeBSD VM image
	@echo "FreeBSD raw image ready: $(FREEBSD_RAW_IMG)"

check-images: $(FREEBSD_RAW_IMG) ## Inspect FreeBSD GPT layout and sizes
	@ls -lh $(FREEBSD_RAW_IMG)
	@file $(FREEBSD_RAW_IMG)
	@if command -v fdisk >/dev/null; then fdisk -l $(FREEBSD_RAW_IMG) 2>/dev/null | sed -n '1,16p'; fi

firmware: ## Build OpenSBI + U-Boot UEFI firmware for QEMU and FPGA
	$(PYTHON) $(OS_BOOT_TOOL) firmware --work-dir $(FREEBSD_WORK_DIR) --jobs $(NPROC)

$(FREEBSD_FPGA_IMG): $(FREEBSD_RAW_IMG)
	$(PYTHON) $(OS_BOOT_TOOL) provision \
		--os freebsd \
		--src $(FREEBSD_RAW_IMG) \
		--dst $(FREEBSD_FPGA_IMG) \
		--work-dir $(FREEBSD_WORK_DIR)

prepare-fpga: $(FREEBSD_FPGA_IMG) ## Build SSH + microbenchmark-ready FreeBSD image

qemu-pristine: $(FREEBSD_RAW_IMG) firmware ## Boot unmodified upstream FreeBSD image in QEMU
	exec qemu-system-riscv64 -M virt -cpu $(QEMU_CPU) -smp $(QEMU_SMP) -m $(QEMU_MEM) \
		-nographic -global virtio-mmio.force-legacy=false -snapshot \
		-bios $(FREEBSD_WORK_DIR)/opensbi-u-boot/platform/generic/firmware/fw_dynamic.bin \
		-kernel $(FREEBSD_WORK_DIR)/uboot/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin \
		-drive file=$(FREEBSD_RAW_IMG),format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		-device virtio-rng-device \
		-netdev user,id=net0,hostfwd=tcp::2225-:22 \
		-device virtio-net-device,netdev=net0,mac=$(FPGA_MAC)

qemu: $(FREEBSD_FPGA_IMG) firmware ## Boot SSH-provisioned FreeBSD image in QEMU
	exec qemu-system-riscv64 -M virt -cpu $(QEMU_CPU) -smp $(QEMU_SMP) -m $(QEMU_MEM) \
		-nographic -global virtio-mmio.force-legacy=false \
		-bios $(FREEBSD_WORK_DIR)/opensbi-u-boot/platform/generic/firmware/fw_dynamic.bin \
		-kernel $(FREEBSD_WORK_DIR)/uboot/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin \
		-drive file=$(FREEBSD_FPGA_IMG),format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		-device virtio-rng-device \
		-netdev user,id=net0,hostfwd=tcp::2225-:22 \
		-device virtio-net-device,netdev=net0,mac=$(FPGA_MAC)

fpga-boot-pristine: $(FREEBSD_RAW_IMG) ## Boot unmodified upstream FreeBSD .raw on FPGA (COW)
	@test -n "$(FPGA_DTB)" || { echo "error: set FPGA_DTB=/path/to/native.dtb"; exit 1; }
	$(PYTHON) $(OS_BOOT_TOOL) fpga-boot \
		--board $(FPGA_BOARD) --dtb $(FPGA_DTB) --disk $(FREEBSD_RAW_IMG) \
		--work-dir $(FREEBSD_WORK_DIR) --port $(FPGA_PORT) \
		--server $(FPGA_SERVER) --loader-ip $(FPGA_LOADER) \
		--bridge-ip $(FPGA_BRIDGE) --mac $(FPGA_MAC) \
		--snapshot --keep-alive

fpga-boot: $(FREEBSD_FPGA_IMG) ## Boot SSH + microbenchmark FreeBSD image on FPGA
	@test -n "$(FPGA_DTB)" || { echo "error: set FPGA_DTB=/path/to/native.dtb"; exit 1; }
	$(PYTHON) $(OS_BOOT_TOOL) fpga-boot \
		--board $(FPGA_BOARD) --dtb $(FPGA_DTB) --disk $(FREEBSD_FPGA_IMG) \
		--work-dir $(FREEBSD_WORK_DIR) --port $(FPGA_PORT) \
		--server $(FPGA_SERVER) --loader-ip $(FPGA_LOADER) \
		--bridge-ip $(FPGA_BRIDGE) --mac $(FPGA_MAC) \
		--keep-alive

clean: ## Remove downloaded and generated FreeBSD artifacts
	rm -rf $(FREEBSD_BUILD_DIR)
