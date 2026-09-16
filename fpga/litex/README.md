# Raptor LiteX SoC Integration

LiteX SoC integration for the [Raptor](../../) dual-issue out-of-order RISC-V core.

## Quick Start

```bash
# 1. Install LiteX environment
make setup
# 2. Pack RTL
make pack
# 3. Run Verilator simulation (BIOS serial)
make sim
# 4. Run CoreMark benchmark
make coremark
```

`SIM_JOBS` limits concurrent C++ compilations (default: up to 4); use `make sim-build ROM=bios SIM_JOBS=2` on memory-limited CI runners. `SIM_THREADS` controls runtime simulation threads independently. Always pass a positive build limit: LiteX's omitted job count otherwise produces unlimited `make -j`. `SIM_TIMEOUT` applies to simulation execution, not compilation.

FPGA packs enable integer-multiply DSP inference with `RAPT_FPGA_DSP=1`. To compare fabric mapping, pass `RAPT_PACK_VFLAGS=-DRAPT_FPGA_DSP=0`; the override is included in the build identity. The arithmetic and valid/tag pipeline have the same latency in both modes. Generic simulator/ASIC builds default to fabric inference unless the define is supplied.

For separate frontend/backend/cache synthesis and checkpoint linking, see [the coarse OOC flow](../ooc/README.md). It exports fixed-preset vector interfaces and checks checkpoint freshness. Full board synthesis, placement and routing remain necessary to assess the final SoC.

## Tang Mega 138K Pro Hardware Flow

```bash
# Install LiteX environment
make setup
# Build the real-FPGA bitstream
make fpga-build
# Load it to the connected board over USB
make fpga-load
# Open the UART console
make fpga-console
```

## FPGA Auto-Detection

For FPGA targets, the Makefile asks Vivado Hardware Manager for attached Xilinx device parts and maps a recognized part to `FPGA_BOARD`. An attached `xcau15p` selects `alinx_axau15`; an attached `xcvu9p` selects `xilinx_vcu118`. The `xcku15p` part is shared by `mlk_cu08_ku15p` and `mlk_cu07_ku15p`, so builds require an explicit board selection to avoid programming the wrong pinout. An explicit `FPGA_BOARD=...` always wins. If no supported Xilinx device is found, the existing profile default is used. Set `FPGA_AUTO_DETECT=0` to skip probing, and run `make fpga-info` to refresh and inspect the connected FPGA count and target details. Detection is cached in `build/.fpga_detect_parts` and related `.fpga_detect_*` files, so later commands do not restart Vivado. Use `FPGA_DETECT_REFRESH=1` on any FPGA command when the connected board has changed. Commands that only use the already-loaded image, such as `make fpga-console` and `make fpga-upload`, do not require `FPGA_BOARD`; set `UART_PORT` when automatic UART selection is ambiguous. Build, load, flash, and timing-gate commands still require an explicit board when multiple boards share the same FPGA part.

Vivado load and flash scripts require exactly one JTAG device matching the board's registered part. They never fall back to the first device in the chain, so a KU15P bitstream cannot accidentally be assigned to an AU15P.

`fpga-load` warns when the saved bitstream input hash differs from the current inputs or its stamp is missing, then continues loading the existing bitstream. Missing bitstream files and failed timing checks still stop loading. `fpga-flash` requires a matching input hash.

## CM005 Ethernet on CU07/CU08

For **LiteX BIOS TFTP network boot** (without replacing the SD card), see [netboot preparation](NETBOOT.md). Its standalone `netboot.mk` checks/packages finished firmware without parsing the FPGA Makefile or touching the board; TFTP service activation and board acceptance remain separate steps.

For the opt-in CU08 RV64 Buildroot + DHCP + SD automatic-boot profile, see [RV64 network preparation](RV64-NETWORK.md). Its read-only preflight does not start a build or touch the board; existing RV32 defaults are unchanged.

For the opt-in RV32 gigabit profile, run `scripts/rv32_network.py check` with the LiteX venv Python, then `scripts/rv32_network.py build`. It uses CU08 FMC_C/ETHA, default/50 MHz, MIG, SD autoboot and a validated RV32 Buildroot package in the separate `build/rv32-network` directory. See [FMC_C integration guide](CM005-FMC-C.md); preflight success is not routed timing or board validation. Neither named profile changes generic defaults.

CU08 defaults to the short-edge **FMC_C/ETHA** connector; CU07 defaults to FMCA/ETHA. Both require 1.8 V I/O power (check the CU08 adjustable-bank supply before use). The CU08 C mapping is checked against baseboard schematic sheet 7: ETHA RX clock lands on L19, a non-global-clock input. The receiver samples RX_CLK, RXD and RX_CTL as data using six ISERDESE3 lanes at 1.25 GS/s (625 MHz DDR, 156.25 MHz word processing). It does not route L19 as an FPGA clock or use `CLOCK_DEDICATED_ROUTE FALSE`. RX_CLK has a calibrated 460 ps extra input delay; the decoder selects the preceding data sample and recovers RX_ER. Sampling-clock root and delay-group constraints select the buffer output pins; the original divided-clock net name can disappear during synthesis. The first-stage inputs are asynchronous: routed path budgets and a separate `cm005_aperture.rpt` sampling-window gate replace the direct-clock RX checks. Core/TX timing checks remain enabled. Fresh full-SoC STA and board traffic validation are still required; peripheral tests do not establish either. See [FMC_C integration and validation](CM005-FMC-C.md) for the sampling bounds and required board-level checks. The old FMCA/ETHA mapping remains selectable with `FMC_SLOT=a`. Ethernet defaults to fixed **1000 Mb/s full duplex**, with a 125 MHz RGMII clock:

```bash
make fpga-build FPGA_BOARD=mlk_cu08_ku15p VARIANT=linux32 \
    WITH_ETHERNET=1 ETH_SPEED=1000 FMC_SLOT=c ETH_PORT=a
make fpga-load FPGA_BOARD=mlk_cu08_ku15p VARIANT=linux32 \
    WITH_ETHERNET=1 ETH_SPEED=1000 FMC_SLOT=c ETH_PORT=a
```

### CU08 RV32/RV64 netboot build and load

#### Recommended: fixed current board-validation profile

For the full default configuration, use these paired targets from `fpga/litex`:

```sh
make fpga-netboot-rv32-build
make fpga-netboot-rv32-load

# Alternative: replaces RV32 in FPGA SRAM, not in flash.
make fpga-netboot-rv64-build
make fpga-netboot-rv64-load
```

Run load only after a successful build and when the board is available. This profile fixes CU08 and 50 MHz, defaults to `RAPT_CONFIG=default`, and supports other presets through e.g. `RAPT_CONFIG=small`. It uses MIG DDR, SD autoboot, CM005 FMC_C/ETHA gigabit, full Linux initialization, Vivado 8 threads and Explore routing. DTB offset/address are `0x04000000`/`0x83f00000`. Both targets use the same parameters; load requires the matching build stamp and an existing, passing timing report. It does not rebuild or program flash.

Outputs and workflow locks are isolated by preset and XLEN at `build/netboot-<RAPT_CONFIG>/rv32/{build,soc,netboot}` and `build/netboot-<RAPT_CONFIG>/rv64/{build,soc,netboot}`; they do not reuse the earlier compact temporary candidates. Use `make fpga-netboot-rv32-info` (or `rv64-info`) to see resolved paths. Do **not** substitute bare `make fpga-load` for the paired target.

The default payloads are downloaded by the paired `build` target when absent: `linux/build/linux-riscv-rv32-qemu-rv32-buildroot-v6.18.50/fw_payload.bin` and `linux/build/linux-riscv-rv64-qemu-rv64-fast-buildroot-v6.18.50/fw_payload.bin`. Repeat `RAPT_CONFIG` for build/load/test steps. Host setup/restore shares `NETBOOT_STATE_ROOT` (default `build/netboot-default`) across presets. Supported location/tool overrides are `NETBOOT_BUILD_ROOT`, `NETBOOT_STATE_ROOT`, `NETBOOT_PAYLOAD_RV32`, `NETBOOT_PAYLOAD_RV64`, `VIVADO`, `VIVADO_JOBS`, and `CROSS`; use absolute paths for custom build/payload locations and repeat them for all workflow steps, or put them in ignored `netboot.local.mk`. Custom build outputs use `<NETBOOT_BUILD_ROOT>/<RAPT_CONFIG>/rvXX/`; older custom-root builds need rebuilding in this layout. Conflicting fixed board/variant/hardware overrides fail explicitly. Use the manual flow below for a different hardware configuration. Do not mix fixed-profile and ordinary targets in the same Make invocation. For the complete flow, including explicit host setup, namespaced TFTP deployment, manual BIOS netboot, Linux startup and network checks, see [NETBOOT.md](NETBOOT.md#fixed-cu08-end-to-end-targets). In short, after build use `make fpga-netboot-host-setup`, `make fpga-netboot-rv64-serve`, `make fpga-netboot-rv64-load` and `make fpga-netboot-rv64-console`; manually enter the namespaced `netboot` command printed by `serve` at `litex>`. After Linux starts, close the console and use `make fpga-netboot-rv64-test` (substitute `rv32` throughout as needed). Restore recorded host changes with `make fpga-netboot-host-restore` when finished. Never boot an RV32 SD payload on RV64.

#### Manual configurable flow

Ethernet itself is **opt-in**: `WITH_ETHERNET=0` is the default, even with `VARIANT=linux32` or `linux64`. The 1000 Mb/s default above applies only when Ethernet is enabled. BIOS registers `netboot` only when its generated CSR header defines `CSR_ETHMAC_BASE`. A BIOS without that command cannot be repaired by connecting a cable or starting a TFTP server.

Run the following in one Bash or Zsh session, starting at the repository root. Complete `make setup` once and put Vivado on `PATH` first. Reserve the board before loading it; do not run this against another session's active build or board test. These commands use the CU08 FMC_C / ETHA connection, 50 MHz CPU, MIG DDR, SD support and the `default` RTL preset; they do not write flash or SD.

```sh
cd fpga/litex

# Keep all build-identifying arguments identical for every operation.
cu08_net() {
    make FPGA_BOARD=mlk_cu08_ku15p FPGA_AUTO_DETECT=0 \
        VARIANT="$fpga_variant" RAPT_CONFIG=default BOOT_MODE=bios \
        SYS_CLK=50000000 WITH_MIG=1 WITH_LITEDRAM=0 WITH_SDCARD=1 \
        WITH_ETHERNET=1 ETH_SPEED=1000 FMC_SLOT=c ETH_PORT=a "$@"
}

# RV32: build, inspect the printed paths, check freshness/timing, then load.
fpga_variant=linux32
cu08_net fpga-build && cu08_net info && \
    cu08_net fpga-bitstream-current && cu08_net fpga-timing-ok && \
    cu08_net fpga-load

# RV64 alternative: run when ready to replace the RV32 image on the board.
# fpga_variant=linux64
# cu08_net fpga-build && cu08_net info && \
#     cu08_net fpga-bitstream-current && cu08_net fpga-timing-ok && \
#     cu08_net fpga-load
```

Do not continue if the build fails, freshness differs, or timing is unverified. Require an existing matching timing report that explicitly meets constraints; `fpga-timing-ok` currently warns and returns success when its report is missing. The helper only holds command arguments in your shell; in a new terminal, define it and select `fpga_variant` again. If you change a preset, clock, `RAPT_PACK_VFLAGS`, `EXTRA_FLAGS`, route directive or other build setting, keep that change identical throughout build/check/load. Do not replace the final command with bare `make fpga-load`: it can select a different configuration's existing image. Enabling Ethernet only at load time cannot change an old image.

#### Custom build directories or an existing bitstream

By default, `info` prints a configuration-specific `FPGA_DIR` and bitstream path. For a custom directory, pass the **same absolute paths on every command**. For example, using the helper above and new, unused directories:

```sh
fpga_variant=linux32
fpga_work_dir=/absolute/path/to/new-rv32-build
fpga_soc_dir=/absolute/path/to/new-rv32-soc
cu08_custom() {
    cu08_net BUILD_DIR="$fpga_work_dir" FPGA_DIR="$fpga_soc_dir" "$@"
}
cu08_custom fpga-build && cu08_custom info && \
    cu08_custom fpga-bitstream-current && cu08_custom fpga-timing-ok && \
    cu08_custom fpga-load
```

Replace both example paths before running. To reuse an existing build, use its recorded configuration and directories instead; do not guess them from XLEN alone. A bare `FPGA_BITSTREAM=/path/to/file.bit` override selects a file but does not automatically select its matching build stamp or timing report. Prefer the matching `FPGA_DIR` and full configuration. Loading is SRAM-only: after power cycling, an older flash image may return.

#### Confirm BIOS support, then prepare TFTP

Open the UART console (`make fpga-console UART_PORT=/dev/serial/by-id/<your-UART>`; replace the device path). Interrupt automatic boot if enabled and run:

```text
litex> help
```

Expect `netboot` with the description `Boot via Ethernet (TFTP)`. If absent:

1. Check the exact build/load commands for `WITH_ETHERNET=1` and identical board, variant, preset and directory settings. Read any stale-bitstream warning.
2. Inspect `<FPGA_DIR>/software/include/generated/csr.h` for `#define CSR_ETHMAC_BASE`. If absent, that generated SoC has no Ethernet MAC exposed to BIOS. Rebuild with Ethernet enabled; regenerating BIOS alone does not update the ROM in the existing `.bit`.
3. If the macro exists but the running BIOS lacks `netboot`, verify that you loaded the matching new `.bit`, not an older/default-directory image or the flash image restored by a power cycle. Keep the build and UART logs.

Once the command exists, follow [NETBOOT.md](NETBOOT.md) to prepare and verify matching RV32/RV64 firmware, configure the board-facing host/TFTP service, and run the exact namespaced `netboot` command printed by `serve`. BIOS IPs are separate from Linux DHCP. Do not stop an existing TFTP service or change a shared host interface without coordinating its use. Successful TFTP transfer is not Linux network acceptance: verify Linux reaches its shell, obtains the intended IP, and passes actual bidirectional traffic tests. Gateware build success alone proves neither boot nor networking.

### CM005 PHY behavior and validation scope

After every PHY reset, gateware waits 10 ms and advertises only 1000BASE-T full duplex without pause, and restarts auto-negotiation. The link partner must support auto-negotiation. Software MDIO access becomes available after these initialization writes; the existing CSR offsets are unchanged. The reset gate is shared by ETHA/ETHB, so either reset also affects ETHB.

CU08 FMC_C/ETHA uses the oversampled gigabit receiver and serialized transmitter. Routed timing and reliable board traffic remain separate acceptance requirements; selecting gigabit does not establish either. Explicit `ETH_SPEED=100` is retained for legacy peripheral tests and requires a 100 Mb/s-capable link partner; it is not the current board-validation route. The 100M gateware and Linux firmware outputs have a separate `-100m` suffix. Loading remains subject to the normal timing gate; functional tests alone do not establish routed timing or a link.

## ALINX AXAU15 Hardware Flow (Xilinx Vivado)

The AXAU15 (`xcau15p-ffvb676-2-i`) supports both `VARIANT=linux32` and `VARIANT=linux64`. With the board attached, the common commands need no board override; `linux32` is the default:

```bash
make fpga-build
make fpga-load
make fpga-console
```

The default AXAU15 Linux profile uses the `small` Raptor configuration, the on-board 1 GiB x16 DDR4 through Xilinx MIG, and the 4-bit SDCard controller/DMA. The MIG parameters and pinout are based on the same-board `xilinx-xcau15p-pcie-gen4` Vivado project and the AXAU15 manual. The physical 200 MHz differential input is buffered once and shared by the SoC CRG and MIG.

```bash
make fpga-build FPGA_BOARD=alinx_axau15 VARIANT=linux32
```

This design maps the full 1 GiB device at `0x80000000`. It passes Vivado DRC, timing, pulse-width, and MIG bus-skew checks. The installed memory is `MT40A512M16LY-062EIT`; the reference project uses Vivado's compatible `MT40A512M16HA-083E` timing model at 2400 MT/s, CL16/CWL12, with a 128-bit AXI reference interface. The LiteX integration uses a native 32-bit AXI interface to match the SoC bus without narrow transfers. On the current AXAU15, all MIG calibration stages pass with no error, the LiteX BIOS 2 MiB write/read memtest passes, and sequential throughput is approximately 20.0 MiB/s write and 14.6 MiB/s read. Full Linux boot from SD remains to be validated.

Configuration flash is not implemented for AXAU15, so `make fpga-flash FPGA_BOARD=alinx_axau15` is deliberately refused.

## Xilinx VCU118 Hardware Flow (Preliminary)

The VCU118 (`xcvu9p-flga2104-2-e`) target reuses the maintained LiteX-Boards platform definition, including the 125 MHz differential clock, on-board USB-UART, eight user LEDs, and DDR4 channel C1. Basic builds use an integrated 512 KiB main RAM at 75 MHz. The default Linux profile also uses 512 KiB of integrated main RAM, with the `small` Raptor configuration and a 62.5 MHz system clock. DDR4 is disabled by default until the LiteDRAM PHY timing constraints have been resolved.

```bash
# UART/integrated-memory bring-up bitstream.
make fpga-build FPGA_BOARD=xilinx_vcu118 BOOT_MODE=bios
make fpga-load FPGA_BOARD=xilinx_vcu118 BOOT_MODE=bios
make fpga-console FPGA_BOARD=xilinx_vcu118 UART_PORT=/dev/ttyUSB0

# Default Linux-oriented build without external DDR4.
make fpga-build FPGA_BOARD=xilinx_vcu118 VARIANT=linux32

# Experimental external DDR4 build.
make fpga-build FPGA_BOARD=xilinx_vcu118 VARIANT=linux32 \
    WITH_LITEDRAM=1 INTEGRATED_MAIN_RAM_SIZE=0
```

VCU118 support is currently implementation-validated: LiteX completes SoC finalization and Vivado emits a bitstream. The experimental LiteDRAM build maps a 1 GiB main RAM window at `0x80000000`; its PHY derives a 250 MHz 4x clock and 500 MHz IDELAY reference from the 125 MHz input. Raptor `sys_clk` setup passes at 62.5 MHz, but the upstream LiteDRAM PHY still reports marginal OSERDES `CLK`/`CLKDIV` Max Skew checks. External DDR4 training, UART operation, and Linux boot therefore still require validation on a physical board. The LiteX platform does not define an SDCard resource, so `WITH_SDCARD=1` is rejected. This target intentionally retains LiteDRAM only as an explicit experiment rather than introducing an unverified board-specific MIG. Persistent configuration flash is also disabled until the board flow is validated.

The VCU118 requires the optional Virtex UltraScale+ device files. A Vivado installation that only contains Artix/Kintex device data reports `No parts matched 'xcvu9p-flga2104-2-e'`. Re-run the matching AMD installer in maintenance mode, choose **Add Design Tools or Devices**, and install **Virtex UltraScale+**. For the default per-user installation, the maintenance launcher is typically:

```bash
$HOME/Vivado/.xinstall/2025.2/xsetup
```

`fpga-build` checks the exact part before starting LiteX synthesis and prints this guidance when the device package is absent. After installation, rerun the same build command; no source or part-name override is required.

## MLK-CU08-KU15P Hardware Flow (Xilinx Vivado)

MiLianKe MLK-CU08-KU15P (Kintex UltraScale+ `xcku15p-ffva1156-2-e`). The board has a 100 MHz single-ended clock on `P26`, UART on `AN11/AM11`, 4 GB DDR4, a 4-bit TF-card interface, and 256 Mbit QSPI configuration flash.

```bash
# List all FPGA targets visible through Vivado Hardware Manager:
make fpga-info FPGA_DETECT_REFRESH=1

# Build and load the unified 4 GB DDR4/MIG BIOS bitstream:
make fpga-build FPGA_BOARD=mlk_cu08_ku15p
make fpga-load FPGA_BOARD=mlk_cu08_ku15p

# Open the H13 UART (the default on the current host is /dev/ttyUSB1):
make fpga-console FPGA_BOARD=mlk_cu08_ku15p UART_PORT=/dev/ttyUSB1

# Linux/MIG flow:
make linux-fpga-rv32-e2e FPGA_BOARD=mlk_cu08_ku15p UART_PORT=/dev/ttyUSB1
```

The default `LINUX_FPGA_INIT=full` runs `/init`, mounts the runtime filesystems, starts Buildroot services, and provides a console login. The explicit diagnostic option `LINUX_FPGA_INIT=shell` enters `/bin/sh` directly and skips runtime mounts as well as services. Missing `/proc/cpuinfo`, `/sys/devices` or `/dev/null` in this mode does not imply that the kernel lacks those features. With linux-build packages containing `/sbin/raptor-shell`, select `LINUX_FPGA_INIT=prepared-shell` for a fast shell with procfs, sysfs, devtmpfs and devpts mounted. Older packages can use `LINUX_FPGA_INIT=full` for the complete Buildroot init sequence, including networking and SSH host-key generation:

```bash
# New linux-build packages: mounts runtime filesystems, skips services.
make linux-fpga-rv32-e2e FPGA_BOARD=mlk_cu08_ku15p \
    UART_PORT=/dev/ttyUSB1 LINUX_FPGA_INIT=prepared-shell

# Full Buildroot initialization, also supported by older packages.
make linux-fpga-rv32-e2e FPGA_BOARD=mlk_cu08_ku15p \
    UART_PORT=/dev/ttyUSB1 LINUX_FPGA_INIT=full
```

The H13 platform uses the board-specific clock, UART, SD, and DDR pinout while reusing the verified KU15P MIG and Vivado load/flash flow. H13 FPGA builds always use the external 4 GB DDR4 profile (`VARIANT=linux32`, `WITH_MIG=1`, `INTEGRATED_MAIN_RAM_SIZE=0`); there is no separate standard 512 KiB image. Because H13 and CU07 share the same `xcku15p` JTAG part, always pass `FPGA_BOARD` for build, load, flash, and upload operations.

## MLK-CU07-KU15P Hardware Flow (Xilinx Vivado)

Milianke MLK-CU07-KU15P (Kintex UltraScale+ `xcku15p-ffva1156-2-e`). The bring-up flow supports the on-board DDR4 through the shared KU15P MIG profile.

```bash
# Source the Vivado settings so `vivado` is on PATH, e.g.:
source /opt/Xilinx/2025.2/Vivado/settings64.sh
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/License.lic

# Build the verified BIOS bitstream (synth + P&R via Vivado), then load it:
make fpga-build FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios
make fpga-load FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios

# Open the BIOS console. Press reset if the BIOS banner already timed out.
make fpga-console FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload and run payloads through BIOS serialboot:
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
make coremark-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 COREMARK_ITERATIONS=1000

# Persist to the on-board QSPI flash:
make fpga-flash FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small
```

Expected: `fpga-build` writes `mlk_cu07_ku15p.bit` under the configuration-specific `FPGA_DIR/gateware/` printed by `make info`, plus a zero-error report dashboard (`.../index.html`); BIOS reaches `litex>` after a passing memtest; `main-fpga` reports `memtest: PASS`; `coremark-fpga` prints `Correct operation validated` + an `Iterations/Sec` line.

Notes:
- `RAPT_CONFIG` defaults to `default`; override it explicitly when reproducing a build made with another preset.
- `BOOT_MODE=custom` (default) boots `firmware/fpga` from ROM; `BOOT_MODE=bios` boots the LiteX BIOS and is required for serialboot uploads.
- Board pins come from `third_party/security-hw-fpga/board/mlk-cu07-ku15p/`. `UART_PORT` defaults to `/dev/ttyUSB0`; override with `UART_PORT=/dev/ttyUSBx`.
- `fpga-load`/`fpga-flash` drive Vivado in batch mode (`scripts/vivado_load.tcl`, `scripts/vivado_flash.tcl`).

## KU15P Linux FPGA Flow (Vivado MIG)

Linux-oriented KU15P bitstream: `VARIANT=linux32`, LiteX BIOS, on-board 4 GB DDR4 via Xilinx MIG mapped as `main_ram` at `0x80000000` (1 GiB AXI window). On the KU15P, the board-aware Linux profile selects `BOOT_MODE=bios WITH_MIG=1 WITH_SDCARD=1 INTEGRATED_MAIN_RAM_SIZE=0`, `SYS_CLK=50000000` (50 MHz), `UART_BAUD=115200`, and the `default` Raptor preset. The KU15P external-DDR build sets `RAPT_PMEM_BYTES` to the mapped DDR size and defaults `LINUX_FPGA_RAM_SIZE` to that size (1 GiB, `0x80000000..0xbfffffff`). Other platforms retain the default 256 MiB PMEM classifier. MMIO still starts at `0xc0000000`; DDR windows larger than 1 GiB are rejected. Rebuild both gateware and the Linux boot artifacts when upgrading from the old 256 MiB map: a new DTB must not be used with the old classifier. This configuration does not by itself establish board-level 1 GiB memory-test or Linux stress-test success. The legacy LiteDRAM path is still available via `WITH_LITEDRAM=1`. `make fpga-build VARIANT=linux32 FPGA_BOARD=mlk_cu07_ku15p` only succeeds if the Vivado timing report meets constraints; the default bitstream lands under `build/mlk_cu07_ku15p/bios-linux32-mig-sdcard-default-<config-hash>/gateware/`.

KU15P BIOS builds now stop at `litex>` after hardware initialization. Enter `sdcardboot` to boot from SD, the namespaced `netboot` command from `serve` for Ethernet, or `serialboot` for a serial upload. This applies to the fixed netboot and RV64 network profiles as well. `BOOT_MODE=bios` selects the firmware; `CONFIG_BIOS_NO_BOOT` disables its automatic startup sequence while preserving these commands. Ordinary builds can explicitly opt back in with `EXTRA_FLAGS=--sdcard-autoboot` and SD enabled. Rebuild and load the matching bitstream to apply this policy: an existing `.bit` embeds the old BIOS and does not change when only the Python/Makefile sources do.

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/License.lic

# Build the RV32 bitstream when stale, load it, then upload OpenSBI + Linux:
make linux-fpga-rv32-e2e UART_PORT=/dev/ttyUSB0

# RV32 OpenSBI-only end-to-end bring-up (small upload, useful before Linux):
make opensbi-fpga-rv32-e2e UART_PORT=/dev/ttyUSB0

# RV64 equivalents use the linux64 CPU variant and a separate image directory:
make linux-fpga-rv64-e2e UART_PORT=/dev/ttyUSB0
make opensbi-fpga-rv64-e2e UART_PORT=/dev/ttyUSB0

# Open the console after either flow finishes:
make fpga-console VARIANT=linux32 UART_PORT=/dev/ttyUSB0

# QSPI flash remains an explicit operation:
make fpga-build VARIANT=linux32 && make fpga-flash VARIANT=linux32
```

The convenience targets are split by iteration cost:

| Target                                                  | Operations                                                  | Use when                                                 |
| ------------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------- |
| `linux-fpga-rv32-upload` / `linux-fpga-rv64-upload`     | Upload payload, seeded DTB, and stage0 without zero gaps    | Debugging without using the SD card                      |
| `linux-fpga-rv32-run` / `linux-fpga-rv64-run`           | Load the matching timing-clean bitstream, then upload Linux | The FPGA may contain another bitstream                   |
| `linux-fpga-rv32-e2e` / `linux-fpga-rv64-e2e`           | Build, load, then upload the matching Linux image           | Reproducing the complete boot flow                       |
| `opensbi-fpga-rv32-upload` / `opensbi-fpga-rv64-upload` | Upload standalone OpenSBI only                              | Iterating OpenSBI or DTB without touching the FPGA image |
| `opensbi-fpga-rv32-run` / `opensbi-fpga-rv64-run`       | Load the matching bitstream, then upload OpenSBI            | Re-establishing a known OpenSBI test state               |
| `opensbi-fpga-rv32-e2e` / `opensbi-fpga-rv64-e2e`       | Build, load, then upload standalone OpenSBI                 | Full OpenSBI-only bring-up                               |

The RV32 wrappers force `VARIANT=linux32`, while the RV64 wrappers force `VARIANT=linux64`; board, MIG, BIOS, clock, DTB timebase, and payload builds therefore remain on the matching profile. Override `UART_PORT` when auto-detection does not select the board. Keep SFL at the default 115200 baud: the host-to-FPGA path is not reliable at higher rates.

### DMA Cache Maintenance

LiteSDCard DMA is not coherent with Raptor's write-through L1D. Current `cbo.inval` and `cbo.flush` invalidate all ways of the addressed set; `cbo.clean` only drains write-through stores. LiteX's legacy no-argument `flush_cpu_dcache()` hook sweeps a mapped 4 KiB SRAM page in 64-byte CBO blocks, covering every set under Raptor's VA-bit-11:6 selection contract (higher physical colors are cleared together). A single `cbo.flush 0(x0)` is not a whole-cache operation, and address zero is unmapped on KU15P. This sweep is Raptor-specific, not a portable generic Zicbom whole-cache algorithm. The Linux DT advertises `zicbom` and the configured `riscv,cbom-block-size`.

### SD Card Boot Image

Build the Linux image from this directory:

```bash
make fpga-img-rv32 RAPT_CONFIG=default
sha256sum build/firmware/linux-fpga/rv32/linux-fpga.img

# RV64 image (linux64 RTL, LP64 stage0, RV64 Linux payload, Sv39 DTB):
make fpga-img-rv64 RAPT_CONFIG=default
sha256sum build/firmware/linux-fpga/rv64/linux-fpga.img
```

On its first image build, the development flow obtains 32 bytes from the host CSPRNG and stores them as `build/firmware/linux-fpga/rv32/rng-seed.bin`. Image assembly replaces the all-zero `/chosen/rng-seed` template with that value. Linux trusts and consumes the seed during early boot, so a full Buildroot boot does not stop indefinitely in `seed_rng()`/`getrandom()` before `ssh-keygen -A`. The seed itself is never printed; the build log only prints a short SHA-256 fingerprint. Delete `rng-seed.bin` and rebuild to rotate it.

For convenient FPGA development, repeated SD boots reuse this build-directory seed. This is sufficient to avoid CRNG startup stalls, but it is not a production entropy design: cloned images can produce related or repeated secrets. A deployed standalone design needs a reviewed FPGA hardware RNG or persistent seed rotation. Never commit or hard-code the generated seed in DTS.

The serial-upload target uses LiteXTerm's multi-image mode and transfers only the populated regions (payload, seeded DTB, and stage0). It deliberately skips the zero-filled address gaps required by the contiguous SD image, reducing the RV32 transfer by about 16 MiB. Passing an explicit `BIN=...` keeps the generic single-region upload behavior.

LiteX BIOS reads this image from `boot.bin` in the root of a FAT32 SD-card partition. The bundled FatFs configuration has exFAT support disabled (`FF_FS_EXFAT=0`), so exFAT and NTFS partitions are not accepted even when the host can mount them normally. Use FAT32; do not rely on the exFAT format commonly shipped on 64 GB and larger cards. This is an SD-card file copy, not a QSPI flash operation.

For the Linux FPGA profile, the BIOS bitstream also embeds the current stage0 and generated DTB. After `sdcardboot` copies an older contiguous `boot.bin` to DDR, BIOS replaces those two small regions before jumping; the large OpenSBI/Linux payload is still read from the unchanged SD card. BIOS also patches one 4-byte instruction in the loaded release OpenSBI header so its FDT relocation uses `0x83f00000`, outside the large Linux Image, rather than the overlapping legacy `0x82200000` address. It checks the expected instruction sequence and refuses to boot if the SD OpenSBI header does not match. This permits bootargs, board-model, and development RNG-seed changes without rewriting the card. The embedded stage0 still has to match the payload layout and size on the card; replace `boot.bin` when changing to a differently sized Linux payload. Changing the embedded stage0, DTB, seed, or OpenSBI patch requires rebuilding and reloading the BIOS bitstream; subsequent boots use the fast SD path.

Before inserting the card, run:

```bash
lsblk -p -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,RM,MODEL,TRAN
```

Insert the card and run the same command again. The newly appearing removable disk is the SD card. A USB reader commonly appears as `/dev/sdX` with partition `/dev/sdX1`; an internal reader may appear as `/dev/mmcblk0` with partition `/dev/mmcblk0p1`. Confirm its size, model, and `RM=1`. **Do not use the host system disk**, such as `/dev/nvme0n1`.

Before copying, verify that the partition is detected as `vfat`/`FAT32`, not `exfat`, `ntfs`, or an unknown filesystem:

```bash
lsblk -p -o NAME,SIZE,FSTYPE,FSVER,LABEL,MOUNTPOINTS,RM,MODEL,TRAN /dev/sdX
sudo blkid -p /dev/sdX1
```

Replace `/dev/sdX` and `/dev/sdX1` below with the names shown by `lsblk`, then copy and verify the image:

```bash
lsblk -p -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,RM,MODEL,TRAN /dev/sdX
sudo umount /dev/sdX1 2>/dev/null || true
sudo mkdir -p /mnt/raptor-sd
sudo mount /dev/sdX1 /mnt/raptor-sd
sudo cp -f build/firmware/linux-fpga/rv32/linux-fpga.img /mnt/raptor-sd/boot.bin
sync
sha256sum build/firmware/linux-fpga/rv32/linux-fpga.img
sudo sha256sum /mnt/raptor-sd/boot.bin
sudo umount /mnt/raptor-sd
sudo eject /dev/sdX
```

For RV64, keep the same mount, sync, destination checksum, unmount, and eject steps, but replace the image copy and source checksum commands with:

```bash
sudo cp -f build/firmware/linux-fpga/rv64/linux-fpga.img /mnt/raptor-sd/boot.bin
sha256sum build/firmware/linux-fpga/rv64/linux-fpga.img
```

The two SHA-256 values must match. `filesystem mount failed (FatFs error 13)` means `FR_NO_FILESYSTEM`: FatFs did not find a supported FAT volume. Check the partition first; a valid exFAT filesystem still produces this BIOS error because exFAT is disabled:

```bash
sudo blkid -p /dev/sdX1
sudo file -s /dev/sdX1
```

If the result is exFAT, NTFS, unknown, or a damaged FAT filesystem, recreate it as FAT32. The following commands **erase all files on that partition**. For an MBR-partitioned `/dev/sdX`, also set partition 1 to type `0x0c` (W95 FAT32 LBA); omit the `sfdisk` command for a GPT card, or use its existing Microsoft basic-data partition type.

```bash
sudo umount /dev/sdX1 2>/dev/null || true
sudo sfdisk --part-type /dev/sdX 1 c
sudo mkfs.fat -F 32 -n RAPTOR_BOOT /dev/sdX1
sudo fsck.fat -n /dev/sdX1
```

Then repeat the mount/copy/checksum/unmount steps above. A successful final check should report `TYPE="vfat"`, `VERSION="FAT32"`, and matching source and destination SHA-256 values:

```bash
sudo blkid -p /dev/sdX1
sudo fsck.fat -n /dev/sdX1
```

Insert the card into the KU15P board, load its Linux bitstream, and open the console (`make linux-fpga-rv32-load FPGA_BOARD=mlk_cu08_ku15p`, then `make fpga-console FPGA_BOARD=mlk_cu08_ku15p UART_PORT=/dev/ttyUSB1`). BIOS waits at the `litex>` prompt after serialboot times out, even with an SD card inserted. Run `sdcardboot` to start from SD manually. The KU15P flow is verified through an interactive BusyBox root shell. Other boards still need their own end-to-end validation.

Key conventions:
- The bitstream knobs `BOOT_MODE=bios INTEGRATED_MAIN_RAM_SIZE=0 WITH_MIG=1` are all auto-set by the Linux FPGA profile (`VARIANT=linux32`). The board-specific MIG IP maps external DDR4 at `0x80000000`.
- The SD controller is present by default in KU15P and AXAU15 Linux builds. `SDCARD_BOOT_DISABLE` excludes SD from automatic BIOS boot; enter `sdcardboot` at the `litex>` console to start it. Serialboot remains available.
- Default `fpga-upload VARIANT=linux32` is a serial fallback: it uses LiteXTerm multi-image mode to upload only payload, seeded DTB, and stage0, avoiding the zero-filled holes in the contiguous SD image.
- KU15P UART and SFL are fixed at 115200 baud because the board's host-to-FPGA path is not reliable at higher rates.
- Payload-only iteration: once the bitstream is loaded, just re-run the matching upload target (`make fpga-upload VARIANT=linux32`, `make coremark-fpga VARIANT=linux32`, …) — no re-synthesis needed.
- Raw `BIN` uploads (`make fpga-upload VARIANT=linux32 BIN=…`) carry no OpenSBI args/DTB/relocation; the image must bring its own LiteX MMIO runtime.
- Hardware-changing knobs and BIOS source changes require a new bitstream; `make fpga VARIANT=linux32` (build + load) rebuilds first, while `make fpga-load VARIANT=linux32` checks the build stamp and loads the existing bitstream without rebuilding. Source-only generation (`fpga-gen`) invalidates that stamp: a newly generated `bios.bin` or `soc.h` does not update the ROM in an existing `.bit`. Use the same `FPGA_BOARD`, `VARIANT`, and preset for build and load. `fpga-load` is volatile; after power cycling, the board uses the image in flash.

Status: the `default` RV32GC-capable preset routes, passes the BIOS DDR test, boots OpenSBI and Linux from an unchanged legacy SD image, initializes the CRNG from the BIOS-embedded DTB at kernel time zero, and reaches the interactive BusyBox `~ #` root shell with the historical `LINUX_FPGA_INIT=shell` setting. The current default is `LINUX_FPGA_INIT=full`; that full-service startup still needs separate board acceptance. Do not treat SFL or SD copy completion alone as a successful Linux boot; the end-to-end success marker is an interactive shell prompt.

Verified on `mlk_cu08_ku15p` at 50 MHz with the legacy SD Linux 6.18.39: OpenSBI passes `Next Arg1=0x83f00000`, `/bin/sh` starts at kernel time 583.5 s, `entropy_avail` reads 256, and the live DT model and bootargs remain intact after initmem is freed. Long silent intervals during this roughly ten-minute kernel startup are still expected; direct-shell mode skips Buildroot service startup and SSH host-key generation. The tested bitstream meets timing with WNS +0.081 ns and WHS +0.005 ns. JTAG loading is volatile; after power loss, reload the bitstream before using the same unchanged SD card.

## Directory Structure

```
fpga/litex/
+-- Makefile            # Build system (run 'make help')
+-- mk/                 # Derived config (config.mk) and reusable recipes (recipes.mk)
+-- setup_env.sh        # Environment setup (venv + LiteX install)
+-- raptor_soc.py       # Verilator simulation SoC entry point
+-- tang_mega_138k_pro.py         # Tang Mega 138K Pro FPGA SoC entry point
+-- ku15p_soc.py                  # Shared KU15P SoC and build flow; explicit immutable board config
+-- mlk_cu07_ku15p.py             # MLK-CU07-KU15P platform/config entry point
+-- mlk_cu08_ku15p.py              # MLK-CU08-KU15P Vivado/MIG entry point
+-- mlk_cu08_ku15p_platform.py     # MLK-CU08-KU15P local pin/platform definition
+-- alinx_axau15.py                # ALINX AXAU15 MIG/SDCard target
+-- README.md           # This file
+-- firmware/           # Sim, integrated-ROM FPGA, and Linux-FPGA stage0 firmware
+-- benchmarks/         # LiteX-native CoreMark/Embench payloads
+-- tests/              # Small standalone LiteX C payloads
+-- scripts/            # LiteX/Vivado patching, reports, load/flash helpers
+-- glsim/              # Gate-level simulation helpers
\-- cores/cpu/raptor/   # LiteX CPU integration files
    +-- __init__.py     # Python package marker
    +-- core.py         # CPU class (AXI4 bus, variants, sources)
    +-- crt0.S          # Startup assembly (trap, .data/.bss init)
    +-- boot-helper.S   # Boot jump helper
    +-- system.h        # Cache flush, CSR macros
    +-- irq.h           # Interrupt management API
    \-- csr-defs.h      # CSR address definitions
```

## CPU Variants

Raptor's microarchitecture preset is selected separately with `RAPT_CONFIG=<name>`, which maps to `hdl/configs/<name>/rapt_config.svh` during RTL packing. The LiteX CPU `VARIANT` still selects SoC/software defaults, but Linux variants also add RTL preprocessor defines through `RAPT_PACK_VFLAGS` (`-DRAPT_LINUX`, and `-DRAPT_RV64` for `linux64`).

### Independent build configurations

RTL exports live in `build/rtl/<preset>-<defines-hash>/`, shared by the Make prerequisite and CPU adapter. Packing does not invoke `sim/Makefile`, alter `sim/.config`, or overwrite `sim/build/<preset>/rapt_pack.sv`. Each cache entry is locked and published only after both preprocessor outputs succeed.

FPGA directories use `build/<board>/<flavor>-<config-hash>/`; simulation and Linux boot artifacts also have configuration-specific directories. The hashes include the resolved preset, variant, clocks, memory settings, debug flags and boot settings, so changing only `SYS_CLK` or `RAPT_PACK_VFLAGS` no longer overwrites another build. BIOS/picolibc patches apply to a private software copy inside that output directory, not to the shared third-party checkout.

Use the same configuration arguments for build and load; `make info` prints the exact `FPGA_DIR` and bitstream path. Older un-hashed output directories are left intact and are not automatically reused. Two simultaneous invocations targeting the *same* full output configuration should still be avoided.

```bash
make pack VARIANT=linux64 FPGA_BOARD=mlk_cu08_ku15p RAPT_CONFIG=default
make fpga-build VARIANT=linux64 FPGA_BOARD=mlk_cu08_ku15p RAPT_CONFIG=default
```

| Variant   | Use Case                |
| --------- | ----------------------- |
| `linux32` | RV32 Linux/OpenSBI boot |
| `linux64` | RV64 experiments        |

Use `make linux32` or `make linux64` for simulation. For FPGA, use the explicit commands such as `make linux-fpga-rv32-build` and `make linux-fpga-rv64-build`.

## Command Reference

The workflow sections above document the common paths. Run `make help` for the generated target and variable reference, and `make info` to inspect the resolved simulation and FPGA profile. Target descriptions and defaults live in the Makefile so this README does not duplicate them.

## FPGA Firmware Upload (via BIOS serialboot)

The `main-fpga`, `irqtest-fpga`, `coremark-fpga`, and `app-llm-*-fpga` targets iterate firmware without rebuilding the bitstream: firmware is compiled to main_ram (`0x80000000`) and uploaded via BIOS serialboot. Prerequisites: a loaded/flashed BIOS bitstream (`make fpga FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small`), `INTEGRATED_MAIN_RAM_SIZE > 0` (default 512 KB), and UART @ 115200. Uploads use `litex_term --safe` by default; set `SERIALBOOT_SAFE=0` for the faster multi-frame mode.

`fpga-egos-upload` also uses the standard `litex_term`/LiteX BIOS serialboot path. It uploads one compact bundle at `0x82000000` instead of the legacy 12 MiB sparse flat image. A 92-byte stage0 clears the egos runtime area, copies the kernel to `0x80000000` and `disk.img` to `0x80800000`, executes `fence.i`, and jumps to egos. The serial transfer is about 4.07 MiB while the runtime memory layout remains unchanged.

```bash
# Build + upload main interactive shell:
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload CoreMark (save log for later reporting):
make coremark-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 COREMARK_ITERATIONS=1000 \
    2>&1 | tee /tmp/raptor-ku15p-coremark.log

# RLLMBench FPGA payloads:
make app-llm-infer-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
```

If `litex_term` reports a serialboot timeout, press the board reset button with the same command still running. OpenSBI/Linux runs in sim (`make linux32`) and on the KU15P MIG bring-up path (`make fpga-* VARIANT=linux32`); the verified day-to-day FPGA smoke path is the 512 KiB integrated-RAM BIOS/CoreMark flow above.

## app/ Payloads

The `app/` tree can produce LiteX-native flat binaries when a program links against `app/lib/litex/start.S`, `app/lib/litex/link.ld`, and `app/lib/litex/runtime.c`. This is the preferred route for running app tests on FPGA: build or load a BIOS bitstream once, then use BIOS serialboot instead of re-running place-and-route for every payload.

Current first-class app payloads are the RLLMBench fixed-point LLM workloads. They print `RLLMBENCH_RESULT` and `RLLMBENCH_SCORE` lines on the UART, matching the pk/NPC report format used by `make -C app llm-bench-report-sim`.

```bash
# LiteX simulation
make app-llm-ops
make app-llm-infer
make app-llm-train

# Override when the SoC time CSR is not 1 MHz
make app-llm-infer RLLMBENCH_TIMEBASE_HZ=50000000

# FPGA upload via BIOS serialboot
make app-llm-fpga BENCH=infer FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Generic prebuilt app payload upload
make app-fpga-upload APP_FPGA_BIN=/path/to/app.bin FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Same app payload, but using the KU15P Linux/MIG DDR bitstream
# (VARIANT=linux32 selects the MIG board + 115200 baud automatically)
make app-fpga-upload VARIANT=linux32 APP_FPGA_BIN=/path/to/app.bin UART_PORT=/dev/ttyUSB0
```

RLLMBench uses `rdtime` by default and reports `score_per_sec` from physical seconds only. Set `RLLMBENCH_TIMEBASE_HZ` to the real `time` CSR frequency so LiteX simulation, FPGA boards, pk/NPC, and native ports remain directly comparable. When producing reports from copied serial logs, pass the board or simulation core clock as `--core-clock-mhz <MHz>` to `report.py` to derive `score_per_mhz`, the CoreMark/MHz-style work-per-million-core-cycles metric.

## Architecture

```
+--------------------------------------------+
|  Raptor Core (rapt.sv)                     |
|  +- Dual-issue OoO, RV32IMAC + Zb*         |
|  \- AXI4 Master (32-bit addr, 32-bit data) |
+---------+----------------------------------+
          | AXI4 Full
          v
+--------------------------------------------+
|  LiteX SoC Interconnect                    |
|  +- AXI -> Wishbone converter              |
|  +- UART (serial console)                  |
|  +- Timer                                  |
|  +- SRAM (integrated)                      |
|  \- main_ram (integrated, LiteDRAM, or MIG)|
+--------------------------------------------+
```

## Configuration

Override configuration inline with `make <target> VAR=value`. Use `make help` for supported variables and `make info` to confirm resolved values such as board, clock, memory profile, build directory, and bitstream path before a hardware operation.

### Embench Simulation

```bash
make embench
# CI-style Linux smoke: one Vsim process, using the host CPUs internally.
make embench SIM_TIMEOUT=300 SIM_THREADS="$(nproc)" EMBENCH_JOBS=1 \
    EMBENCH_NETTLE_SHA256_LOCAL_SCALE=1
```

Per-benchmark logs and `summary.md` are written to `sim/build/<RAPT_CONFIG>/logs/litex/embench-logs/`. A benchmark is successful only after its UART output contains `--- done ---`; a missing binary, Vsim early exit, or timeout is recorded as `ERROR` or `TIMEOUT` and makes `make embench` return nonzero. A non-default `EMBENCH_NETTLE_SHA256_LOCAL_SCALE` keeps SHA-256 as a correctness smoke check and excludes it from the partial aggregate; retain the default scale `562` when reporting an official Embench score. That scale is necessary but not sufficient: the run must also select all 19 canonical workloads and every workload must pass with reference data. Each actual run atomically records its source revision, patch identity, clock, scale, and benchmark selection in `run-config.env`; reports use that manifest and reject an explicitly conflicting scale override.
