#!/usr/bin/env python3
"""Verify exported RTL elaborates after relocation, with dependency failures fatal."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from export_rtl import ROOT, export


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output=ROOT/'verify/build/vpu/export-rtl';output.mkdir(parents=True,exist_ok=True)
    scripts={name:digest(ROOT/name) for name in
             ('verify/vpu/export_rtl.py','verify/vpu/test_export_rtl.py')}
    results=[]
    with tempfile.TemporaryDirectory(prefix='vpu-export-',dir='/tmp') as temp:
        base=Path(temp);initial=base/'original';manifest=export(initial)
        directory=base/'relocated bundle';initial.rename(directory)
        for name,h in {**manifest['sources'],**manifest['generated']}.items():
            assert digest(directory/name)==h
        marker=directory/'user-file';marker.write_text('preserve me\n')
        try:export(directory)
        except FileExistsError:pass
        else:raise RuntimeError('Export overwrote existing directory')
        assert marker.read_text()=='preserve me\n'
        command=['verilator','--lint-only','--assert','-Wall','-DRAPT_ASSERT_EN',
                 'verify/vpu/fma_legacy.vlt','-f','sources.f']
        for top in ('rapt_vpu','rapt_vpu_core'):
            for x,v,e,bb,b in ((32,128,32,64,1),(64,128,64,64,2),
                               (32,256,64,64,4),(64,512,64,128,4)):
                config=dict(XLEN=x,VLEN=v,ELEN=e,BankBits=bb,Banks=b)
                argv=command+['--top-module',top]+[f'-G{k}={value}' for k,value in config.items()]
                log=output/f'{top}-{x}-{v}-{e}-{bb}-{b}.log'
                with log.open('w') as stream:
                    subprocess.run(argv,cwd=directory,stdout=stream,stderr=subprocess.STDOUT,check=True)
                results.append(dict(top=top,configuration=config,command=argv,log_sha256=digest(log)))
                print('PASS relocated RTL',top,config,flush=True)
        # Missing shared include must fail, not silently elaborate a blackbox.
        (directory/'hdl/include/rapt_fp_ops.svh').unlink()
        result=subprocess.run(command+['--top-module','rapt_vpu_core'],cwd=directory,
                              capture_output=True,text=True)
        if result.returncode==0 or 'rapt_fp_ops.svh' not in result.stderr:
            raise RuntimeError('Missing include did not fail as expected')
        print('PASS rejected missing dependency and existing destination')
    sources=dict(manifest['sources'])
    sources.update(scripts)
    assert all(digest(ROOT/name)==h for name,h in sources.items())
    (output/'summary.json').write_text(json.dumps(dict(sources=sources,
        verilator=subprocess.check_output(['verilator','--version'],text=True).strip(),
        elaborations=results,missing_dependency_rejected=True,existing_destination_preserved=True,
        scope='Relocated RTL lint/elaboration with behavioral SRAM; not functional simulation or physical implementation'),indent=2)+'\n')


if __name__=='__main__':main()
