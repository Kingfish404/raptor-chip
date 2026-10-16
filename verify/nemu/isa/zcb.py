"""Check mandatory Zcb compressed memory, arithmetic and reserved encodings."""
import argparse
import hashlib
import json
from pathlib import Path

from lib.reference import Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reference = Reference(args.reference, args.xlen)
    state = reference.state
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected,
                         passed=actual == expected))

    def retired(name, instruction, privilege):
        before = state.minstret[0]
        state.priv[0] = bytes([privilege])
        pc = reference.run([instruction])
        check(name + '-retire', [state.pc[0], state.minstret[0], state.mcause[0]],
              [pc + 2, before + 1, 0])

    memory_base = 0x81000000
    initial_bytes = bytes((0x80, 0xff, 0x01, 0x7f, 0xa5, 0x5a, 0x00, 0xfe))
    for privilege in (0, 1, 3):
        for base_register in (0, 3, 7):
            value_register = (base_register + 1) % 8
            for kind, encoding, width, signed in (
                    ('lbu', 0x8000, 1, False),
                    ('lhu', 0x8400, 2, False),
                    ('lh', 0x8440, 2, True)):
                for offset in range(4 if width == 1 else 2):
                    address_offset = offset if width == 1 else offset * 2
                    immediate = ((address_offset & 1) << 6) | ((address_offset & 2) << 4)
                    instruction = (encoding | (base_register << 7) |
                                   (value_register << 2) | immediate)
                    reference.reset()
                    reference.write(memory_base, initial_bytes)
                    state.gpr[8 + base_register] = memory_base
                    state.gpr[8 + value_register] = reference.mask
                    retired(f'c.{kind}-base{base_register}-offset{address_offset}-p{privilege}',
                            instruction, privilege)
                    raw = initial_bytes[address_offset:address_offset + width]
                    expected = int.from_bytes(raw, 'little', signed=signed) & reference.mask
                    check(f'c.{kind}-value-{base_register}-{address_offset}-p{privilege}',
                          state.gpr[8 + value_register], expected)
            for kind, encoding, width in (('sb', 0x8800, 1), ('sh', 0x8c00, 2)):
                for offset in range(4 if width == 1 else 2):
                    address_offset = offset if width == 1 else offset * 2
                    immediate = ((address_offset & 1) << 6) | ((address_offset & 2) << 4)
                    instruction = (encoding | (base_register << 7) |
                                   (value_register << 2) | immediate)
                    reference.reset()
                    reference.write(memory_base, initial_bytes)
                    state.gpr[8 + base_register] = memory_base
                    state.gpr[8 + value_register] = 0xdeadbeef
                    retired(f'c.{kind}-base{base_register}-offset{address_offset}-p{privilege}',
                            instruction, privilege)
                    expected = bytearray(initial_bytes)
                    expected[address_offset:address_offset + width] = (0xdeadbeef).to_bytes(4, 'little')[:width]
                    check(f'c.{kind}-memory-{base_register}-{address_offset}-p{privilege}',
                          list(reference.read(memory_base, len(initial_bytes))), list(expected))

        for register in range(8, 16):
            for value in (0, 0x80008080, 0xffffffffffffffff, 0x123456789abcdef0):
                operations = [
                    ('zext.b', 0x9c61, value & 0xff),
                    ('sext.b', 0x9c65, (value & 0x7f) - (value & 0x80)),
                    ('zext.h', 0x9c69, value & 0xffff),
                    ('sext.h', 0x9c6d, (value & 0x7fff) - (value & 0x8000)),
                    ('not', 0x9c75, ~value),
                ]
                if args.xlen == 64:
                    operations.append(('zext.w', 0x9c71, value & 0xffffffff))
                for kind, encoding, result in operations:
                    reference.reset()
                    state.gpr[register] = value & reference.mask
                    instruction = encoding | ((register - 8) << 7)
                    retired(f'c.{kind}-x{register}-value{value:x}-p{privilege}',
                            instruction, privilege)
                    check(f'c.{kind}-result-x{register}-value{value:x}-p{privilege}',
                          state.gpr[register], result & reference.mask)

        for destination in (8, 11, 15):
            for source in (8, 10, 15):
                for left, right in ((0, 0xffffffff), (0x12345678, 0x9abcdef0),
                                    (reference.mask, 3)):
                    reference.reset()
                    state.gpr[destination] = left
                    state.gpr[source] = right
                    before_left = state.gpr[destination]
                    before_right = state.gpr[source]
                    instruction = (0x9c41 | ((destination - 8) << 7) |
                                   ((source - 8) << 2))
                    retired(f'c.mul-x{destination}-x{source}-{left:x}-{right:x}-p{privilege}',
                            instruction, privilege)
                    check(f'c.mul-result-x{destination}-x{source}-{left:x}-{right:x}-p{privilege}',
                          state.gpr[destination], before_left * before_right & reference.mask)

    reserved = [0x9c79, 0x9c7d]
    if args.xlen == 32:
        reserved.append(0x9c71)
    for instruction in reserved:
        reference.reset()
        before = state.minstret[0]
        pc = reference.run([instruction])
        check(f'reserved-{instruction:04x}',
              [state.pc[0], state.mcause[0], state.mtval[0], state.mepc[0],
               state.minstret[0]],
              [0x80ff0000, 2, instruction, pc, before])

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        xlen=args.xlen,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_ZCB xlen={args.xlen} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
