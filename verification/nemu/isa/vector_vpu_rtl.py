"""Compare NEMU V128 instruction state against the complete standalone RTL VPU."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import subprocess

from isa.vector_data import VectorAPI, VectorState, instruction
from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]
OPERATIONS = (
    ('vadd', 0x00, 0, 8, 16, 24),
    ('vslideup', 0x0e, 3, 8, 1, 24),
    ('vslidedown', 0x0f, 3, 8, 1, 24),
    ('vrgather', 0x0c, 0, 8, 16, 24),
    ('vmsbf', 0x14, 2, 8, 1, 24),
    ('vmsof', 0x14, 2, 8, 2, 24),
    ('vmsif', 0x14, 2, 8, 3, 24),
    ('viota', 0x14, 2, 8, 16, 24),
    ('vid', 0x14, 2, 0, 17, 24),
    ('vcompress', 0x17, 2, 8, 16, 24),
    ('vcpop', 0x10, 2, 8, 16, 24),
    ('vfirst', 0x10, 2, 8, 17, 24),
    ('vmv.x.s', 0x10, 2, 8, 0, 24),
    ('vmv.s.x', 0x10, 6, 0, 5, 24),
    ('vsaddu.vv', 0x20, 0, 8, 16, 24),
    ('vsadd.vv', 0x21, 0, 8, 16, 24),
    ('vssubu.vv', 0x22, 0, 8, 16, 24),
    ('vssub.vv', 0x23, 0, 8, 16, 24),
    ('vsaddu.vx', 0x20, 4, 8, 5, 24),
    ('vsadd.vx', 0x21, 4, 8, 5, 24),
    ('vssubu.vx', 0x22, 4, 8, 5, 24),
    ('vssub.vx', 0x23, 4, 8, 5, 24),
    ('vsaddu.vi', 0x20, 3, 8, 1, 24),
    ('vsadd.vi', 0x21, 3, 8, 1, 24),
    ('vaaddu.vv', 0x08, 2, 8, 16, 24),
    ('vaadd.vv', 0x09, 2, 8, 16, 24),
    ('vasubu.vv', 0x0a, 2, 8, 16, 24),
    ('vasub.vv', 0x0b, 2, 8, 16, 24),
    ('vaaddu.vx', 0x08, 6, 8, 5, 24),
    ('vaadd.vx', 0x09, 6, 8, 5, 24),
    ('vasubu.vx', 0x0a, 6, 8, 5, 24),
    ('vasub.vx', 0x0b, 6, 8, 5, 24),
    ('vssrl.vv', 0x2a, 0, 8, 16, 24),
    ('vssra.vv', 0x2b, 0, 8, 16, 24),
    ('vssrl.vx', 0x2a, 4, 8, 5, 24),
    ('vssra.vx', 0x2b, 4, 8, 5, 24),
    ('vssrl.vi', 0x2a, 3, 8, 1, 24),
    ('vssra.vi', 0x2b, 3, 8, 1, 24),
    ('vsmul.vv', 0x27, 0, 8, 16, 24),
    ('vsmul.vx', 0x27, 4, 8, 5, 24),
    ('vnsrl.wv', 0x2c, 0, 8, 16, 24),
    ('vnsra.wv', 0x2d, 0, 8, 16, 24),
    ('vnsrl.wx', 0x2c, 4, 8, 5, 24),
    ('vnsra.wx', 0x2d, 4, 8, 5, 24),
    ('vnsrl.wi', 0x2c, 3, 8, 1, 24),
    ('vnsra.wi', 0x2d, 3, 8, 1, 24),
    ('vnclipu.wv', 0x2e, 0, 8, 16, 24),
    ('vnclip.wv', 0x2f, 0, 8, 16, 24),
    ('vnclipu.wx', 0x2e, 4, 8, 5, 24),
    ('vnclip.wx', 0x2f, 4, 8, 5, 24),
    ('vnclipu.wi', 0x2e, 3, 8, 1, 24),
    ('vnclip.wi', 0x2f, 3, 8, 1, 24),
    ('vwaddu.vv', 0x30, 2, 8, 16, 24),
    ('vwadd.vv', 0x31, 2, 8, 16, 24),
    ('vwsubu.vv', 0x32, 2, 8, 16, 24),
    ('vwsub.vv', 0x33, 2, 8, 16, 24),
    ('vwaddu.vx', 0x30, 6, 8, 5, 24),
    ('vwadd.vx', 0x31, 6, 8, 5, 24),
    ('vwsubu.vx', 0x32, 6, 8, 5, 24),
    ('vwsub.vx', 0x33, 6, 8, 5, 24),
    ('vwaddu.wv', 0x34, 2, 8, 16, 24),
    ('vwadd.wv', 0x35, 2, 8, 16, 24),
    ('vwsubu.wv', 0x36, 2, 8, 16, 24),
    ('vwsub.wv', 0x37, 2, 8, 16, 24),
    ('vwaddu.wx', 0x34, 6, 8, 5, 24),
    ('vwadd.wx', 0x35, 6, 8, 5, 24),
    ('vwsubu.wx', 0x36, 6, 8, 5, 24),
    ('vwsub.wx', 0x37, 6, 8, 5, 24),
    ('vwmulu.vv', 0x38, 2, 8, 16, 24),
    ('vwmulsu.vv', 0x3a, 2, 8, 16, 24),
    ('vwmul.vv', 0x3b, 2, 8, 16, 24),
    ('vwmaccu.vv', 0x3c, 2, 8, 16, 24),
    ('vwmacc.vv', 0x3d, 2, 8, 16, 24),
    ('vwmaccsu.vv', 0x3f, 2, 8, 16, 24),
    ('vwmulu.vx', 0x38, 6, 8, 5, 24),
    ('vwmulsu.vx', 0x3a, 6, 8, 5, 24),
    ('vwmul.vx', 0x3b, 6, 8, 5, 24),
    ('vwmaccu.vx', 0x3c, 6, 8, 5, 24),
    ('vwmacc.vx', 0x3d, 6, 8, 5, 24),
    ('vwmaccus.vx', 0x3e, 6, 8, 5, 24),
    ('vwmaccsu.vx', 0x3f, 6, 8, 5, 24),
    ('vzext.vf8', 0x12, 2, 8, 2, 24),
    ('vsext.vf8', 0x12, 2, 8, 3, 24),
    ('vzext.vf4', 0x12, 2, 8, 4, 24),
    ('vsext.vf4', 0x12, 2, 8, 5, 24),
    ('vzext.vf2', 0x12, 2, 8, 6, 24),
    ('vsext.vf2', 0x12, 2, 8, 7, 24),
)


def seeded_bytes(seed):
    raw = bytearray((index * 29 + (index // 16) * 37 + seed * 13) & 255
                    for index in range(512))
    if seed == 255:
        raw[8 * 16] = raw[16 * 16] = 0x80
    elif seed == 254:
        raw[8 * 16:8 * 16 + 2] = b'\xff\xff'
    elif seed == 253:
        raw[8 * 16:8 * 16 + 2] = b'\x00\x80'
    elif seed == 252:
        raw[8 * 16:8 * 16 + 4] = (0x7f800001).to_bytes(4, 'little')
        raw[16 * 16:16 * 16 + 4] = (0x3f800000).to_bytes(4, 'little')
        raw[24 * 16:24 * 16 + 8] = (0x3ff0000000000000).to_bytes(8, 'little')
    elif seed == 251:
        raw[8 * 16:8 * 16 + 8] = (0x3ff0000010000000).to_bytes(8, 'little')
        raw[16 * 16:16 * 16 + 4] = (0x3f800000).to_bytes(4, 'little')
        raw[24 * 16:24 * 16 + 8] = (0x3ff0000000000000).to_bytes(8, 'little')
    elif seed in (247, 248, 249, 250):
        low, high = {
            247: (0x8000000100000001, 0x807fffff007fffff),
            248: (0x7ff0000000000000, 0xfff0000000000000),
            249: (0, 0x8000000000000000),
            250: (0x8000000000000000, 0xff8000007f800000),
        }[seed]
        raw[8 * 16:8 * 16 + 16] = low.to_bytes(8, 'little') + high.to_bytes(8, 'little')
    return bytes(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
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
    for sew in range(4):
        for lmul in (1, 2, 4, 8):
            maximum = (16 >> sew) * lmul
            for avl in (0, 3, maximum):
                for name, function, form, source2, source1, destination in OPERATIONS:
                    for vm in ((1,) if name == 'vcompress' else (0, 1)):
                        for seed in (3, 79):
                            start = 0 if name in ('vmsbf', 'vmsof', 'vmsif',
                                                   'viota', 'vcompress', 'vcpop',
                                                   'vfirst') or seed == 3 else 1
                            cases.append(dict(name=name, sew=sew, lmul=lmul, avl=avl,
                                              vtype=0xc0 | (sew << 3) | (lmul.bit_length() - 1),
                                              start=start, seed=seed, scalar=1,
                                              rounding=(seed + sew + lmul + avl) & 3,
                                              instruction=instruction(
                                                  function, vm, source2, source1,
                                                  form, destination)))
    for name, insn, vtype, start in (
        ('vcompress-masked', instruction(0x17, 0, 8, 16, 2, 24), 0xc0, 0),
        ('vcompress-restart', instruction(0x17, 1, 8, 16, 2, 24), 0xc0, 1),
        ('vcompress-data-mask-v0', instruction(0x17, 1, 0, 0, 2, 24), 0xc0, 0),
        ('vcompress-mask-v0-legal', instruction(0x17, 1, 8, 0, 2, 24), 0xc0, 0),
        ('vcompress-data-mask-group-overlap', instruction(0x17, 1, 8, 9, 2, 24), 0xc1, 0),
        ('vrgatherei16-source-overlap-different-eew',
         instruction(0x0e, 1, 8, 8, 0, 24), 0xc0, 0),
        ('vrgatherei16-source-overlap-same-eew',
         instruction(0x0e, 1, 8, 8, 0, 24), 0xc8, 0),
        ('vcpop-restart', instruction(0x10, 1, 8, 16, 2, 24), 0xc0, 1),
        ('vfirst-restart', instruction(0x10, 1, 8, 17, 2, 24), 0xc0, 1),
        ('vmsbf-restart', instruction(0x14, 1, 8, 1, 2, 24), 0xc0, 1),
        ('vadd-vill', instruction(0, 1, 8, 16, 0, 24), 0x100, 0),
        ('vssubu.vi-illegal', instruction(0x22, 1, 8, 1, 3, 24), 0xc0, 0),
        ('vaaddu.vi-illegal', instruction(0x08, 1, 8, 1, 3, 24), 0xc0, 0),
        ('vssrl-opm-illegal', instruction(0x2a, 1, 8, 16, 2, 24), 0xc0, 0),
        ('vwmul-reserved-illegal', instruction(0x39, 1, 8, 16, 2, 24), 0xc0, 0),
        ('vwmaccus-vv-illegal', instruction(0x3e, 1, 8, 16, 2, 24), 0xc0, 0),
        ('vadd-masked-vs2-v0', instruction(0, 0, 0, 16, 0, 24), 0xc0, 0),
        ('vadd-masked-vs1-v0', instruction(0, 0, 8, 0, 0, 24), 0xc0, 0),
        ('vadd-unmasked-vs2-v0', instruction(0, 1, 0, 16, 0, 24), 0xc0, 0),
        ('vmsbf-masked-source-v0', instruction(0x14, 0, 0, 1, 2, 24), 0xc0, 0),
        ('viota-masked-source-v0', instruction(0x14, 0, 0, 16, 2, 24), 0xc0, 0),
        ('vid-masked-unused-vs2-v0', instruction(0x14, 0, 0, 17, 2, 24), 0xc0, 0),
    ):
        cases.append(dict(name=name, sew=0, lmul=1, avl=8, vtype=vtype, start=start,
                          seed=79 if name == 'vssubu.vi-illegal' else 47,
                          scalar=1, rounding=2, instruction=insn))
    for name, function, form, sew, avl, start, source1 in (
        ('vadd-vstart-vlmax', 0x00, 0, 0, 16, 16, 16),
        ('vadd-vstart-past-vlmax', 0x00, 0, 0, 3, 17, 16),
        ('vnsra-vstart-vlmax', 0x2d, 3, 0, 16, 16, 12),
        ('vnclip-vstart-vlmax', 0x2f, 3, 0, 16, 16, 12),
        ('vwmacc-vstart-vlmax', 0x3d, 2, 0, 16, 16, 16),
        ('vzext-vstart-vlmax', 0x12, 2, 1, 8, 8, 6),
        ('vmv.x.s-vstart-vlmax', 0x10, 2, 0, 16, 16, 0),
    ):
        cases.append(dict(name=name, sew=sew, lmul=1, avl=avl,
                          vtype=0xc0 | (sew << 3), start=start,
                          seed=79, scalar=1, rounding=2,
                          instruction=instruction(function, 1, 8, source1, form, 24)))
    cases.append(dict(name='vmv.x.s-unaligned-source-and-rd', sew=0, lmul=8,
                      avl=0, vtype=0xc3, start=17, seed=79, scalar=1,
                      rounding=2, instruction=instruction(0x10, 1, 9, 0, 2, 3)))
    for name, source2, vm, avl, start, scalar in (
        ('vmv.s.x-negative-scalar', 0, 1, 2, 0, 0x80000001),
        ('vmv.s.x-vstart-nonzero', 0, 1, 2, 1, 0x80000001),
        ('vmv.s.x-vstart-ge-vl', 0, 1, 2, 2, 0x80000001),
        ('vmv.s.x-masked-illegal', 0, 0, 2, 0, 0x80000001),
        ('vmv.s.x-vs2-illegal', 8, 1, 2, 0, 0x80000001),
    ):
        cases.append(dict(name=name, sew=3, lmul=8, avl=avl, vtype=0xdb,
                          start=start, seed=79, scalar=scalar, rounding=2,
                          instruction=instruction(0x10, vm, source2, 5, 6, 24)))
    cases.append(dict(name='vsmul-saturate', sew=0, lmul=1, avl=1, vtype=0xc0,
                      start=0, seed=255, scalar=1, rounding=2,
                      instruction=instruction(0x27, 1, 8, 16, 0, 24)))
    cases.append(dict(name='vnclipu-overlap-low', sew=0, lmul=2, avl=32, vtype=0xc1,
                      start=0, seed=3, scalar=1, rounding=2,
                      instruction=instruction(0x2e, 1, 8, 16, 0, 8)))
    cases.append(dict(name='vnclipu-overlap-high-illegal', sew=0, lmul=2, avl=32,
                      vtype=0xc1, start=0, seed=3, scalar=1, rounding=2,
                      instruction=instruction(0x2e, 1, 8, 16, 0, 10)))
    cases.append(dict(name='vnclipu-saturate', sew=0, lmul=1, avl=1, vtype=0xc0,
                      start=0, seed=254, scalar=1, rounding=2,
                      instruction=instruction(0x2e, 1, 8, 0, 3, 24)))
    cases.append(dict(name='vnclip-saturate', sew=0, lmul=1, avl=1, vtype=0xc0,
                      start=0, seed=253, scalar=1, rounding=2,
                      instruction=instruction(0x2f, 1, 8, 0, 3, 24)))
    for name, function, form, source2, source1, destination, lmul in (
        ('vwaddu-overlap-high', 0x30, 2, 9, 16, 8, 1),
        ('vwaddu-overlap-low-illegal', 0x30, 2, 8, 16, 8, 1),
        ('vwaddu-vs1-overlap-high', 0x30, 2, 16, 9, 8, 1),
        ('vwaddu-vs1-overlap-low-illegal', 0x30, 2, 16, 8, 8, 1),
        ('vwaddu-wide-overlap', 0x34, 2, 8, 16, 8, 1),
        ('vwaddu-wide-misaligned-illegal', 0x34, 2, 9, 16, 8, 1),
        ('vwaddu-fraction-overlap-illegal', 0x30, 2, 8, 16, 8, -1),
        ('vwaddu-wide-fraction-overlap', 0x34, 2, 8, 16, 8, -1),
        ('vwmaccu-overlap-high', 0x3c, 2, 9, 16, 8, 1),
        ('vwmaccu-overlap-low-illegal', 0x3c, 2, 8, 16, 8, 1),
        ('vwmaccsu-vs1-overlap-high', 0x3f, 2, 16, 9, 8, 1),
        ('vwmaccsu-vs1-overlap-low-illegal', 0x3f, 2, 16, 8, 8, 1),
        ('vnsrl-overlap-low', 0x2c, 0, 8, 16, 8, 2),
        ('vnsrl-overlap-high-illegal', 0x2c, 0, 8, 16, 10, 2),
    ):
        encoded_lmul = lmul if lmul >= 0 else 8 + lmul
        cases.append(dict(name=name, sew=0, lmul=lmul, avl=8,
                          vtype=0xc0 | encoded_lmul, start=0, seed=79,
                          scalar=1, rounding=2, instruction=instruction(
                              function, 1, source2, source1, form, destination)))
    for name, function, form, source1, lmul, expected_trap in (
        ('vwaddu-wv-source-eew-overlap', 0x34, 2, 9, 1, 1),
        ('vwaddu-wv-source-eew-partial-overlap', 0x34, 2, 10, 2, 1),
        ('vwaddu-wv-source-eew-disjoint', 0x34, 2, 12, 2, 0),
        ('vnsrl-wv-source-eew-overlap', 0x2c, 0, 9, 1, 1),
        ('vnsrl-wv-source-eew-partial-overlap', 0x2c, 0, 10, 2, 1),
        ('vnsrl-wv-source-eew-disjoint', 0x2c, 0, 12, 2, 0),
    ):
        cases.append(dict(name=name, sew=0, lmul=lmul, avl=8,
                          vtype=0xc0 | (lmul - 1), start=0, seed=79,
                          scalar=1, rounding=2, expected_trap=expected_trap,
                          instruction=instruction(function, 1, 8, source1, form, 24)))
    for name, source2 in (
        ('vzext-overlap-high', 9),
        ('vzext-overlap-low-illegal', 8),
    ):
        cases.append(dict(name=name, sew=1, lmul=2, avl=8, vtype=0xc9,
                          start=0, seed=79, scalar=1, rounding=2,
                          instruction=instruction(0x12, 1, source2, 6, 2, 8)))
    for sew, encoded_lmul, fraction, maximum in (
        (0, 5, 'mf8', 2), (0, 6, 'mf4', 4), (0, 7, 'mf2', 8),
        (1, 6, 'mf4', 2), (1, 7, 'mf2', 4), (2, 7, 'mf2', 2),
    ):
        for function, form, source1, seed in (
            (0x2e, 0, 16, 3), (0x2f, 3, 1, 79),
        ):
            cases.append(dict(name=f'vnclip-{fraction}', sew=sew, lmul=fraction,
                              avl=maximum, vtype=0xc0 | (sew << 3) | encoded_lmul,
                              start=int(seed == 79), seed=seed, scalar=1,
                              rounding=sew, instruction=instruction(
                                  function, 1, 8, source1, form, 24)))
        for function, form, source1 in (
            (0x30, 2, 16), (0x31, 6, 5),
            (0x34, 2, 16), (0x35, 6, 5),
            (0x38, 2, 16), (0x3a, 6, 5),
            (0x3c, 2, 16), (0x3e, 6, 5),
        ):
            cases.append(dict(name=f'vwadd-{fraction}', sew=sew, lmul=fraction,
                              avl=maximum, vtype=0xc0 | (sew << 3) | encoded_lmul,
                              start=0, seed=79, scalar=1, rounding=sew,
                              instruction=instruction(function, 1, 8, source1,
                                                      form, 24)))
        for source1 in (2, 3, 4, 5, 6, 7):
            cases.append(dict(name=f'vext-{fraction}', sew=sew, lmul=fraction,
                              avl=maximum, vtype=0xc0 | (sew << 3) | encoded_lmul,
                              start=0, seed=79, scalar=1, rounding=sew,
                              instruction=instruction(0x12, 1, 8, source1, 2, 24)))
    for name, function in (
        ('vwmulsu-vx-negative-scalar', 0x3a),
        ('vwmaccus-vx-negative-scalar', 0x3e),
        ('vwmaccsu-vx-negative-scalar', 0x3f),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=4, vtype=0xd0,
                          start=0, seed=79, scalar=0xffffffffffffffff,
                          rounding=2, instruction=instruction(function, 1, 8, 5, 6, 24)))
    for name, function in (('vmadd', 0x29), ('vnmsub', 0x2b),
                           ('vmacc', 0x2d), ('vnmsac', 0x2f)):
        for form, source1 in ((2, 16), (6, 5)):
            for sew in range(4):
                for vm in (0, 1):
                    for seed in (3, 79):
                        cases.append(dict(name=f'{name}-{form}', sew=sew, lmul=1,
                                          avl=3, vtype=0xc0 | (sew << 3),
                                          start=int(seed == 79), seed=seed,
                                          scalar=3, rounding=2,
                                          instruction=instruction(function, vm, 8,
                                                                  source1, form, 24)))
                for lmul in (2, 4, 8):
                    for vm in (0, 1):
                        cases.append(dict(name=f'{name}-{form}-m{lmul}', sew=sew,
                                          lmul=lmul, avl=(16 >> sew) * lmul,
                                          vtype=0xc0 | (sew << 3) | (lmul.bit_length() - 1),
                                          start=1, seed=79, scalar=0xffffffffffffffff,
                                          rounding=2,
                                          instruction=instruction(function, vm, 8,
                                                                  source1, form, 24)))
            for sew, encoded_lmul, fraction, maximum in (
                (0, 5, 'mf8', 2), (0, 6, 'mf4', 4), (0, 7, 'mf2', 8)
            ):
                for vm in (0, 1):
                    cases.append(dict(name=f'{name}-{form}-{fraction}', sew=sew,
                                      lmul=fraction, avl=maximum,
                                      vtype=0xc0 | (sew << 3) | encoded_lmul,
                                      start=1, seed=79, scalar=0xffffffffffffffff,
                                      rounding=2,
                                      instruction=instruction(function, vm, 8,
                                                              source1, form, 24)))
            for destination in ((8, 16) if form == 2 else (8,)):
                cases.append(dict(name=f'{name}-{form}-overlap-v{destination}',
                                  sew=0, lmul=8, avl=128, vtype=0xc3,
                                  start=1, seed=79, scalar=3, rounding=2,
                                  instruction=instruction(function, 1, 8,
                                                          source1, form, destination)))

    expected_traps = {
        'vadd-masked-vs2-v0': 0,
        'vadd-masked-vs1-v0': 0,
        'vcompress-data-mask-v0': 1,
        'vcompress-mask-v0-legal': 0,
        'vcompress-data-mask-group-overlap': 1,
        'vrgatherei16-source-overlap-different-eew': 1,
        'vrgatherei16-source-overlap-same-eew': 0,
    }
    if expected_traps.keys() - {case['name'] for case in cases}:
        raise RuntimeError('Missing source-overlap DiffTest cases')
    for case in cases:
        state.gpr[2] = case['avl']
        state.gpr[3] = case['vtype']
        reference.run([0x803170d7])
        raw = seeded_bytes(case['seed'])
        vector = VectorState()
        for reg in range(32):
            for byte in range(16):
                vector.reg[reg][byte] = raw[reg * 16 + byte]
        if vector_api.set_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot seed vector registers')
        state.gpr[4] = case['start']
        reference.run([(0x008 << 20) | (4 << 15) | (1 << 12) | 0x73])
        state.gpr[4] = int(case['seed'] == 79)
        reference.run([(0x009 << 20) | (4 << 15) | (1 << 12) | 0x73])
        state.gpr[4] = case['rounding']
        reference.run([(0x00a << 20) | (4 << 15) | (1 << 12) | 0x73])
        state.gpr[5] = case['scalar']
        state.gpr[24] = 0
        pc = reference.run([case['instruction']])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        expected_trap = case.get('expected_trap', expected_traps.get(case['name']))
        if expected_trap is not None and case['nemu_trap'] != expected_trap:
            raise RuntimeError(f'Unexpected NEMU admission for {case["name"]}')
        case['nemu_cause'] = state.mcause[0] if case['nemu_trap'] else 0
        case['nemu_tval'] = state.mtval[0] if case['nemu_trap'] else 0
        case['nemu_value'] = state.gpr[(case['instruction'] >> 7) & 31] if not case['nemu_trap'] else 0
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu_state'] = bytes(byte for reg in vector.reg for byte in reg)
        if case['name'] in ('vadd-masked-vs2-v0', 'vadd-masked-vs1-v0'):
            expected = bytearray(raw)
            source2 = (case['instruction'] >> 20) & 31
            source1 = (case['instruction'] >> 15) & 31
            for index in range(case['avl']):
                if raw[index >> 3] & (1 << (index & 7)):
                    expected[24 * 16 + index] = (
                        raw[source2 * 16 + index] + raw[source1 * 16 + index]
                    ) & 255
            if case['nemu_state'] != bytes(expected):
                raise RuntimeError(f'Unexpected masked v0 source result for {case["name"]}')
        reference.run([(0xc20 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vl'] = state.gpr[3]
        reference.run([(0xc21 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vtype'] = state.gpr[3]
        reference.run([(0x008 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vstart'] = state.gpr[3]
        reference.run([(0x009 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vxsat'] = state.gpr[3]
        reference.run([(0x00a << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vxrm'] = state.gpr[3]
        reference.run([(0x00f << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_vcsr'] = state.gpr[3]

    vectors = args.output / 'vectors.txt'
    vectors.write_text(''.join(
        f'{case["instruction"]:x} {case["vtype"]:x} {case["avl"]:x} '
        f'{case["start"]:x} {case["scalar"]:x} {case["seed"]:x} '
        f'{case["rounding"]:x}\n'
        for case in cases))
    build_root = args.output / 'vpu-build'
    build_dir = build_root / f'top-{args.xlen}-128-64-64-2-opt1'
    build_command = ['make', '-C', str(ROOT / 'verification/vpu'), 'top-build',
                     f'XLEN={args.xlen}', 'VLEN=128', 'ELEN=64', 'BANK_BITS=64',
                     'BANKS=2', f'BUILD_DIR={build_root}', 'JOBS=2']
    with (args.output / 'build.log').open('w') as log:
        subprocess.run(build_command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([build_dir / 'Vrapt_vpu', '--nemu-diff', vectors],
                            capture_output=True, text=True, check=True)
    (args.output / 'run.log').write_text(result.stdout + result.stderr)
    outputs = [line.split() for line in result.stdout.splitlines()
               if line.startswith('VPU_NEMU_RESULT ')]
    if len(outputs) != len(cases):
        raise RuntimeError(f'RTL produced {len(outputs)} results for {len(cases)} cases')
    failures = []
    for case, output in zip(cases, outputs):
        if len(output) != 13:
            raise RuntimeError(f'Malformed RTL result: {output}')
        rtl_trap = int(output[1])
        rtl_cause, rtl_tval = (int(field, 16) for field in output[2:4])
        rtl_rd = int(output[4])
        rtl_value, rtl_vl, rtl_vtype, rtl_vstart, rtl_vxsat, rtl_vxrm, rtl_vcsr = (
            int(field, 16) for field in output[5:12])
        rtl_state = bytes.fromhex(output[12])
        first_mismatch = next((index for index, (nemu_byte, rtl_byte)
                               in enumerate(zip(case['nemu_state'], rtl_state))
                               if nemu_byte != rtl_byte), None)
        scalar_result = (case['name'] in ('vcpop', 'vfirst', 'vmv.x.s',
                                         'vmv.x.s-vstart-vlmax',
                                         'vmv.x.s-unaligned-source-and-rd') and not rtl_trap)
        if (len(rtl_state) != 512 or case['nemu_trap'] != rtl_trap or
                (rtl_trap and (case['nemu_cause'] != rtl_cause or
                               case['nemu_tval'] != rtl_tval)) or
                (scalar_result and (rtl_rd != ((case['instruction'] >> 7) & 31) or
                                    case['nemu_value'] != rtl_value)) or
                case['nemu_vl'] != rtl_vl or case['nemu_vtype'] != rtl_vtype or
                case['nemu_vstart'] != rtl_vstart or case['nemu_vxsat'] != rtl_vxsat or
                case['nemu_vxrm'] != rtl_vxrm or
                case['nemu_vcsr'] != rtl_vcsr or case['nemu_state'] != rtl_state or
                (case['name'] == 'vsmul-saturate' and
                 (case['nemu_vxsat'] != 1 or rtl_vxsat != 1 or
                  case['nemu_state'][24 * 16] != 0x7f or
                  rtl_state[24 * 16] != 0x7f)) or
                (case['name'] in ('vnclipu-saturate', 'vnclip-saturate') and
                 (case['nemu_vxsat'] != 1 or rtl_vxsat != 1 or
                  case['nemu_state'][24 * 16] !=
                  (0xff if case['name'] == 'vnclipu-saturate' else 0x80) or
                  rtl_state[24 * 16] !=
                  (0xff if case['name'] == 'vnclipu-saturate' else 0x80)))):
            failures.append(dict(name=case['name'], sew=case['sew'], lmul=case['lmul'],
                                 avl=case['avl'],
                                 seed=case['seed'], start=case['start'],
                                 instruction=case['instruction'],
                                 nemu_trap=case['nemu_trap'], rtl_trap=rtl_trap,
                                 nemu_cause=case['nemu_cause'], rtl_cause=rtl_cause,
                                 nemu_tval=case['nemu_tval'], rtl_tval=rtl_tval,
                                 nemu_value=case['nemu_value'], rtl_value=rtl_value,
                                 rtl_rd=rtl_rd,
                                 nemu_vl=case['nemu_vl'], rtl_vl=rtl_vl,
                                 nemu_vtype=case['nemu_vtype'], rtl_vtype=rtl_vtype,
                                 nemu_vstart=case['nemu_vstart'], rtl_vstart=rtl_vstart,
                                 nemu_vxsat=case['nemu_vxsat'], rtl_vxsat=rtl_vxsat,
                                 nemu_vxrm=case['nemu_vxrm'], rtl_vxrm=rtl_vxrm,
                                 nemu_vcsr=case['nemu_vcsr'], rtl_vcsr=rtl_vcsr,
                                 first_mismatch=first_mismatch))
    report = dict(xlen=args.xlen, cases=len(cases), failures=failures,
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                  vectors_sha256=hashlib.sha256(vectors.read_bytes()).hexdigest(),
                  vpu_sources_sha256=hashlib.sha256(
                      (build_dir / 'sources.json').read_bytes()).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    for failure in failures[:12]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_VPU_RTL xlen={args.xlen} '
          f'cases={len(cases)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
