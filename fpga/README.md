# FPGA support

- [Native MLK-CU08-KU15P](mlk-cu08-ku15p/README.md): SystemVerilog board top,
  XDC constraints, UART boot ROM and batch Vivado builds. Supports RV32/RV64,
  BRAM bring-up and a vendor DDR4 MIG path without LiteX or Migen.
- [Native RK-XCKU5P-F V1.2](rk-xcku5p-f/README.md): XCKU5P standalone
  RV32/RV64 builds, 200 MHz reference, BRAM or 32-bit DDR4, UART boot and fan.
- [LiteX integration](litex/README.md): generated SoCs with the existing SD,
  Ethernet and BIOS integrations.
- [Out-of-context analysis](ooc/README.md): module/composition synthesis flows.

`common/` contains native platform RTL, firmware, UART tools and the shared RTL
exporter. Both native and LiteX builds consume the same CPU sources and preset
definitions. Native board addresses come from `hdl/configs/memory_map.json`.

The Tang Nano 20K directory is retained as an archived example. It is no longer
an active board target. Root `make fpga-syn` and `make fpga-pnr` use CU08-KU15P;
select RK with `FPGA_BOARD=rk-xcku5p-f`. Select a preset explicitly, for example
`RAPT_CONFIG=small`, and memory with `MEMORY=bram|ddr`.
