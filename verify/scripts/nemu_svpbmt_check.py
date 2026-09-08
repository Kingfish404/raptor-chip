#!/usr/bin/env python3
"""Build the actual Sv39 walker with deterministic physical memory/PMP inputs."""
import argparse
from pathlib import Path
import subprocess
import tempfile

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc', default='cc')
    p.add_argument('--source', type=Path, help='Alternate walker for negative comparison')
    p.add_argument('--access', action='store_true', help='Exercise production vaddr and software TLB too')
    p.add_argument('--access-source', type=Path, help='Alternate vaddr implementation for a negative comparison')
    args = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='raptor-pbmt-walk-') as tmp:
        work = Path(tmp)
        (work/'generated').mkdir()
        (work/'generated/autoconf.h').write_text('''#define CONFIG_ISA64 1
#define CONFIG_RV64 1
#define CONFIG_RV_SVADE 1
#define CONFIG_RAPTOR_MEMORY_MAP 1
#define CONFIG_MBASE 0x80000000ull
#define CONFIG_MSIZE 0x10000000ull
#define CONFIG_PC_RESET_OFFSET 0
''')
        extra = [str(args.access_source or root/'nemu/src/memory/vaddr.c'), str(root/'nemu/src/cpu/icache.c')] if args.access else []
        test = 'nemu_svpbmt_access.c' if args.access else 'nemu_svpbmt_walk.c'
        exe = work/'walk'
        subprocess.run([args.cc, '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter',
                        '-D__GUEST_ISA__=riscv', '-I'+str(work), '-I'+str(root/'nemu/include'),
                        '-I'+str(root/'nemu/src/isa/riscv/include'),
                        str(args.source or root/'nemu/src/isa/riscv/system/mmu.c'),
                        str(root/'app/tests/host'/test), *extra, '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
    return 0
if __name__ == '__main__':
    raise SystemExit(main())
