"""Compare NEMU's V128 configuration instructions with the RTL VTYPE module."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import re
import subprocess

from lib.reference import ISAAPI, Reference


ROOT = Path(__file__).resolve().parents[3]
RESULT = re.compile(r'^VTYPE_RESULT ([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+) ([01])$')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    if api.configure(1 << 6):
        raise RuntimeError('reference does not support V128 preview')
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state
    state.gpr[4] = 0x200
    reference.run([(0x300 << 20) | (4 << 15) | (2 << 12) | 0x73])

    def read_csr(csr):
        reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3]

    cases = []

    def check(name, instruction, requested, avl, avl_max, keep_vl):
        old_vtype = read_csr(0xc21)
        old_vl = read_csr(0xc20)
        reference.run([instruction])
        cases.append(dict(name=name, requested=requested, avl=avl, avl_max=avl_max,
                          keep_vl=keep_vl, old_vtype=old_vtype, old_vl=old_vl,
                          actual_vtype=read_csr(0xc21), actual_vl=read_csr(0xc20)))

    for vtype in range(256):
        avl = (vtype * 23) % 137
        state.gpr[1] = avl
        instruction = (vtype << 20) | (1 << 15) | (7 << 12) | (5 << 7) | 0x57
        check(f'vsetvli-{vtype}', instruction, vtype, avl, False, False)

        state.gpr[2] = vtype ^ 0xc0
        instruction = (0x40 << 25) | (2 << 20) | (7 << 12) | 0x57
        check(f'vsetvl-keep-{vtype}', instruction, state.gpr[2], 0, False, True)

        immediate_avl = vtype & 31
        instruction = 0xc0000000 | (vtype << 20) | (immediate_avl << 15) | (7 << 12) | (5 << 7) | 0x57
        check(f'vsetivli-{vtype}', instruction, vtype, immediate_avl, False, False)

        instruction = (vtype << 20) | (7 << 12) | (5 << 7) | 0x57
        check(f'vsetvli-max-{vtype}', instruction, vtype, 0, True, False)

        instruction = (vtype << 20) | (7 << 12) | 0x57
        check(f'vsetvli-keep-{vtype}', instruction, vtype, 0, False, True)

    for reserved_bit in range(8, args.xlen):
        requested = 1 << reserved_bit
        state.gpr[2] = requested
        state.gpr[1] = 3
        instruction = (0x40 << 25) | (2 << 20) | (1 << 15) | (7 << 12) | (5 << 7) | 0x57
        check(f'vsetvl-reserved-{reserved_bit}', instruction, requested, 3, False, False)
        if reserved_bit <= 10:
            instruction = (requested << 20) | (1 << 15) | (7 << 12) | (5 << 7) | 0x57
            check(f'vsetvli-reserved-{reserved_bit}', instruction, requested, 3, False, False)
        if reserved_bit <= 9:
            instruction = 0xc0000000 | (requested << 20) | (3 << 15) | (7 << 12) | (5 << 7) | 0x57
            check(f'vsetivli-reserved-{reserved_bit}', instruction, requested, 3, False, False)

    input_path = args.output / 'vectors.txt'
    input_path.write_text(''.join(
        f'{case["requested"]:x} {case["avl"]:x} {case["old_vtype"]:x} '
        f'{case["old_vl"]:x} {int(case["avl_max"])} {int(case["keep_vl"])}\n'
        for case in cases))
    build = args.output / 'obj_dir'
    command = ['verilator', '--binary', '--timing', '-Wall', '--top-module', 'tb_vector_rtl',
               '--Mdir', str(build), f'-GXLEN={args.xlen}',
               str(ROOT / 'rtl/backend/vpu/rapt_vpu_vtype.sv'),
               str(ROOT / 'verification/nemu/tb_vector_rtl.sv')]
    with (args.output / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([build / 'Vtb_vector_rtl', '+vectors=' + str(input_path)],
                            capture_output=True, text=True, check=True)
    (args.output / 'run.log').write_text(result.stdout + result.stderr)
    outputs = [match.groups() for line in result.stdout.splitlines() if (match := RESULT.fullmatch(line))]
    if len(outputs) != len(cases):
        raise RuntimeError(f'RTL produced {len(outputs)} results for {len(cases)} inputs')
    failures = []
    for case, (rtl_vtype, rtl_vl, rtl_vlmax, rtl_vill) in zip(cases, outputs):
        expected_vtype = int(rtl_vtype, 16)
        expected_vl = int(rtl_vl, 16)
        actual_vill = case['actual_vtype'] >> (args.xlen - 1)
        if (case['actual_vtype'], case['actual_vl'], actual_vill) != (
                expected_vtype, expected_vl, int(rtl_vill)):
            failures.append(dict(case=case, rtl_vtype=expected_vtype, rtl_vl=expected_vl,
                                 rtl_vlmax=int(rtl_vlmax, 16), rtl_vill=int(rtl_vill)))
    report = dict(xlen=args.xlen, cases=len(cases), failures=failures,
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                  rtl_sha256=hashlib.sha256((ROOT / 'rtl/backend/vpu/rapt_vpu_vtype.sv').read_bytes()).hexdigest(),
                  testbench_sha256=hashlib.sha256(
                      (ROOT / 'verification/nemu/tb_vector_rtl.sv').read_bytes()).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_VECTOR_RTL xlen={args.xlen} cases={len(cases)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
