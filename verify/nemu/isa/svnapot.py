"""Check opt-in Svnapot translation through the existing RTL reference ABI."""
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
    parser.add_argument('--enable', action='store_true')
    args = parser.parse_args()
    if args.enable and args.xlen != 64:
        parser.error('Svnapot requires RV64')
    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    size = ctypes.sizeof(ISAAPI)
    check('bad-version', bool(query(2, size)), False)
    check('bad-size', bool(query(1, size - 1)), False)
    api = query(1, size).contents
    check('initial-capabilities', [api.version, api.size, api.xlen, api.locked, api.supported, api.enabled],
          [1, size, args.xlen, 0, 2047 if args.xlen == 64 else 998, 0])
    check('reject-unknown-extension', api.configure(1 << 63), -1)
    if args.xlen == 32:
        check('reject-svnapot-rv32', api.configure(1), -1)
    if args.enable:
        check('enable-svnapot', api.configure(1), 0)
    check('configuration-before-init', query(1, size).contents.enabled, int(args.enable))
    reference = Reference(args.reference, args.xlen)
    check('configuration-locked', query(1, size).contents.locked, 1)
    check('reject-late-config', api.configure(0), -1)
    check('configuration-unchanged', query(1, size).contents.enabled, int(args.enable))
    library.difftest_state_version.restype = ctypes.c_uint32
    check('legacy-state-version', library.difftest_state_version(), 2)
    if args.xlen == 64:
        translation_cases(reference, args.enable, check)
    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_SVNAPOT cases={len(rows)} failures={len(failures)} enabled={args.enable}')
    return bool(failures)


def translation_cases(reference, enabled, check):
    state = reference.state
    root, middle, leaf = 0x82000000, 0x82001000, 0x82002000
    virtual, physical = 0x41000000, 0x81000000
    napot = 1 << 63
    for address in (root, middle, leaf):
        reference.write(address, bytes(4096))

    def put(address, value):
        reference.write(address, value.to_bytes(8, 'little'))

    def setup(pte, level=0):
        reference.reset()
        put(root + 8, ((middle >> 12) << 10) | 1)
        put(middle + 8 * 8, ((leaf >> 12) << 10) | 1)
        for page in range(16):
            put(leaf + page * 8, pte)
        if level:
            put(root + 8 if level == 2 else middle + 8 * 8, pte)
        state.satp[0] = (8 << 60) | (root >> 12)

    def access(kind, address, privilege=1, sum_enabled=False, mxr=False):
        state.gpr[1] = address
        state.gpr[2] = 0x123456789abcdef
        state.mstatus[0] |= (int(sum_enabled) << 18) | (int(mxr) << 19)
        if kind == 'fetch':
            state.priv[0] = bytes([privilege])
            state.pc[0] = address
            reference.lib.difftest_exec(1)
            return address
        state.mstatus[0] |= (1 << 17) | (privilege << 11)
        return reference.run([0x0000b183 if kind == 'load' else 0x0020b023])

    def result(name, kind, address, pc, allowed):
        actual = [state.pc[0], state.mcause[0], state.mtval[0], state.minstret[0]]
        expected = [pc + 4, 0, 0, 101] if allowed else [
            0x80ff0000, {'fetch': 12, 'load': 13, 'store': 15}[kind], address, 100]
        check(name, actual, expected)

    for page, kind in itertools.product(range(16), ('fetch', 'load', 'store')):
        pte = napot | (((physical >> 12) | 8) << 10) | 0xcf
        setup(pte)
        address, target = virtual + page * 4096, physical + page * 4096
        value = ((page + 1) << 20) | (3 << 7) | 0x13
        put(target, value)
        pc = access(kind, address)
        result(f'page-{page}-{kind}', kind, address, pc, enabled)
        if enabled and kind != 'store':
            check(f'page-{page}-{kind}-data', state.gpr[3], page + 1 if kind == 'fetch' else value)
        check(f'page-{page}-{kind}-memory', int.from_bytes(reference.read(target, 8), 'little'),
              0x123456789abcdef if enabled and kind == 'store' else value)
        check(f'page-{page}-{kind}-pte', int.from_bytes(reference.read(leaf + page * 8, 8), 'little'), pte)

    for low, level, kind in itertools.product(range(16), range(3), ('fetch', 'load', 'store')):
        if low == 8 and level == 0:
            continue
        pte = napot | (((physical >> 12) | low) << 10) | 0xcf
        setup(pte, level)
        pc = access(kind, virtual)
        result(f'reserved-{low}-{level}-{kind}', kind, virtual, pc, False)

    policies = ((0xcf, 1, 0, 0), (0xdf, 0, 0, 0), (0xdf, 1, 0, 0),
                (0xdf, 1, 1, 0), (0xc9, 1, 0, 0), (0xc9, 1, 0, 1),
                (0x4f, 1, 0, 0), (0x8f, 1, 0, 0), (0xc7, 1, 0, 0))
    for flags, privilege, sum_enabled, mxr in policies:
        for kind in ('fetch', 'load', 'store'):
            pte = napot | (((physical >> 12) | 8) << 10) | flags
            setup(pte)
            put(physical, 0x13)
            read, write, execute, user = (bool(flags & bit) for bit in (2, 4, 8, 16))
            permission = user if privilege == 0 else not user or (kind != 'fetch' and sum_enabled)
            access_allowed = {'fetch': execute, 'load': read or (mxr and execute), 'store': write}[kind]
            allowed = bool(enabled and permission and access_allowed and flags & 64
                           and (kind != 'store' or flags & 128))
            pc = access(kind, virtual, privilege, sum_enabled, mxr)
            result(f'permissions-{flags}-{privilege}-{sum_enabled}-{mxr}-{kind}', kind, virtual, pc, allowed)
            check('permission-pte-unchanged', int.from_bytes(reference.read(leaf, 8), 'little'), pte)

    for flags in (1, 0xc5, 0xcf | (1 << 54), 0xcf | (3 << 61)):
        pte = napot | (((physical >> 12) | 8) << 10) | flags
        setup(pte)
        pc = access('load', virtual)
        result(f'invalid-flags-{flags}', 'load', virtual, pc, False)

    for pbmt, pbmte in itertools.product(range(3), (False, True)):
        pte = napot | (((physical >> 12) | 8) << 10) | 0xcf | (pbmt << 61)
        setup(pte)
        state.menvcfg[0] = int(pbmte) << 62
        put(physical, 0x35)
        pc = access('load', virtual)
        result(f'pbmt-{pbmt}-{pbmte}', 'load', virtual, pc, enabled and (pbmt == 0 or pbmte))

    for page in range(16):
        setup((((physical >> 12) + page) << 10) | 0xcf)
        put(physical + page * 4096, 0x55)
        pc = access('load', virtual + page * 4096)
        result(f'ordinary-page-{page}', 'load', virtual + page * 4096, pc, True)
        check(f'ordinary-data-{page}', state.gpr[3], 0x55)


if __name__ == '__main__':
    raise SystemExit(main())
