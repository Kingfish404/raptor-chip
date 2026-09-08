#!/usr/bin/env python3
"""Exercise the actual synthesis Tcl flow with a valid and missing-driver top."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'verify/build/synthesis-driver-check')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = out/'results.json'
    result = {'complete': False, 'cases': []}
    report.write_text(json.dumps(result)+'\n')
    fixture = ROOT/'verify/formal/synthesis_driver_fixture.sv'
    script = ROOT/'lspd/syn/scripts/synth.tcl'
    platform = ROOT/'third_party/yosys-opensta/platforms/nangate45'
    foundry = ROOT/'third_party/yosys-opensta/third_party/lib/nangate45'
    inputs = [fixture, script, platform/'yosys_config.tcl', foundry/'lib/merged.lib',
              foundry/'verilog/cells_latch.v', Path(__file__).resolve()]
    def manifest():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    result['source_sha256'] = manifest()
    result['yosys_version'] = subprocess.check_output(['yosys','-V'],text=True).strip()
    report.write_text(json.dumps(result,indent=2)+'\n')
    for label in ('good','missing'):
        top = f'synthesis_driver_{label}'
        dest = out/label
        dest.mkdir(exist_ok=True)
        env = dict(os.environ, YS_TOP=top, YS_OUT=str(dest), YS_FOUNDRY_PATH=str(foundry),
                   YS_PLATFORM_DIR=str(platform), YS_PERIOD_NS='10', YS_SRAM_LIB_FILES='',
                   YS_SLANG_FLAGS='--single-unit -DSYNTHESIS', YS_SV_FILES=str(fixture))
        command = ['yosys','-Q','-T','-m','slang','-p',f'tcl {script}']
        run = subprocess.run(command,env=env,text=True,stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT,timeout=120)
        (dest/'run.log').write_text(run.stdout)
        if manifest() != result['source_sha256']:
            raise RuntimeError('synthesis driver check inputs changed')
        if label == 'good':
            if run.returncode or not (dest/f'{top}.netlist.v').is_file():
                raise RuntimeError('valid fixture failed synthesis')
        else:
            if not (run.returncode > 0 and 'is used but has no driver' in run.stdout
                    and re.search(r"ERROR: Found \d+ problems in 'check -assert'", run.stdout)):
                raise RuntimeError('missing driver not rejected by structural check')
            # Verify rejection precedes the normalization that formerly hid it.
            if 'Executing SETUNDEF pass' in run.stdout or 'Executing SYNTH pass' in run.stdout:
                raise RuntimeError('missing driver was not rejected before synthesis')
        result['cases'].append({'name':label,'returncode':run.returncode,
                                'expected_outcome': 'mapped' if label=='good' else 'rejected before synthesis'})
        report.write_text(json.dumps(result,indent=2)+'\n')
        print(f'PASS {label}: {result["cases"][-1]["expected_outcome"]}',flush=True)
    result['complete'] = True
    report.write_text(json.dumps(result,indent=2)+'\n')


if __name__ == '__main__':
    main()
