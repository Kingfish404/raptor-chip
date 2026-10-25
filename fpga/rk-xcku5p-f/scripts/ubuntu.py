#!/usr/bin/env python3
"""Ubuntu 24.04 NFS boot for the native RK board (no LiteX SoC dependency)."""
import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import inspect
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

BOARD = Path(__file__).resolve().parents[1]
REPO = BOARD.parents[1]
sys.path.insert(0, str(REPO / "linux"))
from build_linux import opensbi, opensbi_fingerprint
from distro_boot import SOURCES, download


def run(argv, **kwargs):
    print("+", " ".join(map(str, argv)), flush=True)
    return subprocess.run(list(map(str, argv)), check=True, **kwargs)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


@contextlib.contextmanager
def locked(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".lock").open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def verify(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    for name, checksum in manifest["files"].items():
        require(Path(name).name == name and sha(directory / name) == checksum,
                "artifact changed: " + str(directory / name))
    return manifest


def kernel_inputs(args):
    return {
        "kernel": json.loads((REPO / "linux/kernel-source.json").read_text()),
        "driver": {p.name: sha(p) for p in sorted((BOARD / "linux").iterdir()) if p.is_file()},
        "compiler": subprocess.check_output([args.cross + "gcc", "--version"], text=True),
        "opensbi": opensbi_fingerprint(),
        "builder": digest([inspect.getsource(function) for function in
                           (kernel_inputs, configure_kernel, kernel)] +
                          [sha(REPO / "linux/build_linux.py")]),
        "base_config": "upstream riscv defconfig",
    }


def configure_kernel(tree, obj, args):
    make = ["make", "-C", tree, "O=" + str(obj), "ARCH=riscv", "CROSS_COMPILE=" + args.cross,
            "KBUILD_BUILD_USER=raptor", "KBUILD_BUILD_HOST=native-rk",
            "KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000", "KBUILD_BUILD_VERSION=1"]
    run(make + ["defconfig"])
    command = [tree / "scripts/config", "--file", obj / ".config"]
    for line in (BOARD / "linux/ubuntu.config").read_text().splitlines():
        setting = re.fullmatch(r"CONFIG_(\w+)=(.*)", line)
        disabled = re.fullmatch(r"# CONFIG_(\w+) is not set", line)
        if setting:
            name, value = setting.groups()
            if value == "y":
                command += ["-e", name]
            elif value.startswith('"'):
                command += ["--set-str", name, json.loads(value)]
            else:
                command += ["--set-val", name, value]
        elif disabled:
            command += ["-d", disabled[1]]
    run(command)
    run(make + ["olddefconfig"])
    config = (obj / ".config").read_text()
    for name in ("64BIT", "FPU", "RISCV_SBI", "RAPTOR_NATIVE_ETH", "REALTEK_PHY", "MDIO_BITBANG",
                 "NFS_FS", "NFS_V3", "ROOT_NFS", "IP_PNP", "IP_PNP_DHCP", "SERIAL_8250",
                 "SERIAL_8250_CONSOLE", "SERIAL_OF_PLATFORM", "DEVTMPFS", "CGROUPS", "FUTEX",
                 "TMPFS", "BINFMT_ELF", "BINFMT_SCRIPT", "TTY", "UNIX98_PTYS"):
        require(f"CONFIG_{name}=y\n" in config, "resolved kernel lacks built-in " + name)
    for name in ("VT", "BLK_DEV_LOOP"):
        require(f"CONFIG_{name}=y\n" not in config,
                "serial/NFS kernel unexpectedly enables " + name)
    require('CONFIG_INITRAMFS_SOURCE=""\n' in config and "CONFIG_CMDLINE_FORCE=y\n" not in config,
            "NFS boot requires empty initramfs and DT-provided command line")
    return make


def kernel(args):
    inputs = kernel_inputs(args)
    directory = args.output / "kernels" / digest(inputs)[:20]
    with locked(directory):
        if (directory / "manifest.json").exists():
            require(verify(directory)["inputs"] == inputs, "kernel inputs changed")
            return directory
        source = inputs["kernel"]
        require(re.fullmatch(r"\d+\.\d+\.\d+", source["version"]), "invalid kernel version")
        archive = args.kernel_cache / ("linux-" + source["version"] + ".tar.xz")
        if not archive.exists():
            archive.parent.mkdir(parents=True, exist_ok=True)
            partial = archive.with_suffix(".part")
            run(["curl", "--fail", "--location", "--retry", "3", source["archive_url"], "-o", partial])
            require(sha(partial) == source["sha256"], "kernel archive checksum mismatch")
            partial.replace(archive)
        require(sha(archive) == source["sha256"], "kernel archive checksum mismatch")
        # Interrupted builds reuse only this input-keyed directory.
        tree, obj = directory / ("linux-" + source["version"]), directory / "obj"
        if not (tree / "Makefile").exists():
            with tarfile.open(archive) as bundle:
                bundle.extractall(directory, filter="data")
        target = tree / "drivers/net/ethernet/raptor"
        target.mkdir(exist_ok=True)
        for name in ("raptor_native_eth.c", "Kconfig", "Makefile"):
            shutil.copyfile(BOARD / "linux" / name, target / name)
        for name, line in (("Makefile", "obj-$(CONFIG_RAPTOR_NATIVE_ETH) += raptor/"),
                           ("Kconfig", 'source "drivers/net/ethernet/raptor/Kconfig"')):
            path = tree / "drivers/net/ethernet" / name
            text = path.read_text()
            if line not in text:
                path.write_text(text + "\n" + line + "\n")
        obj.mkdir(exist_ok=True)
        make = configure_kernel(tree, obj, args)
        run(make + ["-j" + str(args.jobs), "Image"])
        shutil.copyfile(obj / "arch/riscv/boot/Image", directory / "Image")
        shutil.copyfile(obj / ".config", directory / "kernel.config")
        header = (directory / "Image").read_bytes()[:64]
        require(header[56:60] == b"RSC\x05" and struct.unpack_from("<Q", header, 8)[0] == 0x200000,
                "not an RV64 Linux Image")
        require(struct.unpack_from("<Q", header, 16)[0] + 0x200000 < 0x0fff0000,
                "kernel runtime overlaps native FDT")
        opensbi(directory / "Image", 64, directory / "fw_payload.bin", args.cross)
        require(kernel_inputs(args) == inputs, "kernel sources changed during build; retry")
        save(directory / "manifest.json", {
            "schema": "raptor-native-ubuntu-kernel-v1", "inputs": inputs, "board_validated": False,
            "files": {name: sha(directory / name) for name in ("Image", "kernel.config", "fw_payload.bin")},
        })
    return directory


def native_directory(args):
    if args.native_build:
        directory = args.native_build
    else:
        command = [sys.executable, BOARD / "build.py", "--xlen", "64", "--memory", "ddr",
                   "--ethernet", "1", "--preset", args.preset, "--clock-mhz", str(args.clock_mhz),
                   "--build-root", args.native_build_root]
        info = json.loads(subprocess.check_output(list(map(str, command + ["info"])), text=True))
        directory = Path(info["output"])
        if not (directory / "manifest.json").exists():
            run(command + ["prepare"])
    manifest = json.loads((directory / "manifest.json").read_text())
    config = manifest["configuration"]
    require((config["xlen"], config["memory"], config.get("ethernet")) == (64, "ddr", 1),
            "Ubuntu requires a native RV64 DDR build with Ethernet enabled")
    require(sha(directory / "native.dtb") == manifest["artifacts"]["native.dtb"],
            "native device tree changed")
    return directory, manifest


def bootargs(args):
    server = str(ipaddress.IPv4Address(args.server))
    root = args.rootfs.resolve()
    require(root.is_absolute() and not re.search(r"[\s,:]", str(root)), "invalid NFS root path")
    return (f"console=ttyS0,115200 earlycon=sbi root=/dev/nfs "
            f"nfsroot={server}:{root},vers=3,tcp,rsize=4096,wsize=4096 rw ip=dhcp "
            "init=/sbin/init net.ifnames=0 random.trust_bootloader=on")


def bundle(args):
    built = kernel(args)
    native, manifest = native_directory(args)
    output = args.output / "bundle"
    with locked(output):
        for name in ("Image", "fw_payload.bin", "kernel.config"):
            shutil.copyfile(built / name, output / name)
        shutil.copyfile(native / "native.dtb", output / "ubuntu.dtb")
        run(["fdtput", "-t", "s", output / "ubuntu.dtb", "/chosen", "bootargs", bootargs(args)])
        save(output / "manifest.json", {
            "schema": "raptor-native-ubuntu-bundle-v1", "kernel": verify(built),
            "native_manifest": str(native / "manifest.json"), "native_identity": manifest["sha256"],
            "native_configuration": manifest["configuration"], "rootfs": str(args.rootfs),
            "rootfs_source": SOURCES["ubuntu"], "bootargs": bootargs(args), "board_validated": False,
            "payload_address": "0x80000000", "dtb_address": "0x8fff0000",
            "files": {name: sha(output / name) for name in
                      ("Image", "fw_payload.bin", "kernel.config", "ubuntu.dtb")},
        })
    print("NATIVE_UBUNTU_BUNDLE=" + str(output), flush=True)
    return output


def overlay_file(tree, name, content, mode=0o644):
    path = tree / name
    require(not Path(name).is_absolute() and ".." not in Path(name).parts, "invalid overlay path")
    # Resolve each parent before creating anything through it. Cloud images
    # can contain absolute symlinks; never follow those into the host filesystem.
    current = tree
    for part in Path(name).parts[:-1]:
        current /= part
        require(current.resolve().is_relative_to(tree.resolve()), "overlay escapes rootfs: " + name)
        current.mkdir(exist_ok=True)
    if path.is_symlink():
        path.unlink()
    path.write_text(content)
    path.chmod(mode)


def overlay_link(tree, name, target):
    overlay_file(tree, name, "")
    path = tree / name
    path.unlink()
    path.symlink_to(target)


def native_services(tree):
    # Even PAM/module loading can exceed login's default 60s on this core.
    login = tree / "etc/login.defs"
    settings, count = re.subn(r"(?m)^LOGIN_TIMEOUT[ \t]+[^\n]+$", "LOGIN_TIMEOUT 600",
                              login.read_text())
    require(count == 1, "expected one LOGIN_TIMEOUT setting in Ubuntu login.defs")
    overlay_file(tree, "etc/login.defs", settings)
    # Preserve the basic banner and reboot notices without running Python,
    # firmware/cloud status probes or news downloads on every serial/SSH login.
    for script in ("50-landscape-sysinfo", "50-motd-news", "85-fwupd",
                   "90-updates-available", "91-contract-ua-esm-status", "91-release-upgrade",
                   "92-unattended-upgrades", "95-hwe-eol"):
        overlay_file(tree, "etc/update-motd.d/" + script,
                     "# Disabled by the native serial/NFS profile.\n", 0o644)
    # Explicit apt operations need package indexes and verification, but not
    # desktop catalogs, command suggestions, Pro news/caches or MOTD refreshes.
    # Keep debconf, needrestart and package-maintainer hooks intact.
    for config in ("20apt-esm-hook.conf", "20packagekit", "50appstream",
                   "50command-not-found", "99update-notifier"):
        overlay_file(tree, "etc/apt/apt.conf.d/" + config,
                     "// Disabled by the native serial/NFS profile.\n")
    # This fixed NFS board needs fstab and serial-console discovery. Starting
    # every cloud-image generator together exceeds systemd's fixed 90s batch
    # deadline on the 50 MHz core. Keep distro binaries intact and use masks.
    for generator in (tree / "usr/lib/systemd/system-generators").iterdir():
        if generator.name not in ("systemd-fstab-generator", "systemd-getty-generator"):
            overlay_link(tree, "etc/systemd/system-generators/" + generator.name, "/dev/null")
    overlay_link(tree, "etc/systemd/system-environment-generators/snapd-env-generator", "/dev/null")
    # Use the normal SSH daemon without the socket-address generator.
    # The cloud image enables the socket with both WantedBy and RequiredBy;
    # leaving the latter link makes ssh.service depend on the masked socket.
    for link in ("sockets.target.wants/ssh.socket", "ssh.service.requires/ssh.socket"):
        name = "etc/systemd/system/" + link
        overlay_file(tree, name, "")
        (tree / name).unlink()
    overlay_link(tree, "etc/systemd/system/ssh.socket", "/dev/null")
    overlay_link(tree, "etc/systemd/system/multi-user.target.wants/ssh.service",
                 "/usr/lib/systemd/system/ssh.service")
    # Cold executable/PAM loads and key exchange can exceed the default 120s.
    overlay_file(tree, "etc/ssh/sshd_config.d/01-raptor-native-timeout.conf",
                 "LoginGraceTime 600\n")
    overlay_file(tree, "etc/systemd/system.conf.d/50-raptor-native.conf",
                 "[Manager]\nDefaultTimeoutStartSec=10min\nDefaultDeviceTimeoutSec=30min\n"
                 "DefaultEnvironment=SYSTEMD_BUS_TIMEOUT=600\n")
    # The user manager has independent defaults. Its D-Bus socket runs a
    # systemctl helper; the 90s default expired during a normal serial login.
    overlay_file(tree, "etc/systemd/user.conf.d/50-raptor-native.conf",
                 "[Manager]\nDefaultTimeoutStartSec=10min\n"
                 "DefaultEnvironment=SYSTEMD_BUS_TIMEOUT=600\n")
    environment = tree / "etc/environment"
    values = [line for line in environment.read_text().splitlines()
              if not line.startswith("SYSTEMD_BUS_TIMEOUT=")]
    overlay_file(tree, "etc/environment", "\n".join(values + ["SYSTEMD_BUS_TIMEOUT=600"]) + "\n")
    # This profile uses OpenSSH directly and has no desktop or snap session.
    for unit in ("gpg-agent-ssh.socket", "snapd.session-agent.socket",
                 "launchpadlib-cache-clean.timer"):
        overlay_link(tree, "etc/systemd/user/" + unit, "/dev/null")
    # The distro prioritizes module/block coldplug before the console. This
    # fixed NFS board needs tty/net first; still trigger every other device.
    overlay_file(tree, "etc/systemd/system/systemd-udev-trigger.service.d/native.conf",
                 "[Service]\nExecStart=\nExecStart=-/usr/bin/udevadm trigger --type=all "
                 "--action=add --prioritized-subsystem=tty,net\n")
    # Concurrent coldplug helpers exceeded the default 180s event deadline on
    # the single 50 MHz core, including eth0's per-interface sysctl helper.
    overlay_file(tree, "etc/udev/udev.conf",
                 "# Native single-core serial/NFS profile.\nchildren_max=2\nevent_timeout=600\n")
    # These boot units set shorter limits instead of inheriting the default.
    for unit in ("systemd-sysctl", "systemd-sysusers", "systemd-journal-flush",
                 "systemd-journal-catalog-update", "systemd-hwdb-update",
                 "systemd-machine-id-commit", "systemd-binfmt", "systemd-udev-settle"):
        overlay_file(tree, "etc/systemd/system/" + unit + ".service.d/native.conf",
                     "[Service]\nTimeoutStartSec=10min\n")
    # The cloud tarball already contains a cache newer than /usr, but lacks
    # /etc/.updated. Avoid an unnecessary scan of every library over NFS on
    # first boot. A missing cache or newer /usr still runs the vendor command;
    # package-maintainer ldconfig invocations are unaffected.
    overlay_file(tree, "etc/systemd/system/ldconfig.service.d/native.conf",
                 "[Service]\nExecCondition=/bin/sh -c 'test ! -s /etc/ld.so.cache || "
                 "test /usr -nt /etc/ld.so.cache'\n")
    # All board drivers are built in. Avoid launching modprobe processes when
    # the kernel has no module support; this also works with a modular kernel.
    for unit in ("modprobe@.service", "systemd-modules-load.service"):
        overlay_file(tree, "etc/systemd/system/" + unit + ".d/native.conf",
                     "[Unit]\nConditionPathExists=/proc/modules\n")
    # No splash daemon is started by this serial-console boot. The vendor quit
    # command has a 20s deadline, shorter than a cold executable load here.
    for unit in ("plymouth-read-write", "plymouth-quit", "plymouth-quit-wait"):
        overlay_file(tree, "etc/systemd/system/" + unit + ".service.d/native.conf",
                     "[Unit]\nConditionPathExists=/run/plymouth/pid\n")
    # Cloud provisioning, snaps, disk management and local display services do
    # not participate in this serial-console/NFS profile. Background apt timers
    # stay disabled; explicit apt commands remain available.
    unused = {
        "ModemManager.service", "apport.service", "apport-forward.socket",
        "keyboard-setup.service", "console-setup.service", "getty@tty1.service",
        "lvm2-monitor.service", "dm-event.service", "dm-event.socket",
        "lvm2-lvmpolld.service", "lvm2-lvmpolld.socket", "multipathd.service",
        "multipathd.socket", "iscsid.service", "iscsid.socket", "open-iscsi.service",
        "iscsiuio.service", "iscsiuio.socket", "pollinate.service",
        "networkd-dispatcher.service", "unattended-upgrades.service",
        "apt-daily.service", "apt-daily.timer", "apt-daily-upgrade.service",
        "apt-daily-upgrade.timer", "rsyslog.service",
        "apt-news.service", "esm-cache.service", "packagekit.service",
        "e2scrub_all.service", "e2scrub_all.timer", "e2scrub_reap.service",
        "motd-news.service", "motd-news.timer",
        "update-notifier-download.service", "update-notifier-download.timer",
        "update-notifier-motd.service", "update-notifier-motd.timer",
        # Native FPGA firmware is loaded through JTAG, not fwupd devices.
        "fwupd.service", "fwupd-refresh.service", "fwupd-refresh.timer",
        # resolv.conf points directly to the configured server; NSS uses dns.
        "systemd-resolved.service",
    }
    for unit in (tree / "usr/lib/systemd/system").iterdir():
        if unit.suffix in (".service", ".socket", ".timer") and unit.name.startswith(
                ("cloud-", "snapd", "lxd-", "ua-", "ubuntu-advantage", "sysstat")):
            unused.add(unit.name)
    for unit in sorted(unused):
        overlay_link(tree, "etc/systemd/system/" + unit, "/dev/null")


def rootfs(args):
    require(os.geteuid() == 0, "rootfs extraction requires sudo to preserve Ubuntu ownership and modes")
    require(not args.rootfs.is_symlink(), "rootfs destination cannot be a symlink")
    root = args.rootfs.resolve()
    key = args.ssh_key.read_text().strip() if args.ssh_key else ""
    if key:
        require("\n" not in key and len(key.split()) >= 2 and
                key.split()[0] in ("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"),
                "expected one SSH public key")
    inputs = {"source": SOURCES["ubuntu"], "server": str(ipaddress.IPv4Address(args.server)),
              "ssh_public_key_sha256": hashlib.sha256(key.encode()).hexdigest() if key else None,
              "overlay": digest([inspect.getsource(f) for f in
                                 (rootfs, overlay_file, overlay_link, native_services)])}
    marker = root / ".raptor-native-rootfs.json"
    if root.exists():
        require(marker.is_file() and json.loads(marker.read_text())["inputs"] == inputs,
                "existing rootfs has different inputs; select a new --rootfs directory")
        print("NATIVE_UBUNTU_ROOTFS=" + str(root), flush=True)
        return root
    archive = download("ubuntu", args.downloads)
    root.parent.mkdir(parents=True, exist_ok=True)
    # Validate archive member names before a privileged system-tar extraction.
    with tarfile.open(archive) as content:
        for member in content:
            require(not Path(member.name).is_absolute() and ".." not in Path(member.name).parts,
                    "unsafe archive member: " + member.name)
    stage = Path(tempfile.mkdtemp(prefix=".ubuntu-rootfs-", dir=root.parent))
    try:
        run(["tar", "--extract", "--file", archive, "--directory", stage, "--numeric-owner",
             "--same-owner", "--xattrs", "--xattrs-include=*", "--acls", "--delay-directory-restore"])
        release = (stage / "usr/lib/os-release").read_text()
        require('ID=ubuntu\n' in release and 'VERSION_ID="24.04"\n' in release,
                "unexpected Ubuntu root filesystem release")
        require((stage / "usr/lib/systemd/systemd").is_file(), "Ubuntu systemd is missing")
        overlay_file(stage, "etc/fstab", "# The kernel mounts the native NFS root.\n"
                     "tmpfs /tmp tmpfs mode=1777,nosuid,nodev 0 0\n")
        overlay_file(stage, "etc/hostname", "raptor-ku5p\n")
        overlay_file(stage, "etc/hosts", "127.0.0.1 localhost\n127.0.1.1 raptor-ku5p\n::1 localhost\n")
        overlay_file(stage, "etc/resolv.conf", "nameserver " + args.server + "\n")
        overlay_file(stage, "etc/cloud/cloud-init.disabled", "Native NFS root provisioned by ubuntu.py\n")
        overlay_file(stage, "etc/machine-id", "")
        overlay_file(stage, "etc/systemd/network/10-raptor-native.network",
                     "[Match]\nName=eth0\n\n[Network]\nDHCP=ipv4\nKeepConfiguration=yes\n"
                     "LinkLocalAddressing=no\nIPv6AcceptRA=no\n\n[DHCPv4]\nUseMTU=no\n")
        overlay_link(stage, "etc/systemd/system/multi-user.target.wants/systemd-networkd.service",
                     "/usr/lib/systemd/system/systemd-networkd.service")
        overlay_link(stage, "etc/systemd/system/default.target",
                     "/usr/lib/systemd/system/multi-user.target")
        overlay_file(stage, "etc/systemd/system/serial-getty@ttyS0.service.d/native.conf",
                     "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear "
                     "--keep-baud 115200,38400,9600 - $TERM\n")
        overlay_file(stage, "etc/systemd/journald.conf.d/native.conf",
                     "[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n")
        native_services(stage)
        # Generate this rootfs's unique host keys on the provisioning host;
        # RSA generation on the 50 MHz board otherwise dominates first boot.
        # -A preserves existing keys. The service also repairs missing keys.
        run(["ssh-keygen", "-q", "-A", "-f", stage])
        overlay_file(stage, "etc/systemd/system/ssh.service.d/native.conf",
                     "[Service]\nExecStartPre=\nExecStartPre=/usr/bin/ssh-keygen -A\n"
                     "ExecStartPre=/usr/sbin/sshd -t\n")
        if key:
            overlay_file(stage, "root/.ssh/authorized_keys", key + "\n", 0o600)
            (stage / "root/.ssh").chmod(0o700)
            overlay_file(stage, "etc/ssh/sshd_config.d/00-raptor-native.conf",
                         "PermitRootLogin prohibit-password\nPasswordAuthentication no\n")
        save(stage / marker.name, {"schema": "raptor-native-ubuntu-rootfs-v1", "inputs": inputs,
                                  "persistent": True, "serial_root_autologin": True})
        stage.chmod(0o755)
        stage.rename(root)
    except BaseException:
        # Keep the incomplete extraction for diagnosis; never delete a live NFS root.
        print("Incomplete rootfs retained at " + str(stage), file=sys.stderr)
        raise
    print("NATIVE_UBUNTU_ROOTFS=" + str(root), flush=True)
    return root


def serve(args, remove=False):
    root = args.rootfs.resolve()
    require((root / ".raptor-native-rootfs.json").is_file(), "prepare the native Ubuntu rootfs first")
    bootargs(args)  # Also validates the export path.
    client = str(ipaddress.IPv4Network(args.client, strict=False))
    options = "rw,sync,no_subtree_check,no_root_squash"
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "nfs-export.exports").write_text(f"{root} {client}({options})\n")
    exportfs = shutil.which("exportfs") or "/usr/sbin/exportfs"
    require(Path(exportfs).is_file(), "install nfs-kernel-server before ubuntu-serve")
    privilege = [] if os.geteuid() == 0 else ["sudo", "-n"]
    if remove:
        run(privilege + [exportfs, "-u", f"{client}:{root}"])
    else:
        run(privilege + ["systemctl", "start", "nfs-kernel-server.service"])
        run(privilege + [exportfs, "-i", "-o", options, f"{client}:{root}"])
    print(("UNEXPORTED=" if remove else "EXPORTED=") + str(root), flush=True)


def check(args):
    directory = args.output / "bundle"
    record = verify(directory)
    get = lambda node, prop: subprocess.check_output(
        ["fdtget", "-t", "s", str(directory / "ubuntu.dtb"), node, prop], text=True).strip()
    require(get("/soc/ethernet@18000000", "compatible") == "raptor,native-ethernet-v1",
            "bundle does not describe native Ethernet")
    require(get("/soc/ethernet@18000000", "phy-mode") == "rgmii-txid", "wrong PHY delay mode")
    require(get("/chosen", "bootargs") == record["bootargs"], "bundle bootargs mismatch")
    require("init=/sbin/init" in record["bootargs"] and "root=/dev/nfs" in record["bootargs"],
            "bundle does not boot Ubuntu systemd from NFS")
    require((args.rootfs / ".raptor-native-rootfs.json").is_file(), "rootfs is not prepared")
    print("PASS native Ubuntu artifact checks (hardware boot is a separate acceptance step)")


def boot(args):
    require(args.port, "--port is required for boot")
    check(args)
    directory = args.output / "bundle"
    # Fresh trusted host entropy for every physical boot; never reuse an entropy
    # seed from a saved firmware bundle or print it to a build log.
    with tempfile.TemporaryDirectory(prefix="boot-", dir=args.output) as temporary:
        dtb = Path(temporary) / "runtime.dtb"
        shutil.copyfile(directory / "ubuntu.dtb", dtb)
        subprocess.run(["fdtput", "-t", "bx", str(dtb), "/chosen", "rng-seed",
                        *[f"{b:02x}" for b in os.urandom(64)]], check=True)
        save(args.output / "last-boot.json", {"runtime_dtb_sha256": sha(dtb),
             "bundle_manifest_sha256": sha(directory / "manifest.json"), "port": args.port})
        if args.transport == "tftp":
            import netboot
            netboot.upload(args.port, directory / "fw_payload.bin", dtb, Path(temporary),
                           args.server, args.boot_ip, args.tftp_port,
                           wait_ready=args.wait_ready, console=args.console)
            return
        if args.upload_baud != 115200:
            import fast_upload
            record = verify(directory)
            stage = fast_upload.build(args.output / "upload-stage",
                                      record["native_configuration"]["clock_mhz"] * 1_000_000,
                                      args.upload_baud)
            fast_upload.upload(args.port, directory / "fw_payload.bin", dtb, stage, args.upload_baud,
                               wait_ready=args.wait_ready, console=args.console)
            return
        command = [sys.executable, REPO / "fpga/common/scripts/upload.py", "--port", args.port,
                   "--image", "0x80000000:" + str(directory / "fw_payload.bin"),
                   "--image", "0x8fff0000:" + str(dtb), "--entry", "0x80000000", "--dtb", "0x8fff0000"]
        if args.wait_ready:
            command += ["--wait-ready"]
        if args.console:
            command += ["--console"]
        run(command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("kernel", "rootfs", "bundle", "check", "serve", "unserve", "boot"))
    parser.add_argument("--output", type=Path, default=BOARD / "build/ubuntu")
    parser.add_argument("--rootfs", type=Path, help="persistent NFS tree (default OUTPUT/rootfs)")
    parser.add_argument("--kernel-cache", type=Path, default=REPO / "linux/build/netboot-kernels")
    parser.add_argument("--downloads", type=Path, default=REPO / "linux/build/distro-boot/downloads")
    parser.add_argument("--cross", default="riscv64-linux-gnu-")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--native-build", type=Path, help="native build containing its verified DTB and manifest")
    parser.add_argument("--native-build-root", type=Path, default=BOARD / "build")
    parser.add_argument("--preset", default="middle-cache")
    parser.add_argument("--clock-mhz", type=int, choices=(25, 50, 100), default=50)
    parser.add_argument("--server", default="192.168.50.1")
    parser.add_argument("--client", default="192.168.50.0/24", help="NFS client subnet or single IPv4/32")
    parser.add_argument("--ssh-key", type=Path, help="optional SSH public key for root (no password SSH)")
    parser.add_argument("--port", help="board UART; use /dev/serial/by-id for stable selection")
    parser.add_argument("--transport", choices=("tftp", "uart"), default="tftp")
    parser.add_argument("--boot-ip", default="192.168.50.88",
                        help="reserved loader IPv4 address on the server LAN; Linux uses DHCP")
    parser.add_argument("--tftp-port", type=int, default=6969)
    parser.add_argument("--upload-baud", type=int, default=312500,
                        help="RAM loader rate; use 115200 to upload directly through the ROM")
    parser.add_argument("--wait-ready", action="store_true")
    parser.add_argument("--console", action="store_true")
    args = parser.parse_args()
    require(1 <= args.jobs <= 32, "jobs must be between 1 and 32")
    args.output = args.output.resolve()
    args.rootfs = args.rootfs.absolute() if args.rootfs else args.output / "rootfs"
    if args.native_build:
        args.native_build = args.native_build.resolve()
    if args.action == "kernel":
        print("NATIVE_UBUNTU_KERNEL=" + str(kernel(args)))
    elif args.action == "rootfs":
        rootfs(args)
    elif args.action == "bundle":
        bundle(args)
    elif args.action == "check":
        check(args)
    elif args.action in ("serve", "unserve"):
        serve(args, args.action == "unserve")
    else:
        boot(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from exc
