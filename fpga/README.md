# FPGA support

- [Native MLK-CU08-KU15P](mlk-cu08-ku15p/README.md): SystemVerilog board top,
  XDC constraints, UART boot ROM and batch Vivado builds. Supports RV32/RV64,
  optional BRAM bring-up, a vendor DDR4 MIG path, and default independent CM005
  A↔B forwarding alongside the CPU and UART.
- [Native RK-XCKU5P-F V1.2](rk-xcku5p-f/README.md): XCKU5P standalone
  RV32/RV64 builds, 200 MHz reference, 32-bit DDR4 by default, UART boot and fan.
- [LiteX integration](litex/README.md): generated SoCs with the existing SD,
  Ethernet and BIOS integrations, including CU08 CM005 and RK onboard Ethernet
  netboot profiles.
- [Out-of-context analysis](ooc/README.md): module/composition synthesis flows.

`common/` contains native platform RTL, firmware, UART tools and the shared RTL
exporter. Both native and LiteX builds consume the same CPU sources and preset
definitions. Native board addresses come from `rtl/configs/memory_map.json`.

Each native board directory is a standalone build that does not run the
`fpga/litex` Makefile; only CU08's CM005 bridge is generated from its Migen and
LiteEth code. Run `make -C fpga/<board> help` for targets and variables, for
example `make -C fpga/rk-xcku5p-f build XLEN=32 MEMORY=bram`. From the
repository root, `make fpga-<target> FPGA_BOARD=<board>` runs the same target
(CU08 by default) and keeps the board's preset unless `RAPT_CONFIG` is given.
Both boards default to RV64, preset `small`, DDR4 and 50 MHz; CU08 also
defaults to `CM005_BRIDGE=1`, which requires 50 MHz. In `fpga/litex`,
`fpga-netboot-rv32-build` and `fpga-netboot-rv64-build` select the CU08 LiteX
netboot profile by default; pass `FPGA_BOARD=rk_xcku5p_f` for RK.

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
resources when available, and timing status. Use `make -C fpga/<board> info` with the
same board and configuration to find the output directory. LiteX Vivado builds
place the same two files in `soc/gateware/`; the matching
`fpga-netboot-rv64-reports` target regenerates them without rebuilding the
bitstream. To summarize an older Vivado report directory, run:

```sh
python3 fpga/common/scripts/vivado_reports_index.py PATH_TO_REPORT_DIRECTORY
```

The summaries label synthesis, placement, and routing separately. A missing
native `result.json` or LiteX bitstream stamp means the displayed reports are
not a validated loadable build.
