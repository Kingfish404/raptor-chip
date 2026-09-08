"""Run a named dual-XLEN proof with its own contract and evidence scope."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


CONTRACTS = {
    'pma-capabilities': dict(
        description='Prove the platform storage-region capability contract for all addresses.',
        top='formal_pma_capabilities', source='hdl/rapt_pkg.sv', option='package',
        option_help='Optional isolated package under test',
        scope='All-address storage PMA capability logic; no bus/coherence/progress claim',
        label='storage PMA capability proof'),
    'pma-span': dict(
        description='Prove scalar PMA span checks equivalent to bytewise address decoding.',
        top='formal_pma_span', source='hdl/rapt_pkg.sv', option='package',
        option_help='Optional isolated package under test',
        scope='All addresses, transfer sizes and read/write modes; exact first-fault offset',
        label='bytewise PMA span equivalence'),
    'ifetch-word-atomic': dict(
        description='Prove aligned instruction-word assembly integrity under arbitrary backpressure.',
        top='formal_ifetch_word_atomic', source='hdl/memory/rapt_ifetch_word.sv', option='rtl',
        option_help='Optional isolated instruction-word module under test',
        scope='Aligned word assembly safety; reset state and explicit responder protocol; no bus/cache/fairness claim',
        label='aligned instruction-word integrity proof',
        proof='sat -verify -tempinduct -seq 8 -maxsteps 32 -set-init-zero -set-def-inputs -prove mismatch 0 -show-inputs -show-outputs',
        success='Induction step proven: SUCCESS!', timeout=180),
}


def add_options(parser, option, option_help):
    parser.add_argument('--source-root', type=Path,
                        default=Path(__file__).resolve().parents[2])
    parser.add_argument('--' + option, type=Path, help=option_help)
    parser.add_argument('--output', type=Path, required=True)


def run_contract(*, description, top, source, option, option_help, scope, label,
                 proof='sat -verify -prove mismatch 0 -set-def-inputs -show-inputs -show-outputs',
                 success='SAT proof finished - no model found: SUCCESS!', timeout=120,
                 argv=None):
    parser = argparse.ArgumentParser(description=description)
    add_options(parser, option, option_help)
    args = parser.parse_args(argv)
    root = args.source_root.resolve()
    dut = (getattr(args, option) or root / source).resolve()
    harness = root / 'verify/formal' / (top + '.sv')
    files = [dut, harness]
    files += sorted((root / 'hdl/include').rglob('*.svh'))
    files += sorted((root / 'hdl/configs/default').rglob('*.svh'))
    for path in files:
        if any(char.isspace() or char in ';"' for char in str(path)):
            raise ValueError(f'Unsupported Yosys source path: {path}')
    def hashes():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = {'complete': False, 'source_sha256': hashes(), 'cases': [],
              'scope': scope}
    report = output / 'results.json'
    report.write_text(json.dumps(result, indent=2) + '\n')
    for xlen in (32, 64):
        commands = [
            f'read_slang --single-unit -DSYNTHESIS {"-DRAPT_RV64" if xlen == 64 else ""} '
            f'-I{root}/hdl/include -I{root}/hdl/configs/default '
            f'--top {top} {dut} {harness}',
            'select -assert-none t:$check t:$assert t:$assume t:$cover',
            f'prep -top {top} -flatten', 'opt',
            proof]
        script = output / f'rv{xlen}.ys'
        script.write_text(';\n'.join(commands) + '\n')
        command = ['yosys', '-Q', '-T', '-m', 'slang', '-s', str(script)]
        log = output / f'rv{xlen}.log'
        with log.open('w') as stream:
            run = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        proved = run.returncode == 0 and success in log.read_text()
        result['cases'].append({'xlen': xlen, 'command': command,
                                'exit': run.returncode, 'proved': proved})
        report.write_text(json.dumps(result, indent=2) + '\n')
        print(f'{"PASS" if proved else "FAIL"}: RV{xlen} {label}', flush=True)
        if not proved:
            return 1
    if hashes() != result['source_sha256']:
        raise RuntimeError('Sources changed during proof')
    result['complete'] = True
    report.write_text(json.dumps(result, indent=2) + '\n')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='contract', required=True)
    for name, config in CONTRACTS.items():
        command = commands.add_parser(name, description=config['description'])
        add_options(command, config['option'], config['option_help'])
    args = parser.parse_args(argv)
    config = CONTRACTS[args.contract]
    options = ['--source-root', str(args.source_root), '--output', str(args.output)]
    override = getattr(args, config['option'])
    if override is not None:
        options += ['--' + config['option'], str(override)]
    return run_contract(**config, argv=options)


if __name__ == '__main__':
    raise SystemExit(main())
