#!/usr/bin/env python3
"""Run one NEMU check: ``check.py NAME [options]``; ``check.py NAME --help`` lists options.

Multi-hart execution and DiffTest checks live in ``multihart/``, single-hart
ISA/platform checks in ``isa/``. ``inspect`` validates a recorded journal and
``supervise`` runs a live DUT/reference pair over a pipe.
"""
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
TOOLS = {'inspect': 'lib.journal', 'supervise': 'lib.stream'}


def modules():
    found = dict(TOOLS)
    for group in ('multihart', 'isa'):
        for path in sorted((HERE / group).glob('[a-z]*.py')):
            found[path.stem.replace('_', '-')] = f'{group}.{path.stem}'
    return found


def main():
    available = modules()
    if len(sys.argv) < 2 or sys.argv[1] not in available:
        names = '\n'.join('  ' + name for name in available)
        raise SystemExit(f'usage: {Path(sys.argv[0]).name} NAME [options]\n\nNAME is one of:\n{names}')
    sys.path.insert(0, str(HERE))
    module = available[sys.argv[1]]
    sys.argv = [f'{sys.argv[0]} {sys.argv[1]}', *sys.argv[2:]]
    if module in TOOLS.values():
        __import__(module, fromlist=['main']).main()
    else:
        runpy.run_module(module, run_name='__main__', alter_sys=True)


if __name__ == '__main__':
    main()
