"""Compare NEMU FP vectors with the complete standalone RTL VPU."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import subprocess

from isa.vector_data import VectorAPI, VectorState, instruction
from isa.vector_vpu_rtl import seeded_bytes
from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]
OPERATIONS = (
    ('vfmv.f.s', 0x10, 1, 8, 0, 24, 1),
    ('vfmv.s.f', 0x10, 5, 0, 5, 24, 1),
    ('vfmv.v.f', 0x17, 5, 0, 5, 24, 1),
    ('vfmerge.vfm', 0x17, 5, 8, 5, 24, 0),
    ('vfslide1up.vf', 0x0e, 5, 8, 5, 24, 1),
    ('vfslide1down.vf', 0x0f, 5, 8, 5, 24, 1),
    ('vfslide1up.vf-masked', 0x0e, 5, 8, 5, 24, 0),
    ('vfslide1down.vf-masked', 0x0f, 5, 8, 5, 24, 0),
    ('vfadd.vv', 0x00, 1, 8, 16, 24, 1),
    ('vfadd.vv-masked', 0x00, 1, 8, 16, 24, 0),
    ('vfadd.vf', 0x00, 5, 8, 5, 24, 1),
    ('vfredusum.vs', 0x01, 1, 8, 16, 24, 1),
    ('vfredusum.vs-masked', 0x01, 1, 8, 16, 24, 0),
    ('vfredosum.vs', 0x03, 1, 8, 16, 24, 1),
    ('vfredmin.vs', 0x05, 1, 8, 16, 24, 1),
    ('vfredmax.vs', 0x07, 1, 8, 16, 24, 1),
    ('vfwredusum.vs', 0x31, 1, 8, 16, 24, 1),
    ('vfwredusum.vs-masked', 0x31, 1, 8, 16, 24, 0),
    ('vfwredosum.vs', 0x33, 1, 8, 16, 24, 1),
    ('vfsub.vv', 0x02, 1, 8, 16, 24, 1),
    ('vfsub.vf', 0x02, 5, 8, 5, 24, 1),
    ('vfmin.vv', 0x04, 1, 8, 16, 24, 1),
    ('vfmin.vf', 0x04, 5, 8, 5, 24, 1),
    ('vfmax.vv', 0x06, 1, 8, 16, 24, 1),
    ('vfmax.vf', 0x06, 5, 8, 5, 24, 1),
    ('vfsgnj.vv', 0x08, 1, 8, 16, 24, 1),
    ('vfsgnj.vf', 0x08, 5, 8, 5, 24, 1),
    ('vfsgnjn.vv', 0x09, 1, 8, 16, 24, 1),
    ('vfsgnjn.vf', 0x09, 5, 8, 5, 24, 1),
    ('vfsgnjx.vv', 0x0a, 1, 8, 16, 24, 1),
    ('vfsgnjx.vf', 0x0a, 5, 8, 5, 24, 1),
    ('vfsqrt.v', 0x13, 1, 8, 0, 24, 1),
    ('vfsqrt.v-masked', 0x13, 1, 8, 0, 24, 0),
    ('vfrsqrt7.v', 0x13, 1, 8, 4, 24, 1),
    ('vfrsqrt7.v-masked', 0x13, 1, 8, 4, 24, 0),
    ('vfrec7.v', 0x13, 1, 8, 5, 24, 1),
    ('vfrec7.v-masked', 0x13, 1, 8, 5, 24, 0),
    ('vfclass.v', 0x13, 1, 8, 16, 24, 1),
    ('vfclass.v-masked', 0x13, 1, 8, 16, 24, 0),
    ('vfcvt.xu.f.v', 0x12, 1, 8, 0, 24, 1),
    ('vfcvt.x.f.v', 0x12, 1, 8, 1, 24, 1),
    ('vfcvt.f.xu.v', 0x12, 1, 8, 2, 24, 1),
    ('vfcvt.f.x.v', 0x12, 1, 8, 3, 24, 1),
    ('vfcvt.rtz.xu.f.v', 0x12, 1, 8, 6, 24, 1),
    ('vfcvt.rtz.x.f.v', 0x12, 1, 8, 7, 24, 1),
    ('vfcvt.x.f.v-masked', 0x12, 1, 8, 1, 24, 0),
    ('vfwcvt.xu.f.v', 0x12, 1, 8, 8, 24, 1),
    ('vfwcvt.x.f.v', 0x12, 1, 8, 9, 24, 1),
    ('vfwcvt.f.xu.v', 0x12, 1, 8, 10, 24, 1),
    ('vfwcvt.f.x.v', 0x12, 1, 8, 11, 24, 1),
    ('vfwcvt.rtz.xu.f.v', 0x12, 1, 8, 14, 24, 1),
    ('vfwcvt.rtz.x.f.v', 0x12, 1, 8, 15, 24, 1),
    ('vfncvt.xu.f.w', 0x12, 1, 8, 16, 24, 1),
    ('vfncvt.x.f.w', 0x12, 1, 8, 17, 24, 1),
    ('vfncvt.f.xu.w', 0x12, 1, 8, 18, 24, 1),
    ('vfncvt.f.x.w', 0x12, 1, 8, 19, 24, 1),
    ('vfncvt.rtz.xu.f.w', 0x12, 1, 8, 22, 24, 1),
    ('vfncvt.rtz.x.f.w', 0x12, 1, 8, 23, 24, 1),
    ('vfwcvt.f.x.v-masked', 0x12, 1, 8, 11, 24, 0),
    ('vfncvt.x.f.w-masked', 0x12, 1, 8, 17, 24, 0),
    ('vfwcvt.f.f.v', 0x12, 1, 8, 12, 24, 1),
    ('vfwcvt.f.f.v-masked', 0x12, 1, 8, 12, 24, 0),
    ('vfncvt.f.f.w', 0x12, 1, 8, 20, 24, 1),
    ('vfncvt.f.f.w-masked', 0x12, 1, 8, 20, 24, 0),
    ('vfncvt.rod.f.f.w', 0x12, 1, 8, 21, 24, 1),
    ('vmfeq.vv', 0x18, 1, 8, 16, 24, 1),
    ('vmfeq.vv-masked', 0x18, 1, 8, 16, 24, 0),
    ('vmfeq.vf', 0x18, 5, 8, 5, 24, 1),
    ('vmfne.vv', 0x1c, 1, 8, 16, 24, 1),
    ('vmfne.vf', 0x1c, 5, 8, 5, 24, 1),
    ('vmfle.vv', 0x19, 1, 8, 16, 24, 1),
    ('vmfle.vf', 0x19, 5, 8, 5, 24, 1),
    ('vmflt.vv', 0x1b, 1, 8, 16, 24, 1),
    ('vmflt.vf', 0x1b, 5, 8, 5, 24, 1),
    ('vmfgt.vf', 0x1d, 5, 8, 5, 24, 1),
    ('vmfge.vf', 0x1f, 5, 8, 5, 24, 1),
    ('vfmul.vv', 0x24, 1, 8, 16, 24, 1),
    ('vfmul.vf', 0x24, 5, 8, 5, 24, 1),
    ('vfdiv.vv', 0x20, 1, 8, 16, 24, 1),
    ('vfdiv.vf', 0x20, 5, 8, 5, 24, 1),
    ('vfrdiv.vf', 0x21, 5, 8, 5, 24, 1),
    ('vfrsub.vf', 0x27, 5, 8, 5, 24, 1),
    ('vfmadd.vv', 0x28, 1, 8, 16, 24, 1),
    ('vfmadd.vf', 0x28, 5, 8, 5, 24, 1),
    ('vfnmadd.vv', 0x29, 1, 8, 16, 24, 1),
    ('vfnmadd.vf', 0x29, 5, 8, 5, 24, 1),
    ('vfmsub.vv', 0x2a, 1, 8, 16, 24, 1),
    ('vfmsub.vf', 0x2a, 5, 8, 5, 24, 1),
    ('vfnmsub.vv', 0x2b, 1, 8, 16, 24, 1),
    ('vfnmsub.vf', 0x2b, 5, 8, 5, 24, 1),
    ('vfmacc.vv', 0x2c, 1, 8, 16, 24, 1),
    ('vfmacc.vf', 0x2c, 5, 8, 5, 24, 1),
    ('vfnmacc.vv', 0x2d, 1, 8, 16, 24, 1),
    ('vfnmacc.vf', 0x2d, 5, 8, 5, 24, 1),
    ('vfmsac.vv', 0x2e, 1, 8, 16, 24, 1),
    ('vfmsac.vf', 0x2e, 5, 8, 5, 24, 1),
    ('vfnmsac.vv', 0x2f, 1, 8, 16, 24, 1),
    ('vfnmsac.vf', 0x2f, 5, 8, 5, 24, 1),
    ('vfmacc.vv-masked', 0x2c, 1, 8, 16, 24, 0),
    ('vfwadd.vv', 0x30, 1, 8, 16, 24, 1),
    ('vfwadd.vf', 0x30, 5, 8, 5, 24, 1),
    ('vfwadd.wv', 0x34, 1, 8, 16, 24, 1),
    ('vfwadd.wf', 0x34, 5, 8, 5, 24, 1),
    ('vfwsub.vv', 0x32, 1, 8, 16, 24, 1),
    ('vfwsub.vf', 0x32, 5, 8, 5, 24, 1),
    ('vfwsub.wv', 0x36, 1, 8, 16, 24, 1),
    ('vfwsub.wf', 0x36, 5, 8, 5, 24, 1),
    ('vfwmul.vv', 0x38, 1, 8, 16, 24, 1),
    ('vfwmul.vf', 0x38, 5, 8, 5, 24, 1),
    ('vfwmacc.vv', 0x3c, 1, 8, 16, 24, 1),
    ('vfwmacc.vf', 0x3c, 5, 8, 5, 24, 1),
    ('vfwnmacc.vv', 0x3d, 1, 8, 16, 24, 1),
    ('vfwnmacc.vf', 0x3d, 5, 8, 5, 24, 1),
    ('vfwmsac.vv', 0x3e, 1, 8, 16, 24, 1),
    ('vfwmsac.vf', 0x3e, 5, 8, 5, 24, 1),
    ('vfwnmsac.vv', 0x3f, 1, 8, 16, 24, 1),
    ('vfwnmsac.vf', 0x3f, 5, 8, 5, 24, 1),
    ('vfwmacc.vv-masked', 0x3c, 1, 8, 16, 24, 0),
)


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
    for sew in (1, 2, 3):
        for lmul in (1, 2, 4):
            maximum = (16 >> sew) * lmul
            for avl in (0, 3, maximum):
                for start in (0, 1, maximum):
                    for name, function, form, source2, source1, destination, vm in OPERATIONS:
                        for seed in (3, 79):
                            cases.append(dict(name=name, sew=sew, lmul=lmul, avl=avl,
                                              vtype=0xc0 | (sew << 3) | (lmul.bit_length() - 1),
                                              start=start, seed=seed,
                                              rounding=(seed + sew + lmul + avl) & 3,
                                              scalar=0xffffffff3f800000 if sew != 3 else
                                              0x3ff0000000000000,
                                              instruction=instruction(function, vm, source2,
                                                                      source1, form, destination)))
    for name, function, form, source2, source1, destination, vm in OPERATIONS:
        cases.append(dict(name=f'{name}-invalid-frm', sew=2, lmul=1, avl=3,
                          vtype=0xd0, start=0, seed=3, rounding=5,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(function, vm, source2,
                                                  source1, form, destination)))
    cases.append(dict(name='vfmv.v.f-unboxed', sew=2, lmul=1, avl=3,
                      vtype=0xd0, start=0, seed=3, rounding=0,
                      scalar=0x3f800000,
                      instruction=instruction(0x17, 1, 0, 5, 5, 24)))
    cases.append(dict(name='vfslide1up-overlap-illegal', sew=2, lmul=1,
                      avl=3, vtype=0xd0, start=0, seed=3, rounding=0,
                      scalar=0xffffffff3f800000,
                      instruction=instruction(0x0e, 1, 8, 5, 5, 8)))
    cases.append(dict(name='vfmerge-masked-v0-illegal', sew=2, lmul=1,
                      avl=3, vtype=0xd0, start=0, seed=3, rounding=0,
                      scalar=0xffffffff3f800000,
                      instruction=instruction(0x17, 0, 8, 5, 5, 0)))
    for name, function, vm, source2, source1, expected_trap in (
        ('vfadd-masked-vs2-v0', 0x00, 0, 0, 16, 0),
        ('vfadd-masked-vs1-v0', 0x00, 0, 8, 0, 0),
        ('vfadd-unmasked-vs2-v0', 0x00, 1, 0, 16, 0),
        ('vfredusum-masked-vs2-v0', 0x01, 0, 0, 16, 0),
        ('vfredusum-masked-seed-v0', 0x01, 0, 8, 0, 0),
        ('vfredusum-unmasked-vs2-v0', 0x01, 1, 0, 16, 0),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=3,
                          vtype=0xd0, start=0, seed=3, rounding=0,
                          expected_trap=expected_trap,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(function, vm, source2,
                                                  source1, 1, 24)))
    cases.append(dict(name='vmfeq-mask-overlap-illegal', sew=2, lmul=2,
                      avl=4, vtype=0xd1, start=0, seed=3, rounding=0,
                      scalar=0xffffffff3f800000,
                      instruction=instruction(0x18, 1, 8, 16, 1, 9)))
    cases.append(dict(name='vmfeq-mask-source-overlap', sew=2, lmul=2,
                      avl=4, vtype=0xd1, start=0, seed=3, rounding=0,
                      scalar=0xffffffff3f800000,
                      instruction=instruction(0x18, 1, 8, 16, 1, 8)))
    for name, source1, source2, destination in (
        ('vfwcvt-overlap-high', 12, 9, 8),
        ('vfwcvt-overlap-low-illegal', 12, 8, 8),
        ('vfncvt-overlap-low', 20, 8, 8),
        ('vfncvt-overlap-high-illegal', 20, 8, 9),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=3,
                          vtype=0xd0, start=0, seed=3, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(0x12, 1, source2, source1, 1,
                                                  destination)))
    cases.append(dict(name='vfwcvt-emul-16-illegal', sew=2, lmul=8,
                      avl=3, vtype=0xd3, start=0, seed=3, rounding=0,
                      scalar=0xffffffff3f800000,
                      instruction=instruction(0x12, 1, 8, 12, 1, 16)))
    cases.append(dict(name='vfwadd-emul-16-illegal', sew=2, lmul=8,
                      avl=3, vtype=0xd3, start=0, seed=3, rounding=0,
                      scalar=0xffffffff3f800000,
                      instruction=instruction(0x30, 1, 8, 16, 1, 16)))
    cases.append(dict(name='vfwadd-vf-unboxed', sew=2, lmul=1,
                      avl=3, vtype=0xd0, start=0, seed=3, rounding=0,
                      scalar=0x3f800000,
                      instruction=instruction(0x30, 1, 8, 5, 5, 24)))
    for name, function, source2, destination in (
        ('vfwadd-overlap-high', 0x30, 9, 8),
        ('vfwadd-overlap-low-illegal', 0x30, 8, 8),
        ('vfwadd-wide-source-overlap', 0x34, 8, 8),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=3,
                          vtype=0xd0, start=0, seed=3, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(function, 1, source2, 16, 1,
                                                  destination)))
    for name, source1, lmul, expected_trap in (
        ('vfwadd-wv-source-eew-overlap', 9, 1, 1),
        ('vfwadd-wv-source-eew-partial-overlap', 10, 2, 1),
        ('vfwadd-wv-source-eew-disjoint', 12, 2, 0),
    ):
        cases.append(dict(name=name, sew=2, lmul=lmul, avl=3,
                          vtype=0xd0 | (lmul - 1), start=0, seed=3, rounding=0,
                          expected_trap=expected_trap, scalar=0xffffffff3f800000,
                          instruction=instruction(0x34, 1, 8, source1, 1, 24)))
    for name, function, source1, expected_trap in (
        ('vfwredusum-source-eew-overlap', 0x31, 9, 1),
        ('vfwredosum-source-eew-overlap', 0x33, 9, 1),
        ('vfwredusum-source-eew-disjoint', 0x31, 10, 0),
        ('vfredusum-source-same-eew-overlap', 0x01, 9, 0),
    ):
        cases.append(dict(name=name, sew=2, lmul=2, avl=4,
                          vtype=0xd1, start=0, seed=3, rounding=0,
                          expected_trap=expected_trap, scalar=0xffffffff3f800000,
                          instruction=instruction(function, 1, 8, source1, 1, 24)))
    for name, function, source1, seed in (
        ('vfwcvt-snan', 0x12, 12, 252),
        ('vfwadd-snan', 0x30, 16, 252),
        ('vfwmacc-snan', 0x3c, 16, 252),
        ('vfncvt-half-ulp', 0x12, 20, 251),
        ('vfncvt-rod-half-ulp', 0x12, 21, 251),
        ('vfwadd-wide-half-ulp', 0x34, 16, 251),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=1,
                          vtype=0xd0, start=0, seed=seed, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(function, 1, 8, source1, 1, 24)))
    for name, source1, source2, destination in (
        ('vfwcvt-int-overlap-high', 9, 9, 8),
        ('vfwcvt-int-overlap-low-illegal', 9, 8, 8),
        ('vfncvt-int-overlap-low', 17, 8, 8),
        ('vfncvt-int-overlap-high-illegal', 17, 8, 9),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=3,
                          vtype=0xd0, start=0, seed=3, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(0x12, 1, source2, source1, 1,
                                                  destination)))
    for name, vtype, source1, source2, destination in (
        ('vfwcvt-i16-fractional-lmul', 0xcf, 11, 8, 24),
        ('vfncvt-i16-fractional-lmul', 0xcf, 17, 8, 24),
        ('vfwcvt-i64-fractional-lmul', 0xd7, 9, 8, 24),
        ('vfwcvt-int-emul-16-illegal', 0xd3, 9, 8, 16),
        ('vfncvt-int-emul-16-illegal', 0xd3, 17, 0, 24),
    ):
        cases.append(dict(name=name, sew=(vtype >> 3) & 7, lmul=1,
                          avl=2, vtype=vtype, start=0, seed=3, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(0x12, 1, source2, source1, 1,
                                                  destination)))
    for name, source1, seed in (
        ('vfwcvt-int-snan', 9, 252),
        ('vfncvt-int-half-ulp', 17, 251),
    ):
        cases.append(dict(name=name, sew=2, lmul=1, avl=1,
                          vtype=0xd0, start=0, seed=seed, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(0x12, 1, 8, source1, 1, 24)))
    for name, source1, destination, vm in (
        ('vfred-source-overlap', 16, 8, 1),
        ('vfred-seed-overlap', 16, 16, 1),
        ('vfred-masked-v0-destination', 16, 0, 0),
    ):
        cases.append(dict(name=name, sew=2, lmul=2, avl=4,
                          vtype=0xd1, start=0, seed=3, rounding=0,
                          scalar=0xffffffff3f800000,
                          instruction=instruction(0x01, vm, 8, source1, 1,
                                                  destination)))
    estimate_inputs = [
        ('fp32-zeros-infinities', 2, 4, 250, 0),
        ('fp64-zeros', 3, 2, 249, 0),
        ('fp64-infinities', 3, 2, 248, 0),
        ('fp32-snan', 2, 1, 252, 0),
    ]
    estimate_inputs.extend((f'fp32-subnormals-rm{mode}', 2, 4, 247, mode)
                           for mode in range(4))
    for name, sew, avl, seed, rounding in estimate_inputs:
        for operation, source1 in (('vfrsqrt7.v', 4), ('vfrec7.v', 5)):
            cases.append(dict(name=f'{operation}-{name}', sew=sew, lmul=1, avl=avl,
                              vtype=0xc0 | (sew << 3), start=0, seed=seed,
                              rounding=rounding, scalar=0xffffffff3f800000,
                              instruction=instruction(0x13, 1, 8, source1, 1, 24)))

    fp_address = 0x80003000
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
        state.gpr[4] = case['rounding'] << 5
        reference.run([(0x003 << 20) | (4 << 15) | (1 << 12) | 0x73])
        reference.write(fp_address, case['scalar'].to_bytes(8, 'little'))
        state.gpr[4] = fp_address
        reference.run([(4 << 15) | (3 << 12) | (5 << 7) | 0x07])
        pc = reference.run([case['instruction']])
        case['nemu_trap'] = int(state.pc[0] != pc + 4)
        if ('expected_trap' in case and
                case['nemu_trap'] != case['expected_trap']):
            raise RuntimeError(f'Unexpected NEMU admission for {case["name"]}')
        case['nemu_cause'] = state.mcause[0] if case['nemu_trap'] else 0
        case['nemu_tval'] = state.mtval[0] if case['nemu_trap'] else 0
        case['nemu_fp_value'] = 0
        if case['name'] == 'vfmv.f.s' and not case['nemu_trap']:
            reference.run([(24 << 20) | (4 << 15) | (3 << 12) | 0x27])
            case['nemu_fp_value'] = int.from_bytes(reference.read(fp_address, 8), 'little')
        if vector_api.get_state(0, ctypes.byref(vector)):
            raise RuntimeError('cannot read vector registers')
        case['nemu_state'] = bytes(byte for reg in vector.reg for byte in reg)
        for csr, field in ((0xc20, 'vl'), (0xc21, 'vtype'), (0x008, 'vstart'),
                           (0x009, 'vxsat'), (0x00a, 'vxrm'), (0x00f, 'vcsr')):
            reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
            case[f'nemu_{field}'] = state.gpr[3]
        reference.run([(0x003 << 20) | (2 << 12) | (3 << 7) | 0x73])
        case['nemu_fflags'] = state.gpr[3] & 0x1f

    vectors = args.output / 'vectors.txt'
    vectors.write_text(''.join(
        f'{case["instruction"]:x} {case["vtype"]:x} {case["avl"]:x} '
        f'{case["start"]:x} {case["scalar"]:x} {case["seed"]:x} '
        f'{case["rounding"]:x}\n'
        for case in cases))
    build_root = args.output / 'vpu-build'
    build_dir = build_root / f'top-{args.xlen}-128-64-64-2-opt1'
    build_command = ['make', '-C', str(ROOT / 'verify/vpu'), 'top-build',
                     f'XLEN={args.xlen}', 'VLEN=128', 'ELEN=64', 'BANK_BITS=64',
                     'BANKS=2', f'BUILD_DIR={build_root}', 'JOBS=2']
    with (args.output / 'build.log').open('w') as log:
        subprocess.run(build_command, stdout=log, stderr=subprocess.STDOUT, check=True)
    source_manifest = json.loads((build_dir / 'sources.json').read_text())
    rtl_sources = {path: digest for path, digest in source_manifest['sources'].items()
                   if path.startswith('hdl/')}
    rtl_sha256 = hashlib.sha256(json.dumps(rtl_sources, sort_keys=True).encode()).hexdigest()
    result = subprocess.run([build_dir / 'Vrapt_vpu', '--nemu-diff-fp', vectors],
                            capture_output=True, text=True, check=True)
    (args.output / 'run.log').write_text(result.stdout + result.stderr)
    outputs = [line.split() for line in result.stdout.splitlines()
               if line.startswith('VPU_NEMU_FP_RESULT ')]
    if len(outputs) != len(cases):
        raise RuntimeError(f'RTL produced {len(outputs)} results for {len(cases)} cases')
    failures = []
    for case, output in zip(cases, outputs):
        if len(output) != 16:
            raise RuntimeError(f'Malformed RTL result: {output}')
        rtl_trap = int(output[1])
        rtl_cause, rtl_tval = (int(field, 16) for field in output[2:4])
        rtl_rd = int(output[4])
        rtl_vl, rtl_vtype, rtl_vstart, rtl_vxsat, rtl_vxrm, rtl_vcsr = (
            int(field, 16) for field in output[6:12])
        rtl_fp_write = int(output[12])
        rtl_fp_value = int(output[13], 16)
        rtl_fflags = int(output[14], 16)
        rtl_state = bytes.fromhex(output[15])
        first_mismatch = next((index for index, (nemu_byte, rtl_byte)
                               in enumerate(zip(case['nemu_state'], rtl_state))
                               if nemu_byte != rtl_byte), None)
        fp_extract = case['name'] == 'vfmv.f.s' and not rtl_trap
        if (len(rtl_state) != 512 or case['nemu_trap'] != rtl_trap or
                (rtl_trap and (case['nemu_cause'] != rtl_cause or
                               case['nemu_tval'] != rtl_tval)) or
                (rtl_fp_write != int(fp_extract)) or
                case['nemu_fflags'] != rtl_fflags or
                (fp_extract and (rtl_rd != 24 or
                                 case['nemu_fp_value'] != rtl_fp_value)) or
                any(case[f'nemu_{field}'] != rtl_value for field, rtl_value in (
                    ('vl', rtl_vl), ('vtype', rtl_vtype), ('vstart', rtl_vstart),
                    ('vxsat', rtl_vxsat), ('vxrm', rtl_vxrm), ('vcsr', rtl_vcsr))) or
                first_mismatch is not None):
            failures.append(dict(name=case['name'], instruction=case['instruction'],
                                 vtype=case['vtype'], avl=case['avl'], start=case['start'],
                                 seed=case['seed'], nemu_trap=case['nemu_trap'],
                                 rtl_trap=rtl_trap, first_mismatch=first_mismatch,
                                 nemu_fp_value=case['nemu_fp_value'],
                                 rtl_fp_value=rtl_fp_value,
                                 nemu_fflags=case['nemu_fflags'], rtl_fflags=rtl_fflags,
                                 nemu_vstart=case['nemu_vstart'], rtl_vstart=rtl_vstart))
    report = dict(xlen=args.xlen, cases=len(cases), failures=failures,
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                  rtl_sha256=rtl_sha256,
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_FP_TRANSFER_RTL xlen={args.xlen} cases={len(cases)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
