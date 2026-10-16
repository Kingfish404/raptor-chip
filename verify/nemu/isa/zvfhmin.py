"""Check opt-in Zvfhmin conversions, flags, masking and register geometry."""
import argparse
import ctypes
import hashlib
import json
import random
from pathlib import Path

from isa.vector_data import VectorAPI, VectorState, instruction
from lib.reference import ISAAPI, Reference


def words(vector, register, size, count):
    raw = bytes(byte for group in vector.reg[register:] for byte in group)
    return [int.from_bytes(raw[index * size:(index + 1) * size], 'little')
            for index in range(count)]


def half_to_single(bits):
    sign = (bits & 0x8000) << 16
    exponent = (bits >> 10) & 0x1f
    fraction = bits & 0x3ff
    if exponent == 0x1f:
        if fraction:
            return 0x7fc00000, 0 if fraction & 0x200 else 0x10
        return sign | 0x7f800000, 0
    if exponent:
        return sign | ((exponent + 112) << 23) | (fraction << 13), 0
    if not fraction:
        return sign, 0
    highest = fraction.bit_length() - 1
    return (sign | ((highest + 103) << 23) |
            ((fraction - (1 << highest)) << (23 - highest))), 0


def half_units(bits):
    exponent = bits >> 10
    fraction = bits & 0x3ff
    if exponent:
        return ((1 << 10) | fraction) << (exponent + 124)
    return fraction << 125


def tiny_after_rounding(magnitude, sign, rounding):
    minimum_normal = 1 << 135
    if magnitude >= minimum_normal:
        return False
    unbounded_step = 1 << 124
    if magnitude <= minimum_normal - unbounded_step:
        return True
    remainder = magnitude - (minimum_normal - unbounded_step)
    if rounding in (0, 4):
        rounds_up = remainder * 2 >= unbounded_step
    else:
        rounds_up = (rounding == 2 and sign) or (rounding == 3 and not sign)
    return not rounds_up


def single_to_half(bits, rounding):
    sign = bits >> 31
    exponent = (bits >> 23) & 0xff
    fraction = bits & 0x7fffff
    if exponent == 0xff:
        if fraction:
            return 0x7e00, 0 if fraction & 0x400000 else 0x10
        return (sign << 15) | 0x7c00, 0
    magnitude = ((1 << 23) | fraction) << (exponent - 1) if exponent else fraction
    maximum = half_units(0x7bff)
    if magnitude > maximum:
        toward_infinity = (rounding == 2 and sign) or (rounding == 3 and not sign)
        nearest_overflow = rounding in (0, 4) and magnitude >= (65520 << 149)
        overflow = toward_infinity or nearest_overflow or magnitude >= (65536 << 149)
        result = 0x7c00 if toward_infinity or nearest_overflow else 0x7bff
        return (sign << 15) | result, 0x5 if overflow else 0x1

    lower = 0
    upper = 0x7bff
    while lower <= upper:
        middle = (lower + upper) // 2
        if half_units(middle) < magnitude:
            lower = middle + 1
        else:
            upper = middle - 1
    if half_units(lower) == magnitude:
        return (sign << 15) | lower, 0
    if rounding in (0, 4):
        midpoint = half_units(upper) + half_units(lower)
        choose_upper = 2 * magnitude > midpoint or (
            2 * magnitude == midpoint and (rounding == 4 or upper & 1))
    else:
        choose_upper = (rounding == 2 and sign) or (rounding == 3 and not sign)
    result = lower if choose_upper else upper
    return (sign << 15) | result, 0x3 if tiny_after_rounding(magnitude, sign, rounding) else 0x1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--enable', action='store_true')
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
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    check('requires-v128', api.configure(1 << 8), -1)
    check('configure', api.configure((1 << 6) | ((1 << 8) if args.enable else 0)), 0)
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state
    check('misa-v', bool(state.misa[0] & (1 << 21)), True)
    check('config-locked', api.configure(0), -1)

    def csr_write(csr, value):
        state.gpr[4] = value & reference.mask
        reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def csr_read(csr):
        reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3]

    def vset(vtype, avl):
        state.gpr[1] = avl
        state.gpr[2] = vtype
        reference.run([0x8020f1d7])

    def vector_get():
        current = VectorState()
        check('vector-get', vector_api.get_state(0, ctypes.byref(current)), 0)
        return current

    def illegal(name, code):
        before = bytes(byte for group in vector_get().reg for byte in group)
        pc = reference.run([code])
        check(name + '-trap', [state.mcause[0], state.mepc[0]], [2, pc])
        check(name + '-vector', bytes(byte for group in vector_get().reg for byte in group).hex(),
              before.hex())

    csr_write(0x300, state.mstatus[0] | 0x6000 | 0x200)
    vset(0xc8, 4)
    seeded = VectorState()
    for register in range(32):
        for offset in range(16):
            seeded.reg[register][offset] = 0xa5
    seeded.reg[0][0] = 0b0101
    for index, value in enumerate((0x3c00, 0xbc00, 0x7d00, 0x0001)):
        seeded.reg[8][index * 2:index * 2 + 2] = value.to_bytes(2, 'little')
    for index, value in enumerate((0x3f800000, 0x3f801000, 0xbf800000, 0x7f800001)):
        seeded.reg[16][index * 4:index * 4 + 4] = value.to_bytes(4, 'little')
    check('vector-seed', vector_api.set_state(0, ctypes.byref(seeded)), 0)
    widen = instruction(0x12, 1, 8, 12, 1, 24)
    narrow = instruction(0x12, 1, 16, 20, 1, 24)
    if not args.enable:
        illegal('widen-disabled', widen)
        illegal('narrow-disabled', narrow)
    else:
        csr_write(0x003, 0)
        pc = reference.run([widen])
        check('widen-retired', state.pc[0], pc + 4)
        check('widen-values', words(vector_get(), 24, 4, 4),
              [0x3f800000, 0xbf800000, 0x7fc00000, 0x33800000])
        check('widen-flags', csr_read(0x003) & 31, 0x10)
        csr_write(0x003, 0)
        pc = reference.run([narrow])
        check('narrow-retired', state.pc[0], pc + 4)
        check('narrow-values', words(vector_get(), 24, 2, 4),
              [0x3c00, 0x3c00, 0xbc00, 0x7e00])
        check('narrow-flags', csr_read(0x003) & 31, 0x11)
        csr_write(0x003, 3 << 5)
        reference.run([narrow])
        check('rup-midpoint', words(vector_get(), 24, 2, 2)[1], 0x3c01)
        check('rup-inexact', csr_read(0x003) & 31, 0x11)
        check('rup-frm', csr_read(0x003) >> 5, 3)
        csr_write(0x003, 0)
        check('reseed-mask', vector_api.set_state(0, ctypes.byref(seeded)), 0)
        csr_write(0x008, 1)
        reference.run([instruction(0x12, 0, 16, 20, 1, 24)])
        check('masked-vstart-values', words(vector_get(), 24, 2, 4),
              [0xa5a5, 0xa5a5, 0xbc00, 0xa5a5])
        check('masked-vstart-flags', csr_read(0x003) & 31, 0)
        check('vstart-clear', csr_read(0x008), 0)
        illegal('narrow-rod-reserved', instruction(0x12, 1, 16, 21, 1, 24))
        illegal('widen-source-low-overlap', instruction(0x12, 1, 24, 12, 1, 24))
        illegal('widen-destination-align', instruction(0x12, 1, 8, 12, 1, 25))
        vset(0xd8, 4)
        illegal('widen-e64-reserved', instruction(0x12, 1, 8, 12, 1, 24))
        vset(0xc8, 4)
        overlap = vector_get()
        overlap.reg[25][0:2] = (0x3c00).to_bytes(2, 'little')
        check('high-overlap-seed', vector_api.set_state(0, ctypes.byref(overlap)), 0)
        pc = reference.run([instruction(0x12, 1, 25, 12, 1, 24)])
        check('high-overlap-retired', state.pc[0], pc + 4)
        check('high-overlap-value', words(vector_get(), 24, 4, 1), [0x3f800000])
        status = state.mstatus[0]
        csr_write(0x300, status & ~0x6000)
        illegal('fs-off', widen)
        csr_write(0x300, status)
        csr_write(0x300, status & ~0x600)
        illegal('vs-off', widen)
        csr_write(0x300, status)
        csr_write(0x003, 5 << 5)
        illegal('reserved-frm', narrow)

        vset(0xc8, 8)
        failures = []
        samples = 0
        for offset in range(0, 1 << 16, 8):
            operands = list(range(offset, offset + 8))
            seeded = VectorState()
            seeded.reg[8][:] = (ctypes.c_uint8 * 16).from_buffer_copy(
                b''.join(value.to_bytes(2, 'little') for value in operands))
            if vector_api.set_state(0, ctypes.byref(seeded)):
                raise RuntimeError('cannot set exhaustive Zvfhmin vector state')
            csr_write(0x003, 0)
            pc = reference.run([widen])
            if state.pc[0] != pc + 4:
                raise RuntimeError(f'Zvfhmin widening trapped at half encoding {offset:#x}')
            actual = VectorState()
            if vector_api.get_state(0, ctypes.byref(actual)):
                raise RuntimeError('cannot get exhaustive Zvfhmin vector state')
            actual_values = words(actual, 24, 4, 8)
            expected = [half_to_single(value) for value in operands]
            actual_flags = csr_read(0x003) & 31
            expected_flags = 0
            for lane, (bits, flags) in enumerate(expected):
                expected_flags |= flags
                if actual_values[lane] != bits and len(failures) < 8:
                    failures.append(dict(operand=hex(operands[lane]),
                                         actual=hex(actual_values[lane]), expected=hex(bits)))
            if actual_flags != expected_flags and len(failures) < 8:
                failures.append(dict(operands=list(map(hex, operands)),
                                     actual_flags=actual_flags, expected_flags=expected_flags))
            samples += len(operands)
        check('widen-exhaustive-coverage', samples, 1 << 16)
        check('widen-exhaustive-results', failures, [])

        vset(0xc8, 4)
        generator = random.Random(0x23f16)
        edge_values = [0, 1, 0x33000000, 0x33000001, 0x337fffff, 0x33800000,
                       0x387fc000, 0x387fe000, 0x387fefff, 0x387ff000,
                       0x387ff001, 0x38800000, 0x3f800000,
                       0x3f801000, 0x477fe000, 0x477ff000, 0x47800000,
                       0x7f800000, 0x7f800001, 0x7fc00001]
        inputs = edge_values + [value | 0x80000000 for value in edge_values]
        inputs += [(exponent << 23) | generator.getrandbits(23)
                   for exponent in range(100, 145) for _ in range(16)]
        inputs += [generator.getrandbits(32) for _ in range(1024)]
        inputs += [0] * (-len(inputs) % 4)
        failures = []
        samples = 0
        for rounding in range(5):
            for offset in range(0, len(inputs), 4):
                operands = inputs[offset:offset + 4]
                seeded = VectorState()
                seeded.reg[16][:] = (ctypes.c_uint8 * 16).from_buffer_copy(
                    b''.join(value.to_bytes(4, 'little') for value in operands))
                if vector_api.set_state(0, ctypes.byref(seeded)):
                    raise RuntimeError('cannot set narrow Zvfhmin vector state')
                csr_write(0x003, rounding << 5)
                pc = reference.run([narrow])
                if state.pc[0] != pc + 4:
                    raise RuntimeError(f'Zvfhmin narrowing trapped at {operands[0]:#x}')
                actual = VectorState()
                if vector_api.get_state(0, ctypes.byref(actual)):
                    raise RuntimeError('cannot get narrow Zvfhmin vector state')
                actual_values = words(actual, 24, 2, 4)
                expected = [single_to_half(value, rounding) for value in operands]
                actual_flags = csr_read(0x003) & 31
                expected_flags = 0
                for lane, (bits, flags) in enumerate(expected):
                    expected_flags |= flags
                    if actual_values[lane] != bits and len(failures) < 8:
                        failures.append(dict(rounding=rounding, operand=hex(operands[lane]),
                                             actual=hex(actual_values[lane]), expected=hex(bits)))
                if actual_flags != expected_flags and len(failures) < 8:
                    failures.append(dict(rounding=rounding, operands=list(map(hex, operands)),
                                         actual_flags=actual_flags, expected_flags=expected_flags))
                samples += len(operands)
        check('narrow-rounded-coverage', samples, len(inputs) * 5)
        check('narrow-rounded-results', failures, [])

    failures = [row for row in rows if not row['passed']]
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable, rows=rows,
                                           reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest()),
                                      indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure['name'], str(failure['actual'])[:100], str(failure['expected'])[:100])
    print(f'NEMU_ZVFHMIN xlen={args.xlen} enabled={args.enable} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
