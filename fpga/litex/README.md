# LiteX Support

[LiteX](https://github.com/enjoy-digital/litex)

The LiteX framework provides a convenient and efficient infrastructure to create FPGA Cores/SoCs, to explore various digital design architectures and create full FPGA based systems.

## CPU Variants

| Variant    | Description                                    | Use Case               |
| ---------- | ---------------------------------------------- | ---------------------- |
| `standard` | Dual-issue OoO, default caches, Sv32 MMU       | BIOS, bare-metal apps  |
| `linux`    | Same RTL + OpenSBI region + DTS cache metadata | Linux boot via OpenSBI |

## Getting Started

```shell
# Prepare environment
./setup.sh
source .venv/bin/activate
# or using conda: `conda activate base`

# Run default BIOS simulation (standard variant)
make run

# Liftoff demo payload
pushd $YSYX_HOME/third_party/enjoy-digital/litex && \
  litex_bare_metal_demo --build-path=build/sim/ && popd
make liftoff

# CoreMark payload
make link
pushd $YSYX_HOME/third_party/enjoy-digital/litex && \
  python3 ./litex/soc/software/coremark_litex/coremark.py --build-path=build/sim/
make coremark
# Add patch below at `CoreMark` to see mark result.
```

## Linux Boot (Verilator Simulation)

The `linux` variant sets up the SoC for OpenSBI + Linux boot:

```shell
# 1. Build SoC and generate device tree (no gateware compile)
make linux_build
make linux_dts

# 2. Build OpenSBI (FW_PAYLOAD) with the generated DTS.
#    See docs/linux_kernel.md for cross-compilation instructions.
#    Place the resulting `Image` file in the LiteX directory.

# 3. Run Linux simulation
make linux_sim        # interactive (with UART console)
make linux_sim_ni     # non-interactive
```

### Boot Flow

```
LiteX BIOS (ROM) → loads Image to main_ram → boot_helper
  → OpenSBI (M-mode, FW_PAYLOAD at main_ram+0x00f00000)
    → Linux kernel (S-mode)
```

### Device Tree

`make linux_dts` generates the DTS from the SoC's CSR JSON. The generated
DTS includes cache parameters (L1I/L1D size, ways, block size) and the
standard CLINT/PLIC memory regions required by OpenSBI and Linux.

## [LiteX](https://github.com/enjoy-digital/litex)

```
                        +---------------+
                        |FPGA toolchains|
                        +----^-----+----+
                             |     |
         +-------+        +--+-----v--+
         | Migen +-------->           |        Your design
         +-------+        |   LiteX   +---> ready to be used!
+----------------------+  |           |
|LiteX Cores Ecosystem +-->           |
+----------------------+  +-^-------^-+
 (Eth, SATA, DRAM, US B,     |       |
  PCIe, Video, etc...)       +       +
                            board   target
                            file    file
```

## [CoreMark](https://github.com/eembc/coremark)

`enjoy-digital/pythondata-software-picolibc/pythondata_software_picolibc/data/newlib/libc/tinystdio/vfiprintf.c`

```patch
diff --git a/newlib/libc/tinystdio/vfiprintf.c b/newlib/libc/tinystdio/vfiprintf.c
index abbd68b82..f0782f030 100644
--- a/newlib/libc/tinystdio/vfiprintf.c
+++ b/newlib/libc/tinystdio/vfiprintf.c
@@ -30,7 +30,7 @@
 
 */
 
-#define PRINTF_LEVEL PRINTF_STD
+#define PRINTF_LEVEL PRINTF_FLT
 #ifndef FORMAT_DEFAULT_INTEGER
 #define vfprintf __i_vfprintf
 #endif
```
