# FE / BE / MEM isolated experiment: initial results

Date: 2026-09-23. RTL base commit: `d2eed1e3`, with uncommitted workspace
changes. Preset `default`, write-through L1D, L2 disabled, Verilator 5.052.
NEMU trace length is 20,000 executed instructions including five reset-ROM
instructions; the measured program window has 19,995 instructions. Image and
trace SHA-256 values are in the generated `*.meta.json` files under
`verify/build/subsystem/` (RV64 under `rv64/`). These results are for this
working tree; old PPA snapshots use other source revisions.

Reproduce the CoreMark RV32 window after building the matching NEMU interpreter:

```sh
make -C verify/subsystem trace TRACE_INSTS=20000
make -C verify/subsystem fe TRACE_INSTS=20000
make -C verify/subsystem be TRACE_INSTS=20000 \
  BE_ARGS='+MAX_INSTS=20000 +MAX_CYCLES=200000'
make -C verify/subsystem mem TRACE_INSTS=20000 \
  MEM_ARGS='+MAX_INSTS=20000 +MAX_MEM=10000 +MAX_CYCLES=200000'
```

For RV64, add `XLEN=64 BUILD_DIR=../../verify/build/subsystem/rv64` to each
command. For CRC32, use the matching `IMG` and `TRACE_PREFIX` values shown in
`verify/subsystem/README.md`. Keep separate build directories for each XLEN.

## Boundaries and coupling

| Composition | Real DUT | Replaced neighbors in the experiment | Coupling retained at the boundary |
| --- | --- | --- | --- |
| FE | `rapt_frontend` | Image-backed ideal L1I, ready-controlled sink and delayed NEMU branch outcome | `ifu_l1i`, decoded `idu_rnu`, commit broadcast, recovery, predictor history |
| BE | `rapt_backend` | Trace-fed real decoders with oracle next PC; real MEM as a data fixture | `idu_rnu`, LSU/L1D, translation, broadcasts, CSR/PMP, writeback drain |
| MEM | `rapt_memory` | Trace-paced I/D request agents and image-backed AXI slave | L1I/L1D, MMU, bus and AXI, CSR/PMP broadcasts, writeback drain |

The three production blocks already meet at named interfaces in `rapt_core`.
They can be compiled and stimulated independently. FE and BE still form a
feedback loop for branch redirect, history restore and rename checkpoints; BE
and MEM still share load/store, translation, fencing and writeback completion.
Their independent measurements therefore describe local capacity under an
explicit environment, not independent replacements for whole-core validation.

## Workload-linked throughput

Default FE sink width and BE commit width are two. FE uses ideal image-backed
fetch, no fetch gaps and four-cycle oracle feedback. BE uses an oracle frontend
that supplies the real decoded instruction and actual next PC. Each row checks
the dynamic retired/delivered PC sequence. MEM replays I requests in trace
order and releases D accesses only after their originating instruction is
supplied; it verifies every retained PMEM load value against NEMU.

| Workload / XLEN | FE uops/cycle | FE width loss | BE committed IPC | BE width loss | MEM I req/cycle | MEM D req/cycle |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CoreMark RV32 | 1.442 | 27.9% | 1.169 | 41.5% | 0.822 | 0.275 |
| Embench CRC32 RV32 | 1.722 | 13.9% | 1.534 | 23.3% | 0.896 | 0.118 |
| CoreMark RV64 | 1.476 | 26.2% | 1.190 | 40.5% | 0.846 | 0.279 |

For RV32 CoreMark, reducing the FE sink to one yields 0.908 uops/cycle; reducing
BE feed width to one over the first 2,000 program instructions yields 0.969
commits/cycle, versus 1.186 with feed width two on the same window. One-cycle
FE feedback yields 1.537 uops/cycle, 6.6% above the four-cycle default.
Inserting two fetch-gap cycles after a response yields 0.538 uops/cycle, 62.7%
below ideal fetch. These knobs expose delivery, feedback and memory-service
sensitivity; the stages do not run concurrently in this experiment.

## External traffic, full 19,995-instruction window

`useful D` counts retained trace load/store payload bytes. `AXI I/D read`
counts completed read beats by the bus IDs used with the default L2-disabled
configuration. `AXI write` counts asserted WSTRB bytes. Refill bytes and
write-through traffic are included; MMIO excluded by the MEM replay is listed
below. The AXI byte rate is total read plus write bytes divided by MEM replay
cycles, not peak physical channel bandwidth.

| Workload / XLEN | MEM cycles | D reads / writes | Useful D read / write B | AXI I / D read B | AXI write B | AXI B/cycle |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CoreMark RV32 | 24,326 | 4,455 / 2,235 | 13,894 / 6,011 | 2,272 / 896 | 6,011 | 0.377 |
| Embench CRC32 RV32 | 22,312 | 1,745 / 888 | 6,845 / 3,546 | 1,576 / 1,344 | 3,546 | 0.290 |
| CoreMark RV64 | 23,624 | 4,360 / 2,225 | 24,422 / 10,327 | 4,544 / 960 | 10,327 | 0.670 |

CoreMark has three non-PMEM memory events; CRC32 has 37. MEM omits these, so
its traffic figures cover retained PMEM accesses only. The low sustained AXI
rate reflects cache hits and a one-instruction-at-a-time trace agent; it is
not an AXI saturation limit. An I request can produce multiple decoded uops,
so MEM I requests/cycle cannot be compared numerically with FE uops/cycle as
an IPC ceiling. `+INDEPENDENT` is available for a separate saturation stress.

## Physical boundary

`lspd/modules.mk` already names the native synthesis tops: FE
`rapt_frontend`, BE `rapt_backend_syn_top`, and MEM `rapt_memory`. The trace
drivers, AXI image model and decoders in `verify/subsystem` are outside these
PPA boundaries. Run `make -C verify/subsystem structure XLEN=32` and `XLEN=64`
for connectivity checks; use the LSPD PPA and FPGA OOC commands in
`lspd/README.md` with the same XLEN, preset, memory model and constraints.

The older RV64/default/50 MHz LSPD snapshots reported FE 208,370 Liberty
area, MEM 1,148,330 Liberty area (macro mode), and backend FPGA 277,985 LUTs
plus 87,924 FFs. They are only historical scale indicators: the saved FE
source manifest already fails against this working tree, backend ASIC and MEM
FPGA use different snapshots/models, and there is no new matched PPA run for
these traces. No current area or Fmax delta is inferred from them.

## Interpretation limits

- BE checks retired PC and next PC, not every register value. In the full
  CoreMark RV32 and RV64 windows its external memory fixture reports two CLINT reads at
  `0x0200bffc` and `0x0200bff8` as unmapped; a full SoC or matching CLINT model
  is needed before treating those runs as program-correctness evidence.
- FE uses NEMU branch outcomes delayed by a fixed number of cycles. It does
  not reproduce the backend's precise predictor-history checkpoint restore.
- MEM presents one traced instruction PC at a time and does not reproduce the
  FE's fetch grouping, wrong-path requests, or BE issue timing. Its cycle count
  is a traffic-service experiment, not whole-core execution time.
- Standalone PPA excludes cross-block timing paths. Whole-core STA and a full
  RTL benchmark run remain the appropriate tests for chip Fmax and IPC claims.
