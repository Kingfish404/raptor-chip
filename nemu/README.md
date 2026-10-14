# NEMU

Raptor's RISC-V instruction-set simulator, derived from
[NJU NEMU](https://github.com/NJU-ProjectN/nemu). It serves as the DiffTest
reference for the RTL simulator and as a standalone system emulator for
bare-metal programs and Linux. Only the RISC-V ISA is kept.

## Build and run

From the repository root (`make help` lists every target):

```sh
make run-nemu32          # configure, build and run riscv32_defconfig
make build-nemu32-ref    # shared reference used by RTL DiffTest (also -nemu64-ref)
make menuconfig-nemu32
make linux-boot-nemu32   # also linux-boot-nemu32gc / linux-boot-nemu64gc
```

Or directly: `cd $NEMU_HOME && make <defconfig> && make && make run`.

| Defconfig | Use |
| --- | --- |
| `riscv{32,64}_defconfig` | Standalone bare-metal/AM programs |
| `riscv{32,64}_ref_defconfig` | Shared reference for RTL DiffTest; deterministic cycle-based counters |
| `riscv{32,64}_ref_2g_defconfig` | Reference with the 2 GiB `SIM_MEM_PROFILE=large` memory map |
| `riscv{32,64}gc_linux_defconfig` | Standalone Linux, including virtio-net |
| `riscv{32,64}_riscof_defconfig` | RISCOF signature runs |

The GC Linux configurations need `libslirp-dev`. User-mode networking needs no
root or TAP device: DHCP assigns `10.0.2.15`, gateway `10.0.2.2`, DNS `10.0.2.3`.
Outbound access works; unsolicited inbound connections are not exposed.

## RISC-V model

- RV32/RV64 IMAFDC with M/S/U modes, Sv32/Sv39 and Svade.
- Zba, Zbb, Zbc, Zbs, Zcb, Zicond, Zicsr, Zifencei, Zimop, Zicbom/Zicbop/Zicboz
  (64-byte block), Zfhmin, Zihintpause and Zicntr/Zihpm.
- The shipped defconfigs match the RTL's `misa`, translation behavior, CMO
  privilege controls and counter-CSR gating. RV64 enables the RVA22S64
  execution environment; this is not a profile certification.
- `CONFIG_RV_ASID_BITS` sets the RV64 `satp.ASID` width: 16 by default (as in
  Sail), 9 in `riscv64_ref_defconfig` to match the RTL.
- RV64 `EBREAK`/`C.EBREAK` always raise a guest breakpoint. Legacy payloads that
  exit through EBREAK can enable `CONFIG_RV_EBREAK_HOST_EXIT` with
  `CONFIG_DEBUG`; RV32 debug configurations enable it by default.

Devices: CLINT, PLIC, ns16550 UART, SiFive finisher, virtio-mmio block/net/rng,
SDHCI, timer, keyboard, VGA and audio. Most are simplified models.

## Debugging

```sh
# Instruction trace with log
$NEMU_HOME/build/riscv32-nemu-interpreter -b -f -l $NEMU_HOME/build/nemu-log.txt \
  $RAPTOR_HOME/abstract-machine/app/am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin
```

The monitor provides single-step, register/memory examination, expressions,
watchpoints and snapshots. Long runs write `nemu-status.log` and
`nemu-uarch_state.json` every 100 million instructions, to `NEMU_STATUS_DIR` if
set (otherwise `$NEMU_HOME/build`). `NEMU_PC_DEBUG=1` adds periodic PC/count
messages on stderr.

## Multi-hart execution

Native system builds with CLINT support both SMP backends; select them at
runtime without rebuilding:

| Option | Default | Meaning |
| --- | --- | --- |
| `--smp=1..4` | `1` | Guest hart count |
| `--smp-backend=rr\|threaded` | `rr` | Cooperative scheduler or one pthread per hart |
| `--smp-clock-div=1..1000` | `16` | Threaded guest clock = host monotonic time / divisor |

The DTB must describe the same number of CPUs and M/S interrupt contexts.
CLINT places `msip[h]` at `base + 4*h` and `mtimecmp[h]` at `base + 0x4000 + 8*h`;
PLIC contexts `2h`/`2h+1` are hart `h`'s M/S external interrupts.

- **`rr`:** one host thread runs up to 256 instructions per hart before rotating.
  Hart switches flush the software TLB, decode cache and PMP cache. WFI yields;
  time fast-forwards only when every hart waits.
- **`threaded`:** each hart has private CPU, TLB, decode-cache, PMP-cache and
  SoftFloat state. A shared bus lock serializes RAM, page walks, MMIO, devices
  and DMA; AMO and LR/SC hold it for the whole operation. Memory is
  conservatively strongly ordered (not an RVWMO litmus model). Batch mode only;
  interactive debugging, `--maximum`, legacy `--diff`, ftrace and flash traces
  are rejected.

Stores and DMA invalidate overlapping LR/SC reservations on every hart.
Distribution boots set the hart count and backend for you:

```sh
make -C linux nemu-distro-prepare DISTRO_BOOT=debian DISTRO_HARTS=4 DISTRO_NEMU_BACKEND=threaded
make -C linux nemu-distro-check   DISTRO_BOOT=debian DISTRO_HARTS=4 DISTRO_NEMU_BACKEND=threaded
```

See [`linux/README.md`](../linux/README.md) for images, outputs and timeouts.

## Multicore DiffTest

The legacy single-hart `difftest_*` ABI used by the RTL simulator is unchanged
(`--diff-mode=legacy`, the default). The multi-hart checker compares a NEMU DUT
with a separately instantiated NEMU reference that has its own RAM, per-hart
state and device models. Both sides share the ISA interpreter, so this checks
scheduling, isolation and transaction consistency, not independent ISA
correctness, RVWMO or RTL coherence.

| Mode | Option | ABI |
| --- | --- | --- |
| Lock-step, cooperative | `--diff-mode=multihart --diff=REF_SO` (with `--smp-backend=rr`) | `include/difftest-multi.h` |
| Record a journal | `--diff-record=FILE` (`--diff-record-max-bytes`, default 256 MiB); inspect with `verify/nemu/check.py inspect FILE` | `include/difftest-journal.h` |
| Offline replay | `nemu_difftest_replay_query` from the reference `.so` (driver: `app/tests/host/nemu_journal_replay.c`) | `include/difftest-replay.h` |
| Live replay over a pipe | `--diff-stream-fd=N`, driven by `verify/nemu/check.py supervise` | `include/difftest-replay.h` |

The journal records each hart's instruction begin/retirement, every physical
access inside outer bus-lock scopes, and the inputs a profile admits. The
reference re-executes at suboperation granularity, checks addresses, widths and
store data before writing its own RAM, compares load values and full
retirement state, and never copies DUT state to recover from a mismatch.
Any unmodeled MMIO, DMA, time read or interrupt fails the run instead of being
skipped. `--diff-progress=N` prints capture counters every N retirements.

Each runtime profile builds on the rows above it (versions 2–5 imply their
predecessors; versions 6–9 require them) and raises the journal version.
Readers reject versions they do not understand:

| Option | Version | Adds |
| --- | --- | --- |
| (none) | 1 | Memory-only: RAM/ROM, frozen time, no devices |
| `--diff-interrupts` | 2 | CPU interrupt selection and WFI |
| `--diff-clint` | 3 | CLINT registers and raw clock samples |
| `--diff-plic` (`--diff-plic-input=FILE`) | 4 | PLIC registers and external source pulses |
| `--diff-uart` (`--diff-uart-input=FILE`, `--diff-uart-stdin`) | 5 | ns16550 RX/TX and its IRQ |
| `--diff-tlb=retain` | 6 | Per-hart TLBs kept across instructions (threaded only) |
| `--diff-rng` (`--diff-rng-input=FILE`) | 7 | virtio-rng and synchronous DMA |
| `--diff-net` (`--diff-net-backend=slirp\|script`, `--diff-net-input=FILE`) | 8 | virtio-net TX/RX and asynchronous DMA |
| `--diff-block` (with `--disk=FILE`) | 9 | virtio-blk with an independent disk-image copy |

Only raw environment inputs (clock samples, source pulses, UART/entropy/network
bytes, the initial disk image) are replayed; device registers, DMA, used-ring
updates and derived interrupts are recomputed by the reference. The device
models reproduce NEMU's simplified devices; they are not full PLIC, 16550 or
virtio conformance models.

### Checks

All NEMU checks are `make -C verify nemu-*-check` targets defined in
[`verify/nemu/nemu.mk`](../verify/nemu/nemu.mk); each runs
`verify/nemu/check.py NAME` (`check.py NAME --help` lists its options).

| Target | Coverage |
| --- | --- |
| `nemu-unit-check` | Python unit tests for the journal/device models and supervisor (fast) |
| `nemu-smp-check` | SMP execution on both backends, device harnesses and option validation |
| `nemu-lockstep-check` | Lock-step multi-hart ABI (`--diff-mode=multihart`) |
| `nemu-journal-check` | Journal capture and the memory-consistency checker |
| `nemu-replay-check` / `nemu-stream-check` | Offline / live ISA replay and transport failures |
| `nemu-{irq,clint,plic,uart,tlb,rng,net,block}-check` | Per-profile replay (journal versions 2–9) |
| `nemu-dma-check`, `nemu-finisher-check`, `nemu-console-check` | DMA failure paths, finisher, UART routing |
| `nemu-multihart-check` | All of the above |
| `nemu-distro-check` | Full Debian/Ubuntu boot under live DiffTest (long) |
| `nemu-isa-check` | Single-hart ISA/MMU/PMP/memory-map checks (`verify/nemu/isa/`) |

The multi-hart checks cover RV32/RV64 with 1/2/4 harts and inject corruptions
that must be rejected. `NEMU_SANITIZE=undefined|thread` builds NEMU with a
sanitizer (add `NEMU_TSAN_NO_ASLR=1` for TSan) and `NEMU_REPEAT` sets threaded
repetitions. Results go to `verify/build/nemu-*`. For the distribution check,
set `NEMU_DISTRO_PREPARED` to a prepared image directory (default: two-hart
threaded Debian) and `NEMU_DISTRO_TIMEOUT` (default 3600 s); a pass requires
both endpoints to complete, matching totals, userspace checks and a clean
poweroff. The reference-library ISA checks need `make build-nemu32-ref
build-nemu64-ref` first.
