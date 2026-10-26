"""Check opt-in state-enable CSRs and supervisor access gates."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path

from lib.reference import ISAAPI, Reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--enable', action='store_true')
    parser.add_argument('--hypervisor', action='store_true')
    args = parser.parse_args()
    if args.hypervisor and (not args.enable or args.xlen != 64):
        parser.error('hypervisor state-enable checks require --enable and RV64')

    library = ctypes.CDLL(str(args.reference.resolve()))
    query = library.nemu_difftest_isa_query
    query.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    query.restype = ctypes.POINTER(ISAAPI)
    api = query(1, ctypes.sizeof(ISAAPI)).contents
    rows = []

    def check(name, actual, expected):
        rows.append(dict(name=name, actual=actual, expected=expected, passed=actual == expected))

    check('supported', bool(api.supported & (1 << 9)), True)
    check('configure', api.configure(((1 << 9) if args.enable else 0) |
                                      ((1 << 10) if args.hypervisor else 0)), 0)
    reference = Reference(args.reference, args.xlen)
    reference.reset()
    state = reference.state

    def read(csr, privilege=3):
        state.priv[0] = bytes([privilege])
        pc = reference.run([(csr << 20) | (2 << 12) | (3 << 7) | 0x73])
        return state.gpr[3], pc

    def write(csr, value, privilege=3):
        state.priv[0] = bytes([privilege])
        state.gpr[4] = value & reference.mask
        return reference.run([(csr << 20) | (4 << 15) | (1 << 12) | 0x73])

    def illegal(name, csr, privilege=3):
        _, pc = read(csr, privilege)
        check(name, [state.mcause[0], state.mepc[0]], [2, pc])

    for index in range(4):
        machine = 0x30c + index
        supervisor = 0x10c + index
        machine_high = 0x31c + index
        if not args.enable:
            illegal(f'mstateen{index}-disabled', machine)
            illegal(f'sstateen{index}-disabled', supervisor)
            if args.xlen == 32:
                illegal(f'mstateen{index}h-disabled', machine_high)
            continue

        check(f'mstateen{index}-reset', read(machine)[0], 0)
        check(f'sstateen{index}-reset', read(supervisor)[0], 0)
        illegal(f'sstateen{index}-supervisor-denied', supervisor, 1)
        illegal(f'mstateen{index}-supervisor-denied', machine, 1)
        write(machine, reference.mask)
        if args.xlen == 64:
            mask = (3 if index == 0 else 2) << 62
            check(f'mstateen{index}-warl', read(machine)[0], mask)
        else:
            check(f'mstateen{index}-low-zero', read(machine)[0], 0)
            write(machine_high, reference.mask)
            mask = (3 if index == 0 else 2) << 30
            check(f'mstateen{index}h-warl', read(machine_high)[0], mask)
        check(f'sstateen{index}-supervisor-granted', read(supervisor, 1)[0], 0)
        write(supervisor, reference.mask, 1)
        check(f'sstateen{index}-warl-zero', read(supervisor, 1)[0], 0)
        illegal(f'sstateen{index}-user-denied', supervisor, 0)
        if args.xlen == 64:
            write(machine, 0)
        else:
            write(machine_high, 0)
        illegal(f'sstateen{index}-supervisor-revoked', supervisor, 1)

    if args.xlen == 32:
        illegal('sstateen-high-absent', 0x11c)
    else:
        illegal('mstateen-high-absent', 0x31c)
        if not args.hypervisor:
            illegal('hstateen0-absent', 0x60c)

    if args.hypervisor:
        for index in range(4):
            machine = 0x30c + index
            hypervisor = 0x60c + index
            mask = (3 if index == 0 else 2) << 62
            check(f'hstateen{index}-reset', read(hypervisor)[0], 0)
            illegal(f'hstateen{index}-supervisor-denied', hypervisor, 1)
            write(machine, mask)
            check(f'hstateen{index}-supervisor-granted', read(hypervisor, 1)[0], 0)
            write(hypervisor, reference.mask, 1)
            check(f'hstateen{index}-warl', read(hypervisor, 1)[0], mask)
            illegal(f'hstateen{index}-user-denied', hypervisor, 0)
            write(machine, 0)
            check(f'hstateen{index}-machine-revoked', read(hypervisor)[0], 0)
            illegal(f'hstateen{index}-supervisor-revoked', hypervisor, 1)
            write(hypervisor, reference.mask)
            check(f'hstateen{index}-machine-write-gated', read(hypervisor)[0], 0)
        illegal('henvcfg-supervisor-denied', 0x60a, 1)
        write(0x30c, 1 << 62)
        check('henvcfg-supervisor-granted', read(0x60a, 1)[0], 0)
        write(0x30c, 0)
        illegal('henvcfg-supervisor-revoked', 0x60a, 1)

        guest_pc = 0x80fd0000

        def guest_read(csr, write_value=None, supervisor=True):
            instruction = (csr << 20) | (2 << 12) | (3 << 7) | 0x73
            if write_value is not None:
                state.gpr[4] = write_value
                instruction = (csr << 20) | (4 << 15) | (1 << 12) | 0x73
            reference.write(guest_pc, instruction.to_bytes(4, 'little') +
                            (0x00000073).to_bytes(4, 'little'))
            state.priv[0] = b'\x03'
            state.mstatus[0] = ((state.mstatus[0] & ~(3 << 11)) | (1 << 39) |
                                ((1 << 11) if supervisor else 0))
            state.mepc[0] = guest_pc
            reference.run([0x30200073])
            reference.lib.difftest_exec(1)
            result = [state.pc[0], state.mcause[0], state.gpr[3]]
            if state.pc[0] == guest_pc + 4:
                reference.lib.difftest_exec(1)
            return result

        write(0x106, 7)
        check('vs-scounteren-shared', guest_read(0x106)[::2], [guest_pc + 4, 7])
        check('vs-scounteren-write', guest_read(0x106, 5)[0], guest_pc + 4)
        check('hs-scounteren-sees-guest-write', read(0x106)[0], 5)
        check('vs-unimplemented-hcsr-illegal', guest_read(0x6ff)[:2],
              [state.mtvec[0], 2])
        check('vs-read-only-hcsr-write-illegal', guest_read(0xe12, 1)[:2],
              [state.mtvec[0], 2])
        check('vs-hstateen-machine-denied', guest_read(0x60c)[:2],
              [state.mtvec[0], 2])
        write(0x30c, 1 << 63)
        check('vs-hstateen-machine-granted', guest_read(0x60c)[:2],
              [state.mtvec[0], 22])
        write(0x30c, 0)
        check('vs-henvcfg-machine-denied', guest_read(0x60a)[:2],
              [state.mtvec[0], 2])
        write(0x30c, 1 << 62)
        check('vs-henvcfg-machine-granted', guest_read(0x60a)[:2],
              [state.mtvec[0], 22])
        write(0x30c, 0)
        check('vu-senvcfg-machine-denied', guest_read(0x10a, supervisor=False)[:2],
              [state.mtvec[0], 2])
        write(0x30c, 1 << 62)
        check('vu-senvcfg-machine-granted', guest_read(0x10a, supervisor=False)[:2],
              [state.mtvec[0], 22])

        for csr, stateen_index, stateen_bit, name in (
            (0x10a, 0, 62, 'senvcfg'),
            (0x10c, 0, 63, 'sstateen0'),
            (0x10d, 1, 63, 'sstateen1'),
        ):
            write(0x30c + stateen_index, 0)
            check(f'vs-{name}-machine-denied', guest_read(csr)[:2],
                  [state.mtvec[0], 2])
            write(0x30c + stateen_index, 1 << stateen_bit)
            check(f'vs-{name}-hypervisor-denied', guest_read(csr)[:2],
                  [state.mtvec[0], 22])
            write(0x60c + stateen_index, 1 << stateen_bit)
            check(f'vs-{name}-granted', guest_read(csr)[::2],
                  [guest_pc + 4, 0])
            if csr == 0x10a:
                check('vs-senvcfg-write', guest_read(csr, 0x40)[0], guest_pc + 4)
                check('hs-senvcfg-sees-guest-write', read(csr)[0], 0x40)
                write(csr, 0)

    if args.enable:
        illegal('senvcfg-supervisor-denied', 0x10a, 1)
        gate = 3 << (62 if args.xlen == 64 else 30)
        write(0x30c if args.xlen == 64 else 0x31c, gate)
        check('senvcfg-supervisor-granted', read(0x10a, 1)[0], 0)
        write(0x30c if args.xlen == 64 else 0x31c, gate & ~(1 << (62 if args.xlen == 64 else 30)))
        illegal('senvcfg-supervisor-revoked', 0x10a, 1)
        check('senvcfg-machine-available', read(0x10a)[0], 0)
    else:
        check('senvcfg-unchanged', read(0x10a, 1)[0], 0)

    failures = [row for row in rows if not row['passed']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(xlen=args.xlen, enabled=args.enable,
        hypervisor=args.hypervisor,
        reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=rows, failures=len(failures)), indent=2) + '\n')
    for failure in failures[:8]:
        print('FAIL', failure)
    print(f'NEMU_SMSTATEEN xlen={args.xlen} enabled={args.enable} cases={len(rows)} failures={len(failures)}')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
