"""Exercise Zfa through the RTL reference ABI with independent bit/rational oracles."""
import argparse
import ctypes
from fractions import Fraction
import hashlib
import itertools
import json
import math
from pathlib import Path
import random
import struct

from lib.reference import ISAAPI, Reference


def encode(value, width):
    return int.from_bytes(struct.pack('<f' if width == 32 else '<d', value), 'little')


def decode(bits, width):
    return struct.unpack('<f' if width == 32 else '<d', bits.to_bytes(width // 8, 'little'))[0]


def nan_flags(bits, width):
    fraction = 23 if width == 32 else 52
    return 16 if math.isnan(decode(bits, width)) and not bits & (1 << (fraction - 1)) else 0


def canonical(width):
    return 0x7fc00000 if width == 32 else 0x7ff8000000000000


def round_bits(bits, width, mode, exact):
    value = decode(bits, width)
    if math.isnan(value):
        return canonical(width), nan_flags(bits, width)
    if not math.isfinite(value) or value == 0:
        return bits, 0
    rational = Fraction(value)
    if mode == 0:
        integer = round(rational)
    elif mode == 1:
        integer = int(rational)
    elif mode == 2:
        integer = math.floor(rational)
    elif mode == 3:
        integer = math.ceil(rational)
    else:
        integer = math.floor(abs(rational) + Fraction(1, 2)) * (-1 if value < 0 else 1)
    result = encode(float(integer), width) if integer else bits & (1 << (width - 1))
    return result, int(exact and integer != rational)


def instruction(funct7, rs2=2, rs1=1, mode=0):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (mode << 12) | (3 << 7) | 0x53


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--enable', action='store_true')
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    if not api.supported & 4 or api.configure(4 if args.enable else 0):
        raise SystemExit('Zfa runtime configuration failed')
    reference = Reference(args.reference, args.xlen)
    state = reference.state
    original_misa = state.misa[0]
    arena = 0x81000000
    sentinel = 0x1122334455667788
    rows = []

    def case(name, code, width=64, lhs=0, rhs=0, result=0, flags=0, integer=False,
             illegal=False, fs=1, frm=0, missing=0, raw=False, registers=None, requires_extension=True):
        reference.reset()
        state.misa[0] = original_misa
        operands = (lhs, rhs) if raw or width == 64 else (lhs | 0xffffffff00000000, rhs | 0xffffffff00000000)
        reference.write(arena, b''.join(value.to_bytes(8, 'little') for value in (*operands, sentinel, 0)))
        state.gpr[1] = arena
        reference.run([0x0000b087, 0x0080b107, 0x0100b187])
        state.gpr[4] = (frm << 5) | 8
        reference.run([0x00321073])
        state.gpr[3] = 0x76543210
        if registers:
            state.gpr[1], state.gpr[2] = registers
        state.mstatus[0] = (state.mstatus[0] & ~0x6000) | (fs << 13)
        state.misa[0] &= ~missing
        retired = state.minstret[0]
        pc = reference.run([code])
        trapped = illegal or (requires_extension and not args.enable)
        actual = [state.pc[0], state.mcause[0], state.mtval[0], state.minstret[0],
                  (state.mstatus[0] >> 13) & 3, state.gpr[3]]
        expected = [0x80ff0000, 2, code, retired, fs, 0x76543210] if trapped else [
            pc + 4, 0, 0, retired + 1, 3 if not integer or flags else fs,
            result & reference.mask if integer else 0x76543210]
        state.misa[0] = original_misa
        state.mstatus[0] |= 0x6000
        state.gpr[1] = arena
        reference.run([0x0030bc27, 0x003022f3])
        actual += [int.from_bytes(reference.read(arena + 24, 8), 'little'), state.gpr[5]]
        expected += [sentinel if trapped or integer else result | (0xffffffff00000000 if width == 32 else 0),
                     (frm << 5) | 8 | (0 if trapped else flags)]
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    constants = [-1, None, 2**-16, 2**-15, 2**-8, 2**-7, 2**-4, 2**-3,
                 .25, .3125, .375, .4375, .5, .625, .75, .875,
                 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 8, 16, 128, 256, 32768, 65536, math.inf, math.nan]
    representative = []
    for width in (32, 64):
        fmt = int(width == 64)
        fraction = 23 if width == 32 else 52
        case(f'baseline-add-{width}', instruction(fmt), width, encode(1, width), encode(2, width),
             encode(3, width), requires_extension=False)
        case(f'baseline-min-nan-{width}', instruction(0x14 | fmt), width, canonical(width), encode(1, width),
             encode(1, width), requires_extension=False)
        case(f'baseline-le-nan-{width}', instruction(0x50 | fmt), width, canonical(width), encode(1, width),
             0, 16, True, requires_extension=False)
        for immediate, value in enumerate(constants):
            result = (1 << fraction) if value is None else canonical(width) if immediate == 31 else encode(value, width)
            case(f'fli{width}-{immediate}', instruction(0x78 | fmt, 1, immediate), width, result=result, frm=7)
        samples = [encode(value, width) for value in (0.0, -0.0, 1, -1, 1.5, -1.5, 2.5, -2.5, math.inf, -math.inf)]
        samples += [1, (1 << (width - 1)) | 1, 1 << fraction, canonical(width), canonical(width) ^ (1 << (fraction - 1)) | 1]
        samples += [encode(math.inf, width) - 1, encode(-math.inf, width) - 1,
                    encode(2**fraction, width) - 1, encode(2**fraction, width) + 1]
        if args.enable:
            for lhs, rhs, operation in itertools.product(samples, samples, ('min', 'max', 'le', 'lt')):
                left, right = decode(lhs, width), decode(rhs, width)
                flags = nan_flags(lhs, width) | nan_flags(rhs, width)
                nan = math.isnan(left) or math.isnan(right)
                compare = operation in ('le', 'lt')
                if compare:
                    result = int(not nan and (left < right if operation == 'lt' else left <= right))
                elif nan:
                    result = canonical(width)
                elif left == right == 0:
                    result = lhs & rhs if operation == 'max' else lhs | rhs
                else:
                    result = lhs if (left > right if operation == 'max' else left < right) else rhs
                code = instruction((0x50 if compare else 0x14) | fmt,
                                   mode=(4 if compare else 2) + int(operation in ('max', 'lt')))
                case(f'{operation}{width}-{lhs:x}-{rhs:x}', code, width, lhs, rhs, result, flags, compare)
            for bits, mode, exact, dynamic in itertools.product(samples, range(5), (False, True), (False, True)):
                result, flags = round_bits(bits, width, mode, exact)
                case(f'round{width}-{bits:x}-{mode}-{exact}-{dynamic}',
                     instruction(0x20 | fmt, 4 + exact, mode=7 if dynamic else mode), width,
                     bits, result=result, flags=flags, frm=mode if dynamic else 0)
        operations = [instruction(0x78 | fmt, 1), instruction(0x14 | fmt, mode=2),
                      instruction(0x14 | fmt, mode=3), instruction(0x20 | fmt, 4),
                      instruction(0x20 | fmt, 5), instruction(0x50 | fmt, mode=4),
                      instruction(0x50 | fmt, mode=5)]
        representative.extend(operations)
        for code in operations:
            case(f'fs-off-{code:x}', code, width, fs=0, illegal=True)
            case(f'no-f-{code:x}', code, width, missing=1 << 5, illegal=True)
            if fmt:
                case(f'no-d-{code:x}', code, width, missing=1 << 3, illegal=True)
        for exact, mode in itertools.product((0, 1), (5, 6)):
            case(f'bad-rm-{width}-{exact}-{mode}', instruction(0x20 | fmt, 4 + exact, mode=mode), width, illegal=True)
        for exact, frm in itertools.product((0, 1), (5, 6, 7)):
            case(f'bad-frm-{width}-{exact}-{frm}', instruction(0x20 | fmt, 4 + exact, mode=7), width, frm=frm, illegal=True)
    if args.enable:
        case('fli-s-without-d', instruction(0x78, 1, 16), 32, result=encode(1, 32), missing=1 << 3)
        for operation, code, integer in [('min', instruction(0x14, mode=2), False),
                                       ('round', instruction(0x20, 5), False),
                                       ('le', instruction(0x50, mode=4), True)]:
            case('unboxed-' + operation, code, 32, lhs=0x3f800000, rhs=0xffffffff3f800000,
                 result=0 if integer else canonical(32), integer=integer, raw=True)
    rng = random.Random(0x23fa)
    modular = [encode(value, 64) for value in (0., -0., 1.5, -1.5, 2**31 - .5, -2**31 - .5,
                                               2**31, -2**31, 2**32 - 1, 2**32 + 1, -2**32 - 1,
                                               2**52 + 1, 2**53 + 2, math.inf, -math.inf, math.nan)]
    modular += [1, 0x8000000000000001, 0x7ff0000000000001]
    modular += [(((exponent + 1023) << 52) | 1 | (sign << 63))
                for exponent, sign in itertools.product((31, 32, 51, 52, 53, 63, 64, 82, 83, 84), (0, 1))]
    modular += [rng.getrandbits(64) for _ in range(128)]
    for bits in modular if args.enable else modular[:1]:
        value = decode(bits, 64)
        integer = int(value) if math.isfinite(value) else 0
        flags = 16 if not math.isfinite(value) or not -(1 << 31) <= integer < (1 << 31) else int(integer != value)
        result = integer & 0xffffffff
        result -= (1 << 32) if result & (1 << 31) else 0
        case(f'mod-{bits:x}', instruction(0x61, 8, mode=1), lhs=bits, result=result, flags=flags, integer=True, frm=7)
    representative += [instruction(0x61, 8, mode=1)]
    for mode in (0, 2, 3, 4, 5, 6, 7):
        case(f'mod-reserved-{mode}', instruction(0x61, 8, mode=mode), illegal=True)
    for code in (instruction(0x61, 8, mode=1), instruction(0x71, 1), instruction(0x59)):
        case(f'extra-fs-off-{code:x}', code, fs=0, illegal=True)
        for missing in (1 << 5, 1 << 3):
            case(f'extra-missing-{code:x}-{missing}', code, missing=missing, illegal=True)
    for bits in (0, 0x89abcdef01234567, 0x7ff0000000000001, 0xffffffffffffffff):
        case(f'move-high-{bits:x}', instruction(0x71, 1), lhs=bits, result=bits >> 32,
             integer=True, illegal=args.xlen != 32)
        case(f'move-pair-{bits:x}', instruction(0x59), result=bits,
             registers=(bits & 0xffffffff, bits >> 32), illegal=args.xlen != 32)
    for fmt in (2, 3):
        for code in (instruction(0x78 | fmt, 1), instruction(0x14 | fmt, mode=2),
                     instruction(0x20 | fmt, 4), instruction(0x50 | fmt, mode=4)):
            case(f'unsupported-format-{code:x}', code, illegal=True)
    if not args.enable:
        for code in representative:
            case(f'disabled-{code:x}', code, illegal=True)
    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_ZFA xlen={args.xlen} cases={len(rows)} failures={len(failures)} enabled={args.enable}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
