"""RISCOF DUT plugin for Raptor Chip (classic RISCOF flow).

Compiles each test through `riscv64-elf-gcc`, extracts the signature region
symbols from the ELF, then runs the binary on the Raptor sim simulator with
`--sig=<begin>-<end>:<signature_path>` so that sim writes the RISCOF signature
directly.  No difftest is needed: RISCOF compares the DUT signature against
the sail reference signature.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

# Default tool prefix (can be overridden via env var RAPT_RISCV_PREFIX).
RISCV_PREFIX = os.environ.get("RAPT_RISCV_PREFIX", "riscv64-elf-")


class raptor(pluginTemplate):
    __model__ = "raptor"
    __version__ = "0.1.0"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)
        config = kwargs.get("config")
        if config is None:
            logger.error("raptor plugin: config node missing in config.ini")
            raise SystemExit(1)

        self.pluginpath = os.path.abspath(config["pluginpath"])
        self.isa_spec = os.path.abspath(config["ispec"])
        self.platform_spec = os.path.abspath(config["pspec"])
        self.num_jobs = str(config.get("jobs", 1))
        self.target_run = config.get("target_run", "1") != "0"

        # Raptor-specific paths picked up from environment.  The verify
        # Makefile exports these before invoking `riscof run`.
        self.npc_bin = os.environ.get("NPC_BIN")
        self.mrom_img = os.environ.get("MROM_IMG")
        self.timeout = os.environ.get("RAPT_TIMEOUT", "30")
        # The sim binary expects its working directory to be $NSIM_HOME
        # because it dlopen()s capstone via a relative path. All test
        # inputs/outputs we pass on the command line are absolute.
        self.nsim_home = os.environ.get("NSIM_HOME")

        if not self.npc_bin or not os.path.isfile(self.npc_bin):
            logger.error(
                "raptor plugin: NPC_BIN env not set or file missing: %s",
                self.npc_bin,
            )
            raise SystemExit(1)
        if not self.mrom_img or not os.path.isfile(self.mrom_img):
            logger.error(
                "raptor plugin: MROM_IMG env not set or file missing: %s",
                self.mrom_img,
            )
            raise SystemExit(1)

        self.cc = RISCV_PREFIX + "gcc"
        self.objcopy = RISCV_PREFIX + "objcopy"
        self.nm = RISCV_PREFIX + "nm"
        for tool in (self.cc, self.objcopy, self.nm):
            if shutil.which(tool) is None:
                logger.error("raptor plugin: %s not found on PATH", tool)
                raise SystemExit(1)

        return sclass

    def initialise(self, suite, work_dir, archtest_env):
        self.suite_dir = suite
        self.work_dir = work_dir
        self.archtest_env = archtest_env
        # march is set per-test by RISCOF via testList[name]['isa']
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
        """Return (begin, end) signature addresses parsed from `nm` output."""
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
        for idx, testname in enumerate(testList, 1):
            entry = testList[testname]
            test_dir = entry["work_dir"]
            asm = entry["test_path"]
            marchstr = entry["isa"].lower()

            os.makedirs(test_dir, exist_ok=True)
            elf = os.path.join(test_dir, "dut.elf")
            bin_ = os.path.join(test_dir, "dut.bin")
            # RISCOF expects DUT-<dut>.signature (self.name has trailing '_')
            sig = os.path.join(test_dir, self.name[:-1] + ".signature")

            macros = " -D" + " -D".join(entry["macros"])
            cmd = self.compile_cmd.format(marchstr, self.xlen, asm, elf, macros)
            logger.debug("[%d/%d] compile: %s", idx, total, cmd)
            utils.shellCommand(cmd).run(cwd=test_dir)

            utils.shellCommand(
                f"{self.objcopy} -O binary {elf} {bin_}"
            ).run(cwd=test_dir)

            print(f"[{idx}/{total}] {os.path.basename(testname)}")

            if not self.target_run:
                continue

            beg, end = self._extract_sig_range(elf)
            run_cmd = (
                f"{self.npc_bin} -b -n --trap-on-ebreak -r {self.mrom_img} "
                f"--sig={beg:x}-{end:x}:{sig} "
                f"-t {self.timeout} {bin_}"
            )
            logger.debug("DUT run: %s", run_cmd)
            try:
                utils.shellCommand(run_cmd).run(
                    cwd=self.nsim_home or test_dir,
                    timeout=int(self.timeout) + 30,
                )
            except Exception as exc:
                logger.warning("DUT run failed for %s: %s", testname, exc)
                # Produce an empty signature so RISCOF flags the failure
                # rather than aborting the whole run.
                if not os.path.exists(sig):
                    open(sig, "w").close()
