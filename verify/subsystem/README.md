# FE, BE and MEM trace experiments

These test tops use the production `rapt_frontend`, `rapt_backend` and
`rapt_memory` instances. They are simulation environments, separate from the
production RTL and from the existing LSPD synthesis tops.

## Trace source

NEMU records `PC expanded_instruction actual_next_PC` in `.inst` and
`instruction_index PC r|w virtual_address size_bytes value` in `.mem` when
`RAPT_SUBSYSTEM_TRACE_PREFIX` is set. A load's value is logged after a
successful read, and a store is logged after a successful write. The test tops
read the original instruction bytes from the
same raw image, because NEMU expands compressed instructions in its decode
record. Keep an image and its two trace files together. The NEMU ROM trampoline
is skipped by the test tops; the measured window begins at the first program
instruction in PMEM. The trace is a dynamic program-order record, not a
cycle-accurate RTL transaction schedule.

For the installed bare-metal RV32 CoreMark image:

```sh
make -C verify/subsystem trace TRACE_INSTS=20000
make -C verify/subsystem fe
make -C verify/subsystem be BE_ARGS='+MAX_INSTS=2000'
make -C verify/subsystem mem MEM_ARGS='+MAX_INSTS=2000 +MAX_MEM=1000'
make -C verify/subsystem structure XLEN=32
```

`trace` requires a current `nemu/build/riscv32-nemu-interpreter` built from this
tree. Its recipe changes into `nemu/` because NEMU loads Capstone from a
relative path. The binary can be rebuilt with the repository's normal NEMU
setup/build target. The generated files and Verilator objects are under
`verify/build/subsystem/`; override `BUILD_DIR` and `TRACE_PREFIX` for
independent configurations.

For the available bare-metal Embench CRC32 image, set both variables on all
commands:

```sh
make -C verify/subsystem trace \
  IMG=../../app/build/rv32/embench-baremetal/crc32/crc32.bin \
  TRACE_PREFIX=../build/subsystem/embench-crc32-rv32 \
  TRACE_INSTS=20000
```

Paths supplied through `IMG` and `TRACE_PREFIX` are resolved from
`verify/subsystem/`. Pass the matching values to `fe`, `be` and `mem`.

## What each top measures

| Target | DUT and environment | Main counters | Interpretation |
| --- | --- | --- | --- |
| `fe` | Real FE, image-backed ideal L1I response, `valid/ready` sink, delayed NEMU control-flow feedback | Correct decoded uops/cycle, width loss, redirects and stall cycles | Fetch/decode delivery under the stated feedback delay and sink width; the branch feedback is an approximation of BE commit/recovery |
| `bpu` | The same real FE replay, with BPU observations before and after IDU repair | Conditional direction accuracy, primary/auxiliary split, target misses, per-PC hotspots, FE cycles | Prediction quality under the stated packet width and feedback delay; the result is not full-core IPC |
| `be` | Real BE, real RTL decoder fed with traced instructions and actual next PC, real memory composition as a data fixture | Committed IPC, admission stalls, load/store and AXI activity | BE throughput with an oracle frontend; the memory fixture is included in functional simulation, not BE-only PPA |
| `mem` | Real memory composition, program-order I and D trace request agents, image-backed AXI slave | Accepted I/D requests/cycle, useful D bytes, AXI beats and bytes/cycle | Closed-loop service rate for the replayed request mix; the D agent holds only one outstanding trace request, so this rate is not saturated D bandwidth |

`fe` accepts `FE_ARGS='+SINK_WIDTH=1 +FETCH_GAP=2 +FEEDBACK_DELAY=4'`;
`be` accepts `BE_ARGS='+FEED_WIDTH=1 +MAX_INSTS=2000'`; `mem` accepts
`MEM_ARGS='+MAX_INSTS=2000 +MAX_MEM=1000'`. `MAX_CYCLES` is available on all
three. The MEM top normally takes only data accesses belonging to its selected
instruction window; `+MAX_MEM` caps that count. `+INDEPENDENT` turns off
instruction-to-data gating for a saturation experiment. Run matched image/trace
windows when comparing width or latency knobs.

## BPU accuracy experiment

Run `trace` once for each image/XLEN, then reuse the exact image and `.inst`
file for each candidate. For example, to compare the RV64 default frontend
with a registered fetch response:

```sh
make -C verify/subsystem bpu XLEN=64 CONFIG=default \
  BUILD_DIR=/tmp/bpu-base EXTRA_DEFINES=-DRAPT_FETCH_RESPONSE_STAGE=1 \
  TRACE_PREFIX=/absolute/path/to/coremark-rv64-100k \
  FE_ARGS='+SINK_WIDTH=2 +FEEDBACK_DELAY=4'
make -C verify/subsystem bpu XLEN=64 CONFIG=default \
  BUILD_DIR=/tmp/bpu-hash TRACE_PREFIX=/absolute/path/to/coremark-rv64-100k \
  FE_ARGS='+SINK_WIDTH=2 +FEEDBACK_DELAY=4' \
  BPU_BASELINE=/tmp/bpu-base/bpu/summary.json
```

Set `IMG` to the image that produced the trace if it is not the default
CoreMark image. `summary.json` records image/trace/executable hashes, config,
defines, replay settings, raw counts, accuracies, MPKI and baseline deltas.
`events.csv` supports per-PC hotspots. All three subsystem builds track the
config, XLEN, `EXTRA_DEFINES`, compiler path and shared headers;
separate `BUILD_DIR` values keep A/B outputs easy to inspect. The `structure`
target also forwards `EXTRA_DEFINES`. Run
`python3 verify/scripts/test_subsystem_build_cache.py` from the repository root
to check rebuild behavior without compiling RTL.

The denominator is every accepted, trace-matched control instruction. A
conditional's `raw_miss` compares the IFU prediction before IDU repair with
the actual next PC; direction and target misses are separated. Primary means
the packet's first branch uses TAGE/BTB; auxiliary means a later conditional
uses the combinational bimodal/gshare chooser. Direct jumps in the raw count
can use an IFU static immediate rather than a BPU table, and returns may be
repaired by IDU's RAS. The `final_miss` in the event CSV is after IDU repair.
Prediction and feedback are causally ordered: the trace supplies an outcome
only after the instruction reaches the test sink, then waits the configured
feedback delay. Wrong-path instruction bytes come from the image. L1I is
ideal, backend recovery is approximated, and no RTL predictor state or port
is added by this instrumentation.

For width scaling, run `CONFIG=default-w4` or `default-w8` and set
`SINK_WIDTH` to 4 or 8. A 16-wide FE stress run can use
`CONFIG=default-w8 EXTRA_DEFINES=-DRAPT_DECODE_WIDTH=16` and
`SINK_WIDTH=16`; this does not create a 16-wide fetch interface or backend.
`check_trace.py` reports width-only and 6/8-halfword-window packet bounds for
2, 4, 8 and 16 slots. Those bounds assume one packet per cycle and omit cache,
prediction and pipeline delays. Current IFU ends each packet at the first
control instruction and has one primary plus at most one auxiliary prediction
query per packet. Its wide fetch window contains only eight halfwords, so
larger decode width alone cannot raise the bound past the eight-halfword
limit. Local measurements and configuration choices are archived in
`docs.agent/evaluation/bpu-trace-evaluation-2026-09-27.md` (not distributed with Git).

## Other FE and MEM metrics

`+HOT_BANDWIDTH +HOT_CYCLES=20000` continuously presents two cacheable D
reads to one fixed PMEM address on the A and B channels. It checks that both
ports return the same data and reports their combined accepted requests per
cycle. The mode tests the hot-hit read path and does not represent CoreMark's
address mix, store traffic, or external AXI bandwidth. The normal trace mode
also reports D inter-completion spans; with `+INDEPENDENT` and a D-only run
these are per-operation service latencies, while coupled replay includes
instruction-to-data gating time.
`width_loss` is `1 - useful_instructions / (cycles * configured_width)`;
finite startup, branches and serial instructions contribute to it. Stall
counters may overlap and must not be summed into a partition of the loss.
The trace metadata also gives `optimistic_fe_packet_bound` for widths 2, 4, 8
and 16, plus `window_limited_fe_packet_bound` for six and eight halfwords.
These assume at most one fetch packet per cycle, end a packet at a branch or
jump, and start a new packet for a non-first-slot JALR. They omit serial
boundaries, cache, prediction, feedback and pipeline costs, so remain
optimistic.

The MEM top retains aligned, supported-size PMEM accesses and reports skipped
events. Its load responses are checked against NEMU's recorded values; a
scenario with nonzero skipped accesses is only representative of the retained
traffic. The BE top checks each retired PC and next PC against the dynamic
trace. A mismatch fails the run rather than silently measuring another path.
For an L2-enabled preset, external AXI IDs are remapped by L2, so the MEM top
reports only aggregate external AXI traffic. A finite write-back run may leave
dirty data in cache and show zero external write bytes.

These rates are not CoreMark scores or full-core IPC. Use the complete RV32 and
RV64 RTL runs for those claims, and compare the module rates with the existing
PMU's fetch, retirement, miss, and stall counters.

Local experiment archives under `docs.agent/evaluation/` are not distributed
with Git. Initial CoreMark and Embench CRC32 measurements, source provenance, traffic
splits and limitations are recorded in
[the subsystem results](../../docs.agent/evaluation/subsystem-trace-results.md).
The current 2026-09-25 default, four-lane and L2 reassessment is in
[the efficiency results](../../docs.agent/evaluation/subsystem-efficiency-2026-09-25.md).
The default backend stall breakdown, load-use optimization and matched A/B results are in
[the backend utilization report](../../docs.agent/evaluation/backend-utilization-2026-09-26.md).

## PPA boundary

The independent synthesis tops already live in `lspd`: `rapt_frontend`,
`rapt_backend_syn_top` and `rapt_memory`. The testbench stimulus, decoder
feeder and AXI image model are outside that PPA boundary. For example:

```sh
for module in frontend backend memory; do
  make -C lspd/syn structure-check MODULE=$module RAPT_CONFIG=default
done
make -C lspd ppa-all MODULES_TO_RUN='frontend backend memory' \
  RAPT_CONFIG=default PDK=nangate45 CLK_FREQ_MHZ=50 SRAM_MODE=macro
```

Use the same configuration, XLEN, SRAM model and constraints for comparisons.
LSPD's standalone timing does not cover paths that cross module boundaries;
use full-core STA for a final timing claim. Macro-mode ASIC synthesis uses
abstract SRAM models, while FPGA OOC estimates use behavioral memories.
