# RaptOS

RaptOS is a compact microkernel-style teaching OS for the Raptor core. The RV32 profile exercises M/U privilege transitions with Sv32 virtual memory; the RV64 FPGA profile uses the same U-mode services with flat low-memory addressing. Both profiles provide system calls, scheduling, IPC, and FPGA console I/O while keeping the image below 256 KiB.

## Layout

- `arch/riscv/machine/`: M-mode reset and trap assembly.
- `arch/riscv/raptos.ld`: RISC-V image layout.
- `kernel/`: scheduling, Sv32, IPC, syscalls, drivers, and RAM filesystem.
- `user/`: layered U-mode runtime, shell/script interpreter, command modules, and service process.
- `include/`: shared syscall and IPC ABI.
- `fs/rootfs/`: files embedded in the initial RAM filesystem.
- `tools/`: host-side image generation.
- `payloads/`: auto-discovered hardware stress commands that execute in U-mode.

## Microkernel Design

The M-mode kernel provides traps, address spaces, scheduling, user-memory validation, IPC, console access, and the RAM filesystem. PID 1 is a persistent U-mode session supervisor, PID 2 blocks on `recv` and handles `SERVICE_PING`, and each root session runs a fresh shell as PID 3.

IPC uses one 64-byte mailbox per process without dynamic allocation. `send` fails if the destination is unavailable or its mailbox is full, while `recv` blocks until a message arrives and returns the sender PID.

## Features

- Syscalls include flag-based `open`, `read`, `write`, `close`, `lseek`, `dup`, `dup2`, `stat`, `fstat`, `mkdir`, `rmdir`, `readdir`, `chdir`, `getcwd`, `truncate`, and filesystem statistics, plus process, IPC, and service calls.
- Shell commands cover file and directory operations, system identity and status (`ps`, `uptime`, `df`, `uname`, `hostname`, and `whoami`), IPC, and deterministic `devtest`/`fstest` diagnostics. `help` presents commands by category and `help COMMAND` provides Unix-style name, synopsis, and description sections.
- `source FILE` composes built-ins into RFS3 shell scripts with blank lines, whole-line comments, shared quoting/escaping rules, fail-fast behavior, and bounded recursion. `/etc/diagnostics.rc` provides a board-health snapshot.
- Chip diagnostics include `meminfo`, RAM-whitelisted `pmem_read`, permission-bypassing `vmem_read`, 64-bit `csr` counters, and bounded `mem_speed` load/store measurements.
- `payload list` enumerates built-in stress payloads; `payload NAME` runs one in U-mode with Sv32 enabled.
- Boot automatically starts a clean root shell. `exit` or a fatal shell exception starts another clean root session, while `halt` explicitly stops the system. `crash` injects a deterministic user page fault for recovery testing.
- Interactive parsing supports whitespace, single and double quotes, backslash escaping, Backspace, `Ctrl-U`, and relative file names.
- Console backends: NS16550 for NPC/NEMU and LiteUART for KU15P.
- Character device paths: `/dev/console`, `/dev/null`, `/dev/zero`, and binary `/dev/cycle`.
- File descriptors reference a fixed shared open-file table, so descriptors created by `dup` share access mode and seek position.
- Each process has an independent current directory. A common kernel resolver canonicalizes absolute and relative paths, repeated separators, `.`, and `..`; vnode lookup then resolves rootfs and devfs objects.

The RFS3 RAM filesystem supports hierarchical directories, 16 inodes, and 29 allocatable 512-byte data blocks in a 16 KiB image. Each inode has eight direct blocks, giving regular files a 4 KiB maximum size. A block bitmap supports allocation, reuse, truncation, and sparse extension; unwritten ranges read as zero. Full paths are limited to 31 bytes. The initial tree contains `/dev`, `/etc/motd`, and `/share/hello`; directories and files remain writable until reset. Empty directories can be removed unless they are active process working directories. There is not yet `fork`, `exec`, pipe, permissions, hard links, a buffer cache, or persistent storage.

The layering and debug-capability model are in [ARCHITECTURE.md](ARCHITECTURE.md), and the staged Unix, filesystem, and peripheral plan is in [ROADMAP.md](ROADMAP.md). Hardware validation remains the acceptance criterion rather than treating POSIX surface area as an end in itself.

## Build And Run

```bash
make -C app/tinyos/raptos build
make -C app/tinyos/raptos nemu
make -C app/tinyos/raptos sim
make -C fpga/litex fpga-raptos-run
```

Use NEMU first for fast functional iteration. Run `source /etc/diagnostics.rc` for identity, layout, filesystem, and counter output; run `devtest` for character devices and `fstest` for descriptor, namespace, and block-allocation semantics. Use NPC after those pass to cover RTL behavior and randomized memory latency, followed by KU15P.

The Makefile automatically compiles every `payloads/NAME/payload.c` into the normal RaptOS image. Payload code executes from user RX pages and mutable `USER_BSS` state is mapped into separate RW+U pages, so tests cover U-mode translation and permissions without producing payload-specific binaries:

```bash
make -C app/tinyos/raptos payloads
make -C app/tinyos/raptos nemu
# In the RaptOS shell:
payload list
payload slub_freelist

# Run the same image on NPC with randomized memory latency:
make -C app/tinyos/raptos sim \
	ARGS="-n --mem-random-delay=4 --mem-random-seed=1"
```

For FPGA, the build and upload targets use the same `build/ku15p/raptos.bin`:

```bash
make -C fpga/litex fpga-raptos-build
make -C fpga/litex fpga-raptos-upload
# Then run in the serial shell:
payload slub_freelist
```

`slub_freelist` stresses encoded bit-30 freelist pointers, mixed-width stores, store-to-load forwarding, repeated object reuse, and the Sv32/PTW path. A metadata mismatch reports the failing iteration and values before returning an error to the shell.

Set `PLATFORM=sim|ku15p`, `ARGS`, `MAX_INST`, or `CROSS` as needed. Outputs are isolated under `build/sim/` and `build/ku15p/`.

