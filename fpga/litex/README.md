# LiteX Support

[LiteX](https://github.com/enjoy-digital/litex)

The LiteX framework provides a convenient and efficient infrastructure to create FPGA Cores/SoCs, to explore various digital design architectures and create full FPGA based systems.

## Getting Started

```shell
# prepare envirement
./setup.sh
source ./venv/bin/activate
# or using conda: `conda activate base`

# run default
make run

# liftoff demo payload
pushd $YSYX_HOME/third_party/enjoy-digital/litex && \
  litex_bare_metal_demo --build-path=build/sim/ && popd
make liftoff

# coremark payload
make link
pushd $YSYX_HOME/third_party/enjoy-digital/litex && \
  python3 ./litex/soc/software/coremark_litex/coremark.py --build-path=build/sim/
make coremark
# add patch below at `CoreMark` to see mark result.
```

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
  PCIe, Video, etc...)      +       +
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
