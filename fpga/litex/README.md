# LiteX Support

[LiteX](https://github.com/enjoy-digital/litex)

The LiteX framework provides a convenient and efficient infrastructure to create FPGA Cores/SoCs, to explore various digital design architectures and create full FPGA based systems.

## Getting Started

```shell
# prepare envirement
./setup.sh
source ./venv/bin/activate

# run default
make run

# liftoff demo payload
pushd $YSYX_HOME/third_party/enjoy-digital/litex && \
  litex_bare_metal_demo --build-path=build/sim/ && popd
make liftoff
```

## LiteX

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
 (Eth, SATA, DRAM, USB,     |       |
  PCIe, Video, etc...)      +       +
                           board   target
                           file    file
```
