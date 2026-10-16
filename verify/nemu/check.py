#!/usr/bin/env python3
"""Run one NEMU check: ``check.py NAME [options]``; ``check.py NAME --help`` lists options.

Multi-hart execution and DiffTest checks live in ``multihart/``, single-hart
ISA/platform checks in ``isa/``. ``inspect`` validates a recorded journal and
``supervise`` runs a live DUT/reference pair over a pipe.
"""
from pathlib import Path
import importlib
import runpy
import sys

HERE = Path(__file__).resolve().parent
TOOLS = {'inspect': 'lib.journal', 'supervise': 'lib.stream'}
SUITES = {
    'isa.vector_units_rtl': {
        'vector-' + unit.replace('_', '-') + '-rtl': unit
        for unit in ('alu', 'muldiv', 'reduce', 'mask_scan', 'slide', 'gather', 'mask_ops', 'move')
    },
}


def modules():
    found = dict(TOOLS)
    for group in ('multihart', 'isa'):
        for path in sorted((HERE / group).glob('[a-z]*.py')):
            module = f'{group}.{path.stem}'
            if module not in SUITES:
                found[path.stem.replace('_', '-')] = module
    for module, checks in SUITES.items():
        found.update(dict.fromkeys(checks, module))
    return found


def main():
    available = modules()
    if len(sys.argv) < 2 or sys.argv[1] not in available:
        names = '\n'.join('  ' + name for name in available)
        raise SystemExit(f'usage: {Path(sys.argv[0]).name} NAME [options]\n\nNAME is one of:\n{names}')
    sys.path.insert(0, str(HERE))
    selected = sys.argv[1]
    module = available[selected]
    sys.argv = [f'{sys.argv[0]} {selected}', *sys.argv[2:]]
    if module in SUITES:
        raise SystemExit(importlib.import_module(module).main(SUITES[module][selected]))
    elif module in TOOLS.values():
        __import__(module, fromlist=['main']).main()
    else:
        runpy.run_module(module, run_name='__main__', alter_sys=True)


if __name__ == '__main__':
    main()
