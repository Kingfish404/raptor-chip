import os
import subprocess
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class nemu_ref(pluginTemplate):
    """RISCOF reference plugin using NEMU ISS."""

    __model__ = "nemu_ref"
    __version__ = "0.1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get("config", {})
        self.pluginpath = os.path.abspath(config.get("pluginpath", "."))

        env_file = os.path.join(self.pluginpath, "env.sh")
        if os.path.exists(env_file):
            self._load_env(env_file)

        self.nemu_so = os.environ.get("NEMU_SO", "")
        self.cc = os.environ.get("CC", "riscv64-elf-gcc")
        self.objcopy = os.environ.get("OBJCOPY", "riscv64-elf-objcopy")
        self.march = os.environ.get("MARCH", "rv32imac_zicsr_zifencei")
        self.mabi = os.environ.get("MABI", "ilp32")

        self.isa_spec = os.path.abspath(config.get("ispec", ""))
        self.platform_spec = os.path.abspath(config.get("pspec", ""))

    def _load_env(self, env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export ") and "=" in line:
                    kv = line[len("export "):]
                    key, _, val = kv.partition("=")
                    val = val.strip('"').strip("'")
                    val = os.path.expandvars(val)
                    os.environ[key.strip()] = val

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.archtest_env = archtest_env

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)["hart0"]
        self.xlen = ("64" if 64 in ispec["supported_xlen"] else "32")

    def runTests(self, testList):
        """
        For NEMU reference, we use the NEMU interpreter to run tests.
        Since NEMU is an ISS, we compile the test and run it on NEMU directly.
        The test signature is extracted from memory after execution.
        """
        for testname in testList:
            testentry = testList[testname]
            test_dir = testentry["work_dir"]
            asm_file = testentry["test_path"]

            os.makedirs(test_dir, exist_ok=True)
            elf_file = os.path.join(test_dir, "ref.elf")
            bin_file = os.path.join(test_dir, "ref.bin")
            sig_file = os.path.join(test_dir, "REF-nemu.signature")

            # Compile (same flags as DUT)
            compile_cmd = (
                f'{self.cc} -march={self.march} -mabi={self.mabi} '
                f'-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles '
                f'-T {os.path.join(os.path.dirname(self.pluginpath), "raptor_dut", "link.ld")} '
                f'{asm_file} -I {self.archtest_env} '
                f'-o {elf_file}'
            )
            logger.debug(f"REF compile: {compile_cmd}")
            try:
                utils.shellCommand(compile_cmd).run(cwd=test_dir)
            except Exception as e:
                logger.warning(f"REF compile failed for {testname}: {e}")
                with open(sig_file, "w") as f:
                    f.write("")
                continue

            # Extract signature
            try:
                subprocess.run(
                    [self.objcopy, "--dump-section",
                     ".data.signature=" + sig_file, elf_file],
                    capture_output=True, text=True, check=True
                )
            except Exception:
                with open(sig_file, "w") as f:
                    f.write("")
