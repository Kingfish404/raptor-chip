"""Check runtime pointer masking, transformed faults and unchanged implicit accesses."""
import argparse
import ctypes
import hashlib
import itertools
import json
from pathlib import Path

from lib.reference import ISAAPI, Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=64)
    parser.add_argument('--extensions', choices=('none', 'ssnpm', 'smnpm', 'ssnpm,smnpm'), default='none')
    args = parser.parse_args()
    if args.xlen == 32 and args.extensions != 'none':
        parser.error('pointer masking requires RV64')
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    extensions = {'none': 0, 'ssnpm': 8, 'smnpm': 16, 'ssnpm,smnpm': 24}[args.extensions]
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    check('configure', api.configure(extensions), 0)
    if args.xlen == 32:
        for extension in (8, 16, 24):
            check(f'unsupported-{extension}', api.configure(extension), -1)
    reference = Reference(args.reference, args.xlen)
    state = reference.state

    def write_csr(csr, value):
        state.gpr[4] = value & reference.mask
        reference.run([(csr << 20) | (4 << 15) | 0x1073])

    def read_csr(csr):
        reference.run([(csr << 20) | 0x21f3])
        return state.gpr[3]

    for csr, extension in ((0x10a, 8), (0x30a, 16)):
        for pmm in (0, 2, 1, 3, 1, 0):
            reference.reset()
            write_csr(csr, (pmm << 32) | 0xf0)
            expected = pmm if extensions & extension and pmm != 1 else 0
            check(f'csr-{csr:x}-{pmm}', read_csr(csr), (expected << 32) | 0xf0)
            if args.xlen == 64 and csr == 0x30a:
                write_csr(csr, (pmm << 32) | 0xc0000000000000f0)
                check(f'csr-preserve-pbmte-stce-{pmm}', read_csr(csr),
                      (expected << 32) | 0xc0000000000000f0)
    if args.xlen == 64:
        address_cases(reference, extensions, write_csr, check)
    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, extensions=args.extensions,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_POINTER_MASK xlen={args.xlen} extensions={args.extensions} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


def address_cases(reference, extensions, write_csr, check):
    state = reference.state
    root, middle, leaf, physical, virtual = 0x82000000, 0x82001000, 0x82002000, 0x81000000, 0x41000000
    all_bits = (1 << 64) - 1
    initial = 0x1122334455667788

    def put(address, value):
        reference.write(address, value.to_bytes(8, 'little'))

    def case(name, privilege=3, mpp=0, pmm=2, supervisor_pmm=None, translated=True, mxr=False,
             operation='load', tag=0xaa00000000000000, negative=False, offset=0, deny=False,
             bad_ptw=False, bad_leaf=False, readonly=False, delegate=False, warm=False):
        reference.reset()
        write_csr(0x3b0, all_bits)
        write_csr(0x3a0, 15)
        state.gpr[1], state.gpr[2] = physical, 0
        reference.run([0x1820b1af])
        supervisor_pmm = pmm if supervisor_pmm is None else supervisor_pmm
        write_csr(0x10a, (pmm << 32) | 0xf0)
        write_csr(0x30a, (supervisor_pmm << 32) | 0xf0)
        effective = mpp if privilege == 3 and mpp is not None else privilege
        paging = translated and effective != 3
        base = (virtual | (all_bits ^ ((1 << 38) - 1)) if negative else virtual) if paging else physical
        address = (base + offset) & all_bits
        length = 0
        enabled = extensions & (8 if effective == 0 else 16)
        selected = pmm if effective == 0 else supervisor_pmm
        if enabled and effective != 3 and not mxr:
            length = {2: 7, 3: 16}.get(selected, 0)
        operand = address if not tag else (address & 0x01ffffffffffffff) | tag
        if tag and (tag & 0x00ff000000000000):
            operand = (address & 0x0000ffffffffffff) | tag
        transformed = operand
        if length:
            retained = (1 << (64 - length)) - 1
            transformed &= retained
            if paging and transformed & (1 << (63 - length)):
                transformed |= all_bits ^ retained
        for table in (root, middle, leaf):
            reference.write(table, bytes(4096))
        put(root + ((base >> 30) & 511) * 8, ((middle >> 12) << 10) | 1)
        put(middle + ((base >> 21) & 511) * 8, ((leaf >> 12) << 10) | 1)
        data_flags = (0xc3 if readonly else 0xcf) | (16 if effective == 0 else 0)
        put(leaf + ((base >> 12) & 511) * 8, (((physical | ((1 << 52) if bad_leaf else 0)) >> 12) << 10) | data_flags)
        put(root + 16, 0x200000cf | (16 if privilege == 0 else 0))
        reference.write(physical, initial.to_bytes(8, 'little') * 16)
        reference.write(physical + 4080, bytes([0xa5]) * 32)
        initial_data = int.from_bytes(reference.read(physical + offset, 8), 'little')
        put(physical + 256, 0)
        state.gpr[1] = physical + 256
        reference.run([0x0000b007])
        if deny:
            write_csr(0x3b0, physical >> 2)
            write_csr(0x3b1, physical >> 2)
            write_csr(0x3b2, all_bits)
            write_csr(0x3a0, 0x1f100f)
        state.satp[0] = ((8 << 60) | ((root | ((1 << 52) if bad_ptw else 0)) >> 12)) if translated else 0
        state.mstatus[0] |= (int(mxr) << 19) | ((1 << 17) | (mpp << 11) if mpp is not None else 0)
        state.priv[0] = bytes([privilege])
        state.gpr[1], state.gpr[2] = operand, 0x55
        store = operation in ('store', 'fsd', 'amo', 'sc', 'zero', 'clean')
        code = {'load': 0x0000b183, 'store': 0x0020b023, 'fld': 0x0000b187,
                'fsd': 0x0000b027, 'lr': 0x1000b1af, 'sc': 0x1820b1af,
                'amo': 0x0020b1af, 'zero': 0x0040a00f, 'clean': 0x0010a00f}[operation]
        valid = transformed == address
        crossing = offset == 4092 and paging
        denied_write = paging and readonly and store and operation != 'clean'
        fault = not valid or bad_ptw or bad_leaf or deny or crossing or denied_write
        exception = (15 if store else 13) if paging and (not valid or crossing or denied_write) else (7 if store else 5)
        trap_value = (transformed + 4) & all_bits if valid and crossing else transformed
        if delegate:
            state.medeleg[0] = (1 << 13) | (1 << 15) | (1 << 5) | (1 << 7)
        retired = state.minstret[0]
        pc = reference.run([code])
        delegated = delegate and privilege != 3
        cause = state.scause[0] if delegated else state.mcause[0]
        tval = state.stval[0] if delegated else state.mtval[0]
        actual = [state.pc[0], cause, tval, state.minstret[0]]
        expected = [0x80fe0000 if delegated else 0x80ff0000, exception, trap_value, retired] if fault else [pc + 4, 0, 0, retired + 1]
        check(name, actual, expected)
        if not fault and operation in ('load', 'lr', 'amo', 'sc'):
            check(name + '-data', state.gpr[3], 1 if operation == 'sc' else initial_data)
        expected_memory = initial
        if not fault and offset == 0:
            expected_memory = {'store': 0x55, 'fsd': 0, 'amo': initial + 0x55, 'zero': 0}.get(operation, initial)
        check(name + '-memory', int.from_bytes(reference.read(physical, 8), 'little'), expected_memory)
        if crossing:
            check(name + '-no-partial-store', reference.read(physical + 4080, 32).hex(), (bytes([0xa5]) * 32).hex())
        if warm and not fault:
            retired = state.minstret[0]
            pc = reference.run([code])
            check(name + '-warm', [state.pc[0], state.mcause[0], state.minstret[0]], [pc + 4, 0, retired + 1])
        state.priv[0] = b'\x03'
        state.mstatus[0] = 0xa00006000
        write_csr(0x3a0, 15)
        write_csr(0x3b0, all_bits)

    privileges = ((0, None), (1, None), (3, None), (3, 0), (3, 1), (3, 3), (1, 0), (0, 1))
    for (privilege, mpp), pmm, translated, mxr, operation in itertools.product(
            privileges, (0, 2, 3), (False, True), (False, True), ('load', 'store')):
        case(f'access-{privilege}-{mpp}-{pmm}-{translated}-{mxr}-{operation}', privilege, mpp, pmm,
             translated=translated, mxr=mxr, operation=operation, warm=operation == 'load')
    for pmm, operation in itertools.product((2, 3), ('fld', 'fsd', 'amo', 'lr', 'sc', 'zero', 'clean')):
        case(f'explicit-{pmm}-{operation}', pmm=pmm, operation=operation)
    for pmm, tag in ((2, 0xaa00000000000000), (3, 0xabcd000000000000)):
        case(f'negative-{pmm}', pmm=pmm, tag=tag, negative=True)
        case(f'tag-width-{pmm}', pmm=pmm, tag=0xabcd000000000000)
        for mode in (False, True):
            case(f'mxr-untagged-{pmm}-{mode}', pmm=pmm, mxr=True, tag=0, translated=mode)
        case(f'crossing-{pmm}', pmm=pmm, operation='store', offset=4092)
        case(f'unaligned-{pmm}', pmm=pmm, offset=1)
        case(f'pmp-{pmm}', pmm=pmm, deny=True)
        case(f'ptw-{pmm}', pmm=pmm, bad_ptw=True)
        case(f'leaf-pa-{pmm}', pmm=pmm, bad_leaf=True)
        case(f'readonly-{pmm}', pmm=pmm, operation='store', readonly=True)
        case(f'delegated-{pmm}', privilege=0, mpp=None, pmm=pmm, operation='store', readonly=True, delegate=True)
    for privilege, user_pmm, supervisor_pmm in itertools.product((0, 1), (2, 3), (2, 3)):
        case(f'independent-{privilege}-{user_pmm}-{supervisor_pmm}', privilege=privilege, mpp=None,
             pmm=user_pmm, supervisor_pmm=supervisor_pmm, tag=0xabcd000000000000)
    for translated in (False, True):
        reference.reset()
        write_csr(0x10a, 3 << 32)
        write_csr(0x30a, 3 << 32)
        state.satp[0] = (8 << 60) | (root >> 12) if translated else 0
        state.priv[0] = b'\x00'
        state.pc[0] = 0xabcd000081000000
        reference.lib.difftest_exec(1)
        check(f'fetch-never-masked-{translated}', [state.mcause[0], state.mtval[0]],
              [12 if translated else 1, 0xabcd000081000000])


if __name__ == '__main__':
    raise SystemExit(main())
