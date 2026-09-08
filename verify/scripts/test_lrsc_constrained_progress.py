"""Guard against accepting simulator/environment failures as negative controls."""
import unittest

from lrsc_constrained_progress import classify


class ResultClassification(unittest.TestCase):
    def test_positive_requires_finisher_and_successful_exit(self):
        good = 'Finisher: poweroff (0x5555)'
        self.assertTrue(classify(0, good, False, 0x1000, 0x1040))
        for status, log in ((0, ''), (1, good), (0, good + '\nFinisher: fail')):
            self.assertFalse(classify(status, log, False, 0x1000, 0x1040))

    def test_negative_requires_observed_execution_inside_loop(self):
        timeout = 'Wall-clock timeout (120s) exceeded at pc: 00001020, 800000 cycles, 40000 insts.'
        self.assertTrue(classify(1, timeout, True, 0x1000, 0x1040))
        self.assertTrue(classify(1, timeout + '\nHIT BAD TRAP', True, 0x1000, 0x1040))
        for status, log, killed in (
            (124, '', True), (1, 'cannot open shared object file', False),
            (0, timeout, False), (1, timeout, True),
            (1, timeout.replace('00001020', '00001040'), False),
            (1, timeout.replace('40000 insts', '0 insts'), False),
            (1, timeout + '\nFinisher: poweroff (0x5555)', False),
            (1, timeout + '\nAssertion failed', False),
            (1, timeout + '\nFinisher: fail (0x3333)', False),
            (1, 'HIT BAD TRAP', False),
        ):
            with self.subTest(status=status, log=log, killed=killed):
                self.assertFalse(classify(status, log, True, 0x1000, 0x1040, killed))


if __name__ == '__main__':
    unittest.main()
