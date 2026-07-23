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

## MLK-CU07-KU15P Hardware Flow (Xilinx Vivado)

Milianke MLK-CU07-KU15P (Kintex UltraScale+ `xcku15p-ffva1156-2-e`). UART-only bring-up SoC (integrated ROM/SRAM, no DDR4) over the on-board USB-UART.

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

Expected: `fpga-build` writes `build/mlk_cu07_ku15p/bios/gateware/mlk_cu07_ku15p.bit` plus a zero-error report dashboard (`.../index.html`); BIOS reaches `litex>` after a passing memtest; `main-fpga` reports `memtest: PASS`; `coremark-fpga` prints `Correct operation validated` + an `Iterations/Sec` line.

Notes:
- `RAPT_CONFIG` defaults to `default`; override it explicitly when reproducing a build made with another preset.
- `BOOT_MODE=custom` (default) boots `firmware/fpga` from ROM; `BOOT_MODE=bios` boots the LiteX BIOS and is required for serialboot uploads.
- Board pins come from `third_party/security-hw-fpga/board/mlk-cu07-ku15p/`. `UART_PORT` defaults to `/dev/ttyUSB0`; override with `UART_PORT=/dev/ttyUSBx`.
- `fpga-load`/`fpga-flash` drive Vivado in batch mode (`scripts/vivado_load.tcl`, `scripts/vivado_flash.tcl`).

## KU15P Linux FPGA Flow (Vivado MIG)

Linux-oriented KU15P bitstream: `VARIANT=linux`, LiteX BIOS, on-board 4 GB DDR4 via Xilinx MIG mapped as `main_ram` at `0x80000000` (1 GiB AXI window). Setting `VARIANT=linux` (or `linux64`) on any FPGA goal auto-activates the **Linux FPGA profile**, which flips the defaults to `FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios WITH_MIG=1 WITH_SDCARD=1 INTEGRATED_MAIN_RAM_SIZE=0`, `SYS_CLK=50000000` (50 MHz), `UART_BAUD=115200`, and the `default` Raptor preset. Linux currently sees 256 MiB because the core's PMEM classifier accepts `0x80000000..0x8fffffff`; `LINUX_FPGA_RAM_SIZE` must not exceed that window until the classifier is widened. The legacy LiteDRAM path is still available via `WITH_LITEDRAM=1`. `make fpga-build VARIANT=linux` only succeeds if the Vivado timing report meets constraints; the default bitstream lands under `build/mlk_cu07_ku15p/bios-linux-mig-sdcard-default/gateware/`.

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/License.lic

# Build the bitstream when stale, load it, then upload OpenSBI + Linux:
make linux-fpga-e2e UART_PORT=/dev/ttyUSB0

# OpenSBI-only end-to-end bring-up (small upload, useful before Linux):
make opensbi-fpga-e2e UART_PORT=/dev/ttyUSB0

# Open the console after either flow finishes:
make fpga-console VARIANT=linux UART_PORT=/dev/ttyUSB0

# QSPI flash remains an explicit operation:
make fpga-build VARIANT=linux && make fpga-flash VARIANT=linux
```

The convenience targets are split by iteration cost:

| Target                | Operations                                                         | Use when                                                 |
| --------------------- | ------------------------------------------------------------------ | -------------------------------------------------------- |
| `linux-fpga-upload`   | Build the contiguous Linux image, then upload it with `litex_term` | Debugging without using the SD card                      |
| `linux-fpga-run`      | Load the existing timing-clean bitstream, then Linux upload        | The FPGA may contain another bitstream                   |
| `linux-fpga-e2e`      | Build bitstream if stale, load, then Linux upload                  | Reproducing the complete boot flow                       |
| `opensbi-fpga-upload` | Upload standalone OpenSBI only                                     | Iterating OpenSBI or DTB without touching the FPGA image |
| `opensbi-fpga-run`    | Load existing bitstream, then standalone OpenSBI upload            | Re-establishing a known OpenSBI test state               |
| `opensbi-fpga-e2e`    | Build if stale, load, then standalone OpenSBI upload               | Full OpenSBI-only bring-up                               |

All wrappers force `VARIANT=linux`; board, MIG, BIOS, clock, DTB timebase, and payload builds therefore remain on the same profile. Override `UART_PORT` when auto-detection does not select the board. Keep SFL at the default 115200 baud: the host-to-FPGA path is not reliable at higher rates.

### DMA Cache Maintenance

LiteSDCard DMA is not coherent with Raptor's write-through L1D. The CPU implements standard Zicbom encodings for `cbo.inval`, `cbo.clean`, and `cbo.flush`; each instruction waits for the unified store queue to drain and then conservatively invalidates the whole L1D. The current hardware therefore ignores the encoded block address for cache selection. LiteX's legacy no-argument `flush_cpu_dcache()` hook emits `cbo.flush 0(x0)` as a full-cache trigger, which is valid for this Raptor implementation but must not be treated as portable per-block Zicbom software. The Linux DT advertises `zicbom` plus a `riscv,cbom-block-size` derived from the selected `RAPT_CONFIG` cache-line size.

### SD Card Boot Image

Build the Linux image from this directory:

```bash
make fpga-img VARIANT=linux RAPT_CONFIG=default
sha256sum build/firmware/linux-fpga/linux-fpga.img
```

LiteX BIOS reads this image from `boot.bin` in the root of a FAT32 SD-card partition. This is an SD-card file copy, not a QSPI flash operation. Before inserting the card, run:

```bash
lsblk -p -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,RM,MODEL,TRAN
```

Insert the card and run the same command again. The newly appearing removable disk is the SD card. A USB reader commonly appears as `/dev/sdX` with partition `/dev/sdX1`; an internal reader may appear as `/dev/mmcblk0` with partition `/dev/mmcblk0p1`. Confirm its size, model, and `RM=1`. **Do not use the host system disk**, such as `/dev/nvme0n1`.

Replace `/dev/sdX` and `/dev/sdX1` below with the names shown by `lsblk`, then copy and verify the image:

```bash
lsblk -p -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,RM,MODEL,TRAN /dev/sdX
sudo umount /dev/sdX1 2>/dev/null || true
sudo mkdir -p /mnt/raptor-sd
sudo mount /dev/sdX1 /mnt/raptor-sd
sudo cp -f build/firmware/linux-fpga/linux-fpga.img /mnt/raptor-sd/boot.bin
sync
sha256sum build/firmware/linux-fpga/linux-fpga.img
sudo sha256sum /mnt/raptor-sd/boot.bin
sudo umount /mnt/raptor-sd
sudo eject /dev/sdX
```

The two SHA-256 values must match. If BIOS reports `filesystem mount failed (FatFs error 13)`, recreate the partition filesystem, which **erases all files on that partition**, then repeat the mount/copy/verify commands above:

```bash
sudo umount /dev/sdX1 2>/dev/null || true
sudo mkfs.fat -F 32 -n RAPTOR_BOOT /dev/sdX1
```

Insert the card into the KU15P board, load the Linux bitstream, and open the console (`make fpga-load`, `make fpga-console`). At the `litex>` prompt, run `sdcardboot`.

Key conventions:
- The bitstream knobs `BOOT_MODE=bios INTEGRATED_MAIN_RAM_SIZE=0 WITH_MIG=1` are all auto-set by the Linux FPGA profile (`VARIANT=linux`). DDR4 MIG IP `raptor_ddr4_0` maps a 1 GiB AXI window at `0x80000000`; the default DTB advertises the currently supported low 256 MiB.
- Linux normally boots from the SD card with the BIOS `sdcardboot` command. The SD controller is present by default on KU15P builds, while automatic SD boot remains disabled so serialboot and RaptOS iteration stay convenient.
- Default `fpga-upload VARIANT=linux` is a serial fallback: it uploads the contiguous `linux-fpga.img` at `0x80000000` with `litex_term`, using the same path as RaptOS and other firmware images.
- KU15P UART and SFL are fixed at 115200 baud because the board's host-to-FPGA path is not reliable at higher rates.
- Payload-only iteration: once the bitstream is loaded, just re-run the matching upload target (`make fpga-upload VARIANT=linux`, `make coremark-fpga VARIANT=linux`, …) — no re-synthesis needed.
- Raw `BIN` uploads (`make fpga-upload VARIANT=linux BIN=…`) carry no OpenSBI args/DTB/relocation; the image must bring its own LiteX MMIO runtime.
- Hardware-changing knobs require a new bitstream; `make fpga VARIANT=linux` (build + load) rebuilds first, while `make fpga-load VARIANT=linux` loads the existing bitstream without rebuilding.

Status: the `default` RV32IMAC preset routes, passes the BIOS DDR test, boots OpenSBI and Linux from SD, and reaches the interactive `tinysh#` initramfs shell. `make coremark-fpga VARIANT=linux` and the directed privileged/MMU probes also pass from MIG DDR. Do not treat SFL upload completion alone as a successful Linux boot; the end-to-end success marker is an interactive `tinysh#` prompt.

## Directory Structure

```
fpga/litex/
+-- Makefile            # Build system (run 'make help')
+-- setup_env.sh        # Environment setup (venv + LiteX install)
+-- raptor_soc.py       # Verilator simulation SoC entry point
+-- raptor_tang_mega_138k_pro.py  # Tang Mega 138K Pro FPGA SoC entry point
+-- raptor_mlk_cu07_ku15p.py      # MLK-CU07-KU15P Vivado/MIG FPGA SoC entry point
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

| Variant    | Use Case                               |
| ---------- | -------------------------------------- |
| `standard` | Sim & FPGA (BIOS-only, no Linux image) |
| `linux`    | RV32 Linux/OpenSBI boot                |
| `linux64`  | RV64 experiments                       |

Select variant directly with `make sim VARIANT=linux`, or use convenience targets such as `make linux` (sim) and `make fpga-build VARIANT=linux` (KU15P Linux/MIG FPGA).

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

If `litex_term` reports a serialboot timeout, press the board reset button with the same command still running. OpenSBI/Linux runs in sim (`make linux`) and on the KU15P MIG bring-up path (`make fpga-* VARIANT=linux`); the verified day-to-day FPGA smoke path is the 512 KiB integrated-RAM BIOS/CoreMark flow above.

## app/ Payloads

The `app/` tree can produce LiteX-native flat binaries when a program links against `app/lib/litex/start.S`, `app/lib/litex/link.ld`, and `app/lib/litex/runtime.c`. This is the preferred route for running app tests on FPGA: build or load a BIOS bitstream once, then use BIOS serialboot instead of re-running place-and-route for every payload.

Current first-class app payloads are the RLLMBench fixed-point LLM workloads. They print `RLLMBENCH_RESULT` and `RLLMBENCH_SCORE` lines on the UART, matching the pk/NPC report format used by `make -C app llm-bench-report-npc`.

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
# (VARIANT=linux selects the MIG board + 115200 baud automatically)
make app-fpga-upload VARIANT=linux APP_FPGA_BIN=/path/to/app.bin UART_PORT=/dev/ttyUSB0
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
