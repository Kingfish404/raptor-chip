# sim/sram — OpenRAM integration

Build infrastructure that compiles real SRAM macros via [OpenRAM](https://github.com/VLSIDA/OpenRAM) for the cache data arrays under [hdl/memory/](../../hdl/memory/), and wires the resulting Verilog blackboxes + Liberty timing into the Yosys / OpenSTA flow used by [sim/Makefile](../Makefile) `sta`.

## Why

The default [hdl/memory/rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv) uses the canonical clocked-read single-port RAM template. FPGA synthesis can infer block RAM from that model. Generic ASIC synthesis may still lower it to flops unless the technology flow maps inferred memories, so the OpenRAM path replaces it with characterised SRAM macros:

- **Realistic area** (6T SRAM bitcell ≈ 50–100× denser than a flop)
- **Realistic timing** (single-cycle synchronous read with `t_CQ` from `.lib`)
- **Realistic power** (active vs leakage modelled per macro)

See [SRAM validation](test/README.md) for the current integration and check scope.

## What gets generated

For the default config (see [hdl/configs/default/rapt_config.svh](../../hdl/configs/default/rapt_config.svh)):

| Shape (depth × width) | Use site                        | Instances                                    |
| --------------------- | ------------------------------- | -------------------------------------------- |
| `64 × 32`             | `rapt_l1i.sv` data banks        | `L1I_N_WAYS × L1I_LINE_SIZE` = `4 × 16` = 64 |
| `64 × 128` | `rapt_l1d_data.sv` data subarrays (RV32/RV64) | `L1D_N_WAYS × subarrays/way` = `4 × 4` = 16 |

All macros are **single-port (1RW)** since the RTL was migrated to [rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv): the cache controllers time-multiplex reads and writes onto the shared port. Legacy 1R1W configs are kept for reference; the current Makefile explicitly selects its 1RW config list, so overriding `PORTS` alone does not select a legacy build.

The RTL and OpenRAM models share the same port contract: writes occur on the rising edge, reads register `rdata` on the rising edge, and `rdata` holds during disabled and write cycles.

Each shape becomes one OpenRAM-compiled macro under `build/<PLATFORM>/macro/<openram_name>/` with the standard OpenRAM artefacts:

- `<name>.v` — behavioural + functional Verilog (also serves as blackbox for synth)
- `<name>.lib` — Liberty timing/power for OpenSTA
- `<name>.lef` — abstract LEF for PnR
- `<name>.gds` — physical layout
- `<name>.sp` — SPICE netlist

## Workflow

```shell
# 1. print setup guidance, then install the listed dependencies separately
make -C sim/sram setup

# 2. generate macros for default config (sky130 PDK)
make -C sim/sram all PLATFORM=sky130

# 3. run STA with real SRAM macros in the loop
make -C sim sta MEMORY=sram STA_PLATFORM=sky130hd SRAM_PLATFORM=sky130 CLK_FREQ_MHZ=50
```

The `sta MEMORY=sram` target defines `RAPT_USE_SRAM_MACRO`, so [rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv) instantiates the OpenRAM blackbox declared in [wrappers/rapt_sram_blackbox.v](wrappers/rapt_sram_blackbox.v) instead of the flop array. Yosys then leaves the macros as blackboxes; OpenSTA picks up the OpenRAM-produced `.lib` files and reports real cache timing.

With `RAPT_USE_SRAM_MACRO`, unregistered shapes intentionally fail elaboration through `rapt_unsupported_sram_shape`; add the matching macro contract rather than hiding the error with another blackbox. Without this define, the wrapper uses its synchronous behavioral model. Generated placeholder Liberty files allow flow checks but do not constitute characterized SRAM timing. `sta` automatically calls `sram-ensure-libs`; if any selected macro library is missing, it generates the complete placeholder set in that platform directory. Keep characterized sets complete and separate from placeholder sets. The standalone OpenRAM compiler defaults to `PLATFORM=sky130`, while whole-core STA defaults to NanGate45 and normalizes `sky130` to `sky130hd`; explicitly pass `SRAM_PLATFORM=sky130` to use the compiled Sky130 set above.

`stubs` also writes the `.ok` stamps used by `all`. To replace placeholders with characterized macros, use a fresh platform output directory or deliberately remove the placeholder set with `make -C sim/sram clean PLATFORM=sky130` before running `all PLATFORM=sky130`. Cleaning removes that platform's macro artifacts.

## Adding a new shape

1. Drop a Python config under [configs/](configs/) (use `rapt_sram_32x32_1rw_sky130.py` as a template — set `word_size`, `num_words`, `tech_name`).
2. Add a matching blackbox stub to [wrappers/rapt_sram_blackbox.v](wrappers/rapt_sram_blackbox.v).
3. Extend the generate-if cascade in [hdl/memory/rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv) under `` `ifdef RAPT_USE_SRAM_MACRO ``.
4. Register the shape in `CONFIGS` and `STUB_SHAPES` in `Makefile`, and in `test/test_sram_integration.py`. Run `make -C sim/sram test` to check the registrations and default L1I/L1D geometry.
5. `make -C sim/sram all` to compile the new macro.
