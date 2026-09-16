# LiteX BIOS netboot (RV32 / RV64)

## Fixed CU08 end-to-end targets

Run from `fpga/litex` with the CU08 UART/JTAG available and FMC_C/ETHA connected to a dedicated host Ethernet interface:

```sh
make fpga-netboot-rv64-check
make fpga-netboot-rv64-build
make fpga-netboot-host-setup
make fpga-netboot-rv64-serve
# In a second terminal if serve started a foreground TFTP daemon:
make fpga-netboot-rv64-load
make fpga-netboot-rv64-console
# At litex>: manually enter the exact netboot .../boot.json printed by serve.
# Wait for Linux, press Enter (Buildroot: log in as root).
# Exit the host console with Ctrl-C before testing:
make fpga-netboot-rv64-test
# Once finished (exit console with Ctrl-C first):
make fpga-netboot-host-restore
```

Replace `rv64` with `rv32` throughout for RV32. `load` only programs the FPGA; enter `netboot` yourself at the BIOS prompt. Build, load and boot are separate. The profile uses `RAPT_CONFIG=default` unless another preset is selected, for example `make fpga-netboot-rv64-build RAPT_CONFIG=small`. Repeat the same `RAPT_CONFIG` for all subsequent build/load/test steps. Host setup/restore is shared across presets and does not require a build or FPGA tools. The profile fixes 50 MHz, MIG DDR, BIOS, CM005 gigabit Ethernet and full Linux initialization. BIOS stops at `litex>` after initialization; choose `sdcardboot` or the exact namespaced `netboot` command printed by `serve` manually. The profile does not automatically shrink the CPU to make routing pass. A routing/timing failure means no board acceptance.

| Target suffix | Effect |
| --- | --- |
| `check` | Read-only tool, release-presence, UART-path and interface preflight; no acceptance claim |
| `info` | Resolve exact Make firmware, payload and output paths |
| `build` | Preserve the last good bitstream, acquire a missing release, build/check timing, publish a verified generation, then package Linux artifacts |
| `bundle` | Validate/package completed firmware; repeat calls reuse an identical SHA256-addressed bundle |
| `serve` | Deploy only `/srv/tftp/raptor-netboot/rvXX/<digest>/`; verify actual TFTP reads; reuse a working daemon or start one in foreground |
| `load` | Verify and program the latest published successful bitstream; independent of current sources or an active rebuild |
| `test` | Check an already manually booted Linux system: boot ID/XLEN, LAN IPv4, bidirectional ping, 1 MiB HTTP download/TCP upload, checksum and error/drop counter deltas |
| `console` | Interactive, exclusive UART; Ctrl-C exits |

No firmware directory, bundle directory or DTB address needs to be supplied. Default release versions/paths and SHA256 values are pinned in `linux/vars.mk`; `build` acquires the BIOS firmware prerequisite; `bundle` also acquires the selected distro and builds a cached LiteX kernel/rootfs in isolated directories. `NETBOOT_DISTRO=legacy` selects the original fw_payload diagnostic workflow. `check` deliberately does not download anything. Initial tool installation is still required: the project LiteX environment (`make setup`), Vivado, RISC-V GNU tools, Verilator, device-tree-compiler, pyserial, `ip`, `nmcli`, `ping`, `sudo`, dnsmasq and tftpd-hpa. Setup/download/build must not overlap another session changing the same dependencies or outputs.

Vivado on PATH or a single standard installation, one MiLianKe UART by-id, and one linked physical non-uplink interface are discovered automatically. Ambiguity fails instead of guessing. Optional machine-specific settings go in ignored `fpga/litex/netboot.local.mk`, for example:

```make
# Only needed when discovery is ambiguous:
NETBOOT_INTERFACE = ens10f0np0
NETBOOT_UART = /dev/serial/by-id/usb-Xilinx_MiLianKe.JTAG1U1_2519C98F420-if01-port0
```

`NETBOOT_BUILD_ROOT` can select an absolute output container; custom outputs live at `<NETBOOT_BUILD_ROOT>/<RAPT_CONFIG>/rvXX/`. Use the same setting for all build/load/test steps. Existing custom-root outputs using the older `<NETBOOT_BUILD_ROOT>/rvXX/` layout need a new paired build.

`NETBOOT_STATE_ROOT` selects the shared host-network journal/lock directory and defaults to `build/netboot-default` for compatibility with the original journal. Keep it the same across presets and host setup/restore. To restore a setup previously recorded elsewhere, pass `NETBOOT_STATE_ROOT=<old-build-root>`.

`VIVADO_JOBS` and `CROSS` select build concurrency and the compiler prefix; `UART_PORT` is accepted as a fallback for `NETBOOT_UART`. Conflicting fixed hardware settings (e.g. another `FPGA_BOARD`, mismatched `VARIANT`, or `WITH_ETHERNET=0`) now fail explicitly; use ordinary `fpga-*` targets for them.

Wait for Linux initialization before testing; silence alone is not a reason to reload the FPGA. `NETBOOT_INTERNET=1` adds an HTTP/DNS Internet test, but requires a separately configured gateway/DNS; LAN success does not prove Internet access. The default host setup never adds NAT, forwarding, firewall rules or a default route.

`host-setup` is explicit and uses sudo only for the dedicated interface/service. It records the MAC, original management/link state, and only addresses it adds (`192.168.1.100/24` for BIOS, `192.168.50.1/24` for Linux by default). It refuses the host default-route interface and an already-addressed managed interface. A matching existing DHCP process is left alone; otherwise it starts LAN-only DHCP with an owned PID identity. `host-restore` removes only recorded additions and stops only that owned process, never a reused daemon. It is safe to repeat. If setup fails, use restore before retrying; its journal is retained. An interruption between DHCP launch and PID identity capture requires inspecting the recorded pidfile; restoration refuses to guess which process to stop. Neither target deletes existing connection profiles or persistent configuration.

Logs and JSON build/boot/test receipts live under `build/netboot-<RAPT_CONFIG>/rvXX/netboot/`; host state lives in `NETBOOT_STATE_ROOT`. Default Linux release downloads use a shared lock beside the release archives, independent of build output roots. The final routed report must also show zero missing clocks and zero unconstrained internal endpoints; a missing coverage summary fails the gate. Successful gateware is copied into `netboot/bitstreams/<digest>/` with a manifest binding the bitstream, passing final timing report, XLEN, source identity and build context. `ready.json` is updated atomically only after the copy validates. Old generations are retained so an in-flight load cannot lose its files. `load` verifies the selected generation and programs that fixed copy directly; it does not inspect the mutable `soc/gateware` or compare against current RTL. A source edit, active rebuild or failed rebuild cannot invalidate this copy. The selected path and recorded source identity are printed before programming. This deliberately permits loading older hardware: new BIOS/RTL edits take effect only after a new successful build replaces the published selection.

Before rebuilding, a completed legacy output can be imported using its matching build receipt or `.bitstream_stamp`, with passing final timing and stable file checks. First-time import requires an idle output directory. If no independent copy exists and a legacy build is already overwriting its output, wait for that build to finish; the tool cannot recover an overwritten prior bitstream.

`build` holds `build.lock` exclusively; `bundle` shares it while reading mutable firmware. `load` uses the published generation and does not acquire this lock after import. A published `load` is not Linux-network acceptance.

`NETBOOT_STATE_ROOT/board.lock` serializes `load`/`test` across profiles. Pure JTAG `load` does not open UART; a terminal can stay attached to observe BIOS startup. Release other terminals before `test`, which requires exclusive UART.

`test` neither loads nor boots the board. Manually boot Linux first. The test records the guest boot ID and checks it again at the end; it does not depend on an earlier automatic boot receipt and does not certify which image or bitstream is running. Bind those artifacts separately when writing a board acceptance report.

The current fixed BIOS uses `192.168.1.50` locally and `192.168.1.100` for TFTP. For a BIOS built with `ETH_DYNAMIC_IP`, you can manually use `eth_local_ip` and `eth_remote_ip` to change these. Static BIOS addresses require a matching server.

Network acceptance uses a temporary private tracefs instance on the board (`skb/kfree_skb` with `UNHANDLED_PROTO` support is required in the kernel). Some links deliver periodic LLDP frames even when host packet capture does not show them. The test records raw counters and accounts only for LLDP (`0x88cc`) protocol discards actually observed by the kernel. Unexplained RX drops, RX/TX errors, TX drops, trace overflow, or checksum mismatches still fail. The instance and temporary mount are removed before the success receipt is written; no host NIC offload or LLDP setting is changed.

## Low-level standalone packer

The separate `netboot.mk` workflow packages **finished** Raptor Linux FPGA firmware for TFTP boot. It does not build/load gateware, access UART/JTAG/SD, install packages, start a server, or change host networking. It does not modify an existing SD card. `rv64_network.py` is a separate **SD-boot + Linux DHCP** profile, not this flow.

First build and load a BIOS with Ethernet enabled using the [CU08 RV32/RV64 build/load quick start](README.md#cu08-rv32rv64-netboot-build-and-load). The normal FPGA build defaults to `WITH_ETHERNET=0`; selecting a Linux variant alone does not enable `netboot`. Verify `help` lists `netboot` before debugging TFTP or the cable. Packing a bundle with this workflow cannot add a missing command to an already-loaded BIOS.

## Standalone preparation entry point

Run from the repository root:

```sh
make -C fpga/litex -f netboot.mk netboot-help
make -C fpga/litex -f netboot.mk netboot-test
```

The separate `-f netboot.mk` is intentional: it does **not** include the ordinary FPGA Makefile, so no profile detection, dependency download, RTL pack, shared `sim/.config` rewrite, BIOS patching, or recursive Make occurs. These targets are not yet aliases in the ordinary Makefile. Do not drop `-f netboot.mk`.

| Target | Effect |
| --- | --- |
| `netboot-check` | Read inputs; temporary ELF/DTB validation only |
| `netboot-pack-rv32`, `netboot-pack-rv64` | Validate and create a new bundle directory; never overwrite |
| `netboot-verify` | Check the bundle file hashes and JSON address map |
| `netboot-serve-plan` | Verify the bundle and print a TFTP command; **does not execute it** |
| `netboot-test` | Host unit/integration tests, temporary outputs only |

## Inputs and software prerequisites

- Python 3.10+; no Python packages or LiteX venv required for this tool.
- GNU RISC-V `nm` and `objcopy`; `fdtget` (device-tree-compiler package). Tests additionally use `riscv64-linux-gnu-gcc` and `dtc`.
- `NETBOOT_FIRMWARE`: one **completed, matching configuration's** firmware directory containing `stage0.elf`, `stage0.bin`, `litex-soc-seeded.dtb`.
- `NETBOOT_PACKAGE`: original extracted release directory containing `manifest.json` and `fw_payload.bin`. Choose RV64 **Buildroot** for normal `/init` and networking, not a tiny-shell release. Release acquisition remains the existing `linux/` workflow; never run it against another session's active build. Existing manifest hashes check consistency, not supply-chain trust; release archive trust must come from the pinned release hash.
- A timing-accepted, matching RV32/RV64 bitstream with BIOS Ethernet, working DDR, correct PHY/port/speed, and a UART console (needed later, not for packing).

Do not select the newest directory using a wildcard or timestamps. Obtain the exact completed firmware/release paths from the matching build. This tool checks file snapshots but does not lock another build's inputs or prove that the programmed bitstream matches them. Do not package files still being generated.

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

For RV32 select matching inputs, set `NETBOOT_XLEN=32` for `netboot-check`, and use `netboot-pack-rv32`. Pack targets force their stated XLEN. The default tool prefix is `riscv64-linux-gnu-` for both ELF classes; override `NETBOOT_CROSS` if necessary. `NETBOOT_PYTHON` selects the interpreter. The Python CLI also accepts explicit `--firmware`, `--package`, `--out`, `--xlen`, and `--cross`.

Output contains `boot.json`, `stage0.bin`, `soc.dtb`, patched `fw_payload.bin`, and `bundle.json` provenance/hashes. It omits zero-filled SD image gaps. Failed output writes may leave a partial new directory; use a fresh output path and do not serve anything before `netboot-verify` passes. There is no cleanup or overwrite target. Only generated bundle files receive read-only permissions; source files are never edited.

## Why this is not just copying the SD image

The BIOS SD hook substitutes its embedded stage0/DTB and patches an OpenSBI `fw_next_arg1` instruction before jumping. The TFTP path does not run that hook. This packer instead:

1. Checks release payload SHA256, stage0 ELF XLEN, and exact ELF/bin agreement.
2. Reads address/size constants from stage0 ELF symbols, not guessed filenames or hardcoded assumptions about the DTB source slot.
3. Checks the DTB header, XLEN/MMU, memory size, populated development RNG seed, and F/D advertisement for a hard-float release. It checks upload overlaps, relocation hazards, and the release's kernel memory end against runtime DTB.
4. Applies the existing fail-closed OpenSBI instruction recognizer to a **copy** of the payload and sets relocation to the stage0 DTB destination. Unknown or ambiguous sequences fail; the release itself remains unchanged.
5. Emits short server-relative filenames, stage0 last, and explicit `addr` in `boot.json`. The current BIOS parses these keys. An older BIOS must be checked independently before use.

The firmware's DTB CSR addresses, IRQs, timebase, PMA and ISA must still match the actual bitstream. The tool records the timebase and bootargs but cannot prove hardware agreement. It does not establish Linux Ethernet capability or validate the complete kernel/rootfs. Successful netboot can boot an initramfs without working Linux Ethernet; BIOS TFTP and Linux networking are different acceptance stages.

## Host TFTP service

The plan uses `tftpd-hpa` (`in.tftpd`). If it is absent, installation is a separate host-administration step; package installation may start a service, so do not do it during another session's network tests. The wrapper does not install anything or invoke `sudo`.

```sh
# Use the server address actually expected by this BIOS, not Linux's DHCP IP.
export NETBOOT_SERVER_IP=192.168.1.100
export NETBOOT_SERVER_PORT=69
make -C fpga/litex -f netboot.mk netboot-serve-plan
```

The command preview binds an explicit IPv4 address, runs in the foreground, chroots to the bundle, and caps blocks at 512 bytes for initial bring-up. The daemon flags follow the [tftpd-hpa manual](https://manpages.debian.org/bookworm/tftpd-hpa/in.tftpd.8.en.html). Starting it requires appropriate privileges for chroot and usually UDP/69; review and execute separately when the board/network are available. A high port alone does not remove the chroot privilege requirement, and does not work unless BIOS uses the same port.

Before starting a server, confirm:

- Host board-facing address and BIOS local/server IP are on the intended subnet. BIOS networking does not inherit the previous Linux DHCP lease. Read the running BIOS help and boot messages; `set_local_ip` / `set_remote_ip` are build-dependent and may be absent. If absent, use the compiled addresses or arrange a BIOS rebuild when the board is available.
- No existing daemon owns the selected UDP port. Only the dedicated bundle should be exported, never the repository, home directory, or release tree.
- Firewall access is limited to the board/lab interface. TFTP uses UDP/69 for requests and a server transfer port for data; allowing only destination 69 is insufficient. Do not disable the host firewall wholesale.
- The service account can read the bundle. Files are generated as 0444 and the directory as 0755. Do not add upload/create/permissive options.
- TFTP provides no authentication or encryption. `soc.dtb` contains a development RNG seed; treat the whole bundle as sensitive development data, not production entropy or a signed/secure boot chain. The checksum manifest is not a signature.

## Board handoff and acceptance (not run by these targets)

When the board is available, load/confirm the intended RV32 or RV64 bitstream through its matching workflow. Interrupt SD autoboot if enabled; do not attempt to run the RV32 SD payload on an RV64 core. At the BIOS prompt:

```text
litex> netboot raptor-netboot/rv64/<bundle-id>/boot.json
```

Copy the actual bundle ID from `fpga-netboot-rv64-serve` (use `rv32` for RV32), or from the standalone `netboot-serve-plan` export instructions. Private BIOS builds reject bare `netboot`, global `boot.json`, traversal paths, and the other XLEN namespace before starting any download. This guard requires rebuilding and loading the BIOS-containing bitstream; old bitstreams still default to the global root manifest. Do not replace the shared root manifest to switch architectures. Host deployment also rejects bundle/request XLEN mismatches. The namespace guard prevents accidental selection; it does not authenticate the TFTP server or validate arbitrary manifest contents on the board. Observe downloads followed by `stage0: copy payload`, OpenSBI, Linux, and the expected `/init`/shell. Record the bitstream identity, bundle hashes, BIOS IPs, UART log, exact configuration and each reached stage. Then validate Linux Ethernet/DHCP, route/DNS and actual traffic separately if needed.

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

No U-Boot/UEFI integration is needed for this preparation. Board netboot remains **unvalidated** until the complete handoff above succeeds on the exact bitstream.
