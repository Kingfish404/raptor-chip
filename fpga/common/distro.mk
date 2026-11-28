# Shared RV64 DDR/NFS/DDR4-RAM Linux distribution targets (Ubuntu, Debian, Alpine).
# Include after board.mk; the board Makefile selects the NIC by overriding its
# options on UBUNTU_BITSTREAM_TARGETS. Values left empty fall back to board.json.

UBUNTU_OUTPUT ?= $(BOARD_DIR)/build/ubuntu ## Ubuntu kernel, bundle and server state directory
UBUNTU_ROOTFS ?= $(UBUNTU_OUTPUT)/rootfs ## Persistent Ubuntu NFS root filesystem
DEBIAN_OUTPUT ?= $(BOARD_DIR)/build/debian ## Debian kernel, bundle and server state directory
DEBIAN_ROOTFS ?= $(DEBIAN_OUTPUT)/rootfs ## Persistent Debian NFS root filesystem
ALPINE_OUTPUT ?= $(BOARD_DIR)/build/alpine ## Alpine kernel, bundle and server state directory
ALPINE_ROOTFS ?= $(ALPINE_OUTPUT)/rootfs ## Persistent Alpine NFS root filesystem
ALPINE_SMP_OUTPUT ?= $(BOARD_DIR)/build/alpine-smp ## Multi-hart Alpine SMP output directory
SMP_RAPT_CONFIG ?= default-smp2 ## Default multi-hart SMP preset for alpine-smp-* targets
SMP_ROOT_DEVICE ?= squashfs ## Default rootfs mode for alpine-smp-* (squashfs, ramroot, or nfs)
UBUNTU_SERVER ?= 192.168.50.1 ## Host IPv4 address serving NFS and TFTP
UBUNTU_CLIENT ?= 192.168.50.0/24 ## NFS client subnet or a single IPv4/32
UBUNTU_SSH_KEY ?= ## SSH public key installed for root (empty: no key)
DEBIAN_SSH_KEY ?= $(UBUNTU_SSH_KEY) ## SSH public key for Debian root (defaults to UBUNTU_SSH_KEY)
ALPINE_SSH_KEY ?= $(UBUNTU_SSH_KEY) ## SSH public key for Alpine root (defaults to UBUNTU_SSH_KEY)
UBUNTU_CROSS ?= riscv64-linux-gnu- ## Linux toolchain prefix for the kernel
UBUNTU_KERNEL_DIR ?= ## Reuse a verified kernel artifact directory
UBUNTU_BOARD_BUILD ?= $(UBUNTU_NATIVE_BUILD) ## Board build directory to boot (empty: auto)
UBUNTU_TRANSPORT ?= ## Boot transport, tftp or uart (empty: board.json)
UBUNTU_BOOT_IP ?= ## Loader IPv4 address on the server LAN (empty: board.json)
UBUNTU_MAC ?= ## Unicast MAC override for multi-board LAN setups (empty: board.json)
UBUNTU_TFTP_PORT ?= 6969 ## Host TFTP port
UBUNTU_UPLOAD_BAUD ?= 312500 ## RAM loader baud; 115200 uploads directly through the ROM
UBUNTU_ROOT_DEVICE ?= nfs ## Rootfs mode: nfs, ramroot, squashfs, or /dev/vda...
UBUNTU_SYSTEMD_TARGET ?= default ## Systemd target: default or minimal
UBUNTU_HTTP_PROXY ?= ## Optional HTTP/HTTPS proxy URL injected at boot
UBUNTU_APT_MIRROR ?= ## Optional package mirror URL injected at boot
DISTRO_HTTP_PROXY ?= $(UBUNTU_HTTP_PROXY) ## Alias for UBUNTU_HTTP_PROXY
DISTRO_APT_MIRROR ?= $(UBUNTU_APT_MIRROR) ## Alias for UBUNTU_APT_MIRROR
UART_PORT ?= ## Board UART for *-boot, preferably /dev/serial/by-id/...
SUDO ?= sudo ## Command that gives *-rootfs root access
$(foreach v,UBUNTU_OUTPUT UBUNTU_ROOTFS DEBIAN_OUTPUT DEBIAN_ROOTFS ALPINE_OUTPUT ALPINE_ROOTFS \
	ALPINE_SMP_OUTPUT SMP_RAPT_CONFIG SMP_ROOT_DEVICE \
	UBUNTU_SERVER UBUNTU_CLIENT UBUNTU_SSH_KEY DEBIAN_SSH_KEY ALPINE_SSH_KEY UBUNTU_CROSS \
	UBUNTU_KERNEL_DIR UBUNTU_BOARD_BUILD UBUNTU_TRANSPORT UBUNTU_BOOT_IP UBUNTU_MAC \
	UBUNTU_TFTP_PORT UBUNTU_UPLOAD_BAUD UBUNTU_ROOT_DEVICE UBUNTU_SYSTEMD_TARGET \
	UBUNTU_HTTP_PROXY UBUNTU_APT_MIRROR DISTRO_HTTP_PROXY DISTRO_APT_MIRROR UART_PORT SUDO,\
	$(eval $(v) := $(strip $($(v)))))

define _distro_runner
$(PYTHON) $(COMMON_DIR)/scripts/distro.py --board '$(BOARD_DIR)' --distro '$(1)' \
	--output '$(2)' --rootfs '$(3)' \
	--server '$(UBUNTU_SERVER)' --client '$(UBUNTU_CLIENT)' --cross '$(UBUNTU_CROSS)' \
	--jobs $(JOBS) --preset '$(RAPT_CONFIG)' --nharts '$(NHARTS)' --vector '$(VECTOR)' \
	--clock-mhz $(CLOCK_MHZ) \
	--root-device '$(UBUNTU_ROOT_DEVICE)' --systemd-target '$(UBUNTU_SYSTEMD_TARGET)' \
	--board-build-root '$(BUILD_ROOT)' \
	$(if $(UBUNTU_KERNEL_DIR),--kernel-dir '$(UBUNTU_KERNEL_DIR)') \
	$(if $(UBUNTU_BOARD_BUILD),--board-build '$(UBUNTU_BOARD_BUILD)') \
	$(if $(4),--ssh-key '$(4)')
endef

UBUNTU = $(call _distro_runner,ubuntu,$(UBUNTU_OUTPUT),$(UBUNTU_ROOTFS),$(UBUNTU_SSH_KEY))
DEBIAN = $(call _distro_runner,debian,$(DEBIAN_OUTPUT),$(DEBIAN_ROOTFS),$(DEBIAN_SSH_KEY))
ALPINE = $(call _distro_runner,alpine,$(ALPINE_OUTPUT),$(ALPINE_ROOTFS),$(ALPINE_SSH_KEY))
ALPINE_SMP = $(call _distro_runner,alpine,$(ALPINE_SMP_OUTPUT),$(ALPINE_ROOTFS),$(ALPINE_SSH_KEY))

UBUNTU_BOOT_OPTIONS = --port '$(UART_PORT)' --upload-baud $(UBUNTU_UPLOAD_BAUD) \
	--tftp-port $(UBUNTU_TFTP_PORT) \
	$(if $(UBUNTU_TRANSPORT),--transport $(UBUNTU_TRANSPORT)) \
	$(if $(UBUNTU_BOOT_IP),--boot-ip $(UBUNTU_BOOT_IP)) \
	$(if $(UBUNTU_MAC),--mac '$(UBUNTU_MAC)') \
	$(if $(DISTRO_HTTP_PROXY),--http-proxy '$(DISTRO_HTTP_PROXY)') \
	$(if $(DISTRO_APT_MIRROR),--apt-mirror '$(DISTRO_APT_MIRROR)')

ALPINE_SMP_BITSTREAM_TARGETS := alpine-smp-info alpine-smp-bitstream alpine-smp-load
ALPINE_SMP_TARGETS := alpine-smp-kernel alpine-smp-rootfs alpine-smp-apps \
	alpine-smp-bundle alpine-smp-check alpine-smp-serve alpine-smp-boot alpine-smp-unserve

UBUNTU_BITSTREAM_TARGETS := ubuntu-info ubuntu-bitstream ubuntu-load \
	debian-info debian-bitstream debian-load \
	alpine-info alpine-bitstream alpine-load \
	$(ALPINE_SMP_BITSTREAM_TARGETS)
UBUNTU_TARGETS := ubuntu-kernel ubuntu-rootfs ubuntu-apps ubuntu-bundle ubuntu-check \
	ubuntu-serve ubuntu-boot ubuntu-unserve \
	debian-kernel debian-rootfs debian-apps debian-bundle debian-check \
	debian-serve debian-boot debian-unserve \
	alpine-kernel alpine-rootfs alpine-apps alpine-bundle alpine-check \
	alpine-serve alpine-boot alpine-unserve \
	$(ALPINE_SMP_TARGETS)

# Default single-hart distros to `default` and multi-hart SMP targets to `$(SMP_RAPT_CONFIG)`.
$(filter-out $(ALPINE_SMP_BITSTREAM_TARGETS),$(UBUNTU_BITSTREAM_TARGETS)) \
	$(filter-out $(ALPINE_SMP_TARGETS),$(UBUNTU_TARGETS)): RAPT_CONFIG = default
$(ALPINE_SMP_BITSTREAM_TARGETS) $(ALPINE_SMP_TARGETS): RAPT_CONFIG = $(SMP_RAPT_CONFIG)
$(ALPINE_SMP_TARGETS): UBUNTU_ROOT_DEVICE = $(SMP_ROOT_DEVICE)
$(UBUNTU_BITSTREAM_TARGETS): override XLEN := 64
$(UBUNTU_BITSTREAM_TARGETS): override MEMORY := ddr

# ============================================================================
# Ubuntu RVA23 (RV64, DDR, Ethernet, NFS / SquashFS / RAM rootfs)
# ============================================================================

ubuntu-info: ## Print the Ubuntu bitstream configuration and output directory
	$(NATIVE_BUILD) info

ubuntu-bitstream: ## Build and timing-check the Ubuntu bitstream
	$(NATIVE_BUILD) build

ubuntu-load: ## Program the Ubuntu bitstream
	$(NATIVE_BUILD) load

ubuntu-kernel: ## Build the Linux kernel and OpenSBI payload
	$(UBUNTU) kernel

ubuntu-rootfs: ## Create or update the Ubuntu root filesystem (uses sudo)
	$(SUDO) $(UBUNTU) rootfs

ubuntu-apps: ## Build and install static RV64 app/ suites into UBUNTU_ROOTFS
	$(UBUNTU) apps

ubuntu-bundle: ## Package the kernel, OpenSBI and DTB for Ubuntu
	$(UBUNTU) bundle

ubuntu-check: ## Verify the Ubuntu bundle against the board profile and rootfs
	$(UBUNTU) check

ubuntu-serve: ## Export the Ubuntu root filesystem over NFS (uses sudo -n)
	$(UBUNTU) serve

ubuntu-boot: ## Send the Ubuntu bundle over TFTP or UART, boot and attach console
	$(UBUNTU) boot $(UBUNTU_BOOT_OPTIONS) --console

ubuntu-unserve: ## Remove the Ubuntu NFS export
	$(UBUNTU) unserve

# ============================================================================
# Debian 13 Trixie (RV64GC, DDR, Ethernet, NFS / SquashFS / RAM rootfs)
# ============================================================================

debian-info: ## Print the Debian bitstream configuration and output directory
	$(NATIVE_BUILD) info

debian-bitstream: ## Build and timing-check the Debian bitstream
	$(NATIVE_BUILD) build

debian-load: ## Program the Debian bitstream
	$(NATIVE_BUILD) load

debian-kernel: ## Build or reuse the verified Linux kernel and OpenSBI payload
	$(DEBIAN) kernel

debian-rootfs: ## Create or update the Debian 13 root filesystem (uses sudo)
	$(SUDO) $(DEBIAN) rootfs

debian-apps: ## Build and install static RV64 app/ suites into DEBIAN_ROOTFS
	$(DEBIAN) apps

debian-bundle: ## Package the kernel, OpenSBI and DTB for Debian
	$(DEBIAN) bundle

debian-check: ## Verify the Debian bundle against the board profile and rootfs
	$(DEBIAN) check

debian-serve: ## Export the Debian root filesystem over NFS (uses sudo -n)
	$(DEBIAN) serve

debian-boot: ## Send the Debian bundle over TFTP or UART, boot and attach console
	$(DEBIAN) boot $(UBUNTU_BOOT_OPTIONS) --console

debian-unserve: ## Remove the Debian NFS export
	$(DEBIAN) unserve

# ============================================================================
# Alpine Linux 3.24 (RV64GC, musl + OpenRC, NFS / SquashFS / RAM rootfs)
# ============================================================================

alpine-info: ## Print the Alpine bitstream configuration and output directory
	$(NATIVE_BUILD) info

alpine-bitstream: ## Build and timing-check the Alpine bitstream
	$(NATIVE_BUILD) build

alpine-load: ## Program the Alpine bitstream
	$(NATIVE_BUILD) load

alpine-kernel: ## Build or reuse the verified Linux kernel and OpenSBI payload
	$(ALPINE) kernel

alpine-rootfs: ## Create or update the Alpine 3.24 root filesystem (uses sudo)
	$(SUDO) $(ALPINE) rootfs

alpine-apps: ## Build and install static RV64 app/ suites into ALPINE_ROOTFS
	$(ALPINE) apps

alpine-bundle: ## Package the kernel, OpenSBI and DTB for Alpine
	$(ALPINE) bundle

alpine-check: ## Verify the Alpine bundle against the board profile and rootfs
	$(ALPINE) check

alpine-serve: ## Export the Alpine root filesystem over NFS (uses sudo -n)
	$(ALPINE) serve

alpine-boot: ## Send the Alpine bundle over TFTP or UART, boot and attach console
	$(ALPINE) boot $(UBUNTU_BOOT_OPTIONS) --console

alpine-unserve: ## Remove the Alpine NFS export
	$(ALPINE) unserve

# ============================================================================
# Multi-Hart SMP Alpine Linux 3.24 (lightweight OpenRC + DDR4 SquashFS/RAM)
# ============================================================================

alpine-smp-info: ## Print the multi-hart Alpine SMP bitstream configuration
	$(NATIVE_BUILD) info

alpine-smp-bitstream: ## Build and timing-check the multi-hart Alpine SMP bitstream
	$(NATIVE_BUILD) build

alpine-smp-load: ## Program the multi-hart Alpine SMP bitstream
	$(NATIVE_BUILD) load

alpine-smp-kernel: ## Build or reuse the verified SMP Linux kernel and OpenSBI payload
	$(ALPINE_SMP) kernel

alpine-smp-rootfs: ## Create or update the shared Alpine 3.24 root filesystem (uses sudo)
	$(SUDO) $(ALPINE_SMP) rootfs

alpine-smp-apps: ## Build and install static RV64 app/ suites into ALPINE_ROOTFS
	$(ALPINE_SMP) apps

alpine-smp-bundle: ## Package the multi-hart Alpine SMP kernel, DTB, and DDR4 SquashFS/RAM initrd
	$(ALPINE_SMP) bundle

alpine-smp-check: ## Verify the multi-hart Alpine SMP bundle against the board profile
	$(ALPINE_SMP) check

alpine-smp-serve: ## Export ALPINE_ROOTFS over NFS when SMP_ROOT_DEVICE=nfs
	$(ALPINE_SMP) serve

alpine-smp-boot: ## Boot multi-hart Alpine Linux SMP over TFTP or UART and attach console
	$(ALPINE_SMP) boot $(UBUNTU_BOOT_OPTIONS) --console

alpine-smp-unserve: ## Remove the Alpine NFS export
	$(ALPINE_SMP) unserve

distro-test ubuntu-test: ## Run the shared board and Linux distribution host unit tests
	$(PYTHON) -m unittest discover -s $(COMMON_DIR)/tests -p 'test_*.py' -v

.PHONY: $(UBUNTU_BITSTREAM_TARGETS) $(UBUNTU_TARGETS) distro-test ubuntu-test
