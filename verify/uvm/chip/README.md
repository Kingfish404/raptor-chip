# Whole-chip UVM verification

The DUT is `hdl/rapt.sv`: the complete CPU, caches, AXI router, CLINT, PLIC,
DTM and debug module. No pipeline or peripheral is replaced by a model. The
second top instantiates `rng_chip` and the real board-side `rnp2axi` bridge,
so transactions cross the RV32 package's RNP pins.

Latest completed validation: [396 positive and 20 negative checks](RESULTS.md).

## Run

From the repository root:

```sh
make -C verify uvm-chip-rv32 UVM_HOME=/path/to/uvm-core
make -C verify uvm-chip-rv64 UVM_HOME=/path/to/uvm-core
make -C verify uvm-chip-regress UVM_HOME=/path/to/uvm-core
```

Run one reproducible scenario without running the complete matrix:

```sh
make -C verify/uvm chip UVM_HOME=/path/to/uvm-core \
  XLEN=64 RAPT_CONFIG=default CASES=mmu SEEDS=42 DELAYS=31
make -C verify/uvm chip-rnp UVM_HOME=/path/to/uvm-core
make -C verify/uvm chip-checkers UVM_HOME=/path/to/uvm-core
python3 -m unittest discover -s verify/uvm -p test_runner.py
```

`run.py --help` lists direct-runner options, including `--no-build`, which
requires an existing build with matching source and executable hashes. Normal
runs reuse such builds automatically. `--build-only` is compilation, not a
passing dynamic verification run.

Requires a class-capable Verilator, Accellera UVM sources (`src/uvm_pkg.sv`),
Python 3 and `riscv64-elf-gcc`/`objcopy`. The development toolchain is Verilator
5.052 and Accellera UVM 2020.3.1; each build records actual tool versions and
UVM source hashes. Set `UVM_HOME` to your installation; no third-party library
is vendored or automatically downloaded. `UVM_NO_DPI` avoids a separate UVM
DPI shared library. The resulting UVM notices do not disable class execution,
scoreboards or the DUT's `RAPT_ASSERT_EN` assertions. Verilator width warnings
remain in `build.log`; `-Wno-fatal` is not a lint-clean claim.

## Architecture

- `rapt_chip_if.sv`: XLEN-parameterized top-level pin interface.
- `rapt_chip_pkg.sv`: sampled AXI transactions, memory responder, monitor,
  independent byte-memory reference model, scoreboard, environment and test.
- `rapt_chip_control.svh`: sequence items, sequencer-facing driver and scenario
  sequence for reset, IRQ, external writes and serial JTAG transactions.
- `firmware/`: self-checking instruction streams and trap handlers.
- `tb_rapt_chip*.sv`: actual AXI chip and RNP-wrapper instantiations.
- `../run.py`: isolated build, firmware compilation, regression and result gate.

The reactive memory model accepts AW and W independently, including W before
AW. It queues reads and reorders responses across IDs while preserving each
ID's order, supports FIXED/INCR bursts, honors byte strobes, and holds R/B
payloads under backpressure. A deterministic xorshift stream controls timing.
`DELAYS=N` means a 1/(N+1) per-cycle readiness probability; it is not a hard
maximum latency. Both a cycle watchdog and host timeout bound every run.

The monitor samples the active edge; drivers change pins on the falling edge.
The scoreboard separately reconstructs outstanding transactions and expected
memory from observed handshakes and the immutable firmware image. It checks
AR/AW/W/R/B stability, ID ownership, burst boundaries, 4 KiB boundaries, byte
memory data, peripheral routing, ordered signatures and transaction drain.
Firmware independently checks architectural results before issuing signatures.
Thus a bus/model mistake is not accepted just because firmware printed PASS.

No register backdoor, force, DPI difftest skip, internal hierarchy poke or
fixed commit-lane assumption is used by these scenarios.

## Scenario ledger

Each scenario must complete exactly three ordered signature stages; a separate
completion write closes the run. Reset restarts the signature epoch and drains
or cancels the pre-reset interface transactions according to reset semantics.

| Scenario | End-to-end checks |
| --- | --- |
| `smoke` | ROM reset vector, dependent multiply/divide, RAM bytes/words, CLINT/PLIC registers |
| `pipeline` | Dependent loops, alternating branches, wrong-path MMIO suppression, nested returns, compressed instructions, self-modifying RAM code and `fence.i` |
| `memory` | Signed/unsigned byte/half/word/double loads, every byte lane, 128 KiB eviction working set, forwarding, LR/SC success/failure and word/double AMOs |
| `traps` | Exact M-ecall and illegal-instruction cause/EPC/tval, U-mode execution, U-ecall and MRET |
| `supervisor` | M-to-S entry, delegated U-ecall, S trap cause/EPC/status, SRET |
| `pmp` | MPRV/S permissions, rejected store without memory modification, locked PMP config/address, M-mode load/fetch rejection |
| `mmu` | Sv32/Sv39 multi-level PTW, virtual alias, remapping plus SFENCE, Svade A/D faults without PTE writes, read-only store fault |
| `ifetch_mmu` | S-mode translated instruction fetch through an alias, return into mapped ROM, execute-permission revocation and instruction page fault |
| `fp` | F/D arithmetic and memory, divide-by-zero/invalid flags, Zfhmin conversion and half-width loads/stores |
| `irq` | CLINT software/timer traps, PLIC priority/enable/threshold, external and legacy pins, claim/deassert/complete |
| `debug` | JTAG IDCODE/DTMCS, DM activation, running-core halt/drain, committed GPR write/read, resume and firmware confirmation |
| `external` | Overlapping notification invalidates LR/SC; disjoint notification preserves it; pending notification batches drain |
| `faults` | AXI SLVERR on data/fetch, precise load/fetch exceptions, posted-store machine interrupt 16, MBERR address/strobe/pending acknowledgement |
| `reset` | Reset during accepted read and write traffic, followed by successful boot in a third reset epoch |

The posted-store error expectation follows the implemented platform contract:
`mie[16]`, `mip[16]`, `MBERR_STATUS` (0x7c0) and `MBERR_ADDR` (0xfc0). A store
has retired before its downstream B response, so its failure cannot be assigned
to a younger instruction as a precise store access fault.

## Matrix and acceptance

`chip-regress` runs seeds 1 and 42 at readiness settings 0, 7 and 31:

| Preset | XLEN | Interface | Scenarios |
| --- | --- | --- | --- |
| default | 32, 64 | AXI | all |
| small | 32 | AXI | all |
| large | 64 | AXI, L2 enabled | all |
| default | 32 | RNP | all except IRQ, debug, external notification and AXI faults |

The RNP wrapper is RV32-only, has one outstanding word transfer, does not
export IRQ/JTAG/device-write pins, and does not transport AXI response errors.
Unsupported RNP case/config requests fail explicitly. Those features are
verified on the actual AXI chip top, rather than by forcing signals inside
the RNP wrapper. Multi-hart, asynchronous JTAG clocking, a gate-level netlist,
analog pads and FPGA timing are outside this RTL interface suite. Directed
ISA scenarios are regression coverage, not exhaustive ISA/profile certification.

The four negative checker tests corrupt one monitor sample's RID, RLAST,
RDATA or WLAST. Each must produce its specific checker error and must not
produce CHIP_PASS. Identity/boundary corruptions can subsequently hit the cycle
watchdog because the corrupted scoreboard queues cannot drain; the required
specific checker error must already be present. These are expected failing simulations used to verify the
checker, not DUT passes. The Python tests additionally verify fail-closed
handling of UVM_FATAL with process status zero, missing PASS and host timeout.

`verify/build/uvm/chip-<preset>-rv<xlen>-<top>/` contains:

- `build.json`: source hashes, executable hash, tool version and exact command;
- `firmware/`: ELF, raw image, compilation logs;
- `runs/`: individual scenario/seed/delay and negative-test logs;
- `results.json`: each pass/fail, elapsed time, firmware hashes and coverage.

`regression.json` records the matrix result; single-configuration invocations
write `regression-<preset>-rv<xlen>-<top>.json`. A source change during a run
invalidates that run. Missing dependencies, incomplete signatures, UVM errors,
assertions, timeout or undrained transactions fail the gate. Build profiles
never rewrite `sim/.config`, install dependencies or regenerate the decoder.

## RTL regressions found by this suite

- Independent AW/W backpressure exposed a router deadlock when the final W
  handshake preceded AW. The router now remembers that completed data phase.
- L2 refill errors now complete the remaining upstream beats with the error;
  they no longer enter an endless miss/refill retry.
- A read following an early-restarted L2 miss waits through the SRAM install
  cycle before its lookup; it cannot consume the previous SRAM output.
- L2 cached bursts advance by ARSIZE and honor FIXED addressing. This covers
  the RV64 instruction port's 32-bit transfers within a 64-bit SRAM word.
- Failed L2 writes invalidate a matching cached alias, including NC/IO aliases
  whose backing memory may have been partially modified.
- CPU AXI writes clear the bufferable attribute so L2 forwards the actual
  downstream B response to the core's machine bus-error handler. Cacheability
  and allocation attributes remain enabled. This removes early L2 write
  completion for CPU writes; its performance impact has not been measured.

- The RNP bridge serializes address/data phases, retains accepted AXI IDs,
  and keeps RLAST/WLAST independent of READY. It no longer acknowledges W
  while its shared pins carry AW. Transactions now remain owned until their
  response handshake or reset, without a timeout silently discarding them.

- Debug halt now flushes queued speculative operand snapshots after the ROB
  drains and redirects to the committed frontier before acknowledging halt.
  Queue admission remains blocked while halt is requested. Resumed instructions therefore consume debugger-updated registers. The ROU
  directed suite checks the halt/flush/redirect ordering and queued-uop discard.

Focused reproductions are available as `make -C verify
verilator-router-early-write-rv32 verilator-router-early-write-rv64
verilator-l2-response-error-rv32 verilator-l2-response-error-rv64
verilator-rnp-handshake-rv32 verilator-rou-dual-commit
verilator-rou-dual-commit-rv64`.
Existing `verilator-bus-pbmt-rv32` / `verilator-bus-pbmt-rv64` and
`verilator-l2-pbmt` / `verilator-l2-pbmt-rv64` tests also cover the write
attribute/error contract.
