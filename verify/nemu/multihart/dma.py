#!/usr/bin/env python3
"""Exercise production DMA/RNG and fail-closed multi-hart DiffTest boundaries."""
from lib.build import ROOT, build_production_harness
from lib.harness import Check, parser, sha256

SOURCES = ['nemu/src/cpu/smp.c', 'nemu/src/cpu/thread.c', 'nemu/src/cpu/difftest/multihart-state.c',
           'nemu/src/device/timer.c', 'nemu/src/device/intr.c', 'nemu/src/isa/riscv/system/pmp.c',
           'nemu/src/device/io/map.c', 'nemu/src/device/io/mmio.c', 'nemu/src/memory/paddr.c',
           'nemu/src/utils/timer.c', 'app/tests/host/nemu_dma_rng.c']


def main():
    arguments = parser(__doc__)
    arguments.set_defaults(sanitize='undefined')
    check = Check(arguments.parse_args(), 'dma')
    inputs = SOURCES + ['nemu/src/device/rng.c'] + [str(path.relative_to(ROOT))
                                                    for path in sorted((ROOT / 'nemu/include').rglob('*.h'))]
    check.details = dict(source_sha256={name: sha256(ROOT / name) for name in inputs})
    for xlen in check.args.xlen:
        check.target(xlen, reference=False, driver=False)
        harness = build_production_harness(check.build / 'dma-rng', SOURCES, check.build / 'nemu', check.args.sanitize)
        for harts in (1, 2, 4):
            output = check.run(f'harts{harts}', [harness, harts], timeout=60,
                               markers=f'NEMU_DMA_RNG_PASS RV{xlen} harts={harts} rounds=100'.encode())
            check.save(f'harts{harts}-rejected-dma', output.count(b'NEMU_MULTIDIFF_UNSUPPORTED_DMA') == 2)
    check.finish('DMA')


if __name__ == '__main__':
    main()
