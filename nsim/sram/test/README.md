# SRAM integration tests

These tests validate that the four moving parts of the OpenRAM SRAM
integration stay in sync, and that the STA evaluation actually exercises
the macro pins:

| Layer                 | File                                           |
| --------------------- | ---------------------------------------------- |
| Macro shape configs   | `nsim/sram/configs/rapt_sram_*_1r1w_sky130.py` |
| Yosys blackbox decls  | `nsim/sram/wrappers/rapt_sram_blackbox.v`      |
| Stub `.lib` generator | `nsim/sram/scripts/gen_stub_lib.py`            |
| RTL instantiation     | `rtl_sv/memory/rapt_sram_1r1w.sv`              |

If any of these drift (e.g. port width change in the blackbox without a
matching Liberty update) STA will either fail to elaborate or silently
mis-map the pins. The tests catch that early.

## Targets

```
make -C nsim/sram/test           # static checks (default)
make -C nsim/sram/test sta-smoke # end-to-end STA flow (opt-in)
make -C nsim/sram/test clean
```

## What `make check` verifies (no external tools)

1. **Configs** — Each macro shape in `SHAPES` has a `rapt_sram_*_1r1w_sky130.py`
   declaring the right `word_size` / `num_words` / `write_size`.
2. **Blackbox V** — Each shape has one `(* blackbox *) module` whose port
   widths match the shape (addr = ⌈log₂(depth)⌉, wmask = width/write_size).
3. **RTL macro path** — The `RAPT_USE_SRAM_MACRO` branch in
   `rapt_sram_1r1w.sv` instantiates each shape with all ten ports
   (`clk0/csb0/web0/wmask0/addr0/din0/clk1/csb1/addr1/dout1`) connected,
   under the correct `DEPTH=={D} && DATA_WIDTH=={W}` guard, and falls
   back to `$fatal` on unsupported shapes. The write-first bypass mux
   (`bypass_en_r`, `wdata_r`) is present (since OpenRAM is read-first).
4. **Stub Liberty** — `gen_stub_lib.py` produces parseable `.lib` files
   with: `is_macro_cell:true`, `dont_touch:true`, all required pins/buses
   at the right widths, ≥6 setup arcs and ≥6 hold arcs on the inputs,
   and a `cell_rise`/`cell_fall` arc from `clk1` to `dout1`. Area is
   positive and within a factor of two of `depth × width × 2.0 × 1.3`.
5. **Cross-consistency** — The set of macro names declared in the
   blackbox V matches `SHAPES` exactly (no orphans, no missing).

## What `make sta-smoke` verifies (needs yosys + slang + OpenSTA)

Generates stubs if needed, preprocesses `fixtures/rapt_sram_test_top.sv`
(a 1-instance wrapper around the L1I 32×32 shape), and drives the
`third_party/yosys-opensta` flow with `EXTRA_LIB_FILES` /
`EXTRA_BLACKBOX_V_FILES` set to the stub artefacts. Then it asserts:

- Yosys produced a synthesised netlist.
- The macro instance (`rapt_openram_1r1w_32x32`) survives synthesis
  (i.e. the blackbox was preserved, not flattened).
- The OpenSTA timing report is non-empty and references the macro's
  `clk0`/`clk1` pins (proving the `.lib` arcs were actually used).

If `yosys-slang` is missing on the host (e.g. on macOS without the
plugin) the smoke target exits with a clear `FAIL: yosys-slang plugin
not installed` message. Run the smoke target inside the colima VM or a
container where slang is available.

## CI hookup

`make check` here is fast and has no external dependencies, so it is
suitable for the default CI lane. `sta-smoke` is gated on the heavier
toolchain and should run on a separate lane (or nightly).
