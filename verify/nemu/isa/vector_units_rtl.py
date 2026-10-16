"""Compare NEMU vector operators with independent, block-scoped RTL testbenches."""

import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess

from isa.vector_data import VectorAPI, VectorState, group_move_instruction, instruction
from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]


FORMS = {
    0x00: (0, 3, 4),
    0x02: (0, 4),
    0x03: (3, 4),
    0x04: (0, 4), 0x05: (0, 4), 0x06: (0, 4), 0x07: (0, 4),
    0x09: (0, 3, 4), 0x0a: (0, 3, 4), 0x0b: (0, 3, 4),
    0x10: (0, 3, 4), 0x11: (0, 3, 4),
    0x12: (0, 4), 0x13: (0, 4),
    0x25: (0, 3, 4), 0x28: (0, 3, 4), 0x29: (0, 3, 4),
    0x18: (0, 3, 4), 0x19: (0, 3, 4),
    0x1a: (0, 4), 0x1b: (0, 4),
    0x1c: (0, 3, 4), 0x1d: (0, 3, 4),
    0x1e: (3, 4), 0x1f: (3, 4),
}


def signed(value, bits):
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


OPERATIONS = ((1, 'prefix'), (2, 'prefix'), (3, 'prefix'),
              (16, 'iota'), (17, 'index'), (16, 'compress'))


def seeded_bytes(seed):
    return bytes((index * 29 + (index // 16) * 37 + seed * 13) & 255
                 for index in range(512))


def mask_bit(data, register, index):
    return (data[register * 16 + index // 8] >> (index % 8)) & 1


def expected_state(case, legal):
    initial = seeded_bytes(case['seed'])
    expected = bytearray(initial)
    if not legal:
        return bytes(expected)
    element_bytes = 1 << case['sew']
    destination = case['destination']
    source = case['source']
    source1 = case['source1']
    count = 0
    seen = False
    for index in range(case['start'], case['vl']):
        if case['operation'] != 'compress' and not case['vm'] and not mask_bit(initial, 0, index):
            continue
        if case['operation'] == 'prefix':
            source_bit = mask_bit(initial, source, index)
            result = not seen and (source1 == 3 or
                                   (source_bit if source1 == 2 else not source_bit))
            address = destination * 16 + index // 8
            bit = 1 << (index % 8)
            expected[address] = expected[address] & ~bit | (bit if result else 0)
            seen |= bool(source_bit)
        elif case['operation'] == 'iota':
            address = destination * 16 + index * element_bytes
            expected[address:address + element_bytes] = count.to_bytes(element_bytes, 'little')
            count += mask_bit(initial, source, index)
        elif case['operation'] == 'index':
            address = destination * 16 + index * element_bytes
            expected[address:address + element_bytes] = index.to_bytes(element_bytes, 'little')
        elif mask_bit(initial, source1, index):
            address = destination * 16 + count * element_bytes
            source_address = source * 16 + index * element_bytes
            expected[address:address + element_bytes] = initial[
                source_address:source_address + element_bytes]
            count += 1
    return bytes(expected)


def alu_cases(reference, vector_api, xlen):
    state = reference.state
    rng = random.Random(0x23a1)
    cases = []

    for sew in range(4):
        bits = 8 << sew
        mask = (1 << bits) - 1
        sign = 1 << (bits - 1)
        state.gpr[1] = 1
        vtype = 0xc0 | (sew << 3)
        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        pairs = [(0, 0), (mask, 1), (1, mask), (sign, 1),
                 (sign - 1, sign), (mask, mask)]
        pairs.extend((rng.getrandbits(bits), rng.getrandbits(bits)) for _ in range(12))
        for function, forms in FORMS.items():
            for form in forms:
                for left, right in pairs:
                    carry = 0x10 <= function <= 0x13
                    if carry:
                        variants = ((0, 0), (0, 1))
                        if function & 1:
                            variants += ((1, 0), (1, 1))
                    else:
                        variants = ((1, 0),)
                    for vm, mask_bit in variants:
                        source1 = 2 if form == 0 else 5 if form == 4 else right & 31
                        scalar = right & reference.mask
                        operand = right if form == 0 else (
                            (source1 if function in (0x25, 0x28, 0x29) else signed(source1, 5))
                            if form == 3 else signed(scalar, xlen))
                        seeded = VectorState()
                        seeded.reg[0][0] = mask_bit
                        for byte in range(bits // 8):
                            seeded.reg[1][byte] = left >> (byte * 8)
                            seeded.reg[2][byte] = right >> (byte * 8)
                        if vector_api.set_state(0, ctypes.byref(seeded)):
                            raise RuntimeError('cannot seed vector registers')
                        state.gpr[5] = scalar
                        pc = reference.run([instruction(function, vm, 1, source1, form, 3)])
                        if state.pc[0] != pc + 4:
                            raise RuntimeError(
                                f'NEMU trapped on legal vector instruction {function:x}/{form}/{vm}')
                        actual_state = VectorState()
                        if vector_api.get_state(0, ctypes.byref(actual_state)):
                            raise RuntimeError('cannot read vector registers')
                        mask_result = 0x18 <= function <= 0x1f or (carry and function & 1)
                        actual = actual_state.reg[3][0] & 1 if mask_result else sum(
                            int(actual_state.reg[3][byte]) << (byte * 8)
                            for byte in range(bits // 8))
                        cases.append(dict(function=function, form=form, sew=sew,
                                          left=left, right=right,
                                          operand=operand & ((1 << 64) - 1),
                                          mask_bit=mask_bit if vm == 0 else 0,
                                          mask_logic=0, actual=actual))

        for function in range(0x18, 0x20):
            for left in (0, 1):
                for right in (0, 1):
                    seeded = VectorState()
                    seeded.reg[1][0] = left
                    seeded.reg[2][0] = right
                    if vector_api.set_state(0, ctypes.byref(seeded)):
                        raise RuntimeError('cannot seed mask registers')
                    pc = reference.run([instruction(function, 1, 1, 2, 2, 3)])
                    if state.pc[0] != pc + 4:
                        raise RuntimeError(f'NEMU trapped on mask logic {function:x}')
                    actual_state = VectorState()
                    if vector_api.get_state(0, ctypes.byref(actual_state)):
                        raise RuntimeError('cannot read mask result')
                    cases.append(dict(function=function, form=2, sew=sew,
                                      left=left, right=right, operand=right,
                                      mask_bit=0, mask_logic=1,
                                      actual=actual_state.reg[3][0] & 1))

    return cases, ''.join(
        f'{case["function"]:x} {case["sew"]:x} {case["left"]:x} {case["operand"]:x} '
        f'{case["mask_bit"]:x} {case["mask_logic"]:x}\n'
        for case in cases)


def muldiv_cases(reference, vector_api, xlen):
    state = reference.state
    rng = random.Random(0x23d1)
    cases = []

    for sew in range(4):
        bits = 8 << sew
        mask = (1 << bits) - 1
        sign = 1 << (bits - 1)
        state.gpr[1] = 1
        vtype = 0xc0 | (sew << 3)
        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        pairs = [(0, 0), (mask, 0), (1, 0), (sign, mask), (sign, 1),
                 (sign - 1, 2), (mask, 1), (mask, mask), (3, 2), (4, mask)]
        pairs.extend((rng.getrandbits(bits), rng.getrandbits(bits)) for _ in range(12))
        for operation in range(8):
            for form in (2, 6):
                for left, right in pairs:
                    scalar = right & reference.mask
                    operand = right if form == 2 else scalar
                    if form == 6 and scalar & (1 << (xlen - 1)):
                        operand |= ((1 << 64) - 1) ^ reference.mask
                    seeded = VectorState()
                    for byte in range(bits // 8):
                        seeded.reg[1][byte] = left >> (byte * 8)
                        seeded.reg[2][byte] = right >> (byte * 8)
                    if vector_api.set_state(0, ctypes.byref(seeded)):
                        raise RuntimeError('cannot seed vector registers')
                    state.gpr[5] = scalar
                    pc = reference.run([instruction(0x20 + operation, 1, 1,
                                                    2 if form == 2 else 5, form, 3)])
                    if state.pc[0] != pc + 4:
                        raise RuntimeError(f'NEMU trapped on muldiv {operation}/{form}')
                    actual_state = VectorState()
                    if vector_api.get_state(0, ctypes.byref(actual_state)):
                        raise RuntimeError('cannot read vector registers')
                    actual = sum(int(actual_state.reg[3][byte]) << (byte * 8)
                                 for byte in range(bits // 8))
                    cases.append(dict(operation=operation, sew=sew, form=form,
                                      left=left, right=right, operand=operand, actual=actual))

    return cases, ''.join(
        f'{case["operation"]:x} {case["sew"]:x} {case["left"]:x} '
        f'{case["operand"]:x}\n' for case in cases)


def reduce_cases(reference, vector_api, xlen):
    state = reference.state

    cases = []
    for sew in range(4):
        for lmul in (0, 1, 2):
            vtype = 0xc0 | (sew << 3) | lmul
            maximum = (16 << lmul) >> sew
            for function in (*range(8), 0x30, 0x31):
                if function >= 0x30 and sew == 3:
                    continue
                form = 0 if function >= 0x30 else 2
                for vm in (0, 1):
                    for destination in (8, 9, 24):
                        cases.append(dict(
                            name=f'reduce-{function:x}-e{8 << sew}-m{1 << lmul}-'
                                 f'vm{vm}-vd{destination}',
                            instruction=instruction(function, vm, 8, 9, form, destination),
                            vtype=vtype, avl=min(maximum, 5), start=0,
                            seed=(function * 17 + sew * 11 + lmul * 7 + vm * 3 + destination)))
    cases.extend([
        dict(name='reduce-vl-zero', instruction=instruction(0, 1, 8, 9, 2, 24),
             vtype=0xc0, avl=0, start=0, seed=201),
        dict(name='reduce-vstart-illegal', instruction=instruction(0, 1, 8, 9, 2, 24),
             vtype=0xc0, avl=4, start=1, seed=202),
        dict(name='reduce-source-unaligned', instruction=instruction(0, 1, 9, 9, 2, 24),
             vtype=0xc1, avl=4, start=0, seed=203),
        dict(name='reduce-wide-e64-illegal',
             instruction=instruction(0x30, 1, 8, 9, 0, 24),
             vtype=0xd8, avl=2, start=0, seed=204),
        dict(name='reduce-vill-illegal', instruction=instruction(0, 1, 8, 9, 2, 24),
             vtype=0xff, avl=4, start=0, seed=205),
        dict(name='reduce-dest-mask', instruction=instruction(0, 0, 8, 9, 2, 0),
             vtype=0xc0, avl=6, start=0, seed=206),
        dict(name='reduce-masked-data-v0', instruction=instruction(0, 0, 0, 9, 2, 24),
             vtype=0xc0, avl=6, start=0, seed=207, expected_trap=0),
        dict(name='reduce-masked-seed-v0', instruction=instruction(0, 0, 8, 0, 2, 24),
             vtype=0xc0, avl=6, start=0, seed=208, expected_trap=0),
        dict(name='reduce-unmasked-data-v0', instruction=instruction(0, 1, 0, 9, 2, 24),
             vtype=0xc0, avl=6, start=0, seed=209),
        dict(name='reduce-wide-source-eew-overlap',
             instruction=instruction(0x30, 1, 8, 9, 0, 24),
             vtype=0xc1, avl=4, start=0, seed=210, expected_trap=1),
        dict(name='reduce-wide-source-eew-disjoint',
             instruction=instruction(0x30, 1, 8, 10, 0, 24),
             vtype=0xc1, avl=4, start=0, seed=211, expected_trap=0),
        dict(name='reduce-same-eew-source-overlap',
             instruction=instruction(0, 1, 8, 9, 2, 24),
             vtype=0xc1, avl=4, start=0, seed=212, expected_trap=0),
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
                index = reg * 16 + byte
                vector.reg[reg][byte] = (index * 29 + reg * 37 + case['seed'] * 13) & 255
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        pc = reference.run([case['instruction']])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        if ('expected_trap' in case and
                case['nemu_trap'] != case['expected_trap']):
            raise RuntimeError(f'Unexpected NEMU admission for {case["name"]}')
        if case['nemu_trap'] and (state.mcause[0] != 2 or state.mepc[0] != pc):
            raise RuntimeError(f'Unexpected NEMU trap for {case["name"]}')
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu_state'] = bytes(byte for reg in vector.reg for byte in reg).hex()

    return cases, ''.join(
        f'{case["instruction"]:x} {case["rtl_vtype"]:x} {case["rtl_vl"]:x} '
        f'{case["start"]:x} {case["seed"]:x}\n' for case in cases)


def mask_scan_cases(reference, vector_api, xlen):
    state = reference.state

    cases = []
    for sew in range(4):
        for lmul in (0, 3):
            vtype = 0xc0 | (sew << 3) | lmul
            for avl in (0, 1, 7, 16, 128):
                for first in (False, True):
                    for vm in (0, 1):
                        for source in (0, 8, 31):
                            for seed in (3, 79):
                                cases.append(dict(
                                    name=f'scan-{first}-e{8 << sew}-m{1 << lmul}-'
                                         f'avl{avl}-vm{vm}-src{source}-seed{seed}',
                                    vtype=vtype, avl=avl, first=first, vm=vm,
                                    source=source, start=0, seed=seed))
    cases.extend([
        dict(name='scan-vstart-illegal', vtype=0xc0, avl=8,
             first=False, vm=1, source=8, start=1, seed=101),
        dict(name='scan-vill-illegal', vtype=0xff, avl=8,
             first=True, vm=1, source=8, start=0, seed=102),
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
                index = reg * 16 + byte
                vector.reg[reg][byte] = (index * 29 + reg * 37 + case['seed'] * 13) & 255
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        expected_vector = bytes(byte for reg in vector.reg for byte in reg)
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        encoded = instruction(0x10, case['vm'], case['source'],
                              17 if case['first'] else 16, 2, 3)
        pc = reference.run([encoded])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        if case['nemu_trap'] and (state.mcause[0] != 2 or state.mepc[0] != pc):
            raise RuntimeError(f'Unexpected NEMU trap for {case["name"]}')
        case['nemu_value'] = state.gpr[3] if not case['nemu_trap'] else None
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        if bytes(byte for reg in vector.reg for byte in reg) != expected_vector:
            raise RuntimeError(f'NEMU changed vector registers for {case["name"]}')

    return cases, ''.join(
        f'{int(case["first"]):x} {1-case["vm"]:x} '
        f'{int(bool(case["rtl_vtype"] & (1 << (xlen - 1)))):x} '
        f'{case["source"]:x} {case["rtl_vl"]:x} '
        f'{case["start"]:x} {case["seed"]:x}\n' for case in cases)


def slide_cases(reference, vector_api, xlen):
    state = reference.state

    cases = []
    for sew in range(4):
        for lmul in (0, 3):
            maximum = (128 >> (sew + 3)) << lmul
            for avl in (0, 1, 7, maximum):
                for function, form in ((0x0e, 3), (0x0e, 4), (0x0e, 6),
                                       (0x0f, 3), (0x0f, 4), (0x0f, 6)):
                    for vm in (0, 1):
                        for seed in (3, 79):
                            source = 8
                            destination = source if function == 0x0f and seed == 79 else 16
                            offset = (0, 1, 5, xlen * 17 + 1)[
                                (sew + lmul + seed // 3) % 4]
                            if form == 3:
                                offset &= 31
                            else:
                                offset &= reference.mask
                            scalar = (0x80 if seed == 3 else reference.mask)
                            sign = 1 << (xlen - 1)
                            cases.append(dict(sew=sew, lmul=lmul, avl=avl,
                                              function=function, form=form, vm=vm,
                                              seed=seed, source=source,
                                              destination=destination,
                                              offset=offset, scalar=scalar,
                                              rtl_scalar=((scalar ^ sign) - sign) & ((1 << 64) - 1),
                                              start=0 if seed == 3 else
                                              1 if avl >= 7 else min(avl + 1, 127)))

    for case in cases:
        state.gpr[1] = case['avl']
        vtype = 0xc0 | (case['sew'] << 3) | case['lmul']
        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['vl'] = state.gpr[3]
        group = 1 << case['lmul']
        seeded = VectorState()
        for reg in range(32):
            for byte in range(16):
                byte_index = reg * 16 + byte
                seeded.reg[reg][byte] = (byte_index * 29 + reg * 37 + case['seed'] * 13) & 255
        if vector_api.set_state(0, ctypes.byref(seeded)):
            raise RuntimeError('cannot seed vector registers')
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        state.gpr[5] = case['scalar'] if case['form'] == 6 else case['offset']
        source1 = case['offset'] if case['form'] == 3 else 5
        pc = reference.run([instruction(case['function'], case['vm'], case['source'],
                                        source1, case['form'], case['destination'])])
        if state.pc[0] != pc + 4:
            raise RuntimeError(f'NEMU trapped on legal slide {case}')
        result = VectorState()
        if vector_api.get_state(0, ctypes.byref(result)):
            raise RuntimeError('cannot read vector registers')
        case['nemu'] = bytes(byte for reg in result.reg[case['destination']:
                                                      case['destination'] + group]
                             for byte in reg)

    return cases, ''.join(
        f'{int(case["function"] == 0x0e):x} {int(case["form"] == 6):x} '
        f'{1-case["vm"]:x} {case["sew"]:x} {case["lmul"]:x} '
        f'{case["source"]:x} {case["destination"]:x} {case["vl"]:x} '
        f'{case["start"]:x} {case["offset"]:x} '
        f'{case["rtl_scalar"]:x} '
        f'{case["seed"]:x}\n' for case in cases)


def gather_cases(reference, vector_api, xlen):
    state = reference.state

    cases = []
    for sew in range(4):
        for lmul in (0, 1, 3):
            maximum = (128 >> (sew + 3)) << lmul
            for avl in (0, 3, maximum):
                for function, form in ((0x0c, 0), (0x0c, 3), (0x0c, 4),
                                       (0x0e, 0), (0x0c, 6)):
                    for vm in (0, 1):
                        for seed in (3, 79):
                            destinations = (24, 8, 16) if form == 0 else (24, 8)
                            for destination in destinations:
                                cases.append(dict(sew=sew, lmul=lmul, avl=avl,
                                                  function=function, form=form,
                                                  vm=vm, seed=seed, destination=destination,
                                                  source=8, index_reg=16,
                                                  start=0 if seed == 3 else 1))

    for case in cases:
        vtype = 0xc0 | (case['sew'] << 3) | case['lmul']
        state.gpr[1] = case['avl']
        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['vl'] = state.gpr[3]
        case['maximum'] = (128 >> (case['sew'] + 3)) << case['lmul']
        raw = seeded_bytes(case['seed'])
        vector = VectorState()
        for reg in range(32):
            for byte in range(16):
                vector.reg[reg][byte] = raw[reg * 16 + byte]
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        state.gpr[5] = (case['maximum'] - 1 if case['seed'] == 3 else reference.mask)
        selector = case['index_reg'] if case['form'] == 0 else (
            5 if case['form'] == 4 else (case['seed'] + case['sew'] * 3) & 31)
        encoded = instruction(case['function'], case['vm'], case['source'],
                              selector, case['form'], case['destination'])
        case['instruction'] = encoded
        pc = reference.run([encoded])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        if case['nemu_trap'] and (state.mcause[0] != 2 or state.mepc[0] != pc):
            raise RuntimeError(f'Unexpected NEMU trap for {case}')
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu'] = bytes(byte for reg in vector.reg for byte in reg)
        case['scalar'] = state.gpr[5]

    return cases, ''.join(f'{case["instruction"]:x} '
                               f'{0xc0 | (case["sew"] << 3) | case["lmul"]:x}\n'
                               for case in cases)


def mask_ops_cases(reference, vector_api, xlen):
    state = reference.state

    cases = []
    for sew in range(4):
        for lmul in (0, 1, 3):
            maximum = (128 >> (sew + 3)) << lmul
            for avl in (0, 3, maximum):
                for source1, operation in OPERATIONS:
                    for vm in (0, 1):
                        for seed in (3, 79):
                            for destination in (0, 8, 16, 24):
                                for start in (0, 1):
                                    source = 0 if operation == 'index' else 8
                                    cases.append(dict(sew=sew, lmul=lmul, avl=avl,
                                                      source1=source1, operation=operation,
                                                      vm=vm, seed=seed, destination=destination,
                                                      source=source, start=start))

    for case in cases:
        vtype = 0xc0 | (case['sew'] << 3) | case['lmul']
        state.gpr[1] = case['avl']
        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['vl'] = state.gpr[3]
        raw = seeded_bytes(case['seed'])
        vector = VectorState()
        for reg in range(32):
            for byte in range(16):
                vector.reg[reg][byte] = raw[reg * 16 + byte]
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        encoded = instruction(0x17 if case['operation'] == 'compress' else 0x14,
                              case['vm'], case['source'], case['source1'], 2,
                              case['destination'])
        case['instruction'] = encoded
        pc = reference.run([encoded])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        if case['nemu_trap'] and (state.mcause[0] != 2 or state.mepc[0] != pc):
            raise RuntimeError(f'Unexpected NEMU trap for {case}')
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu'] = bytes(byte for reg in vector.reg for byte in reg)

    return cases, ''.join(f'{case["instruction"]:x} '
                               f'{0xc0 | (case["sew"] << 3) | case["lmul"]:x} '
                               f'{case["start"]:x}\n' for case in cases)


def move_cases(reference, vector_api, xlen):
    state = reference.state

    cases = []
    for sew in range(4):
        vtype = 0xc0 | (sew << 3)
        for registers in (1, 2, 4, 8):
            effective_length = registers * 16 // (1 << sew)
            starts = (0, 1, effective_length - 1)
            if effective_length < 128:
                starts += (effective_length,)
            for start in starts:
                for seed in (1, 79):
                    cases.append(dict(name=f'move{registers}-e{8 << sew}-start{start}',
                                      instruction=group_move_instruction(registers, 8, 24),
                                      vtype=vtype, start=start, seed=seed,
                                      expected_trap=int(start >= effective_length)))
        cases.append(dict(name=f'self-move-e{8 << sew}',
                          instruction=group_move_instruction(1, 8, 8),
                          vtype=vtype, start=1, seed=sew, expected_trap=0))
    cases.extend([
        dict(name='vill', instruction=group_move_instruction(1, 8, 24),
             vtype=0xff, start=0, seed=5, expected_trap=1),
        dict(name='nregs3', instruction=group_move_instruction(3, 8, 24),
             vtype=0xc0, start=0, seed=6, expected_trap=1),
        dict(name='source-align', instruction=group_move_instruction(2, 9, 24),
             vtype=0xc0, start=0, seed=7, expected_trap=1),
        dict(name='destination-align', instruction=group_move_instruction(2, 8, 25),
             vtype=0xc0, start=0, seed=8, expected_trap=1),
        dict(name='masked', instruction=group_move_instruction(1, 8, 24, vm=0),
             vtype=0xc0, start=0, seed=9, expected_trap=1),
    ])

    for case in cases:
        state.gpr[1] = 0
        reference.run([(case['vtype'] << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
        reference.run([(0xc21 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['rtl_vtype'] = state.gpr[3]
        vector = VectorState()
        for reg in range(32):
            for byte in range(16):
                index = reg * 16 + byte
                vector.reg[reg][byte] = (index * 29 + reg * 37 + case['seed'] * 13) & 255
        case['initial_state'] = bytes(byte for reg in vector.reg for byte in reg).hex()
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        pc = reference.run([case['instruction']])
        case['nemu_trap'] = int(state.mcause[0] == 2 and state.mepc[0] == pc)
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu_state'] = bytes(byte for reg in vector.reg for byte in reg).hex()

    return cases, ''.join(
        f'{case["instruction"]:x} {case["rtl_vtype"]:x} {case["start"]:x} {case["seed"]:x}\n'
        for case in cases)


def compare_elements(cases, outputs):
    return [dict(case=case, rtl=expected) for case, expected in zip(cases, outputs)
            if case['actual'] != expected]


def compare_reduce(cases, outputs):
    failures = []
    for case, (rtl_trap, rtl_state) in zip(cases, outputs):
        if case['nemu_trap'] != int(rtl_trap) or case['nemu_state'] != rtl_state:
            first_mismatch = next((index for index, (nemu_byte, rtl_byte) in enumerate(
                zip(bytes.fromhex(case['nemu_state']), bytes.fromhex(rtl_state)))
                if nemu_byte != rtl_byte), None)
            failures.append(dict(name=case['name'], instruction=case['instruction'],
                                 vtype=case['vtype'], start=case['start'], seed=case['seed'],
                                 nemu_trap=case['nemu_trap'], rtl_trap=int(rtl_trap),
                                 first_mismatch=first_mismatch))
    return failures


def compare_mask_scan(cases, outputs):
    failures = []
    for case, output in zip(cases, outputs):
        if len(output) != 3:
            raise RuntimeError(f'Malformed RTL output: {output}')
        rtl_trap, rtl_value = int(output[1]), int(output[2], 16)
        if case['nemu_trap'] != rtl_trap or (
                not rtl_trap and case['nemu_value'] != rtl_value):
            failures.append(dict(name=case['name'], vtype=case['vtype'],
                                 avl=case['avl'], vl=case['rtl_vl'],
                                 source=case['source'], vm=case['vm'],
                                 start=case['start'], seed=case['seed'],
                                 nemu_trap=case['nemu_trap'], rtl_trap=rtl_trap,
                                 nemu_value=case['nemu_value'], rtl_value=rtl_value))
    return failures


def compare_slide(cases, outputs):
    failures = []
    for case, output in zip(cases, outputs):
        group = 1 << case['lmul']
        rtl_bytes = int(output[1], 16).to_bytes(128, 'little')[:group * 16]
        if case['nemu'] != rtl_bytes:
            failures.append(dict(case={key: value for key, value in case.items()
                                       if key != 'nemu'}, nemu=case['nemu'].hex(),
                                 rtl=rtl_bytes.hex()))
    return failures


def compare_gather(cases, outputs):
    failures = []
    for case, output in zip(cases, outputs):
        legal = int(output[1])
        expected = bytearray(seeded_bytes(case['seed']))
        if legal:
            element_bytes = 1 << case['sew']
            index_bytes = 2 if case['function'] == 0x0e else element_bytes
            for element in range(case['start'], case['vl']):
                if not case['vm'] and not (expected[element // 8] >> (element % 8)) & 1:
                    continue
                if case['form'] == 0:
                    offset = case['index_reg'] * 16 + element * index_bytes
                    selected = int.from_bytes(expected[offset:offset + index_bytes], 'little')
                elif case['form'] == 3:
                    selected = (case['instruction'] >> 15) & 31
                else:
                    selected = case['scalar']
                source = case['source'] * 16 + selected * element_bytes
                value = (expected[source:source + element_bytes]
                         if selected < case['maximum'] else bytes(element_bytes))
                destination = case['destination'] * 16 + element * element_bytes
                expected[destination:destination + element_bytes] = value
        if case['nemu_trap'] == legal or case['nemu'] != expected:
            first_mismatch = next((index for index, (nemu_byte, rtl_byte)
                                   in enumerate(zip(case['nemu'], expected))
                                   if nemu_byte != rtl_byte), None)
            failures.append(dict(instruction=case['instruction'], sew=case['sew'],
                                 lmul=case['lmul'], avl=case['avl'], vl=case['vl'],
                                 seed=case['seed'], vm=case['vm'], start=case['start'],
                                 legal=legal, nemu_trap=case['nemu_trap'],
                                 first_mismatch=first_mismatch))
    return failures


def compare_mask_ops(cases, outputs):
    failures = []
    for case, output in zip(cases, outputs):
        legal = int(output[1])
        expected = expected_state(case, legal)
        if case['nemu_trap'] == legal or case['nemu'] != expected:
            first_mismatch = next((index for index, (nemu_byte, rtl_byte)
                                   in enumerate(zip(case['nemu'], expected))
                                   if nemu_byte != rtl_byte), None)
            failures.append(dict(instruction=case['instruction'], sew=case['sew'],
                                 lmul=case['lmul'], avl=case['avl'], vl=case['vl'],
                                 seed=case['seed'], vm=case['vm'], start=case['start'],
                                 destination=case['destination'], legal=legal,
                                 nemu_trap=case['nemu_trap'], first_mismatch=first_mismatch))
    return failures


def compare_move(cases, outputs):
    failures = []
    for case, (rtl_trap, rtl_state) in zip(cases, outputs):
        unchanged = case['expected_trap'] or case['name'].startswith('self-move')
        if (case['nemu_trap'] != case['expected_trap'] or
                int(rtl_trap) != case['expected_trap'] or
                (unchanged and case['nemu_state'] != case['initial_state']) or
                (unchanged and rtl_state != case['initial_state']) or
                case['nemu_state'] != rtl_state):
            first_mismatch = next((index for index, (nemu_byte, rtl_byte) in enumerate(
                zip(bytes.fromhex(case['nemu_state']), bytes.fromhex(rtl_state)))
                if nemu_byte != rtl_byte), None)
            failures.append(dict(case=case['name'], instruction=case['instruction'],
                                 vtype=case['vtype'], start=case['start'], seed=case['seed'],
                                 expected_trap=case['expected_trap'],
                                 nemu_trap=case['nemu_trap'], rtl_trap=int(rtl_trap),
                                 first_mismatch=first_mismatch,
                                 nemu_state_sha256=hashlib.sha256(bytes.fromhex(case['nemu_state'])).hexdigest(),
                                 rtl_state_sha256=hashlib.sha256(bytes.fromhex(rtl_state)).hexdigest()))
    return failures


UNITS = {
    'alu': (alu_cases, compare_elements),
    'muldiv': (muldiv_cases, compare_elements),
    'reduce': (reduce_cases, compare_reduce),
    'mask_scan': (mask_scan_cases, compare_mask_scan),
    'slide': (slide_cases, compare_slide),
    'gather': (gather_cases, compare_gather),
    'mask_ops': (mask_ops_cases, compare_mask_ops),
    'move': (move_cases, compare_move),
}


def main(unit=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    if unit is None:
        parser.add_argument('--unit', choices=tuple(UNITS), required=True)
    args = parser.parse_args()
    unit = unit or args.unit
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
    reference.state.gpr[4] = 0x200
    reference.run([(0x300 << 20) | (4 << 15) | (2 << 12) | 0x73])
    generate, compare = UNITS[unit]
    cases, inputs = generate(reference, vector_api, args.xlen)
    vectors = args.output / 'vectors.txt'
    vectors.write_text(inputs)
    decode_only = unit in ('gather', 'mask_ops')
    rtl_names = ('decode', 'geometry') if decode_only else (unit,)
    if unit == 'reduce':
        rtl_names += ('alu',)
    rtl_files = [ROOT / f'hdl/backend/vpu/rapt_vpu_{name}.sv' for name in rtl_names]
    top = 'tb_vector_' + unit + '_rtl'
    testbench = ROOT / 'verify/nemu' / (top + '.sv')
    build = args.output / 'obj_dir'
    command = ['verilator', '--binary', '--timing', '-Wall', '--top-module', top,
               '--Mdir', str(build), '-I' + str(ROOT / 'hdl/include')]
    if decode_only:
        command.append('-Wno-PINMISSING')
    elif unit not in ('alu', 'muldiv'):
        command.append(f'-GXLEN={args.xlen}')
    command.extend(map(str, [*rtl_files, testbench]))
    with (args.output / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([build / ('V' + top), '+vectors=' + str(vectors)],
                            capture_output=True, text=True, check=True)
    (args.output / 'run.log').write_text(result.stdout + result.stderr)
    marker = 'VECTOR_' + unit.upper() + ('_LEGAL' if decode_only else '_RESULT')
    outputs = [line.split() for line in result.stdout.splitlines() if line.startswith(marker + ' ')]
    fields = 3 if unit in ('muldiv', 'reduce', 'mask_scan', 'move') else 2
    if len(outputs) != len(cases) or any(len(row) != fields or
            any(not re.fullmatch('[0-9a-f]+', value) for value in row[1:]) for row in outputs):
        raise RuntimeError(f'RTL returned malformed outputs or {len(outputs)} results for {len(cases)} cases')
    if unit in ('alu', 'muldiv'):
        outputs = [int(row[1], 16) for row in outputs]
    elif unit in ('reduce', 'move'):
        outputs = [row[1:] for row in outputs]
    failures = compare(cases, outputs)
    rtl_hashes = [hashlib.sha256(path.read_bytes()).hexdigest() for path in rtl_files]
    report = dict(xlen=args.xlen, cases=len(cases), failures=failures,
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                  rtl_sha256=rtl_hashes if decode_only else rtl_hashes[0],
                  testbench_sha256=hashlib.sha256(testbench.read_bytes()).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    if unit == 'reduce':
        report['alu_sha256'] = rtl_hashes[1]
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_{unit.upper()}_RTL xlen={args.xlen} cases={len(cases)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
