# Simulator builds and configuration

From the repository root, `make run-rv32` and `make run-rv64` configure, build, and run the built-in smoke program with difftest. Use `IMG=/absolute/path.bin` for another program. `NPC_DEFCONFIG` defaults to `o2_difftest_defconfig`.

## Independent builds

`BUILD_ROOT` selects the output root (default `sim/build`); `BUILD_PROFILE` selects a named configuration workspace (default: the HDL preset name). RV32 and RV64 configurations are separate even within one profile:

```text
sim/build/<profile>/
  config-riscv32/.config
  config-riscv32/include/generated/autoconf.h
  config-riscv64/.config
  config-riscv64/include/generated/autoconf.h
  obj_dir-riscv32-<options-key>/...
  obj_dir-riscv64-<options-key>/...
  riscv32-npc-sim -> selected cached executable
  riscv64-npc-sim -> selected cached executable
  mrom/...
  run-riscv32/data/...
  run-riscv64/data/...
```

For example, after preparing both NEMU reference libraries, these simulator builds/runs can execute concurrently:

```sh
make run-rv32 BUILD_PROFILE=smoke32 BUILD_ROOT=/tmp/raptor-sim-builds &
make run-rv64 BUILD_PROFILE=smoke64 BUILD_ROOT=/tmp/raptor-sim-builds &
wait
```

Use **different profiles for different Kconfig variants of the same XLEN**. For manual configuration, use the same profile and VFLAGS on both commands:

```sh
make -C sim o2_defconfig BUILD_PROFILE=plain64 VFLAGS=-DRAPT_RV64
make -C sim all BUILD_PROFILE=plain64 VFLAGS=-DRAPT_RV64
```

`menuconfig`, `savedefconfig`, and `print-config` operate on that selected profile/XLEN. Configure and build in separate Make invocations; root convenience targets already do this. Legacy `sim/.config` and `sim/include/generated` are not implicitly imported, rewritten, or deleted. Reapply a defconfig or use `menuconfig` to initialize a new workspace.

## Cache and cleanup

Kconfig contents and effective compiler/Verilator options select the model cache directory. Switching options preserves older models; switching back reuses an up-to-date model. Reapplying an unchanged defconfig preserves generated header timestamps. Source changes still use normal Make dependency rebuilding. The conventional executable pathname is published atomically; an already running executable is not overwritten in place.

`make -C sim clean BUILD_PROFILE=<name>` explicitly removes only that profile. Do not clean a profile while another process is using it. Ordinary builds no longer delete configuration stamps or entire model directories at parse time. `make help` is read-only; `make -n all` may still generate a missing included Kconfig file, but only in its selected build directory.

`run` and `run_log` execute in the selected `run-riscv*` directory. `IMG`, `DISK`, `SDCARD`, and MROM paths are resolved before changing directories. Use absolute paths for file arguments embedded directly in `ARGS`.

## DFF-only static timing analysis

`make sta` retains the SRAM-macro flow. From the repository root (or with `make -C sim`), use the memory-model parameter for behavioral memories expanded into standard-cell flip-flops and selection logic:

```sh
make sta MEMORY=dff
make sta MEMORY=dff RAPT_CONFIG=small STA_PLATFORM=nangate45 CLK_FREQ_MHZ=100
make sta MEMORY=dff XLEN=64 RAPT_CONFIG=default STA_PLATFORM=sky130 CLK_FREQ_MHZ=50
make sta-detail MEMORY=dff RAPT_CONFIG=small STA_PLATFORM=asap7 VFLAGS=-DRAPT_RV64
make sta-check MEMORY=dff RAPT_CONFIG=default VFLAGS=-DRAPT_RV64
```

`sta-check MEMORY=dff` only preprocesses and elaborates the full core; it does not run technology mapping or STA. The SRAM-macro define is explicitly disabled, and no extra macro Liberty or blackbox files are supplied to the backend. Standard-cell timing still comes from the selected PDK. Supported in-tree platforms are `nangate45`, `asap7`, and `sky130hd` (`sky130` is an alias). A proprietary PDK such as TSMC 22 nm requires licensed libraries and a corresponding platform configuration in the `YOSYS_OPENSTA` backend; these targets do not provide that PDK.

Outputs are isolated by build profile, HDL preset, XLEN, PDK, and frequency:

```text
sim/build/<profile>/sta/dff/<preset>/<riscv32|riscv64>/<platform>/<frequency>MHz/
  rtl/rapt_pack.sv
  rtl/pack-synth-check.log
  backend/result/<platform>-rapt-<frequency>MHz/...
```

Use an absolute `BUILD_ROOT` or `STA_WORK_DIR` to relocate outputs. Use distinct directories for concurrent runs with other differing `VFLAGS`/RTL inputs. Backend scripts and libraries are linked into the isolated workspace; output does not overwrite the backend's shared SRAM reports. Prepare tools and PDKs before running: the DFF targets do not fetch, update, or install dependencies. Large DFF caches substantially increase synthesis cost. These are pre-layout STA results, not SRAM-macro estimates or post-route signoff.

## Remaining shared resources and checks

This isolates the **simulator**, not every external tool. NEMU's legacy config and some software/Chisel generation workflows still have shared state. The default sim run refreshes its NEMU reference. For parallel runs, first build references sequentially, then pass explicit `DIFF_REF_SO="-d /absolute/reference.so"` paths to bypass reference rebuilding. Do not concurrently reconfigure NEMU. Likewise, do not regenerate Chisel decoders while building simulators that read them. Concurrent incompatible configurations must not share the same profile/XLEN directory.

`make -C verify sim-build-isolation-check` checks real Kconfig generation, parallel profile/XLEN isolation, idempotence, cache switching, read-only help, and profile-local cleanup. Its cache tests use a fake compiler; they do not replace an actual `make run-rv32` smoke test. Directed Verilator checks also retain option-keyed object caches instead of deleting the whole test directory on every run. Explicit clean targets remain available.
