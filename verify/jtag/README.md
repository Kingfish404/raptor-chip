# JTAG / RISC-V Debug Verification

This subdirectory adds upstream-aligned verification for the JTAG (DTM) and
Debug Module (DM) blocks introduced under [docs-ref/dev.jtag.md](../../docs-ref/dev.jtag.md).

## Quick start

```sh
# 23-point in-tree compliance probe (runs today, ~5s after rebuild)
make -C verify/jtag selftest

# Live OpenOCD bring-up against the RTL TAP (runs today)
make -C verify/jtag openocd-smoke         # one-shot: PASSes if IDCODE=0x10001913
make -C verify/jtag openocd-server        # foreground: leave running for GDB

# (Future, P1-blocked) Upstream gdb-driven debug-spec suite
make -C verify/jtag debug-tests-setup     # clones riscv-tests
make -C verify/jtag debug-tests           # currently exits 1 with checklist
```

Equivalent shortcuts from the parent directory:

```sh
make -C verify jtag-selftest
make -C verify jtag                       # = jtag-selftest
```
