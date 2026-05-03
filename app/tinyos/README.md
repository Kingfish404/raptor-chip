# tinyos Integration (xv6-riscv / egos-2000)

This directory hosts the Raptor app-layer integration for tiny teaching OSes.

Current scope:
- Source sync helper for upstream trees under `app/tinyos/`
- Clean temporary build-copy flow for NPC/nsim and NEMU
- NPC/nsim egos/xv6 boot helpers
- NEMU egos/xv6 boot helpers
- Direct upstream CLI entry helpers for egos/xv6 on QEMU

## Source Trees

The integration expects source trees at:
- `app/tinyos/xv6-riscv`
- `app/tinyos/egos-2000`

These directories are treated as upstream source checkouts. The sim targets
export a clean copy of each checkout's `HEAD` into
`app/build/tinyos-nsim-src/`. NPC/nsim and NEMU use upstream-compatible QEMU
device paths, so no tinyos OS patches are required.

Use:

```bash
make -C app tinyos-sync
```

## CLI / NPC Sim / NEMU

### Output & Debugging

`egos-cli-nsim` boots the upstream egos QEMU image path without an egos patch:
`tools/egos.bin` is loaded as the boot image and `tools/disk.img` is attached
through nsim's QEMU-compatible SDHCI model at `0x40000000` with PCI ECAM at
`0x30008000`. `egos-cli-nemu` uses the same image pair through NEMU's optional
`--sdcard` path.

On NPC/nsim, egos keeps its upstream translation prompt. Enter `0` to boot with
Sv32 page-table translation and exercise the RTL hardware PTW, or enter `1` to
boot with egos' software TLB path. UART RX is wired through the simulator, so
bounded smoke tests can pipe the selection and simple shell input, for example:

```bash
printf '0\npwd\n' | make -C app egos-cli-nsim ARGS="-b -n" MAX_INST=60000000 TIMEOUT=420
printf '1\n' | make -C app egos-cli-nsim ARGS="-b -n" MAX_INST=20000000 TIMEOUT=120
```

Short bounded runs may end with the simulator's timeout/max-instruction BAD TRAP
after the egos shell is reached. Check the preceding egos log and PTW counters:
`Page table translation is chosen` plus nonzero ITLB/STLB/LTLB PTW counts means
the hardware PTW path was active before the artificial limit stopped the run.

`xv6-cli-nsim` builds an unpatched temporary copy of upstream xv6-riscv as an
RV64/Sv39 kernel, objcopies `kernel/kernel` to `kernel/kernel.bin`, copies
`fs.img` to a temporary disk, and passes that image to nsim through `DISK=...` /
`--disk`. The nsim virtio-blk model keeps writes in memory, so repeated bounded
debug runs do not mutate the source `fs.img`.

The current xv6 path has passed the former paging and device blockers without
requiring xv6 source patches on nsim/NEMU:
hardware PTW A/D writeback lets xv6 run with Sv39 leaf PTEs, the nsim
virtio-blk model serves `fs.img`, RV64 CLINT/PLIC internal MMIO obeys AXI byte
lane semantics, and the nsim 16550 model raises TX-empty interrupts so xv6's
`uartwrite()` can wake after each byte. A cold bounded run reaches the shell
prompt with a 12M cycle/instruction-limit window:

```bash
make -C app/tinyos xv6-cli-nsim SYNC=0 ARGS="-b -n" MAX_INST=12000000 TIMEOUT=120
```

Expected console prefix:

```text
xv6 kernel is booting

init: starting sh
$
```

Shorter cold smoke windows around 5M-7M are useful for paging/device init, but
they do not reliably reach `init`/shell from reset in the current simulator.
For iterative debug, prefer PC checkpoints or resume from a checkpoint near the
area under test instead of extending blind cold runs. Useful bounded probes:

```bash
make -C app xv6-cli-nsim SYNC=0 ARGS="-b -n --ckpt-pc=0x80000f62 --ckpt-save=/tmp/xv6-after-kvminithart-ckpt --ckpt-save-exit" MAX_INST=7000000 TIMEOUT=140
make -C app xv6-cli-nsim SYNC=0 ARGS="-b -n --ckpt-pc=0x80000f82 --ckpt-save=/tmp/xv6-before-virtio-ckpt --ckpt-save-exit" MAX_INST=12000000 TIMEOUT=180
make -C app xv6-cli-nsim SYNC=0 ARGS="-b -n" MAX_INST=12000000 TIMEOUT=120
```

From `app/`:

```bash
# Enter upstream OS CLI via QEMU
make -C app xv6-cli-qemu
make -C app egos-cli-qemu
make -C app os-cli-qemu OS=xv6
make -C app os-cli-qemu OS=egos

# Boot OS images on NPC/nsim where supported
make -C app xv6-cli-nsim ARGS="-b -n"
make -C app egos-cli-nsim ARGS="-b -n"
make -C app egos-cli-nemu ARGS="-b -n"
make -C app os-cli-nsim OS=xv6 ARGS="-b -n"
make -C app os-cli-nsim OS=egos ARGS="-b -n"
make -C app os-cli-nemu OS=xv6 ARGS="-b -n"
make -C app os-cli-nemu OS=egos ARGS="-b -n"

# Add bounded smoke-test limits when desired
make -C app egos-cli-nsim MAX_INST=20000000 TIMEOUT=120

```

From `app/tinyos/` directly:

```bash
# Enter upstream OS CLI via QEMU
make xv6-cli-qemu
make egos-cli-qemu
make cli-qemu OS=xv6
make cli-qemu OS=egos

# Boot OS images on NPC/nsim where supported
make xv6-cli-nsim ARGS="-b -n"
make egos-cli-nsim ARGS="-b -n"
make egos-cli-nemu ARGS="-b -n"
make cli-nsim OS=xv6 ARGS="-b -n"
make cli-nsim OS=egos ARGS="-b -n"
make cli-nemu OS=xv6 ARGS="-b -n"
make cli-nemu OS=egos ARGS="-b -n"

# Add bounded smoke-test limits when desired
make egos-cli-nsim MAX_INST=20000000 TIMEOUT=120

```

## Runtime Path

The egos wrappers reuse the generic runtime support where upstream egos needs a
tiny freestanding libc surface:

- `app/lib/runtime/libc_min.c`
