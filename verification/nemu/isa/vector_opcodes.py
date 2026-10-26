"""Smoke-test nominal OP-V arithmetic encodings from the pinned opcode table."""

import argparse
import ctypes
import json
from pathlib import Path

from lib.reference import ISAAPI, Reference


OPERANDS = {
    'vd': (7, 24), 'rd': (7, 24),
    'vs2': (20, 8), 'rs2': (20, 8),
    'vs1': (15, 16), 'rs1': (15, 16),
    'vm': (25, 1), 'simm5': (15, 1), 'zimm5': (15, 1),
}
EXPECTED_OPCODES = 314


def arithmetic_opcodes(path):
    for line in path.read_text(encoding='utf-8').splitlines():
        parts = line.split('#', 1)[0].split()
        if not parts or '6..0=0x57' not in parts or parts[0].startswith('vset'):
            continue
        name, *tokens = parts
        instruction = 0
        for token in tokens:
            if token in OPERANDS:
                shift, value = OPERANDS[token]
            else:
                location, literal = token.split('=', 1)
                shift, value = int(location.split('..')[-1]), int(literal, 0)
            instruction |= value << shift
        yield name, instruction


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = parser.parse_args()

    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    if api.configure(1 << 6) != 0:
        raise RuntimeError('NEMU reference does not support V128 preview')

    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state
    state.gpr[4] = state.mstatus[0] | 0x200
    reference.run([(0x300 << 20) | (4 << 15) | (1 << 12) | 0x73])

    table = Path(__file__).resolve().parents[2] / 'vpu/vendor/riscv-opcodes/rv_v'
    rows = []
    for name, instruction in arithmetic_opcodes(table):
        sew64 = name in ('vzext.vf8', 'vsext.vf8')
        state.gpr[1] = 2 if sew64 else 4
        vtype = 0xd8 if sew64 else 0xd0
        setup_pc = reference.run([(vtype << 20) | (1 << 15) | (7 << 12) |
                                  (3 << 7) | 0x57])
        if state.pc[0] != setup_pc + 4:
            raise RuntimeError(f'vsetvli failed before {name}')
        pc = reference.run([instruction])
        passed = state.pc[0] == pc + 4
        rows.append(dict(name=name, instruction=f'{instruction:08x}', passed=passed,
                         pc=int(state.pc[0]), mcause=int(state.mcause[0])))

    if len(rows) != EXPECTED_OPCODES:
        raise RuntimeError(f'OP-V table has {len(rows)} entries, expected {EXPECTED_OPCODES}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'xlen': args.xlen, 'results': rows}, indent=2) + '\n',
                           encoding='utf-8')
    failures = [row for row in rows if not row['passed']]
    print(f'RV{args.xlen} OP-V encodings: {len(rows) - len(failures)}/{len(rows)} pass')
    for row in failures:
        print(f"FAIL {row['name']} ({row['instruction']}): pc={row['pc']:x} "
              f"mcause={row['mcause']}")
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
