# nsim/tb — DPI-free SystemVerilog testbench

A self-contained, DPI-free SystemVerilog harness for the Raptor tapeout chip. It replaces the C++/DPI memory model used by the main `nsim` Verilator flow (`nsim/csrc/mem/*.cc`, `nsim/rtl/rapt_npc_soc.sv`) with a pure-SystemVerilog AXI4 slave + MMIO model, so the *same* harness runs under commercial simulators (VCS / Xcelium / Questa) and Verilator, in both RTL and gate-level (post-layout) modes. Functionality and the MMIO map are kept byte-for-byte consistent with the existing `nsim`.

## Files

- [rapt_tb_top.sv](rapt_tb_top.sv) — testbench top: clock/reset, DUT instantiation, image loading, termination, watchdog, optional waveform/SDF.
- [rapt_tb_mem.sv](rapt_tb_mem.sv) — pure-SV AXI4 slave memory + MMIO model (the *external* memory that sits on the chip's rnp bus after `rnp2axi`).
- [Makefile](Makefile) — builds/runs the harness under Verilator, VCS, Xcelium, and Questa, in RTL or gate-level mode.

## The three flows

1. **RTL Verilator alignment** (`make verilator`) — cross-checks the RTL against the C++ `nsim`. Termination is by the AM `ebreak` GOOD/BAD TRAP convention (`RAPT_TB_EBREAK_HALT`), matching `nsim`.
2. **Commercial RTL** (`make vcs` / `make xrun` / `make vsim`) — same RTL, same plusargs, under Synopsys VCS, Cadence Xcelium, or Siemens Questa.
3. **Gate-level / post-sim** (`make vcs-gls` / `make xrun-gls`) — the `soc_pad` post-layout netlist with SDF back-annotation (`RAPT_TB_GLS` + `RAPT_TB_SDF`). The DUT exposes bit-blasted rnp pad pins. Termination is by the `sifive,test` **finisher** MMIO (0x0010_0000), since the gate netlist has no RTL hierarchy to tap for `ebreak`.

## DUT and bus topology

The chip drives its external memory through the single-word **rnp** interface:

```
rapt (CPU) --AXI--> axi2rnp --rnp pins--> rnp2axi --AXI4--> rapt_tb_mem
            (inside rng_chip / soc_pad)   (rtl_sv/perip/wrap_rnp.sv)
```

- RTL mode (`rng_chip`): vectorised rnp ports.
- Gate-level mode (`soc_pad`): bit-blasted `pad_rnp_*` pins.

CLINT and PLIC live *inside* the chip, so they never appear on this bus; only the regions below reach `rapt_tb_mem`.

## Memory map (kept in sync with `nsim/include/common.h`)

| Region                  | Base          | Notes                                              |
| ----------------------- | ------------- | -------------------------------------------------- |
| `sifive,test` finisher  | `0x0010_0000` | write `0x5555`=PASS, `0x3333`=FAIL, `0x7777`=RESET |
| on-chip SRAM window     | `0x0f00_0000` |                                                    |
| NS16550 serial          | `0x1000_0000` | TX console + LSR/IIR polling                       |
| MROM (reset trampoline) | `0x2000_0000` | `PC_INIT`; jumps to `0x8000_0000`                  |
| FLASH                   | `0x3000_0000` |                                                    |
| PMEM (main memory)      | `0x8000_0000` | program image                                      |
| SDRAM                   | `0xa000_0000` |                                                    |

Storage uses sparse associative byte arrays, so the large PMEM/FLASH windows are not pre-allocated. Reads return the word **aligned down** to the `XLEN/8` boundary (matching the reference `pmem_read`); the chip's LSU/L1 perform sub-word extraction.

## Plusargs

| Plusarg                              | Meaning                                                               |
| ------------------------------------ | --------------------------------------------------------------------- |
| `+IMG=<bin>`                         | program image → PMEM `0x8000_0000`                                    |
| `+MROM=<bin>`                        | reset trampoline → MROM `0x2000_0000` (default: nsim `mrom-data.bin`) |
| `+FLASH=<bin>`                       | flash image → FLASH `0x3000_0000` (optional)                          |
| `+MAX_CYCLES=<n>`                    | watchdog cycle limit (default 100,000,000)                            |
| `+WAVE`                              | enable waveform dump                                                  |
| `+SDF=<file>`                        | SDF file for gate-level timing (implies `RAPT_TB_SDF`)                |
| `+SDF_MTM=MINIMUM\|TYPICAL\|MAXIMUM` | SDF corner (default `MAXIMUM`)                                        |

## Make variables

| Variable          | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| `IMG`             | program `.bin` → PMEM                                          |
| `MROM`            | trampoline `.bin` → MROM (default: nsim `mrom-data.bin`)       |
| `FLASH`           | flash `.bin` → FLASH                                           |
| `MAX_CYCLES`      | watchdog limit                                                 |
| `WAVE=1`          | enable waveform dump (`--trace-fst` under Verilator)           |
| `SDF` / `SDF_MTM` | gate-level SDF file and corner                                 |
| `NETLIST`         | gate netlist `.v` for `*-gls` targets                          |
| `LIBS`            | space-separated stdcell/SRAM/PAD simulation models (`-v` each) |
| `RAPT_CONFIG`     | config preset (default `small`)                                |

## Configuration requirement: single-beat / no-L2

The rnp interface and its `axi2rnp`/`rnp2axi` adapters carry exactly **one word per transaction** (the adapters hardwire `arlen=0`, `arsize=2`, `arburst=0`). The chip's internal AXI master must therefore **never issue a burst**. This requires:

- `-DRAPT_SOC` — the single-outstanding, ysyxSoC-style bus (added automatically by the Makefile).
- a config **without** the L2 cache (`RAPT_L2_EN`). The `default` and `large` presets enable `RAPT_L2_EN` (16-beat line fills) and are **not** compatible with the rnp interface. The Makefile defaults to the no-L2 `small` preset.

If you build with an L2-enabled config the chip will issue `arlen=15` bursts, the single-word host returns `rlast` after the first beat, and the chip deadlocks waiting for the remaining beats.

The rnp data path is 32-bit, so the harness is **RV32 only**. `ISA64=1` is rejected with an error; use the AXI-based `nsim` flow for RV64.

## Quick start

```shell
# RTL alignment under Verilator (requires Verilator >= 5: --binary --timing)
make verilator IMG=../../abstract-machine/app/am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin

# Commercial RTL
make vcs   IMG=foo.bin
make xrun  IMG=foo.bin
make vsim  IMG=foo.bin

# Gate-level / post-sim (you supply the netlist and vendor sim libs)
make vcs-gls IMG=foo.bin \
     NETLIST=/path/to/soc_pad.v \
     LIBS="/path/to/stdcell.v /path/to/sram.v /path/to/pad.v" \
     SDF=/path/to/soc_pad.sdf SDF_MTM=MAXIMUM

# Dump the RTL filelist (incdirs + sources) for an external tool
make filelist   # -> rtl.f
```

For gate-level runs you must provide your own `NETLIST` (the `soc_pad` post-layout netlist) and the matching foundry `LIBS` (stdcell / SRAM / PAD simulation models); these are not part of this repository.

## Termination

- **RTL alignment** (`verilator`): the AM `npc` target commits an `ebreak`; the harness taps `ebreak_a`/`ebreak_b` in the commit unit (`RAPT_TB_EBREAK_HALT`) and reports `HIT GOOD TRAP` / `HIT BAD TRAP`, matching `nsim`'s DPI `npc_exu_ebreak` hook.
- **Gate-level / commercial** (`RAPT_TB_GLS`): no RTL hierarchy is available, so termination is driven by the `sifive,test` finisher MMIO at `0x0010_0000` (`FIN_PASS`/`FIN_FAIL`).
- In all flows a watchdog (`+MAX_CYCLES`) `$fatal`s on timeout.
