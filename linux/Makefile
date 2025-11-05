USERNAME=$(shell whoami)
PWD_DIR=$(abspath .)
KERNEL_VERSION:=6.17.7

all:
	echo "PWD: $(PWD_DIR)"

get_linux:
	wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
	tar -xvf linux-$(KERNEL_VERSION).tar.xz
	mv linux-$(KERNEL_VERSION) linux
	rm linux-$(KERNEL_VERSION).tar.xz

build_linux:
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

build_opensbi:
	make PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei CROSS_COMPILE=riscv64-linux-gnu- PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc`

make_initramfs:
	mkdir initramfs && \
		cd initramfs && \
		mkdir --parents {bin,dev,etc,lib,lib64,mnt/root,proc,root/init-linux,sbin,sys,run} && \
		sudo mknod dev/console c 5 1 && \
		sudo mknod dev/null c 1 3 && \
		sudo mknod dev/sda b 8 0
	(cd initramfs && find . | cpio -o --format=newc | gzip > ../initramfs.cpio.gz)

# set initramfs at Kernel config
	make ARCH=riscv menuconfig
# -> General setup -> Initial RAM filesystem and RAM disk (initramfs/initrd) support
# -> [*] Initramfs source file(s) -> [PATH of initramfs] (e.g. `/home/[username]/initramfs`)
	./scripts/config --enable CONFIG_INITRAMFS_SOURCE="$(PWD_DIR)/initramfs"
