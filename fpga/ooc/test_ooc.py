"""Test export wiring and checkpoint invalidation; fake Vivado is not a PPA test."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
BLOCKS = ('rapt_frontend', 'rapt_backend', 'rapt_l1i', 'rapt_l1d')


def run(*args, check=True):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True,
                          text=True, check=check)


class ExportTest(unittest.TestCase):
    @unittest.skipUnless(os.getenv('RAPT_OOC_VIVADO_TEST') == '1', 'opt-in Vivado constraints test')
    def test_real_vivado_constraints_and_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            frozen_script = root / 'synth.tcl'
            frozen_script.write_bytes((HERE / 'synth.tcl').read_bytes())
            (root / 'partitions.sv').write_text('\n'.join(
                f'module {name}_ooc(input clock, input [7:0] data_i, '
                'output reg [7:0] data_o); always @(posedge clock) data_o <= data_i; endmodule'
                for name in BLOCKS))
            (root / 'blackboxes.sv').write_text('\n'.join(
                f'(* black_box *) module {name}_ooc(input clock, input [7:0] data_i, '
                'output [7:0] data_o); endmodule' for name in BLOCKS) +
                '\nmodule rapt(input clock,input [7:0] data_i,output [7:0] data_o); '
                'wire [7:0] a,b,c;\n' + '\n'.join(
                    f'{name}_ooc u{i}(clock,{("data_i", "a", "b", "c")[i]},'
                    f'{("a", "b", "c", "data_o")[i]});' for i, name in enumerate(BLOCKS)) +
                '\nendmodule\n')
            for name in (*BLOCKS, 'merge'):
                result = subprocess.run(['vivado', '-mode', 'batch', '-source', str(frozen_script),
                                         '-tclargs', name, 'xcku15p-ffva1156-2-e', '20', '0'],
                                        cwd=root, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout[-4000:] + result.stderr[-1000:])
                self.assertNotIn('CRITICAL WARNING:', result.stdout)
                timing = (root / f'{name}_timing.rpt').read_text()
                self.assertIn('20.000', timing)
                self.assertIn('0 input ports with no input delay', timing)
                self.assertIn('0 ports with no output delay', timing)
                self.assertTrue((root / f'{name}.dcp').exists())

    @unittest.skipUnless(shutil.which('verilator'), 'needs Verilator')
    def test_array_order_and_independent_dependency_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pack = root / 'pack.sv'
            source = '''// A fixture for synthesis adapter tests; this is an ordinary comment.
interface data_if;
logic [7:0] payload[2]; logic ready[2];
modport master(output payload, input ready);
modport slave(input payload, output ready);
endinterface
module rapt_core #(parameter int XLEN = 32) (input clock); endmodule
'''
            for name in BLOCKS:
                interface = ('data_if.master data,' if name == 'rapt_frontend' else
                             'data_if.slave data,' if name == 'rapt_backend' else '')
                body = ("assign data.payload[0]=8'h12; assign data.payload[1]=8'hab;" if name == 'rapt_frontend' else
                        'assign data.ready[0]=1; assign data.ready[1]=0;' if name == 'rapt_backend' else '')
                parameters = ('parameter int XLEN = 32, parameter bit WriteBack = 1\'b0'
                              if name == 'rapt_l1d' else 'parameter int XLEN = 32')
                source += f'''module {name} #({parameters}) (
input logic clock, {interface} output logic empty_o);
{body}
assign empty_o = 1'b0;
endmodule
'''
            pack.write_text(source)
            output = root / 'out'
            run(HERE / 'export.py', pack, output)
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(manifest['widths']['rapt_frontend__data__payload'], [16, 2])
            self.assertEqual(manifest['blocks']['rapt_l1d']['parameters']['WriteBack'], 0)
            overridden = root / 'overridden'
            run(HERE / 'export.py', '--parameter', 'rapt_l1d.WriteBack=1', pack, overridden)
            overridden_manifest = json.loads((overridden / 'manifest.json').read_text())
            self.assertEqual(overridden_manifest['blocks']['rapt_l1d']['parameters']['WriteBack'], 1)
            self.assertIn('rapt_l1d_impl #(.WriteBack(1)) impl',
                          (overridden / 'partitions.sv').read_text())
            self.assertIn('if (WriteBack != 1)', (overridden / 'blackboxes.sv').read_text())
            tb = '''module adapter_test;
wire [15:0] payload; wire empty;
rapt_frontend_ooc dut(.clock(1'b0),.data__ready(2'b01),.data__payload(payload),.empty_o(empty));
initial begin #1; assert(payload == 16'hab12) else $fatal; $finish; end
endmodule
'''
            (output / 'tb.sv').write_text(tb)
            subprocess.run(['verilator', '--binary', '--timing', '--assert', '-Wno-fatal',
                            '--top-module', 'adapter_test', '--Mdir', str(output / 'obj_test'),
                            str(output / 'partitions.sv'), str(output / 'tb.sv')],
                           capture_output=True, check=True)
            subprocess.run([str(output / 'obj_test/Vadapter_test')], capture_output=True, check=True)
            source = source.replace('assign data.ready[0]=1', 'assign data.ready[0]=0')
            pack.write_text(source)
            run(HERE / 'export.py', pack, output)
            changed = json.loads((output / 'manifest.json').read_text())
            for name in BLOCKS:
                before = manifest['blocks'][name]['source_sha256']
                after = changed['blocks'][name]['source_sha256']
                self.assertEqual(before == after, name != 'rapt_backend')

            invalid = run(HERE / 'export.py', '--parameter', 'rapt_l1d.Unknown=1',
                          pack, root / 'invalid', check=False)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn('Unknown parameter override', invalid.stderr)

    def test_synthesis_comment_pragmas_cannot_hide_from_dependency_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pack = root / 'pack.sv'
            pack.write_text('// synthesis translate_off\nmodule ignored; endmodule\n')
            result = run(HERE / 'export.py', pack, root / 'out', check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unsupported synthesis comment pragma', result.stderr)
            self.assertFalse((root / 'out/manifest.json').exists())

    def test_stale_checkpoints_and_tampered_export_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'partitions.sv'
            source.write_text('fixture')
            manifest = {'blocks': {name: {'source_sha256': name} for name in BLOCKS},
                        'top_sha256': 'top',
                        'artifacts': {'partitions.sv': hashlib.sha256(b'fixture').hexdigest()}}
            (root / 'manifest.json').write_text(json.dumps(manifest))
            fake = root / 'vivado'
            fake.write_text(f'#!{sys.executable}\n' + '''import sys
from pathlib import Path
if '-version' in sys.argv:
 print('test-double-v1')
else:
 name=sys.argv[sys.argv.index('-tclargs')+1]
 Path(name+'.dcp').write_text(name)
''')
            fake.chmod(0o755)
            base = [HERE / 'build.py', root, '--vivado', fake]
            run(*base)
            reused = run(*base)
            self.assertEqual(reused.stdout.count('REUSE'), 4)
            run(*base, '--merge')
            run(*base, '--no-timing-driven')
            reused_fast = run(*base, '--no-timing-driven')
            self.assertEqual(reused_fast.stdout.count('REUSE'), 4)
            self.assertNotEqual(run(*base, '--merge', check=False).returncode, 0)
            run(*base, '--no-timing-driven', '--merge')
            run(*base)  # Restore the default synthesis mode for the remaining checks.
            manifest['blocks']['rapt_backend']['source_sha256'] = 'changed'
            (root / 'manifest.json').write_text(json.dumps(manifest))
            stale = run(*base, '--merge', check=False)
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn('rebuild: rapt_backend', stale.stderr)
            run(*base, '--block', 'rapt_backend', '--merge')
            (root / 'rapt_frontend.dcp').write_text('tampered')
            self.assertNotEqual(run(*base, '--merge', check=False).returncode, 0)
            source.write_text('tampered')
            changed = run(*base, check=False)
            self.assertNotEqual(changed.returncode, 0)
            self.assertIn('Changed exported file', changed.stderr)


if __name__ == '__main__':
    unittest.main()
