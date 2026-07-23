# Raptor Module-Level UVM Verification

This directory adds a module-level verification layer below architectural
difftest and Linux boot. It is intended to find local protocol, arbitration,
ordering, flush, and multi-write defects before they become long full-core
debug sessions.

## Current status

The first environment targets `rapt_exu_iq` and contains:

- a cycle transaction and virtual interface;
- sequencer and driver with directed and randomized stimulus;
- a passive monitor;
- an independent age-ordered issue-queue reference model;
- a scoreboard for occupancy, issue validity/order, payload, CDB forwarding,
  fast-load confirmation, and port-B eligibility;
- coverage counters for empty/partial/full occupancy, A/B/dual dispatch, all
  four writeback ports, fast wake/rebusy, and flush;
- the DUT's `RAPT_ASSERT_EN` SVA checks.

Run the checks available in the current tool installation:

```bash
make -C verify uvm-smoke
make -C verify uvm-iq-compile
make -C verify uvm
```

`uvm-smoke` runs UVM 1.2. `uvm-iq-compile` compiles the complete IQ environment
and RTL. The IQ random sequence defaults to 500 cycles and accepts
`+IQ_CYCLES=<n>` when run on a supported class-capable simulator.

## XSim 2025.2 limitation

The installed XSim 2025.2 runs a minimal UVM test and parses the complete IQ
environment with `xvlog`, but `xelab` crashes internally while analyzing the
larger class-task package (`XSIM 43-3316`, SIGSEGV). This is a simulator crash,
not an HDL diagnostic. Consequently, the Makefile deliberately names the IQ
target `uvm-iq-compile` and does not claim a passing dynamic UVM run.

Use Questa, VCS, or Xcelium for the complete UVM test until the XSim issue is
resolved. Keep XSim directed checks and full-core difftest as executable gates
in this environment.

## Environment layout

```text
uvm/
├── README.md
├── VERIFICATION_PLAN.md
├── xsim_uvm_smoke.sv
└── iq/
    ├── rapt_iq_uvm_if.sv
    ├── rapt_iq_uvm_pkg.sv
    └── tb_rapt_exu_iq_uvm.sv
```

New module environments should use the same agent/monitor/reference-model/
scoreboard split. Drivers must not inspect DUT internals, and scoreboards must
derive expected behavior from observed interface transactions only.

## Executable LSU/SQ random environment

XSim cannot dynamically run the larger class-based IQ UVM package, so the P0
LSU/SQ environment uses the same transaction-driver/reference-model/scoreboard
structure in an executable SystemVerilog testbench:

```bash
make -C verify xsim-lsu-sq-random
make -C verify xsim-lsu-sq-random LSU_SQ_RANDOM_SEED=42
```

It runs 10,000 cycles with `RAPT_ASSERT_EN`, a four-entry SQ, randomized
allocation/commit/drain backpressure/flush traffic, and load probes covering
Sv32 virtual aliases, exact forwarding, partial-store conflicts, LR ordering,
full occupancy, and repeated wraparound. The checker is interface-only and is
intended to become the reference model for a class-based LSU UVM agent when a
supported simulator is available.