#!/usr/bin/env python3
"""Opt-in CU08 RV64/Buildroot/CM005 profile; check is entirely read-only.

Image/build/load are explicit operations. RTL packs and BIOS sources are
private to the build root/configuration. Do not build the same configuration
concurrently or edit its inputs while implementation is running.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

LITEX = Path(__file__).resolve().parents[1]
REPO = LITEX.parents[1]
PACKAGE_NAME = "linux-riscv-rv64-qemu-rv64-fast-buildroot-v6.18.50"
DEFAULT_PACKAGE = REPO / "linux/build" / PACKAGE_NAME
ISA = "rv64imafdc_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs"
PAYLOAD_OFFSET = 0x100000
DTB_OFFSET = 0x4000000
DTB_ADDRESS = 0x83F00000


def cpio_files(archive):
    """Read newc without extracting files or following archive symlinks."""
    data = gzip.decompress(archive.read_bytes())
    offset, files = 0, {}
    while offset + 110 <= len(data):
        header = data[offset:offset + 110]
        if header[:6] not in (b"070701", b"070702"):
            raise ValueError("initramfs is not a newc archive")
        size = int(header[54:62], 16)
        namesize = int(header[94:102], 16)
        start = offset + 110
        if not namesize or start + namesize > len(data):
            raise ValueError("truncated cpio filename")
        name = data[start:start + namesize - 1].decode()
        start = (start + namesize + 3) & ~3
        if start + size > len(data):
            raise ValueError("truncated cpio contents")
        if name == "TRAILER!!!":
            return files
        files[name.removeprefix("./")] = data[start:start + size]
        offset = (start + size + 3) & ~3
    raise ValueError("missing cpio trailer")


def check_package(package, *, bits=64):
    if bits not in (32, 64):
        raise ValueError("network profile requires RV32 or RV64")
    abi = "ilp32d" if bits == 32 else "lp64d"
    manifest = json.loads((package / "manifest.json").read_text())
    if (manifest.get("bits"), manifest.get("abi"), manifest.get("variant")) != (bits, abi, "buildroot"):
        raise ValueError(f"expected RV{bits} {abi.upper()} Buildroot, not a different XLEN or tiny-shell payload")
    for name in ("fw_payload.bin", "kernel.config", "initramfs.cpio.gz"):
        digest = hashlib.sha256((package / name).read_bytes()).hexdigest()
        if manifest["files"].get(name) != digest:
            raise ValueError(f"manifest SHA256 mismatch: {name}")
    config = (package / "kernel.config").read_text()
    for option in ("CONFIG_LITEX_LITEETH", "CONFIG_INET", "CONFIG_FPU", "CONFIG_DEVTMPFS"):
        if f"{option}=y" not in config.splitlines():
            raise ValueError(f"kernel must contain {option}=y")
    if int(manifest["fdt_address"], 0) != DTB_ADDRESS:
        raise ValueError("payload FDT relocation differs from the profile")
    if int(manifest["kernel_memory_end"], 0) >= DTB_ADDRESS:
        raise ValueError("kernel memory overlaps the runtime FDT")
    if PAYLOAD_OFFSET + (package / "fw_payload.bin").stat().st_size > DTB_OFFSET:
        raise ValueError("payload overlaps the uploaded DTB slot")
    # Verify the exact OpenSBI sequence required by the production BIOS hook.
    from patch_litex_sdcard_linux_override import find_opensbi_fdt_lui
    find_opensbi_fdt_lui((package / "fw_payload.bin").read_bytes())
    files = cpio_files(package / "initramfs.cpio.gz")
    for name in ("init", "bin/busybox", "sbin/udhcpc", "etc/init.d/rcS"):
        if name not in files:
            raise ValueError(f"missing rootfs entry: {name}")
    interfaces = files.get("etc/network/interfaces", b"").decode()
    if not re.search(r"(?m)^auto\s+eth0\s*$", interfaces) or not re.search(
            r"(?m)^iface\s+eth0\s+inet\s+dhcp\s*$", interfaces):
        raise ValueError("rootfs must automatically configure eth0 using DHCP")
    if b"/sbin/ifup -a" not in files.get("etc/init.d/S40network", b""):
        raise ValueError("missing automatic network startup")
    dhcp = files.get("usr/share/udhcpc/default.script", b"")
    if b"route add default" not in dhcp or b"nameserver" not in dhcp:
        raise ValueError("DHCP hook must install gateway and DNS")
    return manifest


def make_command(action, package, *, bits=64):
    if bits not in (32, 64):
        raise ValueError("network profile requires RV32 or RV64")
    target = {"image": f"fpga-img-rv{bits}", "build": "fpga-build", "load": "fpga-load"}[action]
    payload = package.resolve() / "fw_payload.bin"
    return ["make", "-C", str(LITEX), target,
            f"VARIANT=linux{bits}", "FPGA_BOARD=mlk_cu08_ku15p", "FPGA_AUTO_DETECT=0",
            "RAPT_CONFIG=default", "SYS_CLK=50000000", "WITH_MIG=1",
            "CROSS=riscv64-linux-gnu-",
            "WITH_LITEDRAM=0", "WITH_SDCARD=1", "WITH_ETHERNET=1",
            "ETH_SPEED=1000", "FMC_SLOT=c", "ETH_PORT=a", "BOOT_MODE=bios",
            "EXTRA_FLAGS=--sdcard-autoboot", "LINUX_FPGA_INIT=full",
            # Command-line overrides keep BIOS DTB and image recipes consistent
            # without changing normal simulation/default payloads.
            f"LINUX_ISA={ISA.replace('rv64', f'rv{bits}', 1)}", f"LINUX_IMG={payload}", f"LINUX_FPGA_PAYLOAD={payload}",
            f"LINUX_FPGA_DTB_OFFSET={DTB_OFFSET:#x}", f"LINUX_FPGA_DTB_ADDR={DTB_ADDRESS:#x}",
            f"BUILD_DIR={LITEX / f'build/rv{bits}-network'}", "FPGA_FLAVOR_SUFFIX=autoboot",
            "VIVADO_JOBS=8"]


def main(*, bits=64, default_package=DEFAULT_PACKAGE):
    parser = argparse.ArgumentParser(description=f"Opt-in CU08 RV{bits}/Buildroot/CM005 profile; check is read-only.")
    parser.add_argument("action", choices=("check", "image", "build", "load"))
    parser.add_argument("--package", type=Path, default=default_package,
                        help=f"unmodified RV{bits} Buildroot release directory with manifest")
    parser.add_argument("--print-command", action="store_true",
                        help="print, but do not execute, the selected Make command")
    args = parser.parse_args()
    try:
        manifest = check_package(args.package, bits=bits)
        for tool in ("make", "dtc", "verilator", "riscv64-linux-gnu-gcc", "riscv64-linux-gnu-objcopy"):
            if not shutil.which(tool):
                raise ValueError(f"missing host tool: {tool}")
        if not (LITEX / ".venv/bin/python3").exists():
            raise ValueError("LiteX venv missing; install separately with make setup")
        print(f"PASS: RV{bits} Buildroot payload {manifest['files']['fw_payload.bin']}")
        print("PASS: LiteEth/FPU, eth0 DHCP, gateway/DNS, image layout and BIOS hook")
        print(f"Profile: CU08 FMC_C/ETHA (oversampling RX), RV{bits} default, 50 MHz, 1000 Mb/s, SD autoboot")
        print("Not validated: routed timing, SD contents, PHY link or board Linux networking.")
        if args.action == "check":
            return 0
        command = make_command(args.action, args.package, bits=bits)
        print(shlex.join(command), flush=True)
        if args.print_command:
            return 0
        if args.action in ("image", "build"):
            print("Using isolated RTL packs and private BIOS sources. "
                  "Keep this configuration's inputs stable during implementation.", flush=True)
        # Do not inherit another make's jobserver, preset, VFLAGS or shell
        # bootargs; this named profile owns those settings explicitly.
        environment = {k: v for k, v in os.environ.items() if not (
            k.startswith(("MAKE", "MFLAGS", "RAPT_", "LINUX_", "FW_")) or k == "BUILD_PROFILE")}
        return subprocess.run(command, env=environment, check=False).returncode
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
