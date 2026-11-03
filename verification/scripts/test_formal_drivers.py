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
from types import SimpleNamespace
from unittest.mock import patch
from alu_contract import snapshot_result
from formal_contract import copy_native_artifact, native_contract, qualify_native_contract, run_contract
from formal_scope import (
    apply_contract_review,
    audit_receipt,
    audit_file,
    binding_key,
    canonical_rtlil,
    inventory,
    native_sat_command,
    preset_xlens,
    required_contracts,
    scope_main,
)
from ioq_contract import (
    PREFIX,
    TOP,
    activation_witnesses,
    activate as activate_ioq,
    audit_extension,
    audit_frontend,
    augment,
    canonical_model,
    compile_case,
    load_primary_replay,
    prove as prove_ioq,
    read_command as ioq_read_command,
    reuse_proof,
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
from yosys_common import ROOT, run_bounded, run_sby, sha
from unit_contracts import load_sram_generator, sram_case, sram_frontend


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


class NativeArtifactTests(unittest.TestCase):
    def test_copy_rejects_corruption_before_and_during_evidence_publication(self):
        with tempfile.TemporaryDirectory(prefix='raptor-native-artifact-') as name:
            root = Path(name)
            source, output = root / 'model.il', root / 'evidence'
            source.write_text('frozen model\n')
            digest = sha(source)
            self.assertEqual(copy_native_artifact(source, output, 'bound/model.il', digest), digest)
            self.assertEqual((output / 'bound/model.il').read_bytes(), source.read_bytes())
            copy_file = shutil.copy2

            def corrupt_copy(origin, target):
                origin.write_text('changed model\n')
                return copy_file(origin, target)

            for during in (False, True):
                source.write_text('frozen model\n' if during else 'changed model\n')
                with self.subTest(during_copy=during), \
                        patch('formal_contract.shutil.copy2', side_effect=corrupt_copy), \
                        self.assertRaisesRegex(ValueError, 'Native artifact changed'):
                    copy_native_artifact(source, output, 'bound/model.il', digest)
            with self.assertRaisesRegex(ValueError, 'escapes'):
                copy_native_artifact(source, output, '../escape.il', digest)


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
    def register(bit, source="rtl/core/backend/rob/rapt_rou.sv:1.1-1.2"):
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


@unittest.skipUnless(YOSYS, 'Native Yosys is required')
class NativeSvaTests(unittest.TestCase):
    def test_sampled_data_and_wide_implication_preserve_assertions_and_covers(self):
        source = '''`include "rapt_sva.svh"
module sva_native(input logic clock, reset, flush, input logic [2:0] value);
  logic first = 1'b1;
  logic [2:0] saved;
  always_ff @(posedge clock) begin
    first <= 1'b0;
    if (first) assume (reset);
    if (reset || flush) saved <= 0;
    else saved <= value;
  end
  `RAPT_SVA_IMPLY(clock, reset, WIDE_TRUTH, 3'b100, 1'b1)
  `RAPT_SVA_IMPLY(clock, reset, PAST_TRUTH, $past(value), $past(value) != 0)
  `RAPT_SVA_NEXT(clock, reset || flush, NEXT_DATA, 1'b1, saved == $past(value))
  `RAPT_COVER(clock, reset, NONEMPTY, saved == 3'b100 && value == 0)
endmodule
'''
        variants = (
            ('positive', source, None),
            ('wide-false', source.replace("3'b100, 1'b1", "3'b100, 1'b0"), 'WIDE_TRUTH_a'),
            ('wrong-data', source.replace('saved <= value;', 'saved <= ~value;'), 'NEXT_DATA_a'),
            ('procedural-false', source.replace('if (reset || flush) saved <= 0;',
                'if (!reset && value == 4) begin `RAPT_SVA_FAIL(PROCEDURAL) end\n'
                '    if (reset || flush) saved <= 0;'), 'PROCEDURAL_a'),
        )
        with tempfile.TemporaryDirectory(prefix='raptor-native-sva-') as name:
            for label, text, failed_property in variants:
                with self.subTest(label=label):
                    directory = Path(name) / label
                    directory.mkdir()
                    rtl = directory / 'fixture.sv'
                    rtl.write_text(text)
                    config = ('[tasks]\nprove\n' + ('' if failed_property else 'cover\n')
                              + '[options]\nprove: mode '
                              + ('bmc\n' if failed_property else 'prove\n')
                              + 'prove: depth 6\n')
                    if not failed_property:
                        config += 'cover: mode cover\ncover: depth 6\n'
                    config += ('timeout 40\n[engines]\nsmtbmc bitwuzla\n[script]\nplugin -i slang\n'
                               'read_slang --single-unit -USYNTHESIS -DRAPT_ASSERT_EN '
                               f'-DRAPT_FORMAL_NATIVE -I{ROOT}/rtl/include '
                               f'--top sva_native {rtl}\n'
                               'prep -top sva_native -flatten\nasync2sync\nchformal -lower\n'
                               'check -assert\n')
                    (directory / 'contract.sby').write_text(config)
                    row, traces = run_sby(directory, 40, negative=bool(failed_property), yosys=YOSYS)
                    self.assertTrue(row['passed'], (directory / 'run.log').read_text())
                    self.assertTrue(traces)
                    if failed_property:
                        self.assertIn(failed_property, (directory / 'run.log').read_text())


@unittest.skipUnless(YOSYS and (ROOT / 'third_party/oss-cad-suite/bin/sby').is_file(),
                     'Native Yosys with Slang and SBY are required')
class NativeSmtbmcReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix='raptor-sram-signoff-')
        cls.addClassCleanup(temporary.cleanup)
        output = Path(temporary.name)
        generator = load_sram_generator()
        case = (2, 32, 8, 1, 0)
        proof = sram_case(case, output, 60, generator)
        cls.directory = output / proof['case']
        bound = cls.directory / 'bindings/fixture'
        binding = sram_frontend(case, bound, 60, generator,
                                 profile='default/rv64/dff', synthesis=True)
        assert binding['canonical_sha256'] == proof['native_binding']['canonical_sha256']
        artifacts = dict(proof['artifacts'])
        artifacts.update({str(p.relative_to(cls.directory)): sha(p)
                          for p in bound.iterdir() if p.is_file()})
        cls.scope = inventory(ROOT)
        unit_id = 'rtl/sram/rapt_sram_1rw.sv:rapt_sram_1rw'
        unit = next(row for row in cls.scope['units'] if row['id'] == unit_id)
        key = binding_key(binding['parameters'])
        unit['reviewed_bindings'] = {binding['profile']: {key: binding['parameters']}}
        harness = 'verification/formal/formal_sram_word.sv'
        inputs = dict(cls.scope['sources'])
        inputs[harness] = sha(ROOT / harness)
        cls.receipt = dict(status='PASS', unit=unit_id, obligation='read-write',
            profile=binding['profile'], method='smtbmc-induction', parameters=binding['parameters'],
            inputs=inputs, harness=harness, assumptions=['Only the observer address is stable'],
            log='run.log', artifacts=artifacts,
            property_activation=[dict(property=name, log='contract_cover/engine_0/logfile.txt',
                                      witness=witness)
                                 for name, witness in proof['activation'].items()],
            model_binding=dict(top='formal_sram_word',
                canonical_sha256=binding['canonical_sha256'], proved_model='frontend.il',
                bound_model='bindings/fixture/frontend.il', read_script='bindings/fixture/read.ys',
                proof_script='contract.sby', proof_root=str(cls.directory),
                depth=6, timeout=60, solver='yices'))

    def audit(self, receipt):
        return audit_receipt(receipt, self.scope, ROOT, self.directory)

    def test_actual_unbounded_memory_receipt_binds_rv64_and_synthesis_context(self):
        expected = (self.receipt['unit'], 'read-write', 'default/rv64/dff',
                    binding_key(self.receipt['parameters']))
        self.assertEqual(self.audit(self.receipt), expected)

    def test_incorrect_unwritten_read_is_detected_without_initializing_dut_memory(self):
        output = self.directory.parent / 'initial-read-control'
        row = sram_case((8, 32, 8, 1, 0), output, 60, load_sram_generator(), mutant='initial-read')
        self.assertEqual(row['proof'], 'FAIL')
        log = (output / 'negative-initial-read/run.log').read_text()
        self.assertIn('Assert failed', log)
        self.assertIn('tracked_read', log)

    def test_bounded_cut_incomplete_and_misattributed_evidence_cannot_qualify(self):
        scenarios = ('bounded', 'bmc-mode', 'prep-cut', 'missing-induction',
                     'missing-predicate', 'missing-activation', 'wrong-waveform', 'conflicting-status')
        for case in scenarios:
            receipt = copy.deepcopy(self.receipt)
            changed, original = None, None
            if case == 'bounded':
                receipt['method'] = 'combinational'
            elif case == 'missing-induction':
                del receipt['artifacts']['contract_prove/engine_0/logfile_induction.txt']
            elif case == 'missing-activation':
                receipt['property_activation'].pop()
            elif case == 'wrong-waveform':
                row = receipt['property_activation'][0]
                row['witness'] = next(item['witness'] for item in receipt['property_activation']
                                      if item['witness'] != row['witness'])
            else:
                name = {'bmc-mode': 'contract.sby',
                        'prep-cut': 'contract_prove/model/design_prep.ys',
                        'missing-predicate': 'contract_prove/model/design_smt2.smt2',
                        'conflicting-status': 'contract_prove/engine_0/logfile_basecase.txt'}[case]
                changed = self.directory / name
                original = changed.read_bytes()
                text = original.decode()
                if case == 'bmc-mode':
                    text = text.replace('prove: mode prove', 'prove: mode bmc')
                elif case == 'prep-cut':
                    text = text.replace('opt_clean\n', 'chformal -assert -remove\nopt_clean\n', 1)
                elif case == 'missing-predicate':
                    text = text.replace(' held_output\n', ' foreign_predicate\n', 1)
                else:
                    text += '\n## 0:00:00 Status: failed\n'
                self.assertNotEqual(text.encode(), original)
                changed.write_text(text)
                receipt['artifacts'][name] = sha(changed)
            try:
                with self.subTest(case=case), self.assertRaises(ValueError):
                    self.audit(receipt)
            finally:
                if changed:
                    changed.write_bytes(original)


@unittest.skipUnless(YOSYS and (ROOT / 'third_party/oss-cad-suite/bin/sby').is_file(),
                     'Native Yosys with Slang and SBY are required')
class NativeCompletionGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix='raptor-completion-signoff-')
        cls.addClassCleanup(temporary.cleanup)
        cls.output = Path(temporary.name)
        contract = native_contract('completion-guard')
        contract['variants'] = contract['variants'][:2]
        args = SimpleNamespace(contract='completion-guard', source_root=ROOT, output=cls.output,
                               presets=['formal'], jobs=4, timeout=60, reuse_evidence=None)
        with patch('formal_contract.native_contract', return_value=contract), patch.dict(
                os.environ, RAPTOR_YOSYS_REAL=YOSYS):
            qualify_native_contract(args)
        cls.result = json.loads((cls.output / 'results.json').read_text())
        cls.scope = inventory(ROOT)
        review = json.loads((cls.output / 'contract-review.json').read_text())
        apply_contract_review(cls.scope, review)

    def test_unrestricted_owner_table_and_both_payload_policies_publish_bound_receipts(self):
        self.assertTrue(self.result['complete'])
        self.assertEqual(len(self.result['proofs']), 2)
        self.assertEqual({row['name'] for row in self.result['negative_controls']},
                         {'generation', 'executing', 'payload', 'live', 'valid'})
        self.assertTrue(all(row['detected'] for row in self.result['negative_controls']))
        paths = json.loads((self.output / 'receipts.json').read_text())
        self.assertEqual(len(paths), 96)
        obligations, policies = set(), set()
        for name in paths:
            path = self.output / name
            receipt = json.loads(path.read_text())
            actual = audit_receipt(receipt, self.scope, ROOT, path.parent)
            obligations.add(actual[1])
            policies.add(receipt['parameters']['EnforcePayload'])
            self.assertNotIn('XLEN', receipt['parameters'])
        self.assertEqual(len(obligations), 6)
        self.assertEqual(policies, {0, 1})

    def test_a_payload_policy_cannot_be_relabeled_as_the_other_policy(self):
        name = json.loads((self.output / 'receipts.json').read_text())[0]
        path = self.output / name
        receipt = json.loads(path.read_text())
        receipt['parameters']['EnforcePayload'] ^= 1
        with self.assertRaises(ValueError):
            audit_receipt(receipt, self.scope, ROOT, path.parent)


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


class PrimaryReplayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='raptor-negative-inputs-')
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name) / 'inputs.smtc'
        self.group = 'a' * 64
        ports = {
            'reset': dict(direction='input', bits=[2]),
            'ready': dict(direction='input', bits=[3]),
            'data': dict(direction='input', bits=[4, 5]),
            'result': dict(direction='output', bits=[6, 7])}
        state = dict(bits=[8], attributes=dict(init='0'))
        module = dict(ports=ports, netnames={'private_state': state})
        self.model = dict(modules={'fixture': module})
        self.specification = dict(model_sha256=self.group, inputs=str(self.source))

    def test_concrete_primary_inputs_preserve_the_entire_model(self):
        text = ('# Concrete stimulus\nstate 0\nassume [reset]\n'
                'assume (= [data] #b10)\nstate 1\nassume (not [reset])\n'
                'assume (= [ready] #b1)\n')
        self.source.write_text(text)
        original = copy.deepcopy(self.model)
        normalized, metadata = load_primary_replay(self.model, self.specification, self.group, 4)
        self.assertEqual(self.model, original)
        self.assertEqual(self.source.read_text(), text)
        self.assertIn('assume [ready]\n', normalized)
        self.assertNotIn('# Concrete', normalized)
        self.assertEqual(metadata['frames'], 2)
        self.assertEqual(metadata['primary_input_assignments'], 4)
        self.assertEqual(metadata['internal_state_constraints'], 0)
        self.assertEqual(metadata['source_sha256'], sha(self.source))

    def test_internal_state_expressions_and_invalid_frames_are_rejected(self):
        cases = ('initial\nassume [reset]\n', 'state 0\nassume [private_state]\n',
                 'state 0\nassume (= [result] #b10)\n', 'state 0\nassert [ready]\n',
                 'state 0\nassume (= [data] #b1)\n', 'state 0\nassume true\n',
                 'state 0\nassume (or [ready] [private_state])\n',
                 'state 1\nassume [reset]\n', 'state 0\nstate 0\nassume [reset]\n',
                 'state 0\nstate 1\nstate 2\nassume [reset]\n', 'state 0\n')
        for text in cases:
            self.source.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                load_primary_replay(self.model, self.specification, self.group, 2)

    def test_replay_must_bind_the_complete_current_mutant(self):
        self.source.write_text('state 0\nassume [reset]\n')
        for specification in ({}, dict(self.specification, model_sha256='b' * 64),
                              dict(self.specification, initial_state=0)):
            with self.subTest(specification=specification), self.assertRaises(ValueError):
                load_primary_replay(self.model, specification, self.group, 4)


@unittest.skipUnless(YOSYS, 'Native Yosys with Slang is required')
class NativeModelTests(unittest.TestCase):
    def test_operand_binding_checks_the_actual_native_branch_and_port_count(self):
        rtl = [ROOT / 'rtl/rapt_pkg.sv']
        rtl += sorted(p for p in (ROOT / 'rtl').rglob('*.sv') if p not in rtl)
        with tempfile.TemporaryDirectory(prefix='raptor-ioq-binding-') as name:
            for xlen in (32, 64):
                case = dict(id='late', preset='formal', xlen=xlen, memory='dff',
                            response_stage=0, lutram=0, synthesis=True, metadata='functional',
                            late_operands=True, operand_read_ports=2)
                directory = Path(name) / str(xlen)
                result = compile_case(directory / 'correct', case, rtl, 60, YOSYS)
                self.assertTrue(result['frontend']['geometry']['late_operands'])
                self.assertEqual(result['frontend']['geometry']['operand_read_ports'], 2)
                command = ioq_read_command(case, rtl).replace('-DRAPT_FORMAL_IOQ_LATE ',
                                                             '-URAPT_FORMAL_IOQ_LATE ')
                with patch('ioq_contract.read_command', return_value=command):
                    with self.assertRaisesRegex(ValueError, 'differs from selected parameters'):
                        compile_case(directory / 'wrong-branch', case, rtl, 60, YOSYS)

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
    @unittest.skipUnless((ROOT / 'third_party/oss-cad-suite/bin/sby').is_file(), 'SBY is required')
    def test_native_proof_reuse_rejects_changed_initial_state_or_cached_artifacts(self):
        with tempfile.TemporaryDirectory(prefix='raptor-ioq-reuse-') as name:
            root = Path(name)
            rtl = [ROOT / 'rtl/rapt_pkg.sv']
            rtl += sorted(path for path in (ROOT / 'rtl').rglob('*.sv') if path not in rtl)
            case = dict(id='native', preset='formal', xlen=32, memory='dff',
                        response_stage=0, lutram=0, synthesis=True, metadata='functional')
            model_dir, proof = root / 'model', root / 'proof'
            row = compile_case(model_dir, case, rtl, 60, YOSYS)
            self.assertTrue(row['complete'])
            report = prove_ioq(proof, row, model_dir, 180, 4, 96, YOSYS)
            self.assertTrue(report['certified'], report['statuses'])
            report_hash = sha(proof / 'results.json')
            copied = reuse_proof(root / 'reuse', row, model_dir, proof, report_hash)
            self.assertTrue(copied['certified'])
            self.assertEqual(copied['reused_evidence']['canonical_sha256'], row['canonical_sha256'])
            activation = activate_ioq(root / 'activation', proof / 'frontend.json',
                                      row['canonical_sha256'], 180, 96, YOSYS)
            self.assertTrue(activation['complete_guard_activation'], activation['status'])
            report_path = proof / 'results.json'
            saved_report = report_path.read_bytes()
            incomplete = json.loads(saved_report)
            del incomplete['artifacts']['contract_prove/status']
            report_path.write_text(json.dumps(incomplete))
            with self.assertRaisesRegex(ValueError, 'artifact inventory is incomplete'):
                reuse_proof(root / 'missing-status', row, model_dir, proof, sha(report_path))
            report_path.write_bytes(saved_report)
            archive = model_dir / 'frontend.json.gz'
            saved = archive.read_bytes()
            changed = json.loads(gzip.decompress(saved))
            changed['modules'][TOP]['netnames']['past_valid']['attributes']['init'] = '1'
            encoded = json.dumps(changed).encode()
            archive.write_bytes(gzip.compress(encoded))
            altered = dict(row, original_sha256=hashlib.sha256(encoded).hexdigest())
            with self.assertRaisesRegex(ValueError, 'state, init or predicates differ'):
                reuse_proof(root / 'wrong-init', altered, model_dir, proof, report_hash)
            archive.write_bytes(saved)
            artifact = proof / 'contract.sby'
            artifact.write_text(artifact.read_text() + '\n# changed\n')
            with self.assertRaisesRegex(ValueError, 'proof artifact changed'):
                reuse_proof(root / 'wrong-proof', row, model_dir, proof, report_hash)

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
            self.assertEqual(len(selected), before['assertions'])
            self.assertEqual(after['covers'], before['covers'] + before['assertions'])
            self.assertIn(TOP + ': ' + PREFIX + 'disabled_b_request', selected)
            self.assertNotIn(TOP + ': ' + PREFIX + 'request_b_live', selected)
            audit_extension(model, expected_hash)
            observer_name = next(n for n in model['modules'][TOP]['cells'] if n.startswith(PREFIX))
            mutations = ('assumption', 'constant_guard', 'changed_clock', 'changed_state',
                         'missing_observer')
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
                elif mutation == 'changed_state':
                    module['netnames']['past_valid']['attributes']['init'] = '1'
                else:
                    del module['cells'][observer_name]
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    audit_extension(changed, expected_hash)


SCRIPTS = Path(__file__).resolve().parent


@unittest.skipUnless(YOSYS, 'Native Yosys with Slang is required')
class StoreCompositionTests(unittest.TestCase):
    def test_full_native_composition_preserves_properties_and_audit_is_read_only(self):
        script = '''
import copy, gzip, hashlib, json, os
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
extended = copy.deepcopy(model)
selected = runner.augment(extended, hashlib.sha256(before.encode()).hexdigest())
assert len(selected) == row['frontend']['assertions']
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
print(json.dumps(row['frontend']))
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
        self.assertEqual(base['geometry'], store['geometry'])
        self.assertEqual(store['assumptions'], 1)
        self.assertGreater(store['assertions'], base['assertions'])
        self.assertGreater(store['covers'], base['covers'])


SMTBMC = ROOT / 'third_party/oss-cad-suite/bin/yosys-smtbmc'


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
            original = (ROOT / 'rtl/core/backend/regfile/rapt_prf.sv').read_text()
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
                    # A small real PRF distinguishes a valid low-byte theorem from
                    # the reached high-byte storage fault without a large port matrix.
                    read = ('read_slang --threads 1 --single-unit --top formal_prf_contract -DRAPT_FORMAL_PRF_CONTRACT '
                            '-GArchRegs=2 -GEntries=4 -GReadPorts=1 -GRetirePorts=1 '
                            '-GPorts=1 -GExtraPorts=0 '
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
            "activation.log": "SAT solving finished - model found:\n",
            "activation.vcd": "$timescale 1ns $end\n#0\n",
            "frontend.il": "module \\harness\n  attribute \\init 8'00000000\n"
                           "  wire width 8 \\state\nend\n",
            "binding.il": "module \\harness\n  attribute \\init 8'00000000\n"
                          "  wire width 8 \\state\nend\n",
            "read.ys": f"read_slang --single-unit --top harness -GWIDTH=8 "
                       f"-I{self.root}/rtl/configs/default "
                       f"{self.root}/rtl/unit.sv {self.root}/verification/formal/harness.sv\n",
        }
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        command = native_sat_command('harness', self.root / 'frontend.il', proof=True)
        (self.root / 'proof.ys').write_text(command + '\n')
        (self.root / 'proof.log').write_text(
            f"-- Running command `{command}' --\nInput filename: {self.root}/frontend.il\n"
            "Induction step proven: SUCCESS!\n")
        self.scope = inventory(self.root)
        self.receipt = {
            "status": "PASS", "unit": "rtl/unit.sv:unit", "obligation": "functional",
            "profile": "default/rv32/dff", "method": "induction",
            "harness": "verification/formal/harness.sv", "parameters": {"WIDTH": 8},
            "assumptions": ["First sampled edge resets"], "inputs": dict(self.scope["sources"]),
            "log": "proof.log", "artifacts": {
                name: sha(self.root / name)
                for name in ("proof.log", "proof.ys", "activation.log", "activation.vcd",
                             "frontend.il", "binding.il", "read.ys")
            },
            "property_activation": [{
                "property": "accepted-item", "log": "activation.log",
                "witness": "activation.vcd",
            }],
        }
        canonical = canonical_rtlil((self.root / "frontend.il").read_text())
        self.receipt["model_binding"] = dict(
            top="harness", canonical_sha256=hashlib.sha256(canonical.encode()).hexdigest(),
            proved_model="frontend.il", bound_model="binding.il", read_script="read.ys",
            proof_script="proof.ys", proof_root=str(self.root))
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
    def test_fixed_xlen_presets_do_not_generate_unsupported_signoff_profiles(self):
        config = self.root / 'rtl/configs/default/rapt_config.svh'
        config.write_text('`define RAPT_XLEN 32\n')
        self.assertEqual(preset_xlens(config), (32,))
        self.assertEqual(inventory(self.root)['profiles'],
                         ['default/rv32/dff', 'default/rv32/sram'])
        config.write_text('`ifdef RAPT_RV64\n`define RAPT_XLEN 64\n'
                          '`else\n`define RAPT_XLEN 32\n`endif\n')
        self.assertEqual(preset_xlens(config), (32, 64))
        self.assertEqual(len(inventory(self.root)['profiles']), 4)
        config.write_text('// `define RAPT_XLEN 32\n`define RAPT_XLEN `EXTERNAL_XLEN\n')
        self.assertEqual(preset_xlens(config), (32, 64))

    def test_scope_rechecks_source_and_metadata_epochs_after_receipt_audits(self):
        scenarios = ('stable', 'add-rtl', 'edit-rtl', 'remove-rtl', 'add-profile',
                     'edit-review', 'edit-index', 'edit-receipt', 'edit-verifier',
                     'edit-harness', 'edit-artifact')
        for strict in (False, True):
            for scenario in scenarios:
                with self.subTest(strict=strict, scenario=scenario), \
                        tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    for name in self.scope['sources']:
                        target = root / name
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(self.root / name, target)
                    harness_name = 'verification/formal/harness.sv'
                    harness = root / harness_name
                    harness.parent.mkdir(parents=True)
                    shutil.copy2(self.root / harness_name, harness)
                    artifact = root / 'compiled-model.il'
                    artifact.write_text('module \\harness\nend\n')
                    artifact_digest = sha(artifact)
                    verifier = root / 'verification/scripts'
                    verifier.mkdir(parents=True)
                    for name in ('formal_scope.py', 'prf_formal.py', 'yosys_common.py'):
                        shutil.copy2(Path(__file__).parent / name, verifier / name)
                    review = root / 'review.json'
                    review.write_text(json.dumps(self.complete_review()))
                    scope = inventory(root)
                    self.assertEqual(apply_contract_review(scope, self.complete_review()), [])
                    expected = sorted(required_contracts(scope))
                    receipts = []
                    for number, binding in enumerate(expected):
                        path = root / f'receipt-{number}.json'
                        path.write_text(json.dumps(dict(binding=binding,
                            inputs={harness_name: sha(harness)})))
                        receipts.append(path)
                    index = root / 'receipts.json'
                    index.write_text(json.dumps([path.name for path in receipts]))
                    calls = []
                    def audited(receipt, *unused, observed_inputs=None):
                        # Emulate already-audited proofs to isolate the gate's epoch checks.
                        for name, digest in receipt['inputs'].items():
                            audit_file(root / name, digest, 'proof input', observed_inputs)
                        audit_file(artifact, artifact_digest, 'proof artifact', observed_inputs)
                        calls.append(receipt['binding'])
                        if len(calls) == len(expected):
                            if scenario == 'add-rtl':
                                (root / 'rtl/new.sv').write_text('module new_unit; endmodule\n')
                            elif scenario == 'edit-rtl':
                                path = root / 'rtl/unit.sv'
                                path.write_text(path.read_text() + '// edit during audit\n')
                            elif scenario == 'remove-rtl':
                                (root / 'rtl/unit.sv').unlink()
                            elif scenario == 'add-profile':
                                path = root / 'rtl/configs/new/rapt_config.svh'
                                path.parent.mkdir()
                                path.write_text('`define WIDTH 8\n')
                            elif scenario == 'edit-review':
                                review.write_text('{}\n')
                            elif scenario == 'edit-index':
                                index.write_text('[]\n')
                            elif scenario == 'edit-receipt':
                                receipts[0].write_text('{}\n')
                            elif scenario == 'edit-verifier':
                                path = verifier / 'formal_scope.py'
                                path.write_text(path.read_text() + '# concurrent checker edit\n')
                            elif scenario == 'edit-harness':
                                harness.write_text(harness.read_text() + '// concurrent harness edit\n')
                            elif scenario == 'edit-artifact':
                                artifact.write_text(artifact.read_text() + '# concurrent model edit\n')
                        return tuple(receipt['binding'])
                    output = root / 'scope'
                    command = ['scope', '--source-root', str(root), '--output', str(output),
                               '--contract-review', str(review), '--receipt-index', str(index)]
                    if strict:
                        command.append('--signoff')
                    with patch.object(sys, 'argv', command), patch('builtins.print'), \
                            patch('formal_scope.audit_receipt', side_effect=audited), \
                            patch('formal_scope.__file__', str(verifier / 'formal_scope.py')):
                        result = scope_main()
                    report = json.loads((output / 'signoff.json').read_text())
                    stable = scenario == 'stable'
                    self.assertEqual(result, 0 if stable else 1)
                    self.assertEqual(report['whole_rtl_signoff'], stable)
                    self.assertEqual(report['accepted'], [list(row) for row in expected] if stable else [])
                    self.assertEqual(bool(report['epoch_errors']), not stable)
                    self.assertTrue(report['evaluation_complete'])
                    self.assertEqual(set(report['verifier_inputs']),
                                     {'formal_scope.py', 'prf_formal.py', 'yosys_common.py'})

    def test_receipt_observations_reject_mixed_versions_of_one_file(self):
        path = self.root / 'frontend.il'
        observed = {}
        audit_file(path, sha(path), 'proof artifact', observed)
        path.write_text(path.read_text() + '# changed after the first receipt\n')
        with self.assertRaisesRegex(ValueError, 'changed between receipts'):
            audit_file(path, sha(path), 'proof artifact', observed)

    def test_scope_invalidates_a_previous_signoff_before_input_failure(self):
        output = self.root / 'prior-scope'
        output.mkdir()
        path = output / 'signoff.json'
        path.write_text(json.dumps(dict(whole_rtl_signoff=True)))
        review = self.root / 'broken-review.json'
        review.write_text('not-json')
        command = ['scope', '--source-root', str(self.root), '--output', str(output),
                   '--contract-review', str(review), '--signoff']
        with patch.object(sys, 'argv', command), self.assertRaises(json.JSONDecodeError):
            scope_main()
        report = json.loads(path.read_text())
        self.assertFalse(report['whole_rtl_signoff'])
        self.assertFalse(report['evaluation_complete'])

    def test_native_receipt_checks_actual_script_model_and_executed_command(self):
        self.audit()
        script = self.root / 'proof.ys'
        log = self.root / 'proof.log'
        saved_script, saved_log = script.read_text(), log.read_text()
        cases = ('missing-script', 'missing-origin', 'unrelated-model', 'unrelated-directory',
                 'changed-top', 'remove-state', 'different-parsed-model',
                 'remove-assertions', 'extra-assumption', 'bounded-query',
                 'different-executed-command', 'missing-executed-command')
        for case in cases:
            receipt = copy.deepcopy(self.receipt)
            text, output = saved_script, saved_log
            if case == 'missing-script':
                del receipt['model_binding']['proof_script']
            elif case == 'missing-origin':
                del receipt['model_binding']['proof_root']
            elif case == 'different-parsed-model':
                output = output.replace('Input filename: ', 'Input filename: unrelated/', 1)
            elif case == 'different-executed-command':
                output = output.replace('read_rtlil ', 'read_verilog ', 1)
            elif case == 'missing-executed-command':
                output = 'Induction step proven: SUCCESS!\n'
            else:
                old, new = {
                    'unrelated-model': ('frontend.il;', 'unrelated.il;'),
                    'unrelated-directory': (str(self.root) + '/', str(self.root / 'other') + '/'),
                    'changed-top': ('-top harness', '-top unrelated'),
                    'remove-state': ('memory_map;', 'memory_map; delete t:$dff;'),
                    # Split so the native synthesis policy scan does not see a real command.
                    'remove-assertions': ('chformal -lower;', 'chformal ' + '-remove -assert;'),
                    'extra-assumption': ('-prove correct 1', '-set state 0 -prove correct 1'),
                    'bounded-query': ('-tempinduct ', ''),
                }[case]
                text = text.replace(old, new)
                output = output.replace(saved_script.strip(), text.strip())
            script.write_text(text)
            log.write_text(output)
            receipt['artifacts']['proof.ys'] = sha(script)
            receipt['artifacts']['proof.log'] = sha(log)
            try:
                with self.subTest(case=case), self.assertRaises(ValueError):
                    self.audit(receipt)
            finally:
                script.write_text(saved_script)
                log.write_text(saved_log)

    def test_native_receipt_can_move_with_its_complete_artifact_directory(self):
        destination = self.root / 'relocated'
        destination.mkdir()
        for name in self.receipt['artifacts']:
            shutil.copy2(self.root / name, destination / name)
        scope = copy.deepcopy(self.scope)
        self.assertEqual(apply_contract_review(scope, self.complete_review()), [])
        expected = self.audit()
        for name in self.receipt['artifacts']:
            (self.root / name).unlink()
        actual = audit_receipt(self.receipt, scope, self.root, destination)
        self.assertEqual(actual, expected)

    def test_receipt_indexes_share_the_direct_audit_and_reject_invalid_members(self):
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps(self.receipt))
        review = self.root / 'review.json'
        review.write_text(json.dumps(self.complete_review()))
        index = self.root / 'receipts.json'
        scenarios = [('direct', None), ('indexed', ['receipt.json'] * 1000),
                     ('escape', ['receipt.json', '../escape.json']), ('object', {}),
                     ('invalid-member', [1]), ('invalid-json', 'not-json')]
        accepted = {}
        for name, entries in scenarios:
            output = self.root / ('scope-' + name)
            command = ['scope', '--source-root', str(self.root), '--output', str(output),
                       '--contract-review', str(review), '--signoff']
            if name == 'direct':
                command += ['--receipts', str(receipt)]
            else:
                index.write_text(entries if name == 'invalid-json' else json.dumps(entries))
                command += ['--receipt-index', str(index)]
            with self.subTest(name=name), patch.object(sys, 'argv', command), \
                    patch('builtins.print'):
                self.assertEqual(scope_main(), 1)  # Other required contracts remain open.
            result = json.loads((output / 'signoff.json').read_text())
            accepted[name] = result['accepted']
            self.assertEqual(len(result['rejected']), 0 if name in ('direct', 'indexed') else 1)
            self.assertEqual(len(result['accepted']), 1 if name in ('direct', 'indexed') else 0)
        self.assertEqual(accepted['direct'], accepted['indexed'])

    def test_native_receipt_requires_exact_full_model_and_elaboration_binding(self):
        self.audit()
        cases = ("missing-binding", "wrong-fingerprint", "missing-artifact", "changed-init",
                 "wrong-parameter", "wrong-top", "wrong-preset")
        for case in cases:
            receipt = copy.deepcopy(self.receipt)
            saved = {name: (self.root / name).read_bytes() for name in ("binding.il", "read.ys")}
            if case == "missing-binding":
                del receipt["model_binding"]
            elif case == "wrong-fingerprint":
                receipt["model_binding"]["canonical_sha256"] = "0" * 64
            elif case == "missing-artifact":
                del receipt["artifacts"]["binding.il"]
            elif case == "changed-init":
                path = self.root / "binding.il"
                path.write_text(path.read_text().replace("8'00000000", "8'00000001"))
                receipt["artifacts"]["binding.il"] = sha(path)
            else:
                path = self.root / "read.ys"
                old, new = {"wrong-parameter": ("WIDTH=8", "WIDTH=9"),
                            "wrong-top": ("--top harness", "--top different"),
                            "wrong-preset": ("/configs/default", "/configs/different")}[case]
                path.write_text(path.read_text().replace(old, new))
                receipt["artifacts"]["read.ys"] = sha(path)
            try:
                with self.subTest(case=case), self.assertRaises(ValueError):
                    self.audit(receipt)
            finally:
                for name, value in saved.items():
                    (self.root / name).write_bytes(value)

    def test_current_complete_receipt(self):
        self.assertEqual(self.audit(), ("rtl/unit.sv:unit", "functional", "default/rv32/dff",
                                       binding_key({"WIDTH": 8})))

    def test_small_contract_rejects_timeout_and_tool_error_despite_success_marker(self):
        marker = 'SAT proof finished - no model found: SUCCESS!'
        config = dict(description='Fixture contract', top='harness', source='rtl/unit.sv',
                      option='rtl', option_help='Fixture RTL', scope='Fixture only', label='fixture')
        for code, diagnostic in ((124, ''), (1, ''), (0, 'ERROR: failed\n'), (0, '')):
            with self.subTest(code=code, diagnostic=diagnostic):
                def fake_tool(command, *, stdout, **kwargs):
                    stdout.write(marker + '\n' + diagnostic)
                    self.assertEqual(command[0], '/configured/yosys')
                    return subprocess.CompletedProcess(command, code)
                output = self.root / f'evidence-{code}-{bool(diagnostic)}'
                args = SimpleNamespace(source_root=self.root, output=output, rtl=None)
                with patch('formal_contract.run_bounded', side_effect=fake_tool), \
                        patch.dict(os.environ, RAPTOR_YOSYS_REAL='/configured/yosys'), \
                        patch('builtins.print'):
                    exit_code = run_contract(args, **config)
                report = json.loads((output / 'results.json').read_text())
                passed = code == 0 and not diagnostic
                self.assertEqual(exit_code, 0 if passed else 1)
                self.assertEqual(report['complete'], passed)
                self.assertEqual(len(report['cases']), 2 if passed else 1)

    def test_ioq_producer_proofs_cannot_replace_store_and_atomic_contracts(self):
        path = self.root / 'rtl/core/backend/lsu/rapt_lsu_ioq.sv'
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

    def test_axi_passthrough_proof_cannot_close_buffered_transport(self):
        path = self.root / 'rtl/uncore/rapt_axi_r_buffer.sv'
        path.parent.mkdir(parents=True)
        path.write_text('module rapt_axi_r_buffer(input clock, reset);\n'
                        'always @(posedge clock);\nendmodule\n')
        self.scope = inventory(self.root)
        unit = next(u for u in self.scope['units'] if u['name'] == 'rapt_axi_r_buffer')
        expected = {'channel-passthrough', 'elastic-order', 'capacity', 'registered-latency',
                    'stall-preservation', 'bypass', 'conditional-drain', 'reset'}
        self.assertTrue(expected <= set(unit['obligations']))
        review = self.complete_review()
        review['units'][unit['id']]['obligations'] = ['functional', 'channel-passthrough']
        errors = apply_contract_review(self.scope, review)
        self.assertTrue(any('removes required obligations' in error for error in errors))

    def test_tlb_lookup_review_cannot_remove_refill_fence_or_replacement_obligations(self):
        path = self.root / 'rtl/core/memory/mmu/rapt_tlb.sv'
        path.parent.mkdir(parents=True)
        path.write_text(''.join(f'module {name}(input clock, reset, flush);\n'
                                'always @(posedge clock);\nendmodule\n'
                                for name in ('rapt_tlb', 'rapt_data_tlb')))
        self.scope = inventory(self.root)
        review = self.complete_review()
        lookup = ['lookup-owner', 'lookup-miss', 'asid-global-lookup', 'canonical-lookup']
        for unit in self.scope['units']:
            if unit['path'] != str(path.relative_to(self.root)):
                continue
            self.assertTrue(set(lookup + ['fill-history', 'replacement-selection'])
                            <= set(unit['obligations']))
            review['units'][unit['id']]['obligations'] = lookup
        errors = apply_contract_review(self.scope, review)
        self.assertEqual(sum('removes required obligations' in error for error in errors), 2)

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
