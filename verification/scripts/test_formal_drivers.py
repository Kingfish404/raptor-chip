#!/usr/bin/env python3
"""Check formal drivers: proof answers, ABC compatibility, abstraction and model audits, scope."""
import copy
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from alu_contract import snapshot_result
from formal_scope import (
    apply_contract_review,
    audit_receipt,
    binding_key,
    canonical_rtlil,
    inventory,
    required_contracts,
    sha,
)
from ioq_contract import (
    PREFIX,
    TOP,
    activation_witnesses,
    audit_extension,
    audit_frontend,
    augment,
    canonical_model,
    compile_case,
)
from prf_formal import (
    FORMAL,
    audit_frontend as audit_prf_frontend,
    audit_model,
    byte_lemma,
    history_harness,
    partition_history,
    run_composed,
)
from rou_contract import audit_abstraction, select_control_state
from yosys_common import ROOT, run_bounded


class SnapshotOutputTests(unittest.TestCase):
    def test_answer_with_or_without_standard_progress(self):
        for answer in ('sat', 'unsat'):
            for prefix in ('', '##   0:01:00  waiting for solver (1 minute)\n',
                           '##   0:05:00  waiting for solver (5 minutes)\n'
                           '##   1:00:00  waiting for solver (1 hour)\n'):
                with self.subTest(answer=answer, prefix=prefix):
                    self.assertEqual(snapshot_result(prefix + answer + '\n'), answer)

    def test_unknown_conflicting_missing_and_diagnostic_answers_rejected(self):
        for text in ('', 'unknown\n', 'sat\nunsat\n', 'unsat\nsat\n',
                     'ERROR\nunsat\n', 'unsat\nextra\n',
                     '##   0:01:00  waiting for solver (1 minute)\n'):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    snapshot_result(text)


WRAPPER = Path(__file__).resolve().parents[1] / "formal/abc-read-blif-compat.sh"


class AbcCompatibilityTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="raptor-abc-wrapper-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.capture = self.root / "capture.json"
        self.fake = self.root / "abc"
        self.fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
result = {'args': args}
if '-f' in args:
    path = Path(args[args.index('-f') + 1])
    result.update(path=str(path), script=path.read_text())
Path(os.environ['ABC_CAPTURE']).write_text(json.dumps(result))
sys.exit(int(os.environ.get('ABC_EXIT', '0')))
""")
        self.fake.chmod(0o755)
        self.script = self.root / "commands.abc"
        self.original = 'echo + read_blif input.blif;\nread_blif input.blif;\nprint_stats;\n'
        self.script.write_text(self.original)

    def run_wrapper(self, parser=None, args=None, exit_code=0):
        env = dict(os.environ, RAPTOR_ABC_REAL=str(self.fake), ABC_CAPTURE=str(self.capture),
                   ABC_EXIT=str(exit_code), TMPDIR=str(self.root))
        env.pop("RAPTOR_ABC_BLIF_PARSER", None)
        if parser is not None:
            env["RAPTOR_ABC_BLIF_PARSER"] = parser
        return subprocess.run([str(WRAPPER), *(args or ["-s", "-f", str(self.script)])],
                              env=env, capture_output=True, text=True, timeout=10)

    def test_default_preserves_native_parser_and_arguments(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(self.capture.read_text())
        self.assertEqual(captured["args"], ["-s", "-f", str(self.script)])
        self.assertEqual(captured["script"], self.original)

    def test_legacy_rewrites_only_real_command_and_cleans_temporary_file(self):
        result = self.run_wrapper("legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(self.capture.read_text())
        self.assertEqual(captured["script"], self.original.replace(
            '\nread_blif ', '\nread_blif -n '))
        self.assertFalse(Path(captured["path"]).exists())
        self.assertEqual(self.script.read_text(), self.original)

    def test_legacy_passthrough_without_script(self):
        result = self.run_wrapper("legacy", ["-c", "version"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.capture.read_text())["args"], ["-c", "version"])

    def test_invalid_parser_does_not_invoke_abc(self):
        result = self.run_wrapper("invalid")
        self.assertEqual(result.returncode, 2)
        self.assertIn("must be default or legacy", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_failure_status_is_preserved_and_temporary_file_removed(self):
        result = self.run_wrapper("legacy", exit_code=7)
        self.assertEqual(result.returncode, 7)
        self.assertFalse(Path(json.loads(self.capture.read_text())["path"]).exists())


def fixture():
    def register(bit, source="rtl/backend/rapt_rou.sv:1.1-1.2"):
        return {"type": "$dff", "attributes": {"src": source},
                "parameters": {"WIDTH": "1"},
                "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
                "connections": {"CLK": [10], "D": [11], "Q": [bit]}}

    before = {
        "ports": {"clock": {"direction": "input", "bits": [10]},
                  "data": {"direction": "input", "bits": [11]}},
        "netnames": {
            "clock": {"bits": [10]}, "data": {"bits": [11]},
            "dut_rou.head": {"bits": [1], "attributes": {"init": "0"}},
            "dut_rou.rvfi_mem_result[0]": {"bits": [2]},
            "expected_result[0]": {"bits": [3]}, "monitor": {"bits": [4]},
        },
        "cells": {
            "head_ff": register(1), "payload_ff": register(2),
            "reference_ff": register(3),
            "monitor_ff": register(4, "verification/formal/formal_rou.sv:1.1-1.2"),
            "property": {"type": "$assert", "parameters": {}, "attributes": {},
                         "port_directions": {"A": "input", "EN": "input"},
                         "connections": {"A": [4], "EN": ["1"]}},
        },
    }
    cut, _ = select_control_state(before)
    after = copy.deepcopy(before)
    del after["cells"]["head_ff"]
    after["cells"]["free_state"] = {
        "type": "$anyseq", "parameters": {"WIDTH": "1"}, "attributes": {},
        "port_directions": {"Y": "output"}, "connections": {"Y": [1]},
    }
    # JSON bit numbering may change without changing the graph.
    for objects in (after["netnames"].values(), after["ports"].values()):
        for obj in objects:
            obj["bits"] = [b + 100 if isinstance(b, int) else b for b in obj["bits"]]
    for cell in after["cells"].values():
        for port, bits in cell["connections"].items():
            cell["connections"][port] = [b + 100 if isinstance(b, int) else b for b in bits]
    return before, after, cut


class StateAbstractionAudit(unittest.TestCase):
    def test_only_control_ff_is_cut(self):
        before, after, cut = fixture()
        self.assertEqual([r["name"] for r in cut], ["head_ff"])
        self.assertEqual(audit_abstraction(before, after, cut)["cut_registers"], 1)

    def test_payload_alias_protects_shared_ff(self):
        before, _, _ = fixture()
        before["netnames"]["expected_address[0]"] = {"bits": [1]}
        before["netnames"]["dut_rou.other_state"] = {"bits": [12]}
        before["cells"]["other_ff"] = copy.deepcopy(before["cells"]["head_ff"])
        before["cells"]["other_ff"]["connections"]["Q"] = [12]
        cut, _ = select_control_state(before)
        self.assertEqual([r["name"] for r in cut], ["other_ff"])

    def test_changed_assertion_is_rejected(self):
        before, after, cut = fixture()
        after["cells"]["property"]["connections"]["A"] = ["1"]
        with self.assertRaises(ValueError):
            audit_abstraction(before, after, cut)

    def test_new_assumption_is_rejected(self):
        before, after, cut = fixture()
        after["cells"]["hidden_assumption"] = copy.deepcopy(after["cells"]["property"])
        after["cells"]["hidden_assumption"]["type"] = "$assume"
        with self.assertRaises(ValueError):
            audit_abstraction(before, after, cut)

    def test_wrong_cutpoint_is_rejected(self):
        before, after, cut = fixture()
        after["cells"]["free_state"]["connections"]["Y"] = [102]
        with self.assertRaises(ValueError):
            audit_abstraction(before, after, cut)

    def test_removed_monitor_is_rejected(self):
        before, after, cut = fixture()
        del after["cells"]["monitor_ff"]
        with self.assertRaises(ValueError):
            audit_abstraction(before, after, cut)

    def test_changed_initial_state_is_rejected(self):
        before, after, cut = fixture()
        after["netnames"]["dut_rou.head"]["attributes"]["init"] = "1"
        with self.assertRaises(ValueError):
            audit_abstraction(before, after, cut)

    def test_merged_nets_are_rejected(self):
        before, after, cut = fixture()
        after["netnames"]["expected_result[0]"]["bits"] = [102]
        with self.assertRaises(ValueError):
            audit_abstraction(before, after, cut)


YOSYS = shutil.which(os.environ.get('RAPTOR_YOSYS_REAL', 'yosys'))


class WitnessTests(unittest.TestCase):
    def test_relative_sby_waveform_resolves_to_the_reached_properties(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            trace = root / 'contract_cover/engine_0/trace0.vcd'
            trace.parent.mkdir(parents=True)
            trace.write_text('$timescale 1ns $end\n#0\n')
            log = ('##   0:00:00  Reached cover statement in step 2 at top: first\n'
                   '##   0:00:00  Reached cover statement in step 2 at top: second\n'
                   '##   0:00:00  Writing trace to VCD file: engine_0/trace0.vcd\n')
            self.assertEqual(activation_witnesses(log, root), {
                'top: first': 'contract_cover/engine_0/trace0.vcd',
                'top: second': 'contract_cover/engine_0/trace0.vcd'})
            for broken in (log + log, log.split('Writing trace')[0],
                           log.replace('engine_0/trace0.vcd', '../../escape.vcd')):
                with self.subTest(log=broken), self.assertRaises(ValueError):
                    activation_witnesses(broken, root)
            trace.write_text('')
            with self.assertRaisesRegex(ValueError, 'empty'):
                activation_witnesses(log, root)


@unittest.skipUnless(YOSYS, 'Native Yosys with Slang is required')
class NativeModelTests(unittest.TestCase):
    def test_only_locations_can_change_without_changing_full_model_identity(self):
        variants = [('base', '', '', 'q == a', True, True),
                    ('relocated', '', '', 'q == a', True, True),
                    ('initialized', ' = 0', '', 'q == a', True, True),
                    ('assumed', '', 'always_comb assume (a != 0);', 'q == a', True, True),
                    ('assertion', '', '', 'q == 0', True, True),
                    ('cover', '', '', 'q == a', False, True),
                    ('trigger', '', '', 'q == a', True, False)]
        models = {}
        with tempfile.TemporaryDirectory(prefix='raptor-ioq-json-') as name:
            root = Path(name)
            for identifier, initializer, assumption, assertion, covered, clocked in variants:
                event = 'always_ff @(posedge clock)' if clocked else 'always_comb'
                cover = 'always_comb witness: cover (q != 0);' if covered else ''
                source = root / (identifier + '.sv')
                source.write_text(f'''module fixture(input logic clock, input logic [3:0] a,
    output logic [3:0] q{initializer});
  always_ff @(posedge clock) q <= a;
  {event} contract_check: assert ({assertion});
  {assumption}
  {cover}
endmodule
''')
                output = root / (identifier + '.json')
                read = (f'read_slang --threads 1 --single-unit --top fixture {source}; '
                        f'write_json {output}')
                child = subprocess.run([YOSYS, '-Q', '-T', '-m', 'slang', '-p', read],
                                       capture_output=True, text=True, timeout=30)
                self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
                models[identifier] = canonical_model(json.loads(output.read_text()))
            self.assertEqual(models['base'], models['relocated'])
            self.assertEqual(len(set(models.values())), 6)

    def test_instruction_context_changes_the_actual_native_dispatch_port(self):
        rtl = [ROOT / 'rtl/rapt_pkg.sv']
        rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
        widths = {}
        with tempfile.TemporaryDirectory(prefix='raptor-ioq-metadata-') as name:
            root = Path(name)
            for metadata in ('functional', 'instruction', 'rvfi'):
                case = dict(id=metadata, preset='formal', xlen=32, memory='dff',
                            response_stage=0, lutram=0, synthesis=True, metadata=metadata)
                directory = root / metadata
                result = compile_case(directory, case, rtl, 60, YOSYS)
                self.assertTrue(result['complete'])
                module = json.loads(gzip.decompress(
                    (directory / 'frontend.json.gz').read_bytes()))['modules']['formal_ioq_owner']
                widths[metadata] = len(module['ports']['dispatch']['bits'])
                lanes = result['frontend']['geometry']['dispatch_width']
            self.assertEqual(widths['instruction'] - widths['functional'], 32 * lanes)
            self.assertEqual(widths['rvfi'] - widths['functional'], 64 * lanes)


@unittest.skipUnless(YOSYS, 'Native Yosys with Slang is required')
class ActivationExtensionTests(unittest.TestCase):
    def test_native_extension_preserves_state_and_rejects_changed_guards_or_assumptions(self):
        with tempfile.TemporaryDirectory(prefix='raptor-ioq-activation-') as name:
            root = Path(name)
            rtl = [ROOT / 'rtl/rapt_pkg.sv']
            rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
            case = dict(id='native', preset='formal', xlen=32, memory='dff',
                        response_stage=0, lutram=0, synthesis=True, metadata='functional')
            directory = root / 'model'
            row = compile_case(directory, case, rtl, 60, YOSYS)
            self.assertTrue(row['complete'])
            model = json.loads(gzip.decompress((directory / 'frontend.json.gz').read_bytes()))
            expected_hash = hashlib.sha256(canonical_model(model).encode()).hexdigest()
            before = audit_frontend(model)
            selected = augment(model, expected_hash)
            after = audit_frontend(model)
            self.assertEqual(after['assertions'], before['assertions'])
            self.assertEqual(after['assumptions'], before['assumptions'])
            self.assertEqual(len(selected), 24)
            self.assertEqual(after['covers'], before['covers'] + 24)
            audit_extension(model, expected_hash)
            observer_name = next(n for n in model['modules'][TOP]['cells'] if n.startswith(PREFIX))
            mutations = ('assumption', 'constant_guard', 'changed_clock', 'changed_state')
            for mutation in mutations:
                changed = copy.deepcopy(model)
                module = changed['modules'][TOP]
                observer = module['cells'][observer_name]
                if mutation == 'assumption':
                    observer['parameters']['FLAVOR'] = 'assume'
                elif mutation == 'constant_guard':
                    observer['connections']['A'] = ['1']
                elif mutation == 'changed_clock':
                    observer['parameters']['TRG_ENABLE'] = format(0, '032b')
                else:
                    module['netnames']['past_valid']['attributes']['init'] = '1'
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    audit_extension(changed, expected_hash)


SCRIPTS = Path(__file__).resolve().parent


@unittest.skipUnless(YOSYS, 'Native Yosys with Slang is required')
class StoreCompositionTests(unittest.TestCase):
    def test_full_native_composition_preserves_properties_and_audit_is_read_only(self):
        script = '''
import copy, gzip, json, os
from pathlib import Path
import ioq_contract as runner
rtl = [runner.ROOT / 'rtl/rapt_pkg.sv']
rtl += sorted(p for p in (runner.ROOT / 'rtl').rglob('*.sv') if p not in rtl)
case = dict(id='native', preset='formal', xlen=64, memory='dff', response_stage=0,
            lutram=0, synthesis=True, metadata='functional',
            contract='store' if os.environ['STORE_MODEL'] == '1' else 'owner')
directory = Path(os.environ['MODEL_OUT'])
row = runner.compile_case(directory, case, rtl, 60, os.environ['NATIVE_YOSYS'])
assert row['complete'], row
model = json.loads(gzip.decompress((directory/'frontend.json.gz').read_bytes()))
before = runner.canonical_model(model)
runner.audit_frontend(model)
assert before == runner.canonical_model(model)
if os.environ['STORE_MODEL'] == '1':
    altered = copy.deepcopy(model)
    altered['modules']['formal_ioq_store']['netnames']['clock']['attributes']['init'] = '1'
    try:
        runner.audit_frontend(altered)
    except ValueError:
        pass
    else:
        raise AssertionError('Unexpected initial-state restriction was accepted')
extra = runner.contract_profile(case['contract'])['extra_sources']
summary = dict(frontend=row['frontend'], extra=list(map(str, extra)),
               harness=str(runner.contract_profile(case['contract'])['harness']))
print(json.dumps(summary))
'''
        results = []
        with tempfile.TemporaryDirectory(prefix='raptor-store-native-') as temp:
            for store in ('0', '1'):
                env = dict(os.environ, PYTHONPATH=str(SCRIPTS), STORE_MODEL=store,
                           MODEL_OUT=str(Path(temp) / store), NATIVE_YOSYS=YOSYS)
                child = subprocess.run([sys.executable, '-c', script], env=env,
                                       capture_output=True, text=True, timeout=90)
                self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
                results.append(json.loads(child.stdout))
        base, store = results
        self.assertEqual(base['frontend']['geometry'], store['frontend']['geometry'])
        self.assertEqual(store['frontend']['assumptions'], 1)
        self.assertGreater(store['frontend']['assertions'], base['frontend']['assertions'])
        self.assertGreater(store['frontend']['covers'], base['frontend']['covers'])
        self.assertEqual(store['extra'], [])
        self.assertEqual(store['harness'], base['harness'])


SMTBMC = ROOT / 'third_party/oss-cad-suite/bin/yosys-smtbmc'


class ToolTimeoutTest(unittest.TestCase):
    def test_timeout_allows_controller_to_clean_separate_engine_groups(self):
        with tempfile.TemporaryDirectory(prefix='raptor-engine-timeout-') as name:
            pid_file = Path(name) / 'engine.pid'
            program = '''import os, pathlib, signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'],
                         start_new_session=True)
def stop(signum, frame):
    os.killpg(child.pid, signal.SIGTERM)
    child.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
time.sleep(30)
'''
            result = run_bounded([sys.executable, '-c', program, str(pid_file)],
                                 capture_output=True, text=True, timeout=1)
            self.assertEqual(result.returncode, 124)
            self.assertFalse((Path('/proc') / pid_file.read_text()).exists())

    def test_timeout_terminates_solver_descendants(self):
        with tempfile.TemporaryDirectory(prefix='raptor-tool-timeout-') as name:
            pid_file = Path(name) / 'child.pid'
            program = ("import pathlib, subprocess, sys, time; "
                       "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                       "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); time.sleep(30)")
            result = run_bounded([sys.executable, '-c', program, str(pid_file)],
                                 capture_output=True, text=True, timeout=1)
            self.assertEqual(result.returncode, 124)
            self.assertIn('TIMEOUT:', result.stderr)
            child = Path('/proc') / pid_file.read_text()
            try:
                state = (child / 'stat').read_text().split()[2]
            except (FileNotFoundError, ProcessLookupError):
                pass
            else:
                self.assertEqual(state, 'Z', 'Timed-out solver descendant is still running')


@unittest.skipUnless(YOSYS and SMTBMC.exists(), 'Formal tools are required')
class AllStateCertificateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='raptor-view-audit-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def compile(self, *, initialized=False, assumed=False, clocked=False):
        initial = ' = 0' if initialized else ''
        declaration = f'output logic [3:0] q{initial}'
        assertion = 'q == 0' if initialized or assumed else 'q == q'
        sampling = 'always_ff @(posedge clock)' if clocked else 'always_comb'
        assumption = 'always_comb assume (q == 0);' if assumed else ''
        source = self.directory / 'fixture.sv'
        source.write_text(f'''module fixture(input logic clock, input logic [3:0] a,
    {declaration});
  always_ff @(posedge clock) q <= a;
  {sampling} assert ({assertion});
  {assumption}
  always_comb cover (1'b1);
endmodule
''')
        raw = self.directory / 'frontend.il'
        model = self.directory / 'model.smt2'
        command = (f'read_slang --threads 1 --top fixture {source}; write_rtlil {raw}; '
                   'async2sync; chformal -lower; prep -top fixture; dffunmap; '
                   f'write_smt2 -wires {model}')
        process = subprocess.run([YOSYS, '-Q', '-T', '-m', 'slang', '-p', command],
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        return raw.read_text(), model

    def bmc(self, model, depth):
        return subprocess.run([str(SMTBMC), '-s', 'bitwuzla', '-t', str(depth), str(model)],
                              capture_output=True, text=True, timeout=30)

    def test_uninitialized_state_identity_is_unrestricted(self):
        raw, model = self.compile()
        self.assertEqual(audit_prf_frontend(raw, 1)['assertions_before_optimization'], 1)
        self.assertEqual(audit_model(model.read_text(), 'fixture'),
                         {'i': 'true', 'h': 'true', 'u': 'true'})
        self.assertEqual(self.bmc(model, 1).returncode, 0)

    def test_direct_query_does_not_apply_initialization(self):
        for initialized, expected in ((False, 'unsat'), (True, 'sat')):
            with self.subTest(initialized=initialized):
                _, model = self.compile(initialized=initialized)
                query = self.directory / 'direct.smt2'
                query.write_text(model.read_text() + '\n'
                                 '(declare-fun arbitrary_snapshot () |fixture_s|)\n'
                                 '(assert (not (|fixture_a| arbitrary_snapshot)))\n'
                                 '(check-sat)\n')
                helper = Path(__file__).with_name('prf_formal.py')
                env = dict(os.environ, PATH=str(SMTBMC.parent) + ':' + os.environ['PATH'])
                result = run_bounded([sys.executable, str(helper), 'views', '--snapshot-query',
                                      str(query), str(self.directory / 'expanded.smt2')],
                                     capture_output=True, text=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_initialization_can_hide_a_later_failure(self):
        raw, model = self.compile(initialized=True)
        self.assertEqual(self.bmc(model, 1).returncode, 0)
        later = self.bmc(model, 2)
        self.assertNotEqual(later.returncode, 0)
        self.assertIn('assert failed', later.stdout.lower())
        with self.assertRaisesRegex(ValueError, 'initialization'):
            audit_prf_frontend(raw, 1)
        with self.assertRaisesRegex(ValueError, 'state or inputs: i'):
            audit_model(model.read_text(), 'fixture')

    def test_assumptions_can_hide_bad_current_states(self):
        raw, model = self.compile(assumed=True)
        self.assertEqual(self.bmc(model, 1).returncode, 0)
        with self.assertRaisesRegex(ValueError, 'Environmental'):
            audit_prf_frontend(raw, 1)
        with self.assertRaisesRegex(ValueError, 'state or inputs: u'):
            audit_model(model.read_text(), 'fixture')

    def test_clocked_sampling_is_not_a_combinational_certificate(self):
        raw, _ = self.compile(clocked=True)
        with self.assertRaisesRegex(ValueError, 'Clocked'):
            audit_prf_frontend(raw, 1)

    def test_partition_preserves_other_obligations_and_all_guards(self):
        source = (ROOT / 'verification/formal/formal_prf.sv').read_text()
        partition = history_harness(source)
        self.assertIn('observed_valid : assert', partition)
        self.assertIn('stored_byte : assert', partition)
        self.assertIn('if (rat[r] == watched_address) cover', partition)
        self.assertIn('else if (known && commits.slot[c].prd == watched_address)', partition)
        with self.assertRaisesRegex(ValueError, 'obligations changed'):
            history_harness(source.replace('assert (rvfi_value[c] == 0);', 'assert (1);'))


TOOLS = ROOT / 'third_party/oss-cad-suite/bin'


@unittest.skipUnless(YOSYS and (TOOLS / 'yosys-smtbmc').exists(), 'Formal tools are required')
class BytePartitionTest(unittest.TestCase):
    def test_recovery_entrypoint_preserves_native_frontend_selection(self):
        with tempfile.TemporaryDirectory(prefix='raptor-byte-recovery-') as name:
            directory = Path(name)
            reference = directory / 'reference'
            original = run_composed(reference, preset='formal', xlen=32, lutram=0,
                                     shape=(4, 8, 2, 2, 3, 3), synthesis=True, rvfi=False,
                                     timeout=60, history_proof=False)
            self.assertFalse(original['certified'])
            self.assertEqual(original['history']['statuses'], {'prove': 'NOT_RUN', 'cover': 'PASS'})
            env = dict(os.environ)
            env.pop('RAPTOR_YOSYS_REAL', None)
            result = run_bounded([sys.executable, str(Path(__file__).with_name(
                                  'prf_formal.py')), 'byte-partition', '--reference', str(reference),
                                  '--output', str(directory / 'recovery'), '--jobs', '2',
                                  '--timeout', '60', '--engine', 'abc-pdr'],
                                 capture_output=True, text=True,
                                 env=env, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads((directory / 'recovery/results.json').read_text())
            self.assertTrue(report['certified'])
            self.assertEqual({r['lane'] for r in report['partitions']}, set(range(4)))
            self.assertTrue(all(r['engine'] == 'abc pdr' for r in report['partitions']))
            config = reference / 'history.sby'
            config.write_text(config.read_text().replace('prove: mode prove', 'prove: mode bmc'))
            original['artifacts']['history.sby'] = hashlib.sha256(
                config.read_bytes()).hexdigest()
            (reference / 'results.json').write_text(json.dumps(original))
            rejected = run_bounded([sys.executable, str(Path(__file__).with_name(
                                    'prf_formal.py')), 'byte-partition', '--reference', str(reference),
                                    '--output', str(directory / 'bounded'), '--timeout', '60'],
                                   capture_output=True, text=True, env=env, timeout=30)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('unbounded history proof mode', rejected.stderr)

    def test_reconstruction_rejects_every_missing_byte(self):
        with tempfile.TemporaryDirectory(prefix='raptor-byte-theorem-') as name:
            for xlen in (32, 64):
                result = byte_lemma(Path(name) / str(xlen), xlen)
                self.assertTrue(result['complete'])
                self.assertEqual(len(result['cases']), 2 * (1 + xlen // 8))

    def test_high_byte_storage_defect_is_not_hidden_by_low_byte_success(self):
        with tempfile.TemporaryDirectory(prefix='raptor-byte-mutant-') as name:
            directory = Path(name)
            dut = directory / 'mutant.sv'
            original = (ROOT / 'rtl/backend/rapt_prf.sv').read_text()
            anchor = 'prf_arr[i] <= wr_mux_data[i];'
            self.assertEqual(original.count(anchor), 1)
            dut.write_text(original.replace(anchor,
                           "prf_arr[i] <= wr_mux_data[i] ^ (XLEN'(1) << (XLEN-1));"))
            history = history_harness((FORMAL / 'formal_prf.sv').read_text())
            env = dict(os.environ, PATH=str(TOOLS) + ':' + os.environ['PATH'])
            for lane, expected in ((0, 'PASS'), (3, 'FAIL')):
                with self.subTest(lane=lane):
                    harness = directory / f'byte-{lane}.sv'
                    harness.write_text(partition_history(history, lane, 32))
                    model = directory / f'byte-{lane}.smt2'
                    read = ('read_slang --threads 1 --single-unit --top formal_prf_contract -DRAPT_FORMAL_PRF_CONTRACT '
                            '-DRAPT_FPGA_LUTRAM=0 -DSYNTHESIS '
                            f'-I{ROOT}/rtl/configs/formal -I{ROOT}/rtl/include '
                            f'-I{ROOT}/rtl/include/npc -I{ROOT}/rtl/include/dpic_mock '
                            f'{ROOT}/rtl/rapt_pkg.sv {dut} {harness}; '
                            'async2sync; chformal -lower; '
                            'prep -top formal_prf_contract -flatten; '
                            f'dffunmap; write_smt2 -wires {model}')
                    prepared = run_bounded([YOSYS, '-Q', '-T', '-m', 'slang', '-p', read],
                                           capture_output=True, text=True, env=env, timeout=30)
                    self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
                    log = directory / f'byte-{lane}.log'
                    with log.open('w') as stream:
                        checked = run_bounded([str(TOOLS / 'yosys-smtbmc'), '-s', 'bitwuzla',
                                               '--noprogress', '-t', '6', '--dump-vcd',
                                               str(directory / f'byte-{lane}.vcd'), str(model)],
                                              env=env, stdout=stream, stderr=subprocess.STDOUT,
                                              timeout=30)
                    output = log.read_text()
                    self.assertNotEqual(checked.returncode, 124, output)
                    self.assertIn('Status: ' + ('PASSED' if expected == 'PASS' else 'FAILED'), output)
                    if expected == 'FAIL':
                        self.assertIn('Assert failed', output)
                        self.assertGreater((directory / f'byte-{lane}.vcd').stat().st_size, 0)


class QualificationFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        files = {
            "rtl/configs/default/rapt_config.svh": "`define WIDTH 8\n",
            "rtl/unit.sv": "module unit(input clock, reset); always @(posedge clock); endmodule\n",
            "rtl/generated/rapt_idu_decoder.sv": "module decoder; endmodule\n",
            "rtl/generated/rapt_idu_decoder_c.sv": "module compressed; endmodule\n",
            "verification/formal/harness.sv": "module harness; endmodule\n",
            "proof.log": "Induction step proven: SUCCESS!\n",
            "proof.ys": "sat -verify -tempinduct -prove correct 1\n",
            "activation.log": "SAT solving finished - model found:\n",
            "activation.vcd": "$timescale 1ns $end\n#0\n",
        }
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.scope = inventory(self.root)
        self.receipt = {
            "status": "PASS", "unit": "rtl/unit.sv:unit", "obligation": "functional",
            "profile": "default/rv32/dff", "method": "induction",
            "harness": "verification/formal/harness.sv", "parameters": {"WIDTH": 8},
            "assumptions": [], "inputs": dict(self.scope["sources"]),
            "log": "proof.log", "artifacts": {
                name: sha(self.root / name)
                for name in ("proof.log", "proof.ys", "activation.log", "activation.vcd")
            },
            "property_activation": [{
                "property": "accepted-item", "log": "activation.log",
                "witness": "activation.vcd",
            }],
        }
        self.receipt["inputs"][self.receipt["harness"]] = sha(self.root / self.receipt["harness"])

    def audit(self, receipt=None):
        scope = copy.deepcopy(self.scope)
        self.assertEqual(apply_contract_review(scope, self.complete_review()), [])
        return audit_receipt(receipt or self.receipt, scope, self.root, self.root)

    def setUp_activation(self):
        self.receipt["property_activation"] = [{
            "property": "accepted-item", "log": "activation.log", "witness": "activation.vcd",
        }]

    def complete_review(self):
        return {
            "sources": dict(self.scope["sources"]),
            "units": {unit["id"]: {
                "rationale": "Review preserves all candidate contracts and configurations",
                "parameter_bindings": {profile: [{"WIDTH": 8}]
                                       for profile in self.scope["profiles"]},
                "obligations": list(unit["obligations"]),
                "profiles": list(self.scope["profiles"]),
            } for unit in self.scope["units"]},
        }


class QualificationEvidenceTests(QualificationFixture, unittest.TestCase):
    def test_current_complete_receipt(self):
        self.assertEqual(self.audit(), ("rtl/unit.sv:unit", "functional", "default/rv32/dff",
                                       binding_key({"WIDTH": 8})))

    def test_ioq_producer_proofs_cannot_replace_store_and_atomic_contracts(self):
        path = self.root / 'rtl/backend/lsu/rapt_lsu_ioq.sv'
        path.parent.mkdir(parents=True)
        path.write_text('module rapt_lsu_ioq(input clock, reset);\n'
                        'always @(posedge clock);\nendmodule\n')
        scope = inventory(self.root)
        unit = next(u for u in scope['units'] if u['name'] == 'rapt_lsu_ioq')
        expected = {'dispatch-admission', 'completion-identity', 'request-response-provenance',
                    'single-completion', 'store-data-owner', 'atomic-semantics'}
        self.assertTrue(expected <= set(unit['obligations']))
        review = dict(sources=scope['sources'], units={unit['id']: dict(
            rationale='Completion producer layer only',
            obligations=['dispatch-admission', 'completion-identity',
                         'request-response-provenance', 'single-completion'],
            profiles=scope['profiles'], parameter_bindings={p: [{'XLEN': 32}]
                for p in scope['profiles']})})
        self.assertTrue(any('removes required obligations' in error
                            for error in apply_contract_review(scope, review)))

    def test_rtl_and_configuration_edits_invalidate_evidence(self):
        for name in ("rtl/unit.sv", "rtl/configs/default/rapt_config.svh"):
            path = self.root / name
            original = path.read_text()
            path.write_text(original + "// changed\n")
            with self.assertRaisesRegex(ValueError, "Stale or missing proof input"):
                self.audit()
            path.write_text(original)

    def test_partial_source_manifest_rejected(self):
        del self.receipt["inputs"]["rtl/configs/default/rapt_config.svh"]
        with self.assertRaisesRegex(ValueError, "complete RTL/configuration"):
            self.audit()

    def test_bmc_does_not_close_sequential_obligation(self):
        self.receipt["method"] = "bmc"
        with self.assertRaisesRegex(ValueError, "Bounded/unsupported"):
            self.audit()

    def test_empty_or_unfingerprinted_activation_rejected(self):
        self.receipt["property_activation"] = []
        with self.assertRaisesRegex(ValueError, "activation"):
            self.audit()
        self.setUp_activation()
        (self.root / "activation.vcd").write_text("")
        self.receipt["artifacts"]["activation.vcd"] = sha(self.root / "activation.vcd")
        with self.assertRaisesRegex(ValueError, "witness is empty"):
            self.audit()

    def test_tool_error_cannot_be_overridden_by_pass_receipt(self):
        text = "Induction step proven: SUCCESS!\nERROR: incomplete proof\n"
        (self.root / "proof.log").write_text(text)
        self.receipt["artifacts"]["proof.log"] = sha(self.root / "proof.log")
        with self.assertRaisesRegex(ValueError, "does not establish"):
            self.audit()

    def test_wrong_profile_and_wrong_obligation_rejected(self):
        for field, value in (("profile", "unknown"), ("obligation", "other-contract")):
            candidate = copy.deepcopy(self.receipt)
            candidate[field] = value
            with self.assertRaises(ValueError):
                self.audit(candidate)

    def test_absolute_and_escaping_artifact_paths_rejected(self):
        for name in (str(self.root / "proof.log"), "../proof.log"):
            candidate = copy.deepcopy(self.receipt)
            candidate["artifacts"][name] = sha(self.root / "proof.log")
            with self.assertRaisesRegex(ValueError, "paths|escapes"):
                self.audit(candidate)

    def test_activation_error_rejected_even_with_a_model(self):
        path = self.root / "activation.log"
        path.write_text("SAT solving finished - model found:\nERROR: witness conversion failed\n")
        self.receipt["artifacts"]["activation.log"] = sha(path)
        with self.assertRaisesRegex(ValueError, "Activation log contains"):
            self.audit()

    def test_inventory_includes_interfaces_packages_and_generated_decoders(self):
        (self.root / "rtl/interfaces.svh").write_text("interface channel; endinterface\n")
        (self.root / "rtl/types.sv").write_text("package types; endpackage\n")
        scope = inventory(self.root)
        ids = {unit["id"] for unit in scope["units"]}
        self.assertIn("rtl/interfaces.svh:channel", ids)
        self.assertIn("rtl/types.sv:types", ids)
        self.assertIn("rtl/generated/rapt_idu_decoder.sv:decoder", ids)
        self.assertFalse(scope["missing_generated"])
        self.assertEqual(len(scope["profiles"]), 4)

    def test_verilog_and_conditional_units_cannot_disappear(self):
        (self.root / "rtl/legacy.v").write_text("module legacy; endmodule\n")
        (self.root / "rtl/conditional.v").write_text('`include "external.vh"\n')
        scope = inventory(self.root)
        ids = {unit["id"] for unit in scope["units"]}
        self.assertIn("rtl/legacy.v:legacy", ids)
        self.assertIn("rtl/conditional.v:file", ids)

    def test_review_cannot_omit_configurations(self):
        review = self.complete_review()
        review["units"]["rtl/unit.sv:unit"]["profiles"] = [self.scope["profiles"][0]]
        errors = apply_contract_review(self.scope, review)
        self.assertTrue(any("omits or changes supported profiles" in e for e in errors))
        unit = next(u for u in self.scope["units"] if u["name"] == "unit")
        self.assertNotIn("reviewed_profiles", unit)

    def test_review_cannot_replace_required_contracts_with_generic_pass(self):
        review = self.complete_review()
        review["units"]["rtl/unit.sv:unit"]["obligations"] = ["functional"]
        errors = apply_contract_review(self.scope, review)
        self.assertTrue(any("removes required obligations" in e for e in errors))
        unit = next(u for u in self.scope["units"] if u["name"] == "unit")
        self.assertIn("reset", unit["obligations"])

    def test_review_can_add_contracts_without_removing_scope(self):
        review = self.complete_review()
        review["units"]["rtl/unit.sv:unit"]["obligations"].append("transport")
        self.assertEqual(apply_contract_review(self.scope, review), [])
        unit = next(u for u in self.scope["units"] if u["name"] == "unit")
        self.assertIn("transport", unit["obligations"])
        self.assertEqual(set(unit["reviewed_profiles"]), set(self.scope["profiles"]))

    def test_one_geometry_cannot_close_another_in_the_same_profile(self):
        scope = copy.deepcopy(self.scope)
        review = self.complete_review()
        profile = self.receipt['profile']
        review['units']['rtl/unit.sv:unit']['parameter_bindings'][profile].append({'WIDTH': 16})
        self.assertEqual(apply_contract_review(scope, review), [])
        accepted = audit_receipt(self.receipt, scope, self.root, self.root)
        pending = required_contracts(scope) - {accepted}
        self.assertIn(('rtl/unit.sv:unit', 'functional', profile, binding_key({'WIDTH': 16})),
                      pending)
        self.assertNotIn(accepted, pending)

    def test_wrong_geometry_and_unreviewed_receipts_are_rejected(self):
        wrong = copy.deepcopy(self.receipt)
        wrong['parameters'] = {'WIDTH': 16}
        with self.assertRaisesRegex(ValueError, 'reviewed parameter binding'):
            self.audit(wrong)
        with self.assertRaisesRegex(ValueError, 'reviewed parameter binding'):
            audit_receipt(self.receipt, self.scope, self.root, self.root)

    def test_legacy_missing_empty_and_duplicate_binding_reviews_are_rejected(self):
        for replacement in ({'WIDTH': 8}, {}, {p: [] for p in self.scope['profiles']},
                            {p: [{'WIDTH': 8}, {'WIDTH': 8}] for p in self.scope['profiles']}):
            with self.subTest(bindings=replacement):
                review = self.complete_review()
                review['units']['rtl/unit.sv:unit']['parameter_bindings'] = replacement
                self.assertTrue(apply_contract_review(copy.deepcopy(self.scope), review))

    def test_combinational_snapshot_cannot_close_a_sequential_contract(self):
        self.receipt['method'] = 'combinational-smt'
        with self.assertRaisesRegex(ValueError, 'Bounded/unsupported'):
            self.audit()


class NativeQualificationEvidenceTests(QualificationFixture, unittest.TestCase):
    @unittest.skipUnless(shutil.which('yosys'), 'Native Yosys with Slang is required')
    def test_unrestricted_smt_receipt_and_extra_query_constraint(self):
        from yosys_common import ROOT

        unit = self.root / 'rtl/unit.sv'
        unit.write_text('''module unit #(parameter WIDTH=8)(input [WIDTH-1:0] a,
    output [WIDTH-1:0] y);
  assign y = a + WIDTH'(1);
endmodule
''')
        harness = self.root / 'verification/formal/harness.sv'
        harness.write_text('''module harness #(parameter WIDTH=8)(
    input [WIDTH-1:0] a, output wire [WIDTH-1:0] y);
  unit #(.WIDTH(WIDTH)) dut(.*);
  always_comb assert (y == a + 8'd1);
  always_comb cover (a != 0);
endmodule
''')
        frontend, model = self.root / 'frontend.il', self.root / 'model.smt2'
        command = (f'read_slang --threads 1 --single-unit --top harness -GWIDTH=8 '
                   f'{unit} {harness}; '
                   f'write_rtlil {frontend}; chformal -lower; prep -top harness -flatten; '
                   f'write_smt2 -wires {model}')
        native = os.environ.get('RAPTOR_YOSYS_REAL', 'yosys')
        prepared = subprocess.run([native, '-Q', '-T', '-m', 'slang', '-p', command],
                                  capture_output=True, text=True, timeout=30)
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        (self.root / 'binding.il.gz').write_bytes(gzip.compress(frontend.read_bytes()))
        (self.root / 'read.ys').write_text(command.replace('; ', '\n'))
        query, expanded = self.root / 'query.smt2', self.root / 'expanded.smt2'
        query.write_text(model.read_text() + '\n'
                         '(declare-fun arbitrary_snapshot () |harness_s|)\n'
                         '(assert (not (|harness_a| arbitrary_snapshot)))\n(check-sat)\n')
        env = dict(os.environ, PATH=str(ROOT / 'third_party/oss-cad-suite/bin')
                   + ':' + os.environ['PATH'])
        checked = subprocess.run([sys.executable, str(ROOT / 'verification/scripts/prf_formal.py'), 'views',
                                  '--snapshot-query', str(query), str(expanded)], env=env,
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(checked.stdout.strip(), 'unsat')
        (self.root / 'query.log').write_text(checked.stdout)
        (self.root / 'proof.log').write_text('UNRESTRICTED COMBINATIONAL PROOF COMPLETE\n')
        self.scope = inventory(self.root)
        self.receipt.update(method='combinational-smt', inputs=dict(self.scope['sources']))
        self.receipt['inputs']['verification/formal/harness.sv'] = sha(harness)
        self.receipt['artifacts'].update({n: sha(self.root / n) for n in
                                         ['frontend.il', 'model.smt2', 'query.smt2',
                                          'expanded.smt2', 'query.log', 'proof.log',
                                          'binding.il.gz', 'read.ys']})
        self.receipt['elaboration'] = dict(model='binding.il.gz', script='read.ys')
        self.receipt['snapshot'] = dict(frontend='frontend.il', model='model.smt2',
                                        query='query.smt2', result='query.log',
                                        expanded='expanded.smt2', top='harness', assertions=1,
                                        covers=1)
        import re

        cover = re.search(r'^; yosys-smt2-cover 0 (.+)$', model.read_text(), re.M)[1]
        property_name = 'harness: ' + cover
        activation_log = ('##   0:00:00  Reached cover statement in step 0 at '
                          + property_name + '\n##   0:00:00  Writing trace to VCD file: '
                          + str(self.root / 'activation.vcd') + '\n')
        (self.root / 'activation.log').write_text(activation_log)
        self.receipt['artifacts']['activation.log'] = sha(self.root / 'activation.log')
        self.receipt['property_activation'][0]['property'] = property_name
        self.audit()
        original_activation = copy.deepcopy(self.receipt['property_activation'])
        self.receipt['property_activation'] = []
        with self.assertRaisesRegex(ValueError, 'complete model inventory'):
            self.audit()
        self.receipt['property_activation'] = copy.deepcopy(original_activation)
        self.receipt['property_activation'][0]['witness'] = 'query.log'
        with self.assertRaisesRegex(ValueError, 'differs from the reached property'):
            self.audit()
        self.receipt['property_activation'] = copy.deepcopy(original_activation)
        original_read = (self.root / 'read.ys').read_text()
        (self.root / 'read.ys').write_text(original_read.replace('-GWIDTH=8', '-GWIDTH=16'))
        self.receipt['artifacts']['read.ys'] = sha(self.root / 'read.ys')
        with self.assertRaisesRegex(ValueError, 'Actual elaboration parameters'):
            self.audit()
        (self.root / 'read.ys').write_text(original_read)
        self.receipt['artifacts']['read.ys'] = sha(self.root / 'read.ys')
        query.write_text(query.read_text().replace('(check-sat)', '(assert false)\n(check-sat)'))
        self.receipt['artifacts']['query.smt2'] = sha(query)
        with self.assertRaisesRegex(ValueError, 'unrestricted assertion predicate'):
            self.audit()
        query.write_text(query.read_text().replace('(assert false)\n', ''))
        self.receipt['artifacts']['query.smt2'] = sha(query)
        unit.write_text(unit.read_text().replace("WIDTH'(1)", "WIDTH'(2)"))
        changed_frontend = self.root / 'changed.il'
        changed_model = self.root / 'changed.smt2'
        changed = command.replace(str(frontend), str(changed_frontend)).replace(
            str(model), str(changed_model))
        rebuilt = subprocess.run([native, '-Q', '-T', '-m', 'slang', '-p', changed],
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(rebuilt.returncode, 0, rebuilt.stdout + rebuilt.stderr)
        (self.root / 'binding.il.gz').write_bytes(gzip.compress(changed_frontend.read_bytes()))
        self.receipt['artifacts']['binding.il.gz'] = sha(self.root / 'binding.il.gz')
        self.scope = inventory(self.root)
        self.receipt['inputs'] = dict(self.scope['sources'])
        self.receipt['inputs']['verification/formal/harness.sv'] = sha(harness)
        with self.assertRaisesRegex(ValueError, 'Parameter-binding model differs'):
            self.audit()


@unittest.skipUnless(shutil.which('yosys'), 'Yosys is required')
class GraphIdentityTest(unittest.TestCase):
    def model(self, expression='a', initial=0, assumption='a', unused='a'):
        with tempfile.TemporaryDirectory(prefix='raptor-graph-test-') as directory:
            root = Path(directory)
            source = root / 'design.sv'
            source.write_text(f'''
module unused(input a, output y); assign y = {unused}; endmodule
module top(input clock, a, output reg q = {initial});
  always @(posedge clock) begin
    q <= {expression};
    assume ({assumption});
    assert (q || !a);
  end
endmodule
''')
            out = root / 'model.il'
            run = subprocess.run(['yosys', '-Q', '-T', '-m', 'slang', '-p',
                                  f'read_slang --threads 1 --top top {source}; write_rtlil {out}'],
                                 capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            return canonical_rtlil(out.read_text())

    def test_unused_module_change_does_not_change_graph(self):
        self.assertEqual(self.model(), self.model(unused='~a'))

    def test_functional_change_is_detected(self):
        self.assertNotEqual(self.model(), self.model(expression='~a'))

    def test_initial_value_change_is_detected(self):
        self.assertNotEqual(self.model(), self.model(initial=1))

    def test_assumption_change_is_detected(self):
        self.assertNotEqual(self.model(), self.model(assumption='!a'))


@unittest.skipUnless(YOSYS, 'Native Yosys with Slang is required')
class ModelClassTest(unittest.TestCase):
    def test_initialization_assumptions_assertions_and_covers_remain_distinct(self):
        with tempfile.TemporaryDirectory(prefix='raptor-model-classes-') as name:
            root = Path(name)
            cases = []
            variations = [('base', '', '', 'q == a', True),
                          ('different_location', '', '', 'q == a', True),
                          ('initialized', ' = 0', '', 'q == a', True),
                          ('assumed', '', 'always_comb assume (q == 0);', 'q == a', True),
                          ('assertion_changed', '', '', 'q == 0', True),
                          ('cover_removed', '', '', 'q == a', False)]
            for identifier, initializer, assumption, assertion, covered in variations:
                cover = "always_comb cover (q == 1);" if covered else ''
                (root / f'{identifier}.sv').write_text(f'''module fixture(
    input logic clock, input logic [3:0] a, output logic [3:0] q{initializer});
  always_ff @(posedge clock) q <= a;
  always_comb assert ({assertion});
  {assumption}
  {cover}
endmodule
''')
                cases.append(dict(id=identifier, top='fixture',
                                  read='read_slang --threads 1 --single-unit --top fixture '
                                       f'@ROOT@/{identifier}.sv'))
            manifest = root / 'commands.json'
            manifest.write_text(json.dumps(dict(cases=cases)))
            process = subprocess.run([sys.executable, str(ROOT / 'verification/scripts'
                                      / 'formal_scope.py'), 'model-classes', '--source-root', str(root),
                                      '--commands', str(manifest), '--output', str(root / 'results'),
                                      '--jobs', '2'], capture_output=True, text=True, timeout=60)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            result = json.loads((root / 'results/results.json').read_text())
            self.assertTrue(result['complete_model_inventory'])
            self.assertFalse(result['whole_rtl_signoff'])
            self.assertEqual(len(result['groups']), 5)
            rows = {r['id']: r['canonical_sha256'] for r in result['cases']}
            self.assertEqual(rows['base'], rows['different_location'])
            self.assertEqual(len(set(rows.values())), 5)


if __name__ == '__main__':
    unittest.main()
