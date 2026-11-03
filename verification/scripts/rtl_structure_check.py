#!/usr/bin/env python3
"""Check that RTL directories follow the instance hierarchy and its dependency rules.

rtl/ holds only the processor: the cluster top (rapt.sv) and its core, uncore and
shared leaves. Downstream integrations (synth/configs/, sim/, fpga/) live outside it. A
module may only instantiate modules from the zones listed for its own zone, so a
core never reaches into the uncore, and shared leaves never depend on either.
L2 configuration macros may only be tested where the L2 link is interpreted,
never inside a core.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# zone -> zones it may instantiate
ALLOWED = {
    'core': {'core', 'common', 'sram', 'generated'},
    'uncore': {'uncore', 'common', 'sram'},
    'top': {'core', 'uncore', 'common', 'sram'},
    'common': {'common', 'sram'},
    'sram': {'sram'},
    'generated': {'generated'},
}
TOP_FILES = {'rapt.sv': 'top', 'rapt_pkg.sv': 'top'}
L2_MACRO = re.compile(r'`(?:ifdef|ifndef|elsif)?\s*RAPT_L2_(?!TLB)\w*|`RAPT_L2_(?!TLB)\w*')
L2_ALLOWED = ('uncore/', 'configs/', 'include/rapt.svh', 'rapt_pkg.sv')
MODULE = re.compile(r'^\s*module\s+(\w+)', re.M)
INSTANCE = re.compile(r'^\s*((?:rapt|wrap)_\w+)\s*(?:#\s*\(|\w+\s*(?:\[[^\]]*\]\s*)?\()', re.M)
COMMENTS = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)


def zone_of(rel):
    parts = rel.parts
    if len(parts) == 1:
        return TOP_FILES.get(parts[0])
    return parts[0] if parts[0] in ALLOWED else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, default=ROOT / 'rtl')
    args = parser.parse_args()
    rtl = args.rtl
    errors = []
    defined, texts = {}, {}
    for path in sorted(rtl.rglob('*.sv')):
        rel = path.relative_to(rtl)
        if rel.parts[0] == 'configs':
            continue
        zone = zone_of(rel)
        if zone is None:
            errors.append(f'{rel}: not in a known zone ({", ".join(sorted(ALLOWED))})')
            continue
        text = COMMENTS.sub('', path.read_text())
        texts[rel] = (zone, text)
        for name in MODULE.findall(text):
            defined[name] = zone
    edges = 0
    for rel, (zone, text) in texts.items():
        for child in INSTANCE.findall(text):
            child_zone = defined.get(child)
            if child_zone is None or child in MODULE.findall(text):
                continue
            edges += 1
            if child_zone not in ALLOWED[zone]:
                errors.append(f'{rel}: {zone} instantiates {child} from {child_zone}')
    for path in sorted(rtl.rglob('*.sv*')):
        rel = path.relative_to(rtl).as_posix()
        if rel.startswith(L2_ALLOWED) or rel in L2_ALLOWED:
            continue
        text = COMMENTS.sub('', path.read_text())
        if L2_MACRO.search(text):
            errors.append(f'{rel}: tests an L2 macro; take L2 capabilities as parameters')
    for e in errors:
        print(f'ERROR: {e}')
    if errors:
        print(f'FAIL: RTL structure ({len(errors)} errors)')
        return 1
    print(f'PASS: RTL structure ({len(texts)} files, {len(defined)} modules, {edges} instances)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
