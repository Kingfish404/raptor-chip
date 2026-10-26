#!/usr/bin/env python3
"""C 2.0 expansion oracle. No RTL/NEMU imports; extra Zcb regions excluded."""
import argparse
import collections
import hashlib
import json
from pathlib import Path


def sext(v, n):
    return v - (1 << n) if v & (1 << (n - 1)) else v


def permute(c, mapping):
    return sum(((c >> src) & 1) << dst for dst, src in mapping.items())


def it(imm, rs, f, rd, op=0x13):
    return ((imm & 4095) << 20) | rs << 15 | f << 12 | rd << 7 | op


def rt(f7, rs2, rs1, f, rd, op=0x33):
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f << 12 | rd << 7 | op


def st(imm, rs2, rs1, f, op=0x23):
    return ((imm & 0xfe0) << 20) | rs2 << 20 | rs1 << 15 | f << 12 | (imm & 31) << 7 | op


def jt(imm, rd):
    v = imm & 0x1fffff
    return ((v >> 20) << 31) | ((v & 0x7fe) << 20) | ((v & 0x800) << 9) | (v & 0xff000) | rd << 7 | 0x6f


def bt(imm, rs, f):
    v = imm & 8191
    return ((v & 0x1000) << 19) | ((v & 0x7e0) << 20) | rs << 15 | f << 12 | ((v & 30) << 7) | ((v & 0x800) >> 4) | 0x63


def expand(c, x):
    # kind: 0 exact expansion, 1 illegal, 2 HINT (exact or canonical NOP),
    # 3 breakpoint, 4 separately excluded implemented-extra region.
    q, f = c & 3, c >> 13
    rd, rs2 = (c >> 7) & 31, (c >> 2) & 31
    a, b = 8 + ((c >> 7) & 7), 8 + ((c >> 2) & 7)
    ci = sext(((c >> 12) & 1) * 32 + ((c >> 2) & 31), 6)
    sh = ((c >> 12) & 1) * 32 + ((c >> 2) & 31)
    word = permute(c, {6: 5, 5: 12, 4: 11, 3: 10, 2: 6})
    double = permute(c, {7: 6, 6: 5, 5: 12, 4: 11, 3: 10})
    jump = sext(permute(c, {11:12, 10:8, 9:10, 8:9, 7:6, 6:7, 5:2, 4:11, 3:5, 2:4, 1:3}), 12)
    branch = sext(permute(c, {8:12, 7:6, 6:5, 5:2, 4:11, 3:10, 2:4, 1:3}), 9)
    bad = (1, 0, 'reserved')
    if q == 0:
        if f == 0:
            v = permute(c, {9:10, 8:9, 7:8, 6:7, 5:12, 4:11, 3:5, 2:6})
            return bad if not v else (0, it(v, 2, 0, b), 'addi4spn')
        if f == 4:
            return 4, 0, 'Zcb-Q0-region'
        fp = f in (1, 5) or (x == 32 and f in (3, 7))
        wide = f in (1, 5) or (x == 64 and f in (3, 7))
        v, funct = (double, 3) if wide else (word, 2)
        if f < 4:
            return 0, it(v, a, funct, b, 7 if fp else 3), 'register-load'
        return 0, st(v, b, a, funct, 0x27 if fp else 0x23), 'register-store'
    if q == 1:
        if f == 0:
            return (2 if rd == 0 or ci == 0 else 0), it(ci, rd, 0, rd), 'addi/nop'
        if f == 1:
            return (bad if rd == 0 else (0, it(ci, rd, 0, rd, 0x1b), 'addiw')) if x == 64 else (0, jt(jump, 1), 'jal')
        if f == 2:
            return (2 if rd == 0 else 0), it(ci, 0, 0, rd), 'li'
        if f == 3:
            if ci == 0:
                return (2, 0x13, 'C.MOP') if rd < 16 and rd & 1 else bad
            if rd == 2:
                v = sext(permute(c, {9:12, 8:4, 7:3, 6:5, 5:2, 4:6}), 10)
                return 0, it(v, 2, 0, 2), 'addi16sp'
            return (2 if rd == 0 else 0), ((ci << 12) & 0xfffff000) | rd << 7 | 0x37, 'lui'
        if f == 4:
            sub = (c >> 10) & 3
            if sub in (0, 1):
                if x == 32 and sh >= 32:
                    return bad
                return (2 if sh == 0 else 0), it(sh | (0x400 if sub else 0), a, 5, a), 'right-shift'
            if sub == 2:
                return 0, it(ci, a, 7, a), 'andi'
            op = (c >> 5) & 3
            if c & 0x1000:
                if op >= 2:
                    return 4, 0, 'Zcb-Q1-region'
                return (0, rt(0x20 if op == 0 else 0, b, a, 0, a, 0x3b), 'word-arithmetic') if x == 64 else bad
            return 0, rt(0x20 if op == 0 else 0, b, a, [0, 4, 6, 7][op], a), 'register-arithmetic'
        if f == 5:
            return 0, jt(jump, 0), 'j'
        return 0, bt(branch, a, 0 if f == 6 else 1), 'branch'
    if q == 2:
        if f == 0:
            if x == 32 and sh >= 32:
                return bad
            return (2 if sh == 0 or rd == 0 else 0), it(sh, rd, 1, rd), 'slli'
        if f in (1, 2, 3):
            fp = f == 1 or (f == 3 and x == 32)
            wide = f == 1 or (f == 3 and x == 64)
            if not fp and rd == 0:
                return bad
            mapping = {8:4, 7:3, 6:2, 5:12, 4:6, 3:5} if wide else {7:3, 6:2, 5:12, 4:6, 3:5, 2:4}
            return 0, it(permute(c, mapping), 2, 3 if wide else 2, rd, 7 if fp else 3), 'stack-load'
        if f == 4:
            if rs2 == 0:
                if not c & 0x1000:
                    return bad if rd == 0 else (0, it(0, rd, 0, 0, 0x67), 'jr')
                return (3, 0x100073, 'ebreak') if rd == 0 else (0, it(0, rd, 0, 1, 0x67), 'jalr')
            return (2 if rd == 0 else 0), rt(0, rs2, rd if c & 0x1000 else 0, 0, rd), 'add/mv'
        fp = f == 5 or (f == 7 and x == 32)
        wide = f == 5 or (f == 7 and x == 64)
        mapping = {8:9, 7:8, 6:7, 5:12, 4:11, 3:10} if wide else {7:8, 6:7, 5:12, 4:11, 3:10, 2:9}
        return 0, st(permute(c, mapping), rs2, 2, 3 if wide else 2, 0x27 if fp else 0x23), 'stack-store'
    raise ValueError('not a 16-bit instruction')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xlen', type=int, choices=[32, 64], required=True)
    ap.add_argument('--output', type=Path, required=True)
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    counts, kinds, excluded, lines = collections.Counter(), collections.Counter(), [], []
    for c in range(65536):
        if c & 3 == 3:
            continue
        kind, expected, group = expand(c, a.xlen)
        counts[group] += 1
        kinds[str(kind)] += 1
        if kind == 4:
            excluded.append(f'{c:04x}')
        else:
            lines.append(f'{c:04x} {kind:x} {expected:08x}')
    assert len(lines) == 46976 and len(excluded) == 2176
    (a.output / 'vectors.txt').write_text('\n'.join(lines) + '\n')
    (a.output / 'manifest.json').write_text(json.dumps({'xlen':a.xlen, 'cases':len(lines), 'groups':counts, 'kinds':kinds, 'excluded':excluded, 'source_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'scope':'C 2.0 expansion and selected unimplemented-encoding policy; Zcb regions excluded; eight existing C.MOP controls retained; not execution/whole-profile proof'}, indent=2) + '\n')
    print(a.xlen, len(lines), 'cases;', len(excluded), 'explicit extra-region exclusions')


if __name__ == '__main__':
    main()
