# Raptor UVM Verification

## Whole-chip verification

[`chip/`](chip/README.md) instantiates the complete `rapt` RTL with a reactive UVM AXI memory model, independent bus monitor/scoreboard, pin-control sequencer, and self-checking bare-metal firmware. A second top exercises the RV32 RNP package wrapper. It uses class-capable Verilator and Accellera UVM sources; it does not depend on XSim's larger-class elaboration support.

```sh
make -C verification uvm-chip-rv32 UVM_HOME=/path/to/uvm-core
make -C verification uvm-chip-rv64 UVM_HOME=/path/to/uvm-core
make -C verification uvm-chip-regress UVM_HOME=/path/to/uvm-core
```

The matrix covers default RV32/RV64, small RV32, large RV64 with L2, and RV32 RNP. The runner saves source/firmware hashes, commands, seeds, coverage counters and results in `verification/build/uvm/`. A missing tool, watchdog, UVM error/fatal, missing completion marker or incomplete transaction drain fails the run. See the [scenario ledger and limitations](chip/README.md).

## Module-level verification

This directory adds a module-level verification layer below architectural difftest and Linux boot. It is intended to find local protocol, arbitration, ordering, flush, and multi-write defects before they become long full-core debug sessions.

## Current status

The first environment targets `rapt_iq` and contains:

- a cycle transaction and virtual interface;
- sequencer and driver with directed and randomized stimulus;
- a passive monitor;
- an independent age-ordered issue-queue reference model;
- a scoreboard for occupancy, issue validity/order, payload, CDB forwarding, fast-load confirmation, and port-B eligibility;
- coverage counters for empty/partial/full occupancy, A/B/dual dispatch, all four writeback ports, fast wake/rebusy, and flush;
- the DUT's `RAPT_ASSERT_EN` SVA checks.

Run the checks available in the current tool installation:

```bash
make -C verification uvm-smoke
make -C verification uvm-iq-compile
make -C verification uvm
```

`uvm-smoke` runs UVM 1.2. `uvm-iq-compile` compiles the complete IQ environment and RTL. The IQ random sequence defaults to 500 cycles and accepts `+IQ_CYCLES=<n>` when run on a supported class-capable simulator.

## Historical XSim 2025.2 limitation

The evaluated XSim 2025.2 installation ran a minimal UVM test and parsed the
complete IQ environment with `xvlog`, but `xelab` crashed internally while
analyzing the larger class-task package (`XSIM 43-3316`, SIGSEGV). This was a
simulator crash, not an HDL diagnostic. The Makefile therefore names the IQ
target `uvm-iq-compile` and does not claim a passing dynamic IQ UVM run.
That historical result does not establish behavior for another XSim release.

Use a supported class-capable simulator for the complete IQ test and retain
directed checks and full-core difftest. The whole-chip Verilator UVM flow above
has a separate environment and acceptance ledger.

## Environment layout

```text
uvm/
├── README.md
├── xsim_uvm_smoke.sv
└── iq/
    ├── rapt_iq_uvm_if.sv
    ├── rapt_iq_uvm_pkg.sv
    └── tb_rapt_iq_uvm.sv
```

New module environments should use the same agent/monitor/reference-model/ scoreboard split. Drivers must not inspect DUT internals, and scoreboards must derive expected behavior from observed interface transactions only.

## Executable LSU/SQ random environment

XSim cannot dynamically run the larger class-based IQ UVM package, so the P0 LSU/SQ environment uses the same transaction-driver/reference-model/scoreboard structure in an executable SystemVerilog testbench:

```bash
make -C verification xsim-lsu-sq-random
make -C verification xsim-lsu-sq-random LSU_SQ_RANDOM_SEED=42
```

It runs 10,000 cycles with `RAPT_ASSERT_EN`, a four-entry SQ, randomized allocation/commit/drain backpressure/flush traffic, and load probes covering Sv32 virtual aliases, exact forwarding, partial-store conflicts, LR ordering, full occupancy, and repeated wraparound. The checker is interface-only and is intended to become the reference model for a class-based LSU UVM agent when a supported simulator is available.
