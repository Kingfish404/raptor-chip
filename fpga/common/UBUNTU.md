# Ubuntu 26.10 (RVA23) NFS root

The `ubuntu-*` targets use each board's SystemVerilog SoC. Shared
code, Linux sources and benchmark tools live under `fpga/common/`; board
profiles select the physical NIC, MAC address, loader IP and hostname. The boot chain is
boot ROM → small RAM TFTP loader → OpenSBI/Linux → Ethernet → Ubuntu
`/sbin/init` (systemd) on an NFS root. The default is RV64 `default` (RVA23U64/RVA23S64),
50 MHz, 2 GiB DDR4, a 1 MHz CLINT timebase and a 115200-baud Linux console.
The kernel builds directly from upstream mainline Linux `7.3.5` (`defconfig` plus
[`ubuntu.config`](linux/ubuntu.config) and the board Ethernet driver).

On RK-XCKU5P-F, the Ethernet controller uses eight 2 KiB receive slots and one
2 KiB transmit buffer at `0x18000000`, PLIC interrupt 2, and a local MAC address
`02:52:41:50:05:01`. CPU accesses are aligned 32-bit PIO into uncached packet
SRAM. It does not DMA into cached DDR. Linux uses the included
[`raptor_eth.c`](linux/raptor_eth.c) driver, NAPI, and the upstream
RTL8211F PHY driver. The link supports **1000BASE-T full duplex**; `rgmii-txid`
enables PHY TX delay and disables PHY RX delay. See [the register ABI](../rk-xcku5p-f/ETHERNET.md).

On MLK-CU08-KU15P, `ubuntu-bitstream` selects the CM005 three-port switch: A/B
continue forwarding while a third port supplies the CPU NIC. Linux uses the
upstream LiteEth driver with the included aligned 32-bit packet PIO patch.
The CPU has eight RX slots, two TX slots, MAC `02:52:41:50:15:01`, and PLIC
interrupt 2. MAC CSRs are at `0x18002000`, the CPU-local virtual PHY reset is at
`0x18001000`, and packet SRAM is at `0x18004000` (RX) / `0x18008000` (TX).
The CPU PHY register never drives the physical CM005 reset gate. A full CPU
queue drops its own frame copies while A/B forwarding continues.

Programming KU15P reconfigures the FPGA and temporarily interrupts any network
using its A/B bridge. Schedule that operation after dependent KU5P work has
finished; starting/stopping the Linux CPU NIC does not reset those links.

Additional host prerequisites are `riscv64-linux-gnu-gcc`, kernel build tools
(`make`, `bison`, `flex`, `bc`, `libssl-dev`, `libelf-dev`), `curl`, `dtc`,
`nfs-kernel-server`, `ssh-keygen`, and the initialized OpenSBI source under
`third_party/riscv-software-src/opensbi`. The board network must already provide
DHCP; the defaults assume the host is `192.168.50.1/24`.

```sh
# Use a build host with the required Vivado/device support.
make -C fpga/rk-xcku5p-f ethernet-test
make -C fpga/rk-xcku5p-f ubuntu-test
make -C fpga/rk-xcku5p-f ubuntu-bitstream

# On the UART/NFS host; official source archives are SHA-256 verified.
make -C fpga/rk-xcku5p-f ubuntu-kernel JOBS=8
make -C fpga/rk-xcku5p-f ubuntu-rootfs
make -C fpga/rk-xcku5p-f ubuntu-bundle ubuntu-check
make -C fpga/rk-xcku5p-f ubuntu-serve

# Program a matching timing-validated bitstream on the selected JTAG target.
make -C fpga/rk-xcku5p-f ubuntu-load HW_TARGET='*/<KU5P-JTAG-ID>'
make -C fpga/rk-xcku5p-f ubuntu-boot \
  UART_PORT='/dev/serial/by-id/<KU5P-UART>'
```

`ubuntu-rootfs` uses sudo to preserve the official Ubuntu file ownership and
modes. Its default persistent directory is `build/ubuntu/rootfs`. The overlay
replaces disk-specific fstab entries, disables cloud-init, keeps the kernel's
network configuration while systemd-networkd starts, and enables root autologin
on the **serial console**. On KU5P, `UBUNTU_SSH_KEY` defaults to the checked-in
[`keys/ubuntu-test.pub`](../rk-xcku5p-f/keys/ubuntu-test.pub), the development host's Ed25519
public key, so rebuilding does not depend on the provisioning user's home
directory. Its fingerprint is
`SHA256:j3BFJwDL9RM5l4YcLYD3R2WvWtmqZ0SrKyqZEw7nq2c`.
It is installed as root's `authorized_keys` with mode 0600 inside a 0700
`.ssh` directory. Only the public key is included; the private key stays on
the development host. Override `UBUNTU_SSH_KEY=/path/to/another.pub` to provision
a different key, or use `UBUNTU_SSH_KEY=` to omit authorized-key provisioning.
The rootfs manifest records the key's SHA-256. Different rootfs inputs require
a new rootfs directory, preserving the existing persistent installation.
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

The Ubuntu rootfs profile retains the fstab and serial-getty generators and
masks the other cloud-image generators. Their combined startup work exceeds
systemd 255's fixed 90-second generator-batch deadline on this core. SSH runs
as `ssh.service`, without socket activation. Service startup waits are ten
minutes; device waits are thirty minutes to allow serial-device coldplug on the
50 MHz core. Coldplug prioritizes tty/net, with two workers and a ten-minute
event timeout; all other devices are still processed. The kernel omits
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

The boards have no battery-backed RTC. Before using apt or TLS after
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
printf 'Raptor Ubuntu\n' > /root/persistence-check.txt
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

The boot bundle contains a kernel with the board's Ethernet driver and NFS client
built in, an empty embedded initramfs, OpenSBI `fw_payload.bin`, and a board DTB with
`root=/dev/nfs ... init=/sbin/init`. Each boot injects fresh host entropy into a
temporary DTB. By default the ROM receives only a small TFTP loader at
`0x8f000000`; firmware and DTB travel over Ethernet with 1024-byte TFTP
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
verifies hashes, the board DTB, PHY mode and NFS/systemd boot arguments. Board
acceptance additionally requires a routed timing pass, DDR initialization,
Ethernet/DHCP, an NFS root mount and an Ubuntu systemd login. Record the
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
Use the [benchmark tools](tests/ubuntu_bench/README.md) for repeatable
CoreMark/Embench measurements. Keep per-run results, traces, build identities
and acceptance logs outside the source tree.

The board kernel omits legacy PTYs, block throttling, IPsec ESP and ftrace.
The latter two pulled in expensive boot-time crypto/trace work on the 50 MHz
core. Unix98 PTYs, normal kernel logs, stack traces, getrandom and userspace
SSH/TLS remain available. The kernel uses a 100 Hz scheduler tick to reduce
periodic interrupt overhead on the single 50 MHz core.

For KU5P physical Ethernet checks, see its [board documentation](../rk-xcku5p-f/README.md).

For KU15P, use the same `ubuntu-*` sequence with `-C fpga/mlk-cu08-ku15p`.
Supply `UBUNTU_SSH_KEY=/path/to/your.pub` when preparing its separate rootfs;
the KU15P flow has no default authorized key. Its loader address defaults to
`192.168.50.90` and hostname to `raptor-ku15p`. Reserve that address and provide
DHCP for its distinct MAC. Keep each board's `UBUNTU_OUTPUT`, rootfs, JTAG ID,
UART and runtime NFS export separate.

`UBUNTU_BOARD_BUILD=/path/to/board-build` selects a copied implementation
manifest and DTB. Their board, preset, clock, networking configuration and DTB
hash must match the request. `UBUNTU_KERNEL_DIR=/path/to/kernel-artifacts`
reuses a manifest-verified kernel; KU15P additionally requires built-in LiteEth
and matching packet PIO patch provenance. Kernel and bundle manifests retain
source/artifact hashes; creating a bundle does not mark it board-validated.

Run the common host checks with `make -C fpga/mlk-cu08-ku15p ubuntu-test` or the
same target on KU5P. Run CM005 packet/switch/MMIO tests with the configured
LiteX Python environment:

```sh
fpga/litex/.venv/bin/python -m unittest discover \
  -s fpga/litex/tests -p 'test_cm005_*.py'
```

## Standard DMA Block Devices, `virtio-mmio` NIC, and QEMU I/O Bridge

[`ubuntu.config`](linux/ubuntu.config) also builds in upstream mainline drivers for:

- **VirtIO-MMIO v2** (`CONFIG_VIRTIO_MMIO=y`, `CONFIG_VIRTIO_BLK=y`, `CONFIG_VIRTIO_NET=y`)
- **SDHCI / MMC** (`CONFIG_MMC=y`, `CONFIG_MMC_SDHCI_OF_ARASAN=y`, `CONFIG_MMC_SDHCI_PCI=y`)
- **PCIe Generic ECAM + NVMe 1.4** (`CONFIG_PCI_HOST_GENERIC=y`, `CONFIG_BLK_DEV_NVME=y`)

When `native_build.py` or `ubuntu.py` is invoked with `--virtio-net 1` and/or
`--qemu-bridge 1`, [`rapt_native_io_soc.sv`](rtl/rapt_native_io_soc.sv) instantiates:

1. [`rapt_virtio_mmio_net.sv`](rtl/rapt_virtio_mmio_net.sv) at `0x10002000` (PLIC IRQ 2),
   an OASIS VirtIO 1.2 Modern (`VERSION=2`) NIC with a hardware Split-Virtqueue
   RX/TX AXI4-DMA engine advertising `VIRTIO_F_ACCESS_PLATFORM` (bit 33).
2. [`rapt_qemu_io_bridge.sv`](rtl/rapt_qemu_io_bridge.sv), forwarding `VirtIO-Blk`
   (`0x10001000`), `SDHCI` (`0x42000000`), and `PCIe ECAM + NVMe` (`0x41000000` /
   `0x50000000`) MMIO, PLIC IRQs, and non-coherent AXI4-DMA over L2 Ethernet
   (EtherType `0x88B5`, shared with `virtio-net` via [`rapt_eth_rqio_mux.sv`](rtl/rapt_eth_rqio_mux.sv))
   or SLIP+CRC16 serial fallback to [`raptor_qemu_bridge.py`](../../tools/qemu_io_bridge/raptor_qemu_bridge.py).

Non-coherent DMA uses standard upstream Linux `dma-noncoherent;` DT properties
with RVA23 `Zicbom` + `Svpbmt` cache maintenance and drives `external_write_*`
into `rapt` for LR/SC reservation invalidation, requiring zero kernel patches.
Pass `--root-device /dev/vda`, `/dev/nvme0n1`, or `/dev/mmcblk0` to `ubuntu.py`
to boot Ubuntu 26.10 directly from a local ext4 block device instead of NFS.
