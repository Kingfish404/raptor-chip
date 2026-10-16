"""Compare NEMU V128 FP estimate results and flags with Spike SoftFloat."""
import argparse
import ctypes
import hashlib
import json
import random
import subprocess
import tempfile
from pathlib import Path

from isa.vector_data import VectorAPI, VectorState, instruction
from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]
SOFTFLOAT = ROOT / 'nemu/tools/spike-diff/repo'


class OracleResult(ctypes.Structure):
    _fields_ = [('bits', ctypes.c_uint64), ('flags', ctypes.c_uint32)]


def inputs(width, generator):
    exponent_bits = 8 if width == 32 else 11
    fraction_bits = 23 if width == 32 else 52
    bias = (1 << (exponent_bits - 1)) - 1
    exponent_max = (1 << exponent_bits) - 1
    values = [0, 1, 2, 3, (1 << fraction_bits) - 1, 1 << fraction_bits,
              bias << fraction_bits, (exponent_max - 1) << fraction_bits,
              exponent_max << fraction_bits, (exponent_max << fraction_bits) | 1,
              (exponent_max << fraction_bits) | (1 << (fraction_bits - 1))]
    values.extend(value | (1 << (width - 1)) for value in list(values))
    for exponent in (0, 1, bias, bias + 1, exponent_max - 2, exponent_max - 1):
        for table_index in range(128):
            for low_bits in (0, (1 << (fraction_bits - 7)) - 1):
                positive = (exponent << fraction_bits) | (table_index << (fraction_bits - 7)) | low_bits
                values.extend((positive, positive | (1 << (width - 1))))
    values.extend(generator.getrandbits(width) for _ in range(1000))
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--cc', default='cc')
    args = parser.parse_args()
    archive = SOFTFLOAT / 'build/libsoftfloat.a'
    if not archive.exists():
        parser.error(f'Spike SoftFloat not built: {archive}')

    with tempfile.TemporaryDirectory(prefix='nemu-vector-estimate-') as temporary:
        library_path = Path(temporary) / 'oracle.so'
        subprocess.run([args.cc, '-shared', '-fPIC', '-I', str(SOFTFLOAT),
                        str(Path(__file__).with_name('spike_estimate_oracle.c')),
                        str(archive), '-o', str(library_path)], check=True)
        oracle = ctypes.CDLL(str(library_path)).estimate_oracle
        oracle.argtypes = [ctypes.c_uint64, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        oracle.restype = OracleResult

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

        def csr_write(csr, value):
            state.gpr[4] = value & reference.mask
            reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

        def csr_read(csr):
            reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
            return state.gpr[3]

        csr_write(0x300, state.mstatus[0] | 0x200)
        generator = random.Random(0x23a23)
        checks = 0
        failures = []
        for element_bytes in (4, 8):
            width = element_bytes * 8
            values = inputs(width, generator)
            lanes = 16 // element_bytes
            state.gpr[1] = lanes
            vtype = 0xc0 | ((element_bytes.bit_length() - 1) << 3)
            reference.run([(vtype << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57])
            for reciprocal_sqrt in (False, True):
                for rounding in range(5):
                    for offset in range(0, len(values), lanes):
                        batch = values[offset:offset + lanes]
                        batch += [0] * (lanes - len(batch))
                        seeded = VectorState()
                        data = b''.join(value.to_bytes(element_bytes, 'little') for value in batch)
                        seeded.reg[8][:] = (ctypes.c_uint8 * 16).from_buffer_copy(data)
                        if vector_api.set_state(0, ctypes.byref(seeded)):
                            raise RuntimeError('cannot set vector state')
                        csr_write(0x003, rounding << 5)
                        reference.run([instruction(0x13, 1, 8, 4 if reciprocal_sqrt else 5, 1, 24)])
                        actual = VectorState()
                        if vector_api.get_state(0, ctypes.byref(actual)):
                            raise RuntimeError('cannot get vector state')
                        actual_flags = csr_read(0x003) & 31
                        expected_flags = 0
                        for lane, operand in enumerate(batch):
                            expected = oracle(operand, element_bytes, reciprocal_sqrt, rounding)
                            actual_bits = int.from_bytes(bytes(actual.reg[24][lane * element_bytes:
                                                                  (lane + 1) * element_bytes]), 'little')
                            expected_flags |= expected.flags
                            if actual_bits != expected.bits:
                                failures.append(dict(width=width, rsqrt=reciprocal_sqrt,
                                                     rounding=rounding, operand=hex(operand),
                                                     actual=hex(actual_bits), expected=hex(expected.bits)))
                            checks += 1
                        if actual_flags != expected_flags:
                            failures.append(dict(width=width, rsqrt=reciprocal_sqrt,
                                                 rounding=rounding, operands=list(map(hex, batch)),
                                                 actual_flags=actual_flags,
                                                 expected_flags=expected_flags))

            for reciprocal_sqrt in (False, True):
                batch = [values[index] for index in (0, 9, 1, 8)[:lanes]]
                seeded = VectorState()
                data = b''.join(value.to_bytes(element_bytes, 'little') for value in batch)
                seeded.reg[8][:] = (ctypes.c_uint8 * 16).from_buffer_copy(data)
                seeded.reg[24][:] = (ctypes.c_uint8 * 16).from_buffer_copy(bytes([0xa5] * 16))
                seeded.reg[0][0] = 0x0a
                if vector_api.set_state(0, ctypes.byref(seeded)):
                    raise RuntimeError('cannot set masked vector state')
                csr_write(0x003, 0)
                csr_write(0x008, 1)
                reference.run([instruction(0x13, 0, 8, 4 if reciprocal_sqrt else 5, 1, 24)])
                actual = VectorState()
                if vector_api.get_state(0, ctypes.byref(actual)):
                    raise RuntimeError('cannot get masked vector state')
                expected_flags = 0
                for lane, operand in enumerate(batch):
                    active = lane >= 1 and (0x0a >> lane) & 1
                    expected_bits = int.from_bytes(bytes([0xa5] * element_bytes), 'little')
                    if active:
                        expected = oracle(operand, element_bytes, reciprocal_sqrt, 0)
                        expected_bits = expected.bits
                        expected_flags |= expected.flags
                    actual_bits = int.from_bytes(bytes(actual.reg[24][lane * element_bytes:
                                                              (lane + 1) * element_bytes]), 'little')
                    if actual_bits != expected_bits:
                        failures.append(dict(width=width, rsqrt=reciprocal_sqrt,
                                             masked=True, lane=lane, operand=hex(operand),
                                             actual=hex(actual_bits), expected=hex(expected_bits)))
                    checks += 1
                if expected_flags != 0x10:
                    raise RuntimeError('masked estimate oracle did not raise invalid for signaling NaN')
                actual_flags = csr_read(0x003) & 31
                actual_start = csr_read(0x008)
                if actual_flags != expected_flags or actual_start != 0:
                    failures.append(dict(width=width, rsqrt=reciprocal_sqrt, masked=True,
                                         actual_flags=actual_flags, expected_flags=expected_flags,
                                         actual_start=actual_start, expected_start=0))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, checks=checks,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        oracle_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        failures=failures), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_ESTIMATE_SPIKE xlen={args.xlen} checks={checks} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
