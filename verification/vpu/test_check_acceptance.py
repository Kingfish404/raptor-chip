#!/usr/bin/env python3
"""Reject corrupted acceptance evidence in isolated copies of completed runs."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
BUILD=ROOT/'verification/build/vpu'
TARGET='core-top-32-128-32-64-1-opt1-spike'
ELEN64_TARGET='core-top-32-128-64-64-2-opt1-spike'
CHECKER=ROOT/'verification/vpu/check_acceptance.py'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path,default=BUILD)
    build=parser.parse_args().build_dir.resolve()
    subprocess.run([sys.executable,str(CHECKER),'--build-dir',str(build)],cwd=ROOT,check=True)
    mutations=[(name,TARGET,'32-full') for name in
               ('stale_source','truncated_run','wrong_reference','wrong_vlen','wrong_bank_bits')]
    mutations.extend((('wrong_elen',ELEN64_TARGET,'32-elen64-full'),
                      ('truncated_run',ELEN64_TARGET+'-geometry-overlap',
                       '32-elen64-geometry-overlap')))
    for mutation,target,expected_gate in mutations:
        with tempfile.TemporaryDirectory(prefix='vpu-acceptance-',dir='/tmp') as temp:
            directory=Path(temp)
            # Other evidence is read through symlinks; only this isolated
            # candidate and the aggregate report are ever written.
            for name in ('formal-owner','formal-core-adapter','formal-memory-isolation',
                         'alu-optimization','fpga-map-alu-opt'):
                (directory/name).symlink_to(build/name,target_is_directory=True)
            for original in build.glob('core-top-*'):
                if original.name!=target:
                    (directory/original.name).symlink_to(original,target_is_directory=True)
            candidate=directory/target;candidate.mkdir()
            for name in ('sources.json','reference.json','run.log'):
                shutil.copyfile(build/target/name,candidate/name)
            if mutation=='truncated_run':
                (candidate/'run.log').write_text('PASS partial instruction family\n')
            else:
                path=candidate/('reference.json' if mutation=='wrong_reference' else 'sources.json')
                data=json.loads(path.read_text())
                if mutation=='stale_source':data['sources']['rtl/core/backend/vpu/rapt_vpu.sv']='0'*64
                elif mutation=='wrong_reference':data['revision']='0'*40
                elif mutation=='wrong_vlen':data['configuration']['VLEN']=256
                elif mutation=='wrong_elen':data['configuration']['ELEN']=32
                else:data['configuration']['BankBits']=128
                path.write_text(json.dumps(data))
            process=subprocess.run([sys.executable,str(CHECKER),'--build-dir',str(directory)],
                                   cwd=ROOT,capture_output=True,text=True)
            report=json.loads((directory/'acceptance.json').read_text())
            failures=[r['gate'] for r in report['gates'] if r['status']=='FAIL']
            if process.returncode!=1 or report['passed'] or failures!=[expected_gate]:
                raise RuntimeError(f'Failed to isolate/reject {mutation}: {process.stdout}')
            print('PASS rejected',mutation)


if __name__=='__main__':
    main()
