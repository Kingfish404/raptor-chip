#!/usr/bin/env python3
"""Ubuntu RVA23 preparation and boot for Raptor FPGA board profiles."""
import argparse
import asyncio
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
import threading
import time
import urllib.parse
import zlib

COMMON = Path(__file__).resolve().parents[1]
REPO = COMMON.parents[1]
sys.path.insert(0, str(REPO / "linux"))
from build_linux import opensbi, opensbi_fingerprint
from distro_boot import SOURCES, download

BOARD = PROFILE = None


def configure(board):
    global BOARD, PROFILE
    BOARD = Path(board).resolve()
    PROFILE = json.loads((BOARD / "board.json").read_text())
    if "ubuntu" not in PROFILE:
        raise ValueError("Board profile does not provide Ubuntu support")
    require(PROFILE["ubuntu"]["network_driver"] in ("raptor", "native", "liteeth"),
            "unsupported Ubuntu Ethernet driver")


def board_parser():
    """Parse --board first, because the board profile supplies other defaults."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--board", type=Path, help="board directory containing board.json")
    args, _ = parser.parse_known_args()
    if args.board:
        configure(args.board)
    elif BOARD is None:
        parser.error("--board is required")
    return parser


def network_profile(board_cfg=None):
    driver = PROFILE["ubuntu"]["network_driver"]
    if driver == "native":
        driver = "raptor"
    if board_cfg and board_cfg.get("eth_dma"):
        if driver == "liteeth":
            cm = PROFILE["cm005_cpu_ethernet"]
            return {"driver": "raptor_dma", "mac": cm["mac"],
                    "dma_base": cm["csr_base"], "fixed_link": True}
        return {"driver": "raptor_dma", "mac": "02:52:41:50:05:01",
                "dma_base": "0x18000000", "fixed_link": False}
    if driver == "liteeth":
        return dict(PROFILE["cm005_cpu_ethernet"], driver=driver)
    return {"driver": driver, "mac": "02:52:41:50:05:01"}


def has_rootfs_marker(path):
    return ((path / ".raptor-rootfs.json").is_file() or
            (path / ".raptor-native-rootfs.json").is_file())


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
        "kernel": json.loads((COMMON / "linux/kernel-source.json").read_text()),
        "driver": {p.name: sha(p) for p in sorted((COMMON / "linux").iterdir()) if p.is_file()},
        "compiler": subprocess.check_output([args.cross + "gcc", "--version"], text=True),
        "opensbi": opensbi_fingerprint(),
        "builder": digest([inspect.getsource(function) for function in
                           (kernel_inputs, configure_kernel, kernel)] +
                          [sha(REPO / "linux/build_linux.py")]),
        "base_config": "upstream riscv defconfig",
    }


def configure_kernel(tree, obj, args):
    make = ["make", "-C", tree, "O=" + str(obj), "ARCH=riscv", "CROSS_COMPILE=" + args.cross,
            "KBUILD_BUILD_USER=raptor", "KBUILD_BUILD_HOST=raptor-fpga",
            "KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000", "KBUILD_BUILD_VERSION=1"]
    run(make + ["defconfig"])
    command = [tree / "scripts/config", "--file", obj / ".config"]
    for line in (COMMON / "linux/ubuntu.config").read_text().splitlines():
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
    for name in ("64BIT", "FPU", "RISCV_SBI", "RISCV_ISA_V", "RISCV_ISA_V_DEFAULT_ENABLE",
                 "RISCV_ISA_SUPM", "RISCV_ISA_SVNAPOT", "RISCV_ISA_SVPBMT", "RISCV_ISA_ZAWRS",
                 "RISCV_ISA_ZICBOM", "RISCV_ISA_ZICBOP", "RISCV_ISA_ZICBOZ", "KVM",
                 "RAPTOR_ETH", "LITEX_LITEETH", "REALTEK_PHY", "MDIO_BITBANG",
                 "VIRTIO_MMIO", "VIRTIO_BLK", "VIRTIO_NET", "EXT4_FS",
                 "PCI", "PCI_HOST_GENERIC", "NVME_CORE", "BLK_DEV_NVME",
                 "MMC", "MMC_BLOCK", "MMC_SDHCI", "MMC_SDHCI_PLTFM",
                 "MMC_SDHCI_OF_ARASAN", "MMC_SDHCI_PCI",
                 "NFS_FS", "NFS_V3", "ROOT_NFS", "IP_PNP", "IP_PNP_DHCP", "SERIAL_8250",
                 "SERIAL_8250_CONSOLE", "SERIAL_OF_PLATFORM", "DEVTMPFS", "CGROUPS", "FUTEX",
                 "TMPFS", "BINFMT_ELF", "BINFMT_SCRIPT", "TTY", "UNIX98_PTYS",
                 "OVERLAY_FS", "SQUASHFS", "SQUASHFS_LZ4", "MTD", "MTD_BLOCK", "MTD_PHRAM",
                 "BLK_DEV_INITRD", "POWER_RESET_SYSCON_POWEROFF"):
        require(f"CONFIG_{name}=y\n" in config, "resolved kernel lacks built-in " + name)
    for name in ("VT", "BLK_DEV_LOOP"):
        require(f"CONFIG_{name}=y\n" not in config,
                "serial/NFS kernel unexpectedly enables " + name)
    require('CONFIG_INITRAMFS_SOURCE=""\n' in config and "CONFIG_CMDLINE_FORCE=y\n" not in config,
            "NFS boot requires empty initramfs and DT-provided command line")
    return make


def kernel(args):
    if args.kernel_dir:
        directory = args.kernel_dir.resolve()
        record = verify(directory)
        require(record["schema"] in ("raptor-ubuntu-kernel-v1", "raptor-native-ubuntu-kernel-v1"),
                "unknown kernel manifest")
        config = (directory / "kernel.config").read_text()
        driver = PROFILE["ubuntu"]["network_driver"]
        if driver == "liteeth":
            require("CONFIG_LITEX_LITEETH=y\n" in config, "prebuilt kernel lacks LITEX_LITEETH")
        else:
            require("CONFIG_RAPTOR_ETH=y\n" in config or "CONFIG_RAPTOR_NATIVE_ETH=y\n" in config,
                    "prebuilt kernel lacks RAPTOR_ETH")
        if getattr(args, "root_device", "nfs") == "squashfs":
            for sqsh_req in ("OVERLAY_FS", "SQUASHFS", "SQUASHFS_LZ4",
                             "MTD", "MTD_BLOCK", "MTD_PHRAM"):
                require(f"CONFIG_{sqsh_req}=y\n" in config,
                        "prebuilt kernel lacks " + sqsh_req)
        if driver == "liteeth":
            patch = "liteeth-native-pio.patch"
            require(record["inputs"]["driver"].get(patch) == sha(COMMON / "linux" / patch),
                    "prebuilt LiteEth kernel lacks the 32-bit packet PIO patch")
        return directory
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
        for name in ("raptor_eth.c", "Kconfig", "Makefile"):
            shutil.copyfile(COMMON / "linux" / name, target / name)
        for name, line in (("Makefile", "obj-$(CONFIG_RAPTOR_ETH) += raptor/"),
                           ("Kconfig", 'source "drivers/net/ethernet/raptor/Kconfig"')):
            path = tree / "drivers/net/ethernet" / name
            text = path.read_text()
            if line not in text:
                path.write_text(text + "\n" + line + "\n")
        patch = COMMON / "linux/liteeth-native-pio.patch"
        # An interrupted build can leave an already patched, input-keyed tree.
        probe = subprocess.run(["patch", "--dry-run", "--forward", "-p1", "-i", patch],
                               cwd=tree, capture_output=True)
        if probe.returncode == 0:
            run(["patch", "--forward", "-p1", "-i", patch], cwd=tree)
        else:
            run(["patch", "--dry-run", "--reverse", "-p1", "-i", patch], cwd=tree)
        obj.mkdir(exist_ok=True)
        make = configure_kernel(tree, obj, args)
        run(make + ["-j" + str(args.jobs), "Image"])
        shutil.copyfile(obj / "arch/riscv/boot/Image", directory / "Image")
        shutil.copyfile(obj / ".config", directory / "kernel.config")
        header = (directory / "Image").read_bytes()[:64]
        require(header[56:60] == b"RSC\x05" and struct.unpack_from("<Q", header, 8)[0] == 0x200000,
                "not an RV64 Linux Image")
        require(struct.unpack_from("<Q", header, 16)[0] + 0x200000 < 0x0fff0000,
                "kernel runtime overlaps FDT")
        opensbi(directory / "Image", 64, directory / "fw_payload.bin", args.cross)
        require(kernel_inputs(args) == inputs, "kernel sources changed during build; retry")
        save(directory / "manifest.json", {
            "schema": "raptor-ubuntu-kernel-v1", "inputs": inputs, "board_validated": False,
            "files": {name: sha(directory / name) for name in ("Image", "kernel.config", "fw_payload.bin")},
        })
    return directory


def board_directory(args):
    if args.board_build:
        directory = args.board_build
    else:
        command = [sys.executable, Path(__file__).with_name("native_build.py"), "--board", BOARD,
                   "--xlen", "64", "--memory", "ddr",
                   "--preset", args.preset, "--clock-mhz", str(args.clock_mhz),
                   "--build-root", args.board_build_root]
        io_soc = getattr(args, "virtio_net", 0) or getattr(args, "qemu_bridge", 0)
        if getattr(args, "eth_dma", 0):
            command += ["--eth-dma", "1"]
        if PROFILE["ubuntu"]["network_driver"] == "liteeth" and not io_soc:
            command += ["--cm005-bridge", "1", "--cm005-ethernet", "1"]
        else:
            # The virtio-mmio NIC and the QEMU bridge share the board MAC.
            command += ["--ethernet", "1"]
            if getattr(args, "virtio_net", 0):
                command += ["--virtio-net", "1"]
            if getattr(args, "qemu_bridge", 0):
                command += ["--qemu-bridge", "1"]
        info = json.loads(subprocess.check_output(list(map(str, command + ["info"])), text=True))
        directory = Path(info["output"])
        if not (directory / "manifest.json").exists():
            run(command + ["prepare"])
    manifest = json.loads((directory / "manifest.json").read_text())
    config = manifest["configuration"]
    require((config["xlen"], config["memory"]) == (64, "ddr"), "Ubuntu requires RV64 DDR")
    require(config.get("vector") == 1,
            "Ubuntu RVA23 requires an RVA23/V-enabled preset (for example default)")
    require((config["preset"], config["clock_mhz"]) == (args.preset, args.clock_mhz),
            "board build preset/clock differs from the Ubuntu request")
    io_soc = config.get("virtio_net") or config.get("qemu_bridge")
    if PROFILE["ubuntu"]["network_driver"] == "liteeth" and not io_soc:
        require(config.get("cm005_bridge") == 1 and config.get("cm005_ethernet") == 1,
                "Ubuntu requires the CM005 CPU NIC and A/B forwarding")
    else:
        require(config.get("ethernet") == 1, "Ubuntu requires onboard Ethernet enabled")
    require(sha(directory / "native.dtb") == manifest["artifacts"]["native.dtb"],
            "board device tree changed")
    compatible = subprocess.check_output(["fdtget", "-t", "s", str(directory / "native.dtb"),
                                          "/", "compatible"], text=True).strip()
    allowed_compat = {PROFILE["compatible"], PROFILE["compatible"] + "-native"}
    require(compatible in allowed_compat, "board build belongs to another board")
    return directory, manifest


ALLOWED_BLOCK_ROOTS = ("/dev/vda", "/dev/vda1", "/dev/nvme0n1", "/dev/nvme0n1p1",
                       "/dev/mmcblk0", "/dev/mmcblk0p1")
INITRD_ADDRESS = 0x90000000
PHRAM_OFFSET = 0x200000


def validate_nfs_path(path):
    root = Path(path).resolve()
    require(root.is_absolute() and not re.search(r"[\s,:]", str(root)), "invalid NFS root path")
    return root


def ramroot_fstab(server, host_export):
    ip = str(ipaddress.IPv4Address(server))
    export = validate_nfs_path(host_export)
    return (
        "# RAM-resident rootfs (loaded into DDR4); host NFS mounted only at /mnt/host.\n"
        "tmpfs /tmp tmpfs mode=1777,nosuid,nodev 0 0\n"
        f"{ip}:{export} /mnt/host nfs vers=3,tcp,rsize=32768,wsize=32768,"
        "_netdev,nofail,x-systemd.automount 0 0\n"
    )


def build_ramroot(rootfs_dir, output_initrd, server, host_export):
    """Package a prepared Ubuntu rootfs into a gzip-compressed newc cpio initrd.img.

    Leaves the source rootfs untouched; strips docs/manpages/apt caches in a staging
    copy and installs /mnt/host NFS automount in /etc/fstab so / runs purely in DDR4.
    """
    src = Path(rootfs_dir).resolve()
    require(has_rootfs_marker(src), "prepare the Ubuntu rootfs first")
    fstab_text = ramroot_fstab(server, host_export)
    with tempfile.TemporaryDirectory(prefix=".ramroot-stage-", dir=output_initrd.parent) as temp:
        stage = Path(temp) / "root"
        run(["cp", "-a", "--reflink=auto", str(src), str(stage)])
        for prune in ("var/cache/apt/archives", "var/lib/apt/lists",
                      "usr/share/doc", "usr/share/man", "usr/share/info",
                      "usr/share/locale", "usr/share/i18n",
                      "usr/share/python-babel-localedata", "usr/share/vim",
                      "usr/share/fwupd", "usr/share/perl",
                      "usr/lib/snapd", "usr/lib/python3", "usr/lib/cargo"):
            target = stage / prune
            if target.is_dir():
                shutil.rmtree(target)
                target.mkdir(parents=True, exist_ok=True)
        for pydir in (stage / "usr/lib").glob("python3.*"):
            if pydir.is_dir():
                shutil.rmtree(pydir)
        (stage / "mnt/host").mkdir(parents=True, exist_ok=True)
        (stage / "var/lib/man-db/auto-update").unlink(missing_ok=True)
        overlay_file(stage, "etc/fstab", fstab_text)
        overlay_file(stage, "etc/apt/apt.conf.d/95-raptor-fast.conf", FAST_APT_CONF)
        overlay_file(stage, "etc/apt/apt.conf.d/99needrestart",
                     "// Disabled by the Raptor FPGA profile.\n")
        gai_src = stage / "etc/gai.conf"
        gai_text = gai_src.read_text() if gai_src.is_file() else ""
        if GAI_IPV4_CONF.strip() not in gai_text:
            gai_text = gai_text.rstrip("\n") + ("\n" if gai_text else "") + GAI_IPV4_CONF
        overlay_file(stage, "etc/gai.conf", gai_text)
        overlay_file(stage, "etc/systemd/system/raptor-boot-env.service", RAPTOR_BOOT_ENV_SERVICE)
        overlay_link(stage, "etc/systemd/system/sysinit.target.wants/raptor-boot-env.service",
                     "/etc/systemd/system/raptor-boot-env.service")
        overlay_file(stage, "usr/local/sbin/raptor-boot-env", RAPTOR_BOOT_ENV_SH, 0o755)
        tmp_img = output_initrd.with_suffix(".img.tmp")
        find_proc = subprocess.Popen(["find", ".", "-print0"], cwd=stage, stdout=subprocess.PIPE)
        cpio_proc = subprocess.Popen(
            ["cpio", "--null", "-o", "--format=newc", "--quiet"],
            cwd=stage, stdin=find_proc.stdout, stdout=subprocess.PIPE)
        find_proc.stdout.close()
        with tmp_img.open("wb") as out_f:
            gzip_proc = subprocess.Popen(["gzip", "-1"], stdin=cpio_proc.stdout, stdout=out_f)
            cpio_proc.stdout.close()
            require(gzip_proc.wait() == 0 and cpio_proc.wait() == 0 and find_proc.wait() == 0,
                    "failed to build ramroot initrd.img")
        tmp_img.replace(output_initrd)
    return output_initrd


SWITCHROOT_INIT_C = """\
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void sync_dt_epoch(void)
{
    if (mount("proc", "/proc", "proc", 0, NULL) < 0 && errno != EBUSY)
        return;
    int fd = open("/proc/device-tree/chosen/raptor,host-epoch", O_RDONLY);
    if (fd >= 0) {
        uint8_t buf[8];
        if (read(fd, buf, 8) == 8) {
            uint64_t sec = 0;
            for (int i = 0; i < 8; i++)
                sec = (sec << 8) | buf[i];
            if (sec > 1700000000ULL) {
                struct timespec ts = { .tv_sec = (time_t)sec, .tv_nsec = 0 };
                clock_settime(CLOCK_REALTIME, &ts);
            }
        }
        close(fd);
    }
    umount("/proc");
}

static void die(const char *msg)
{
    perror(msg);
    for (;;) sleep(60);
}

int main(int argc, char **argv)
{
    (void)argc;
    mkdir("/dev", 0755);
    mkdir("/proc", 0755);
    mkdir("/sys", 0755);
    mkdir("/lower", 0755);
    mkdir("/rw", 0755);
    mkdir("/merged", 0755);
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 && errno != EBUSY)
        die("mount devtmpfs");
    for (int i = 0; i < 50; i++) {
        if (access("/dev/mtdblock0", F_OK) == 0)
            break;
        usleep(100000);
    }
    if (mount("/dev/mtdblock0", "/lower", "squashfs", MS_RDONLY, NULL) < 0)
        die("mount squashfs /dev/mtdblock0");
    if (mount("tmpfs", "/rw", "tmpfs", 0, "mode=0755") < 0)
        die("mount tmpfs /rw");
    mkdir("/rw/upper", 0755);
    mkdir("/rw/work", 0755);
    if (mount("overlay", "/merged", "overlay", 0,
              "lowerdir=/lower,upperdir=/rw/upper,workdir=/rw/work") < 0)
        die("mount overlay /merged");
    mkdir("/merged/dev", 0755);
    mount("/dev", "/merged/dev", NULL, MS_MOVE, NULL);
    if (chdir("/merged") < 0)
        die("chdir /merged");
    if (mount(".", "/", NULL, MS_MOVE, NULL) < 0)
        die("mount MS_MOVE /");
    if (chroot(".") < 0)
        die("chroot");
    if (chdir("/") < 0)
        die("chdir /");
    sync_dt_epoch();
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
    argv[0] = "/sbin/init";
    execv("/sbin/init", argv);
    die("execv /sbin/init");
    return 1;
}
"""

RAPTOR_MINIMAL_TARGET = (
    "[Unit]\n"
    "Description=Raptor Minimal Fast-Boot Target (SSH + Serial + Network + APT)\n"
    "DefaultDependencies=no\n"
    "Requires=local-fs.target systemd-tmpfiles-setup.service raptor-boot-env.service\n"
    "Wants=systemd-journald.service ssh.service raptor-console.service remote-fs.target\n"
    "After=local-fs.target systemd-tmpfiles-setup.service raptor-boot-env.service "
    "ssh.service raptor-console.service\n"
    "AllowIsolate=yes\n"
)

RAPTOR_CONSOLE_SERVICE = (
    "[Unit]\n"
    "Description=Raptor Fast Serial Root Console on ttyS0\n"
    "DefaultDependencies=no\n"
    "After=local-fs.target systemd-tmpfiles-setup.service raptor-boot-env.service\n"
    "Conflicts=shutdown.target\n"
    "Before=shutdown.target\n\n"
    "[Service]\n"
    "ExecStartPre=-/usr/bin/rm -f /run/nologin\n"
    "ExecStart=-/usr/sbin/agetty --autologin root --noclear "
    "--keep-baud 115200,38400,9600 ttyS0 vt220\n"
    "Type=idle\n"
    "Restart=always\n"
    "RestartSec=1\n"
)

RAPTOR_BOOT_ENV_SERVICE = (
    "[Unit]\n"
    "Description=Raptor Device-Tree Clock, Proxy, and APT Mirror Sync\n"
    "DefaultDependencies=no\n"
    "After=local-fs.target\n"
    "Before=sysinit.target ssh.service raptor-console.service\n"
    "Conflicts=shutdown.target\n\n"
    "[Service]\n"
    "Type=oneshot\n"
    "RemainAfterExit=yes\n"
    "ExecStart=/bin/sh /usr/local/sbin/raptor-boot-env\n"
)

RAPTOR_BOOT_ENV_SH = """\
#!/bin/sh
set -eu
CHOSEN=/proc/device-tree/chosen
APT_PROXY=/etc/apt/apt.conf.d/98-raptor-proxy.conf
PROF_PROXY=/etc/profile.d/raptor-proxy.sh
SOURCES=/etc/apt/sources.list.d/ubuntu.sources

if [ -f "$CHOSEN/raptor,host-epoch" ]; then
    sec=$(od -An -tu8 --endian=big "$CHOSEN/raptor,host-epoch" 2>/dev/null | tr -d ' \\n' || true)
    now=$(date +%s 2>/dev/null || echo 0)
    case "$sec" in
        ''|*[!0-9]*) ;;
        *) [ "$sec" -gt "$now" ] && date -u -s "@$sec" >/dev/null 2>&1 || true ;;
    esac
fi

read_url() {
    [ -f "$1" ] || return 0
    val=$(tr -d '\\000\\r\\n' < "$1" 2>/dev/null || true)
    case "$val" in
        http://*[!A-Za-z0-9._:/-]*|https://*[!A-Za-z0-9._:/-]*) ;;
        http://*|https://*) printf '%s' "$val" ;;
    esac
}

proxy=$(read_url "$CHOSEN/raptor,http-proxy")
if [ -n "$proxy" ]; then
    mkdir -p /etc/apt/apt.conf.d /etc/profile.d
    {
        printf 'Acquire::http::Proxy "%s";\\n' "$proxy"
        printf 'Acquire::https::Proxy "%s";\\n' "$proxy"
    } > "$APT_PROXY"
    cat > "$PROF_PROXY" <<EOF
export http_proxy="$proxy" https_proxy="$proxy"
export HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy"
export no_proxy="localhost,127.0.0.1,192.168.50.0/24"
export NO_PROXY="localhost,127.0.0.1,192.168.50.0/24"
EOF
else
    rm -f "$APT_PROXY" "$PROF_PROXY"
fi

mirror=$(read_url "$CHOSEN/raptor,apt-mirror")
if [ -n "$mirror" ] && [ -f "$SOURCES" ]; then
    mirror="${mirror%/}/"
    sed -i "s|^URIs:[[:space:]].*|URIs: $mirror|" "$SOURCES"
fi
"""

RAPTOR_MINIMAL_SSH_CONF = (
    "[Unit]\n"
    "DefaultDependencies=no\n"
    "After=local-fs.target systemd-tmpfiles-setup.service raptor-boot-env.service\n"
    "Conflicts=shutdown.target\n"
    "Before=shutdown.target\n"
)

RAPTOR_MINIMAL_KEYGEN_CONF = (
    "[Unit]\n"
    "DefaultDependencies=no\n"
    "After=local-fs.target\n"
    "Conflicts=shutdown.target\n"
    "Before=shutdown.target\n"
)

FAST_SSH_CONF = (
    "LoginGraceTime 600\n"
    "MaxStartups 64:30:128\n"
    "UseDNS no\n"
    "GSSAPIAuthentication no\n"
    "KexAlgorithms curve25519-sha256\n"
    "Ciphers chacha20-poly1305@openssh.com,aes128-ctr,aes128-gcm@openssh.com\n"
)

FAST_APT_CONF = (
    'Acquire::ForceIPv4 "true";\n'
    'Acquire::Languages "none";\n'
    'Acquire::GzipIndexes "false";\n'
    'Acquire::CompressionTypes::Order { "gz"; "xz"; };\n'
    'DPkg::Options { "--force-unsafe-io"; };\n'
)

GAI_IPV4_CONF = "precedence ::ffff:0:0/96  100\n"


def build_switchroot_initramfs(output_cpio_gz, cross="riscv64-linux-gnu-"):
    """Build a minimal static /init cpio.gz that mounts phram SquashFS + OverlayFS."""
    cc = shutil.which(cross + "gcc")
    require(cc is not None, f"missing {cross}gcc needed for switch_root initramfs")
    with tempfile.TemporaryDirectory(prefix=".switchroot-", dir=output_cpio_gz.parent) as temp:
        tmp_dir = Path(temp)
        src_c = tmp_dir / "init.c"
        root_dir = tmp_dir / "root"
        root_dir.mkdir(parents=True, exist_ok=True)
        src_c.write_text(SWITCHROOT_INIT_C)
        init_bin = root_dir / "init"
        run([cc, "-static", "-Os", "-s", "-Wall", "-Wextra", "-Werror",
             str(src_c), "-o", str(init_bin)])
        init_bin.chmod(0o755)
        tmp_img = output_cpio_gz.with_suffix(".cpio.gz.tmp")
        find_proc = subprocess.Popen(["find", ".", "-print0"], cwd=root_dir,
                                     stdout=subprocess.PIPE)
        cpio_proc = subprocess.Popen(["cpio", "--null", "-o", "--format=newc", "--quiet"],
                                     cwd=root_dir, stdin=find_proc.stdout,
                                     stdout=subprocess.PIPE)
        find_proc.stdout.close()
        with tmp_img.open("wb") as out_f:
            gzip_proc = subprocess.Popen(["gzip", "-9"], stdin=cpio_proc.stdout, stdout=out_f)
            cpio_proc.stdout.close()
            require(gzip_proc.wait() == 0 and cpio_proc.wait() == 0 and find_proc.wait() == 0,
                    "failed to build switch_root initramfs")
        size = tmp_img.stat().st_size
        require(0 < size < PHRAM_OFFSET, "switch_root initramfs exceeds PHRAM_OFFSET")
        tmp_img.replace(output_cpio_gz)
    return size


def build_squashfs(rootfs_dir, output_sqsh, server, host_export, *, use_sudo=False):
    """Package a full, unmodified Ubuntu rootfs into an LZ4-HC SquashFS image.

    Injects /etc/fstab (/mnt/host NFS automount), /etc/systemd/system/raptor-minimal.target,
    and fast OpenSSH settings via mksquashfs pseudo-files without modifying or
    pruning the source rootfs.
    """
    src = Path(rootfs_dir).resolve()
    require(has_rootfs_marker(src), "prepare the Ubuntu rootfs first")
    mksq = shutil.which("mksquashfs")
    require(mksq is not None, "install squashfs-tools (mksquashfs) for --root-device squashfs")
    fstab_text = ramroot_fstab(server, host_export)
    with tempfile.TemporaryDirectory(prefix=".sqsh-stage-", dir=output_sqsh.parent) as temp:
        tmp_dir = Path(temp)
        target_file = tmp_dir / "raptor-minimal.target"
        console_file = tmp_dir / "raptor-console.service"
        boot_env_svc = tmp_dir / "raptor-boot-env.service"
        boot_env_py = tmp_dir / "raptor-boot-env"
        fstab_file = tmp_dir / "fstab"
        ssh_file = tmp_dir / "02-raptor-fast-ssh.conf"
        apt_file = tmp_dir / "95-raptor-fast.conf"
        needrestart_file = tmp_dir / "99needrestart"
        gai_file = tmp_dir / "gai.conf"
        ssh_dropin = tmp_dir / "02-raptor-fast-ssh-unit.conf"
        keygen_dropin = tmp_dir / "02-raptor-fast-keygen.conf"
        exclude_file = tmp_dir / "exclude.txt"
        pseudo_file = tmp_dir / "pseudo.txt"
        target_file.write_text(RAPTOR_MINIMAL_TARGET)
        console_file.write_text(RAPTOR_CONSOLE_SERVICE)
        boot_env_svc.write_text(RAPTOR_BOOT_ENV_SERVICE)
        boot_env_py.write_text(RAPTOR_BOOT_ENV_SH)
        fstab_file.write_text(fstab_text)
        ssh_file.write_text(FAST_SSH_CONF)
        apt_file.write_text(FAST_APT_CONF)
        needrestart_file.write_text("// Disabled by the Raptor FPGA profile.\n")
        gai_src = src / "etc/gai.conf"
        existing_gai = gai_src.read_text() if gai_src.is_file() else ""
        if GAI_IPV4_CONF.strip() not in existing_gai:
            sep = "\n" if existing_gai else ""
            existing_gai = existing_gai.rstrip("\n") + sep + GAI_IPV4_CONF
        gai_file.write_text(existing_gai)
        ssh_dropin.write_text(RAPTOR_MINIMAL_SSH_CONF)
        keygen_dropin.write_text(RAPTOR_MINIMAL_KEYGEN_CONF)
        exclude_file.write_text(
            "etc/fstab\n"
            "etc/gai.conf\n"
            "etc/apt/apt.conf.d/95-raptor-fast.conf\n"
            "etc/apt/apt.conf.d/99needrestart\n"
            "etc/systemd/system/raptor-minimal.target\n"
            "etc/systemd/system/raptor-console.service\n"
            "etc/systemd/system/raptor-boot-env.service\n"
            "usr/local/sbin/raptor-boot-env\n"
            "var/lib/man-db/auto-update\n"
        )
        pseudo_file.write_text(
            "/etc/apt d 755 0 0\n"
            "/etc/apt/apt.conf.d d 755 0 0\n"
            "/etc/systemd d 755 0 0\n"
            "/etc/systemd/system d 755 0 0\n"
            "/etc/systemd/system/sysinit.target.wants d 755 0 0\n"
            "/etc/systemd/system/ssh.service.d d 755 0 0\n"
            "/etc/systemd/system/sshd-keygen.service.d d 755 0 0\n"
            "/usr/local d 755 0 0\n"
            "/usr/local/sbin d 755 0 0\n"
            f"/etc/systemd/system/raptor-minimal.target f 644 0 0 cat {target_file}\n"
            f"/etc/systemd/system/raptor-console.service f 644 0 0 cat {console_file}\n"
            f"/etc/systemd/system/raptor-boot-env.service f 644 0 0 cat {boot_env_svc}\n"
            "/etc/systemd/system/sysinit.target.wants/raptor-boot-env.service "
            "s 777 0 0 /etc/systemd/system/raptor-boot-env.service\n"
            f"/usr/local/sbin/raptor-boot-env f 755 0 0 cat {boot_env_py}\n"
            "/etc/systemd/system/ssh.service.d/02-raptor-fast.conf "
            f"f 644 0 0 cat {ssh_dropin}\n"
            "/etc/systemd/system/sshd-keygen.service.d/02-raptor-fast.conf "
            f"f 644 0 0 cat {keygen_dropin}\n"
            f"/etc/fstab f 644 0 0 cat {fstab_file}\n"
            f"/etc/gai.conf f 644 0 0 cat {gai_file}\n"
            f"/etc/apt/apt.conf.d/95-raptor-fast.conf f 644 0 0 cat {apt_file}\n"
            f"/etc/apt/apt.conf.d/99needrestart f 644 0 0 cat {needrestart_file}\n"
            f"/etc/ssh/sshd_config.d/02-raptor-fast-ssh.conf f 644 0 0 cat {ssh_file}\n"
            "/mnt/host d 755 0 0\n"
        )
        tmp_img = output_sqsh.with_suffix(".sqsh.tmp")
        if tmp_img.exists():
            tmp_img.unlink()
        prefix = ["sudo", "-n"] if (use_sudo and os.geteuid() != 0) else []
        run(prefix + [mksq, str(src), str(tmp_img), "-comp", "lz4", "-Xhc",
                      "-b", "131072", "-ef", str(exclude_file), "-pf", str(pseudo_file),
                      "-noappend", "-quiet"])
        tmp_img.replace(output_sqsh)
    return output_sqsh


def pack_combined_squashfs_initrd(initramfs_path, sqsh_path, output_img):
    """Combine initramfs.cpio.gz at offset 0 and SquashFS at PHRAM_OFFSET."""
    initramfs_bytes = Path(initramfs_path).read_bytes()
    initramfs_size = len(initramfs_bytes)
    require(0 < initramfs_size < PHRAM_OFFSET, "initramfs exceeds PHRAM_OFFSET")
    sqsh_size = Path(sqsh_path).stat().st_size
    require(sqsh_size >= 4, "invalid SquashFS size")
    tmp_img = output_img.with_suffix(".img.tmp")
    with tmp_img.open("wb") as out_f, Path(sqsh_path).open("rb") as sqsh_f:
        out_f.write(initramfs_bytes)
        out_f.write(b"\x00" * (PHRAM_OFFSET - initramfs_size))
        shutil.copyfileobj(sqsh_f, out_f, length=1024 * 1024)
    tmp_img.replace(output_img)
    return initramfs_size, sqsh_size


def inspect_combined_squashfs_initrd(image_path):
    """Extract (initramfs_size, sqsh_size) from a combined initrd.img."""
    total = Path(image_path).stat().st_size
    require(total > PHRAM_OFFSET + 4, "combined squashfs initrd is smaller than PHRAM_OFFSET")
    with Path(image_path).open("rb") as stream:
        head = stream.read(PHRAM_OFFSET)
        sqsh_magic = stream.read(4)
    require(head[:2] == b"\x1f\x8b" and sqsh_magic == b"hsqs",
            "expected gzipped initramfs at 0 and SquashFS at PHRAM_OFFSET")
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    dec.decompress(head)
    require(dec.eof, "truncated gzipped initramfs header before PHRAM_OFFSET")
    initramfs_size = len(head) - len(dec.unused_data)
    return initramfs_size, total - PHRAM_OFFSET


def inject_phram_dtb(dtb_path, sqsh_size, phram_addr=INITRD_ADDRESS + PHRAM_OFFSET):
    """Add cached DT phram (MEMREMAP_WB) + reserved-memory nodes for SquashFS."""
    dts_txt = subprocess.check_output(["dtc", "-I", "dtb", "-O", "dts", str(dtb_path)], text=True)
    res_size = ((sqsh_size + 0x1000000 - 1) // 0x1000000) * 0x1000000
    addr_hi = (phram_addr >> 32) & 0xffffffff
    addr_lo = phram_addr & 0xffffffff
    nodes = (
        "\n\treserved-memory {\n"
        "\t\t#address-cells = <0x02>;\n"
        "\t\t#size-cells = <0x02>;\n"
        "\t\tranges;\n\n"
        f"\t\tphram_rootfs@{phram_addr:x} {{\n"
        f"\t\t\treg = <0x{addr_hi:x} 0x{addr_lo:x} 0x0 0x{res_size:x}>;\n"
        "\t\t};\n"
        "\t};\n\n"
        f"\tphram@{phram_addr:x} {{\n"
        '\t\tcompatible = "phram";\n'
        '\t\tlabel = "rootfs";\n'
        f"\t\treg = <0x{addr_hi:x} 0x{addr_lo:x} 0x0 0x{sqsh_size:x}>;\n"
        "\t};\n"
    )
    idx = dts_txt.rfind("};")
    require(idx != -1, "invalid DTB syntax when injecting phram node")
    with tempfile.TemporaryDirectory(prefix=".phram-dts-", dir=dtb_path.parent) as temp:
        dts_file = Path(temp) / "phram.dts"
        dts_file.write_text(dts_txt[:idx] + nodes + dts_txt[idx:])
        run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb_path), str(dts_file)])


def bootargs(args):
    root_dev = getattr(args, "root_device", "nfs") or "nfs"
    systemd_target = getattr(args, "systemd_target", "default") or "default"
    require(systemd_target in ("default", "minimal"),
            "unsupported systemd target: " + str(systemd_target))
    unit_arg = " systemd.unit=raptor-minimal.target" if systemd_target == "minimal" else ""
    if root_dev == "squashfs":
        ipaddress.IPv4Address(args.server)
        validate_nfs_path(getattr(args, "host_nfs", None) or args.rootfs)
        return ("console=ttyS0,115200 earlycon=sbi rdinit=/init ip=dhcp "
                "net.ifnames=0 random.trust_bootloader=on "
                "unaligned_scalar_speed=fast unaligned_vector_speed=fast" + unit_arg)
    if root_dev == "ramroot":
        ipaddress.IPv4Address(args.server)
        validate_nfs_path(getattr(args, "host_nfs", None) or args.rootfs)
        return ("console=ttyS0,115200 earlycon=sbi rootfstype=tmpfs rdinit=/sbin/init ip=dhcp "
                "net.ifnames=0 random.trust_bootloader=on "
                "unaligned_scalar_speed=fast unaligned_vector_speed=fast" + unit_arg)
    if root_dev != "nfs":
        require(root_dev in ALLOWED_BLOCK_ROOTS, "unsupported block root device: " + str(root_dev))
        return (f"console=ttyS0,115200 earlycon=sbi root={root_dev} rootfstype=ext4 rw rootwait "
                "init=/sbin/init net.ifnames=0 random.trust_bootloader=on "
                "unaligned_scalar_speed=fast unaligned_vector_speed=fast" + unit_arg)
    server = str(ipaddress.IPv4Address(args.server))
    root = validate_nfs_path(args.rootfs)
    return (f"console=ttyS0,115200 earlycon=sbi root=/dev/nfs "
            f"nfsroot={server}:{root},vers=3,tcp,rsize=32768,wsize=32768 "
            "rw ip=dhcp init=/sbin/init net.ifnames=0 random.trust_bootloader=on "
            "unaligned_scalar_speed=fast unaligned_vector_speed=fast" + unit_arg)


def bundle(args):
    built = kernel(args)
    board_dir, manifest = board_directory(args)
    output = args.output / "bundle"
    root_dev = getattr(args, "root_device", "nfs") or "nfs"
    with locked(output):
        for name in ("Image", "fw_payload.bin", "kernel.config"):
            shutil.copyfile(built / name, output / name)
        shutil.copyfile(board_dir / "native.dtb", output / "ubuntu.dtb")
        run(["fdtput", "-t", "s", output / "ubuntu.dtb", "/chosen", "bootargs", bootargs(args)])
        bundle_files = ["Image", "fw_payload.bin", "kernel.config", "ubuntu.dtb"]
        extra = {}
        if root_dev == "squashfs":
            initrd_out = output / "initrd.img"
            if getattr(args, "initrd", None):
                src_img = Path(args.initrd).resolve()
                with src_img.open("rb") as stream:
                    magic = stream.read(4)
                if magic == b"hsqs":
                    with tempfile.TemporaryDirectory(prefix=".sqsh-wrap-", dir=output) as temp:
                        cpio_gz = Path(temp) / "initramfs.cpio.gz"
                        build_switchroot_initramfs(cpio_gz, args.cross)
                        initramfs_size, sqsh_size = pack_combined_squashfs_initrd(
                            cpio_gz, src_img, initrd_out)
                else:
                    shutil.copyfile(src_img, initrd_out)
                    initramfs_size, sqsh_size = inspect_combined_squashfs_initrd(initrd_out)
            else:
                host_export = getattr(args, "host_nfs", None) or args.rootfs
                with tempfile.TemporaryDirectory(prefix=".sqsh-build-", dir=output) as temp:
                    cpio_gz = Path(temp) / "initramfs.cpio.gz"
                    sqsh_img = Path(temp) / "ubuntu.sqsh"
                    build_switchroot_initramfs(cpio_gz, args.cross)
                    build_squashfs(args.rootfs, sqsh_img, args.server, host_export, use_sudo=True)
                    initramfs_size, sqsh_size = pack_combined_squashfs_initrd(
                        cpio_gz, sqsh_img, initrd_out)
            initrd_size = initrd_out.stat().st_size
            initrd_end = INITRD_ADDRESS + initramfs_size
            phram_addr = INITRD_ADDRESS + PHRAM_OFFSET
            inject_phram_dtb(output / "ubuntu.dtb", sqsh_size, phram_addr)
            run(["fdtput", "-t", "x", output / "ubuntu.dtb", "/chosen", "linux,initrd-start",
                 f"{(INITRD_ADDRESS >> 32) & 0xffffffff:x}", f"{INITRD_ADDRESS & 0xffffffff:x}"])
            run(["fdtput", "-t", "x", output / "ubuntu.dtb", "/chosen", "linux,initrd-end",
                 f"{(initrd_end >> 32) & 0xffffffff:x}", f"{initrd_end & 0xffffffff:x}"])
            run(["fdtput", "-t", "s", output / "ubuntu.dtb", "/chosen", "bootargs", bootargs(args)])
            bundle_files.append("initrd.img")
            extra["initrd_address"] = hex(INITRD_ADDRESS)
            extra["initrd_size"] = initrd_size
            extra["phram_address"] = hex(phram_addr)
            extra["squashfs_size"] = sqsh_size
        elif root_dev == "ramroot":
            initrd_out = output / "initrd.img"
            if getattr(args, "initrd", None):
                shutil.copyfile(args.initrd, initrd_out)
            else:
                host_export = getattr(args, "host_nfs", None) or args.rootfs
                build_ramroot(args.rootfs, initrd_out, args.server, host_export)
            initrd_size = initrd_out.stat().st_size
            initrd_end = INITRD_ADDRESS + initrd_size
            run(["fdtput", "-t", "x", output / "ubuntu.dtb", "/chosen", "linux,initrd-start",
                 f"{(INITRD_ADDRESS >> 32) & 0xffffffff:x}", f"{INITRD_ADDRESS & 0xffffffff:x}"])
            run(["fdtput", "-t", "x", output / "ubuntu.dtb", "/chosen", "linux,initrd-end",
                 f"{(initrd_end >> 32) & 0xffffffff:x}", f"{initrd_end & 0xffffffff:x}"])
            bundle_files.append("initrd.img")
            extra["initrd_address"] = hex(INITRD_ADDRESS)
            extra["initrd_size"] = initrd_size
        save(output / "manifest.json", {
            "schema": "raptor-ubuntu-bundle-v1", "kernel": verify(built),
            "board_manifest": str(board_dir / "manifest.json"),
            "board_identity": manifest["sha256"],
            "board_configuration": manifest["configuration"], "rootfs": str(args.rootfs),
            "board": BOARD.name, "network": network_profile(manifest["configuration"]),
            "rootfs_source": SOURCES["ubuntu"], "bootargs": bootargs(args), "board_validated": False,
            "payload_address": "0x80000000", "dtb_address": "0x8fff0000",
            **extra,
            "files": {name: sha(output / name) for name in bundle_files},
        })
    print("UBUNTU_BUNDLE=" + str(output), flush=True)
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


def board_services(tree):
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
                     "# Disabled by the Raptor serial/NFS profile.\n", 0o644)
    # Explicit apt operations need package indexes and verification, but not
    # desktop catalogs, command suggestions, Pro news/caches or MOTD refreshes.
    # Keep debconf, needrestart and package-maintainer hooks intact.
    for config in ("20apt-esm-hook.conf", "20packagekit", "50appstream",
                   "50command-not-found", "99needrestart", "99update-notifier"):
        overlay_file(tree, "etc/apt/apt.conf.d/" + config,
                     "// Disabled by the Raptor serial/NFS profile.\n")
    overlay_file(tree, "etc/apt/apt.conf.d/95-raptor-fast.conf", FAST_APT_CONF)
    (tree / "var/lib/man-db/auto-update").unlink(missing_ok=True)
    gai_path = tree / "etc/gai.conf"
    gai_text = gai_path.read_text() if gai_path.is_file() else ""
    if GAI_IPV4_CONF.strip() not in gai_text:
        gai_text = gai_text.rstrip("\n") + ("\n" if gai_text else "") + GAI_IPV4_CONF
    overlay_file(tree, "etc/gai.conf", gai_text)
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
    overlay_file(tree, "etc/systemd/system/raptor-minimal.target", RAPTOR_MINIMAL_TARGET)
    overlay_file(tree, "etc/systemd/system/raptor-console.service", RAPTOR_CONSOLE_SERVICE)
    overlay_file(tree, "etc/systemd/system/raptor-boot-env.service", RAPTOR_BOOT_ENV_SERVICE)
    overlay_link(tree, "etc/systemd/system/sysinit.target.wants/raptor-boot-env.service",
                 "/etc/systemd/system/raptor-boot-env.service")
    overlay_file(tree, "usr/local/sbin/raptor-boot-env", RAPTOR_BOOT_ENV_SH, 0o755)
    # Keep SSH handshakes fast on 50-100 MHz FPGA cores: avoid post-quantum KEX,
    # reverse DNS lookups, and GSSAPI while preserving PAM / Ubuntu MOTD.
    overlay_file(tree, "etc/ssh/sshd_config.d/01-raptor-timeout.conf", FAST_SSH_CONF)
    overlay_file(tree, "etc/systemd/system.conf.d/50-raptor.conf",
                 "[Manager]\nDefaultTimeoutStartSec=10min\nDefaultDeviceTimeoutSec=30min\n"
                 "DefaultEnvironment=SYSTEMD_BUS_TIMEOUT=600\n")
    # The user manager has independent defaults. Its D-Bus socket runs a
    # systemctl helper; the 90s default expired during a normal serial login.
    overlay_file(tree, "etc/systemd/user.conf.d/50-raptor.conf",
                 "[Manager]\nDefaultTimeoutStartSec=10min\n"
                 "DefaultEnvironment=SYSTEMD_BUS_TIMEOUT=600\n")
    environment = tree / "etc/environment"
    lines = environment.read_text().splitlines() if environment.is_file() else []
    values = [line for line in lines if not line.startswith("SYSTEMD_BUS_TIMEOUT=")]
    overlay_file(tree, "etc/environment", "\n".join(values + ["SYSTEMD_BUS_TIMEOUT=600"]) + "\n")
    # This profile uses OpenSSH directly and has no desktop or snap session.
    for unit in ("gpg-agent-ssh.socket", "snapd.session-agent.socket",
                 "launchpadlib-cache-clean.timer"):
        overlay_link(tree, "etc/systemd/user/" + unit, "/dev/null")
    # The distro prioritizes module/block coldplug before the console. This
    # fixed NFS board needs tty/net first; still trigger every other device.
    overlay_file(tree, "etc/systemd/system/systemd-udev-trigger.service.d/raptor.conf",
                 "[Service]\nExecStart=\nExecStart=-/usr/bin/udevadm trigger --type=all "
                 "--action=add --prioritized-subsystem=tty,net\n")
    # Concurrent coldplug helpers exceeded the default 180s event deadline on
    # the single 50 MHz core, including eth0's per-interface sysctl helper.
    overlay_file(tree, "etc/udev/udev.conf",
                 "# Raptor single-core serial/NFS profile.\nchildren_max=2\nevent_timeout=600\n")
    # These boot units set shorter limits instead of inheriting the default.
    for unit in ("systemd-sysctl", "systemd-sysusers", "systemd-journal-flush",
                 "systemd-journal-catalog-update", "systemd-hwdb-update",
                 "systemd-machine-id-commit", "systemd-binfmt", "systemd-udev-settle"):
        overlay_file(tree, "etc/systemd/system/" + unit + ".service.d/raptor.conf",
                     "[Service]\nTimeoutStartSec=10min\n")
    # The cloud tarball already contains a cache newer than /usr, but lacks
    # /etc/.updated. Avoid an unnecessary scan of every library over NFS on
    # first boot. A missing cache or newer /usr still runs the vendor command;
    # package-maintainer ldconfig invocations are unaffected.
    overlay_file(tree, "etc/systemd/system/ldconfig.service.d/raptor.conf",
                 "[Service]\nExecCondition=/bin/sh -c 'test ! -s /etc/ld.so.cache || "
                 "test /usr -nt /etc/ld.so.cache'\n")
    # All board drivers are built in. Avoid launching modprobe processes when
    # the kernel has no module support; this also works with a modular kernel.
    for unit in ("modprobe@.service", "systemd-modules-load.service"):
        overlay_file(tree, "etc/systemd/system/" + unit + ".d/raptor.conf",
                     "[Unit]\nConditionPathExists=/proc/modules\n")
    # No splash daemon is started by this serial-console boot. The vendor quit
    # command has a 20s deadline, shorter than a cold executable load here.
    for unit in ("plymouth-read-write", "plymouth-quit", "plymouth-quit-wait"):
        overlay_file(tree, "etc/systemd/system/" + unit + ".service.d/raptor.conf",
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
        # FPGA bitstreams are loaded through JTAG, not fwupd devices.
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
              "board": BOARD.name, "hostname": PROFILE["ubuntu"]["hostname"],
              "ssh_public_key_sha256": hashlib.sha256(key.encode()).hexdigest() if key else None,
              "overlay": digest([inspect.getsource(f) for f in
                                 (rootfs, overlay_file, overlay_link, board_services)])}
    marker = root / ".raptor-rootfs.json"
    legacy_marker = root / ".raptor-native-rootfs.json"
    if root.exists():
        active_marker = marker if marker.is_file() else legacy_marker
        require(active_marker.is_file() and json.loads(active_marker.read_text())["inputs"] == inputs,
                "existing rootfs has different inputs; select a new --rootfs directory")
        print("UBUNTU_ROOTFS=" + str(root), flush=True)
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
        expected = f'VERSION_ID="{SOURCES["ubuntu"]["release"]}"\n'
        require('ID=ubuntu\n' in release and expected in release,
                "unexpected Ubuntu root filesystem release")
        require((stage / "usr/lib/systemd/systemd").is_file(), "Ubuntu systemd is missing")
        overlay_file(stage, "etc/fstab", "# The kernel mounts the NFS root.\n"
                     "tmpfs /tmp tmpfs mode=1777,nosuid,nodev 0 0\n")
        overlay_file(stage, "etc/hostname", PROFILE["ubuntu"]["hostname"] + "\n")
        overlay_file(stage, "etc/hosts", "127.0.0.1 localhost\n127.0.1.1 "
                     + PROFILE["ubuntu"]["hostname"] + "\n::1 localhost\n")
        overlay_file(stage, "etc/resolv.conf", "nameserver " + args.server + "\n")
        overlay_file(stage, "etc/cloud/cloud-init.disabled", "NFS root provisioned by ubuntu.py\n")
        overlay_file(stage, "etc/machine-id", "")
        overlay_file(stage, "etc/systemd/network/10-raptor.network",
                     "[Match]\nName=eth0\n\n[Network]\nDHCP=ipv4\nKeepConfiguration=yes\n"
                     "LinkLocalAddressing=no\nIPv6AcceptRA=no\n\n[DHCPv4]\nUseMTU=no\n")
        overlay_link(stage, "etc/systemd/system/multi-user.target.wants/systemd-networkd.service",
                     "/usr/lib/systemd/system/systemd-networkd.service")
        overlay_link(stage, "etc/systemd/system/default.target",
                     "/usr/lib/systemd/system/multi-user.target")
        overlay_file(stage, "etc/systemd/system/serial-getty@ttyS0.service.d/raptor.conf",
                     "[Service]\nExecStart=\nExecStart=-/usr/sbin/agetty --autologin root "
                     "--noclear --keep-baud 115200,38400,9600 - $TERM\n")
        overlay_file(stage, "etc/systemd/journald.conf.d/raptor.conf",
                     "[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n")
        board_services(stage)
        # Generate this rootfs's unique host keys on the provisioning host;
        # RSA generation on the 50 MHz board otherwise dominates first boot.
        # -A preserves existing keys. The service also repairs missing keys.
        run(["ssh-keygen", "-q", "-A", "-f", stage])
        overlay_file(stage, "etc/systemd/system/ssh.service.d/raptor.conf",
                     "[Service]\nExecStartPre=\nExecStartPre=/usr/bin/ssh-keygen -A\n"
                     "ExecStartPre=/usr/sbin/sshd -t\n")
        if key:
            overlay_file(stage, "root/.ssh/authorized_keys", key + "\n", 0o600)
            (stage / "root/.ssh").chmod(0o700)
            overlay_file(stage, "etc/ssh/sshd_config.d/00-raptor.conf",
                         "PermitRootLogin prohibit-password\nPasswordAuthentication no\n")
        save(stage / marker.name, {"schema": "raptor-ubuntu-rootfs-v1", "inputs": inputs,
                                   "persistent": True, "serial_root_autologin": True})
        stage.chmod(0o755)
        stage.rename(root)
    except BaseException:
        # Keep the incomplete extraction for diagnosis; never delete a live NFS root.
        print("Incomplete rootfs retained at " + str(stage), file=sys.stderr)
        raise
    print("UBUNTU_ROOTFS=" + str(root), flush=True)
    return root


def serve(args, remove=False):
    root = args.rootfs.resolve()
    require(has_rootfs_marker(root), "prepare the Ubuntu rootfs first")
    bootargs(args)  # Also validates the export path.
    client = str(ipaddress.IPv4Network(args.client, strict=False))
    options = "rw,async,no_subtree_check,no_root_squash"
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
    allowed_board_compat = {PROFILE["compatible"], PROFILE["compatible"] + "-native"}
    require(get("/", "compatible") in allowed_board_compat, "bundle belongs to another board")
    board_cfg = record.get("board_configuration") or record.get("native_configuration", {})
    net = network_profile(board_cfg)
    require(record["network"] == net, "bundle Ethernet profile changed")
    if board_cfg.get("virtio_net") or board_cfg.get("qemu_bridge"):
        require(get("/soc/virtio_mmio@10002000", "compatible") == "virtio,mmio",
                "bundle lacks virtio-mmio NIC node")
    else:
        node = PROFILE["ubuntu"]["ethernet_node"]
        if net["driver"] in ("raptor_dma", "native_dma"):
            allowed_eth = {"raptor,ethernet-v2", "raptor,native-ethernet-v2"}
        elif net["driver"] == "liteeth":
            allowed_eth = {"litex,liteeth"}
        else:
            allowed_eth = {"raptor,ethernet-v1", "raptor,native-ethernet-v1"}
        require(get(node, "compatible") in allowed_eth, "bundle Ethernet driver mismatch")
        if net["driver"] in ("raptor", "native") or (
                net["driver"] in ("raptor_dma", "native_dma") and not net.get("fixed_link")):
            require(get(node, "phy-mode") == "rgmii-txid", "wrong PHY delay mode")
    require(get("/chosen", "bootargs") == record["bootargs"], "bundle bootargs mismatch")
    root_dev = getattr(args, "root_device", "nfs") or "nfs"
    require(root_dev in ("nfs", "ramroot", "squashfs") or board_cfg.get("qemu_bridge"),
            "block root devices are served through --qemu-bridge 1")
    if root_dev == "squashfs":
        require("rdinit=/init" in record["bootargs"],
                "squashfs bundle does not boot switch_root initramfs via rdinit=/init")
        require("initrd.img" in record["files"] and (directory / "initrd.img").is_file(),
                "squashfs bundle is missing initrd.img")
        phram_node = f"/phram@{INITRD_ADDRESS + PHRAM_OFFSET:x}"
        require(get(phram_node, "compatible") == "phram",
                "squashfs bundle DTB lacks phram rootfs node")
    elif root_dev == "ramroot":
        require("rdinit=/sbin/init" in record["bootargs"],
                "ramroot bundle does not boot Ubuntu systemd via rdinit=/sbin/init")
        require("initrd.img" in record["files"] and (directory / "initrd.img").is_file(),
                "ramroot bundle is missing initrd.img")
    else:
        expected_root = "root=/dev/nfs" if root_dev == "nfs" else f"root={root_dev}"
        require("init=/sbin/init" in record["bootargs"] and expected_root in record["bootargs"],
                "bundle does not boot Ubuntu systemd from " + expected_root)
    if root_dev == "nfs":
        require(has_rootfs_marker(args.rootfs), "rootfs is not prepared")
    print("PASS Ubuntu artifact checks (hardware boot is a separate acceptance step)")


def validate_http_url(url, label="URL"):
    require(bool(re.fullmatch(r"https?://[A-Za-z0-9._:/-]+", url)),
            f"invalid {label}: {url!r}")
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme in ("http", "https") and bool(parsed.hostname),
            f"invalid {label}: {url!r}")
    if parsed.port is not None:
        require(1 <= parsed.port <= 65535, f"invalid port in {label}: {url!r}")
    return url


class ProxyRelay:
    """Thread-backed TCP relay exposing a localhost HTTP proxy on the FPGA LAN."""

    def __init__(self, bind_host, bind_port, upstream_host, upstream_port):
        self.bind_host = bind_host
        self.bind_port = bind_port
        self.upstream_host = upstream_host
        self.upstream_port = upstream_port
        self.port = None
        self._loop = None
        self._thread = None

    def start(self):
        ready = threading.Event()
        errors = []

        async def pipe(reader, writer):
            try:
                while True:
                    chunk = await reader.read(65536)
                    if not chunk:
                        break
                    writer.write(chunk)
                    await writer.drain()
            except OSError:
                pass
            finally:
                with contextlib.suppress(OSError):
                    writer.close()

        async def handle_client(creader, cwriter):
            try:
                ureader, uwriter = await asyncio.open_connection(
                    self.upstream_host, self.upstream_port
                )
            except OSError:
                with contextlib.suppress(OSError):
                    cwriter.close()
                return
            await asyncio.gather(pipe(creader, uwriter), pipe(ureader, cwriter))

        def runner():
            loop = asyncio.new_event_loop()
            self._loop = loop
            asyncio.set_event_loop(loop)
            try:
                try:
                    srv = loop.run_until_complete(
                        asyncio.start_server(handle_client, self.bind_host, self.bind_port)
                    )
                except OSError:
                    if self.bind_port == 0:
                        raise
                    srv = loop.run_until_complete(
                        asyncio.start_server(handle_client, self.bind_host, 0)
                    )
                self.port = srv.sockets[0].getsockname()[1]
            except BaseException as exc:
                errors.append(exc)
                ready.set()
                return
            ready.set()
            loop.run_forever()
            srv.close()
            loop.run_until_complete(srv.wait_closed())
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            loop.close()

        self._thread = threading.Thread(target=runner, daemon=True)
        self._thread.start()
        ready.wait(timeout=5.0)
        if errors:
            raise errors[0]
        require(self.port is not None, "failed to start FPGA LAN proxy relay")
        return self

    def close(self):
        if self._loop is not None:
            self._loop.call_soon_threadsafe(self._loop.stop)
        if self._thread is not None:
            self._thread.join(timeout=2.0)


@contextlib.contextmanager
def board_proxy_context(proxy_url, server_ip):
    if not proxy_url:
        yield None
        return
    clean = validate_http_url(proxy_url, "HTTP proxy")
    parsed = urllib.parse.urlsplit(clean)
    if parsed.hostname in ("127.0.0.1", "localhost"):
        bind_ip = str(ipaddress.IPv4Address(server_ip))
        up_port = parsed.port or (443 if parsed.scheme == "https" else 80)
        relay = ProxyRelay(bind_ip, up_port, "127.0.0.1", up_port).start()
        try:
            guest_url = f"http://{bind_ip}:{relay.port}"
            print(f"PROXY_RELAY={guest_url} -> 127.0.0.1:{up_port}", flush=True)
            yield guest_url
        finally:
            relay.close()
    else:
        yield clean


def stamp_runtime_dtb(dtb, *, host_epoch=None, http_proxy=None, apt_mirror=None):
    subprocess.run(["fdtput", "-t", "bx", str(dtb), "/chosen", "rng-seed",
                    *[f"{b:02x}" for b in os.urandom(64)]], check=True)
    epoch = int(time.time()) if host_epoch is None else int(host_epoch)
    require(epoch >= 0, "invalid host epoch")
    subprocess.run(["fdtput", "-t", "x", str(dtb), "/chosen", "raptor,host-epoch",
                    f"{(epoch >> 32) & 0xffffffff:x}", f"{epoch & 0xffffffff:x}"], check=True)
    if http_proxy:
        clean_proxy = validate_http_url(http_proxy, "HTTP proxy")
        subprocess.run(["fdtput", "-t", "s", str(dtb), "/chosen", "raptor,http-proxy",
                        clean_proxy], check=True)
    if apt_mirror:
        clean_mirror = validate_http_url(apt_mirror, "APT mirror")
        if not clean_mirror.endswith("/"):
            clean_mirror += "/"
        subprocess.run(["fdtput", "-t", "s", str(dtb), "/chosen", "raptor,apt-mirror",
                        clean_mirror], check=True)


def proxy_command(args):
    proxy_url = getattr(args, "http_proxy", None) or os.environ.get("HTTP_PROXY")
    require(bool(proxy_url), "--http-proxy (or HTTP_PROXY) is required for proxy")
    with board_proxy_context(proxy_url, args.server) as guest_url:
        print(f"Configure on board: export http_proxy={guest_url} https_proxy={guest_url}",
              flush=True)
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass


def boot(args):
    require(args.port, "--port is required for boot")
    check(args)
    directory = args.output / "bundle"
    # Fresh trusted host entropy and UTC wall-clock for every physical boot; never
    # reuse an entropy seed from a saved firmware bundle or print it to a build log.
    with tempfile.TemporaryDirectory(prefix="boot-", dir=args.output) as temporary, \
         board_proxy_context(getattr(args, "http_proxy", None), args.server) as guest_proxy:
        dtb = Path(temporary) / "runtime.dtb"
        shutil.copyfile(directory / "ubuntu.dtb", dtb)
        stamp_runtime_dtb(dtb, http_proxy=guest_proxy,
                          apt_mirror=getattr(args, "apt_mirror", None))
        save(args.output / "last-boot.json", {"runtime_dtb_sha256": sha(dtb),
             "bundle_manifest_sha256": sha(directory / "manifest.json"), "port": args.port})
        initrd = (directory / "initrd.img") if "initrd.img" in verify(directory)["files"] else None
        record = verify(directory)
        board_cfg = record.get("board_configuration") or record["native_configuration"]
        if args.transport == "tftp":
            # The I/O SoC's stream bridge owns the MAC that the TFTP loader drives.
            require(not (board_cfg.get("virtio_net") or board_cfg.get("qemu_bridge")),
                    "the virtio-net/QEMU bridge SoC boots with --transport uart")
            import netboot
            netboot.upload(args.port, directory / "fw_payload.bin", dtb, Path(temporary),
                           args.server, args.boot_ip, args.tftp_port,
                           wait_ready=args.wait_ready, console=args.console,
                           network=network_profile(board_cfg), initrd=initrd)
            return
        if args.upload_baud != 115200:
            import fast_upload
            stage = fast_upload.build(args.output / "upload-stage",
                                      board_cfg["clock_mhz"] * 1_000_000,
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
    parser = argparse.ArgumentParser(description=__doc__, parents=[board_parser()])
    parser.add_argument("action",
                        choices=("kernel", "rootfs", "bundle", "check", "serve", "unserve",
                                 "proxy", "boot"))
    parser.add_argument("--output", type=Path, default=BOARD / "build/ubuntu")
    parser.add_argument("--rootfs", type=Path, help="persistent NFS tree (default OUTPUT/rootfs)")
    parser.add_argument("--kernel-cache", type=Path, default=REPO / "linux/build/netboot-kernels")
    parser.add_argument("--kernel-dir", type=Path, help="reuse a verified kernel artifact directory")
    parser.add_argument("--downloads", type=Path, default=REPO / "linux/build/distro-boot/downloads")
    parser.add_argument("--cross", default="riscv64-linux-gnu-")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--board-build", dest="board_build", type=Path,
                        help="board build containing its verified DTB and manifest")
    parser.add_argument("--native-build", dest="board_build", type=Path,
                        help=argparse.SUPPRESS)
    parser.add_argument("--board-build-root", dest="board_build_root", type=Path,
                        default=BOARD / "build")
    parser.add_argument("--native-build-root", dest="board_build_root", type=Path,
                        help=argparse.SUPPRESS)
    parser.add_argument("--preset", default="default")
    parser.add_argument("--clock-mhz", type=int, choices=(25, 50, 75, 100), default=50)
    parser.add_argument("--root-device", default="nfs",
                        choices=("nfs", "ramroot", "squashfs", *ALLOWED_BLOCK_ROOTS),
                        help="root filesystem source (nfs, DDR4 ramroot/squashfs, or block device)")
    parser.add_argument("--systemd-target", default="default", choices=("default", "minimal"),
                        help="systemd boot target (default multi-user or minimal fast-boot)")
    parser.add_argument("--initrd", type=Path,
                        help="optional prebuilt initrd.img or SquashFS image")
    parser.add_argument("--host-nfs", type=Path,
                        help="host NFS export mounted at /mnt/host in ramroot mode (default --rootfs)")
    parser.add_argument("--http-proxy",
                        help="optional HTTP/HTTPS proxy URL (localhost proxies bridge to --server)")
    parser.add_argument("--apt-mirror",
                        help="optional Ubuntu ports archive mirror URL injected at boot")
    parser.add_argument("--eth-dma", type=int, choices=(0, 1), default=0,
                        help="enable 64-bit AXI4-Master Ethernet Ring DMA (ABI v2)")
    parser.add_argument("--virtio-net", type=int, choices=(0, 1), default=0,
                        help="select standard OASIS VirtIO 1.2 virtio-mmio DMA NIC")
    parser.add_argument("--qemu-bridge", type=int, choices=(0, 1), default=0,
                        help="enable FPGA-to-QEMU RQIO direct MMIO + AXI4-DMA bridge")
    parser.add_argument("--server", default="192.168.50.1")
    parser.add_argument("--client", default="192.168.50.0/24", help="NFS client subnet or single IPv4/32")
    parser.add_argument("--ssh-key", type=Path, help="optional SSH public key for root (no password SSH)")
    parser.add_argument("--port", help="board UART; use /dev/serial/by-id for stable selection")
    parser.add_argument("--transport", choices=("tftp", "uart"), default=PROFILE["ubuntu"]["transport"])
    parser.add_argument("--boot-ip", default=PROFILE["ubuntu"]["boot_ip"],
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
    if args.board_build:
        args.board_build = args.board_build.resolve()
    if args.action == "kernel":
        print("UBUNTU_KERNEL=" + str(kernel(args)))
    elif args.action == "rootfs":
        rootfs(args)
    elif args.action == "bundle":
        bundle(args)
    elif args.action == "check":
        check(args)
    elif args.action in ("serve", "unserve"):
        serve(args, args.action == "unserve")
    elif args.action == "proxy":
        proxy_command(args)
    else:
        boot(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from exc
