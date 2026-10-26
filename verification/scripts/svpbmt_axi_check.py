#!/usr/bin/env python3
"""Check external AXI evidence for the fixed svpbmt_enabled.S workload.

Requires a simulator built with RAPT_AXI_OBSERVE. This checks accepted bus
transactions, not all speculative internal requests or arbitrary workloads.
"""
import argparse
from collections import Counter, defaultdict, deque
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def parse_trace(text):
    reads, writes, beats = [], [], []
    pending_r, pending_b = defaultdict(deque), defaultdict(deque)
    last_cycle = -1
    for line in text.splitlines():
        if not line.startswith('AXI_OBS '):
            continue
        _, cycle, kind, *fields = line.split()
        cycle = int(cycle)
        assert cycle >= last_cycle, 'non-monotonic AXI log'
        last_cycle = cycle
        v = [int(f, 16) for f in fields]
        if kind in ('AR', 'AW'):
            ident, addr, size, length, burst, cache = v
            req = dict(cycle=cycle, id=ident, addr=addr, size=size,
                       length=length, burst=burst, cache=cache, responses=0)
            if kind == 'AR':
                reads.append(req)
                pending_r[ident].append(req)
            else:
                writes.append(req)
                pending_b[ident].append(req)
        elif kind == 'R':
            ident, resp, last = v
            assert pending_r[ident], 'R without AR'
            req = pending_r[ident][0]
            assert resp == 0, 'unexpected read error in this workload'
            req['responses'] += 1
            assert last == int(req['responses'] == req['length'] + 1), 'RLAST/count'
            if last:
                req['done'] = cycle
                pending_r[ident].popleft()
        elif kind == 'W':
            data, strb, last = v
            beats.append(dict(cycle=cycle, data=data, strb=strb, last=last))
        elif kind == 'B':
            ident, resp = v
            assert pending_b[ident], 'B without AW'
            assert resp == 0, 'unexpected write error in this workload'
            pending_b[ident].popleft()['done'] = cycle
        else:
            raise AssertionError('unknown AXI event ' + kind)
    assert reads and writes, 'missing AXI observation (build with RAPT_AXI_OBSERVE)'
    # AXI4 W data has no ID; it belongs to AW requests in order. Collecting
    # offline also handles W-before-AW and independent channel backpressure.
    cursor = 0
    for req in writes:
        count = req['length'] + 1
        req['beats'] = beats[cursor:cursor + count]
        cursor += count
        assert len(req['beats']) == count, 'incomplete W transaction'
        assert [x['last'] for x in req['beats']] == [0] * (count-1) + [1], 'WLAST/count'
        assert req.get('done', -1) >= max(req['cycle'], req['beats'][-1]['cycle']), 'B before AW/W completion'
    assert cursor == len(beats), 'orphan W beats'

    return reads, writes


def check(text, payload, code):
    reads, writes = parse_trace(text)
    typed_reads = [r for r in reads if code <= r['addr'] < code + 4096]
    expected = Counter({(code, 2): 1, (code+4, 2): 1,
                        (code, 0): 2, (code+4, 0): 2})
    assert Counter((r['addr'], r['cache']) for r in typed_reads) == expected, 'typed fetch count/address/cache'
    for r in typed_reads:
        assert r['size'] == 2 and r['length'] == 0 and 'done' in r, 'typed fetch widened/incomplete'

    io_reads = [r for r in reads if payload <= r['addr'] < payload+4096 and r['cache'] == 0]
    io_writes = [r for r in writes if payload <= r['addr'] < payload+4096 and r['cache'] == 0]
    expected_data = Counter({(payload, 3): 1, (payload+16, 0): 1,
                             (payload+18, 1): 1, (payload+20, 2): 1})
    assert Counter((r['addr'], r['size']) for r in io_reads) == expected_data, 'IO read count/address/size'
    assert Counter((r['addr'], r['size']) for r in io_writes) == expected_data, 'IO write count/address/size'
    for r in io_reads + io_writes:
        assert r['length'] == 0 and 'done' in r, 'IO data burst/completion'
    values = {payload: 0x123456789abcdef, payload+16: 0x5a,
              payload+18: 0x1234, payload+20: 0x12345678}
    for r in io_writes:
        lane = r['addr'] & 7
        width = 1 << r['size']
        mask = ((1 << width) - 1) << lane
        data_mask = ((1 << (8*width)) - 1) << (8*lane)
        assert r['beats'][0]['strb'] == mask, 'IO store byte enables'
        assert r['beats'][0]['data'] & data_mask == values[r['addr']] << (8*lane), 'IO store data'
    assert io_reads[0]['done'] <= io_writes[0]['cycle'], 'IO store overtook older IO load'
    nc_reads = [r for r in reads if payload <= r['addr'] < payload+4096 and r['cache'] == 2]
    nc_writes = [r for r in writes if payload <= r['addr'] < payload+4096 and r['cache'] == 2]
    # One aligned read/write and two-word misaligned operations. The second
    # misaligned read after re-enabling PBMTE must reach memory again.
    assert len(nc_reads) == 5 and len(nc_writes) == 3, 'NC bypass transaction count'
    assert all(r['length'] == 0 and 'done' in r for r in nc_reads + nc_writes), 'NC burst or incomplete access'
    # Workload fences require older accepted stores to have completed before
    # each IO read. The I-side guard has the same memory-idle obligation.
    for r in io_reads + [r for r in typed_reads if r['cache'] == 0]:
        for w in writes:
            if w['cycle'] < r['cycle']:
                assert w['done'] <= r['cycle'], 'IO read overtook pending write response'
    return dict(read_requests=len(reads), write_requests=len(writes),
                typed_fetches=len(typed_reads), io_data_reads=len(io_reads),
                io_data_writes=len(io_writes), nc_data_reads=len(nc_reads),
                nc_data_writes=len(nc_writes))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--summary', type=Path, required=True)
    ap.add_argument('--elf', type=Path, required=True)
    ap.add_argument('--nm', default='riscv64-elf-nm')
    ap.add_argument('--objcopy', default='riscv64-elf-objcopy')
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    symbols = {}
    for line in subprocess.check_output([args.nm, '-n', str(args.elf)], text=True).splitlines():
        f = line.split()
        if len(f) == 3 and f[2] in ('payload', 'typed_code'):
            symbols[f[2]] = int(f[0], 16)
    summary = json.loads(args.summary.read_text())
    assert summary['name'] == 'svpbmt-enabled', 'wrong workload'
    for item in summary['inputs'].values():
        assert hashlib.sha256(Path(item['path']).read_bytes()).hexdigest() == item['sha256'], 'input drift'
    with tempfile.TemporaryDirectory(prefix='svpbmt-axi-') as temp:
        binary = Path(temp) / 'test.bin'
        subprocess.run([args.objcopy, '-O', 'binary', str(args.elf), str(binary)], check=True)
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == summary['inputs']['image']['sha256'], 'ELF/image mismatch'
    result = {'symbols': symbols, 'elf_sha256': hashlib.sha256(args.elf.read_bytes()).hexdigest(),
              'summary_sha256': hashlib.sha256(args.summary.read_bytes()).hexdigest(), 'runs': []}
    for run in summary['runs']:
        assert run['passed'] and run['returncode'] == 0, 'architectural run failed'
        log = Path(run['log'])
        counts = check(log.read_text(), symbols['payload'], symbols['typed_code'])
        result['runs'].append(dict(delay=run['delay'], seed=run['seed'], counts=counts,
                                  log=str(log), sha256=hashlib.sha256(log.read_bytes()).hexdigest()))
    assert result['runs'], 'empty run set'
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f"PASS: {len(result['runs'])} whole-core Svpbmt AXI traces")


if __name__ == '__main__':
    main()
