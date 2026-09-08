#!/usr/bin/env python3
"""Compile real trap entry with deterministic architectural CSR inputs."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path)
p.add_argument('--sanitize',action='store_true')
a=p.parse_args()
for xlen in (32,64):
    with tempfile.TemporaryDirectory(prefix='nemu-traps-') as temp:
        work=Path(temp);(work/'generated').mkdir()
        (work/'generated/autoconf.h').write_text(
            '#define CONFIG_ISA_riscv 1\n'+
            ('#define CONFIG_ISA64 1\n#define CONFIG_RV64 1\n' if xlen==64 else ''))
        command=['cc','-std=gnu11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-parameter',
            '-D__GUEST_ISA__=riscv','-I'+str(work),'-I'+str(root/'nemu/include'),
            '-I'+str(root/'nemu/src/isa/riscv/include'),
            str(a.source or root/'nemu/src/isa/riscv/system/intr.c'),
            str(root/'app/tests/host/nemu_trap_delegation.c'),'-o',str(work/'test')]
        if a.sanitize:command+=['-fsanitize=undefined','-fno-sanitize-recover=all']
        subprocess.run(command,check=True)
        subprocess.run([str(work/'test')],check=True)
