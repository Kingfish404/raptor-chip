"""Check closed-loop L1D/bus bounded progress and non-vacuity witnesses."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), nargs='+', default=[32, 64])
    parser.add_argument('--mode', choices=('bmc', 'cover', 'prove'), default='bmc')
    parser.add_argument('--negative-control', action='store_true',
                        help='Remove only the fix in an isolated packed copy; require progress FAIL')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.negative_control and args.mode == 'cover':
        parser.error('negative control requires bmc or prove')
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = [root / 'hdl/rapt_pkg.sv']
    sources += sorted(p for p in (root / 'hdl').rglob('*.sv')
                      if 'chisel' not in p.parts and p != sources[0])
    sources += [root / 'verify/formal/formal_memory_progress.sv']
    includes = [root / 'hdl/configs/default-w4', root / 'hdl/include',
                root / 'hdl/include/npc', root / 'hdl/include/dpic_mock', root / 'verify/xsim']
    dependencies = sources + sorted((root / 'hdl').rglob('*.svh'))
    dependencies += [root / 'verify/xsim/tb_l1d_defaults.svh',
                     root / 'verify/xsim/tb_core_bcast_defaults.svh', Path(__file__).resolve(),
                     root / 'verify/formal/sby', root / 'verify/formal/yosys-rvfi-compat.sh',
                     root / 'verify/formal/abc-read-blif-compat.sh']

    def hashes():
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in dependencies}

    result = {'complete': False, 'source_sha256': hashes(), 'cases': [],
              'scope': 'Real L1D/bus, 2 sets, 1 way, 2 words/line, no MSHRs/L2/D translation; '
                       'one load/store/I-PTW, start cycles 0..3, 3 aliases and 3 load kinds; '
                       'independent bounded external stalls, error-free responses; '
                       '32-cycle per-request deadline measured before AR; no data proof',
              'negative_control': args.negative_control,
              'negative_schedule': 'load=0 store=1 PTW=0 kind=split relation=different-line'
                                   if args.negative_control else None}
    report = output / 'results.json'

    def save():
        report.write_text(json.dumps(result, indent=2) + '\n')

    save()
    env = dict(os.environ)
    # formal/Makefile resolves Slang-capable Yosys before adding bundled solvers
    # to PATH. Preserve that choice when invoked through its aggregate target.
    env['RAPTOR_YOSYS_REAL'] = env.get('RAPTOR_YOSYS_REAL') or shutil.which('yosys') or 'yosys'
    env['PATH'] = str(root / 'third_party/oss-cad-suite/bin') + os.pathsep + env['PATH']
    for width in args.xlen:
        case_dir = output / f'rv{width}'
        case_dir.mkdir(exist_ok=True)
        pack = case_dir / 'design.sv'
        preprocess = ['verilator', '-E', '-P', '-DSYNTHESIS', '-DRAPT_L1D_MSHRS=0']
        if width == 64:
            preprocess += ['-DRAPT_RV64']
        preprocess += [f'-I{p}' for p in includes] + [str(p) for p in sources]
        with pack.open('w') as stream, (case_dir / 'preprocess.log').open('w') as errors:
            subprocess.run(preprocess, cwd=root, stdout=stream, stderr=errors, check=True)
        if args.negative_control:
            text = pack.read_text()
            old = '!line_read_request || !lsu_l1d.wvalid || local_store || !lsu_bus_write_allowed'
            if text.count(old) != 1:
                raise RuntimeError('Cannot locate exactly one refill fix for negative control')
            text = text.replace(old, '!line_read_request || !lsu_l1d.wvalid || local_store')
            anchor = 'assume (kind < 3);'
            if text.count(anchor) != 1:
                raise RuntimeError('Cannot locate negative-control schedule constraint')
            text = text.replace(anchor, anchor + '\n'
                                '    assume (load_start == 0 && store_start == 1 && ptw_start == 0);\n'
                                '    assume (kind == 1 && relation == 0);')
            pack.write_text(text)
        config = case_dir / 'check.sby'
        engine = 'abc pdr' if args.mode == 'prove' else 'abc bmc3'
        if args.mode == 'cover' or args.negative_control:
            engine = 'smtbmc --unroll bitwuzla'
        config.write_text(f'''[options]
mode {args.mode}
depth 40
timeout {args.timeout}

[engines]
{engine}

[script]
plugin -i slang
read_slang --single-unit --top formal_memory_progress design.sv
prep -top formal_memory_progress

[files]
design.sv
''')
        command = [str(root / 'verify/formal/sby'), '-f', str(config.name)]
        with (case_dir / 'run.log').open('w') as stream:
            run = subprocess.run(command, cwd=case_dir, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, timeout=args.timeout + 60)
        status_file = case_dir / 'check/status'
        status = status_file.read_text().split()[0] if status_file.exists() else 'ERROR'
        log = (case_dir / 'run.log').read_text()
        # SBY truncates the terminal summary after a few witness traces.
        # PASS contains the complete list, needed to reject vacuous covers.
        full_summary = case_dir / 'check/PASS'
        if full_summary.exists():
            log += '\n' + full_summary.read_text()
        passed = status == 'PASS' and run.returncode == 0
        if args.mode == 'cover':
            witnesses = set(re.findall(r'reached cover statement formal_memory_progress\.(\w+)', log))
            passed &= witnesses >= {'collision', 'owned_collision', 'same_line', 'pte_alias',
                                    'finished', 'escaped_collision', 'escaped_owned_collision'}
        if args.negative_control:
            passed = status == 'FAIL' and run.returncode != 0 and bool(re.search(
                r'Assert failed.*(?:load|store|ptw)_progress', log))
        result['cases'].append({'xlen': width, 'mode': args.mode, 'status': status,
                                'exit': run.returncode, 'accepted': passed,
                                'pack_sha256': hashlib.sha256(pack.read_bytes()).hexdigest()})
        save()
        print(f'{"PASS" if passed else "FAIL"}: RV{width} {args.mode}, solver={status}', flush=True)
        if not passed:
            return 1
    if hashes() != result['source_sha256']:
        raise RuntimeError('Sources changed during verification')
    result['complete'] = True
    save()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
