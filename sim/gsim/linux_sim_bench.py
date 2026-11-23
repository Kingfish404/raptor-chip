#!/usr/bin/env python3
"""Run Linux-mode CoreMark and Embench-IoT on RTL Verilator via NEMU checkpoints.

Boots real Linux (RV32 or RV64) in NEMU up to each benchmark's ROI-begin marker
(after ELF load and perf_user_access=2), captures an architectural checkpoint,
and replays the full timed ROI on real RTL Verilator with MMU/TLB active.

Outputs CoreMark/MHz and KU5P-relative Embench-IoT (19 workloads) comparable to
the FPGA Linux rows in README.md.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

GSIM_DIR = Path(__file__).resolve().parent
RAPTOR_HOME = GSIM_DIR.parents[1]

BENCHMARKS = [
    "aha-mont64", "crc32", "depthconv", "edn", "huffbench", "matmult-int",
    "md5sum", "nettle-aes", "nettle-sha256", "nsichneu", "picojpeg",
    "qrduino", "sglib-combined", "slre", "statemate", "tarfind", "ud",
    "wikisort", "xgboost",
]

# KU5P FPGA Linux (middle-cache / RV64, 50 MHz core, 333 MHz DDR4 UI)
# baseline hart_cycles for the 19 passing Embench-IoT workloads (gsf=1).
KU5P_REF_CYCLES: dict[str, int] = {
    "aha-mont64": 2012542,
    "crc32": 2976567,
    "depthconv": 2601631,
    "edn": 2962053,
    "huffbench": 3495276,
    "matmult-int": 3927470,
    "md5sum": 2320749,
    "nettle-aes": 3916419,
    "nettle-sha256": 4570835,
    "nsichneu": 9492732,
    "picojpeg": 4365474,
    "qrduino": 5432715,
    "sglib-combined": 5664907,
    "slre": 4415718,
    "statemate": 6329147,
    "tarfind": 4769575,
    "ud": 5047396,
    "wikisort": 1814443,
    "xgboost": 5462732,
}

LINUX_SIM_PROFILE_C = r"""
#include "profile.h"
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *bench_name = "unknown";
static uint64_t begin_cycle, end_cycle, begin_instret, end_instret;

static inline uint64_t read_cycle(void) {
#if __riscv_xlen == 64
    uint64_t v;
    __asm__ volatile("rdcycle %0" : "=r"(v) :: "memory");
    return v;
#else
    uint32_t hi0, lo, hi1;
    do {
        __asm__ volatile("rdcycleh %0" : "=r"(hi0) :: "memory");
        __asm__ volatile("rdcycle %0" : "=r"(lo) :: "memory");
        __asm__ volatile("rdcycleh %0" : "=r"(hi1) :: "memory");
    } while (hi0 != hi1);
    return ((uint64_t)hi1 << 32) | lo;
#endif
}

static inline uint64_t read_instret(void) {
#if __riscv_xlen == 64
    uint64_t v;
    __asm__ volatile("rdinstret %0" : "=r"(v) :: "memory");
    return v;
#else
    uint32_t hi0, lo, hi1;
    do {
        __asm__ volatile("rdinstreth %0" : "=r"(hi0) :: "memory");
        __asm__ volatile("rdinstret %0" : "=r"(lo) :: "memory");
        __asm__ volatile("rdinstreth %0" : "=r"(hi1) :: "memory");
    } while (hi0 != hi1);
    return ((uint64_t)hi1 << 32) | lo;
#endif
}

static void enable_user_csr(void) {
    int fd = open("/proc/sys/kernel/perf_user_access", O_WRONLY);
    if (fd >= 0) {
        (void)write(fd, "2\n", 2);
        close(fd);
    }
}

void profile_emit_roi_marker(void) {
    const char msg[] = "RAPTOR_ROI_BEGIN\n";
    ssize_t _r = write(1, msg, sizeof(msg) - 1);
    (void)_r;
    /* Let the 8250 UART TX IRQ drain before NEMU captures at +50k insts. */
    for (volatile int i = 0; i < 40000; i++) {
        __asm__ volatile("nop");
    }
}

void profile_init(const char *name) {
    bench_name = name;
    setbuf(stdout, NULL);
    enable_user_csr();
    printf("PROFILE_BEGIN_CONFIG name=%s sample_ns=0 csr=1\n", bench_name);
}

void profile_begin(void) {
    begin_instret = read_instret();
    begin_cycle = read_cycle();
}

void profile_end(void) {
    end_cycle = read_cycle();
    end_instret = read_instret();
}

uint64_t profile_elapsed_ns(void) {
    /* Scaled to 50 MHz core clock (20 ns/cycle) to match FPGA Linux rows. */
    return (end_cycle - begin_cycle) * UINT64_C(20);
}

void profile_report(void) {
    uint64_t cyc = end_cycle - begin_cycle;
    uint64_t ins = end_instret - begin_instret;
    printf("PROFILE_JSON {\"name\":\"%s\",\"wall_ns\":%" PRIu64
           ",\"hart_cycles\":%" PRIu64 ",\"hart_instructions\":%" PRIu64 "}\n",
           bench_name, cyc * UINT64_C(20), cyc, ins);
}
"""

EMBENCH_SIM_MAIN_C = r"""
#include "support.h"
#include "profile.h"
#include <stdio.h>
#include <stdlib.h>

extern void profile_emit_roi_marker(void);

#ifndef BENCH_NAME
#define BENCH_NAME "unknown"
#endif

int main(int argc, char **argv) {
    long repeats = argc > 1 ? strtol(argv[1], NULL, 10) : 1;
    if (repeats < 1 || repeats > 10000)
        return 2;
    profile_init(BENCH_NAME);
    initialise_benchmark();
    profile_emit_roi_marker();
    warm_caches(1);
    volatile int result = 0;
    profile_begin();
    for (long i = 0; i < repeats; i++)
        result = benchmark();
    profile_end();
    int correct = verify_benchmark(result);
    profile_report();
    printf("EMBENCH_VERIFY name=%s repeats=%ld result=%d verified=%d\n",
           BENCH_NAME, repeats, result, correct);
    return correct == 1 ? 0 : 1;
}
"""

COREMARK_SIM_PORTME_C = r"""
#include "coremark.h"
#include "profile.h"

extern void profile_emit_roi_marker(void);

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[]) {
    p->portable_id = 1;
    if (*argc > 1) {
        long iterations = strtol(argv[1], NULL, 10);
        if (iterations >= 1 && iterations <= 1000000)
            seed4_volatile = iterations;
    }
    profile_init("coremark");
    profile_emit_roi_marker();
}

void start_time(void) { profile_begin(); }
void stop_time(void) { profile_end(); }
CORE_TICKS get_time(void) { return profile_elapsed_ns(); }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks / 1000000000.0; }
void portable_fini(core_portable *p) {
    p->portable_id = 0;
    profile_report();
}
"""

# Minimal open/close Linux ecall additions to pair with app/lib/pk_io.c under picolibc.
RV32_LINUX_SHIM_C = r"""
#include <stdint.h>
#include <sys/types.h>

static inline long linux_ecall4(long n, long a0, long a1, long a2, long a3) {
    register long r_a0 __asm__("a0") = a0;
    register long r_a1 __asm__("a1") = a1;
    register long r_a2 __asm__("a2") = a2;
    register long r_a3 __asm__("a3") = a3;
    register long r_a7 __asm__("a7") = n;
    __asm__ volatile("ecall"
                     : "+r"(r_a0)
                     : "r"(r_a1), "r"(r_a2), "r"(r_a3), "r"(r_a7)
                     : "memory");
    return r_a0;
}

int open(const char *path, int flags, ...) {
    long r = linux_ecall4(56, -100, (long)path, flags, 0); /* SYS_openat */
    return r < 0 ? -1 : (int)r;
}

int close(int fd) {
    long r = linux_ecall4(57, fd, 0, 0, 0); /* SYS_close */
    return r < 0 ? -1 : (int)r;
}

static uintptr_t cur_brk = 0;
void *sbrk(ptrdiff_t incr) {
    if (!cur_brk) {
        cur_brk = (uintptr_t)linux_ecall4(214, 0, 0, 0, 0); /* SYS_brk */
    }
    uintptr_t prev = cur_brk;
    uintptr_t next = prev + (uintptr_t)incr;
    uintptr_t res = (uintptr_t)linux_ecall4(214, (long)next, 0, 0, 0);
    if (res < next)
        return (void *)-1;
    cur_brk = res;
    return (void *)prev;
}
"""


def geomean(vals: list[float]) -> float:
    return math.exp(sum(math.log(v) for v in vals) / len(vals))


def build_binaries(xlen: int, bin_dir: Path, cm_iters: int, benches: list[str]) -> dict[str, Path]:
    bin_dir.mkdir(parents=True, exist_ok=True)
    src_dir = bin_dir / "_src"
    src_dir.mkdir(exist_ok=True)
    (src_dir / "linux_sim_profile.c").write_text(LINUX_SIM_PROFILE_C)
    (src_dir / "embench_sim_main.c").write_text(EMBENCH_SIM_MAIN_C)
    (src_dir / "coremark_sim_portme.c").write_text(COREMARK_SIM_PORTME_C)
    if xlen == 32:
        (src_dir / "rv32_linux_shim.c").write_text(RV32_LINUX_SHIM_C)

    ubuntu_bench = RAPTOR_HOME / "fpga/common/tests/ubuntu_bench"
    core_dir = RAPTOR_HOME / "abstract-machine/app/am-kernels/benchmarks/coremark_eembc/src"
    core_hdr = RAPTOR_HOME / "app/benchmarks/coremark/portme"
    embench_dir = RAPTOR_HOME / "app/build/src/embench-iot"

    if xlen == 64:
        cc = "riscv64-linux-gnu-gcc"
        flags = ["-O2", "-march=rv64gc", "-mabi=lp64d", "-static", "-fno-pie", "-no-pie",
                 "-std=gnu99", "-Wno-unused-parameter", "-Wno-unused-variable",
                 "-Wno-sign-compare", "-Wno-unused-but-set-variable"]
        extra_srcs: list[Path] = []
        link_flags = ["-lm"]
    else:
        cc = "riscv64-unknown-elf-gcc"
        flags = ["-O2", "-march=rv32imafdc", "-mabi=ilp32d", "--specs=picolibc.specs",
                 "-nostartfiles", "-T" + str(RAPTOR_HOME / "app/lib/pk-user.ld"),
                 "-std=gnu99", "-Wno-unused-parameter", "-Wno-unused-variable",
                 "-Wno-sign-compare", "-Wno-unused-but-set-variable"]
        extra_srcs = [RAPTOR_HOME / "app/lib/pk_io.c", src_dir / "rv32_linux_shim.c"]
        link_flags = ["-lm"]

    built: dict[str, Path] = {}

    if "coremark" in benches:
        out = bin_dir / "coremark"
        cm_srcs = [core_dir / f for f in (
            "core_list_join.c", "core_main.c", "core_matrix.c",
            "core_state.c", "core_util.c",
        )]
        cmd = [
            cc, *flags,
            "-I" + str(ubuntu_bench), "-I" + str(core_dir), "-I" + str(core_hdr),
            f"-DITERATIONS={cm_iters}", "-DHAS_FLOAT=1", "-DPERFORMANCE_RUN=1",
            '-DCOMPILER_FLAGS="-O2"', '-DMEM_LOCATION="Linux static arrays"',
            *map(str, cm_srcs),
            str(src_dir / "coremark_sim_portme.c"),
            str(src_dir / "linux_sim_profile.c"),
            *map(str, extra_srcs),
            *link_flags, "-o", str(out),
        ]
        subprocess.run(cmd, check=True)
        built["coremark"] = out

    for name in benches:
        if name == "coremark":
            continue
        out = bin_dir / name
        d = embench_dir / "src" / name
        srcs = sorted(d.glob("*.c"))
        cmd = [
            cc, *flags,
            "-I" + str(ubuntu_bench), "-I" + str(d), "-I" + str(embench_dir / "support"),
            "-DGLOBAL_SCALE_FACTOR=1", f'-DBENCH_NAME="{name}"',
            *map(str, srcs),
            str(embench_dir / "support/beebsc.c"),
            str(src_dir / "embench_sim_main.c"),
            str(src_dir / "linux_sim_profile.c"),
            *map(str, extra_srcs),
            *link_flags, "-o", str(out),
        ]
        subprocess.run(cmd, check=True)
        built[name] = out

    return built


def make_dtb(xlen: int, firmware: Path, nemu_bin: Path, out_dtb: Path) -> None:
    if out_dtb.exists():
        return
    out_dtb.parent.mkdir(parents=True, exist_ok=True)
    tmp_dir = out_dtb.parent / "_dtb_gen"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    cmd = [
        sys.executable, str(RAPTOR_HOME / "nemu/tools/nemu.py"), "run",
        "--xlen", str(xlen),
        "--emulator", str(nemu_bin),
        "--firmware", str(firmware),
        "--dry-run", "--state-dir", str(tmp_dir),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    gen_dtb = tmp_dir / "nemu.dtb"
    if not gen_dtb.exists():
        gen_dtb = tmp_dir / "machine.dtb"
    if not gen_dtb.exists():
        cands = list(tmp_dir.glob("*.dtb"))
        if not cands:
            raise RuntimeError(f"No .dtb generated in {tmp_dir}")
        gen_dtb = cands[0]
    shutil.copyfile(gen_dtb, out_dtb)
    # Clamp PLIC riscv,ndev=31 for RTL PLIC compatibility
    subprocess.run(
        ["fdtput", "-t", "u", str(out_dtb), "/soc/plic@c000000", "riscv,ndev", "31"],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def capture_one(
    name: str, prog: Path, xlen: int, ram_mib: int,
    nemu_bin: Path, firmware: Path, base_initramfs: Path, base_dtb: Path,
    work_root: Path, cm_iters: int,
) -> tuple[str, Path]:
    bdir = work_root / name
    ckpt_dir = bdir / "ckpt"
    existing = sorted(ckpt_dir.glob("sample-*")) if ckpt_dir.exists() else []
    if existing and (existing[0] / "state.txt").exists():
        return name, existing[0]

    if bdir.exists():
        shutil.rmtree(bdir)
    wl_dir = bdir / "workload"
    if xlen == 64:
        rootfs_dummy = work_root / "_empty_rootfs"
        rootfs_dummy.mkdir(parents=True, exist_ok=True)
        wl_cmd = [
            sys.executable, str(RAPTOR_HOME / "verification/performance/linux_workload.py"),
            "--firmware", str(firmware),
            "--base-initramfs", str(base_initramfs),
            "--dtb", str(base_dtb),
            "--rootfs", str(rootfs_dummy),
            "--program", str(prog),
            "--output", str(wl_dir),
            "--ram-mib", str(ram_mib),
            "--compression", "none",
            "--readelf", "riscv64-linux-gnu-readelf",
            "--arg", str(cm_iters if name == "coremark" else 1),
        ]
        subprocess.run(wl_cmd, check=True, stdout=subprocess.DEVNULL)
    else:
        import gzip
        sys.path.insert(0, str(RAPTOR_HOME / "verification/performance"))
        import linux_workload as lw
        wl_dir.mkdir(parents=True, exist_ok=True)
        arg_s = str(cm_iters if name == "coremark" else 1)
        init_sh = (
            "#!/bin/sh\nexport PATH=/sbin:/bin:/usr/sbin:/usr/bin\n"
            "mount -t proc proc /proc\nmount -t sysfs sysfs /sys\n"
            "mount -t devtmpfs devtmpfs /dev\n"
            "echo RAPTOR_WORKLOAD_BEGIN\ncd /work || exit 2\n"
            f"./program {arg_s}\n"
            "result=$?\necho RAPTOR_WORKLOAD_EXIT=$result\n"
            "poweroff -f\nwhile :; do sleep 1; done\n"
        ).encode()
        base_cpio = gzip.decompress(base_initramfs.read_bytes())
        initramfs = lw.append_entries(
            base_cpio, {"work/program": prog.read_bytes(), "init": init_sh}
        )
        initrd_addr = 0x84000000
        fw_out = wl_dir / "fw_payload.bin"
        with fw_out.open("wb") as stream:
            with firmware.open("rb") as fw_in:
                shutil.copyfileobj(fw_in, stream)
            stream.seek(initrd_addr - 0x80000000)
            stream.write(initramfs)
        dtb_out = wl_dir / "machine.dtb"
        shutil.copyfile(base_dtb, dtb_out)
        subprocess.run(
            ["fdtput", "-t", "x", str(dtb_out), "/chosen", "linux,initrd-start",
             f"{initrd_addr:x}"],
            check=True, stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            ["fdtput", "-t", "x", str(dtb_out), "/chosen", "linux,initrd-end",
             f"{initrd_addr + len(initramfs):x}"],
            check=True, stdout=subprocess.DEVNULL,
        )

    bbv_file = bdir / "bbv.jsonl"
    nemu_log = bdir / "nemu_capture.log"
    nemu_cmd = [
        str(nemu_bin), "-b", "--serial-stdout",
        "-t", str(wl_dir / "machine.dtb"),
        "--bbv=" + str(bbv_file),
        "--bbv-interval=50000",
        "--bbv-length=100000",
        "--bbv-start-marker=RAPTOR_ROI_BEGIN",
        "--sample-directory=" + str(ckpt_dir),
        "--sample-bbv-every=1",
        str(wl_dir / "fw_payload.bin"),
    ]
    with nemu_log.open("w") as lf:
        proc = subprocess.run(nemu_cmd, stdout=lf, stderr=subprocess.STDOUT, timeout=2400)
    snaps = sorted(ckpt_dir.glob("sample-*"))
    if not snaps or not (snaps[0] / "state.txt").exists():
        raise RuntimeError(
            f"NEMU capture failed for {name} (rc={proc.returncode}); see {nemu_log}"
        )
    return name, snaps[0]


def replay_one(
    name: str, ckpt: Path, rtl_sim: Path, out_dir: Path,
    read_lat: int, write_lat: int, timeout: int,
) -> dict:
    rdir = out_dir / name
    rdir.mkdir(parents=True, exist_ok=True)
    log_path = rdir / "rtl_replay.log"
    cmd = [
        str(rtl_sim), "-b", "-n", "--no-lightsss",
        "-t", str(timeout),
        "-m", "200000000",
        f"--ckpt-load={ckpt}",
        f"--mem-read-latency={read_lat}",
        f"--mem-write-latency={write_lat}",
        "--mem-random-delay=0",
    ]
    t0 = time.monotonic()
    saw_exit = False
    with log_path.open("w") as lf:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", bufsize=1,
        )
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                lf.write(line)
                if "RAPTOR_WORKLOAD_EXIT=" in line:
                    saw_exit = True
                    proc.terminate()
                    break
                if time.monotonic() - t0 > timeout:
                    proc.kill()
                    break
        finally:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    wall = time.monotonic() - t0
    clean = log_path.read_text(errors="replace")
    clean = re.sub(r"Failed to open perf\.log:[^\n]*\n?", "", clean)
    clean = re.sub(r"Failed to save uarch state[^\n]*\n?", "", clean)
    clean = re.sub(r"cpu_exec\.cc:[^\n]*\n?", "", clean)
    prof = None
    m_prof = re.search(r"PROFILE_JSON\s+(\{[^\n]+\})", clean)
    if m_prof:
        try:
            prof = json.loads(m_prof.group(1))
        except json.JSONDecodeError:
            pass
    verified = True
    m_ver = re.search(r"EMBENCH_VERIFY .*verified=(\d+)", clean)
    if m_ver:
        verified = (m_ver.group(1) == "1")
    ok = (prof is not None) and verified and (prof.get("hart_cycles", 0) > 0)
    return {
        "name": name,
        "ok": ok,
        "rc": 0 if saw_exit else proc.returncode,
        "wall_s": round(wall, 2),
        "cycles": prof["hart_cycles"] if prof else 0,
        "insts": prof["hart_instructions"] if prof else 0,
        "ipc": (prof["hart_instructions"] / prof["hart_cycles"]) if ok else 0.0,
        "log": str(log_path),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    ap.add_argument("--preset", required=True)
    ap.add_argument("--rtl-sim", type=Path, required=True)
    ap.add_argument("--nemu", type=Path, required=True)
    ap.add_argument("--firmware", type=Path, required=True)
    ap.add_argument("--base-initramfs", type=Path, required=True)
    ap.add_argument("--ram-mib", type=int, required=True)
    ap.add_argument("--outdir", type=Path, required=True)
    ap.add_argument("--ckpt-root", type=Path, required=True,
                    help="Reusable directory for built binaries and NEMU checkpoints")
    ap.add_argument("--cm-iters", type=int, default=2)
    ap.add_argument("--benches", default="coremark," + ",".join(BENCHMARKS))
    ap.add_argument("--read-latency", type=int, default=0)
    ap.add_argument("--write-latency", type=int, default=0)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    benches = [b.strip() for b in args.benches.split(",") if b.strip()]
    args.outdir.mkdir(parents=True, exist_ok=True)
    args.ckpt_root.mkdir(parents=True, exist_ok=True)

    print(f"[linux_sim] Building {len(benches)} RV{args.xlen} Linux benchmarks...", flush=True)
    bins = build_binaries(args.xlen, args.ckpt_root / "bins", args.cm_iters, benches)

    base_dtb = args.ckpt_root / "base.dtb"
    make_dtb(args.xlen, args.firmware, args.nemu, base_dtb)

    print(f"[linux_sim] Capturing NEMU Linux checkpoints (jobs={args.jobs})...", flush=True)
    ckpts: dict[str, Path] = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {
            ex.submit(
                capture_one, name, bins[name], args.xlen, args.ram_mib,
                args.nemu, args.firmware, args.base_initramfs, base_dtb,
                args.ckpt_root / "work", args.cm_iters,
            ): name
            for name in benches
        }
        for fut in cf.as_completed(futs):
            name, ckpt = fut.result()
            ckpts[name] = ckpt
            print(f"  [ckpt] {name:16s} -> {ckpt.name}", flush=True)

    print(f"[linux_sim] Replaying on RTL {args.preset}/RV{args.xlen} (jobs={args.jobs})...",
          flush=True)
    results: dict[str, dict] = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {
            ex.submit(
                replay_one, name, ckpts[name], args.rtl_sim, args.outdir,
                args.read_latency, args.write_latency, args.timeout,
            ): name
            for name in benches
        }
        for fut in cf.as_completed(futs):
            res = fut.result()
            results[res["name"]] = res
            print(
                f"  [rtl]  {res['name']:16s} ok={res['ok']} cyc={res['cycles']:10d} "
                f"inst={res['insts']:10d} ipc={res['ipc']:.4f} wall={res['wall_s']}s",
                flush=True,
            )

    cm_mhz = None
    if "coremark" in results and results["coremark"]["ok"]:
        cm_mhz = args.cm_iters * 1e6 / results["coremark"]["cycles"]

    ratios = []
    for b in BENCHMARKS:
        r = results.get(b)
        if r and r["ok"] and b in KU5P_REF_CYCLES:
            ratios.append(KU5P_REF_CYCLES[b] / r["cycles"])
    emb_rel = geomean(ratios) if ratios else None

    summary = {
        "preset": args.preset,
        "xlen": args.xlen,
        "cm_iters": args.cm_iters,
        "cm_mhz": round(cm_mhz, 4) if cm_mhz else None,
        "embench_ok": len(ratios),
        "embench_rel_ku5p": round(emb_rel, 4) if emb_rel else None,
        "benchmarks": results,
    }
    (args.outdir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(
        f"\n[linux_sim] SUMMARY {args.preset} / RV{args.xlen}: "
        f"CM/MHz={cm_mhz:.4f}" if cm_mhz else f"\n[linux_sim] SUMMARY {args.preset} / RV{args.xlen}: CM/MHz=N/A",
        end="",
    )
    print(f" | Embench-IoT ({len(ratios)}/19 vs KU5P)={emb_rel:.4f}x" if emb_rel else " | Embench=N/A")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
