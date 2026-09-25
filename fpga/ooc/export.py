#!/usr/bin/env python3
"""Export fixed-preset interface adapters for coarse OOC synthesis."""
import argparse
import fcntl
import hashlib
import json
import re
import subprocess
from pathlib import Path
P = argparse.ArgumentParser()
P.add_argument('--parameter', action='append', default=[], metavar='BLOCK.PARAM=INTEGER',
               help='Specialize a block parameter to match its value in the exported top')
P.add_argument('pack', type=Path)
P.add_argument('output', type=Path)
a = P.parse_args()
a.output = a.output.resolve()
a.pack = a.pack.resolve()
a.output.mkdir(parents=True, exist_ok=True)
lock = (a.output / '.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
text = a.pack.read_text()
# The dependency hashes ignore ordinary comments. Reject synthesis directives
# in comments instead of allowing an apparently unchanged checkpoint to hide
# their effect. Use SV attributes or the normal preprocessed pack flow.
for comment in re.findall(r'/\*.*?\*/|//[^\n]*', text, re.S):
    if re.match(r'(?:/\*|//)\s*(?:synthesis|synopsys|pragma|translate_on|translate_off)\b', comment, re.I):
        raise ValueError('Unsupported synthesis comment pragma; use SystemVerilog attributes in the preprocessed pack')
clean = re.sub('/\\*.*?\\*/|//[^\\n]*', '', text, flags=re.S)
blocks = ['rapt_frontend', 'rapt_backend', 'rapt_l1i', 'rapt_l1d']
parameter_overrides = {block: {} for block in blocks}
for override in a.parameter:
    match = re.fullmatch(r'(\w+)\.(\w+)=(0[xX][0-9a-fA-F]+|\d+)', override)
    if not match or match[1] not in parameter_overrides:
        raise ValueError(f'Invalid parameter override: {override}')
    block, name, raw_value = match.groups()
    if name in parameter_overrides[block]:
        raise ValueError(f'Duplicate parameter override: {block}.{name}')
    parameter_overrides[block][name] = int(raw_value, 0)
modules = {m[1]: m[0] for m in re.finditer('\\bmodule\\s+(\\w+)\\b.*?endmodule', clean, re.S)}
globals_text = '\n'.join((m[0] for m in re.finditer('\\b(package|interface)\\s+.*?end(?:package|interface)', clean, re.S)))

def dependencies(name):
    # A conservative module-token closure: extra dependencies only invalidate
    # more checkpoints. Global package/interface changes invalidate all blocks.
    found = set()
    todo = [name]
    while todo:
        current = todo.pop()
        if current in found:
            continue
        found.add(current)
        todo.extend(set(re.findall('\\b\\w+\\b', modules[current])) & modules.keys() - found)
    return sorted(found)
interfaces = {m[1]: m[2] for m in re.finditer('\\binterface\\s+(\\w+)(.*?endinterface)', clean, re.S)}
probe = ['module width_probe;']
info = {}
ports = []
for block in blocks:
    m = re.search('\\bmodule\\s+' + block + '\\b(.*?);(.*?)endmodule', clean, re.S)
    header = m[1]
    start = header.index(') (') + 2 if ') (' in header else header.index('(')
    rawports = header[start + 1:].rstrip().removesuffix(')')
    params = header[:header.index(') (')].strip().removeprefix('#(')
    probe.append(f'if (1) begin : {block}_parameters')
    param_names = []
    for decl in params.split(','):
        decl = decl.strip()
        pm = re.fullmatch(
            r'parameter\s+(?:(?:int|integer|bit|logic)(?:\s+(?:signed|unsigned))?'
            r'|signed|unsigned)\s+(\w+)\s*=\s*(.*)', decl, re.S)
        if not pm:
            raise ValueError(f'Unsupported parameter: {decl}')
        param_names.append(pm[1])
        probe.append(decl.replace('parameter', 'localparam', 1) + ';')
    for name in param_names:
        probe.append(f'initial $display("PARAM {block} {name} %0d",{name});')
    probe.append('end')
    entries = [s.strip() for s in rawports.split(',') if s.strip()]
    rec = {'header': header, 'scalar': [], 'interface': [], 'dependencies': dependencies(block)}
    info[block] = rec
    for e in entries:
        im = re.fullmatch('(\\w+_if)(?:\\.(\\w+))?\\s+(\\w+)', e)
        if im:
            ty, mod, name = im.groups()
            mod = mod or ('source' if name == 'recovery' else 'out')
            body = interfaces[ty]
            mm = re.search('\\bmodport\\s+' + mod + '\\((.*?)\\);', body, re.S)
            if not mm:
                raise ValueError((ty, mod))
            var = block + '__' + name
            probe.append(f'{ty} {var}();')
            direction = None
            fields = []
            for f in mm[1].split(','):
                f = f.strip()
                dm = re.match('(input|output)\\s+(\\w+)$', f)
                if dm:
                    direction, f = dm.groups()
                if not re.fullmatch('\\w+', f) or direction is None:
                    raise ValueError(f)
                array = bool(re.search('\\b' + f + '\\s*\\[', body[:body.index('modport')]))
                fields.append({'name': f, 'direction': direction, 'array': array, 'key': var + '__' + f})
                ports.append((var + '.' + f, var + '__' + f, array))
            rec['interface'].append({'type': ty, 'name': name, 'fields': fields})
        else:
            sm = re.fullmatch('(input|output)\\s+(?:logic\\s+)?(\\[[^]]+\\]\\s*)?(\\w+)(?:\\s*=.*)?', e, re.S)
            if not sm:
                raise ValueError((block, e))
            direction, width, name = sm.groups()
            width = (width or '').replace('XLEN', '`RAPT_XLEN')
            key = block + '__' + name
            probe.append(f'logic {width} {key};')
            ports.append((key, key, False))
            rec['scalar'].append({'name': name, 'direction': direction, 'key': key})
probe.append('initial begin')
for ref, key, array in ports:
    probe.append(f'$display("WIDTH {key} %0d %0d",$bits({ref}),' + (f'$size({ref})' if array else '1') + ');')
probe += ['$finish; end', 'endmodule']
x = re.search('module rapt_core\\s*#\\(\\s*parameter int XLEN\\s*=\\s*(\\d+)', clean).group(1)
probe = '\n'.join(probe).replace('`RAPT_XLEN', x)
(a.output / 'probe.sv').write_text(text + '\n' + probe)
with (a.output / 'probe-build.log').open('w') as log:
    subprocess.run(['verilator', '--binary', '--top-module', 'width_probe', '-Wno-fatal', '--Mdir', str(a.output / 'obj_probe'), str(a.output / 'probe.sv')], stdout=log, stderr=subprocess.STDOUT, check=True)
out = subprocess.check_output([str(a.output / 'obj_probe/Vwidth_probe')], text=True)
sizes = {m[1]: (int(m[2]), int(m[3])) for m in re.finditer('WIDTH (\\w+) (\\d+) (\\d+)', out)}
parameter_values = {b: {} for b in blocks}
for m in re.finditer('PARAM (\\w+) (\\w+) (\\d+)', out):
    parameter_values[m[1]][m[2]] = int(m[3])
for block, overrides in parameter_overrides.items():
    unknown = overrides.keys() - parameter_values[block].keys()
    if unknown:
        raise ValueError(f'Unknown parameter override: {block}.{sorted(unknown)[0]}')
    parameter_values[block].update(overrides)
wrappers = []
bridges = []
renamed = text
for block, rec in info.items():
    flat = []
    conn = []
    local = []
    assigns = []
    bconn = []
    for s in rec['scalar']:
        w, _ = sizes[s['key']]
        bit_range = f'[{w - 1}:0] ' if w > 1 else ''
        flat.append(f"{s['direction']} wire {bit_range}{s['name']}")
        conn.append(f".{s['name']}({s['name']})")
        bconn.append(conn[-1])
    for it in rec['interface']:
        n = it['name']
        local.append(f"{it['type']} {n}();")
        conn.append(f'.{n}({n})')
        for f in it['fields']:
            w, count = sizes[f['key']]
            port = n + '__' + f['name']
            ref = n + '.' + f['name']
            bit_range = f'[{w - 1}:0] ' if w > 1 else ''
            flat.append(f"{f['direction']} wire {bit_range}{port}")
            refs = [f'{ref}[{i}]' for i in reversed(range(count))] if f['array'] else [ref]
            bconn.append(f'.{port}(' + ('{' + ', '.join(refs) + '}' if f['array'] else ref) + ')')
            for i in range(count):
                lhs = f'{ref}[{i}]' if f['array'] else ref
                rhs = f'{port}[{i * (w // count)}+:{w // count}]' if f['array'] else port
                if f['direction'] == 'output':
                    lhs, rhs = (rhs, lhs)
                assigns.append(f'assign {lhs} = {rhs};')
    wrapper = f'module {block}_ooc(\n' + ',\n'.join(flat) + '\n);\n'
    overrides = parameter_overrides[block]
    specialization = (' #(' + ', '.join(f'.{name}({value})' for name, value in overrides.items()) + ')'
                      if overrides else '')
    wrappers.append(wrapper + '\n'.join(local + assigns) + f'\n{block}_impl{specialization} impl('
                    + ', '.join(conn) + ');\nendmodule\n')
    (a.output / f'{block}_stub.sv').write_text('(* black_box *) ' + wrapper + 'endmodule\n')
    checks = '\n'.join((f'initial if ({name} != {value}) $error("OOC export parameter mismatch: {block}.{name}");' for name, value in parameter_values[block].items()))
    rec['parameters'] = parameter_values[block]
    rec['source_sha256'] = hashlib.sha256((globals_text + '\n' + '\n'.join((modules[n] for n in rec['dependencies'])) + '\n' + wrappers[-1]).encode()).hexdigest()
    bridges.append(f'module {block}' + rec['header'] + ';\n' + checks + '\n' + f'{block}_ooc partition(' + ', '.join(bconn) + ');\nendmodule\n')
    renamed = re.sub('\\bmodule\\s+' + block + '\\b', 'module ' + block + '_impl', renamed, count=1)
(a.output / 'partitions.sv').write_text(renamed + '\n' + '\n'.join(wrappers))
(a.output / 'linked.sv').write_text(renamed + '\n' + '\n'.join(bridges) + '\n' + '\n'.join(wrappers))
(a.output / 'blackboxes.sv').write_text(renamed + '\n' + '\n'.join(bridges) + '\n' + '\n'.join(((a.output / f'{b}_stub.sv').read_text() for b in blocks)))
artifacts = {
    name: hashlib.sha256((a.output / name).read_bytes()).hexdigest()
    for name in ('partitions.sv', 'linked.sv', 'blackboxes.sv')
}
(a.output / 'manifest.json').write_text(json.dumps({
    'pack_sha256': hashlib.sha256(a.pack.read_bytes()).hexdigest(),
    'xlen': int(x),
    'top_sha256': hashlib.sha256((renamed + '\n' + '\n'.join(bridges)).encode()).hexdigest(),
    'blocks': info, 'widths': sizes, 'artifacts': artifacts,
}, indent=2) + '\n')
print(a.output)
