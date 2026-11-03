"""riscv-tests/debug target adapter for the production-chip bitbang harness."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import time

import targets


class RaptorHart(targets.Hart):
    xlen = int(os.environ.get('RAPT_UPSTREAM_XLEN', '32'))
    misa = (1 if xlen == 32 else 2) << (xlen - 2) | 0x14112f
    ram = 0x80000000
    ram_size = 0x100000
    reset_vectors = [0x20000000]
    instruction_hardware_breakpoint_count = 0
    progbufsize = 0


class ChipProcess:
    def __init__(self, command):
        self.output = tempfile.NamedTemporaryFile(prefix='raptor-chip-', suffix='.log',
                                                  delete=False)
        self.lognames = [self.output.name]
        self.process = subprocess.Popen(shlex.split(command), stdout=self.output,
                                        stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 30
        while 'waiting for OpenOCD' not in Path(self.output.name).read_text():
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('chip server failed to start: ' + self.output.name)
            time.sleep(0.05)

    def __del__(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.output.close()


class Raptor(targets.Target):
    harts = [RaptorHart()]
    openocd_config_path = str(Path(__file__).with_name('upstream.cfg'))
    link_script = str(Path(__file__).with_name('upstream.lds'))
    timeout_sec = 30
    support_hasel = False
    support_manual_hwbp = False
    support_memory_sampling = False
    support_mcontrol = False
    support_mcontrol6 = False
    support_icount = False
    support_itrigger = False
    support_etrigger = False
    test_semihosting = False
    # Without symbols, GDB can otherwise scan unmapped addresses while finding
    # a frame for a memory assignment at the reset ROM. Declare the test map.
    gdb_setup = [
        f'set architecture riscv:rv{RaptorHart.xlen}',
        'set osabi none',
        'set language c',
        'mem 0x20000000 0x20001000 ro',
        'mem 0x80000000 0x80100000 rw',
        'set mem inaccessible-by-default on',
        'set breakpoint auto-hw off',
    ] + ([
        # GDB's RV32 register-indirect step can sign-extend a target internally,
        # even though its remote packet carries the same 32-bit physical address.
        'mem 0xffffffff80000000 0xffffffff80100000 rw',
    ] if RaptorHart.xlen == 32 else [])

    def __init__(self, path, parsed):
        self.harts[0].link_script_path = self.link_script
        super().__init__(path, parsed)

    def create(self):
        return ChipProcess(self.sim_cmd)

    def compile(self, hart, *sources):
        # Upstream supplies its own entry and initialization code. The selected
        # assembly payload does not require a hosted C library or startup files.
        return super().compile(hart, *sources, '-nostdlib', '-fno-builtin')
