"""Validate the combined RVA23 profile on multiple cooperative harts."""

import re
import struct
from itertools import product

from lib.build import build_dtb
from lib.harness import Check, parser, sha256
from lib.journal import END, HEADER, STATE, STATE_WORDS, VECTOR_FLAG, check_journal, read_events, write_events


CASES = {
    'atomic': (),
    'overflow': ('SSCOFPMF',),
    'stateen': ('SMSTATEEN',),
    'guest-stateen': ('H_STATEEN',),
    'guest-memory': ('H_GSTAGE', 'H_PBMT', 'H_POINTER_MASK'),
    'guest-napot': ('H_GSTAGE', 'H_SVNAPOT'),
    'wait-reservation': ('ZAWRS',),
    'vector-control': ('VECTOR_CONTROL',),
    'vector': ('VECTOR_DATA',),
    'vector-fp': ('VECTOR_FP',),
    'vector-bits': ('ZVBB',),
    'vector-half': ('ZVFHMIN',),
    'guest-vector': ('H_GSTAGE', 'VECTOR_DATA'),
    'zfa': 'nemu_zfa.S',
    'pointer-mask': 'nemu_pointer_mask.S',
    'napot': 'nemu_svnapot.S',
    'shared-memory': 'nemu_rva23_shared.S',
}
CLOCK_CASES = {
    'clint': ('nemu_diff_clint.S', ()),
    'guest-timer': ('nemu_h_gstage_irq.S', ('-DNEMU_H_IRQ_CLOCK',)),
    'guest-timer-delta': ('nemu_h_gstage_irq.S', ('-DNEMU_H_IRQ_CLOCK', '-DNEMU_H_IRQ_DELTA')),
}


def corrupt_state(source, destination, fault):
    header, events = read_events(source)
    slots = {'vector': STATE_WORDS + 16, 'fcsr': 65 + 0x003,
             'hstatus': 65 + 0x600, 'senvcfg': 65 + 0x10a, 'vstart': 65 + 0x008}
    slot = slots[fault]
    candidates = [event for event in events if event[0] == END and event[1] == 1]
    event = next((event for event in candidates if slot in
                  struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3])[4::2]), candidates[0])
    fields = list(struct.unpack('<' + 'Q' * (len(event[3]) // 8), event[3]))
    delta = dict(zip(fields[4::2], fields[5::2]))
    initial = next(item[3] for item in events if item[0] == STATE and item[1] == 1)
    delta[slot] = delta.get(slot, struct.unpack_from('<Q', initial, slot * 8)[0]) ^ 1
    fields = fields[:4] + [value for pair in sorted(delta.items()) for value in pair]
    event[3] = bytearray(struct.pack('<' + 'Q' * len(fields), *fields))
    write_events(destination, header, events)


def main():
    arguments = parser(__doc__, repeat=1, sanitizers=('undefined',))
    arguments.set_defaults(xlen=[64])
    arguments.add_argument('--harts', type=int, choices=(2, 3, 4), nargs='+', default=[2, 3, 4])
    arguments.add_argument('--cases', choices=tuple(CASES) + tuple(CLOCK_CASES), nargs='+',
                           default=list(CASES) + list(CLOCK_CASES))
    args = arguments.parse_args()
    if args.xlen != [64]:
        arguments.error('RVA23 requires RV64')
    check = Check(args, 'rva23-multihart')
    check.target(64)
    names = ('nemu_multidiff.S', 'nemu_zfa.S', 'nemu_pointer_mask.S', 'nemu_svnapot.S',
             'nemu_diff_clint.S', 'nemu_h_gstage_irq.S', 'nemu_rva23_shared.S')
    sources = dict(zip(names, check.snapshot(*names)))
    platforms = {}
    for harts in args.harts:
        directory = check.session / f'platform-{harts}'
        directory.mkdir(exist_ok=True)
        build_dtb(directory, harts, source_name='spike-rva23-nemu.dts')
        platforms[harts] = directory / 'nemu.dtb'
    check.details['platform_sha256'] = {harts: sha256(path) for harts, path in platforms.items()}
    fault_source = None
    for harts, repeat in product(args.harts, range(args.repeat)):
        check.dtb = platforms[harts]
        for case in args.cases:
            options = ['--isa-extensions=rva23', '--smp-backend=rr', f'--smp={harts}']
            name = f'harts{harts}-{case}-{repeat}'
            defines = ['-DNEMU_TEST_RVA23', '-DNEMU_MULTIDIFF_ITERATIONS=8']
            if case == 'shared-memory':
                defines.append('-march=rv64gcv')
            if case in CLOCK_CASES:
                source, extra = CLOCK_CASES[case]
                defines += extra
            else:
                features = CASES[case]
                source = features if isinstance(features, str) else 'nemu_multidiff.S'
                if not isinstance(features, str):
                    defines += ['-DNEMU_TEST_' + feature for feature in features]
            image = check.guest(name, [sources[source]], harts, defines)
            check.run(name + '-native', [check.binary, '-b', '-n', *options, '-t', check.dtb, image],
                      markers=b'Finisher: poweroff')
            if case in CLOCK_CASES:
                options.append('--diff-clint')
            else:
                check.run(name + '-lockstep', [check.binary, '-b', '-n', *options, '--diff-mode=multihart',
                                               '--diff=' + str(check.reference), '-t', check.dtb, image],
                          markers=f'seen=0x{(1 << harts) - 1:x} status=OK'.encode())
            journal, _ = check.record(name, options, image)
            memory = check_journal(journal)
            header, _ = read_events(journal)
            fields = HEADER.unpack(header)
            profile_mask = ((fields[6] >> 8) & 0xff) | ((fields[6] >> 40) & ~0xff)
            check.save(name + '-journal', all(count > 0 for count in memory['instructions'])
                       and len(memory['instructions']) == harts
                       and bool(fields[1] & VECTOR_FLAG) and fields[2:4] == (64, harts)
                       and profile_mask == 0x7ff and fields[7] == 0,
                       memory=memory, profile_mask=profile_mask)
            if case in CLOCK_CASES:
                check.save(name + '-interrupts', all(count > 0 for count in memory['interrupts'])
                           and memory['clocks'] > 0 and memory['idle_clocks'] > 0)
            output = check.replay(name + '-replay', journal)
            checked = re.search(rb'NEMU_REPLAY checked=(\d+)', output)
            check.save(name + '-retirements', checked is not None
                       and int(checked[1]) == sum(memory['instructions']))
            check.live(name + '-live', ['-n', *options, '-t', check.dtb, image])
            if case == 'shared-memory':
                broken = check.guest(name + '-missing-store', [sources[source]], harts,
                                     [*defines, '-DNEMU_TEST_SKIP_VECTOR_STORE'])
                check.run(name + '-missing-store', [check.binary, '-b', '-n', *options,
                                                    '-t', check.dtb, broken],
                          expect='nonzero', markers=b'Finisher: fail')
            if fault_source is None and case == 'guest-vector':
                check.run(name + '-disabled', [check.binary, '-b', '-n', '--isa-extensions=none',
                                               '--smp-backend=rr', f'--smp={harts}', '-t', check.dtb, image],
                          expect='nonzero', markers=b'Finisher: fail')
                fault_source = journal
    if fault_source is not None:
        check.faults(fault_source, corrupt_state, ('vector', 'fcsr', 'hstatus', 'senvcfg', 'vstart'))
    check.finish('RVA23_MULTIHART')


if __name__ == '__main__':
    main()
