#!/usr/bin/env python3
"""Export a relocatable standalone VPU RTL source bundle, without publishing."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
FMA_WAIVER = """`verilator_config
// Existing shared scalar FMA uses implicit width conversions and unused stage
// fields. Keep these waivers confined to that file; the VPU stays strict.
lint_off -rule WIDTH -file "*/rapt_fpu_fma.sv"
lint_off -rule UNUSEDSIGNAL -file "*/rapt_fpu_fma.sv"
lint_off -rule DECLFILENAME -file "*/rapt_fpu_fma.sv"
"""


def write_fma_waiver(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(FMA_WAIVER)


def export(destination):
    # Refuse existing directories so repeated exports cannot overwrite edits.
    destination.mkdir(parents=True,exist_ok=False)
    rtl=[ROOT/'rtl/rapt_pkg.sv', ROOT/'rtl/sram/rapt_sram_1rw.sv']+[
        ROOT/f'rtl/core/backend/fpu/rapt_fpu_{name}.sv'
        for name in ('fma','divsqrt','convert_narrow','int_to_fp','integer_to_fp',
                     'single_to_int_w','fp_to_int')]
    rtl+=sorted((ROOT/'rtl/core/backend/vpu').glob('*.sv'))
    headers = sorted((ROOT/'rtl/include').glob('*.svh'))
    headers += [ROOT/'rtl/configs/default/rapt_config.svh']
    files=rtl+headers+[ROOT/'LICENSE']
    sources={}
    for source in files:
        relative=source.relative_to(ROOT);data=source.read_bytes()
        target=destination/relative;target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(data)
        sources[str(relative)]=hashlib.sha256(data).hexdigest()
    write_fma_waiver(destination/'verification/vpu/fma_legacy.vlt')
    (destination/'sources.f').write_text('+incdir+rtl/include\n+incdir+rtl/configs/default\n'+
        '\n'.join(str(p.relative_to(ROOT)) for p in rtl)+'\n')
    (destination/'README.md').write_text('''# Standalone VPU RTL bundle

Run tools from this directory; `sources.f` contains relative paths only.
Numerical top: `rapt_vpu`. Core ownership/metadata wrapper: `rapt_vpu_core`.
XLEN, VLEN, ELEN, BankBits and Banks are independent top parameters.

Example elaboration/lint (requires Verilator):

```sh
verilator --lint-only --assert -Wall -DRAPT_ASSERT_EN \\
  verification/vpu/fma_legacy.vlt -f sources.f --top-module rapt_vpu_core
```

The narrow existing scalar FMA warning waivers are retained. This bundle uses
the behavioral SRAM implementation; technology-specific SRAM macros and their
libraries are not included. The shared scalar package and default preset define
the SRAM control type; no scalar core modules, LSU/MMU, Spike, firmware, or board
files are needed for the default elaboration.

The core must resolve scalar operands and retain command identity/metadata.
Effects require matching irrevocable ROB-head authorization, including older
memory ordering. External transactions must drain before identity reuse;
reset does not flush an external fabric. Store completion must be final with
respect to faults. Scalar ROB/CSR/LSU wiring remains the integrator's task.

Source hashes identify this export, not ISA certification or physical timing.
See LICENSE for the repository license.
''')
    generated={name:hashlib.sha256((destination/name).read_bytes()).hexdigest()
               for name in ('sources.f','README.md','verification/vpu/fma_legacy.vlt')}
    result=dict(sources=sources,generated=generated,
                exporter_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                scope='Standalone RTL and behavioral SRAM; no physical macros or scalar core integration')
    (destination/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination',type=Path,nargs='?')
    parser.add_argument('--write-fma-waiver',type=Path)
    args=parser.parse_args()
    if args.write_fma_waiver is not None:
        if args.destination is not None:
            parser.error('choose either destination or --write-fma-waiver')
        write_fma_waiver(args.write_fma_waiver)
    else:
        if args.destination is None:
            parser.error('destination is required')
        result=export(args.destination.resolve())
        print('Exported',len(result['sources']),'files to',args.destination)
