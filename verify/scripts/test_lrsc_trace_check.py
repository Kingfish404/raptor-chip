import unittest
from lrsc_trace_check import check_trace


SUCCESS = '''LRSC_EVT 0 A 100 1 0 1 1 1 0 1 0 1 0
LRSC_EVT 0 Q 1 0 0 0 100 1 0 200
LRSC_EVT 1 F 1 0
LRSC_EVT 1 R 100 1800202f 1 0 0 1
LRSC_EVT 1 Q 0 1 0 0 0 0 0 0
LRSC_EVT 2 Q 0 0 1 0 0 0 0 0
'''


class TraceChecks(unittest.TestCase):
    def test_success_requires_commit_and_drain(self):
        self.assertEqual(check_trace(SUCCESS, 1)['drained_sc'], 1)
        for text in (SUCCESS.replace('Q 0 1 0 0', 'Q 0 0 0 0'),
                     SUCCESS.replace('LRSC_EVT 1 F 1 0\n', ''),
                     SUCCESS.replace('LRSC_EVT 2 Q 0 0 1 0 0 0 0 0\n', ''),
                     SUCCESS.replace('1800202f 1 0 0 1', '1800202f 1 0 0 0')):
            with self.subTest(text=text), self.assertRaises((AssertionError, KeyError)):
                check_trace(text, 1)

    def test_flush_cancels_without_retirement(self):
        text = '''LRSC_EVT 0 F 1 0
LRSC_EVT 0 A 100 1 0 1 1 1 0 1 0 1 1
'''
        counts = check_trace(text, 0)
        self.assertEqual(counts['canceled_sc'], 1)
        self.assertEqual(counts['retired_success'], 0)

    def test_rejected_identity_is_not_an_acceptance(self):
        text = 'LRSC_EVT 0 A 100 1 0 1 1 0 0 1 0 0 0\n'
        self.assertEqual(check_trace(text, 0)['accepted_sc'], 0)

    def test_empty_log_rejected(self):
        with self.assertRaises(ValueError):
            check_trace('', 0)

    def test_cycle_regression_rejected(self):
        with self.assertRaises(ValueError):
            check_trace('LRSC_EVT 2 F 1 0\nLRSC_EVT 1 F 1 0\n', 0)


if __name__ == '__main__':
    unittest.main()
