"""Execute real S-mode CBOs with/without the startup fix, on both XLENs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

LITEX = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include "cmo_init.h"
.option norelax
.section .text
.global _start
_start:
    lla t0, trap
    csrw mtvec, t0
    csrw 0x30a, zero
#ifdef ENABLE_CMO
    raptor_enable_cmo
#endif
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 15
    csrw pmpcfg0, t0
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x800
    csrs mstatus, t0
    lla t0, supervisor
    csrw mepc, t0
    mret
supervisor:
    lla a0, line
faulting_flush:
    .word 0x0025200f /* exact faulting instruction: cbo.flush (a0) */
    .word 0x0015200f /* cbo.clean (a0) */
    .word 0x0005200f /* cbo.inval (a0) */
#ifdef ENABLE_CMO
    j pass
#else
    j fail
#endif
.balign 4
trap:
#ifndef ENABLE_CMO
    csrr t0, mcause
    li t1, 2
    bne t0, t1, fail
    /* QEMU reports zero mtval here; Raptor reports the instruction bits. */
    csrr t0, mepc
    lla t1, faulting_flush
    bne t0, t1, fail
    j pass
#endif
fail:
    li t1, 0x13333
    j finish
pass:
    li t1, 0x5555
finish:
    li t0, 0x100000
    sw t1, 0(t0)
    j finish
.balign 64
line:
    .space 64
'''


class CmoStartupTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('riscv64-linux-gnu-gcc') and
                         shutil.which('qemu-system-riscv32') and shutil.which('qemu-system-riscv64'),
                         'requires RISC-V GCC and both QEMU system emulators')
    def test_permission_fault_and_fixed_supervisor_cache_operations(self):
        with tempfile.TemporaryDirectory(prefix='raptor-chip-cmo-test-', dir='/tmp') as tmp:
            root = Path(tmp)
            source = root / 'probe.S'
            source.write_text(SOURCE)
            for bits in (32, 64):
                for enabled in (False, True):
                    with self.subTest(bits=bits, enabled=enabled):
                        elf = root / f'probe-{bits}-{enabled}.elf'
                        command = ['riscv64-linux-gnu-gcc', f'-march=rv{bits}imac_zicsr_zifencei',
                                   '-mabi=' + ('ilp32' if bits == 32 else 'lp64'),
                                   '-nostdlib', '-static', '-fno-pic', '-no-pie',
                                   '-Wl,--build-id=none,-Ttext=0x80000000',
                                   '-I' + str(LITEX / 'firmware/linux-fpga'), '-o', str(elf), str(source)]
                        if enabled:
                            command.append('-DENABLE_CMO')
                        subprocess.run(command, check=True, capture_output=True)
                        result = subprocess.run([f'qemu-system-riscv{bits}', '-M', 'virt',
                            '-cpu', f'rv{bits},zicbom=true', '-m', '128M', '-bios', 'none',
                            '-nographic', '-monitor', 'none', '-device', f'loader,file={elf},cpu-num=0'],
                            capture_output=True, timeout=15)
                        self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
