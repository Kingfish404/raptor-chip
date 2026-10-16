"""Compare NEMU vector memory instructions with the independent RTL sequencer."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import subprocess

from isa.vector_data import (VectorAPI, VectorState, fof_instruction, indexed_instruction,
                             mask_instruction, memory_instruction, segment_instruction,
                             strided_instruction, whole_instruction)
from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]
MEMORY_BASE = 0x80073000
MEMORY_EDGE = 0x8ffffe00


def seeded_byte(index, seed, vector):
    if vector:
        return (index * 29 + (index // 16) * 37 + seed * 13) & 255
    return (index * 13 + (index // 16) * 19 + seed * 7) & 255


def indexed_offset(index, seed, pattern):
    if pattern == 1:
        return ((index * 3 + seed) % 8) * 8
    if pattern == 4:
        return 3 + index * 4
    return index * (4 if pattern == 2 else 3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    library = ctypes.CDLL(str(args.reference.resolve()))
    isa_query = library.nemu_difftest_isa_query
    isa_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    isa_query.restype = ctypes.POINTER(ISAAPI)
    if isa_query(1, ctypes.sizeof(ISAAPI)).contents.configure(1 << 6):
        raise RuntimeError('reference does not support V128 preview')
    vector_query = library.nemu_difftest_vector_query
    vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    vector_query.restype = ctypes.POINTER(VectorAPI)
    vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state
    state.gpr[4] = 0x200
    reference.run([(0x300 << 20) | (4 << 15) | (2 << 12) | 0x73])

    cases = []
    widths = (0, 5, 6, 7)
    for width in widths:
        sew = width - 4 if width else 0
        maximum = 16 // (1 << sew)
        vtype = 0xc0 | (sew << 3)
        for store in (False, True):
            for vm in (0, 1):
                for start in sorted({0, 1, min(3, maximum - 1)}):
                    cases.append(dict(name=f'unit-{store}-{width}-{vm}-{start}',
                                      instruction=memory_instruction(store, width, vm, 1, 8),
                                      vtype=vtype, avl=min(5, maximum), start=start,
                                      base=32, seed=sew * 19 + int(store) * 5 + vm,
                                      expected_trap=0,
                                      expect_requests=width == 0 and vm == 1 and start == 0))
        for store in (False, True):
            for vm in (0, 1):
                for stride in (2 << sew, -(2 << sew), 0):
                    for start in (0, 1):
                        cases.append(dict(name=f'strided-{store}-{width}-{vm}-{stride}-{start}',
                                          instruction=strided_instruction(store, width, vm, 1, 2, 8),
                                          vtype=vtype, avl=min(5, maximum), start=start,
                                          base=64, stride=stride,
                                          seed=width * 7 + int(store) * 11 + vm * 3 + start))
    for registers in (1, 2, 4, 8):
        for store in (False, True):
            for width in ((0,) if store else widths):
                effective_length = registers * 16 // (1 << (width - 4 if width else 0))
                starts = (0, 1, effective_length - 1)
                if effective_length < 128:
                    starts += (effective_length,)
                for start in starts:
                    reg = 8 if store else 24
                    cases.append(dict(name=f'whole-{store}-{registers}-{width}-{start}',
                                      instruction=whole_instruction(store, width, registers, 1, reg),
                                      vtype=0xff, avl=0, start=start, base=32,
                                      seed=registers * 13 + width + int(store),
                                      expected_trap=int(start >= effective_length),
                                      reserved_whole_start=start >= effective_length))
    for stride_reg in (0, 8, 11, 16):
        cases.append(dict(name=f'strided-rs2-{stride_reg}',
                          instruction=strided_instruction(False, 0, 1, 1, stride_reg, 24),
                          vtype=0xc0, avl=4, start=0, base=64,
                          stride=0 if stride_reg == 0 else 2,
                          stride_reg=stride_reg, seed=112 + stride_reg))
    for data_width in widths:
        data_sew = data_width - 4 if data_width else 0
        for index_width in widths:
            for ordered in (False, True):
                for store in (False, True):
                    for vm in (0, 1):
                        for start in (0, 1):
                            seed = (120 + data_width * 9 + index_width * 3 +
                                    int(ordered) * 2 + int(store) + vm + start)
                            cases.append(dict(
                                name=f'indexed-{store}-{ordered}-{data_width}-'
                                     f'{index_width}-{vm}-{start}',
                                instruction=indexed_instruction(store, index_width, vm, 1,
                                                                16, 8, ordered),
                                vtype=0xc0 | (data_sew << 3),
                                avl=min(5, 16 >> data_sew), start=start,
                                base=64, seed=seed, index_pattern=1,
                                expected_trap=int(args.xlen == 32 and index_width == 7)))
    cases.extend([
        dict(name='indexed-overlap-equal',
             instruction=indexed_instruction(False, 0, 1, 1, 8, 8),
             vtype=0xc0, avl=4, start=0, base=64, seed=202, index_pattern=1),
        dict(name='indexed-overlap-narrow',
             instruction=indexed_instruction(False, 6, 1, 1, 16, 16),
             vtype=0xc0, avl=4, start=0, base=64, seed=203, index_pattern=1),
        dict(name='indexed-overlap-wide',
             instruction=indexed_instruction(False, 0, 1, 1, 19, 16),
             vtype=0xd2, avl=4, start=0, base=64, seed=204, index_pattern=1),
        dict(name='indexed-overlap-invalid',
             instruction=indexed_instruction(False, 6, 1, 1, 16, 17),
             vtype=0xc0, avl=4, start=0, base=64, seed=205, index_pattern=1),
        dict(name='indexed-source-unaligned',
             instruction=indexed_instruction(False, 5, 1, 1, 17, 8),
             vtype=0xc0, avl=4, start=0, base=64, seed=206, index_pattern=1),
        dict(name='indexed-misaligned-load',
             instruction=indexed_instruction(False, 0, 1, 1, 16, 8),
             vtype=0xc8, avl=4, start=0, base=32, seed=207, index_pattern=3),
        dict(name='indexed-misaligned-store',
             instruction=indexed_instruction(True, 0, 1, 1, 16, 8),
             vtype=0xc8, avl=4, start=0, base=32, seed=208, index_pattern=3),
        dict(name='indexed-masked-index-v0',
             instruction=indexed_instruction(False, 0, 0, 1, 0, 8),
             vtype=0xc0, avl=4, start=0, base=64, seed=210, index_pattern=4,
             expected_trap=0, expect_requests=True),
        dict(name='indexed-unmasked-index-v0',
             instruction=indexed_instruction(False, 0, 1, 1, 0, 8),
             vtype=0xc0, avl=4, start=0, base=64, seed=211, index_pattern=1),
        dict(name='indexed-store-different-eew-source-overlap',
             instruction=indexed_instruction(True, 0, 1, 1, 8, 8),
             vtype=0xc8, avl=4, start=0, base=64, seed=214,
             index_pattern=1, expected_trap=1),
        dict(name='indexed-store-same-eew-source-overlap',
             instruction=indexed_instruction(True, 5, 1, 1, 8, 8),
             vtype=0xc8, avl=4, start=0, base=64, seed=215,
             index_pattern=1, expected_trap=0),
    ])
    if args.xlen == 64:
        cases.append(dict(name='indexed-index-emul-invalid',
                          instruction=indexed_instruction(False, 7, 1, 1, 16, 8),
                          vtype=0xc3, avl=4, start=0, base=64,
                          seed=209, index_pattern=1))
    for width in widths:
        sew = width - 4 if width else 0
        vtype = 0xc0 | (sew << 3)
        for fields in (2, 3, 4):
            for store in (False, True):
                for vm in (0, 1):
                    for mop, selector in ((0, 0), (2, 2), (1, 16), (3, 16)):
                        cases.append(dict(
                            name=f'segment-{mop}-{store}-{width}-{fields}-{vm}',
                            instruction=segment_instruction(store, width, fields, vm,
                                                            1, 8, mop, selector),
                            vtype=vtype, avl=min(4, 16 >> sew), start=0,
                            base=64, stride=fields << sew,
                            seed=230 + width * 19 + fields * 7 + int(store) * 3 + vm + mop,
                            index_pattern=1 if mop & 1 else 0))
    cases.extend([
        dict(name='segment-fof-normal',
             instruction=segment_instruction(False, 0, 2, 1, 1, 8, selector=16),
             vtype=0xc0, avl=4, start=0, base=32, seed=310),
        dict(name='segment-overlap-illegal',
             instruction=segment_instruction(False, 0, 2, 1, 1, 8, 1, 9),
             vtype=0xc0, avl=4, start=0, base=32, seed=311, index_pattern=1),
        dict(name='segment-group-illegal',
             instruction=segment_instruction(False, 0, 5, 1, 1, 8),
             vtype=0xc1, avl=4, start=0, base=32, seed=312),
        dict(name='segment-register-illegal',
             instruction=segment_instruction(False, 0, 2, 1, 1, 31),
             vtype=0xc0, avl=4, start=0, base=32, seed=313),
    ])
    for store in (False, True):
        cases.extend([
            dict(name=f'segment-edge-first-{store}',
                 instruction=segment_instruction(store, 0, 2, 1, 1, 8),
                 vtype=0xc0, avl=3, start=0, base=511,
                 seed=314 + int(store), edge=True),
            dict(name=f'segment-edge-later-{store}',
                 instruction=segment_instruction(store, 0, 2, 1, 1, 8),
                 vtype=0xc0, avl=3, start=0, base=509,
                 seed=316 + int(store), edge=True),
            dict(name=f'segment-edge-masked-{store}',
                 instruction=segment_instruction(store, 0, 2, 0, 1, 8),
                 vtype=0xc0, avl=3, start=0, base=509,
                 seed=318 + int(store), edge=True),
        ])
    cases.extend([
        dict(name='segment-fof-edge-first',
             instruction=segment_instruction(False, 0, 2, 1, 1, 8, selector=16),
             vtype=0xc0, avl=3, start=0, base=511, seed=320, edge=True),
        dict(name='segment-fof-edge-trim',
             instruction=segment_instruction(False, 0, 2, 1, 1, 8, selector=16),
             vtype=0xc0, avl=3, start=0, base=509, seed=321, edge=True),
    ])
    for store in (False, True):
        for reg in (0, 24):
            for start in (0, 1, 2):
                cases.append(dict(name=f'mask-{store}-{reg}-{start}',
                                  instruction=mask_instruction(store, 1, reg),
                                  vtype=0xc0, avl=11, start=start, base=32,
                                  seed=reg + start * 17 + int(store)))
    cases.extend([
        dict(name='whole-nregs3', instruction=whole_instruction(False, 0, 3, 1, 24),
             vtype=0xff, avl=0, start=0, base=32, seed=71),
        dict(name='whole-align', instruction=whole_instruction(False, 0, 2, 1, 25),
             vtype=0xff, avl=0, start=0, base=32, seed=72),
        dict(name='whole-masked', instruction=whole_instruction(False, 0, 1, 1, 24, vm=0),
             vtype=0xff, avl=0, start=0, base=32, seed=73),
        dict(name='mask-vill', instruction=mask_instruction(False, 1, 24),
             vtype=0xff, avl=0, start=0, base=32, seed=74),
        dict(name='mask-nf', instruction=mask_instruction(False, 1, 24) | (1 << 29),
             vtype=0xc0, avl=11, start=0, base=32, seed=75),
        dict(name='unit-misaligned-load', instruction=memory_instruction(False, 5, 1, 1, 8),
             vtype=0xc0, avl=3, start=0, base=33, seed=76),
        dict(name='unit-misaligned-store', instruction=memory_instruction(True, 5, 1, 1, 8),
             vtype=0xc0, avl=3, start=0, base=33, seed=77),
        dict(name='unit-masked-store-v0', instruction=memory_instruction(True, 0, 0, 1, 0),
             vtype=0xc0, avl=4, start=0, base=32, seed=212,
             expected_trap=0, expect_requests=True),
        dict(name='unit-unmasked-store-v0', instruction=memory_instruction(True, 0, 1, 1, 0),
             vtype=0xc0, avl=4, start=0, base=32, seed=213),
        dict(name='whole-misaligned-load',
             instruction=whole_instruction(False, 5, 1, 1, 24),
             vtype=0xff, avl=0, start=0, base=33, seed=78),
        dict(name='unit-misaligned-restart-load',
             instruction=memory_instruction(False, 5, 1, 1, 8),
             vtype=0xc0, avl=4, start=2, base=33, seed=79),
        dict(name='unit-misaligned-restart-store',
             instruction=memory_instruction(True, 5, 1, 1, 8),
             vtype=0xc0, avl=4, start=2, base=33, seed=80),
        dict(name='strided-misaligned-later-load',
             instruction=strided_instruction(False, 5, 1, 1, 2, 8),
             vtype=0xc8, avl=4, start=0, base=32, stride=3, seed=81),
        dict(name='strided-misaligned-later-store',
             instruction=strided_instruction(True, 5, 1, 1, 2, 8),
             vtype=0xc8, avl=4, start=0, base=32, stride=3, seed=82),
        dict(name='unit-load-vstart-vlmax',
             instruction=memory_instruction(False, 5, 1, 1, 8),
             vtype=0xc0, avl=16, start=16, base=33, seed=83,
             expected_trap=0, expect_no_requests=True),
        dict(name='unit-store-vstart-past-vlmax',
             instruction=memory_instruction(True, 5, 1, 1, 8),
             vtype=0xc0, avl=3, start=17, base=33, seed=84,
             expected_trap=0, expect_no_requests=True),
        dict(name='segment-load-vstart-vlmax',
             instruction=segment_instruction(False, 5, 2, 1, 1, 8),
             vtype=0xc0, avl=16, start=16, base=33, seed=85,
             expected_trap=0, expect_no_requests=True),
        dict(name='fof-load-vstart-vlmax',
             instruction=fof_instruction(5, 1, 1, 8),
             vtype=0xc0, avl=16, start=16, base=33, seed=86,
             expected_trap=0, expect_no_requests=True),
        dict(name='unit-load-zero-vl',
             instruction=memory_instruction(False, 5, 1, 1, 8),
             vtype=0xc0, avl=0, start=0, base=512, seed=87, edge=True,
             expected_trap=0, expect_no_requests=True),
        dict(name='segment-load-zero-vl',
             instruction=segment_instruction(False, 5, 2, 1, 1, 8),
             vtype=0xc0, avl=0, start=0, base=512, seed=88, edge=True,
             expected_trap=0, expect_no_requests=True),
        dict(name='fof-load-zero-vl',
             instruction=fof_instruction(5, 1, 1, 8),
             vtype=0xc0, avl=0, start=0, base=512, seed=89, edge=True,
             expected_trap=0, expect_no_requests=True),
        dict(name='unit-load-e64-edge',
             instruction=memory_instruction(False, 7, 1, 1, 8),
             vtype=0xd8, avl=2, start=0, base=504, seed=90, edge=True,
             expected_trap=1),
        dict(name='unit-store-e64-edge',
             instruction=memory_instruction(True, 7, 1, 1, 8),
             vtype=0xd8, avl=2, start=0, base=504, seed=91, edge=True,
             expected_trap=1),
        dict(name='whole-load-e64-edge',
             instruction=whole_instruction(False, 7, 1, 1, 24),
             vtype=0xff, avl=0, start=0, base=504, seed=92, edge=True,
             expected_trap=1),
        dict(name='segment-load-e64-edge',
             instruction=segment_instruction(False, 7, 2, 1, 1, 8),
             vtype=0xd8, avl=2, start=0, base=504, seed=93, edge=True,
             expected_trap=1),
        dict(name='fof-load-e64-edge',
             instruction=fof_instruction(7, 1, 1, 8),
             vtype=0xd8, avl=2, start=0, base=504, seed=94, edge=True,
             expected_trap=0, expected_vl=1),
    ])
    for store in (False, True):
        cases.extend([
            dict(name=f'unit-edge-{store}',
                 instruction=memory_instruction(store, 0, 1, 1, 8),
                 vtype=0xc0, avl=4, start=0, base=510, seed=81 + int(store), edge=True),
            dict(name=f'whole-edge-{store}',
                 instruction=whole_instruction(store, 0, 1, 1, 8 if store else 24),
                 vtype=0xff, avl=0, start=0, base=510, seed=83 + int(store), edge=True),
            dict(name=f'mask-edge-{store}',
                 instruction=mask_instruction(store, 1, 8 if store else 24),
                 vtype=0xc1, avl=17, start=0, base=510, seed=85 + int(store), edge=True),
            dict(name=f'strided-edge-{store}',
                 instruction=strided_instruction(store, 0, 1, 1, 2, 8),
                 vtype=0xc0, avl=4, start=0, base=508, stride=4,
                 seed=87 + int(store), edge=True),
            dict(name=f'indexed-edge-{store}',
                 instruction=indexed_instruction(store, 0, 1, 1, 16, 8),
                 vtype=0xc0, avl=4, start=0, base=508, seed=117 + int(store),
                 edge=True, index_pattern=2),
        ])
    cases.append(dict(name='indexed-edge-masked',
                      instruction=indexed_instruction(False, 0, 0, 1, 16, 8),
                      vtype=0xc0, avl=4, start=0, base=508, seed=121,
                      edge=True, index_pattern=2))
    for width in widths:
        sew = width - 4 if width else 0
        for vm in (0, 1):
            cases.append(dict(name=f'fof-normal-{width}-{vm}',
                              instruction=fof_instruction(width, vm, 1, 8),
                              vtype=0xc0 | (sew << 3), avl=4, start=0,
                              base=32, seed=91 + width + vm))
    cases.extend([
        dict(name='fof-edge-trim', instruction=fof_instruction(0, 1, 1, 8),
             vtype=0xc0, avl=4, start=0, base=510, seed=105, edge=True),
        dict(name='fof-edge-masked-trim', instruction=fof_instruction(0, 0, 1, 8),
             vtype=0xc0, avl=4, start=0, base=510, seed=110, edge=True),
        dict(name='fof-edge-first', instruction=fof_instruction(0, 1, 1, 8),
             vtype=0xc0, avl=4, start=0, base=512, seed=106, edge=True),
        dict(name='fof-edge-masked-first', instruction=fof_instruction(0, 0, 1, 8),
             vtype=0xc0, avl=4, start=0, base=512, seed=138, edge=True,
             expected_trap=0, expected_vl=1),
        dict(name='fof-edge-restart-trim', instruction=fof_instruction(0, 1, 1, 8),
             vtype=0xc0, avl=4, start=1, base=511, seed=2, edge=True,
             expected_trap=0, expected_vl=1),
        dict(name='fof-edge-masked-restart-trim', instruction=fof_instruction(0, 0, 1, 8),
             vtype=0xc0, avl=4, start=1, base=511, seed=3, edge=True,
             expected_trap=0, expected_vl=1),
        dict(name='fof-misaligned-first', instruction=fof_instruction(5, 1, 1, 8),
             vtype=0xc8, avl=4, start=0, base=33, seed=107),
        dict(name='fof-misaligned-restart', instruction=fof_instruction(5, 1, 1, 8),
             vtype=0xc8, avl=4, start=1, base=33, seed=108),
        dict(name='fof-store-illegal',
             instruction=memory_instruction(True, 0, 1, 1, 8) | (16 << 20),
             vtype=0xc0, avl=4, start=0, base=32, seed=109),
    ])

    for case in cases:
        state.gpr[1] = case['avl']
        reference.run([(case['vtype'] << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        reference.run([(0xc21 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['rtl_vtype'] = state.gpr[3]
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['rtl_vl'] = state.gpr[3]
        vector = VectorState()
        for reg in range(32):
            for byte in range(16):
                vector.reg[reg][byte] = seeded_byte(reg * 16 + byte, case['seed'], True)
        if case.get('index_pattern'):
            index_reg = (case['instruction'] >> 20) & 31
            width = (case['instruction'] >> 12) & 7
            index_bytes = 1 << (width - 4 if width else 0)
            for index in range(16):
                offset = indexed_offset(index, case['seed'], case['index_pattern'])
                for byte in range(index_bytes):
                    position = index_reg * 16 + index * index_bytes + byte
                    if position < 512:
                        vector.reg[position // 16][position % 16] = (offset >> (byte * 8)) & 255
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        window_base = MEMORY_EDGE if case.get('edge') else MEMORY_BASE
        reference.write(window_base,
                        bytes(seeded_byte(index, case['seed'], False) for index in range(512)))
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        state.gpr[1] = window_base + case['base']
        stride_reg = case.get('stride_reg', 2)
        if stride_reg:
            state.gpr[stride_reg] = case.get('stride', 0) & reference.mask
        pc = reference.run([case['instruction']])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        if ('expected_trap' in case and
                case['nemu_trap'] != case['expected_trap']):
            raise RuntimeError(f'Unexpected NEMU admission for {case["name"]}')
        case['nemu_cause'] = int(state.mcause[0]) if case['nemu_trap'] else 0
        case['nemu_tval'] = int(state.mtval[0]) if case['nemu_trap'] else 0
        if case['nemu_trap'] and state.mepc[0] != pc:
            raise RuntimeError(f'Unexpected trap PC for {case["name"]}')
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vl'] = state.gpr[3]
        if ('expected_vl' in case and case['nemu_vl'] != case['expected_vl']):
            raise RuntimeError(f'Unexpected NEMU VL for {case["name"]}')
        case['nemu_fof'] = int(not case['nemu_trap'] and
                               case['nemu_vl'] != case['rtl_vl'])
        reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vstart'] = state.gpr[3]
        if case.get('expect_no_requests') and (
                case['nemu_trap'] or case['nemu_vstart'] != 0):
            raise RuntimeError(f'No-op vector memory instruction trapped: {case["name"]}')
        if case.get('reserved_whole_start') and (
                case['nemu_trap'] != 1 or case['nemu_cause'] != 2 or
                case['nemu_vstart'] != case['start']):
            raise RuntimeError(f'Invalid whole-register start accepted: {case["name"]}')
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu_vector'] = bytes(byte for reg in vector.reg for byte in reg).hex()
        case['nemu_memory'] = reference.read(window_base, 512).hex()

    vectors = args.output / 'vectors.txt'
    vectors.write_text(''.join(
        f'{case["instruction"]:x} {case["rtl_vtype"]:x} {case["rtl_vl"]:x} '
        f'{case["start"]:x} {case["base"]:x} '
        f'{case.get("stride", 0) & reference.mask:x} {case["seed"]:x} '
        f'{case.get("index_pattern", 0):x}\n' for case in cases))
    rtl = ROOT / 'hdl/backend/vpu/rapt_vpu_memory.sv'
    testbench = ROOT / 'verify/nemu/tb_vector_memory_rtl.sv'
    build = args.output / 'obj_dir'
    command = ['verilator', '--binary', '--timing', '-Wall', '--top-module',
               'tb_vector_memory_rtl', '--Mdir', str(build), f'-GXLEN={args.xlen}',
               '-I' + str(ROOT / 'hdl/include'), str(rtl), str(testbench)]
    with (args.output / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([build / 'Vtb_vector_memory_rtl', '+vectors=' + str(vectors)],
                            capture_output=True, text=True, check=True)
    (args.output / 'run.log').write_text(result.stdout + result.stderr)
    outputs = [line.split() for line in result.stdout.splitlines()
               if line.startswith('VECTOR_MEMORY_RESULT ')]
    if len(outputs) != len(cases):
        raise RuntimeError(f'RTL produced {len(outputs)} results for {len(cases)} cases')
    failures = []
    for case, output in zip(cases, outputs):
        if len(output) != 12:
            raise RuntimeError(f'Malformed RTL result: {output[:8]}')
        (_, trap, update, fof, cause, tval, vl, vstart,
         vector_requests, memory_requests, rtl_vector, rtl_memory) = output
        expected_tval = (case['nemu_tval'] -
                         (MEMORY_EDGE if case.get('edge') else MEMORY_BASE))
        match = (case['nemu_trap'] == int(trap) and
                 case['nemu_vector'] == rtl_vector and
                 case['nemu_memory'] == rtl_memory and
                 int(fof) == case['nemu_fof'] and
                 int(vl, 16) == (case['nemu_vl'] if case['nemu_fof'] else 0) and
                 (case['nemu_trap'] == 0 or int(cause, 16) == case['nemu_cause']) and
                 (case['nemu_cause'] not in (4, 5, 6, 7) or
                  int(tval, 16) == expected_tval) and
                 int(update) == int(case['nemu_cause'] != 2) and
                 int(vstart, 16) == (case['nemu_vstart'] if update == '1' else 0) and
                 (case['nemu_cause'] != 2 or
                  (int(vector_requests) == 0 and int(memory_requests) == 0)) and
                 (not case.get('expect_no_requests') or
                  (int(vector_requests) == 0 and int(memory_requests) == 0)) and
                 (not case.get('expect_requests') or
                  (int(vector_requests) > 0 and int(memory_requests) > 0)))
        if not match:
            first_vector = next((index for index, (actual, expected) in enumerate(zip(
                bytes.fromhex(case['nemu_vector']), bytes.fromhex(rtl_vector)))
                if actual != expected), None)
            first_memory = next((index for index, (actual, expected) in enumerate(zip(
                bytes.fromhex(case['nemu_memory']), bytes.fromhex(rtl_memory)))
                if actual != expected), None)
            failures.append(dict(name=case['name'], instruction=case['instruction'],
                                 vtype=case['rtl_vtype'], vl=case['rtl_vl'],
                                 start=case['start'], stride=case.get('stride', 0),
                                 index_pattern=case.get('index_pattern', 0),
                                 seed=case['seed'],
                                 nemu_trap=case['nemu_trap'], nemu_cause=case['nemu_cause'],
                                 nemu_tval=case['nemu_tval'], nemu_vl=case['nemu_vl'],
                                 nemu_fof=case['nemu_fof'], rtl_fof=int(fof),
                                 rtl_vl=int(vl, 16),
                                 rtl_trap=int(trap),
                                 rtl_update=int(update), rtl_cause=int(cause, 16),
                                 rtl_tval=int(tval, 16), nemu_vstart=case['nemu_vstart'],
                                 rtl_vstart=int(vstart, 16),
                                 rtl_vector_requests=int(vector_requests),
                                 rtl_memory_requests=int(memory_requests),
                                 first_vector=first_vector,
                                 first_memory=first_memory))
    report = dict(xlen=args.xlen, cases=len(cases), failures=failures,
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                  rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),
                  testbench_sha256=hashlib.sha256(testbench.read_bytes()).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_MEMORY_RTL xlen={args.xlen} cases={len(cases)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
