# JTAG / RISC-V Debug Verification

Tests cover [rapt_dtm](../../rtl/uncore/debug/rapt_dtm.sv),
[rapt_dm](../../rtl/uncore/debug/rapt_dm.sv), the cluster AXI debug arbiter and the
production chip's sampled JTAG / octal memory link.

## Implemented debug access

The single-hart DM supports drained-core halt/resume, selected GPR/CSR abstract
transfers (32-bit, plus paired `data0/data1` transfers on RV64), and independent
physical System Bus Access (SBA). OpenOCD discovers `sbversion=1`, the implemented
physical address width and byte/halfword/word access; RV64 also supports 64-bit
access. `sbaddress1` exists when physical addresses exceed 32 bits.

SBA reaches CLINT, PLIC and the external AXI port, including while the hart is in
`ndmreset`. It bypasses **both L1 and L2**. AXI DECERR reports `sberror=2`; other
bus errors report 7, misalignment 3 and unsupported size 4. Errors are sticky W1C.
Accessing address/data while busy sets `sbbusyerror` without changing the in-flight
payload. Poll `sbbusy=0` before changing SBA controls and clear errors before retry.
Only accesses to `sbdata0` trigger a transfer; write/read `sbdata1` first on RV64.
Successful bus completion performs the optional address increment.

`ndmreset` blocks new core bus requests and drains already offered/accepted
transactions before resetting the core, caches, L2, CLINT and PLIC. DTM, DM, AXI
arbiter/router and the chip's octal bridge retain their state. The hart reports
unavailable during draining/reset; `ndmresetpending` covers that interval.
`anyhavereset/allhavereset` stay set until `ackhavereset`. Both a held `haltreq` and
`setresethaltreq` halt at the reset PC before retirement. SBA transactions also
drain if `dmactive` is cleared; the DM never abandons an AXI transfer halfway.

Debug CSRs remain DM-local. Stepping consumes one rename-to-skid admission token;
younger instructions cannot enter execution, including loads from read-sensitive
MMIO. AMOs and compressed expansion each have one architectural ROB owner. A
normal step halts with cause 4 and DPC at the successor; a trapping instruction
updates trap CSRs and halts at the handler before any handler instruction runs.
Faults leave the ROB without incrementing architectural `instret`. Interrupts
are masked unless `dcsr.stepie=1`, in which case an interrupt can consume a step
without executing an instruction. WFI completes as a NOP. LR reservations may be
lost across debug entry, so a stepped SC can fail, as permitted by the specification.

DPC is captured on every actual halt edge. Resume holds the hart until DPC is
redirected through normal recovery, with the frontend and speculative predictor
history flushed. A write to `reg pc` therefore selects the resume address; no write
continues from the captured frontier. `dcsr.prv` is read-only and records the actual
halt privilege. Only step, stepie, and ebreakm/s/u are writable DCSR controls;
xdebugver and cause are read-only and unimplemented controls read zero.

EBREAK/C.EBREAK enter the debugger when the corresponding privilege's ebreak bit
is set: cause 1, DPC at EBREAK, no exception or retirement. Otherwise they take the
normal breakpoint exception. Haltreq takes cause 3; resethaltreq takes cause 5
unless an explicit haltreq is also asserted. No address triggers are implemented.
Program-buffer execution, architectural debug-CSR instructions and abstract
`access_memory` remain unsupported. These tests do not claim full Debug
Specification conformance.

## Safe loading and inspection

Use OpenOCD's physical `sysbus` memory path (`openocd.cfg` selects it):

```tcl
reset halt
load_image program.bin 0x80000000 bin
verify_image program.bin 0x80000000 bin
reset halt
reg pc 0x80000000
resume
```

The chip powers up in its on-chip ROM and jumps to Flash XIP. The sampled-chip
fixture has a bridge peer and no NOR. Its explicit accelerated Flash startup /
reset / recovery / poll budgets are 2000 / 32 / 4000 / 4096 chip clocks;
production defaults are unchanged. After normal `init; halt`, `bridge_boot.tcl`
selects boot control 0 at 0x00100808, applies ndmreset with haltreq, verifies
active readback and synchronizes OpenOCD with another reset-halt. The bridge's
external trampoline then reaches the JTAG-loaded RAM program. No strap, forced
RTL state or PC redirection selects that backend. Keep the chip clock running
while older Flash work finishes or times out, and throughout JTAG access.

The six sampled SBA/reset/step targets perform this selection automatically;
the direct cluster TAP tests do not. The bridge model is disabled in Flash mode.
Paired `chip-flash-absent`, `chip-flash-blank` and `chip-flash-stalled` directed
tests exercise accepted XIP failure followed by JTAG bridge selection and actual
bridge execution. The stalled case removes DS after two array bytes and retains
the normal 100 MHz receive-timeout budget; it does not reset or force the DUT.

The first reset discards old cache contents, including dirty data. Halt drains
pending stores/responses and cleans L1D before reporting halted; with no L2 this
makes committed stack spills visible to GDB's unwinder through SBA. SBA writes
still bypass cached data. Resume invalidates L1I for software-breakpoint patches;
this supports ordinary RAM code on the no-L2 chip/middle presets. Data resident in
L1D, and SBA accesses with an enabled L2, need firmware cache maintenance. The
second reset removes stale or speculative instruction/data
cache state before running the newly loaded program. For recovery, SBA loading
also works with `ndmreset` held; release it with `haltreq` set, then reset-halt
again before resuming. Board flash programming uses the board's documented MMIO
controller/window; this DM introduces no board-specific flash registers.

A slave must eventually return AXI responses. No timeout cancels an accepted
transaction: abandoning it could misroute a late response or duplicate a write.
The Flash slave supplies bounded error responses for absent or stalled NOR;
see [chip recovery](../../docs/chip.md#boot-control). A permanently unresponsive
external bridge can prevent reset drain; recover with external chip/board reset.
Clear a sticky SBA error after busy clears. Do not retry a program/erase whose
physical outcome is uncertain.

## Tests

```sh
# Existing simulator tests, including register access (RV32).
make -C verification/jtag selftest openocd-smoke openocd-halt-reg

# Directed DM and arbiter protocol checks, both XLENs and extended physical address.
make -C verification/jtag sba-unit-rv32 sba-unit-rv64 sba-unit-pa36 \
  arbiter-unit-rv32 arbiter-unit-rv64

# Real OpenOCD through sampled chip JTAG and the octal board link.
make -C verification/jtag openocd-sba-rv32 openocd-ndmreset-rv32 \
  RAPT_CONFIG=chip32-middle-16k
make -C verification/jtag openocd-sba-rv64 openocd-ndmreset-rv64 RAPT_CONFIG=middle

# Exact independent retire/ROB-exit/admission counts, DPC, traps and MMIO effects.
make -C verification/jtag openocd-step-rv32 RAPT_CONFIG=chip32-middle-16k
make -C verification/jtag openocd-step-rv64 RAPT_CONFIG=middle
# Adds a batch GDB session with stepi, set $pc, break, continue and finish.
make -C verification/jtag gdb-step RAPT_CONFIG=chip32-middle-16k RISCV_GDB=riscv64-elf-gdb
```

`chip32-middle-16k` is explicitly RV32-only; use `middle` for RV64. The new harness
starts with a boot trampoline and a RAM spin loop. It loads every test program
byte over SBA, verifies/dumps the image, resets without resetting board RAM, then
resumes to a checked GOOD TRAP finisher. SBA tests include byte/halfword/word and
RV64 upper-lane/64-bit accesses, running-hart access, CLINT `mtime`, PLIC and an
unmapped board address that returns DECERR. The shared simulation memory model
normally returns OKAY for invalid reads; the new harness injects the explicit
unmapped-window response without changing existing benches.

DM unit checks also exercise DPC recapture, writable/read-only DCSR fields,
held resume payload, delayed redirect acknowledgement, and haltreq during a step.
The directed ROU tests check the production admission token, interrupt masking,
zero-instruction interrupt step, redirect ordering, and M/S/U ebreak entry.

Protocol checks exercise sticky busy/errors, read-on-address/data, increments,
independent AW/W stalls in both orders, sustained fair arbitration, multiple core
IDs, response backpressure and draining before reset. The DTM formal proof also
allows arbitrary TCK-enable stalls (`verification/formal/dtm.sby`, prove/cover).
`make -C verification formal-debug` checks DPC capture, read-only status, held
resume, SBA errors/draining, arbiter ownership and the production ROU admission
token. It shares the production native RAPT assertion helpers and requires
nonempty assertion/cover inventories, induction, every cover waveform and
counterexamples from injected RTL faults. The abstract hart holds halt until a
pending resume is applied, and availability returns after reset. The reset
controller/arbiter composition retains the exact inline controller source;
core/L2 quiescence and top-level composition remain open. See the formal section
of [the verification guide](../README.md) for scope and parameter bindings.

`debug-tests-setup` stages the upstream riscv-tests and test-environment archives
without git, including the `encoding.h` dependency omitted by source archives.
`debug-tests` runs selected upstream GPR, SBA memory, halt/PC and step tests through
`upstream.py`; set `RISCV_TESTS_REPO`, `UPSTREAM_PYTHON`, `RISCV_GDB` and
`CROSS_COMPILE` to available tools. Upstream Python needs pexpect and PyYAML.
The ebreak-exception case disables OpenOCD's `riscv set_ebreakm` policy temporarily;
otherwise OpenOCD turns the bit back on before stepping.
Override `DEBUG_TESTS` to select additional test classes. Program-buffer, trigger,
general abstract-CSR, vector, multi-hart and semihosting tests are outside the
implemented DM contract. The adapter does not replace upstream tests with local
approximations. It supplies MISA directly because the general CSR examination
requires registers the DM cannot transfer.

The adapter translates upstream's port-command spelling for OpenOCD 0.12 and
declares the harness ROM/RAM map to GDB. Without that map, GDB can repeatedly scan
unmapped addresses while unwinding a memory expression at reset without symbols.
GDB uses the bare-metal OS ABI (`set osabi none`), including with gdb-multiarch;
the installed Linux ABI used temporary breakpoints and stalled on the trap case.
RV32 RAM includes its sign-extended alias for GDB's register-indirect software step;
automatic hardware-breakpoint selection is disabled because this DM has no triggers.
Use `SBA_XLEN=64 RAPT_CONFIG=middle` for an RV64 harness; `JTAG_PORT` also selects
the upstream adapter's bitbang port. Selected assembly payloads use upstream's own
entry/init code with `-nostdlib`, so they do not require a hosted C library.

## Build and log isolation

Set `BUILD_ROOT` for simulator artifacts, `JTAG_LOG_ROOT` for original smoke logs
and `BUILD_DIR` for new JTAG harness artifacts
when keeping results outside the tree. `BUILD_PROFILE` selects an independent
simulator profile. Example, with a configurable external work directory:

```sh
make -C verification/jtag selftest openocd-smoke openocd-halt-reg \
  BUILD_ROOT="$WORK_DIR/sim" BUILD_PROFILE=sba \
  JTAG_LOG_ROOT="$WORK_DIR/jtag/runs" NPROC=4
make -C verification/jtag openocd-sba-rv32 openocd-ndmreset-rv32 \
  RAPT_CONFIG=chip32-middle-16k BUILD_DIR="$WORK_DIR/jtag" JOBS=4
```

`NSIM_BIN` selects an existing RV32 simulator for the original smoke tests; pair
it with the matching `RAPT_CONFIG`. Those tests use the simulator's direct-TAP
remote-bitbang host. New chip tests build their own DPI-free host with eight core
clocks per TCK half-period and keep generated models separate by tool version.

`JTAG_PORT` selects the loopback TCP port for both processes; choose distinct
ports for simultaneous tests. GDB uses `GDB_PORT`; TCL/Telnet listeners are disabled.
Every run preserves logs and images in a unique directory under `BUILD_DIR/runs`
and terminates only processes it started. Client failures, missing markers,
image mismatches and missing tools fail the runner. Jobs default to four or fewer.
During raw reset-status checks, `reset.tcl` disables OpenOCD background polling so
it cannot acknowledge/reset `dmcontrol` state behind the test.

Interactive use and host-only runner tests:

```sh
make -C verification/jtag openocd-server
openocd -c 'set RAPT_JTAG_PORT 9824' -c 'set RAPT_GDB_PORT 3333' \
  -f verification/jtag/openocd.cfg
python3 -B -m unittest discover -s verification/jtag -p 'test_run_smoke.py'
```
