# Coarse CPU out-of-context synthesis

This flow exports fixed-width ports for `rapt_frontend`, `rapt_backend`, `rapt_l1i` and `rapt_l1d`, synthesizes each block to a Vivado checkpoint, and links those checkpoints into `rapt`. Rename, checkpoints, operand storage, issue, completion, LSU/SQ and retirement stay together inside the backend. The adapters add no registers. Cross-block timing still has to close after the blocks are linked.

The exporter consumes a **preprocessed, fixed-preset** RTL pack. It obtains interface field widths and unpacked-array sizes from Verilator, then emits ordinary vector ports. It supports the declarations used by these four modules; it is not a general SystemVerilog parser. Synthesis pragmas in comments are rejected because dependency hashes ignore comments; use SystemVerilog attributes. Re-export after changing the preset, XLEN, parameter defaults, interfaces or RTL. Use `--parameter BLOCK.PARAM=INTEGER` when the top-level hierarchy overrides a block's module default without changing its ports. The specialization is included in the dependency hash and generated bridge checks reject a different top-level value.

## Export and build

From the repository root, with generated decoders already available (`make verilog` when needed):

```sh
task_tmp=$(mktemp -d /tmp/raptor-chip-ooc.XXXXXX)
python3 fpga/litex/scripts/isolated_pack.py \
  --repo "$PWD" --root "$task_tmp/pack" --config default \
  --flags='-DRAPT_RV64 -DRAPT_FPGA_DSP=1'
# Use the rapt_pack.sv path printed by the command above.
python3 fpga/ooc/export.py --parameter rapt_l1d.WriteBack=1 \
  /absolute/path/to/rapt_pack.sv "$task_tmp/rv64"
python3 fpga/ooc/build.py "$task_tmp/rv64"
python3 fpga/ooc/build.py "$task_tmp/rv64" --merge
# Optional: place and route the linked CPU, with the same block constraints.
python3 fpga/ooc/build.py "$task_tmp/rv64" --merge --route
```

The default hierarchy selects the write-through L1D through `L1dWriteBack=0`; pass an explicit parameter override to evaluate the optional write-back implementation. For RV32, omit `-DRAPT_RV64` and use a separate output directory. The default part is `xcku15p-ffva1156-2-e`, with a 20 ns clock and 2 ns input/output budgets. `--part` and `--period` select another device or clock budget. These are CPU OOC constraints, not board constraints or a replacement for full-SoC implementation. The flow requires Verilator, a C++ compiler, Python and Vivado. It does not rewrite `sim/.config`, install dependencies or program a board.

## Synthesis runtime exploration

For faster iteration on a large partition, `--no-timing-driven` disables Vivado's synthesis timing optimization. It retains the clock and IO constraints for reports and leaves merge/place/route behavior unchanged. This is a runtime/area tradeoff; check the resulting timing before using it for implementation.

```sh
python3 fpga/ooc/build.py "$task_tmp/rv64" --no-timing-driven
python3 fpga/ooc/build.py "$task_tmp/rv64" --no-timing-driven --merge
```

Use the same mode for build and merge. Switching modes changes the frozen Tcl fingerprint and invalidates the partition cache; a separate export directory can preserve results from both modes. The default remains timing-driven synthesis.

## Rebuild one block

After editing RTL, regenerate the pack and export into the same OOC directory. Then select the affected block:

```sh
python3 fpga/ooc/export.py --parameter rapt_l1d.WriteBack=1 \
  /absolute/path/to/new/rapt_pack.sv "$task_tmp/rv64"
python3 fpga/ooc/build.py "$task_tmp/rv64" --block rapt_backend
python3 fpga/ooc/build.py "$task_tmp/rv64" --merge
```

Each checkpoint stamp records the dependency closure, shared package/interface text, adapter, Vivado version, part, constraints script, clock period and DCP hash. Unchanged blocks can be reused. Shared type/configuration changes may invalidate all blocks. `--merge` rejects missing or stale checkpoints and checks that exactly one instance of each partition was linked with no unresolved black boxes. Export and synthesis serialize access to each output directory.

`manifest.json` records the pack fingerprint, widths, parameters, dependencies and generated-file hashes. `partitions.sv` contains the OOC implementations; `linked.sv` contains the same adapters with implementations for full RTL lint or simulation; `blackboxes.sv` is the parent-synthesis input. Each block produces a `<block>_timed.dcp` with its standalone budgets, `<block>.dcp` with timing constraints cleared for linking, utilization/timing reports and a log. Merge produces `merge.dcp` and reports. Treat pre-route timing and isolated utilization as local evidence: checkpoint boundaries restrict cross-module optimization, and placement/routing can change both timing and resource use.

## Default RV64 FPGA evaluation

The following result was measured on 2026-09-22 with Vivado 2025.2, the `default` preset,
`-DRAPT_RV64 -DRAPT_FPGA_DSP=1`, `rapt_l1d.WriteBack=1`, part
`xcku15p-ffva1156-2-e`, and a 20 ns clock. The partitions used
`--no-timing-driven`; merge, placement, and routing retained their normal timing-driven behavior.

| Scope | CLB LUTs | CLB registers | BRAM tiles | DSPs | Pre-route WNS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frontend | 12,858 (2.46%) | 5,327 (0.51%) | 0 | 0 | +11.018 ns |
| Backend | 257,031 (49.17%) | 88,020 (8.42%) | 0 | 27 (1.37%) | +6.460 ns |
| L1I | 32,658 (6.25%) | 9,673 (0.93%) | 0 | 0 | +10.330 ns |
| L1D write-back | 42,607 (8.15%) | 21,109 (2.02%) | 32 (3.25%) | 0 | +9.674 ns |
| Linked CPU after `opt_design` | 346,406 (66.27%) | 123,940 (11.86%) | 32 (3.25%) | 27 (1.37%) | +6.034 ns |

All four partitions and the linked pre-route CPU completed with no errors or critical warnings.
Placement completed, but routing did not converge. Vivado estimated global/short congestion level 6
and timing congestion level 7; it warns that levels 5 and above can affect routability and timing.
Global route iteration 1 reduced reported node overlaps from 536,938 to 4,344, but took 1 hour
44 minutes and reported WNS -3.343 ns and TNS -31,289.860 ns. Iteration 2 reopened at 473,904
overlaps. The run was stopped after available memory fell to about 8 GiB and swap use began to
increase. No final route-status report was produced.

This result does not demonstrate 50 MHz closure. It shows that the default RV64 CPU fits the raw
KU15P resource capacity and can be placed, while the present OOC partitioning and implementation
settings have severe routing congestion. The OOC top also has no board pin placement or
`HD.PARTPIN_LOCS`, so top-level port timing and partial routes are not sign-off quality. Use a full
board implementation, complete routing, and final timing/DRC reports before claiming an FPGA
frequency.

## Checks

```sh
python3 -m unittest discover -s fpga/ooc -p test_ooc.py
# Include the actual Vivado constraint/merge preflight:
RAPT_OOC_VIVADO_TEST=1 python3 -m unittest discover -s fpga/ooc -p test_ooc.py
verilator --lint-only --top-module rapt -Wno-fatal "$task_tmp/rv64/linked.sv"
```

The opt-in Vivado test synthesizes four small partitions and links their DCPs, checking clock and IO-delay coverage and rejecting critical warnings. The default unit tests exercise actual Verilator adapter wiring and use a fake Vivado only to test cache invalidation and stale-checkpoint rejection. They do not establish FPGA resource use, routability or timing closure. The lint command allows warnings; inspect its log separately from functional and physical tests.

Partition clock and IO budgets are read with `read_xdc -mode out_of_context`. The flow also clears timing constraints before writing the link checkpoint; standalone constraints remain in the separate timed checkpoint and reports. After linking, it reloads the parent timing constraints. For the distinction between standalone and parent constraints, see [AMD UG903: Out-of-Context Constraints](https://docs.amd.com/r/2025.2-English/ug903-vivado-using-constraints/Out-of-Context-Constraints). The merge registers the parent and child checkpoints, then uses `link_design`; `parent_synth.dcp` is retained for diagnosing link failures.
