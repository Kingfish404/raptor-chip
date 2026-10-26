# Shared native RV64 DDR/NFS Ubuntu targets. Include after board.mk; the board
# Makefile selects the NIC by overriding its options on UBUNTU_BITSTREAM_TARGETS.
# Values left empty here fall back to the board's board.json.

UBUNTU_OUTPUT ?= $(BOARD_DIR)/build/ubuntu ## Kernel, bundle and server state directory
UBUNTU_ROOTFS ?= $(UBUNTU_OUTPUT)/rootfs ## Persistent NFS root filesystem
UBUNTU_SERVER ?= 192.168.50.1 ## Host IPv4 address serving NFS and TFTP
UBUNTU_CLIENT ?= 192.168.50.0/24 ## NFS client subnet or a single IPv4/32
UBUNTU_SSH_KEY ?= ## SSH public key installed for root (empty: no key)
UBUNTU_CROSS ?= riscv64-linux-gnu- ## Linux toolchain prefix for the kernel
UBUNTU_KERNEL_DIR ?= ## Reuse a verified kernel artifact directory
UBUNTU_NATIVE_BUILD ?= ## Native build directory to boot (empty: the matching configuration)
UBUNTU_TRANSPORT ?= ## Boot transport, tftp or uart (empty: board.json)
UBUNTU_BOOT_IP ?= ## Loader IPv4 address on the server LAN (empty: board.json)
UBUNTU_TFTP_PORT ?= 6969 ## Host TFTP port
UBUNTU_UPLOAD_BAUD ?= 312500 ## RAM loader baud; 115200 uploads directly through the ROM
UART_PORT ?= ## Board UART for ubuntu-boot, preferably /dev/serial/by-id/...
SUDO ?= sudo ## Command that gives ubuntu-rootfs root access
$(foreach v,UBUNTU_OUTPUT UBUNTU_ROOTFS UBUNTU_SERVER UBUNTU_CLIENT UBUNTU_SSH_KEY UBUNTU_CROSS \
	UBUNTU_KERNEL_DIR UBUNTU_NATIVE_BUILD UBUNTU_TRANSPORT UBUNTU_BOOT_IP UBUNTU_TFTP_PORT \
	UBUNTU_UPLOAD_BAUD UART_PORT SUDO,$(eval $(v) := $(strip $($(v)))))

UBUNTU = $(PYTHON) $(COMMON_DIR)/scripts/ubuntu.py --board '$(BOARD_DIR)' \
	--output '$(UBUNTU_OUTPUT)' --rootfs '$(UBUNTU_ROOTFS)' \
	--server '$(UBUNTU_SERVER)' --client '$(UBUNTU_CLIENT)' --cross '$(UBUNTU_CROSS)' \
	--jobs $(JOBS) --preset '$(RAPT_CONFIG)' --clock-mhz $(CLOCK_MHZ) \
	--native-build-root '$(BUILD_ROOT)' \
	$(if $(UBUNTU_KERNEL_DIR),--kernel-dir '$(UBUNTU_KERNEL_DIR)') \
	$(if $(UBUNTU_NATIVE_BUILD),--native-build '$(UBUNTU_NATIVE_BUILD)') \
	$(if $(UBUNTU_SSH_KEY),--ssh-key '$(UBUNTU_SSH_KEY)')
UBUNTU_BOOT_OPTIONS = --port '$(UART_PORT)' --upload-baud $(UBUNTU_UPLOAD_BAUD) \
	--tftp-port $(UBUNTU_TFTP_PORT) \
	$(if $(UBUNTU_TRANSPORT),--transport $(UBUNTU_TRANSPORT)) \
	$(if $(UBUNTU_BOOT_IP),--boot-ip $(UBUNTU_BOOT_IP))

UBUNTU_BITSTREAM_TARGETS := ubuntu-info ubuntu-bitstream ubuntu-load
UBUNTU_TARGETS := ubuntu-kernel ubuntu-rootfs ubuntu-bundle ubuntu-check ubuntu-serve \
	ubuntu-boot ubuntu-unserve

# Ubuntu runs on the RV64 DDR native SoC; RAPT_CONFIG may still be overridden.
$(UBUNTU_BITSTREAM_TARGETS) $(UBUNTU_TARGETS): RAPT_CONFIG = middle-cache
$(UBUNTU_BITSTREAM_TARGETS): override XLEN := 64
$(UBUNTU_BITSTREAM_TARGETS): override MEMORY := ddr

# ============================================================================
# Native Ubuntu 24.04 (RV64, DDR, Ethernet, root filesystem over NFS)
# ============================================================================

ubuntu-info: ## Print the Ubuntu bitstream configuration and output directory
	$(NATIVE_BUILD) info

ubuntu-bitstream: ## Build and timing-check the Ubuntu bitstream
	$(NATIVE_BUILD) build

ubuntu-load: ## Program the Ubuntu bitstream
	$(NATIVE_BUILD) load

ubuntu-kernel: ## Build the Linux kernel and OpenSBI payload
	$(UBUNTU) kernel

ubuntu-rootfs: ## Create or update the NFS root filesystem (uses sudo)
	$(SUDO) $(UBUNTU) rootfs

ubuntu-bundle: ## Package the kernel, OpenSBI and DTB for the Ubuntu bitstream
	$(UBUNTU) bundle

ubuntu-check: ## Verify the bundle against the board profile and root filesystem
	$(UBUNTU) check

ubuntu-serve: ## Export the root filesystem over NFS (uses sudo -n)
	$(UBUNTU) serve

ubuntu-boot: ## Send the bundle over TFTP or UART, boot and attach the console
	$(UBUNTU) boot $(UBUNTU_BOOT_OPTIONS) --console

ubuntu-unserve: ## Remove the NFS export
	$(UBUNTU) unserve

ubuntu-test: ## Run the shared native and Ubuntu host unit tests
	$(PYTHON) -m unittest discover -s $(COMMON_DIR)/tests -p 'test_*.py' -v

.PHONY: $(UBUNTU_BITSTREAM_TARGETS) $(UBUNTU_TARGETS) ubuntu-test
