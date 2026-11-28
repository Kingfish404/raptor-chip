#!/usr/bin/env python3
"""Boot and provision unmodified mainline BSD/Linux disk images on Raptor FPGA & QEMU.

Supports:
  1. Building OpenSBI + U-Boot UEFI (or direct kernel) `fw_payload.bin` /
     `fw_dynamic.bin` with user-mode `rdcycle`/`rdtime`/`rdinstret` enabled
     (`CSR_SCOUNTEREN |= 0x07`) so microarchitectural benchmarks run unmodified.
  2. Cloning and provisioning official NetBSD 11 (`riscv64.img`) and
     FreeBSD 15.0-RELEASE (`FreeBSD-15.0-RELEASE-riscv-riscv64-ufs.raw`) images
     via QEMU with SSH public keys, fast `sshd_config`, trimmed boot daemons,
     and natively compiled Raptor `app/` microbenchmarks — while keeping the
     downloaded upstream `.img`/`.raw` files 100% unmodified.
  3. Booting any `.img`/`.raw` directly on KU15P / KU5P FPGA via Gigabit
     VirtIO-Net TFTP + unprivileged UDP RQIO (`raptor_qemu_bridge.py`).
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
BRIDGE_SCRIPT = Path(__file__).resolve().parent / "raptor_qemu_bridge.py"
sys.path.insert(0, str(REPO / "fpga/common/scripts"))
import netboot  # noqa: E402


QEMU_CPU_FLAGS = (
    "rv64,zba=true,zbb=true,zbc=true,zbs=true,"
    "zicbom=true,zicboz=true,svpbmt=true,sstc=false,v=true"
)


def run_cmd(cmd: list[str], *, cwd: Path | None = None) -> None:
    print("+", " ".join(str(x) for x in cmd), flush=True)
    subprocess.run([str(x) for x in cmd], cwd=cwd, check=True)


def ensure_uboot_bin(work_dir: Path) -> Path:
    """Locate or extract Ubuntu's qemu-riscv64_smode u-boot.bin without root."""
    sys_uboot = Path("/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin")
    if sys_uboot.is_file():
        return sys_uboot
    cached = work_dir / "uboot/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin"
    if cached.is_file():
        return cached
    dl_dir = work_dir / "uboot"
    dl_dir.mkdir(parents=True, exist_ok=True)
    run_cmd(["apt-get", "download", "u-boot-qemu"], cwd=dl_dir)
    debs = sorted(dl_dir.glob("u-boot-qemu_*.deb"))
    if not debs:
        raise RuntimeError("apt-get download u-boot-qemu produced no .deb")
    run_cmd(["dpkg-deb", "-x", str(debs[-1]), str(dl_dir)])
    if not cached.is_file():
        raise RuntimeError(f"missing extracted U-Boot binary at {cached}")
    return cached


def stage_opensbi_scounteren(src_dir: Path, dst_dir: Path) -> Path:
    """Stage OpenSBI source with U-mode CY/TM/IR counters (CSR_SCOUNTEREN |= 0x07)."""
    stamp = dst_dir / ".raptor_scounteren_v1"
    if stamp.is_file():
        return dst_dir
    if dst_dir.exists():
        shutil.rmtree(dst_dir)
    shutil.copytree(src_dir, dst_dir)

    hart_c = dst_dir / "lib/sbi/sbi_hart.c"
    txt = hart_c.read_text()
    old = "csr_write(CSR_SCOUNTEREN, 0x02);"
    if old not in txt:
        raise RuntimeError(f"expected '{old}' in {hart_c}")
    hart_c.write_text(txt.replace(old, "csr_write(CSR_SCOUNTEREN, 0x07);", 1))

    timer_c = dst_dir / "lib/sbi/sbi_timer.c"
    ttxt = timer_c.read_text()
    t_old = "void sbi_timer_process(void)\n{\n"
    t_new = (
        "void sbi_timer_process(void)\n{\n"
        "\tif (misa_extension('S'))\n"
        "\t\tcsr_set(CSR_SCOUNTEREN, 0x07);\n"
    )
    if t_old not in ttxt:
        raise RuntimeError(f"expected sbi_timer_process in {timer_c}")
    timer_c.write_text(ttxt.replace(t_old, t_new, 1))

    ecall_c = dst_dir / "lib/sbi/sbi_ecall.c"
    etxt = ecall_c.read_text()
    e_old = "\text = sbi_ecall_find_extension(extension_id);\n"
    e_new = (
        "\tif (misa_extension('S'))\n"
        "\t\tcsr_set(CSR_SCOUNTEREN, 0x07);\n"
        + e_old
    )
    if e_old not in etxt:
        raise RuntimeError(f"expected sbi_ecall_find_extension in {ecall_c}")
    ecall_c.write_text(etxt.replace(e_old, e_new, 1))

    stamp.write_text("ok\n")
    return dst_dir


def build_firmware(out_dir: Path, payload_bin: Path | None = None,
                   jobs: int = 8) -> tuple[Path, Path]:
    """Build OpenSBI fw_dynamic.bin and fw_payload.bin (default payload: U-Boot)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    opensbi_orig = REPO / "third_party/riscv-software-src/opensbi"
    opensbi_src = stage_opensbi_scounteren(opensbi_orig, out_dir / "opensbi-src")
    if payload_bin is None:
        payload_bin = ensure_uboot_bin(out_dir)

    build_dir = out_dir / ("opensbi-" + payload_bin.stem)
    fw_dyn = build_dir / "platform/generic/firmware/fw_dynamic.bin"
    fw_pay = build_dir / "platform/generic/firmware/fw_payload.bin"
    if fw_dyn.is_file() and fw_pay.is_file():
        if fw_pay.stat().st_mtime >= payload_bin.stat().st_mtime:
            return fw_dyn, fw_pay

    build_dir.mkdir(parents=True, exist_ok=True)
    (build_dir / "platform/generic/firmware/fw_payload.o").unlink(missing_ok=True)
    cmd = [
        "make", "-C", str(opensbi_src),
        "CROSS_COMPILE=riscv64-linux-gnu-",
        "PLATFORM=generic",
        "PLATFORM_RISCV_XLEN=64",
        "PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei",
        "FW_PAYLOAD=y",
        f"FW_PAYLOAD_PATH={payload_bin.resolve()}",
        "FW_PAYLOAD_OFFSET=0x200000",
        f"O={build_dir.resolve()}",
        f"-j{jobs}",
    ]
    run_cmd(cmd)
    if not (fw_dyn.is_file() and fw_pay.is_file()):
        raise RuntimeError("OpenSBI build did not produce fw_dynamic.bin / fw_payload.bin")
    return fw_dyn, fw_pay


def collect_host_authorized_keys() -> str:
    ssh_dir = Path.home() / ".ssh"
    keys: list[str] = []
    if ssh_dir.is_dir():
        for pub in sorted(ssh_dir.glob("*.pub")):
            line = pub.read_text().strip()
            if line and line not in keys:
                keys.append(line)
    if not keys:
        raise RuntimeError(f"no SSH public keys found in {ssh_dir}/*.pub")
    return "\n".join(keys) + "\n"


BSD_PROFILE_C = r"""#include "profile.h"
#include <stdio.h>
#include <time.h>

static const char *g_name;
static struct timespec g_t0, g_t1;
static uint64_t g_c0, g_c1, g_i0, g_i1;

static inline uint64_t rdcycle64(void) {
    uint64_t v;
    __asm__ volatile("rdcycle %0" : "=r"(v) :: "memory");
    return v;
}
static inline uint64_t rdinstret64(void) {
    uint64_t v;
    __asm__ volatile("rdinstret %0" : "=r"(v) :: "memory");
    return v;
}
void profile_init(const char *name) { g_name = name; }
void profile_begin(void) {
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    g_i0 = rdinstret64();
    g_c0 = rdcycle64();
}
void profile_end(void) {
    g_c1 = rdcycle64();
    g_i1 = rdinstret64();
    clock_gettime(CLOCK_MONOTONIC, &g_t1);
}
uint64_t profile_elapsed_ns(void) {
    int64_t s = (int64_t)g_t1.tv_sec - (int64_t)g_t0.tv_sec;
    int64_t ns = (int64_t)g_t1.tv_nsec - (int64_t)g_t0.tv_nsec;
    return (uint64_t)(s * 1000000000LL + ns);
}
void profile_report(void) {
    uint64_t w = profile_elapsed_ns();
    uint64_t c = g_c1 - g_c0;
    uint64_t ir = g_i1 - g_i0;
    double ipc = c ? ((double)ir / (double)c) : 0.0;
    printf("PROFILE_JSON {\"name\":\"%s\",\"wall_ns\":%llu,\"cycles\":%llu,"
           "\"instret\":%llu,\"ipc\":%.4f}\n",
           g_name ? g_name : "bench",
           (unsigned long long)w, (unsigned long long)c,
           (unsigned long long)ir, ipc);
}
"""

GUEST_BUILD_SH = r"""#!/bin/sh
set -eu
SRC=/tmp/raptor-payload
OUT=/opt/raptor/bin
mkdir -p "$OUT" /usr/local/bin

OS_NAME="$(uname -s)"
echo "[raptor-build] building microbenchmarks on $OS_NAME ($(cc --version | head -n 1))"

# 1. CoreMark (FPGA 1 MHz mtime & QEMU 10 MHz mtime binaries)
CM_SRCS="
  $SRC/coremark/upstream/core_list_join.c
  $SRC/coremark/upstream/core_main.c
  $SRC/coremark/upstream/core_matrix.c
  $SRC/coremark/upstream/core_state.c
  $SRC/coremark/upstream/core_util.c
  $SRC/coremark/portme/core_portme.c
"
CM_INC="-I$SRC/coremark/upstream -I$SRC/coremark/portme"
cc -O3 -DPERFORMANCE_RUN=1 -DITERATIONS=2000 -DCOREMARK_TIMEBASE_HZ=1000000ULL \
  $CM_INC $CM_SRCS -o "$OUT/coremark.elf"
cc -O3 -DPERFORMANCE_RUN=1 -DITERATIONS=400 -DCOREMARK_TIMEBASE_HZ=1000000ULL \
  $CM_INC $CM_SRCS -o "$OUT/coremark-quick.elf"
cc -O3 -DPERFORMANCE_RUN=1 -DITERATIONS=400 -DCOREMARK_TIMEBASE_HZ=10000000ULL \
  $CM_INC $CM_SRCS -o "$OUT/coremark-qemu.elf"

# 2. Hello, sysinfo, portable memprobe (pointer-chase + streaming bandwidth)
cc -O3 "$SRC/hello/hello.c" -o "$OUT/hello.elf"
for d in "$SRC/demos"/*.c; do
  [ -f "$d" ] || continue
  base="$(basename "$d" .c)"
  cc -O3 "$d" -lm -o "$OUT/$base.elf" 2>/dev/null || true
done
cc -O3 -I"$SRC/memprobe_portable" \
  "$SRC/memprobe_portable/memory_probe.c" \
  "$SRC/memprobe_portable/bsd_profile.c" \
  -o "$OUT/memprobe.elf"

# 3. ISA, memory, algo suites (with RVA23 extension flags where supported)
for dir in isa memory algo; do
  for f in "$SRC/$dir"/*.c; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .c)"
    case "$base" in
      rv_bitmanip)
        cc -O3 -march=rv64gc_zba_zbb_zbc_zbs "$f" -lm -o "$OUT/$base.elf" 2>/dev/null || true ;;
      rv_zcb)
        cc -O3 -march=rv64gc_zcb "$f" -lm -o "$OUT/$base.elf" 2>/dev/null || true ;;
      rv_zicond)
        cc -O3 -march=rv64gc_zicond "$f" -lm -o "$OUT/$base.elf" 2>/dev/null || true ;;
      *)
        cc -O3 "$f" -lm -o "$OUT/$base.elf" 2>/dev/null || true ;;
    esac
  done
done

# 4. Microarchitectural cache/branch/fence timing suite
for f in "$SRC/uarch"/*.c; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .c)"
  cc -O3 -I"$SRC/uarch" "$f" -lm -o "$OUT/$base.elf" 2>/dev/null || true
  if [ "$OS_NAME" = "NetBSD" ] && command -v paxctl >/dev/null 2>&1 && [ -f "$OUT/$base.elf" ]; then
    paxctl +m "$OUT/$base.elf" || true
  fi
done

for bin in "$OUT"/*.elf; do
  [ -f "$bin" ] || continue
  stem="$(basename "$bin" .elf)"
  ln -sf "$bin" "/usr/local/bin/$stem.elf"
  ln -sf "$bin" "/usr/local/bin/$stem"
done

echo "[raptor-build] installed $(ls -1 "$OUT"/*.elf | wc -l) binaries into $OUT"
"$OUT/hello.elf"
"$OUT/rv_zicsr.elf"
"$OUT/coremark-qemu.elf" | grep -E "CoreMark|Total ticks|Cycles|IPC" || true
if [ -x "$OUT/cache-timing.elf" ]; then
  "$OUT/cache-timing.elf" | head -n 10 || true
fi
"""


def build_payload_tar(tar_path: Path, os_kind: str) -> None:
    """Bundle SSH authorized_keys, setup.sh, and portable app/ C sources into a USTAR tar."""
    auth_keys = collect_host_authorized_keys()
    setup_body = NETBSD_SETUP_SCRIPT if os_kind == "netbsd" else FREEBSD_SETUP_SCRIPT
    with tempfile.TemporaryDirectory() as td:
        stage = Path(td) / "raptor-payload"
        stage.mkdir(parents=True)
        (stage / "authorized_keys").write_text(auth_keys)
        (stage / "build_bsd_apps.sh").write_text(GUEST_BUILD_SH)
        (stage / "build_bsd_apps.sh").chmod(0o755)
        (stage / "setup.sh").write_text(setup_body)
        (stage / "setup.sh").chmod(0o755)

        shutil.copytree(REPO / "app/benchmarks/coremark", stage / "coremark")
        cm_upstream = REPO / "abstract-machine/app/am-kernels/benchmarks/coremark_eembc/src"
        shutil.copytree(cm_upstream, stage / "coremark/upstream")
        mp_dir = stage / "memprobe_portable"
        mp_dir.mkdir(parents=True)
        shutil.copy2(REPO / "fpga/common/tests/ubuntu_bench/memory_probe.c", mp_dir / "memory_probe.c")
        shutil.copy2(REPO / "fpga/common/tests/ubuntu_bench/profile.h", mp_dir / "profile.h")
        (mp_dir / "bsd_profile.c").write_text(BSD_PROFILE_C)
        shutil.copytree(REPO / "app/tests/hello", stage / "hello")
        shutil.copytree(REPO / "app/tests/isa", stage / "isa")
        shutil.copytree(REPO / "app/tests/memory", stage / "memory")
        shutil.copytree(REPO / "app/tests/algo", stage / "algo")
        if (REPO / "app/demos").is_dir():
            shutil.copytree(REPO / "app/demos", stage / "demos")
        if (REPO / "app/security").is_dir():
            shutil.copytree(REPO / "app/security", stage / "uarch")

        with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tf:
            tf.add(stage, arcname="raptor-payload")
    raw = tar_path.read_bytes()
    rem = len(raw) % 65536
    if rem:
        with tar_path.open("ab") as fh:
            fh.write(b"\x00" * (65536 - rem))


NETBSD_SETUP_SCRIPT = r"""#!/bin/sh
set -eu
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /tmp/raptor-payload/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat >> /etc/ssh/sshd_config <<'EOF'

# Raptor 50 MHz FPGA fast SSH tuning
PermitRootLogin prohibit-password
PubkeyAuthentication yes
UseDNS no
LoginGraceTime 600
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes128-ctr
EOF
ssh-keygen -A

# Trim unnecessary background services for fast FPGA boot & clean microbenchmarks
printf '127.0.0.1\traptor-netbsd\n::1\traptor-netbsd\n' >> /etc/hosts
cat >> /etc/rc.conf <<'EOF'
hostname="raptor-netbsd"
sshd=YES
dhcpcd=YES
dhcpcd_flags="-q -b"
ntpd=NO
postfix=NO
mdnsd=NO
makemandb=NO
savecore=NO
virecover=NO
inetd=NO
sysdb=NO
cron=NO
EOF

sh /tmp/raptor-payload/build_bsd_apps.sh
rm -rf /tmp/raptor-payload
sync
printf "RAPTOR_PROV_%s\n" "DONE"
"""


FREEBSD_SETUP_SCRIPT = r"""#!/bin/sh
set -eu
service growfs onestart || true
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /tmp/raptor-payload/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat >> /etc/ssh/sshd_config <<'EOF'

# Raptor 50 MHz FPGA fast SSH tuning
PermitRootLogin prohibit-password
PubkeyAuthentication yes
UseDNS no
GSSAPIAuthentication no
LoginGraceTime 600
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes128-gcm@openssh.com,aes128-ctr
EOF
cat > /boot/loader.conf <<'EOF'
autoboot_delay="0"
beastie_disable="YES"
EOF

printf '127.0.0.1\traptor-freebsd\n::1\traptor-freebsd\n' >> /etc/hosts
sysrc hostname="raptor-freebsd"
sysrc ifconfig_vtnet0="DHCP"
sysrc background_dhclient="YES"
sysrc sshd_enable="YES"
sysrc sendmail_enable="NONE"
sysrc cron_enable="NO"
sysrc growfs_enable="NO"
sysrc syslogd_flags="-ss"
service sshd onekeygen

sh /tmp/raptor-payload/build_bsd_apps.sh
rm -rf /tmp/raptor-payload
sync
printf "RAPTOR_PROV_%s\n" "DONE"
"""


def _send_paced(stdin_fd: int, text: str, delay_s: float = 0.008) -> None:
    for ch in text.encode("ascii"):
        os.write(stdin_fd, bytes([ch]))
        time.sleep(delay_s)


def provision_image(os_kind: str, src_img: Path, dst_img: Path, work_dir: Path,
                    kernel_path: Path | None = None, timeout_s: int = 420) -> None:
    """Clone src_img -> dst_img and provision SSH + Raptor microbenchmarks in QEMU."""
    if not src_img.is_file():
        raise FileNotFoundError(f"missing source image: {src_img}")
    dst_img.parent.mkdir(parents=True, exist_ok=True)
    fw_dyn, _ = build_firmware(work_dir)
    uboot_bin = ensure_uboot_bin(work_dir)

    tmp_img = dst_img.with_suffix(dst_img.suffix + ".provisioning")
    tmp_img.unlink(missing_ok=True)
    run_cmd(["cp", "--sparse=always", "--reflink=auto", str(src_img), str(tmp_img)])

    tar_path = work_dir / f"payload-{os_kind}.tar"
    build_payload_tar(tar_path, os_kind)

    qemu_cmd = [
        "qemu-system-riscv64",
        "-M", "virt",
        "-cpu", QEMU_CPU_FLAGS,
        "-smp", "4",
        "-m", "4G",
        "-display", "none",
        "-serial", "stdio",
        "-monitor", "none",
        "-global", "virtio-mmio.force-legacy=false",
        "-bios", str(fw_dyn),
    ]
    if os_kind == "netbsd" and kernel_path and kernel_path.is_file():
        qemu_cmd += ["-kernel", str(kernel_path), "-append", "root=dk1"]
    else:
        qemu_cmd += ["-kernel", str(uboot_bin)]

    qemu_cmd += [
        "-drive", f"file={tmp_img},format=raw,if=none,id=hd0",
        "-device", "virtio-blk-device,drive=hd0",
        "-drive", f"file={tar_path},format=raw,readonly=on,if=none,id=hd1",
        "-device", "virtio-blk-device,drive=hd1",
        "-device", "virtio-rng-device",
        "-netdev", "user,id=n0",
        "-device", "virtio-net-device,netdev=n0,mac=02:52:41:50:15:01",
    ]

    print("+", " ".join(qemu_cmd), flush=True)
    proc = subprocess.Popen(
        qemu_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    assert proc.stdin is not None and proc.stdout is not None
    in_fd = proc.stdin.fileno()
    out_fd = proc.stdout.fileno()

    buf = b""
    logged_in = False
    sent_setup = False
    provision_ok = False
    sent_poweroff = False
    uboot_nudged = False
    fbsd_loader_nudged = False
    deadline = time.monotonic() + timeout_s

    if os_kind == "netbsd":
        boot_cmd = (
            "for d in /dev/rld5c /dev/rld1c /dev/rld5d /dev/rld1d; do "
            "[ -e $d ] && tar -tf $d >/dev/null 2>&1 && tar -xf $d -C /tmp && break; "
            "done && sh /tmp/raptor-payload/setup.sh\n"
        )
    else:
        boot_cmd = (
            "service growfs onestart || true; "
            "for d in /dev/vtbd1 /dev/vtbd0; do "
            "[ -e $d ] && tar -tf $d >/dev/null 2>&1 && tar -xf $d -C /tmp && break; "
            "done && sh /tmp/raptor-payload/setup.sh\n"
        )

    try:
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            rlist, _, _ = select.select([out_fd], [], [], 0.25)
            if not rlist:
                continue
            chunk = os.read(out_fd, 4096)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            buf = (buf + chunk)[-8192:]

            if (os_kind == "freebsd" and not fbsd_loader_nudged
                    and b"Autoboot in " in buf):
                os.write(in_fd, b"\r")
                fbsd_loader_nudged = True

            if not logged_in and re.search(rb"login:\s*$", buf):
                _send_paced(in_fd, "root\n")
                logged_in = True
                buf = b""
            elif logged_in and not sent_setup and re.search(rb"[#?]\s*$", buf):
                if b"Terminal type?" in buf:
                    _send_paced(in_fd, "\n")
                    buf = b""
                    continue
                time.sleep(0.2)
                _send_paced(in_fd, boot_cmd, delay_s=0.01)
                sent_setup = True
                buf = b""
            elif sent_setup and not sent_poweroff and b"RAPTOR_PROV_DONE" in buf:
                provision_ok = True
                _send_paced(in_fd, "poweroff\n", delay_s=0.01)
                sent_poweroff = True
                buf = b""
    finally:
        if proc.poll() is None:
            try:
                proc.wait(timeout=25)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

    if not provision_ok:
        raise RuntimeError(f"{os_kind} QEMU provisioning did not reach RAPTOR_PROVISION_OK")

    tmp_img.replace(dst_img)
    print(f"[provision] READY: {dst_img} ({dst_img.stat().st_size} bytes)", flush=True)


def prepare_runtime_dtb(base_dtb: Path, out_dtb: Path, bootargs: str = "",
                        strip_unused_buses: bool = True,
                        ram_mb: int = 1024) -> Path:
    """Create runtime DTB with fresh rng-seed and without unused PCIe/SDHCI scans."""
    out_dtb.parent.mkdir(parents=True, exist_ok=True)
    dts_tmp = out_dtb.with_suffix(".dts")
    subprocess.run(
        ["dtc", "-I", "dtb", "-O", "dts", "-o", str(dts_tmp), str(base_dtb)],
        check=True, stderr=subprocess.DEVNULL,
    )
    dts = dts_tmp.read_text()
    dts = re.sub(r"\n\s*rtc@101000\s*\{.*?\n\s*\};", "", dts, flags=re.S)
    dts = re.sub(r"\n\s*syscon@102000\s*\{.*?\n\s*\};", "", dts, flags=re.S)
    if "rtc@10004000" not in dts and "rtc@10009000" not in dts:
        m_ip = re.search(r"virtio_mmio@10003000\s*\{[^}]*?(interrupt-parent\s*=\s*<[^>]+>;)", dts)
        ip_line = f"\t\t\t{m_ip.group(1)}\n" if m_ip else ""
        rtc_node = (
            "\n\t\trtc@10004000 {\n"
            '\t\t\tcompatible = "google,goldfish-rtc";\n'
            "\t\t\treg = <0x00 0x10004000 0x00 0x1000>;\n"
            + ip_line
            + "\t\t\tinterrupts = <0x06>;\n"
            "\t\t};\n"
        )
        dts = re.sub(
            r"(\n\s*virtio_mmio@10003000\s*\{.*?\n\s*\};)",
            r"\1" + rtc_node,
            dts,
            count=1,
            flags=re.S,
        )
    if strip_unused_buses:
        dts = re.sub(r"\n\s*sdhci@42000000\s*\{.*?\n\s*\};", "", dts, flags=re.S)
        dts = re.sub(r"\n\s*pci@41000000\s*\{.*?\n\s*\};", "", dts, flags=re.S)
    dts_tmp.write_text(dts)
    subprocess.run(
        ["dtc", "-I", "dts", "-O", "dtb", "-o", str(out_dtb), str(dts_tmp)],
        check=True, stderr=subprocess.DEVNULL,
    )
    if ram_mb > 0:
        ram_bytes = ram_mb * 1024 * 1024
        subprocess.run(
            [
                "fdtput", "-t", "x", str(out_dtb), "/memory@80000000", "reg",
                "0", "0x80000000",
                f"0x{(ram_bytes >> 32) & 0xFFFFFFFF:x}",
                f"0x{ram_bytes & 0xFFFFFFFF:x}",
            ],
            check=True,
        )
    seed_hex = [f"0x{b:02x}" for b in os.urandom(64)]
    subprocess.run(
        ["fdtput", "-t", "bx", str(out_dtb), "/chosen", "rng-seed", *seed_hex],
        check=True,
    )
    if bootargs:
        subprocess.run(
            ["fdtput", "-t", "s", str(out_dtb), "/chosen", "bootargs", bootargs],
            check=True,
        )
    else:
        subprocess.run(
            ["fdtput", "-d", str(out_dtb), "/chosen", "bootargs"],
            check=False, stderr=subprocess.DEVNULL,
        )
    return out_dtb


def discover_guest_ip(mac: str, server_ip: str) -> str | None:
    mac_l = mac.lower()
    lease_dirs = [
        Path("/var/lib/NetworkManager"),
        Path("/var/lib/misc"),
    ]
    best_ts = -1
    best_ip = None
    for d in lease_dirs:
        try:
            if not d.is_dir():
                continue
            lease_files = list(d.glob("*leases*"))
        except OSError:
            continue
        for lf in lease_files:
            try:
                for line in lf.read_text().splitlines():
                    parts = line.split()
                    if len(parts) >= 3 and parts[1].lower() == mac_l:
                        ts = int(parts[0]) if parts[0].isdigit() else 0
                        if ts >= best_ts:
                            best_ts = ts
                            best_ip = parts[2]
            except OSError:
                continue
    if best_ip:
        return best_ip
    # Fallback: inspect kernel neighbor / ARP cache (`ip neigh`)
    try:
        out = subprocess.check_output(["ip", "neigh"], text=True)
        prefix = ".".join(server_ip.split(".")[:3]) + "."
        fallback_ip = None
        for line in out.splitlines():
            if mac_l in line.lower() and line.startswith(prefix):
                cand = line.split()[0]
                if "REACHABLE" in line or "DELAY" in line:
                    return cand
                fallback_ip = cand
        if fallback_ip:
            return fallback_ip
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def fpga_boot(args: argparse.Namespace) -> int:
    board = args.board.resolve()
    disk = args.disk.resolve()
    if not disk.is_file():
        raise FileNotFoundError(f"disk image not found: {disk}")

    work_dir = args.work_dir.resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    payload_bin = args.kernel.resolve() if args.kernel else None
    _, fw_payload = build_firmware(work_dir, payload_bin=payload_bin)

    runtime_dtb = prepare_runtime_dtb(
        args.dtb.resolve(),
        work_dir / "runtime.dtb",
        bootargs=args.bootargs or "",
        strip_unused_buses=not args.keep_pcie,
        ram_mb=args.ram_mb,
    )

    bridge_cmd = [
        sys.executable, "-u", str(BRIDGE_SCRIPT),
        "--transport", "udp",
        "--udp-bind", f"{args.server}:{args.rqio_port}",
        "--udp-peer", f"{args.bridge_ip}:{args.rqio_port}",
        "--backend", "builtin",
        "--disk", str(disk),
    ]
    if args.snapshot:
        bridge_cmd.append("--snapshot")

    bridge_log = (work_dir / "rqio_bridge.log").open("w")
    print("+", " ".join(bridge_cmd), flush=True)
    bridge_proc = subprocess.Popen(
        bridge_cmd, stdout=bridge_log, stderr=subprocess.STDOUT
    )

    try:
        t0 = time.monotonic()
        netboot.upload(
            args.port,
            fw_payload,
            runtime_dtb,
            work_dir / "netboot",
            args.server,
            args.loader_ip,
            args.tftp_port,
            console=False,
            wait_ready=args.wait_ready,
            network={"driver": "virtio_net", "mac": args.mac},
            xlen=64,
        )
        t_tftp = time.monotonic()
        print(f"[fpga-boot] TFTP payload handoff complete in {t_tftp - t0:.2f}s", flush=True)

        # Monitor UART until login: (and optionally keep console or exit for SSH)
        from upload import Serial  # noqa: E402
        ser = Serial(args.port)
        log_path = work_dir / "uart_boot.log"
        uboot_nudged = False
        milestones: dict[str, float] = {"tftp_done_s": round(t_tftp - t0, 2)}
        buf = b""
        try:
            with log_path.open("wb") as lf:
                deadline = time.monotonic() + args.boot_timeout
                while time.monotonic() < deadline:
                    if bridge_proc.poll() is not None:
                        raise RuntimeError(
                            f"raptor_qemu_bridge exited early ({bridge_proc.returncode})"
                        )
                    if select.select([ser.fd], [], [], 0.25)[0]:
                        chunk = os.read(ser.fd, 4096)
                        if chunk:
                            os.write(1, chunk)
                            lf.write(chunk)
                            lf.flush()
                            buf = (buf + chunk)[-8192:]
                            rel = round(time.monotonic() - t_tftp, 2)
                            if "opensbi_s" not in milestones and b"OpenSBI" in buf:
                                milestones["opensbi_s"] = rel
                            if "uboot_s" not in milestones and b"U-Boot " in buf:
                                milestones["uboot_s"] = rel
                            if not uboot_nudged and b"Autoboot in " in buf:
                                os.write(ser.fd, b"\r")
                                uboot_nudged = True
                            if "kernel_s" not in milestones and (
                                b"NetBSD " in buf or b"FreeBSD " in buf or b"Linux version " in buf
                            ):
                                milestones["kernel_s"] = rel
                            if "root_mount_s" not in milestones and (
                                b"root on " in buf or b"Mounting from " in buf
                            ):
                                milestones["root_mount_s"] = rel
                            if "sshd_s" not in milestones and (
                                b"Starting sshd" in buf or b"Server listening on" in buf
                            ):
                                milestones["sshd_s"] = rel
                            if re.search(rb"(?:^|[\r\n])[^\r\n]{0,80}login:[ \t]*", buf[-1024:]):
                                milestones["login_prompt_s"] = rel
                                break
        finally:
            ser.close()

        guest_ip = discover_guest_ip(args.mac, args.server)
        print(f"\n[fpga-boot] milestones={milestones} guest_ip={guest_ip}", flush=True)
        if "login_prompt_s" not in milestones:
            raise TimeoutError(f"OS did not reach login: within {args.boot_timeout}s")

        if args.keep_alive:
            signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
            print(
                f"[fpga-boot] RQIO bridge PID={bridge_proc.pid} active for {disk.name} "
                f"(guest_ip={guest_ip}); press Ctrl-C to stop.",
                flush=True,
            )
            try:
                while bridge_proc.poll() is None:
                    time.sleep(1.0)
            except KeyboardInterrupt:
                pass
        return 0
    finally:
        if bridge_proc.poll() is None:
            bridge_proc.terminate()
            try:
                bridge_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge_proc.kill()
        bridge_log.close()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    pfw = sub.add_parser("firmware", help="Build OpenSBI + U-Boot firmware")
    pfw.add_argument("--work-dir", type=Path, required=True)
    pfw.add_argument("--kernel", type=Path, help="Optional flat kernel instead of U-Boot")
    pfw.add_argument("--jobs", type=int, default=8)

    ppr = sub.add_parser("provision", help="Provision NetBSD/FreeBSD image in QEMU")
    ppr.add_argument("--os", choices=("netbsd", "freebsd"), required=True)
    ppr.add_argument("--src", type=Path, required=True)
    ppr.add_argument("--dst", type=Path, required=True)
    ppr.add_argument("--work-dir", type=Path, required=True)
    ppr.add_argument("--kernel", type=Path, help="Optional NetBSD kernel for fast QEMU boot")
    ppr.add_argument("--timeout", type=int, default=420)

    pfb = sub.add_parser("fpga-boot", help="Boot .img/.raw on FPGA over VirtIO-Net + UDP RQIO")
    pfb.add_argument("--board", type=Path, default=REPO / "fpga/mlk-cu08-ku15p")
    pfb.add_argument("--dtb", type=Path, required=True)
    pfb.add_argument("--disk", type=Path, required=True)
    pfb.add_argument("--work-dir", type=Path, required=True)
    pfb.add_argument("--port", required=True, help="FPGA UART serial device")
    pfb.add_argument("--kernel", type=Path, help="Optional direct flat kernel binary")
    pfb.add_argument("--bootargs", default="")
    pfb.add_argument("--server", default="192.168.50.1")
    pfb.add_argument("--loader-ip", default="192.168.50.92")
    pfb.add_argument("--bridge-ip", default="192.168.50.93")
    pfb.add_argument("--mac", default="02:52:41:50:15:01")
    pfb.add_argument("--tftp-port", type=int, default=6969)
    pfb.add_argument("--rqio-port", type=int, default=9885)
    pfb.add_argument("--snapshot", action="store_true")
    pfb.add_argument("--wait-ready", action="store_true")
    pfb.add_argument("--keep-pcie", action="store_true")
    pfb.add_argument("--keep-alive", action="store_true")
    pfb.add_argument("--ram-mb", type=int, default=1024,
                     help="Guest DDR4 size in MiB in runtime DTB (0 keeps native DTB size)")
    pfb.add_argument("--boot-timeout", type=int, default=900)

    args = p.parse_args()
    if args.cmd == "firmware":
        dyn, pay = build_firmware(args.work_dir.resolve(), args.kernel, jobs=args.jobs)
        print(f"FW_DYNAMIC={dyn}\nFW_PAYLOAD={pay}")
        return 0
    if args.cmd == "provision":
        provision_image(args.os, args.src.resolve(), args.dst.resolve(),
                        args.work_dir.resolve(), args.kernel, timeout_s=args.timeout)
        return 0
    return fpga_boot(args)


if __name__ == "__main__":
    raise SystemExit(main())
