#!/usr/bin/env python3
"""Check explicit low-counter CSR write ordering through the NEMU shared API.

NPCState begins with this pointer prefix (sim/include/common.h and NEMU ref.c).
The API writes the full state into a generously sized buffer; only the prefix
is accessed here. Each case uses a distinct PC to avoid stale decode-cache hits.
This checks reference semantics, not physical hardware cycle counts.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--high-half', action='store_true', help='RV32 high write versus low carry')
    a = p.parse_args()
    if a.high_half and a.xlen != 32:
        p.error('--high-half requires --xlen 32')
    word = C.c_uint64 if a.xlen == 64 else C.c_uint32

    class Prefix(C.Structure):
        _fields_ = [('state', C.c_int), ('host_exit_ok', C.c_uint8),
                    ('gpr', C.POINTER(word)), ('ret', C.POINTER(word)),
                    ('pc', C.POINTER(word)), ('priv', C.POINTER(C.c_char))]

    n = C.CDLL(str(a.reference.resolve()))
    n.difftest_init.argtypes = [C.c_int]
    n.difftest_init(0)
    n.difftest_regcpy.argtypes = [C.c_void_p, C.c_bool]
    storage = C.create_string_buffer(4096)
    n.difftest_regcpy(storage, False)
    state = C.cast(storage, C.POINTER(Prefix)).contents
    n.difftest_memcpy.argtypes = [C.c_uint64, C.c_void_p, C.c_size_t, C.c_bool]
    n.difftest_exec.argtypes = [C.c_uint64]
    rows = []
    base = 7 if a.high_half else 100
    for csr in ((0xb80, 0xb82) if a.high_half else (0xb00, 0xb02)):
        for f in (1, 2, 3, 5, 6, 7):
            source = 5 if a.high_half else 2
            for field, reg_value in ((0, 0), (source, 0), (source, 1), (31, 31)):
                pc = 0x80000000 + len(rows) * 0x100
                state.pc[0] = pc
                for i in range(32):
                    state.gpr[i] = 0
                state.gpr[1] = base
                if a.high_half:
                    state.gpr[2] = 0xffffffff
                if field:
                    state.gpr[field] = reg_value
                insn = (csr << 20) | (field << 15) | (f << 12) | (3 << 7) | 0x73
                setup = [(csr << 20) | 0x9073]
                if a.high_half:
                    setup.append(((csr - 0x80) << 20) | 0x11073)
                words = setup + [insn, (csr << 20) | 0x2273]
                program = (C.c_uint32 * len(words))(*words)
                n.difftest_memcpy(pc, program, C.sizeof(program), True)
                n.difftest_exec(len(words))
                value = field if f >= 5 else reg_value
                writes = (f & 3) == 1 or field != 0
                new = value if (f & 3) == 1 else base | value if (f & 3) == 2 else base & ~value
                expected = [base, new if writes else base + 1]
                actual = [state.gpr[3], state.gpr[4]]
                rows.append({'csr': csr, 'funct3': f, 'field': field,
                             'register_value': reg_value, 'pc': pc,
                             'instructions': list(program), 'expected': expected,
                             'actual': actual, 'passed': actual == expected})
    result = {'xlen': a.xlen, 'reference': str(a.reference.resolve()),
              'reference_sha256': hashlib.sha256(a.reference.read_bytes()).hexdigest(),
              'checker_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'scope': ('RV32 high MCYCLE/MINSTRET write versus low-half carry' if a.high_half else
                        'low MCYCLE/MINSTRET explicit-write versus implicit-increment semantics; other counter and trap behavior separate'),
              'cases': rows}
    a.output.write_text(json.dumps(result, indent=2) + '\n')
    failures = sum(not r['passed'] for r in rows)
    print(f'RV{a.xlen}: {len(rows)} reference counter cases, {failures} failures')
    return int(failures != 0)


if __name__ == '__main__':
    raise SystemExit(main())
