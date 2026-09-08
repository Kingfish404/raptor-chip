#!/usr/bin/env python3
"""Reject corrupted acceptance evidence in isolated copies of completed runs."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
BUILD=ROOT/'verify/build/vpu'
TARGET='core-top-32-128-32-64-1-opt1-spike'
CHECKER=ROOT/'verify/vpu/check_acceptance.py'


def main():
    subprocess.run([sys.executable,str(CHECKER)],cwd=ROOT,check=True)
    for mutation in ('stale_source','truncated_run','wrong_reference',
                     'wrong_vlen','wrong_bank_bits'):
        with tempfile.TemporaryDirectory(prefix='vpu-acceptance-',dir='/tmp') as temp:
            directory=Path(temp)
            # Other evidence is read through symlinks; only this isolated
            # candidate and the aggregate report are ever written.
            for name in ('formal-owner','formal-core-adapter','formal-memory-isolation',
                         'alu-optimization','fpga-map-alu-opt'):
                (directory/name).symlink_to(BUILD/name,target_is_directory=True)
            for original in BUILD.glob('core-top-*'):
                if original.name!=TARGET:
                    (directory/original.name).symlink_to(original,target_is_directory=True)
            candidate=directory/TARGET;candidate.mkdir()
            for name in ('sources.json','reference.json','run.log'):
                shutil.copyfile(BUILD/TARGET/name,candidate/name)
            if mutation=='truncated_run':
                (candidate/'run.log').write_text('PASS partial instruction family\n')
            else:
                path=candidate/('reference.json' if mutation=='wrong_reference' else 'sources.json')
                data=json.loads(path.read_text())
                if mutation=='stale_source':data['sources']['hdl/backend/vpu/rapt_vpu.sv']='0'*64
                elif mutation=='wrong_reference':data['revision']='0'*40
                elif mutation=='wrong_vlen':data['configuration']['VLEN']=256
                else:data['configuration']['BankBits']=128
                path.write_text(json.dumps(data))
            process=subprocess.run([sys.executable,str(CHECKER),'--build-dir',str(directory)],
                                   cwd=ROOT,capture_output=True,text=True)
            report=json.loads((directory/'acceptance.json').read_text())
            failures=[r['gate'] for r in report['gates'] if r['status']=='FAIL']
            if process.returncode!=1 or report['passed'] or failures!=['32-full']:
                raise RuntimeError(f'Failed to isolate/reject {mutation}: {process.stdout}')
            print('PASS rejected',mutation)


if __name__=='__main__':
    main()
