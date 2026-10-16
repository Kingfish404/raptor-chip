"""Exercise single-hart RVA23 vector misalignment and split-page fault restart."""

import argparse
import ctypes
import json
from pathlib import Path

from isa.vector_data import (VectorAPI, VectorState, fof_instruction,
                            indexed_instruction, memory_instruction,
                            segment_instruction, strided_instruction)
from lib.reference import ISAAPI, Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.reference.resolve()))
    isa_query = library.nemu_difftest_isa_query
    isa_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    isa_query.restype = ctypes.POINTER(ISAAPI)
    api = isa_query(1, ctypes.sizeof(ISAAPI)).contents
    if api.xlen != 64 or api.configure(api.supported):
        raise RuntimeError('RVA23 vector misalignment requires the RV64 reference')
    vector_query = library.nemu_difftest_vector_query
    vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    vector_query.restype = ctypes.POINTER(VectorAPI)
    vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
    reference = Reference(args.reference, 64)
    reference.reset()
    state = reference.state
    checks = []

    def check(name, actual, expected):
        checks.append(dict(name=name, actual=actual, expected=expected,
                           passed=actual == expected))

    def csr_write(csr, value):
        state.gpr[4] = value
        reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def csr_read(csr):
        reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3]

    def configure(sew, length):
        state.mstatus[0] |= 0x200
        state.gpr[1] = length
        reference.run([((0xc0 | (sew << 3)) << 20) | (1 << 15) |
                       (7 << 12) | (3 << 7) | 0x57])
        state.mcause[0] = 0

    def seed():
        vector = VectorState()
        ctypes.memset(ctypes.byref(vector), 0xa5, ctypes.sizeof(vector))
        vector.reg[0][0] = 0x0a
        vector.reg[16][:4] = (ctypes.c_uint8 * 4)(8, 0, 24, 16)
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        return vector

    def registers():
        vector = VectorState()
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        return vector

    base = 0x81000000
    payload = bytes(range(64))
    for sew in (1, 2, 3):
        element_bytes = 1 << sew
        for offset in range(1, element_bytes):
            name = f'e{8 * element_bytes}-offset-{offset}'
            reference.write(base, payload)
            configure(sew, 16 // element_bytes)
            seed()
            state.gpr[1] = base + offset
            pc = reference.run([memory_instruction(False, 4 + sew, 1, 1, 8)])
            check(f'{name}-load-pc', state.pc[0], pc + 4)
            check(f'{name}-load-data', list(registers().reg[8]),
                  list(payload[offset:offset + 16]))
            reference.write(base + 128, bytes([0xee] * 32))
            state.gpr[1] = base + 128 + offset
            pc = reference.run([memory_instruction(True, 4 + sew, 1, 1, 8)])
            check(f'{name}-store-pc', state.pc[0], pc + 4)
            check(f'{name}-store-data', reference.read(base + 128, 32).hex(),
                  (bytes([0xee] * offset) + payload[offset:offset + 16] +
                   bytes([0xee] * (16 - offset))).hex())

    for name, opcode, offsets in (
        ('strided', strided_instruction(False, 6, 1, 1, 2, 8), (0, 7, 14, 21)),
        ('indexed', indexed_instruction(False, 0, 1, 1, 16, 8), (8, 0, 24, 16)),
    ):
        configure(2, 4)
        seed()
        state.gpr[1] = base + 1
        state.gpr[2] = 7
        pc = reference.run([opcode])
        check(f'{name}-load-pc', state.pc[0], pc + 4)
        expected = b''.join(payload[offset + 1:offset + 5] for offset in offsets)
        check(f'{name}-load-data', bytes(registers().reg[8]).hex(), expected.hex())
        for masked in (False, True):
            reference.write(base + 128, bytes([0xee] * 64))
            state.gpr[1] = base + 129
            csr_write(0x008, 1 if masked else 0)
            store = (opcode | 0x20) & (~(1 << 25) if masked else 0xffffffff)
            pc = reference.run([store])
            check(f'{name}-store-{masked}-pc', state.pc[0], pc + 4)
            expected_memory = bytearray([0xee] * 64)
            for index in ((1, 3) if masked else range(4)):
                offset = offsets[index] + 1
                expected_memory[offset:offset + 4] = expected[index * 4:index * 4 + 4]
            check(f'{name}-store-{masked}-data', reference.read(base + 128, 64).hex(),
                  expected_memory.hex())
            check(f'{name}-store-{masked}-vstart', csr_read(0x008), 0)

    for sew in (1, 2, 3):
        element_bytes = 1 << sew
        length = 16 // element_bytes
        configure(sew, length)
        seed()
        state.gpr[1] = base + 1
        pc = reference.run([segment_instruction(False, 4 + sew, 2, 1, 1, 8)])
        check(f'segment-e{element_bytes * 8}-load-pc', state.pc[0], pc + 4)
        for field in (0, 1):
            expected = b''.join(payload[1 + (index * 2 + field) * element_bytes:
                                        1 + (index * 2 + field + 1) * element_bytes]
                                for index in range(length))
            check(f'segment-e{element_bytes * 8}-field-{field}',
                  bytes(registers().reg[8 + field]).hex(), expected.hex())
        reference.write(base + 128, bytes([0xee] * 34))
        state.gpr[1] = base + 129
        pc = reference.run([segment_instruction(True, 4 + sew, 2, 1, 1, 8)])
        check(f'segment-e{element_bytes * 8}-store-pc', state.pc[0], pc + 4)
        check(f'segment-e{element_bytes * 8}-store-data', reference.read(base + 128, 34).hex(),
              (b'\xee' + payload[1:33] + b'\xee').hex())

    root, middle, leaf = 0x82000000, 0x82001000, 0x82002000
    virtual, second = 0x40000000, 0x81200000
    for table in (root, middle, leaf):
        reference.write(table, bytes(4096))

    def pte(address, value):
        reference.write(address, value.to_bytes(8, 'little'))
        reference.run([0x12000073])

    pte(root + 8, ((middle >> 12) << 10) | 1)
    pte(middle, ((leaf >> 12) << 10) | 1)
    pte(leaf, ((base >> 12) << 10) | 0xc7)
    pte(leaf + 8, ((second >> 12) << 10) | 0xc7)
    state.satp[0] = (8 << 60) | (root >> 12)

    def supervisor_data():
        state.mstatus[0] = (state.mstatus[0] & ~(3 << 11)) | (1 << 17) | (1 << 11)

    reference.write(base + 4093, b'\x11\x22\x33')
    reference.write(second, b'\x44\x55\x66\x77\x88')
    configure(2, 2)
    seed()
    supervisor_data()
    state.gpr[1] = virtual + 4093
    pc = reference.run([memory_instruction(False, 6, 1, 1, 8)])
    check('split-load-pc', state.pc[0], pc + 4)
    check('split-load-data', list(registers().reg[8][:8]),
          [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

    vector = seed()
    vector.reg[8][:8] = (ctypes.c_uint8 * 8)(1, 2, 3, 4, 5, 6, 7, 8)
    if vector_api.set_state(0, ctypes.byref(vector)):
        raise RuntimeError('cannot seed split-store registers')
    pc = reference.run([memory_instruction(True, 6, 1, 1, 8)])
    check('split-store-pc', state.pc[0], pc + 4)
    check('split-store-data', (reference.read(base + 4093, 3) +
                              reference.read(second, 5)).hex(), '0102030405060708')

    for fault in ('unmapped', 'readonly', 'pmp'):
        pte(leaf + 8, 0 if fault == 'unmapped' else
            ((second >> 12) << 10) | (0xc3 if fault == 'readonly' else 0xc7))
        if fault == 'pmp':
            csr_write(0x3a0, 0)
            csr_write(0x3b0, (second >> 2) | 0x1ff)
            csr_write(0x3b1, reference.mask)
            csr_write(0x3a0, 0x1f18)
        reference.write(base + 4088, bytes([0x66] * 8))
        reference.write(second, bytes([0x77] * 8))
        configure(2, 1)
        seed()
        supervisor_data()
        state.gpr[1] = virtual + 4091
        pc = reference.run([segment_instruction(True, 6, 2, 1, 1, 8)])
        check(f'split-segment-{fault}-trap',
              [state.mcause[0], state.mepc[0], state.mtval[0]],
              [7 if fault == 'pmp' else 15, pc, virtual + 4096])
        check(f'split-segment-{fault}-memory',
              (reference.read(base + 4088, 8) + reference.read(second, 8)).hex(),
              (bytes([0x66] * 8) + bytes([0x77] * 8)).hex())
        check(f'split-segment-{fault}-vstart', csr_read(0x008), 0)
        if fault == 'pmp':
            csr_write(0x3a0, 0)
            csr_write(0x3b0, reference.mask)
            csr_write(0x3a0, 0x0f)

    for fof in (False, True):
        pte(leaf + 8, 0)
        reference.write(base + 4089, b'\x11\x22\x33\x44\x55\x66\x77')
        configure(2, 2)
        seed()
        supervisor_data()
        state.gpr[1] = virtual + 4089
        opcode = fof_instruction(6, 1, 1, 8) if fof else memory_instruction(False, 6, 1, 1, 8)
        pc = reference.run([opcode])
        check(f'split-load-later-{fof}-pc', state.pc[0], pc + 4 if fof else state.mtvec[0])
        check(f'split-load-later-{fof}-data', list(registers().reg[8][:8]),
              [0x11, 0x22, 0x33, 0x44, 0xa5, 0xa5, 0xa5, 0xa5])
        check(f'split-load-later-{fof}-vstart', csr_read(0x008), 0 if fof else 1)
        check(f'split-load-later-{fof}-vl', csr_read(0xc20), 1 if fof else 2)
        if not fof:
            check('split-load-later-tval', state.mtval[0], virtual + 4096)
            pte(leaf + 8, ((second >> 12) << 10) | 0xc7)
            reference.write(base + 4089, bytes([0x99] * 4))
            reference.write(second, b'\x88')
            supervisor_data()
            state.pc[0] = pc
            reference.lib.difftest_exec(1)
            check('split-load-restart-pc', state.pc[0], pc + 4)
            check('split-load-restart-data', list(registers().reg[8][:8]),
                  [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
            check('split-load-restart-vstart', csr_read(0x008), 0)

    configure(2, 2)
    vector = seed()
    vector.reg[0][0] = 1
    if vector_api.set_state(0, ctypes.byref(vector)):
        raise RuntimeError('cannot seed masked split-load registers')
    supervisor_data()
    state.gpr[1] = virtual + 4089
    pc = reference.run([memory_instruction(False, 6, 0, 1, 8)])
    check('split-masked-load-pc', state.pc[0], pc + 4)
    check('split-masked-load-data', list(registers().reg[8][:8]),
          [0x11, 0x22, 0x33, 0x44, 0xa5, 0xa5, 0xa5, 0xa5])
    check('split-masked-load-vl', csr_read(0xc20), 2)

    pte(leaf, ((base >> 12) << 10) | (2 << 61) | 0xc7)
    state.menvcfg[0] |= 1 << 62
    for store in (False, True):
        configure(2, 1)
        vector = seed()
        supervisor_data()
        state.gpr[1] = virtual + 1
        before = reference.read(base, 8)
        pc = reference.run([memory_instruction(store, 6, 1, 1, 8)])
        check(f'pbmt-io-{store}-access-fault',
              [state.mcause[0], state.mepc[0], state.mtval[0]],
              [7 if store else 5, pc, virtual + 1])
        check(f'pbmt-io-{store}-memory-unchanged', reference.read(base, 8).hex(), before.hex())
        check(f'pbmt-io-{store}-registers-unchanged', bytes(registers()).hex(), bytes(vector).hex())

    failures = [entry for entry in checks if not entry['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(cases=checks, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:10]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_MISALIGNED cases={len(checks)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
