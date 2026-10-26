"""Check opt-in V128 integer arithmetic, masks, memory and vector-state API."""
import argparse
import ctypes
import hashlib
import json
import struct
from pathlib import Path

from lib.reference import ISAAPI, Reference


class VectorState(ctypes.Structure):
    _fields_ = [('reg', (ctypes.c_uint8 * 16) * 32)]


class VectorAPI(ctypes.Structure):
    _fields_ = [('version', ctypes.c_uint32), ('size', ctypes.c_uint32),
                ('xlen', ctypes.c_uint32), ('max_harts', ctypes.c_uint32),
                ('set_state', ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint32,
                                               ctypes.POINTER(VectorState))),
                ('get_state', ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_uint32,
                                               ctypes.POINTER(VectorState)))]


def instruction(function, vm, source2, source1, form, destination):
    return (function << 26) | (vm << 25) | (source2 << 20) | (source1 << 15) | (
        form << 12) | (destination << 7) | 0x57


def memory_instruction(store, width, vm, base, vector_reg):
    return (vm << 25) | (base << 15) | (width << 12) | (vector_reg << 7) | (
        0x27 if store else 0x07)


def strided_instruction(store, width, vm, base, stride_reg, vector_reg):
    return memory_instruction(store, width, vm, base, vector_reg) | (
        2 << 26) | (stride_reg << 20)


def indexed_instruction(store, width, vm, base, index_reg, vector_reg, ordered=False):
    return memory_instruction(store, width, vm, base, vector_reg) | (
        (3 if ordered else 1) << 26) | (index_reg << 20)


def whole_instruction(store, width, registers, base, vector_reg, vm=1):
    return ((registers - 1) << 29) | (vm << 25) | (8 << 20) | (
        base << 15) | (width << 12) | (vector_reg << 7) | (
        0x27 if store else 0x07)


def mask_instruction(store, base, vector_reg, vm=1):
    return memory_instruction(store, 0, vm, base, vector_reg) | (11 << 20)


def fof_instruction(width, vm, base, vector_reg):
    return memory_instruction(False, width, vm, base, vector_reg) | (16 << 20)


def segment_instruction(store, width, fields, vm, base, vector_reg, mop=0, selector=0):
    return (memory_instruction(store, width, vm, base, vector_reg) |
            ((fields - 1) << 29) | (mop << 26) | (selector << 20))


def group_move_instruction(registers, source, destination, vm=1):
    return instruction(0x27, vm, source, registers - 1, 3, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.reference.resolve()))
    isa_query = library.nemu_difftest_isa_query
    isa_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    isa_query.restype = ctypes.POINTER(ISAAPI)
    isa_api = isa_query(1, ctypes.sizeof(ISAAPI)).contents
    vector_query = library.nemu_difftest_vector_query
    vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    vector_query.restype = ctypes.POINTER(VectorAPI)
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    check('configure', isa_api.configure(1 << 6), 0)
    check('api-version-reject', bool(vector_query(0, ctypes.sizeof(VectorAPI))), False)
    check('api-size-reject', bool(vector_query(1, ctypes.sizeof(VectorAPI) - 1)), False)
    vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
    check('api-xlen', vector_api.xlen, args.xlen)
    check('api-vlenb', ctypes.sizeof(VectorState), 512)

    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state

    def vector_get():
        vector = VectorState()
        check('get-state', vector_api.get_state(0, ctypes.byref(vector)), 0)
        return vector

    def csr_write(csr, value):
        state.gpr[4] = value & reference.mask
        return reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def vset(vtype, avl):
        state.gpr[1] = avl
        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])

    seeded = VectorState()
    for reg in range(32):
        for byte in range(16):
            seeded.reg[reg][byte] = 0xa5
    check('set-state', vector_api.set_state(0, ctypes.byref(seeded)), 0)
    check('initial-regs', list(vector_get().reg[2]), [0xa5] * 16)
    csr_write(0x300, state.mstatus[0] | 0x200)
    vset(0xc0, 4)
    state.gpr[1] = 7
    reference.run([instruction(0x17, 1, 0, 1, 4, 1)])
    check('vmv-v-x', list(vector_get().reg[1]), [7] * 4 + [0xa5] * 12)
    reference.run([instruction(0, 1, 1, 1, 0, 2)])
    check('vadd-v-v', list(vector_get().reg[2]), [14] * 4 + [0xa5] * 12)
    reference.run([instruction(0x10, 1, 2, 0, 2, 3)])
    check('vmv-x-s', state.gpr[3], 14)

    state.gpr[1] = 0x123
    reference.run([instruction(0x10, 1, 0, 1, 6, 30)])
    check('vmv-s-x', list(vector_get().reg[30]), [0x23] + [0xa5] * 15)
    before = list(vector_get().reg[30])
    pc = reference.run([instruction(0x10, 0, 0, 1, 6, 30)])
    check('vmv-s-x-masked-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x10, 1, 8, 1, 6, 30)])
    check('vmv-s-x-vs2-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('vmv-s-x-illegal-undisturbed', list(vector_get().reg[30]), before)
    csr_write(0x008, 1)
    state.gpr[1] = 0x45
    reference.run([instruction(0x10, 1, 0, 1, 6, 30)])
    check('vmv-s-x-vstart-nonzero', list(vector_get().reg[30]), [0x45] + [0xa5] * 15)
    csr_write(0x008, 4)
    state.gpr[1] = 0x55
    reference.run([instruction(0x10, 1, 0, 1, 6, 30)])
    check('vmv-s-x-vstart-ge-vl', list(vector_get().reg[30]), [0x45] + [0xa5] * 15)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vmv-s-x-vstart-cleared', state.gpr[3], 0)
    vset(0xd8, 2)
    state.gpr[1] = 0x80000001
    reference.run([instruction(0x10, 1, 0, 1, 6, 30)])
    scalar = 0xffffffff80000001 if args.xlen == 32 else 0x80000001
    check('vmv-s-x-sew64', list(vector_get().reg[30]),
          list(scalar.to_bytes(8, 'little')) + [0xa5] * 8)
    vset(0xc0, 4)
    state.gpr[1] = 7

    csr_write(0x008, 2)
    state.gpr[1] = 1
    reference.run([instruction(0, 1, 2, 1, 4, 2)])
    check('vstart-prefix', list(vector_get().reg[2]), [14, 14, 15, 15] + [0xa5] * 12)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vstart-cleared', state.gpr[3], 0)
    csr_write(0x008, 16)
    before = list(vector_get().reg[2])
    pc = reference.run([instruction(0, 1, 2, 1, 4, 2)])
    check('vstart-vlmax-noop-pc', state.pc[0], pc + 4)
    check('vstart-vlmax-noop-vector', list(vector_get().reg[2]), before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vstart-vlmax-noop-cleared', state.gpr[3], 0)

    fp_address = 0x80003000

    def fp_seed(bits):
        reference.write(fp_address, bits.to_bytes(8, 'little'))
        state.gpr[4] = fp_address
        reference.run([(4 << 15) | (3 << 12) | (5 << 7) | 0x07])

    def fp_result():
        state.gpr[4] = fp_address
        reference.run([(6 << 20) | (4 << 15) | (3 << 12) | 0x27])
        return int.from_bytes(reference.read(fp_address, 8), 'little')

    fp_saved = vector_get()
    vector = vector_get()
    vector.reg[0][0] = 0x05
    vector.reg[8][:12] = (ctypes.c_uint8 * 12)(*range(12))
    vector.reg[24][:16] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-fp-transfer', vector_api.set_state(0, ctypes.byref(vector)), 0)
    fp_seed(0xffffffff3f800000)
    vset(0xd0, 3)
    reference.run([instruction(0x17, 1, 0, 5, 5, 24)])
    check('vfmv-v-f', list(vector_get().reg[24][:12]), list((0x3f800000).to_bytes(4, 'little')) * 3)
    reference.run([instruction(0x17, 0, 8, 5, 5, 24)])
    check('vfmerge-vfm', list(vector_get().reg[24][:12]),
          list((0x3f800000).to_bytes(4, 'little')) + list(range(4, 8)) +
          list((0x3f800000).to_bytes(4, 'little')))
    reference.run([instruction(0x10, 1, 0, 5, 5, 25)])
    check('vfmv-s-f', list(vector_get().reg[25][:4]), list((0x3f800000).to_bytes(4, 'little')))
    reference.run([instruction(0x10, 1, 25, 0, 1, 6)])
    check('vfmv-f-s-boxed', fp_result(), 0xffffffff3f800000)
    reference.run([instruction(0x0e, 1, 8, 5, 5, 24)])
    check('vfslide1up-vf', list(vector_get().reg[24][:12]),
          list((0x3f800000).to_bytes(4, 'little')) + list(range(8)))
    reference.run([instruction(0x0f, 1, 8, 5, 5, 24)])
    check('vfslide1down-vf', list(vector_get().reg[24][:12]),
          list(range(4, 12)) + list((0x3f800000).to_bytes(4, 'little')))
    csr_write(0x008, 16)
    before = list(vector_get().reg[25])
    reference.run([instruction(0x10, 1, 0, 5, 5, 25)])
    check('vfmv-s-f-vstart-noop', list(vector_get().reg[25]), before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfmv-s-f-vstart-cleared', state.gpr[3], 0)
    fp_seed(0x000000003f800000)
    reference.run([instruction(0x17, 1, 0, 5, 5, 24)])
    check('vfmv-v-f-unboxed', list(vector_get().reg[24][:4]),
          list((0x7fc00000).to_bytes(4, 'little')))
    fp_seed(0x3ff0000000000000)
    vset(0xd8, 2)
    reference.run([instruction(0x17, 1, 0, 5, 5, 24)])
    check('vfmv-v-f64', list(vector_get().reg[24][:16]),
          list((0x3ff0000000000000).to_bytes(8, 'little')) * 2)
    reference.run([instruction(0x10, 1, 24, 0, 1, 6)])
    check('vfmv-f-s64', fp_result(), 0x3ff0000000000000)
    vset(0xd0, 1)
    vector = vector_get()
    vector.reg[8][:4] = (ctypes.c_uint8 * 4)(0, 0, 0x80, 0x3f)
    vector.reg[16][:4] = (ctypes.c_uint8 * 4)(0, 0, 0, 0)
    check('seed-fp-divide', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x20, 1, 8, 16, 1, 24)])
    check('vfdiv-vv-zero', list(vector_get().reg[24][:4]), list((0x7f800000).to_bytes(4, 'little')))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfdiv-vv-dz-flag', state.gpr[3] & 0x1f, 8)
    vector = vector_get()
    vector.reg[0][0] = 0
    check('seed-fp-divide-mask', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    before = list(vector_get().reg[24])
    reference.run([instruction(0x20, 0, 8, 16, 1, 24)])
    check('vfdiv-vv-masked-noop', list(vector_get().reg[24]), before)
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfdiv-vv-masked-flags', state.gpr[3] & 0x1f, 0)
    vector = vector_get()
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy((0x40000000).to_bytes(4, 'little'))
    vector.reg[16][:4] = (ctypes.c_uint8 * 4).from_buffer_copy((0x40400000).to_bytes(4, 'little'))
    for function, expected in ((0x28, 14), (0x29, -14), (0x2a, 10), (0x2b, -10),
                               (0x2c, 10), (0x2d, -10), (0x2e, 2), (0x2f, -2)):
        vector.reg[24][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(
            (0x40800000).to_bytes(4, 'little'))
        check(f'seed-fma-{function:x}', vector_api.set_state(0, ctypes.byref(vector)), 0)
        reference.run([instruction(function, 1, 8, 16, 1, 24)])
        check(f'vfma-vv-{function:x}', list(vector_get().reg[24][:4]),
              list(struct.pack('<f', expected)))
    fp_seed(0xffffffff40400000)
    check('seed-fma-vf', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x2c, 1, 8, 5, 5, 24)])
    check('vfmacc-vf', list(vector_get().reg[24][:4]), list(struct.pack('<f', 10)))
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 4))
    check('seed-vfsqrt', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x13, 1, 8, 0, 1, 24)])
    check('vfsqrt-v', list(vector_get().reg[24][:4]), list(struct.pack('<f', 2)))
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', -1))
    check('seed-vfsqrt-negative', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x13, 1, 8, 0, 1, 24)])
    check('vfsqrt-v-negative', list(vector_get().reg[24][:4]),
          list((0x7fc00000).to_bytes(4, 'little')))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfsqrt-v-nv-flag', state.gpr[3] & 0x1f, 16)
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(
        (0x7f800001).to_bytes(4, 'little'))
    check('seed-vfclass', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x13, 1, 8, 16, 1, 24)])
    check('vfclass-v-snan', list(vector_get().reg[24][:4]),
          list((0x100).to_bytes(4, 'little')))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfclass-v-no-flags', state.gpr[3] & 0x1f, 0)
    pc = reference.run([instruction(0x13, 1, 8, 1, 1, 24)])
    check('vfclass-reserved-source1-trap', [state.mcause[0], state.mepc[0]], [2, pc])
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 3.5))
    check('seed-vfcvt-f32', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 1, 1, 24)])
    check('vfcvt-x-f-rne', list(vector_get().reg[24][:4]), [4, 0, 0, 0])
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfcvt-x-f-rne-inexact', state.gpr[3] & 0x1f, 1)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 7, 1, 24)])
    check('vfcvt-rtz-x-f', list(vector_get().reg[24][:4]), [3, 0, 0, 0])
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy((-2).to_bytes(4, 'little', signed=True))
    check('seed-vfcvt-i32', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x12, 1, 8, 3, 1, 24)])
    check('vfcvt-f-x', list(vector_get().reg[24][:4]), list(struct.pack('<f', -2)))
    vset(0xd8, 1)
    vector.reg[8][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(struct.pack('<d', 3.5))
    check('seed-vfcvt-f64', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 1, 1, 24)])
    check('vfcvt-x-f64-rne', list(vector_get().reg[24][:8]),
          list((4).to_bytes(8, 'little')))
    vset(0xd0, 1)
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 1.5))
    check('seed-vfwcvt-f32', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 12, 1, 24)])
    check('vfwcvt-f-f', list(vector_get().reg[24][:8]), list(struct.pack('<d', 1.5)))
    vector.reg[8][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(
        (0x3ff0000010000000).to_bytes(8, 'little'))
    check('seed-vfncvt-f64', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 20, 1, 24)])
    check('vfncvt-f-f-rne', list(vector_get().reg[24][:4]),
          list((0x3f800000).to_bytes(4, 'little')))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfncvt-f-f-rne-inexact', state.gpr[3] & 0x1f, 1)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 21, 1, 24)])
    check('vfncvt-rod-f-f', list(vector_get().reg[24][:4]),
          list((0x3f800001).to_bytes(4, 'little')))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfncvt-rod-f-f-inexact', state.gpr[3] & 0x1f, 1)
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 2))
    vector.reg[16][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 3))
    vector.reg[24][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(struct.pack('<d', 4))
    for function, expected in ((0x30, 5), (0x32, -1), (0x38, 6), (0x3c, 10)):
        check(f'seed-fp-wide-{function:x}', vector_api.set_state(0, ctypes.byref(vector)), 0)
        reference.run([instruction(function, 1, 8, 16, 1, 24)])
        check(f'fp-wide-{function:x}', list(vector_get().reg[24][:8]),
              list(struct.pack('<d', expected)))
    fp_seed(0xffffffff40400000)
    check('seed-vfwadd-vf', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x30, 1, 8, 5, 5, 24)])
    check('vfwadd-vf', list(vector_get().reg[24][:8]), list(struct.pack('<d', 5)))
    vector.reg[8][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(struct.pack('<d', 2))
    check('seed-vfwadd-wv', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x34, 1, 8, 16, 1, 24)])
    check('vfwadd-wv', list(vector_get().reg[24][:8]), list(struct.pack('<d', 5)))
    pc = reference.run([instruction(0x34, 1, 8, 9, 1, 24)])
    check('vfwadd-wv-source-eew-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x34, 1, 8, 10, 1, 24)])
    check('vfwadd-wv-source-eew-disjoint-legal', state.pc[0], pc + 4)
    vset(0xc8, 2)
    vector.reg[8][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(
        struct.pack('<ff', 40000, -40000))
    check('seed-vfncvt-i16', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 17, 1, 24)])
    check('vfncvt-x-f-i16-saturation', list(vector_get().reg[24][:4]),
          list((32767).to_bytes(2, 'little', signed=True) +
               (-32768).to_bytes(2, 'little', signed=True)))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfncvt-x-f-i16-nv-flag', state.gpr[3] & 0x1f, 16)
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(
        struct.pack('<hh', -2, 3))
    check('seed-vfwcvt-i16', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 11, 1, 24)])
    check('vfwcvt-f-x-i16', list(vector_get().reg[24][:8]),
          list(struct.pack('<ff', -2, 3)))
    vset(0xd0, 1)
    vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 3.5))
    check('seed-vfwcvt-i64', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 9, 1, 24)])
    check('vfwcvt-x-f-i64', list(vector_get().reg[24][:8]), list((4).to_bytes(8, 'little')))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfwcvt-x-f-i64-nx-flag', state.gpr[3] & 0x1f, 1)
    vector.reg[8][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(
        (-2).to_bytes(8, 'little', signed=True))
    check('seed-vfncvt-i64', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x12, 1, 8, 19, 1, 24)])
    check('vfncvt-f-x-i64', list(vector_get().reg[24][:4]),
          list(struct.pack('<f', -2)))
    vset(0xd0, 3)
    vector.reg[0][0] = 0x05
    vector.reg[8][:12] = (ctypes.c_uint8 * 12).from_buffer_copy(
        struct.pack('<fff', 2, 3, 4))
    vector.reg[16][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(struct.pack('<f', 1))
    check('seed-vfred', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    for function, expected in ((0x03, 10), (0x05, 1), (0x07, 4)):
        reference.run([instruction(function, 1, 8, 16, 1, 24)])
        check(f'vfred-{function:x}', list(vector_get().reg[24][:4]),
              list(struct.pack('<f', expected)))
    reference.run([instruction(0x01, 0, 8, 16, 1, 24)])
    check('vfredusum-masked', list(vector_get().reg[24][:4]),
          list(struct.pack('<f', 7)))
    vector.reg[16][:8] = (ctypes.c_uint8 * 8).from_buffer_copy(struct.pack('<d', 1))
    check('seed-vfwred', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x33, 1, 8, 16, 1, 24)])
    check('vfwredosum', list(vector_get().reg[24][:8]), list(struct.pack('<d', 10)))
    reference.run([instruction(0x31, 0, 8, 16, 1, 24)])
    check('vfwredusum-masked', list(vector_get().reg[24][:8]),
          list(struct.pack('<d', 7)))
    vset(0xd1, 4)
    pc = reference.run([instruction(0x31, 1, 8, 9, 1, 24)])
    check('vfwredusum-source-eew-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x31, 1, 8, 10, 1, 24)])
    check('vfwredusum-source-eew-disjoint-legal', state.pc[0], pc + 4)
    vset(0xd0, 3)
    vector.reg[0][0] = 0
    check('seed-vfwred-all-masked', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x003, 0)
    reference.run([instruction(0x31, 0, 8, 16, 1, 24)])
    check('vfwred-all-masked-seed', list(vector_get().reg[24][:8]),
          list(struct.pack('<d', 1)))
    reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vfwred-all-masked-flags', state.gpr[3] & 0x1f, 0)
    vset(0xd0, 0)
    before = list(vector_get().reg[24])
    reference.run([instruction(0x33, 1, 8, 16, 1, 24)])
    check('vfwred-vl-zero', list(vector_get().reg[24]), before)
    vset(0xd0, 3)
    csr_write(0x008, 1)
    pc = reference.run([instruction(0x33, 1, 8, 16, 1, 24)])
    check('vfwred-vstart-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xd0, 1)
    for name, operand, source1, rounding, expected, flags in (
        ('vfrec7-positive-zero', 0x00000000, 5, 0, 0x7f800000, 8),
        ('vfrsqrt7-negative-zero', 0x80000000, 4, 0, 0xff800000, 8),
        ('vfrsqrt7-negative-one', 0xbf800000, 4, 0, 0x7fc00000, 16),
        ('vfrec7-positive-infinity', 0x7f800000, 5, 0, 0x00000000, 0),
        ('vfrec7-snan', 0x7f800001, 5, 0, 0x7fc00000, 16),
        ('vfrec7-subnormal-rne', 0x00000001, 5, 0, 0x7f800000, 5),
        ('vfrec7-subnormal-rtz', 0x00000001, 5, 1, 0x7f7fffff, 5),
    ):
        vector = vector_get()
        vector.reg[8][:4] = (ctypes.c_uint8 * 4).from_buffer_copy(
            operand.to_bytes(4, 'little'))
        check(f'seed-{name}', vector_api.set_state(0, ctypes.byref(vector)), 0)
        csr_write(0x003, rounding << 5)
        reference.run([instruction(0x13, 1, 8, source1, 1, 24)])
        check(name, list(vector_get().reg[24][:4]), list(expected.to_bytes(4, 'little')))
        reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
        check(f'{name}-fflags', state.gpr[3] & 0x1f, flags)
    csr_write(0x002, 5)
    pc = reference.run([instruction(0x17, 1, 0, 5, 5, 24)])
    check('vfmv-v-f-invalid-frm', [state.mcause[0], state.mepc[0]], [2, pc])
    csr_write(0x002, 0)
    csr_write(0x300, state.mstatus[0] & ~0x6000)
    pc = reference.run([instruction(0x17, 1, 0, 5, 5, 24)])
    check('vfmv-v-f-fs-off', [state.mcause[0], state.mepc[0]], [2, pc])
    csr_write(0x300, (state.mstatus[0] & ~0x6000) | 0x2000)
    vset(0xd0, 0)
    reference.run([instruction(0x17, 1, 0, 5, 5, 24)])
    check('vfmv-v-f-vl-zero-fs-dirty', state.mstatus[0] & 0x6000, 0x6000)
    check('restore-fp-transfer', vector_api.set_state(0, ctypes.byref(fp_saved)), 0)

    vset(0xc8, 3)
    reference.run([instruction(0x17, 1, 0, 31, 3, 4)])
    check('vmv-v-i', list(vector_get().reg[4][:8]), [0xff] * 6 + [0xa5] * 2)
    state.gpr[1] = 2
    reference.run([instruction(0, 1, 4, 1, 4, 6)])
    check('vadd-v-x', list(vector_get().reg[6][:8]), [1, 0, 1, 0, 1, 0, 0xa5, 0xa5])

    vset(0xc0, 4)
    vector = vector_get()
    vector.reg[0][0] = 0x05
    vector.reg[8][:4] = (ctypes.c_uint8 * 4)(255, 1, 0, 0)
    vector.reg[9][:4] = (ctypes.c_uint8 * 4)(0, 255, 0, 1)
    vector.reg[10][0] = 0xa5
    check('seed-carry', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x10, 0, 8, 9, 0, 11)])
    check('vadc-vvm', list(vector_get().reg[11][:4]), [0, 0, 1, 1])
    reference.run([instruction(0x11, 0, 8, 9, 0, 10)])
    check('vmadc-vvm', vector_get().reg[10][0] & 15, 3)
    reference.run([instruction(0x11, 1, 8, 9, 0, 10)])
    check('vmadc-vv-no-carry', vector_get().reg[10][0] & 15, 2)
    reference.run([instruction(0x12, 0, 8, 9, 0, 11)])
    check('vsbc-vvm', list(vector_get().reg[11][:4]), [254, 2, 255, 255])
    reference.run([instruction(0x13, 0, 8, 9, 0, 10)])
    check('vmsbc-vvm', vector_get().reg[10][0] & 15, 14)
    saved_vector = vector_get()
    vset(0xc1, 8)
    vector = vector_get()
    vector.reg[8][:8] = (ctypes.c_uint8 * 8)(*range(1, 9))
    vector.reg[16][:8] = (ctypes.c_uint8 * 8)(*range(1, 9))
    check('seed-mask-result-overlap', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x18, 1, 8, 16, 0, 8)])
    check('vmseq-low-source-overlap', vector_get().reg[8][0], 0xff)
    before = list(vector_get().reg[9])
    pc = reference.run([instruction(0x18, 1, 8, 16, 0, 9)])
    check('vmseq-high-source-overlap-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('vmseq-high-source-overlap-undisturbed', list(vector_get().reg[9]), before)
    before = list(vector_get().reg[17])
    pc = reference.run([instruction(0x11, 1, 8, 16, 0, 17)])
    check('vmadc-high-source-overlap-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('vmadc-high-source-overlap-undisturbed', list(vector_get().reg[17]), before)
    vset(0xc0, 4)
    check('restore-mask-result-overlap', vector_api.set_state(0, ctypes.byref(saved_vector)), 0)
    vector = vector_get()
    vector.reg[8][0] = 0x0a
    vector.reg[9][0] = 0x0c
    vector.reg[12][0] = 0xa5
    check('seed-mask-logic', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x008, 1)
    reference.run([instruction(0x19, 1, 8, 9, 2, 12)])
    check('vmand-mm-vstart', vector_get().reg[12][0] & 15, 9)
    for name, invalid_instruction in (
        ('vadc-unmasked-illegal', instruction(0x10, 1, 8, 9, 0, 11)),
        ('vsbc-immediate-illegal', instruction(0x12, 0, 8, 1, 3, 11)),
        ('vmand-masked-illegal', instruction(0x19, 0, 8, 9, 2, 12)),
        ('vadc-v0-destination-illegal', instruction(0x10, 0, 8, 9, 0, 0)),
    ):
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    vector = vector_get()
    vector.reg[0][0] = 0x05
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(1, 2, 3, 4)
    vector.reg[25][0] = 5
    vector.reg[26][0] = 0xa5
    check('seed-reduction', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0, 1, 24, 25, 2, 26)])
    check('vredsum-vs', vector_get().reg[26][0], 15)
    reference.run([instruction(0, 0, 24, 25, 2, 26)])
    check('vredsum-vs-masked', vector_get().reg[26][0], 9)
    csr_write(0x008, 1)
    pc = reference.run([instruction(0, 1, 24, 25, 2, 26)])
    check('vredsum-vstart-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vredsum-vstart-unchanged', state.gpr[3], 1)
    vset(0xc0, 0)
    reference.run([instruction(0, 1, 24, 25, 2, 26)])
    check('vredsum-vl-zero', vector_get().reg[26][0], 9)
    vset(0xc0, 2)
    vector = vector_get()
    vector.reg[24][:2] = (ctypes.c_uint8 * 2)(0xff, 1)
    vector.reg[25][:2] = (ctypes.c_uint8 * 2)(0, 1)
    check('seed-wide-reduction', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x30, 1, 24, 25, 0, 26)])
    check('vwredsumu-vs', list(vector_get().reg[26][:2]), [0, 2])
    reference.run([instruction(0x31, 1, 24, 25, 0, 26)])
    check('vwredsum-vs', list(vector_get().reg[26][:2]), [0, 1])
    vset(0xc1, 4)
    pc = reference.run([instruction(0x30, 1, 8, 9, 0, 26)])
    check('vwredsumu-source-eew-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x30, 1, 8, 10, 0, 26)])
    check('vwredsumu-source-eew-disjoint-legal', state.pc[0], pc + 4)
    pc = reference.run([instruction(0, 1, 8, 9, 2, 26)])
    check('vredsum-source-same-eew-overlap-legal', state.pc[0], pc + 4)
    vset(0xc0, 4)
    vector = vector_get()
    vector.reg[0][0] = 0x05
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(255, 128, 7, 5)
    vector.reg[25][:4] = (ctypes.c_uint8 * 4)(0, 255, 2, 0)
    vector.reg[26][:4] = (ctypes.c_uint8 * 4)(*[0xa5] * 4)
    check('seed-muldiv', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x20, 1, 24, 25, 2, 26)])
    check('vdivu-vv', list(vector_get().reg[26][:4]), [255, 0, 3, 255])
    reference.run([instruction(0x21, 1, 24, 25, 2, 26)])
    check('vdiv-vv', list(vector_get().reg[26][:4]), [255, 128, 3, 255])
    reference.run([instruction(0x23, 1, 24, 25, 2, 26)])
    check('vrem-vv', list(vector_get().reg[26][:4]), [255, 0, 1, 5])
    reference.run([instruction(0x24, 1, 24, 25, 2, 26)])
    check('vmulhu-vv', list(vector_get().reg[26][:4]), [0, 127, 0, 0])
    reference.run([instruction(0x26, 1, 24, 25, 2, 26)])
    check('vmulhsu-vv', list(vector_get().reg[26][:4]), [0, 128, 0, 0])
    state.gpr[5] = 2
    reference.run([instruction(0x20, 1, 24, 5, 6, 26)])
    check('vdivu-vx', list(vector_get().reg[26][:4]), [127, 64, 3, 2])
    original_vector = vector_get()
    source_values = [2, 3, 4, 5]
    operand_values = [3, 4, 5, 6]
    old_values = [7, 8, 9, 10]
    for function, name in ((0x29, 'vmadd'), (0x2b, 'vnmsub'),
                           (0x2d, 'vmacc'), (0x2f, 'vnmsac')):
        for form in (2, 6):
            vector = vector_get()
            vector.reg[24][:4] = (ctypes.c_uint8 * 4)(*source_values)
            vector.reg[25][:4] = (ctypes.c_uint8 * 4)(*operand_values)
            vector.reg[26][:4] = (ctypes.c_uint8 * 4)(*old_values)
            check(f'seed-{name}-{form}', vector_api.set_state(0, ctypes.byref(vector)), 0)
            state.gpr[5] = 3
            reference.run([instruction(function, 1, 24, 25 if form == 2 else 5,
                                       form, 26)])
            expected = []
            for source, operand, old in zip(source_values, operand_values, old_values):
                if form == 6:
                    operand = 3
                product = (source if function & 4 else old) * operand
                addend = old if function & 4 else source
                expected.append((addend - product if function & 2 else
                                 addend + product) & 0xff)
            check(f'{name}-{form}', list(vector_get().reg[26][:4]), expected)
    vector = vector_get()
    vector.reg[0][0] = 0x05
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(*source_values)
    vector.reg[25][:4] = (ctypes.c_uint8 * 4)(*operand_values)
    vector.reg[26][:4] = (ctypes.c_uint8 * 4)(*old_values)
    check('seed-vmadd-masked', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x29, 0, 24, 25, 2, 26)])
    check('vmadd-vv-masked', list(vector_get().reg[26][:4]), [23, 8, 49, 10])
    check('seed-vmadd-vstart', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x008, 2)
    reference.run([instruction(0x29, 1, 24, 25, 2, 26)])
    check('vmadd-vv-vstart', list(vector_get().reg[26][:4]), [7, 8, 49, 65])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vmadd-vstart-cleared', state.gpr[3], 0)
    check('seed-vmadd-overlap', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x29, 1, 24, 26, 2, 26)])
    check('vmadd-source1-destination-overlap', list(vector_get().reg[26][:4]),
          [51, 67, 85, 105])
    pc = reference.run([instruction(0x2d, 0, 24, 25, 2, 0)])
    check('vmacc-masked-v0-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xd8, 2)
    vector = vector_get()
    vector.reg[24][:8] = (ctypes.c_uint8 * 8)(2, 0, 0, 0, 0, 0, 0, 0)
    vector.reg[24][8:16] = (ctypes.c_uint8 * 8)(5, 0, 0, 0, 0, 0, 0, 0)
    vector.reg[26][:8] = (ctypes.c_uint8 * 8)(1, 0, 0, 0, 0, 0, 0, 0x80)
    vector.reg[26][8:16] = (ctypes.c_uint8 * 8)(*([0] * 8))
    check('seed-vmadd-sew64', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[5] = (-2) & reference.mask
    reference.run([instruction(0x29, 1, 24, 5, 6, 26)])
    check('vmadd-vx-sew64-signed-scalar', list(vector_get().reg[26]),
          [0] * 8 + [5] + [0] * 7)
    vset(0xc0, 4)
    check('restore-muldiv-state',
          vector_api.set_state(0, ctypes.byref(original_vector)), 0)
    vector = vector_get()
    vector.reg[26][:4] = (ctypes.c_uint8 * 4)(*[0xa5] * 4)
    check('seed-muldiv-mask', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x25, 0, 24, 25, 2, 26)])
    check('vmul-vv-masked', list(vector_get().reg[26][:4]), [0, 0xa5, 14, 0xa5])
    csr_write(0x009, 0)
    reference.run([instruction(0x20, 1, 24, 25, 0, 26)])
    check('vsaddu-vv', list(vector_get().reg[26][:4]), [255, 255, 9, 5])
    reference.run([(0x009 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vsaddu-vxsat', state.gpr[3], 1)
    reference.run([(0x00f << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vsaddu-vcsr', state.gpr[3], 1)
    pc = reference.run([instruction(0x22, 1, 24, 1, 3, 26)])
    check('vssubu-vi-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vector = vector_get()
    vector.reg[24][:2] = (ctypes.c_uint8 * 2)(5, 3)
    check('seed-fixed-rounding', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[5] = 1
    for mode, expected in enumerate(((3, 2), (2, 2), (2, 1), (3, 1))):
        csr_write(0x00a, mode)
        reference.run([instruction(0x2a, 1, 24, 5, 4, 26)])
        check(f'vssrl-rm{mode}', list(vector_get().reg[26][:2]), list(expected))
    vector = vector_get()
    vector.reg[24][0] = 0x80
    vector.reg[25][0] = 0x80
    check('seed-vsmul-saturation', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x009, 0)
    reference.run([instruction(0x27, 1, 24, 25, 0, 26)])
    check('vsmul-saturated-result', vector_get().reg[26][0], 0x7f)
    reference.run([(0x009 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vsmul-vxsat', state.gpr[3], 1)
    reference.run([(0x00f << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vsmul-vcsr', state.gpr[3], 7)
    vset(0xc0, 1)
    vector = vector_get()
    vector.reg[24][:2] = (ctypes.c_uint8 * 2)(0xff, 0xff)
    check('seed-vnclipu-saturation', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x009, 0)
    reference.run([instruction(0x2e, 1, 24, 0, 3, 26)])
    check('vnclipu-saturated-result', vector_get().reg[26][0], 0xff)
    reference.run([(0x009 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vnclipu-vxsat', state.gpr[3], 1)
    vector = vector_get()
    vector.reg[24][:2] = (ctypes.c_uint8 * 2)(0, 0x80)
    check('seed-vnclip-saturation', vector_api.set_state(0, ctypes.byref(vector)), 0)
    csr_write(0x009, 0)
    reference.run([instruction(0x2f, 1, 24, 0, 3, 26)])
    check('vnclip-saturated-result', vector_get().reg[26][0], 0x80)
    reference.run([(0x009 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vnclip-vxsat', state.gpr[3], 1)
    vset(0xc0, 4)
    vector = vector_get()
    vector.reg[16][:4] = (ctypes.c_uint8 * 4)(1, 1, 1, 2)
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(255, 128, 0, 1)
    check('seed-wide-addsub', vector_api.set_state(0, ctypes.byref(vector)), 0)
    for name, function, expected in (
        ('vwaddu-vv', 0x30, [0, 1, 129, 0, 1, 0, 3, 0]),
        ('vwadd-vv', 0x31, [0, 0, 129, 255, 1, 0, 3, 0]),
        ('vwsubu-vv', 0x32, [254, 0, 127, 0, 255, 255, 255, 255]),
        ('vwsub-vv', 0x33, [254, 255, 127, 255, 255, 255, 255, 255]),
    ):
        reference.run([instruction(function, 1, 24, 16, 2, 28)])
        check(name, list(vector_get().reg[28][:8]), expected)
    state.gpr[5] = 1
    reference.run([instruction(0x30, 1, 24, 5, 6, 28)])
    check('vwaddu-vx', list(vector_get().reg[28][:8]),
          [0, 1, 129, 0, 1, 0, 2, 0])
    state.gpr[5] = 0xff
    reference.run([instruction(0x31, 1, 24, 5, 6, 28)])
    check('vwadd-vx-signed', list(vector_get().reg[28][:8]),
          [254, 255, 127, 255, 255, 255, 0, 0])
    vector = vector_get()
    vector.reg[24][:8] = (ctypes.c_uint8 * 8)(0, 1, 255, 255, 0, 0, 255, 127)
    check('seed-wide-source', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x34, 1, 24, 16, 2, 28)])
    check('vwaddu-wv', list(vector_get().reg[28][:8]),
          [1, 1, 0, 0, 1, 0, 1, 128])
    pc = reference.run([instruction(0x34, 1, 24, 25, 2, 28)])
    check('vwaddu-wv-source-eew-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x34, 1, 24, 26, 2, 28)])
    check('vwaddu-wv-source-eew-disjoint-legal', state.pc[0], pc + 4)
    reference.run([instruction(0x35, 1, 24, 16, 2, 28)])
    check('vwadd-wv', list(vector_get().reg[28][:8]),
          [1, 1, 0, 0, 1, 0, 1, 128])
    vector = vector_get()
    vector.reg[16][:4] = (ctypes.c_uint8 * 4)(255, 2, 128, 1)
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(255, 128, 2, 0)
    for name, function, form, source1, expected in (
        ('vwmulu-vv', 0x38, 2, 16, [1, 254, 0, 1, 0, 1, 0, 0]),
        ('vwmulsu-vv', 0x3a, 2, 16, [1, 255, 0, 255, 0, 1, 0, 0]),
        ('vwmul-vv', 0x3b, 2, 16, [1, 0, 0, 255, 0, 255, 0, 0]),
        ('vwmaccu-vv', 0x3c, 2, 16, [2, 254, 1, 1, 1, 1, 1, 0]),
        ('vwmacc-vv', 0x3d, 2, 16, [2, 0, 1, 255, 1, 255, 1, 0]),
        ('vwmaccsu-vv', 0x3f, 2, 16, [2, 255, 1, 1, 1, 255, 1, 0]),
        ('vwmaccus-vx', 0x3e, 6, 5, [2, 255, 129, 128, 255, 1, 1, 0]),
    ):
        vector.reg[28][:8] = (ctypes.c_uint8 * 8)(1, 0, 1, 0, 1, 0, 1, 0)
        check(f'seed-{name}', vector_api.set_state(0, ctypes.byref(vector)), 0)
        state.gpr[5] = 255
        reference.run([instruction(function, 1, 24, source1, form, 28)])
        check(name, list(vector_get().reg[28][:8]), expected)
    for name, function, form in (
        ('vwmul-reserved-illegal', 0x39, 2),
        ('vwmaccus-vv-illegal', 0x3e, 2),
    ):
        pc = reference.run([instruction(function, 1, 24, 16, form, 28)])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xd0, 1)
    vector = vector_get()
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(4, 3, 2, 1)
    vector.reg[28][:8] = (ctypes.c_uint8 * 8)(1, 0, 0, 0, 0, 0, 0, 0)
    check('seed-vwmaccsu-negative-scalar', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[5] = reference.mask
    reference.run([instruction(0x3f, 1, 24, 5, 6, 28)])
    check('vwmaccsu-negative-scalar',
          int.from_bytes(bytes(vector_get().reg[28][:8]), 'little'),
          (1 - 0x01020304) & ((1 << 64) - 1))
    vset(0xd0, 2)
    vector = vector_get()
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(1, 128, 255, 255)
    check('seed-extension', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x12, 1, 24, 6, 2, 28)])
    check('vzext-vf2', list(vector_get().reg[28][:8]),
          [1, 128, 0, 0, 255, 255, 0, 0])
    reference.run([instruction(0x12, 1, 24, 7, 2, 28)])
    check('vsext-vf2', list(vector_get().reg[28][:8]),
          [1, 128, 255, 255, 255, 255, 255, 255])
    vset(0xc0, 2)
    vector = vector_get()
    vector.reg[16][:2] = (ctypes.c_uint8 * 2)(12, 12)
    vector.reg[24][:4] = (ctypes.c_uint8 * 4)(0, 128, 255, 127)
    check('seed-narrow-shift', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x2c, 1, 24, 16, 0, 28)])
    check('vnsrl-wv', list(vector_get().reg[28][:2]), [8, 7])
    pc = reference.run([instruction(0x2c, 1, 24, 25, 0, 28)])
    check('vnsrl-wv-source-eew-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x2c, 1, 24, 26, 0, 28)])
    check('vnsrl-wv-source-eew-disjoint-legal', state.pc[0], pc + 4)
    reference.run([instruction(0x2d, 1, 24, 12, 3, 28)])
    check('vnsra-wi', list(vector_get().reg[28][:2]), [248, 7])
    state.gpr[5] = reference.mask
    reference.run([instruction(0x2d, 1, 24, 5, 4, 28)])
    check('vnsra-wx-masked-shift', list(vector_get().reg[28][:2]), [255, 0])
    vset(0xd8, 1)
    vector = vector_get()
    vector.reg[24][0] = 0x80
    check('seed-extension-vf8', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x12, 1, 24, 3, 2, 28)])
    check('vsext-vf8', list(vector_get().reg[28][:8]),
          [128, 255, 255, 255, 255, 255, 255, 255])
    pc = reference.run([instruction(0x30, 1, 24, 16, 2, 28)])
    check('vwaddu-e64-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 8)
    vector = vector_get()
    vector.reg[0][0] = 0x24
    vector.reg[24][0] = 0xa4
    check('seed-mask-scan', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x10, 1, 24, 16, 2, 3)])
    check('vcpop-m', state.gpr[3], 3)
    reference.run([instruction(0x10, 0, 24, 16, 2, 3)])
    check('vcpop-m-masked', state.gpr[3], 2)
    reference.run([instruction(0x10, 0, 24, 17, 2, 3)])
    check('vfirst-m-masked', state.gpr[3], 2)
    reference.run([instruction(0x10, 0, 0, 16, 2, 3)])
    check('vcpop-m-v0-source', state.gpr[3], 2)
    vector = vector_get()
    vector.reg[24][0] = 0
    check('seed-mask-scan-empty', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x10, 1, 24, 17, 2, 3)])
    check('vfirst-m-none', state.gpr[3], reference.mask)
    vset(0xc0, 0)
    reference.run([instruction(0x10, 1, 24, 16, 2, 3)])
    check('vcpop-m-vl-zero', state.gpr[3], 0)
    reference.run([instruction(0x10, 1, 24, 17, 2, 3)])
    check('vfirst-m-vl-zero', state.gpr[3], reference.mask)
    vset(0xc0, 8)
    csr_write(0x008, 1)
    pc = reference.run([instruction(0x10, 1, 24, 16, 2, 3)])
    check('vcpop-m-vstart-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 5)
    vector = vector_get()
    vector.reg[0][0] = 0x15
    vector.reg[8][:5] = (ctypes.c_uint8 * 5)(10, 20, 30, 40, 50)
    vector.reg[9][:5] = (ctypes.c_uint8 * 5)(*[0xa5] * 5)
    check('seed-slide', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x0e, 1, 8, 2, 3, 9)])
    check('vslideup-vi', list(vector_get().reg[9][:5]), [0xa5, 0xa5, 10, 20, 30])
    reference.run([instruction(0x0f, 1, 8, 2, 3, 9)])
    check('vslidedown-vi', list(vector_get().reg[9][:5]), [30, 40, 50, 0xa5, 0xa5])
    state.gpr[5] = 3
    reference.run([instruction(0x0e, 1, 8, 5, 4, 9)])
    check('vslideup-vx', list(vector_get().reg[9][:5]), [30, 40, 50, 10, 20])
    state.gpr[5] = reference.mask
    reference.run([instruction(0x0f, 1, 8, 5, 4, 9)])
    check('vslidedown-vx-large', list(vector_get().reg[9][:5]), [0] * 5)
    state.gpr[5] = 0x78
    reference.run([instruction(0x0e, 1, 8, 5, 6, 9)])
    check('vslide1up-vx', list(vector_get().reg[9][:5]), [0x78, 10, 20, 30, 40])
    reference.run([instruction(0x0f, 1, 8, 5, 6, 9)])
    check('vslide1down-vx', list(vector_get().reg[9][:5]), [20, 30, 40, 50, 0x78])
    vector = vector_get()
    vector.reg[9][:5] = (ctypes.c_uint8 * 5)(*[0xa5] * 5)
    check('seed-slide-mask', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x0f, 0, 8, 2, 3, 9)])
    check('vslidedown-vi-masked', list(vector_get().reg[9][:5]),
          [30, 0xa5, 50, 0xa5, 0xa5])
    csr_write(0x008, 2)
    reference.run([instruction(0x0f, 1, 8, 1, 3, 9)])
    check('vslidedown-vi-vstart', list(vector_get().reg[9][:5]),
          [30, 0xa5, 40, 50, 0xa5])
    csr_write(0x008, 7)
    reference.run([instruction(0x0f, 1, 8, 1, 3, 9)])
    check('vslidedown-vstart-past-vl', list(vector_get().reg[9][:5]),
          [30, 0xa5, 40, 50, 0xa5])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vslide-vstart-cleared', state.gpr[3], 0)
    pc = reference.run([instruction(0x0e, 1, 8, 1, 3, 8)])
    check('vslideup-overlap-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x0f, 0, 8, 1, 3, 0)])
    check('vslidedown-masked-v0-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    reference.run([instruction(0x0f, 1, 8, 2, 3, 8)])
    check('vslidedown-overlap', list(vector_get().reg[8][:5]),
          [30, 40, 50, 0xa5, 0xa5])
    vset(0xc0, 0)
    reference.run([instruction(0x0e, 1, 8, 1, 3, 9)])
    check('vslideup-vl-zero', list(vector_get().reg[9][:5]),
          [30, 0xa5, 40, 50, 0xa5])
    vset(0xc0, 5)
    vector = vector_get()
    vector.reg[0][0] = 0x15
    vector.reg[8][:5] = (ctypes.c_uint8 * 5)(10, 20, 30, 40, 50)
    vector.reg[9][:5] = (ctypes.c_uint8 * 5)(4, 2, 0, 15, 16)
    vector.reg[10][:5] = (ctypes.c_uint8 * 5)(*[0xa5] * 5)
    for index, selected in enumerate((4, 2, 0, 15, 16)):
        vector.reg[12][index * 2] = selected
        vector.reg[12][index * 2 + 1] = 0
    check('seed-gather', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x0c, 1, 8, 9, 0, 10)])
    check('vrgather-vv', list(vector_get().reg[10][:5]), [50, 30, 10, 0xa5, 0])
    vector = vector_get()
    vector.reg[10][:5] = (ctypes.c_uint8 * 5)(*[0xa5] * 5)
    check('seed-gather-mask', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x0c, 0, 8, 9, 0, 10)])
    check('vrgather-vv-masked', list(vector_get().reg[10][:5]),
          [50, 0xa5, 10, 0xa5, 0])
    state.gpr[5] = 3
    reference.run([instruction(0x0c, 1, 8, 5, 4, 10)])
    check('vrgather-vx', list(vector_get().reg[10][:5]), [40] * 5)
    reference.run([instruction(0x0c, 1, 8, 31, 3, 10)])
    check('vrgather-vi-out-of-range', list(vector_get().reg[10][:5]), [0] * 5)
    reference.run([instruction(0x0e, 1, 8, 12, 0, 10)])
    check('vrgatherei16-vv', list(vector_get().reg[10][:5]),
          [50, 30, 10, 0xa5, 0])
    csr_write(0x008, 2)
    reference.run([instruction(0x0c, 1, 8, 9, 0, 10)])
    check('vrgather-vstart', list(vector_get().reg[10][:5]),
          [50, 30, 10, 0xa5, 0])
    for name, invalid_instruction in (
        ('vrgather-data-overlap-illegal', instruction(0x0c, 1, 8, 9, 0, 8)),
        ('vrgather-index-overlap-illegal', instruction(0x0c, 1, 8, 9, 0, 9)),
        ('vrgatherei16-misaligned-index-illegal', instruction(0x0e, 1, 8, 13, 0, 10)),
    ):
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 5)
    pc = reference.run([instruction(0x0e, 1, 8, 8, 0, 10)])
    check('vrgatherei16-different-eew-source-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc8, 5)
    pc = reference.run([instruction(0x0e, 1, 8, 8, 0, 10)])
    check('vrgatherei16-same-eew-source-overlap-legal', state.pc[0], pc + 4)
    vset(0xc3, 5)
    pc = reference.run([instruction(0x0e, 1, 8, 16, 0, 24)])
    check('vrgatherei16-emul-too-large', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 8)
    vector = vector_get()
    vector.reg[0][0] = 0xb5
    vector.reg[24][0] = 0x28
    for reg in (25, 26, 27, 28, 29):
        vector.reg[reg][:8] = (ctypes.c_uint8 * 8)(*[0xa5] * 8)
    check('seed-mask-prefix', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x14, 1, 24, 1, 2, 25)])
    check('vmsbf-m', vector_get().reg[25][0], 0x07)
    reference.run([instruction(0x14, 1, 24, 2, 2, 26)])
    check('vmsof-m', vector_get().reg[26][0], 0x08)
    reference.run([instruction(0x14, 1, 24, 3, 2, 27)])
    check('vmsif-m', vector_get().reg[27][0], 0x0f)
    vector = vector_get()
    vector.reg[25][0] = 0xa5
    check('seed-mask-prefix-masked', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x14, 0, 24, 1, 2, 25)])
    check('vmsbf-m-masked', vector_get().reg[25][0], 0x15)
    reference.run([instruction(0x14, 1, 24, 16, 2, 28)])
    check('viota-m', list(vector_get().reg[28][:8]), [0, 0, 0, 0, 1, 1, 2, 2])
    vector = vector_get()
    vector.reg[28][:8] = (ctypes.c_uint8 * 8)(*[0xa5] * 8)
    check('seed-viota-masked', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x14, 0, 24, 16, 2, 28)])
    check('viota-m-masked', list(vector_get().reg[28][:8]),
          [0, 0xa5, 0, 0xa5, 0, 0, 0xa5, 1])
    reference.run([instruction(0x14, 0, 0, 17, 2, 29)])
    check('vid-v-masked', list(vector_get().reg[29][:8]),
          [0, 0xa5, 2, 0xa5, 4, 5, 0xa5, 7])
    csr_write(0x008, 1)
    for name, invalid_instruction in (
        ('vmsbf-vstart-illegal', instruction(0x14, 1, 24, 1, 2, 25)),
        ('viota-vstart-illegal', instruction(0x14, 1, 24, 16, 2, 28)),
    ):
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 8)
    for name, invalid_instruction in (
        ('vmsbf-source-overlap-illegal', instruction(0x14, 1, 24, 1, 2, 24)),
        ('vmsbf-mask-overlap-illegal', instruction(0x14, 0, 24, 1, 2, 0)),
        ('viota-source-overlap-illegal', instruction(0x14, 1, 24, 16, 2, 24)),
        ('viota-mask-overlap-illegal', instruction(0x14, 0, 24, 16, 2, 0)),
        ('vid-source-nonzero-illegal', instruction(0x14, 1, 24, 17, 2, 29)),
    ):
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    vector = vector_get()
    vector.reg[8][:8] = (ctypes.c_uint8 * 8)(10, 20, 30, 40, 50, 60, 70, 80)
    vector.reg[12][:8] = (ctypes.c_uint8 * 8)(*[0xa5] * 8)
    vector.reg[24][0] = 0x2d
    check('seed-compress', vector_api.set_state(0, ctypes.byref(vector)), 0)
    reference.run([instruction(0x17, 1, 8, 24, 2, 12)])
    check('vcompress-vm', list(vector_get().reg[12][:8]),
          [10, 30, 40, 60, 0xa5, 0xa5, 0xa5, 0xa5])
    csr_write(0x008, 1)
    pc = reference.run([instruction(0x17, 1, 8, 24, 2, 12)])
    check('vcompress-vstart-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 8)
    for name, invalid_instruction in (
        ('vcompress-masked-illegal', instruction(0x17, 0, 8, 24, 2, 12)),
        ('vcompress-data-overlap-illegal', instruction(0x17, 1, 8, 24, 2, 8)),
        ('vcompress-mask-overlap-illegal', instruction(0x17, 1, 8, 24, 2, 24)),
        ('vcompress-data-mask-v0-illegal', instruction(0x17, 1, 0, 0, 2, 12)),
    ):
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x17, 1, 8, 0, 2, 12)])
    check('vcompress-mask-v0-legal', state.pc[0], pc + 4)
    vset(0xc1, 8)
    pc = reference.run([instruction(0x17, 1, 8, 9, 2, 24)])
    check('vcompress-data-mask-group-overlap-illegal',
          [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 8)
    vector = vector_get()
    vector.reg[9][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('restore-carry-source', vector_api.set_state(0, ctypes.byref(vector)), 0)

    vset(0xc0, 4)
    data_address = 0x80071000
    reference.write(data_address, bytes([4, 5, 6, 7] + [0x99] * 12))
    state.gpr[1] = data_address + 1
    csr_write(0x008, 16)
    before = list(vector_get().reg[8])
    pc = reference.run([memory_instruction(False, 5, 1, 1, 8)])
    check('vle16-vstart-vlmax-noop-pc', state.pc[0], pc + 4)
    check('vle16-vstart-vlmax-noop-vector', list(vector_get().reg[8]), before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle16-vstart-vlmax-noop-cleared', state.gpr[3], 0)
    state.gpr[1] = data_address
    reference.run([memory_instruction(False, 0, 1, 1, 8)])
    check('vle8', list(vector_get().reg[8][:4]), [4, 5, 6, 7])
    state.gpr[1] = data_address + 8
    reference.run([memory_instruction(True, 0, 1, 1, 8)])
    check('vse8', list(reference.read(data_address + 8, 4)), [4, 5, 6, 7])
    csr_write(0x008, 2)
    state.gpr[1] = data_address + 4
    reference.run([memory_instruction(True, 0, 1, 1, 8)])
    check('vse8-vstart', list(reference.read(data_address + 4, 4)), [0x99, 0x99, 6, 7])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vse8-vstart-cleared', state.gpr[3], 0)

    stride_address = data_address + 384
    reference.write(stride_address, bytes(range(32)))
    vset(0xc0, 4)
    state.gpr[1] = stride_address
    state.gpr[2] = 2
    reference.run([strided_instruction(False, 0, 1, 1, 2, 8)])
    check('vlse8-positive', list(vector_get().reg[8][:4]), [0, 2, 4, 6])
    state.gpr[1] = stride_address + 6
    state.gpr[2] = (-2) & reference.mask
    reference.run([strided_instruction(False, 0, 1, 1, 2, 8)])
    check('vlse8-negative', list(vector_get().reg[8][:4]), [6, 4, 2, 0])
    state.gpr[1] = stride_address + 3
    state.gpr[2] = 0
    reference.run([strided_instruction(False, 0, 1, 1, 2, 8)])
    check('vlse8-zero', list(vector_get().reg[8][:4]), [3] * 4)

    vector = vector_get()
    vector.reg[0][0] = 0x0a
    vector.reg[8][:4] = (ctypes.c_uint8 * 4)(9, 10, 11, 12)
    check('seed-strided-store', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[1] = stride_address + 16
    state.gpr[2] = 3
    csr_write(0x008, 2)
    reference.run([strided_instruction(True, 0, 1, 1, 2, 8)])
    stored = list(reference.read(stride_address + 16, 12))
    check('vsse8-vstart', [stored[0], stored[3], stored[6], stored[9]],
          [16, 19, 11, 12])
    vector = vector_get()
    vector.reg[8][:4] = (ctypes.c_uint8 * 4)(*[0xa5] * 4)
    check('seed-strided-mask', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[1] = stride_address
    state.gpr[2] = 2
    reference.run([strided_instruction(False, 0, 0, 1, 2, 8)])
    check('vlse8-masked', list(vector_get().reg[8][:4]), [0xa5, 2, 0xa5, 6])
    vset(0xc8, 4)
    state.gpr[1] = stride_address
    state.gpr[2] = 3
    pc = reference.run([strided_instruction(False, 5, 1, 1, 2, 10)])
    check('vlse16-misaligned-stride-pc', state.pc[0], pc + 4)
    check('vlse16-misaligned-stride-data', list(vector_get().reg[10][:8]),
          [0, 1, 3, 4, 6, 7, 9, 10])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vlse16-misaligned-stride-vstart', state.gpr[3], 0)
    csr_write(0x008, 0)

    vset(0xc0, 4)
    vector = vector_get()
    vector.reg[16][:4] = (ctypes.c_uint8 * 4)(0, 4, 8, 12)
    vector.reg[8][:4] = (ctypes.c_uint8 * 4)(*[0xa5] * 4)
    check('seed-indexed-ei8', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[1] = stride_address
    reference.run([indexed_instruction(False, 0, 1, 1, 16, 8)])
    check('vluxei8', list(vector_get().reg[8][:4]), [0, 4, 8, 12])
    state.gpr[1] = stride_address + 16
    reference.run([indexed_instruction(True, 0, 1, 1, 16, 8, ordered=True)])
    stored = list(reference.read(stride_address + 16, 32))
    check('vsoxei8', [stored[index] for index in (0, 4, 8, 12)], [0, 4, 8, 12])

    vector = vector_get()
    vector.reg[16][:8] = (ctypes.c_uint8 * 8)(0, 0, 4, 0, 8, 0, 12, 0)
    check('seed-indexed-ei16', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[1] = stride_address
    reference.run([indexed_instruction(False, 5, 1, 1, 16, 8)])
    check('vluxei16-data-e8', list(vector_get().reg[8][:4]), [0, 4, 8, 12])
    pc = reference.run([indexed_instruction(False, 5, 1, 1, 16, 17)])
    check('vluxei16-overlap-illegal', [state.mcause[0], state.mepc[0]], [2, pc])

    vset(0xc8, 4)
    vector = vector_get()
    vector.reg[16][:4] = (ctypes.c_uint8 * 4)(0, 4, 8, 12)
    check('seed-indexed-data-e16', vector_api.set_state(0, ctypes.byref(vector)), 0)
    state.gpr[1] = stride_address
    reference.run([indexed_instruction(False, 0, 1, 1, 16, 10, ordered=True)])
    check('vloxei8-data-e16', list(vector_get().reg[10][:8]),
          [0, 1, 4, 5, 8, 9, 12, 13])

    original_vector = vector_get()
    vector = vector_get()
    vector.reg[8][:8] = (ctypes.c_uint8 * 8)(0, 8, 16, 24, 32, 40, 48, 56)
    vector.reg[9][:8] = (ctypes.c_uint8 * 8)(1, 2, 3, 4, 5, 6, 7, 8)
    check('seed-indexed-store-overlap', vector_api.set_state(0, ctypes.byref(vector)), 0)
    overlap_address = stride_address + 48
    for ordered in (False, True):
        reference.write(overlap_address, bytes([0xee] * 32))
        state.gpr[1] = overlap_address
        opcode = indexed_instruction(True, 0, 1, 1, 8, 8, ordered=ordered) | (1 << 29)
        csr_write(0x008, 1)
        pc = reference.run([opcode])
        check(f'indexed-segment-store-overlap-illegal-{ordered}',
              [state.pc[0], state.mcause[0], state.mepc[0], state.mtval[0]],
              [state.mtvec[0], 2, pc, opcode])
        check(f'indexed-segment-store-overlap-memory-unchanged-{ordered}',
              list(reference.read(overlap_address, 32)), [0xee] * 32)
        check(f'indexed-segment-store-overlap-registers-unchanged-{ordered}',
              bytes(vector_get()).hex(), bytes(vector).hex())
        reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
        check(f'indexed-segment-store-overlap-vstart-preserved-{ordered}', state.gpr[3], 1)
    check('restore-indexed-store-overlap',
          vector_api.set_state(0, ctypes.byref(original_vector)), 0)

    vset(0xc0, 4)
    vector = vector_get()
    vector.reg[8][:4] = (ctypes.c_uint8 * 4)(4, 5, 6, 7)
    check('restore-unit-source', vector_api.set_state(0, ctypes.byref(vector)), 0)

    reference.write(data_address + 16, bytes(range(1, 10)))
    state.gpr[1] = data_address + 16
    reference.run([memory_instruction(False, 5, 1, 1, 10)])
    check('vle16-emul2', list(vector_get().reg[10][:8]), [1, 2, 3, 4, 5, 6, 7, 8])
    pc = reference.run([memory_instruction(False, 5, 1, 1, 11)])
    check('vle16-misaligned-group', [state.mcause[0], state.mepc[0]], [2, pc])
    state.gpr[1] = data_address + 17
    pc = reference.run([memory_instruction(False, 5, 1, 1, 10)])
    check('vle16-misaligned-address', state.pc[0], pc + 4)
    check('vle16-misaligned-data', list(vector_get().reg[10][:8]), list(range(2, 10)))
    reference.write(data_address + 16, bytes([0xee] * 10))
    pc = reference.run([memory_instruction(True, 5, 1, 1, 10)])
    check('vse16-misaligned-address', state.pc[0], pc + 4)
    check('vse16-misaligned-data', list(reference.read(data_address + 16, 10)),
          [0xee] + list(range(2, 10)) + [0xee])

    vset(0xc0, 16)
    reference.write(data_address + 64, bytes(range(64)))
    state.gpr[1] = data_address + 64
    reference.run([memory_instruction(False, 6, 1, 1, 16)])
    check('vle32-emul4-first', list(vector_get().reg[16]), list(range(16)))
    check('vle32-emul4-last', list(vector_get().reg[19]), list(range(48, 64)))
    state.gpr[1] = data_address + 128
    reference.run([memory_instruction(True, 6, 1, 1, 16)])
    check('vse32-emul4', list(reference.read(data_address + 128, 64)), list(range(64)))

    vset(0xd8, 2)
    state.gpr[1] = data_address + 64
    reference.run([memory_instruction(False, 7, 1, 1, 20)])
    check('vle64', list(vector_get().reg[20]), list(range(16)))
    state.gpr[1] = data_address + 192
    reference.run([memory_instruction(True, 7, 1, 1, 20)])
    check('vse64', list(reference.read(data_address + 192, 16)), list(range(16)))
    state.gpr[1] = data_address + 193
    pc = reference.run([memory_instruction(True, 7, 1, 1, 20)])
    check('vse64-misaligned', state.pc[0], pc + 4)
    check('vse64-misaligned-data', list(reference.read(data_address + 192, 17)),
          [0] + list(range(16)))
    vset(0xd8, 1)
    reference.write(data_address + 208, bytes(range(16)))
    state.gpr[1] = data_address + 208
    reference.run([segment_instruction(False, 7, 2, 1, 1, 20)])
    check('vlseg2e64-first', list(vector_get().reg[20][:8]), list(range(8)))
    check('vlseg2e64-second', list(vector_get().reg[21][:8]), list(range(8, 16)))
    state.gpr[1] = data_address + 224
    reference.run([segment_instruction(True, 7, 2, 1, 1, 20)])
    check('vsseg2e64', list(reference.read(data_address + 224, 16)), list(range(16)))
    vset(0xd8, 2)
    state.gpr[1] = data_address + 208
    if args.xlen == 32:
        for store in (False, True):
            opcode = indexed_instruction(store, 7, 1, 1, 8, 22)
            before = vector_get()
            pc = reference.run([opcode])
            check(f'{"vsuxei" if store else "vluxei"}64-rv32-illegal',
                  [state.mcause[0], state.mepc[0]], [2, pc])
            check(f'{"vsuxei" if store else "vluxei"}64-rv32-no-write',
                  list(vector_get().reg[22]), list(before.reg[22]))
            check(f'{"vsuxei" if store else "vluxei"}64-rv32-memory-unchanged',
                  list(reference.read(data_address + 208, 16)), list(range(16)))
    else:
        offsets = vector_get()
        original_vectors = VectorState.from_buffer_copy(offsets)
        offsets.reg[8][:16] = (ctypes.c_uint8 * 16).from_buffer_copy(
            (0).to_bytes(8, 'little') + (8).to_bytes(8, 'little'))
        check('seed-indexed-ei64', vector_api.set_state(0, ctypes.byref(offsets)), 0)
        reference.run([indexed_instruction(False, 7, 1, 1, 8, 22)])
        check('vluxei64-rv64', list(vector_get().reg[22]), list(range(16)))
        state.gpr[1] = data_address + 240
        reference.run([indexed_instruction(True, 7, 1, 1, 8, 22)])
        check('vsuxei64-rv64', list(reference.read(data_address + 240, 16)),
              list(range(16)))
        check('restore-indexed-ei64', vector_api.set_state(0, ctypes.byref(original_vectors)), 0)

    state.gpr[1] = data_address + 16
    vset(0xc0, 2)
    csr_write(0x008, 3)
    before = list(vector_get().reg[8])
    reference.run([memory_instruction(False, 0, 1, 1, 8)])
    check('vstart-ge-vl-noop', list(vector_get().reg[8]), before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vstart-ge-vl-cleared', state.gpr[3], 0)
    vset(0xc0, 0)
    reference.run([instruction(0x10, 1, 8, 0, 2, 3)])
    check('vmv-x-s-vl-zero', state.gpr[3], 4)

    vset(0xc0, 4)
    edge_address = 0x8ffffffe
    reference.write(edge_address, bytes([0x11, 0x22]))
    state.gpr[1] = edge_address
    pc = reference.run([memory_instruction(False, 0, 1, 1, 9)])
    check('vle8-fault', [state.mcause[0], state.mepc[0]], [5, pc])
    check('vle8-partial', list(vector_get().reg[9][:4]), [0x11, 0x22, 0xa5, 0xa5])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle8-fault-vstart', state.gpr[3], 2)

    vset(0xc0, 4)
    state.gpr[1] = edge_address
    pc = reference.run([memory_instruction(True, 0, 1, 1, 8)])
    check('vse8-fault', [state.mcause[0], state.mepc[0]], [7, pc])
    check('vse8-partial', list(reference.read(edge_address, 2)), [4, 5])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vse8-fault-vstart', state.gpr[3], 2)

    vset(0xc0, 4)
    values = vector_get()
    values.reg[9][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-fof-destination', vector_api.set_state(0, ctypes.byref(values)), 0)
    reference.write(edge_address, bytes([0x11, 0x22]))
    state.gpr[1] = edge_address
    pc = reference.run([fof_instruction(0, 1, 1, 9)])
    check('vle8ff-trim-no-trap', state.pc[0], pc + 4)
    check('vle8ff-trim-data', list(vector_get().reg[9][:4]),
          [0x11, 0x22, 0xa5, 0xa5])
    reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle8ff-trim-vl', state.gpr[3], 2)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle8ff-trim-vstart', state.gpr[3], 0)

    vset(0xc0, 4)
    state.gpr[1] = edge_address + 2
    before = list(vector_get().reg[9][:4])
    pc = reference.run([fof_instruction(0, 1, 1, 9)])
    check('vle8ff-first-fault', [state.mcause[0], state.mepc[0], state.mtval[0]],
          [5, pc, edge_address + 2])
    check('vle8ff-first-fault-data', list(vector_get().reg[9][:4]), before)
    reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle8ff-first-fault-vl', state.gpr[3], 4)

    vset(0xc0, 4)
    values = vector_get()
    values.reg[0][0] = 0x02
    values.reg[9][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-fof-masked-first', vector_api.set_state(0, ctypes.byref(values)), 0)
    state.gpr[1] = edge_address + 2
    pc = reference.run([fof_instruction(0, 0, 1, 9)])
    check('vle8ff-masked-first-trim', state.pc[0], pc + 4)
    check('vle8ff-masked-first-data', list(vector_get().reg[9][:4]), [0xa5] * 4)
    reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle8ff-masked-first-vl', state.gpr[3], 1)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle8ff-masked-first-vstart', state.gpr[3], 0)

    vset(0xc8, 4)
    csr_write(0x008, 1)
    state.gpr[1] = data_address + 17
    before = list(vector_get().reg[10][:2])
    pc = reference.run([fof_instruction(5, 1, 1, 10)])
    check('vle16ff-restart-misaligned-no-trap', state.pc[0], pc + 4)
    check('vle16ff-restart-misaligned-data', list(vector_get().reg[10][:8]),
          before + list(reference.read(data_address + 19, 6)))
    reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle16ff-restart-misaligned-vl', state.gpr[3], 4)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vle16ff-restart-misaligned-vstart', state.gpr[3], 0)

    vset(0xc0, 4)
    state.gpr[1] = data_address
    pc = reference.run([memory_instruction(True, 0, 1, 1, 9) | (16 << 20)])
    check('vse8-fof-illegal', [state.mcause[0], state.mepc[0]], [2, pc])

    if args.xlen == 64:
        root, middle, leaf = 0x82000000, 0x82001000, 0x82002000
        physical, virtual = 0x81000000, 0x41000000
        for table in (root, middle, leaf):
            reference.write(table, bytes(4096))
        for address, entry in (
            (root + ((virtual >> 30) & 511) * 8, ((middle >> 12) << 10) | 1),
            (middle + ((virtual >> 21) & 511) * 8, ((leaf >> 12) << 10) | 1),
            (leaf + ((virtual >> 12) & 511) * 8, ((physical >> 12) << 10) | 0xcf),
        ):
            reference.write(address, entry.to_bytes(8, 'little'))
        reference.write(physical + 4094, bytes([0x31, 0x32]))
        state.satp[0] = (8 << 60) | (root >> 12)
        state.mstatus[0] = (state.mstatus[0] & ~(3 << 11)) | (1 << 17) | (1 << 11)
        reference.run([0x12000073])
        vset(0xc0, 4)
        state.gpr[1] = virtual + 4094
        pc = reference.run([fof_instruction(0, 1, 1, 9)])
        check('vle8ff-page-trim-no-trap', state.pc[0], pc + 4)
        check('vle8ff-page-trim-data', list(vector_get().reg[9][:2]), [0x31, 0x32])
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        check('vle8ff-page-trim-vl', state.gpr[3], 2)
        reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
        check('vle8ff-page-trim-vstart', state.gpr[3], 0)
        vset(0xc0, 4)
        state.gpr[1] = virtual + 4096
        pc = reference.run([fof_instruction(0, 1, 1, 9)])
        check('vle8ff-first-page-fault',
              [state.mcause[0], state.mepc[0], state.mtval[0]],
              [13, pc, virtual + 4096])
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        check('vle8ff-first-page-fault-vl', state.gpr[3], 4)
        state.mstatus[0] &= ~(1 << 17)
        state.satp[0] = 0
        reference.run([0x12000073])

    vset(0xff, 0)
    reference.run([(0xc21 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('whole-vill', state.gpr[3], 1 << (args.xlen - 1))
    reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('whole-vl-zero', state.gpr[3], 0)
    values = vector_get()
    for reg in range(8, 24):
        for byte in range(16):
            values.reg[reg][byte] = (reg * 16 + byte) & 0xff
    check('seed-whole-registers', vector_api.set_state(0, ctypes.byref(values)), 0)

    whole_cases = [(1, 0, 9), (2, 5, 10), (4, 6, 12), (8, 0, 16), (8, 7, 16)]
    for case_index, (registers, width, source_reg) in enumerate(whole_cases):
        address = data_address + 512 + case_index * 256
        size = registers * 16
        expected_store = bytes((reg * 16 + byte) & 0xff
                               for reg in range(source_reg, source_reg + registers)
                               for byte in range(16))
        state.gpr[1] = address
        reference.run([whole_instruction(True, 0, registers, 1, source_reg)])
        check(f'vs{registers}r-vill', list(reference.read(address, size)), list(expected_store))
        expected_load = bytes((byte + case_index * 17) & 0xff for byte in range(size))
        reference.write(address, expected_load)
        reference.run([whole_instruction(False, width, registers, 1, 24)])
        loaded = bytes(byte for reg in range(24, 24 + registers)
                       for byte in vector_get().reg[reg])
        check(f'vl{registers}re{8 << (width - 4) if width else 8}-vill',
              list(loaded), list(expected_load))

    values = vector_get()
    values.reg[25][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-whole-restart', vector_api.set_state(0, ctypes.byref(values)), 0)
    state.gpr[1] = data_address + 2048
    reference.write(state.gpr[1], bytes(range(16)))
    csr_write(0x008, 2)
    reference.run([whole_instruction(False, 0, 1, 1, 25)])
    check('whole-vstart-prefix', list(vector_get().reg[25]), [0xa5, 0xa5] + list(range(2, 16)))
    csr_write(0x008, 16)
    before = list(vector_get().reg[25])
    pc = reference.run([whole_instruction(False, 0, 1, 1, 25)])
    check('whole-load-vstart-ge-evl-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('whole-load-vstart-ge-evl-undisturbed', list(vector_get().reg[25]), before)
    pc = reference.run([whole_instruction(True, 0, 1, 1, 9)])
    check('whole-store-vstart-ge-evl-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('whole-store-vstart-ge-evl-undisturbed',
          list(reference.read(state.gpr[1], 16)), list(range(16)))
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('whole-vstart-illegal-preserved', state.gpr[3], 16)
    csr_write(0x008, 0)

    values = vector_get()
    values.reg[25][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-whole-fault', vector_api.set_state(0, ctypes.byref(values)), 0)
    reference.write(edge_address, bytes([0x11, 0x22]))
    state.gpr[1] = edge_address
    pc = reference.run([whole_instruction(False, 0, 1, 1, 25)])
    check('whole-load-fault', [state.mcause[0], state.mepc[0]], [5, pc])
    check('whole-load-partial', list(vector_get().reg[25][:4]), [0x11, 0x22, 0xa5, 0xa5])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('whole-load-fault-vstart', state.gpr[3], 2)
    csr_write(0x008, 0)
    state.gpr[1] = edge_address
    pc = reference.run([whole_instruction(True, 0, 1, 1, 9)])
    check('whole-store-fault', [state.mcause[0], state.mepc[0]], [7, pc])
    check('whole-store-partial', list(reference.read(edge_address, 2)), [144, 145])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('whole-store-fault-vstart', state.gpr[3], 2)
    csr_write(0x008, 0)

    state.gpr[1] = data_address + 512
    invalid_whole = [
        ('whole-nregs3-illegal', whole_instruction(False, 0, 3, 1, 24)),
        ('whole-group-align-illegal', whole_instruction(False, 0, 2, 1, 25)),
        ('whole-masked-illegal', whole_instruction(False, 0, 1, 1, 24, vm=0)),
        ('whole-store-width-illegal', whole_instruction(True, 5, 1, 1, 24)),
        ('whole-mop-illegal', whole_instruction(False, 0, 1, 1, 24) | (1 << 26)),
    ]
    for name, invalid_instruction in invalid_whole:
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])

    pc = reference.run([group_move_instruction(1, 8, 24)])
    check('vmv1r-vill-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xc0, 0)
    values = vector_get()
    for reg in range(8, 16):
        for byte in range(16):
            values.reg[reg][byte] = (reg * 16 + byte) & 0xff
    check('seed-whole-move-source', vector_api.set_state(0, ctypes.byref(values)), 0)
    for registers in (1, 2, 4, 8):
        values = vector_get()
        for reg in range(24, 32):
            for byte in range(16):
                values.reg[reg][byte] = 0xa5
        check('seed-whole-move-destination', vector_api.set_state(0, ctypes.byref(values)), 0)
        reference.run([group_move_instruction(registers, 8, 24)])
        moved = [byte for reg in range(24, 24 + registers)
                 for byte in vector_get().reg[reg]]
        expected = [byte for reg in range(8, 8 + registers)
                    for byte in vector_get().reg[reg]]
        check(f'vmv{registers}r-vl-zero', moved, expected)

    before = [byte for reg in range(8, 16) for byte in vector_get().reg[reg]]
    csr_write(0x008, 2)
    reference.run([group_move_instruction(8, 8, 8)])
    actual = [byte for reg in range(8, 16) for byte in vector_get().reg[reg]]
    check('vmv8r-same-group', actual, before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vmv8r-same-group-vstart-cleared', state.gpr[3], 0)

    values = vector_get()
    values.reg[25][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-move-restart', vector_api.set_state(0, ctypes.byref(values)), 0)
    csr_write(0x008, 2)
    reference.run([group_move_instruction(1, 8, 25)])
    check('vmv1r-vstart-byte', list(vector_get().reg[25]),
          [0xa5] * 2 + list(vector_get().reg[8][2:]))
    csr_write(0x008, 16)
    before = list(vector_get().reg[25])
    pc = reference.run([group_move_instruction(1, 8, 25)])
    check('vmv1r-vstart-eq-evl-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('vmv1r-vstart-eq-evl-undisturbed', list(vector_get().reg[25]), before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vmv1r-vstart-illegal-preserved', state.gpr[3], 16)
    csr_write(0x008, 17)
    pc = reference.run([group_move_instruction(1, 8, 25)])
    check('vmv1r-vstart-gt-evl-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('vmv1r-vstart-gt-evl-undisturbed', list(vector_get().reg[25]), before)
    csr_write(0x008, 0)

    vset(0xd0, 0)
    values = vector_get()
    values.reg[25][:] = (ctypes.c_uint8 * 16)(*[0xa5] * 16)
    check('seed-move-e32-restart', vector_api.set_state(0, ctypes.byref(values)), 0)
    csr_write(0x008, 1)
    reference.run([group_move_instruction(1, 8, 25)])
    check('vmv1r-vstart-e32', list(vector_get().reg[25]),
          [0xa5] * 4 + list(vector_get().reg[8][4:]))
    vset(0xc0, 0)
    invalid_moves = [
        ('vmv3r-illegal', group_move_instruction(3, 8, 24)),
        ('vmv2r-source-align-illegal', group_move_instruction(2, 9, 24)),
        ('vmv2r-destination-align-illegal', group_move_instruction(2, 8, 25)),
        ('vmv1r-masked-illegal', group_move_instruction(1, 8, 24, vm=0)),
    ]
    for name, invalid_instruction in invalid_moves:
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])

    values = vector_get()
    for reg in (15, 24):
        for byte in range(16):
            values.reg[reg][byte] = 0xa5
    check('restore-ordinary-destinations', vector_api.set_state(0, ctypes.byref(values)), 0)
    vset(0xc0, 4)
    values = vector_get()
    values.reg[0][0] = 0x0a
    for index, value in enumerate([250, 1, 128, 127]):
        values.reg[1][index] = value
    for index, value in enumerate([10, 2, 1, 128]):
        values.reg[2][index] = value
    check('seed-integer-operands', vector_api.set_state(0, ctypes.byref(values)), 0)

    integer_cases = [
        ('vsub-vv', 0x02, 0, 2, [240, 255, 127, 255]),
        ('vrsub-vi', 0x03, 3, 5, [11, 4, 133, 134]),
        ('vmin-vv', 0x05, 0, 2, [250, 1, 128, 128]),
        ('vmaxu-vv', 0x06, 0, 2, [250, 2, 128, 128]),
        ('vand-vv', 0x09, 0, 2, [10, 0, 0, 0]),
        ('vor-vi', 0x0a, 3, 3, [251, 3, 131, 127]),
        ('vsll-vi', 0x25, 3, 1, [244, 2, 0, 254]),
        ('vsrl-vi', 0x28, 3, 1, [125, 0, 64, 63]),
        ('vsra-vi', 0x29, 3, 1, [253, 0, 192, 63]),
    ]
    for destination, (name, function, form, source1, expected) in enumerate(integer_cases, 3):
        reference.run([instruction(function, 1, 1, source1, form, destination)])
        check(name, list(vector_get().reg[destination][:4]), expected)

    state.gpr[1] = 0xff
    reference.run([instruction(0x0b, 1, 1, 1, 4, 12)])
    check('vxor-vx', list(vector_get().reg[12][:4]), [5, 254, 127, 128])
    reference.run([instruction(0x18, 1, 1, 1, 3, 20)])
    check('vmseq-vi', vector_get().reg[20][0] & 0x0f, 0x02)
    reference.run([instruction(0x1b, 1, 1, 2, 0, 21)])
    check('vmslt-vv', vector_get().reg[21][0] & 0x0f, 0x07)
    state.gpr[1] = 100
    reference.run([instruction(0x1e, 1, 1, 1, 4, 22)])
    check('vmsgtu-vx', vector_get().reg[22][0] & 0x0f, 0x0d)
    reference.run([instruction(0x17, 0, 1, 2, 0, 23)])
    check('vmerge-vvm', list(vector_get().reg[23][:4]), [250, 2, 128, 128])
    reference.run([instruction(0x17, 1, 0, 1, 0, 25)])
    check('vmv-v-v', list(vector_get().reg[25][:4]), [250, 1, 128, 127])
    reference.run([instruction(0, 0, 1, 2, 0, 15)])
    check('masked-vadd', list(vector_get().reg[15][:4]), [0xa5, 3, 0xa5, 255])

    reference.write(data_address + 256, bytes([100, 101, 102, 103]))
    state.gpr[1] = data_address + 256
    reference.run([memory_instruction(False, 0, 0, 1, 24)])
    check('masked-vle8', list(vector_get().reg[24][:4]), [0xa5, 101, 0xa5, 103])
    reference.write(data_address + 272, bytes([0x77] * 4))
    state.gpr[1] = data_address + 272
    reference.run([memory_instruction(True, 0, 0, 1, 24)])
    check('masked-vse8', list(reference.read(data_address + 272, 4)), [0x77, 101, 0x77, 103])

    saved_vector = vector_get()
    state.gpr[1] = data_address + 512
    reference.write(data_address + 512, bytes([0x77] * 16))
    pc = reference.run([instruction(0x10, 0, 0, 16, 2, 3)])
    check('vcpop-mask-source-v0-legal', [state.pc[0], state.gpr[3]], [pc + 4, 2])
    pc = reference.run([instruction(0x14, 0, 0, 1, 2, 25)])
    check('vmsbf-mask-source-v0-legal', state.pc[0], pc + 4)
    pc = reference.run([instruction(0, 1, 0, 8, 0, 24)])
    check('vadd-unmasked-data-v0-legal', state.pc[0], pc + 4)
    pc = reference.run([memory_instruction(True, 0, 1, 1, 0)])
    check('vse8-unmasked-data-v0-legal', state.pc[0], pc + 4)
    check('vse8-unmasked-data-v0-values', list(reference.read(data_address + 512, 4)),
          list(vector_get().reg[0][:4]))
    reference.write(data_address + 512, bytes([0x77] * 16))
    before_v0 = list(vector_get().reg[0])
    before_v24 = list(vector_get().reg[24])
    source_v8 = list(vector_get().reg[8])
    for name, source2, source1 in (
        ('vadd-mask-data-vs2-v0', 0, 8),
        ('vadd-mask-data-vs1-v0', 8, 0),
    ):
        pc = reference.run([instruction(0, 0, source2, source1, 0, 24)])
        check(name + '-legal', state.pc[0], pc + 4)
        expected = before_v24[:4]
        for index in range(4):
            if before_v0[0] & (1 << index):
                expected[index] = (before_v0[index] + source_v8[index]) & 255
        check(name + '-result', list(vector_get().reg[24][:4]), expected)
    pc = reference.run([instruction(0, 0, 8, 0, 2, 24)])
    check('vredsum-mask-seed-v0-legal', state.pc[0], pc + 4)
    check('vredsum-mask-seed-v0-result', vector_get().reg[24][0],
          (before_v0[0] + source_v8[1] + source_v8[3]) & 255)
    pc = reference.run([memory_instruction(True, 0, 0, 1, 0)])
    check('vse8-mask-data-v0-legal', state.pc[0], pc + 4)
    check('vse8-mask-data-v0-values', list(reference.read(data_address + 512, 4)),
          [0x77, before_v0[1], 0x77, before_v0[3]])
    pc = reference.run([indexed_instruction(False, 0, 0, 1, 0, 24)])
    check('vluxei8-mask-index-v0-legal', state.pc[0], pc + 4)
    check('vluxei8-mask-index-v0-source-undisturbed', list(vector_get().reg[0]), before_v0)
    pc = reference.run([instruction(0x18, 0, 0, 8, 0, 0)])
    check('vmseq-mask-data-v0-legal', state.pc[0], pc + 4)
    check('vmseq-mask-data-v0-result', vector_get().reg[0][0] & 0x0f,
          sum((before_v0[index] == source_v8[index]) << index for index in (1, 3)))
    check('restore-mask-before-fp-v0', vector_api.set_state(0, ctypes.byref(saved_vector)), 0)
    vset(0xd0, 4)
    pc = reference.run([instruction(0, 0, 8, 0, 1, 24)])
    check('vfadd-mask-data-vs1-v0-legal', state.pc[0], pc + 4)
    vset(0xc0, 4)
    check('restore-mask-data-v0', vector_api.set_state(0, ctypes.byref(saved_vector)), 0)

    reference.run([instruction(0x19, 0, 1, 1, 3, 20)])
    check('masked-vmsne-vi', vector_get().reg[20][0] & 0x0f, 0x08)
    reference.run([instruction(0x18, 0, 1, 1, 3, 0)])
    check('masked-vmseq-v0', vector_get().reg[0][0] & 0x0f, 0x02)

    before = list(vector_get().reg[0])
    pc = reference.run([instruction(0, 0, 1, 2, 0, 0)])
    check('masked-destination-v0-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('masked-destination-v0-unchanged', list(vector_get().reg[0]), before)
    pc = reference.run([memory_instruction(False, 0, 0, 1, 0)])
    check('masked-load-v0-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x02, 1, 1, 1, 3, 16)])
    check('vsub-vi-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    pc = reference.run([instruction(0x1a, 1, 1, 1, 3, 16)])
    check('vmsltu-vi-illegal', [state.mcause[0], state.mepc[0]], [2, pc])

    vset(0xc0, 11)
    values = vector_get()
    values.reg[0][0] = 0x5a
    values.reg[0][1] = 0xa5
    values.reg[24][0] = 0xa5
    values.reg[24][1] = 0xa5
    check('seed-mask-memory', vector_api.set_state(0, ctypes.byref(values)), 0)
    state.gpr[1] = data_address + 3072
    reference.run([mask_instruction(True, 1, 0)])
    check('vsm-v0-two-bytes', list(reference.read(state.gpr[1], 2)), [0x5a, 0xa5])
    reference.write(state.gpr[1], bytes([0x3c, 0xc3]))
    reference.run([mask_instruction(False, 1, 24)])
    check('vlm-two-bytes', list(vector_get().reg[24][:3]), [0x3c, 0xc3, 0xa5])
    reference.run([mask_instruction(False, 1, 0)])
    check('vlm-v0', list(vector_get().reg[0][:2]), [0x3c, 0xc3])

    csr_write(0x008, 1)
    values = vector_get()
    values.reg[24][0] = 0xa5
    values.reg[24][1] = 0xa5
    check('seed-mask-restart', vector_api.set_state(0, ctypes.byref(values)), 0)
    reference.run([mask_instruction(False, 1, 24)])
    check('vlm-vstart-byte', list(vector_get().reg[24][:2]), [0xa5, 0xc3])
    csr_write(0x008, 2)
    before = list(vector_get().reg[24])
    reference.run([mask_instruction(False, 1, 24)])
    check('vlm-vstart-ge-evl-noop', list(vector_get().reg[24]), before)
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vlm-vstart-cleared', state.gpr[3], 0)

    reference.write(edge_address + 1, bytes([0x7e]))
    state.gpr[1] = edge_address + 1
    values = vector_get()
    values.reg[24][0] = 0xa5
    values.reg[24][1] = 0xa5
    check('seed-mask-fault', vector_api.set_state(0, ctypes.byref(values)), 0)
    pc = reference.run([mask_instruction(False, 1, 24)])
    check('vlm-fault', [state.mcause[0], state.mepc[0]], [5, pc])
    check('vlm-fault-partial', list(vector_get().reg[24][:2]), [0x7e, 0xa5])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vlm-fault-vstart-byte', state.gpr[3], 1)
    csr_write(0x008, 0)
    pc = reference.run([mask_instruction(True, 1, 0)])
    check('vsm-fault', [state.mcause[0], state.mepc[0]], [7, pc])
    check('vsm-fault-partial', list(reference.read(edge_address + 1, 1)), [0x3c])
    reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('vsm-fault-vstart-byte', state.gpr[3], 1)
    csr_write(0x008, 0)

    state.gpr[1] = data_address + 3072
    invalid_masks = [
        ('vlm-masked-illegal', mask_instruction(False, 1, 24, vm=0)),
        ('vlm-nf-illegal', mask_instruction(False, 1, 24) | (1 << 29)),
        ('vlm-width-illegal', mask_instruction(False, 1, 24) | (5 << 12)),
    ]
    for name, invalid_instruction in invalid_masks:
        pc = reference.run([invalid_instruction])
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])
    vset(0xff, 0)
    pc = reference.run([mask_instruction(False, 1, 24)])
    check('vlm-vill-illegal', [state.mcause[0], state.mepc[0]], [2, pc])
    check('hart-range', vector_api.get_state(1, ctypes.byref(VectorState())), -1)

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_DATA xlen={args.xlen} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
