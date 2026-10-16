"""Check the single-hart runtime profile selection and reference ABI."""

import argparse
import ctypes
import json
from pathlib import Path

from lib.reference import ISAAPI, Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(64,), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    set_stip = library.difftest_set_stip
    set_stip.argtypes = [ctypes.c_uint8]
    checks = []

    def check(name, actual, expected):
        checks.append(dict(name=name, actual=actual, expected=expected,
                           passed=actual == expected))

    api = query(1, ctypes.sizeof(ISAAPI)).contents
    check('initial-mode', api.enabled, 0)
    check('implemented-bundle', api.supported & 0x7ff, 0x7ff)
    check('enable-profile', api.configure(api.supported), 0)
    check('profile-mask', query(1, ctypes.sizeof(ISAAPI)).contents.enabled, api.supported)
    check('reject-unsupported-mask', api.configure(api.supported | (1 << 63)), -1)
    check('preserve-valid-mask', query(1, ctypes.sizeof(ISAAPI)).contents.enabled,
          api.supported)
    check('disable-profile', api.configure(0), 0)
    check('disabled-mask', query(1, ctypes.sizeof(ISAAPI)).contents.enabled, 0)
    check('reenable-profile', api.configure(api.supported), 0)

    reference = Reference(args.reference, args.xlen)
    locked = query(1, ctypes.sizeof(ISAAPI)).contents
    check('locked', locked.locked, 1)
    check('locked-mask', locked.enabled, api.supported)
    check('reject-after-init', api.configure(0), -1)
    check('misa-v', bool(reference.state.misa[0] & (1 << 21)), True)
    check('misa-h', bool(reference.state.misa[0] & (1 << 7)), True)
    check('misa-b', bool(reference.state.misa[0] & (1 << 1)), True)

    reference.reset()
    state = reference.state
    state.mstatus[0] |= 0x200
    state.gpr[1] = 4
    vector_set = (0xc0 << 20) | (1 << 15) | (7 << 12) | (3 << 7) | 0x57
    pc = reference.run([vector_set])
    check('vector-control', [state.gpr[3], state.pc[0], state.mcause[0]],
          [4, pc + 4, 0])
    state.gpr[1] = 123
    state.gpr[2] = 0
    zero_if_equal = (7 << 25) | (2 << 20) | (1 << 15) | (5 << 12) | (3 << 7) | 0x33
    pc = reference.run([zero_if_equal])
    check('zicond', [state.gpr[3], state.pc[0], state.mcause[0]], [0, pc + 4, 0])

    stimecmp_read = (0x14d << 20) | (2 << 12) | (3 << 7) | 0x73
    stimecmp_write = (0x14d << 20) | (1 << 15) | (1 << 12) | 0x73
    reference.reset()
    state.priv[0] = b'\x01'
    pc = reference.run([stimecmp_read])
    check('sstc-disabled-s-trap', [state.mcause[0], state.mepc[0], state.pc[0]],
          [2, pc, state.mtvec[0]])

    reference.reset()
    state.gpr[1] = 1 << 63
    reference.run([(0x30a << 20) | (1 << 15) | (1 << 12) | 0x73])
    state.gpr[1] = 2
    reference.run([(0x306 << 20) | (1 << 15) | (1 << 12) | 0x73])
    state.gpr[1] = 0x1234
    reference.run([stimecmp_write])
    state.priv[0] = b'\x01'
    pc = reference.run([stimecmp_read])
    check('sstc-enabled-s-read', [state.gpr[3], state.pc[0]], [0x1234, pc + 4])
    state.gpr[1] = 0x5678
    reference.run([stimecmp_write])
    pc = reference.run([stimecmp_read])
    check('sstc-enabled-s-write', [state.gpr[3], state.pc[0]], [0x5678, pc + 4])
    state.mideleg[0] = 0x20
    set_stip(1)
    state.priv[0] = b'\x03'
    reference.run([(0x344 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('sstc-hardware-mip', state.gpr[3] & 0x20, 0x20)
    state.priv[0] = b'\x01'
    reference.run([(0x144 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('sstc-hardware-sip', state.gpr[3] & 0x20, 0x20)
    set_stip(0)
    reference.run([(0x144 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('sstc-hardware-clear', state.gpr[3] & 0x20, 0)
    state.priv[0] = b'\x03'
    state.gpr[1] = 0
    reference.run([(0x306 << 20) | (1 << 15) | (1 << 12) | 0x73])
    state.priv[0] = b'\x01'
    pc = reference.run([stimecmp_read])
    check('sstc-counteren-s-trap', [state.mcause[0], state.mepc[0], state.pc[0]],
          [2, pc, state.mtvec[0]])

    reference.reset()
    set_stip(1)
    reference.run([(0x344 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('sstc-disabled-hardware-ignored', state.gpr[3] & 0x20, 0)
    state.gpr[1] = 0x20
    reference.run([(0x344 << 20) | (1 << 15) | (1 << 12) | 0x73])
    set_stip(0)
    reference.run([(0x344 << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('sstc-disabled-software-stip', state.gpr[3] & 0x20, 0x20)

    reference.reset()
    pc = reference.run([(0x15d << 20) | (2 << 12) | (3 << 7) | 0x73])
    check('sstc-rv64-high-half-illegal', [state.mcause[0], state.mepc[0]], [2, pc])

    reference.reset()
    address = 0x81000000
    reference.write(address, bytes((0x11, 0x22, 0x33, 0x44)))
    state.gpr[1] = 2 << 32
    reference.run([(0x10a << 20) | (1 << 15) | (1 << 12) | 0x73])
    state.mstatus[0] |= 0x200
    state.gpr[1] = 4
    reference.run([vector_set])
    state.gpr[1] = address | 0xaa00000000000000
    state.priv[0] = b'\x00'
    vector_load = (1 << 25) | (1 << 15) | (24 << 7) | 0x07
    pc = reference.run([vector_load])
    check('supm-vector-load', [state.pc[0], state.mcause[0]], [pc + 4, 0])
    vector_extract = (0x10 << 26) | (1 << 25) | (24 << 20) | (2 << 12) | (3 << 7) | 0x57
    pc = reference.run([vector_extract])
    check('supm-vector-data', [state.gpr[3], state.pc[0]], [0x11, pc + 4])

    hstatus_read = (0x600 << 20) | (2 << 12) | (3 << 7) | 0x73
    hstatus_write = (0x600 << 20) | (1 << 15) | (1 << 12) | 0x73
    for privilege in (3, 1):
        reference.reset()
        state.priv[0] = bytes([privilege])
        preserved = (1 << 8) | (1 << 20)
        expected = (2 << 32) | preserved
        state.gpr[1] = preserved | (1 << 6)
        reference.run([hstatus_write, hstatus_read])
        check(f'hstatus-gva-write-{privilege}', state.gpr[3], expected | (1 << 6))
        state.gpr[1] = 1 << 6
        reference.run([(0x600 << 20) | (1 << 15) | (3 << 12) | (3 << 7) | 0x73])
        check(f'hstatus-gva-clear-old-{privilege}', state.gpr[3], expected | (1 << 6))
        reference.run([hstatus_read])
        check(f'hstatus-gva-cleared-{privilege}', state.gpr[3], expected)
        reference.run([(0x600 << 20) | (1 << 15) | (2 << 12) | (3 << 7) | 0x73])
        check(f'hstatus-gva-set-old-{privilege}', state.gpr[3], expected)
        reference.run([hstatus_read])
        check(f'hstatus-gva-set-{privilege}', state.gpr[3], expected | (1 << 6))
        state.gpr[1] = preserved
        reference.run([hstatus_write, hstatus_read])
        check(f'hstatus-gva-restore-{privilege}', state.gpr[3], expected)

    def csr_exchange(csr, value):
        state.priv[0] = b'\x03'
        state.gpr[1] = value
        reference.run([(csr << 20) | (1 << 15) | (1 << 12) | 0x73,
                       (csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return int(state.gpr[3])

    reference.reset()
    addresses = [0, 4, 0x80000004, 0x3ffffffffc, 0xffffffc000000000,
                 0xfffffffffffffffc]
    for csr, name in ((0x105, 'sstvecd'), (0x205, 'shvstvecd')):
        for address in addresses:
            check(f'{name}-{address:x}', csr_exchange(csr, address), address)
    for value in (0, 1, 2, 3):
        check(f'ssu64xl-{value}', (csr_exchange(0x100, value << 32) >> 32) & 3, 2)
        check(f'vs-uxl-{value}', (csr_exchange(0x200, value << 32) >> 32) & 3, 2)
    for csr, name in ((0x180, 'satp'), (0x280, 'vsatp'), (0x680, 'hgatp')):
        for mode in (8, 0):
            check(f'{name}-mandatory-mode-{mode}', csr_exchange(csr, mode << 60) >> 60, mode)
    for csr, name in ((0x106, 'scounteren'), (0x606, 'hcounteren')):
        check(f'{name}-implemented-counters', csr_exchange(csr, 0xffffffff), 7)
    for counter in range(3, 32):
        check(f'optional-hpm{counter}-readonly-zero',
              csr_exchange(0xb00 + counter, reference.mask), 0)

    block = 0x81001040
    for width in (4, 8):
        function = 2 if width == 4 else 3
        load_reserved = (2 << 27) | (1 << 15) | (function << 12) | (4 << 7) | 0x2f
        store_conditional = (3 << 27) | (3 << 20) | (2 << 15) | (function << 12) | (4 << 7) | 0x2f
        for offset in range(0, 64, width):
            for target in (block + offset, block - 64, block + 64):
                reference.reset()
                initial = bytes([0xa5]) * 192
                reference.write(block - 64, initial)
                state.gpr[1] = block + offset
                state.gpr[2] = target
                state.gpr[3] = 0x1122334455667788
                pc = reference.run([load_reserved, store_conditional])
                succeeds = target == block + offset
                expected = bytearray(initial)
                if succeeds:
                    start = target - (block - 64)
                    expected[start:start + width] = state.gpr[3].to_bytes(8, 'little')[:width]
                check(f'za64rs-width{width}-offset{offset}-target{target:x}',
                      [int(state.gpr[4]), int(state.pc[0]), reference.read(block - 64, 192).hex()],
                      [0 if succeeds else 1, pc + 8, expected.hex()])

    failures = [entry for entry in checks if not entry['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, cases=checks,
                                           failures=len(failures)), indent=2) + '\n')
    for failure in failures:
        print('FAIL', failure)
    print(f'NEMU_RVA23_PROFILE xlen={args.xlen} cases={len(checks)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
