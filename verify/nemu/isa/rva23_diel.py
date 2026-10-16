"""Check the scalar Zkt instruction subset in NEMU's virtual-cycle model."""

import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile

from lib.reference import ISAAPI, Reference


def scalar_instructions():
    for name in ('lui', 'auipc'):
        yield name, f'{name} t0, 0x12345'
    for name in ('addi', 'slti', 'sltiu', 'xori', 'ori', 'andi', 'slli', 'srli', 'srai',
                 'addiw', 'slliw', 'srliw', 'sraiw', 'rori', 'roriw'):
        yield name, f'{name} t0, t1, 1'
    for name in ('add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and',
                 'addw', 'subw', 'sllw', 'srlw', 'sraw', 'mul', 'mulh', 'mulhsu', 'mulhu',
                 'mulw', 'clmul', 'clmulh', 'clmulr', 'ror', 'rol', 'rorw', 'rolw',
                 'andn', 'orn', 'xnor'):
        yield name, f'{name} t0, t1, t2'
    yield 'rev8', 'rev8 t0, t1'
    yield 'c.nop', 'c.nop'
    for name in ('c.addi', 'c.addiw', 'c.lui', 'c.srli', 'c.srai', 'c.andi', 'c.slli'):
        yield name, f'{name} s0, 1'
    for name in ('c.sub', 'c.xor', 'c.or', 'c.and', 'c.subw', 'c.addw', 'c.mv', 'c.add', 'c.mul'):
        yield name, f'{name} s0, s1'
    for name in ('c.not', 'c.zext.b'):
        yield name, f'{name} s0'


def compile_instructions(directory, cross):
    entries = list(scalar_instructions())
    source = directory / 'instructions.S'
    source.write_text('.text\n.option norelax\n' + ''.join(
        ('.option rvc\n' if name.startswith('c.') else '.option norvc\n') +
        assembly + '\n' + ('.2byte 0\n' if name.startswith('c.') else '')
        for name, assembly in entries))
    obj = directory / 'instructions.o'
    raw = directory / 'instructions.bin'
    subprocess.run([cross + 'gcc', '-c', '-march=rv64gc_zba_zbb_zbc_zbs_zcb', '-mabi=lp64d',
                    source, '-o', obj], check=True)
    subprocess.run([cross + 'objcopy', '-O', 'binary', '-j', '.text', obj, raw], check=True)
    data = raw.read_bytes()
    if len(data) != len(entries) * 4:
        raise RuntimeError('assembler did not preserve four-byte instruction slots')
    return [(name, int.from_bytes(data[index * 4:index * 4 + 4], 'little'))
            for index, (name, _) in enumerate(entries)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cross-compile', default='riscv64-linux-gnu-')
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    if api.supported & 0x7ff != 0x7ff or api.configure(api.supported):
        raise RuntimeError('cannot enable RVA23')
    reference = Reference(args.reference, 64)
    reference.reset()
    state = reference.state
    generator = random.Random(0x23d1e1)
    values = [0, 1, 1 << 63, (1 << 63) - 1, reference.mask,
              0xaaaaaaaaaaaaaaaa, 0x5555555555555555,
              *(generator.getrandbits(64) for _ in range(9))]
    rows = []
    with tempfile.TemporaryDirectory(prefix='nemu-rva23-diel-') as temporary:
        instructions = compile_instructions(Path(temporary), args.cross_compile)
        for privilege in (0, 1, 3):
            for name, instruction in instructions:
                for left in values:
                    for right in values:
                        state.priv[0] = bytes([privilege])
                        for register in range(1, 32):
                            state.gpr[register] = left if register % 2 == 0 else right
                        before_cycles = int(state.mcycle[0])
                        before_retired = int(state.minstret[0])
                        pc = reference.run([instruction])
                        length = 2 if instruction & 3 != 3 else 4
                        actual = [int(state.pc[0]),
                                  (int(state.mcycle[0]) - before_cycles) & reference.mask,
                                  (int(state.minstret[0]) - before_retired) & reference.mask]
                        rows.append(dict(name=name, privilege=privilege, operands=[left, right],
                                         actual=actual, expected=[pc + length, 1, 1],
                                         passed=actual == [pc + length, 1, 1]))
    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        model='one virtual cycle per instruction; not host wall-clock latency',
        seed=0x23d1e1, instructions=len(instructions), checks=len(rows), failures=failures,
        encodings={name: f'{opcode:08x}' for name, opcode in instructions},
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest()), indent=2) + '\n')
    for row in failures[:10]:
        print('FAIL', row)
    print(f'NEMU_RVA23_DIEL instructions={len(instructions)} checks={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
