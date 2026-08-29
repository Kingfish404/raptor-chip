# sim/sram — OpenRAM integration

Build infrastructure that compiles real SRAM macros via [OpenRAM](https://github.com/VLSIDA/OpenRAM)
for the cache data arrays under [hdl/memory/](../../hdl/memory/), and wires the resulting
Verilog blackboxes + Liberty timing into the Yosys / OpenSTA flow used by
[sim/Makefile](../Makefile) `sta`.

## Why

The default [hdl/memory/rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv) uses the
canonical clocked-read single-port RAM template. FPGA synthesis can infer block RAM from
that model. Generic ASIC synthesis may still lower it to flops unless the technology flow
maps inferred memories, so the OpenRAM path replaces it with characterised SRAM macros:

- **Realistic area** (6T SRAM bitcell ≈ 50–100× denser than a flop)
- **Realistic timing** (single-cycle synchronous read with `t_CQ` from `.lib`)
- **Realistic power** (active vs leakage modelled per macro)

Compare [docs-ref/plan/plan.sram.md](../../docs-ref/plan/plan.sram.md) §4 and
[docs-ref/uarch.sram.md](../../docs-ref/uarch.sram.md) §6.

## What gets generated

For the default config (see [hdl/configs/default/rapt_config.svh](../../hdl/configs/default/rapt_config.svh)):

| Shape (depth × width) | Use site                        | Instances                                    |
| --------------------- | ------------------------------- | -------------------------------------------- |
| `32 × 32`             | `rapt_l1i.sv` data banks        | `L1I_N_WAYS × L1I_LINE_SIZE` = `2 × 16` = 32 |
| `16 × 32`             | `rapt_l1d.sv` data banks (RV32) | `L1D_N_WAYS × subarrays/way` = `2 × 4` = 8   |
| `16 × 64`             | `rapt_l1d.sv` data banks (RV64) | `2 × 4` = 8                                  |

All macros are **single-port (1RW)** since the RTL was migrated to
[rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv): the cache controllers
time-multiplex reads and writes onto the shared port. Legacy 1R1W configs
are kept for reference and can be built with `make PORTS=1r1w`.

The RTL and OpenRAM models share the same port contract: writes occur on the
rising edge, reads register `rdata` on the rising edge, and `rdata` holds during
disabled and write cycles.

Each shape becomes one OpenRAM-compiled macro under
`build/<PLATFORM>/macro/<openram_name>/` with the standard OpenRAM artefacts:

- `<name>.v` — behavioural + functional Verilog (also serves as blackbox for synth)
- `<name>.lib` — Liberty timing/power for OpenSTA
- `<name>.lef` — abstract LEF for PnR
- `<name>.gds` — physical layout
- `<name>.sp` — SPICE netlist

## Workflow

```shell
# 1. one-off: install OpenRAM dependencies (Docker is recommended)
make -C sim/sram setup

# 2. generate macros for default config (sky130 PDK)
make -C sim/sram all PLATFORM=sky130

# 3. run STA with real SRAM macros in the loop
make -C sim sta-sram STA_PLATFORM=sky130hd CLK_FREQ_MHZ=50
```

The `sta-sram` target defines `RAPT_USE_SRAM_MACRO`, so
[rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv) instantiates the OpenRAM blackbox
declared in [wrappers/rapt_sram_blackbox.v](wrappers/rapt_sram_blackbox.v) instead of the
flop array. Yosys then leaves the macros as blackboxes; OpenSTA picks up the OpenRAM-produced
`.lib` files and reports real cache timing.

Shapes without a generated OpenRAM macro, such as an enabled large L2 configuration,
fall back to the synchronous inference template instead of failing elaboration. Their
timing and area are only technology-accurate after the ASIC flow maps the inferred memory
or a matching OpenRAM shape is added.

## Adding a new shape

1. Drop a Python config under [configs/](configs/) (use `rapt_sram_32x32_1rw_sky130.py` as a
   template — set `word_size`, `num_words`, `tech_name`).
2. Add a matching blackbox stub to [wrappers/rapt_sram_blackbox.v](wrappers/rapt_sram_blackbox.v).
3. Extend the generate-if cascade in
   [hdl/memory/rapt_sram_1rw.sv](../../hdl/memory/rapt_sram_1rw.sv) under
   `` `ifdef RAPT_USE_SRAM_MACRO ``.
4. `make -C sim/sram all` to compile the new macro.
