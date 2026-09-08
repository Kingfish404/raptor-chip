#!/usr/bin/env python3
"""Test actual STA constraint failure and stale-report invalidation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'verify/build/sta-constraint-check')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = out/'results.json'
    result = {'complete':False, 'cases':[]}
    report.write_text(json.dumps(result)+'\n')
    sta = ROOT/'third_party/yosys-opensta/third_party/OpenSTA/build/sta'
    lib = ROOT/'third_party/yosys-opensta/third_party/lib/nangate45/lib/merged.lib'
    fixture = ROOT/'verify/formal/sta_clock_fixture.v'
    script = ROOT/'lspd/syn/scripts/run_sta.tcl'
    paths = [sta,lib,fixture,script,script.with_name('sta.tcl'),Path(__file__).resolve()]
    def manifest():
        return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    result['source_sha256'] = manifest()
    report.write_text(json.dumps(result,indent=2)+'\n')
    for label in ('good','missing'):
        top = f'sta_clock_{label}'
        dest = out/label
        dest.mkdir(exist_ok=True)
        summary = dest/f'{top}.sta_summary.rpt'
        summary.write_text('status ok\nwns_ns 9.0\n')
        env = dict(os.environ,STA_TOP=top,STA_NETLIST=str(fixture),STA_LIB_FILES=str(lib),
                   STA_OUT=str(dest),STA_CLK='clock',STA_PERIOD='10',STA_IO_DELAY_FRAC='0.2',
                   STA_OUTPUT_LOAD_FF='5')
        run = subprocess.run([str(sta),'-exit',str(script)],env=env,text=True,
                             stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        (dest/'sta.log').write_text(run.stdout)
        if label=='good':
            if run.returncode or 'status ok' not in summary.read_text():
                raise RuntimeError('valid clock fixture failed')
            text = summary.read_text()
            if 'timing_schema 2' not in text or 'fmax_mhz' in text or 'period_min_ns' in text:
                raise RuntimeError('STA timing schema still reports global-slack Fmax')
            # This fixture has only input->register and register->output paths.
            if 'reg_setup_budget_ns' in text:
                raise RuntimeError('invented register-to-register path metric')
        else:
            if not (run.returncode>0 and 'STA constraint coverage check failed' in run.stdout
                    and summary.read_text()=='status incomplete\n'):
                raise RuntimeError('unconstrained clock not rejected or stale success survived')
        if manifest()!=result['source_sha256']:
            raise RuntimeError('STA check inputs changed')
        result['cases'].append({'name':label,'returncode':run.returncode})
        report.write_text(json.dumps(result,indent=2)+'\n')
        print('PASS STA fixture',label,flush=True)
    result['complete']=True
    report.write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':
    main()
