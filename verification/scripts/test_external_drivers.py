#!/usr/bin/env python3
"""Reject false passes from riscv-tests/HTIF, Pono, Cascade and the extended campaign drivers."""
import argparse
import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import cascade_fuzz as cascade
import extended_campaign as campaign
import pono_recovery as pono
from pathlib import Path
from unittest.mock import patch
from patch_riscv_dv_npc import replace_once
from run_riscv_tests import ROOT, npc_passed, select_tests


class UpstreamRunnerTest(unittest.TestCase):
    def test_failed_preflight_invalidates_a_previous_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / 'report.json'
            report.write_text(json.dumps(dict(complete=True, passed=True)))
            process = subprocess.run([
                'python3', str(ROOT / 'verification/scripts/run_riscv_tests.py'), 'run',
                '--repo', str(root / 'missing-repo'), '--output', str(root),
                '--npc', str(root / 'missing-npc')], capture_output=True, text=True)
            self.assertNotEqual(process.returncode, 0)
            value = json.loads(report.read_text())
            self.assertFalse(value['passed'])
            self.assertFalse(value['complete'])

    def test_riscv_dv_make_selects_matching_xlen_and_abi(self):
        for isa, abi in [('rv32', 'ilp32'), ('rv64', 'lp64')]:
            with self.subTest(isa=isa):
                result = subprocess.run(['make', '-n', '-C', str(ROOT / 'verification'),
                                         'riscv-dv-gen', f'ISA={isa}'],
                                        capture_output=True, text=True, check=True)
                self.assertIn(f'--target raptor_{isa}imac', result.stdout)
                self.assertIn(f'--isa {isa}imac_zicsr_zifencei --mabi {abi}', result.stdout)
                self.assertIn(f'/riscv-dv/{isa}/raptor_privileged_smoke', result.stdout)

    def test_illegal_burst_adapter_accepts_blank_lines_and_is_idempotent(self):
        # "$^" matches blank lines under MULTILINE; it is not a never-match regex.
        original = 'main:             add a0, a0, a1\n\nnext:\n'
        result = replace_once(original, r'^main:\s+(.+)$', r'main:\n\1',
                              r'(?!)', Path('generated.S'))
        self.assertEqual(result, 'main:\nadd a0, a0, a1\n\nnext:\n')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'test.S'
            source.write_text('''csrw 0x301, x31
main:             add a0, a0, a1

test_done:
                  li gp, 1
                  ecall
write_tohost:
                  sw gp, tohost, t5
''')
            command = ['python3', str(ROOT / 'verification/scripts/patch_riscv_dv_npc.py'),
                       '--illegal-burst-count', '4', str(root)]
            subprocess.run(command, check=True, capture_output=True)
            adapted = source.read_text()
            self.assertEqual(adapted.count('.4byte 0xffffffff'), 4)
            self.assertIn('bne gp, t5, .Lraptor_finisher_fail', adapted)
            self.assertIn('li t4, 0x3333', adapted)
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(source.read_text(), adapted)

    def test_only_observed_success_on_the_requested_xlen_passes(self):
        good = 'HTIF: configured XLEN=64 tohost=0x80001000\n' \
               'HTIF: tohost=0x80001000 exit=0\nHIT GOOD TRAP\n'
        self.assertTrue(npc_passed(0, good, 64))
        self.assertFalse(npc_passed(0, good, 64, difftest=True))
        self.assertTrue(npc_passed(0, good + '[difftest] reference ISA mask: 0x0', 64,
                                   difftest=True))
        for code, text, xlen in [(1, good, 64), ('timeout', good, 64), (0, good, 32),
                                 (0, 'HIT GOOD TRAP', 64), (0, good + 'ABORT', 64),
                                 (0, good + 'mismatch', 64),
                                 (0, good.replace('exit=0', 'exit=1'), 64)]:
            with self.subTest(code=code, text=text, xlen=xlen):
                self.assertFalse(npc_passed(code, text, xlen))

    def test_upstream_selection_does_not_silently_drop_misspelled_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / 'isa/rv64ui'
            folder.mkdir(parents=True)
            (folder / 'Makefrag').write_text('rv64ui_sc_tests = add \\\n  lbu\n')
            for name in ('add', 'lbu'):
                (folder / f'{name}.S').write_text('')
            selected = select_tests(root, 64, ['ui'], ['*-p-lbu'])
            self.assertEqual([test['name'] for test in selected], ['rv64ui-p-lbu'])
            with self.assertRaisesRegex(ValueError, 'matched nothing'):
                select_tests(root, 64, ['ui'], ['*-p-add', '*-p-typo'])
            with self.assertRaisesRegex(ValueError, 'Unsupported test group'):
                select_tests(root, 64, ['missing'], [])


class HtifMemoryTest(unittest.TestCase):
    def test_rv32_and_rv64_actual_htif_observer(self):
        compiler = shutil.which('c++')
        self.assertIsNotNone(compiler, 'A host C++ compiler is required')
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / 'common.h').write_text('''#pragma once
#include <cstdint>
#include <cstdio>
#include <cassert>
using word_t = WORD;
using paddr_t = word_t;
#define MBASE 0x80000000u
#define MSIZE 4096
#define Log(...) printf(__VA_ARGS__)
enum { NPC_RUNNING, NPC_END, NPC_ABORT };
struct NPCState { int state = NPC_RUNNING; int host_exit_ok = 0; };
''')
            (work / 'memory.h').write_text('''#pragma once
#include <common.h>
uint8_t *guest_to_host(paddr_t);
''')
            (work / 'verilated.h').write_text('''#pragma once
struct VerilatedContext { bool finished = false; void gotFinish(bool v) { finished = v; } };
''')
            (work / 'test.cc').write_text('''#include <htif.h>
#include <verilated.h>
#include <cstring>
#include <initializer_list>
NPCState npc;
VerilatedContext context;
VerilatedContext *contextp = &context;
uint8_t ram[MSIZE] = {};
uint8_t *guest_to_host(paddr_t a) { return ram + (uint64_t(a) - MBASE); }
void npc_abort() { npc.state = NPC_ABORT; npc.host_exit_ok = 0; context.finished = true; }
void clear() { npc = {}; context.finished = false; }
void mailbox(uint64_t value) { memcpy(ram + 8, &value, 8); }
int main() {
  mailbox(1);
  htif_observe_write(MBASE + 8, 15);
  assert(!context.finished); // opt-in only
  for (auto text : {"", "-1", "0", "0x80000001", "0x80001000", "0x180000008"})
    assert(htif_set_tohost(text) != 0);
  assert(htif_set_tohost("0x80000008") == 0);
  htif_observe_write(MBASE, 15);
  htif_observe_write(MBASE + 8, 0);
  assert(!context.finished);
  for (uint64_t value : {uint64_t(0), uint64_t(2), uint64_t(1) << 56 | 1}) {
    mailbox(value);
    htif_observe_write(MBASE + 8, 15);
    assert(!context.finished); // not an exit / a different HTIF device
  }
  mailbox(1);
  htif_observe_write(MBASE + 8, 15);
  assert(context.finished && npc.state == NPC_END && npc.host_exit_ok);
  clear();
  mailbox(3);
  htif_observe_write(MBASE + 8, 1);
  assert(context.finished && npc.state == NPC_ABORT && !npc.host_exit_ok);
  clear();
  mailbox(1);
  htif_observe_write(MBASE + 12, 15); // RV32's second mailbox word
  assert(context.finished && npc.state == NPC_END);
}
''')
            for xlen in (32, 64):
                with self.subTest(xlen=xlen):
                    binary = work / f'htif-{xlen}'
                    subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                                    f'-DWORD=uint{xlen}_t', '-I' + str(work),
                                    '-I' + str(ROOT / 'sim/include'),
                                    str(ROOT / 'sim/csrc/mem/htif.cc'), str(work / 'test.cc'),
                                    '-o', str(binary)], check=True, capture_output=True)
                    subprocess.run([str(binary)], check=True, capture_output=True)


class PonoOutcomes(unittest.TestCase):
    def test_parameter_mask_and_nonempty_widths(self):
        self.assertEqual(pono.dimensions('127:8:0x55:64:8'), (127, 8, 85, 64, 8))
        for text in ('1:1:2:32:1', '0:1:1:32:4', '3:2:1:0:4', '3:2:1:32',
                     '3:2:1:32:0'):
            with self.subTest(text=text), self.assertRaises(argparse.ArgumentTypeError):
                pono.dimensions(text)

    def test_result_and_exit_code_must_agree(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'proof.log'
            cases = [('sat\n', 0, 'sat'), ('unsat\n', 1, 'unsat'),
                     ('unknown\n', 2, 'unknown'), ('unsat\n', 0, 'error'),
                     ('sat\n', 'timeout', 'error'), ('unsat\nERROR\n', 1, 'error'),
                     ('sat\nunsat\n', 0, 'error'), ('', 0, 'error')]
            for text, code, expected in cases:
                with self.subTest(text=text, code=code):
                    log.write_text(text)
                    self.assertEqual(pono.outcome(dict(log=str(log), exit=code)), expected)

    def test_monitor_requires_reset_and_event_reachability(self):
        source = pono.monitor_source(127)
        self.assertIn('if (!past_valid) assume (reset)', source)
        self.assertIn('assert (correct)', source)
        self.assertIn("cover ((pono_seen_events & 7'd127) == 7'd127)", source)


class CascadeChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / 'state.txt'
        self.text = ('xlen=64\ninstr=42\n'
                     'save_trigger=pc target=0000000080000040 actual=0000000080000040\n'
                     'gpr1=0xffffffffffffffff\nfpr0=0xffffffff7fc00000\n')
        self.golden = dict(final_pc='0x80000040', num_gpr=2, num_fpr=1,
                           expected=[[(1 << 64) - 1], [0xffffffff7fc00000]])
        self.state.write_text(self.text)

    def test_matches_spike_raw_register_bits(self):
        self.assertEqual(cascade.compare_checkpoint(self.state, self.golden, 64), [])

    def test_integer_only_program_has_no_fp_oracle(self):
        self.golden['num_fpr'] = 0
        self.golden['expected'][1] = []
        self.state.write_text(self.text.split('fpr0=')[0])
        self.assertEqual(cascade.compare_checkpoint(self.state, self.golden, 64), [])

    def test_corrupted_spike_integer_and_float_oracles_fail(self):
        for bank, register in [(0, 'gpr1'), (1, 'fpr0')]:
            golden = copy.deepcopy(self.golden)
            golden['expected'][bank][0] ^= 1
            mismatches = cascade.compare_checkpoint(self.state, golden, 64)
            self.assertEqual(mismatches[0]['register'], register)

    def test_wrong_pc_xlen_empty_missing_or_duplicate_state_is_rejected(self):
        changes = [('actual=0000000080000040', 'actual=0000000080000044'),
                   ('xlen=64', 'xlen=32'), ('instr=42', 'instr=0'),
                   ('gpr1=', 'missing='), ('instr=42', 'instr=42\ninstr=43'),
                   ('save_trigger=pc', 'save_trigger=cycle')]
        for before, after in changes:
            with self.subTest(before=before):
                self.state.write_text(self.text.replace(before, after))
                with self.assertRaises((ValueError, KeyError)):
                    cascade.compare_checkpoint(self.state, self.golden, 64)

    def test_rv32_integer_width_and_nan_boxed_double_width_fp(self):
        self.state.write_text(self.text.replace('xlen=64', 'xlen=32')
                              .replace('gpr1=0xffffffffffffffff', 'gpr1=0xffffffff'))
        self.assertEqual(cascade.compare_checkpoint(self.state, self.golden, 32), [])

    def test_epilogue_cannot_overwrite_compared_registers(self):
        cascade.check_epilogue([0x0f000f37, 0x0000000f, 0x0000006f], 6)
        for words in ([], [0x000000b7], [0x00000053]):
            with self.subTest(words=words), self.assertRaises(ValueError):
                cascade.check_epilogue(words, 6)

    def test_upstream_revision_and_sources_are_checked(self):
        with patch.object(cascade, 'git', side_effect=[cascade.REVISION, '']):
            self.assertEqual(cascade.validate_source(Path('source')), cascade.REVISION)
        for results in (['wrong'], [cascade.REVISION, ' M fuzzer/code.py']):
            with patch.object(cascade, 'git', side_effect=results), self.assertRaises(ValueError):
                cascade.validate_source(Path('source'))


class ExtendedCampaignChecks(unittest.TestCase):
    def test_resume_keeps_completed_time_and_recorded_failures(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'source-manifest.json').write_text('{}\n')
            args = argparse.Namespace(output=root, parallel_builds=1, seconds=10800,
                                      resume=False, yosys=sys.executable)
            original = campaign.Campaign(args, {})
            original.report['lanes']['pono'] = dict(active_seconds=45, failed_batches=1)
            original.save()
            args.resume = True
            resumed = campaign.Campaign(args, {})
            self.assertEqual(resumed.report['lanes']['pono']['active_seconds'], 45)
            self.assertEqual(resumed.report['lanes']['pono']['failed_batches'], 1)
            self.assertFalse(resumed.report['passed'])

    def test_isolated_build_forwards_cross_compiler_and_architecture_flags(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'source-manifest.json').write_text('{}\n')
            args = argparse.Namespace(output=root, parallel_builds=1, seconds=10800,
                                      resume=False, cross='riscv-test-', yosys=sys.executable)
            runner = campaign.Campaign(args, {})
            runner.report['lanes']['small-rv32'] = dict(active_seconds=0)
            with patch.object(runner, 'execute', return_value={'exit': 0}) as execute:
                runner.build('small-rv32', 'small', 32, root / 'small-rv32')
            self.assertIn('VFLAGS=', execute.call_args_list[0].args[1])
            self.assertIn('CROSS_COMPILE=riscv-test-', execute.call_args_list[1].args[1])

    def test_parameter_schedule_expands_dimensions_and_seeds(self):
        shapes = [pono.dimensions(campaign.pono_shape((index * 137) % 4800))
                  for index in range(50)]
        self.assertIn(256, {row[0] for row in shapes})
        self.assertIn(0, {row[2] for row in shapes})
        self.assertEqual({row[3] for row in shapes}, {8, 32, 40, 64})
        self.assertEqual({row[4] for row in shapes}, {1, 2, 4, 8})
        cases = [campaign.fuzz_parameters(index) for index in range(48)]
        self.assertEqual(len({row['seed'] for row in cases}), 48)
        self.assertEqual({row['isa_profile'] for row in cases}, {'gc', 'imac'})
        self.assertEqual({row['delay'] for row in cases}, {7, 31, 127})
        self.assertEqual(max(row['instructions'] for row in cases), 50000)

    def test_snapshot_includes_dirty_sources_and_isolates_subsequent_edits(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, frozen = root / 'repo', root / 'snapshot'
            source.mkdir()
            subprocess.run(['git', 'init', '-q', str(source)], check=True)
            (source / 'tracked.py').write_text('original\n')
            subprocess.run(['git', '-C', str(source), 'add', 'tracked.py'], check=True)
            (source / 'tracked.py').write_text('dirty\n')
            (source / 'new.py').write_text('untracked\n')
            for name in ('third_party', 'nemu', 'abstract-machine'):
                (source / name).mkdir()
            hashes = campaign.snapshot(source, frozen)
            self.assertEqual((frozen / 'tracked.py').read_text(), 'dirty\n')
            self.assertIn('new.py', hashes)
            (source / 'tracked.py').write_text('later edit\n')
            self.assertEqual(campaign.sha(frozen / 'tracked.py'), hashes['tracked.py'])

    def test_build_time_excluded_and_timed_out_job_cannot_succeed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'source').mkdir()
            (root / 'source-manifest.json').write_text('{}\n')
            args = argparse.Namespace(output=root, parallel_builds=1, seconds=1, resume=False,
                                      yosys=sys.executable)
            runner = campaign.Campaign(args, {})
            runner.report['lanes']['test'] = dict(active_seconds=0)
            build = runner.execute('test', [sys.executable, '-c', 'print(42)'],
                                   root / 'build', 10, verification=False)
            self.assertEqual(build['exit'], 0)
            self.assertEqual(runner.report['lanes']['test']['active_seconds'], 0)
            failed = runner.execute('test', [sys.executable, '-c', 'import time; time.sleep(30)'],
                                    root / 'timeout', 0.2)
            self.assertEqual(failed['exit'], 'timeout')
            self.assertGreater(runner.report['lanes']['test']['active_seconds'], 0)
            self.assertFalse(runner.report['complete'])


if __name__ == '__main__':
    unittest.main()
