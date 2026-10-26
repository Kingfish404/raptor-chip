"""Compare single-hart OP-V execution against the independent Spike interpreter."""

import argparse
import ctypes
import json
import random
import subprocess
import tempfile
from pathlib import Path

from isa.vector_data import VectorAPI, VectorState, instruction as encode_instruction
from isa.vector_opcodes import arithmetic_opcodes, EXPECTED_OPCODES
from isa.zvbb import OPERATIONS as ZVBB_OPERATIONS
from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]
SPIKE = ROOT / 'nemu/tools/spike-diff/repo'


class OracleResult(ctypes.Structure):
    _fields_ = [('registers', ctypes.c_uint8 * 512)] + [
        (name, ctypes.c_uint64) for name in
        ('scalar', 'floating', 'flags', 'saturated', 'vl', 'vstart', 'trapped', 'cause')
    ] + [('memory', ctypes.c_uint8 * 4096)]


def build_oracle(directory, compiler):
    output = directory / 'oracle.so'
    includes = ('', 'riscv', 'fesvr', 'softfloat', 'build')
    libraries = ('riscv', 'disasm', 'softfloat', 'fesvr', 'fdt')
    subprocess.run([compiler, '-std=c++20', '-O2', '-shared', '-fPIC',
                    *[f'-iquote{SPIKE / path}' for path in includes],
                    str(Path(__file__).with_name('spike_vector_oracle.cc')),
                    '-Wl,--start-group',
                    *[str(SPIKE / f'build/lib{name}.a') for name in libraries],
                    '-Wl,--end-group', '-o', str(output)], check=True)
    library = ctypes.CDLL(str(output))
    library.vector_oracle_init.argtypes = [ctypes.c_uint]
    library.vector_oracle_init.restype = None
    library.vector_oracle.argtypes = [ctypes.c_uint32] * 5 + [ctypes.c_uint64] * 2 + [
        ctypes.POINTER(VectorState), ctypes.POINTER(OracleResult)]
    library.vector_oracle.restype = None
    library.vector_memory_oracle.argtypes = [ctypes.c_uint32] * 3 + [ctypes.c_uint64] * 2 + [
        ctypes.POINTER(VectorState), ctypes.c_void_p, ctypes.POINTER(OracleResult)]
    library.vector_memory_oracle.restype = None
    return library


def comparable_registers(name, data, width, vl):
    data = bytearray(data)
    mask_result = name.startswith(('vmseq.', 'vmsne.', 'vmslt', 'vmsle', 'vmsgt',
                                  'vmadc.', 'vmsbc.', 'vmf', 'vmsbf.', 'vmsif.',
                                  'vmsof.', 'vmand', 'vmnand', 'vmor', 'vmnor',
                                  'vmxor', 'vmxnor'))
    if mask_result:
        destination = int.from_bytes(data[384:400], 'little') & ((1 << vl) - 1)
        data[384:400] = destination.to_bytes(16, 'little')
    elif 'red' in name:
        result_bytes = width // 8 * (2 if name.startswith(('vwred', 'vfwred')) else 1)
        data[384 + result_bytes:400] = bytes(16 - result_bytes)
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--cxx', default='g++')
    parser.add_argument('--seed', type=lambda value: int(value, 0), default=0x23a23)
    parser.add_argument('--samples', type=int, default=4)
    parser.add_argument('--profile', choices=('none', 'rva23'), default='none')
    args = parser.parse_args()
    if args.samples < 1:
        parser.error('--samples must be positive')
    if args.profile == 'rva23' and args.xlen != 64:
        parser.error('RVA23 requires RV64')
    if not (SPIKE / 'build/libriscv.a').exists():
        parser.error('build the bundled Spike before running this check')

    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    extensions = api.supported if args.profile == 'rva23' else (1 << 6) | (1 << 7) | (1 << 8)
    if args.profile == 'rva23' and api.supported & 0x7ff != 0x7ff:
        raise RuntimeError('reference lacks the RVA23 bundle')
    if api.configure(extensions):
        raise RuntimeError('reference lacks V128/Zvbb/Zvfhmin preview')
    vector_query = library.nemu_difftest_vector_query
    vector_query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    vector_query.restype = ctypes.POINTER(VectorAPI)
    vector_api = vector_query(1, ctypes.sizeof(VectorAPI)).contents
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state

    def csr_write(csr, value):
        state.gpr[4] = value
        reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def csr_read(csr):
        reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return int(state.gpr[3])

    csr_write(0x300, state.mstatus[0] | 0x600)
    table = ROOT / 'verification/vpu/vendor/riscv-opcodes/rv_v'
    opcodes = list(arithmetic_opcodes(table))
    maskable = {tokens[0] for line in table.read_text(encoding='utf-8').splitlines()
                if (tokens := line.split('#', 1)[0].split()) and 'vm' in tokens}
    if len(opcodes) != EXPECTED_OPCODES:
        raise RuntimeError('unexpected opcode table size')
    for name, function, form, source in ZVBB_OPERATIONS:
        opcodes.append((name, encode_instruction(function, 1, 8,
                                                 16 if form == 4 else source, form, 24)))
        maskable.add(name)
    generator = random.Random(args.seed)
    counts = {name: 0 for name, _ in opcodes}
    checks = 0
    illegal = 0
    failures = []
    with tempfile.TemporaryDirectory(prefix='nemu-vector-spike-') as temporary:
        oracle = build_oracle(Path(temporary), args.cxx)
        oracle.vector_oracle_init(args.xlen)
        for name, instruction in opcodes:
            for width in (8, 16, 32, 64):
                for lmul in (0, 1, 2, 3, 5, 6, 7):
                    exponent = lmul if lmul < 4 else lmul - 8
                    if width > (64 << exponent if exponent >= 0 else 64 >> -exponent):
                        continue
                    maximum = (128 // width << exponent if exponent >= 0
                               else 128 // width >> -exponent)
                    vtype = ((width.bit_length() - 4) << 3) | lmul
                    for sample in range(args.samples):
                        vl = maximum if sample == 0 else max(1, maximum - 1)
                        rounding = (sample + width + lmul) % 4
                        frm = (sample + lmul) % 5
                        raw = (bytes(512) if sample == 2 else bytes([255]) * 512
                               if sample == 3 else generator.randbytes(512))
                        seeded = VectorState.from_buffer_copy(raw)
                        scalar = (generator.getrandbits(args.xlen) if sample == 0 else
                                  1 if sample == 1 else 0 if sample == 2 else reference.mask)
                        floating = generator.getrandbits(64)
                        if width == 32:
                            floating |= 0xffffffff00000000
                        expected = OracleResult()
                        opcode = instruction & ~(1 << 25) if sample % 2 and name in maskable else instruction
                        oracle.vector_oracle(opcode, vtype, vl, rounding, frm,
                                             scalar, floating, ctypes.byref(seeded),
                                             ctypes.byref(expected))
                        state.mstatus[0] |= 0x6600
                        state.gpr[1] = vl
                        reference.run([(vtype << 20) | (1 << 15) | (7 << 12) |
                                       (3 << 7) | 0x57])
                        csr_write(0x009, 0)
                        csr_write(0x00a, rounding)
                        csr_write(0x003, frm << 5)
                        if vector_api.set_state(0, ctypes.byref(seeded)):
                            raise RuntimeError('cannot set vector state')
                        state.gpr[16] = scalar
                        state.gpr[24] = 0x1234
                        state.gpr[5] = 0x81000000
                        reference.write(0x81000000, floating.to_bytes(8, 'little') +
                                        (0x1234).to_bytes(8, 'little'))
                        reference.run([(5 << 15) | (3 << 12) | (16 << 7) | 7,
                                       (8 << 20) | (5 << 15) | (3 << 12) | (24 << 7) | 7])
                        before_cycles = int(state.mcycle[0])
                        pc = reference.run([opcode])
                        model_cycles = (int(state.mcycle[0]) - before_cycles) & reference.mask
                        trapped = state.pc[0] != pc + 4
                        errors = {}
                        if trapped != bool(expected.trapped):
                            errors['trapped'] = [trapped, bool(expected.trapped)]
                        elif trapped:
                            illegal += 1
                            actual = VectorState()
                            if vector_api.get_state(0, ctypes.byref(actual)):
                                raise RuntimeError('cannot get vector state')
                            if (state.mcause[0] != 2 or expected.cause != 2 or
                                    state.mtval[0] != opcode or bytes(actual) != raw):
                                errors['illegal_trap'] = dict(actual_cause=int(state.mcause[0]),
                                                             expected_cause=int(expected.cause),
                                                             tval=int(state.mtval[0]))
                        else:
                            counts[name] += 1
                            if model_cycles != 1:
                                errors['model_cycles'] = [model_cycles, 1]
                            actual = VectorState()
                            if vector_api.get_state(0, ctypes.byref(actual)):
                                raise RuntimeError('cannot get vector state')
                            actual_bytes = comparable_registers(name, bytes(actual), width, vl)
                            expected_bytes = comparable_registers(name, bytes(expected.registers), width, vl)
                            if actual_bytes != expected_bytes:
                                errors['registers'] = [actual_bytes.hex(), expected_bytes.hex()]
                            actual_scalar = int(state.gpr[24])
                            reference.run([(24 << 20) | (5 << 15) | (3 << 12) | 0x27])
                            observed = dict(scalar=actual_scalar,
                                            floating=int.from_bytes(reference.read(0x81000000, 8), 'little'),
                                            flags=csr_read(0x001), saturated=csr_read(0x009),
                                            vl=csr_read(0xc20), vstart=csr_read(0x008))
                            for field, value in observed.items():
                                wanted = getattr(expected, field)
                                if field == 'scalar':
                                    wanted &= reference.mask
                                if value != wanted:
                                    errors[field] = [value, wanted]
                        checks += 1
                        if errors:
                            failures.append(dict(name=name, instruction=f'{opcode:08x}',
                                                 width=width, lmul=lmul, vl=vl, sample=sample,
                                                 errors=errors))
    missing = [name for name, count in counts.items() if not count]
    revision = subprocess.check_output(['git', '-C', str(SPIKE), 'rev-parse', 'HEAD'], text=True).strip()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, seed=args.seed, samples=args.samples,
                                          profile=args.profile, model_cycles_per_instruction=1,
                                          spike_revision=revision, checks=checks, illegal=illegal,
                                          coverage=counts, missing=missing, failures=failures),
                                     indent=2) + '\n', encoding='utf-8')
    print(f'RV{args.xlen} Spike OP-V: {checks} cases, {len(failures)} mismatches, '
          f'{len(counts) - len(missing)}/{len(counts)} opcodes executed')
    for failure in failures[:12]:
        print('FAIL', failure['name'], failure['width'], failure['lmul'], list(failure['errors']))
    return bool(failures or missing)


if __name__ == '__main__':
    raise SystemExit(main())
