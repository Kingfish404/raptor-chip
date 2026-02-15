PWD_DIR=$(abspath .)
KERNEL_VERSION:=6.17.7

all:
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

linux:
	wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
	tar -xf linux-$(KERNEL_VERSION).tar.xz
	mv linux-$(KERNEL_VERSION) linux
	rm linux-$(KERNEL_VERSION).tar.xz

build_linux: linux
	make -C linux ARCH=riscv -j`nproc` defconfig

	cd linux && \
		./scripts/config --enable CONFIG_NONPORTABLE && \
		./scripts/config --disable CONFIG_ARCH_RV64I && \
		./scripts/config --enable CONFIG_ARCH_RV32I && \
		./scripts/config --disable CONFIG_FPU && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZAWRS && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZBA && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZBB && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZBC && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOM && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOZ && \
		./scripts/config --disable CONFIG_RISCV_ISA_ZICBOM

	make -C linux ARCH=riscv -j`nproc` olddefconfig

	make -C linux ARCH=riscv -j`nproc`

make_initramfs:
	mkdir initramfs && \
		cd initramfs && \
 		mkdir --parents {bin,dev,etc,lib,lib64,mnt/root,proc,root/init-linux,sbin,sys,run} && \
		mkdir dev && \
		sudo mknod dev/console c 5 1 && \
		sudo mknod dev/null c 1 3 && \
		sudo mknod dev/sda b 8 0
	(cd initramfs && find . | cpio -o --format=newc | gzip > ../initramfs.cpio.gz)

build_init:
	make -C payload init_loop install

install_initramfs:
# -> General setup -> Initial RAM filesystem and RAM disk (initramfs/initrd) support
# -> [*] Initramfs source file(s) -> [PATH of initramfs] (e.g. `/home/[username]/initramfs`)
	cd linux && ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE $(PWD_DIR)/initramfs
	make -C linux ARCH=riscv -j`nproc` olddefconfig

opensbi:
	git clone https://github.com/riscv-software-src/opensbi

build_opensbi: opensbi
	make -C opensbi PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei \
		CROSS_COMPILE=riscv64-linux-gnu- PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc`

build_opensbi_with_kernel: opensbi
	make -C opensbi PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei \
		CROSS_COMPILE=riscv64-linux-gnu- PLATFORM_RISCV_XLEN=32 PLATFORM=generic \
		FW_PAYLOAD_PATH=$(PWD_DIR)/linux/arch/riscv/boot/Image -j`nproc`

clean:
	rm -rf linux initramfs initramfs.cpio.gz opensbi payload/build
