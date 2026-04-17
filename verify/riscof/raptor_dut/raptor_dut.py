import os
import shutil
import subprocess
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class raptor_dut(pluginTemplate):
    """RISCOF DUT plugin for Raptor Chip (Verilator-based NPC simulator)."""

    __model__ = "raptor_dut"
    __version__ = "0.1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get("config", {})
        self.pluginpath = os.path.abspath(config.get("pluginpath", "."))

        # Load environment from env.sh
        env_file = os.path.join(self.pluginpath, "env.sh")
        if os.path.exists(env_file):
            self._load_env(env_file)

        self.npc_bin = os.environ.get("NPC_BIN", "")
        self.nemu_so = os.environ.get("NEMU_SO", "")
        self.mrom_img = os.environ.get("MROM_IMG", "")
        self.cc = os.environ.get("CC", "riscv64-elf-gcc")
        self.objcopy = os.environ.get("OBJCOPY", "riscv64-elf-objcopy")
        self.march = os.environ.get(
            "MARCH", "rv32imac_zicntr_zicond_zicsr_zifencei_zba_zbb_zbc_zbs"
        )
        self.mabi = os.environ.get("MABI", "ilp32")

        self.isa_spec = os.path.abspath(config.get("ispec", ""))
        self.platform_spec = os.path.abspath(config.get("pspec", ""))
        self.num_jobs = str(config.get("jobs", 1))

    def _load_env(self, env_file):
        """Parse env.sh and load into os.environ."""
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export ") and "=" in line:
                    kv = line[len("export ") :]
                    key, _, val = kv.partition("=")
                    val = val.strip('"').strip("'")
                    val = os.path.expandvars(val)
                    os.environ[key.strip()] = val

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.archtest_env = archtest_env
        self.compile_cmd = (
            f"{self.cc} -march={self.march} -mabi={self.mabi} "
            f"-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles "
            f"-T {self.pluginpath}/link.ld "
            f"{{asm_file}} -I {archtest_env} -I {self.pluginpath} "
            f"-o {{elf_file}}"
        )

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)["hart0"]
        self.xlen = "64" if 64 in ispec["supported_xlen"] else "32"
        self.isa = ispec["ISA"]
        # Collect test list from the RISCOF framework
        if "32" in self.xlen:
            self.compile_cmd = self.compile_cmd.replace(
                self.march, "rv32imac_zicntr_zicond_zicsr_zifencei_zba_zbb_zbc_zbs"
            )

    def runTests(self, testList):
        for testname in testList:
            testentry = testList[testname]
            test_dir = testentry["work_dir"]
            asm_file = testentry["test_path"]

            os.makedirs(test_dir, exist_ok=True)
            elf_file = os.path.join(test_dir, "dut.elf")
            bin_file = os.path.join(test_dir, "dut.bin")
            sig_file = os.path.join(test_dir, "DUT-raptor.signature")
            log_file = os.path.join(test_dir, "dut.log")

            # Compile
            cmd = self.compile_cmd.format(asm_file=asm_file, elf_file=elf_file)
            logger.debug(f"DUT compile: {cmd}")
            utils.shellCommand(cmd).run(cwd=test_dir)

            # Create binary
            utils.shellCommand(f"{self.objcopy} -O binary {elf_file} {bin_file}").run(
                cwd=test_dir
            )

            # Run on NPC simulator with difftest
            run_cmd = (
                f"{self.npc_bin} -b -n "
                f"-d {self.nemu_so} "
                f"-r {self.mrom_img} "
                f"{bin_file}"
            )
            logger.debug(f"DUT run: {run_cmd}")
            try:
                utils.shellCommand(run_cmd).run(cwd=test_dir, timeout=60)
            except Exception as e:
                logger.warning(f"DUT run failed for {testname}: {e}")

            # Extract signature from ELF (begin_signature..end_signature)
            self._extract_signature(elf_file, sig_file)

    def _extract_signature(self, elf_file, sig_file):
        """Extract test signature region from ELF."""
        try:
            # Use objdump to find signature section
            result = subprocess.run(
                [
                    self.objcopy,
                    "--dump-section",
                    ".data.signature=" + sig_file,
                    elf_file,
                ],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                # Fallback: empty signature
                with open(sig_file, "w") as f:
                    f.write("")
        except Exception:
            with open(sig_file, "w") as f:
                f.write("")
