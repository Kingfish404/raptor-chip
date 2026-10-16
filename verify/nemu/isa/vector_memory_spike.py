"""Compare single-hart vector memory instructions with Spike and private RAM."""

import argparse
import ctypes
import json
import random
import subprocess
import tempfile
from pathlib import Path

from isa.vector_data import VectorAPI, VectorState, segment_instruction, whole_instruction, mask_instruction
from isa.vector_spike import OracleResult, SPIKE, build_oracle
from lib.reference import ISAAPI, Reference


def cases():
    for sew in range(4):
        for lmul in (0, 1, 2, 3, 5, 6, 7):
            exponent = lmul if lmul < 4 else lmul - 8
            if (8 << sew) > (64 << exponent if exponent >= 0 else 64 >> -exponent):
                continue
            maximum = (16 >> sew) << exponent if exponent >= 0 else (16 >> sew) >> -exponent
            for width in range(4):
                for fields in (1, 2, 3, 4, 8):
                    for mode in ('unit', 'strided', 'negative-stride', 'indexed', 'ordered', 'fof'):
                        for store in (False, True):
                            if mode == 'fof' and store:
                                continue
                            for masked in (False, True):
                                data_bytes = (1 << sew) if mode in ('indexed', 'ordered') else 1 << width
                                count = min(maximum, 255 // (data_bytes * fields) + 1)
                                mop, selector = (0, 16 if mode == 'fof' else 0)
                                if mode in ('strided', 'negative-stride'):
                                    mop, selector = 2, 17
                                elif mode in ('indexed', 'ordered'):
                                    mop, selector = 3 if mode == 'ordered' else 1, 8
                                opcode = segment_instruction(store, 0 if width == 0 else width + 4,
                                                             fields, not masked, 16, 24, mop, selector)
                                yield dict(mode=mode, sew=sew, lmul=lmul, width=width,
                                           fields=fields, store=store, masked=masked,
                                           vl=count, opcode=opcode)
    for store in (False, True):
        for registers in (1, 2, 4, 8):
            for width in range(4):
                if store and width:
                    continue
                yield dict(mode='whole', sew=2, lmul=0, width=width, fields=registers,
                           store=store, masked=False, vl=3,
                           opcode=whole_instruction(store, 0 if width == 0 else width + 4,
                                                    registers, 16, 24))
        for vl in (1, 7, 8, 9, 16, 31, 32, 63, 64, 127, 128):
            yield dict(mode='mask', sew=0, lmul=3, width=0, fields=1,
                       store=store, masked=False, vl=vl,
                       opcode=mask_instruction(store, 16, 24))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--cxx', default='g++')
    parser.add_argument('--seed', type=lambda value: int(value, 0), default=0x23b23)
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    if query(1, ctypes.sizeof(ISAAPI)).contents.configure(1 << 6):
        raise RuntimeError('reference lacks V128 preview')
    vector_query = library.nemu_difftest_vector_query
    vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    vector_query.restype = ctypes.POINTER(VectorAPI)
    vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state
    generator = random.Random(args.seed)
    counts = {}
    illegal = 0
    alignment_traps = 0
    checks = 0
    failures = []
    with tempfile.TemporaryDirectory(prefix='nemu-vector-memory-spike-') as temporary:
        oracle = build_oracle(Path(temporary), args.cxx)
        oracle.vector_oracle_init(args.xlen)
        for case in cases():
            for unaligned in (False, True):
                seeded = VectorState.from_buffer_copy(generator.randbytes(512))
                raw = bytearray(bytes(seeded))
                if case['mode'] in ('indexed', 'ordered'):
                    index_bytes = 1 << case['width']
                    stride = (1 << case['sew']) * case['fields']
                    for element in range(min(case['vl'], 128 // index_bytes)):
                        offset = element * stride & ((1 << (8 * index_bytes)) - 1)
                        start = 128 + element * index_bytes
                        raw[start:start + index_bytes] = offset.to_bytes(index_bytes, 'little')
                    seeded = VectorState.from_buffer_copy(raw)
                memory = generator.randbytes(4096)
                memory_buffer = ctypes.create_string_buffer(memory)
                stride = (1 << case['width']) * case['fields'] + 3
                if case['mode'] == 'negative-stride':
                    stride = -stride & reference.mask
                base = 0x81000800 + unaligned
                expected = OracleResult()
                vtype = (case['sew'] << 3) | case['lmul']
                oracle.vector_memory_oracle(case['opcode'], vtype, case['vl'], base, stride,
                                            ctypes.byref(seeded), memory_buffer, ctypes.byref(expected))
                state.mstatus[0] |= 0x6600
                state.gpr[1] = case['vl']
                reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
                if vector_api.set_state(0, ctypes.byref(seeded)):
                    raise RuntimeError('cannot set vector state')
                state.gpr[16] = base
                state.gpr[17] = stride
                reference.write(0x81000000, memory)
                pc = reference.run([case['opcode']])
                trapped = state.pc[0] != pc + 4
                actual = VectorState()
                if vector_api.get_state(0, ctypes.byref(actual)):
                    raise RuntimeError('cannot get vector state')
                errors = {}
                alignment_choice = (case['mode'] == 'whole' and unaligned and
                                    case['width'] > 0 and not case['store'])
                if alignment_choice and trapped and not expected.trapped:
                    alignment_traps += 1
                    if (state.mcause[0] != 4 or state.mtval[0] != base or
                            bytes(actual) != bytes(seeded) or reference.read(0x81000000, 4096) != memory):
                        errors['alignment_trap'] = dict(cause=int(state.mcause[0]),
                                                       address=int(state.mtval[0]))
                elif trapped != bool(expected.trapped):
                    errors['trapped'] = [trapped, bool(expected.trapped)]
                elif trapped:
                    illegal += 1
                    if (state.mcause[0] != 2 or expected.cause != 2 or
                            state.mtval[0] != case['opcode'] or bytes(actual) != bytes(seeded) or
                            reference.read(0x81000000, 4096) != memory):
                        errors['illegal_trap'] = dict(actual_cause=int(state.mcause[0]),
                                                     expected_cause=int(expected.cause),
                                                     tval=int(state.mtval[0]))
                else:
                    key = case['mode'] + ('-store' if case['store'] else '-load')
                    counts[key] = counts.get(key, 0) + 1
                    if bytes(actual) != bytes(expected.registers):
                        errors['registers'] = [bytes(actual).hex(), bytes(expected.registers).hex()]
                    actual_memory = reference.read(0x81000000, 4096)
                    if actual_memory != bytes(expected.memory):
                        errors['memory'] = [[offset, actual_byte, expected_byte]
                                            for offset, (actual_byte, expected_byte) in enumerate(
                                                zip(actual_memory, expected.memory))
                                            if actual_byte != expected_byte][:32]
                    for csr, field in ((0xc20, 'vl'), (0x008, 'vstart')):
                        reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
                        if state.gpr[3] != getattr(expected, field):
                            errors[field] = [int(state.gpr[3]), getattr(expected, field)]
                checks += 1
                if errors:
                    failures.append(dict(**case, unaligned=unaligned, errors=errors))
    revision = subprocess.check_output(['git', '-C', str(SPIKE), 'rev-parse', 'HEAD'], text=True).strip()
    required = {f'{mode}-{operation}' for mode in
                ('unit', 'strided', 'negative-stride', 'indexed', 'ordered', 'whole', 'mask')
                for operation in ('load', 'store')} | {'fof-load'}
    missing = sorted(required - counts.keys())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, seed=args.seed, spike_revision=revision,
                                          checks=checks, illegal=illegal, alignment_traps=alignment_traps,
                                          coverage=counts, missing=missing,
                                          failures=failures), indent=2) + '\n', encoding='utf-8')
    print(f'RV{args.xlen} Spike vector memory: {checks} cases, {len(failures)} mismatches')
    for failure in failures[:12]:
        print('FAIL', {key: value for key, value in failure.items() if key != 'errors'},
              list(failure['errors']))
    return bool(failures or missing)


if __name__ == '__main__':
    raise SystemExit(main())
