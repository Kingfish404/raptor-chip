# FPGA support

- [Native MLK-CU08-KU15P](mlk-cu08-ku15p/README.md): SystemVerilog board top,
  XDC constraints, UART boot ROM and batch Vivado builds. Supports RV32/RV64,
  optional BRAM bring-up, a vendor DDR4 MIG path, and default independent CM005
  A↔B forwarding alongside the CPU and UART. Its LiteX profile supports CM005
  Ethernet netboot.
- [Native RK-XCKU5P-F V1.2](rk-xcku5p-f/README.md): XCKU5P standalone
  RV32/RV64 builds, 200 MHz reference, 32-bit DDR4 by default, UART boot and fan.
  Its LiteX profile adds onboard RGMII Ethernet netboot with 2 GiB DDR4.
- [LiteX integration](litex/README.md): generated SoCs with the existing SD,
  Ethernet and BIOS integrations.
- [Out-of-context analysis](ooc/README.md): module/composition synthesis flows.

`common/` contains native platform RTL, firmware, UART tools and the shared RTL
exporter. Both native and LiteX builds consume the same CPU sources and preset
definitions. Native board addresses come from `hdl/configs/memory_map.json`.

The Tang Nano 20K directory is an archived example outside active board support.
Root `make fpga-rv32-build` and `make fpga-rv64-build` select CU08-KU15P by
default; use `FPGA_BOARD=rk-xcku5p-f` for RK. The root defaults to preset
`default`; pass `RAPT_CONFIG=small` for a smaller build. RK defaults to DDR4,
and CU08 native builds default to DDR with `CM005_BRIDGE=1` at 50 MHz.
Set `MEMORY=bram|ddr` to choose memory; use `CM005_BRIDGE=0` for a CU08 build
without the forwarder or when selecting another CPU clock.
`fpga-netboot-rv32-build` and `fpga-netboot-rv64-build` select the CU08 LiteX
netboot profile by default. Pass `FPGA_BOARD=rk-xcku5p-f` for the RK LiteX
profile with onboard Ethernet; RK also provides the same targets in its board
directory.

## Build reports

Run synthesis and evaluation on a host with the required Vivado installation.
Verify the intended source revision, generated decoders, and dependencies before
each run; use separate output directories per configuration. Keep large
checkpoints on the build host and archive reports, logs, and input manifests
outside the source tree. Record the exact preset, XLEN, memory, clock constraints,
tool version, source fingerprint, and build stage. A synthesis report alone
does not establish routed timing closure or hardware operation.

Native KU15P/KU5P `synth` and `build` outputs contain `index.html` with the
Vivado reports and `README.md` with synthesis resources, implementation
resources when available, and timing status. Use `make fpga-rv64-info` with the
same board and configuration to find the output directory. LiteX Vivado builds
place the same two files in `soc/gateware/`; the matching
`fpga-netboot-rv64-reports` target regenerates them without rebuilding the
bitstream. To summarize an older Vivado report directory, run:

```sh
python3 fpga/litex/scripts/vivado_reports_index.py PATH_TO_REPORT_DIRECTORY
```

The summaries label synthesis, placement, and routing separately. A missing
native `result.json` or LiteX bitstream stamp means the displayed reports are
not a validated loadable build.
