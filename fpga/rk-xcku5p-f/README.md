# Native RK-XCKU5P-F V1.2

Raptor support for `xcku5p-ffvb676-2-i`, using SystemVerilog, XDC and batch
Vivado. Supports RV32/RV64 with DDR4 or BRAM main memory, a boot ROM, scratch
SRAM, an 8250-compatible UART, CLINT and PLIC. The board has a 2 GiB DDR4
interface and an RTL8211F Ethernet PHY. The native SoC supports an optional
packet SRAM Ethernet controller and Ubuntu NFS root boot. Native Ubuntu uses
TFTP firmware loading with a UART fallback. A separate LiteX profile also
provides BIOS/TFTP netboot.

All commands below run from the **repository root**.

## Prerequisites

- Vivado with support for the target Kintex UltraScale+ device and the DDR4/AXI IP.
- Python 3, GNU Make, `riscv64-unknown-elf-gcc`, `riscv64-unknown-elf-objcopy`
  and the device-tree compiler `dtc` on `PATH`. The compiler must support the
  selected RV32/RV64 architecture and ABI.
- Verilator for RTL preprocessing in every build, and for `lint`, `test` and `sim`.
- For board use: a powered board, a working Vivado JTAG connection and access
  to its UART device. Install the cable drivers required by the JTAG adapter.

Generate the instruction decoders from the repository's Scala sources with
`make verilog` if they are missing. The native Python tools use the standard
library and need no additional Python packages.

## Build and program

The board Makefile defaults to RV64, preset `small`, a 50 MHz CPU clock and
DDR4 main memory. Build and program the default DDR configuration with:

```sh
make -C fpga/rk-xcku5p-f fpga-rv64-ip-check
make -C fpga/rk-xcku5p-f fpga-rv64-build
make -C fpga/rk-xcku5p-f fpga-rv64-info
make -C fpga/rk-xcku5p-f fpga-rv64-load
```

The `fpga-rv32-*` targets select RV32 with the same default DDR configuration.
Use `MEMORY=bram` on each command for an isolated UART/loader bring-up without
DDR calibration; BRAM defaults to 128 KiB:

```sh
make -C fpga/rk-xcku5p-f fpga-rv64-build MEMORY=bram
make -C fpga/rk-xcku5p-f fpga-rv64-load MEMORY=bram
```

Use the same configuration options for `build`, `info` and `load`. `load`
checks source/configuration freshness, artifact hashes and a passing routed
build, then requires exactly one matching FPGA on JTAG. Programming is volatile;
it does not write configuration flash or automatically rebuild stale outputs.

Root shortcuts are also available; select the preset explicitly because the
repository root defaults to `RAPT_CONFIG=default`:

```sh
make fpga-rv32-build FPGA_BOARD=rk-xcku5p-f RAPT_CONFIG=small
make fpga-rv64-build FPGA_BOARD=rk-xcku5p-f RAPT_CONFIG=small
make fpga-rv64-load FPGA_BOARD=rk-xcku5p-f RAPT_CONFIG=small
```

The board Makefile also forwards the generic LiteX SoC targets with RK board
selection fixed, including `fpga-build`, `fpga-load`, and `fpga-console`:

```sh
make -C fpga/rk-xcku5p-f fpga-build VARIANT=linux64
make -C fpga/rk-xcku5p-f fpga-load VARIANT=linux64
make -C fpga/rk-xcku5p-f fpga-console UART_PORT=/dev/ttyUSB2
```

`fpga-build` follows the LiteX RK Linux profile defaults (50 MHz, `small`, MIG
DDR4 and onboard Ethernet). The `fpga-rv64-*` targets above build the separate
native SystemVerilog SoC. The dedicated `fpga-netboot-rv64-*` flow below adds
matching Linux bundle and TFTP steps.

## Native Ubuntu 24.04 NFS root

The `ubuntu-*` targets use this board's SystemVerilog platform. The boot chain is
native ROM → small RAM TFTP loader → OpenSBI/Linux → native Ethernet → Ubuntu
`/sbin/init` (systemd) on an NFS root. The default is RV64 `small-cache16`, 50 MHz, 2 GiB
DDR4, a 1 MHz CLINT timebase and a 115200-baud Linux console.

The native controller uses eight 2 KiB receive slots and one 2 KiB transmit
buffer at `0x18000000`, PLIC interrupt 2, and a local MAC address
`02:52:41:50:05:01`. CPU accesses are aligned 32-bit PIO into uncached packet
SRAM. It does not DMA into cached DDR. Linux uses the included
[`raptor_native_eth.c`](linux/raptor_native_eth.c) driver, NAPI, and the upstream
RTL8211F PHY driver. The link supports **1000BASE-T full duplex**; `rgmii-txid`
enables PHY TX delay and disables PHY RX delay. See [the register ABI](ETHERNET.md).

Additional host prerequisites are `riscv64-linux-gnu-gcc`, kernel build tools
(`make`, `bison`, `flex`, `bc`, `libssl-dev`, `libelf-dev`), `curl`, `dtc`,
`nfs-kernel-server`, `ssh-keygen`, and the initialized OpenSBI source under
`third_party/riscv-software-src/opensbi`. The board network must already provide
DHCP; the defaults assume the host is `192.168.50.1/24`.

```sh
# Run FPGA evaluation on the primary host specified in AGENTS.md.
make -C fpga/rk-xcku5p-f ethernet-test
make -C fpga/rk-xcku5p-f ubuntu-test
make -C fpga/rk-xcku5p-f ubuntu-fpga-build

# On the UART/NFS host; official source archives are SHA-256 verified.
make -C fpga/rk-xcku5p-f ubuntu-kernel JOBS=8
make -C fpga/rk-xcku5p-f ubuntu-rootfs
make -C fpga/rk-xcku5p-f ubuntu-bundle ubuntu-check
make -C fpga/rk-xcku5p-f ubuntu-serve

# Program a matching timing-validated native build on the selected JTAG target.
make -C fpga/rk-xcku5p-f ubuntu-fpga-load NATIVE_HW_TARGET='*/0ABC01A'
make -C fpga/rk-xcku5p-f ubuntu-boot \
  UART_PORT=/dev/serial/by-id/usb-Xilinx_my_product_desc_0ABC01-if01-port0
```

`ubuntu-rootfs` uses sudo to preserve the official Ubuntu file ownership and
modes. Its default persistent directory is `build/ubuntu/rootfs`. The overlay
replaces disk-specific fstab entries, disables cloud-init, keeps the kernel's
network configuration while systemd-networkd starts, and enables root autologin
on the **serial console**. `UBUNTU_SSH_KEY` defaults to the checked-in
[`keys/ubuntu-test.pub`](keys/ubuntu-test.pub), the development host's Ed25519
public key, so rebuilding does not depend on the provisioning user's home
directory. Its fingerprint is
`SHA256:j3BFJwDL9RM5l4YcLYD3R2WvWtmqZ0SrKyqZEw7nq2c`.
It is installed as root's `authorized_keys` with mode 0600 inside a 0700
`.ssh` directory. Only the public key is included; the private key stays on
the development host. Override `UBUNTU_SSH_KEY=/path/to/another.pub` to provision
a different key, or use `UBUNTU_SSH_KEY=` to omit authorized-key provisioning.
The accepted persistent rootfs already contains this same default key, and its
manifest records the key's SHA-256. Different rootfs inputs require a new rootfs
directory, preserving the existing persistent installation.
The key enables root SSH; password SSH is disabled when a key is provisioned.
Provisioning generates unique SSH host keys for this rootfs on the
host, avoiding slow first-boot RSA generation on the board. They remain in the
NFS root; do not clone that tree to another board without regenerating its host
keys. The SSH service creates any missing keys. Journald uses a bounded volatile
journal. Ubuntu's package manager,
glibc and systemd remain the distribution versions.

Serial login and SSH authentication allow ten minutes for initialization on the 50 MHz core. The
profile suppresses dynamic news, cloud, firmware and system-summary MOTD scripts;
the basic banner and reboot notices remain.
The user manager also allows ten minutes for unit startup; D-Bus clients use
`SYSTEMD_BUS_TIMEOUT=600`. The GPG SSH-agent, snap session socket and Launchpad
cache-clean timer are disabled in this serial profile. The normal user manager
and D-Bus session remain enabled.
APT's optional Pro news/cache, PackageKit, AppStream, command-suggestion and
MOTD hooks are disabled. Package indexes, repository signature checks, debconf,
needrestart and package-maintainer scripts retain their normal behavior.

The native rootfs profile retains the fstab and serial-getty generators and
masks the other cloud-image generators. Their combined startup work exceeds
systemd 255's fixed 90-second generator-batch deadline on this core. SSH runs
as `ssh.service`, without socket activation. Service startup waits are ten
minutes; device waits are thirty minutes to allow serial-device coldplug on the
50 MHz core. Coldplug prioritizes tty/net, with two workers and a ten-minute
event timeout; all other devices are still processed. The native kernel omits
virtual terminals and loop block devices;
the UART console and Unix98 PTYs remain available. Cloud provisioning, snap/LXD
services, disk-management
daemons, local-display setup, duplicate syslog, fwupd firmware refresh, and
background apt/Ubuntu Pro tasks are masked; explicit apt commands remain
available. Module-loading units
are skipped when `/proc/modules` is absent, and Plymouth cleanup is skipped
unless its daemon is running. These are configuration files under
`/etc/systemd`; the distribution binaries are unchanged. Enabling one of these
features later requires removing its corresponding masks and providing its
hardware or service dependencies.

DNS uses the configured server directly through `/etc/resolv.conf` and the
distribution's `files dns` NSS configuration; `systemd-resolved` is masked.

The native platform has no battery-backed RTC. Before using apt or TLS after
a reset, confirm that network time synchronization has completed. If necessary,
set the board's clock from a host with correct time, for example:

```sh
ssh root@192.168.50.88 "date -u -s '@$(date +%s)'"
```

For a userspace check, run these commands in the board's serial or SSH shell:

```sh
systemctl is-active multi-user.target ssh.service systemd-networkd.service
systemctl --failed
apt-get --error-on=any update
apt-get install -y --no-install-recommends hello
hello
printf 'Raptor native Ubuntu\n' > /root/persistence-check.txt
sync
```

After another FPGA load and Ubuntu boot using the same NFS root, check
`dpkg-query -W hello`, `hello` and `cat /root/persistence-check.txt`. The
50 MHz core takes minutes to initialize userspace and process package indexes;
the firmware transfer alone is much shorter.

`ubuntu-serve` installs a runtime NFS export for this tree and
`UBUNTU_CLIENT=192.168.50.0/24`; `ubuntu-unserve` removes that export. It does not
provide DHCP, DNS or NAT. Use `UBUNTU_SERVER`, `UBUNTU_CLIENT`, `UBUNTU_ROOTFS` and
`UBUNTU_OUTPUT` consistently if overriding the defaults. Rootfs contents persist
across board resets; an existing rootfs with different provisioning inputs is
rejected rather than overwritten.

The boot bundle contains a kernel with the native driver and NFS client built
in, an empty embedded initramfs, OpenSBI `fw_payload.bin`, and a native DTB with
`root=/dev/nfs ... init=/sbin/init`. Each boot injects fresh host entropy into a
temporary DTB. By default the ROM receives only a small native TFTP loader at
`0x8f000000`; firmware and DTB travel over the native MAC with 1024-byte TFTP
blocks, retries and whole-file size/CRC checks. The host serves only those two
files on `UBUNTU_SERVER:UBUNTU_TFTP_PORT` (default UDP 6969), using ephemeral
transfer ports. Reserve `UBUNTU_BOOT_IP` (default `192.168.50.88`) for this MAC on
the same LAN; Linux subsequently obtains its address by DHCP. The existing NFS
and DHCP services remain in use. This path needs no separately installed TFTP
server and does not require privileged port binding.

For a serial-only fallback, set `UBUNTU_TRANSPORT=uart`: the RAM uploader uses
`UBUNTU_UPLOAD_BAUD=312500`, or set that rate to `115200` for the ROM protocol.
The console stays at 115200 baud with TFTP. The DTB resides at `0x8fff0000`;
payload size checks prevent overlap with the loaders and DTB.

Validation separates software artifacts from FPGA acceptance. `ubuntu-check`
verifies hashes, the native DTB, PHY mode and NFS/systemd boot arguments. Board
acceptance additionally requires a routed timing pass, DDR initialization,
native Ethernet/DHCP, an NFS root mount and an Ubuntu systemd login. Record the
bitstream, firmware and rootfs manifests with that result. A small-module timing
pass or a QEMU userspace boot is not whole-board validation.

### Access and profiling

For repeated commands, use SSH connection sharing and batch commands in one
shell session. Keep the control socket in a private directory and retain host-key
verification and public-key authentication:

```sshconfig
Host raptor-ku5p
    HostName 192.168.50.88
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    Compression no
    ConnectTimeout 600
    ControlMaster auto
    ControlPersist 15m
    ControlPath ~/.ssh/raptor-%C
```

The Ubuntu profile disables SSH DNS lookup and GSSAPI authentication while
retaining PAM account/session handling. CPU, session setup and NFS costs should
be measured separately; a new SSH connection is not a cold-boot measurement.
Use the [native benchmark tools](tests/ubuntu_bench/README.md) for repeatable
CoreMark/Embench measurements. Keep per-run results, traces, build identities
and acceptance logs in ignored local evidence directories, outside Git.

The board kernel omits legacy PTYs, block throttling, IPsec ESP and ftrace.
The latter two pulled in expensive boot-time crypto/trace work on this small
preset. Unix98 PTYs, normal kernel logs, stack traces, getrandom and userspace
SSH/TLS remain available. The kernel uses a 100 Hz scheduler tick to reduce
periodic interrupt overhead on the single 50 MHz core.

For focused physical checks with Vivado, use `scripts/ethernet_synth.tcl` and
`scripts/ethernet_route.tcl`; the latter routes only the MAC at the board pins.
`scripts/test_ethernet.py --vivado-bin /path/to/Vivado/bin` also runs the AMD
receive primitive test at −1, 0 and +1 ns input skew. Full board builds additionally
check Gray-bus skew, routed setup/hold, missing timing constraints and DRC before
creating a loadable result.

## LiteX onboard Ethernet netboot

The LiteX board profile uses the RK onboard RGMII PHY and 2 GiB DDR4 MIG at
50 MHz. Its fixed netboot build selects `RAPT_CONFIG=small` by default, builds a
BIOS with Ethernet, and packages matching RV32 or RV64 Linux boot files. Run
from the repository root:

```sh
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-check
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-build
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-info
make -C fpga/rk-xcku5p-f fpga-netboot-host-setup
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-serve
# In another terminal if serve is running in the foreground:
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-load
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-console
# At the litex> prompt, enter the exact netboot .../boot.json command printed by serve.
make -C fpga/rk-xcku5p-f fpga-netboot-rv64-test
make -C fpga/rk-xcku5p-f fpga-netboot-host-restore
```

Use `rv32` in place of `rv64` for RV32. The network host needs a dedicated
Ethernet interface and an accessible board UART/JTAG connection. Set
`NETBOOT_INTERFACE` and `NETBOOT_UART` if discovery is ambiguous. `serve` and
`console` occupy their terminals; exit the console before `test`. See the
[netboot workflow](../litex/NETBOOT.md) for host setup and result gates. The
RV64 `small` profile passed Vivado 2025.2 routing at 50 MHz (WNS +0.118 ns,
WHS +0.005 ns, zero failing setup/hold endpoints) and loaded on the detected
XCKU5P-F. MIG calibration and a 16 MiB BIOS DDR4 memory test passed. Physical
netboot is still pending: the RTL8211F reported link down and BIOS ARP failed
before TFTP, so Linux network operation has not been verified.

Linux 6.18.51 also booted through the UART `serialboot` path on the RV64
`small` LiteX bitstream. The BIOS reached its interactive `litex>` prompt,
passed a 16 MiB DDR4 memory test, and accepted the serial image. OpenSBI and
Linux reached the initramfs `tinysh#` prompt; `uname -a`, `free` and `uptime`
worked. This check did not use Ethernet. For the same 50 MHz DDR4 plus Ethernet
SoC, `middle` placed and routed with 171,927/216,960 LUTs and 26,160/27,120
CLB sites (96.46%). Final WNS was +0.024 ns and WHS was +0.005 ns, so the
implementation has very little margin. The `middle` bitstream loaded on the
XCKU5P-F, its interactive BIOS passed a 16 MiB DDR4 test, and a UART serialboot
of Linux 6.18.51 reached the initramfs `tinysh#` prompt. `uname -a`, `free`
and `uptime` worked there too. The native `default` RV64 DDR4 synthesis alone
used 230,862 LUTs, exceeding this part's LUT capacity; `default-w3` and
`default-w4` are larger still.

## Configuration and outputs

| Option | Default | Meaning |
|---|---|---|
| `XLEN` | `64` | `32` or `64` |
| `RAPT_CONFIG` | `small` | CPU preset from `hdl/configs/` |
| `MEMORY` | `ddr` | `ddr` or `bram` main RAM |
| `CLOCK_MHZ` | `50` | CPU clock target: `25`, `50` or `100` MHz |
| `RAM_BYTES` | `131072` | BRAM main RAM size; power of two, 16 KiB–1 MiB |
| `USE_RESET_BUTTON` | `0` | Set to `1` to enable the active-low reset button |
| `DDR_PART` | `MT40A512M16LY-075` | MIG memory-part selection; see board details below |
| `JOBS` | `4` | Tool parallelism, 1–32 |
| `CROSS` | `riscv64-unknown-elf-` | Cross-toolchain prefix |
| `VIVADO` | `vivado` | Vivado executable |
| `PYTHON` | `python3` | Python executable used by Make |
| `BUILD_ROOT` | This board directory's `build/` | Output root; use a separate root for each board |

`RAM_BYTES` controls BRAM mode only. DDR maps 1 GiB for RV32 and 2 GiB for
RV64. Larger CPU presets, RAM sizes and higher clocks require their own
capacity and timing checks. `CLOCK_MHZ` specifies a constraint, not measured Fmax.

`make info` prints JSON containing the selected configuration and output path.
Each configuration uses its own directory, protected by a build lock. Outputs
include ROM files `boot.elf/bin/hex`, a sample `payload.elf/bin`, the board's
`native.dts/dtb`, source snapshots, `manifest.json`, logs and reports. A successful
full build also produces `rapt_rk.bit` and a validated `result.json`.

For software-only updates, `make -C fpga/rk-xcku5p-f refresh-software`
with the original build options can retain a passing bitstream only when all
regenerated hardware inputs are byte-identical. Hardware changes require a
new `build`; an accepted refresh retains the original implementation manifest.

## Board interfaces and DDR

| Interface | Connection / behavior |
|---|---|
| Reference clock | 200 MHz differential, T24/U24, DIFF_SSTL12 |
| UART RX/TX | AD13/AC14, FT2232, LVCMOS33, 115200 8N1 |
| Optional reset | KEY1, K9, active low; disabled by default |
| LEDs 0–3 | H9/J9/G11/H11: reset released, DDR ready, heartbeat, writeback error |
| Fan | G9, active high, continuously enabled |
| DDR4 data interface | Two x16 devices, 32-bit bus, 2 GiB physical memory; 256-bit MIG AXI interface |
| Onboard Ethernet (LiteX) | RTL8211F-CG RGMII, 1.8 V I/O, 1000 Mb/s; MDIO on L19/M19 |

The [board schematic](../../third_party/rk-xcku5p-f-v1.2/doc/RK-XCKU5P-F%20V1.2原理图.pdf)
pulls `TXDLY/RXD1` high and `RXDLY/RXCTL` low. LiteX therefore uses the PHY's
TX clock delay and a compensated FPGA RX capture clock. The board UDP reference and
native DDR XDC supply the RGMII and DDR pin assignments, respectively.

Power-on reset is always enabled. DDR-ready is asserted continuously in BRAM
mode. In DDR mode, the CPU remains in reset until MIG calibration completes.
Calibration status is registered in the UI clock domain before crossing a
two-stage CPU-domain synchronizer.

One differential input buffer feeds the CPU MMCM and MIG
(`System_Clock=No_Buffer`); MIG supplies its own internal clock buffering.
The CPU uses a 1 GHz MMCM VCO. The DDR profile uses 2666 MT/s, CL=19/CWL=14
and a 333.333 MHz UI clock. A vendor AXI converter handles data-width conversion
and the CPU/UI clock crossing. `DCIRESET` initializes I/O impedance calibration;
its lock status crosses a two-stage synchronizer before MIG reset is released.
Review this reset-conditioning path when changing the clock or reset design.

The default MIG part is `MT40A512M16LY-075`, as in the supplied reference XCI.
The schematic/manual instead lists `MT40A512M16LY-062E`, and the material README
also uses `-0625E`. Confirm the fitted part and validate calibration and RAM
access on the board. Changing `DDR_PART` changes only the MIG part selection;
it does not adjust latencies, geometry or pins automatically.

The board top is [rapt_rk_top.sv](rtl/rapt_rk_top.sv). Pin assignments are in
[board.xdc](constraints/board.xdc) and [ddr4.xdc](constraints/ddr4.xdc); the DDR
profile is in [create_ip.tcl](ip/create_ip.tcl). Configuration-bank voltage is
1.8 V, and unused pins have pull-ups.

Board references under `third_party/rk-xcku5p-f-v1.2/` are optional reading,
not build-time dependencies:

- `doc/`: board schematic and user manual for device, power, clock and memory geometry.
- `designs/blink/blink.srcs/blink.xdc`: clock, UART, LED and button pins.
- `designs/ddr4_0_ex/imports/example_design.xdc`: all 71 DDR pins.
- `designs/ddr4_0_ex/ddr4_0_ex.srcs/sources_1/ip/ddr4_0/ddr4_0.xci`:
  32-bit DDR profile with 750 ps memory clock and 5000 ps reference clock.

The 50 MHz single-ended oscillator is unused; the supplied blink example
reports it as nonfunctional on its board.

## Memory map and software interface

Addresses are generated from `hdl/configs/memory_map.json`:

| Region | Base address | Size / behavior |
|---|---|---|
| CLINT | `0x02000000` | Cluster timer; 1 MHz `mtime` |
| PLIC | `0x0c000000` | Interrupt controller; UART source 1 |
| Scratch SRAM | `0x0f000000` | 8 KiB; includes the ROM monitor's stack |
| UART | `0x10000000` | Byte-spaced 8250 registers, 115200 baud, 8N1 |
| Boot ROM / reset vector | `0x20000000` | 64 KiB, initialized from `boot.hex` |
| Main RAM | `0x80000000` | `RAM_BYTES` in BRAM mode; 1 GiB RV32 / 2 GiB RV64 in DDR mode |

The platform router allows one outstanding read and one outstanding write,
with FIXED/INCR bursts, byte strobes, IDs and response backpressure. Unsupported
bursts, out-of-range accesses and transactions crossing a 4 KiB or region
boundary return DECERR; ROM writes return SLVERR.

The UART has a 16-byte receive queue, a one-byte transmit holding register,
receive/transmit interrupts and overrun/framing status. Line format is fixed
at 8N1; modem loopback and flow control are not implemented. The generated DTB
sets `fifo-size = <1>`, `tx-threshold = <0>` and `no-loopback-test` for the Linux
8250 driver. CPU, UART and timer clock properties are generated together.

## Serial loading

After JTAG programming, the ROM prints `Raptor native RK-XCKU5P-F RV64`
(or `RV32`), followed by `RAPT ready`. Close other programs using the serial
port. Set `out` to the `output` path printed by `make info` for the configuration
you loaded, and replace `/dev/ttyUSB1` with the board's actual UART device:

```sh
out=/absolute/path/reported/by/info
python3 fpga/common/scripts/upload.py --port /dev/ttyUSB1 \
  --memtest 0x80000000:0x10000 \
  --image "0x80000000:$out/payload.bin" --entry 0x80000000 --console
```

This destructively tests 64 KiB of main RAM, uploads the sample payload and
expects `NATIVE PAYLOAD PASS`. Reduce the test range if using less than 64 KiB
of BRAM. Add `--wait-ready` when starting the uploader before a reset; omit it
when the ROM monitor is already waiting.

Uploads use CRC32-checked chunks of at most 4096 bytes. The monitor rejects
writes outside main RAM and never jumps automatically after reset or a failed
upload. A failed upload may have modified its destination; upload it again
before requesting execution.

## OpenSBI and Linux

Use DDR mode and a matching RV32/RV64 OpenSBI generic-platform `fw_payload.bin`,
linked at `0x80000000` and containing a kernel with an embedded initramfs.
Use this build's `native.dtb` for the board description. Build and load the DDR
configuration, then set `out` to its output directory before uploading:

```sh
python3 fpga/common/scripts/upload.py --port /dev/ttyUSB1 \
  --image "0x80000000:/path/to/fw_payload.bin" \
  --image "0x83f00000:$out/native.dtb" \
  --entry 0x80000000 --dtb 0x83f00000 --console
```

Keep the firmware/kernel image and DTB within main RAM and non-overlapping;
choose another DTB address if the image extends into `0x83f00000`. The uploader
rejects overlapping supplied files. The ROM executes `fence rw,rw` and `fence.i`,
then enters M-mode with `a0=0`, `a1=DTB`, `satp=0` and interrupts disabled.

Default boot arguments are `console=ttyS0,115200 earlycon=sbi`. For different
arguments, copy `native.dts`, edit the copy and compile it with `dtc -I dts -O dtb`;
upload that DTB instead. UART transfer of large images is slow at 115200 baud.

## Verification and troubleshooting

These targets describe what to check for the selected configuration; they do
not certify any preset, clock target or physical board in advance.

| Target | Scope |
|---|---|
| `prepare` | Generate firmware, DTB and an immutable RTL/configuration snapshot |
| `lint` | Verilator checks of the native SoC |
| `test` | Host tools, pin/map consistency, UART and AXI regressions |
| `sim` | CPU/ROM serial upload, CRC/range rejection, RAM test and payload execution |
| `ip-check` | Elaborate the board top with generated MIG and AXI IP |
| `peripheral-synth` | Synthesize router, local memories and UART; check BRAM inference |
| `synth` | Whole-board synthesis and estimated resource/timing reports |
| `build` | Full implementation, routed setup/hold and clock/I/O constraint checks, DRC and bitstream |

For example, run the functional matrix with a selected preset:

```sh
for xlen in 32 64; do
  for memory in bram ddr; do
    make -C fpga/rk-xcku5p-f test sim \
      XLEN="$xlen" MEMORY="$memory" RAPT_CONFIG=small
  done
done
```

DDR simulation uses a delayed AXI RAM model, not a physical DDR model. For a
focused boot waveform, run `python3 fpga/rk-xcku5p-f/build.py --xlen 64 --memory ddr --trace sim`.
Review `timing_summary.rpt`, `check_timing.rpt`, `cdc.rpt`, `drc.rpt` and
`utilization.rpt` for the exact source/configuration in `manifest.json`.
The output directory also contains `index.html` for browsing all Vivado
reports and `README.md` with synthesis and implementation resource tables.
The native `synth` and `build` actions regenerate both summaries, including
partial reports after a failed Vivado run.
Peripheral synthesis excludes the CPU and board clock/DDR infrastructure.
A passing build gate does not establish CDC sign-off, DDR calibration or
successful software execution on the physical board.

- **No serial banner:** check power, UART device and 115200 8N1 settings. In DDR
  mode, check DDR-ready first: the CPU is held in reset until calibration.
- **DDR-ready stays low:** check reference clocks, reset, fitted memory part,
  pinout and MIG configuration; use BRAM mode to isolate UART/CPU bring-up.
- **Upload errors:** close competing serial clients, check addresses and RAM
  size, then retry the upload before executing it.
- **`load` rejects the build:** use matching options and rebuild after source
  changes. Use `refresh-software` only when its byte-identical hardware check passes.
