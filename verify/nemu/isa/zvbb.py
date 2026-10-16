"""Check opt-in Zvbb encodings against independent per-element bit oracles."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path

from isa.vector_data import VectorAPI, VectorState, instruction
from lib.reference import ISAAPI, Reference


OPERATIONS = (
    ('vandn.vv', 0x01, 0, 16), ('vandn.vx', 0x01, 4, 5),
    ('vbrev8.v', 0x12, 2, 8), ('vrev8.v', 0x12, 2, 9),
    ('vbrev.v', 0x12, 2, 10), ('vclz.v', 0x12, 2, 12),
    ('vctz.v', 0x12, 2, 13), ('vcpop.v', 0x12, 2, 14),
    ('vror.vv', 0x14, 0, 16), ('vror.vx', 0x14, 4, 5),
    ('vror.vi', 0x14, 3, 31), ('vror.vi-high', 0x15, 3, 5),
    ('vrol.vv', 0x15, 0, 16), ('vrol.vx', 0x15, 4, 5),
    ('vwsll.vv', 0x35, 0, 16), ('vwsll.vx', 0x35, 4, 5),
    ('vwsll.vi', 0x35, 3, 31),
)


def expected_value(name, value, operand, bits):
    mask = (1 << bits) - 1
    if name.startswith('vandn'):
        return value & ~operand & mask
    if name == 'vbrev.v':
        return int(f'{value:0{bits}b}'[::-1], 2)
    if name == 'vbrev8.v':
        return int.from_bytes(bytes(int(f'{byte:08b}'[::-1], 2)
                                    for byte in value.to_bytes(bits // 8, 'little')), 'little')
    if name == 'vrev8.v':
        return int.from_bytes(value.to_bytes(bits // 8, 'little')[::-1], 'little')
    if name == 'vclz.v':
        return bits - value.bit_length()
    if name == 'vctz.v':
        return bits if not value else (value & -value).bit_length() - 1
    if name == 'vcpop.v':
        return value.bit_count()
    if name.startswith('vwsll'):
        return value << (operand & (2 * bits - 1)) & ((1 << (2 * bits)) - 1)
    shift = operand & (bits - 1)
    if not shift:
        return value
    if name.startswith('vrol'):
        return ((value << shift) | (value >> (bits - shift))) & mask
    return ((value >> shift) | (value << (bits - shift))) & mask


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    library = ctypes.CDLL(str(args.reference.resolve()))
    isa_query = library.nemu_difftest_isa_query
    isa_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    isa_query.restype = ctypes.POINTER(ISAAPI)
    api = isa_query(1, ctypes.sizeof(ISAAPI)).contents
    vector_query = library.nemu_difftest_vector_query
    vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    vector_query.restype = ctypes.POINTER(VectorAPI)
    vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
    failures = []
    cases = 0

    def check(name, actual, expected):
        nonlocal cases
        cases += 1
        if actual != expected:
            failures.append(dict(name=name, actual=actual, expected=expected))

    check('zvbb-requires-v128', api.configure(1 << 7), -1)
    check('failed-config-preserves-mask', api.enabled, 0)
    check('configure', api.configure((1 << 6) | (1 << 7)), 0)
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state
    state.gpr[4] = 0x200
    reference.run([(0x300 << 20) | (4 << 15) | (2 << 12) | 0x73])
    check('config-locked', api.configure(1 << 6), -1)
    check('misa-v', bool(state.misa[0] & (1 << 21)), True)

    for sew in range(4):
        width = 1 << sew
        bits = width * 8
        for lmul in (0, 1, 7):
            if sew == 3 and lmul == 7:
                continue
            vtype = 0xc0 | (sew << 3) | lmul
            for masked, start in ((False, 0), (True, 0), (False, 1)):
                state.gpr[1] = 3
                state.gpr[2] = vtype
                reference.run([0x8020f1d7])
                vl = state.gpr[3]
                for name, function, form, source1 in OPERATIONS:
                    if name.startswith('vwsll') and sew == 3:
                        continue
                    seeded = VectorState()
                    for reg in range(32):
                        for byte in range(16):
                            seeded.reg[reg][byte] = (reg * 13 + byte * 29 + sew * 47) & 255
                    seeded.reg[0][0] = 0b0101
                    for reg in (8, 16):
                        for index in range(16):
                            seeded.reg[reg][index] = (index * 37 + reg * 9) & 255
                    check(f'{name}-seed', vector_api.set_state(0, ctypes.byref(seeded)), 0)
                    state.gpr[5] = 0x9abcdef3 & reference.mask
                    state.gpr[4] = start
                    reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
                    raw = bytearray(byte for reg in seeded.reg for byte in reg)
                    expected = raw.copy()
                    scalar = state.gpr[5]
                    if scalar & (1 << (args.xlen - 1)):
                        scalar -= 1 << args.xlen
                    for index in range(start, vl):
                        if masked and not raw[index // 8] & (1 << (index % 8)):
                            continue
                        offset = 8 * 16 + index * width
                        value = int.from_bytes(raw[offset:offset + width], 'little')
                        if form == 0:
                            source_offset = 16 * 16 + index * width
                            operand = int.from_bytes(raw[source_offset:source_offset + width], 'little')
                        elif form == 3:
                            operand = source1 | (32 if name == 'vror.vi-high' else 0)
                        else:
                            operand = scalar
                        result = expected_value(name, value, operand, bits)
                        output_width = width * (2 if name.startswith('vwsll') else 1)
                        destination = 24 * 16 + index * output_width
                        expected[destination:destination + output_width] = result.to_bytes(output_width, 'little')
                    code = instruction(function, int(not masked), 8, source1, form, 24)
                    pc = reference.run([code])
                    check(f'{name}-pc-e{bits}-l{lmul}-m{masked}-s{start}', state.pc[0], pc + 4)
                    observed = VectorState()
                    check(f'{name}-read', vector_api.get_state(0, ctypes.byref(observed)), 0)
                    actual = bytes(byte for reg in observed.reg for byte in reg)
                    check(f'{name}-state-e{bits}-l{lmul}-m{masked}-s{start}', actual.hex(), expected.hex())
                    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
                    check(f'{name}-vstart', state.gpr[3], 0)

    def vset(vtype):
        state.gpr[1] = 3
        state.gpr[2] = vtype
        reference.run([0x8020f1d7])

    def illegal(name, code):
        before = VectorState()
        vector_api.get_state(0, ctypes.byref(before))
        before_bytes = bytes(byte for reg in before.reg for byte in reg)
        pc = reference.run([code])
        check(name + '-trap', [state.mcause[0], state.mepc[0]], [2, pc])
        after = VectorState()
        vector_api.get_state(0, ctypes.byref(after))
        check(name + '-vector', bytes(byte for reg in after.reg for byte in reg), before_bytes)

    vset(0xc8)
    illegal('widen-destination-alignment', instruction(0x35, 1, 8, 3, 3, 25))
    illegal('widen-low-overlap', instruction(0x35, 1, 8, 3, 3, 8))
    illegal('masked-destination-v0', instruction(0x12, 0, 8, 8, 2, 0))
    seeded = VectorState()
    seeded.reg[9][0] = 3
    check('widen-high-overlap-seed', vector_api.set_state(0, ctypes.byref(seeded)), 0)
    pc = reference.run([instruction(0x35, 1, 9, 3, 3, 8)])
    check('widen-high-overlap-pc', state.pc[0], pc + 4)
    observed = VectorState()
    vector_api.get_state(0, ctypes.byref(observed))
    check('widen-high-overlap-value', list(observed.reg[8][:2]), [24, 0])
    vset(0xc1)
    illegal('lmul2-source-alignment', instruction(0x01, 1, 9, 16, 0, 24))
    vset(0xd8)
    illegal('widen-e64', instruction(0x35, 1, 8, 3, 3, 24))

    report = dict(xlen=args.xlen, cases=cases, failures=failures,
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest())
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure['name'], str(failure['actual'])[:100],
              str(failure['expected'])[:100])
    print(f'NEMU_ZVBB xlen={args.xlen} cases={cases} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
