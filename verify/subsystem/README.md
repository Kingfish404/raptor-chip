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
| `be` | Real BE, real RTL decoder fed with traced instructions and actual next PC, real memory composition as a data fixture | Committed IPC, admission stalls, load/store and AXI activity | BE throughput with an oracle frontend; the memory fixture is included in functional simulation, not BE-only PPA |
| `mem` | Real memory composition, program-order I and D trace request agents, image-backed AXI slave | Accepted I/D requests/cycle, useful D bytes, AXI beats and bytes/cycle | Traffic capacity for the replayed request mix; each D request waits until its traced instruction has been supplied, without backend issue latency |

`fe` accepts `FE_ARGS='+SINK_WIDTH=1 +FETCH_GAP=2 +FEEDBACK_DELAY=4'`;
`be` accepts `BE_ARGS='+FEED_WIDTH=1 +MAX_INSTS=2000'`; `mem` accepts
`MEM_ARGS='+MAX_INSTS=2000 +MAX_MEM=1000'`. `MAX_CYCLES` is available on all
three. The MEM top normally takes only data accesses belonging to its selected
instruction window; `+MAX_MEM` caps that count. `+INDEPENDENT` turns off
instruction-to-data gating for a saturation experiment. Run matched image/trace
windows when comparing width or latency knobs.
`width_loss` is `1 - useful_instructions / (cycles * configured_width)`;
finite startup, branches and serial instructions contribute to it. Stall
counters may overlap and must not be summed into a partition of the loss.

The MEM top retains aligned, supported-size PMEM accesses and reports skipped
events. Its load responses are checked against NEMU's recorded values; a
scenario with nonzero skipped accesses is only representative of the retained
traffic. The BE top checks each retired PC and next PC against the dynamic
trace. A mismatch fails the run rather than silently measuring another path.

These rates are not CoreMark scores or full-core IPC. Use the complete RV32 and
RV64 RTL runs for those claims, and compare the module rates with the existing
PMU's fetch, retirement, miss, and stall counters.

Initial CoreMark and Embench CRC32 measurements, source provenance, traffic
splits and limitations are recorded in
[the subsystem results](../../docs/subsystem-trace-results.md).

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
