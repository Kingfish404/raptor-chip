#!/usr/bin/env python3
"""Static regression check for known synthesis bypass switches, not RTL proof."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Split spellings so this test's own source does not look like a tool invocation.
FORBIDDEN = tuple('--' + name for name in (
    'ignore-assertions', 'ignore-initial', 'unroll-limit', 'unroll-count',
    'allow-use-before-declare', 'ignore-unknown-modules', 'ignore-timing'))

# Option order and selecting all formal cells must not bypass the policy.
# Keep legal assumption lowering in formal harnesses outside this check.
FORMAL_REMOVAL = re.compile(r'\bchformal\b[^;\n]*?(?<!\S)-remove\b')


def violations(text):
    text = re.sub(r'\\\r?\n', ' ', text)
    return ([flag for flag in FORBIDDEN if flag in text]
            + [match.group(0) for match in FORMAL_REMOVAL.finditer(text)])


class NativePolicyTest(unittest.TestCase):
    def test_driver_checks_precede_normalization_and_guard_final_netlist(self):
        text = (ROOT/'lspd/syn/scripts/synth.tcl').read_text()
        # Ignore comments; check command ordering, not explanatory prose.
        commands = [line.strip() for line in text.splitlines()
                    if line.strip() and not line.lstrip().startswith('#')]
        self.assertEqual(commands.count('check -assert'), 2)
        self.assertNotIn('check', commands)
        self.assertLess(commands.index('check -assert'), commands.index('synth -top $top'))
        self.assertLess(commands.index('check -assert'), commands.index('opt -undriven'))
        self.assertGreater(max(i for i,c in enumerate(commands) if c=='check -assert'),
                           commands.index('setundef -zero'))

    def test_rejects_bypass_spellings(self):
        for flag in FORBIDDEN:
            self.assertEqual(violations('read_slang ' + flag), [flag])

    def test_allows_explicit_contract_checks(self):
        self.assertEqual(violations('read_slang -DSYNTHESIS; select -assert-none t:$assert'), [])

    def test_rejects_formal_removal_option_orders(self):
        for options in ('-remove', '-assert -remove', '-remove -assert',
                        '-assert \\\n -remove', '-assert\t-remove'):
            with self.subTest(options=options):
                self.assertTrue(violations('chformal ' + options))

    def test_allows_formal_assumption_lowering(self):
        self.assertEqual(violations('chformal -assume -lower; sat -prove ok 1'), [])

    def test_scoped_evaluation_entrypoints(self):
        files = list((ROOT / 'verify/scripts').glob('*.py'))
        # The standalone vector engine is not instantiated by rapt_core;
        # its independent synthesis entrypoint must obey the same policy.
        files += list((ROOT / 'verify/vpu').glob('*.py'))
        files += [ROOT / 'verify/vpu/Makefile']
        files += list((ROOT / 'lspd').rglob('Makefile'))
        files += list((ROOT / 'lspd').rglob('*.tcl'))
        files += [ROOT / 'sim/Makefile']
        for path in files:
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertEqual(violations(path.read_text()), [])


if __name__ == '__main__':
    unittest.main()
