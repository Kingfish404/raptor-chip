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
make fpga-build FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small
make fpga-load FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small

# Open the BIOS console. Press reset if the BIOS banner already timed out.
make fpga-console FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload and run payloads through BIOS serialboot:
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
make coremark-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 COREMARK_ITERATIONS=1000

# Persist to the on-board QSPI flash:
make fpga-flash FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small
```

Expected results:
- `fpga-build` exits successfully and writes `build/mlk_cu07_ku15p/bios/gateware/mlk_cu07_ku15p.bit`.
- Vivado report dashboard is generated at `build/mlk_cu07_ku15p/bios/gateware/index.html`; route errors and DRC checks should be zero.
- BIOS console prints the LiteX BIOS banner, main RAM memtest passes, and reaches `litex>`.
- `main-fpga` uploads with `litex_term --safe`; its shell `memtest` command should report `memtest: PASS`.
- `coremark-fpga` should print `Correct operation validated` and an `Iterations/Sec` line.

Notes:
- FPGA goals default to `RAPT_CONFIG=middle`, the current KU15P-safe preset. Use `RAPT_CONFIG=small` for the compact legacy BIOS/CoreMark flow; `RAPT_CONFIG=default` can build but is not yet a passing KU15P hardware smoke path.
- `BOOT_MODE=custom` (default) boots `firmware/fpga` from ROM; `BOOT_MODE=bios` boots the LiteX BIOS `litex>` prompt and is required for serialboot uploads.
- Board pins (`sys_clock` AH18, `resetn` J23, UART `AN13`/`AP13`) come from `third_party/security-hw-fpga/board/mlk-cu07-ku15p/`.
- KU15P defaults `UART_PORT` to `/dev/ttyUSB0` when present; override it with `UART_PORT=/dev/ttyUSBx` if your host enumerates the board differently.
- `make fpga-load`/`fpga-flash` drive Vivado in batch mode (`scripts/vivado_load.tcl`, `scripts/vivado_flash.tcl`); override the serial device with `UART_PORT=/dev/ttyUSBx`.
- Vivado builds generate a local report dashboard at `build/mlk_cu07_ku15p/<boot_mode>/gateware/index.html`; regenerate it with `make fpga-reports-index FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=<mode>`.

## Experimental KU15P Linux FPGA Flow (Vivado MIG)

This path builds a Linux-oriented KU15P bitstream with `VARIANT=linux`, LiteX BIOS, and the on-board 4 GB DDR4 attached through Xilinx DDR4 MIG. The first RV32-addressable window is mapped as `main_ram` at `0x80000000` (default `LINUX_FPGA_RAM_SIZE=0x40000000`, 1 GiB). The default KU15P Linux/DDR system clock is `LINUX_FPGA_SYS_CLK=50000000` (50 MHz), matching the current bring-up target for MLK-CU07-KU15P. Linux FPGA targets default the bitstream/serial baud to `LINUX_FPGA_UART_BAUD=230400`; a command-line `UART_BAUD=...` still overrides that value for compatibility. Linux FPGA targets now default to the KU15P-safe `middle` Raptor preset: default-sized ROB/RS/IOQ/L1, TAGE, single issue/commit, SQ=4, and no L2. The older LiteDRAM path remains available with `WITH_LITEDRAM=1`, but the Linux FPGA make targets now default to MIG because the board DDR reference design also uses Vivado MIG.

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/License.lic

# Build the Linux variant bitstream. The default KU15P-safe profile writes:
#   build/mlk_cu07_ku15p/bios-linux-mig-middle/gateware/mlk_cu07_ku15p.bit
# The target only succeeds if the Vivado timing report says constraints are met.
make linux-fpga-build UART_BAUD=230400

# Load an already-built timing-clean bitstream without re-entering fpga-build.
make linux-fpga-load-only UART_BAUD=230400

# First upload the tiny stage0-only smoke image. It is only about 660 bytes and
# quickly validates BIOS serialboot, DDR writes, stage0 SRAM relocation, and the
# final jump back to 0x80000000 without waiting for a ~32 MiB Linux transfer.
make linux-fpga-smoke-img
make linux-fpga-smoke-upload UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# Convenience: build, load, then upload the tiny smoke image.
# This is a from-scratch target; for payload-only iteration, use the upload
# target above instead.
make linux-fpga-smoke UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# After the smoke path is good, build/upload the full OpenSBI+Linux image.
# Press reset if the BIOS serialboot window has timed out before litex_term attaches.
make firmware-linux-fpga
make linux-fpga-upload UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# Faster OpenSBI-only upload using linux/opensbi's standalone fw_payload.bin.
# This reuses the same Linux/MIG bitstream and stage0+DTB handoff, but uses an
# 8 MiB DTB staging slot by default so the serialboot image stays much smaller
# than the full OpenSBI+Linux payload.
make linux-fpga-opensbi-img
make linux-fpga-opensbi-upload UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# Reuse the same loaded/flashed Linux/MIG bitstream for other raw payloads.
# These paths do not rebuild the bitstream; the payload must be a flat RV32
# image linked to run at 0x80000000 and must use the LiteX FPGA device map.
make linux-fpga-upload-bin BIN=/path/to/payload.bin UART_PORT=/dev/ttyUSB0 UART_BAUD=230400
make linux-fpga-upload BIN=/path/to/payload.bin UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# Convenience raw-payload uploads known to match the Linux/MIG bitstream.
make linux-fpga-coremark-upload COREMARK_ITERATIONS=1000 UART_PORT=/dev/ttyUSB0 UART_BAUD=230400
make linux-fpga-main-upload UART_PORT=/dev/ttyUSB0 UART_BAUD=230400
make linux-fpga-app-upload APP_FPGA_BIN=/path/to/litex-native-app.bin UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# TinyOS / egos — KU15P RAM-disk image. `linux-fpga-egos-prepare` builds
# `egos-ku15p.bin` which embeds disk.img at 0x80800000 and fixes UART/CLINT
# addresses for the KU15P LiteX memory map. The same Linux/MIG bitstream is
# reused; no new hardware or bitstream rebuild is needed.
make linux-fpga-egos-prepare
make linux-fpga-egos-upload UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# xv6 is still RV64/Sv39 only — no KU15P support yet.
make linux-fpga-xv6-prepare
make linux-fpga-xv6-upload

# Directed Vivado xsim checks for the FPGA bring-up fixes.
make -C ../../verify xsim-l2-ordered-mmio
make -C ../../verify xsim-l1d-byte-rom
make -C ../../verify xsim-bus-l1d-rlast
make -C ../../verify xsim-ioq-pending-lock

# Convenience: build, load, then upload the full Linux image.
# This is a from-scratch target; for payload-only iteration, use the upload
# target above instead.
make linux-fpga UART_PORT=/dev/ttyUSB0 UART_BAUD=230400

# Persist only the Linux/MIG bitstream to QSPI flash.
make linux-fpga-flash UART_BAUD=230400
```

Boot/image conventions:
- Bitstream: `BOOT_MODE=bios`, `VARIANT=linux`, `INTEGRATED_MAIN_RAM_SIZE=0`, `WITH_MIG=1`.
- DDR4 MIG: generated as Vivado IP `raptor_ddr4_0`, using a 64-bit DDR4 interface, 512-bit AXI user port, and `MT40A512M16`-compatible timing for the board's 4 x Hynix `H5AN8G6NCJR-VKI`; mapped size defaults to 1 GiB at `0x80000000`.
- Smoke image: `build/firmware/linux-fpga/linux-fpga-smoke.img` is a stage0-only diagnostic with zero payload and zero DTB size. It repeatedly prints the stage0 checkpoints after the jump back to `0x80000000`; stop `litex_term` with Ctrl-A K after confirming the output.
- Upload image: `build/firmware/linux-fpga/linux-fpga.img` contains stage0 at `0x80000000`, source `fw_payload.bin` at `0x80100000`, and source DTB at `0x82000000`.
- OpenSBI-only image: `build/firmware/linux-fpga/linux-fpga-opensbi.img` has the same stage0/OpenSBI handoff as the full Linux image, but its payload is the standalone `linux/opensbi/build/platform/generic/firmware/fw_payload.bin` built by `make -C linux opensbi`, and its DTB source defaults to `0x80800000` (`LINUX_FPGA_OPENSBI_DTB_OFFSET=0x00800000`) instead of the full-Linux `0x82000000` slot. This is intended for quick OpenSBI/DTB/SBI-console bring-up; on the current tree the image is about 8 MiB versus about 32 MiB for the full RV32 OpenSBI+Linux upload image. The target intentionally uses `fw_payload.bin`: `fw_dynamic.bin` would need stage0 to provide an `fw_dynamic_info` block, and `fw_jump.bin` only becomes useful once a next-stage address/payload convention is added.
- OpenSBI convention: stage0 copies `fw_payload.bin` back to its link/run address `0x80000000`, copies the DTB to `LINUX_FPGA_DTB_ADDR` (default `0x83f00000`), then jumps with `a0=0` and `a1=LINUX_FPGA_DTB_ADDR`.
- DTB: generated from `firmware/linux-fpga/litex-soc.dts.in`; `timebase-frequency` follows `LINUX_FPGA_SYS_CLK` by default.
- Raw serialboot payload ABI: `linux-fpga-upload-bin` and `linux-fpga-upload BIN=...` upload exactly the specified flat image to `0x80000000` and let the LiteX BIOS jump there. The image must already be linked for `0x80000000`, must match the current RV32 bitstream, and must bring its own runtime/device support for LiteX UART/timer/CSR plus DDR main RAM. The raw path does not add OpenSBI arguments, a DTB, a disk image, or any relocation shim.
- Payload-only iteration: after the Linux/MIG BIOS bitstream is loaded or flashed, changing `linux-fpga-smoke.img`, `linux-fpga-opensbi.img`, `linux-fpga.img`, `egos-ku15p.bin`, or a raw `BIN` payload does not require synthesis/P&R. Use `linux-fpga-smoke-upload`, `linux-fpga-opensbi-upload`, `linux-fpga-upload`, `linux-fpga-egos-upload`, or `linux-fpga-upload-bin` to serialboot the new payload into the same bitstream.
- egos KU15P RAM-disk: `linux-fpga-egos-prepare` builds `app/build/tinyos-nsim-src/egos-2000/tools/egos-ku15p.bin`, a single flat binary (~12 MiB) containing the egos kernel at 0x80000000 and an embedded disk.img at 0x80800000. The build uses `-DPLATFORM_KU15P` to fix UART (0xF0001800) and CLINT (0x02000000) for the KU15P LiteX SoC, and the disk driver reads from the embedded RAM copy via the existing FLASH_ROM fallback path. `linux-fpga-egos-upload` uploads this image through BIOS serialboot. No SD card or SPI controller is needed. `linux-fpga-xv6-prepare` builds `kernel/kernel.bin` and `fs.img`, but `xv6-riscv` is RV64/Sv39 and expects virtio-blk plus QEMU/NSIM-style UART/CLINT/PLIC devices, while the current Linux/MIG target is RV32 `VARIANT=linux` and has no virtio disk.
- CoreMark compatibility: use `linux-fpga-coremark-upload` for the LiteX-native CoreMark in `fpga/litex/benchmarks/coremark`. The `app/benchmarks/coremark` target builds a pk/libc ELF path and is not a direct BIOS serialboot payload unless it is converted to a LiteX-native flat binary.
- Middle-config FPGA notes: the default Linux FPGA profile uses `RAPT_CONFIG=middle`, which keeps the useful default-size OoO window and L1 caches while baking in the currently hardware-passing KU15P choices. The fully enabled `default` preset remains available for architecture work and can meet timing, but it still needs RTL/microarchitecture debugging before it is treated as a passing KU15P hardware smoke path.
- Hardware-changing knobs: changing RTL, `RAPT_CONFIG`, `LINUX_FPGA_RAPT_CONFIG`, `RAPT_PACK_VFLAGS`, `LINUX_FPGA_FLAVOR_SUFFIX`, `SYS_CLK`, `LINUX_FPGA_SYS_CLK`, `LINUX_FPGA_UART_BAUD`, `UART_BAUD`, `WITH_MIG`, `MIG_SIZE`, `LINUX_FPGA_RAM_SIZE`, target Python, or the MIG Tcl regenerates hardware and requires a new bitstream. `linux-fpga-load` and the convenience targets call `linux-fpga-build` first; use `linux-fpga-load-only` when you explicitly want to program the cached bitstream.

Expected bring-up checkpoints:
- `make -C verify xsim-l2-ordered-mmio` should print `PASS: L2 ordered-MMIO xsim checks passed`.
- `make -C verify xsim-l1d-byte-rom` should print `PASS: L1D byte-ROM xsim checks passed`.
- `make -C verify xsim-bus-l1d-rlast` should print `PASS: rapt_bus L1D rlast xsim checks passed`.
- `make -C verify xsim-ioq-pending-lock` should print `PASS: IOQ pending-load lock xsim checks passed`.
- `linux-fpga-build` writes the bitstream under `build/mlk_cu07_ku15p/bios-linux-mig-middle/gateware/` by default and then requires the Vivado timing report to say constraints are met. Set `FPGA_FLAVOR_SUFFIX=...` or `LINUX_FPGA_FLAVOR_SUFFIX=...` only when intentionally naming an experimental variant.
- If Vivado writes a bitstream but the report says `Timing constraints are not met`, `linux-fpga-build`, `linux-fpga-load`, `linux-fpga-flash`, `linux-fpga-opensbi-upload`, and `linux-fpga-upload` stop before hardware use.
- BIOS waits for MIG calibration before releasing the Raptor CPU, reports `MAIN RAM: 1.0GiB`, runs the 2 MiB main RAM memtest successfully, and reaches the serial boot prompt or `litex>`.
- `linux-fpga-smoke-upload` completes quickly and then loops over these lines: `Raptor KU15P Linux stage0: loading OpenSBI payload`, `stage0: copy payload`, `stage0: payload copied`, and `stage0: jumping to OpenSBI`.
- `linux-fpga-upload` without `BIN` transfers the full image and should print the same stage0 checkpoints once before handing off to OpenSBI. With `BIN=/path/to/payload.bin`, it uploads that raw image directly to `0x80000000`; expected output then depends on the payload.
- `linux-fpga-opensbi-upload` builds `linux/opensbi` if needed, packages stage0 + standalone OpenSBI + DTB, and should print the stage0 checkpoints followed by the OpenSBI banner. The default standalone OpenSBI `fw_payload.bin` contains OpenSBI's small test payload, so this is a fast firmware/SBI smoke path rather than a Linux boot.
- `linux-fpga-coremark-upload` should print `Correct operation validated` and an `Iterations/Sec` line, now running from MIG DDR instead of the smaller integrated-RAM BIOS flow.
- Example 10-iteration CoreMark smoke result: `Total ticks=11539929` and `Total time=0.230798s` imply a 50 MHz timebase (`ticks / seconds`) and `43.327822 / 50 = 0.8666 CoreMark/MHz`. This run is not an official CoreMark score because it is shorter than 10 seconds; use `COREMARK_ITERATIONS=500` or `1000` for a valid-length FPGA run.
- A successful handoff then prints the OpenSBI banner and Linux boot log; the prebuilt payload uses a tiny initramfs shell.

This path is still Linux bring-up work, not yet equivalent to the verified 512 KiB integrated-RAM BIOS/CoreMark flow. Current KU15P `middle` checkpoints are: 50 MHz MIG bitstream routes and meets timing, Vivado recognizes one MIG core, BIOS DDR memtest passes after MIG-ready CPU reset gating, untraced BIOS `memspeed()` completes (`Write speed: 18.2MiB/s`, `Read speed: 12.2MiB/s` on the 2026-06-04 SQ=4 run), and BIOS reaches `litex>`. The same profile is now the default for `linux-fpga-*` targets. The fully enabled `default` preset still fails hardware smoke: dual issue/commit fail very early, and the old single-issue/no-L2/SQ=8 A/B hangs at `Memspeed...` unless slowed by verbose trace. 230400 baud safe serialboot can transfer the full ~32 MiB Linux FPGA image but is slow; 460800 and 1 Mbps UART builds produce clean or partially readable banners but are not reliable for SFL upload on the current board/host link. If the full image reaches `stage0: jumping to OpenSBI` but no OpenSBI banner appears, the next suspects are the OpenSBI link address, DTB contents, or the prebuilt QEMU-oriented kernel config.

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

Raptor's microarchitecture preset is selected separately with `RAPT_CONFIG=<name>`, which maps to `configs/<name>/rapt_config.svh` during RTL packing. The LiteX CPU `VARIANT` still selects SoC/software defaults, but Linux variants also add RTL preprocessor defines through `RAPT_PACK_VFLAGS` (`-DRAPT_LINUX`, and `-DRAPT_RV64` for `linux64`).

| Variant    | Use Case                                |
| ---------- | --------------------------------------- |
| `standard` | Sim & FPGA (BIOS-only, no Linux image)  |
| `linux`    | RV32 Linux/OpenSBI boot                 |
| `linux64`  | RV64 experiments                        |

Select variant directly with `make sim VARIANT=linux`, or use convenience targets such as `make linux` and `make linux-fpga-build`.

## Commands

| Command                           | Description                                        |
| --------------------------------- | -------------------------------------------------- |
| `make setup`                      | Install LiteX + register Raptor CPU                |
| `make pack`                       | Pack RTL into single .sv                           |
| `make sim`                        | Verilator simulation (LiteX BIOS by default)       |
| `make sim-trace`                  | Simulation with FST waveform                       |
| `make coremark`                   | Build + run CoreMark in sim                        |
| `make linux`                      | Build + run Linux payload in sim                   |
| `make linux-fpga-build`           | Build KU15P Linux variant MIG bitstream            |
| `make linux-fpga-load`            | Build if needed, then load KU15P Linux bitstream   |
| `make linux-fpga-load-only`       | Load existing KU15P Linux bitstream over JTAG      |
| `make linux-fpga-smoke-img`       | Build tiny stage0-only KU15P smoke image           |
| `make linux-fpga-smoke-upload`    | Upload tiny stage0-only smoke image                |
| `make linux-fpga-smoke`           | From-scratch build/load, then smoke upload         |
| `make linux-fpga-upload`          | Upload stage0+OpenSBI+DTB through BIOS serialboot  |
| `make firmware-linux-fpga`        | Build stage0+OpenSBI+DTB image (no upload)         |
| `make linux-fpga-opensbi-img`     | Build stage0+standalone OpenSBI+DTB image          |
| `make linux-fpga-opensbi-upload`  | Upload standalone OpenSBI through BIOS serialboot  |
| `make linux-fpga-upload-bin`      | Upload raw flat payload through Linux/MIG BIOS     |
| `make linux-fpga-coremark-upload` | CoreMark through Linux/MIG BIOS serialboot         |
| `make linux-fpga-main-upload`     | Main RAM FPGA shell through Linux/MIG BIOS         |
| `make linux-fpga-app-upload`      | LiteX-native app bin through Linux/MIG BIOS        |
| `make linux-fpga-console`         | Open Linux/MIG FPGA UART console                   |
| `make linux-fpga-tinyos-prepare`  | Build egos/xv6 TinyOS artifacts for checks         |
| `make linux-fpga-tinyos-check`    | Explain egos/xv6 FPGA serialboot requirements      |
| `make linux-fpga-egos-prepare`    | Build `egos.bin` and `disk.img`                    |
| `make linux-fpga-egos-upload`     | Prepare egos, then guard or force raw upload       |
| `make linux-fpga-xv6-prepare`     | Build xv6 `kernel.bin` and `fs.img`                |
| `make linux-fpga-xv6-upload`      | Prepare xv6, then refuse current RV32 bitstream    |
| `make linux-fpga-flash`           | Flash KU15P Linux variant bitstream to QSPI        |
| `make fpga-build`                 | Build the selected FPGA board bitstream            |
| `make fpga-load`                  | Load the selected FPGA board volatile bitstream    |
| `make fpga-flash`                 | Flash the selected FPGA board persistent bitstream |
| `make fpga-console`               | Open the selected FPGA board UART console          |
| `make fpga-upload`                | Upload firmware to main_ram via BIOS serialboot    |
| `make main-fpga`                  | Build + upload FPGA main firmware                  |
| `make irqtest-fpga`               | Build + upload minimal IRQ test firmware           |
| `make coremark-fpga`              | CoreMark to FPGA main_ram via serialboot           |
| `make app-llm-infer`              | app/ LLM inference benchmark in LiteX sim          |
| `make app-llm-infer-fpga`         | app/ LLM benchmark to FPGA main_ram via serialboot |
| `make clean`                      | Remove build artifacts                             |
| `make help`                       | Show all targets                                   |

## FPGA Firmware Upload (via BIOS serialboot)

The `main-fpga`, `irqtest-fpga`, `coremark-fpga`, and `app-llm-*-fpga` targets enable rapid firmware iteration on supported FPGA boards without rebuilding the FPGA bitstream. Firmware is compiled to main_ram (@ 0x80000000) and uploaded via BIOS serialboot.

**Prerequisites:**
1. Loaded or flashed BIOS bitstream: `make fpga FPGA_BOARD=mlk_cu07_ku15p BOOT_MODE=bios RAPT_CONFIG=small`
2. `INTEGRATED_MAIN_RAM_SIZE > 0` in the bitstream (default 512 KB)
3. UART connected @ 115200 baud

Uploads use `litex_term --safe` by default for reliable SFL transfers on Raptor hardware. Set `SERIALBOOT_SAFE=0` to re-enable litex_term's optimized multi-frame upload mode when debugging throughput.

**Usage:**
```bash
# Build + upload main interactive shell (includes donut, primes, memtest, etc.)
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload minimal IRQ test firmware
make irqtest-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Upload CoreMark and save the serial log
make coremark-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 COREMARK_ITERATIONS=1000 \
    2>&1 | tee /tmp/raptor-ku15p-coremark.log

# Upload RLLMBench payloads
make app-llm-ops-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
make app-llm-infer-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0
make app-llm-train-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0

# Explicit UART port (if auto-detection fails)
make main-fpga FPGA_BOARD=mlk_cu07_ku15p UART_PORT=/dev/ttyUSB0 UART_BAUD=115200

# Build only (no upload)
make main-fpga-build
```

If `litex_term` prints that the BIOS serialboot prompt timed out, press the board reset button and keep the same upload command running.

OpenSBI/Linux is supported in the LiteX simulation path (`make linux`) and has an experimental KU15P MIG FPGA path (`make linux-fpga-*`). The default verified day-to-day FPGA smoke path remains the 512 KiB integrated-RAM BIOS/CoreMark flow above.

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
make linux-fpga-app-upload APP_FPGA_BIN=/path/to/app.bin UART_PORT=/dev/ttyUSB0 UART_BAUD=230400
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

## Environment Variables

| Variable                   | Description                                    | Default                                     |
| -------------------------- | ---------------------------------------------- | ------------------------------------------- |
| `RAPTOR_HOME`              | Root of raptor-chip repo                       | Auto-detected                               |
| `VARIANT`                  | CPU variant (`standard`, `linux`, `linux64`)   | `standard`                                  |
| `SYS_CLK`                  | System clock frequency (Hz)                    | `10000000`                                  |
| `FPGA_BOARD`               | FPGA board target                              | `tang_mega_138k_pro`                        |
| `BOOT_MODE`                | FPGA boot ROM source                           | `custom`                                    |
| `RAPT_CONFIG`              | RTL config preset                              | `middle` for FPGA goals, otherwise `default` |
| `INTEGRATED_MAIN_RAM_SIZE` | FPGA main RAM size at `0x80000000`             | `0x80000`                                   |
| `WITH_LITEDRAM`            | Use external LiteDRAM/DDR4 for FPGA main RAM   | `0`                                         |
| `LITEDRAM_SIZE`            | Mapped external LiteDRAM main RAM size         | `0x40000000`                                |
| `WITH_MIG`                 | Use external Xilinx DDR4 MIG for FPGA main RAM | `0`                                         |
| `MIG_SIZE`                 | Mapped external MIG main RAM size              | `0x40000000`                                |
| `LINUX_FPGA_SYS_CLK`       | Linux FPGA bitstream system clock in Hz        | `50000000`                                  |
| `LINUX_FPGA_RAM_SIZE`      | Linux FPGA DDR window advertised in DTB        | `MIG_SIZE`                                  |
| `LINUX_FPGA_DTB_ADDR`      | Runtime DTB address passed to OpenSBI          | `0x83f00000`                                |
| `UART_PORT`                | FPGA UART device                               | Auto-detected; KU15P prefers `/dev/ttyUSB0` |
| `UART_BAUD`                | FPGA UART baud rate                            | `115200`                                    |
| `SERIALBOOT_SAFE`          | Use `litex_term --safe` for uploads            | `1`                                         |
| `GOWIN_APP`                | Gowin IDE app bundle path                      | Auto-detected on macOS                      |
| `RLLMBENCH_TIMEBASE_HZ`    | RLLMBench `time` CSR frequency in Hz           | `1000000`                                   |
| `RLLMBENCH_CORE_CLOCK_MHZ` | Core clock for score/MHz reports               | `SYS_CLK/1e6`                               |
| `EXTRA_FLAGS`              | Extra flags for the selected LiteX target script | (empty)                                   |
