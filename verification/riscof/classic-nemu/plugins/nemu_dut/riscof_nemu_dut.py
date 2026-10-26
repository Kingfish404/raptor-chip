"""RISCOF DUT plugin for NEMU (classic RISCOF flow).

Uses the NEMU standalone executable (riscv{32,64}-nemu-interpreter) as the
DUT, with the same signature-dump + sifive,test halt convention as the
Raptor DUT.  This lets us run the RISCOF test suite against NEMU itself
to verify that the reference model implements what we are testing, and
cross-check the Raptor DUT results.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import logging
import os
import shlex
import shutil
import subprocess

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

RISCV_PREFIX = os.environ.get("RAPT_RISCV_PREFIX", "riscv64-elf-")


class nemu_dut(pluginTemplate):
    __model__ = "nemu_dut"
    __version__ = "0.1.0"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)
        config = kwargs.get("config")
        if config is None:
            logger.error("nemu_dut plugin: config node missing in config.ini")
            raise SystemExit(1)

        self.pluginpath = os.path.abspath(config["pluginpath"])
        self.isa_spec = os.path.abspath(config["ispec"])
        self.platform_spec = os.path.abspath(config["pspec"])
        self.num_jobs = max(1, int(os.environ.get("RAPT_JOBS", config.get("jobs", 4))))
        self.target_run = config.get("target_run", "1") != "0"

        # NEMU-specific paths picked up from the environment.  The verify
        # Makefile exports NEMU_BIN and NEMU_HOME before invoking `riscof run`.
        self.nemu_bin = os.environ.get("NEMU_BIN")
        self.nemu_home = os.environ.get("NEMU_HOME")
        self.timeout = os.environ.get("RAPT_TIMEOUT", "30")

        if not self.nemu_bin or not os.path.isfile(self.nemu_bin):
            logger.error(
                "nemu_dut plugin: NEMU_BIN env not set or file missing: %s",
                self.nemu_bin,
            )
            raise SystemExit(1)
        if not self.nemu_home or not os.path.isdir(self.nemu_home):
            logger.error(
                "nemu_dut plugin: NEMU_HOME env not set or dir missing: %s",
                self.nemu_home,
            )
            raise SystemExit(1)

        self.cc = RISCV_PREFIX + "gcc"
        self.objcopy = RISCV_PREFIX + "objcopy"
        self.nm = RISCV_PREFIX + "nm"
        for tool in (self.cc, self.objcopy, self.nm):
            if shutil.which(tool) is None:
                logger.error("nemu_dut plugin: %s not found on PATH", tool)
                raise SystemExit(1)

        return sclass

    def initialise(self, suite, work_dir, archtest_env):
        self.suite_dir = suite
        self.work_dir = work_dir
        self.archtest_env = archtest_env
        self.compile_cmd = (
            self.cc
            + " -march={0}"
            + " -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles"
            + " -T " + os.path.join(self.pluginpath, "env", "link.ld")
            + " -I " + os.path.join(self.pluginpath, "env")
            + " -I " + archtest_env
            + " {2} -o {3} {4}"
        )

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)["hart0"]
        self.xlen = "64" if 64 in ispec["supported_xlen"] else "32"
        self.compile_cmd += (
            " -mabi=" + ("lp64 " if self.xlen == "64" else "ilp32 ")
        )

    # ------------------------------------------------------------------
    def _extract_sig_range(self, elf):
        out = subprocess.check_output([self.nm, elf], text=True)
        begin = end = None
        for line in out.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            addr, _sym_type, name = parts[0], parts[1], parts[2]
            if name == "begin_signature":
                begin = int(addr, 16)
            elif name == "end_signature":
                end = int(addr, 16)
        if begin is None or end is None:
            raise RuntimeError(
                f"signature symbols not found in {elf}"
            )
        return begin, end

    # ------------------------------------------------------------------
    def runTests(self, testList):
        total = len(testList)
        if not total:
            raise RuntimeError("No NEMU tests selected")
        jobs = ((idx, total, name, testList[name]) for idx, name in enumerate(testList, 1))
        with ThreadPoolExecutor(max_workers=self.num_jobs) as pool:
            failures = [name for name in pool.map(self._run_test, jobs) if name]
        if failures:
            raise RuntimeError(f"{len(failures)}/{total} NEMU runs failed; see dut/nemu.log")

    def _run_test(self, job):
        idx, total, testname, entry = job
        test_dir = entry["work_dir"]
        asm = entry["test_path"]
        marchstr = entry["isa"].lower()

        os.makedirs(test_dir, exist_ok=True)
        elf = os.path.join(test_dir, "dut.elf")
        bin_ = os.path.join(test_dir, "dut.bin")
        sig = os.path.join(test_dir, self.name[:-1] + ".signature")

        macros = " -D" + " -D".join(entry["macros"])
        cmd = self.compile_cmd.format(marchstr, self.xlen, asm, elf, macros)
        logger.debug("[%d/%d] compile: %s", idx, total, cmd)
        with open(os.path.join(test_dir, "build.log"), "w") as log:
            subprocess.run(shlex.split(cmd), cwd=test_dir, stdout=log,
                           stderr=subprocess.STDOUT, check=True)
            subprocess.run([self.objcopy, "-O", "binary", elf, bin_],
                           cwd=test_dir, stdout=log,
                           stderr=subprocess.STDOUT, check=True)

        print(f"[{idx}/{total}] {os.path.basename(testname)}", flush=True)

        if not self.target_run:
            return None

        beg, end = self._extract_sig_range(elf)
        # NEMU must be invoked from its own source tree because it
        # dereferences the DTB with a path relative to $NEMU_HOME.
        run_cmd = [self.nemu_bin, "-b", "-n",
                   f"--sig={beg:x}-{end:x}:{sig}", bin_]
        logger.debug("DUT run: %s", run_cmd)
        if os.path.exists(sig):
            os.remove(sig)
        try:
            with open(os.path.join(test_dir, "nemu.log"), "w") as log:
                subprocess.run(run_cmd, cwd=self.nemu_home, stdout=log,
                               stderr=subprocess.STDOUT,
                               timeout=int(self.timeout) + 30, check=True)
            if not os.path.isfile(sig) or os.path.getsize(sig) == 0:
                raise RuntimeError("NEMU produced no signature")
        except (subprocess.SubprocessError, OSError, RuntimeError) as exc:
            logger.error("DUT run failed for %s: %s", testname, exc)
            return testname
        return None
