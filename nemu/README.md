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

NEMU's Makefile also works directly, without `env.sh`, `NEMU_HOME`, or the
parent project's Makefile. Keep native and reference configurations separate:

```sh
make -C nemu O=build/linux64 riscv64gc_linux_defconfig
make -C nemu O=build/linux64 -j4
make -C nemu reference REF_DEFCONFIG=riscv64_ref_defconfig -j4
```

`O` is relative to the NEMU directory (absolute paths also work). Configuration,
generated headers, Kconfig/fixdep tools and objects stay there; the source
directory's interactive `.config` is unchanged. Run configuration and compilation
as separate commands. The native binary above is
`nemu/build/linux64/build/riscv64-nemu-interpreter`; the reference is
`nemu/build/ref/riscv64_ref_defconfig/riscv64-nemu-interpreter-so`.
Omit `O` to use the existing in-source workflow. `reference` already manages
private directories and must not be combined with `O`.

Build prerequisites are GNU make 4.3+, GCC/G++, flex, bison and readline development
headers. Floating-point execution uses the SoftFloat sources/archive under
`tools/spike-diff/repo`; the dependency rule fetches Spike if missing and
initializes its recursive submodules, including Berkeley SoftFloat. Existing
checkouts from an interrupted bootstrap are initialized on retry as well
(network access and Spike's configure dependencies are then needed). SDL2 is only
required for keyboard, audio or graphical-display configurations, not headless
Linux or shared-reference builds. `menuconfig` additionally needs ncurses.
Device-tree generation requires `dtc`.
Private reference builds also use `flock` for build serialization. Configuration,
help and cleanup do not require the currently selected SDL/slirp dependencies.

| Defconfig | Use |
| --- | --- |
| `riscv{32,64}_defconfig` | Standalone bare-metal/AM programs |
| `riscv{32,64}_ref_defconfig` | Shared reference for RTL DiffTest; deterministic cycle-based counters |
| `riscv{32,64}_ref_2g_defconfig` | Reference with the 2 GiB `SIM_MEM_PROFILE=large` memory map |
| `riscv{32,64}gc_linux_defconfig` | Standalone Linux, including virtio-net |
| `riscv{32,64}_vm_defconfig` | Headless: RV32 256 MiB / RV64 1 GiB RAM, UART, timers, disk, network, RNG |
| `riscv{32,64}_riscof_defconfig` | RISCOF signature runs |

The GC Linux configurations need `libslirp-dev`. User-mode networking needs no
root or TAP device: DHCP assigns `10.0.2.15`, gateway `10.0.2.2`, DNS `10.0.2.3`.
Outbound access works; incoming connections require an explicit loopback forwarding rule.

### Installable application

Build and install a headless emulator with a relocatable `nemu` launcher:

```sh
make -C nemu O=build/vm64 riscv64_vm_defconfig
make -C nemu O=build/vm64 -j4
make -C nemu O=build/vm64 install PREFIX="$HOME/.local"
"$HOME/.local/bin/nemu" info
"$HOME/.local/bin/nemu" run --firmware /path/to/fw_payload.bin \
  --disk /path/to/rootfs.raw --harts 2 --state-dir /path/to/new-run
```

The last command defaults to **volatile disk writes**. Add
`--disk-mode=persistent` only when you intend to modify that image, or
`--disk-mode=readonly` for a clean read-only filesystem. `--append '...'`
replaces the entire Linux command line. Without it, a disk attachment selects
`root=/dev/vda rootwait rw` (`ro` in read-only mode), plus serial console and
bootloader entropy options; a payload with an embedded initramfs can omit
`--disk`. Supply a firmware payload and root filesystem built for the selected
XLEN. The launcher does not build/download operating systems or combine a
separate `-bios`, `-kernel` and initrd.

Runtime requirements are Python 3.8+, `dtc`, and the native executable's shared
libraries (including readline and libslirp for these presets). No root, TAP,
repository checkout or `NEMU_HOME` is needed at runtime. Firmware and disk paths
are resolved before starting the guest. The launcher queries the **actual
binary** with `--describe` and generates a DTB matching its RAM, peripherals,
ISA profile and requested harts; it does not read sibling `linux/dts` files.
RAM size is a **build-time** setting, not a runtime `--memory` promise. Use
`O=... menuconfig` and rebuild to change it.

`--harts=1..4` and `--backend=rr|threaded` select execution. RV64
`--isa-profile=rva23` requires `rr`; the launcher rejects incompatible choices
before launching. `nemu info --xlen 32` and `nemu run --xlen 32 ...` select an
installed RV32 build. Use `--emulator /path/to/binary` with either subcommand
to work directly with an uninstalled build, for example
`python3 nemu/tools/nemu.py info --emulator nemu/build/vm64/build/riscv64-nemu-interpreter`.

`--dry-run` validates inputs and compiles the DTB without starting the guest,
binding forwarding ports or opening the disk for writes; it does not guarantee later port/file-lock availability
or firmware compatibility. `--state-dir` must name a **new** directory and
retains `machine.dts`, `machine.dtb`, `run.json`, `nemu.log` and `result.json`.
Without it, temporary run files are removed on exit. UART input/output stays
attached to the invoking terminal; the launcher forwards INT/TERM/HUP and
returns the emulator's exit status. Prefer guest shutdown: terminating a
persistent VM abruptly can leave a dirty filesystem. Console output is not
duplicated into a separate console transcript; redirect it when needed.

Installation supports `DESTDIR` staging and relocation of the whole prefix:

```sh
make -C nemu O=build/vm64 install PREFIX=/opt/nemu DESTDIR="$PWD/package"
make -C nemu O=build/ref64 riscv64_ref_defconfig
make -C nemu O=build/ref64 -j4 install PREFIX=/opt/nemu DESTDIR="$PWD/package"
```

Native binaries go in `libexec/nemu/`, reference libraries in `lib/nemu/`, and
per-build configuration provenance in `share/nemu/configs/`. Reference installs
also include the public `difftest-*.h` headers and their generated configuration
dependencies under `include/nemu/riscv64-nemu-interpreter-so/` (likewise RV32).
Use that directory as a compiler include path; load the installed reference
by its full path. Prefer the versioned `nemu_difftest_query`/ISA/vector/replay
interfaces for new integrations. The legacy `difftest_regcpy` uses Raptor's
pointer-based `NPCState`, **not** the generic upstream flat register layout.
Different configurations of the same XLEN overwrite the same installation
slot; use separate prefixes when keeping multiple variants. Instruction-traced
builds are rejected by `install` because their Capstone loader still uses a
source-tree-relative path. Existing in-tree traced workflows are unchanged.

### Standalone execution and VM boundaries

The executable can run from any directory when given explicit image and DTB
paths. For example, after the private Linux build above:

```sh
nemu/build/linux64/build/riscv64-nemu-interpreter -b \
  -t /absolute/path/to/platform.dtb /absolute/path/to/fw_payload.bin
```

The payload is a raw image loaded into RAM, normally OpenSBI with an embedded
Linux kernel, not an arbitrary ELF or a QEMU `-kernel` argument. The DTB must
match the configured RAM, devices, ISA and runtime hart count. In this repository
the canonical DTS files remain in `linux/dts`; a detached NEMU source tree can
use an external DTS directory via `NEMU_DTS_DIR=/absolute/path/to/dts` when
generating its configured default DTB. Supplying `-t` directly avoids depending
on the default relative DTB path at runtime. Firmware, kernels and disk images
are separate inputs, not included in the emulator build.
The installed launcher above automates this DTB setup; the low-level executable
remains available for custom platforms, monitoring and DiffTest options.

NEMU is currently a small system emulator, not a drop-in QEMU replacement:
VM save/restore and finisher-driven guest reboot are not implemented, and device
models are simplified. Disk writes are volatile unless explicitly configured
otherwise, as described below.
Do not treat it as a security boundary for untrusted guests. The DiffTest
interfaces and deterministic replay are separate from ordinary interactive
VM execution; select only the replay-supported device inputs when checking.

### Disk images and persistence

With `CONFIG_HAS_DISK=y`, `--disk=/path/to/image` attaches one **raw** image to
virtio-mmio at `0x10001000`, IRQ 1. Enable the disk in `menuconfig` when starting
from a GC Linux defconfig; those presets do not enable it by default. The DTB
must describe this device, for example the `linux/dts/nemu-distro-rv64.dts`
platform used by the distribution workflow. A qcow2 image must be converted to
raw first; NEMU does not interpret qcow2 metadata.
The VM presets already enable the disk, and `nemu run --disk ...` adds its node
to the generated device tree automatically.

| `--disk-mode` | Guest behavior | Host storage |
| --- | --- | --- |
| `volatile` (default) | Writable private snapshot | Entire image copied to RAM; all changes discarded on exit |
| `readonly` | Advertises a read-only disk; writes fail | Reads the file on demand; no whole-image RAM allocation |
| `persistent` | Writable disk with cache-flush support | Writes the supplied file directly; no whole-image RAM allocation |

For example, on an emulator built with disk support:

```sh
"$NEMU" -b --disk=/absolute/path/to/rootfs.raw --disk-mode=persistent \
  -t /absolute/path/to/platform.dtb /absolute/path/to/fw_payload.bin
```

**Persistent mode modifies the original file. Use a disposable copy when testing.**
Images must be existing, nonempty regular files; NEMU never creates or truncates
them. Writers take an exclusive advisory file lock; volatile and read-only
readers take shared locks. A conflicting attachment fails rather than waiting.
Do not mount, truncate or modify an attached image with other host tools: advisory
locks do not prevent non-cooperating processes from changing it.

Persistent storage implements the
[Virtio 1.2 block flush contract](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html):
negotiated flush requests call host `fsync` before successful completion. If the
driver does not negotiate flush support, each completed write is synchronized
before acknowledgment. Short transfers and interrupted host calls are handled;
read/write/flush failures become guest I/O errors. Guest `fsync`/`sync` and clean
poweroff remain necessary for filesystem consistency; unflushed writes are not
promised to survive host failure. A read-only Linux root must use `ro` in its
kernel command line and have a cleanly unmounted filesystem. In particular,
[ext4 journal recovery can require writes even for a read-only mount](https://www.kernel.org/doc/html/v6.6/admin-guide/ext4.html);
powering off a custom PID 1 should first sync and cleanly remount the root
read-only, rather than merely invoke the reboot syscall.

DiffTest and journal modes currently accept only `volatile`, preserving the
existing v9 block-device format and independent reference image. Other disk
modes are rejected before opening an image when comparison or recording is
requested; they are not silently skipped.

`make -C verify nemu-storage-check` exercises RV32/RV64 disk modes on both SMP
backends, host-file retention, a second invocation, invalid inputs and lock
conflicts. `make -C verify nemu-storage-linux-check
NEMU_STORAGE_LINUX_PREPARED=/path/to/prepared/distro` reuses hash-verified firmware
from `linux/distro_boot.py prepare` and creates a private 64-MiB ext4 root. Four
Linux boots check discarded volatile writes, persistent creation and `fsync`,
retention on restart, and read-only reopening with unchanged host bytes. It
does not modify the prepared distribution image. This check needs the RV64
Linux cross-compiler, `mkfs.ext4`, `debugfs` and device-tree tools.
Set `NEMU_STORAGE_LINUX_LAUNCHER=/path/to/installed/bin/nemu` to test the installed
application and its generated device tree instead of a private native build.

### Host-to-guest networking

The launcher and native executable accept repeated
`--hostfwd=tcp:HOST_PORT:GUEST_PORT` options.
For example, to reach an SSH server already installed and enabled in the guest:

```sh
nemu run --firmware /path/to/fw_payload.bin --disk /path/to/rootfs.raw \
  --hostfwd=tcp:2222:22
ssh -p 2222 guest-user@127.0.0.1
```

Run SSH in another host terminal after the guest is ready. Forwarding does not
install, start or authenticate guest services. The guest must use `10.0.2.15`
(DHCP or static configuration) and allow the service through its own firewall.
Rules bind **only `127.0.0.1`**, never wildcard/LAN addresses, and are released
when the emulator exits. Other local host users can also reach these ports;
retain normal service authentication. No root or TAP setup is required for
unprivileged host ports. Up to 16 TCP rules are accepted; ports must be
decimal integers from 1 through 65535. Duplicate host ports and
unavailable host ports fail explicitly instead of silently disabling forwarding.
No ports are forwarded by default.
UDP forwarding is deliberately unsupported: with the tested libslirp 4.7.0,
its replies conflict with the existing guest-to-host loopback access restriction.
NEMU retains that restriction rather than enabling general access to host-local
services merely to make UDP forwarding work. Ordinary outbound UDP is unchanged.

Forwarding is also supported by slirp journal capture with `--diff-net`: actual
incoming packets are recorded and independently replayed offline without host
sockets. Scripted networking, legacy/strict DiffTest, and captures without
network checking reject forwarding before guest startup.
`make -C verify nemu-net-check` includes RV32/RV64 forwarding validation, an
actual TCP SYN capture/replay and port-release checks; it needs loopback
socket access, but no external network. Add `NEMU_STORAGE_LINUX_NETWORK=1` to
`nemu-storage-linux-check` to check an 8192-byte TCP round trip
on each of its four real Linux boots. This reuses the storage probe and
requires built-in kernel `CONFIG_NET`, `CONFIG_INET` and `CONFIG_VIRTIO_NET`.

## Architecture

| Area | Responsibility |
| --- | --- |
| `tools/nemu.py`, `scripts/install.mk` | Relocatable application layout, input validation, capability-driven DTB generation and VM process lifecycle |
| `src/monitor`, `src/engine` | Startup options, image loading, interactive monitor and interpreter entry |
| `src/cpu`, `src/isa/riscv` | Execution, hart scheduling, architectural state, instruction semantics, traps and address translation |
| `src/memory`, `src/device/io` | Physical memory, access checks and MMIO routing; devices use checked guest-memory access for DMA |
| `src/device` | CLINT/PLIC, UART, virtio and other platform devices; host I/O stays outside instruction semantics |
| `src/device/block-image.c` | Raw-file lifetime, locking, volatile snapshots, bounded file I/O and flushes, separate from virtqueue handling |
| `src/cpu/difftest`, `include/difftest-*.h` | Legacy RTL ABI, versioned multi-hart/state sidecars, journals and replay |
| `scripts`, `configs` | Build isolation and compile-time platform choices; runtime CLI options select supported modes |

Guest clocks drive architectural counters and interrupts; host monotonic time
measures emulator execution. Keep these domains separate. Additional architectural
state belongs in versioned DiffTest sidecars rather than extending the legacy
RTL state layout. Device inputs admitted by replay must be captured explicitly;
unsupported I/O must fail rather than silently bypass comparison.

## RISC-V model

- RV32/RV64 IMAFDC with M/S/U modes, Sv32/Sv39 and Svade.
- Zba, Zbb, Zbc, Zbs, Zcb, Zicond, Zicsr, Zifencei, Zimop, Zicbom/Zicbop/Zicboz
  (64-byte block), Zfhmin, Zihintpause and Zicntr/Zihpm.
- The shipped defconfigs match the RTL's `misa`, translation behavior, CMO
  privilege controls and counter-CSR gating. RV64 enables the RVA22S64
  execution environment used as the reference for the default RV64 RTL configuration.
- `CONFIG_RV_ASID_BITS` sets the RV64 `satp.ASID` width: 16 by default (as in
  Sail), 9 in `riscv64_ref_defconfig` to match the RTL.
- RV64 `EBREAK`/`C.EBREAK` always raise a guest breakpoint. Legacy payloads that
  exit through EBREAK can enable `CONFIG_RV_EBREAK_HOST_EXIT` with
  `CONFIG_DEBUG`; RV32 debug configurations enable it by default.

Devices: CLINT, PLIC, ns16550 UART, SiFive finisher, virtio-mmio block/net/rng,
SDHCI, timer, keyboard, VGA and audio. Most are simplified models.

### Runtime ISA profile

`--isa-extensions=none|rva23` selects the runtime ISA mode before initialization.
`none` is the default and preserves the RTL DiffTest reference behavior.
`rva23` enables the RVA23U64/S64 functional model;
individual extension names and comma-separated lists are not accepted by the
command line. It requires an RV64 system build with F, D, Svade and
`CONFIG_TIMER_CYCLE`, using the `rr` execution backend rather than the
host-wall-clock `threaded` backend;
RV32 builds accept only `none`. Repeating the option replaces the previous mode.
The ratified [RVA23 profiles](https://docs.riscv.org/reference/rva23/v1.0/rva23-profiles.html)
define only U64 and S64 variants.

The current `rva23` mode adds Svnapot, Zawrs, Zfa, Ssnpm/Smnpm, Sscofpmf,
Smstateen, V with VLEN=128/ELEN=64, Zvbb, Zvfhmin, and H with VS/VU execution
and two-stage translation. The base RV64 model also implements Zicond, Zimop/Zcmop,
Zcb, Zicbop and Svinval.
The vector implementation includes integer, fixed-point, FP32/FP64 arithmetic,
reductions, conversions, permutations, masks and vector memory operations;
unsupported extension encodings trap. Ordinary vector loads and stores support misaligned main-memory
accesses, including split-page elements; whole-register transfers retain their
encoded alignment requirement. Memory-type and protection checks still apply.
Zvfhmin currently covers half/single widening and narrowing
conversions, not full Zvfh. Zfa does not provide Zfh/Q formats without those
extensions. H includes Sv39/Sv39x4 guest translation, HLV/HLVX/HSV,
virtual interrupts, virtual timers, hypervisor CSRs and trap delegation.
Enabling vector state in a build with F and D sets the read-only `misa.V` bit;
enabling H on RV64 sets `misa.H`. The extension-free default keeps both clear.
This is a software execution model, **not** an RVA23 certification.
The optional NEMU-only device tree advertises individual implemented extensions,
not a complete-profile compatibility claim.

The NEMU RVA23 platform models Zkt/Zvkt using data-independent virtual cycles:
each completed instruction advances `mcycle` by one, and the native platform's
CLINT clock follows the instruction count. `nemu-rva23-diel-check` exercises
the implemented scalar Zkt subset in M/S/U modes; `nemu-rva23-vector-check`
checks vector arithmetic against Spike and verifies virtual-cycle accounting
across operand samples. `nemu-rva23-runtime-check` also checks native cycle and
CLINT deltas while varying scalar/vector data. These are functional simulation
guarantees, **not** constant host execution time or a cryptographic side-channel
security certification. No timing or performance conclusion about RTL follows
from these checks.

#### Mandatory-feature coverage

The table maps the ratified profile requirements to the model and focused
single-hart checks. Check names abbreviate `make -C verify nemu-NAME-check`;
`rva23-scalar` runs the scalar suite with the entire runtime profile enabled.
The model is little-endian, uses Svade rather than hardware A/D updates, and
provides Sv39/Sv39x4 rather than optional Sv48/Sv57. Optional vector crypto,
full Zfh/Zvfh, Zacas and Zabha are not implied by selecting this profile.

| Mandatory features | Model and checks |
| --- | --- |
| RV64I, M, A, F, D, C, B, Zicsr, Zifencei | Scalar, atomic, FP and compressed execution; `rva23-scalar`, `compressed`, `zcb` |
| Zicntr, Zihpm, Sscounterenw, Shcounterenw | Counter access gating; 29 legal read-only-zero HPM counters; `counter-trap`, `rva23-profile` |
| Ziccif, Ziccrse, Ziccamoa, Za64rs | Main RAM permits aligned atomic fetch and A operations; LR/SC reservations are naturally aligned 4/8-byte regions with eventual success absent interference; `rva23-scalar`, `rva23-profile` |
| Zicclsm | Scalar/vector misaligned main-memory access, including page crossings; `rva23-scalar`, `vector-misaligned` |
| Zic64b, Zicbom, Zicbop, Zicboz | 64-byte blocks, permission-checked management/zeroing and non-faulting prefetch hints; `rva23-scalar`, `zicbop`, `rva23-linux` |
| Zihintpause, Zihintntl, Zicond, Zimop, Zcmop, Zcb | Hints, conditional zero, may-be operations and compressed operations; `rva23-scalar`, `zicond`, `mop`, `zcb` |
| Zfhmin, Zfa, Zawrs | Half/single conversions, additional FP operations and reservation waits; `rva23-scalar`, `zfa`, `zawrs` |
| V, Zvbb, Zvfhmin | VLEN=128, ELEN=64, vector integer/FP/memory and minimal half conversions; `rva23-vector`, `vector-memory-spike`, `vector-data`, `zvbb`, `zvfhmin` |
| Zkt, Zvkt | Data-independent simulated cycles, not host latency; `rva23-diel`, `rva23-vector`, `rva23-runtime` |
| Supm, Ssnpm | User pointer masking with PMLEN=0/7/16, including VS/VU and vector memory; `pointer-mask`, `rva23-profile`, `rva23-linux` |
| Ss1p13, Svbare, Sv39, Svade, Ssccptr | Supervisor traps, returns, page-table reads and permission checks; `trap-delegation`, `sv39-permissions`, `sv39-superpage`, `rva23-profile` |
| Sstvecd, Sstvala, Ssu64xl | Direct trap vectors, fault address/instruction reporting and 64-bit UXL; `rva23-profile`, `physical-address`, `h-gstage` |
| Svpbmt, Svinval, Svnapot | Page memory types, invalidation and 64-KiB NAPOT mappings; `svpbmt`, `svpbmt-access`, `svinval`, `svnapot` |
| Sstc, Sscofpmf | Supervisor/virtual timers, zero HPM events and overflow CSR/interrupt behavior; `rva23-runtime`, `sscofpmf`, `h-gstage` |
| Sha: H, Ssstateen, Shvstvala, Shtvala, Shvstvecd, Shvsatpa, Shgatpa | VS/VU, two-stage translation, state-enable controls, guest trap metadata, direct vectors and matching Bare/Sv39 modes; `h-gstage`, `smstateen`, `rva23-profile`, `hypervisor-runtime`, `rva23-linux` |

This coverage does not constitute exhaustive architectural proof, an RVWMO
litmus-model validation, or RTL implementation of these features.

The legacy DiffTest state ABI is unchanged. The reference's
`nemu_difftest_isa_query` API reports its internal capability mask and lets
test harnesses configure that mask before `difftest_init`; unsupported bits
or configuration after initialization are rejected. Existing RTL hosts use
the default extension-free reference. When vector state is enabled,
`nemu_difftest_vector_query` exposes all 32 128-bit registers through a
versioned sidecar without changing the legacy state layout. The internal mask
remains available for focused ISA and DiffTest tests; it is not a set of
user-facing CLI switches. The existing `NEMU_ISA_EXT_V128_PREVIEW` and
`NEMU_ISA_EXT_H_GSTAGE_PREVIEW` bit names and values remain unchanged for API
compatibility.

Single-hart checks are available through `make -C verify nemu-isa-check`
after building the RV32/RV64 reference libraries. Focused targets are defined
in [`verify/nemu/nemu.mk`](../verify/nemu/nemu.mk), including
`nemu-vector-misaligned-check` for RVA23 memory accesses and fault restart.
These checks exercise implemented behavior and illegal encodings, but do not establish complete
RVA23 conformance.

For Linux, `make linux-boot-nemu-rva23` selects the runtime bundle and the
`linux/dts/spike-rva23-nemu.dts` platform. Set `NEMU_RVA23_HARTS=1..4`
(default 1) to generate matching CPU and CLINT/PLIC topology in a private
build directory. `make linux-nemu-rva23-dtb` generates just the device tree.
The boot target uses the existing
`LINUX_RV64GC_PAYLOAD` selection; supply an OpenSBI payload containing a kernel
with the desired extension support. The shared RTL/legacy device trees and
default DiffTest mode are unchanged. The NEMU tree describes 256 MiB of RAM,
Sv39, 64-byte cache-block operations, V and H, and a poweroff finisher.

An isolated Linux smoke test is available with:

```sh
make -C verify nemu-rva23-linux-check NEMU_RVA23_KERNEL=/absolute/path/to/Image
```

This requires `dtc`, `fdtput`, `riscv64-linux-gnu-gcc`, the bundled OpenSBI
sources, and an RV64 kernel with V, SUPM, Zicboz, KVM, devtmpfs, initrd and syscon-poweroff
support. The kernel's embedded initramfs must provide `/dev` and `/dev/console`.
The runner privately builds NEMU, OpenSBI and a freestanding PID 1 probe, then
boots one hart. It checks Linux's extension discovery, unaligned user vector
arithmetic, 64-byte user cache-block zeroing, tagged user loads/stores, and one
KVM vCPU's execution and MMIO exit.
It requires every probe marker and clean finisher poweroff; panic, timeout and
partial success fail. Logs and artifact hashes are written under
`verify/build/nemu-rva23-linux/run-*/`. Override
`NEMU_RVA23_LINUX_TIMEOUT` for slower hosts (default 1800 seconds).
This is an integration smoke test, not full kernel or RVA23 compliance coverage.

Set `NEMU_RVA23_HARTS=2`, `3` or `4` on the same check to boot SMP Linux.
The probe requires the exact online CPU mask, starts two processes pinned to
each CPU, and uses shared-memory rendezvous to force timer preemption while
vector/FCSR/VCSR state is live. Each worker also exercises V, cache-block
zeroing, pointer masking and a private KVM VM/vCPU. Every worker must exit
successfully before the SMP marker and clean poweroff are accepted.
The live-vector section intentionally makes no system calls: the
[Linux vector ABI](https://docs.kernel.org/arch/riscv/vector.html) permits
syscalls to discard caller-saved vector state.

`make -C verify nemu-rva23-multihart-check` checks 2/3/4-hart combined-profile
execution, native completion, strict memory lock-step, offline replay and
bounded-pipe live replay. It covers per-hart vector/FP state, H/Svnapot/PMM,
state-enable and overflow CSRs, shared atomics and cross-hart LR/SC invalidation.
The shared-memory payload checks vector stores, 64-byte CBO.ZERO and AMOs
against another hart's live reservation and checks all surrounding words;
omitting the vector store is a required failing negative control.
CLINT/IPI/Sstc and virtual timers (including per-hart `htimedelta`) use the
clock-aware replay path rather than the memory-only lock-step mode. Corrupted
vector, FCSR, H-status, pointer-mask and restart state must be rejected offline
and live. Run with `NEMU_SANITIZE=undefined` for instrumented native/reference
builds. The profile uses `rr` for both single- and multi-hart execution;
`threaded` remains a wall-clock backend and is rejected in named RVA23 mode.
These checks validate scheduling and state/transaction consistency; DUT and
reference share the ISA interpreter, so they complement rather than replace
the independent single-hart Spike checks.

Instead of supplying an existing Image, set
`NEMU_RVA23_KERNEL_PACKAGE=/path/to/pinned/rv64/release` (leave
`NEMU_RVA23_KERNEL` unset). The check builds a private `nemu-rva23` kernel from
the release's hash-verified source and configuration. This enables V, SUPM,
Svnapot/Svpbmt, Zawrs, Zba/Zbb, cache-block operations and KVM, and verifies
the resolved configuration before building. The minimal built-in initramfs
provides the console; the external test initramfs supplies PID 1.
The cached kernel does not replace the release Image or alter the sim/FPGA
kernel configurations. The boot timeout excludes kernel compilation.

Independent single-hart vector checks are available as
`make -C verify nemu-vector-spike-check nemu-vector-memory-spike-check`.
They require the bundled Spike libraries (build them with
`make -C nemu/tools/spike-diff repo/build/spike`) and a C++20 compiler.
The arithmetic check covers the pinned V opcode table and Zvbb over supported
SEW/LMUL combinations, masks, rounding modes and deterministic operand samples.
The memory check covers unit, strided, indexed, segmented, fault-only-first,
mask and whole-register transfers in private RAM. It separately validates
NEMU's permitted whole-register alignment traps. Both compare vector state;
arithmetic also compares scalar results and flags, and memory compares RAM.
These checks do not establish privileged, MMU or full-profile conformance.

`make -C verify nemu-hypervisor-runtime-check` runs a single-hart HS/VS payload
on native NEMU and the bundled Spike executable. It exercises state-enable
CSRs, Sv39/Sv39x4, HLV/HSV, delegated traps, guest-page faults, virtual
instructions, virtual software/timer interrupts and guest vector execution.
The payload checks `stval`, `vstval`, `htval`, guest state and return paths;
an injected guest failure must fail on both models. The default
`nemu-h-gstage-check` is single-hart; its `check.py h-gstage --multihart` option
separately enables two-hart state-copy tests.

## Debugging

```sh
# Instruction trace with log
$NEMU_HOME/build/riscv32-nemu-interpreter -b -f -l $NEMU_HOME/build/nemu-log.txt \
  $RAPTOR_HOME/abstract-machine/app/am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin
```

The monitor provides single-step, register/memory examination, expressions and
watchpoints. Long runs write `nemu-status.log` and
`nemu-uarch_state.json` every 100 million instructions, to `NEMU_STATUS_DIR` if
set (otherwise `$NEMU_HOME/build`). `NEMU_PC_DEBUG=1` adds periodic PC/count
messages on stderr.

Execution-time and instructions-per-second diagnostics use the host monotonic
clock, excluding time spent at the interactive prompt. Guest time remains
instruction-based or backend-scaled according to the selected configuration;
status dumps label these clocks separately. These are emulator throughput
measurements, not guest processor frequency or RTL performance estimates.
Instruction totals count executed instruction attempts (including traps), not
idle-clock fast-forward steps. The latter remain separately reported as guest
clock steps; the existing JSON `inst_cnt` retains that legacy count, with
`executed_inst_cnt` providing the actual execution count.

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

Tests are grouped by responsibility rather than adding one wrapper per feature:
`tests/test_application.py` covers build/install/launch; `test_storage.py` covers
block replay, host images, virtio completions and Linux storage supervision;
`test_platform.py` covers clocks and the RVA23 Linux platform; `test_difftest.py`
covers state capture/deltas and replay fault injection. Dedicated network,
journal and stream suites remain separate.
`isa/vector_units_rtl.py` shares reference setup, Verilator execution and result
reporting for eight vector unit checks, while preserving their independent
case generators, RTL testbenches, command names and result directories.
Virtio block/network/RNG guest programs share `nemu_virtio_start.S`.
Extend the relevant suite or case table first; keep distinct tests separate
when their fixtures or correctness oracles genuinely differ.

| Target | Coverage |
| --- | --- |
| `nemu-unit-check` | Python unit tests for the journal/device models and supervisor (fast) |
| `nemu-application-check` | Build/install/relocate both VM presets and reference SDKs; installed headers/ABI, capability JSON, RV32/RV64 SMP boot and RVA23 launch |
| `nemu-smp-check` | SMP execution on both backends, device harnesses and option validation |
| `nemu-stats-check` | RV32/RV64 host throughput and executed-instruction accounting across RR idle-clock jumps and threaded WFI |
| `nemu-storage-check` | Standalone volatile/read-only/persistent disk modes, reopen retention, CLI validation and file locks on RV32/RV64 RR/threaded |
| `nemu-storage-linux-check` | Real Linux/ext4 file persistence over separate boots, volatile discard and read-only protection |
| `nemu-lockstep-check` | Lock-step multi-hart ABI (`--diff-mode=multihart`) |
| `nemu-journal-check` | Journal capture and the memory-consistency checker |
| `nemu-replay-check` / `nemu-stream-check` | Offline / live ISA replay and transport failures |
| `nemu-{irq,clint,plic,uart,tlb,rng,net,block}-check` | Per-profile replay (journal versions 2–9) |
| `nemu-dma-check`, `nemu-finisher-check`, `nemu-console-check` | DMA failure paths, finisher, UART routing |
| `nemu-multihart-check` | SMP, statistics, storage and lock-step/journal/device checks (not application packaging or Linux boot) |
| `nemu-distro-check` | Full Debian/Ubuntu boot under live DiffTest (long) |
| `nemu-isa-check` | Single-hart ISA/MMU/PMP/memory-map checks (`verify/nemu/isa/`) |
| `nemu-rva23-profile-check` | RV64 combined profile-mask selection, ABI locking, vector-control/Zicond smoke, Sstc CSR gating, DiffTest STIP delivery, tagged U-mode vector load and M/HS `hstatus.GVA` reads/writes |
| `nemu-rva23-scalar-check` | Mandatory base scalar, FP, atomic, CSR and cache-block regressions with the entire RVA23 extension bundle enabled |
| `nemu-rva23-diel-check` | Scalar Zkt subset: M/S/U instruction retirement and data-independent virtual-cycle accounting |
| `nemu-rva23-vector-check` | All enabled vector arithmetic against Spike in combined RVA23 mode, including virtual-cycle accounting |
| `nemu-rva23-runtime-check` | RV64 single-hart native boot: unaligned vector transfers, `hstatus.GVA`, live Sstc timing, data-independent virtual-cycle/CLINT deltas and unsupported-clock rejection |
| `nemu-rva23-multihart-check` | RV64 2/3/4-hart combined-profile isolation, shared atomics, timers, lock-step and offline/live replay with injected state corruption |
| `nemu-rva23-linux-check` | Linux extension discovery, user V/Supm/Zicboz and KVM; `NEMU_RVA23_HARTS=2..4` also checks pinned workers and preempted FP/vector state; accepts `NEMU_RVA23_KERNEL` or `NEMU_RVA23_KERNEL_PACKAGE` |
| `nemu-hypervisor-runtime-check` | RV64 single-hart HS/VS payload on NEMU and Spike: two-stage translation, HLV/HSV, delegated traps, virtual instructions/interrupts/timers, guest vectors and injected guest failure |
| `nemu-svnapot-check` | Runtime reference ABI, Svnapot translations/faults and disabled/RV32 compatibility |
| `nemu-svinval-check` | RV32/RV64 Svinval privilege and TVM rules, plus retained-TLB remapping through `SFENCE.W.INVAL`/`SINVAL.VMA`/`SFENCE.INVAL.IR` |
| `nemu-h-gstage-check` | Disabled/RV32 rejection and RV64 opt-in VS/G-stage HLV/HLVX/HSV, MPRV/MPV guest memory, VS/VU entry and two-stage faults, VS interrupt/timer CSR aliases, virtual-instruction controls, synchronous `hedeleg`, `vstval` and xRET, PBMT/MMIO, PMM and fences |
| `nemu-zawrs-check` | RV32/RV64 Zawrs decode, TW/privilege checks, RV64 VTW interception, retirement and reservation preservation |
| `nemu-zfa-check` | RV32/RV64 Zfa constants, bit/rational result oracles, flags, NaN boxing, access and encoding checks |
| `nemu-pointer-mask-check` | PMM WARL, effective privilege/MXR, explicit versus implicit accesses, transformed faults and RV32 rejection |
| `nemu-sscofpmf-check` | RV32/RV64 zero-HPM CSR and interrupt-enable/delegation behavior, enabled and disabled |
| `nemu-vector-control-check` | RV32/RV64 V128 control instructions, read-only `misa.V`, VS and CSR gating, enabled and disabled |
| `nemu-vector-data-check` | RV32/RV64 V128 integer data, same-width FP arithmetic and scalar transfers, reductions, memory, whole-register moves, register-state API and illegal encodings |
| `nemu-vector-misaligned-check` | RV64 RVA23 vector loads/stores across element widths, strides, indices, masks and segments; noncontiguous page mappings, PMP/PBMT checks and fault restart |
| `nemu-vector-opcodes-check` | RV32/RV64 nominal execution of 314 OP-V arithmetic encodings from the pinned opcode table; decode smoke test, not full V compliance |
| `nemu-vector-spike-check` | RV32/RV64 independent Spike instruction execution: V and Zvbb arithmetic results, vector/scalar state, FP flags and saturation over SEW/LMUL, masks and operands |
| `nemu-vector-memory-spike-check` | RV32/RV64 independent Spike vector memory execution: load/store addressing modes, segments, masks, FOF and whole-register transfers, RAM/VRF comparison and illegal encodings |
| `nemu-zvbb-check` | RV32/RV64 opt-in Zvbb bit oracles across SEW, LMUL, mask and `vstart`, plus illegal geometry |
| `nemu-zvfhmin-check` | RV32/RV64 opt-in half/single conversions, flags, masking, overlap and disabled traps |
| `nemu-smstateen-check` | RV32/RV64 disabled and enabled state-enable CSR access, RV64 H-stateen WARL bits, S/VS-mode gates and revocation, including shared guest `scounteren`/`senvcfg`/`sstateen` access |
| `nemu-vector-estimate-spike-check` | RV32/RV64 V128 `vfrec7`/`vfrsqrt7` results and flags against locally built Spike SoftFloat across edge and deterministic random inputs; requires `nemu/tools/spike-diff/repo/build/libsoftfloat.a` |
| `nemu-vector-rtl-check` | RV32/RV64 NEMU `vset*` state compared against the RTL VTYPE module (requires Verilator) |
| `nemu-vector-alu-rtl-check` | RV32/RV64 NEMU integer, carry/borrow and mask logical element results compared against the standalone RTL VPU ALU (requires Verilator) |
| `nemu-vector-muldiv-rtl-check` | RV32/RV64 NEMU integer multiply/divide/remainder element results compared against the standalone RTL VPU engine (requires Verilator) |
| `nemu-vector-reduce-rtl-check` | RV32/RV64 NEMU integer reductions compared byte-for-byte against the standalone RTL VPU reduction engine (requires Verilator) |
| `nemu-vector-mask-scan-rtl-check` | RV32/RV64 NEMU `vcpop.m`/`vfirst.m` compared against the standalone RTL VPU mask-scan engine (requires Verilator) |
| `nemu-vector-slide-rtl-check` | RV32/RV64 NEMU slide element results compared against the standalone RTL VPU slide router (requires Verilator) |
| `nemu-vector-gather-rtl-check` | RV32/RV64 NEMU gather results checked against a spec oracle and RTL decoder/register geometry (requires Verilator) |
| `nemu-vector-mask-ops-rtl-check` | RV32/RV64 NEMU mask-prefix, iota, index and compress results checked against a spec oracle and RTL decoder/register geometry (requires Verilator) |
| `nemu-vector-vpu-rtl-check` | RV32/RV64 NEMU integer/mask/scan/fixed-point, widening add/subtract/multiply/accumulate, narrowing shift and sign/zero extension compared with the complete standalone RTL VPU across LMUL 1/2/4/8 and directed fractional LMUL cases, including scalar results, traps with cause/`tval`, `vl`, `vtype`, `vstart`, `vxrm`/`vxsat`/`vcsr` and all VRF bytes (requires Verilator) |
| `nemu-vector-fp-rtl-check` | RV32/RV64 FP transfers, same-width and widening arithmetic/FMA, sqrt, class, conversions, comparisons and reductions against the complete standalone RTL VPU, including FPR results, `fflags`, traps and VRF bytes (requires Verilator; `nemu-vector-fp-transfer-rtl-check` remains an alias) |
| `nemu-vector-move-rtl-check` | RV32/RV64 NEMU whole-register moves compared byte-for-byte against the standalone RTL VPU move engine (requires Verilator) |
| `nemu-vector-memory-rtl-check` | RV32/RV64 NEMU unit/strided/indexed/segment/mask/whole-register transfers compared against the standalone RTL VPU memory sequencer (requires Verilator) |

The multi-hart checks cover RV32/RV64 with 1/2/4 harts and inject corruptions
that must be rejected. `NEMU_SANITIZE=undefined|thread` builds NEMU with a
sanitizer (add `NEMU_TSAN_NO_ASLR=1` for TSan) and `NEMU_REPEAT` sets threaded
repetitions. Results go to `verify/build/nemu-*`. For the distribution check,
set `NEMU_DISTRO_PREPARED` to a prepared image directory (default: two-hart
threaded Debian) and `NEMU_DISTRO_TIMEOUT` (default 3600 s); a pass requires
both endpoints to complete, matching totals, userspace checks and a clean
poweroff. The reference-library ISA checks need `make build-nemu32-ref
build-nemu64-ref` first.
