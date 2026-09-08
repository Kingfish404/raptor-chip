#!/usr/bin/env python3
"""Exercise architectural counter/trap semantics through NEMU's shared API.

Uses the public NPCState pointer prefix, no copied interpreter implementation.
Run each reference in a fresh process. --architectural-ebreak requires a build
without the legacy CONFIG_RV_EBREAK_HOST_EXIT convention.
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
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--architectural-ebreak', action='store_true')
    mode.add_argument('--legacy-ebreak', choices=('normal', 'compressed'),
                      help='check the opt-in host-exit convention in a fresh process')
    a = p.parse_args()
    word = C.c_uint64 if a.xlen == 64 else C.c_uint32
    names = ('sstatus sie stvec scounteren mcounteren sscratch sepc scause stval '
             'sip satp mstatus misa medeleg mideleg mie mtvec menvcfg mstatush '
             'mscratch mepc mcause mtval mip mcycle mcycleh minstret minstreth time timeh').split()

    class State(C.Structure):
        _fields_ = [('state', C.c_int), ('host_exit_ok', C.c_uint8),
                    ('gpr', C.POINTER(word)), ('ret', C.POINTER(word)),
                    ('pc', C.POINTER(word)), ('priv', C.POINTER(C.c_char))] + [
                        (name, C.POINTER(word)) for name in names]

    lib = C.CDLL(str(a.reference.resolve()))
    lib.difftest_init.argtypes = [C.c_int]
    lib.difftest_regcpy.argtypes = [C.c_void_p, C.c_bool]
    lib.difftest_memcpy.argtypes = [word, C.c_void_p, C.c_size_t, C.c_bool]
    lib.difftest_exec.argtypes = [C.c_uint64]
    lib.difftest_init(0)
    storage = C.create_string_buffer(4096)
    lib.difftest_regcpy(storage, False)
    state = C.cast(storage, C.POINTER(State)).contents
    rows = []

    def reset():
        pc = 0x80000000 + 0x100 * len(rows)
        for name in names:
            if name != 'misa':
                getattr(state, name)[0] = 0
        state.mstatus[0] = 0xa00000000 if a.xlen == 64 else 0
        state.pc[0] = pc
        state.priv[0] = b'\x03'
        for i in range(32):
            state.gpr[i] = 0
        state.mtvec[0] = 0x800f0000
        state.mcycle[0] = 100
        state.minstret[0] = 100
        return pc

    def step(pc, insn):
        program = C.c_uint32(insn)
        lib.difftest_memcpy(pc, C.byref(program), 4, True)
        lib.difftest_exec(1)

    def record(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    traps = [('ecall', 0x73, 11, 0), ('illegal', 0xffffffff, 2, 0xffffffff),
             ('absent-csr', 0x777020f3, 2, 0x777020f3),
             ('readonly-write', 0xc00010f3, 2, 0xc00010f3),
             ('compressed-illegal', 0, 2, 0)]
    if a.architectural_ebreak:
        traps += [('ebreak', 0x00100073, 3, None), ('c.ebreak', 0x9002, 3, None)]
    for name, insn, cause, tval in traps:
        pc = reset()
        step(pc, insn)
        record(name, [state.minstret[0], state.mcause[0], state.mepc[0], state.mtval[0], state.pc[0]],
               [100, cause, pc, pc if tval is None else tval, 0x800f0000])
        # The first successful handler instruction must retire exactly once.
        step(0x800f0000, 0x13)
        record(name + '-handler', [state.minstret[0], state.pc[0]], [101, 0x800f0004])
    pc = reset()
    state.mtvec[0] = 0
    step(pc, 0xffffffff)
    record('zero-trap-vector', [state.pc[0], state.mcause[0], state.minstret[0]], [0, 2, 100])
    if a.xlen == 32:
        for name, csr, high in [('cycle', 0xb80, 'mcycleh'), ('instret', 0xb82, 'minstreth')]:
            low = 'mcycle' if name == 'cycle' else 'minstret'
            for value in (0, 100, 0xffffffff):
                pc = reset()
                getattr(state, low)[0] = 0xffffffff
                getattr(state, high)[0] = 7
                state.gpr[1] = value
                step(pc, (csr << 20) | 0x9073)
                # Either half writes the underlying 64-bit counter and
                # suppresses its implicit increment (also Spike's
                # rv32_high_csr_t -> wide_counter_csr_t write/bump contract).
                record(name + '-high-write-' + str(value),
                       [getattr(state, low)[0], getattr(state, high)[0]], [0xffffffff, value])
    if a.legacy_ebreak:
        pc = reset()
        state.gpr[10] = 7
        compressed = a.legacy_ebreak == 'compressed'
        step(pc, 0x9002 if compressed else 0x00100073)
        record('legacy-' + a.legacy_ebreak,
               [state.mcause[0], state.pc[0], state.gpr[10]],
               [0, pc + (2 if compressed else 4), 7])
        stopped_pc = state.pc[0]
        step(stopped_pc, 0x00100293)  # addi t0, zero, 1 must not execute after host exit
        record('legacy-halt-stops-execution', [state.pc[0], state.gpr[5]],
               [stopped_pc, 0])
    report = dict(xlen=a.xlen, reference_sha256=hashlib.sha256(a.reference.read_bytes()).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), cases=rows)
    a.output.write_text(json.dumps(report, indent=2) + '\n')
    failures = [r for r in rows if not r['passed']]
    for row in failures:
        print('FAIL', row)
    print(f'RV{a.xlen}: {len(rows)} counter/trap checks, {len(failures)} failures')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
