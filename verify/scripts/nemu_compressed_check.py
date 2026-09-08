#!/usr/bin/env python3
"""Compare the production C decoder for both XLENs with the C 2.0 oracle."""
import ctypes as C
from pathlib import Path
import subprocess
import tempfile
from compressed_vectors import expand


def main():
    root=Path(__file__).resolve().parents[2]
    for xlen in (32,64):
        with tempfile.TemporaryDirectory(prefix='nemu-compressed-') as directory:
            out=Path(directory);(out/'generated').mkdir()
            (out/'generated/autoconf.h').write_text('#define CONFIG_ISA_riscv 1\n'+
                ('#define CONFIG_RV64 1\n#define CONFIG_ISA64 1\n' if xlen==64 else ''))
            libpath=out/'decoder.so'
            subprocess.run(['cc','-std=gnu11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-parameter',
                            '-shared','-fPIC','-D__GUEST_ISA__=riscv','-I'+str(out),'-I'+str(root/'nemu/include'),
                            '-I'+str(root/'nemu/src/isa/riscv/include'),
                            str(root/'nemu/src/isa/riscv/inst_c.c'),str(root/'nemu/src/isa/riscv/inst_c_ref.c'),
                            '-o',str(libpath)],check=True)
            lib=C.CDLL(str(libpath));lib.decompress_c.argtypes=[C.c_uint32];lib.decompress_c.restype=C.c_uint32
            checked=excluded=0
            for insn in range(65536):
                if insn&3==3:continue
                kind,expected,name=expand(insn,xlen)
                if kind==4:excluded+=1;continue
                actual=lib.decompress_c(insn)
                allowed={expected}
                if kind==2:allowed.add(0x13)
                # RV32 custom/reserved shift parcels may expand to an
                # illegal 32-bit shift instead of the zero sentinel.
                if kind==1 and xlen==32 and actual&0x7f==0x13:
                    f3=(actual>>12)&7;f7=actual>>25
                    if (f3==1 and f7!=0) or (f3==5 and f7 not in (0,32)):
                        allowed.add(actual)
                if actual not in allowed:
                    raise AssertionError(f'RV{xlen} {name} {insn:04x}: {actual:08x}, expected {expected:08x}')
                checked+=1
            print(f'PASS RV{xlen}: {checked} C encodings; {excluded} optional Zcb encodings outside C scope')


if __name__=='__main__':main()
