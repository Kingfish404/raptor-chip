# nsim/sram — OpenRAM integration

Build infrastructure that compiles real SRAM macros via [OpenRAM](https://github.com/VLSIDA/OpenRAM)
for the cache data arrays under [rtl_sv/memory/](../../rtl_sv/memory/), and wires the resulting
Verilog blackboxes + Liberty timing into the Yosys / OpenSTA flow used by
[nsim/Makefile](../Makefile) `sta`.

## Why

The default [rtl_sv/memory/rapt_sram_1r1w.sv](../../rtl_sv/memory/rapt_sram_1r1w.sv) is a
behavioural flop-array model. Yosys synthesises it to D flip-flop + mux trees, which makes
the cache data arrays dominate area and inflate `WNS/TNS` to numbers that bear no resemblance
to a real chip. Replacing them with characterised SRAM macros gives:

- **Realistic area** (6T SRAM bitcell ≈ 50–100× denser than a flop)
- **Realistic timing** (single-cycle synchronous read with `t_CQ` from `.lib`)
- **Realistic power** (active vs leakage modelled per macro)

Compare [docs-ref/plan/plan.sram.md](../../docs-ref/plan/plan.sram.md) §4 and
[docs-ref/uarch.sram.md](../../docs-ref/uarch.sram.md) §6.

## What gets generated

For the default config (see [configs/default/rapt_config.svh](../../configs/default/rapt_config.svh)):

| Shape (depth × width) | Use site                        | Instances                                    |
| --------------------- | ------------------------------- | -------------------------------------------- |
| `32 × 32`             | `rapt_l1i.sv` data banks        | `L1I_N_WAYS × L1I_LINE_SIZE` = `2 × 16` = 32 |
| `16 × 32`             | `rapt_l1d.sv` data banks (RV32) | `L1D_N_WAYS × L1D_LINE_SIZE` = `2 × 16` = 32 |
| `16 × 64`             | `rapt_l1d.sv` data banks (RV64) | `2 × 8` = 16                                 |

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
make -C nsim/sram setup

# 2. generate macros for default config (sky130 PDK)
make -C nsim/sram all PLATFORM=sky130

# 3. run STA with real SRAM macros in the loop
make -C nsim sta-sram STA_PLATFORM=sky130hd CLK_FREQ_MHZ=50
```

The `sta-sram` target defines `RAPT_USE_SRAM_MACRO`, so
[rapt_sram_1r1w.sv](../../rtl_sv/memory/rapt_sram_1r1w.sv) instantiates the OpenRAM blackbox
declared in [wrappers/rapt_sram_blackbox.v](wrappers/rapt_sram_blackbox.v) instead of the
flop array. Yosys then leaves the macros as blackboxes; OpenSTA picks up the OpenRAM-produced
`.lib` files and reports real cache timing.

## Adding a new shape

1. Drop a Python config under [configs/](configs/) (use `sram_32x32_1r1w_sky130.py` as a
   template — set `word_size`, `num_words`, `tech_name`).
2. Add a matching blackbox stub to [wrappers/rapt_sram_blackbox.v](wrappers/rapt_sram_blackbox.v).
3. Extend the generate-if cascade in
   [rtl_sv/memory/rapt_sram_1r1w.sv](../../rtl_sv/memory/rapt_sram_1r1w.sv) under
   `` `ifdef RAPT_USE_SRAM_MACRO ``.
4. `make -C nsim/sram all` to compile the new macro.
