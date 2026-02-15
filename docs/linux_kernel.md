# Boot Linux Kernel (NEMU)

- Boot Linux: firmware (rom) -> openSBI -> Linux
- [RISC-V Open Source Supervisor Binary Interface](https://github.com/riscv-software-src/opensbi)
  - Tested: v1.6
- [The Linux Kernel Archives](https://www.kernel.org/)
  - Tested: 6.14.2, 6.15-rc2

## openSBI

```shell
git clone https://github.com/riscv-software-src/opensbi

make PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc`
# or build with Linux Image as payload
make PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc` FW_PAYLOAD_PATH=~/linux/linux-6.14.2/arch/riscv/boot/Image

# or build using llvm + clang
brew install llvm lld
make LLVM=1 PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc`
# with Linux Image as payload
make LLVM=1 PLATFORM_RISCV_ISA=rv32imac_zicntr_zicsr_zifencei PLATFORM_RISCV_XLEN=32 PLATFORM=generic -j`nproc` FW_PAYLOAD_PATH=~/linux/linux-6.14.2/arch/riscv/boot/Image
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

Get the Linux Kernel source code from [The Linux Kernel Archives](https://www.kernel.org/):

```shell
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.15.6.tar.xz

tar -xf linux-6.15.6.tar.xz
cd linux-6.15.6
```

See more details in [linux/README.md](../linux/README.md).

## Run at `nemu`

```shell
make riscv32_linux_defconfig

make run IMG=../third_party/riscv-software-src/opensbi/build/platform/generic/firmware/fw_payload.bin

# or batch mode
make run IMG=../third_party/riscv-software-src/opensbi/build/platform/generic/firmware/fw_payload.bin ARGS="-b --log=build/nemu-log.txt"
```

## References

- [Build mini linux for your own RISC-V emulator!](https://github.com/CmdBlockZQG/rvcore-mini-linux)
- [给NEMU移植Linux Kernel!](https://github.com/Seeker0472/ysyx-linux)
