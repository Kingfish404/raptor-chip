# Boot Linux Kernel

- Boot Linux: firmware (rom) -> openSBI -> Linux
- [RISC-V Open Source Supervisor Binary Interface](https://github.com/riscv-software-src/opensbi)
  - Tested: v1.6
- [The Linux Kernel Archives](https://www.kernel.org/)
  - Tested: 6.14.2, 6.15-rc2

## openSBI

```shell
git clone https://github.com/riscv-software-src/opensbi

make PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei_zicntr PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc`
# or build with Linux Image as payload
make PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei_zicntr PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc` FW_PAYLOAD_PATH=~/linux/linux-6.14.2/arch/riscv/boot/Image
# or build using llvm + clang
brew install llvm lld
make LLVM=1 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei_zicntr PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc`
```

Both `QEMU` and `Spike` device tree tables are supported and listed in `nemu/src/memory/rom`.

## Device Tree

```shell
cd $YSYX_HOME/nemu/src/memory/rom
dtc spike-rv32ima.dts -o spike-rv32ima.dtb
# or hack to Spike to dump Spike DTB
```

### Dump DTB from Spike

```patch
diff --git a/riscv/sim.cc b/riscv/sim.cc
index fd1c6fb1..63b8418c 100644
--- a/riscv/sim.cc
+++ b/riscv/sim.cc
@@ -398,6 +398,15 @@ void sim_t::set_rom()
   const int align = 0x1000;
   rom.resize((rom.size() + align - 1) / align * align);
 
+  FILE* dtb_file = NULL;
+  dtb_file = fopen("spike.dtb", "wb");
+  if (dtb_file) {
+    fwrite(dtb.c_str(), 1, dtb.size(), dtb_file);
+    fclose(dtb_file);
+  } else {
+    fprintf(stderr, "Failed to open dtb.dtb for writing\n");
+  }
+
   std::shared_ptr<rom_device_t> boot_rom(new rom_device_t(rom));
   add_device(DEFAULT_RSTVEC, boot_rom);
 }
```

## Linux Kernel Setting and Build

```shell
#!/bin/bash

make ARCH=riscv -j`nproc` defconfig
./scripts/config --enable CONFIG_NONPORTABLE
./scripts/config --disable CONFIG_ARCH_RV64I
./scripts/config --enable CONFIG_ARCH_RV32I
./scripts/config --disable CONFIG_EFI
./scripts/config --disable CONFIG_RISCV_ISA_C
./scripts/config --disable CONFIG_FPU
./scripts/config --disable CONFIG_RISCV_ISA_ZAWRS
./scripts/config --disable CONFIG_RISCV_ISA_ZBA
./scripts/config --disable CONFIG_RISCV_ISA_ZBB
./scripts/config --disable CONFIG_RISCV_ISA_ZBC
./scripts/config --disable CONFIG_RISCV_ISA_ZICBOM
./scripts/config --disable CONFIG_RISCV_ISA_ZICBOZ
./scripts/config --disable CONFIG_RISCV_ISA_ZICBOM

make ARCH=riscv -j`nproc` olddefconfig

make ARCH=riscv -j`nproc`
```

## make `initramfs`

```shell
mkdir initramfs && cd initramfs
mkdir --parents {bin,dev,etc,lib,lib64,mnt/root,proc,root/init-linux,sbin,sys,run}
sudo mknod dev/console c 5 1
sudo mknod dev/null c 1 3
sudo mknod dev/sda b 8 0
cd ..
(cd initramfs && find . | cpio -o --format=newc | gzip > ../initramfs.cpio.gz)
```

### `init` at `initramfs/root/init-linux`

```c
int main() {
  for (;;) {
  }
}
```

```makefile
CFLAGS=-march=rv32ima_zicsr_zifencei_zicntr -mabi=ilp32 -nostdlib

init:
	riscv64-linux-gnu-gcc $(CFLAGS) -static -o init init.c $(LDFLAG)

install: init
	mv init ../../
```

## Run at `nemu`

```shell
make run IMG=../riscv-software-src/build/linux-mmu/fw_payload.bin

# or batch mode
make run IMG=../riscv-software-src/build/linux-mmu/fw_payload.bin ARGS="-b --log=build/nemu-log.txt"
```

## References

- [Build mini linux for your own RISC-V emulator!](https://github.com/CmdBlockZQG/rvcore-mini-linux)
- [给NEMU移植Linux Kernel!](https://github.com/Seeker0472/ysyx-linux)
