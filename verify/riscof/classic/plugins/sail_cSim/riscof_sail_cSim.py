"""RISCOF reference plugin: sail-riscv C simulator.

Minimal, DUT-agnostic variant of the upstream RISCOF sail_cSim plugin.
Adapted for modern `sail_riscv_sim` (config JSON based) and stripped of
neorv32-specific overrides.
"""

from __future__ import annotations

import logging
import os
import re
import shutil

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

RISCV_PREFIX = os.environ.get("RAPT_RISCV_PREFIX", "riscv64-elf-")


class sail_cSim(pluginTemplate):
    __model__ = "sail_c_simulator"
    __version__ = "0.5.0"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)
        config = kwargs.get("config")
        if config is None:
            logger.error("sail_cSim plugin: config node missing.")
            raise SystemExit(1)

        self.num_jobs = str(
            max(1, int(os.environ.get("RAPT_JOBS", config.get("jobs", 1))))
        )
        self.pluginpath = os.path.abspath(config["pluginpath"])
        self.sail_exe = os.path.join(
            config.get("PATH", ""), "sail_riscv_sim"
        )
        self.isa_spec = os.path.abspath(config.get("ispec", ""))
        self.platform_spec = os.path.abspath(config.get("pspec", ""))
        self.make = config.get("make", "make")
        return sclass

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.objdump_cmd = (
            f"{RISCV_PREFIX}objdump -D " + "{0} > {2} &&"
        )
        self.compile_cmd = (
            f"{RISCV_PREFIX}gcc -march={{0}}"
            " -static -mcmodel=medany -fvisibility=hidden"
            " -nostdlib -nostartfiles"
            f" -T {self.pluginpath}/env/link.ld"
            f" -I {self.pluginpath}/env/"
            f" -I {archtest_env}"
        )

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)["hart0"]
        self.xlen = "64" if 64 in ispec["supported_xlen"] else "32"
        isa = ispec["ISA"].upper()
        self.flen = "64" if "D" in isa else "32"
        sail_exe = shutil.which(self.sail_exe)
        if sail_exe is None:
            logger.error("sail_cSim: tool not found: %s", self.sail_exe)
            raise SystemExit(1)
        self.sail_exe = os.path.realpath(sail_exe)
        self.isa_yaml_path = isa_yaml
        self.isa = "rv" + self.xlen

        for letter in "IMAFDCB":
            if letter in ispec["ISA"]:
                self.isa += letter.lower()

        for tool in (
            f"{RISCV_PREFIX}gcc",
            f"{RISCV_PREFIX}objdump",
            self.make,
        ):
            if shutil.which(tool) is None:
                logger.error("sail_cSim: tool not found: %s", tool)
                raise SystemExit(1)

    # ------------------------------------------------------------------
    def runTests(self, testList, cgf_file=None, header_file=None):
        makefile_path = os.path.join(
            self.work_dir, "Makefile." + self.name[:-1]
        )
        if os.path.exists(makefile_path):
            os.remove(makefile_path)
        make = utils.makeUtil(makefilePath=makefile_path)
        make.makeCommand = self.make + " -j" + self.num_jobs
        sail_arch_flag = " --rv32" if self.xlen == "32" else ""

        for testname in testList:
            entry = testList[testname]
            test = entry["test_path"]
            test_dir = entry["work_dir"]
            test_name = test.rsplit("/", 1)[1][:-2]

            elf = "ref.elf"
            execute = f"@cd {test_dir} &&"
            march = entry["isa"].lower()
            mabi = self._mabi_for_isa(march)
            compile_cmd = (
                self.compile_cmd.format(march)
                + " -mabi=" + mabi
                + " " + test + " -o " + elf
                + " -D" + " -D".join(entry["macros"])
            )
            execute += compile_cmd + " &&"
            execute += self.objdump_cmd.format(elf, self.xlen, "ref.disass")

            sig_file = os.path.join(
                test_dir, self.name[:-1] + ".signature"
            )

            execute += (
                f"{self.sail_exe}"
                f"{sail_arch_flag}"
                f" --signature-granularity=4"
                f" --test-signature={sig_file}"
                f" {elf} > {test_name}.log 2>&1"
            )
            make.add_target(execute)

        make.execute_all(self.work_dir)

    @staticmethod
    def _mabi_for_isa(march):
        base_isa = march.lower().split("_", 1)[0]
        xlen_prefix = "rv64" if base_isa.startswith("rv64") else "rv32"
        extension_block = base_isa[len(xlen_prefix):]
        extension_block = re.split(r"[zsx]", extension_block, maxsplit=1)[0]
        xlen_abi = "lp64" if base_isa.startswith("rv64") else "ilp32"
        if "d" in extension_block:
            return xlen_abi + "d"
        if "f" in extension_block:
            return xlen_abi + "f"
        return xlen_abi
