# LiteX BIOS netboot (RV32 / RV64)

## Fixed CU08 end-to-end targets

Run from `fpga/litex` with the CU08 UART/JTAG available and FMC_C/ETHA connected
to a dedicated host Ethernet interface:

```sh
make fpga-netboot-rv64-check
make fpga-netboot-rv64-build
make fpga-netboot-host-setup
make fpga-netboot-rv64-serve
# In a second terminal if serve started a foreground TFTP daemon:
make fpga-netboot-rv64-run
make fpga-netboot-rv64-test
make fpga-netboot-rv64-console
# Once finished (exit console with Ctrl-C first):
make fpga-netboot-host-restore
```

Replace `rv64` with `rv32` throughout for RV32. `run` already loads the bitstream;
there is no need for an extra `load`. Build and board programming are separate.
The profile uses the full `default` microarchitecture, 50 MHz, MIG DDR, BIOS,
CM005 gigabit Ethernet and full Linux initialization. It does not shrink the
CPU to make routing pass. A routing/timing failure means no board acceptance.

| Target suffix | Effect |
| --- | --- |
| `check` | Read-only tool, release-presence, UART-path and interface preflight; no acceptance claim |
| `info` | Resolve exact Make firmware, payload and output paths |
| `build` | Acquire a missing default release through `linux/Makefile`, build, check timing, package and record source/bitstream identity |
| `bundle` | Validate/package completed firmware; repeat calls reuse an identical SHA256-addressed bundle |
| `serve` | Deploy only `/srv/tftp/raptor-netboot/rvXX/<digest>/`; verify actual TFTP reads; reuse a working daemon or start one in foreground |
| `load` | Check source/build receipt, bitstream freshness and routed timing; program volatile FPGA SRAM |
| `run` | Same gates; own UART before loading, stop SD autoboot, validate static BIOS IPs or set dynamic ones, netboot, wait for full Linux login, mark the session and release UART |
| `test` | Check the marked Linux session/XLEN, LAN IPv4, bidirectional ping, 1 MiB HTTP download/TCP upload, checksum and error/drop counter deltas |
| `console` | Interactive, exclusive UART; Ctrl-C exits |

No firmware directory, bundle directory or DTB address needs to be supplied.
Default release versions/paths are pinned in `mk/netboot-profile.mk`;
`build` downloads only a missing default payload, never to a custom path.
`check` deliberately does not download anything. Initial tool installation is
still required: the project LiteX environment (`make setup`), Vivado, RISC-V
GNU tools, Verilator, device-tree-compiler, pyserial, `ip`, `nmcli`, `ping`,
`sudo`, dnsmasq and tftpd-hpa. Setup/download/build must not overlap another
session changing the same dependencies or outputs.

Vivado on PATH or a single standard installation, one MiLianKe UART by-id,
and one linked physical non-uplink interface are discovered automatically.
Ambiguity fails instead of guessing. Optional machine-specific settings go in
ignored `fpga/litex/netboot.local.mk`, for example:

```make
# Only needed when discovery is ambiguous:
NETBOOT_INTERFACE = ens10f0np0
NETBOOT_UART = /dev/serial/by-id/usb-Xilinx_MiLianKe.JTAG1U1_2519C98F420-if01-port0
```

`NETBOOT_BUILD_ROOT` can select an absolute isolated output root. Use the same
root for all steps. `NETBOOT_TIMEOUT` defaults to 2400 seconds for full Linux
initialization (including first-boot SSH key generation). Silence alone is not
a reason to reload the FPGA. `NETBOOT_INTERNET=1` adds an HTTP/DNS Internet test,
but requires a separately configured gateway/DNS; LAN success does not prove
Internet access. The default host setup never adds NAT, forwarding, firewall
rules or a default route.

`host-setup` is explicit and uses sudo only for the dedicated interface/service.
It records the MAC, original management/link state, and only addresses it adds
(`192.168.1.100/24` for BIOS, `192.168.50.1/24` for Linux by default). It refuses
the host default-route interface and an already-addressed managed interface.
A matching existing DHCP process is left alone; otherwise it starts LAN-only
DHCP with an owned PID identity. `host-restore` removes only recorded additions
and stops only that owned process, never a reused daemon. It is safe to repeat.
If setup fails, use restore before retrying; its journal is retained. An
interruption between DHCP launch and PID identity capture requires inspecting
the recorded pidfile; restoration refuses to guess which process to stop.
Neither target deletes existing connection profiles or persistent configuration.

Logs and JSON build/boot/test receipts live under
`build/netboot-default/rvXX/netboot/`; host state lives at the build-root level.
The final routed report must also show zero missing clocks and zero unconstrained
internal endpoints; a missing coverage summary fails the gate.
Build receipts reject hardware-input changes during/after synthesis. If another
session is editing HDL, use a fixed source snapshot for the entire workflow;
later formatting in the original worktree then cannot invalidate that snapshot.
UART orchestration runs concurrently with programming so it can interrupt
autoboot before Vivado exits; edits to that runtime script do not themselves
change the bitstream identity. A legacy `fpga-build` alone does not create this
workflow's receipt: run the paired `fpga-netboot-rvXX-build` first. A failed
test can be retried from the login prompt or the workflow's root shell.
UART exclusion cannot protect against unrelated tools that ignore serial locks;
release other terminal programs before run/test/load.

The current fixed BIOS uses `192.168.1.50` locally and `192.168.1.100` for TFTP.
The runner checks the generated constants and private BIOS source before using
static addresses; it sends `eth_local_ip`/`eth_remote_ip` only when
`ETH_DYNAMIC_IP` was compiled in. A custom server address incompatible with a
static BIOS fails explicitly. Colored BIOS prompts are supported; UART logs
retain the original bytes.

Network acceptance uses a temporary private tracefs instance on the board
(`skb/kfree_skb` with `UNHANDLED_PROTO` support is required in the kernel).
Some links deliver periodic LLDP frames even when host packet capture does not
show them. The test records raw counters and accounts only for LLDP (`0x88cc`)
protocol discards actually observed by the kernel. Unexplained RX drops, RX/TX
errors, TX drops, trace overflow, or checksum mismatches still fail. The instance
and temporary mount are removed before the success receipt is written; no host
NIC offload or LLDP setting is changed.

## Low-level standalone packer

The separate `netboot.mk` workflow packages **finished** Raptor Linux FPGA firmware for TFTP boot.
It does not build/load gateware, access UART/JTAG/SD, install packages, start a
server, or change host networking. It does not modify an existing SD card.
`rv64_network.py` is a separate **SD-boot + Linux DHCP** profile, not this flow.

First build and load a BIOS with Ethernet enabled using the
[CU08 RV32/RV64 build/load quick start](README.md#cu08-rv32rv64-netboot-build-and-load).
The normal FPGA build defaults to `WITH_ETHERNET=0`; selecting a Linux variant
alone does not enable `netboot`. Verify `help` lists `netboot` before debugging
TFTP or the cable. Packing a bundle with this workflow cannot add a missing
command to an already-loaded BIOS.

## Standalone preparation entry point

Run from the repository root:

```sh
make -C fpga/litex -f netboot.mk netboot-help
make -C fpga/litex -f netboot.mk netboot-test
```

The separate `-f netboot.mk` is intentional: it does **not** include the ordinary
FPGA Makefile, so no profile detection, dependency download, RTL pack, shared
`sim/.config` rewrite, BIOS patching, or recursive Make occurs. These targets
are not yet aliases in the ordinary Makefile. Do not drop `-f netboot.mk`.

| Target | Effect |
| --- | --- |
| `netboot-check` | Read inputs; temporary ELF/DTB validation only |
| `netboot-pack-rv32`, `netboot-pack-rv64` | Validate and create a new bundle directory; never overwrite |
| `netboot-verify` | Check the bundle file hashes and JSON address map |
| `netboot-serve-plan` | Verify the bundle and print a TFTP command; **does not execute it** |
| `netboot-test` | Host unit/integration tests, temporary outputs only |

## Inputs and software prerequisites

- Python 3.10+; no Python packages or LiteX venv required for this tool.
- GNU RISC-V `nm` and `objcopy`; `fdtget` (device-tree-compiler package).
  Tests additionally use `riscv64-linux-gnu-gcc` and `dtc`.
- `NETBOOT_FIRMWARE`: one **completed, matching configuration's** firmware
  directory containing `stage0.elf`, `stage0.bin`, `litex-soc-seeded.dtb`.
- `NETBOOT_PACKAGE`: original extracted release directory containing
  `manifest.json` and `fw_payload.bin`. Choose RV64 **Buildroot** for normal
  `/init` and networking, not a tiny-shell release. Release acquisition remains
  the existing `linux/` workflow; never run it against another session's active
  build. Existing manifest hashes check consistency, not supply-chain trust;
  release archive trust must come from the pinned release hash.
- A timing-accepted, matching RV32/RV64 bitstream with BIOS Ethernet, working
  DDR, correct PHY/port/speed, and a UART console (needed later, not for packing).

Do not select the newest directory using a wildcard or timestamps. Obtain the
exact completed firmware/release paths from the matching build. This tool checks
file snapshots but does not lock another build's inputs or prove that the
programmed bitstream matches them. Do not package files still being generated.

```sh
# Replace these three paths. The output must not exist; its parent must exist.
export NETBOOT_FIRMWARE=/absolute/path/to/completed/firmware/linux-fpga/rv64-config-id
export NETBOOT_PACKAGE=/absolute/path/to/extracted/rv64-buildroot-release
export NETBOOT_OUT=/absolute/path/to/new-netboot-rv64-bundle
export NETBOOT_XLEN=64

make -C fpga/litex -f netboot.mk netboot-check
make -C fpga/litex -f netboot.mk netboot-pack-rv64
make -C fpga/litex -f netboot.mk netboot-verify
```

For RV32 select matching inputs, set `NETBOOT_XLEN=32` for `netboot-check`, and
use `netboot-pack-rv32`. Pack targets force their stated XLEN. The default tool
prefix is `riscv64-linux-gnu-` for both ELF classes; override `NETBOOT_CROSS`
if necessary. `NETBOOT_PYTHON` selects the interpreter. The Python CLI also
accepts explicit `--firmware`, `--package`, `--out`, `--xlen`, and `--cross`.

Output contains `boot.json`, `stage0.bin`, `soc.dtb`, patched `fw_payload.bin`,
and `bundle.json` provenance/hashes. It omits zero-filled SD image gaps. Failed
output writes may leave a partial new directory; use a fresh output path and
do not serve anything before `netboot-verify` passes. There is no cleanup or
overwrite target. Only generated bundle files receive read-only permissions;
source files are never edited.

## Why this is not just copying the SD image

The BIOS SD hook substitutes its embedded stage0/DTB and patches an OpenSBI
`fw_next_arg1` instruction before jumping. The TFTP path does not run that hook.
This packer instead:

1. Checks release payload SHA256, stage0 ELF XLEN, and exact ELF/bin agreement.
2. Reads address/size constants from stage0 ELF symbols, not guessed filenames
   or hardcoded assumptions about the DTB source slot.
3. Checks the DTB header, XLEN/MMU, memory size, populated development RNG seed,
   and F/D advertisement for a hard-float release. It checks upload overlaps,
   relocation hazards, and the release's kernel memory end against runtime DTB.
4. Applies the existing fail-closed OpenSBI instruction recognizer to a **copy**
   of the payload and sets relocation to the stage0 DTB destination. Unknown or
   ambiguous sequences fail; the release itself remains unchanged.
5. Emits short server-relative filenames, stage0 last, and explicit `addr` in
   `boot.json`. The current BIOS parses these keys. An older BIOS must be
   checked independently before use.

The firmware's DTB CSR addresses, IRQs, timebase, PMA and ISA must still match
the actual bitstream. The tool records the timebase and bootargs but cannot
prove hardware agreement. It does not establish Linux Ethernet capability or
validate the complete kernel/rootfs. Successful netboot can boot an initramfs
without working Linux Ethernet; BIOS TFTP and Linux networking are different
acceptance stages.

## Host TFTP service

The plan uses `tftpd-hpa` (`in.tftpd`). If it is absent, installation is a
separate host-administration step; package installation may start a service,
so do not do it during another session's network tests. The wrapper does not
install anything or invoke `sudo`.

```sh
# Use the server address actually expected by this BIOS, not Linux's DHCP IP.
export NETBOOT_SERVER_IP=192.168.1.100
export NETBOOT_SERVER_PORT=69
make -C fpga/litex -f netboot.mk netboot-serve-plan
```

The command preview binds an explicit IPv4 address, runs in the foreground,
chroots to the bundle, and caps blocks at 512 bytes for initial bring-up.
The daemon flags follow the [tftpd-hpa manual](https://manpages.debian.org/bookworm/tftpd-hpa/in.tftpd.8.en.html).
Starting it requires appropriate privileges for chroot and usually UDP/69;
review and execute separately when the board/network are available. A high
port alone does not remove the chroot privilege requirement, and does not work
unless BIOS uses the same port.

Before starting a server, confirm:

- Host board-facing address and BIOS local/server IP are on the intended subnet.
  BIOS networking does not inherit the previous Linux DHCP lease. Read the
  running BIOS help and boot messages; `set_local_ip` / `set_remote_ip` are
  build-dependent and may be absent. If absent, use the compiled addresses or
  arrange a BIOS rebuild when the board is available.
- No existing daemon owns the selected UDP port. Only the dedicated bundle
  should be exported, never the repository, home directory, or release tree.
- Firewall access is limited to the board/lab interface. TFTP uses UDP/69 for
  requests and a server transfer port for data; allowing only destination 69
  is insufficient. Do not disable the host firewall wholesale.
- The service account can read the bundle. Files are generated as 0444 and the
  directory as 0755. Do not add upload/create/permissive options.
- TFTP provides no authentication or encryption. `soc.dtb` contains a development
  RNG seed; treat the whole bundle as sensitive development data, not production
  entropy or a signed/secure boot chain. The checksum manifest is not a signature.

## Board handoff and acceptance (not run by these targets)

When the board is available, load/confirm the intended RV32 or RV64
bitstream through its matching workflow. Interrupt SD autoboot if enabled;
do not attempt to run the RV32 SD payload on an RV64 core. At the BIOS prompt:

```text
litex> netboot boot.json
```

Explicit JSON selection avoids falling back to an unrelated `boot.bin`.
Observe downloads followed by `stage0: copy payload`, OpenSBI, Linux, and the
expected `/init`/shell. Record the bitstream identity, bundle hashes, BIOS IPs,
UART log, exact configuration and each reached stage. Then validate Linux
Ethernet/DHCP, route/DNS and actual traffic separately if needed.

| Symptom | Check first |
| --- | --- |
| `help` has no `netboot` | Rebuild with `WITH_ETHERNET=1`; use identical build/load settings and `FPGA_DIR`; confirm `CSR_ETHMAC_BASE` in the matching generated BIOS header |
| No TFTP request | BIOS IPs/command availability, PHY/port/speed, cable and host interface |
| Requests but timeout | daemon address/permissions, filename, firewall transfer ports |
| Download stops around 32 MiB at 512-byte blocks | exact BIOS/server 16-bit block rollover support |
| JSON/address error | current BIOS parser, short relative filenames, matching RAM layout |
| Download succeeds but no stage0 | RV32/RV64 mismatch, entry address, complete transfer |
| stage0/OpenSBI then hang | DTB relocation, kernel memory, ISA/PMA/CSR/timebase; retain UART log |
| Linux boots without network | Linux driver/DT/IRQ/rootfs DHCP; BIOS TFTP success is not proof |

No U-Boot/UEFI integration is needed for this preparation. Board netboot remains
**unvalidated** until the complete handoff above succeeds on the exact bitstream.
