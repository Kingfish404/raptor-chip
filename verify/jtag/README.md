# JTAG / RISC-V Debug Verification

This subdirectory provides verification entry points for
[rapt_dtm](../../hdl/perip/rapt_dtm.sv) and
[rapt_dm](../../hdl/perip/rapt_dm.sv), with the
[remote-bitbang host](../../sim/csrc/jtag/jtag_rbb_server.cc).

## Implementation boundary

The DM supports drained-core halt/resume, a sticky halt state and abstract
32-bit transfers for GPRs and selected DM-local CSRs. `dcsr`, `dpc` and scratch
registers are stored in the DM; commit-based stepping supports bring-up.
This is not a complete architectural Debug Mode implementation.
Memory access/SBA, program-buffer execution, 64-bit abstract transfers and
Debug Mode fetch redirect/`dret` remain unsupported. `debug-tests` still exits
nonzero with this gap list; available smoke targets are not upstream-suite
acceptance evidence.

## Quick start

```sh
# 23-point in-tree compliance probe (runs today, ~5s after rebuild)
make -C verify/jtag selftest

# Live OpenOCD bring-up against the RTL TAP (runs today)
make -C verify/jtag openocd-smoke         # one-shot: PASSes if IDCODE=0x10001913
make -C verify/jtag openocd-server        # foreground: leave running for GDB

# Implemented integration checks (32-bit abstract transfers)
make -C verify/jtag openocd-halt-reg      # halt and GPR/selected-CSR round-trip
make -C verify/jtag gdb-smoke             # GDB register read/write path

# Upstream GDB-driven debug-spec suite (runner remains a stub)
make -C verify/jtag debug-tests-setup     # clones riscv-tests
make -C verify/jtag debug-tests           # currently exits 1 with checklist
```

Equivalent shortcuts from the parent directory:

```sh
make -C verify jtag-selftest
make -C verify jtag                       # = jtag-selftest
```

## Build selection and isolation

Smoke runners support RV32 abstract transfers. `RAPT_CONFIG` and
`BUILD_PROFILE` are forwarded to `sim/Makefile`; the executable path is
resolved there, including SoC mode and profiling suffixes. Set `NSIM_BIN`
explicitly to use an existing executable without rebuilding, and supply its
matching `RAPT_CONFIG`. Custom defines changing MISA need a matching preset.

`JTAG_PORT` is passed to both simulator and OpenOCD. `GDB_PORT` is passed to
OpenOCD and GDB; choose distinct values for concurrent sessions. TCL and
Telnet listeners are disabled. Each run preserves logs in a unique directory
under `verify/jtag/build/runs/` and terminates only processes it started.
Missing tools, nonzero client exits and readiness timeouts fail the check.
The halt test derives expected MISA from the selected RV32 preset.

For a manually launched server on a custom port:

```sh
openocd -c 'set RAPT_JTAG_PORT 9825' -c 'set RAPT_GDB_PORT 3334' \
  -f verify/jtag/openocd.cfg
```

Host-side regression (uses fake tools, no RTL build):

```sh
python3 -B -m unittest discover -s verify/jtag -p 'test_run_smoke.py'
```
